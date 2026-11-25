//! Interlaced rendering on the Metal side: a record that carries a field
//! writes only that field's native rows, at every internal resolution. No
//! fixture in the corpus carries the bits, so these hand-built frames are the
//! only gate on the shader's row skip.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const ps1_core = @import("ps1_core");
const harness = @import("harness.zig");

const pi = ps1_metal.prim_instance;
const command = ps1_core.gpu.command;
const Command = command.Command;
const Rows = ps1_core.gpu.Rows;
const vtx = harness.vtx;

const alloc = std.testing.allocator;
const native_width = pi.native_width;

const page_x = 256;
const page_y = 256;
const tpage: u16 = (2 << 7) | (1 << 4) | 4; // 16bpp at (256, 256)

/// Every texel non-zero, so no texel is a hole and the textured draws paint
/// whatever rows they are allowed.
const texture_words: [64 * 64 / 2]u32 = blk: {
    @setEvalBranchQuota(10_000);
    var w: [64 * 64 / 2]u32 = undefined;
    for (&w, 0..) |*word, i| word.* = (0x4000 + 2 * i) | ((0x4000 + 2 * i + 1) << 16);
    break :blk w;
};

const draws_end = 128;

/// One of each kind a field restricts, over rows 0..127, and a
/// semi-transparent rectangle over the fill, which reads its destination.
fn frameRecords(out: *[14]Command, rows: Rows) []const Command {
    const head = [_]Command{
        harness.fullDrawingArea(),
        .{ .kind = .vram_write_setup, .x = page_x, .y = page_y, .w = 64, .h = 64 },
        .{ .kind = .vram_write_data, .x = 0, .y = texture_words.len },
    };
    @memcpy(out[0..head.len], &head);
    const body = [_]Command{
        .{ .kind = .fill_rect, .x = 4, .y = 100, .w = 48, .h = 20, .value = 0x1234 },
        .{ .kind = .draw_rectangle, .x = 10, .y = 103, .w = 20, .h = 11, .value = 0x7FE0, .transparent = 1 },
        .{ .kind = .draw_triangle, .value = 0x7FFF, .v = .{ vtx(2, 3, 0, 0, 0), vtx(50, 9, 0, 0, 0), vtx(20, 60, 0, 0, 0) } },
        .{ .kind = .draw_shaded_triangle, .v = .{ vtx(60, 3, 0, 0, 0x0000FF), vtx(110, 9, 0, 0, 0x00FF00), vtx(80, 60, 0, 0, 0xFF0000) } },
        .{ .kind = .draw_textured_triangle, .opcode = 0x25, .clut = 0, .tpage = tpage, .v = .{ vtx(120, 3, 0, 0, 0xFFFFFF), vtx(170, 9, 40, 0, 0xFFFFFF), vtx(140, 60, 10, 40, 0xFFFFFF) } },
        .{ .kind = .draw_textured_rectangle, .opcode = 0x65, .tpage = tpage, .x = 180, .y = 6, .w = 30, .h = 21, .value = 0x7FFF, .v = .{ vtx(0, 0, 3, 4, 0), vtx(0, 0, 0, 0, 0), vtx(0, 0, 0, 0, 0) } },
        .{ .kind = .draw_line, .value = 0x7FFF, .v = .{ vtx(2, 70, 0, 0, 0), vtx(40, 96, 0, 0, 0), vtx(0, 0, 0, 0, 0) } },
        .{ .kind = .draw_shaded_line, .v = .{ vtx(60, 70, 0, 0, 0x0000FF), vtx(100, 96, 0, 0, 0xFF0000), vtx(0, 0, 0, 0, 0) } },
    };
    @memcpy(out[head.len..][0..body.len], &body);
    const all = out[0 .. head.len + body.len];
    for (all[head.len..]) |*c| command.restrict(c, rows);
    return all;
}

fn paintedRows(pixels: []const u16, parity: usize) usize {
    var n: usize = 0;
    for (0..draws_end) |y| {
        for (pixels[y * native_width ..][0..native_width]) |p| {
            if (p != 0 and y & 1 == parity) n += 1;
        }
    }
    return n;
}

