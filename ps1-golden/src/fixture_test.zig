//! The .p1fx format and its hash, pinned independently on the Zig side.
//! ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift pins the SAME literal
//! vectors on the Swift side, so neither implementation is verified only
//! against the other — which is what a cross-language convention needs.

const std = @import("std");
const ps1 = @import("ps1_core");
const fixture = @import("fixture.zig");
const env_sync = @import("env_sync.zig");

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

test "fixture: parse rejects a bad version and a bad kind count" {
    const a = std.testing.allocator;

    var w = fixture.Writer.empty;
    defer w.deinit(a);
    try w.addFrame(a, .{ .records = &.{}, .payload = &.{}, .complete = true }, 0);
    const good = try w.serialize(a);
    defer a.free(good);

    const bad_version = try a.dupe(u8, good);
    defer a.free(bad_version);
    std.mem.writeInt(u32, bad_version[8..12], fixture.version + 1, .little);
    try std.testing.expectError(error.BadVersion, fixture.parse(a, bad_version));

    const bad_kind_count = try a.dupe(u8, good);
    defer a.free(bad_kind_count);
    std.mem.writeInt(u32, bad_kind_count[16..20], fixture.kind_count + 1, .little);
    try std.testing.expectError(error.KindCountMismatch, fixture.parse(a, bad_kind_count));
}

test "fixture: parse rejects overflowing record/payload totals without panicking" {
    const a = std.testing.allocator;

    var w = fixture.Writer.empty;
    defer w.deinit(a);
    try w.addFrame(a, .{ .records = &.{}, .payload = &.{}, .complete = true }, 0);
    const good = try w.serialize(a);
    defer a.free(good);

    // 72 * total_records overflows u64 for a total_records this large; the
    // fix must return Truncated instead of panicking (Debug/ReleaseSafe) or
    // silently wrapping into a `want` that happens to match bytes.len
    // (ReleaseFast).
    const huge_records = try a.dupe(u8, good);
    defer a.free(huge_records);
    std.mem.writeInt(u64, huge_records[24..32], 0xFFFF_FFFF_FFFF_FFFF, .little);
    try std.testing.expectError(error.Truncated, fixture.parse(a, huge_records));

    const huge_payload = try a.dupe(u8, good);
    defer a.free(huge_payload);
    std.mem.writeInt(u64, huge_payload[32..40], 0xFFFF_FFFF_FFFF_FFFF, .little);
    try std.testing.expectError(error.Truncated, fixture.parse(a, huge_payload));
}

test "fixture: parse rejects a frame-table entry whose offsets exceed the totals, including the u32-wrap case" {
    const a = std.testing.allocator;

    var w = fixture.Writer.empty;
    defer w.deinit(a);
    const recs = [_]command.Command{.{ .kind = .vram_write_data, .x = 0, .y = 1 }};
    const pay = [_]u32{0xAABB_CCDD};
    try w.addFrame(a, .{ .records = &recs, .payload = &pay, .complete = true }, 0);
    const good = try w.serialize(a);
    defer a.free(good);

    // The (only) frame table entry lives at byte 48: record_off[0..4],
    // record_count[4..8], payload_off[8..12], payload_count[12..16].
    // total_records == total_payload == 1 for this fixture.

    const bad_record_simple = try a.dupe(u8, good);
    defer a.free(bad_record_simple);
    std.mem.writeInt(u32, bad_record_simple[48..52], 5, .little);
    std.mem.writeInt(u32, bad_record_simple[52..56], 5, .little);
    try std.testing.expectError(error.BadOffsets, fixture.parse(a, bad_record_simple));

    // record_off + record_count wraps a u32 add to 1, which equals
    // total_records (1) and would slip past a check done in u32. Widening to
    // u64 before adding must still catch it.
    const bad_record_wrap = try a.dupe(u8, good);
    defer a.free(bad_record_wrap);
    std.mem.writeInt(u32, bad_record_wrap[48..52], 0xFFFF_FFFF, .little);
    std.mem.writeInt(u32, bad_record_wrap[52..56], 2, .little);
    try std.testing.expectError(error.BadOffsets, fixture.parse(a, bad_record_wrap));

    const bad_payload_simple = try a.dupe(u8, good);
    defer a.free(bad_payload_simple);
    std.mem.writeInt(u32, bad_payload_simple[56..60], 5, .little);
    std.mem.writeInt(u32, bad_payload_simple[60..64], 5, .little);
    try std.testing.expectError(error.BadOffsets, fixture.parse(a, bad_payload_simple));

    // Same wrap, on the payload offsets: payload_off + payload_count wraps
    // to 1, matching total_payload (1).
    const bad_payload_wrap = try a.dupe(u8, good);
    defer a.free(bad_payload_wrap);
    std.mem.writeInt(u32, bad_payload_wrap[56..60], 0xFFFF_FFFF, .little);
    std.mem.writeInt(u32, bad_payload_wrap[60..64], 2, .little);
    try std.testing.expectError(error.BadOffsets, fixture.parse(a, bad_payload_wrap));
}

