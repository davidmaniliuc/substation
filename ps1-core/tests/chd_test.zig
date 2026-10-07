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

const cd = chd.cd;
const sector_bytes = ps1.constants.sector_bytes;
const disc_bin = @embedFile("chd/disc.bin");
const disc_cue = @embedFile("chd/disc.cue");

fn binSector(lba: usize) [sector_bytes]u8 {
    return disc_bin[lba * sector_bytes ..][0..sector_bytes].*;
}

/// Zeroes what chdman strips from a sector whose ECC verified: the sync
/// pattern and the P/Q parity.
fn stripped(lba: usize) [sector_bytes]u8 {
    var s = binSector(lba);
    @memset(s[0..12], 0);
    @memset(s[0x81C..], 0);
    return s;
}

test "ECC regeneration restores a Mode 2 Form 1 sector byte for byte" {
    var s = stripped(0);
    cd.restoreSector(&s);
    try std.testing.expectEqualSlices(u8, &binSector(0), &s);
}

test "ECC regeneration restores a Mode 1 sector byte for byte" {
    var s = stripped(25);
    cd.restoreSector(&s);
    try std.testing.expectEqualSlices(u8, &binSector(25), &s);
}

/// A raw deflate stream of one stored block: no compressor needed.
fn storedDeflate(list: *std.ArrayList(u8), bytes: []const u8) !void {
    const a = std.testing.allocator;
    try list.append(a, 0x01); // BFINAL, BTYPE=00
    var len: [2]u8 = undefined;
    std.mem.writeInt(u16, &len, @intCast(bytes.len), .little);
    try list.appendSlice(a, &len);
    std.mem.writeInt(u16, &len, ~@as(u16, @intCast(bytes.len)), .little);
    try list.appendSlice(a, &len);
    try list.appendSlice(a, bytes);
}

test "a cdzl hunk splits sectors from subcode and regenerates flagged ECC" {
    const a = std.testing.allocator;
    var sectors: [2 * sector_bytes]u8 = undefined;
    sectors[0..sector_bytes].* = stripped(0); // flagged: regenerated
    sectors[sector_bytes..].* = binSector(60); // audio: left alone
    var subcode: [2 * cd.subcode_bytes]u8 = undefined;
    for (&subcode, 0..) |*b, i| b.* = @truncate(i);

    var base = std.ArrayList(u8).empty;
    defer base.deinit(a);
    try storedDeflate(&base, &sectors);
    var src = std.ArrayList(u8).empty;
    defer src.deinit(a);
    try src.append(a, 0b01); // ECC bitmap: frame 0 only
    var len: [2]u8 = undefined;
    std.mem.writeInt(u16, &len, @intCast(base.items.len), .big);
    try src.appendSlice(a, &len);
    try src.appendSlice(a, base.items);
    try storedDeflate(&src, &subcode);

    var scratch = try cd.Scratch.init(a, 2, false);
    defer scratch.deinit(a);
    var hunk: [2 * cd.frame_bytes]u8 = undefined;
    try cd.decode(&scratch, a, .cdzl, src.items, &hunk);

    try std.testing.expectEqualSlices(u8, &binSector(0), hunk[0..sector_bytes]);
    try std.testing.expectEqualSlices(u8, subcode[0..96], hunk[sector_bytes..][0..96]);
    try std.testing.expectEqualSlices(u8, &binSector(60), hunk[cd.frame_bytes..][0..sector_bytes]);
    try std.testing.expectEqualSlices(u8, subcode[96..], hunk[cd.frame_bytes + sector_bytes ..][0..96]);
}

