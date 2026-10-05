//! The software rasterizer on a second thread.
//!
//! The emulator thread is the only producer and the worker the only consumer
//! of two single-producer/single-consumer rings: records, and the CPU->VRAM
//! payload words the upload records point into. The worker runs the same
//! `command.execute` the inline path runs, on its own copy of the drawing
//! environment, so threading changes WHEN a pixel lands and never which
//! pixel. `sync` is how the emulator thread waits for "now".
//!
//! `.deferred` runs no thread: nothing executes until a sync, or a full ring,
//! drains the queue on the caller's thread. A sync point missing from the
//! emulator side then reads stale VRAM on every run instead of only when the
//! worker happens to lose a race, which is what lets
//! `verify --threaded=deferred` fail.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const command = @import("command.zig");
const Vram = @import("vram.zig").Vram;
const DrawingEnv = @import("registers.zig").DrawingEnv;

/// There is no second thread on a single-threaded target (the wasm build).
pub const available = !builtin.single_threaded;

/// Records in flight. Covers `stream-verify`'s per-frame peak, so an
/// ordinary frame never waits for space; a frame that outgrows it waits.
/// Peak measured 2026-10-05 (`stream-verify`, nine workloads): 3,711
/// records (crash-bandicoot-europe-edc); the others 236 to 3,289. Payload
/// peaks reach 131,072 words (spyro) against `ring_payload`.
const record_slots: u32 = 16_384;
/// Upload words in flight: one whole-VRAM upload.
pub const ring_payload: u32 = 262_144;
/// An upload run is published once it reaches this many words. The consumer
/// frees payload only from published runs, so an open run must never be able
/// to fill the ring; publishing early also starts a long upload sooner.
pub const max_run: u32 = 4096;
/// Polls before a waiter sleeps. The waits worth spinning for are a few
/// microseconds; anything longer sleeps rather than heating a fanless
/// machine.
const spin_limit: u32 = 1024;

comptime {
    // The counters are free-running u32s and a slot is the counter modulo
    // the ring, which survives the u32 wrap only for a power of two.
    std.debug.assert(std.math.isPowerOfTwo(record_slots));
    std.debug.assert(std.math.isPowerOfTwo(ring_payload));
    std.debug.assert(max_run < ring_payload);
}

/// An event count. A waiter sleeps on `seq` only after announcing itself in
/// `waiting` and re-testing its condition; a notifier bumps `seq` only when
/// someone has announced. Every access is seq_cst, so either the waiter's
/// re-test sees the new state or the notifier sees the waiter, and a bump
/// that lands between the re-test and the sleep makes the futex return at
/// once because `seq` no longer matches.
const Signal = struct {
    seq: std.atomic.Value(u32) = .init(0),
    waiting: std.atomic.Value(u32) = .init(0),

    fn wait(s: *Signal, io: Io, w: *RasterWorker, comptime ready: fn (*RasterWorker) bool) void {
        var spins: u32 = 0;
        while (!ready(w)) {
            if (spins < spin_limit) {
                spins += 1;
                std.atomic.spinLoopHint();
                continue;
            }
            const seq = s.seq.load(.seq_cst);
            s.waiting.store(1, .seq_cst);
            if (!ready(w)) io.futexWaitUncancelable(u32, &s.seq.raw, seq);
            s.waiting.store(0, .seq_cst);
        }
    }

    fn notify(s: *Signal, io: Io) void {
        if (s.waiting.load(.seq_cst) == 0) return;
        _ = s.seq.fetchAdd(1, .seq_cst);
        io.futexWake(u32, &s.seq.raw, 1);
    }
};

