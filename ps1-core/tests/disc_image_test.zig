const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const ps1_core = @import("ps1_core");
const disc_image = ps1_core.disc_image;
const fixtures = @import("image_fixtures.zig");

const gpa = std.testing.allocator;
const sector_bytes = 2352;
const bin = fixtures.disc_bin;
const cue = fixtures.disc_cue;
const chd_image = @embedFile("chd/disc-default.chd");

fn expectOpens(opened: disc_image.Opened, tracks: u8) !void {
    try expectEqual(tracks, opened.disc.track_count);
    var a: [sector_bytes]u8 = undefined;
    try expect(opened.disc.readSector2352(50, &a));
    try expectEqualSlices(u8, bin[50 * sector_bytes ..][0..sector_bytes], &a);
}

test "open sniffs each format" {
    {
        const o = try disc_image.open(gpa, chd_image, "", "");
        defer o.decoder.close();
        try expect(o.decoder == .chd);
        try expect(o.disc.source == .chd);
        try expectOpens(o, 3);
    }
    {
        const encoded = try fixtures.encodeEcm(gpa, bin);
        defer gpa.free(encoded);
        const o = try disc_image.open(gpa, encoded, "", "");
        defer o.decoder.close();
        try expect(o.decoder == .ecm);
        try expect(o.disc.source == .ecm);
        try expectOpens(o, 1);
    }
    {
        const o = try disc_image.open(gpa, bin, fixtures.ccd_sheet, "");
        try expect(o.decoder == .none);
        try expect(o.disc.source == .flat);
        try expectOpens(o, 3);
    }
    {
        const o = try disc_image.open(gpa, bin, cue, "");
        try expect(o.disc.source == .flat);
        try expectOpens(o, 3);
    }
    {
        const cooked: [3 * 2048]u8 = @splat(0);
        const o = try disc_image.open(gpa, &cooked, "", "");
        try expect(o.disc.source == .cooked);
        try expectEqual(@as(i32, 3), o.disc.sectorCount());
    }
}

test "an ECM named by a one-FILE cue takes the cue's tracks" {
    const encoded = try fixtures.encodeEcm(gpa, bin);
    defer gpa.free(encoded);
    const o = try disc_image.open(gpa, encoded, cue, "");
    defer o.decoder.close();
    try expect(o.disc.source == .ecm);
    try expectOpens(o, 3);
    try expectEqual(@as(i32, 40), o.disc.tracks[1].start_lba);
}

test "a .sub is accepted only beside a CloneCD sheet" {
    const sub = try fixtures.cloneSub(gpa, bin.len / sector_bytes, &.{ 7, 60 });
    defer gpa.free(sub);

    const o = try disc_image.open(gpa, bin, fixtures.ccd_sheet, sub);
    defer gpa.free(o.sbi);
    try expectEqual(@as(usize, 4 + 2 * 14), o.sbi.len);
    var d = o.disc;
    d.setSbi(o.sbi);
    try expect(d.isLibCryptSector(60));

    try expectError(error.BadSbi, disc_image.open(gpa, bin, cue, sub));
    try expectError(error.BadSbi, disc_image.open(gpa, chd_image, "", sub));
    // One that stops short of the image cannot vouch for the sectors past it.
    try expectError(error.BadSbi, disc_image.open(gpa, bin, fixtures.ccd_sheet, sub[0 .. sub.len - 96]));
}

test "an .sbi sidecar is copied whatever the image" {
    const sbi = "SBI\x00" ++ "\x03\x08\x05\x01\x41\x01\x01\x07\x06\x05\x00\x23\x08\x05";
    const o = try disc_image.open(gpa, chd_image, "", sbi);
    defer o.decoder.close();
    defer gpa.free(o.sbi);
    try expectEqualSlices(u8, sbi, o.sbi);
    try expect(o.sbi.ptr != sbi.ptr);
}

