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

/// Requests a slot for each seq and releases it while the render side is
/// serving that seq, as a capture cancelled mid-frame would. Only one slot is
/// ever held, so once that serve has returned, the next request must get the
/// same slot back: one still busy was stranded by the release.
const Canceller = struct {
    ring: *CaptureRing,
    seq: std.atomic.Value(u64) = .init(0),
    /// The seq the serving loop is about to serve, and the last it served.
    serving: std.atomic.Value(u64) = .init(0),
    served: std.atomic.Value(u64) = .init(0),
    done: std.atomic.Value(bool) = .init(false),
    stranded: std.atomic.Value(bool) = .init(false),

    fn run(self: *Canceller) void {
        defer self.done.store(true, .release);
        for (1..rounds + 1) |k| {
            const i = self.ring.request(k) orelse return self.stranded.store(true, .release);
            if (i != 0) return self.stranded.store(true, .release);
            self.seq.store(k, .release);
            while (self.serving.load(.acquire) != k) std.atomic.spinLoopHint();
            // A varying delay, so some releases land inside the serve's
            // encode rather than all before it or all after.
            for (0..(k % 64) * 40) |_| std.atomic.spinLoopHint();
            self.ring.release(i);
            while (self.served.load(.acquire) < k) std.atomic.spinLoopHint();
        }
    }

    const rounds = 3000;
};

test "CaptureRing: releasingARequestedSlotNeverStrandsIt" {
    const m = try harness.metal();
    defer m.deinit();
    const live = try lh.make(m, 1, false);
    defer live.deinit();
    var c: Canceller = .{ .ring = &live.captures };
    const t = try std.Thread.spawn(.{}, Canceller.run, .{&c});
    while (!c.done.load(.acquire)) {
        const pool = objc.Pool.push();
        defer pool.pop();
        const seq = c.seq.load(.acquire);
        c.serving.store(seq, .release);
        live.captures.serve(seq, .{
            .queue = live.vram.queue,
            .pipeline = live.rasterizer.pipelines.gather_colour,
            .texture = live.vram.texture,
            .scale = 1,
        });
        c.served.store(seq, .release);
    }
    t.join();
    try check(!c.stranded.load(.acquire), "a released slot stayed busy after its serve returned", .{});
}
