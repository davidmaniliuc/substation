//! The Metal speculation gate: a replay that runs two frames ahead after
//! every frame, as runahead does, and puts them back, must leave the
//! real-timeline texture exactly as a plain replay leaves it. Ported from
//! SpeculationTests.swift.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const harness = @import("harness.zig");
const lh = @import("live_harness.zig");

const objc = ps1_metal.objc;
const LiveRenderer = ps1_metal.live_renderer.LiveRenderer;

const alloc = std.testing.allocator;
const check = harness.check;

const fixtures = [_][]const u8{ "synthetic-primitives", "synthetic-movers", "croc-legend-of-the-gobbos", "crash-bandicoot-warped" };
const ahead = 2;

test "LiveRenderer: speculationLeavesTheRealTimelineUntouched" {
    const m = try harness.metal();
    defer m.deinit();

    var gated: usize = 0;
    for (fixtures) |name| {
        const parsed = harness.loadFixture(alloc, name) catch |err| switch (err) {
            error.SkipZigTest => continue,
            else => return err,
        };
        defer parsed.deinit(alloc);
        for ([_]u32{ 1, 2 }) |scale| try expectUntouched(m, name, parsed, scale);
        gated += 1;
    }
    if (gated == 0) return error.SkipZigTest;
}

fn expectUntouched(m: harness.Metal, name: []const u8, parsed: ps1_metal.fixture.Parsed, scale: u32) !void {
    const n = parsed.frames.len;
    const plain = try lh.make(m, scale, false);
    defer plain.deinit();
    const spec = try lh.make(m, scale, false);
    defer spec.deinit();
    const q1 = try lh.queue();
    defer q1.deinit();
    const q2 = try lh.queue();
    defer q2.deinit();

    for (0..n) |i| {
        const pool = objc.Pool.push();
        defer pool.pop();
        const seq: u64 = i + 1;
        q1.publish(seq, parsed.frameStream(i));
        _ = q2.stage(seq, parsed.frameStream(i));
        q2.beginSpeculativeGroup(seq);
        for (i + 1..@min(i + 1 + ahead, n)) |j| q2.appendSpeculative(parsed.frameStream(j));
        q2.commitSpeculativeGroup(.{});
        q2.commitStaged();

        var shadow: lh.Shadow = .{};
        plain.drain(q1, &shadow);
        spec.drain(q2, &shadow);
        if (i + 1 < n) try check(spec.present_display != null, "{s} {d}x frame {d}: no speculation", .{ name, scale, i });
        spec.settleSpeculation();
        try check(spec.vram.hash() == plain.vram.hash(), "{s} at {d}x: frame {d} differs after speculating", .{ name, scale, i });
    }

    const want = try alloc.alloc(u8, plain.vram.pixelCount() * 4);
    defer alloc.free(want);
    const got = try alloc.alloc(u8, spec.vram.pixelCount() * 4);
    defer alloc.free(got);
    plain.vram.readbackSidecar(want);
    spec.vram.readbackSidecar(got);
    try check(std.mem.eql(u8, want, got), "{s} at {d}x: sidecar differs", .{ name, scale });
}
