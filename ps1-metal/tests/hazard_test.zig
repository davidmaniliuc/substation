//! HazardTracker and the sampled-rect rule. No Metal: runs under `zig build test`.

const std = @import("std");
const metal = @import("ps1_metal");
const HazardTracker = metal.hazard_tracker.HazardTracker;
const prim_builder = metal.prim_builder;
const pi = metal.prim_instance;
const VramRect = pi.VramRect;

fn rect(x0: i32, y0: i32, x1: i32, y1: i32) VramRect {
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

fn texturedInstance() pi.PrimInstance {
    var inst = std.mem.zeroes(pi.PrimInstance);
    inst.kind = pi.Kind.textured_tri;
    return inst;
}

test "Hazard: a draw that samples nothing never breaks the pass" {
    var h = HazardTracker.init(std.testing.allocator);
    defer h.deinit();
    h.markWritten(rect(0, 0, 100, 100));
    try std.testing.expect(!h.needsBreakSampling(&.{}));
}

test "Hazard: sampling outside the dirty rect does not break the pass" {
    var h = HazardTracker.init(std.testing.allocator);
    defer h.deinit();
    h.markWritten(rect(0, 0, 63, 63));
    try std.testing.expect(!h.needsBreakSampling(&.{rect(256, 0, 319, 63)}));
}

test "Hazard: sampling what this pass wrote breaks it" {
    var h = HazardTracker.init(std.testing.allocator);
    defer h.deinit();
    h.markWritten(rect(0, 0, 63, 63));
    const r = [_]VramRect{rect(60, 60, 200, 200)};
    try std.testing.expect(h.needsBreakSampling(&r));
    // The predicate is PURE; only reset() clears the state.
    try std.testing.expect(h.needsBreakSampling(&r));
    h.reset();
    try std.testing.expect(!h.needsBreakSampling(&r));
}

test "Hazard: the clut row is checked separately from the texture page" {
    // Folding the two into one bounding rect would span everything between
    // them and split passes that do not need splitting.
    var h = HazardTracker.init(std.testing.allocator);
    defer h.deinit();
    h.markWritten(rect(0, 480, 255, 480));
    const page = rect(512, 0, 575, 255);
    const clut = rect(0, 480, 255, 480);
    try std.testing.expect(!h.needsBreakSampling(&.{page}));
    try std.testing.expect(h.needsBreakSampling(&.{ page, clut }));
}

test "Hazard: a textured triangle reports its page and clut at the right depth" {
    var inst = texturedInstance();
    inst.tex_depth = 0; // 4bpp: 64 words wide
    inst.tpage_x = 320;
    inst.tpage_y = 256;
    inst.clut_x = 640;
    inst.clut_y = 300;
    var buf: [4]VramRect = undefined;
    var rects = prim_builder.sampledRects(inst, &buf);
    try std.testing.expectEqual(2, rects.len);
    try std.testing.expectEqual(rect(320, 256, 383, 511), rects[0]);
    try std.testing.expectEqual(rect(640, 300, 655, 300), rects[1]);

    inst.tex_depth = 1; // 8bpp: 128 words
    rects = prim_builder.sampledRects(inst, &buf);
    try std.testing.expectEqual(447, rects[0].x1);
    inst.tex_depth = 2; // 16bpp: 256 words, and no CLUT read at all
    rects = prim_builder.sampledRects(inst, &buf);
    try std.testing.expectEqual(575, rects[0].x1);
    try std.testing.expectEqual(1, rects.len);
}

test "Hazard: a page on vram's last row wraps to row zero, not row 512" {
    // ps1_vram_read masks the linear index with 0x7FFFF over the WHOLE
    // 1024x512 space, so row 511's overflow wraps to row 0.
    var inst = texturedInstance();
    inst.tex_depth = 2;
    inst.tpage_x = 960; // 960 + 255 = 1215 >= 1024: this page wraps
    inst.tpage_y = 256; // last sampled row is 511
    var buf: [4]VramRect = undefined;
    const rects = prim_builder.sampledRects(inst, &buf);
    try std.testing.expectEqual(2, rects.len);
    try std.testing.expectEqual(rect(0, 256, 1023, 511), rects[0]);
    try std.testing.expectEqual(rect(0, 0, 1023, 0), rects[1]);

    // u = 255 at tpage_x = 960 is column 1215 in row 511: lin = 524479,
    // & 0x7FFFF = 191, row 0 column 191.
    const wrapped = rect(191, 0, 191, 0);
    try std.testing.expect(rects[1].intersects(wrapped));
    try std.testing.expect(!rects[0].intersects(wrapped));
}

test "Hazard: a clut on vram's last row wraps to row zero, not row 512" {
    var inst = texturedInstance();
    inst.tex_depth = 1; // 8bpp: 256-entry CLUT row
    inst.clut_x = 784; // 784 + 255 = 1039 >= 1024: this CLUT wraps
    inst.clut_y = 511;
    var buf: [4]VramRect = undefined;
    const rects = prim_builder.sampledRects(inst, &buf);
    try std.testing.expectEqual(3, rects.len); // 1 page rect + 2 CLUT rects
    try std.testing.expectEqual(rect(0, 511, 1023, 511), rects[1]);
    try std.testing.expectEqual(rect(0, 0, 1023, 0), rects[2]);

    const wrapped = rect(0, 0, 15, 0);
    try std.testing.expect(rects[2].intersects(wrapped));
    try std.testing.expect(!rects[1].intersects(wrapped));
}

test "Hazard: writing what this pass sampled breaks it too" {
    // The mirror of "sampling what this pass wrote". A read resolves against
    // device memory; a write reaches it only when its tile is stored, so the
    // outcome is decided by tile scheduling: a race, not a stable wrong pixel.
    var h = HazardTracker.init(std.testing.allocator);
    defer h.deinit();
    h.markRead(&.{rect(256, 256, 319, 511)});
    h.markWritten(rect(300, 20, 380, 90));

    try std.testing.expect(!h.needsBreakWriting(rect(0, 0, 63, 63)));
    try std.testing.expect(h.needsBreakWriting(rect(256, 256, 287, 287)));
    h.reset();
    try std.testing.expect(!h.needsBreakWriting(rect(256, 256, 287, 287)));
}

test "Hazard: read rects are kept as a list rather than unioned together" {
    // Two pages that sit apart: their union spans everything between them.
    // Measured 13,767 passes against 266 over silent-hill-usa.
    var h = HazardTracker.init(std.testing.allocator);
    defer h.deinit();
    h.markRead(&.{rect(0, 0, 63, 255)});
    h.markRead(&.{rect(896, 0, 959, 255)});
    try std.testing.expect(!h.needsBreakWriting(rect(400, 100, 500, 150)));
    try std.testing.expect(h.needsBreakWriting(rect(900, 100, 910, 150)));
}

test "Hazard: a rect read twice is stored once" {
    var h = HazardTracker.init(std.testing.allocator);
    defer h.deinit();
    h.markRead(&.{ rect(0, 0, 63, 255), rect(0, 0, 63, 255) });
    h.markRead(&.{rect(0, 0, 63, 255)});
    try std.testing.expectEqual(1, h.reads.items.len);
}
