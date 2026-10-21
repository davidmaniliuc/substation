//! The sidecar's presence invariant under the rasterizer: drawn pixels are
//! present and mirror VRAM, uploads make their rect absent, copies carry
//! presence with the pixels.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const harness = @import("harness.zig");
const command = @import("ps1_core").gpu.command;
const Command = command.Command;

const alloc = std.heap.page_allocator;
const native_pixels = ps1_metal.prim_instance.native_pixels;

fn vtx(x: i16, y: i16, color: u32) command.Vertex {
    return .{ .x = x, .y = y, .color = color, .px = @as(i32, x) << 16, .py = @as(i32, y) << 16 };
}

fn fillRecord(x: i32, y: i32, w: i32, h: i32, value: u32) Command {
    return .{ .kind = .fill_rect, .x = x, .y = y, .w = w, .h = h, .value = value };
}

fn alphaAt(side: []const u8, x: usize, y: usize) u8 {
    return side[(y * 1024 + x) * 4 + 3];
}

test "theSidecarMirrorsVramWhereverItIsPresent" {
    const env = try harness.metal();
    defer env.deinit();
    const rig = try harness.Rig.create(alloc, env, .{});
    defer rig.destroy();
    // Pinned rather than inherited from the shipped default: this invariant
    // is "the sidecar is the 8-bit expansion of 5-bit VRAM", which
    // `.true_color` deliberately breaks by keeping genuine 8-bit precision
    // the expansion can't reproduce.
    rig.r.dither_mode = .native;

    const tri: Command = .{
        .kind = .draw_shaded_triangle,
        .v = .{ vtx(100, 100, 0x0020_4060), vtx(300, 110, 0x00C0_8040), vtx(110, 260, 0x0040_C080) },
    };
    rig.frame(&.{}, &.{
        .{ .kind = .set_draw_env, .opcode = 0xE4, .value = (511 << 10) | 1023 },
        fillRecord(8, 8, 32, 32, 0x2955), // low bits set in all three channels
        tri,
    });

    const pixels = try rig.readback(alloc);
    defer alloc.free(pixels);
    const side = try rig.readbackSidecar(alloc);
    defer alloc.free(side);
    var present: usize = 0;
    for (pixels, 0..) |p, i| {
        const a = side[i * 4 + 3];
        if (a == 0) {
            // Absent means nothing has drawn here, so VRAM is still blank.
            if (p != 0) {
                std.debug.print("pixel {d} is drawn but absent from the sidecar\n", .{i});
                return error.TestExpectedEqual;
            }
            continue;
        }
        // Alpha is presence: only 0 or 255 are legal.
        try std.testing.expectEqual(@as(u8, 255), a);
        present += 1;
        const channels = [3]u16{ p & 0x1F, (p >> 5) & 0x1F, (p >> 10) & 0x1F };
        for (channels, 0..) |c, k| {
            const want: u8 = @intCast((c << 3) | (c >> 2));
            if (side[i * 4 + k] != want) {
                std.debug.print("pixel {d} sidecar disagrees with the expansion of VRAM\n", .{i});
                return error.TestExpectedEqual;
            }
        }
    }
    // Guards the loop against passing vacuously. This geometry paints ~16,974
    // native pixels (the triangle's 15,950 plus the fill's 1,024); 10,000
    // still catches a blank frame, which is all this guard is for.
    try std.testing.expect(present > 10_000);
}

