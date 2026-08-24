//! Phase A gate: a recorded command stream, replayed into a shadow VRAM, must
//! reproduce the rasterizer's VRAM byte for byte.
//!
//! This binary is compiled against the recording core module (`gpu_sink =
//! .dual`); the other unit-test files are not, and cannot see the recorder.

const std = @import("std");
const ps1_core = @import("ps1_core");
const expectVramEqual = @import("vram_compare.zig").expectVramEqual;

const Gpu = ps1_core.gpu.Gpu;
const Vram = ps1_core.gpu.Vram;
const DrawingEnv = ps1_core.gpu.Regs.DrawingEnv;
const command = ps1_core.gpu.command;
const recorder = ps1_core.gpu.recorder;

comptime {
    // If this binary ends up on the software core module the whole suite is
    // vacuous, so fail the build rather than pass silently.
    if (ps1_core.gpu.Sink.kind != .dual) @compileError("gpu_stream_test needs gpu_sink = .dual");
}

fn xy(x: u16, y: u16) u32 {
    return @as(u32, x & 0x7FF) | (@as(u32, y & 0x7FF) << 16);
}

/// Both the Gpu (1 MB of VRAM plus 6.5 MB of recorder) and the shadow VRAM
/// are heap-allocated: 8.5 MB of test-runner stack is not available.
const StreamCase = struct {
    a: std.mem.Allocator,
    gpu: *Gpu,
    shadow: *Vram,
    env: DrawingEnv = .{},

    fn init(a: std.mem.Allocator) !StreamCase {
        const gpu = try a.create(Gpu);
        gpu.* = Gpu.init();
        gpu.sink.rec.arm();

        const shadow = try a.create(Vram);
        shadow.* = .{};

        return .{ .a = a, .gpu = gpu, .shadow = shadow };
    }

    fn deinit(self: *StreamCase) void {
        self.a.destroy(self.gpu);
        self.a.destroy(self.shadow);
    }

    fn gp0(self: *StreamCase, word: u32) void {
        _ = self.gpu.writeGp0(word);
    }

    fn gp1(self: *StreamCase, word: u32) void {
        self.gpu.writeGp1(word);
    }

    /// Drains the GP0 FIFO so every queued word has actually executed.
    ///
    /// **Call this before every `gp1()` and before any direct `gpu.readData()`,
    /// and it is not optional.** GP1 writes execute immediately
    /// (`gpu.zig:232`), while GP0 words queue into a 16-entry FIFO gated on
    /// `cycle_debt` — and once the debt goes positive, `writeGp0` only retires
    /// a word when the FIFO is already full, so the FIFO sits a **permanent 16
    /// words behind** for the rest of the test. A `gp1()` issued without
    /// draining therefore lands 16 GP0 words earlier than the source reads,
    /// and the queued words are applied AFTER it.
    ///
    /// The trap is that `expectIdentical` still passes: the live path and the
    /// replay see the same order either way, so the round trip is green and the
    /// test has quietly stopped exercising the scenario its name describes.
    /// Task 3's GP1(00) test is the sharp example — 7 GP0 words are written
    /// before the reset and only 1 has executed, so the E3/E4/E5 writes land
    /// after `draw_env = .{}` and the drawing area is not the default at all.
    fn drain(self: *StreamCase) void {
        _ = self.gpu.step(50_000_000);
    }

    /// Full drawing area, zero offset — the same preamble gpu_test.zig uses.
    fn fullArea(self: *StreamCase) void {
        self.gp0(0xE3000000);
        self.gp0(0xE407FFFF);
        self.gp0(0xE5000000);
    }

    fn expectIdentical(self: *StreamCase) !void {
        self.drain();
        const s = self.gpu.sink.rec.takeFrame();
        try std.testing.expect(s.complete);
        command.replay(s, self.shadow, &self.env);
        try expectVramEqual(&self.gpu.vram, self.shadow);
    }
};

