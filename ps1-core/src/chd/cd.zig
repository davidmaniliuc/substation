//! The four CHD CD codecs. `cdzl`, `cdlz` and `cdzs` share one hunk layout:
//! an ECC bitmap (one bit per frame, LSB first), the compressed length of the
//! sector data (2 bytes, or 3 for a hunk of 64 KB or more), the sector data
//! through the base codec, then the subcode through its own stream. `cdfl` is
//! FLAC sector data followed directly by deflated subcode, with no header.
//!
//! A set ECC bit means chdman verified that frame's parity and then zeroed its
//! sync pattern and P/Q bytes, so they are regenerated here bit for bit.
const std = @import("std");
const constants = @import("../constants.zig");
const flac = @import("flac.zig");

const sector_bytes = constants.sector_bytes;
pub const subcode_bytes = 96;
pub const frame_bytes = sector_bytes + subcode_bytes;

pub const Codec = enum { cdzl, cdlz, cdzs, cdfl };
pub const Error = error{ BadHunk, OutOfMemory };

/// Literal/position properties chdman's LZMA encoder uses (lc 3, lp 0, pb 2).
const lzma_properties: std.compress.lzma.Decode.Properties = .{ .lc = 3, .lp = 0, .pb = 2 };
/// zstd window for one hunk; a hunk is up to 256 frames (~602 KB).
const zstd_window = 1 << 20;

/// Per-reader working memory, sized once for the reader's hunk size.
pub const Scratch = struct {
    sectors: []u8,
    subcode: []u8,
    flate_window: []u8,
    /// Empty unless the CHD names `cdzs`.
    zstd_buffer: []u8,

    pub fn init(gpa: std.mem.Allocator, frames: usize, zstd: bool) !Scratch {
        const sectors = try gpa.alloc(u8, frames * sector_bytes);
        errdefer gpa.free(sectors);
        const subcode = try gpa.alloc(u8, frames * subcode_bytes);
        errdefer gpa.free(subcode);
        const flate_window = try gpa.alloc(u8, std.compress.flate.max_window_len);
        errdefer gpa.free(flate_window);
        const zstd_buffer = if (zstd) try gpa.alloc(u8, zstd_window + std.compress.zstd.block_size_max) else @as([]u8, &.{});
        return .{ .sectors = sectors, .subcode = subcode, .flate_window = flate_window, .zstd_buffer = zstd_buffer };
    }

    pub fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
        gpa.free(self.sectors);
        gpa.free(self.subcode);
        gpa.free(self.flate_window);
        gpa.free(self.zstd_buffer);
    }
};

pub fn decode(scratch: *Scratch, gpa: std.mem.Allocator, codec: Codec, src: []const u8, dest: []u8) Error!void {
    const frames = dest.len / frame_bytes;
    const sectors = scratch.sectors[0 .. frames * sector_bytes];
    const subcode = scratch.subcode[0 .. frames * subcode_bytes];
    var ecc_bitmap: []const u8 = &.{};

    if (codec == .cdfl) {
        const used = flac.decodeFrames(src, sectors, null) catch return error.BadHunk;
        try inflate(scratch, src[used..], subcode);
    } else {
        const ecc_bytes = (frames + 7) / 8;
        const len_bytes: usize = if (dest.len < 65536) 2 else 3;
        const head = ecc_bytes + len_bytes;
        if (src.len < head) return error.BadHunk;
        var base_len: usize = std.mem.readInt(u16, src[ecc_bytes..][0..2], .big);
        if (len_bytes == 3) base_len = (base_len << 8) | src[ecc_bytes + 2];
        if (src.len < head + base_len) return error.BadHunk;
        const base = src[head..][0..base_len];
        const rest = src[head + base_len ..];
        switch (codec) {
            .cdzl => {
                try inflate(scratch, base, sectors);
                try inflate(scratch, rest, subcode);
            },
            .cdlz => {
                try unlzma(gpa, base, sectors);
                try inflate(scratch, rest, subcode);
            },
            .cdzs => {
                try unzstd(scratch, base, sectors);
                try unzstd(scratch, rest, subcode);
            },
            .cdfl => unreachable,
        }
        ecc_bitmap = src[0..ecc_bytes];
    }

    for (0..frames) |f| {
        const frame = dest[f * frame_bytes ..][0..frame_bytes];
        @memcpy(frame[0..sector_bytes], sectors[f * sector_bytes ..][0..sector_bytes]);
        @memcpy(frame[sector_bytes..], subcode[f * subcode_bytes ..][0..subcode_bytes]);
        if (ecc_bitmap.len > 0 and ecc_bitmap[f / 8] & (@as(u8, 1) << @intCast(f % 8)) != 0) {
            restoreSector(frame[0..sector_bytes]);
        }
    }
}

