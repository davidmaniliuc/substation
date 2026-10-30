const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const ps1_core = @import("ps1_core");
const ccd = ps1_core.ccd;
const disc = ps1_core.disc;
const Disc = disc.Disc;
const MSF = disc.MSF;

const gpa = std.testing.allocator;
const sector_bytes = 2352;
const bin = @embedFile("chd/disc.bin");
const cue = @embedFile("chd/disc.cue");

const header =
    \\[CloneCD]
    \\Version=3
    \\[Disc]
    \\TocEntries=4
    \\Sessions=1
    \\
;

/// The sheet of `chd/disc.cue`: track 1 data at 0, track 2 audio from 40
/// (pregap 30), track 3 audio from 93 (pregap 91), lead-out at 113.
const sheet = header ++
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

test "a CloneCD sheet reads as the cue's disc" {
    try expect(ccd.isCcd(sheet));
    try expect(!ccd.isCcd(cue));
    const want = Disc.initFromCue(cue, bin);
    const got = try ccd.parse(sheet, bin);
    try expectEqual(want.track_count, got.track_count);
    for (want.tracks[0..want.track_count], got.tracks[0..got.track_count]) |w, g| {
        try expectEqual(w.number, g.number);
        try expectEqual(w.type, g.type);
        try expectEqual(w.start_lba, g.start_lba);
        try expectEqual(w.pregap_lba, g.pregap_lba);
    }
    var a: [sector_bytes]u8 = undefined;
    try expect(got.readSector2352(50, &a));
    try expectEqualSlices(u8, bin[50 * sector_bytes ..][0..sector_bytes], &a);
}

test "a stored track-1 pregap is skipped" {
    const text = header ++
        \\[Entry 0]
        \\Point=0x01
        \\Control=0x04
        \\PLBA=-150
        \\[Entry 1]
        \\Point=0x02
        \\Control=0x00
        \\PLBA=190
        \\[Entry 2]
        \\Point=0x03
        \\Control=0x00
        \\PLBA=243
        \\[Entry 3]
        \\Point=0xa2
        \\Control=0x00
        \\PLBA=263
        \\[TRACK 1]
        \\MODE=2
        \\INDEX 0=0
        \\INDEX 1=150
        \\[TRACK 2]
        \\MODE=0
        \\INDEX 1=190
        \\[TRACK 3]
        \\MODE=0
        \\INDEX 1=243
        \\
    ;
    try expectEqual(@as(usize, 150), ccd.pregapSkip(text));
    try expectEqual(@as(usize, 0), ccd.pregapSkip(sheet));
    const img = try gpa.alloc(u8, 150 * sector_bytes + bin.len);
    defer gpa.free(img);
    @memset(img[0 .. 150 * sector_bytes], 0);
    @memcpy(img[150 * sector_bytes ..], bin);
    const got = try ccd.parse(text, img);
    try expectEqual(@as(i32, 0), got.tracks[0].start_lba);
    try expectEqual(@as(?i32, null), got.tracks[0].pregap_lba);
    try expectEqual(@as(i32, 40), got.tracks[1].start_lba);
    try expectEqual(@as(i32, 93), got.tracks[2].start_lba);
    try expectEqual(@as(i32, 113), got.sectorCount());
    var a: [sector_bytes]u8 = undefined;
    try expect(got.readSector2352(0, &a));
    try expectEqualSlices(u8, bin[0..sector_bytes], &a);
}

test "a missing lead-out comes from the image size" {
    const text = header ++
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
        \\[TRACK 1]
        \\MODE=2
        \\[TRACK 2]
        \\MODE=0
        \\[TRACK 3]
        \\MODE=0
        \\
    ;
    const got = try ccd.parse(text, bin);
    try expectEqual(@as(i32, 113), got.sectorCount());
    try expectEqual(@as(i32, 93), got.tracks[2].start_lba);
}

test "refusals" {
    try expectError(error.BadCcd, ccd.parse("[Disc]\nTocEntries=4\n", bin));
    const two = "[CloneCD]\n[Disc]\nTocEntries=2\n[Entry 0]\nPoint=1\nPLBA=0\n[Entry 1]\nPoint=0xa2\nPLBA=113\n";
    try expectError(error.BadCcd, ccd.parse(two, bin));
    const gap = "[CloneCD]\n[Disc]\nTocEntries=3\n[Entry 0]\nPoint=1\nPLBA=0\n[Entry 1]\nPoint=3\nPLBA=93\n[Entry 2]\nPoint=0xa2\nPLBA=113\n";
    try expectError(error.BadCcd, ccd.parse(gap, bin));
    try expectError(error.BadCcd, ccd.parse(sheet, bin[0 .. 50 * sector_bytes]));
    const backwards = "[CloneCD]\n[Disc]\nTocEntries=3\n[Entry 0]\nPoint=1\nPLBA=50\n[Entry 1]\nPoint=2\nPLBA=40\n[Entry 2]\nPoint=0xa2\nPLBA=113\n";
    try expectError(error.BadCcd, ccd.parse(backwards, bin));
    const inverted = "[CloneCD]\n[Disc]\nTocEntries=3\n[Entry 0]\nPoint=1\nPLBA=0\n[Entry 1]\nPoint=0xa2\nPLBA=113\n[TRACK 1]\nINDEX 0=30\nINDEX 1=20\n";
    try expectError(error.BadCcd, ccd.parse(inverted, bin));
}

