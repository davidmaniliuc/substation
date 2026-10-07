//! CHD v5 disc images, read on demand. See `Reader`.
const std = @import("std");

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
