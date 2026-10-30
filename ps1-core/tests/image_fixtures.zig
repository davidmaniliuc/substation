//! Disc-image encoders for tests: each turns a raw 2352-byte-per-sector image
//! into one of the formats the core reads, so a reader is checked against the
//! bytes it must reproduce. Also the shared fixture discs and sheets.
const std = @import("std");
const ps1_core = @import("ps1_core");
const sector = ps1_core.sector;
const disc = ps1_core.disc;
const ccd = ps1_core.ccd;

const sector_bytes = 2352;

const ecm_raw = 0;
const ecm_mode1 = 1;
const ecm_form1 = 2;
const ecm_form2 = 3;

/// One run of records sharing a type: one chunk of the stream.
const EcmChunk = struct {
    type: u2 = ecm_raw,
    count: u32 = 0,
    records: std.ArrayList(u8) = .empty,
};

/// ECM-encodes `raw`: type 1 for a Mode 1 sector, the 16 sync/header bytes
/// raw then type 2 or 3 for a Mode 2 Form 1 or Form 2 sector, raw bytes for
/// anything else. A sector is only stripped when its rebuild matches it.
pub fn encodeEcm(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    std.debug.assert(raw.len % sector_bytes == 0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "ECM\x00");

    var chunk: EcmChunk = .{};
    defer chunk.records.deinit(gpa);

    var at: usize = 0;
    while (at < raw.len) : (at += sector_bytes) {
        const s = raw[at..][0..sector_bytes];
        switch (ecmTypeOf(s)) {
            ecm_mode1 => try addRecord(gpa, &out, &chunk, ecm_mode1, &.{ s[0x0C..0x0F], s[0x10..0x810] }),
            ecm_form1 => {
                try addRecord(gpa, &out, &chunk, ecm_raw, &.{s[0..0x10]});
                try addRecord(gpa, &out, &chunk, ecm_form1, &.{s[0x14..0x818]});
            },
            ecm_form2 => {
                try addRecord(gpa, &out, &chunk, ecm_raw, &.{s[0..0x10]});
                try addRecord(gpa, &out, &chunk, ecm_form2, &.{s[0x14..0x92C]});
            },
            else => try addRecord(gpa, &out, &chunk, ecm_raw, &.{s}),
        }
    }
    try flushChunk(gpa, &out, &chunk);
    try putEcmHeader(gpa, &out, ecm_raw, 0xFFFFFFFF);
    var edc: [4]u8 = undefined;
    std.mem.writeInt(u32, &edc, sector.edc(raw), .little);
    try out.appendSlice(gpa, &edc);
    return out.toOwnedSlice(gpa);
}

fn addRecord(gpa: std.mem.Allocator, out: *std.ArrayList(u8), chunk: *EcmChunk, kind: u2, parts: []const []const u8) !void {
    if (chunk.count != 0 and chunk.type != kind) try flushChunk(gpa, out, chunk);
    chunk.type = kind;
    for (parts) |p| try chunk.records.appendSlice(gpa, p);
    // A raw chunk is one record of `count` bytes; the others count records.
    chunk.count += if (kind == ecm_raw) @intCast(parts[0].len) else 1;
}

fn flushChunk(gpa: std.mem.Allocator, out: *std.ArrayList(u8), chunk: *EcmChunk) !void {
    if (chunk.count == 0) return;
    try putEcmHeader(gpa, out, chunk.type, chunk.count - 1);
    try out.appendSlice(gpa, chunk.records.items);
    chunk.records.clearRetainingCapacity();
    chunk.count = 0;
}

fn putEcmHeader(gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: u2, count_minus_one: u32) !void {
    var n = count_minus_one >> 5;
    try out.append(gpa, @as(u8, kind) | (@as(u8, @intCast(count_minus_one & 0x1F)) << 2) | (if (n != 0) @as(u8, 0x80) else 0));
    while (n != 0) {
        const low: u8 = @intCast(n & 0x7F);
        n >>= 7;
        try out.append(gpa, low | (if (n != 0) @as(u8, 0x80) else 0));
    }
}

