//! CloneCD images: a `.ccd` control file over a raw `.img`, and the `.sub`
//! beside them. The `.ccd` supplies the track layout and the `.sub` the
//! sectors whose subchannel Q is deliberately corrupt (LibCrypt), which come
//! out as the same record buffer a `.sbi` sidecar holds.

const std = @import("std");
const constants = @import("constants.zig");
const disc = @import("disc.zig");

const Disc = disc.Disc;
const Track = disc.Track;
const MSF = disc.MSF;

const sub_sector_bytes = 96;
const q_offset = 12;
const q_bytes = 10;
const max_tracks = 99;
const point_leadout = 0xA2;
const control_data = 4;
const sbi_type_q = 1;

/// Whether `text` opens a CloneCD control file: a `[CloneCD]` line.
pub fn isCcd(text: []const u8) bool {
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (std.ascii.eqlIgnoreCase(line, "[CloneCD]")) return true;
    }
    return false;
}

/// The CRC the drive checks a subchannel Q against: CRC-16, polynomial
/// 0x1021, started at zero, over the 10 bytes before it, then inverted.
pub fn qCrc(q: *const [q_bytes]u8) u16 {
    var crc: u16 = 0;
    for (q) |byte| {
        crc ^= @as(u16, byte) << 8;
        for (0..8) |_| {
            crc = if (crc & 0x8000 != 0) (crc << 1) ^ 0x1021 else crc << 1;
        }
    }
    return ~crc;
}

/// An sbi-shaped buffer holding every sector from `skip` on whose stored Q
/// fails its CRC, addressed from the sector `skip` is LBA 0 of. The caller
/// owns the result.
pub fn subRecords(gpa: std.mem.Allocator, sub: []const u8, skip: usize) error{ OutOfMemory, BadCcd }![]u8 {
    if (sub.len % sub_sector_bytes != 0) return error.BadCcd;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, disc.sbi_magic);
    const count = sub.len / sub_sector_bytes;
    for (@min(skip, count)..count) |i| {
        const q = sub[i * sub_sector_bytes + q_offset ..][0 .. q_bytes + 2];
        // A dump without subchannel data is all zero; that is absence, not corruption.
        if (std.mem.allEqual(u8, q, 0)) continue;
        const stored = (@as(u16, q[q_bytes]) << 8) | q[q_bytes + 1];
        if (qCrc(q[0..q_bytes]) == stored) continue;
        const msf = MSF.fromLba(@intCast(i - skip));
        try out.appendSlice(gpa, &.{ msf.m, msf.s, msf.f, sbi_type_q });
        try out.appendSlice(gpa, q[0..q_bytes]);
    }
    return out.toOwnedSlice(gpa);
}

const Entry = struct {
    point: u8 = 0,
    control: u8 = 0,
    plba: ?i64 = null,
};

const TrackSection = struct {
    mode: ?i64 = null,
    index0: ?i64 = null,
    index1: ?i64 = null,
};

/// What a control file says, in the fixed tables a disc can hold.
const Sheet = struct {
    is_ccd: bool = false,
    toc_entries: i64 = 0,
    entries: [max_tracks + 4]Entry = @splat(.{}),
    entry_count: usize = 0,
    tracks: [max_tracks + 1]TrackSection = @splat(.{}),
};

const Section = union(enum) { none, clonecd, disc, entry: usize, track: usize };

fn parseInt(text: []const u8) ?i64 {
    const s = std.mem.trim(u8, text, " \t");
    const neg = std.mem.startsWith(u8, s, "-");
    const body = if (neg) s[1..] else s;
    const base: u8 = if (std.mem.startsWith(u8, body, "0x") or std.mem.startsWith(u8, body, "0X")) 16 else 10;
    const digits = if (base == 16) body[2..] else body;
    const v = std.fmt.parseInt(i64, digits, base) catch return null;
    return if (neg) -v else v;
}

fn sectionOf(sheet: *Sheet, name: []const u8) Section {
    if (std.ascii.eqlIgnoreCase(name, "CloneCD")) return .clonecd;
    if (std.ascii.eqlIgnoreCase(name, "Disc")) return .disc;
    if (name.len > 6 and std.ascii.eqlIgnoreCase(name[0..6], "Entry ")) {
        const n = std.math.cast(usize, parseInt(name[6..]) orelse return .none) orelse return .none;
        if (n >= sheet.toc_entries or n >= sheet.entries.len) return .none;
        sheet.entry_count = @max(sheet.entry_count, n + 1);
        return .{ .entry = n };
    }
    if (name.len > 6 and std.ascii.eqlIgnoreCase(name[0..6], "TRACK ")) {
        const n = std.math.cast(usize, parseInt(name[6..]) orelse return .none) orelse return .none;
        if (n < 1 or n > max_tracks) return .none;
        return .{ .track = n };
    }
    return .none;
}

