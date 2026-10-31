//! The TOC an eboot keeps for each disc: 102 entries of 10 bytes in the
//! shape a drive reads them (A0, A1, the lead-out A2, then one per track),
//! turned into the track table the rest of the core uses.
const std = @import("std");
const disc = @import("../disc.zig");
const msf = @import("../msf.zig");

pub const entry_bytes = 10;
pub const entry_count = 102;
pub const toc_bytes = entry_bytes * entry_count;
const lead_in = @import("../constants.zig").lead_in_frames;

const point_first: u8 = 0xA0;
const point_last: u8 = 0xA1;
const point_lead_out: u8 = 0xA2;
const type_audio: u8 = 0x01;

/// What the tracks add up to, and how the image lines up with them.
pub const Layout = struct {
    count: u8,
    /// Sectors from our LBA 0 to the lead-out.
    sectors: i32,
    /// Frames of track 1's pregap the image holds before our LBA 0 (or, for
    /// a negative LBA, would): file sector = LBA + 150 - this.
    track1_pregap: i32,
};

const Entry = struct {
    kind: u8,
    point: u8,
    pregap: msf.MSF,
    user: msf.MSF,

    fn parse(toc: *const [toc_bytes]u8, index: usize) error{BadPbp}!Entry {
        const e = toc[index * entry_bytes ..][0..entry_bytes];
        return .{
            .kind = e[0],
            .point = e[2],
            .pregap = try bcdMsf(e[3..6]),
            .user = try bcdMsf(e[7..10]),
        };
    }
};

fn bcdMsf(b: []const u8) error{BadPbp}!msf.MSF {
    for (b) |byte| {
        if (byte & 0x0F > 9 or byte >> 4 > 9) return error.BadPbp;
    }
    return .{ .m = b[0], .s = b[1], .f = b[2] };
}

pub fn tracks(toc: *const [toc_bytes]u8, out: *[99]disc.Track) error{BadPbp}!Layout {
    const first = try Entry.parse(toc, 0);
    const last = try Entry.parse(toc, 1);
    const lead_out = try Entry.parse(toc, 2);
    if (first.point != point_first or last.point != point_last or lead_out.point != point_lead_out) return error.BadPbp;
    if (first.user.m != 0x01) return error.BadPbp;
    const count = msf.bcdToBinary(last.user.m);
    if (count < 1) return error.BadPbp;

    var track1_pregap: i32 = 0;
    var track1_counts = false;
    var final_start: i32 = 0;
    for (0..count) |i| {
        const n: u8 = @intCast(i + 1);
        const e = try Entry.parse(toc, i + 3);
        const start = e.user.toLba();
        const pregap = e.pregap.toLba();
        const audio = e.kind == type_audio;
        if (start < pregap and (n != 1 or audio)) return error.BadPbp;
        if (n == 1) {
            track1_counts = start >= pregap;
            track1_pregap = if (track1_counts) start - pregap else start + lead_in;
        }
        if (n < count) {
            const next = try Entry.parse(toc, i + 4);
            if (next.point != msf.binaryToBcd(n + 1) or next.pregap.toLba() < start) return error.BadPbp;
        }
        out[i] = .{
            .number = n,
            .type = if (audio) .audio else .data,
            .start_lba = start,
            .pregap_lba = if (n == 1 or pregap == start) null else pregap,
        };
        final_start = start;
    }

    const sectors = lead_out.user.toLba() + if (track1_counts) track1_pregap else 0;
    if (final_start >= sectors) return error.BadPbp;
    return .{ .count = count, .sectors = sectors, .track1_pregap = track1_pregap };
}