test "a cd hunk whose length field overruns its data is refused" {
    const a = std.testing.allocator;
    var scratch = try cd.Scratch.init(a, 2, false);
    defer scratch.deinit(a);
    var hunk: [2 * cd.frame_bytes]u8 = undefined;
    try std.testing.expectError(error.BadHunk, cd.decode(&scratch, a, .cdzl, &.{ 0, 0xFF, 0xFF, 1 }, &hunk));
}
const Fixture = struct { name: []const u8, bytes: []const u8 };
const fixtures = [_]Fixture{
    .{ .name = "cdzl", .bytes = @embedFile("chd/disc-cdzl.chd") },
    .{ .name = "cdlz", .bytes = @embedFile("chd/disc-cdlz.chd") },
    .{ .name = "cdzs", .bytes = @embedFile("chd/disc-cdzs.chd") },
    .{ .name = "cdfl", .bytes = @embedFile("chd/disc-cdfl.chd") },
    .{ .name = "default", .bytes = @embedFile("chd/disc-default.chd") },
};

fn mutated(bytes: []const u8, offset: usize, patch: []const u8) ![]u8 {
    const m = try std.testing.allocator.dupe(u8, bytes);
    @memcpy(m[offset..][0..patch.len], patch);
    return m;
}

test "a CHD header parses into its CD geometry" {
    const h = try chd.Header.parse(fixtures[0].bytes);
    try std.testing.expectEqual(@as(u32, 19584), h.hunk_bytes);
    try std.testing.expectEqual(@as(u32, cd.frame_bytes), h.unit_bytes);
    try std.testing.expectEqual(@as(?cd.Codec, .cdzl), h.codecs[0]);
    try std.testing.expectEqual(@as(u32, @intCast((h.logical_bytes + 19583) / 19584)), h.hunk_count);
}

test "every fixture's map decodes and passes its CRC" {
    for (fixtures) |f| {
        const h = try chd.Header.parse(f.bytes);
        const entries = try chd.map.decode(std.testing.allocator, f.bytes, h.map_offset, h.hunk_count, h.hunk_bytes);
        defer std.testing.allocator.free(entries);
        try std.testing.expectEqual(@as(usize, h.hunk_count), entries.len);
    }
}

test "the fixtures cover self-referenced and stored hunks" {
    var self_refs: usize = 0;
    var stored: usize = 0;
    for (fixtures) |f| {
        const h = try chd.Header.parse(f.bytes);
        const entries = try chd.map.decode(std.testing.allocator, f.bytes, h.map_offset, h.hunk_count, h.hunk_bytes);
        defer std.testing.allocator.free(entries);
        for (entries) |e| switch (e.kind) {
            .self => self_refs += 1,
            .none => stored += 1,
            else => {},
        };
    }
    try std.testing.expect(self_refs > 0);
    try std.testing.expect(stored > 0);
}

test "the header refuses what this reader does not support" {
    const base = fixtures[0].bytes;
    const cases = [_]struct { offset: usize, patch: []const u8, err: chd.Error }{
        .{ .offset = 12, .patch = &.{ 0, 0, 0, 4 }, .err = error.UnsupportedVersion },
        .{ .offset = 104, .patch = &.{1}, .err = error.ParentChd },
        .{ .offset = 16, .patch = "xxxx", .err = error.UnsupportedCodec },
        .{ .offset = 16, .patch = &@as([16]u8, @splat(0)), .err = error.UncompressedChd },
        .{ .offset = 60, .patch = &.{ 0, 0, 0x09, 0x30 }, .err = error.NotCdImage },
    };
    for (cases) |c| {
        const m = try mutated(base, c.offset, c.patch);
        defer std.testing.allocator.free(m);
        try std.testing.expectError(c.err, chd.Header.parse(m));
    }
    try std.testing.expectError(error.NotChd, chd.Header.parse("not a chd at all"));
    try std.testing.expect(!chd.isChd("MComprH"));
}

test "a map whose CRC does not match is refused" {
    const h = try chd.Header.parse(fixtures[0].bytes);
    const crc_at: usize = @intCast(h.map_offset + 10);
    const m = try mutated(fixtures[0].bytes, crc_at, &.{fixtures[0].bytes[crc_at] ^ 0xFF});
    defer std.testing.allocator.free(m);
    try std.testing.expectError(error.BadMap, chd.map.decode(std.testing.allocator, m, h.map_offset, h.hunk_count, h.hunk_bytes));
}

