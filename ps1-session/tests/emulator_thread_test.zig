//! The emulator thread around `iterate`: every wait is one futex word, so a
//! stop or a setter wakes it at once, and stop answers every request and
//! leaves the cards flushed after the join.

const std = @import("std");
const builtin = @import("builtin");
const session = @import("ps1_session");
const metal = @import("ps1_metal");
const FakeMachine = @import("fake_machine.zig").FakeMachine;

const pacing = session.pacing;
const capi = session.capi;
const Exchange = metal.frame_exchange.Exchange;
const StreamQueue = metal.stream_queue.StreamQueue;
const Pacer = metal.waker.Pacer;
const AudioRing = session.audio_ring.AudioRing;
const Loop = session.run_loop.RunLoop(FakeMachine);
const Thread = session.emulator_thread.EmulatorThread(FakeMachine);

const alloc = std.testing.allocator;
const io = std.testing.io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

fn nowNs() u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

/// What a frame hook reports across threads.
const Signals = struct {
    frames: std.atomic.Value(u32) = .init(0),
    first_frame_ns: std.atomic.Value(u64) = .init(0),
    /// While true, `runFrame` spins: the test holds the thread mid-frame.
    hold: std.atomic.Value(bool) = .init(false),
    inside: std.atomic.Value(bool) = .init(false),
};

fn onRun(m: *FakeMachine) void {
    const s: *Signals = @ptrCast(@alignCast(m.ctx.?));
    if (s.frames.fetchAdd(1, .acq_rel) == 0) s.first_frame_ns.store(nowNs(), .release);
    s.inside.store(true, .release);
    while (s.hold.load(.acquire)) std.atomic.spinLoopHint();
}

const Rig = struct {
    m: FakeMachine,
    x: *Exchange,
    ring: AudioRing,
    loop: *Loop,
    pacer: Pacer = .{},
    wake: metal.waker.PacerWake = undefined,
    thread: Thread = .{},
    signals: Signals = .{},

    fn init(self: *Rig) !void {
        self.* = .{ .m = FakeMachine.init(alloc), .x = undefined, .ring = undefined, .loop = undefined };
        self.x = try Exchange.init(alloc);
        self.ring = try AudioRing.init(alloc, pacing.ring_capacity);
        self.loop = try Loop.create(alloc, io, &self.m, self.x, &self.ring, null);
        self.x.queue.clearResync();
        self.m.ctx = &self.signals;
        self.m.on_run = onRun;
        self.wake = .{ .pacer = &self.pacer, .io = io };
        self.x.queue.on_drained = self.wake.waker();
    }

    fn start(self: *Rig) !void {
        try self.thread.start(self.loop, &self.pacer, io);
    }

    fn deinit(self: *Rig) void {
        self.thread.shutdown();
        self.loop.destroy();
        self.ring.deinit();
        self.x.deinit();
        self.m.deinit();
    }

    /// Waits up to a second for `cond`.
    fn waitFor(self: *Rig, comptime cond: fn (*Rig) bool) !void {
        const t0 = nowNs();
        while (!cond(self)) {
            if (nowNs() - t0 > std.time.ns_per_s) return error.TestUnexpectedResult;
            std.atomic.spinLoopHint();
        }
    }
};

fn queueFull(r: *Rig) bool {
    return r.x.queue.freeSlots() == 0;
}

/// The timestamp, not the count: the count moves first.
fn ranAFrame(r: *Rig) bool {
    return r.signals.first_frame_ns.load(.acquire) != 0;
}

fn insideAFrame(r: *Rig) bool {
    return r.signals.inside.load(.acquire);
}

/// Parks the thread one way, then times `stop`.
fn stopTime(comptime park: fn (*Rig) anyerror!void) !u64 {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    try park(&r);
    try r.start();
    // Long enough to be inside the wait, short beside its 50 ms timeouts.
    try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(5), .clock = .awake }, io);
    const t0 = nowNs();
    r.thread.shutdown();
    return nowNs() - t0;
}

fn parkPaused(r: *Rig) !void {
    r.loop.controls.paused.store(true, .release);
}

fn parkAudio(r: *Rig) !void {
    var block: [1024]f32 = @splat(0);
    while (r.ring.filled() <= pacing.waterMarks(1).high) _ = r.ring.write(&block);
}

