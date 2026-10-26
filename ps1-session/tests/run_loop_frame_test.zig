//! One pass of the emulator thread's loop: what it runs, what it publishes
//! and in which order, and what it waits for instead of running. Every case
//! drives `iterate` against the scripted machine and a real `Exchange`.

const std = @import("std");
const session = @import("ps1_session");
const metal = @import("ps1_metal");
const ps1_core = @import("ps1_core");
const FakeMachine = @import("fake_machine.zig").FakeMachine;

const pacing = session.pacing;
const run_loop = session.run_loop;
const Exchange = metal.frame_exchange.Exchange;
const StreamQueue = metal.stream_queue.StreamQueue;
const StreamSlot = metal.stream_queue.StreamSlot;
const AudioRing = session.audio_ring.AudioRing;
const Loop = run_loop.RunLoop(FakeMachine);
const picture_frames = @import("ps1_core").savestate.rewind.picture_frames;

const alloc = std.testing.allocator;
const io = std.testing.io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Rig = struct {
    m: FakeMachine,
    x: *Exchange,
    ring: AudioRing,
    loop: *Loop,

    fn init(self: *Rig) !void {
        self.m = FakeMachine.init(alloc);
        self.x = try Exchange.init(alloc);
        self.ring = try AudioRing.init(alloc, pacing.ring_capacity);
        self.loop = try Loop.create(alloc, io, &self.m, self.x, &self.ring, null);
        // A running game: the fresh-queue resync already answered.
        self.x.queue.clearResync();
    }

    fn deinit(self: *Rig) void {
        self.loop.destroy();
        self.ring.deinit();
        self.x.deinit();
        self.m.deinit();
    }

    fn iterate(self: *Rig) run_loop.Outcome {
        return self.loop.iterate(0);
    }
};

fn ignore(_: void, _: *const StreamSlot) void {}

fn expectWait(o: run_loop.Outcome, reason: run_loop.Wait.Reason) !void {
    switch (o) {
        .wait => |w| try expectEqual(reason, w.reason),
        else => {
            std.debug.print("expected a {s} wait, got {s}\n", .{ @tagName(reason), @tagName(o) });
            return error.TestUnexpectedResult;
        },
    }
}

test "FramePath: aFullQueueParksTheProducerUntilADrainWakesIt" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    for (0..StreamQueue.capacity) |_| try expectEqual(.ran_frame, std.meta.activeTag(r.iterate()));
    const parked = r.iterate();
    try expectWait(parked, .queue);
    // Nothing but a drain can wake it, so it has no timeout.
    try expectEqual(null, parked.wait.timeout_ns);
    _ = r.x.queue.discardThrough(1);
    try expectEqual(.ran_frame, std.meta.activeTag(r.iterate()));
}

fn rewinding(r: *Rig, history: u32) void {
    r.loop.controls.rewind_budget.store(1 << 20, .release);
    r.loop.controls.rewinding.store(true, .release);
    r.m.rewind_history = history;
}

test "FramePath: aRewindStepWaitsForRoomForEveryFrameItPublishes" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    // Two real frames leave three slots: one short of a step's four.
    _ = r.iterate();
    _ = r.iterate();
    rewinding(&r, 100);
    try expectEqual(StreamQueue.capacity - 2, r.x.queue.freeSlots());
    try expectWait(r.iterate(), .queue);
    _ = r.x.queue.discardThrough(1);
    try expectEqual(.rewound, std.meta.activeTag(r.iterate()));
    try expectEqual(0, r.x.queue.dropped_count.load(.acquire));
    try expectEqual(StreamQueue.capacity, r.x.queue.pendingCount());
}