// GP0(A0). The payload is genuine 5551 from the game and no extra precision
// exists, so the destination rect goes ABSENT: exactly the rect, which is
// what per-pixel presence buys over a dirty rectangle.
test "theSidecarIsAbsentWhereVramWasUploaded" {
    const env = try harness.metal();
    defer env.deinit();
    const rig = try harness.Rig.create(alloc, env, .{});
    defer rig.destroy();

    const payload: [16]u32 = @splat(0x1234_1234);
    rig.frame(&payload, &.{
        fillRecord(0, 0, 64, 64, 0x7FFF),
        .{ .kind = .vram_write_setup, .x = 16, .y = 16, .w = 8, .h = 4 },
        // Payload word offset 0; 8 * 4 pixels / 2 per word.
        .{ .kind = .vram_write_data, .x = 0, .y = 16 },
    });

    const side = try rig.readbackSidecar(alloc);
    defer alloc.free(side);
    // Inside the destination rect: absent.
    try std.testing.expectEqual(@as(u8, 0), alphaAt(side, 16, 16));
    try std.testing.expectEqual(@as(u8, 0), alphaAt(side, 23, 19));
    // One pixel outside it on each axis: still present from the fill.
    try std.testing.expectEqual(@as(u8, 255), alphaAt(side, 15, 16));
    try std.testing.expectEqual(@as(u8, 255), alphaAt(side, 24, 16));
    try std.testing.expectEqual(@as(u8, 255), alphaAt(side, 16, 15));
    try std.testing.expectEqual(@as(u8, 255), alphaAt(side, 16, 20));
}

// GP0(80). The sidecar is copied alongside VRAM, alpha included, in the SAME
// shader pass, so an absent source yields an absent destination and the
// invariant carries itself with no extra rule.
test "aCopyCarriesPresenceWithThePixels" {
    const env = try harness.metal();
    defer env.deinit();
    const rig = try harness.Rig.create(alloc, env, .{});
    defer rig.destroy();

    rig.frame(&.{}, &.{
        fillRecord(0, 0, 32, 32, 0x7FFF),
        // Present -> absent region: the fill copied somewhere never drawn.
        .{ .kind = .copy_rect, .x = 0, .y = 0, .x2 = 200, .y2 = 200, .w = 16, .h = 16 },
        // Absent -> present region: somewhere never drawn copied onto the fill.
        .{ .kind = .copy_rect, .x = 500, .y = 400, .x2 = 0, .y2 = 0, .w = 8, .h = 8 },
    });

    const side = try rig.readbackSidecar(alloc);
    defer alloc.free(side);
    try std.testing.expectEqual(@as(u8, 255), alphaAt(side, 205, 205)); // carried presence into a blank region
    try std.testing.expectEqual(@as(u8, 0), alphaAt(side, 4, 4)); // carried absence over a drawn one
    try std.testing.expectEqual(@as(u8, 255), alphaAt(side, 20, 20)); // the rest of the fill is untouched
}

// A resync from a software frame is 5551 with no extra precision in it, so
// both upload paths invalidate the WHOLE sidecar. Keeping presence across one
// would display last frame's eight-bit colour under this frame's picture.
test "bothUploadPathsInvalidateTheWholeSidecar" {
    const env = try harness.metal();
    defer env.deinit();
    const rig = try harness.Rig.create(alloc, env, .{ .scale = 2 });
    defer rig.destroy();
    const fill = [_]Command{fillRecord(0, 0, 64, 64, 0x7FFF)};

    rig.frame(&.{}, &fill);
    try expectSidecar(rig, true);

    const native = try alloc.alloc(u16, native_pixels);
    defer alloc.free(native);
    @memset(native, 0x1234);
    rig.vram.uploadNative(native[0..native_pixels]);
    try expectSidecar(rig, false);

    rig.frame(&.{}, &fill);
    try expectSidecar(rig, true);

    const scaled = try alloc.alloc(u16, rig.vram.pixelCount());
    defer alloc.free(scaled);
    @memset(scaled, 0x1234);
    rig.vram.upload(scaled);
    try expectSidecar(rig, false);
}

/// `present`: some byte of the sidecar is 255. Otherwise: every byte is 0.
fn expectSidecar(rig: *harness.Rig, present: bool) !void {
    const side = try rig.readbackSidecar(alloc);
    defer alloc.free(side);
    if (present) {
        try std.testing.expect(std.mem.indexOfScalar(u8, side, 255) != null);
    } else {
        try std.testing.expect(std.mem.allEqual(u8, side, 0));
    }
}
