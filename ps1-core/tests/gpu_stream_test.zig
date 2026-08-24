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
