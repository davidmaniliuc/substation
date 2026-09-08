const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const ps1_core = @import("ps1_core");
const discid = ps1_core.discid;
const disc_mod = ps1_core.disc;

const sector_bytes = 2352;
const sectors = 40;

// The licence area exactly as it sits on the discs in `games/`, spacing and
// all. Sony's mastering tool padded these by eye: "America" carries a space
// inside the word on most discs, and three separate spellings are in
// circulation. A matcher that compares them literally — which is what
// DuckStation does — fails on the last three.
const license_america = "          Licensed  by          Sony Computer Entertainment Amer  ica ";
const license_europe = "          Licensed  by          Sony Computer Entertainment Euro pe   ";
const license_japan = "          Licensed  by          Sony Computer Entertainment Inc.";
const license_europe_compact = "          Licensed  by          Sony Computer Entertainment(Europe)";
const license_america_of = "          Licensed  by          Sony Computer Entertainment of America";

const Layout = struct {
    mode: u8 = 2,
    license: []const u8 = license_america,
    system_cnf: []const u8 = "BOOT = cdrom:\\SLUS_005.30;1\r\nTCB = 4\r\n",
    volume_id: []const u8 = "CROC",
    iso: bool = true,
};

const root_dir_lba = 22;
const system_cnf_lba = 30;

/// The sector layout every real rip has: licence area at LBA 4, primary volume
/// descriptor at 16, its root directory past that, and SYSTEM.CNF past that.
/// Written at whichever offset `mode` implies, so one builder produces both a
/// Mode 1 and a Mode 2 disc.
fn build(image: *[sector_bytes * sectors]u8, layout: Layout) disc_mod.Disc {
    @memset(image, 0);

    writeSector(image, 4, layout.mode, layout.license);

    if (layout.iso) {
        var pvd = [_]u8{0} ** 2048;
        pvd[0] = 1;
        @memcpy(pvd[1..6], "CD001");
        pvd[6] = 1;
        @memset(pvd[40..72], ' ');
        @memcpy(pvd[40..][0..layout.volume_id.len], layout.volume_id);
        _ = writeDirRecord(pvd[156..], root_dir_lba, 2048, "\x00");
        writeSector(image, 16, layout.mode, &pvd);

        var root = [_]u8{0} ** 2048;
        var at: usize = 0;
        at += writeDirRecord(root[at..], root_dir_lba, 2048, "\x00");
        at += writeDirRecord(root[at..], root_dir_lba, 2048, "\x01");
        at += writeDirRecord(root[at..], system_cnf_lba, layout.system_cnf.len, "SYSTEM.CNF;1");
        writeSector(image, root_dir_lba, layout.mode, &root);

        writeSector(image, system_cnf_lba, layout.mode, layout.system_cnf);
    }

    return disc_mod.Disc.init(image);
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

test "the licence string is matched with its spacing stripped" {
    try expectEqual(discid.Region.america, discid.licenseRegion(license_america).?);
    try expectEqual(discid.Region.europe, discid.licenseRegion(license_europe).?);
    try expectEqual(discid.Region.japan, discid.licenseRegion(license_japan).?);
    try expectEqual(discid.Region.europe, discid.licenseRegion(license_europe_compact).?);
    try expectEqual(discid.Region.america, discid.licenseRegion(license_america_of).?);
}

test "an unrecognised licence area names no region" {
    try expectEqual(@as(?discid.Region, null), discid.licenseRegion("PlayStation demo disc"));
    try expectEqual(@as(?discid.Region, null), discid.licenseRegion(""));
}

test "a serial prefix names a region" {
    try expectEqual(discid.Region.europe, discid.regionForSerial("SCES-00344").?);
    try expectEqual(discid.Region.europe, discid.regionForSerial("SLED-01234").?);
    try expectEqual(discid.Region.japan, discid.regionForSerial("SLPS-01234").?);
    try expectEqual(discid.Region.japan, discid.regionForSerial("PAPX-90001").?);
    try expectEqual(discid.Region.america, discid.regionForSerial("SLUS-00530").?);
    try expectEqual(discid.Region.america, discid.regionForSerial("scus-94163").?);
    try expectEqual(@as(?discid.Region, null), discid.regionForSerial("PSX.EXE"));
}

test "a Mode 2 disc's serial comes from SYSTEM.CNF" {
    var image: [sector_bytes * sectors]u8 = undefined;
    const d = build(&image, .{});
    const id = discid.identify(d);
    try expectEqualStrings("SLUS-00530", id.serial.slice());
    try expectEqualStrings("CROC", id.volumeId());
    try expectEqual(discid.Region.america, id.region.?);
}

// The user data of a Mode 1 sector starts eight bytes earlier, because it
// carries no sub-header. Reading it at the Mode 2 offset makes the whole ISO
// filesystem unreadable, which is the bug that parks the BIOS in
// SystemErrorBootOrDiskFailure.
test "a Mode 1 disc's user data starts eight bytes earlier" {
    var image: [sector_bytes * sectors]u8 = undefined;
    const d = build(&image, .{ .mode = 0x01 });
    try expectEqualStrings("SLUS-00530", discid.identify(d).serial.slice());
}

test "a BOOT path is taken apart whatever shape it has" {
    var image: [sector_bytes * sectors]u8 = undefined;

    // Castlevania: no leading backslash.
    var d = build(&image, .{ .system_cnf = "BOOT = cdrom:SLUS_000.67;1\r\nTCB = 4\r\n" });
    try expectEqualStrings("SLUS-00067", discid.identify(d).serial.slice());

    // Tekken 3: the executable sits in a subdirectory.
    d = build(&image, .{ .system_cnf = "BOOT = cdrom:\\TEKKEN3\\SLUS_004.02;1\r\n" });
    try expectEqualStrings("SLUS-00402", discid.identify(d).serial.slice());

    // Tomb Raider: lowercase, and no spaces around the '='.
    d = build(&image, .{ .system_cnf = "BOOT=cdrom:\\slus_001.52;1\r\nEVENT=10\r\n" });
    try expectEqualStrings("SLUS-00152", discid.identify(d).serial.slice());
}

test "the region falls back to the serial when the licence area is unreadable" {
    var image: [sector_bytes * sectors]u8 = undefined;
    const d = build(&image, .{
        .license = "scrambled",
        .system_cnf = "BOOT=cdrom:\\SLES_029.66;1\r\n",
    });
    const id = discid.identify(d);
    try expectEqual(discid.Region.europe, id.region.?);
    try expectEqualStrings("SLES-02966", id.serial.slice());
}

test "a disc with no ISO filesystem still reports its licence region" {
    var image: [sector_bytes * sectors]u8 = undefined;
    const d = build(&image, .{ .license = license_europe, .iso = false });
    const id = discid.identify(d);
    try expectEqual(discid.Region.europe, id.region.?);
    try expect(id.serial.slice().len == 0);
    try expect(id.volumeId().len == 0);
}

test "a boot file that is not a serial yields none" {
    var image: [sector_bytes * sectors]u8 = undefined;
    const d = build(&image, .{ .system_cnf = "BOOT = cdrom:\\PSX.EXE;1\r\n" });
    try expect(discid.identify(d).serial.slice().len == 0);
}
