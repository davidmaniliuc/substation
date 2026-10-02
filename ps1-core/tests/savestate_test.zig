const std = @import("std");
const ps1 = @import("ps1_core");
const stream = ps1.savestate_stream;

test "ints round-trip at their wire width, little-endian" {
    var buf: [64]u8 = undefined;
    var w = stream.Writer{ .buf = &buf };
    try w.int(@as(u5, 17));
    try w.int(@as(i16, -2));
    try w.int(@as(u32, 0xDEADBEEF));
    try w.int(@as(i64, -5));
    try w.int(@as(usize, 7));
    // u5 -> 1 byte, i16 -> 2, u32 -> 4, i64 -> 8, usize -> 8 (always u64 on the wire)
    try std.testing.expectEqual(@as(usize, 1 + 2 + 4 + 8 + 8), w.len);
    try std.testing.expectEqualSlices(u8, &.{ 0xEF, 0xBE, 0xAD, 0xDE }, buf[3..7]);

    var r = stream.Reader{ .buf = buf[0..w.len] };
    try std.testing.expectEqual(@as(u5, 17), try r.int(u5));
    try std.testing.expectEqual(@as(i16, -2), try r.int(i16));
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), try r.int(u32));
    try std.testing.expectEqual(@as(i64, -5), try r.int(i64));
    try std.testing.expectEqual(@as(usize, 7), try r.int(usize));
    try r.end();
}

test "a counting writer measures without writing" {
    var w = stream.Writer{};
    try w.int(@as(u32, 1));
    try w.array(&[_]i16{ 1, 2, 3 });
    try std.testing.expectEqual(@as(usize, 4 + 6), w.len);
}

test "a full buffer is NoSpace, not an overrun" {
    var buf: [3]u8 = undefined;
    var w = stream.Writer{ .buf = &buf };
    try std.testing.expectError(error.NoSpace, w.int(@as(u32, 1)));
}

test "out-of-range narrow ints, bools and enums are StateCorrupt" {
    const E = enum(u8) { a = 0, b = 5 };
    var r = stream.Reader{ .buf = &.{0x20} }; // 32 does not fit a u5
    try std.testing.expectError(error.StateCorrupt, r.int(u5));
    r = .{ .buf = &.{2} };
    try std.testing.expectError(error.StateCorrupt, r.flag());
    r = .{ .buf = &.{ 3, 0, 0, 0 } }; // 3 is not a value of E
    try std.testing.expectError(error.StateCorrupt, r.tag(E));
    r = .{ .buf = &.{ 5, 0, 0, 0 } };
    try std.testing.expectEqual(E.b, try r.tag(E));
}

test "reading past the end, or stopping short of it, is StateCorrupt" {
    var r = stream.Reader{ .buf = &.{ 1, 2 } };
    try std.testing.expectError(error.StateCorrupt, r.int(u32));
    r = .{ .buf = &.{ 1, 2 } };
    _ = try r.int(u8);
    try std.testing.expectError(error.StateCorrupt, r.end());
}

test "arrays of wide elements round-trip" {
    const src = [_]f32{ 1.5, -2.25, 0 };
    var buf: [12]u8 = undefined;
    var w = stream.Writer{ .buf = &buf };
    try w.array(&src);
    var dst: [3]f32 = undefined;
    var r = stream.Reader{ .buf = &buf };
    try r.array(&dst);
    try std.testing.expectEqualSlices(f32, &src, &dst);
}

test "patchU32 rewrites in place and is a no-op when counting" {
    var buf: [8]u8 = [_]u8{0} ** 8;
    var w = stream.Writer{ .buf = &buf };
    try w.int(@as(u32, 0));
    try w.int(@as(u32, 9));
    w.patchU32(0, 0x01020304);
    try std.testing.expectEqualSlices(u8, &.{ 4, 3, 2, 1 }, buf[0..4]);
    var counting = stream.Writer{};
    try counting.int(@as(u32, 0));
    counting.patchU32(0, 5); // must not crash
}
