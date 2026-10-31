const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const ps1_core = @import("ps1_core");
const mds = ps1_core.mds;
const disc = ps1_core.disc;
const Disc = disc.Disc;
const MSF = disc.MSF;
const fixtures = @import("image_fixtures.zig");

const gpa = std.testing.allocator;
const sector_bytes = 2352;
const bin = fixtures.disc_bin;
const cue = fixtures.disc_cue;

const header_bytes = 0x58;
const entries_at = header_bytes + 24;
const entry_bytes = 80;

fn trackEntry(n: usize) usize {
    return entries_at + (3 + n) * entry_bytes;
}

fn extraOf(sheet: []const u8, n: usize) usize {
    return std.mem.readInt(u32, sheet[trackEntry(n) + 12 ..][0..4], .little);
}

test "an Alcohol image reads back as its cue's disc" {
    const want = Disc.initFromCue(cue, bin);
    for ([_]bool{ false, true }) |with_sub| {
        const img = try fixtures.encodeMds(gpa, want, bin, with_sub);
        defer gpa.free(img.mds);
        defer gpa.free(img.mdf);
        try expect(mds.isMds(img.mds));
        try expect(!mds.isMds(cue));
        try expectEqual(@as(u16, if (with_sub) 2448 else 2352), try mds.stride(img.mds));

        const got = try mds.parse(img.mds, img.mdf);
        try expectEqual(want.track_count, got.track_count);
        for (want.tracks[0..want.track_count], got.tracks[0..got.track_count]) |w, g| {
            try expectEqual(w.number, g.number);
            try expectEqual(w.type, g.type);
            try expectEqual(w.start_lba, g.start_lba);
            try expectEqual(w.pregap_lba, g.pregap_lba);
        }
        try expectEqual(want.sectorCount(), got.sectorCount());
        var a: [sector_bytes]u8 = undefined;
        for (0..@intCast(want.sectorCount())) |lba| {
            try expect(got.readSector2352(@intCast(lba), &a));
            try expectEqualSlices(u8, bin[lba * sector_bytes ..][0..sector_bytes], &a);
        }
    }
}

test "subchannel LibCrypt records equal the sbi's" {
    var want = Disc.initFromCue(cue, bin);
    var sbi: std.ArrayList(u8) = .empty;
    defer sbi.deinit(gpa);
    try sbi.appendSlice(gpa, disc.sbi_magic);
    for ([_]i32{ 7, 60 }) |lba| {
        const m = MSF.fromLba(lba);
        try sbi.appendSlice(gpa, &.{ m.m, m.s, m.f, 1 });
        try sbi.appendNTimes(gpa, 0, 10);
    }
    want.setSbi(sbi.items);

    const img = try fixtures.encodeMds(gpa, want, bin, true);
    defer gpa.free(img.mds);
    defer gpa.free(img.mdf);
    const out = try mds.subRecords(gpa, img.mdf);
    defer gpa.free(out);
    try expectEqual(@as(usize, 4 + 2 * 14), out.len);
    try expectEqualSlices(u8, "SBI\x00", out[0..4]);
    const a = MSF.fromLba(7);
    const b = MSF.fromLba(60);
    try expectEqualSlices(u8, &.{ a.m, a.s, a.f, 1 }, out[4..8]);
    try expectEqualSlices(u8, &.{ b.m, b.s, b.f, 1 }, out[18..22]);

    var got = try mds.parse(img.mds, img.mdf);
    got.setSbi(out);
    try expect(got.isLibCryptSector(7));
    try expect(got.isLibCryptSector(60));
    try expect(!got.isLibCryptSector(8));

    // A dump with no subchannel has no records.
    const plain = try fixtures.encodeMds(gpa, want, bin, false);
    defer gpa.free(plain.mds);
    defer gpa.free(plain.mdf);
    const none = try mds.subRecords(gpa, img.mdf[0..0]);
    defer gpa.free(none);
    try expectEqualSlices(u8, "SBI\x00", none);
}

test "refusals" {
    const want = Disc.initFromCue(cue, bin);
    const img = try fixtures.encodeMds(gpa, want, bin, false);
    defer gpa.free(img.mds);
    defer gpa.free(img.mdf);
    _ = try mds.parse(img.mds, img.mdf);

    const m = try gpa.dupe(u8, img.mds);
    defer gpa.free(m);
    const restore = struct {
        fn go(dst: []u8, src: []const u8) void {
            @memcpy(dst, src);
        }
    }.go;

    m[0] = 'X';
    try expectError(error.BadMds, mds.parse(m, img.mdf));
    try expectError(error.BadMds, mds.stride(m));
    restore(m, img.mds);

    std.mem.writeInt(u16, m[header_bytes + 14 ..][0..2], 100, .little);
    try expectError(error.BadMds, mds.parse(m, img.mdf));
    std.mem.writeInt(u16, m[header_bytes + 14 ..][0..2], 0, .little);
    try expectError(error.BadMds, mds.parse(m, img.mdf));
    restore(m, img.mds);

    m[trackEntry(1) + 4] = 0x03;
    try expectError(error.BadMds, mds.parse(m, img.mdf));
    restore(m, img.mds);

    std.mem.writeInt(u32, m[extraOf(m, 1)..][0..4], 1000, .little);
    try expectError(error.BadMds, mds.parse(m, img.mdf));
    restore(m, img.mds);

    const off = trackEntry(1) + 40;
    std.mem.writeInt(u32, m[off..][0..4], std.mem.readInt(u32, m[off..][0..4], .little) + sector_bytes, .little);
    try expectError(error.BadMds, mds.parse(m, img.mdf));
    restore(m, img.mds);

    m[trackEntry(2) + 1] = 1;
    try expectError(error.BadMds, mds.stride(m));
    try expectError(error.BadMds, mds.parse(m, img.mdf));
    restore(m, img.mds);

    try expectError(error.BadMds, mds.parse(m, img.mdf[0 .. img.mdf.len - sector_bytes]));
    try expectError(error.BadMds, mds.parse(m[0..0x53], img.mdf));
}
