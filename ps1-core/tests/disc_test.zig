const std = @import("std");
const expectEqual = std.testing.expectEqual;
const ps1_core = @import("ps1_core");
const disc = ps1_core.disc;

test "bare init builds one MODE2 data track at lba 0" {
    var data = [_]u8{0} ** (2352 * 4); // 4 sectors
    const d = disc.Disc.init(&data);
    try expectEqual(@as(u8, 1), d.track_count);
    try expectEqual(@as(u8, 1), d.tracks[0].number);
    try expectEqual(disc.TrackType.data, d.tracks[0].type);
    try expectEqual(@as(i32, 0), d.tracks[0].start_lba);
    try expectEqual(@as(?i32, null), d.tracks[0].pregap_lba);
}

test "initFromCue single data track" {
    var data = [_]u8{0} ** (2352 * 8);
    const cue =
        "REM FILESIZE 18816\n" ++ // 8 sectors * 2352
        "FILE \"Silent Hill (USA).bin\" BINARY\n" ++
        "  TRACK 01 MODE2/2352\n" ++
        "    INDEX 01 00:00:00\n";
    const d = disc.Disc.initFromCue(cue, &data);
    try expectEqual(@as(u8, 1), d.track_count);
    try expectEqual(@as(u8, 1), d.tracks[0].number);
    try expectEqual(disc.TrackType.data, d.tracks[0].type);
    try expectEqual(@as(i32, 0), d.tracks[0].start_lba);
    try expectEqual(@as(?i32, null), d.tracks[0].pregap_lba);
}

test "initFromCue two files, data + audio with pregap" {
    var data = [_]u8{0} ** (2352 * 150);
    const cue =
        "REM FILESIZE 235200\n" ++ // 100 sectors
        "FILE \"SOTN (Track 1).bin\" BINARY\n" ++
        "  TRACK 01 MODE2/2352\n" ++
        "    INDEX 01 00:00:00\n" ++
        "REM FILESIZE 117600\n" ++ // 50 sectors
        "FILE \"SOTN (Track 2).bin\" BINARY\n" ++
        "  TRACK 02 AUDIO\n" ++
        "    INDEX 00 00:00:00\n" ++
        "    INDEX 01 00:02:00\n";
    const d = disc.Disc.initFromCue(cue, &data);

    try expectEqual(@as(u8, 2), d.track_count);

    // Track 1: data, starts at LBA 0
    try expectEqual(disc.TrackType.data, d.tracks[0].type);
    try expectEqual(@as(i32, 0), d.tracks[0].start_lba);

    // Track 2: audio, file 2 begins at LBA 100.
    // pregap (INDEX 00) at 100; INDEX 01 at 100 + 150 frames (00:02:00).
    try expectEqual(disc.TrackType.audio, d.tracks[1].type);
    try expectEqual(@as(?i32, 100), d.tracks[1].pregap_lba);
    try expectEqual(@as(i32, 250), d.tracks[1].start_lba);

    // firstTrack/lastTrack reflect the TOC
    try expectEqual(@as(u8, 1), d.firstTrack());
    try expectEqual(@as(u8, 2), d.lastTrack());
}

test "getSubchannelQ reports index 00 inside pregap, 01 after" {
    var data = [_]u8{0} ** (2352 * 150);
    const cue =
        "REM FILESIZE 235200\n" ++
        "FILE \"t1.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n" ++
        "REM FILESIZE 117600\n" ++
        "FILE \"t2.bin\" BINARY\n  TRACK 02 AUDIO\n    INDEX 00 00:00:00\n    INDEX 01 00:02:00\n";
    const d = disc.Disc.initFromCue(cue, &data);

    const q_pregap = d.getSubchannelQ(120); // within [100,250)
    try expectEqual(@as(u8, disc.binaryToBcd(2)), q_pregap.track);
    try expectEqual(@as(u8, 0x00), q_pregap.index);

    const q_track = d.getSubchannelQ(260); // past INDEX 01
    try expectEqual(@as(u8, disc.binaryToBcd(2)), q_track.track);
    try expectEqual(@as(u8, 0x01), q_track.index);
}

/// The first two records of Final Fantasy IX (France) disc 1's `.sbi`.
///
/// LibCrypt hides its key in the subchannel Q of a handful of sectors, where
/// the drive is made to report positions that disagree with the sector's real
/// address: here 03:08:05 reports relative minute 07 and absolute minute 23,
/// both of which are truly 03. That data lives nowhere in a 2352-byte image, so
/// a Q synthesized from the TOC is always clean and always fails the check.
const ff9_sbi =
    "SBI\x00" ++
    "\x03\x08\x05\x01\x41\x01\x01\x07\x06\x05\x00\x23\x08\x05" ++
    "\x03\x08\x10\x01\x41\x01\x01\x03\x06\x11\x00\x03\x08\x90";

fn lbaOf(m: u8, s: u8, f: u8) i32 {
    return (disc.MSF{ .m = m, .s = s, .f = f }).toLba();
}

test "isLibCryptSector matches every sector the SBI names" {
    var data = [_]u8{0} ** (2352 * 4);
    var d = disc.Disc.init(&data);
    d.setSbi(ff9_sbi);

    try std.testing.expect(d.isLibCryptSector(lbaOf(0x03, 0x08, 0x05)));
    try std.testing.expect(d.isLibCryptSector(lbaOf(0x03, 0x08, 0x10))); // second record
}

test "isLibCryptSector leaves ordinary sectors alone" {
    var data = [_]u8{0} ** (2352 * 4);
    var d = disc.Disc.init(&data);
    d.setSbi(ff9_sbi);

    try std.testing.expect(!d.isLibCryptSector(lbaOf(0x03, 0x08, 0x06)));
    try std.testing.expect(!d.isLibCryptSector(0));
}

test "setSbi ignores a file without the SBI magic" {
    var data = [_]u8{0} ** (2352 * 4);
    var d = disc.Disc.init(&data);
    d.setSbi("NOTSBI\x00\x00" ++ "\x03\x08\x05\x01\x41\x01\x01\x07\x06\x05\x00\x23\x08\x05");

    try std.testing.expect(!d.isLibCryptSector(lbaOf(0x03, 0x08, 0x05)));
}

test "countCueFiles counts FILE directives" {
    const single = "FILE \"a.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n";
    const multi = "FILE \"a.bin\" BINARY\n  TRACK 01 MODE2/2352\nFILE \"b.bin\" BINARY\n  TRACK 02 AUDIO\n";
    try expectEqual(@as(usize, 1), disc.countCueFiles(single));
    try expectEqual(@as(usize, 2), disc.countCueFiles(multi));
    try expectEqual(@as(usize, 0), disc.countCueFiles("no directives here\n"));
}