test "a truncated or garbled map is refused, never a panic" {
    const h = try chd.Header.parse(fixtures[0].bytes);
    const alloc = std.testing.allocator;
    const cuts = [_]usize{ 0, 8, @intCast(h.map_offset), @intCast(h.map_offset + 15), @intCast(h.map_offset + 20), @intCast(h.map_offset + 40) };
    for (cuts) |cut| {
        try std.testing.expectError(error.BadMap, chd.map.decode(alloc, fixtures[0].bytes[0..cut], h.map_offset, h.hunk_count, h.hunk_bytes));
    }
    try std.testing.expectError(error.BadMap, chd.map.decode(alloc, fixtures[0].bytes, std.math.maxInt(u64), h.hunk_count, h.hunk_bytes));
    var prng = std.Random.DefaultPrng.init(4);
    const rand = prng.random();
    for (0..200) |_| {
        const m = try alloc.dupe(u8, fixtures[0].bytes);
        defer alloc.free(m);
        const at: usize = @intCast(h.map_offset + rand.uintLessThan(u64, @min(200, m.len - h.map_offset)));
        m[at] ^= @as(u8, 1) << rand.int(u3);
        if (chd.map.decode(alloc, m, h.map_offset, h.hunk_count, h.hunk_bytes)) |e| alloc.free(e) else |_| {}
    }
}

const Disc = ps1.disc.Disc;

test "a CHT2 track with a stored pregap parses" {
    const t = try chd.parseTrack("TRACK:2 TYPE:AUDIO SUBTYPE:NONE FRAMES:10410 PREGAP:150 PGTYPE:VAUDIO PGSUB:NONE POSTGAP:0");
    try std.testing.expectEqual(chd.TrackMeta{ .number = 2, .audio = true, .frames = 10410, .stored_pregap = 150 }, t);
}

test "an unstored pregap is not in the image" {
    const t = try chd.parseTrack("TRACK:1 TYPE:MODE2_RAW SUBTYPE:NONE FRAMES:26404 PREGAP:150 PGTYPE:MODE1 PGSUB:NONE POSTGAP:0");
    try std.testing.expectEqual(chd.TrackMeta{ .number = 1, .audio = false, .frames = 26404, .stored_pregap = 0 }, t);
}

test "a CHTR track (no pregap fields) parses" {
    const t = try chd.parseTrack("TRACK:1 TYPE:MODE1_RAW SUBTYPE:NONE FRAMES:300");
    try std.testing.expectEqual(chd.TrackMeta{ .number = 1, .audio = false, .frames = 300, .stored_pregap = 0 }, t);
}

test "a cooked track type is refused" {
    try std.testing.expectError(error.UnsupportedTrackType, chd.parseTrack("TRACK:1 TYPE:MODE1 SUBTYPE:NONE FRAMES:300"));
    try std.testing.expectError(error.BadMetadata, chd.parseTrack("TRACK:1 TYPE:AUDIO FRAMES:10 PREGAP:20 PGTYPE:VAUDIO"));
}

fn expectSameSector(flat: Disc, reader: *chd.Reader, lba: i32, name: []const u8) !void {
    var want: [sector_bytes]u8 = undefined;
    var got: [sector_bytes]u8 = undefined;
    try std.testing.expect(flat.readSector2352(lba, &want));
    try std.testing.expect(reader.readSector(lba, &got));
    std.testing.expectEqualSlices(u8, &want, &got) catch |err| {
        std.debug.print("{s}: LBA {d} differs\n", .{ name, lba });
        return err;
    };
}

