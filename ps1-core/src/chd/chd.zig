//! CHD v5 disc images, read on demand. See `Reader`.
const std = @import("std");
const disc = @import("../disc.zig");
const sector_bytes = @import("../constants.zig").sector_bytes;

pub const bitstream = @import("bitstream.zig");
pub const flac = @import("flac.zig");
pub const cd = @import("cd.zig");
pub const map = @import("map.zig");

const magic = "MComprHD";
const header_bytes = 124;
const version = 5;

pub const Error = error{
    NotChd,
    BadHeader,
    UnsupportedVersion,
    ParentChd,
    UnsupportedCodec,
    UncompressedChd,
    NotCdImage,
    BadMap,
    BadMetadata,
    UnsupportedTrackType,
    OutOfMemory,
};

pub fn isChd(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, magic);
}

fn be(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .big);
}

pub const Header = struct {
    codecs: [4]?cd.Codec,
    logical_bytes: u64,
    map_offset: u64,
    meta_offset: u64,
    hunk_bytes: u32,
    unit_bytes: u32,
    hunk_count: u32,

    pub fn parse(bytes: []const u8) Error!Header {
        if (!isChd(bytes)) return error.NotChd;
        if (bytes.len < header_bytes or be(u32, bytes, 8) != header_bytes) return error.BadHeader;
        if (be(u32, bytes, 12) != version) return error.UnsupportedVersion;
        // A non-zero parent SHA-1 means hunks live in another file.
        if (!std.mem.allEqual(u8, bytes[104..124], 0)) return error.ParentChd;

        var codecs: [4]?cd.Codec = undefined;
        for (&codecs, 0..) |*c, i| c.* = try codecFromTag(bytes[16 + 4 * i ..][0..4]);
        if (codecs[0] == null) return error.UncompressedChd;

        const logical_bytes = be(u64, bytes, 32);
        const hunk_bytes = be(u32, bytes, 56);
        const unit_bytes = be(u32, bytes, 60);
        if (unit_bytes != cd.frame_bytes or hunk_bytes == 0 or hunk_bytes % cd.frame_bytes != 0) return error.NotCdImage;
        return .{
            .codecs = codecs,
            .logical_bytes = logical_bytes,
            .map_offset = be(u64, bytes, 40),
            .meta_offset = be(u64, bytes, 48),
            .hunk_bytes = hunk_bytes,
            .unit_bytes = unit_bytes,
            .hunk_count = std.math.cast(u32, std.math.divCeil(u64, logical_bytes, hunk_bytes) catch return error.BadHeader) orelse return error.BadHeader,
        };
    }

    pub fn usesCodec(self: Header, codec: cd.Codec) bool {
        for (self.codecs) |slot| {
            if (slot) |c| if (c == codec) return true;
        }
        return false;
    }
};

fn codecFromTag(tag: *const [4]u8) Error!?cd.Codec {
    if (std.mem.allEqual(u8, tag, 0)) return null;
    const tags = [_]struct { []const u8, cd.Codec }{
        .{ "cdzl", .cdzl }, .{ "cdlz", .cdlz }, .{ "cdzs", .cdzs }, .{ "cdfl", .cdfl },
    };
    for (tags) |t| if (std.mem.eql(u8, tag, t[0])) return t[1];
    return error.UnsupportedCodec;
}

/// Tracks are padded to a multiple of this many frames inside the image.
const track_alignment = 4;
/// Hunks kept decoded: data and CD-DA interleave, and a self-reference
/// decodes its target into its own slot.
const cache_slots = 4;
const max_tracks = 99;
/// Metadata entries walked before the chain is declared corrupt.
const max_metadata = 1024;
const metadata_header_bytes = 16;

pub const TrackMeta = struct { number: u8, audio: bool, frames: u32, stored_pregap: u32 };

