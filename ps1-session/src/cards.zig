//! The two memory cards, on disk, and when a dirtied one is written.
//!
//! ONE shared pair for the whole library, like a console with two cards in
//! it, rather than a card per game: a multi-disc game finds its own save on
//! disc 2 because it is the same card, and a sequel finds its predecessor's
//! for the same reason. The format is a raw 131072-byte image per slot, the
//! `.mcd` layout other emulators read, so a save can be carried in or out.

const std = @import("std");

const Io = std.Io;
const Dir = Io.Dir;
const log = std.log.scoped(.cards);

pub const bytes = 128 * 1024;
pub const slots = 2;

pub fn fileName(slot: u1) []const u8 {
    return if (slot == 0) "card1.mcd" else "card2.mcd";
}

fn tempName(slot: u1) []const u8 {
    return if (slot == 0) "card1.mcd.tmp" else "card2.mcd.tmp";
}

/// The directory the frontend named. Only its path is kept: the directory is
/// made on the first write, so a fresh install has nothing to create until a
/// game saves.
pub const CardStore = struct {
    buf: [Dir.max_path_bytes]u8 = undefined,
    len: usize = 0,

    pub fn open(dir_path: []const u8) CardStore {
        var self: CardStore = .{};
        std.debug.assert(dir_path.len <= self.buf.len);
        @memcpy(self.buf[0..dir_path.len], dir_path);
        self.len = dir_path.len;
        return self;
    }

    pub fn path(self: *const CardStore) []const u8 {
        return self.buf[0..self.len];
    }

    /// False for a card that has never been written, and for a file that is
    /// not exactly one card long: a short file is far more likely a botched
    /// copy than a card worth salvaging, and refusing it presents as
    /// "unformatted", which the BIOS offers to fix, instead of as corrupt
    /// save data.
    pub fn load(self: *const CardStore, io: Io, slot: u1, out: *[bytes]u8) bool {
        var dir = Dir.cwd().openDir(io, self.path(), .{}) catch return false;
        defer dir.close(io);
        const st = dir.statFile(io, fileName(slot), .{}) catch return false;
        if (st.size != bytes) return false;
        const got = dir.readFile(io, fileName(slot), out) catch return false;
        return got.len == bytes;
    }

    /// Through a temporary file and a rename, so a crash mid-write leaves the
    /// old card rather than half of a new one. False, logged, on failure:
    /// silent loss here is the one failure this whole feature exists to
    /// prevent, and the caller keeps the image to try again.
    pub fn write(self: *const CardStore, io: Io, slot: u1, image: *const [bytes]u8) bool {
        writeFile(self.path(), io, slot, image) catch |err| {
            log.warn("memory card slot {d} failed to write to {s}: {s}; kept for the next try", .{ @as(u8, slot) + 1, self.path(), @errorName(err) });
            return false;
        };
        return true;
    }

    fn writeFile(dir_path: []const u8, io: Io, slot: u1, image: *const [bytes]u8) !void {
        try Dir.cwd().createDirPath(io, dir_path);
        var dir = try Dir.cwd().openDir(io, dir_path, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = tempName(slot), .data = image });
        errdefer dir.deleteFile(io, tempName(slot)) catch {};
        try dir.rename(tempName(slot), dir, fileName(slot), io);
    }
};

/// When a dirtied card should be written: a value with no clock and no I/O of
/// its own, so the rule is reachable from a test with synthetic timestamps.
///
/// The window restarts on every new write rather than counting from the
/// first, because what is being waited out is a BURST: a game committing a
/// save writes ten or so 128-byte blocks back to back, and each one raises
/// the dirty flag.
pub const FlushPolicy = struct {
    /// Long enough to swallow a save's burst of blocks, short enough that a
    /// force-quit a moment later still finds the save on disk.
    pub const settle_ns: u64 = std.time.ns_per_s;

    pending_since_ns: ?u64 = null,

    pub fn hasPendingWrite(self: *const FlushPolicy) bool {
        return self.pending_since_ns != null;
    }

    /// `dirty` is whether the core reported new bytes on this tick.
    pub fn shouldWrite(self: *FlushPolicy, dirty: bool, now_ns: u64) bool {
        if (dirty) self.pending_since_ns = now_ns;
        const since = self.pending_since_ns orelse return false;
        if (now_ns < since + settle_ns) return false;
        self.pending_since_ns = null;
        return true;
    }
};

/// Card images taken from the machine and not yet on disk. Fixed storage: the
/// emulator thread holds one and never allocates for it.
pub const Pending = struct {
    images: [slots]?[bytes]u8 = .{ null, null },

    pub fn isEmpty(self: *const Pending) bool {
        return self.images[0] == null and self.images[1] == null;
    }

    /// Writes every held image. One that fails stays held for the next
    /// settle, where Swift dropped it: a card directory on an unplugged
    /// volume comes back, and the save with it.
    pub fn writeAll(self: *Pending, store: *const CardStore, io: Io) void {
        for (&self.images, 0..) |*held, i| {
            const img = &(held.* orelse continue);
            if (store.write(io, @intCast(i), img)) held.* = null;
        }
    }
};
