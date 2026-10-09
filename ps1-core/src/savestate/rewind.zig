//! Rewind: a ring of reverse deltas over trusted snapshots.
//!
//! `head` holds the newest capture in full. Each entry turns one capture back
//! into the capture before it, so stepping back is one delta applied to
//! `head` and one in-place load. Nothing depends on the OLDEST entry, which
//! is why the budget can always free it: there are no keyframes to keep.
//!
//! A delta is runs of changed 8-byte words, `(word offset u32, word count
//! u32, the older words)`. Two captures a few frames apart share almost every
//! word, and the runs that differ are mostly real changes, so the deltas are
//! not compressed further: the budget already bounds the memory.
//!
//! The PGXP shadows are not captured. An entry would grow by 10.5 MB, and
//! PGXP refills within a frame or two of the player letting go.

const std = @import("std");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const savestate = @import("savestate.zig");

pub const word = 8;

/// Frames between two captures. Rewinding plays one shown frame per step,
/// so it runs backwards at half the game's own rate.
pub const capture_interval = 2;

pub const Error = savestate.Error || error{ NoHistory, OutOfMemory };

const run_header = 2 * @sizeOf(u32);

/// Appends to `out` the runs that turn `newer` back into `older`. Both are
/// the same length, a multiple of `word`.
pub fn encode(newer: []const u8, older: []const u8, out: *std.ArrayList(u8), a: std.mem.Allocator) error{OutOfMemory}!void {
    std.debug.assert(newer.len == older.len and newer.len % word == 0);
    const n: u32 = @intCast(newer.len / word);
    var i: u32 = 0;
    while (i < n) {
        if (wordAt(newer, i) == wordAt(older, i)) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < n and wordAt(newer, i) != wordAt(older, i)) i += 1;
        const count = i - start;
        try out.ensureUnusedCapacity(a, run_header + count * word);
        out.appendSliceAssumeCapacity(std.mem.asBytes(&start));
        out.appendSliceAssumeCapacity(std.mem.asBytes(&count));
        out.appendSliceAssumeCapacity(older[start * word ..][0 .. count * word]);
    }
}

/// Writes a delta's older words over `buf`.
pub fn apply(delta: []const u8, buf: []u8) void {
    var p: usize = 0;
    while (p < delta.len) {
        const start = std.mem.readInt(u32, delta[p..][0..4], .little);
        const count = std.mem.readInt(u32, delta[p + 4 ..][0..4], .little);
        p += run_header;
        const len = count * word;
        @memcpy(buf[start * word ..][0..len], delta[p..][0..len]);
        p += len;
    }
}

fn wordAt(buf: []const u8, i: u32) u64 {
    return std.mem.readInt(u64, buf[i * word ..][0..word], .little);
}

const Entry = struct {
    delta: []u8,
    /// The older capture's own length, which `head` takes back on a step.
    older_len: usize,
    /// Frames between the older capture and the newer one.
    frames: u32,
};

pub const Info = struct {
    entries: u32 = 0,
    frames_covered: u32 = 0,
    bytes_used: usize = 0,
};

