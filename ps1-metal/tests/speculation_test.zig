//! The Metal speculation gate: a replay that runs two frames ahead after
//! every frame, as runahead does, and puts them back, must leave the
//! real-timeline texture exactly as a plain replay leaves it.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const ps1_core = @import("ps1_core");
const harness = @import("harness.zig");
const lh = @import("live_harness.zig");

const objc = ps1_metal.objc;
const LiveRenderer = ps1_metal.live_renderer.LiveRenderer;
const Command = ps1_core.gpu.command.Command;
const Stream = ps1_core.gpu.command.Stream;

const alloc = std.testing.allocator;
const check = harness.check;

const fixtures = [_][]const u8{ "synthetic-primitives", "synthetic-movers", "croc-legend-of-the-gobbos", "crash-bandicoot-warped" };
const ahead = 2;

test "LiveRenderer: speculationLeavesTheRealTimelineUntouched" {
    const m = try harness.metal();
    defer m.deinit();

    // Every fixture and scale is gated before the test fails, so one red
    // run names all of them rather than the first.
    var gated: usize = 0;
    var failed: usize = 0;
    for (fixtures) |name| {
        const parsed = harness.loadFixture(alloc, name) catch |err| switch (err) {
            error.SkipZigTest => continue,
            else => return err,
        };
        defer parsed.deinit(alloc);
        for ([_]u32{ 1, 2 }) |scale| expectUntouched(m, name, parsed, scale) catch |err| switch (err) {
            error.TestUnexpectedResult => failed += 1,
            else => return err,
        };
        gated += 1;
    }
    if (gated == 0) return error.SkipZigTest;
    try check(failed == 0, "{d} fixture/scale pairs left the real timeline changed", .{failed});
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

test "LiveRenderer: aGroupCutIntoChunksReplaysAndRestoresLikeAWholeOne" {
    const m = try harness.metal();
    defer m.deinit();

    // Only a frame with an upload to cut gates anything.
    var cuts: usize = 0;
    for (fixtures) |name| {
        const parsed = harness.loadFixture(alloc, name) catch |err| switch (err) {
            error.SkipZigTest => continue,
            else => return err,
        };
        defer parsed.deinit(alloc);
        cuts += try expectCutLikeWhole(m, name, parsed);
    }
    if (cuts == 0) return error.SkipZigTest;
}

/// A frame cut in two inside its first upload run longer than one word, as
/// a GPU-only flush cuts it: the second half continues as a bare
/// `vram_write_data`. Null when the frame has no such run.
const Cut = struct {
    head: []Command,
    tail: []Command,
    payload: []const u32,

    fn of(s: Stream) !?Cut {
        const at = for (s.records, 0..) |r, i| {
            if (r.kind == .vram_write_data and r.y >= 2) break i;
        } else return null;
        const run = s.records[at];
        const k = @divTrunc(run.y, 2);
        const head = try alloc.alloc(Command, at + 1);
        errdefer alloc.free(head);
        @memcpy(head[0..at], s.records[0..at]);
        head[at] = run;
        head[at].y = k;
        const tail = try alloc.alloc(Command, s.records.len - at);
        @memcpy(tail[1..], s.records[at + 1 ..]);
        tail[0] = run;
        tail[0].x = run.x + k;
        tail[0].y = run.y - k;
        return .{ .head = head, .tail = tail, .payload = s.payload };
    }

    fn deinit(self: Cut) void {
        alloc.free(self.head);
        alloc.free(self.tail);
    }

    fn stream(self: Cut, records: []const Command) Stream {
        return .{ .records = records, .payload = self.payload, .complete = true };
    }
};

/// Returns how many frames had an upload to cut.
fn expectCutLikeWhole(m: harness.Metal, name: []const u8, parsed: ps1_metal.fixture.Parsed) !usize {
    const n = parsed.frames.len;
    const plain = try lh.make(m, 1, false);
    defer plain.deinit();
    const whole = try lh.make(m, 1, false);
    defer whole.deinit();
    const cut = try lh.make(m, 1, false);
    defer cut.deinit();
    const q1 = try lh.queue();
    defer q1.deinit();
    const q2 = try lh.queue();
    defer q2.deinit();
    const q3 = try lh.queue();
    defer q3.deinit();

    var cuts: usize = 0;
    for (0..n) |i| {
        const pool = objc.Pool.push();
        defer pool.pop();
        const seq: u64 = i + 1;
        q1.publish(seq, parsed.frameStream(i));
        _ = q2.stage(seq, parsed.frameStream(i));
        _ = q3.stage(seq, parsed.frameStream(i));
        q2.beginSpeculativeGroup(seq);
        q3.beginSpeculativeGroup(seq);
        const c = if (i + 1 < n) try Cut.of(parsed.frameStream(i + 1)) else null;
        defer if (c) |x| x.deinit();
        if (c) |x| {
            q2.appendSpeculative(parsed.frameStream(i + 1));
            q3.appendSpeculative(x.stream(x.head));
            q3.appendSpeculative(x.stream(x.tail));
            cuts += 1;
        }
        q2.commitSpeculativeGroup(.{});
        q3.commitSpeculativeGroup(.{});
        q2.commitStaged();
        q3.commitStaged();

        var shadow: lh.Shadow = .{};
        plain.drain(q1, &shadow);
        whole.drain(q2, &shadow);
        cut.drain(q3, &shadow);
        try check(cut.vram.hash() == whole.vram.hash(), "{s} frame {d}: the cut group's picture differs", .{ name, i });
        cut.settleSpeculation();
        whole.settleSpeculation();
        try check(cut.vram.hash() == plain.vram.hash(), "{s} frame {d}: the cut group left the real timeline changed", .{ name, i });
    }
    return cuts;
}
