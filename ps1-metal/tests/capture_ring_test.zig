//! The capture ring: a whole native VRAM gathered asynchronously after a
//! chosen real frame executes, for the emulator thread to collect later.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const harness = @import("harness.zig");
const lh = @import("live_harness.zig");

const objc = ps1_metal.objc;
const CaptureRing = ps1_metal.capture_ring.CaptureRing;
const Command = @import("ps1_core").gpu.command.Command;

const alloc = std.testing.allocator;
const io = std.testing.io;
const expect = std.testing.expect;
const check = harness.check;

/// Polls slot `i` until it leaves `.pending`, for up to 2 s.
fn settled(ring: *CaptureRing, i: u32) !CaptureRing.Poll {
    const t0 = std.Io.Clock.awake.now(io);
    while (true) {
        const p = ring.poll(i);
        if (p != .pending) return p;
        if (t0.untilNow(io, .awake).nanoseconds > 2 * std.time.ns_per_s) return error.CaptureNeverLanded;
        try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(1), .clock = .awake }, io);
    }
}

const frames = [_]Command{
    lh.fillRect(0, 0, 32, 16, 0x001F),
    lh.fillRect(64, 32, 48, 16, 0x03E0),
    // Frame 3 overwrites frame 2's fill, so a capture taken late shows it.
    lh.fillRect(64, 32, 48, 16, 0x7C00),
};

test "CaptureRing: aCaptureLandsAfterItsFrameExecutes" {
    const m = try harness.metal();
    defer m.deinit();
    const rig = try harness.Rig.create(alloc, m, .{});
    defer rig.destroy();
    for (frames[0..2]) |c| rig.frame(&.{}, &.{c});
    const want = try rig.readback(alloc);
    defer alloc.free(want);

    for ([_]u32{ 1, 3 }) |s| {
        const pool = objc.Pool.push();
        defer pool.pop();
        const live = try lh.make(m, s, false);
        defer live.deinit();
        const q = try lh.queue();
        defer q.deinit();
        const i = live.captures.request(2) orelse return error.RingFull;
        for (frames, 1..) |c, seq| lh.publish(q, seq, &.{c});
        var shadow: lh.Shadow = .{};
        live.drain(q, &shadow);
        switch (try settled(&live.captures, i)) {
            .ready => |pixels| try check(std.mem.eql(u16, want, pixels), "the {d}x capture is not the VRAM after frame 2", .{s}),
            else => return error.CaptureFailed,
        }
        live.captures.release(i);
    }
}

test "CaptureRing: aCaptureForADiscardedSeqFails" {
    const m = try harness.metal();
    defer m.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();
    const live = try lh.make(m, 1, false);
    defer live.deinit();
    const q = try lh.queue();
    defer q.deinit();
    const i = live.captures.request(2) orelse return error.RingFull;
    q.requestResync();
    for (frames, 1..) |c, seq| lh.publish(q, seq, &.{c});
    // The resync adopts the shadow at 3 and discards frames 1-3 unexecuted.
    var shadow: lh.Shadow = .{ .seq = 3 };
    live.drain(q, &shadow);
    try expect(try settled(&live.captures, i) == .failed);
}

test "CaptureRing: aFullRingRefusesARequest" {
    const m = try harness.metal();
    defer m.deinit();
    const live = try lh.make(m, 1, false);
    defer live.deinit();
    var taken: [CaptureRing.slots]u32 = undefined;
    for (&taken, 1..) |*t, seq| t.* = live.captures.request(seq) orelse return error.RingFull;
    try expect(live.captures.request(9) == null);
    live.captures.release(taken[1]);
    try expect(live.captures.request(9) != null);
}

test "CaptureRing: aSpeculativeFrameNeverServesACapture" {
    const m = try harness.metal();
    defer m.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();
    const live = try lh.make(m, 1, false);
    defer live.deinit();
    const q = try lh.queue();
    defer q.deinit();
    const i = live.captures.request(5) orelse return error.RingFull;
    _ = q.stage(4, .{ .records = frames[0..1], .payload = &.{}, .complete = true });
    q.beginSpeculativeGroup(4);
    q.appendSpeculative(.{ .records = frames[1..2], .payload = &.{}, .complete = true });
    q.commitSpeculativeGroup(.{});
    q.commitStaged();
    var shadow: lh.Shadow = .{};
    live.drain(q, &shadow);
    try expect(live.pending_restore != null);
    try expect(live.captures.poll(i) == .pending);
}
