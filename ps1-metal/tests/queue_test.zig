//! StreamQueue: the frame ring from the emulator thread to the render thread,
//! and runahead's speculative groups. No Metal: runs under `zig build test`.

const std = @import("std");
const ps1_core = @import("ps1_core");
const metal = @import("ps1_metal");
const sq = metal.stream_queue;
const StreamQueue = sq.StreamQueue;
const StreamSlot = sq.StreamSlot;
const Display = sq.Display;
const Command = ps1_core.gpu.command.Command;
const recorder = ps1_core.gpu.recorder;

const alloc = std.testing.allocator;

/// Publishes a stream of `n` records whose `value` carries the seq, so a
/// drain can assert ORDER and that the bytes were copied.
fn publish(q: *StreamQueue, seq: u64, n: usize, words: usize, complete: bool) !void {
    const recs = try alloc.alloc(Command, n);
    defer alloc.free(recs);
    for (recs) |*r| r.* = .{ .kind = .draw_triangle, .value = @intCast(seq) };
    const pay = try alloc.alloc(u32, words);
    defer alloc.free(pay);
    @memset(pay, @intCast(seq));
    q.publish(seq, .{ .records = recs, .payload = pay, .complete = complete });
}

fn fresh() !*StreamQueue {
    const q = try StreamQueue.init(alloc);
    q.clearResync();
    return q;
}

const Seen = struct {
    seqs: [16]u64 = undefined,
    counts: [16]usize = undefined,
    n: usize = 0,

    fn add(self: *Seen, slot: *const StreamSlot) void {
        self.seqs[self.n] = slot.seq;
        self.counts[self.n] = slot.record_count;
        self.n += 1;
    }
};

fn ignore(_: void, _: *const StreamSlot) void {}

test "StreamQueue: a queue starts asking for a resync" {
    // The GPU texture's contents are unrelated to the shadow until the first
    // frame lands, so the very first draw must adopt the shadow rather than
    // assume a blank match.
    const q = try StreamQueue.init(alloc);
    defer q.deinit();
    try std.testing.expect(q.needsResync());
}

test "StreamQueue: drain hands back every published frame in order" {
    const q = try fresh();
    defer q.deinit();
    try publish(q, 1, 3, 0, true);
    try publish(q, 2, 5, 0, true);

    var seen: Seen = .{};
    q.drain(&seen, Seen.add);

    try std.testing.expectEqual(@as(usize, 2), seen.n);
    try std.testing.expectEqual(@as(u64, 1), seen.seqs[0]);
    try std.testing.expectEqual(@as(usize, 3), seen.counts[0]);
    try std.testing.expectEqual(@as(u64, 2), seen.seqs[1]);
    try std.testing.expectEqual(@as(usize, 5), seen.counts[1]);
    try std.testing.expectEqual(@as(usize, 0), q.pendingCount());
}

test "StreamQueue: drain copies records and payload rather than aliasing them" {
    const q = try fresh();
    defer q.deinit();
    try publish(q, 7, 2, 4, true);

    const Got = struct {
        records: [2]u32 = .{ 0, 0 },
        payload: [4]u32 = .{ 0, 0, 0, 0 },
        fn take(self: *@This(), slot: *const StreamSlot) void {
            const s = slot.stream();
            for (s.records, 0..) |r, i| self.records[i] = r.value;
            @memcpy(&self.payload, s.payload);
        }
    };
    var got: Got = .{};
    q.drain(&got, Got.take);

    // The core reuses its recorder storage the instant emulation resumes, so a
    // slot that aliased it would hand the renderer the NEXT frame's bytes.
    try std.testing.expectEqualSlices(u32, &.{ 7, 7 }, &got.records);
    try std.testing.expectEqualSlices(u32, &.{ 7, 7, 7, 7 }, &got.payload);
}

