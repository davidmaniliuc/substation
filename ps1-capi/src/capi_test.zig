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

const single_file_cue =
    \\FILE "game.bin" BINARY
    \\  TRACK 01 MODE2/2352
    \\    INDEX 01 00:00:00
    \\
;

const multi_file_cue =
    \\FILE "a.bin" BINARY
    \\  TRACK 01 MODE2/2352
    \\    INDEX 01 00:00:00
    \\FILE "b.bin" BINARY
    \\  TRACK 02 AUDIO
    \\    INDEX 01 00:00:00
    \\
;

test "load_disc rejects a multi-FILE cue" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin = [_]u8{0} ** 2352;
    try std.testing.expectEqual(
        @as(i32, -3),
        capi.ps1_load_disc(h, &bin, bin.len, multi_file_cue.ptr, multi_file_cue.len),
    );
    try std.testing.expect(h.disc == null);
}

test "load_disc rejects a cue with no FILE directive" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin = [_]u8{0} ** 2352;
    const junk = "this is not a cue sheet\n";
    try std.testing.expectEqual(
        @as(i32, -2),
        capi.ps1_load_disc(h, &bin, bin.len, junk.ptr, junk.len),
    );
}

test "load_disc accepts a single-FILE cue and attaches the disc" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin = [_]u8{0} ** 2352;
    try std.testing.expectEqual(
        @as(i32, 0),
        capi.ps1_load_disc(h, &bin, bin.len, single_file_cue.ptr, single_file_cue.len),
    );
    try std.testing.expect(h.disc != null);
    try std.testing.expectEqual(@as(u8, 1), h.disc.?.track_count);
}

test "load_disc with no cue takes the raw .bin fallback" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin = [_]u8{0} ** 2352;
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, &bin, bin.len, null, 0));
    try std.testing.expect(h.disc != null);
    try std.testing.expectEqual(@as(u8, 1), h.disc.?.track_count);
}

test "load_disc rejects an empty image" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const empty = [_]u8{};
    try std.testing.expectEqual(@as(i32, -2), capi.ps1_load_disc(h, &empty, 0, null, 0));
}

test "reset re-attaches the disc" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin = [_]u8{0} ** 2352;
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, &bin, bin.len, null, 0));
    capi.ps1_reset(h);
    try std.testing.expect(h.disc != null);
    try std.testing.expect(h.cpu.bus.cdrom.disc != null);
}
