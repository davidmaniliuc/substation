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
//! Under a GPU-only renderer the machine's VRAM comes back from the host
//! some frames after the capture that needs it, so a capture can be taken
//! with its VRAM bytes KEPT (`defer_vram`) and filled later (`fillVram`) by a
//! second diff appended to its entry. Captures are filled oldest first, which
//! is what makes that diff exact: `head`'s VRAM bytes then always hold the
//! newest FILLED capture's VRAM, which is what the oldest pending capture's
//! entry must turn back into. A capture whose VRAM cannot come is dropped
//! with every newer one (`dropVramFrom`), since entries chain.
//!
//! The PGXP shadows are not captured. An entry would grow by 10.5 MB, and
//! PGXP refills within a frame or two of the player letting go.

const std = @import("std");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const savestate = @import("savestate.zig");
const native_pixels = @import("stream.zig").native_pixels;

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

    /// Leaves `head[pos..pos + len]` as it is and records nothing for those
    /// bytes: exactly what writing them again would do, so a range holding a
    /// whole word closes the open run. A word the range only partly covers
    /// is compared whole, as a write would compare it. Like `write`, it
    /// continues a stream begun at a word boundary.
    pub fn keep(d: *Diff, pos: usize, len: usize) error{OutOfMemory}!void {
        const end = pos + len;
        std.debug.assert(end <= d.head.len);
        const first_whole = @min(std.mem.alignForward(usize, pos, word), end);
        const last_whole = @max(std.mem.alignBackward(usize, end, word), first_whole);
        try d.rewrite(pos, first_whole);
        if (last_whole > first_whole) d.run_at = null;
        try d.rewrite(last_whole, end);
    }

    /// Writes `head[from..to]`, within one word, over itself.
    fn rewrite(d: *Diff, from: usize, to: usize) error{OutOfMemory}!void {
        var same: [word]u8 = undefined;
        const n = to - from;
        @memcpy(same[0..n], d.head[from..to]);
        try d.write(from, same[0..n]);
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
    /// The NEWER capture's id: the one this entry turns back.
    id: u64,
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
    /// Set by the host whose VRAM arrives later: captures then keep VRAM's
    /// bytes and wait for `fillVram`.
    defer_vram: bool = false,
    /// The id the next capture takes. A dropped capture's id is taken again,
    /// so the pending ids are always one unbroken range.
    next_id: u64 = 0,
    /// The oldest capture still waiting for its VRAM; every capture after it
    /// waits too.
    pending_from: ?u64 = null,
    /// Where the pending captures' VRAM bytes sit in `head`.
    pending_vram_at: usize = 0,

    /// Captures waiting for their VRAM, both ends inclusive.
    pub const PendingVram = struct { first: u64, last: u64 };

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
        r.pending_from = null;
    }

    pub fn pendingVram(r: *const Rewind) ?PendingVram {
        const first = r.pending_from orelse return null;
        return .{ .first = first, .last = r.next_id - 1 };
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
        cpu.bus.gpu.syncRaster();
        const layout = savestate.trustedLayout(cpu);
        // A capture written whole, or with its VRAM somewhere else, would
        // leave `head`'s VRAM bytes no longer the ones the pending captures'
        // fills diff against.
        if (r.pending_from) |first| {
            if (!r.defer_vram or layout.vram_at != r.pending_vram_at) r.dropVramFrom(first);
        }
        const vram: savestate.VramBytes = if (r.defer_vram) .keep else .write;
        const n = layout.len;
        try r.reserve(n);
        if (!r.has_head) {
            _ = savestate.saveTrusted(cpu, r.head, vram) catch unreachable;
            @memset(r.head[n..], 0);
        } else {
            // From the first word written, `head` is no longer the capture
            // the last entry turns back into; a failure must drop them all.
            errdefer r.clear();
            r.encoded.clearRetainingCapacity();
            var diff = Diff{ .head = r.head, .out = &r.encoded, .allocator = r.allocator };
            _ = savestate.saveTrustedOver(cpu, &diff, vram) catch return error.OutOfMemory;
            try diff.finish(n);
            const delta = try r.allocator.dupe(u8, r.encoded.items);
            errdefer r.allocator.free(delta);
            try r.entries.append(r.allocator, .{ .id = r.next_id, .delta = delta, .older_len = r.head_len, .frames = r.frames_since });
            r.entry_bytes += delta.len;
        }
        if (r.defer_vram and r.pending_from == null) {
            r.pending_from = r.next_id;
            r.pending_vram_at = layout.vram_at;
        }
        r.next_id += 1;
        r.head_len = n;
        r.has_head = true;
        r.frames_since = 0;
        r.evict();
    }

    /// Gives the OLDEST pending capture its VRAM. False, with nothing
    /// changed, for any other id: a fill out of order would diff against
    /// VRAM bytes that are not the capture before it.
    pub fn fillVram(r: *Rewind, id: u64, pixels: *const [native_pixels]u16) error{OutOfMemory}!bool {
        if (r.pending_from != id) return false;
        const bytes = std.mem.sliceAsBytes(pixels);
        const at = r.pending_vram_at;
        if (r.entryOf(id)) |e| {
            // `head` changes from the first word written; see `capture`.
            errdefer r.clear();
            r.encoded.clearRetainingCapacity();
            var diff = Diff{ .head = r.head, .out = &r.encoded, .allocator = r.allocator };
            // A diff compares whole words, so it runs from the word VRAM
            // starts in to the word it ends in, the bytes beside it kept.
            const end = at + bytes.len;
            const start = std.mem.alignBackward(usize, at, word);
            try diff.keep(start, at - start);
            try diff.write(at, bytes);
            try diff.keep(end, std.mem.alignForward(usize, end, word) - end);
            const old_len = e.delta.len;
            e.delta = try r.allocator.realloc(e.delta, old_len + r.encoded.items.len);
            @memcpy(e.delta[old_len..], r.encoded.items);
            r.entry_bytes += r.encoded.items.len;
        } else {
            // The first capture: no entry to turn it back, only `head`.
            @memcpy(r.head[at..][0..bytes.len], bytes);
        }
        r.pending_from = if (id + 1 == r.next_id) null else id + 1;
        r.evict();
        return true;
    }

    /// Drops every pending capture with an id at or above `id`, newest
    /// first. Their entries hold no VRAM runs yet, so each turns `head` back
    /// whole; their frames go to the next capture's entry.
    pub fn dropVramFrom(r: *Rewind, id: u64) void {
        const first = r.pending_from orelse return;
        const from = @max(id, first);
        while (r.next_id > from) {
            r.next_id -= 1;
            const last = r.entries.items.len;
            if (last > 0 and r.entries.items[last - 1].id == r.next_id) {
                const e = r.entries.pop().?;
                apply(e.delta, r.head);
                r.entry_bytes -= e.delta.len;
                r.allocator.free(e.delta);
                r.head_len = e.older_len;
                r.frames_since += e.frames;
            } else {
                // The first capture, which nothing turns back.
                r.has_head = false;
            }
        }
        if (from == first) r.pending_from = null;
    }

    /// A pending capture's entry, found from the newest end where every
    /// pending entry sits. Null for the first capture, which has none.
    fn entryOf(r: *Rewind, id: u64) ?*Entry {
        var i = r.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = &r.entries.items[i];
            if (e.id <= id) return if (e.id == id) e else null;
        }
        return null;
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

    /// Never drops a pending capture's entry: its fill appends to it.
    fn evict(r: *Rewind) void {
        var drop: usize = 0;
        var used = r.bytesUsed();
        var held = r.entries.items.len;
        if (r.pending_from) |first| {
            while (held > 0 and r.entries.items[held - 1].id >= first) held -= 1;
        }
        while (drop < held and used > r.budget) : (drop += 1) {
            used -= r.entries.items[drop].delta.len;
        }
        if (drop == 0) return;
        for (r.entries.items[0..drop]) |e| r.allocator.free(e.delta);
        r.entry_bytes = used - r.head.len;
        r.entries.replaceRangeAssumeCapacity(0, drop, &.{});
    }

    /// Returns the machine IN PLACE to the capture before `head`, which
    /// becomes the new head. With no entry left the machine is untouched.
    ///
    /// With captures pending it drops them and returns to the newest
    /// complete one instead, which is `head` once they are gone: never to a
    /// capture whose VRAM bytes are still another's.
    pub fn step(r: *Rewind, cpu: *Cpu) Error!void {
        if (r.pending_from) |first| {
            r.dropVramFrom(first);
            if (!r.has_head) return error.NoHistory;
        } else {
            const e = r.entries.pop() orelse return error.NoHistory;
            defer r.allocator.free(e.delta);
            r.entry_bytes -= e.delta.len;
            apply(e.delta, r.head);
            r.head_len = e.older_len;
        }
        r.frames_since = 0;
        r.picture_left = picture_frames;
        try savestate.loadTrusted(cpu, r.head[0..r.head_len]);
    }
};
