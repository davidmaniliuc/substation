const std = @import("std");
const ps1 = @import("ps1_core");
const pbp = ps1.pbp;
const Disc = ps1.disc.Disc;
const fixtures = @import("image_fixtures.zig");

const bin = fixtures.disc_bin;
const sectors = bin.len / 2352;
const encrypted: u32 = 0x44475000;

fn fixtureDisc() Disc {
    return Disc.initFromCue(fixtures.disc_cue, bin);
}

fn encode(a: std.mem.Allocator, stored: bool) ![]u8 {
    return fixtures.encodePbp(a, &.{.{ .raw = bin, .d = fixtureDisc() }}, "Fixture", stored);
}

fn encodeTwo(a: std.mem.Allocator, stored: bool) ![]u8 {
    const short = bin[0 .. 40 * 2352];
    return fixtures.encodePbp(a, &.{
        .{ .raw = bin, .d = fixtureDisc() },
        .{ .raw = short, .d = Disc.init(short) },
    }, "Fixture", stored);
}

fn u32At(b: []const u8, at: usize) usize {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

fn put32(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}

/// File offset of the first byte of `key`'s value in the eboot's SFO.
fn sfoValue(b: []const u8, key: []const u8) usize {
    const sfo = u32At(b, 8);
    const count = u32At(b, sfo + 0x10);
    for (0..count) |i| {
        const e = sfo + 0x14 + i * 16;
        const name = std.mem.sliceTo(b[sfo + u32At(b, sfo + 8) + std.mem.readInt(u16, b[e..][0..2], .little) ..], 0);
        if (std.mem.eql(u8, name, key)) return sfo + u32At(b, sfo + 12) + u32At(b, e + 12);
    }
    unreachable;
}

fn sfoEntry(b: []const u8, key: []const u8) usize {
    const sfo = u32At(b, 8);
    for (0..u32At(b, sfo + 0x10)) |i| {
        const e = sfo + 0x14 + i * 16;
        const name = std.mem.sliceTo(b[sfo + u32At(b, sfo + 8) + std.mem.readInt(u16, b[e..][0..2], .little) ..], 0);
        if (std.mem.eql(u8, name, key)) return e;
    }
    unreachable;
}

fn expectAllSectors(r: *pbp.Reader) !void {
    var out: [2352]u8 = undefined;
    for (0..sectors) |lba| {
        try std.testing.expect(r.readSector(@intCast(lba), &out));
        try std.testing.expectEqualSlices(u8, bin[lba * 2352 ..][0..2352], &out);
    }
}

test "an eboot reads back as its cue's disc" {
    const a = std.testing.allocator;
    for ([_]bool{ true, false }) |stored| {
        const file = try encode(a, stored);
        defer a.free(file);
        try std.testing.expect(pbp.isPbp(file));
        const r = try pbp.Reader.open(a, file, 0);
        defer r.close();
        const want = fixtureDisc();
        try std.testing.expectEqual(@as(u8, 3), r.track_count);
        for (0..3) |i| try std.testing.expectEqualDeep(want.tracks[i], r.tracks[i]);
        try std.testing.expectEqual(@as(i32, sectors), r.sectorCount());
        try expectAllSectors(r);
    }
}

test "a deflated eboot is smaller than a stored one" {
    const a = std.testing.allocator;
    const stored = try encode(a, true);
    defer a.free(stored);
    const packed_file = try encode(a, false);
    defer a.free(packed_file);
    try std.testing.expect(packed_file.len < stored.len);
}

test "the last short block reads, and past the end does not" {
    const a = std.testing.allocator;
    const file = try encode(a, false);
    defer a.free(file);
    const r = try pbp.Reader.open(a, file, 0);
    defer r.close();
    var out: [2352]u8 = undefined;
    try std.testing.expect(r.readSector(sectors - 1, &out));
    try std.testing.expectEqualSlices(u8, bin[(sectors - 1) * 2352 ..][0..2352], &out);
    try std.testing.expect(!r.readSector(sectors, &out));
    try std.testing.expect(!r.readSector(-1, &out));
}

test "a two-disc eboot opens each disc" {
    const a = std.testing.allocator;
    const file = try encodeTwo(a, false);
    defer a.free(file);
    try std.testing.expectEqual(@as(u8, 2), try pbp.discCount(file));
    const first = try pbp.Reader.open(a, file, 0);
    defer first.close();
    try std.testing.expectEqual(@as(i32, sectors), first.sectorCount());
    try expectAllSectors(first);
    const second = try pbp.Reader.open(a, file, 1);
    defer second.close();
    try std.testing.expectEqual(@as(i32, 40), second.sectorCount());
    try std.testing.expectEqual(@as(u8, 1), second.track_count);
    var out: [2352]u8 = undefined;
    try std.testing.expect(second.readSector(39, &out));
    try std.testing.expectEqualSlices(u8, bin[39 * 2352 ..][0..2352], &out);
    try std.testing.expectError(error.BadPbp, pbp.Reader.open(a, file, 2));
}

test "refusals" {
    const a = std.testing.allocator;
    const Case = struct { name: []const u8, want: anyerror };
    const cases = [_]Case{
        .{ .name = "category", .want = error.BadPbp },
        .{ .name = "bootable", .want = error.BadPbp },
        .{ .name = "disc magic", .want = error.BadPbp },
        .{ .name = "encrypted disc", .want = error.EncryptedPbp },
        .{ .name = "encrypted table", .want = error.EncryptedPbp },
        .{ .name = "toc point", .want = error.BadPbp },
        .{ .name = "sfo type", .want = error.BadPbp },
        .{ .name = "psar offset", .want = error.BadPbp },
    };
    for (cases) |c| {
        const file = if (std.mem.eql(u8, c.name, "encrypted table")) try encodeTwo(a, true) else try encode(a, true);
        defer a.free(file);
        const psar = u32At(file, 0x24);
        if (std.mem.eql(u8, c.name, "category")) {
            file[sfoValue(file, "CATEGORY")] = 'E';
        } else if (std.mem.eql(u8, c.name, "bootable")) {
            put32(file, sfoValue(file, "BOOTABLE"), 0);
        } else if (std.mem.eql(u8, c.name, "disc magic")) {
            file[psar] = 'X';
        } else if (std.mem.eql(u8, c.name, "encrypted disc")) {
            put32(file, psar + 0x400, encrypted);
        } else if (std.mem.eql(u8, c.name, "encrypted table")) {
            put32(file, psar + 0x200, encrypted);
        } else if (std.mem.eql(u8, c.name, "toc point")) {
            file[psar + 0x800 + 10 + 2] = 0xA0;
        } else if (std.mem.eql(u8, c.name, "sfo type")) {
            std.mem.writeInt(u16, file[sfoEntry(file, "TITLE") + 2 ..][0..2], 0x0004, .little);
        } else {
            put32(file, 0x24, @intCast(file.len + 1));
        }
        try std.testing.expectError(c.want, pbp.Reader.open(a, file, 0));
    }
}

test "title is the SFO TITLE" {
    const a = std.testing.allocator;
    const file = try encode(a, true);
    defer a.free(file);
    try std.testing.expectEqualStrings("Fixture", try pbp.title(file));
    file[sfoValue(file, "TITLE")] = 'F';
    const key = std.mem.indexOf(u8, file, "TITLE\x00").?;
    file[key] = 'X';
    try std.testing.expectEqualStrings("", try pbp.title(file));
}

test "an eboot disc reads through Disc" {
    const a = std.testing.allocator;
    const file = try encode(a, false);
    defer a.free(file);
    const r = try pbp.Reader.open(a, file, 0);
    defer r.close();
    const d = Disc.initFromPbp(r);
    try std.testing.expectEqual(@as(i32, sectors), d.sectorCount());
    var out: [2352]u8 = undefined;
    try std.testing.expect(d.readSector2352(50, &out));
    try std.testing.expectEqualSlices(u8, bin[50 * 2352 ..][0..2352], &out);
}

test "write the two-disc fixture" {
    if (!try std.testing.environ.contains(std.testing.allocator, "PS1_WRITE_FIXTURES")) return error.SkipZigTest;
    const a = std.testing.allocator;
    const file = try encodeTwo(a, false);
    defer a.free(file);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = "ps1-core/tests/fixtures/two-disc.pbp", .data = file });
}