/// One `CHT2` (or older `CHTR`) entry. Only a pregap whose type starts with
/// `V` is stored in the image; any other takes no frames, and no LBAs.
pub fn parseTrack(text: []const u8) Error!TrackMeta {
    var number: ?u32 = null;
    var kind: []const u8 = "";
    var frames: ?u32 = null;
    var pregap: u32 = 0;
    var pregap_type: []const u8 = "";
    var fields = std.mem.tokenizeScalar(u8, text, ' ');
    while (fields.next()) |field| {
        const colon = std.mem.indexOfScalar(u8, field, ':') orelse continue;
        const key = field[0..colon];
        const value = field[colon + 1 ..];
        if (std.mem.eql(u8, key, "TRACK")) {
            number = std.fmt.parseInt(u32, value, 10) catch return error.BadMetadata;
        } else if (std.mem.eql(u8, key, "TYPE")) {
            kind = value;
        } else if (std.mem.eql(u8, key, "FRAMES")) {
            frames = std.fmt.parseInt(u32, value, 10) catch return error.BadMetadata;
        } else if (std.mem.eql(u8, key, "PREGAP")) {
            pregap = std.fmt.parseInt(u32, value, 10) catch return error.BadMetadata;
        } else if (std.mem.eql(u8, key, "PGTYPE")) {
            pregap_type = value;
        }
    }
    const n = number orelse return error.BadMetadata;
    if (n == 0 or n > max_tracks) return error.BadMetadata;
    const total = frames orelse return error.BadMetadata;
    const audio = if (std.mem.eql(u8, kind, "AUDIO"))
        true
    else if (std.mem.eql(u8, kind, "MODE1_RAW") or std.mem.eql(u8, kind, "MODE2_RAW"))
        false
    else
        return error.UnsupportedTrackType;
    const stored = if (pregap_type.len > 0 and pregap_type[0] == 'V') pregap else 0;
    if (stored > total) return error.BadMetadata;
    return .{ .number = @intCast(n), .audio = audio, .frames = total, .stored_pregap = stored };
}

/// Where a track's LBAs live in the image.
const Layout = struct { first_lba: i32, frames: i32, chd_frame: u32, audio: bool };

