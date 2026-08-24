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

const command = ps1.gpu.command;

test "fixture: two frames round-trip through serialize and parse" {
    const a = std.testing.allocator;

    var w = fixture.Writer.empty;
    defer w.deinit(a);

    // Frame 0: two records, no payload.
    const f0 = [_]command.Command{
        .{ .kind = .fill_rect, .value = 0x7C1F, .x = 4, .y = 8, .w = 16, .h = 2 },
        .{ .kind = .set_draw_env, .opcode = 0xE6, .value = 3 },
    };
    try w.addFrame(a, .{ .records = &f0, .payload = &.{}, .complete = true }, 0x1111_2222_3333_4444);

    // Frame 1: one record plus a payload run. The record's .x is an offset
    // into THIS FRAME's payload, which is the invariant the format keeps.
    const f1 = [_]command.Command{
        .{ .kind = .vram_write_data, .x = 0, .y = 3 },
    };
    const p1 = [_]u32{ 0xDEAD_BEEF, 0x0BAD_F00D, 0x1234_5678 };
    try w.addFrame(a, .{ .records = &f1, .payload = &p1, .complete = true }, 0x5555_6666_7777_8888);

    const bytes = try w.serialize(a);
    defer a.free(bytes);

    const p = try fixture.parse(a, bytes);
    defer p.deinit(a);

    try std.testing.expectEqual(@as(usize, 2), p.frames.len);
    try std.testing.expectEqual(@as(u64, 0x1111_2222_3333_4444), p.frames[0].vram_hash);
    try std.testing.expectEqual(@as(u64, 0x5555_6666_7777_8888), p.frames[1].vram_hash);

    const s0 = p.frameStream(0);
    try std.testing.expectEqual(@as(usize, 2), s0.records.len);
    try std.testing.expectEqual(command.Kind.fill_rect, s0.records[0].kind);
    try std.testing.expectEqual(@as(u32, 0x7C1F), s0.records[0].value);
    try std.testing.expectEqual(@as(i32, 16), s0.records[0].w);
    try std.testing.expectEqual(@as(u8, 0xE6), s0.records[1].opcode);

    const s1 = p.frameStream(1);
    try std.testing.expectEqual(@as(usize, 3), s1.payload.len);
    try std.testing.expectEqual(@as(u32, 0x0BAD_F00D), s1.payload[1]);
    // Frame-relative: record .x is 0 even though frame 1's payload starts at
    // word 0 of the file only because frame 0 had none.
    try std.testing.expectEqual(@as(i32, 0), s1.records[0].x);
    try std.testing.expect(s1.complete);
}

test "fixture: parse rejects a bad magic and a stride mismatch" {
    const a = std.testing.allocator;

    var w = fixture.Writer.empty;
    defer w.deinit(a);
    try w.addFrame(a, .{ .records = &.{}, .payload = &.{}, .complete = true }, 0);
    const good = try w.serialize(a);
    defer a.free(good);

    const bad_magic = try a.dupe(u8, good);
    defer a.free(bad_magic);
    bad_magic[0] = 'X';
    try std.testing.expectError(error.BadMagic, fixture.parse(a, bad_magic));

    const bad_stride = try a.dupe(u8, good);
    defer a.free(bad_stride);
    std.mem.writeInt(u32, bad_stride[12..16], 64, .little);
    try std.testing.expectError(error.StrideMismatch, fixture.parse(a, bad_stride));

    try std.testing.expectError(error.Truncated, fixture.parse(a, good[0..16]));
}