const t = std.testing;

/// The file offset of disc 0's TOC entry `index` (0 = A0, 2 = A2, 3 = track 1).
fn tocEntry(file: []const u8, index: usize) usize {
    return u32At(file, 0x24) + 0x800 + index * 10;
}

/// Replaces block `n` of a single-disc eboot with a stored deflate stream
/// holding `payload` and nothing else: a final block with no padding.
fn withShortBlock(a: std.mem.Allocator, file: []const u8, n: usize, payload: []const u8) ![]u8 {
    const psar = u32At(file, 0x24);
    const entry = psar + 0x4000 + n * 32;
    const start = psar + 0x100000 + u32At(file, entry);
    const old = std.mem.readInt(u16, file[entry + 4 ..][0..2], .little);
    const len: u16 = @intCast(payload.len);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, file[0..start]);
    try out.append(a, 0x01);
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, len)));
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, ~len)));
    try out.appendSlice(a, payload);
    try out.appendSlice(a, file[start + old ..]);
    std.mem.writeInt(u16, out.items[entry + 4 ..][0..2], @intCast(payload.len + 5), .little);
    return out.toOwnedSlice(a);
}

test "a final block that inflates short reads up to its end and no further" {
    const a = t.allocator;
    const file = try encode(a, false);
    defer a.free(file);
    // Track 1's pregap is off the file (see the next test), so file sector
    // 112, the one real sector of the last block, is LBA 37 and 113 is LBA 38.
    shiftTrack1(file);
    const cut = try withShortBlock(a, file, (sectors - 1) / 16, bin[(sectors - 1) * 2352 ..][0..2352]);
    defer a.free(cut);
    const r = try pbp.Reader.open(a, cut, 0);
    defer r.close();
    try t.expectEqual(@as(i32, sectors), r.sectorCount());
    var out: [2352]u8 = undefined;
    try t.expect(r.readSector(sectors - 1 - 75, &out));
    try t.expectEqualSlices(u8, bin[(sectors - 1) * 2352 ..][0..2352], &out);
    try t.expect(!r.readSector(sectors - 75, &out));
    try t.expect(!r.readSector(sectors - 1, &out));
    // The blocks before it are untouched.
    try t.expect(r.readSector(0, &out));
    try t.expectEqualSlices(u8, bin[75 * 2352 ..][0..2352], &out);
}

