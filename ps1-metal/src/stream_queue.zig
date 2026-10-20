//! The frames from the emulator thread to the render thread: a
//! single-producer / single-consumer ring of real frames, and runahead's
//! speculative groups beside it.

const std = @import("std");
const ps1_core = @import("ps1_core");

const Allocator = std.mem.Allocator;
const command = ps1_core.gpu.command;
const Command = command.Command;
const Stream = command.Stream;
const recorder = ps1_core.gpu.recorder;

/// Where a frame is shown: the display start in VRAM, its size, its depth.
pub const Display = struct {
    vram_x: u32 = 0,
    vram_y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    depth24: bool = false,
    enabled: bool = false,
};

/// One frame's recorded GP0 stream, COPIED out of the core.
///
/// The copy is not defensive tidiness: `ps1_take_frame_stream` returns slices
/// into the recorder's own storage, valid only until the next `ps1_run_frame`.
/// Aliasing them would hand the renderer whichever frame the emulator happened
/// to be building when it looked.
///
/// Sized at the recorder's own capacities so the producer never allocates and
/// never truncates. About 10 MB per slot.
pub const StreamSlot = struct {
    records: []Command,
    payload: []u32,
    record_count: usize = 0,
    payload_count: usize = 0,
    seq: u64 = 0,

    fn init(alloc: Allocator) !StreamSlot {
        const records = try alloc.alloc(Command, recorder.max_records);
        errdefer alloc.free(records);
        return .{ .records = records, .payload = try alloc.alloc(u32, recorder.max_payload_words) };
    }

    fn deinit(self: *StreamSlot, alloc: Allocator) void {
        alloc.free(self.records);
        alloc.free(self.payload);
    }

    /// Whether `s` fits a slot whole. One that does not is refused rather
    /// than truncated: a truncated slot would be a silent prefix.
    fn fits(s: Stream) bool {
        return s.complete and s.records.len <= recorder.max_records and
            s.payload.len <= recorder.max_payload_words;
    }

    fn copy(self: *StreamSlot, s: Stream, seq: u64) void {
        @memcpy(self.records[0..s.records.len], s.records);
        @memcpy(self.payload[0..s.payload.len], s.payload);
        self.record_count = s.records.len;
        self.payload_count = s.payload.len;
        self.seq = seq;
    }

    /// The slot as the core's own stream type. Only a complete stream is ever
    /// copied into a slot, so this one is complete by construction.
    pub fn stream(self: *const StreamSlot) Stream {
        return .{
            .records = self.records[0..self.record_count],
            .payload = self.payload[0..self.payload_count],
            .complete = true,
        };
    }
};

/// Runahead's speculative frames: the picture N frames ahead of the real
/// timeline, replayed for display and then undone (`LiveRenderer`).
///
/// Only the NEWEST group can ever be shown: one followed by a real frame is
/// already stale. So they do not queue. Two buffers alternate, one the
/// consumer may be replaying and one the producer writes, and a group
/// committed before the last was taken simply replaces it.
pub const SpeculativeGroup = struct {
    slots: [StreamQueue.max_speculative_frames]StreamSlot,
    count: usize = 0,
    after_seq: u64 = 0,
    display: Display = .{},
    /// A frame was a prefix, or there were more frames than slots: a partial
    /// group would replay the wrong picture and restore the wrong region, so
    /// it is never handed over.
    spoiled: bool = false,

    pub fn frames(self: *SpeculativeGroup) []StreamSlot {
        return self.slots[0..self.count];
    }
};