pub const RasterWorker = struct {
    pub const Mode = enum { thread, deferred };
    /// Records in flight; tests size their floods off it.
    pub const ring_records = record_slots;

    records: []command.Command,
    payload: []u32,

    /// Records published by the producer and executed by the consumer.
    /// Free-running: the slot is the count modulo `record_slots`.
    head: std.atomic.Value(u32) = .init(0),
    tail: std.atomic.Value(u32) = .init(0),
    /// Payload words written by the producer and consumed by the consumer.
    payload_head: u32 = 0,
    payload_tail: std.atomic.Value(u32) = .init(0),
    /// The upload run being built: its first word's slot and its length.
    /// The consumer cannot see it until `closeRun` publishes it.
    run_start: u32 = 0,
    run_len: u32 = 0,

    /// The consumer sleeps on `work`, the producer on `space`.
    work: Signal = .{},
    space: Signal = .{},
    quit: std.atomic.Value(bool) = .init(false),

    vram: *Vram,
    /// Equal to `Gpu.draw_env` at every record: both start from the same
    /// value and apply the same env records in the same order.
    env: DrawingEnv,
    io: Io,
    allocator: std.mem.Allocator,
    thread: ?std.Thread = null,

    pub fn create(allocator: std.mem.Allocator, io: Io, vram: *Vram, env: DrawingEnv, mode: Mode) !*RasterWorker {
        if (comptime !available) return error.Unsupported;
        const w = try allocator.create(RasterWorker);
        errdefer allocator.destroy(w);
        const records = try allocator.alloc(command.Command, record_slots);
        errdefer allocator.free(records);
        const payload = try allocator.alloc(u32, ring_payload);
        errdefer allocator.free(payload);
        w.* = .{
            .records = records,
            .payload = payload,
            .vram = vram,
            .env = env,
            .io = io,
            .allocator = allocator,
        };
        if (mode == .thread) w.thread = try std.Thread.spawn(.{}, consume, .{w});
        return w;
    }

    /// Drains the queue, stops the thread and frees everything.
    pub fn destroy(w: *RasterWorker) void {
        w.sync();
        if (comptime available) {
            if (w.thread) |t| {
                w.quit.store(true, .seq_cst);
                w.work.notify(w.io);
                t.join();
            }
        }
        const allocator = w.allocator;
        allocator.free(w.records);
        allocator.free(w.payload);
        allocator.destroy(w);
    }

    // The producer side: the emulator thread only.

    pub fn push(w: *RasterWorker, cmd: command.Command) void {
        w.closeRun();
        w.publish(cmd);
    }

    pub fn pushWord(w: *RasterWorker, word: u32) void {
        const slot = w.payload_head % ring_payload;
        // A run is one contiguous slice of the ring: it closes at the wrap.
        if (w.run_len == max_run or (w.run_len > 0 and slot == 0)) w.closeRun();
        w.waitFor(&w.space, payloadFree);
        w.payload[slot] = word;
        if (w.run_len == 0) w.run_start = slot;
        w.run_len += 1;
        w.payload_head +%= 1;
    }

    /// Returns once everything pushed so far has executed. Until its next
    /// push, the emulator thread may then read `vram`: pixels, depth and
    /// the transfer fields.
    pub fn sync(w: *RasterWorker) void {
        w.closeRun();
        w.waitFor(&w.space, idle);
    }

    fn closeRun(w: *RasterWorker) void {
        if (w.run_len == 0) return;
        const len = w.run_len;
        w.run_len = 0;
        w.publish(.{ .kind = .vram_write_data, .x = @intCast(w.run_start), .y = @intCast(len) });
    }

    fn publish(w: *RasterWorker, cmd: command.Command) void {
        w.waitFor(&w.space, recordFree);
        const h = w.head.load(.monotonic);
        w.records[h % record_slots] = cmd;
        w.head.store(h +% 1, .seq_cst);
        w.work.notify(w.io);
    }

    /// A deferred worker has no one to wait for: it does the work itself.
    fn waitFor(w: *RasterWorker, s: *Signal, comptime ready: fn (*RasterWorker) bool) void {
        if (w.thread == null) {
            if (!ready(w)) w.drain();
            return;
        }
        s.wait(w.io, w, ready);
    }

    fn idle(w: *RasterWorker) bool {
        return w.tail.load(.seq_cst) == w.head.load(.monotonic);
    }

    fn recordFree(w: *RasterWorker) bool {
        return w.head.load(.monotonic) -% w.tail.load(.seq_cst) < record_slots;
    }

    fn payloadFree(w: *RasterWorker) bool {
        return w.payload_head -% w.payload_tail.load(.seq_cst) < ring_payload;
    }

    // The consumer side: the worker thread, or the caller under `.deferred`.

    fn consume(w: *RasterWorker) void {
        while (true) {
            w.work.wait(w.io, w, pendingOrQuit);
            // `destroy` syncs before it quits, so quit finds the ring empty.
            if (!w.pending()) return;
            w.executeNext();
        }
    }

    fn drain(w: *RasterWorker) void {
        while (w.pending()) w.executeNext();
    }

    fn pending(w: *RasterWorker) bool {
        return w.head.load(.seq_cst) != w.tail.load(.monotonic);
    }

    fn pendingOrQuit(w: *RasterWorker) bool {
        return w.pending() or w.quit.load(.seq_cst);
    }

    fn executeNext(w: *RasterWorker) void {
        const t = w.tail.load(.monotonic);
        const cmd = w.records[t % record_slots];
        command.execute(cmd, w.payload, w.vram, &w.env);
        if (cmd.kind == .vram_write_data) {
            const len: u32 = @intCast(cmd.y);
            w.payload_tail.store(w.payload_tail.load(.monotonic) +% len, .seq_cst);
        }
        w.tail.store(t +% 1, .seq_cst);
        w.space.notify(w.io);
    }
};