test "every codec fixture reads back byte-identical to its .bin, in any order" {
    const flat = Disc.initFromCue(disc_cue, disc_bin);
    const count: i32 = @intCast(disc_bin.len / sector_bytes);
    for (fixtures) |f| {
        const r = try chd.Reader.open(std.testing.allocator, f.bytes);
        defer r.close();
        try std.testing.expectEqual(count, r.sectorCount());
        var lba: i32 = 0;
        while (lba < count) : (lba += 1) try expectSameSector(flat, r, lba, f.name);
        lba = count;
        while (lba > 0) : (lba -= 1) try expectSameSector(flat, r, lba - 1, f.name);
        // Interleaved: a data sector, then CD-DA, as a game streaming music does.
        lba = 0;
        while (lba < 30) : (lba += 1) {
            try expectSameSector(flat, r, lba, f.name);
            try expectSameSector(flat, r, count - 1 - lba, f.name);
        }
    }
}

test "a fixture's track table matches the cue's" {
    const flat = Disc.initFromCue(disc_cue, disc_bin);
    for (fixtures) |f| {
        const r = try chd.Reader.open(std.testing.allocator, f.bytes);
        defer r.close();
        try std.testing.expectEqual(flat.track_count, r.track_count);
        for (flat.tracks[0..flat.track_count], r.tracks[0..r.track_count]) |want, got| {
            try std.testing.expectEqualDeep(want, got);
        }
    }
}

test "a read outside the disc fails without touching a hunk" {
    const r = try chd.Reader.open(std.testing.allocator, fixtures[0].bytes);
    defer r.close();
    var out: [sector_bytes]u8 = undefined;
    try std.testing.expect(!r.readSector(-1, &out));
    try std.testing.expect(!r.readSector(r.sectorCount(), &out));
}

test "a corrupted hunk fails its own reads and no others" {
    // The reader warns once on an unreadable hunk; these tests provoke it.
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    const a = std.testing.allocator;
    const clean = try chd.Reader.open(a, fixtures[0].bytes);
    const first = clean.map[0];
    clean.close();
    try std.testing.expect(first.kind != .self and first.kind != .none);
    const at: usize = @intCast(first.offset + first.length / 2);
    const m = try mutated(fixtures[0].bytes, at, &.{fixtures[0].bytes[at] ^ 0xFF});
    defer a.free(m);
    const r = try chd.Reader.open(a, m);
    defer r.close();
    var out: [sector_bytes]u8 = undefined;
    try std.testing.expect(!r.readSector(0, &out));
    try std.testing.expect(r.readSector(r.sectorCount() - 1, &out));
}

test "a truncated or bit-rotted CHD never panics" {
    // The reader warns once on an unreadable hunk; these tests provoke it.
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    const a = std.testing.allocator;
    for (fixtures) |f| {
        // Half a file: chdman writes the map last, so open must refuse it.
        try std.testing.expectError(error.BadMap, chd.Reader.open(a, f.bytes[0 .. f.bytes.len / 2]));

        const h = try chd.Header.parse(f.bytes);
        const m = try a.dupe(u8, f.bytes);
        defer a.free(m);
        var rng = std.Random.DefaultPrng.init(f.bytes.len);
        for (0..64) |_| {
            const at = rng.random().intRangeLessThan(usize, 124, @intCast(h.map_offset));
            m[at] ^= rng.random().int(u8) | 1;
        }
        const r = chd.Reader.open(a, m) catch continue;
        defer r.close();
        var out: [sector_bytes]u8 = undefined;
        var lba: i32 = 0;
        while (lba < r.sectorCount()) : (lba += 1) _ = r.readSector(lba, &out);
    }
}