fn inflate(scratch: *Scratch, src: []const u8, out: []u8) Error!void {
    var in = std.Io.Reader.fixed(src);
    var d = std.compress.flate.Decompress.init(&in, .raw, scratch.flate_window);
    d.reader.readSliceAll(out) catch return error.BadHunk;
}

fn unlzma(gpa: std.mem.Allocator, src: []const u8, out: []u8) Error!void {
    var in = std.Io.Reader.fixed(src);
    var d = std.compress.lzma.Decompress.initParams(&in, gpa, &.{}, .{
        .properties = lzma_properties,
        // Any window covering the hunk decodes it: no match reaches further back.
        .dict_size = @intCast(@max(out.len, 4096)),
        .unpacked_size = out.len,
    }, std.math.maxInt(usize)) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.BadHunk;
    defer d.deinit();
    d.reader.readSliceAll(out) catch return error.BadHunk;
}

fn unzstd(scratch: *Scratch, src: []const u8, out: []u8) Error!void {
    if (scratch.zstd_buffer.len == 0) return error.BadHunk;
    var in = std.Io.Reader.fixed(src);
    var d = std.compress.zstd.Decompress.init(&in, scratch.zstd_buffer, .{ .window_len = zstd_window });
    d.reader.readSliceAll(out) catch return error.BadHunk;
}

// --- ECC ---------------------------------------------------------------------

const sync_pattern = [12]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
const p_offset = 0x81C;
const p_rows = 86;
const p_terms = 24;
const q_offset = p_offset + 2 * p_rows;
const q_rows = 52;
const q_terms = 43;

/// GF(2^8) doubling, and the inverse that finishes each parity pair.
const ecc_low: [256]u8 = blk: {
    var t: [256]u8 = undefined;
    for (0..256) |i| t[i] = @truncate((i << 1) ^ (if (i & 0x80 != 0) 0x11D else 0));
    break :blk t;
};
const ecc_high: [256]u8 = blk: {
    var t: [256]u8 = undefined;
    for (0..256) |i| t[ecc_low[i] ^ i] = @intCast(i);
    break :blk t;
};

fn pOffset(row: usize, term: usize) usize {
    return row + p_rows * term;
}

fn qOffset(row: usize, term: usize) usize {
    return (((row >> 1) * q_terms + term * (q_terms + 1)) % (q_rows * q_terms / 2)) * 2 + (row & 1);
}

/// One parity pair over the bytes after the sync pattern. A Mode 2 sector's
/// header is excluded from its parity, so its four bytes count as zero.
fn parity(sector: *const [sector_bytes]u8, comptime terms: usize, comptime offsetOf: fn (usize, usize) usize, row: usize) [2]u8 {
    const data = sector[sync_pattern.len..];
    const mode2 = sector[15] == 2;
    var v1: u8 = 0;
    var v2: u8 = 0;
    for (0..terms) |term| {
        const off = offsetOf(row, term);
        const byte: u8 = if (mode2 and off < 4) 0 else data[off];
        v1 = ecc_low[v1 ^ byte];
        v2 ^= byte;
    }
    v1 = ecc_high[ecc_low[v1] ^ v2];
    return .{ v1, v2 ^ v1 };
}

/// Puts back what chdman strips from a frame whose ECC it verified. P is
/// written first because Q covers it.
pub fn restoreSector(sector: *[sector_bytes]u8) void {
    sector[0..sync_pattern.len].* = sync_pattern;
    for (0..p_rows) |row| {
        const v = parity(sector, p_terms, pOffset, row);
        sector[p_offset + row] = v[0];
        sector[p_offset + p_rows + row] = v[1];
    }
    for (0..q_rows) |row| {
        const v = parity(sector, q_terms, qOffset, row);
        sector[q_offset + row] = v[0];
        sector[q_offset + q_rows + row] = v[1];
    }
}
