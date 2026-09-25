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
const Value = ps1_core.pgxp.Value;
const subPixelDepth = @import("pgxp_value.zig").subPixelDepth;

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
        _ = self.gpu.writeGp0(word, Value.none);
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

test "a textured triangle's rw survives the record round trip" {
    var cmd: ps1_core.gpu.command.Command = .{ .kind = .draw_textured_triangle };
    cmd.v[0].rw = 65536;
    cmd.v[1].rw = 16384;
    cmd.v[2].rw = 1;
    const bytes = std.mem.asBytes(&cmd);
    var back: ps1_core.gpu.command.Command = undefined;
    @memcpy(std.mem.asBytes(&back), bytes);
    try std.testing.expectEqual(@as(i32, 65536), back.v[0].rw);
    try std.testing.expectEqual(@as(i32, 16384), back.v[1].rw);
    try std.testing.expectEqual(@as(i32, 1), back.v[2].rw);
    try std.testing.expectEqual(@as(usize, 120), @sizeOf(ps1_core.gpu.command.Command));
}

/// Records of kind `.draw_textured_triangle` only, in emission order.
///
/// Fix-round addition: the round-trip test above proves a `Command`'s `rw`
/// field survives serialization, but nothing in this file drove GP0 far
/// enough to observe what `gp0` and `sink.zig` actually WRITE into a live
/// record. Every textured handler emits exactly one `latch_texpage` record
/// ahead of its triangle(s) (`sink.latchTexpage`), so filtering by kind is
/// what isolates the triangle(s) from that neighbour.
fn texturedTriangles(rec: *const recorder.Recorder, out: []command.Command) []command.Command {
    var n: usize = 0;
    for (rec.records[0..rec.count]) |cmd| {
        if (cmd.kind == .draw_textured_triangle) {
            out[n] = cmd;
            n += 1;
        }
    }
    return out[0..n];
}