/// Which record a sector can be stored as: the rebuild from what that record
/// keeps must give back the sector exactly.
fn ecmTypeOf(s: *const [sector_bytes]u8) u2 {
    if (!std.mem.eql(u8, s[0..12], &sector.sync_pattern)) return ecm_raw;
    var rebuilt: [sector_bytes]u8 = @splat(0);
    rebuilt[0..12].* = sector.sync_pattern;
    rebuilt[0x0C..0x10].* = s[0x0C..0x10].*;
    switch (s[15]) {
        1 => {
            @memcpy(rebuilt[0x10..0x810], s[0x10..0x810]);
            std.mem.writeInt(u32, rebuilt[0x810..0x814], sector.edc(rebuilt[0..0x810]), .little);
            sector.writeEcc(&rebuilt);
            return if (std.mem.eql(u8, &rebuilt, s)) ecm_mode1 else ecm_raw;
        },
        2 => {
            if (!std.mem.eql(u8, s[0x10..0x14], s[0x14..0x18])) return ecm_raw;
            rebuilt[0x10..0x18].* = s[0x10..0x18].*;
            if (s[0x12] & 0x20 != 0) {
                @memcpy(rebuilt[0x18..0x92C], s[0x18..0x92C]);
                std.mem.writeInt(u32, rebuilt[0x92C..0x930], sector.edc(rebuilt[0x10..0x92C]), .little);
                return if (std.mem.eql(u8, &rebuilt, s)) ecm_form2 else ecm_raw;
            }
            @memcpy(rebuilt[0x18..0x818], s[0x18..0x818]);
            std.mem.writeInt(u32, rebuilt[0x818..0x81C], sector.edc(rebuilt[0x10..0x818]), .little);
            sector.writeEcc(&rebuilt);
            return if (std.mem.eql(u8, &rebuilt, s)) ecm_form1 else ecm_raw;
        },
        else => return ecm_raw,
    }
}

/// The three-track fixture disc: a Mode 2 then Mode 1 data track and two
/// audio tracks, with its cue sheet.
pub const disc_bin = @embedFile("chd/disc.bin");
pub const disc_cue = @embedFile("chd/disc.cue");

pub const ccd_header =
    \\[CloneCD]
    \\Version=3
    \\[Disc]
    \\TocEntries=4
    \\Sessions=1
    \\
;

/// The CloneCD sheet of `disc_cue`: track 1 data at 0, track 2 audio from 40
/// (pregap 30), track 3 audio from 93 (pregap 91), lead-out at 113.
pub const ccd_sheet = ccd_header ++
    \\[Entry 0]
    \\Point=0x01
    \\Control=0x04
    \\PLBA=0
    \\[Entry 1]
    \\Point=0x02
    \\Control=0x00
    \\PLBA=40
    \\[Entry 2]
    \\Point=0x03
    \\Control=0x00
    \\PLBA=93
    \\[Entry 3]
    \\Point=0xa2
    \\Control=0x00
    \\PLBA=113
    \\[TRACK 1]
    \\MODE=2
    \\INDEX 1=0
    \\[TRACK 2]
    \\MODE=0
    \\INDEX 0=30
    \\INDEX 1=40
    \\[TRACK 3]
    \\MODE=0
    \\INDEX 0=91
    \\INDEX 1=93
    \\
;

/// A `.sub` of `count` sectors whose every Q is valid for its address, but
/// for the sectors in `broken`, whose CRC is corrupt (LibCrypt's mark).
pub fn cloneSub(gpa: std.mem.Allocator, count: usize, broken: []const usize) ![]u8 {
    const sub = try gpa.alloc(u8, count * 96);
    @memset(sub, 0);
    for (0..count) |i| {
        const m = disc.MSF.fromLba(@intCast(i));
        const q = sub[i * 96 + 12 ..][0..12];
        q[0..10].* = .{ 0x41, 0x01, 0x01, 0, 0, 0, m.m, m.s, m.f, 0 };
        const crc = ccd.qCrc(q[0..10]);
        q[10] = @truncate(crc >> 8);
        q[11] = @truncate(crc);
    }
    for (broken) |i| sub[i * 96 + 12 + 11] ^= 0xFF;
    return sub;
}

