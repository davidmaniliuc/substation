const std = @import("std");
const constants = @import("constants.zig");
const chd = @import("chd/chd.zig");
const ecm = @import("ecm.zig");
const pbp = @import("pbp/pbp.zig");
const ppf = @import("ppf.zig");
const cooked_sector = @import("sector.zig");
const msf_mod = @import("msf.zig");

/// User-data payload of a standard PS1 sector: Mode 1, or Mode 2 Form 1 (the
/// 2352-byte raw sector minus sync/header/subheader/ECC). Also the size
/// `readSectorRaw` uses to pick which sub-header offset to skip.
const mode1_data_bytes = 2048;

pub const MSF = msf_mod.MSF;
pub const bcdToBinary = msf_mod.bcdToBinary;
pub const binaryToBcd = msf_mod.binaryToBcd;

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
pub const sbi_magic = "SBI\x00";
pub const sbi_record_bytes = 14;

/// Counts `FILE` directives in a cue sheet.
///
/// `initFromCue` lays multiple FILEs out using `REM FILESIZE` lines, but a
/// `Disc` holds a single data slice, so a caller that cannot concatenate the
/// images must reject a multi-FILE cue up front rather than mis-lay it out.
pub fn countCueFiles(cue_text: []const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, cue_text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (std.mem.startsWith(u8, line, "FILE ")) n += 1;
    }
    return n;
}

/// Whether `initFromCue` can place every FILE in `cue_text`.
///
/// A `Disc` holds one data slice, so a multi-FILE cue is laid out from the
/// `REM FILESIZE` line preceding each FILE: that size is what moves the base
/// LBA on to the NEXT one. Every FILE but the last therefore needs one, and it
/// has to be at least a sector — a size that rounds to nothing stacks the two
/// images at the same base rather than placing them. The last FILE's size
/// places nothing and may be absent.
pub fn cueFilesAreLaidOut(cue_text: []const u8) bool {
    var files: usize = 0;
    var previous_file_placed = true; // vacuous until there is a previous FILE
    var pending_sectors: i64 = 0;

    var lines = std.mem.tokenizeAny(u8, cue_text, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (matchKeyword(line, "REM FILESIZE")) |rest| {
            pending_sectors = @divTrunc(parseFirstInt(rest), constants.sector_bytes);
        } else if (matchKeyword(line, "FILE")) |_| {
            if (files > 0 and !previous_file_placed) return false;
            files += 1;
            previous_file_placed = pending_sectors > 0;
            pending_sectors = 0;
        }
    }
    return true;
}

/// Where a disc's sectors come from.
pub const Source = union(enum) {
    /// A flat image, 2352 bytes per sector, owned by the caller.
    flat: []const u8,
    /// A CHD, decompressed on demand; the reader is owned by the caller.
    chd: *chd.Reader,
    /// A cooked image: `mode.bytes()` per sector, dressed into a raw sector on
    /// read. One data track, owned by the caller.
    cooked: struct { data: []const u8, mode: cooked_sector.CookedMode },
    /// An ECM image, decoded on demand; the reader is owned by the caller.
    ecm: *ecm.Reader,
    /// One disc of an eboot, inflated on demand; the reader is owned by the caller.
    pbp: *pbp.Reader,
};

/// The cooked layout a cue sheet's TRACK mode names, if any. Null when every
/// TRACK is a raw mode or audio; an error when a cooked track shares the disc
/// with a second TRACK or FILE, which a single cooked source cannot lay out.
pub fn cueCookedMode(cue_text: []const u8) error{CookedLayout}!?cooked_sector.CookedMode {
    const modes = [_]struct { name: []const u8, mode: cooked_sector.CookedMode }{
        .{ .name = "MODE1/2048", .mode = .mode1 },
        .{ .name = "MODE2/2336", .mode = .mode2 },
        .{ .name = "MODE2/2048", .mode = .mode2_form1 },
        .{ .name = "MODE2/2324", .mode = .mode2_form2 },
        .{ .name = "MODE2/2332", .mode = .mode2_mixed },
    };
    var found: ?cooked_sector.CookedMode = null;
    var tracks: usize = 0;
    var lines = std.mem.tokenizeAny(u8, cue_text, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        const rest = matchKeyword(line, "TRACK") orelse continue;
        tracks += 1;
        for (modes) |m| {
            if (std.mem.indexOf(u8, rest, m.name) != null) found = m.mode;
        }
    }
    const mode = found orelse return null;
    if (tracks != 1 or countCueFiles(cue_text) != 1) return error.CookedLayout;
    return mode;
}

