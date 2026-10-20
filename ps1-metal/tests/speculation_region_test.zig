//! SpeculativeRegion: the VRAM rectangle a runahead group may write. No
//! Metal: runs under `zig build test`.

const std = @import("std");
const ps1_core = @import("ps1_core");
const metal = @import("ps1_metal");
const speculative_region = metal.speculative_region;
const StreamSlot = metal.stream_queue.StreamSlot;
const VramRect = metal.prim_instance.VramRect;
const Command = ps1_core.gpu.command.Command;
const WriteCursor = ps1_core.gpu.WriteCursor;

/// One slot over `cmds`. `of` reads only `records[0..record_count]`, so the
/// slot may borrow the caller's array rather than own recorder-sized storage.
fn region(cmds: []const Command, transfer: WriteCursor) ?VramRect {
    const slot = [_]StreamSlot{.{ .records = @constCast(cmds), .payload = &.{}, .record_count = cmds.len }};
    return speculative_region.of(&slot, .{}, transfer);
}

fn rect(x0: i32, y0: i32, x1: i32, y1: i32) ?VramRect {
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

test "SpeculativeRegion: a group that draws nothing has no region" {
    try std.testing.expectEqual(@as(?VramRect, null), region(&.{}, .{}));
    try std.testing.expectEqual(@as(?VramRect, null), region(&.{
        .{ .kind = .set_draw_env, .opcode = 0xE1, .value = 0 },
    }, .{}));
}

test "SpeculativeRegion: a primitive is bounded by the drawing area its group set" {
    try std.testing.expectEqual(rect(10, 20, 329, 259), region(&.{
        .{ .kind = .set_draw_env, .opcode = 0xE3, .value = 10 | (20 << 10) },
        .{ .kind = .set_draw_env, .opcode = 0xE4, .value = 329 | (259 << 10) },
        .{ .kind = .draw_triangle },
    }, .{}));
}

test "SpeculativeRegion: fills, copies and uploads use their own rectangles" {
    try std.testing.expectEqual(rect(100, 50, 115, 57), region(&.{
        .{ .kind = .fill_rect, .x = 100, .y = 50, .w = 16, .h = 8 },
    }, .{}));
    // A copy whose destination crosses the right edge wraps: the whole width.
    try std.testing.expectEqual(rect(0, 4, 1023, 5), region(&.{
        .{ .kind = .copy_rect, .x2 = 1020, .y2 = 4, .w = 8, .h = 2 },
    }, .{}));
    try std.testing.expectEqual(rect(0, 256, 1023, 256), region(&.{
        .{ .kind = .vram_write_setup, .x = 640, .y = 256, .w = 0, .h = 1 },
    }, .{}));
    try std.testing.expectEqual(rect(0, 0, 115, 115), region(&.{
        .{ .kind = .fill_rect, .x = 0, .y = 0, .w = 16, .h = 16 },
        .{ .kind = .fill_rect, .x = 100, .y = 100, .w = 16, .h = 16 },
    }, .{}));
}

test "SpeculativeRegion: an upload the real frame began is part of the region" {
    const t = WriteCursor.setup(512, 0, 64, 64);
    try std.testing.expectEqual(rect(512, 0, 575, 63), region(&.{
        .{ .kind = .vram_write_data },
    }, t));
}
