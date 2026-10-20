//! `ps1-bench-gpu`: the renderer benchmark's command line.
//!
//!   ps1-bench-gpu <fixture>[,<fixture>…] [--scales=1,4,6,8] [--repeats=5]
//!     [--dither=true-color|native|scaled|off] [--filter=nearest|bilinear]
//!     [--sprite-filter=nearest|bilinear]
//!
//! Run from the repo root: fixtures are read from
//! `ps1-core/tests/goldens/fixtures/` and `zig-out/fixtures/`. Prints one line
//! per (fixture, scale, config) in the Swift benchmark's format.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const gpu_bench = @import("gpu_bench.zig");

const mtl = ps1_metal.mtl;
const fixture_corpus = ps1_metal.fixture_corpus;

const usage =
    \\usage: ps1-bench-gpu <fixture>[,<fixture>...] [--scales=1,4,6,8] [--repeats=5]
    \\         [--dither=true-color|native|scaled|off] [--filter=nearest|bilinear]
    \\         [--sprite-filter=nearest|bilinear]
    \\
;

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.smp_allocator;
    const io = init.io;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    var it = init.minimal.args.iterate();
    _ = it.skip();
    while (it.next()) |a| try argv.append(alloc, a);

    const args = gpu_bench.Args.parse(alloc, argv.items) catch |err| fail("{s}\n" ++ usage, .{@errorName(err)});
    defer args.deinit(alloc);

    // Every fixture is checked before any is timed: a typo found after
    // minutes of measuring is minutes lost.
    for (args.fixtures) |name| {
        const path = try fixture_corpus.path(alloc, io, name);
        defer alloc.free(path);
        std.Io.Dir.cwd().access(io, path, .{}) catch fail(
            "fixture {s} not found in {s}/ or {s}/; run `zig build fixtures -Doptimize=ReleaseFast` from the repo root\n",
            .{ name, fixture_corpus.committed_dir, fixture_corpus.generated_dir },
        );
        if (!fixture_corpus.currentFormat(io, path)) fail(
            "{s} is not a version-{d} fixture; regenerate it with `zig build fixtures -Doptimize=ReleaseFast`\n",
            .{ path, ps1_metal.fixture.version },
        );
    }

    const device = mtl.Device.createSystemDefault() orelse fail("no Metal device\n", .{});
    defer device.release();
    const queue = device.newCommandQueue() orelse fail("no Metal command queue\n", .{});
    defer queue.release();
    const lib = try ps1_metal.shaders.makeLibrary(device);
    defer lib.release();

    const results = try gpu_bench.run(alloc, io, .{ .device = device, .queue = queue, .lib = lib }, .{
        .fixtures = args.fixtures,
        .scales = args.scales,
        .configs = &.{args.config},
        .repeats = args.repeats,
    });
    defer alloc.free(results);

    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    for (results) |r| try out.interface.print("{f}\n", .{r});
    try out.interface.flush();
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("[gpu-bench] " ++ fmt, args);
    std.process.exit(1);
}