/// Issues GP0(A0) for a w x h rectangle at (x, y) plus the (w*h+1)/2 payload
/// words that follow it, filled with a deterministic pattern. Every test that
/// samples a texture needs real texels in VRAM first, and they have to arrive
/// through the stream like everything else.
fn uploadPattern(c: *StreamCase, x: u16, y: u16, w: u16, h: u16, seed: u16) void {
    c.gp0(0xA0000000);
    c.gp0(@as(u32, x) | (@as(u32, y) << 16));
    c.gp0(@as(u32, w) | (@as(u32, h) << 16));

    const words = (@as(u32, w) * @as(u32, h) + 1) / 2;
    var i: u32 = 0;
    while (i < words) : (i += 1) {
        const lo: u16 = seed +% @as(u16, @truncate(i *% 2));
        const hi: u16 = seed +% @as(u16, @truncate(i *% 2 +% 1));
        c.gp0(@as(u32, lo) | (@as(u32, hi) << 16));
    }
}

fn expectEnvEqual(want: *const DrawingEnv, got: *const DrawingEnv) !void {
    try std.testing.expectEqual(want.draw_mode, got.draw_mode);
    try std.testing.expectEqual(want.tex_window, got.tex_window);
    try std.testing.expectEqual(want.area_top_left, got.area_top_left);
    try std.testing.expectEqual(want.area_bot_right, got.area_bot_right);
    try std.testing.expectEqual(want.offset, got.offset);
    try std.testing.expectEqual(want.mask_bit, got.mask_bit);
    try std.testing.expectEqual(want.texture_disable_allowed, got.texture_disable_allowed);
}

test "Stream: flat triangle and flat quad round-trip" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    c.gp0(0x20FF00FF); // flat triangle, magenta
    c.gp0(xy(0x10, 0x10));
    c.gp0(xy(0x40, 0x10));
    c.gp0(xy(0x28, 0x40));

    c.gp0(0x2800FF00); // flat quad, green
    c.gp0(xy(0x60, 0x60));
    c.gp0(xy(0xA0, 0x60));
    c.gp0(xy(0x60, 0xA0));
    c.gp0(xy(0xA0, 0xA0));

    try c.expectIdentical();
}

test "Stream: Gouraud triangle and quad round-trip with dithering on" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();
    c.gp0(0xE1000200); // E1 with dither ON — the shaded path reads bit 9

    c.gp0(0x300000FF);
    c.gp0(xy(0x10, 0x10));
    c.gp0(0x0000FF00);
    c.gp0(xy(0x50, 0x10));
    c.gp0(0x00FF0000);
    c.gp0(xy(0x30, 0x50));

    c.gp0(0x380000FF);
    c.gp0(xy(0x80, 0x80));
    c.gp0(0x0000FF00);
    c.gp0(xy(0xC0, 0x80));
    c.gp0(0x00FF0000);
    c.gp0(xy(0x80, 0xC0));
    c.gp0(0x00FFFFFF);
    c.gp0(xy(0xC0, 0xC0));

    try c.expectIdentical();
}

test "Stream: a textured triangle round-trips through the CLUT it samples" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    // The CLUT and the texture page are uploaded THROUGH the stream, and the
    // draw then samples VRAM the stream itself wrote. That dependency is the
    // property the whole design turns on: replay only reproduces the draw if
    // it reproduced the upload first.
    uploadPattern(&c, 0, 300, 16, 1, 0x1234); // 16-entry CLUT at (0,300)
    uploadPattern(&c, 0, 256, 64, 64, 0x0F0F); // 4bpp page at (0,256)

    // clut word  = (y << 6) | (x / 16)         -> (300 << 6) | 0 = 0x4B00
    // tpage word = (page_y_flag << 4) | (x/64) -> 0x10, depth 0 (4bpp)
    c.gp0(0x24808080); // textured triangle, modulated, opaque
    c.gp0(xy(0x20, 0x20));
    c.gp0(0x4B000000); // clut, u=0,  v=0
    c.gp0(xy(0x60, 0x20));
    c.gp0(0x00100040); // tpage, u=64, v=0
    c.gp0(xy(0x40, 0x60));
    c.gp0(0x00003F20); // u=32, v=63

    try c.expectIdentical();
}

