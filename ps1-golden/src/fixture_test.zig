//! The .p1fx format and its hash, pinned independently on the Zig side.
//! ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift pins the SAME literal
//! vectors on the Swift side, so neither implementation is verified only
//! against the other — which is what a cross-language convention needs.

const std = @import("std");
const ps1 = @import("ps1_core");
const fixture = @import("fixture.zig");

test "fixture: FNV-1a 64 matches the published vectors" {
    try std.testing.expectEqual(@as(u64, 0xcbf29ce484222325), fixture.fnv1a(""));
    try std.testing.expectEqual(@as(u64, 0xaf63dc4c8601ec8c), fixture.fnv1a("a"));
    try std.testing.expectEqual(@as(u64, 0x85944171f73967e8), fixture.fnv1a("foobar"));
}

test "fixture: VRAM is hashed as little-endian u16, full 1024x512" {
    // Pins the BYTE ORDER, which the ASCII vectors above cannot.
    const px = [_]u16{ 0x0000, 0x7FFF, 0x8001, 0x1234 };
    try std.testing.expectEqual(
        @as(u64, 0x1b86415c70511fc8),
        fixture.fnv1a(std.mem.sliceAsBytes(px[0..])),
    );

    // Pins the EXTENT: the full VRAM, not the display window.
    const v = try std.testing.allocator.create(ps1.gpu.Vram);
    defer std.testing.allocator.destroy(v);
    v.* = .{};
    try std.testing.expectEqual(@as(u64, 0xa96777069d622325), fixture.hashVram(v));
}