test "qCrc matches a known Q" {
    const q = [10]u8{ 0x41, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00 };
    try expectEqual(@as(u16, 0x2832), ccd.qCrc(&q));
    try expectEqual(@as(u16, 0xFFFF), ccd.qCrc(&@splat(0)));
}

test "subRecords keeps only sectors whose Q fails its CRC" {
    const count = 113;
    const sub = try gpa.alloc(u8, count * 96);
    defer gpa.free(sub);
    @memset(sub, 0);
    for (0..count) |i| {
        const m = MSF.fromLba(@intCast(i));
        const q = sub[i * 96 + 12 ..][0..12];
        q[0..10].* = .{ 0x41, 0x01, 0x01, 0, 0, 0, m.m, m.s, m.f, 0 };
        const crc = ccd.qCrc(q[0..10]);
        q[10] = @truncate(crc >> 8);
        q[11] = @truncate(crc);
    }
    sub[7 * 96 + 12 + 11] ^= 0xFF;
    sub[60 * 96 + 12 + 10] ^= 0x01;

    const out = try ccd.subRecords(gpa, sub, 0);
    defer gpa.free(out);
    try expectEqual(@as(usize, 4 + 2 * 14), out.len);
    try expectEqualSlices(u8, "SBI\x00", out[0..4]);
    const a = MSF.fromLba(7);
    const b = MSF.fromLba(60);
    try expectEqualSlices(u8, &.{ a.m, a.s, a.f, 1 }, out[4..8]);
    try expectEqualSlices(u8, sub[7 * 96 + 12 ..][0..10], out[8..18]);
    try expectEqualSlices(u8, &.{ b.m, b.s, b.f, 1 }, out[18..22]);

    var d = Disc.init(bin);
    d.setSbi(out);
    try expect(d.isLibCryptSector(60));
    try expect(!d.isLibCryptSector(61));

    // A skip shifts the address and ignores the sectors before it.
    const shifted = try ccd.subRecords(gpa, sub, 10);
    defer gpa.free(shifted);
    try expectEqual(@as(usize, 4 + 14), shifted.len);
    const c = MSF.fromLba(50);
    try expectEqualSlices(u8, &.{ c.m, c.s, c.f, 1 }, shifted[4..8]);

    try expectError(error.BadCcd, ccd.subRecords(gpa, sub[0..95], 0));
}

test "out-of-range numbers are refused" {
    const tail = "[Disc]\nTocEntries=3\n[Entry 0]\nPoint=1\nPLBA=0\n[Entry 1]\nPoint=2\nPLBA=40\n[Entry 2]\nPoint=0xa2\nPLBA=113\n";
    try expectError(error.BadCcd, ccd.parse("[CloneCD]\n[Entry -1]\n" ++ tail ++ "[TRACK -2]\nINDEX 1=5\n[Entry -3]\n", bin[0..0]));
    const huge = "[CloneCD]\n[Disc]\nTocEntries=3\n[Entry 0]\nPoint=1\nPLBA=0\n[Entry 1]\nPoint=2\nPLBA=99999999999\n[Entry 2]\nPoint=0xa2\nPLBA=113\n";
    try expectError(error.BadCcd, ccd.parse(huge, bin));
    const huge_index = "[CloneCD]\n[Disc]\nTocEntries=3\n[Entry 0]\nPoint=1\nPLBA=0\n[Entry 1]\nPoint=2\nPLBA=40\n[Entry 2]\nPoint=0xa2\nPLBA=113\n[TRACK 2]\nINDEX 0=30\nINDEX 1=99999999999\n";
    try expectError(error.BadCcd, ccd.parse(huge_index, bin));
}

test "a last track at or past the lead-out is refused" {
    const text = "[CloneCD]\n[Disc]\nTocEntries=3\n[Entry 0]\nPoint=1\nPLBA=0\n[Entry 1]\nPoint=2\nPLBA=113\n[Entry 2]\nPoint=0xa2\nPLBA=113\n";
    try expectError(error.BadCcd, ccd.parse(text, bin));
}

test "an all-zero Q is not a record" {
    var sub: [2 * 96]u8 = @splat(0);
    const q = sub[96 + 12 ..][0..12];
    q[0..10].* = .{ 0x41, 0x01, 0x01, 0, 0, 0, 0, 0, 2, 0 };
    q[10] = 0xDE; // wrong CRC
    q[11] = 0xAD;
    const out = try ccd.subRecords(gpa, &sub, 0);
    defer gpa.free(out);
    try expectEqual(@as(usize, 4 + 14), out.len);
    const m = MSF.fromLba(1);
    try expectEqualSlices(u8, &.{ m.m, m.s, m.f, 1 }, out[4..8]);
}