test "Stream: a textured polygon's own tpage sets the blend mode, not the last E1" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    // 15bpp texels with bit15 set, so the polygon's semi-transparency runs.
    uploadPattern(&c, 0, 256, 64, 64, 0x8421);

    // E1 selects semi-transparency mode 0 (B/2 + F/2), 15bpp, page (0,256)...
    c.gp0(0xE1000000 | 0x10 | (2 << 7) | (0 << 5));

    // ...and a solid background to blend against.
    c.gp0(0x60FFFFFF);
    c.gp0(xy(0x20, 0x20));
    c.gp0(0x00400040);

    // ...but the polygon carries mode 2 (B - F) in bits 5-6 of its OWN tpage
    // word, which latchPolygonTexpage writes straight into draw_mode, and
    // which putPixel then reads. Dropping the latch record leaves the replay
    // blending with mode 0 and every covered pixel differs.
    const tpage: u32 = 0x10 | (2 << 7) | (2 << 5);
    c.gp0(0x27000000); // textured triangle, semi-transparent, raw texture
    c.gp0(xy(0x20, 0x20));
    c.gp0(0x00000000);
    c.gp0(xy(0x50, 0x20));
    c.gp0(tpage << 16);
    c.gp0(xy(0x30, 0x50));
    c.gp0(0x00003F20);

    try c.expectIdentical();
    try expectEnvEqual(&c.gpu.draw_env, &c.env);
}

test "Stream: E1-E6 writes between draws reach the replayed environment" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    // E3/E4: a tighter drawing area clips the second of two identical rects.
    c.gp0(0x60FF0000);
    c.gp0(xy(0x40, 0x40));
    c.gp0(0x00200020);
    c.gp0(0xE3000000 | 0x48 | (0x48 << 10));
    c.gp0(0xE4000000 | 0x50 | (0x50 << 10));
    c.gp0(0x6000FF00);
    c.gp0(xy(0x40, 0x40));
    c.gp0(0x00200020);

    // E5: the same rect again, displaced by the drawing offset.
    c.gp0(0xE3000000);
    c.gp0(0xE407FFFF);
    c.gp0(0xE5000000 | 0x80 | (0x60 << 11));
    c.gp0(0x600000FF);
    c.gp0(xy(0x10, 0x10));
    c.gp0(0x00180018);

    // E6: set-mask on, so the rect comes back with bit15 set.
    c.gp0(0xE5000000);
    c.gp0(0xE6000001);
    c.gp0(0x60FFFFFF);
    c.gp0(xy(0x120, 0x30));
    c.gp0(0x00100010);

    // E2: a texture window folds the sampled u/v of a textured rectangle.
    c.gp0(0xE6000000);
    uploadPattern(&c, 0, 0x100, 64, 64, 0x2468);
    c.gp0(0xE1000000 | 0x10 | (2 << 7)); // page (0,256), 15bpp
    c.gp0(0xE2000000 | 0x1F | (0x1F << 5));
    c.gp0(0x64808080);
    c.gp0(xy(0x160, 0x30));
    c.gp0(0x00000000);
    c.gp0(0x00200020);

    try c.expectIdentical();
    try expectEnvEqual(&c.gpu.draw_env, &c.env);
}