fn parkQueue(r: *Rig) !void {
    for (0..StreamQueue.capacity) |i| r.x.queue.publish(i + 1, r.m.takeFrameStream());
}

fn parkRewindIdle(r: *Rig) !void {
    r.loop.controls.rewind_budget.store(1 << 20, .release);
    r.loop.controls.rewinding.store(true, .release);
}

test "EmulatorThread: stopReturnsPromptlyFromEveryWait" {
    const limit = 200 * std.time.ns_per_ms;
    inline for (.{ parkPaused, parkAudio, parkQueue, parkRewindIdle }) |park| {
        const t = try stopTime(park);
        try expect(t < limit);
    }
}

const Answers = struct {
    save: std.atomic.Value(i32) = .init(1),
    load: std.atomic.Value(i32) = .init(1),

    fn saved(ctx: ?*anyopaque, code: i32, _: [*]const u8, _: usize, _: ?[*]const u8, _: usize) callconv(.c) void {
        const self: *Answers = @ptrCast(@alignCast(ctx.?));
        self.save.store(code, .release);
    }

    fn loaded(ctx: ?*anyopaque, code: i32, _: [*]const u8, _: usize) callconv(.c) void {
        const self: *Answers = @ptrCast(@alignCast(ctx.?));
        self.load.store(code, .release);
    }
};

fn stopper(t: *Thread) void {
    t.shutdown();
}

test "EmulatorThread: stopAnswersEveryPendingRequest" {
    // Queued while the thread is mid-frame, past this pass's services: a
    // paused loop would service them, so the frame is where a request can
    // still be waiting when the stop lands.
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    r.signals.hold.store(true, .release);
    try r.start();
    try r.waitFor(insideAFrame);
    var a: Answers = .{};
    r.loop.requests.addSave(Answers.saved, &a);
    r.loop.requests.addLoad(try alloc.dupe(u8, "state"), alloc, Answers.loaded, &a);
    const s = try std.Thread.spawn(.{}, stopper, .{&r.thread});
    try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(5), .clock = .awake }, io);
    r.signals.hold.store(false, .release);
    s.join();
    try expectEqual(capi.PS1_ERR_SESSION_STOPPED, a.save.load(.acquire));
    try expectEqual(capi.PS1_ERR_SESSION_STOPPED, a.load.load(.acquire));
}

test "EmulatorThread: theCardsAreFlushedAfterTheJoin" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    const store = session.cards.CardStore.open(try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}));
    r.loop.cards = &store;
    try r.start();
    try r.waitFor(ranAFrame);
    r.m.dirty_cards[0] = true;
    r.thread.shutdown();
    // The flush's take came after the last frame the thread ran, and the
    // card it took is on disk.
    try expect(r.m.last("takeMemcard 0").? > r.m.last("run").?);
    var out: [session.cards.bytes]u8 = undefined;
    try expect(store.load(io, 0, &out));
}

test "EmulatorThread: aSetterWakesAPausedThreadWithoutWaitingOutItsTimeout" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    r.loop.controls.paused.store(true, .release);
    try r.start();
    try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(5), .clock = .awake }, io);
    const t0 = nowNs();
    r.loop.controls.paused.store(false, .release);
    r.pacer.bump(io);
    try r.waitFor(ranAFrame);
    try expect(r.signals.first_frame_ns.load(.acquire) - t0 < 10 * std.time.ns_per_ms);
}

test "EmulatorThread: theMixersWakeReachesTheProducerWithoutALock" {
    if (builtin.mode != .debug) return error.SkipZigTest; // the Lock counts acquisitions in Debug only
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    var mixer = session.mixer.Mixer.init(&r.ring);
    mixer.drained = r.wake.waker();
    try parkAudio(&r);
    try r.start();
    try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(5), .clock = .awake }, io);
    try expectEqual(0, r.signals.frames.load(.acquire));

    const locks_before = metal.lock.acquisitionsOnThisThread();
    var left: [512]f32 = undefined;
    var right: [512]f32 = undefined;
    const t0 = nowNs();
    while (r.ring.filled() >= pacing.waterMarks(1).low) mixer.pull(&left, &right);
    try expectEqual(locks_before, metal.lock.acquisitionsOnThisThread());
    try r.waitFor(ranAFrame);
    // Woken, not timed out: well inside the 50 ms backstop.
    try expect(r.signals.first_frame_ns.load(.acquire) - t0 < 25 * std.time.ns_per_ms);
}