test "fixture: a record round-trips byte-for-byte, including every field" {
    const a = std.testing.allocator;

    const original = command.Command{
        .kind = .draw_textured_triangle,
        .opcode = 0x2C,
        .transparent = 1,
        .value = 0x00AA_BBCC,
        .clut = 0x1234,
        .tpage = 0x5678,
        .x = -12345,
        .y = 6789,
        .x2 = -1,
        .y2 = 2147483647,
        .w = -2147483648,
        .h = 42,
        .v = .{
            .{ .x = -100, .y = 200, .u = 1, .v = 2, .color = 0x0011_2233 },
            .{ .x = 300, .y = -400, .u = 3, .v = 4, .color = 0x0044_5566 },
            .{ .x = -32768, .y = 32767, .u = 5, .v = 6, .color = 0x0077_8899 },
        },
    };

    var w = fixture.Writer.empty;
    defer w.deinit(a);
    const recs = [_]command.Command{original};
    try w.addFrame(a, .{ .records = &recs, .payload = &.{}, .complete = true }, 0);

    const bytes = try w.serialize(a);
    defer a.free(bytes);

    const p = try fixture.parse(a, bytes);
    defer p.deinit(a);

    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&original),
        std.mem.asBytes(&p.records[0]),
    );
}

test "fixture: envSyncRecords reproduces every field of a non-default DrawingEnv" {
    const DrawingEnv = ps1.gpu.Regs.DrawingEnv;

    // Every one of the seven fields is deliberately non-default, including
    // texture_disable_allowed = true and bit 11 set in draw_mode — the two
    // fields the ordering test below depends on.
    const source = DrawingEnv{
        .draw_mode = 0x0000_0800, // bit 11 (texture disable) set
        .tex_window = 0x1234_5678,
        .area_top_left = 0x0000_0111,
        .area_bot_right = 0x0000_0222,
        .offset = 0x0000_0333,
        .mask_bit = 0x0000_0003,
        .texture_disable_allowed = true,
    };

    const records = env_sync.envSyncRecords(source);

    const vram = try std.testing.allocator.create(ps1.gpu.Vram);
    defer std.testing.allocator.destroy(vram);
    vram.* = .{};

    // Freshly default-constructed, exactly what a from-blank consumer starts
    // replay with.
    var env: DrawingEnv = .{};
    for (records) |cmd| command.execute(cmd, &.{}, vram, &env);

    try std.testing.expectEqual(source.draw_mode, env.draw_mode);
    try std.testing.expectEqual(source.tex_window, env.tex_window);
    try std.testing.expectEqual(source.area_top_left, env.area_top_left);
    try std.testing.expectEqual(source.area_bot_right, env.area_bot_right);
    try std.testing.expectEqual(source.offset, env.offset);
    try std.testing.expectEqual(source.mask_bit, env.mask_bit);
    try std.testing.expectEqual(source.texture_disable_allowed, env.texture_disable_allowed);
}

test "fixture: envSyncRecords ordering is load-bearing — set_texture_disable_allowed must replay first" {
    const DrawingEnv = ps1.gpu.Regs.DrawingEnv;

    const source = DrawingEnv{
        .draw_mode = 0x0000_0800, // bit 11 set
        .tex_window = 0x1234_5678,
        .area_top_left = 0x0000_0111,
        .area_bot_right = 0x0000_0222,
        .offset = 0x0000_0333,
        .mask_bit = 0x0000_0003,
        .texture_disable_allowed = true,
    };

    var records = env_sync.envSyncRecords(source);
    // Control: move set_texture_disable_allowed (index 0) to last, so E1's
    // set_draw_env record replays while texture_disable_allowed is still
    // false (the default). `registers.zig`'s `update` masks bit 11 out of
    // draw_mode in that case (`maskTextureDisable`), so the env must NOT be
    // reproduced — this is what pins why the real code emits the flag first.
    const first = records[0];
    var i: usize = 0;
    while (i < records.len - 1) : (i += 1) records[i] = records[i + 1];
    records[records.len - 1] = first;

    const vram = try std.testing.allocator.create(ps1.gpu.Vram);
    defer std.testing.allocator.destroy(vram);
    vram.* = .{};

    var env: DrawingEnv = .{};
    for (records) |cmd| command.execute(cmd, &.{}, vram, &env);

    // Bit 11 came back cleared: draw_mode does not match source.
    try std.testing.expect(env.draw_mode != source.draw_mode);
    try std.testing.expectEqual(
        source.draw_mode & ~@as(u32, 1 << 11),
        env.draw_mode,
    );
    // texture_disable_allowed itself still ends up true — it's the last
    // record replayed, and set_texture_disable_allowed always assigns
    // absolutely regardless of position.
    try std.testing.expectEqual(source.texture_disable_allowed, env.texture_disable_allowed);
}