test "Stream: GP1(09) gates the E1 texture-disable bit" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    // Bit 11 is masked off while GP1(09) has not enabled it...
    c.gp0(0xE1000000 | (1 << 11));
    c.drain();
    try std.testing.expectEqual(@as(u32, 0), c.gpu.draw_env.draw_mode & (1 << 11));

    // ...and survives afterwards. Drop the GP1(09) record and the replayed
    // env masks the second write off too, so the two envs disagree.
    c.gp1(0x09000001);
    c.gp0(0xE1000000 | (1 << 11));
    c.drain();
    try std.testing.expectEqual(@as(u32, 1 << 11), c.gpu.draw_env.draw_mode & (1 << 11));

    try c.expectIdentical();
    try expectEnvEqual(&c.gpu.draw_env, &c.env);
}

test "Stream: GP1(00) resets the drawing environment mid-stream" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();
    c.gp0(0xE5000000 | 0x40 | (0x40 << 11)); // offset (64, 64)

    c.gp0(0x60FF00FF);
    c.gp0(xy(0x10, 0x10));
    c.gp0(0x00100010);

    // Without this the E3/E4/E5 preamble is still sitting in the GP0 FIFO when
    // the reset executes, and lands AFTER it — the drawing area is then the
    // full one, the rectangle below paints, and the test is green for the
    // wrong reason. See StreamCase.drain.
    c.drain();

    c.gp1(0x00000000); // GPU reset: draw_env = .{}

    // The same rectangle again. After the reset the drawing area is the
    // DEFAULT (top-left 0,0 and bottom-right 0,0), so it paints nothing at
    // all; without the reset record the replay paints 16x16 at (80,80).
    c.gp0(0x6000FF00);
    c.gp0(xy(0x10, 0x10));
    c.gp0(0x00100010);

    try c.expectIdentical();
    try expectEnvEqual(&c.gpu.draw_env, &c.env);
}

test "Stream: fill rectangle ignores E6 while copy and upload honour it" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    // Pre-mark bit15 at each masked write's DESTINATION, not at the fill's.
    // check-mask tests the pixel already in VRAM where the write is going, so
    // marking the source proves nothing — and marking the fill's target proves
    // less than nothing, because the fill overwrites the marks (bit15 clear)
    // before either masked path runs, leaving `check` never once exercised.
    uploadPattern(&c, 0x40, 0x10, 16, 16, 0x8000); // A0's destination
    uploadPattern(&c, 0x10, 0x40, 16, 16, 0x8000); // the copy's destination
    uploadPattern(&c, 0x10, 0x10, 16, 16, 0x8000); // and the fill's, for contrast

    c.gp0(0xE6000003); // set-mask AND check-mask

    // GP0(02) deliberately ignores both: this repaints the marked block at
    // (0x10,0x10) outright, bit15 included, where a masked write would skip it.
    c.gp0(0x02FF00FF);
    c.gp0(xy(0x10, 0x10));
    c.gp0(0x00200020);

    // A0 honours both: the 16x16 marked block at (0x40,0x10) is skipped
    // pixel-for-pixel, and only the surrounding rows of the 16x32 upload land.
    uploadPattern(&c, 0x40, 0x10, 16, 32, 0x00AA);

    // GP0(80) honours both: the marked block at the destination is skipped,
    // and what does get written picks up bit15 from set-mask.
    c.gp0(0x80000000);
    c.gp0(xy(0x10, 0x10));
    c.gp0(xy(0x10, 0x40));
    c.gp0(xy(0x20, 0x20));

    try c.expectIdentical();
}

test "Stream: an overlapping VRAM-to-VRAM copy round-trips in both directions" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    uploadPattern(&c, 0x10, 0x10, 32, 32, 0x0101);

    // Forwards branch: destination above and left of the source.
    c.gp0(0x80000000);
    c.gp0(xy(0x10, 0x10));
    c.gp0(xy(0x08, 0x08));
    c.gp0(xy(32, 32));

    // Backwards branch: destination below and right, overlapping.
    c.gp0(0x80000000);
    c.gp0(xy(0x10, 0x10));
    c.gp0(xy(0x18, 0x18));
    c.gp0(xy(32, 32));

    try c.expectIdentical();
}

