//! The scaled path's blind spot: every
//! test here asserts something about the INTERIOR of a block, not only its
//! corner. `readbackNative` is the top-left subtexel of each block, where the
//! sample point IS the native pixel, so anything decided from px/py
//! reproduces its 1x answer there by construction and Gate 1 and Gate 2 both
//! pass whatever the other s*s - 1 subtexels do.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const ps1_core = @import("ps1_core");
const harness = @import("harness.zig");

const pi = ps1_metal.prim_instance;
const command = ps1_core.gpu.command;
const Command = command.Command;
const Frame = harness.Frame;

const alloc = std.testing.allocator;
const native_width = pi.native_width;
const native_pixels = pi.native_pixels;
const scale_ladder = harness.scale_ladder;
const painted = harness.painted;
const vtx = harness.vtx;
const fullDrawingArea = harness.fullDrawingArea;
const check = harness.check;

fn flatTriangle(colour: u16, v: [3][2]i16) Command {
    return .{ .kind = .draw_triangle, .value = colour, .v = .{
        vtx(v[0][0], v[0][1], 0, 0, 0),
        vtx(v[1][0], v[1][1], 0, 0, 0),
        vtx(v[2][0], v[2][1], 0, 0, 0),
    } };
}

test "subPixelSliversAreRefusedAndPaintedIdenticallyAtEveryScale" {
    // The coverage test's "not all three zero" half is the only part of
    // ps1_triangle_coverage that is not scale-invariant by construction, and
    // only a sliver can reach it: all three biased edge functions are zero at
    // once only when twice-area is 1, 2 or 3, since each term contributes
    // 0 or 1 to their sum. PrimBuilder refuses area == 0 and nothing else, so
    // these reach the shader.
    //
    // The first triangle below is the exact failing case: twice-area 1, and at
    // (100,100) the unbiased weights are (1,0,0) with edge 0 top-left, so 1x
    // computes b == (0,0,0) and refuses it. Before the s^2 comparison it was
    // painted at 2x, 3x, 4x and 8x alike: one native pixel appearing out of
    // nothing above 1x, which is downsample-invariance broken outright. No
    // fixture in the corpus contains such a triangle; real distant geometry
    // does.
    //
    // The assertion is on `.native`, and since the clause moved to the native
    // sample point that is exactly what it now pins: a sliver is refused at
    // every native SAMPLE POINT at every scale. It does paint the off-lattice
    // subtexels it covers (1/s^2 of a pixel apiece), which is the price of a
    // hole-free sub-pixel mesh and is deliberately outside this test's reach.
    // Comparing `.scaled` instead would freeze the artifact this file exists
    // to describe, not the invariant.
    const m = try harness.metal();
    defer m.deinit();
    const Sliver = struct { label: []const u8, v: [3][2]i16 };
    const slivers = [_]Sliver{
        .{ .label = "twice-area 1", .v = .{ .{ 100, 100 }, .{ 101, 100 }, .{ 100, 101 } } },
        .{ .label = "twice-area 1, reversed", .v = .{ .{ 100, 100 }, .{ 100, 101 }, .{ 101, 100 } } },
        .{ .label = "twice-area 2", .v = .{ .{ 100, 100 }, .{ 102, 100 }, .{ 100, 101 } } },
        .{ .label = "twice-area 3", .v = .{ .{ 100, 100 }, .{ 103, 100 }, .{ 100, 101 } } },
    };

    var ever_painted: usize = 0;
    var failed = false;
    for (slivers) |sliver| {
        const records = [_]Command{ fullDrawingArea(), flatTriangle(0x7FFF, sliver.v) };
        const one = try harness.frameOf(alloc, m, 1, .{}, &records);
        defer one.deinit(alloc);
        ever_painted += painted(one.native);
        for (scale_ladder) |scale| {
            const many = try harness.frameOf(alloc, m, scale, .{}, &records);
            defer many.deinit(alloc);
            if (!std.mem.eql(u16, one.native, many.native)) {
                std.debug.print("{s} @{d}x: native views differ\n", .{ sliver.label, scale });
                failed = true;
            }
        }
    }
    try std.testing.expect(!failed);

    // Without this the test would pass just as well against a shader that
    // refused every sliver at every scale, which is a different bug with the
    // same symptom. The twice-area 2 and 3 cases do paint at 1x.
    try check(ever_painted > 0, "every sliver was refused at 1x: the check is vacuous", .{});
}