test "Stream: a raw textured triangle's record carries the exact rw triple" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();
    c.gpu.gp0.pgxp_enabled = true;
    c.gpu.gp0.pgxp_texture_correction = true;

    // GP0 0x25: raw textured triangle (cmd, v0, t0, v1, t1, v2, t2). Depths
    // 4.0 / 1.0 / 16.0 give a non-trivial, hand-computed triple: the minimum
    // is v1's 1.0, and reciprocalDepths is round(65536 * min / w), clamped to
    // [1, 65536] -> [16384, 65536, 4096]. A swapped or dropped `v[i].rw =
    // rw[i]` line in sink.zig changes one of these three numbers.
    const w0 = xy(0x10, 0x10);
    const w1 = xy(0x40, 0x10);
    const w2 = xy(0x28, 0x40);
    _ = c.gpu.writeGp0(0x25000000, Value.none);
    _ = c.gpu.writeGp0(w0, subPixelDepth(w0, 0.25, 0.25, 4.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(w1, subPixelDepth(w1, 0.5, 0.5, 1.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(w2, subPixelDepth(w2, 0.5, 0.5, 16.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    c.drain();

    var buf: [2]command.Command = undefined;
    const tris = texturedTriangles(&c.gpu.sink.rec, &buf);
    try std.testing.expectEqual(@as(usize, 1), tris.len);
    try std.testing.expectEqual(@as(i32, 16384), tris[0].v[0].rw);
    try std.testing.expectEqual(@as(i32, 65536), tris[0].v[1].rw);
    try std.testing.expectEqual(@as(i32, 4096), tris[0].v[2].rw);
}

test "Stream: a raw textured quad's two triangles carry the vs[0..3] / vs[1..4] slices" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();
    c.gpu.gp0.pgxp_enabled = true;
    c.gpu.gp0.pgxp_texture_correction = true;

    // GP0 0x2D: raw textured quad (cmd, v0,t0, v1,t1, v2,t2, v3,t3). Four
    // DISTINCT depths, not a shared ratio, so the two triangles' triples
    // cannot be confused with each other by a wrong slice:
    //   first triangle  = vs[0..3] -> depths 1.0, 2.0, 3.0
    //                                  -> rw = [65536, 32768, 21845]
    //   second triangle = vs[1..4] -> depths 2.0, 3.0, 8.0
    //                                  -> rw = [65536, 43691, 16384]
    // A call site that used vs[0..3] twice (e.g. the second draw call
    // mistakenly sliced vs[0..3] instead of vs[1..4]) would reproduce the
    // FIRST triple on the second triangle instead of the second one.
    const w0 = xy(0x10, 0x10);
    const w1 = xy(0x60, 0x10);
    const w2 = xy(0x60, 0x60);
    const w3 = xy(0x10, 0x60);
    _ = c.gpu.writeGp0(0x2D000000, Value.none);
    _ = c.gpu.writeGp0(w0, subPixelDepth(w0, 0.25, 0.25, 1.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(w1, subPixelDepth(w1, 0.5, 0.5, 2.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(w2, subPixelDepth(w2, 0.5, 0.5, 3.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(w3, subPixelDepth(w3, 0.5, 0.5, 8.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    c.drain();

    var buf: [2]command.Command = undefined;
    const tris = texturedTriangles(&c.gpu.sink.rec, &buf);
    try std.testing.expectEqual(@as(usize, 2), tris.len);
    try std.testing.expectEqual(@as(i32, 65536), tris[0].v[0].rw);
    try std.testing.expectEqual(@as(i32, 32768), tris[0].v[1].rw);
    try std.testing.expectEqual(@as(i32, 21845), tris[0].v[2].rw);
    try std.testing.expectEqual(@as(i32, 65536), tris[1].v[0].rw);
    try std.testing.expectEqual(@as(i32, 43691), tris[1].v[1].rw);
    try std.testing.expectEqual(@as(i32, 16384), tris[1].v[2].rw);
}

test "Stream: a raw shaded-textured triangle's record carries the exact rw triple" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();
    c.gpu.gp0.pgxp_enabled = true;
    c.gpu.gp0.pgxp_texture_correction = true;

    // GP0 0x35: raw shaded-textured triangle (c0, v0,t0, c1, v1,t1, c2, v2,t2).
    // Same depths and expected triple as the flat-textured triangle above —
    // this handler goes through its own `texturedDepths`/`depthsFor` call
    // site (gp0.zig's `drawShadedTexturedTriangle`), so it needs its own proof.
    const w0 = xy(0x10, 0x10);
    const w1 = xy(0x40, 0x10);
    const w2 = xy(0x28, 0x40);
    _ = c.gpu.writeGp0(0x35000000, Value.none); // c0
    _ = c.gpu.writeGp0(w0, subPixelDepth(w0, 0.25, 0.25, 4.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none); // t0
    _ = c.gpu.writeGp0(0x00000000, Value.none); // c1
    _ = c.gpu.writeGp0(w1, subPixelDepth(w1, 0.5, 0.5, 1.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none); // t1
    _ = c.gpu.writeGp0(0x00000000, Value.none); // c2
    _ = c.gpu.writeGp0(w2, subPixelDepth(w2, 0.5, 0.5, 16.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none); // t2
    c.drain();

    var buf: [2]command.Command = undefined;
    const tris = texturedTriangles(&c.gpu.sink.rec, &buf);
    try std.testing.expectEqual(@as(usize, 1), tris.len);
    try std.testing.expectEqual(@as(i32, 16384), tris[0].v[0].rw);
    try std.testing.expectEqual(@as(i32, 65536), tris[0].v[1].rw);
    try std.testing.expectEqual(@as(i32, 4096), tris[0].v[2].rw);
}

test "Stream: a raw shaded-textured quad's two triangles carry the vs[0..3] / vs[1..4] slices" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();
    c.gpu.gp0.pgxp_enabled = true;
    c.gpu.gp0.pgxp_texture_correction = true;

    // GP0 0x3D: raw shaded-textured quad
    // (c0, v0,t0, c1, v1,t1, c2, v2,t2, c3, v3,t3). Same four depths and
    // expected triples as the flat-textured quad above — this handler's two
    // `drawTexturedTriangle` calls are its own call sites in gp0.zig and need
    // their own proof that vs[1..4] wasn't collapsed onto vs[0..3].
    const w0 = xy(0x10, 0x10);
    const w1 = xy(0x60, 0x10);
    const w2 = xy(0x60, 0x60);
    const w3 = xy(0x10, 0x60);
    _ = c.gpu.writeGp0(0x3D000000, Value.none); // c0
    _ = c.gpu.writeGp0(w0, subPixelDepth(w0, 0.25, 0.25, 1.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none); // t0
    _ = c.gpu.writeGp0(0x00000000, Value.none); // c1
    _ = c.gpu.writeGp0(w1, subPixelDepth(w1, 0.5, 0.5, 2.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none); // t1
    _ = c.gpu.writeGp0(0x00000000, Value.none); // c2
    _ = c.gpu.writeGp0(w2, subPixelDepth(w2, 0.5, 0.5, 3.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none); // t2
    _ = c.gpu.writeGp0(0x00000000, Value.none); // c3
    _ = c.gpu.writeGp0(w3, subPixelDepth(w3, 0.5, 0.5, 8.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none); // t3
    c.drain();

    var buf: [2]command.Command = undefined;
    const tris = texturedTriangles(&c.gpu.sink.rec, &buf);
    try std.testing.expectEqual(@as(usize, 2), tris.len);
    try std.testing.expectEqual(@as(i32, 65536), tris[0].v[0].rw);
    try std.testing.expectEqual(@as(i32, 32768), tris[0].v[1].rw);
    try std.testing.expectEqual(@as(i32, 21845), tris[0].v[2].rw);
    try std.testing.expectEqual(@as(i32, 65536), tris[1].v[0].rw);
    try std.testing.expectEqual(@as(i32, 43691), tris[1].v[1].rw);
    try std.testing.expectEqual(@as(i32, 16384), tris[1].v[2].rw);
}

test "Stream: both corrections off means every emitted rw is zero, across all four handlers" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();
    c.gpu.gp0.pgxp_enabled = true;
    c.gpu.gp0.pgxp_texture_correction = false;
    c.gpu.gp0.pgxp_color_correction = false;

    // The same four command streams as the four positive tests above (real,
    // fully-resolved depths present on every vertex), just with both
    // settings off. Two of these six triangles are Gouraud-textured (0x35,
    // 0x3D) — with colour correction on, `depthsFor`'s "texture OR colour"
    // gate would give those two a non-zero rw even with texture correction
    // off, so this test needs both settings off, not just texture's, to
    // prove the mirror and the gate in `depthsFor` are not bypassed.
    const w0 = xy(0x10, 0x10);
    const w1 = xy(0x40, 0x10);
    const w2 = xy(0x28, 0x40);
    _ = c.gpu.writeGp0(0x25000000, Value.none);
    _ = c.gpu.writeGp0(w0, subPixelDepth(w0, 0.25, 0.25, 4.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(w1, subPixelDepth(w1, 0.5, 0.5, 1.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(w2, subPixelDepth(w2, 0.5, 0.5, 16.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);

    const q0 = xy(0x10, 0x10);
    const q1 = xy(0x60, 0x10);
    const q2 = xy(0x60, 0x60);
    const q3 = xy(0x10, 0x60);
    _ = c.gpu.writeGp0(0x2D000000, Value.none);
    _ = c.gpu.writeGp0(q0, subPixelDepth(q0, 0.25, 0.25, 1.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(q1, subPixelDepth(q1, 0.5, 0.5, 2.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(q2, subPixelDepth(q2, 0.5, 0.5, 3.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(q3, subPixelDepth(q3, 0.5, 0.5, 8.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);

    _ = c.gpu.writeGp0(0x35000000, Value.none);
    _ = c.gpu.writeGp0(w0, subPixelDepth(w0, 0.25, 0.25, 4.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(w1, subPixelDepth(w1, 0.5, 0.5, 1.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(w2, subPixelDepth(w2, 0.5, 0.5, 16.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);

    _ = c.gpu.writeGp0(0x3D000000, Value.none);
    _ = c.gpu.writeGp0(q0, subPixelDepth(q0, 0.25, 0.25, 1.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(q1, subPixelDepth(q1, 0.5, 0.5, 2.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(q2, subPixelDepth(q2, 0.5, 0.5, 3.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(q3, subPixelDepth(q3, 0.5, 0.5, 8.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    c.drain();

    var buf: [6]command.Command = undefined;
    const tris = texturedTriangles(&c.gpu.sink.rec, &buf);
    try std.testing.expectEqual(@as(usize, 6), tris.len);
    for (tris) |t| {
        try std.testing.expectEqual(@as(i32, 0), t.v[0].rw);
        try std.testing.expectEqual(@as(i32, 0), t.v[1].rw);
        try std.testing.expectEqual(@as(i32, 0), t.v[2].rw);
    }
}

// --- Phase 4 Task 1: the flags byte.

/// The last record of a given kind captured so far. The recorder is a
/// fixed-capacity array, so this reads the stream rather than a return
/// value: what is under test is what a Metal replay would receive.
fn lastRecord(gpu: *Gpu, kind: command.Kind) command.Command {
    const records = gpu.sink.rec.records[0..gpu.sink.rec.count];
    var i = records.len;
    while (i > 0) {
        i -= 1;
        if (records[i].kind == kind) return records[i];
    }
    unreachable;
}

/// Every vertex of a triangle record sits exactly on its wire integer.
fn expectIntegerVertices(rec: command.Command) !void {
    for (rec.v[0..3]) |v| {
        try std.testing.expectEqual(@as(i32, v.x) << 16, v.px);
        try std.testing.expectEqual(@as(i32, v.y) << 16, v.py);
    }
}

// The bit is a property of the RECORD, not of the renderer: a Metal replay
// has only the record, so a bit re-derived on either side is exactly the
// second transcription the sink exists to prevent.
test "Phase4: a corrected textured triangle records the texture bit" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();
    c.gpu.gp0.pgxp_enabled = true;
    c.gpu.gp0.pgxp_texture_correction = true;

    const w0 = xy(10, 10);
    const w1 = xy(70, 12);
    const w2 = xy(14, 68);
    _ = c.gpu.writeGp0(0x25000000, Value.none);
    _ = c.gpu.writeGp0(w0, subPixelDepth(w0, 0.25, 0.25, 4.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(w1, subPixelDepth(w1, 0.5, 0.5, 1.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(w2, subPixelDepth(w2, 0.5, 0.5, 16.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    c.drain();

    const rec = lastRecord(c.gpu, .draw_textured_triangle);
    try std.testing.expect((rec.flags & command.flag_texture_perspective) != 0);
    try std.testing.expectEqual(@as(u8, 0), rec.flags & command.flag_color_perspective);
}

test "Phase4: an uncorrected textured triangle records neither bit" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();
    c.gpu.gp0.pgxp_enabled = true;
    c.gpu.gp0.pgxp_texture_correction = false;

    const w0 = xy(10, 10);
    const w1 = xy(70, 12);
    const w2 = xy(14, 68);
    _ = c.gpu.writeGp0(0x25000000, Value.none);
    _ = c.gpu.writeGp0(w0, subPixelDepth(w0, 0.25, 0.25, 4.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(w1, subPixelDepth(w1, 0.5, 0.5, 1.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(w2, subPixelDepth(w2, 0.5, 0.5, 16.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    c.drain();

    try std.testing.expectEqual(@as(u8, 0), lastRecord(c.gpu, .draw_textured_triangle).flags);
}

// --- Phase 4 Task 3: rw on Gouraud triangles, and the colour bit.

/// GP0 0x34, one Gouraud-textured triangle whose three vertices resolve
/// widely different depths (4.0, 1.0, 16.0), so no `rw` rounds to the same
/// value. The fixture the four-combination test drives through every
/// setting combination.
fn drawGouraudTexturedTriangle(c: *StreamCase) void {
    const w0 = xy(0x10, 0x10);
    const w1 = xy(0x40, 0x10);
    const w2 = xy(0x28, 0x40);
    _ = c.gpu.writeGp0(0x34000000, Value.none); // c0
    _ = c.gpu.writeGp0(w0, subPixelDepth(w0, 0.25, 0.25, 4.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none); // t0
    _ = c.gpu.writeGp0(0x00000000, Value.none); // c1
    _ = c.gpu.writeGp0(w1, subPixelDepth(w1, 0.5, 0.5, 1.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none); // t1
    _ = c.gpu.writeGp0(0x00000000, Value.none); // c2
    _ = c.gpu.writeGp0(w2, subPixelDepth(w2, 0.5, 0.5, 16.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none); // t2
    c.drain();
}

/// GP0 0x30, one UNTEXTURED Gouraud triangle whose three vertices all
/// resolve a depth. The colour setting is the only one that can use them —
/// there are no texcoords here to correct.
fn drawShadedTriangleWithDepth(c: *StreamCase) void {
    const w0 = xy(0x10, 0x10);
    const w1 = xy(0x40, 0x10);
    const w2 = xy(0x28, 0x40);
    _ = c.gpu.writeGp0(0x30000000, Value.none); // c0
    _ = c.gpu.writeGp0(w0, subPixelDepth(w0, 0.25, 0.25, 4.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none); // c1
    _ = c.gpu.writeGp0(w1, subPixelDepth(w1, 0.5, 0.5, 1.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none); // c2
    _ = c.gpu.writeGp0(w2, subPixelDepth(w2, 0.5, 0.5, 16.0));
    c.drain();
}

/// GP0 0x24, one FLAT-shaded textured triangle whose three vertices all
/// resolve a depth. `gp0` routes this site through `texturedDepths(vs,
/// false)`, so even with colour correction on the record must never carry
/// the colour bit — a flat-shaded primitive has only one modulation colour
/// to begin with.
fn drawFlatTexturedTriangle(c: *StreamCase) void {
    const w0 = xy(0x10, 0x10);
    const w1 = xy(0x40, 0x10);
    const w2 = xy(0x28, 0x40);
    _ = c.gpu.writeGp0(0x24000000, Value.none);
    _ = c.gpu.writeGp0(w0, subPixelDepth(w0, 0.25, 0.25, 4.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(w1, subPixelDepth(w1, 0.5, 0.5, 1.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(w2, subPixelDepth(w2, 0.5, 0.5, 16.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    c.drain();
}

/// GP0 0x30, an untextured Gouraud triangle whose first two vertices resolve
/// a depth and whose third does not — the MIXED case. `unify` snaps the
/// whole primitive back to the integer grid, clearing every vertex's depth
/// along with its position.
fn drawShadedTriangleWithDepth2Of3(c: *StreamCase) void {
    const w0 = xy(0x10, 0x10);
    const w1 = xy(0x40, 0x10);
    const w2 = xy(0x28, 0x40);
    _ = c.gpu.writeGp0(0x30000000, Value.none); // c0
    _ = c.gpu.writeGp0(w0, subPixelDepth(w0, 0.25, 0.25, 4.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none); // c1
    _ = c.gpu.writeGp0(w1, subPixelDepth(w1, 0.5, 0.5, 1.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none); // c2
    _ = c.gpu.writeGp0(w2, Value.none); // vertex 2 unresolved
    c.drain();
}

/// GP0 0x30, an untextured Gouraud triangle whose integer geometry is
/// thinner than `thinIntegerTriangle`'s floor. All three vertices resolve a
/// depth; `unify` keeps the integer grid there regardless, and the depths
/// reach the sink with it.
fn drawThinShadedTriangleWithDepth(c: *StreamCase) void {
    const w0 = xy(10, 10);
    const w1 = xy(12, 10);
    const w2 = xy(10, 11);
    _ = c.gpu.writeGp0(0x30000000, Value.none); // c0
    _ = c.gpu.writeGp0(w0, subPixelDepth(w0, 0.25, 0.25, 4.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none); // c1
    _ = c.gpu.writeGp0(w1, subPixelDepth(w1, 0.5, 0.5, 1.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none); // c2
    _ = c.gpu.writeGp0(w2, subPixelDepth(w2, 0.5, 0.5, 16.0));
    c.drain();
}

/// GP0 0x24, the thin geometry of `drawThinShadedTriangleWithDepth` as a
/// flat-shaded TEXTURED triangle — the shape that left Crash's fence rails
/// and wall quads affine beside corrected neighbours.
fn drawThinTexturedTriangleWithDepth(c: *StreamCase) void {
    const w0 = xy(10, 10);
    const w1 = xy(12, 10);
    const w2 = xy(10, 11);
    _ = c.gpu.writeGp0(0x24000000, Value.none);
    _ = c.gpu.writeGp0(w0, subPixelDepth(w0, 0.25, 0.25, 4.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(w1, subPixelDepth(w1, 0.5, 0.5, 1.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(w2, subPixelDepth(w2, 0.5, 0.5, 16.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    c.drain();
}

/// The same thin textured triangle with vertex 2 UNRESOLVED: thin and mixed
/// at once.
fn drawThinTexturedTriangleWithDepth2Of3(c: *StreamCase) void {
    const w0 = xy(10, 10);
    const w1 = xy(12, 10);
    const w2 = xy(10, 11);
    _ = c.gpu.writeGp0(0x24000000, Value.none);
    _ = c.gpu.writeGp0(w0, subPixelDepth(w0, 0.25, 0.25, 4.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(w1, subPixelDepth(w1, 0.5, 0.5, 1.0));
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    _ = c.gpu.writeGp0(w2, Value.none);
    _ = c.gpu.writeGp0(0x00000000, Value.none);
    c.drain();
}

// The defect the flags byte exists to prevent: with one bit, a triangle drawn
// with colour correction on and texture correction off would have its
// TEXCOORDS corrected by a setting the player turned off.
//
// One Gouraud-textured triangle (GP0 0x34), four setting combinations, and
// the pair of bits each must produce. Verified to FAIL against a single-bit
// implementation before landing — see Step 2.
test "Phase4: the two correction bits are independent" {
    const cases = [_]struct { tex: bool, col: bool, want: u8 }{
        .{ .tex = false, .col = false, .want = 0 },
        .{ .tex = true, .col = false, .want = command.flag_texture_perspective },
        .{ .tex = false, .col = true, .want = command.flag_color_perspective },
        .{ .tex = true, .col = true, .want = command.flag_texture_perspective | command.flag_color_perspective },
    };
    for (cases) |c| {
        var case = try StreamCase.init(std.testing.allocator);
        defer case.deinit();
        case.gpu.gp0.pgxp_enabled = true;
        case.gpu.gp0.pgxp_texture_correction = c.tex;
        case.gpu.gp0.pgxp_color_correction = c.col;
        drawGouraudTexturedTriangle(&case);
        try std.testing.expectEqual(c.want, lastRecord(case.gpu, .draw_textured_triangle).flags);
        // The depths themselves must be present whenever EITHER setting wants
        // them: gating them on texture correction alone is what would make the
        // colour bit unusable on its own.
        const rec = lastRecord(case.gpu, .draw_textured_triangle);
        const want_rw = c.tex or c.col;
        try std.testing.expectEqual(want_rw, rec.v[0].rw != 0);
    }
}

// An untextured Gouraud triangle carries depths only for the colour setting.
test "Phase4: an untextured Gouraud triangle records the colour bit alone" {
    var case = try StreamCase.init(std.testing.allocator);
    defer case.deinit();
    case.gpu.gp0.pgxp_enabled = true;
    case.gpu.gp0.pgxp_texture_correction = true;
    case.gpu.gp0.pgxp_color_correction = true;
    drawShadedTriangleWithDepth(&case);

    const rec = lastRecord(case.gpu, .draw_shaded_triangle);
    try std.testing.expectEqual(command.flag_color_perspective, rec.flags);
    try std.testing.expect(rec.v[0].rw != 0 and rec.v[1].rw != 0 and rec.v[2].rw != 0);
    try std.testing.expectEqual(@as(u64, 1), case.gpu.gp0.pgxp.shaded_triangles);
    try std.testing.expectEqual(@as(u64, 1), case.gpu.gp0.pgxp.color_perspective_primitives);
    // Untextured: it must not touch the textured population at all.
    try std.testing.expectEqual(@as(u64, 0), case.gpu.gp0.pgxp.textured_triangles);
}

// The structural half of the flat-shaded carve-out. The arithmetic half is
// pinned in gpu_test.zig; this one says gp0 never even offers the bit, so a
// future change to `interpW` cannot reach a flat-shaded primitive by accident.
test "Phase4: a flat-shaded textured triangle never carries the colour bit" {
    var case = try StreamCase.init(std.testing.allocator);
    defer case.deinit();
    case.gpu.gp0.pgxp_enabled = true;
    case.gpu.gp0.pgxp_texture_correction = true;
    case.gpu.gp0.pgxp_color_correction = true;
    drawFlatTexturedTriangle(&case);

    const rec = lastRecord(case.gpu, .draw_textured_triangle);
    try std.testing.expectEqual(command.flag_texture_perspective, rec.flags);
    try std.testing.expectEqual(@as(u64, 0), case.gpu.gp0.pgxp.shaded_triangles);
}

// `unify` snaps a partly-resolved primitive back to integers and clears `w`
// with the position. The textured equivalents are pinned by Phase 3; these
// are the SHADED ones, which had no depth to lose until this task.
test "Phase4: unify clears the depth on a mixed shaded primitive" {
    var case = try StreamCase.init(std.testing.allocator);
    defer case.deinit();
    case.gpu.gp0.pgxp_enabled = true;
    case.gpu.gp0.pgxp_color_correction = true;
    drawShadedTriangleWithDepth2Of3(&case); // vertex 2 unresolved

    const rec = lastRecord(case.gpu, .draw_shaded_triangle);
    try std.testing.expectEqual(@as(u8, 0), rec.flags);
    try std.testing.expectEqual(@as(i32, 0), rec.v[0].rw);
    try std.testing.expectEqual(@as(u64, 1), case.gpu.gp0.pgxp.mixed_primitives);
}

// The thin rule guards POSITION: a sub-pixel move can carry a thin triangle
// off every sample point it covers. Nothing about a vertex's own depth can
// delete a pixel, so a thin primitive keeps its integers AND its depths.
// Clearing them left Crash's thin wall and fence quads affine beside
// corrected neighbours, and a triangle crossing the 1.5 px line toggled its
// correction from frame to frame -- texture visibly popping.
test "a thin shaded primitive keeps its integers and its depths" {
    var case = try StreamCase.init(std.testing.allocator);
    defer case.deinit();
    case.gpu.gp0.pgxp_enabled = true;
    case.gpu.gp0.pgxp_color_correction = true;
    drawThinShadedTriangleWithDepth(&case);

    const rec = lastRecord(case.gpu, .draw_shaded_triangle);
    try std.testing.expectEqual(@as(u64, 1), case.gpu.gp0.pgxp.thin_primitives);
    try std.testing.expectEqual(command.flag_color_perspective, rec.flags);
    try std.testing.expect(rec.v[0].rw != 0 and rec.v[1].rw != 0 and rec.v[2].rw != 0);
    try expectIntegerVertices(rec);
}

test "a thin textured primitive keeps its integers and its depths" {
    var case = try StreamCase.init(std.testing.allocator);
    defer case.deinit();
    case.gpu.gp0.pgxp_enabled = true;
    case.gpu.gp0.pgxp_texture_correction = true;
    drawThinTexturedTriangleWithDepth(&case);

    const rec = lastRecord(case.gpu, .draw_textured_triangle);
    try std.testing.expectEqual(@as(u64, 1), case.gpu.gp0.pgxp.thin_primitives);
    try std.testing.expectEqual(command.flag_texture_perspective, rec.flags);
    try std.testing.expect(rec.v[0].rw != 0 and rec.v[1].rw != 0 and rec.v[2].rw != 0);
    try expectIntegerVertices(rec);
}

// Thin AND mixed: the mixed rule still wins. An unresolved vertex has no depth
// to keep, so the triangle cannot take the perspective path either way, and
// the resolved two must not publish depths the primitive was not drawn with.
test "a thin primitive that is also mixed keeps no depth" {
    var case = try StreamCase.init(std.testing.allocator);
    defer case.deinit();
    case.gpu.gp0.pgxp_enabled = true;
    case.gpu.gp0.pgxp_texture_correction = true;
    drawThinTexturedTriangleWithDepth2Of3(&case);

    const rec = lastRecord(case.gpu, .draw_textured_triangle);
    try std.testing.expectEqual(@as(u64, 1), case.gpu.gp0.pgxp.thin_primitives);
    try std.testing.expectEqual(@as(u8, 0), rec.flags);
    try std.testing.expectEqual(@as(i32, 0), rec.v[0].rw);
    try expectIntegerVertices(rec);
}

// --- Phase 5 Task 1: the record.

test "Phase5: the record carries iz and two depth bits, and clear_depth is appended" {
    try std.testing.expectEqual(@as(usize, 28), @sizeOf(command.Vertex));
    try std.testing.expectEqual(@as(usize, 120), @sizeOf(command.Command));
    // APPENDED: every existing kind keeps its number, so a version-3 reader's
    // table is a prefix of this one.
    try std.testing.expectEqual(@as(usize, 17), @intFromEnum(command.Kind.clear_depth));
    try std.testing.expectEqual(@as(u8, 1 << 2), command.flag_depth_test);
    try std.testing.expectEqual(@as(u8, 1 << 3), command.flag_depth_write);
}

// --- Phase 5 Task 4: a toggle resets the plane THROUGH THE STREAM.
//
// A silent @memset would clear the software plane and leave Metal's stale, so
// the next frame's depth tests would disagree between the two rasterizers.

test "Phase5: turning the depth buffer on records a whole-plane clear_depth" {
    var case = try StreamCase.init(std.testing.allocator);
    defer case.deinit();
    @memset(&case.gpu.vram.depth, 7);
    case.gpu.gp0.pgxp_depth_buffer = false;
    case.gpu.gp0.setDepthMirrors(&case.gpu.sink, &case.gpu.vram, &case.gpu.draw_env, true, false, false);
    const rec = lastRecord(case.gpu, .clear_depth);
    try std.testing.expectEqual(@as(i32, 1024), rec.w);
    try std.testing.expectEqual(@as(i32, 512), rec.h);
    try std.testing.expectEqual(@as(u32, 0), case.gpu.vram.depth[0]);
}

test "Phase5: re-applying the same setting records nothing" {
    var case = try StreamCase.init(std.testing.allocator);
    defer case.deinit();
    case.gpu.gp0.setDepthMirrors(&case.gpu.sink, &case.gpu.vram, &case.gpu.draw_env, true, false, false);
    const before = case.gpu.sink.rec.count;
    // The macOS runner re-applies every setting every frame.
    case.gpu.gp0.setDepthMirrors(&case.gpu.sink, &case.gpu.vram, &case.gpu.draw_env, true, false, false);
    try std.testing.expectEqual(before, case.gpu.sink.rec.count);
}

// --- Phase 5 Task 5: what gp0 records.

fn depthCase() !StreamCase {
    var case = try StreamCase.init(std.testing.allocator);
    case.fullArea();
    case.gpu.gp0.pgxp_enabled = true;
    case.gpu.gp0.setDepthMirrors(&case.gpu.sink, &case.gpu.vram, &case.gpu.draw_env, true, false, false);
    return case;
}

/// GP0 opcode `op` (a flat triangle, 0x20 opaque or 0x22 transparent) whose
/// three vertices resolve with the given depths.
fn flatTri(c: *StreamCase, op: u8, zs: [3]f32) void {
    const ws = [3]u32{ xy(0x10, 0x10), xy(0x40, 0x10), xy(0x28, 0x40) };
    _ = c.gpu.writeGp0(@as(u32, op) << 24, Value.none);
    for (ws, zs) |w, z| _ = c.gpu.writeGp0(w, subPixelDepth(w, 0.25, 0.25, z));
    c.drain();
}

test "Phase5: a 3D opaque triangle records both bits and three iz" {
    var case = try depthCase();
    defer case.deinit();
    flatTri(&case, 0x20, .{ 100, 200, 300 });
    const rec = lastRecord(case.gpu, .draw_triangle);
    try std.testing.expectEqual(command.flag_depth_test | command.flag_depth_write, rec.flags);
    try std.testing.expectEqual(ps1_core.gpu.depth.reciprocal(100), rec.v[0].iz);
    try std.testing.expect(rec.v[1].iz != 0 and rec.v[2].iz != 0);
    try std.testing.expectEqual(@as(u64, 1), case.gpu.gp0.pgxp.depth_tested);
}

test "Phase5: equal depths are 2D and record neither bit" {
    var case = try depthCase();
    defer case.deinit();
    flatTri(&case, 0x20, .{ 200, 200, 200 });
    const rec = lastRecord(case.gpu, .draw_triangle);
    try std.testing.expectEqual(@as(u8, 0), rec.flags);
    try std.testing.expectEqual(@as(i32, 0), rec.v[0].iz);
}

test "Phase5: transparent records nothing, then test-only under transparent_depth" {
    var case = try depthCase();
    defer case.deinit();
    flatTri(&case, 0x22, .{ 100, 200, 300 });
    try std.testing.expectEqual(@as(u8, 0), lastRecord(case.gpu, .draw_triangle).flags);
    case.gpu.gp0.setDepthMirrors(&case.gpu.sink, &case.gpu.vram, &case.gpu.draw_env, true, true, false);
    flatTri(&case, 0x22, .{ 100, 200, 300 });
    try std.testing.expectEqual(command.flag_depth_test, lastRecord(case.gpu, .draw_triangle).flags);
}

test "Phase5: both halves of a quad record the same bits" {
    var case = try depthCase();
    defer case.deinit();
    // GP0 0x28: vertices 0..2 at one depth, vertex 3 different. Judged per
    // HALF, the first half would be 2D; judged as the quad, both are 3D.
    const ws = [4]u32{ xy(0x10, 0x10), xy(0x40, 0x10), xy(0x10, 0x40), xy(0x40, 0x40) };
    const zs = [4]f32{ 100, 100, 100, 300 };
    _ = case.gpu.writeGp0(0x28000000, Value.none);
    for (ws, zs) |w, z| _ = case.gpu.writeGp0(w, subPixelDepth(w, 0.25, 0.25, z));
    case.drain();
    const records = case.gpu.sink.rec.records[0..case.gpu.sink.rec.count];
    var n: usize = 0;
    for (records) |r| if (r.kind == .draw_triangle) {
        try std.testing.expectEqual(command.flag_depth_test | command.flag_depth_write, r.flags);
        n += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "Phase5: a drawing-area CHANGE after a depth write records a whole-plane clear" {
    var case = try depthCase();
    defer case.deinit();
    flatTri(&case, 0x20, .{ 100, 200, 300 });
    const before = case.gpu.sink.rec.count;
    case.gp0(0xE3000000 | (10 << 10)); // top-left moves
    case.drain();
    const rec = lastRecord(case.gpu, .clear_depth);
    try std.testing.expectEqual(@as(i32, 1024), rec.w);
    try std.testing.expect(case.gpu.sink.rec.count > before);
    try std.testing.expectEqual(@as(u64, 1), case.gpu.gp0.pgxp.depth_clears);
}

test "Phase5: re-writing E3 with its CURRENT value records no clear" {
    var case = try depthCase();
    defer case.deinit();
    flatTri(&case, 0x20, .{ 100, 200, 300 });
    const clears = case.gpu.gp0.pgxp.depth_clears;
    case.gp0(0xE3000000 | (case.gpu.draw_env.area_top_left & 0xFFFFF));
    case.drain();
    try std.testing.expectEqual(clears, case.gpu.gp0.pgxp.depth_clears);
}

test "Phase5: a jump of 4096 AWAY clears the drawing area; toward does not" {
    var case = try depthCase();
    defer case.deinit();
    flatTri(&case, 0x20, .{ 100, 200, 300 }); // avg 200
    flatTri(&case, 0x20, .{ 4296, 4296, 4297 }); // avg ~4296: +4096
    try std.testing.expectEqual(@as(u64, 1), case.gpu.gp0.pgxp.depth_clears);
    const rec = lastRecord(case.gpu, .clear_depth);
    try std.testing.expectEqual(@as(i32, 1024), rec.w); // fullArea's drawing area
    flatTri(&case, 0x20, .{ 10, 20, 30 });
    try std.testing.expectEqual(@as(u64, 1), case.gpu.gp0.pgxp.depth_clears);
}

test "Phase5: with the setting off nothing is recorded" {
    var case = try StreamCase.init(std.testing.allocator);
    defer case.deinit();
    case.fullArea();
    case.gpu.gp0.pgxp_enabled = true;
    flatTri(&case, 0x20, .{ 100, 200, 300 });
    try std.testing.expectEqual(@as(u8, 0), lastRecord(case.gpu, .draw_triangle).flags);
    case.gp0(0xE3000000 | (10 << 10));
    case.drain();
    for (case.gpu.sink.rec.records[0..case.gpu.sink.rec.count]) |r| try std.testing.expect(r.kind != .clear_depth);
}
