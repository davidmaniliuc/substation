//! Phase C's gate ladder, ported from MetalScaleTests.swift. Gate 1 (Metal ==
//! Zig at 1x) lives in rasterizer_test.zig and mover_test.zig and is a
//! FREEZE: nothing here may move it. What these tests add is Gate 2
//! (downsample-invariance) and Gate 2b (bounds, the clip conversion and
//! coverage density) over the untextured paths. The sampling paths, movers
//! and real-game fixtures are in scale_sampling_test.zig, the sub-pixel and
//! perspective cases in scale_geometry_test.zig, Gates 3 and 4 in
//! scale_gate_test.zig.

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
const native_height = pi.native_height;
const native_pixels = pi.native_pixels;
const scale_ladder = harness.scale_ladder;
const painted = harness.painted;
const vtx = harness.vtx;
const env = harness.env;
const fullDrawingArea = harness.fullDrawingArea;
const check = harness.check;

const Bounds = struct { min_x: usize, max_x: usize, min_y: usize, max_y: usize, count: usize };

/// The extent of every non-zero scaled pixel.
fn bounds(f: Frame) Bounds {
    var b: Bounds = .{ .min_x = std.math.maxInt(usize), .max_x = 0, .min_y = std.math.maxInt(usize), .max_y = 0, .count = 0 };
    for (0..f.height) |y| for (0..f.width) |x| {
        if (f.scaled[y * f.width + x] == 0) continue;
        b.min_x = @min(b.min_x, x);
        b.max_x = @max(b.max_x, x);
        b.min_y = @min(b.min_y, y);
        b.max_y = @max(b.max_y, y);
        b.count += 1;
    };
    return b;
}

test "aFillPaintsExactlyItsScaledBoxAndNothingElse" {
    // ps1_fill_fragment has no coverage test, no clip and no mask, so whatever
    // region it paints IS the quad ps1_vertex emitted. That isolates the
    // vertex shader: this test fails for a wrong box expansion and for nothing
    // else.
    const m = try harness.metal();
    defer m.deinit();
    const scale = 4;
    const fill: Command = .{ .kind = .fill_rect, .x = 10, .y = 20, .w = 20, .h = 20, .value = 0x7C1F };
    const f = try harness.frameOf(alloc, m, scale, .{}, &.{fill});
    defer f.deinit(alloc);

    const b = bounds(f);
    // The box is INCLUSIVE (10,20)-(29,39), so the scaled span is
    // [10*s, (29+1)*s - 1]: the same +1 the vertex shader applies, and the
    // same one the drawing-area clip needs.
    try std.testing.expectEqual(10 * scale, b.min_x);
    try std.testing.expectEqual(30 * scale - 1, b.max_x);
    try std.testing.expectEqual(20 * scale, b.min_y);
    try std.testing.expectEqual(40 * scale - 1, b.max_y);
    try std.testing.expectEqual(20 * scale * 20 * scale, b.count);
    try std.testing.expectEqual(20 * 20, painted(f.native));
}

test "aFillIsDownsampleInvariantAtEveryScale" {
    // The first instance of the property the whole phase is built on, on the
    // one path that is complete on its own. An odd, prime-ish extent
    // (33 x 17) so no scale divides it evenly.
    const m = try harness.metal();
    defer m.deinit();
    const fill: Command = .{ .kind = .fill_rect, .x = 7, .y = 11, .w = 33, .h = 17, .value = 0x03E0 };
    try harness.expectRecordsInvariant(m, .{}, &.{fill}, &scale_ladder);
}

// MARK: Gate 2b: bounds, the clip conversion, and coverage density

