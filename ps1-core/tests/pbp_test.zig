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
    file[sfoValue(file, "TITLE") - 0] = 'F';
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
