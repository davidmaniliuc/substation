//! The committed rasterization fixture — the gate ladder for Phase B's shader
//! tasks.
//!
//! `pl-render-polygon`'s only non-empty frame carries 18 flat AND 6 Gouraud
//! triangles, so no fixture in the Phase A2 corpus can gate a flat-only
//! rasterizer. This one puts ONE FEATURE GROUP PER FRAME, in a fixed order
//! that the Swift tests index by number — see the table in
//! docs/superpowers/plans/2026-08-27-metal-renderer-phase-b.md. Do not
//! reorder or insert frames; append instead.
//!
//! Driven by real GP0 words through a bare Gpu rather than by hand-built
//! records, so gp0.zig's decode and the recorder path are exercised too, and
//! the records are the ones a real game would produce.
//!
//! Unlike `synthetic.zig` this fixture is NOT reproducible from Swift without
//! a rasterizer — that is the whole point. Its hashes come from the software
//! rasterizer and Phase B's job is to match them.

const std = @import("std");
const ps1 = @import("ps1_core");
const fixture = @import("fixture.zig");

const Gpu = ps1.gpu.Gpu;

const Case = struct {
    gpu: *Gpu,
    w: fixture.Writer = fixture.Writer.empty,
    a: std.mem.Allocator,

    fn gp0(self: *Case, word: u32) void {
        _ = self.gpu.writeGp0(word);
    }

    /// GP0 words queue into a 16-entry FIFO gated on cycle_debt while GP1
    /// executes immediately, so an undrained interleave silently reorders the
    /// stream. Always drain before a gp1() and before ending a frame.
    fn drain(self: *Case) void {
        _ = self.gpu.step(50_000_000);
    }

    fn gp1(self: *Case, word: u32) void {
        self.drain();
        self.gpu.writeGp1(word);
    }

    fn endFrame(self: *Case) !void {
        self.drain();

        // A hand-written GP0 stream whose word count does not match the
        // opcode's arity is a silent bug: gp0.zig consumes parameters
        // blindly, so a primitive short by one word swallows the NEXT
        // frame's first command instead of failing. Catch it here, at
        // generation time, rather than as a mysteriously wrong later frame.
        //
        // These assertions compile out under the ReleaseFast build this
        // fixture is GENERATED with (`stream-capture`), so they cannot catch
        // anything at generation time by themselves. What makes them
        // effective is `zig build test`, which reruns this same generator in
        // Debug (where they DO fire) and byte-compares the result against
        // the committed fixture — a mismatched arity introduced later would
        // either trip an assertion here or change the committed bytes, and
        // either way the test fails.
        std.debug.assert(self.gpu.gp0.words_remaining == 0);
        std.debug.assert(!self.gpu.gp0.polyline_active);

        const s = self.gpu.sink.rec.takeFrame();
        std.debug.assert(s.complete);
        try self.w.addFrame(self.a, s, fixture.hashVram(&self.gpu.vram));
    }

    /// GP0(E3)/GP0(E4): the inclusive drawing area. Every frame sets it
    /// explicitly — `registers.zig` defaults `area_bot_right` to 0, which is a
    /// degenerate clip rect that draws nothing at all.
    fn clip(self: *Case, x0: u32, y0: u32, x1: u32, y1: u32) void {
        self.gp0(0xE3000000 | (y0 << 10) | x0);
        self.gp0(0xE4000000 | (y1 << 10) | x1);
    }

    /// GP0(E5): the drawing offset, two 11-bit signed fields.
    fn offset(self: *Case, x: i32, y: i32) void {
        const ux: u32 = @as(u32, @bitCast(x)) & 0x7FF;
        const uy: u32 = @as(u32, @bitCast(y)) & 0x7FF;
        self.gp0(0xE5000000 | (uy << 11) | ux);
    }

    /// A vertex word: 16-bit y in the high half, 16-bit x in the low half.
    fn xy(x: i32, y: i32) u32 {
        return (@as(u32, @as(u16, @bitCast(@as(i16, @intCast(y))))) << 16) |
            @as(u32, @as(u16, @bitCast(@as(i16, @intCast(x)))));
    }
};