/// Gate 2b, bounds half. Every non-zero scaled pixel must lie inside some
/// instance's scaled box: intersected with that instance's scaled drawing
/// area for the seven DRAWING kinds. The three movers carry no clip: their
/// instances are zero-initialized by the encoder and the shader never applies
/// one to them.
fn expectNothingOutsideTheScaledBoxes(f: Frame, label: []const u8) !void {
    const s: i64 = f.scale;
    const allowed = try alloc.alloc(bool, f.width * f.height);
    defer alloc.free(allowed);
    @memset(allowed, false);
    for (f.instances) |inst| {
        var x0: i64 = @as(i64, inst.box_x0) * s;
        var x1: i64 = (@as(i64, inst.box_x1) + 1) * s - 1;
        var y0: i64 = @as(i64, inst.box_y0) * s;
        var y1: i64 = (@as(i64, inst.box_y1) + 1) * s - 1;
        if (inst.kind <= pi.Kind.shaded_line_pixel) {
            x0 = @max(x0, @as(i64, inst.clip_x0) * s);
            x1 = @min(x1, (@as(i64, inst.clip_x1) + 1) * s - 1);
            y0 = @max(y0, @as(i64, inst.clip_y0) * s);
            y1 = @min(y1, (@as(i64, inst.clip_y1) + 1) * s - 1);
        }
        if (x0 > x1 or y0 > y1) continue;
        var y = y0;
        while (y <= y1) : (y += 1) {
            const row: usize = @intCast(y * @as(i64, @intCast(f.width)));
            @memset(allowed[row + @as(usize, @intCast(x0)) ..][0..@intCast(x1 - x0 + 1)], true);
        }
    }
    var strays: usize = 0;
    var first: ?usize = null;
    for (f.scaled, allowed, 0..) |p, ok, i| {
        if (p == 0 or ok) continue;
        if (first == null) first = i;
        strays += 1;
    }
    if (first) |i| std.debug.print("{s}: {d} px outside every scaled box, first ({d},{d})={X:0>4}\n", .{ label, strays, i % f.width, i / f.width, f.scaled[i] });
    try std.testing.expectEqual(0, strays);
}

/// Gate 2b, density half.
///
/// The spec proposes a tolerance of `perimeter * s`; that bound is not
/// provable: a native covered pixel on a primitive's boundary can have
/// anywhere from 1 to s*s of its subpixels covered, so the per-boundary-pixel
/// error is O(s^2), not O(s). What the check exists to catch is two gross
/// failures Gate 2 is blind to, because Gate 2 constrains only the top-left
/// subtexel of each block:
///
///   - every OTHER subpixel left black  -> ratio ~ 1/s^2, at most 0.25
///   - the whole bounding box painted    -> ratio well above 1.6
///
/// so a ratio band catches both with a wide margin on these three frames,
/// whose primitives are chunky triangles and exact-by-construction rectangles
/// and line pixels. `perimeter` is still computed and printed: it is the
/// number that says how much slack the band actually has.
fn expectCoverageDensity(one_x: []const u16, f: Frame, label: []const u8) !void {
    const n1 = painted(one_x);
    if (n1 == 0) {
        std.debug.print("{s}: the 1x replay drew nothing\n", .{label});
        return error.TestUnexpectedResult;
    }
    const w = native_width;
    const h = native_height;
    var perimeter: usize = 0;
    for (0..h) |y| for (0..w) |x| {
        if (one_x[y * w + x] == 0) continue;
        const up = y == 0 or one_x[(y - 1) * w + x] == 0;
        const down = y == h - 1 or one_x[(y + 1) * w + x] == 0;
        const left = x == 0 or one_x[y * w + x - 1] == 0;
        const right = x == w - 1 or one_x[y * w + x + 1] == 0;
        if (up or down or left or right) perimeter += 1;
    };
    const n_n = painted(f.scaled);
    const expected: f64 = @floatFromInt(n1 * f.scale * f.scale);
    const ratio = @as(f64, @floatFromInt(n_n)) / expected;
    std.debug.print("[gate-2b] {s}: n1={d} perimeter={d} nN={d} ratio={d:.4}\n", .{ label, n1, perimeter, n_n, ratio });
    if (!(ratio >= 0.6 and ratio <= 1.6)) {
        std.debug.print("{s}: coverage ratio {d} outside [0.6, 1.6]\n", .{ label, ratio });
        return error.TestUnexpectedResult;
    }
}

/// Gate 2b runs at these scales only. The bounds half allocates and scans one
/// bool per scaled pixel, which is 33.5M at scale 8: for three frames on
/// every run of the suite. Scale 8's bounds are covered instead by
/// `theDrawingAreaClipScalesAsAnInclusiveBound` (the specific off-by-one this
/// gate exists for) and by Gate 2 at scale 8.
const gate2b_scales = [_]u32{ 2, 3, 4 };