// A small triangle that 1x paints must not be HOLLOW above 1x.
//
// The degeneracy clause ("and not all three zero", restated as
// `b_i < PS1_Q_BIAS_SCALE`) is a statement about a whole NATIVE pixel, but
// it was evaluated at the SUBTEXEL sample point. Off the native lattice the
// three biased edge functions are no longer multiples of PS1_Q_BIAS_SCALE, so
// for any triangle of twice-area under 3 * PS1_Q_BIAS_SCALE a band around the
// centroid has all three under it at once and is refused, while every
// subtexel nearer an edge, where one term is large, is kept. The result is a
// RING: the triangle is painted round its rim and hollow in the middle.
//
// The triangle below is native twice-area 2. It paints 2 px at 1x, and before
// the fix it painted 18 of 20 subtexels at 4x and 60 of 72 at 8x, with the
// missing ones forming a solid triangular hole dead centre.
//
// This is exactly the shape the two existing gates cannot see. Gate 1 and
// Gate 2 compare `readbackNative()`, which is the TOP-LEFT subtexel of each
// block, and at a top-left subtexel the sample point IS the native pixel, so
// the clause reproduces its 1x decision there by construction and both gates
// pass. Gate 2b's coverage ratio is a whole-frame average and a corpus of
// mostly-large primitives dilutes it away. Only the interior of a small
// triangle shows it, and a real game at 8x is made of them: a distant
// character model whose facets are all about a pixel across comes out as
// scattered rims with the scene showing through.
test "aSmallTriangleIsSolidRatherThanHollowAtEveryScale" {
    const m = try harness.metal();
    defer m.deinit();
    const fill: u16 = 0x7FFF;
    // Native twice-area 2: small enough to reach the clause, large enough that
    // 1x paints it. Twice-area 1 is the genuine sliver and is refused at every
    // scale: `subPixelSliversAreRefusedAndPaintedIdenticallyAtEveryScale`
    // pins that, and this test must not weaken it.
    const records = [_]Command{ fullDrawingArea(), flatTriangle(fill, .{ .{ 100, 100 }, .{ 102, 100 }, .{ 100, 101 } }) };

    const one = try harness.frameOf(alloc, m, 1, .{}, &records);
    defer one.deinit(alloc);
    // Without this the test passes against a shader that refuses the triangle
    // outright at every scale, which is a different bug with the same shape.
    try check(painted(one.native) > 0, "the 1x replay drew nothing", .{});

    var failed = false;
    for ([_]u32{1} ++ scale_ladder) |scale| {
        const f = try harness.frameOf(alloc, m, scale, .{}, &records);
        defer f.deinit(alloc);
        // A window around the triangle, one native pixel of margin on each
        // side, so "enclosed" is decided inside the drawn shape and never
        // against the edge of the scan.
        const x0 = 99 * scale;
        const x1 = 104 * scale - 1;
        const y0 = 99 * scale;
        const y1 = 103 * scale - 1;
        const at = struct {
            fn call(fr: Frame, x: usize, y: usize) bool {
                return fr.scaled[y * fr.width + x] == fill;
            }
        }.call;

        var holes: usize = 0;
        var first: [2]usize = .{ 0, 0 };
        for (y0..y1 + 1) |y| for (x0..x1 + 1) |x| {
            if (at(f, x, y)) continue;
            const left = for (x0..x) |i| (if (at(f, i, y)) break true) else false;
            const right = for (x + 1..x1 + 1) |i| (if (at(f, i, y)) break true) else false;
            const up = for (y0..y) |j| (if (at(f, x, j)) break true) else false;
            const down = for (y + 1..y1 + 1) |j| (if (at(f, x, j)) break true) else false;
            if (!(left and right and up and down)) continue;
            if (holes == 0) first = .{ x, y };
            holes += 1;
        };
        if (holes != 0) {
            std.debug.print("@{d}x: {d} enclosed unpainted subtexels, first at ({d}, {d})\n", .{ scale, holes, first[0], first[1] });
            failed = true;
        }
    }
    try std.testing.expect(!failed);
}