/// Single-producer / single-consumer ring carrying frames from the emulator
/// thread to the render thread.
///
/// The producer's whole cost is one bounded memcpy: no allocation, no lock,
/// no wait. That is what keeps the emulator thread (audio-paced) off the
/// renderer's clock entirely.
///
/// `head` and `tail` are monotonic counters rather than wrapped indices, so a
/// full ring is `tail - head == capacity` and no slot is wasted to tell full
/// from empty.
pub const StreamQueue = struct {
    /// Five frames, where DuckStation queues two: a renderer that falls
    /// behind stops the producer instead of losing a frame, so depth no longer
    /// buys fewer drops, only a picture further behind the game's audio and
    /// input once the queue fills. Depth times the drain rate is a hard cap on
    /// emulated frames per second when the queue drains once per display
    /// refresh: three capped 4x speed at 180 fps, under NTSC's 240 and PAL's
    /// 200. Five clears both.
    pub const capacity = 5;
    /// The most runahead frames a group holds.
    pub const max_speculative_frames = 3;

    alloc: Allocator,
    slots: [capacity]StreamSlot,
    head: std.atomic.Value(u64) = .init(0),
    tail: std.atomic.Value(u64) = .init(0),

    /// Starts TRUE: the GPU texture's contents bear no relation to the shadow
    /// until the first frame lands, so the first drain adopts the shadow
    /// rather than assuming a blank match.
    ///
    /// This is the HARD condition ("the texture is not a picture of
    /// anything"), and its only remedy is adopting the shadow. Keep it
    /// distinct from `dropped`: they were one flag until the 8x flicker, and
    /// answering a lost frame with a full re-adoption is what put a 1x picture
    /// on screen.
    resync: std.atomic.Value(bool) = .init(true),

    /// One or more frames never reached the queue.
    ///
    /// The SOFT condition. The texture is still a faithful picture of every
    /// frame that did arrive; it is merely missing the mutations of the ones
    /// that did not, and those are gone from the stream for good either way.
    /// The consumer decides what to do about it, and the two answers differ by
    /// scale, which is knowledge this side of the queue does not have.
    dropped: std.atomic.Value(bool) = .init(false),

    /// The consumer wants a shadow newer than the last one published: see
    /// `wantsShadow`.
    shadow_wanted: std.atomic.Value(bool) = .init(false),

    /// Runahead's two group buffers and which of them is where. A lock rather
    /// than atomics: three indices change together, a few times a frame,
    /// never around a copy. A spin lock, because the critical sections are a
    /// handful of assignments (Zig 0.17 has no `std.Thread.Mutex`, and an
    /// `Io.Mutex` would thread an `Io` through both threads for nothing).
    groups: ?*[2]SpeculativeGroup = null,
    group_lock: std.atomic.Mutex = .unlocked,
    group_ready: ?u1 = null,
    group_reading: ?u1 = null,
    /// Producer-only.
    group_writing: ?u1 = null,
    /// Producer-only: a frame `stage` copied and `commitStaged` has not yet
    /// handed over.
    staged: bool = false,

    /// How often frames are published and lost: counters rather than the
    /// flags above, because the question they answer is HOW OFTEN.
    published_count: std.atomic.Value(u64) = .init(0),
    dropped_count: std.atomic.Value(u64) = .init(0),

    pub fn init(alloc: Allocator) !*StreamQueue {
        const self = try alloc.create(StreamQueue);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .slots = undefined };
        var made: usize = 0;
        errdefer for (self.slots[0..made]) |*s| s.deinit(alloc);
        while (made < capacity) : (made += 1) self.slots[made] = try StreamSlot.init(alloc);
        return self;
    }

    pub fn deinit(self: *StreamQueue) void {
        for (&self.slots) |*s| s.deinit(self.alloc);
        if (self.groups) |gs| {
            for (gs) |*g| for (&g.slots) |*s| s.deinit(self.alloc);
            self.alloc.destroy(gs);
        }
        self.alloc.destroy(self);
    }

    /// Loads `head` before `tail`, not the other way round: `head <= tail` is
    /// a standing invariant and `tail` only grows, so a head-then-tail read
    /// always subtracts a smaller-or-equal value from a larger-or-equal one.
    /// Reading `tail` first lets a concurrent drain move `head` past it, which
    /// underflows.
    pub fn pendingCount(self: *const StreamQueue) usize {
        const h = self.head.load(.acquire);
        return @intCast(self.tail.load(.acquire) -% h);
    }

    pub fn isFull(self: *const StreamQueue) bool {
        return self.pendingCount() >= capacity;
    }

    pub fn needsResync(self: *const StreamQueue) bool {
        return self.resync.load(.acquire);
    }

    pub fn requestResync(self: *StreamQueue) void {
        self.resync.store(true, .release);
    }

    pub fn clearResync(self: *StreamQueue) void {
        self.resync.store(false, .release);
    }

    pub fn hasDroppedFrames(self: *const StreamQueue) bool {
        return self.dropped.load(.acquire);
    }

    pub fn noteDroppedFrame(self: *StreamQueue) void {
        _ = self.dropped_count.fetchAdd(1, .monotonic);
        self.dropped.store(true, .release);
    }

    /// Reads and clears in one step, unlike `clearResync`.
    ///
    /// A plain store could swallow a drop the producer recorded between the
    /// read and the clear. `resync` gets away with that because clearing it
    /// early only costs a redundant re-adoption; clearing this one early would
    /// silently keep a stale picture with nothing left to say so.
    pub fn takeDroppedFrames(self: *StreamQueue) bool {
        return self.dropped.swap(false, .acq_rel);
    }

    /// Asks the producer for a shadow with its next frame: the consumer has a
    /// dropped frame to repair and the newest shadow predates frames it
    /// already executed.
    pub fn requestShadow(self: *StreamQueue) void {
        self.shadow_wanted.store(true, .release);
    }

    /// Whether the producer must publish a shadow with this frame, which it
    /// otherwise skips: copying VRAM waits for the raster worker. A resync and
    /// a dropped frame are both answered by adopting one, and either may have
    /// been raised since the consumer last asked. Clears the consumer's
    /// request, so call it once per frame, before publishing.
    pub fn wantsShadow(self: *StreamQueue) bool {
        const asked = self.shadow_wanted.swap(false, .acq_rel);
        return asked or self.needsResync() or self.hasDroppedFrames();
    }

    // Producer: emulator thread only.

    /// Copies one frame into the ring.
    ///
    /// Three conditions lose the frame instead of enqueuing it, and all three
    /// lose it the same way (its mutations never reach the consumer), so the
    /// policy lives here rather than at each call site: an incomplete stream
    /// (a prefix), a frame too large for a slot, and a full ring. A renderer
    /// that is merely behind never fills it, because the producer waits first;
    /// a full ring here means one that stopped draining (a hidden window, a
    /// torn-down view).
    ///
    /// All three note a DROP, not a resync. None of them says anything about
    /// the consumer's texture, which is still exactly the frames it executed;
    /// conflating the two is what made a renderer that fell behind at 8x
    /// re-adopt a native shadow and collapse the picture to 1x.
    pub fn publish(self: *StreamQueue, seq: u64, s: Stream) void {
        if (self.stage(seq, s)) self.commitStaged();
    }

    /// `publish`'s first half: copies the frame into the next slot without
    /// handing it over. Runahead stages the real frame, runs its speculative
    /// frames, commits their group and only then `commitStaged`s, so a drain
    /// never sees the real frame without the group that follows it, which
    /// would put a picture without runahead on screen for a frame. Returns
    /// false, having noted the drop, when `publish` would have dropped it.
    pub fn stage(self: *StreamQueue, seq: u64, s: Stream) bool {
        if (!StreamSlot.fits(s)) {
            self.noteDroppedFrame();
            return false;
        }
        const t = self.tail.load(.monotonic);
        if (t -% self.head.load(.acquire) >= capacity) {
            self.noteDroppedFrame();
            return false;
        }
        self.slots[@intCast(t % capacity)].copy(s, seq);
        self.staged = true;
        return true;
    }

    /// Hands over the frame `stage` copied, if it copied one.
    pub fn commitStaged(self: *StreamQueue) void {
        if (!self.staged) return;
        self.staged = false;
        // Release: everything written into the slot must be visible to the
        // consumer before it can observe the new tail.
        self.tail.store(self.tail.load(.monotonic) +% 1, .release);
        _ = self.published_count.fetchAdd(1, .monotonic);
    }

    /// Starts a group that runs ahead of real frame `after`, in whichever
    /// buffer the consumer is not replaying. The buffers are allocated the
    /// first time runahead runs; if that allocation fails the group is simply
    /// never started, and appends and the commit do nothing.
    pub fn beginSpeculativeGroup(self: *StreamQueue, after: u64) void {
        self.lock();
        if (self.groups == null) self.groups = self.allocGroups() catch null;
        const gs = self.groups orelse {
            self.group_writing = null;
            self.unlock();
            return;
        };
        const free: u1 = if (self.group_reading) |r| ~r else if (self.group_ready == 0) 1 else 0;
        // A committed group the consumer never took is superseded by this one.
        if (self.group_ready == free) self.group_ready = null;
        self.group_writing = free;
        self.unlock();

        const g = &gs[free];
        g.count = 0;
        g.after_seq = after;
        g.spoiled = false;
    }

    pub fn appendSpeculative(self: *StreamQueue, s: Stream) void {
        const w = self.group_writing orelse return;
        const g = &self.groups.?[w];
        if (!StreamSlot.fits(s) or g.count >= max_speculative_frames) {
            g.spoiled = true;
            return;
        }
        g.slots[g.count].copy(s, g.after_seq);
        g.count += 1;
    }

    /// Hands the group over. `display` is its last frame's: a game that flips
    /// buffers shows the speculative picture somewhere else.
    pub fn commitSpeculativeGroup(self: *StreamQueue, display: Display) void {
        const w = self.group_writing orelse return;
        const g = &self.groups.?[w];
        g.display = display;
        self.lock();
        self.group_writing = null;
        self.group_ready = if (g.spoiled or g.count == 0) null else w;
        self.unlock();
    }

    // Consumer: render thread only.

    /// Hands every queued slot to `body`, oldest first.
    ///
    /// Drain-ALL, not take-newest: a command stream is a set of incremental
    /// mutations, so a skipped frame is lost permanently. Only PRESENTATION is
    /// allowed to skip.
    pub fn drain(
        self: *StreamQueue,
        ctx: anytype,
        comptime body: fn (@TypeOf(ctx), *const StreamSlot) void,
    ) void {
        var h = self.head.load(.monotonic);
        const t = self.tail.load(.acquire);
        while (h < t) {
            body(ctx, &self.slots[@intCast(h % capacity)]);
            h +%= 1;
            self.head.store(h, .release);
        }
    }

    /// Drops every queued frame at or below `seq`, and returns the seq of the
    /// oldest frame still queued: null when the ring is now empty.
    ///
    /// This is the resync's discard half, and the bound is the whole point.
    /// A resync adopts one sampled shadow, tagged with the seq it was
    /// published under; frames at or below that seq are ALREADY folded into
    /// it, and replaying one applies its mutations a second time: VRAM->VRAM
    /// copies, semi-transparent blends and mask-bit draws are not idempotent,
    /// so that is permanent corruption rather than a transient. Frames above
    /// it are not in the shadow at all, and dropping them loses their
    /// mutations for good. The producer publishes VRAM before the stream, so
    /// a queued stream can be newer than the newest shadow but never older
    /// than its own.
    pub fn discardThrough(self: *StreamQueue, seq: u64) ?u64 {
        var h = self.head.load(.monotonic);
        const t = self.tail.load(.acquire);
        while (h < t) {
            // Safe to read: the producer writes only the slot at `tail`, and
            // it cannot reach an unconsumed `h` without the ring exceeding
            // `capacity`, which `stage` refuses.
            const s = self.slots[@intCast(h % capacity)].seq;
            if (s > seq) return s;
            h +%= 1;
            self.head.store(h, .release);
        }
        return null;
    }

    /// Drops the whole backlog without executing it. Only ever correct as half
    /// of a resync whose shadow is known to be at least as new as everything
    /// queued: `discardThrough` is the form that establishes that rather than
    /// assuming it. Returns the seq of the newest frame dropped, null when
    /// none was queued.
    pub fn discardAll(self: *StreamQueue) ?u64 {
        const h = self.head.load(.monotonic);
        const t = self.tail.load(.acquire);
        if (h >= t) return null;
        const last = self.slots[@intCast((t -% 1) % capacity)].seq;
        self.head.store(t, .release);
        return last;
    }

    /// The newest committed group if it runs ahead of real frame `after`,
    /// held for the consumer until `releaseSpeculativeGroup`. A group ahead
    /// of an older frame is stale and is dropped; one ahead of a newer frame
    /// waits for that frame to be executed.
    pub fn takeSpeculativeGroup(self: *StreamQueue, after: u64) ?*SpeculativeGroup {
        self.lock();
        defer self.unlock();
        const r = self.group_ready orelse return null;
        const g = &self.groups.?[r];
        if (g.after_seq > after) return null;
        self.group_ready = null;
        if (g.after_seq != after) return null;
        self.group_reading = r;
        return g;
    }

    pub fn releaseSpeculativeGroup(self: *StreamQueue) void {
        self.lock();
        self.group_reading = null;
        self.unlock();
    }

    fn allocGroups(self: *StreamQueue) !*[2]SpeculativeGroup {
        const gs = try self.alloc.create([2]SpeculativeGroup);
        errdefer self.alloc.destroy(gs);
        var made: usize = 0;
        errdefer for (0..made) |i| gs[i / max_speculative_frames].slots[i % max_speculative_frames].deinit(self.alloc);
        for (gs) |*g| {
            g.* = .{ .slots = undefined };
            for (&g.slots) |*s| {
                s.* = try StreamSlot.init(self.alloc);
                made += 1;
            }
        }
        return gs;
    }

    fn lock(self: *StreamQueue) void {
        while (!self.group_lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *StreamQueue) void {
        self.group_lock.unlock();
    }
};