test "Stream: a long upload coalesces into one payload run" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    uploadPattern(&c, 0, 0x100, 256, 64, 0x3C3C); // 8,192 payload words
    c.drain();

    // One setup record and ONE data record, not 8,192 of them — a wrong `y`
    // on the run replays the wrong texel count and the quad below diverges.
    const rec = &c.gpu.sink.rec;
    const run = rec.records[rec.count - 1];
    try std.testing.expectEqual(command.Kind.vram_write_data, run.kind);
    try std.testing.expectEqual(@as(i32, 8192), run.y);
    try std.testing.expectEqual(command.Kind.vram_write_setup, rec.records[rec.count - 2].kind);

    c.gp0(0xE1000000 | 0x10 | (2 << 7)); // page (0,256), 15bpp

    c.gp0(0x2D808080); // textured quad, raw
    c.gp0(xy(0x20, 0x20));
    c.gp0(0x00000000); // u=0,  v=0   (clut unused at 15bpp)
    c.gp0(xy(0x60, 0x20));
    c.gp0((0x10 | (2 << 7)) << 16 | 0x0040); // tpage word; u=64, v=0
    c.gp0(xy(0x20, 0x60));
    c.gp0(0x00003F00); // u=0,  v=63
    c.gp0(xy(0x60, 0x60));
    c.gp0(0x00003F40); // u=64, v=63

    try c.expectIdentical();
}

test "Stream: GP1(01) aborts a CPU-to-VRAM payload mid-flight" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    c.gp0(0xA0000000);
    c.gp0(xy(0x10, 0x10));
    c.gp0(0x00100010); // 16x16 -> 128 words expected
    var i: u32 = 0;
    while (i < 40) : (i += 1) c.gp0(0xDEAD0000 | i); // only 40 arrive
    c.drain(); // all 40 have really executed before the abort — StreamCase.drain

    c.gp1(0x01000000); // abort

    // The next GP0 word must be decoded as a COMMAND, not swallowed as
    // payload — on the LIVE side. The replay cannot get this wrong, because it
    // consumes records rather than GP0 words: by the time a word reaches the
    // stream it has already been decoded, so these three arrive as one
    // draw_rectangle record either way.
    c.gp0(0x60FF0000);
    c.gp0(xy(0x50, 0x50));
    c.gp0(0x00080008);

    try c.expectIdentical();

    // Which is why the pixels alone do NOT pin the abort record, and asserting
    // only on them leaves this test green with `vram_write_abort` dropped
    // entirely (verified). The record's whole effect is the shadow's transfer
    // state: 88 of the 128 words are still outstanding here, and nothing that
    // follows an abort can expose that through a pixel — the live side stops
    // emitting payload words the moment it aborts, and the next transfer's
    // `vram_write_setup` overwrites the cursor before any of them resume.
    // Phase B inherits the same shadow, so pin the state directly.
    try std.testing.expect(!c.shadow.write_active);
}

test "Stream: GP1(00) aborts a payload and resets the environment together" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    c.gp0(0xA0000000);
    c.gp0(xy(0x10, 0x10));
    c.gp0(0x00100010);
    var i: u32 = 0;
    while (i < 40) : (i += 1) c.gp0(0xBEEF0000 | i);
    c.drain();

    c.gp1(0x00000000);

    // Two ordered effects from one GP1 word: the transfer aborts AND the
    // drawing area goes back to its default, which is a single pixel.
    c.gp0(0x6000FF00);
    c.gp0(xy(0x50, 0x50));
    c.gp0(0x00080008);

    try c.expectIdentical();
    try expectEnvEqual(&c.gpu.draw_env, &c.env);
    try std.testing.expect(!c.shadow.write_active); // see the GP1(01) test above
}

