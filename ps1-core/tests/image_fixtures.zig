//! Disc-image fixtures for tests: encoders that turn a raw 2352-byte-per-sector
//! image into one of the formats the core reads, so a reader is checked against
//! the bytes it must reproduce, and the shared fixture discs and sheets.
const std = @import("std");
const ps1_core = @import("ps1_core");
const disc = ps1_core.disc;
const ccd = ps1_core.ccd;

const sector_bytes = 2352;

/// The harness's encoders, so a reader is checked against the same bytes the
/// round trip over real discs writes.
const image_write = @import("image_write");
pub const encodeEcm = image_write.encodeEcm;
pub const cook = image_write.cook;

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
