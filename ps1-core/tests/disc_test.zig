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
