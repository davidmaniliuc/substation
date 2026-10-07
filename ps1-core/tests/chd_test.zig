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
