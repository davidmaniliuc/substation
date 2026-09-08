//! Identifying a disc from the disc itself.
//!
//! Two signals, and both are on the disc: the licence string the BIOS reads at
//! LBA 4, and the boot executable named by SYSTEM.CNF, whose four-letter
//! prefix carries a region of its own. Nothing here consults a filename or a
//! database, so a renamed rip still identifies, and a disc no database has
//! heard of identifies as well as a famous one.
//!
//! What is deliberately NOT here: a title, and any notion of which discs
//! belong to one multi-disc game. Neither is recorded on a PS1 disc — the
//! volume-set fields ISO 9660 reserves for it read 1-of-1 on every rip
//! measured — so both are the frontend's problem, and DuckStation only
//! answers them by shipping a curated serial table.

const std = @import("std");
const constants = @import("constants.zig");
const disc_mod = @import("disc.zig");

/// The BIOS reads its licence check from LBA 4; ISO 9660 puts the primary
/// volume descriptor at 16. Both are fixed by their respective standards.
const license_lba = 4;
const pvd_lba = 16;
const iso_sector_bytes = 2048;

/// Raw-sector layout, the same rule `cdrom.zig` applies: the header's last
/// byte is the mode, and only Mode 1 drops the 8-byte sub-header and starts
/// its user data at 010h. Reading a Mode 1 disc at the Mode 2 offset shifts
/// every sector eight bytes late and makes the filesystem unreadable.
const mode_byte_offset = 15;
const mode1_data_offset = 16;
const mode2_data_offset = 24;

/// A directory record's fixed fields: extent LBA, data length, and the length
/// of the name that follows the header.
const rec_extent = 2;
const rec_length = 10;
const rec_name_len = 32;
const rec_header_bytes = 33;

/// The PVD's volume identifier, and the root directory record embedded in it.
const pvd_volume_id = 40;
const pvd_volume_id_bytes = 32;
const pvd_root_record = 156;

/// A directory bigger than this is not one we are looking in. SYSTEM.CNF lives
/// in the root, which is a sector or two; the cap only bounds a corrupt length
/// field.
const max_dir_sectors = 16;

pub const Region = enum { america, europe, japan };

