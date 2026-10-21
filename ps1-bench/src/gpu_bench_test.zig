//! `ps1-bench-gpu`'s tests. Part of `test-metal`: the benchmark needs a
//! device and the shader library, and skips without them.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const gpu_bench = @import("gpu_bench.zig");

const alloc = std.testing.allocator;
const io = std.testing.io;

// The benchmark is a measuring instrument: the one property worth pinning is
// that it actually replays frames and reports a positive GPU time, so a
// silently empty run (a missing fixture, a hook never called) cannot read as
// "infinitely fast".
test "theBenchmarkReplaysEveryFrameAndTimesTheGpu" {
    // A headless runner has no device: a skip that says why, as the
    // harness's `metal()` does (it lives under ps1-metal/tests/, out of reach).
    const gpu = ps1_metal.metal_context.Metal.open() catch |err| switch (err) {
        error.NoMetalDevice => {
            std.debug.print("no Metal device\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer gpu.deinit();

    // Committed under ps1-core/tests/goldens/fixtures, so it is never
    // missing; if it were, the skip names it rather than failing.
    const parsed = ps1_metal.fixture_corpus.load(alloc, io, "synthetic-primitives") catch |err| switch (err) {
        error.FixtureNotFound => {
            std.debug.print("fixture synthetic-primitives not found\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer parsed.deinit(alloc);

    const results = try gpu_bench.run(alloc, io, gpu, .{
        .fixtures = &.{"synthetic-primitives"},
        .scales = &.{1},
        .configs = &.{.{}},
        .repeats = 1,
    });
    defer alloc.free(results);
    try std.testing.expectEqual(1, results.len);
    const r = results[0];
    try std.testing.expectEqual(parsed.frames.len, r.frames);
    try std.testing.expectEqual(1, r.scale);
    try std.testing.expect(r.gpu_ms > 0);
    try std.testing.expect(r.cpu_ms > 0);
    try std.testing.expect(r.fps > 0);
}

// The line is what Plan C compares against the Swift benchmark's, so it is
// the Swift `Result.line` byte for byte.
test "theBenchmarkLineIsTheSwiftFormat" {
    const r: gpu_bench.Result = .{
        .fixture = "silent-hill-usa",
        .scale = 4,
        .config = "current",
        .gpu_ms = 8.514,
        .cpu_ms = 1.35,
        .fps = 113.46,
        .frames = 100,
    };
    var buf: [160]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "{f}", .{r});
    try std.testing.expectEqualStrings(
        "[gpu-bench] silent-hill-usa          4x current    gpu   8.51 ms  cpu   1.35 ms   113.5 fps  (100 frames)",
        line,
    );
}

test "theBenchmarkArgumentsDefaultToTheShippedSettings" {
    const a = try gpu_bench.Args.parse(alloc, &.{"crash-bandicoot-warped,tr1-usa-v1-1"});
    defer a.deinit(alloc);
    try std.testing.expectEqual(2, a.fixtures.len);
    try std.testing.expectEqualStrings("tr1-usa-v1-1", a.fixtures[1]);
    try std.testing.expectEqualSlices(u32, &.{ 1, 4, 6, 8 }, a.scales);
    try std.testing.expectEqual(5, a.repeats);
    try std.testing.expectEqual(.true_color, a.config.dither);
    try std.testing.expectEqual(.bilinear, a.config.filter);
    try std.testing.expectEqual(.nearest, a.config.sprite_filter);

    const b = try gpu_bench.Args.parse(alloc, &.{ "x", "--scales=2,3", "--repeats=1", "--dither=native", "--filter=nearest", "--sprite-filter=bilinear" });
    defer b.deinit(alloc);
    try std.testing.expectEqualSlices(u32, &.{ 2, 3 }, b.scales);
    try std.testing.expectEqual(1, b.repeats);
    try std.testing.expectEqual(.native, b.config.dither);
    try std.testing.expectEqual(.nearest, b.config.filter);
    try std.testing.expectEqual(.bilinear, b.config.sprite_filter);

    try std.testing.expectError(error.BadScale, gpu_bench.Args.parse(alloc, &.{ "x", "--scales=9" }));
    try std.testing.expectError(error.BadDither, gpu_bench.Args.parse(alloc, &.{ "x", "--dither=pretty" }));
    try std.testing.expectError(error.NoFixtures, gpu_bench.Args.parse(alloc, &.{}));
}