test "FramePath: theRingAboveItsHighMarkParksTheProducer" {
    for (1..pacing.max_speed + 1) |n| {
        var r: Rig = undefined;
        try r.init();
        defer r.deinit();
        const speed: u32 = @intCast(n);
        r.loop.setSpeed(speed);
        var block: [1024]f32 = @splat(0);
        while (r.ring.filled() <= pacing.waterMarks(speed).high) _ = r.ring.write(&block);
        const o = r.iterate();
        try expectWait(o, .audio);
        try expectEqual(50 * std.time.ns_per_ms, o.wait.timeout_ns.?);
        try expectEqual(0, r.m.count("run"));
    }
}

const SaveSeen = struct {
    calls: usize = 0,
    fn done(ctx: ?*anyopaque, code: i32, _: [*]const u8, _: usize, _: ?[*]const u8, _: usize) callconv(.c) void {
        const self: *SaveSeen = @ptrCast(@alignCast(ctx.?));
        if (code == 0) self.calls += 1;
    }
};

test "FramePath: aPausedLoopStillServicesRequestsAndTheCards" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    const store = session.cards.CardStore.open(try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}));
    r.loop.cards = &store;
    r.loop.controls.paused.store(true, .release);
    r.m.dirty_cards[1] = true;
    var seen: SaveSeen = .{};
    r.loop.requests.addSave(SaveSeen.done, &seen);
    const o = r.iterate();
    try expectWait(o, .paused);
    try expectEqual(50 * std.time.ns_per_ms, o.wait.timeout_ns.?);
    try expectEqual(1, seen.calls);
    try expectEqual(1, r.loop.card_writes.load(.acquire));
    try expectEqual(0, r.m.count("run"));
}

test "FramePath: theVertexCacheEngineAndRewindBudgetCrossOnlyOnChange" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    r.loop.controls.vertex_cache.store(true, .release);
    r.loop.controls.engine.store(@backingInt(session.machine.Engine.cached), .release);
    r.loop.controls.rewind_budget.store(1 << 20, .release);
    _ = r.iterate();
    _ = r.iterate();
    try expectEqual(1, r.m.count("setVertexCache"));
    try expectEqual(1, r.m.count("setEngine"));
    try expectEqual(1, r.m.count("configureRewind"));
    // The nine re-applied switches cross every frame.
    try expectEqual(2, r.m.count("applyPgxp"));
}

test "FramePath: aRefusedEngineIsNotRetried" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    r.m.fail_engine = true;
    r.loop.controls.engine.store(@backingInt(session.machine.Engine.jit), .release);
    _ = r.iterate();
    _ = r.iterate();
    _ = r.iterate();
    try expectEqual(1, r.m.count("setEngine"));
}

/// Asserts, inside every speculative frame, that the real frame has not been
/// handed over yet.
fn realFrameStillStaged(m: *FakeMachine) void {
    const x: *Exchange = @ptrCast(@alignCast(m.ctx.?));
    if (m.count("mark") > 0 and x.queue.pendingCount() != 0) m.card_fill = 0xEE;
}

test "FramePath: runaheadRunsOnlyAtOneXAndStagesTheRealFrameUntilItsGroupIsIn" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    r.loop.controls.runahead.store(2, .release);
    r.m.ctx = r.x;
    r.m.on_run = realFrameStillStaged;
    try expectEqual(.ran_frame, std.meta.activeTag(r.iterate()));
    try expectEqual(1, r.m.count("mark"));
    try expectEqual(3, r.m.count("run"));
    try expect(r.m.card_fill != 0xEE);
    try expectEqual(1, r.x.queue.pendingCount());
    try expect(r.x.queue.takeSpeculativeGroup(1) != null);

    r.loop.setSpeed(2);
    _ = r.iterate();
    try expectEqual(1, r.m.count("mark"));
}

const Probe = struct {
    x: *Exchange,
    resync_at_first_run: ?bool = null,
    pending_at_first_run: usize = 99,
};

fn firstRun(m: *FakeMachine) void {
    const p: *Probe = @ptrCast(@alignCast(m.ctx.?));
    if (p.resync_at_first_run != null) return;
    p.resync_at_first_run = p.x.queue.needsResync();
    p.pending_at_first_run = p.x.queue.pendingCount();
}

