//! PGXP-ON PARITY, at STRICT equality: the gate that proves the shared
//! integer perspective path. Ported from PgxpParityTests.swift.
//!
//! Every other fixture in the corpus was captured with PGXP off, so every `rw`
//! in them is zero and every textured triangle takes the affine branch: the
//! perspective interpolant is entirely uncovered by Gate 1 and Gate 2. This
//! fixture is the same 100-frame Tomb Raider window captured with PGXP on, so
//! its textured triangles carry real reciprocal depths and its per-frame VRAM
//! hashes are the software rasterizer's answer to them.
//!
//! It is a STRICT equality rather than a tolerance only because the
//! interpolant is exact: every term is an integer and the division is an
//! integer division, so the two rasterizers evaluate one expression over
//! identical inputs and agree by construction. No float formulation could
//! offer this, and it matters because the comparison is a HASH: under float,
//! one ULP anywhere is a red gate with no diagnostic.
//!
//! Skipped, and named, when the fixture is absent (`harness.loadFixture`): it
//! needs `zig build fixtures -Doptimize=ReleaseFast` and a `games/` directory.

const std = @import("std");
const ps1_core = @import("ps1_core");
const harness = @import("harness.zig");

const command = ps1_core.gpu.command;
const check = harness.check;
const alloc = std.testing.allocator;

const fixture_name = "tr1-usa-v1-1-pgxp";

test "aPgxpOnCaptureReplaysBitExactlyInMetal" {
    // `depth_buffer` since Phase 5: `--pgxp-on` now forces every depth
    // sub-setting on too, so this capture carries real depth-tested triangles
    // and `clear_depth` records; a memoryless depth attachment would lose
    // them across this capture's many pass breaks.
    const m = try harness.metal();
    defer m.deinit();
    const r = try harness.replay(alloc, m, fixture_name, .{ .depth_buffer = true });
    defer r.deinit(alloc);
    try check(r.first_divergence == null, "{s}", .{r.message});
    try std.testing.expectEqual(@as(usize, 100), r.frames_checked);
}

// The gate above is worthless if the capture carried no perspective
// triangles: a fixture recorded with PGXP accidentally off would pass it
// trivially, by taking exactly the affine path Gate 1 already covers.
test "thePgxpParityFixtureActuallyCarriesPerspectiveTriangles" {
    const parsed = try harness.loadFixture(alloc, fixture_name);
    defer parsed.deinit(alloc);
    var perspective: usize = 0;
    for (parsed.records) |c| {
        if (c.kind != .draw_textured_triangle) continue;
        if (c.v[0].rw != 0 and c.v[1].rw != 0 and c.v[2].rw != 0) perspective += 1;
    }
    try check(perspective > 1000, "only {d} perspective triangles; was the capture really --pgxp-on?", .{perspective});
}

// The depth half of the same guard: a fixture captured before `--pgxp-on`
// forced the depth settings would pass the strict-equality gate trivially.
test "thePgxpParityFixtureActuallyCarriesDepthTestedTriangles" {
    const parsed = try harness.loadFixture(alloc, fixture_name);
    defer parsed.deinit(alloc);
    var tested: usize = 0;
    var clears: usize = 0;
    for (parsed.records) |c| {
        if (c.flags & command.flag_depth_test != 0) tested += 1;
        if (c.kind == .clear_depth) clears += 1;
    }
    try check(tested > 1000, "only {d} depth-tested triangles; was the capture really --pgxp-on?", .{tested});
    try check(clears > 0, "no clear_depth record in the capture", .{});
}

// The colour half of the same guard the test above applies to texcoords: a
// fixture captured before `--pgxp-on` learned the sub-settings would pass the
// strict-equality gate trivially, by taking the affine colour path Gate 1
// already covers.
//
// Counts GOURAUD triangles specifically (both the untextured kind and the
// Gouraud-textured one), because those are the only records that can carry
// the colour bit at all.
test "thePgxpParityFixtureCarriesColourCorrectedTriangles" {
    const parsed = try harness.loadFixture(alloc, fixture_name);
    defer parsed.deinit(alloc);
    var corrected: usize = 0;
    for (parsed.records) |c| {
        if (c.kind != .draw_shaded_triangle and c.kind != .draw_textured_triangle) continue;
        if (c.flags & command.flag_color_perspective != 0) corrected += 1;
    }
    try check(corrected > 100, "only {d} colour-corrected triangles; did --pgxp-on enable the sub-settings?", .{corrected});
}
