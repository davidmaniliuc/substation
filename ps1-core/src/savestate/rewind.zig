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
//! A capture is written straight over `head` (`Diff`), which saves each
//! changed word into the delta as it goes. Writing it elsewhere and comparing
//! after cost twice the memory traffic, and that traffic was the capture.
//!
//! The PGXP shadows are not captured. An entry would grow by 10.5 MB, and
//! PGXP refills within a frame or two of the player letting go.

const std = @import("std");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const savestate = @import("savestate.zig");

pub const word = 8;

/// Frames between two captures.
pub const capture_interval = 2;

/// Frames the host runs after a step for its picture, none of which
/// captures. A step's shadow is native, and a double-buffered game shows the
/// buffer it drew in the frame BEFORE: one frame puts that 1x shadow on
/// screen, two cover a 60 fps game, and a 30 fps game needs a whole draw
/// period after the shadow, flip included, which is four.
pub const picture_frames = 4;

pub const Error = savestate.Error || error{ NoHistory, OutOfMemory };

const run_header = 2 * @sizeOf(u32);

/// Words compared at once while skipping the equal stretches, which are
/// nearly all of a capture.
const lanes = 8;
const Lanes = @Vector(lanes, u64);

/// Writes a capture over the one before it, appending to `out` the runs that
/// turn it back. Bytes arrive in order, in pieces of any length.
pub const Diff = struct {
    head: []u8,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    /// The older word under the write position while a piece has left it
    /// part-written.
    carry: u64 = 0,
    /// Where the open run's header sits in `out`; null between runs.
    run_at: ?usize = null,

    pub fn write(d: *Diff, pos: usize, b: []const u8) error{OutOfMemory}!void {
        std.debug.assert(pos + b.len <= d.head.len);
        var off: usize = 0;
        while (off < b.len) {
            const p = pos + off;
            const in_word = p % word;
            const k: u32 = @intCast(p / word);
            // `@reduce`, not a lane mask: arm64 has no movemask, and
            // building one lane by lane cost seven times the whole compare.
            if (in_word == 0 and b.len - off >= lanes * word and
                !@reduce(.Or, lanesAt(b[off..], 0) != lanesAt(d.head, k)))
            {
                d.run_at = null;
                off += lanes * word;
                continue;
            }
            const take = @min(word - in_word, b.len - off);
            const older = if (in_word == 0) wordAt(d.head, k) else d.carry;
            @memcpy(d.head[p..][0..take], b[off..][0..take]);
            off += take;
            if (in_word + take < word) {
                d.carry = older;
                continue;
            }
            try d.wordDone(k, older);
        }
    }

    /// Zeroes `head` from `len` to its end, as everything past a capture's
    /// length is in both captures.
    pub fn finish(d: *Diff, len: usize) error{OutOfMemory}!void {
        const zeros: [lanes * word]u8 = @splat(0);
        var p = len;
        while (p < d.head.len) {
            const n = @min(zeros.len, d.head.len - p);
            try d.write(p, zeros[0..n]);
            p += n;
        }
        d.run_at = null;
    }

    fn wordDone(d: *Diff, k: u32, older: u64) error{OutOfMemory}!void {
        if (older == wordAt(d.head, k)) {
            d.run_at = null;
            return;
        }
        try d.out.ensureUnusedCapacity(d.allocator, run_header + word);
        if (d.run_at) |at| {
            const count = std.mem.readInt(u32, d.out.items[at + 4 ..][0..4], .little);
            std.mem.writeInt(u32, d.out.items[at + 4 ..][0..4], count + 1, .little);
        } else {
            d.run_at = d.out.items.len;
            const one: u32 = 1;
            d.out.appendSliceAssumeCapacity(std.mem.asBytes(&k));
            d.out.appendSliceAssumeCapacity(std.mem.asBytes(&one));
        }
        d.out.appendSliceAssumeCapacity(std.mem.asBytes(&older));
    }
};