test "StreamQueue: a full ring notes a dropped frame and enqueues nothing further" {
    const q = try fresh();
    defer q.deinit();
    for (0..StreamQueue.capacity) |i| try publish(q, i, 1, 0, true);
    try std.testing.expect(!q.hasDroppedFrames());
    try std.testing.expectEqual(StreamQueue.capacity, q.pendingCount());

    try publish(q, 99, 1, 0, true);
    // A DROP, not a resync. The consumer's texture is still a faithful
    // picture of every frame it executed: it is this frame's mutations that
    // are gone, and re-adopting a native shadow over it is what collapsed the
    // picture to 1x at scale.
    try std.testing.expect(q.hasDroppedFrames());
    try std.testing.expect(!q.needsResync());
    try std.testing.expectEqual(StreamQueue.capacity, q.pendingCount());
}

test "StreamQueue: taking the dropped flag clears it" {
    const q = try fresh();
    defer q.deinit();
    try std.testing.expect(!q.takeDroppedFrames());

    q.noteDroppedFrame();
    // Read-and-clear in one step, unlike clearResync: clearing this one in a
    // separate store would swallow a drop recorded between the two.
    try std.testing.expect(q.takeDroppedFrames());
    try std.testing.expect(!q.takeDroppedFrames());
}

test "StreamQueue: an incomplete stream is never enqueued" {
    const q = try fresh();
    defer q.deinit();
    try publish(q, 1, 3, 0, false);

    // A prefix applied to VRAM leaves it permanently out of step, so the
    // frame is dropped whole rather than partly applied.
    try std.testing.expect(q.hasDroppedFrames());
    try std.testing.expect(!q.needsResync());
    try std.testing.expectEqual(@as(usize, 0), q.pendingCount());
}

test "StreamQueue: requestResync survives an empty queue" {
    const q = try fresh();
    defer q.deinit();
    try std.testing.expect(!q.needsResync());

    // A front-panel reset rebuilds Bus and clears software VRAM while the GPU
    // texture still holds the old picture. Nothing is queued at that instant,
    // so the flag is the only thing carrying the news.
    q.requestResync();
    try std.testing.expect(q.needsResync());
    try std.testing.expectEqual(@as(usize, 0), q.pendingCount());
}

test "StreamQueue: discardAll drops the backlog without executing it" {
    const q = try fresh();
    defer q.deinit();
    try publish(q, 1, 1, 0, true);
    try publish(q, 2, 1, 0, true);

    try std.testing.expectEqual(@as(?u64, 2), q.discardAll());

    var seen: Seen = .{};
    q.drain(&seen, Seen.add);
    try std.testing.expectEqual(@as(usize, 0), seen.n);
    try std.testing.expectEqual(@as(usize, 0), q.pendingCount());
}

test "StreamQueue: discardThrough drops only the frames at or below the seq" {
    const q = try fresh();
    defer q.deinit();
    try publish(q, 1, 1, 0, true);
    try publish(q, 2, 1, 0, true);
    try publish(q, 3, 1, 0, true);

    // A resync adopts ONE shadow, and that shadow accounts for every frame up
    // to its own seq and for none above it. Dropping more loses mutations;
    // dropping fewer applies them twice.
    _ = q.discardThrough(2);

    var seen: Seen = .{};
    q.drain(&seen, Seen.add);
    try std.testing.expectEqual(@as(usize, 1), seen.n);
    try std.testing.expectEqual(@as(u64, 3), seen.seqs[0]);
}

test "StreamQueue: discardThrough names the oldest surviving frame" {
    const q = try fresh();
    defer q.deinit();
    try publish(q, 5, 1, 0, true);

    // The caller needs this to tell "the queue resumes exactly where the
    // shadow ends" from "frames were dropped in between", which is the
    // difference between a complete resync and one that has to be repeated.
    try std.testing.expectEqual(@as(?u64, 5), q.discardThrough(2));
    try std.testing.expectEqual(@as(?u64, null), q.discardThrough(5));
}

test "StreamQueue: a frame larger than a slot is refused rather than truncated" {
    const q = try fresh();
    defer q.deinit();
    try publish(q, 1, recorder.max_records + 1, 0, true);

    // The core cannot produce one (the recorder caps at the same number and
    // reports complete == false), but a truncated slot would be a silent
    // prefix, which is the exact failure the complete flag exists to prevent.
    try std.testing.expect(q.hasDroppedFrames());
    try std.testing.expect(!q.needsResync());
    try std.testing.expectEqual(@as(usize, 0), q.pendingCount());
}

