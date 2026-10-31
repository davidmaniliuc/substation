const std = @import("std");
const sector = @import("ps1_core").sector;

const bin = @embedFile("chd/disc.bin");

fn binSector(lba: usize) *const [2352]u8 {
    return bin[lba * 2352 ..][0..2352];
}

fn expectDress(comptime mode: sector.CookedMode, lba: usize, from: usize) !void {
    var out: [2352]u8 = undefined;
    sector.dress(mode, @intCast(lba), binSector(lba)[from..][0..comptime mode.bytes()], &out);
    try std.testing.expectEqualSlices(u8, binSector(lba), &out);
}

test "dress mode1 rebuilds a real Mode 1 sector" {
    try expectDress(.mode1, 25, 0x10);
}

test "dress mode2_form1 rebuilds a real Form 1 sector" {
    try expectDress(.mode2_form1, 3, 0x18);
}

test "dress mode2 rebuilds from 2336 bytes" {
    try expectDress(.mode2, 3, 0x10);
}

test "dress mode2_mixed rebuilds a Form 1 sector from 2332 bytes" {
    try expectDress(.mode2_mixed, 3, 0x10);
}

test "dress mode2_form2 lays out a Form 2 sector" {
    var payload: [2324]u8 = @splat(0x5A);
    var out: [2352]u8 = undefined;
    sector.dress(.mode2_form2, 100, &payload, &out);
    try std.testing.expectEqualSlices(u8, &sector.sync_pattern, out[0..12]);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x03, 0x25, 0x02 }, out[12..16]);
    try std.testing.expectEqual(@as(u8, 0x28), out[0x12]);
    try std.testing.expectEqual(@as(u8, 0x5A), out[0x18]);
    try std.testing.expectEqual(sector.edc(out[0x10..0x92C]), std.mem.readInt(u32, out[0x92C..0x930], .little));
}

test "dress mode2_mixed with the Form 2 bit lays out a Form 2 sector" {
    var payload: [2332]u8 = @splat(0x5A);
    payload[0..8].* = .{ 0, 0, 0x28, 0, 0, 0, 0x28, 0 };
    var mixed: [2352]u8 = undefined;
    sector.dress(.mode2_mixed, 100, &payload, &mixed);
    var form2: [2352]u8 = undefined;
    sector.dress(.mode2_form2, 100, payload[8..], &form2);
    try std.testing.expectEqualSlices(u8, &form2, &mixed);
}