/// Writes `newer` over `older`, appending to `out` the runs that turn it
/// back. Both are the same length, a multiple of `word`.
pub fn encode(newer: []const u8, older: []u8, out: *std.ArrayList(u8), a: std.mem.Allocator) error{OutOfMemory}!void {
    std.debug.assert(newer.len == older.len and newer.len % word == 0);
    var d = Diff{ .head = older, .out = out, .allocator = a };
    try d.write(0, newer);
    try d.finish(newer.len);
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

inline fn wordAt(buf: []const u8, i: u32) u64 {
    return std.mem.readInt(u64, buf[i * word ..][0..word], .little);
}

inline fn lanesAt(buf: []const u8, i: u32) Lanes {
    return std.mem.bytesToValue([lanes]u64, buf[i * word ..][0 .. lanes * word]);
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
    /// The newest capture, which the next is written over. Zero past its
    /// state's length, so a delta can compare it whole.
    head: []u8 = &.{},
    head_len: usize = 0,
    has_head: bool = false,
    /// Oldest first; a step pops from the end.
    entries: std.ArrayList(Entry) = .empty,
    entry_bytes: usize = 0,
    frames_since: u32 = 0,
    /// Frames since the last step that may not capture: see `picture_frames`.
    picture_left: u32 = 0,
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

    /// Sets the memory budget in bytes, `head` included. 0 turns
    /// rewind off and frees everything. A change keeps what still fits.
    pub fn configure(r: *Rewind, budget: usize) error{OutOfMemory}!void {
        r.budget = budget;
        if (budget == 0) {
            r.clear();
            r.allocator.free(r.head);
            r.head = &.{};
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
        r.picture_left = 0;
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
        return r.entry_bytes + r.head.len;
    }

    /// Called once per frame run; captures every `capture_interval`.
    pub fn frameDone(r: *Rewind, cpu: *const Cpu) error{OutOfMemory}!void {
        if (!r.enabled()) return;
        r.frames_since += 1;
        if (r.picture_left > 0) {
            r.picture_left -= 1;
            return;
        }
        if (r.frames_since < capture_interval) return;
        try r.capture(cpu);
    }

    fn capture(r: *Rewind, cpu: *const Cpu) error{OutOfMemory}!void {
        // Counting never fails, and `head` is sized from that count.
        const n = savestate.saveTrusted(cpu, null) catch unreachable;
        try r.reserve(n);
        if (!r.has_head) {
            _ = savestate.saveTrusted(cpu, r.head) catch unreachable;
            @memset(r.head[n..], 0);
        } else {
            // From the first word written, `head` is no longer the capture
            // the last entry turns back into; a failure must drop them all.
            errdefer r.clear();
            r.encoded.clearRetainingCapacity();
            var diff = Diff{ .head = r.head, .out = &r.encoded, .allocator = r.allocator };
            _ = savestate.saveTrustedOver(cpu, &diff) catch return error.OutOfMemory;
            try diff.finish(n);
            const delta = try r.allocator.dupe(u8, r.encoded.items);
            errdefer r.allocator.free(delta);
            try r.entries.append(r.allocator, .{ .delta = delta, .older_len = r.head_len, .frames = r.frames_since });
            r.entry_bytes += delta.len;
        }
        r.head_len = n;
        r.has_head = true;
        r.frames_since = 0;
        r.evict();
    }

    /// Grows `head` to hold a state of `n` bytes. A build's state size is
    /// fixed, so this allocates once; growing keeps `head` and pads it.
    fn reserve(r: *Rewind, n: usize) error{OutOfMemory}!void {
        const cap = std.mem.alignForward(usize, n, word);
        if (r.head.len >= cap) return;
        const head = try r.allocator.alloc(u8, cap);
        @memcpy(head[0..r.head.len], r.head);
        @memset(head[r.head.len..], 0);
        r.allocator.free(r.head);
        r.head = head;
        // An entry's runs address words of the old capacity, which the
        // larger buffer still holds at the same offsets.
    }

    fn evict(r: *Rewind) void {
        var drop: usize = 0;
        var used = r.bytesUsed();
        while (drop < r.entries.items.len and used > r.budget) : (drop += 1) {
            used -= r.entries.items[drop].delta.len;
        }
        if (drop == 0) return;
        for (r.entries.items[0..drop]) |e| r.allocator.free(e.delta);
        r.entry_bytes = used - r.head.len;
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
        r.picture_left = picture_frames;
        try savestate.loadTrusted(cpu, r.head[0..r.head_len]);
    }
};