test "refusals map to their errors" {
    try expectError(error.BadCue, disc_image.open(gpa, bin[0..2047], "", ""));
    try expectError(error.BadChd, disc_image.open(gpa, chd_image, cue, ""));

    const encoded = try fixtures.encodeEcm(gpa, bin);
    defer gpa.free(encoded);
    const two_files = "REM FILESIZE 2352\nFILE \"a.ecm\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n" ++
        "FILE \"b.bin\" BINARY\n  TRACK 02 AUDIO\n    INDEX 01 00:00:00\n";
    try expectError(error.BadCue, disc_image.open(gpa, encoded, two_files, ""));
    const cooked_ecm = "FILE \"a.bin.ecm\" BINARY\n  TRACK 01 MODE1/2048\n    INDEX 01 00:00:00\n";
    try expectError(error.BadCue, disc_image.open(gpa, encoded, cooked_ecm, ""));
    try expectError(error.BadEcm, disc_image.open(gpa, "ECM\x00" ++ @as([2048]u8, @splat(0xFF)), "", ""));

    try expectError(error.BadCcd, disc_image.open(gpa, bin, "[CloneCD]\nVersion=3\n", ""));

    const cooked_two = "FILE \"a.iso\" BINARY\n  TRACK 01 MODE1/2048\n    INDEX 01 00:00:00\n" ++
        "  TRACK 02 AUDIO\n    INDEX 01 00:00:10\n";
    try expectError(error.BadCue, disc_image.open(gpa, bin, cooked_two, ""));
    try expectError(error.MultiFileCue, disc_image.open(gpa, bin, "FILE \"a\" BINARY\n  TRACK 01 MODE2/2352\nFILE \"b\" BINARY\n  TRACK 02 AUDIO\n", ""));
    try expectError(error.BadCue, disc_image.open(gpa, bin, "FILE \"a\" BINARY\n", ""));
}

test "identify reads a lone image and refuses one it cannot open" {
    var raw: [sector_bytes * fixtures.iso_sectors]u8 = undefined;
    fixtures.writeIso(&raw, .{});
    const cooked = try fixtures.cook(gpa, &raw);
    defer gpa.free(cooked);
    const id = try disc_image.identify(gpa, cooked);
    try std.testing.expectEqualStrings("SLUS-00530", id.serial.slice());
    try expectError(error.BadEcm, disc_image.identify(gpa, "ECM\x00" ++ @as([2048]u8, @splat(0xFF))));
}

const image_write = @import("image_write");

fn expectSameTracks(want: ps1_core.disc.Disc, got: ps1_core.disc.Disc) !void {
    try expectEqual(want.track_count, got.track_count);
    for (want.tracks[0..want.track_count], got.tracks[0..got.track_count]) |w, g| try expectEqual(w, g);
}

test "a written CloneCD set opens as the cue's disc, LibCrypt sectors and all" {
    var want = ps1_core.disc.Disc.initFromCue(cue, bin);
    // The sector addresses are all the sidecar is read for.
    const sbi = "SBI\x00" ++ "\x00\x02\x07\x01" ++ @as([10]u8, @splat(0)) ++ "\x00\x02\x60\x01" ++ @as([10]u8, @splat(0));
    want.setSbi(sbi);

    const sheet = try image_write.ccdSheet(gpa, want);
    defer gpa.free(sheet);
    const sub = try image_write.subchannel(gpa, want);
    defer gpa.free(sub);
    const o = try disc_image.open(gpa, bin, sheet, sub);
    defer gpa.free(o.sbi);
    try expectSameTracks(want, o.disc);
    try expectEqual(want.sectorCount(), o.disc.sectorCount());

    var got = o.disc;
    got.setSbi(o.sbi);
    try expectEqual(@as(usize, 2 * 14), got.sbi.len);
    try expect(got.isLibCryptSector(7) and got.isLibCryptSector(60) and !got.isLibCryptSector(8));
}

test "a written ECM opens through its one-FILE cue as the cue's disc" {
    const want = ps1_core.disc.Disc.initFromCue(cue, bin);
    const encoded = try image_write.encodeEcm(gpa, bin);
    defer gpa.free(encoded);
    const sheet = try image_write.singleFileCue(gpa, want, "disc.ecm");
    defer gpa.free(sheet);
    const o = try disc_image.open(gpa, encoded, sheet, "");
    defer o.decoder.close();
    try expectSameTracks(want, o.disc);
    var a: [sector_bytes]u8 = undefined;
    var lba: i32 = 0;
    while (lba < want.sectorCount()) : (lba += 1) {
        try expect(o.disc.readSector2352(lba, &a));
        try expectEqualSlices(u8, bin[@as(usize, @intCast(lba)) * sector_bytes ..][0..sector_bytes], &a);
    }
}

test "an ISO is written only for a single data track" {
    // A refusal writes nothing, so the stem is never touched.
    const three = ps1_core.disc.Disc.initFromCue(cue, bin);
    try expectEqual(image_write.Outcome.refused, try image_write.write(gpa, std.testing.io, three, .iso, "unwritten"));
}