/// The cooked copy of `raw`: each sector's 2048 bytes of user data, from
/// wherever its own mode byte puts them.
pub fn cook(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    std.debug.assert(raw.len % sector_bytes == 0);
    const count = raw.len / sector_bytes;
    const out = try gpa.alloc(u8, count * 2048);
    for (0..count) |i| {
        const s = raw[i * sector_bytes ..][0..sector_bytes];
        const start: usize = if (s[15] == 1) 16 else 24;
        @memcpy(out[i * 2048 ..][0..2048], s[start..][0..2048]);
    }
    return out;
}

/// The licence area of an American disc, its spacing as mastered.
pub const license_america = "          Licensed  by          Sony Computer Entertainment Amer  ica ";

pub const IsoLayout = struct {
    mode: u8 = 2,
    license: []const u8 = license_america,
    system_cnf: []const u8 = "BOOT = cdrom:\\SLUS_005.30;1\r\nTCB = 4\r\n",
    volume_id: []const u8 = "CROC",
    iso: bool = true,
};

pub const iso_sectors = 40;
const root_dir_lba = 22;
const system_cnf_lba = 30;

/// Writes the sector layout every real rip has: licence area at LBA 4, primary volume
/// descriptor at 16, its root directory past that, and SYSTEM.CNF past that.
/// Written at whichever offset `mode` implies, so one builder produces both a
/// Mode 1 and a Mode 2 disc.
pub fn writeIso(image: *[sector_bytes * iso_sectors]u8, layout: IsoLayout) void {
    @memset(image, 0);

    writeSector(image, 4, layout.mode, layout.license);

    if (layout.iso) {
        var pvd: [2048]u8 = @splat(0);
        pvd[0] = 1;
        @memcpy(pvd[1..6], "CD001");
        pvd[6] = 1;
        @memset(pvd[40..72], ' ');
        @memcpy(pvd[40..][0..layout.volume_id.len], layout.volume_id);
        _ = writeDirRecord(pvd[156..], root_dir_lba, 2048, "\x00");
        writeSector(image, 16, layout.mode, &pvd);

        var root: [2048]u8 = @splat(0);
        var at: usize = 0;
        at += writeDirRecord(root[at..], root_dir_lba, 2048, "\x00");
        at += writeDirRecord(root[at..], root_dir_lba, 2048, "\x01");
        at += writeDirRecord(root[at..], system_cnf_lba, layout.system_cnf.len, "SYSTEM.CNF;1");
        writeSector(image, root_dir_lba, layout.mode, &root);

        writeSector(image, system_cnf_lba, layout.mode, layout.system_cnf);
    }
}

fn writeSector(image: []u8, lba: usize, mode: u8, payload: []const u8) void {
    const base = lba * sector_bytes;
    image[base + 15] = mode;
    const start = base + @as(usize, if (mode == 0x01) 16 else 24);
    @memcpy(image[start..][0..payload.len], payload);
}

/// One ISO 9660 directory record. Records are padded to an even length, which
/// is why the caller has to be told how far to advance.
fn writeDirRecord(out: []u8, extent: u32, length: usize, name: []const u8) usize {
    const size = 33 + name.len + (name.len + 1) % 2;
    out[0] = @intCast(size);
    std.mem.writeInt(u32, out[2..6], extent, .little);
    std.mem.writeInt(u32, out[10..14], @intCast(length), .little);
    out[32] = @intCast(name.len);
    @memcpy(out[33..][0..name.len], name);
    return size;
}
