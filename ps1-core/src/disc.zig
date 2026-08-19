const std = @import("std");
const constants = @import("constants.zig");

/// User-data payload of a standard PS1 sector: Mode 1, or Mode 2 Form 1 (the
/// 2352-byte raw sector minus sync/header/subheader/ECC). Also the size
/// `readSectorRaw` uses to pick which sub-header offset to skip.
const mode1_data_bytes = 2048;

pub const MSF = struct {
    m: u8,
    s: u8,
    f: u8,

    pub fn toLba(self: MSF) i32 {
        const m = @as(i32, bcdToBinary(self.m));
        const s = @as(i32, bcdToBinary(self.s));
        const f = @as(i32, bcdToBinary(self.f));
        return (m * 60 + s) * 75 + f - constants.lead_in_frames;
    }

    pub fn fromLba(lba: i32) MSF {
        const total_f = lba + constants.lead_in_frames;
        const m = @divFloor(total_f, 60 * 75);
        const s = @divFloor(@mod(total_f, 60 * 75), 75);
        const f = @mod(total_f, 75);
        return .{
            .m = binaryToBcd(@intCast(m)),
            .s = binaryToBcd(@intCast(s)),
            .f = binaryToBcd(@intCast(f)),
        };
    }

    pub fn fromFrames(frames: i32) MSF {
        const clamped = @max(frames, 0);
        const m = @divFloor(clamped, 60 * 75);
        const s = @divFloor(@mod(clamped, 60 * 75), 75);
        const f = @mod(clamped, 75);
        return .{
            .m = binaryToBcd(@intCast(m)),
            .s = binaryToBcd(@intCast(s)),
            .f = binaryToBcd(@intCast(f)),
        };
    }
};

pub fn bcdToBinary(value: u8) u8 {
    return ((value >> 4) * 10) + (value & 0x0F);
}

pub fn binaryToBcd(value: u8) u8 {
    return ((value / 10) << 4) | (value % 10);
}

/// Returns the remainder of `line` after `kw` if `line` starts with `kw`, else null.
fn matchKeyword(line: []const u8, kw: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, kw)) return null;
    return std.mem.trim(u8, line[kw.len..], " \t");
}

/// First base-10 integer found in `s` (skips leading non-digits). 0 if none.
fn parseFirstInt(s: []const u8) i64 {
    var i: usize = 0;
    while (i < s.len and (s[i] < '0' or s[i] > '9')) : (i += 1) {}
    var v: i64 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        v = v * 10 + (s[i] - '0');
    }
    return v;
}

/// Parses the trailing `mm:ss:ff` of an INDEX line into absolute frame count.
fn parseMsfFrames(s: []const u8) i32 {
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return 0;
    // find the second-to-last colon to bound mm:ss:ff
    const head = s[0..colon];
    const colon2 = std.mem.lastIndexOfScalar(u8, head, ':') orelse return 0;
    // back up over digits to find start of mm
    var start = colon2;
    while (start > 0 and s[start - 1] >= '0' and s[start - 1] <= '9') : (start -= 1) {}
    const m = parseFirstInt(s[start..colon2]);
    const sec = parseFirstInt(s[colon2 + 1 .. colon]);
    const f = parseFirstInt(s[colon + 1 ..]);
    return @intCast(((m * 60) + sec) * 75 + f);
}

pub const TrackType = enum { data, audio };

pub const Track = struct {
    number: u8,
    type: TrackType = .data,
    start_lba: i32 = 0,
    pregap_lba: ?i32 = null,
};

pub const SubchannelQ = struct {
    track: u8,
    index: u8,
    rel_m: u8,
    rel_s: u8,
    rel_f: u8,
    abs_m: u8,
    abs_s: u8,
    abs_f: u8,
};

/// A `.sbi` file is the 4-byte magic below followed by 14-byte records: a
/// 3-byte BCD MSF, a type byte, then the sector's 10 raw subchannel-Q bytes
/// (control/adr, track, index, relative MSF, a zero, absolute MSF).
const sbi_magic = "SBI\x00";
const sbi_record_bytes = 14;

