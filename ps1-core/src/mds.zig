//! Alcohol 120% images: a `.mds` descriptor over an `.mdf` of raw sectors,
//! each followed by 96 bytes of interleaved subchannel when the descriptor
//! says so. The descriptor supplies the track layout and the `.mdf`'s
//! subchannel the sectors whose Q is deliberately corrupt (LibCrypt), which
//! come out as the same record buffer a `.sbi` sidecar holds.
//!
//! The image is served as ONE strided source, so every track must share one
//! stride and sit where a contiguous image puts it. Alcohol writes every PS1
//! dump that way; anything else is refused rather than guessed at.

const std = @import("std");
const constants = @import("constants.zig");
const disc = @import("disc.zig");
const ccd = @import("ccd.zig");

const Disc = disc.Disc;
const MSF = disc.MSF;

const signature = "MEDIA DESCRIPTOR";
const session_pointer = 0x50;
const min_sheet_bytes = session_pointer + 4;
const session_bytes = 24;
const entry_bytes = 80;
const extra_bytes = 8;
const max_tracks = 99;
const first_special_point = 0xA0;
const type_audio = 0xA9;
const sub_bytes = 96;
const stride_plain: u16 = constants.sector_bytes;
const stride_sub: u16 = constants.sector_bytes + sub_bytes;

/// Whether `sheet` opens an Alcohol descriptor.
pub fn isMds(sheet: []const u8) bool {
    return std.mem.startsWith(u8, sheet, signature);
}

fn u16At(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

fn u32At(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

/// Whether `len` bytes starting at `at` lie inside `sheet`, without wrapping.
fn fits(sheet: []const u8, at: u32, len: usize) bool {
    return @as(u64, at) + len <= sheet.len;
}

/// What the descriptor says about a disc, in a fixed table.
const Layout = struct {
    stride: u16,
    track_count: u8,
    tracks: [max_tracks]disc.Track,
    /// Where each track's first on-file sector sits in the `.mdf`.
    offsets: [max_tracks]u32,
    lead_out: u64,
};

fn readLayout(sheet: []const u8) error{BadMds}!Layout {
    if (!isMds(sheet) or sheet.len < min_sheet_bytes) return error.BadMds;
    const session = u32At(sheet, session_pointer);
    if (!fits(sheet, session, session_bytes)) return error.BadMds;
    const count = u16At(sheet, session + 14);
    if (count < 1 or count > max_tracks) return error.BadMds;
    var at = u32At(sheet, session + 20);

    // The A0/A1/A2 entries come first and describe no track.
    while (true) : (at += entry_bytes) {
        if (!fits(sheet, at, entry_bytes)) return error.BadMds;
        if (sheet[at + 4] < first_special_point) break;
    }

    var out: Layout = .{ .stride = 0, .track_count = @intCast(count), .tracks = undefined, .offsets = undefined, .lead_out = 0 };
    var prev_start: i64 = -1;
    for (0..count) |i| {
        const e = at + @as(u32, @intCast(i)) * entry_bytes;
        if (!fits(sheet, e, entry_bytes)) return error.BadMds;
        const number: u8 = @intCast(i + 1);
        if (sheet[e + 4] != disc.binaryToBcd(number)) return error.BadMds;

        const per_sector: u16 = if (sheet[e + 1] != 0) stride_sub else stride_plain;
        if (i == 0) out.stride = per_sector else if (per_sector != out.stride) return error.BadMds;

        const extra = u32At(sheet, e + 12);
        if (!fits(sheet, extra, extra_bytes)) return error.BadMds;
        const pregap = u32At(sheet, extra);
        const length = u32At(sheet, extra + 4);

        const start = MSF.toLba(.{ .m = sheet[e + 9], .s = sheet[e + 10], .f = sheet[e + 11] });
        // Pregaps count from the absolute address, 150 sectors past the LBA.
        if (pregap > @as(u64, @intCast(@max(start, 0))) + constants.lead_in_frames) return error.BadMds;
        if (start < 0 or start <= prev_start) return error.BadMds;
        prev_start = start;

        var first: i64 = 0;
        var pregap_lba: ?i32 = null;
        if (i > 0) {
            first = start;
            if (pregap > 0) {
                first = @as(i64, start) - pregap;
                pregap_lba = @intCast(first);
            }
            if (first < 0) return error.BadMds;
        }
        out.tracks[i] = .{
            .number = number,
            .type = if (sheet[e] == type_audio) .audio else .data,
            .start_lba = start,
            .pregap_lba = pregap_lba,
        };

        // The data must sit where a contiguous image puts it.
        const want = @as(u64, @intCast(first)) * per_sector;
        if (u32At(sheet, e + 40) != want) return error.BadMds;
        out.offsets[i] = @intCast(want);
        out.lead_out = @as(u64, @intCast(start)) + length;
    }
    if (out.lead_out <= @as(u64, @intCast(prev_start)) or out.lead_out > std.math.maxInt(i32)) return error.BadMds;
    return out;
}

/// The bytes a sector takes in the `.mdf`: 2352, or 2448 with subchannel.
/// Refuses a descriptor whose tracks disagree.
pub fn stride(sheet: []const u8) error{BadMds}!u16 {
    return (try readLayout(sheet)).stride;
}

/// The disc a descriptor lays out over its `.mdf`. Borrows `mdf`.
pub fn parse(sheet: []const u8, mdf: []const u8) error{BadMds}!Disc {
    const layout = try readLayout(sheet);
    if (@as(u64, layout.lead_out) * layout.stride > mdf.len) return error.BadMds;
    var d = Disc{ .source = .{ .strided = .{ .data = mdf, .stride = layout.stride } } };
    d.track_count = layout.track_count;
    @memcpy(d.tracks[0..layout.track_count], layout.tracks[0..layout.track_count]);
    return d;
}

/// Sector `i` of a 2448-byte-stride `.mdf`: its Q, deinterleaved.
const MdfView = struct {
    mdf: []const u8,

    pub fn q(self: MdfView, i: usize) [12]u8 {
        const at = i * stride_sub + constants.sector_bytes;
        return ccd.deinterleaveQ(self.mdf[at..][0..sub_bytes]);
    }
};

/// `ccd.qRecords` over an `.mdf` that carries subchannel: every sector whose
/// Q fails its CRC. Only whole 2448-byte sectors are read.
pub fn subRecords(gpa: std.mem.Allocator, mdf: []const u8) error{OutOfMemory}![]u8 {
    return ccd.qRecords(gpa, mdf.len / stride_sub, 0, MdfView{ .mdf = mdf });
}