pub const Rewind = struct {
    allocator: std.mem.Allocator,
    /// 0 is off: no buffers, no captures.
    budget: usize = 0,
    /// The newest capture, and the scratch the next one is written into.
    /// Both are zero past their state's length, up to their common
    /// capacity, so a delta can compare them whole.
    head: []u8 = &.{},
    scratch: []u8 = &.{},
    head_len: usize = 0,
    has_head: bool = false,
    /// Oldest first; a step pops from the end.
    entries: std.ArrayList(Entry) = .empty,
    entry_bytes: usize = 0,
    frames_since: u32 = 0,
    encoded: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Rewind {
        return .{ .allocator = allocator };
    }

    pub fn deinit(r: *Rewind) void {
        r.configure(0) catch unreachable;
        r.entries.deinit(r.allocator);
        r.encoded.deinit(r.allocator);
        r.* = undefined;
    }

    pub fn enabled(r: *const Rewind) bool {
        return r.budget != 0;
    }

    /// Sets the memory budget in bytes, the two buffers included. 0 turns
    /// rewind off and frees everything. A change keeps what still fits.
    pub fn configure(r: *Rewind, budget: usize) error{OutOfMemory}!void {
        r.budget = budget;
        if (budget == 0) {
            r.clear();
            r.allocator.free(r.head);
            r.allocator.free(r.scratch);
            r.head = &.{};
            r.scratch = &.{};
            r.encoded.clearAndFree(r.allocator);
            return;
        }
        r.evict();
    }

    /// Forgets every capture: the machine moved somewhere history cannot
    /// follow (a reset, a state load, a disc change).
    pub fn clear(r: *Rewind) void {
        for (r.entries.items) |e| r.allocator.free(e.delta);
        r.entries.clearRetainingCapacity();
        r.entry_bytes = 0;
        r.has_head = false;
        r.frames_since = 0;
    }

    pub fn info(r: *const Rewind) Info {
        var frames: u32 = 0;
        for (r.entries.items) |e| frames += e.frames;
        return .{
            .entries = @intCast(r.entries.items.len),
            .frames_covered = frames,
            .bytes_used = r.bytesUsed(),
        };
    }

    fn bytesUsed(r: *const Rewind) usize {
        return r.entry_bytes + r.head.len + r.scratch.len;
    }

    /// Called once per frame run; captures every `capture_interval`.
    pub fn frameDone(r: *Rewind, cpu: *const Cpu) error{OutOfMemory}!void {
        if (!r.enabled()) return;
        r.frames_since += 1;
        if (r.frames_since < capture_interval) return;
        try r.capture(cpu);
    }

    fn capture(r: *Rewind, cpu: *const Cpu) error{OutOfMemory}!void {
        // Counting never fails, and the buffers are sized from that count.
        const n = savestate.saveTrusted(cpu, null) catch unreachable;
        try r.reserve(n);
        _ = savestate.saveTrusted(cpu, r.scratch) catch unreachable;
        @memset(r.scratch[n..], 0);

        if (r.has_head) {
            r.encoded.clearRetainingCapacity();
            try encode(r.scratch, r.head, &r.encoded, r.allocator);
            const delta = try r.allocator.dupe(u8, r.encoded.items);
            errdefer r.allocator.free(delta);
            try r.entries.append(r.allocator, .{ .delta = delta, .older_len = r.head_len, .frames = r.frames_since });
            r.entry_bytes += delta.len;
        }
        std.mem.swap([]u8, &r.head, &r.scratch);
        r.head_len = n;
        r.has_head = true;
        r.frames_since = 0;
        r.evict();
    }

    /// Grows both buffers to hold a state of `n` bytes. A build's state size
    /// is fixed, so this allocates once; growing keeps `head` and pads it.
    fn reserve(r: *Rewind, n: usize) error{OutOfMemory}!void {
        const cap = std.mem.alignForward(usize, n, word);
        if (r.head.len >= cap) return;
        const head = try r.allocator.alloc(u8, cap);
        errdefer r.allocator.free(head);
        const scratch = try r.allocator.alloc(u8, cap);
        @memcpy(head[0..r.head.len], r.head);
        @memset(head[r.head.len..], 0);
        r.allocator.free(r.head);
        r.allocator.free(r.scratch);
        r.head = head;
        r.scratch = scratch;
        // An entry's runs address words of the old capacity, which the
        // larger buffers still hold at the same offsets.
    }

    fn evict(r: *Rewind) void {
        var drop: usize = 0;
        var used = r.bytesUsed();
        while (drop < r.entries.items.len and used > r.budget) : (drop += 1) {
            used -= r.entries.items[drop].delta.len;
        }
        if (drop == 0) return;
        for (r.entries.items[0..drop]) |e| r.allocator.free(e.delta);
        r.entry_bytes = used - r.head.len - r.scratch.len;
        r.entries.replaceRangeAssumeCapacity(0, drop, &.{});
    }

    /// Returns the machine IN PLACE to the capture before `head`, which
    /// becomes the new head. With no entry left the machine is untouched.
    pub fn step(r: *Rewind, cpu: *Cpu) Error!void {
        const e = r.entries.pop() orelse return error.NoHistory;
        defer r.allocator.free(e.delta);
        r.entry_bytes -= e.delta.len;
        apply(e.delta, r.head);
        r.head_len = e.older_len;
        r.frames_since = 0;
        try savestate.loadTrusted(cpu, r.head[0..r.head_len]);
    }
};