fn readSheet(text: []const u8) Sheet {
    var sheet = Sheet{};
    var section: Section = .none;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] == ';') continue;
        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            section = sectionOf(&sheet, line[1..close]);
            if (section == .clonecd) sheet.is_ccd = true;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = parseInt(line[eq + 1 ..]) orelse continue;
        switch (section) {
            .disc => if (std.ascii.eqlIgnoreCase(key, "TocEntries")) {
                sheet.toc_entries = value;
            },
            .entry => |n| {
                const e = &sheet.entries[n];
                if (std.ascii.eqlIgnoreCase(key, "Point")) {
                    e.point = std.math.cast(u8, value) orelse 0;
                } else if (std.ascii.eqlIgnoreCase(key, "Control")) {
                    e.control = std.math.cast(u8, value) orelse 0;
                } else if (std.ascii.eqlIgnoreCase(key, "PLBA")) {
                    e.plba = value;
                }
            },
            .track => |n| {
                const t = &sheet.tracks[n];
                if (std.ascii.eqlIgnoreCase(key, "MODE")) {
                    t.mode = value;
                } else if (std.ascii.eqlIgnoreCase(key, "INDEX 0")) {
                    t.index0 = value;
                } else if (std.ascii.eqlIgnoreCase(key, "INDEX 1")) {
                    t.index1 = value;
                }
            },
            else => {},
        }
    }
    return sheet;
}

/// The sectors of the image that come before our LBA 0: the stored pregap of
/// track 1, which exists when its `INDEX 0` does and ends at its `INDEX 1`.
pub fn pregapSkip(text: []const u8) usize {
    const t = readSheet(text).tracks[1];
    if (t.index0 == null) return 0;
    return std.math.cast(usize, t.index1 orelse return 0) orelse 0;
}

/// Lays the tracks of `text` over `img`, a raw 2352-byte-per-sector image.
/// `img` is borrowed; the disc starts past track 1's stored pregap.
pub fn parse(text: []const u8, img: []const u8) error{BadCcd}!Disc {
    const sheet = readSheet(text);
    if (!sheet.is_ccd or sheet.toc_entries < 3) return error.BadCcd;

    var present: [max_tracks + 1]bool = @splat(false);
    var control: [max_tracks + 1]u8 = @splat(0);
    var plba: [max_tracks + 1]?i64 = @splat(null);
    var leadout: ?i64 = null;
    var highest: usize = 0;
    for (sheet.entries[0..sheet.entry_count]) |e| {
        if (e.point == point_leadout) {
            leadout = e.plba;
        } else if (e.point >= 1 and e.point <= max_tracks) {
            present[e.point] = true;
            control[e.point] = e.control;
            plba[e.point] = e.plba;
            highest = @max(highest, e.point);
        }
    }
    if (highest == 0) return error.BadCcd;
    for (present[1 .. highest + 1]) |p| if (!p) return error.BadCcd;

    const skip: i64 = @intCast(pregapSkip(text));
    const image_sectors: i64 = @intCast(img.len / constants.sector_bytes);
    const end = leadout orelse image_sectors;
    if (image_sectors < end or skip > image_sectors) return error.BadCcd;

    var d = Disc{ .source = .{ .flat = img[@intCast(skip * constants.sector_bytes)..] } };
    var next_start: ?i64 = null;
    var n = highest;
    // Walk down so each track can be checked against the one after it.
    while (n >= 1) : (n -= 1) {
        const t = sheet.tracks[n];
        const start = t.index1 orelse plba[n] orelse return error.BadCcd;
        if (t.index0) |pregap| if (start < pregap) return error.BadCcd;
        if (next_start) |ns| {
            if (ns <= start) return error.BadCcd;
        } else if (start >= end) return error.BadCcd;
        next_start = start;

        const is_data = if (t.mode) |m| m != 0 else control[n] & control_data != 0;
        const lba = start - skip;
        if (lba < 0) return error.BadCcd;
        var pregap_lba: ?i32 = null;
        if (t.index0) |pregap| {
            const p = pregap - skip;
            if (p >= 0) pregap_lba = std.math.cast(i32, p) orelse return error.BadCcd else if (n != 1) return error.BadCcd;
        }
        d.tracks[n - 1] = .{
            .number = @intCast(n),
            .type = if (is_data) .data else .audio,
            .start_lba = std.math.cast(i32, lba) orelse return error.BadCcd,
            .pregap_lba = pregap_lba,
        };
    }
    d.track_count = @intCast(highest);
    return d;
}
