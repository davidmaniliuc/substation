const std = @import("std");
const ps1 = @import("ps1_core");
const ecm = ps1.ecm;
const sector = ps1.sector;
const fixtures = @import("image_fixtures.zig");

const bin = @embedFile("chd/disc.bin");
const sectors = bin.len / 2352;

fn binSector(lba: usize) *const [2352]u8 {
    return bin[lba * 2352 ..][0..2352];
}

fn expectSector(r: *ecm.Reader, want: *const [2352]u8, lba: usize) !void {
    var out: [2352]u8 = undefined;
    try std.testing.expect(r.readSector(@intCast(lba), &out));
    try std.testing.expectEqualSlices(u8, want, &out);
}

test "ECM decodes every sector of the fixture disc" {
    const a = std.testing.allocator;
    const encoded = try fixtures.encodeEcm(a, bin);
    defer a.free(encoded);
    try std.testing.expect(ecm.isEcm(encoded));
    // The data sectors were stripped, not stored raw.
    try std.testing.expect(encoded.len < bin.len);

    const r = try ecm.Reader.open(a, encoded);
    defer r.close();
    try std.testing.expectEqual(@as(i32, sectors), r.sectorCount());
    for (0..sectors) |lba| try expectSector(r, binSector(lba), lba);
    var out: [2352]u8 = undefined;
    try std.testing.expect(!r.readSector(sectors, &out));
    try std.testing.expect(!r.readSector(-1, &out));
}

test "ECM answers sectors out of order" {
    const a = std.testing.allocator;
    const encoded = try fixtures.encodeEcm(a, bin);
    defer a.free(encoded);
    const r = try ecm.Reader.open(a, encoded);
    defer r.close();
    for ([_]usize{ 112, 0, 57 }) |lba| try expectSector(r, binSector(lba), lba);
}

test "ECM finds a sector hundreds of chunks in, out of order" {
    // Each Form 1 sector is two chunks, so this stream needs several
    // checkpoints and a search that lands between them.
    const a = std.testing.allocator;
    const count = 300;
    const raw = try a.alloc(u8, count * 2352);
    defer a.free(raw);
    for (0..count) |lba| {
        var payload: [2048]u8 = undefined;
        for (&payload, 0..) |*b, i| b.* = @truncate(lba *% 31 +% i);
        sector.dress(.mode2_form1, @intCast(lba), &payload, raw[lba * 2352 ..][0..2352]);
    }
    const encoded = try fixtures.encodeEcm(a, raw);
    defer a.free(encoded);
    const r = try ecm.Reader.open(a, encoded);
    defer r.close();
    for ([_]usize{ 250, 3, 129, 128, 299, 64, 0, 200 }) |lba| try expectSector(r, raw[lba * 2352 ..][0..2352], lba);
    try std.testing.expectEqual(@as(i32, count), r.sectorCount());
}

test "ECM rebuilds a Form 2 sector" {
    const a = std.testing.allocator;
    var raw: [2 * 2352]u8 = undefined;
    for (0..2) |lba| {
        var payload: [2324]u8 = undefined;
        for (&payload, 0..) |*b, i| b.* = @truncate(i *% 7 +% lba);
        sector.dress(.mode2_form2, @intCast(lba + 40), &payload, raw[lba * 2352 ..][0..2352]);
    }
    const encoded = try fixtures.encodeEcm(a, &raw);
    defer a.free(encoded);
    // Magic, then per sector a raw 16-byte chunk and a type-3 record (one
    // header byte each), then the terminator and the EDC.
    try std.testing.expectEqual(@as(usize, 4 + 2 * (1 + 16 + 1 + 0x918) + 5 + 4), encoded.len);
    const r = try ecm.Reader.open(a, encoded);
    defer r.close();
    try expectSector(r, raw[2352..][0..2352], 1);
    try expectSector(r, raw[0..2352], 0);
}

test "ECM refuses a bad magic, a truncated stream and a misaligned total" {
    const a = std.testing.allocator;
    const encoded = try fixtures.encodeEcm(a, bin);
    defer a.free(encoded);

    const bad_magic = try a.dupe(u8, encoded);
    defer a.free(bad_magic);
    bad_magic[2] = 'X';
    try std.testing.expect(!ecm.isEcm(bad_magic));
    try std.testing.expectError(error.BadEcm, ecm.Reader.open(a, bad_magic));

    const truncated = try ecm.Reader.open(a, encoded[0 .. encoded.len - 10]);
    defer truncated.close();
    try std.testing.expect(truncated.sectorCount() < sectors);
    var out: [2352]u8 = undefined;
    try std.testing.expect(!truncated.readSector(112, &out));

    // One 100-byte raw chunk, then the terminator: 100 decoded bytes is not
    // a whole sector.
    var misaligned: [4 + 2 + 100 + 5]u8 = undefined;
    misaligned[0..4].* = "ECM\x00".*;
    misaligned[4] = 0x80 | ((99 & 0x1F) << 2);
    misaligned[5] = 99 >> 5;
    @memset(misaligned[6..106], 0x5A);
    misaligned[106..111].* = .{ 0xFC, 0xFF, 0xFF, 0xFF, 0x3F };
    const short = try ecm.Reader.open(a, &misaligned);
    defer short.close();
    try std.testing.expectEqual(@as(i32, 0), short.sectorCount());
    try std.testing.expect(!short.readSector(0, &out));
}

test "an ECM disc reads through Disc" {
    const a = std.testing.allocator;
    const encoded = try fixtures.encodeEcm(a, bin);
    defer a.free(encoded);
    const r = try ecm.Reader.open(a, encoded);
    defer r.close();
    const d = ps1.disc.Disc.initFromEcm(r);
    var out: [2352]u8 = undefined;
    try std.testing.expect(d.readSector2352(25, &out));
    try std.testing.expectEqualSlices(u8, binSector(25), &out);
    try std.testing.expectEqual(@as(i32, sectors), d.sectorCount());
}