test "Stream: a VRAM-to-CPU read setup replays the window, not the cursor" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    uploadPattern(&c, 0x20, 0x20, 16, 16, 0x5A5A);

    c.gp0(0xC0000000);
    c.gp0(xy(0x20, 0x20));
    c.gp0(0x00100010);

    // readData() is immediate; the C0 that arms it is not. Undrained, the
    // transfer has not been set up yet and all 128 reads return gpu_read_data
    // instead of VRAM, so the drain below is what makes them real reads.
    c.drain();

    var i: usize = 0;
    while (i < 128) : (i += 1) _ = c.gpu.readData();

    c.gp0(0x60FF00FF);
    c.gp0(xy(0x50, 0x50));
    c.gp0(0x00100010);

    try c.expectIdentical();

    // The setup IS replayed, so the shadow's read WINDOW matches. The drains
    // are not recorded, because reading VRAM mutates no pixel.
    //
    // That leaves the shadow's read CURSOR permanently unadvanced —
    // `read_remaining` never decrements and `read_active` never clears — which
    // is fine for Phase A (expectVramEqual compares `.data` only) but is a real
    // open question for Phase B: serving GPUREAD from the shadow needs the
    // drains recorded too, or the cursor driven from the live side. Do not read
    // this test as evidence that Phase B's GPUREAD path already works.
    try std.testing.expect(c.shadow.read_active);
    try std.testing.expectEqual(@as(usize, 0x20), c.shadow.read_x);
    try std.testing.expectEqual(@as(usize, 16), c.shadow.read_w);
}

test "Stream: mono and shaded lines round-trip, including a zero-length one" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();
    c.gp0(0xE1000200); // dither on — the shaded-line gradient reads bit 9

    c.gp0(0x40FFFFFF);
    c.gp0(xy(0x10, 0x10));
    c.gp0(xy(0x60, 0x40));

    c.gp0(0x500000FF);
    c.gp0(xy(0x10, 0x50));
    c.gp0(0x00FF0000);
    c.gp0(xy(0x60, 0x50));

    // Zero length: one pixel, and the `steps == 0` guard in drawShadedLine.
    c.gp0(0x500000FF);
    c.gp0(xy(0x70, 0x70));
    c.gp0(0x00FFFFFF);
    c.gp0(xy(0x70, 0x70));

    try c.expectIdentical();
}

test "Stream: polylines record one line per segment" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    c.gp0(0x480000FF); // mono polyline, 4 vertices -> 3 segments
    c.gp0(xy(0x10, 0x10));
    c.gp0(xy(0x40, 0x10));
    c.gp0(xy(0x40, 0x40));
    c.gp0(xy(0x10, 0x40));
    c.gp0(0x55555555);

    c.gp0(0x5800FF00); // shaded polyline, 3 vertices -> 2 segments
    c.gp0(xy(0x60, 0x10));
    c.gp0(0x000000FF);
    c.gp0(xy(0x90, 0x10));
    c.gp0(0x00FF0000);
    c.gp0(xy(0x90, 0x40));
    c.gp0(0x55555555);

    c.drain();

    // A polyline path that silently records nothing still passes a VRAM check
    // wherever the shadow happens to be black, so count the records too.
    var mono: usize = 0;
    var shaded: usize = 0;
    const rec = &c.gpu.sink.rec;
    for (rec.records[0..rec.count]) |cmd| {
        switch (cmd.kind) {
            .draw_line => mono += 1,
            .draw_shaded_line => shaded += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 3), mono);
    try std.testing.expectEqual(@as(usize, 2), shaded);

    try c.expectIdentical();
}