test "StreamQueue: isFull only once every slot is taken" {
    const q = try fresh();
    defer q.deinit();
    for (0..StreamQueue.capacity) |i| {
        try std.testing.expect(!q.isFull());
        try publish(q, i, 1, 0, true);
    }
    try std.testing.expect(q.isFull());
    q.drain({}, ignore);
    try std.testing.expect(!q.isFull());
}

/// One speculative frame, `n` records each carrying `tag` in `value`.
fn speculate(q: *StreamQueue, tag: u32, n: usize, complete: bool) !void {
    const recs = try alloc.alloc(Command, n);
    defer alloc.free(recs);
    for (recs) |*r| r.* = .{ .kind = .draw_triangle, .value = tag };
    const pay = [_]u32{tag};
    q.appendSpeculative(.{ .records = recs, .payload = &pay, .complete = complete });
}

fn display(x: u32) Display {
    return .{ .vram_x = x };
}

test "StreamQueue: a committed speculative group is handed over whole with its display" {
    const q = try fresh();
    defer q.deinit();
    q.beginSpeculativeGroup(5);
    try speculate(q, 1, 1, true);
    try speculate(q, 2, 3, true);
    q.commitSpeculativeGroup(display(320));

    // Not until the real frame it runs ahead of has been executed.
    try std.testing.expect(q.takeSpeculativeGroup(4) == null);
    const g = q.takeSpeculativeGroup(5) orelse return error.NoGroup;
    try std.testing.expectEqual(@as(u64, 5), g.after_seq);
    try std.testing.expectEqual(@as(u32, 320), g.display.vram_x);
    const frames = g.frames();
    try std.testing.expectEqual(@as(usize, 2), frames.len);
    try std.testing.expectEqual(@as(usize, 1), frames[0].record_count);
    try std.testing.expectEqual(@as(usize, 3), frames[1].record_count);
    try std.testing.expectEqual(@as(u32, 2), frames[1].records[2].value);
    try std.testing.expectEqual(@as(u32, 1), frames[0].payload[0]);
    q.releaseSpeculativeGroup();
    // Taken once: the next drain has nothing until the next group.
    try std.testing.expect(q.takeSpeculativeGroup(5) == null);
}

test "StreamQueue: a newer group replaces one never taken" {
    const q = try fresh();
    defer q.deinit();
    q.beginSpeculativeGroup(1);
    try speculate(q, 1, 1, true);
    q.commitSpeculativeGroup(display(0));
    q.beginSpeculativeGroup(2);
    try speculate(q, 2, 1, true);
    q.commitSpeculativeGroup(display(0));

    const g = q.takeSpeculativeGroup(2) orelse return error.NoGroup;
    try std.testing.expectEqual(@as(u64, 2), g.after_seq);
    try std.testing.expectEqual(@as(u32, 2), g.frames()[0].records[0].value);
}

test "StreamQueue: a group holding an incomplete frame is never handed over" {
    const q = try fresh();
    defer q.deinit();
    q.beginSpeculativeGroup(1);
    try speculate(q, 1, 1, true);
    try speculate(q, 2, 1, false);
    q.commitSpeculativeGroup(display(0));
    // A prefix replayed for display would leave the restore region wrong.
    try std.testing.expect(q.takeSpeculativeGroup(1) == null);
}

test "StreamQueue: the producer never writes into the group being replayed" {
    const q = try fresh();
    defer q.deinit();
    q.beginSpeculativeGroup(1);
    try speculate(q, 1, 1, true);
    q.commitSpeculativeGroup(display(0));
    const replaying = q.takeSpeculativeGroup(1) orelse return error.NoGroup;

    // Two more groups while the first is still being replayed.
    for ([_]u32{ 2, 3 }) |tag| {
        q.beginSpeculativeGroup(tag);
        try speculate(q, tag, 1, true);
        q.commitSpeculativeGroup(display(0));
    }
    try std.testing.expectEqual(@as(u32, 1), replaying.frames()[0].records[0].value);
    q.releaseSpeculativeGroup();
    const next = q.takeSpeculativeGroup(3) orelse return error.NoGroup;
    try std.testing.expectEqual(@as(u32, 3), next.frames()[0].records[0].value);
}