test "theDrawingAreaClipScalesAsAnInclusiveBound" {
    // The native drawing area is INCLUSIVE, so the scaled test is
    // `px > (x1 + 1) * s - 1`, not `px > x1 * s`. The two agree at every
    // top-left subtexel (which is exactly the set Gate 1 and Gate 2 compare),
    // so neither can see the difference; the wrong form silently drops the
    // last (s - 1) columns and rows of every clipped primitive.
    //
    // A flat rectangle is the subject because it is covered by construction:
    // no edge function participates, so the extent of what lands in VRAM is
    // decided by the clip and by nothing else.
    const m = try harness.metal();
    defer m.deinit();
    const scale = 4;
    const f = try harness.frameOf(alloc, m, scale, .{}, &.{
        env(0xE3, (100 << 10) | 100), // top-left (100, 100)
        env(0xE4, (130 << 10) | 140), // bottom-right (140, 130), INCLUSIVE
        // Overflows all four sides.
        .{ .kind = .draw_rectangle, .x = 90, .y = 90, .w = 80, .h = 80, .value = 0x7FFF },
    });
    defer f.deinit(alloc);

    const b = bounds(f);
    try std.testing.expectEqual(100 * scale, b.min_x); // 400
    try std.testing.expectEqual((140 + 1) * scale - 1, b.max_x); // 563, NOT 140 * 4 == 560
    try std.testing.expectEqual(100 * scale, b.min_y); // 400
    try std.testing.expectEqual((130 + 1) * scale - 1, b.max_y); // 523, NOT 130 * 4 == 520
}

test "aFullVramGouraudTriangleDoesNotOverflowTheInterpolator" {
    // ps1_interp's numerator is bounded by area * 255. An oversized-capped
    // primitive reaches about 2.13e9, 1% under int32's ceiling. This triangle
    // is 1022 x 510, the largest the oversized refusal admits, with the full
    // 0..255 colour range, so a shader that kept `int` intermediates wraps
    // here and nowhere else in the corpus.
    const m = try harness.metal();
    defer m.deinit();
    const tri: Command = .{ .kind = .draw_shaded_triangle, .v = .{
        vtx(0, 0, 0, 0, 0x00FF_FFFF),
        vtx(1022, 0, 0, 0, 0x0000_00FF),
        vtx(0, 510, 0, 0, 0x00FF_0000),
    } };
    try harness.expectRecordsInvariant(m, .{}, &.{ fullDrawingArea(), tri }, &.{ 4, 8 });
}

// Two triangles sharing a SHALLOW edge must tile it with no crack, at every
// internal resolution: checked over the FULL scaled buffer, not at top-left
// subtexels.
//
// This is the one thing downsample-invariance cannot see. It samples one
// subtexel per native pixel, and a fill-rule bias that erodes a fraction of a
// pixel from every top-left edge leaves those subtexels alone while carving a
// crack through the ones between them. In a game it reads as a bright dashed
// seam along every shared edge, because whatever was drawn earlier shows
// through.
//
// Shallow on purpose. The erosion a bias of B costs is B divided by the edge
// function's gradient per subtexel, which is |dy| * 16 / s q-units, so a 45°
// edge hides the bug completely and only a nearly-horizontal one exposes it.
// This edge rises 1 px over 390, which at 8x puts the gradient at 32 q-units
// per subtexel: a bias of PS1_Q_BIAS_SCALE would eat eight of them, a whole
// native pixel.
test "twoTrianglesSharingAShallowEdgeLeaveNoCrackAtAnyScale" {
    const m = try harness.metal();
    defer m.deinit();
    const background: u16 = 0x7C1F;
    const fill: u16 = 0x03E0;

    const preload = try alloc.create([native_pixels]u16);
    defer alloc.destroy(preload);
    @memset(preload, 0);
    for (0..80) |y| @memset(preload[y * native_width ..][0..512], background);

    // The shared edge runs (10, 30) -> (400, 31); one triangle sits above it
    // and one below, and they traverse it in opposite directions, which is
    // what makes the fill rule award each pixel on it to exactly one of them.
    const tri = struct {
        fn f(a: [2]i16, b: [2]i16, c: [2]i16) Command {
            return .{ .kind = .draw_triangle, .value = fill, .v = .{ vtx(a[0], a[1], 0, 0, 0), vtx(b[0], b[1], 0, 0, 0), vtx(c[0], c[1], 0, 0, 0) } };
        }
    }.f;
    const records = [_]Command{
        fullDrawingArea(),
        tri(.{ 10, 30 }, .{ 400, 31 }, .{ 200, 5 }),
        tri(.{ 400, 31 }, .{ 10, 30 }, .{ 200, 60 }),
    };

    var failed = false;
    for ([_]u32{1} ++ scale_ladder) |scale| {
        const f = try harness.frameOf(alloc, m, scale, .{ .preload = preload }, &records);
        defer f.deinit(alloc);
        // A band straddling the shared edge, well inside the union's other
        // four edges at both ends, so only the shared one is under test.
        var survivors: usize = 0;
        var first: [2]usize = .{ 0, 0 };
        for (28..35) |ny| for (60..351) |nx| for (0..scale) |sy| for (0..scale) |sx| {
            const x = nx * scale + sx;
            const y = ny * scale + sy;
            if (f.scaled[y * f.width + x] != background) continue;
            if (survivors == 0) first = .{ x, y };
            survivors += 1;
        };
        if (survivors != 0) {
            std.debug.print("@{d}x: {d} uncovered subtexels, first at ({d}, {d})\n", .{ scale, survivors, first[0], first[1] });
            failed = true;
        }
    }
    try std.testing.expect(!failed);
}