/// Three texture pages plus a CLUT row, uploaded with GP0(A0).
///
/// The CLUT deliberately contains index 0 == 0x0000 (a HOLE — `texel == 0` is
/// not drawn at all, which is a discard rather than a black pixel) and an
/// entry with bit 15 set (STP, which is what gates per-pixel transparency on
/// a textured draw).
fn uploadTexturePages(c: *Case) void {
    // CLUT at (0, 240): 256 entries so both the 4bpp and 8bpp pages can share
    // it. Entry 0 is the hole; entry 3 carries STP.
    c.gp0(0xA0000000);
    c.gp0(Case.xy(0, 240));
    c.gp0(0x00010100); // 256 x 1
    var i: u32 = 0;
    while (i < 128) : (i += 1) {
        const lo: u16 = clutEntry(@intCast(i * 2));
        const hi: u16 = clutEntry(@intCast(i * 2 + 1));
        c.gp0(@as(u32, lo) | (@as(u32, hi) << 16));
    }

    // 4bpp page at (0, 0): 64 x 64 texels, four texels per word.
    c.gp0(0xA0000000);
    c.gp0(Case.xy(0, 0));
    c.gp0(0x00400040); // 64 x 64
    i = 0;
    while (i < 64 * 64 / 2) : (i += 1) {
        c.gp0(0x1234_5678 +% (i *% 0x0101_0101));
    }

    // 8bpp page at (128, 0): tpage bit 7. Same 64x64 word footprint.
    c.gp0(0xA0000000);
    c.gp0(Case.xy(128, 0));
    c.gp0(0x00400040);
    i = 0;
    while (i < 64 * 64 / 2) : (i += 1) {
        c.gp0(0x0A1B_2C3D +% (i *% 0x0003_0007));
    }

    // 16bpp page at (256, 0): tpage bit 8, so texels are read straight out.
    c.gp0(0xA0000000);
    c.gp0(Case.xy(256, 0));
    c.gp0(0x00400040);
    i = 0;
    while (i < 64 * 64 / 2) : (i += 1) {
        c.gp0(0x7C1F_03E0 +% (i *% 0x0011_0023));
    }
}

fn clutEntry(idx: u8) u16 {
    if (idx == 0) return 0x0000; // the hole
    if (idx == 3) return 0x8000 | 0x1F; // STP set
    return @as(u16, idx) *% 0x0123;
}

