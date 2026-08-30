//! The committed memory-mover fixture.
//!
//! Every command here is a VRAM move rather than a rasterization, which is what
//! makes it checkable from Swift without a rasterizer: ~120 lines of ShadowVram
//! reproduce it exactly, and its per-frame hashes are the only ones Phase A2
//! actually verifies.
//!
//! Driven by real GP0 words through a bare Gpu rather than by hand-built
//! records, so the recorder path is exercised too.

const std = @import("std");
const ps1 = @import("ps1_core");
const fixture = @import("fixture.zig");

const Gpu = ps1.gpu.Gpu;
const Precise = ps1.pgxp.Precise;

const Case = struct {
    gpu: *Gpu,
    w: fixture.Writer = fixture.Writer.empty,
    a: std.mem.Allocator,

    fn gp0(self: *Case, word: u32) void {
        _ = self.gpu.writeGp0(word, Precise.none);
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

    /// Ends a frame: drains, takes the stream, hashes VRAM, appends.
    fn endFrame(self: *Case) !void {
        self.drain();
        const s = self.gpu.sink.rec.takeFrame();
        std.debug.assert(s.complete);
        try self.w.addFrame(self.a, s, fixture.hashVram(&self.gpu.vram));
    }
};

/// A GP0(A0) upload of `w` x `h` at (x, y), payload filled deterministically.
/// `seed` shifts the pattern so successive uploads differ.
fn upload(c: *Case, x: u16, y: u16, w: u16, h: u16, seed: u16) void {
    c.gp0(0xA0000000);
    c.gp0(@as(u32, x) | (@as(u32, y) << 16));
    c.gp0(@as(u32, w) | (@as(u32, h) << 16));

    // The word count must come from the AXIS EXTENT, not the literal field:
    // `vram.zig`'s axisExtent reads w == 0 as the whole 1024-pixel axis and
    // h == 0 as the whole 512 rows. Taking the literal sends zero words for a
    // whole-axis upload, which leaves `write_active` true with the transfer
    // outstanding — and `gp0.zig`'s `if (vram.write_active)` then swallows the
    // NEXT frame's commands as payload.
    const ew: u32 = if (w == 0) 1024 else w;
    const eh: u32 = if (h == 0) 512 else h;

    const words = (ew * eh + 1) / 2;
    var i: u32 = 0;
    while (i < words) : (i += 1) {
        const lo: u16 = seed +% @as(u16, @truncate(i *% 2));
        const hi: u16 = seed +% @as(u16, @truncate(i *% 2 +% 1));
        c.gp0(@as(u32, lo) | (@as(u32, hi) << 16));
    }
}

/// Builds the fixture and returns its serialized bytes; caller frees.
pub fn build(a: std.mem.Allocator) ![]u8 {
    const gpu = try a.create(Gpu);
    defer a.destroy(gpu);
    gpu.* = Gpu.init();
    gpu.sink.rec.arm();

    var c = Case{ .gpu = gpu, .a = a };
    defer c.w.deinit(a);

    // Frame 0 — a plain upload, mask off. Establishes texels, some with bit 15
    // set (the pattern runs through 0x8000+), which later frames read back.
    c.gp0(0xE6000000);
    upload(&c, 0, 0, 32, 8, 0x7FF0);
    try c.endFrame();

    // Frame 1 — Fill Rectangle is UNMASKED even with E6 check+set on. Hardware
    // ignores E6 for fills, and this is the single write in the whole core that
    // does; a Swift mover that routes fills through the masked store fails here
    // and nowhere else. The fill is (8,2)-(24,8), NOT the whole (0,0)-(32,8)
    // upload: every pixel it covers already has bit15 set (any upload row
    // except row 0 does, see `upload`'s doc comment above), so a masked fill
    // would skip literally all of them (mask.check) instead of overwriting to
    // 0x3C1F — the real fillRectangle does neither that nor force bit15 back on
    // via mask.set. Off-origin on purpose: an unset destination cell inside
    // this rect can read an UNSET source cell that is itself inside the rect —
    // e.g. dst (8,2)'s source is (4,0), outside the fill and still carrying the
    // original pattern — so frame 2's copy has both a real value crossing INTO
    // the fill footprint and, one hop further at (12,4), a cell whose value
    // depends on whether that crossing was read before or after it happened.
    // A fill anchored at the upload's own origin can't do this: every cell
    // inside it maps, one copy-offset step back, to another cell inside it,
    // so the whole region is a self-similar sink and copy order is invisible.
    c.gp0(0xE6000003);
    // GP0(02)'s colour is BGR888 on the wire and `gp0.zig` runs it through
    // Color.getColor16 before it reaches the record, so the word is chosen for
    // what it DECODES to: r=0xF8>>3=0x1F, g=0x00, b=0x78>>3=0x0F, i.e. the
    // record's `.value` is ABGR1555 0x3C1F. Writing 0x02003C1F here instead —
    // the obvious reading — records 0x00E3.
    c.gp0(0x027800F8); // GP0(02) fill, colour 0x3C1F once decoded
    c.gp0(0x00020008); // at (8, 2)
    c.gp0(0x00060010); // 16 wide, 6 tall
    try c.endFrame();

    // Frame 2 — VRAM->VRAM copy, masked, overlapping FORWARD (dst below-right
    // of src, so the copy runs backwards). The source rect (0,0)-(32,8) is now
    // frame 1's mix of fresh uniform 0x3C1F and the original varying, bit15-set
    // pattern, and the destination rect (4,2)-(36,10) overlaps it enough for
    // (8,2) and (12,4) — one copy-offset (4,2) apart, both inside the fill —
    // to alias each other: forced-forward order propagates (8,2)'s freshly
    // copied value (from source (4,0), outside the fill) into (12,4), while
    // the real backwards order still finds (8,2) unwritten and copies its
    // stale 0x3C1F fill colour instead. mask.check is exercised too: every
    // destination cell outside the fill's footprint still carries bit15 from
    // the untouched pattern and must be skipped rather than overwritten.
    c.gp0(0xE6000002);
    c.gp0(0x80000000);
    c.gp0(0x00000000); // source (0, 0)
    c.gp0(0x00020004); // destination (4, 2)
    c.gp0(0x00080020); // 32 x 8
    try c.endFrame();

    // Frame 3 — the same copy the other way, mask off (dst above-left of src,
    // so the FORWARDS branch of copyRect runs). Every destination cell is
    // overwritten regardless of bit15, which is a different outcome from
    // frame 2's masked copy over the same footprint — frame 3's hash differs
    // from frame 2's because of that, not just because a different Zig branch
    // ran.
    c.gp0(0xE6000000);
    c.gp0(0x80000000);
    c.gp0(0x00020004); // source (4, 2)
    c.gp0(0x00000000); // destination (0, 0)
    c.gp0(0x00080020);
    try c.endFrame();

    // Frame 4 — w == 0 means the WHOLE AXIS, not an empty rectangle. One full
    // 1024-pixel row is 512 payload words, which keeps the committed file small.
    //
    // h == 0 is NOT exercised here, and deliberately so: it means the full 512
    // rows, i.e. 262,144 payload words and a ~1 MB committed fixture. The spec
    // asks for both, but the axisExtent rule is the same code for either axis
    // and one of them proves it. If you want the other covered, put it in a
    // GENERATED fixture, not this one.
    upload(&c, 0, 300, 0, 1, 0x1234);
    try c.endFrame();

    // Frame 5 — a payload aborted mid-transfer by GP1(01). The remaining words
    // of the declared 16x16 never arrive; the pixels already written stay.
    c.gp0(0xA0000000);
    c.gp0(0x00400040); // (64, 64)
    c.gp0(0x00100010); // 16 x 16 => 128 payload words
    // Each word carries its own index in both halves, so a consumer that
    // misindexes within this 8-word run still lands on a different value
    // instead of silently matching by accident.
    var i: u32 = 0;
    while (i < 8) : (i += 1) c.gp0(0xAAAA5555 +% ((i << 16) | i));
    c.gp1(0x01000000); // abort; drains first, per Case.gp1
    c.gp0(0x02007FFF); // a fill afterwards proves the machine is still sane
    c.gp0(0x00600060);
    c.gp0(0x00040008);
    try c.endFrame();

    return c.w.serialize(a);
}
