const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const ps1_core = @import("ps1_core");
const discid = ps1_core.discid;
const discdb = ps1_core.discdb;
const game_titles = ps1_core.game_titles;
const pgxp_presets = ps1_core.pgxp_presets;
const vram_readbacks = ps1_core.vram_readbacks;
const disc_mod = ps1_core.disc;
const fixtures = @import("image_fixtures.zig");

const sector_bytes = 2352;
const sectors = fixtures.iso_sectors;

// The licence area exactly as it sits on the discs in `games/`, spacing and
// all. Sony's mastering tool padded these by eye: "America" carries a space
// inside the word on most discs, and three separate spellings are in
// circulation. A matcher that compares them literally — which is what
// DuckStation does — fails on the last three.
const license_america = fixtures.license_america;
const license_europe = "          Licensed  by          Sony Computer Entertainment Euro pe   ";
const license_japan = "          Licensed  by          Sony Computer Entertainment Inc.";
const license_europe_compact = "          Licensed  by          Sony Computer Entertainment(Europe)";
const license_america_of = "          Licensed  by          Sony Computer Entertainment of America";

const Layout = fixtures.IsoLayout;

fn build(image: *[sector_bytes * sectors]u8, layout: Layout) disc_mod.Disc {
    fixtures.writeIso(image, layout);
    return disc_mod.Disc.init(image);
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

test "the disc database gives a known multi-disc serial its canonical set and ordinal" {
    const entry = discdb.lookup("SLES-12965") orelse return error.MissingEntry;
    try expectEqualStrings("Final Fantasy IX (Europe)", entry.game_title);
    try expectEqual(@as(u8, 2), entry.disc_number);
    try expect(discdb.lookup("SLUS-00530") == null);
}

test "the disc database places a subtitled disc and a reprint serial in their sets" {
    // "(Disc 3) (VR-Disc)": a disc whose name carries more than its number.
    const vr = discdb.lookup("SCPS-45414") orelse return error.MissingEntry;
    try expectEqual(@as(u8, 3), vr.disc_number);
    try expectEqualStrings((discdb.lookup("SCPS-45412") orelse return error.MissingEntry).game_title, vr.game_title);
    // A reprint serial is in the set through its disc's codes list.
    const reprint = discdb.lookup("SLPS-03416") orelse return error.MissingEntry;
    try expectEqualStrings("Black-Matrix + (Japan)", reprint.game_title);
    try expectEqual(@as(u8, 2), reprint.disc_number);
}

test "the disc database is sorted, unique and one-based" {
    for (discdb.entries, 0..) |entry, i| {
        try expect(entry.disc_number >= 1);
        if (i > 0) try expect(std.mem.lessThan(u8, discdb.entries[i - 1].serial, entry.serial));
    }
}

test "the title table names a disc by its serial, per disc and through codes lists" {
    try expectEqualStrings("Tomb Raider", (game_titles.lookup("SLUS-00152") orelse return error.MissingEntry).title);
    try expectEqualStrings("Final Fantasy VII (Disc 2)", (game_titles.lookup("scus-94164") orelse return error.MissingEntry).title);
    // One entry, two serials: its codes list is the key, not the entry's own.
    const a = game_titles.lookup("SLPS-01311") orelse return error.MissingEntry;
    const b = game_titles.lookup("SLPS-02546") orelse return error.MissingEntry;
    try expectEqualStrings(a.title, b.title);
    try expect(game_titles.lookup("SLUS-99999") == null);
    try expect(game_titles.lookup("") == null);
}

test "the title table is sorted, unique and serial-keyed" {
    for (game_titles.entries, 0..) |entry, i| {
        try expect(!std.mem.startsWith(u8, entry.serial, "HASH-"));
        try expect(entry.title.len > 0 and entry.title.len < 256);
        if (i > 0) try expect(std.mem.lessThan(u8, game_titles.entries[i - 1].serial, entry.serial));
    }
}

test "a PGXP preset overrides only the settings its game lists" {
    // Spyro the Dragon (USA): CPU mode forced on, culling correction off.
    const spyro = pgxp_presets.lookup("scus-94228") orelse return error.MissingEntry;
    try expectEqual(@as(?bool, true), spyro.cpu);
    try expectEqual(@as(?bool, false), spyro.culling);
    try expectEqual(@as(?bool, null), spyro.enabled);
    try expectEqual(@as(?f32, null), spyro.tolerance);

    const tekken3 = pgxp_presets.lookup("SLUS-00402") orelse return error.MissingEntry;
    try expectEqual(@as(?f32, 3), tekken3.tolerance);

    // Silent Hill (USA) has no PGXP entry.
    try expect(pgxp_presets.lookup("SLUS-00707") == null);
    try expect(pgxp_presets.lookup("") == null);
}

test "the PGXP preset table is sorted, unique and serial-keyed" {
    for (pgxp_presets.entries, 0..) |entry, i| {
        // A HASH- key is DuckStation's executable hash, which no disc serial matches.
        try expect(!std.mem.startsWith(u8, entry.serial, "HASH-"));
        if (i > 0) try expect(std.mem.lessThan(u8, pgxp_presets.entries[i - 1].serial, entry.serial));
    }
}

test "a serial the VRAM readback table lists needs dual in any case" {
    // Pinned by name, so a regeneration that drops it fails here.
    try expect(vram_readbacks.needsDual("SCPS-45116"));
    try expect(vram_readbacks.needsDual("scps-45116"));
    try expectEqualStrings("SCPS-45116", vram_readbacks.entries[0]);

    // Silent Hill (USA) is not listed.
    try expect(!vram_readbacks.needsDual("SLUS-00707"));
    try expect(!vram_readbacks.needsDual(""));
}

test "the VRAM readback table is sorted, unique and serial-keyed" {
    for (vram_readbacks.entries, 0..) |serial, i| {
        try expect(!std.mem.startsWith(u8, serial, "HASH-"));
        if (i > 0) try expect(std.mem.lessThan(u8, vram_readbacks.entries[i - 1], serial));
    }
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