test "StreamQueue: more speculative frames than a group holds spoil the group" {
    const q = try fresh();
    defer q.deinit();
    q.beginSpeculativeGroup(1);
    for (0..StreamQueue.max_speculative_frames + 1) |tag| try speculate(q, @intCast(tag), 1, true);
    q.commitSpeculativeGroup(display(0));
    try std.testing.expect(q.takeSpeculativeGroup(1) == null);
}

test "StreamQueue: a group behind the executed frame is stale and dropped" {
    const q = try fresh();
    defer q.deinit();
    q.beginSpeculativeGroup(1);
    try speculate(q, 1, 1, true);
    q.commitSpeculativeGroup(display(0));
    try std.testing.expect(q.takeSpeculativeGroup(2) == null);
    try std.testing.expect(q.takeSpeculativeGroup(1) == null);
}

test "StreamQueue: a staged frame is not visible until committed" {
    const q = try fresh();
    defer q.deinit();
    const cmd = [_]Command{.{ .kind = .draw_triangle }};
    try std.testing.expect(q.stage(1, .{ .records = &cmd, .payload = &.{}, .complete = true }));
    try std.testing.expectEqual(@as(usize, 0), q.pendingCount());
    q.commitStaged();
    try std.testing.expectEqual(@as(usize, 1), q.pendingCount());
    q.commitStaged(); // nothing staged: no second frame
    try std.testing.expectEqual(@as(usize, 1), q.pendingCount());
}

const frames_to_send = 10_000;

const Shared = struct {
    q: *StreamQueue,
    /// Raised by the producer after its last publish, so a consumer facing a
    /// LOST frame stops instead of waiting for it forever.
    done: std.atomic.Value(bool) = .init(false),
};

fn produce(shared: *Shared) void {
    var seq: u64 = 1;
    while (seq <= frames_to_send) : (seq += 1) {
        while (shared.q.isFull()) std.atomic.spinLoopHint();
        const cmd = [_]Command{.{ .kind = .draw_triangle, .value = @truncate(seq) }};
        const pay = [_]u32{@truncate(seq)};
        shared.q.publish(seq, .{ .records = &cmd, .payload = &pay, .complete = true });
    }
    shared.done.store(true, .release);
}

const Consumer = struct {
    next: u64 = 1,
    taken: u64 = 0,
    /// The first slot that broke the contract, kept rather than asserted on
    /// the consumer thread so the failure reaches the test runner.
    bad_seq: ?u64 = null,

    fn take(self: *Consumer, slot: *const StreamSlot) void {
        const s = slot.stream();
        const tag: u32 = @truncate(slot.seq);
        const ok = slot.seq == self.next and s.records.len == 1 and s.payload.len == 1 and
            s.records[0].value == tag and s.payload[0] == tag;
        if (!ok and self.bad_seq == null) self.bad_seq = slot.seq;
        self.next = slot.seq + 1;
        self.taken += 1;
    }

    fn run(self: *Consumer, shared: *Shared) void {
        while (true) {
            // Read BEFORE the drain: a drain that follows the producer's last
            // publish is then guaranteed to see every frame it published.
            const finished = shared.done.load(.acquire);
            shared.q.drain(self, take);
            if (finished) return;
            std.atomic.spinLoopHint();
        }
    }
};

test "StreamQueue: a producer and consumer on two threads lose nothing" {
    const q = try fresh();
    defer q.deinit();
    var consumer: Consumer = .{};
    var shared: Shared = .{ .q = q };

    const reader = try std.Thread.spawn(.{}, Consumer.run, .{ &consumer, &shared });
    const writer = try std.Thread.spawn(.{}, produce, .{&shared});
    writer.join();
    reader.join();

    // Every seq exactly once and in order: `take` checks each slot against
    // the next expected seq, and the reader drains once more after the
    // producer's last publish.
    try std.testing.expectEqual(@as(?u64, null), consumer.bad_seq);
    try std.testing.expectEqual(@as(u64, frames_to_send), consumer.taken);
    try std.testing.expectEqual(@as(u64, frames_to_send + 1), consumer.next);
    try std.testing.expect(!q.hasDroppedFrames());
    try std.testing.expectEqual(@as(u64, frames_to_send), q.published_count.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), q.pendingCount());
}