/// Rewrites disc 0's TOC so track 1's user time is before its pregap field
/// (the pregap is then off the file, `user < pregap`): user 00:01:00, pregap
/// 00:02:00, and a lead-out given as an absolute time, 113 sectors on.
fn shiftTrack1(file: []u8) void {
    const a2 = tocEntry(file, 2);
    file[a2 + 7 ..][0..3].* = .{ 0x00, 0x03, 0x38 };
    const t1 = tocEntry(file, 3);
    file[t1 + 3 ..][0..3].* = .{ 0x00, 0x02, 0x00 };
    file[t1 + 7 ..][0..3].* = .{ 0x00, 0x01, 0x00 };
}

test "a track 1 whose user time precedes its pregap leaves the count and maps from the user time" {
    const a = t.allocator;
    const file = try encode(a, true);
    defer a.free(file);
    shiftTrack1(file);
    const r = try pbp.Reader.open(a, file, 0);
    defer r.close();
    // Unchanged count: the lead-out is taken as it stands, no pregap added.
    try t.expectEqual(@as(i32, sectors), r.sectorCount());
    // user = LBA -75, so track1_pregap = -75 + 150 and file sector = LBA + 75.
    try t.expectEqual(@as(i32, 75), r.track1_pregap);
    var out: [2352]u8 = undefined;
    for ([_]usize{ 0, 10, 37 }) |lba| {
        try t.expect(r.readSector(@intCast(lba), &out));
        try t.expectEqualSlices(u8, bin[(lba + 75) * 2352 ..][0..2352], &out);
    }
}

test "an SFO offset that would wrap a 32-bit usize is refused" {
    const a = t.allocator;
    for ([_]usize{ 8, 12 }) |field| {
        const file = try encode(a, true);
        defer a.free(file);
        const sfo = u32At(file, 8);
        // The base plus an entry's own offset exceeds u32: on wasm32 that sum
        // wrapped to a small, valid-looking place.
        put32(file, sfo + field, 0xFFFFFFF0);
        try t.expectError(error.BadPbp, pbp.title(file));
    }
}

/// Opens a deflated eboot and hands back where its first block sits in `file`
/// (the table entry, the block's bytes) so a test can damage it.
fn firstBlock(file: []u8, r: *const pbp.Reader) struct { entry: usize, bytes: usize, size: usize } {
    const entry = @intFromPtr(r.table.ptr) - @intFromPtr(file.ptr);
    return .{
        .entry = entry,
        .bytes = @intCast(r.image + u32At(file, entry)),
        .size = std.mem.readInt(u16, file[entry + 4 ..][0..2], .little),
    };
}

test "a damaged deflate block fails its reads and never serves garbage" {
    const a = std.testing.allocator;
    const Damage = enum { truncated, flipped, no_final_marker, open_ended };
    for ([_]Damage{ .truncated, .flipped, .no_final_marker, .open_ended }) |damage| {
        const file = try encode(a, false);
        defer a.free(file);
        const r = try pbp.Reader.open(a, file, 0);
        defer r.close();
        const at = firstBlock(file, r);
        // The fixture is compressible, so the first block is a real deflate stream.
        try std.testing.expect(at.size < 16 * 2352);
        switch (damage) {
            .truncated => std.mem.writeInt(u16, file[at.entry + 4 ..][0..2], @intCast(at.size / 2), .little),
            .flipped => for (file[at.bytes..][0..at.size]) |*b| {
                b.* ^= 0xA5;
            },
            // The stream with its last byte gone: the final-block marker lives in the last block header.
            .no_final_marker => std.mem.writeInt(u16, file[at.entry + 4 ..][0..2], @intCast(at.size - 1), .little),
            // A well-formed stored deflate block that is NOT the final one, then
            // the end of the input: it inflates cleanly but never says it is done.
            .open_ended => {
                // One whole sector, so a reader that accepts it would serve 0x5A bytes.
                const stored_len = 2352;
                try std.testing.expect(at.bytes + 5 + stored_len <= file.len);
                file[at.bytes] = 0x00;
                std.mem.writeInt(u16, file[at.bytes + 1 ..][0..2], stored_len, .little);
                std.mem.writeInt(u16, file[at.bytes + 3 ..][0..2], ~@as(u16, stored_len), .little);
                @memset(file[at.bytes + 5 ..][0..stored_len], 0x5A);
                std.mem.writeInt(u16, file[at.entry + 4 ..][0..2], 5 + stored_len, .little);
            },
        }
        var out: [2352]u8 = undefined;
        // Every sector of that block must fail, not read as short or wrong bytes.
        for (0..16) |lba| try std.testing.expect(!r.readSector(@intCast(lba), &out));
    }
}