pub const Disc = struct {
    source: Source,
    /// The record region of a `.sbi`, magic already stripped. Empty for the
    /// unprotected discs that are the overwhelming majority.
    sbi: []const u8 = &.{},
    /// The sectors a `.ppf` rewrites, served in place of the `Source`'s.
    /// Empty for an unpatched disc.
    patch: ppf.Overlay = .{},
    tracks: [99]Track = undefined,
    track_count: u8 = 0,

    pub fn init(data: []const u8) Disc {
        var d = Disc{ .source = .{ .flat = data } };
        d.tracks[0] = .{ .number = 1, .type = .data, .start_lba = 0 };
        d.track_count = 1;
        return d;
    }

    /// A cue-less image, told apart by content: a raw sector dump (sync, then
    /// a mode byte of 1 or 2) is the plain data track, any other whole number
    /// of 2352-byte sectors is audio, and anything else is a 2048-byte ISO.
    pub fn initLone(data: []const u8) Disc {
        const raw = data.len % constants.sector_bytes == 0;
        const synced = data.len >= 16 and std.mem.eql(u8, data[0..12], &cooked_sector.sync_pattern) and
            (data[15] == 1 or data[15] == 2);
        var d = init(data);
        if (raw and synced) return d;
        if (raw) {
            d.tracks[0].type = .audio;
        } else {
            d.source = .{ .cooked = .{ .data = data, .mode = .mode1 } };
        }
        return d;
    }

    /// `initFromCue`'s track table over a cooked image.
    pub fn initCookedCue(cue_text: []const u8, data: []const u8, mode: cooked_sector.CookedMode) Disc {
        var d = initFromCue(cue_text, data);
        d.source = .{ .cooked = .{ .data = data, .mode = mode } };
        return d;
    }

    pub fn initFromChd(reader: *chd.Reader) Disc {
        var d = Disc{ .source = .{ .chd = reader } };
        d.track_count = reader.track_count;
        @memcpy(d.tracks[0..reader.track_count], reader.tracks[0..reader.track_count]);
        return d;
    }

    /// One data track; a cue sheet's tracks are applied over it by the caller.
    pub fn initFromEcm(reader: *ecm.Reader) Disc {
        var d = Disc{ .source = .{ .ecm = reader } };
        d.tracks[0] = .{ .number = 1, .type = .data, .start_lba = 0 };
        d.track_count = 1;
        return d;
    }

    pub fn initFromPbp(reader: *pbp.Reader) Disc {
        var d = Disc{ .source = .{ .pbp = reader } };
        d.track_count = reader.track_count;
        @memcpy(d.tracks[0..reader.track_count], reader.tracks[0..reader.track_count]);
        return d;
    }

    pub fn sectorCount(self: Disc) i32 {
        return switch (self.source) {
            .flat => |data| @intCast(data.len / constants.sector_bytes),
            .chd => |reader| reader.sectorCount(),
            .cooked => |c| @intCast(c.data.len / c.mode.bytes()),
            .ecm => |reader| reader.sectorCount(),
            .pbp => |reader| reader.sectorCount(),
        };
    }

    pub fn initFromCue(cue_text: []const u8, data: []const u8) Disc {
        var d = Disc{ .source = .{ .flat = data } };
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
        return MSF.fromLba(self.sectorCount());
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

        // Raw sector layout: sync(12) + header(4) [+ sub-header(8)] + user data.
        // A 2048-byte request is a user-data read: Mode 1 has no sub-header, so
        // it starts at 010h, and Mode 2 Form 1 starts past the sub-header at
        // 018h. Any other size is a whole-sector read that wants the sub-header
        // too, so it starts at 010h.
        const data_start: usize = if (size == mode1_data_bytes and raw[15] != 1) 24 else 16;

        @memcpy(buffer[0..actual_size], raw[data_start..][0..actual_size]);

        return true;
    }

    pub fn readSector2352(self: Disc, lba: i32, buffer: *[constants.sector_bytes]u8) bool {
        if (lba < 0) return false;
        if (self.patch.find(lba)) |sector| {
            buffer.* = sector.*;
            return true;
        }

        switch (self.source) {
            .chd => |reader| return reader.readSector(lba, buffer),
            .ecm => |reader| return reader.readSector(lba, buffer),
            .pbp => |reader| return reader.readSector(lba, buffer),
            .flat => |data| {
                const offset = @as(usize, @intCast(lba)) * constants.sector_bytes;
                if (offset + constants.sector_bytes > data.len) return false;
                @memcpy(buffer, data[offset..][0..constants.sector_bytes]);
                return true;
            },
            .cooked => |c| {
                switch (c.mode) {
                    inline else => |mode| {
                        const n = comptime mode.bytes();
                        const offset = @as(usize, @intCast(lba)) * n;
                        if (offset + n > c.data.len) return false;
                        cooked_sector.dress(mode, lba, c.data[offset..][0..n], buffer);
                    },
                }
                return true;
            },
        }
    }

    pub fn readSector(self: Disc, lba: i32, buffer: *[mode1_data_bytes]u8) bool {
        return self.readSectorRaw(lba, buffer[0..], mode1_data_bytes);
    }
};