/// Every subtexel of each native pixel in `pixels` that is not `fill`.
fn unpaintedSubtexels(f: Frame, pixels: []const [2]usize, fill: u16) usize {
    var missing: usize = 0;
    for (pixels) |p| for (0..f.scale) |sy| for (0..f.scale) |sx| {
        missing += @intFromBool(f.scaled[(p[1] * f.scale + sy) * f.width + p[0] * f.scale + sx] != fill);
    };
    return missing;
}

// A sub-pixel MESH must keep every native pixel that 1x paints.
//
// `aSmallTriangleIsSolidRatherThanHollowAtEveryScale` is the single-triangle
// half of this and it is not enough, in two ways at once: it draws ONE
// triangle, and it looks only for an ENCLOSED hole. A character model is a
// mesh, and the hole a mesh opens reaches the silhouette rather than being
// surrounded by paint.
//
// The pixel one facet owns is a pixel every other facet is refused in (a
// non-owner's native sample point lies outside it by definition), so the pixel
// used to come out covered by the owner's share alone, with each neighbour's
// share left as background. The quad below is 2x1, split along its diagonal
// into two facets of native twice-area 2, the size a distant character model's
// facets are. 1x paints two pixels; at 8x, 20 of those two pixels' 128
// subtexels were unpainted, in one wedge: the far facet's whole share of the
// pixel its neighbour owned. That wedge is the reported hole.
//
// What makes it pass is now WATERTIGHTNESS, not blockiness: the two facets
// tile the 2x1 rectangle exactly, so between them they cover every subtexel
// of both pixels and the fill rule hands each shared-edge subtexel to
// exactly one of them. A mesh with a real gap in it would fail here and
// should: that is the difference from the blocky rule this replaced, which
// filled an owned block whole and so could not tell the two apart.
test "aSubPixelMeshKeepsEveryNativePixelOneXPaints" {
    const m = try harness.metal();
    defer m.deinit();
    const fill: u16 = 0x7FFF;
    const records = [_]Command{
        fullDrawingArea(),
        flatTriangle(fill, .{ .{ 100, 100 }, .{ 102, 100 }, .{ 100, 101 } }),
        flatTriangle(fill, .{ .{ 102, 100 }, .{ 102, 101 }, .{ 100, 101 } }),
    };

    const one = try harness.frameOf(alloc, m, 1, .{}, &records);
    defer one.deinit(alloc);
    var buf: [120][2]usize = undefined;
    var n: usize = 0;
    for (96..106) |y| for (96..108) |x| {
        if (one.native[y * one.width + x] != fill) continue;
        buf[n] = .{ x, y };
        n += 1;
    };
    const pixels = buf[0..n];
    // Without this the test passes against a shader that draws nothing at all,
    // which is a different bug with the same reading.
    try check(pixels.len > 0, "the 1x replay drew nothing", .{});

    var failed = false;
    for (scale_ladder) |scale| {
        const f = try harness.frameOf(alloc, m, scale, .{}, &records);
        defer f.deinit(alloc);
        const missing = unpaintedSubtexels(f, pixels, fill);
        if (missing != 0) {
            std.debug.print("scale {d}: {d} of {d} subtexels unpainted, over the {d} native px 1x paints\n", .{ scale, missing, pixels.len * scale * scale, pixels.len });
            failed = true;
        }
    }
    try std.testing.expect(!failed);
}