/// A CHD opened over bytes the caller owns and keeps alive. Decodes hunks on
/// demand. Not thread-safe: a second thread opens its own.
pub const Reader = struct {
    gpa: std.mem.Allocator,
    file: []const u8,
    header: Header,
    map: []map.Entry,
    tracks: [max_tracks]disc.Track = undefined,
    track_count: u8 = 0,
    layout: [max_tracks]Layout = undefined,
    sector_count: i32 = 0,
    cache_block: []u8,
    cache: [cache_slots]?u32 = @splat(null),
    next_slot: usize = 0,
    scratch: cd.Scratch,
    logged_failure: bool = false,

    const HunkError = error{ BadHunk, BadHunkCrc, OutOfMemory };

    pub fn open(gpa: std.mem.Allocator, file: []const u8) Error!*Reader {
        const header = try Header.parse(file);
        const entries = try map.decode(gpa, file, header.map_offset, header.hunk_count, header.hunk_bytes);
        errdefer gpa.free(entries);
        const cache_block = try gpa.alloc(u8, cache_slots * header.hunk_bytes);
        errdefer gpa.free(cache_block);
        var scratch = try cd.Scratch.init(gpa, header.hunk_bytes / cd.frame_bytes, header.usesCodec(.cdzs));
        errdefer scratch.deinit(gpa);

        const self = try gpa.create(Reader);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .file = file, .header = header, .map = entries, .cache_block = cache_block, .scratch = scratch };
        try self.readTracks();
        return self;
    }

    pub fn close(self: *Reader) void {
        const gpa = self.gpa;
        self.scratch.deinit(gpa);
        gpa.free(self.cache_block);
        gpa.free(self.map);
        gpa.destroy(self);
    }

    pub fn sectorCount(self: *const Reader) i32 {
        return self.sector_count;
    }

    fn readTracks(self: *Reader) Error!void {
        var offset = self.header.meta_offset;
        var lba: i32 = 0;
        var chd_frame: u32 = 0;
        var walked: usize = 0;
        while (offset != 0) : (walked += 1) {
            if (walked == max_metadata or offset + metadata_header_bytes > self.file.len) return error.BadMetadata;
            const head = self.file[@intCast(offset)..][0..metadata_header_bytes];
            const tag = head[0..4];
            const length = std.mem.readInt(u24, head[5..8], .big);
            const start = offset + metadata_header_bytes;
            if (start + length > self.file.len) return error.BadMetadata;
            offset = std.mem.readInt(u64, head[8..16], .big);

            if (std.mem.eql(u8, tag, "CHCD") or std.mem.eql(u8, tag, "CHGD")) return error.BadMetadata;
            if (!std.mem.eql(u8, tag, "CHT2") and !std.mem.eql(u8, tag, "CHTR")) continue;

            const text = std.mem.trimEnd(u8, self.file[@intCast(start)..][0..length], "\x00");
            const meta = try parseTrack(text);
            if (meta.number != self.track_count + 1) return error.BadMetadata;
            const frames: i32 = @intCast(meta.frames);
            const stored: i32 = @intCast(meta.stored_pregap);
            self.tracks[self.track_count] = .{
                .number = meta.number,
                .type = if (meta.audio) .audio else .data,
                .start_lba = lba + stored,
                .pregap_lba = if (stored > 0) lba else null,
            };
            self.layout[self.track_count] = .{ .first_lba = lba, .frames = frames, .chd_frame = chd_frame, .audio = meta.audio };
            self.track_count += 1;
            lba += frames;
            chd_frame += std.mem.alignForward(u32, meta.frames, track_alignment);
        }
        if (self.track_count == 0) return error.BadMetadata;
        if (@as(u64, chd_frame) * cd.frame_bytes > self.header.logical_bytes) return error.BadMetadata;
        self.sector_count = lba;
    }

    /// The raw 2352-byte sector at `lba`, audio in host (little-endian) order.
    pub fn readSector(self: *Reader, lba: i32, out: *[sector_bytes]u8) bool {
        if (lba < 0 or lba >= self.sector_count) return false;
        const layout = self.layoutFor(lba);
        const frame = layout.chd_frame + @as(u32, @intCast(lba - layout.first_lba));
        const per_hunk = self.header.hunk_bytes / cd.frame_bytes;
        const index = frame / per_hunk;
        const data = self.hunk(index) catch |err| {
            if (!self.logged_failure) std.log.warn("chd: hunk {d} unreadable: {s}", .{ index, @errorName(err) });
            self.logged_failure = true;
            return false;
        };
        @memcpy(out, data[(frame % per_hunk) * cd.frame_bytes ..][0..sector_bytes]);
        if (layout.audio) {
            var i: usize = 0;
            while (i < sector_bytes) : (i += 2) std.mem.swap(u8, &out[i], &out[i + 1]);
        }
        return true;
    }

    fn layoutFor(self: *const Reader, lba: i32) Layout {
        var found = self.layout[0];
        for (self.layout[0..self.track_count]) |l| {
            if (l.first_lba > lba) break;
            found = l;
        }
        return found;
    }

    fn slot(self: *Reader, index: usize) []u8 {
        return self.cache_block[index * self.header.hunk_bytes ..][0..self.header.hunk_bytes];
    }

    fn hunk(self: *Reader, n: u32) HunkError![]const u8 {
        for (self.cache, 0..) |cached, i| {
            if (cached) |c| if (c == n) return self.slot(i);
        }
        const i = self.next_slot;
        self.next_slot = (self.next_slot + 1) % cache_slots;
        self.cache[i] = null;
        try self.decodeHunk(n, self.slot(i));
        self.cache[i] = n;
        return self.slot(i);
    }

    fn decodeHunk(self: *Reader, n: u32, dest: []u8) HunkError!void {
        if (n >= self.map.len) return error.BadHunk;
        const entry = self.map[n];
        switch (entry.kind) {
            // A self-reference points back at a hunk that carries its own CRC.
            .self => {
                if (entry.offset >= n) return error.BadHunk;
                return self.decodeHunk(@intCast(entry.offset), dest);
            },
            .none => @memcpy(dest, try self.compressed(entry.offset, self.header.hunk_bytes)),
            else => {
                const codec = self.header.codecs[@backingInt(entry.kind)] orelse return error.BadHunk;
                try cd.decode(&self.scratch, self.gpa, codec, try self.compressed(entry.offset, entry.length), dest);
            },
        }
        if (std.hash.crc.@"CRC-16/IBM-3740".hash(dest) != entry.crc) return error.BadHunkCrc;
    }

    fn compressed(self: *const Reader, offset: u64, length: u64) HunkError![]const u8 {
        if (offset + length > self.file.len) return error.BadHunk;
        return self.file[@intCast(offset)..][0..@intCast(length)];
    }
};