/// `SLUS-00530`, or empty when the disc names no serial. A fixed buffer rather
/// than a slice because a `DiscId` outlives the sector it was read out of.
pub const Serial = struct {
    buf: [16]u8 = [_]u8{0} ** 16,
    len: u8 = 0,

    pub fn slice(self: *const Serial) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const DiscId = struct {
    /// The licence region, or the serial's when the licence area is not one of
    /// the three known spellings. Null for a disc that is neither.
    region: ?Region = null,
    serial: Serial = .{},
    volume_buf: [pvd_volume_id_bytes]u8 = [_]u8{0} ** pvd_volume_id_bytes,
    volume_len: u8 = 0,

    /// The ISO volume identifier — `FINALFANTASY7`, `CROC`, or empty. Not a
    /// title: it is absent on Silent Hill, FF9 and Metal Gear Solid, and it is
    /// `SLUS_00067` on Castlevania.
    pub fn volumeId(self: *const DiscId) []const u8 {
        return self.volume_buf[0..self.volume_len];
    }
};

/// The region named by the licence area, matched with all whitespace removed.
///
/// The string is padded by eye and the padding lands INSIDE the words:
/// "Amer  ica" and "Euro pe" are what most discs carry, against a compact
/// "Entertainment(Europe)" on Rayman and Doom and an "of America" on Tekken.
/// DuckStation compares three literals with `memcmp`, which misses the last
/// two spellings; stripping first matches all five.
pub fn licenseRegion(text: []const u8) ?Region {
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    for (text) |c| {
        if (c == 0 or std.ascii.isWhitespace(c)) continue;
        if (n == buf.len) break;
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    const flat = buf[0..n];

    // Anchored on the sentence, so arbitrary sector contents that happen to
    // contain "america" are not read as a licence.
    if (std.mem.indexOf(u8, flat, "computerentertainment") == null) return null;

    if (std.mem.indexOf(u8, flat, "america") != null) return .america;
    if (std.mem.indexOf(u8, flat, "europe") != null) return .europe;
    if (std.mem.indexOf(u8, flat, "inc.") != null) return .japan;
    return null;
}

/// The region named by a serial's four-letter prefix. Sony's own allocation,
/// and the same table DuckStation carries.
pub fn regionForSerial(serial: []const u8) ?Region {
    const prefixes = [_]struct { []const u8, Region }{
        .{ "sces", .europe },  .{ "sced", .europe },  .{ "sles", .europe },
        .{ "sled", .europe },  .{ "scps", .japan },   .{ "slps", .japan },
        .{ "slpm", .japan },   .{ "sczs", .japan },   .{ "papx", .japan },
        .{ "scus", .america }, .{ "slus", .america },
    };

    if (serial.len < 4) return null;
    var head: [4]u8 = undefined;
    for (serial[0..4], 0..) |c, i| head[i] = std.ascii.toLower(c);

    for (prefixes) |entry| {
        if (std.mem.eql(u8, &head, entry[0])) return entry[1];
    }
    return null;
}

pub fn identify(d: disc_mod.Disc) DiscId {
    var id = DiscId{};

    var sector: [iso_sector_bytes]u8 = undefined;
    if (readUserData(d, license_lba, &sector)) {
        id.region = licenseRegion(&sector);
    }

    if (readUserData(d, pvd_lba, &sector) and isPvd(&sector)) {
        id.volume_len = @intCast(trimmed(sector[pvd_volume_id..][0..pvd_volume_id_bytes]).len);
        @memcpy(id.volume_buf[0..id.volume_len], trimmed(sector[pvd_volume_id..][0..pvd_volume_id_bytes]));

        const root = extentOf(sector[pvd_root_record..]);
        if (findInDirectory(d, root, "SYSTEM.CNF")) |cnf| {
            if (readUserData(d, cnf.lba, &sector)) {
                const bytes = @min(cnf.len, iso_sector_bytes);
                id.serial = bootSerial(sector[0..bytes]);
            }
        }
    }

    if (id.region == null) id.region = regionForSerial(id.serial.slice());
    return id;
}

const Extent = struct { lba: i32, len: u32 };

fn isPvd(sector: []const u8) bool {
    return sector[0] == 1 and std.mem.eql(u8, sector[1..6], "CD001");
}

fn extentOf(record: []const u8) Extent {
    return .{
        .lba = @intCast(std.mem.readInt(u32, record[rec_extent..][0..4], .little)),
        .len = std.mem.readInt(u32, record[rec_length..][0..4], .little),
    };
}

/// Reads a sector's 800h user bytes, taking the offset from the sector's own
/// mode byte.
fn readUserData(d: disc_mod.Disc, lba: i32, out: *[iso_sector_bytes]u8) bool {
    var raw: [constants.sector_bytes]u8 = undefined;
    if (!d.readSector2352(lba, &raw)) return false;

    const start: usize = if (raw[mode_byte_offset] == 0x01)
        mode1_data_offset
    else
        mode2_data_offset;

    @memcpy(out, raw[start..][0..iso_sector_bytes]);
    return true;
}

/// A directory record never straddles a sector boundary — the remainder of a
/// sector is zero padding — so each sector is scanned until a zero length byte.
fn findInDirectory(d: disc_mod.Disc, dir: Extent, name: []const u8) ?Extent {
    const total = (dir.len + iso_sector_bytes - 1) / iso_sector_bytes;
    var sector: u32 = 0;
    while (sector < @min(total, max_dir_sectors)) : (sector += 1) {
        var buf: [iso_sector_bytes]u8 = undefined;
        if (!readUserData(d, dir.lba + @as(i32, @intCast(sector)), &buf)) return null;

        var at: usize = 0;
        while (at + rec_header_bytes <= buf.len) {
            const size = buf[at];
            if (size == 0 or at + size > buf.len) break;

            const name_len = buf[at + rec_name_len];
            if (at + rec_header_bytes + name_len <= buf.len and
                nameMatches(buf[at + rec_header_bytes ..][0..name_len], name))
            {
                return extentOf(buf[at..]);
            }
            at += size;
        }
    }
    return null;
}

/// ISO names carry a `;1` version suffix, and case is not guaranteed.
fn nameMatches(entry: []const u8, name: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, entry, ';') orelse entry.len;
    return std.ascii.eqlIgnoreCase(entry[0..end], name);
}

fn trimmed(field: []const u8) []const u8 {
    return std.mem.trimEnd(u8, field, " \x00");
}

/// Pulls the serial out of SYSTEM.CNF's `BOOT` line.
///
/// The line is `BOOT = cdrom:\SLUS_005.30;1` on most discs, but Castlevania
/// drops the backslash, Tekken 3 puts the executable in a subdirectory, and
/// Tomb Raider writes it in lowercase — so the value is reduced to its last
/// path component, and that is reduced to four letters and its digits.
fn bootSerial(system_cnf: []const u8) Serial {
    var lines = std.mem.tokenizeAny(u8, system_cnf, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len < 4 or !std.ascii.eqlIgnoreCase(line[0..4], "BOOT")) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        const tail = value[(std.mem.lastIndexOfAny(u8, value, "\\/:") orelse 0) + 1 ..];
        const name = tail[0 .. std.mem.indexOfScalar(u8, tail, ';') orelse tail.len];
        return normalise(name);
    }
    return .{};
}

/// `SLUS_005.30` -> `SLUS-00530`. A name that is not four letters followed by
/// digits — `PSX.EXE`, the BIOS's own fallback — is not a serial.
fn normalise(name: []const u8) Serial {
    var serial = Serial{};

    var letters: usize = 0;
    while (letters < name.len and std.ascii.isAlphabetic(name[letters])) : (letters += 1) {}
    if (letters != 4) return .{};

    for (name[0..4], 0..) |c, i| serial.buf[i] = std.ascii.toUpper(c);
    serial.buf[4] = '-';
    serial.len = 5;

    for (name[4..]) |c| {
        if (!std.ascii.isDigit(c)) continue;
        if (serial.len == serial.buf.len) break;
        serial.buf[serial.len] = c;
        serial.len += 1;
    }

    // Four letters and a dash is not a serial either.
    return if (serial.len > 5) serial else .{};
}