test "a header claiming an absurd hunk size or count is refused" {
    const a = std.testing.allocator;
    const hunk_bytes = try mutated(fixtures[0].bytes, 56, &.{ 0, 0x09, 0x99, 0x90 }); // 257 frames
    defer a.free(hunk_bytes);
    try std.testing.expectError(error.BadHeader, chd.Header.parse(hunk_bytes));
    const huge = try mutated(fixtures[0].bytes, 56, &.{ 0xFF, 0xFF, 0xFF, 0xFF - 0xFF % 2448 });
    defer a.free(huge);
    try std.testing.expectError(error.BadHeader, chd.Header.parse(huge));
    const count = try mutated(fixtures[0].bytes, 32, &.{ 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
    defer a.free(count);
    try std.testing.expectError(error.BadHeader, chd.Header.parse(count));
}

test "a metadata pointer near the end of the address space is refused" {
    const a = std.testing.allocator;
    const h = try chd.Header.parse(fixtures[0].bytes);
    const far = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xF8 };
    const head = try mutated(fixtures[0].bytes, 48, &far);
    defer a.free(head);
    try std.testing.expectError(error.BadMetadata, chd.Reader.open(a, head));
    const chain = try mutated(fixtures[0].bytes, @intCast(h.meta_offset + 8), &far);
    defer a.free(chain);
    try std.testing.expectError(error.BadMetadata, chd.Reader.open(a, chain));
}

test "a track too long to be a disc is refused" {
    try std.testing.expectError(error.BadMetadata, chd.parseTrack("TRACK:1 TYPE:AUDIO FRAMES:4294967295"));
    try std.testing.expectError(error.BadMetadata, chd.parseTrack("TRACK:1 TYPE:AUDIO FRAMES:2147483648"));
}

test "a self-reference to a self-reference is refused" {
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    const r = try chd.Reader.open(std.testing.allocator, fixtures[0].bytes);
    defer r.close();
    const per_hunk: i32 = @intCast(r.header.hunk_bytes / chd.cd.frame_bytes);
    try std.testing.expect(r.map.len > 2);
    r.map[1] = .{ .kind = .self, .length = 0, .offset = 0, .crc = 0 };
    r.map[2] = .{ .kind = .self, .length = 0, .offset = 1, .crc = 0 };
    var out: [sector_bytes]u8 = undefined;
    try std.testing.expect(!r.readSector(2 * per_hunk, &out));
}

test "a Disc over a CHD answers exactly as the Disc over its cue" {
    const flat = Disc.initFromCue(disc_cue, disc_bin);
    const r = try chd.Reader.open(std.testing.allocator, fixtures[4].bytes);
    defer r.close();
    const packed_disc = Disc.initFromChd(r);

    try std.testing.expectEqual(flat.sectorCount(), packed_disc.sectorCount());
    try std.testing.expectEqual(flat.leadOut(), packed_disc.leadOut());
    try std.testing.expectEqual(flat.firstTrack(), packed_disc.firstTrack());
    try std.testing.expectEqual(flat.lastTrack(), packed_disc.lastTrack());
    var lba: i32 = 0;
    while (lba < flat.sectorCount()) : (lba += 1) {
        try std.testing.expectEqual(flat.getSubchannelQ(lba), packed_disc.getSubchannelQ(lba));
        var want: [2048]u8 = undefined;
        var got: [2048]u8 = undefined;
        try std.testing.expectEqual(flat.readSector(lba, &want), packed_disc.readSector(lba, &got));
        try std.testing.expectEqualSlices(u8, &want, &got);
    }
}

test "a LibCrypt sidecar applies to a CHD disc as to a .bin" {
    const r = try chd.Reader.open(std.testing.allocator, fixtures[0].bytes);
    defer r.close();
    var d = Disc.initFromChd(r);
    // One record: MSF 00:02:05 (LBA 5), type 1, ten bytes of Q.
    const sbi = "SBI\x00" ++ [_]u8{ 0x00, 0x02, 0x05, 0x01 } ++ @as([10]u8, @splat(0));
    d.setSbi(sbi);
    try std.testing.expect(d.isLibCryptSector(5));
    try std.testing.expect(!d.isLibCryptSector(6));
}