// A sub-pixel facet must paint its share of a native pixel its LARGE
// neighbour owns.
//
// This is the third and last shape of the hollow-mesh bug, and the one the
// other two tests could not see. `aSubPixelMeshKeepsEveryNativePixelOneXPaints`
// builds its mesh out of sub-pixel facets alone, so every pixel was OWNED by
// one of them and the blocky branch filled each block whole. A real character
// model is MIXED: the pixel is owned by a facet large enough to take the
// per-subtexel path, which paints only its own geometric share of the block,
// while the sub-pixel facets covering the rest of that block were drawn
// blockily and painted nothing outside the blocks they owned. The remainder
// of the block came out background, and the mesh is watertight there.
//
// This is FF7's field model at 8x: 67% of Cloud's 232 facets are under 1.5
// native px^2, and over the model's 1x-painted blocks 299 subtexels were
// unpainted while covered by a triangle the shader can paint.
//
// The pair below is the smallest instance. `small` is twice-area 2 (under
// `3 * PS1_Q_BIAS_SCALE`, the band the degeneracy clause governs), and
// `large` is twice-area 8. They share the edge (100,101)-(102,100) and
// between them cover the whole of native pixel (101,100), whose own sample
// point lies in `large`. At 8x, 44 of that block's 64 subtexels came back
// unpainted (10 of 16 at 4x, 4 of 9 at 3x, 2 of 4 at 2x).
test "aSubPixelFacetPaintsItsShareOfAPixelALargeNeighbourOwns" {
    const m = try harness.metal();
    defer m.deinit();
    const fill: u16 = 0x7FFF;
    const records = [_]Command{
        fullDrawingArea(),
        flatTriangle(fill, .{ .{ 100, 101 }, .{ 102, 101 }, .{ 102, 100 } }), // small
        flatTriangle(fill, .{ .{ 102, 100 }, .{ 100, 101 }, .{ 100, 97 } }), // large
    };

    // The pixel the two facets share. Without this the test would pass against
    // a shader that drew nothing there at any scale, which is a different bug
    // with the same reading.
    const shared = [_][2]usize{.{ 101, 100 }};
    const one = try harness.frameOf(alloc, m, 1, .{}, &records);
    defer one.deinit(alloc);
    try check(one.native[100 * one.width + 101] == fill, "1x did not paint the shared pixel", .{});

    var failed = false;
    for (scale_ladder) |scale| {
        const f = try harness.frameOf(alloc, m, scale, .{}, &records);
        defer f.deinit(alloc);
        const missing = unpaintedSubtexels(f, &shared, fill);
        if (missing != 0) {
            std.debug.print("scale {d}: {d} of {d} subtexels of the shared pixel unpainted\n", .{ scale, missing, scale * scale });
            failed = true;
        }
    }
    try std.testing.expect(!failed);
}

// MARK: Perspective, off the lattice

/// The texture the tests below sample: a 16bpp direct page at (256, 256)
/// whose texel at (u, v) is `0x0100 | u`, so a raw (unmodulated) draw writes
/// the texel's own u and a readback names what was sampled. Seeded through
/// `preload` rather than through a GP0 upload, so no pass split and no
/// primitive sampling its own destination.
fn rampVram(v: *[native_pixels]u16) void {
    @memset(v, 0);
    for (0..256) |row| for (0..256) |u| {
        v[(256 + row) * native_width + 256 + u] = @intCast(0x0100 | u);
    };
}

/// The same triangle `gpu_test.zig`'s Phase 3 tests use: (0,0) (64,0) (0,64),
/// u = 0, 240, 0. The ramp page at (256..511, 256..511) is well outside it.
fn rampTriangle(rw: [3]i32) [2]Command {
    var tri: Command = .{
        .kind = .draw_textured_triangle,
        .opcode = 0x25, // raw: no modulation
        .tpage = 0x0100 | 0x0010 | 0x0004, // 16bpp, page (256, 256)
        // Every caller here passes real (non-zero) depths, including the
        // "affine" control that uses three EQUAL reciprocals; `gp0.zig`
        // would set this bit for any of them. Since Phase 4 Task 1, `rw`
        // alone no longer selects the perspective path in Metal.
        .flags = command.flag_texture_perspective,
        .v = .{ vtx(0, 0, 0, 0, 0), vtx(64, 0, 240, 0, 0), vtx(0, 64, 0, 0, 0) },
    };
    for (&tri.v, rw) |*v, w| v.rw = w;
    return .{ fullDrawingArea(), tri };
}