const Seqs = struct {
    min: u64 = std.math.maxInt(u64),
    n: usize = 0,
    fn add(self: *Seqs, slot: *const StreamSlot) void {
        self.min = @min(self.min, slot.seq);
        self.n += 1;
    }
};

test "FramePath: aRewindStepPublishesItsShadowAndResyncBeforeItsStreams" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    rewinding(&r, 100);
    var probe: Probe = .{ .x = r.x };
    r.m.ctx = &probe;
    r.m.on_run = firstRun;
    try expectEqual(.rewound, std.meta.activeTag(r.iterate()));
    // Resync raised before the first stream was visible.
    try expectEqual(true, probe.resync_at_first_run.?);
    try expectEqual(0, probe.pending_at_first_run);
    const shadow = r.x.acquireShadow().?;
    var seqs: Seqs = .{};
    r.x.queue.drain(&seqs, Seqs.add);
    try expectEqual(picture_frames, seqs.n);
    try expect(shadow.seq < seqs.min);
}

fn frameValue(m: *FakeMachine) void {
    m.audio_value = @floatFromInt(m.frames_run);
}

test "FramePath: aRewindStepWritesTheWentBackStretchReversedAndDropsThePicturesOwnAudio" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    // Three frames of history, one step back over all three: the step's
    // fourth picture frame is the picture's own and its audio is dropped.
    rewinding(&r, 3);
    r.m.rewind_step_frames = 3;
    r.m.audio_per_frame = 2;
    r.m.on_run = frameValue;
    try expectEqual(.rewound, std.meta.activeTag(r.iterate()));
    var out: [16]f32 = undefined;
    const n = r.ring.read(&out);
    try std.testing.expectEqualSlices(f32, &.{ 3, 3, 2, 2, 1, 1 }, out[0..n]);
}

test "FramePath: theShadowIsPublishedOnlyWhenSomethingReadsIt" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    _ = r.iterate();
    try expectEqual(0, r.m.count("copyVram"));
    r.x.queue.requestShadow();
    _ = r.iterate();
    try expectEqual(1, r.m.count("copyVram"));
    // A 24-bit display scans out of the render texture: no shadow.
    r.m.display_value.depth24 = true;
    _ = r.iterate();
    try expectEqual(1, r.m.count("copyVram"));
}

fn displayNotYetPublished(m: *FakeMachine) void {
    const x: *Exchange = @ptrCast(@alignCast(m.ctx.?));
    if (x.newestDisplay().vram_x == m.display_value.vram_x) m.card_fill = 0xEE;
}

test "FramePath: theDisplayIsPublishedAfterTheShadow" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    r.m.display_value = .{ .vram_x = 100, .width = 320, .height = 240, .enabled = true };
    r.m.ctx = r.x;
    r.m.on_copy = displayNotYetPublished;
    r.x.queue.requestShadow();
    _ = r.iterate();
    try expectEqual(1, r.m.count("copyVram"));
    try expect(r.m.card_fill != 0xEE);
    try expectEqual(100, r.x.newestDisplay().vram_x);
}

test "FramePath: aPressIsDrainedOnce" {
    var c: run_loop.Controls = .{};
    try expect(!c.takeAnalogPress());
    c.pressAnalogButton();
    c.pressAnalogButton();
    try expect(c.takeAnalogPress());
    try expect(!c.takeAnalogPress());
}

test "FramePath: inputsAndPgxpReachTheMachineBeforeTheFrame" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    r.loop.controls.pressAnalogButton();
    _ = r.iterate();
    const run = r.m.first("run").?;
    try expect(r.m.first("setButtons").? < run);
    try expect(r.m.first("setAnalog").? < run);
    try expect(r.m.first("pressAnalogButton").? < run);
    try expect(r.m.first("applyPgxp").? < run);
    try expectEqual(1, r.x.frames_produced.load(.acquire));
}