// MARK: Gate 2: downsample-invariance, untextured

test "theUntexturedPeterLemonRomsAreDownsampleInvariant" {
    const m = try harness.metal();
    defer m.deinit();
    try harness.expectInvariantWherePresent(m, &harness.untextured_pl_fixtures);
}

test "theDepthRungIsDownsampleInvariant" {
    // Frame 8, the depth rung, needs a persistent depth attachment for the
    // same reason Gate 1's frame-8 test does. This is Gate 2 over the same
    // prefix: the backend must agree with ITSELF at every scale, not just
    // with the software rasterizer.
    const m = try harness.metal();
    defer m.deinit();
    try harness.expectInvariant(m, "synthetic-primitives", .{ .up_to = 9, .depth_buffer = true });
}

test "theUntexturedSyntheticFramesAreDownsampleInvariant" {
    // Frames 0 and 1 are flat and Gouraud triangles and can be replayed
    // cumulatively. Frame 2 uploads three texture pages and a CLUT, so the
    // cumulative replay stops before it.
    const m = try harness.metal();
    defer m.deinit();
    try harness.expectInvariant(m, "synthetic-primitives", .{ .up_to = 2 });

    // Frames 3 (rectangles) and 5 (lines) each open with their own E3/E4/E5,
    // so a from-blank single-frame replay of either is well defined and skips
    // the upload frames between them.
    for ([_]usize{ 3, 5 }) |frame| {
        const one = try harness.fixtureFrame(alloc, m, "synthetic-primitives", frame, 1);
        defer one.deinit(alloc);
        for (scale_ladder) |scale| {
            const many = try harness.fixtureFrame(alloc, m, "synthetic-primitives", frame, scale);
            defer many.deinit(alloc);
            var label: [32]u8 = undefined;
            try harness.expectSameNative(one, many, try std.fmt.bufPrint(&label, "frame {d} @{d}x", .{ frame, scale }));
        }
    }
}

test "theUntexturedSyntheticFramesRespectTheirScaledBoxesAndCoverTheirBlocks" {
    // Gate 2 constrains only the top-left subtexel of each block, so a bug
    // that left every other subpixel black would pass it and look
    // catastrophic. This is what catches that mechanically.
    const m = try harness.metal();
    defer m.deinit();
    var failed = false;
    for ([_]usize{ 0, 3, 5 }) |frame| {
        const one = try harness.fixtureFrame(alloc, m, "synthetic-primitives", frame, 1);
        defer one.deinit(alloc);
        for (gate2b_scales) |scale| {
            const f = try harness.fixtureFrame(alloc, m, "synthetic-primitives", frame, scale);
            defer f.deinit(alloc);
            var buf: [32]u8 = undefined;
            const label = try std.fmt.bufPrint(&buf, "frame {d} @{d}x", .{ frame, scale });
            expectNothingOutsideTheScaledBoxes(f, label) catch {
                failed = true;
            };
            expectCoverageDensity(one.native, f, label) catch {
                failed = true;
            };
        }
    }
    try std.testing.expect(!failed);
}