/// The Gouraud counterpart of `rampTriangle`: the same (0,0) (64,0) (0,64)
/// triangle with red carrying the ramp. Red is the low byte of the 24-bit BGR
/// wire colour, so vertex 1 is 0x0000F0 and the other two are 0.
fn shadedRampTriangle(rw: [3]i32, colour_perspective: bool) [2]Command {
    var tri: Command = .{
        .kind = .draw_shaded_triangle,
        .flags = if (colour_perspective) command.flag_color_perspective else 0,
        .v = .{ vtx(0, 0, 0, 0, 0x000000), vtx(64, 0, 0, 0, 0x0000F0), vtx(0, 64, 0, 0, 0x000000) },
    };
    for (&tri.v, rw) |*v, w| v.rw = w;
    return .{ fullDrawingArea(), tri };
}

/// Where two 8x renders differ over the triangle's 64x64 native box, split by
/// whether the subtexel is on the native lattice.
fn latticeSplit(a: Frame, b: Frame) struct { on: usize, off: usize } {
    var on: usize = 0;
    var off: usize = 0;
    const s = a.scale;
    for (0..64 * s) |y| for (0..64 * s) |x| {
        if (a.scaled[y * a.width + x] == b.scaled[y * b.width + x]) continue;
        if (x % s == 0 and y % s == 0) on += 1 else off += 1;
    };
    return .{ .on = on, .off = off };
}

/// Whether anything is painted in the triangle's 64x64 native box.
fn drewInBox(f: Frame) bool {
    for (0..64 * f.scale) |y| for (0..64 * f.scale) |x| {
        if (f.scaled[y * f.width + x] != 0) return true;
    };
    return false;
}

// The scaled path's own gate, and it must reach INSIDE a block: render the
// same triangle at 8x twice, once with a real depth ratio and once with
// three equal reciprocals (which is the affine answer exactly), and require
// them to differ at a subtexel that is NOT on the native lattice. A
// correction applied only at the lattice would be invisible to every gate
// this project has.
test "perspectiveCorrectionReachesTheInteriorOfABlockAtEightX" {
    const m = try harness.metal();
    defer m.deinit();
    const scale = 8;
    const vram = try alloc.create([native_pixels]u16);
    defer alloc.destroy(vram);
    rampVram(vram);
    const affine = try harness.frameOf(alloc, m, scale, .{ .preload = vram }, &rampTriangle(.{ 65536, 65536, 65536 }));
    defer affine.deinit(alloc);
    const persp = try harness.frameOf(alloc, m, scale, .{ .preload = vram }, &rampTriangle(.{ 65536, 16384, 65536 }));
    defer persp.deinit(alloc);

    // Without this the test passes against a shader that refuses the triangle
    // outright, which is a different bug with the same shape.
    try check(drewInBox(affine), "the affine control drew nothing", .{});

    const split = latticeSplit(affine, persp);
    try check(split.on > 0, "the correction did not change the 1x picture at all", .{});
    try check(split.off > 0, "the correction fires only at the native lattice: the one bug no existing gate can see", .{});
}