pub fn build(a: std.mem.Allocator) ![]u8 {
    const gpu = try a.create(Gpu);
    defer a.destroy(gpu);
    gpu.* = Gpu.init();
    gpu.sink.rec.arm();

    var c = Case{ .gpu = gpu, .a = a };
    defer c.w.deinit(a);

    // ---- Frame 0: flat triangles ----------------------------------------
    // GP0(20) is an opaque flat triangle, GP0(22) a semi-transparent one; the
    // semi-transparency MODE is GP0(E1) bits 5-6, so the four transparent
    // triangles below each reprogram E1 first.
    c.gp0(0xE1000000); // dither off, blend mode 0
    c.clip(0, 0, 255, 191);
    c.offset(0, 0);
    c.gp0(0xE6000000); // mask off

    // Clockwise and counter-clockwise windings of the same triangle: the
    // rasterizer normalizes by flipping the sign of every edge function
    // rather than by swapping vertices, and the two must cover identically.
    c.gp0(0x2000FF00); // colour 0x00FF00
    c.gp0(Case.xy(10, 10));
    c.gp0(Case.xy(60, 14));
    c.gp0(Case.xy(20, 50));
    c.gp0(0x200000FF);
    c.gp0(Case.xy(80, 10));
    c.gp0(Case.xy(90, 50));
    c.gp0(Case.xy(130, 14));

    // Two triangles sharing the edge (10,60)-(60,60): the top-left fill rule
    // must paint every pixel on it exactly once. A seam or a double-blend
    // here is the single most likely shader bug and it is invisible in a
    // screenshot.
    c.gp0(0x20FFFFFF);
    c.gp0(Case.xy(10, 60));
    c.gp0(Case.xy(60, 60));
    c.gp0(Case.xy(10, 100));
    c.gp0(0x20FF00FF);
    c.gp0(Case.xy(60, 60));
    c.gp0(Case.xy(60, 100));
    c.gp0(Case.xy(10, 100));

    // Degenerate: zero area, drawn nowhere.
    c.gp0(0x20123456);
    c.gp0(Case.xy(70, 60));
    c.gp0(Case.xy(90, 60));
    c.gp0(Case.xy(110, 60));

    // Clipped by the drawing area on all four sides at once.
    c.clip(100, 100, 140, 130);
    c.gp0(0x2000FFFF);
    c.gp0(Case.xy(90, 90));
    c.gp0(Case.xy(160, 95));
    c.gp0(Case.xy(120, 150));
    c.clip(0, 0, 255, 191);

    // A non-zero drawing offset, including a negative one.
    c.offset(30, -5);
    c.gp0(0x20FFFF00);
    c.gp0(Case.xy(150, 20));
    c.gp0(Case.xy(200, 30));
    c.gp0(Case.xy(160, 70));
    c.offset(0, 0);

    // Oversized: 1024 wide, DROPPED rather than clipped. If Phase B clips it
    // instead, this frame's hash moves and nothing else in the corpus notices.
    c.gp0(0x20FF0000);
    c.gp0(Case.xy(-500, 150));
    c.gp0(Case.xy(524, 150));
    c.gp0(Case.xy(0, 180));

    // The four semi-transparency modes over the white triangle drawn above.
    var mode: u32 = 0;
    while (mode < 4) : (mode += 1) {
        c.gp0(0xE1000000 | (mode << 5));
        c.gp0(0x22808080);
        c.gp0(Case.xy(12 + @as(i32, @intCast(mode)) * 12, 62));
        c.gp0(Case.xy(22 + @as(i32, @intCast(mode)) * 12, 62));
        c.gp0(Case.xy(12 + @as(i32, @intCast(mode)) * 12, 98));
    }
    c.gp0(0xE1000000);

    // E6: set-mask on, then a check-mask draw over the pixels it marked.
    c.gp0(0xE6000001);
    c.gp0(0x2000FF7F);
    c.gp0(Case.xy(170, 100));
    c.gp0(Case.xy(210, 100));
    c.gp0(Case.xy(170, 140));
    c.gp0(0xE6000002);
    c.gp0(0x207F00FF);
    c.gp0(Case.xy(160, 95));
    c.gp0(Case.xy(220, 110));
    c.gp0(Case.xy(180, 150));
    c.gp0(0xE6000000);
    try c.endFrame();

    // ---- Frame 1: Gouraud triangles --------------------------------------
    // GP0(30) opaque, GP0(32) semi-transparent. Colours are BGR888 on the
    // wire; the first colour word carries the opcode in its top byte.
    c.gp0(0xE1000000); // dither OFF
    c.gp0(0x300000FF);
    c.gp0(Case.xy(10, 10));
    c.gp0(0x0000FF00);
    c.gp0(Case.xy(90, 20));
    c.gp0(0x00FF0000);
    c.gp0(Case.xy(20, 90));

    // Dither ON (E1 bit 9). The offsets are 8-bit channel units added BEFORE
    // the >> 3 down to 5 bits, which is the thing 900daa0 fixed; a shader
    // that treats them as 5-bit units differs here and only here.
    c.gp0(0xE1000200);
    c.gp0(0x30102030);
    c.gp0(Case.xy(110, 10));
    c.gp0(0x00405060);
    c.gp0(Case.xy(190, 20));
    c.gp0(0x00708090);
    c.gp0(Case.xy(120, 90));

    // A shaded QUAD (GP0(38)), which decomposes into two triangles — the
    // diagonal seam is a real behaviour and must be reproduced, not smoothed.
    c.gp0(0x38FF0000);
    c.gp0(Case.xy(10, 110));
    c.gp0(0x0000FF00);
    c.gp0(Case.xy(90, 110));
    c.gp0(0x000000FF);
    c.gp0(Case.xy(10, 180));
    c.gp0(0x00FFFFFF);
    c.gp0(Case.xy(90, 180));

    // Transparent Gouraud, blend mode 1 (B+F), dither still on.
    c.gp0(0xE1000220);
    c.gp0(0x32404040);
    c.gp0(Case.xy(20, 120));
    c.gp0(0x00808080);
    c.gp0(Case.xy(80, 130));
    c.gp0(0x00C0C0C0);
    c.gp0(Case.xy(30, 170));
    c.gp0(0xE1000000);
    try c.endFrame();

    // ---- Frame 2: textured triangles -------------------------------------
    // Three texture pages are uploaded first: a 4bpp one, an 8bpp one and a
    // 16bpp one, plus a CLUT row. The CLUT deliberately contains a 0 entry
    // (a HOLE — texel == 0 is not drawn at all) and an entry with bit 15 set
    // (STP, which is what gates per-pixel transparency on a textured draw).
    uploadTexturePages(&c);

    c.clip(0, 0, 255, 191);
    c.offset(0, 0);
    c.gp0(0xE2000000); // texture window: no mask, no offset

    // GP0(24): textured triangle, opaque, MODULATED (opcode bit 0 clear).
    // tpage word 0x0000 selects page (0,0) at 4bpp, blend mode 0. The clut
    // half is 0x3C00 — (240 << 6) | 0 — pointing at the CLUT row uploaded
    // above at (0, 240); 0x0000 would alias the 4bpp page's own first row.
    c.gp0(0x24808080);
    c.gp0(Case.xy(10, 10));
    c.gp0(0x3C000000); // clut (0,240) in the high half, u/v in the low
    c.gp0(Case.xy(70, 14));
    c.gp0(0x00000040); // tpage in the high half, u/v in the low
    c.gp0(Case.xy(20, 70));
    c.gp0(0x00004000);

    // GP0(25): RAW textured — opcode bit 0 set, so no modulation at all.
    c.gp0(0x25000000);
    c.gp0(Case.xy(90, 10));
    c.gp0(0x3C000000);
    c.gp0(Case.xy(150, 14));
    c.gp0(0x00000040);
    c.gp0(Case.xy(100, 70));
    c.gp0(0x00004000);

    // 8bpp (tpage bit 7, page X 2 -> x=128) and 16bpp (tpage bit 8, page X 4
    // -> x=256) pages — the two pages `uploadTexturePages` put at (128,0) and
    // (256,0). Page X is `tpage & 0xF` in 64-pixel units: leaving it 0 (as an
    // earlier draft did) samples the SAME 4bpp page at (0,0) as every other
    // draw in this frame, so these two pages were uploaded and never read.
    c.gp0(0x24FFFFFF);
    c.gp0(Case.xy(10, 90));
    c.gp0(0x3C000000);
    c.gp0(Case.xy(70, 94));
    c.gp0(0x00820040);
    c.gp0(Case.xy(20, 150));
    c.gp0(0x00804000);

    // 16bpp: clut is unused at this depth, so this one keeps 0x00000000. Note
    // v0's u reaches 64 here — one column past the 64-wide upload — which
    // reads unwritten VRAM as texel 0 and is discarded; that is expected and
    // deliberately left alone.
    c.gp0(0x25000000);
    c.gp0(Case.xy(90, 90));
    c.gp0(0x00000000);
    c.gp0(Case.xy(150, 94));
    c.gp0(0x01040040);
    c.gp0(Case.xy(100, 150));
    c.gp0(0x01004000);

    // A texture window: GP0(E2) mask=8, offset=8 on both axes. mask*8 == 0x40
    // is a single bit (bit 6), so this does NOT tile u/v into a 64x64 block —
    // it forces bit 6 of both u and v to 1 (offset*8's own bit 6), leaving
    // every other bit unchanged. The sprite path applies the identical E2
    // arithmetic independently, which is why frame 4 repeats this setup.
    c.gp0(0xE2000000 | (8 << 15) | (8 << 10) | (8 << 5) | 8);
    c.gp0(0x24FFFFFF);
    c.gp0(Case.xy(170, 10));
    c.gp0(0x3C000000);
    c.gp0(Case.xy(240, 20));
    c.gp0(0x000000FF);
    c.gp0(Case.xy(180, 90));
    c.gp0(0x0000FF00);
    c.gp0(0xE2000000);

    // Semi-transparent textured (GP0(26)): the STP bit of each TEXEL decides
    // per pixel, not the opcode alone. The E1 write below sets blend mode 1,
    // but a textured polygon's ACTUAL blend mode is latched from its own
    // tpage word (`e1_texpage_mask` covers bits 5-6, `latch_texpage` in
    // gp0.zig) — so the tpage word here carries bit 5 (0x0020) itself. Page X
    // stays 0: this draw still samples the 4bpp page.
    c.gp0(0xE1000020); // blend mode 1
    c.gp0(0x26808080);
    c.gp0(Case.xy(170, 100));
    c.gp0(0x3C000000);
    c.gp0(Case.xy(240, 110));
    c.gp0(0x00200040);
    c.gp0(Case.xy(180, 170));
    c.gp0(0x00004000);
    c.gp0(0xE1000000);
    try c.endFrame();

    // ---- Frame 3: flat rectangles ----------------------------------------
    c.clip(0, 0, 255, 191);
    c.offset(0, 0);
    c.gp0(0x6000FF00); // GP0(60): variable-size, opaque
    c.gp0(Case.xy(10, 10));
    c.gp0(0x00200030); // 48 x 32

    c.gp0(0x60FF0000); // 1x1 — the smallest thing the box path can emit
    c.gp0(Case.xy(70, 10));
    c.gp0(0x00010001);

    // This core maps GP0(70..73) to fixed 8x8 and GP0(78..7B) to fixed 16x16
    // (`gp0.zig`'s `drawFixedRectangle(..., 8)` / `(..., 16)` dispatch) — this
    // fixture freezes THIS core's mapping, not the hardware naming some docs
    // use.
    c.gp0(0x700000FF); // GP0(70): fixed 8x8
    c.gp0(Case.xy(74, 10));

    c.gp0(0x7800FFFF); // GP0(78): fixed 16x16
    c.gp0(Case.xy(80, 10));

    // Clipped on all four sides. The clip rect must be programmed BEFORE
    // GP0(60)'s own header: gp0.zig consumes the next two words as this
    // primitive's vertex and size unconditionally, so an E3/E4 pair emitted
    // in between is read as primitive data instead of a register write.
    c.clip(100, 40, 140, 70);
    c.gp0(0x60FFFFFF);
    c.gp0(Case.xy(90, 30));
    c.gp0(0x00400040);
    c.clip(0, 0, 255, 191);

    c.gp0(0x60123456); // oversized: 1024 wide, DROPPED
    c.gp0(Case.xy(0, 100));
    c.gp0(0x00100400);

    c.gp0(0xE1000040); // blend mode 2 (B-F)
    c.gp0(0x62808080); // GP0(62): semi-transparent
    c.gp0(Case.xy(14, 14));
    c.gp0(0x00180020);
    c.gp0(0xE1000000);

    c.offset(-8, 6); // a negative offset on the rectangle path
    c.gp0(0x6000FFFF);
    c.gp0(Case.xy(170, 20));
    c.gp0(0x00180018);
    c.offset(0, 0);
    try c.endFrame();

    // ---- Frame 4: textured rectangles ------------------------------------
    // The sprite path. Its u/v arithmetic is `tu +% @truncate(xx)` on u8 —
    // a WRAP, not the triangle path's interpolate-and-clamp — so a sprite
    // wider than the distance from tu to 255 reads back round to 0. That is
    // the behaviour with no coverage anywhere in the Phase A2 corpus.
    c.clip(0, 0, 255, 191);
    c.offset(0, 0);
    c.gp0(0xE1000000);
    c.gp0(0xE2000000);

    // tv = 240 with a 32-tall sprite: v runs 240..255 then wraps to 0..15.
    // clut half 0x3C00 as in frame 2 — the sprite path shares the CLUT row.
    c.gp0(0x64FFFFFF); // GP0(64): variable-size textured, modulated
    c.gp0(Case.xy(10, 10));
    c.gp0(0x3C00F000); // clut (0,240), u=0x00 v=0xF0 -> exercise the v wrap
    c.gp0(0x00200020);

    // Same clut and size, but tu = 240 as well: u now runs 240..255 then
    // wraps to 0..15 too — the sprite path's own u WRAP (`tu +% @truncate(xx)`
    // on u8), not the triangle path's interpolate-and-clamp.
    c.gp0(0x65000000); // RAW (no modulation)
    c.gp0(Case.xy(50, 10));
    c.gp0(0x3C00F0F0);
    c.gp0(0x00200020);

    c.gp0(0x7C808080); // GP0(7C): fixed 16x16, modulated
    c.gp0(Case.xy(90, 10));
    c.gp0(0x3C001010);

    c.gp0(0x74FFFFFF); // GP0(74): fixed 8x8
    c.gp0(Case.xy(110, 10));
    c.gp0(0x3C002020);

    // The same E2 mask/offset as frame 2 (forces bit 6 of u and v to 1 rather
    // than tiling — see the comment there), applied through the sprite path's
    // own copy of the masking arithmetic in `drawTexturedRectangle`.
    c.gp0(0xE2000000 | (8 << 15) | (8 << 10) | (8 << 5) | 8);
    c.gp0(0x64FFFFFF);
    c.gp0(Case.xy(10, 60));
    c.gp0(0x3C000000);
    c.gp0(0x00400040);
    c.gp0(0xE2000000);

    // Semi-transparent sprite, blend mode 3 (B + F/4).
    c.gp0(0xE1000060);
    c.gp0(0x66808080);
    c.gp0(Case.xy(70, 60));
    c.gp0(0x3C000000);
    c.gp0(0x00300030);
    c.gp0(0xE1000000);

    // Off the left/top edge, so the sprite's own bounds check runs.
    c.gp0(0x64FFFFFF);
    c.gp0(Case.xy(-10, -6));
    c.gp0(0x3C000000);
    c.gp0(0x00200020);
    try c.endFrame();

    // ---- Frame 5: lines ---------------------------------------------------
    // All eight octants, so no swapped dx/dy or sign survives. Bresenham's
    // error accumulator has no closed form, which is why the Swift encoder
    // walks the same loop and emits one instance per step.
    c.clip(0, 0, 255, 191);
    c.offset(0, 0);
    c.gp0(0xE1000000);
    const cx: i32 = 128;
    const cy: i32 = 96;
    const ends = [8][2]i32{
        .{ 90, 20 },   .{ 40, 60 },   .{ -40, 60 }, .{ -90, 20 },
        .{ -90, -20 }, .{ -40, -60 }, .{ 40, -60 }, .{ 90, -20 },
    };
    for (ends, 0..) |e, i| {
        c.gp0(0x4000FF00 | (@as(u32, @intCast(i)) << 16));
        c.gp0(Case.xy(cx, cy));
        c.gp0(Case.xy(cx + e[0], cy + e[1]));
    }

    // A zero-length line: steps == 0, and the shaded path must not divide.
    c.gp0(0x40FFFFFF);
    c.gp0(Case.xy(200, 170));
    c.gp0(Case.xy(200, 170));

    // Shaded lines (GP0(50)), rising and falling channels, dither on. The
    // channel at step k is c0 + floor((c1-c0)*k/steps) and (c1-c0) is
    // NEGATIVE on the falling one, so a shader using truncating division
    // instead of a floor differs here.
    c.gp0(0xE1000200);
    c.gp0(0x50000000);
    c.gp0(Case.xy(10, 180));
    c.gp0(0x00FFFFFF);
    c.gp0(Case.xy(240, 186));
    c.gp0(0x50FFFFFF);
    c.gp0(Case.xy(10, 188));
    c.gp0(0x00000000);
    c.gp0(Case.xy(240, 182));
    c.gp0(0xE1000000);

    // A semi-transparent polyline (GP0(4A) + the 0x55555555 terminator).
    // Opcode 0x42 is an ordinary 2-point line, NOT a polyline: gp0.zig
    // recognises polylines only when (opcode & 0xF8) == 0x48 or 0x58. 0x4A
    // is mono (bit 4 clear) and semi-transparent (bit 1 set).
    c.gp0(0xE1000020);
    c.gp0(0x4A808080);
    c.gp0(Case.xy(20, 20));
    c.gp0(Case.xy(60, 40));
    c.gp0(Case.xy(30, 70));
    c.gp0(0x55555555);
    c.gp0(0xE1000000);
    try c.endFrame();

    // ---- Frame 6: the feedback loop ---------------------------------------
    // Reads frames 0-5's OWN OUTPUT back as texture data, in the same frame
    // as further draws that overwrite it. This is the shape Task 11's hazard
    // detection exists for: a textured draw whose tpage intersects what the
    // current render pass has already written must end the pass first.
    c.clip(0, 0, 511, 511);
    c.offset(0, 0);
    c.gp0(0xE2000000);

    // Copy a drawn region up into the second texture-page row, then sample it.
    c.gp0(0x80000000);
    c.gp0(Case.xy(0, 0));
    c.gp0(Case.xy(256, 256));
    c.gp0(0x00400040); // 64 x 64

    c.gp0(0x25000000); // 16bpp page at (256,256) -> tpage 0x0114
    c.gp0(Case.xy(300, 20));
    c.gp0(0x00000000);
    c.gp0(Case.xy(380, 30));
    c.gp0(0x0114003F);
    c.gp0(Case.xy(310, 90));
    c.gp0(0x00003F00);

    // Draw INTO that page, then sample it again in the same frame.
    c.gp0(0x6000FF00);
    c.gp0(Case.xy(256, 256));
    c.gp0(0x00200020);
    c.gp0(0x25000000);
    c.gp0(Case.xy(390, 20));
    c.gp0(0x00000000); // GP0(25) needs 7 words; this v0 texcoord/clut word
    // was missing in an earlier draft and silently ate frame 6's next word.
    c.gp0(Case.xy(470, 30));
    c.gp0(0x0114003F);
    c.gp0(Case.xy(400, 90));
    c.gp0(0x00003F00);
    try c.endFrame();

    return c.w.serialize(a);
}