pub const Disc = struct {
    data: []const u8,
    /// The record region of a `.sbi`, magic already stripped. Empty for the
    /// unprotected discs that are the overwhelming majority.
    sbi: []const u8 = &.{},
    tracks: [99]Track = undefined,
    track_count: u8 = 0,

    pub fn init(data: []const u8) Disc {
        var d = Disc{ .data = data };
        d.tracks[0] = .{ .number = 1, .type = .data, .start_lba = 0 };
        d.track_count = 1;
        return d;
    }

    pub fn initFromCue(cue_text: []const u8, data: []const u8) Disc {
        var d = Disc{ .data = data };
        d.track_count = 0;

        var file_base_lba: i32 = 0; // absolute LBA where the current FILE begins
        var next_file_base: i32 = 0; // accumulator for the next FILE
        var pending_file_sectors: i32 = 0; // from the most recent REM FILESIZE

        var lines = std.mem.tokenizeAny(u8, cue_text, "\r\n");
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t");
            if (matchKeyword(line, "REM FILESIZE")) |rest| {
                const bytes = parseFirstInt(rest);
                pending_file_sectors = @intCast(@divTrunc(bytes, constants.sector_bytes));
            } else if (matchKeyword(line, "FILE")) |_| {
                file_base_lba = next_file_base;
                next_file_base += pending_file_sectors;
                pending_file_sectors = 0;
            } else if (matchKeyword(line, "TRACK")) |rest| {
                const number = @as(u8, @intCast(parseFirstInt(rest)));
                const ttype: TrackType = if (std.mem.indexOf(u8, rest, "AUDIO") != null) .audio else .data;
                d.tracks[d.track_count] = .{ .number = number, .type = ttype };
                d.track_count += 1;
            } else if (matchKeyword(line, "INDEX")) |rest| {
                if (d.track_count == 0) continue;
                const idx = parseFirstInt(rest); // 0 or 1
                const frames = parseMsfFrames(rest);
                const abs = file_base_lba + frames;
                const t = &d.tracks[d.track_count - 1];
                if (idx == 0) t.pregap_lba = abs else if (idx == 1) t.start_lba = abs;
            }
        }

        if (d.track_count == 0) {
            // Malformed/empty cue: fall back to a single data track.
            d.tracks[0] = .{ .number = 1, .type = .data, .start_lba = 0 };
            d.track_count = 1;
        }
        return d;
    }

    pub fn firstTrack(self: Disc) u8 {
        if (self.track_count == 0) return 1;
        return self.tracks[0].number;
    }

    pub fn lastTrack(self: Disc) u8 {
        if (self.track_count == 0) return 1;
        return self.tracks[self.track_count - 1].number;
    }

    pub fn trackStart(self: Disc, track_bcd: u8) ?MSF {
        const track = bcdToBinary(track_bcd);
        for (self.tracks[0..self.track_count]) |entry| {
            if (entry.number == track) return MSF.fromLba(entry.start_lba);
        }
        return null;
    }

    pub fn trackForLba(self: Disc, lba: i32) Track {
        var current = self.tracks[0];
        for (self.tracks[0..self.track_count]) |entry| {
            const entry_start = entry.pregap_lba orelse entry.start_lba;
            if (entry_start > lba) break;
            current = entry;
        }
        return current;
    }

    pub fn leadOut(self: Disc) MSF {
        const sector_count: i32 = @intCast(self.data.len / constants.sector_bytes);
        return MSF.fromLba(sector_count);
    }

    /// Attaches a `.sbi` sidecar. A file that does not carry the magic is
    /// ignored rather than parsed as records.
    pub fn setSbi(self: *Disc, bytes: []const u8) void {
        if (!std.mem.startsWith(u8, bytes, sbi_magic)) return;
        self.sbi = bytes[sbi_magic.len..];
    }

    /// Whether `lba` is one of the sectors a LibCrypt disc deliberately corrupts.
    ///
    /// The Q of such a sector fails its CRC on real hardware, so the drive
    /// discards the frame and goes on reporting the previous position. That
    /// stall is what the protection measures; the corrupt values the sidecar
    /// records never reach software, which is why only the address is read
    /// back out of each record.
    pub fn isLibCryptSector(self: Disc, lba: i32) bool {
        const msf = MSF.fromLba(lba);
        var i: usize = 0;
        while (i + sbi_record_bytes <= self.sbi.len) : (i += sbi_record_bytes) {
            const record = self.sbi[i..][0..sbi_record_bytes];
            if (record[0] == msf.m and record[1] == msf.s and record[2] == msf.f) return true;
        }
        return false;
    }

    pub fn getSubchannelQ(self: Disc, lba: i32) SubchannelQ {
        const current_track = self.trackForLba(lba);
        const track_lba = current_track.start_lba;

        const index: u8 = if (lba < track_lba) 0x00 else 0x01;
        const relative = MSF.fromFrames(lba - track_lba);
        const absolute = MSF.fromLba(lba);

        return .{
            .track = binaryToBcd(current_track.number),
            .index = index,
            .rel_m = relative.m,
            .rel_s = relative.s,
            .rel_f = relative.f,
            .abs_m = absolute.m,
            .abs_s = absolute.s,
            .abs_f = absolute.f,
        };
    }

    pub fn readSectorRaw(self: Disc, lba: i32, buffer: []u8, size: usize) bool {
        var raw: [constants.sector_bytes]u8 = undefined;
        if (!self.readSector2352(lba, &raw)) return false;

        const actual_size = @min(size, buffer.len);

        // Raw sector layout: sync(12) + header(4) + sub-header(8) + user data.
        // A 2048-byte request is a Form 1 user-data read and starts past the
        // sub-header at 018h; any other size is a whole-sector read that wants
        // the sub-header too, so it starts at 010h.
        const data_start: usize = if (size == mode1_data_bytes) 24 else 16;

        @memcpy(buffer[0..actual_size], raw[data_start..][0..actual_size]);

        return true;
    }

    pub fn readSector2352(self: Disc, lba: i32, buffer: *[constants.sector_bytes]u8) bool {
        if (lba < 0) return false;

        const sector_size = constants.sector_bytes;
        const offset = @as(usize, @intCast(lba)) * sector_size;

        if (offset + sector_size > self.data.len) {
            return false;
        }

        @memcpy(buffer, self.data[offset..][0..sector_size]);
        return true;
    }

    pub fn readSector(self: Disc, lba: i32, buffer: *[mode1_data_bytes]u8) bool {
        return self.readSectorRaw(lba, buffer[0..], mode1_data_bytes);
    }
};