// The perspective SIGNATURE, read on rows `readbackNative()` never looks at.
//
// A receding surface compresses more texture into fewer screen pixels as it
// recedes, so the texel step GROWS with distance; affine's is uniform by
// construction. Row 8*ny + 4 is the middle of a block, so every sample here
// is one the downsample-invariance gate is blind to by construction.
//
// Measured against the real render before landing this test: at a 16:1
// depth ratio the near-third step is 0.0414 and the far-third step is
// 1.0769; the far end steps ~26x faster than the near end. The affine
// control's near and far steps agreed EXACTLY (difference 0.0), not merely
// within tolerance. `K = 5` below leaves an order of magnitude of headroom
// under the measured ~26x while staying far above the control's noise
// floor; `0.05` is loose against an exact 0.0 but is the right shape for a
// control, since a future change to the flooring could legitimately move it
// by a hair.
test "aPerspectiveRowStepsFasterFarThanNearOffTheLattice" {
    const m = try harness.metal();
    defer m.deinit();
    const scale = 8;
    const vram = try alloc.create([native_pixels]u16);
    defer alloc.destroy(vram);
    rampVram(vram);
    // 16:1 rather than the 4:1 used elsewhere, so the near/far step difference
    // is large enough to read through integer flooring.
    const persp = try harness.frameOf(alloc, m, scale, .{ .preload = vram }, &rampTriangle(.{ 65536, 4096, 65536 }));
    defer persp.deinit(alloc);
    const affine = try harness.frameOf(alloc, m, scale, .{ .preload = vram }, &rampTriangle(.{ 65536, 65536, 65536 }));
    defer affine.deinit(alloc);

    const Row = struct {
        us: [64 * scale]i32 = undefined,
        len: usize = 0,

        /// The sampled `u` at every painted subtexel of one off-lattice row,
        /// left to right. `0x0100 | u` is the texel, so the low byte IS u.
        fn of(f: Frame, y: usize) @This() {
            var r: @This() = .{};
            for (0..64 * scale) |x| {
                const p = f.scaled[y * f.width + x];
                if (p == 0) continue;
                r.us[r.len] = p & 0xFF;
                r.len += 1;
            }
            return r;
        }

        /// Mean step over the first and last thirds of the span. A single
        /// first difference is ±1 noise from the flooring; a third of the
        /// span is not.
        fn nearFar(r: *const @This()) [2]f64 {
            const us = r.us[0..r.len];
            const n = us.len / 3;
            const third: f64 = @floatFromInt(n);
            const near = @as(f64, @floatFromInt(us[n] - us[0])) / third;
            const far = @as(f64, @floatFromInt(us[us.len - 1] - us[us.len - 1 - n])) / third;
            return .{ near, far };
        }
    };

    const y = 4; // inside native row 0, off the lattice
    const pu = Row.of(persp, y);
    const au = Row.of(affine, y);
    try check(pu.len > 30, "too few painted subtexels on row {d} to read a trend", .{y});
    try check(pu.len == au.len, "the two renders disagree on coverage, not just on sampling", .{});

    const p = pu.nearFar();
    const a = au.nearFar();
    // Affine is the control: its step is uniform, so near and far agree.
    try check(@abs(a[0] - a[1]) < 0.05, "the affine control is not uniform: near {d}, far {d}", .{ a[0], a[1] });
    // Perspective on a receding surface steps faster far than near: a
    // receding surface compresses more texture into fewer screen pixels with
    // distance. K = 5 leaves an order of magnitude of headroom under the
    // measured ~26x separation while staying far above noise.
    try check(p[1] > p[0] * 5, "no perspective trend off the lattice: near {d}, far {d}", .{ p[0], p[1] });
}

// The same arithmetic `gpu_test.zig`'s "hand-computed perspective value" test
// pins, read back from Metal: the two rasterizers evaluate one expression over
// identical integers, so this is an equality with a number worked on paper
// rather than a comparison against our own other implementation.
test "aGouraudTriangleShadesTheHandComputedPerspectiveValueInMetal" {
    const m = try harness.metal();
    defer m.deinit();
    const persp = try harness.frameOf(alloc, m, 1, .{}, &shadedRampTriangle(.{ 65536, 16384, 65536 }, true));
    defer persp.deinit(alloc);
    const affine = try harness.frameOf(alloc, m, 1, .{}, &shadedRampTriangle(.{ 65536, 16384, 65536 }, false));
    defer affine.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 6), persp.native[16 * 1024 + 32]);
    try std.testing.expectEqual(@as(u16, 15), affine.native[16 * 1024 + 32]);
}

// The scaled path's own gate, the Gouraud copy of
// `perspectiveCorrectionReachesTheInteriorOfABlockAtEightX`. A correction
// applied only at the lattice would be invisible to every gate this project
// has.
test "colourCorrectionReachesTheInteriorOfABlockAtEightX" {
    const m = try harness.metal();
    defer m.deinit();
    const scale = 8;
    const affine = try harness.frameOf(alloc, m, scale, .{}, &shadedRampTriangle(.{ 65536, 16384, 65536 }, false));
    defer affine.deinit(alloc);
    const persp = try harness.frameOf(alloc, m, scale, .{}, &shadedRampTriangle(.{ 65536, 16384, 65536 }, true));
    defer persp.deinit(alloc);

    // Without this the test passes against a shader that refuses the triangle
    // outright, which is a different bug with the same shape.
    try check(drewInBox(affine), "the affine control drew nothing", .{});

    const split = latticeSplit(affine, persp);
    try check(split.on > 0, "the correction did not change the 1x picture at all", .{});
    try check(split.off > 0, "the correction fires only at the native lattice: the one bug no existing gate can see", .{});
}