test "aFieldRestrictedFrameMatchesTheSoftwareRasterizerAtOneX" {
    const m = try harness.metal();
    defer m.deinit();

    for ([_]Rows{ .all, .even, .odd }) |rows| {
        var buf: [14]Command = undefined;
        const records = frameRecords(&buf, rows);
        const soft = try harness.softwareFrame(alloc, &texture_words, records);
        defer alloc.destroy(soft);
        const gpu = try harness.frameOf(alloc, m, 1, .{ .payload = &texture_words }, records);
        defer gpu.deinit(alloc);

        if (!std.mem.eql(u16, &soft.data, gpu.native)) {
            var diffs: [6]harness.Difference = undefined;
            std.debug.print("rows {s}: Metal differs from the software rasterizer\n", .{@tagName(rows)});
            for (harness.firstDifferences(&soft.data, gpu.native, &diffs)) |d| {
                std.debug.print("  ({d},{d}) software {X:0>4} metal {X:0>4}\n", .{ d.x, d.y, d.want, d.got });
            }
            return error.TestUnexpectedResult;
        }

        const even = paintedRows(gpu.native, 0);
        const odd = paintedRows(gpu.native, 1);
        switch (rows) {
            .all => try std.testing.expect(even > 0 and odd > 0),
            .even => try std.testing.expect(even > 0 and odd == 0),
            .odd => try std.testing.expect(odd > 0 and even == 0),
        }
    }
}

test "aSkippedNativeRowIsUnpaintedAtEverySubtexelAndAKeptRowIsWhatAnUnrestrictedDrawMakes" {
    const m = try harness.metal();
    defer m.deinit();

    for (harness.scale_ladder) |scale| {
        var all_buf: [14]Command = undefined;
        const all = try harness.frameOf(alloc, m, scale, .{ .payload = &texture_words }, frameRecords(&all_buf, .all));
        defer all.deinit(alloc);

        for ([_]Rows{ .even, .odd }) |rows| {
            var buf: [14]Command = undefined;
            const f = try harness.frameOf(alloc, m, scale, .{ .payload = &texture_words }, frameRecords(&buf, rows));
            defer f.deinit(alloc);
            const kept: usize = if (rows == .even) 0 else 1;

            var kept_painted: usize = 0;
            for (0..draws_end * scale) |py| {
                const row = f.scaled[py * f.width ..][0..f.width];
                if ((py / scale) & 1 == kept) {
                    try std.testing.expectEqualSlices(u16, all.scaled[py * f.width ..][0..f.width], row);
                    for (row) |p| kept_painted += @intFromBool(p != 0);
                } else {
                    for (row, 0..) |p, x| {
                        if (p != 0) {
                            std.debug.print("{s} @{d}x: skipped row {d} painted at subpixel ({d},{d})\n", .{ @tagName(rows), scale, py / scale, x, py });
                            return error.TestUnexpectedResult;
                        }
                    }
                }
            }
            try std.testing.expect(kept_painted > 0);
        }
    }
}

test "aFieldRecordKeepsItsRowsWhateverTheDrawingOffset" {
    const m = try harness.metal();
    defer m.deinit();

    // The row that decides is the ABSOLUTE VRAM row, offset applied: an odd
    // offset turns a rectangle's local row 0 into row 1.
    const records = [_]Command{
        harness.fullDrawingArea(),
        harness.env(0xE5, 1 << 11),
        .{ .kind = .draw_rectangle, .x = 0, .y = 0, .w = 4, .h = 4, .value = 0x7FFF },
    };
    var even = records;
    command.restrict(&even[2], .even);
    for ([_]u32{ 1, 2, 4 }) |scale| {
        const f = try harness.frameOf(alloc, m, scale, .{}, &even);
        defer f.deinit(alloc);
        for (0..8) |y| {
            const want: u16 = if (y == 2 or y == 4) 0x7FFF else 0;
            try std.testing.expectEqual(want, f.native[y * native_width]);
        }
    }
}