test "Stream: all three rectangle size classes, plain and textured" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    c.gp0(0x60FF0000); // variable size
    c.gp0(xy(0x10, 0x10));
    c.gp0(0x000C0014);

    c.gp0(0x7000FF00); // 8x8
    c.gp0(xy(0x40, 0x10));

    c.gp0(0x780000FF); // 16x16
    c.gp0(xy(0x60, 0x10));

    uploadPattern(&c, 0, 0x100, 64, 64, 0x1357);

    // A textured RECTANGLE does not latch — gp0.zig:342 reads the CURRENT
    // texpage instead — so this E1 write is what selects the page it samples,
    // and dropping the set_draw_env record leaves the replay sampling page 0.
    c.gp0(0xE1000000 | 0x10 | (2 << 7));

    c.gp0(0x64808080); // variable size, modulated
    c.gp0(xy(0x10, 0x40));
    c.gp0(0x00000000);
    c.gp0(0x00200020);

    c.gp0(0x74808080); // 8x8
    c.gp0(xy(0x40, 0x40));
    c.gp0(0x00001010);

    c.gp0(0x7C808080); // 16x16
    c.gp0(xy(0x60, 0x40));
    c.gp0(0x00002020);

    try c.expectIdentical();
}

test "Stream: an oversized primitive is dropped identically on both sides" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    c.gp0(0x60FFFFFF); // 1024 wide -> refused, not clipped
    c.gp0(xy(0, 0));
    c.gp0(1024 | (8 << 16));

    c.gp0(0x40FFFFFF); // 600 tall -> refused
    c.gp0(xy(0x10, 0));
    c.gp0(xy(0x10, 600));

    c.drain();

    // Both are RECORDED — the sink runs before the renderer's refusal — and
    // dropped again by the same renderer on replay, so both sides stay black.
    //
    // Count the two KINDS, not the total: fullArea() alone leaves three
    // set_draw_env records, so `count >= 2` would pass with neither oversized
    // primitive recorded at all — which is precisely the failure this test
    // exists to catch.
    var rects: usize = 0;
    var lines: usize = 0;
    const rec = &c.gpu.sink.rec;
    for (rec.records[0..rec.count]) |cmd| {
        switch (cmd.kind) {
            .draw_rectangle => rects += 1,
            .draw_line => lines += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), rects);
    try std.testing.expectEqual(@as(usize, 1), lines);

    for (c.gpu.vram.data) |px| try std.testing.expectEqual(@as(u16, 0), px);

    try c.expectIdentical();
}

test "Stream: exceeding the record capacity marks the frame incomplete" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    // Zero-area triangles: recorded in full, refused by the rasterizer before
    // it touches a pixel, so this loop costs almost nothing.
    var i: usize = 0;
    while (i < recorder.max_records + 16) : (i += 1) {
        c.gp0(0x20FFFFFF);
        c.gp0(xy(0, 0));
        c.gp0(xy(0, 0));
        c.gp0(xy(0, 0));
    }
    c.drain();

    try std.testing.expect(c.gpu.sink.rec.overflow);
    const s = c.gpu.sink.rec.takeFrame();
    try std.testing.expect(!s.complete);
    // The records it DID keep are still exposed, which is exactly why the
    // flag has to be checked: a caller that ignored it would apply a prefix.
    // `command.replay` asserts on `complete` rather than trusting anyone.
    try std.testing.expectEqual(recorder.max_records, s.records.len);

    // takeFrame resets, so the next frame starts clean.
    c.gp0(0x60FF0000);
    c.gp0(xy(0x10, 0x10));
    c.gp0(0x00080008);
    c.drain();
    try std.testing.expect(c.gpu.sink.rec.takeFrame().complete);
}

test "Stream: exceeding the payload capacity marks the frame incomplete" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    // A full-VRAM upload is 262,144 words; three of them overrun the
    // 524,288-word payload buffer.
    var n: usize = 0;
    while (n < 3) : (n += 1) {
        c.gp0(0xA0000000);
        c.gp0(xy(0, 0));
        c.gp0(0x00000000); // w = h = 0 -> the whole 1024x512 axis extent
        var i: usize = 0;
        while (i < 262_144) : (i += 1) {
            c.gp0(0xA5A50000 | (@as(u32, @truncate(i)) & 0xFFFF));
        }
    }
    c.drain();

    try std.testing.expect(!c.gpu.sink.rec.takeFrame().complete);
}