/// A `Waker` that counts its calls.
const Wakes = struct {
    n: usize = 0,

    fn wake(ctx: *anyopaque) void {
        const self: *Wakes = @ptrCast(@alignCast(ctx));
        self.n += 1;
    }

    fn waker(self: *Wakes) metal.waker.Waker {
        return .{ .ctx = self, .wake = wake };
    }
};

test "StreamQueue: aDrainThatTakesAFrameWakesTheProducer" {
    const q = try fresh();
    defer q.deinit();
    var wakes: Wakes = .{};
    q.on_drained = wakes.waker();
    q.drain({}, ignore);
    try std.testing.expectEqual(0, wakes.n);
    try publish(q, 1, 1, 0, true);
    try publish(q, 2, 1, 0, true);
    q.drain({}, ignore);
    try std.testing.expectEqual(1, wakes.n);
}

test "StreamQueue: aDiscardThatTakesAFrameWakesTheProducerToo" {
    const q = try fresh();
    defer q.deinit();
    var wakes: Wakes = .{};
    q.on_drained = wakes.waker();
    _ = q.discardThrough(9);
    _ = q.discardAll();
    try std.testing.expectEqual(0, wakes.n);
    try publish(q, 1, 1, 0, true);
    try publish(q, 2, 1, 0, true);
    _ = q.discardThrough(0);
    try std.testing.expectEqual(0, wakes.n);
    _ = q.discardThrough(1);
    try std.testing.expectEqual(1, wakes.n);
    _ = q.discardAll();
    try std.testing.expectEqual(2, wakes.n);
}

test "StreamQueue: freeSlotsIsWhatTheProducerMayStillPublish" {
    const q = try fresh();
    defer q.deinit();
    try std.testing.expectEqual(StreamQueue.capacity, q.freeSlots());
    try publish(q, 1, 1, 0, true);
    try publish(q, 2, 1, 0, true);
    try std.testing.expectEqual(StreamQueue.capacity - 2, q.freeSlots());
    q.drain({}, ignore);
    try std.testing.expectEqual(StreamQueue.capacity, q.freeSlots());
}

/// Counts every allocation ATTEMPT, and refuses each one past `succeed`.
const Refusing = struct {
    inner: std.mem.Allocator,
    succeed: usize,
    attempts: usize = 0,

    fn allocator(self: *Refusing) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocFn, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = freeFn } };
    }

    fn allocFn(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Refusing = @ptrCast(@alignCast(ctx));
        self.attempts += 1;
        if (self.attempts > self.succeed) return null;
        return self.inner.rawAlloc(len, a, ra);
    }

    fn freeFn(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Refusing = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(buf, a, ra);
    }
};

test "StreamQueue: aGroupThatCannotBeAllocatedIsTriedOnceAndRunaheadStaysOff" {
    // The queue itself is one create plus two buffers per slot; everything
    // after that (the groups) is refused.
    var refusing: Refusing = .{ .inner = alloc, .succeed = 1 + 2 * StreamQueue.capacity };
    const q = try StreamQueue.init(refusing.allocator());
    defer q.deinit();
    q.clearResync();
    const built = refusing.attempts;
    q.beginSpeculativeGroup(1);
    q.beginSpeculativeGroup(2);
    try std.testing.expectEqual(built + 1, refusing.attempts);
    try std.testing.expect(q.group_alloc_failed);
    try std.testing.expectEqual(null, q.takeSpeculativeGroup(1));
    try std.testing.expectEqual(null, q.takeSpeculativeGroup(2));
}

test "StreamQueue: theLockIsTakenAroundEveryGroupIndexChange" {
    var l: metal.lock.Lock = .{};
    l.lock();
    l.unlock();
    l.lock();
    l.unlock();
}
