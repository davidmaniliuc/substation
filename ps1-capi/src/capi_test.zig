const std = @import("std");
const capi = @import("root.zig");

test "create returns a handle and destroy frees it" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    capi.ps1_destroy(h);
}

test "destroy of a handle that never got a BIOS is safe" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    capi.ps1_destroy(h);
}

test "destroy tolerates null" {
    capi.ps1_destroy(null);
}

test "load_bios rejects any length that is not 524288" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const short = [_]u8{0} ** 16;
    try std.testing.expectEqual(@as(i32, -1), capi.ps1_load_bios(h, &short, short.len));

    const good = try std.testing.allocator.alloc(u8, 524288);
    defer std.testing.allocator.free(good);
    @memset(good, 0xAB);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_bios(h, good.ptr, good.len));
    try std.testing.expectEqual(@as(u8, 0xAB), h.cpu.bus.bios[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), h.cpu.bus.bios[524287]);
}

test "reset keeps the loaded BIOS" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const good = try std.testing.allocator.alloc(u8, 524288);
    defer std.testing.allocator.free(good);
    @memset(good, 0x5A);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_bios(h, good.ptr, good.len));

    // Dirty some RAM, then reset.
    h.cpu.bus.ram[0x1000] = 0xFF;
    capi.ps1_reset(h);

    try std.testing.expectEqual(@as(u8, 0x5A), h.cpu.bus.bios[0]);
    try std.testing.expectEqual(@as(u8, 0), h.cpu.bus.ram[0x1000]);
}
