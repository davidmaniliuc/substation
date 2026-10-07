const std = @import("std");
const ps1 = @import("ps1_core");
const chd = ps1.chd;
const BitReader = chd.bitstream.BitReader;

test "the bit reader reads MSB-first across byte boundaries" {
    var br = BitReader.init(&.{ 0b1011_0011, 0b0101_1100, 0xFF });
    try std.testing.expectEqual(@as(u32, 0b101), br.read(3));
    try std.testing.expectEqual(@as(u32, 0b10011_010), br.read(8));
    try std.testing.expectEqual(@as(u32, 0b11100), br.peek(5));
    try std.testing.expectEqual(@as(u32, 0b11100), br.read(5));
    try std.testing.expectEqual(@as(u32, 0xFF), br.read(8));
    try std.testing.expect(!br.overflow);
}

test "the bit reader sign-extends, including a full 32-bit field" {
    var br = BitReader.init(&.{ 0b1110_0000, 0xFF, 0xFF, 0xFF, 0xFE });
    try std.testing.expectEqual(@as(i32, -1), br.readSigned(3));
    try std.testing.expectEqual(@as(i32, 0), br.readSigned(0));
    var full = BitReader.init(&.{ 0xFF, 0xFF, 0xFF, 0xFE });
    try std.testing.expectEqual(@as(i32, -2), full.readSigned(32));
}

test "a unary code counts zeros up to the next one, across a long run" {
    // 70 zero bits then a one: longer than the reader's 57-bit window.
    var bytes: [10]u8 = @splat(0);
    bytes[8] = 0b0000_0010; // bit 70 is the one
    var br = BitReader.init(&bytes);
    try std.testing.expectEqual(@as(u32, 70), br.readUnary());
    try std.testing.expectEqual(@as(usize, 71), br.pos);
}

test "reading past the end yields zeros and flags overflow" {
    var br = BitReader.init(&.{0xFF});
    try std.testing.expectEqual(@as(u32, 0xFF0), br.read(12));
    try std.testing.expect(br.overflow);
}

test "alignToByte skips to the next byte boundary" {
    var br = BitReader.init(&.{ 0xFF, 0xAB });
    _ = br.read(3);
    br.alignToByte();
    try std.testing.expectEqual(@as(usize, 1), br.bytePos());
    try std.testing.expectEqual(@as(u32, 0xAB), br.read(8));
}

const flac = chd.flac;

/// The frames of a FLAC file: past "fLaC" and every metadata block.
fn flacFrames(file: []const u8) []const u8 {
    var pos: usize = 4;
    while (true) {
        const last = file[pos] & 0x80 != 0;
        const len = std.mem.readInt(u24, file[pos + 1 ..][0..3], .big);
        pos += 4 + len;
        if (last) return file[pos..];
    }
}

/// Decodes `flac_file` and requires the little-endian `pcm` back, sample for sample.
fn expectDecodes(flac_file: []const u8, pcm: []const u8, stats: *flac.Stats) !void {
    const out = try std.testing.allocator.alloc(u8, pcm.len);
    defer std.testing.allocator.free(out);
    const frames = flacFrames(flac_file);
    try std.testing.expectEqual(frames.len, try flac.decodeFrames(frames, out, stats));
    for (0..pcm.len / 2) |i| {
        try std.testing.expectEqual(pcm[2 * i], out[2 * i + 1]);
        try std.testing.expectEqual(pcm[2 * i + 1], out[2 * i]);
    }
}

test "FLAC silence decodes through constant subframes" {
    var s: flac.Stats = .{};
    try expectDecodes(@embedFile("chd/silence.flac"), @embedFile("chd/silence.pcm"), &s);
    try std.testing.expect(s.constant > 0);
}

test "FLAC ramp decodes through fixed predictors" {
    var s: flac.Stats = .{};
    try expectDecodes(@embedFile("chd/ramp.flac"), @embedFile("chd/ramp.pcm"), &s);
    try std.testing.expect(s.fixed > 0);
}

test "FLAC music decodes through LPC subframes" {
    var s: flac.Stats = .{};
    try expectDecodes(@embedFile("chd/music.flac"), @embedFile("chd/music.pcm"), &s);
    try std.testing.expect(s.lpc > 0);
}

test "FLAC noise decodes through verbatim subframes" {
    var s: flac.Stats = .{};
    try expectDecodes(@embedFile("chd/noise.flac"), @embedFile("chd/noise.pcm"), &s);
    try std.testing.expect(s.verbatim > 0);
}

test "FLAC correlated stereo decodes through a decorrelation mode" {
    var s: flac.Stats = .{};
    try expectDecodes(@embedFile("chd/stereo.flac"), @embedFile("chd/stereo.pcm"), &s);
    try std.testing.expect(s.left_side + s.right_side + s.mid_side > 0);
}

test "FLAC restores left and right from every stereo mode" {
    // left = 100, right = 40 in every mode's own encoding.
    var a = [_]i32{100};
    var b = [_]i32{60}; // side = left - right
    flac.restoreStereo(.left_side, &a, &b);
    try std.testing.expectEqual([2]i32{ 100, 40 }, [2]i32{ a[0], b[0] });

    a = .{60}; // side
    b = .{40}; // right
    flac.restoreStereo(.right_side, &a, &b);
    try std.testing.expectEqual([2]i32{ 100, 40 }, [2]i32{ a[0], b[0] });

    a = .{70}; // mid = (left + right) >> 1
    b = .{60}; // side
    flac.restoreStereo(.mid_side, &a, &b);
    try std.testing.expectEqual([2]i32{ 100, 40 }, [2]i32{ a[0], b[0] });

    a = .{100};
    b = .{40};
    flac.restoreStereo(.independent, &a, &b);
    try std.testing.expectEqual([2]i32{ 100, 40 }, [2]i32{ a[0], b[0] });
}

test "FLAC reads an escaped Rice partition as raw samples" {
    // method 0, partition order 0, parameter 15 (escape), 5-bit width = 4,
    // then four 4-bit samples 3, -2, 0, 7.
    var br = chd.bitstream.BitReader.init(&.{ 0x03, 0xC8, 0x7C, 0x0E });
    var residual: [4]i32 = undefined;
    var s: flac.Stats = .{};
    try flac.decodeResidual(&br, 4, 0, &residual, &s);
    try std.testing.expectEqual([4]i32{ 3, -2, 0, 7 }, residual);
    try std.testing.expectEqual(@as(u32, 1), s.escaped_partitions);
}

test "a corrupted FLAC frame is refused, never decoded or panicked on" {
    const frames = flacFrames(@embedFile("chd/music.flac"));
    const bad = try std.testing.allocator.dupe(u8, frames);
    defer std.testing.allocator.free(bad);
    var out: [4704 * 4]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(7);
    for (0..64) |_| {
        @memcpy(bad, frames);
        bad[rng.random().intRangeLessThan(usize, 16, bad.len)] ^= 0x5A;
        _ = flac.decodeFrames(bad, &out, null) catch continue;
        return error.CorruptionAccepted;
    }
}