test "FramePath: aGpuFrameNeverPublishesAShadowOnItsOwn" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    r.loop.controls.gpu_vram = true;
    r.x.queue.requestShadow();
    r.m.display_value.depth24 = true;
    try expectEqual(.ran_frame, std.meta.activeTag(r.iterate()));
    try expectEqual(0, r.m.count("copyVram"));
    try expect(r.x.acquireShadow() == null);
    // The request was still taken, so it cannot fire on a later frame.
    try expect(!r.x.queue.shadow_wanted.load(.acquire));
}

test "FramePath: runaheadRunsUnderGpuVram" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    r.loop.controls.gpu_vram = true;
    r.loop.controls.runahead.store(2, .release);
    try expectEqual(.ran_frame, std.meta.activeTag(r.iterate()));
    try expectEqual(1, r.m.count("mark"));
    try expectEqual(3, r.m.count("run"));
    try expectEqual(1, r.m.count("return"));
}

test "FramePath: rewindStaysOffUnderGpuVramWithoutACaptureRing" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    r.loop.controls.gpu_vram = true;
    rewinding(&r, 100);
    try expectEqual(.ran_frame, std.meta.activeTag(r.iterate()));
    try expectEqual(0, r.m.count("configureRewind"));
    try expectEqual(0, r.m.count("rewindStep"));
}

test "FramePath: aGpuRewindStepPublishesTheRestoredVramWithoutDepth" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    r.loop.controls.gpu_vram = true;
    r.loop.controls.setPgxp(.{ .enabled = true, .depth_buffer = true });
    // Never touched: the fake machine has no capture waiting for VRAM, so
    // only the ring's presence matters.
    var ring: metal.capture_ring.CaptureRing = undefined;
    r.loop.captures = &ring;
    rewinding(&r, 100);
    var probe: Probe = .{ .x = r.x };
    r.m.ctx = &probe;
    r.m.on_run = firstRun;
    try expectEqual(.rewound, std.meta.activeTag(r.iterate()));
    try expectEqual(1, r.m.count("copyVramAsIs"));
    try expectEqual(0, r.m.count("copyVram"));
    try expectEqual(0, r.m.count("copyDepth"));
    try expectEqual(0, r.m.count("copyDepthAsIs"));
    const shadow = r.x.acquireShadow().?;
    try expect(shadow.depth == null);
    try expectEqual(true, probe.resync_at_first_run.?);
    try expectEqual(0, probe.pending_at_first_run);
    var seqs: Seqs = .{};
    r.x.queue.drain(&seqs, Seqs.add);
    try expectEqual(picture_frames, seqs.n);
    try expect(shadow.seq < seqs.min);
}

test "Session: aDebugSeamForcesDual" {
    const choose = session.session.chooseVram;
    try expectEqual(.dual, choose(.gpu, true, .{ .live_diff = true }));
    try expectEqual(.dual, choose(.dual, true, .{ .software_display = true }));
    try expectEqual(.gpu, choose(.dual, true, .{}));
    try expectEqual(.gpu, choose(.gpu, false, .{ .live_stats = true }));
    try expectEqual(.dual, choose(.dual, false, .{ .live_stats = true }));
}

test "FramePath: everyShadowCarriesTheMachinesRasterState" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    r.m.raster_state.env.offset = 100;
    r.m.raster_state.transfer = ps1_core.gpu.WriteCursor.setup(0, 200, 8, 8);

    r.loop.controls.gpu_vram = true;
    r.loop.machineReplaced();
    try expectEqual(r.m.raster_state, r.x.acquireShadow().?.state.?);

    r.loop.controls.gpu_vram = false;
    r.m.raster_state.env.offset = 7;
    r.x.queue.requestShadow();
    _ = r.iterate();
    try expectEqual(1, r.m.count("copyVram"));
    try expectEqual(r.m.raster_state, r.x.acquireShadow().?.state.?);
}
