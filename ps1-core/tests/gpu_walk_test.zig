const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;
const ps1_core = @import("ps1_core");
const LineWalk = ps1_core.gpu.LineWalk;
const Renderer = ps1_core.gpu.Renderer;
const Vram = ps1_core.gpu.Vram;
const Regs = ps1_core.gpu.Regs;
const constants = ps1_core.constants;

test "LineWalk: a horizontal line is one pixel per column, inclusive" {
    var w = LineWalk.init(10, 5, 14, 5).?;
    try expectEqual(@as(i32, 4), w.steps);
    var k: i32 = 0;
    while (w.next()) |s| : (k += 1) {
        try expectEqual(10 + k, s.x);
        try expectEqual(@as(i32, 5), s.y);
        try expectEqual(k, s.k);
    }
    try expectEqual(@as(i32, 5), k);
}

test "LineWalk: a zero-length line is exactly one pixel" {
    var w = LineWalk.init(3, 3, 3, 3).?;
    try expectEqual(@as(i32, 0), w.steps);
    const s = w.next().?;
    try expectEqual(@as(i32, 3), s.x);
    try expectEqual(@as(i32, 3), s.y);
    try expectEqual(@as(i32, 0), s.k);
    try expect(w.next() == null);
}

test "LineWalk: all eight octants end on their endpoint" {
    const deltas = [_][2]i32{ .{ 9, 2 }, .{ 2, 9 }, .{ -2, 9 }, .{ -9, 2 }, .{ -9, -2 }, .{ -2, -9 }, .{ 2, -9 }, .{ 9, -2 } };
    for (deltas) |d| {
        var w = LineWalk.init(50, 50, 50 + d[0], 50 + d[1]).?;
        const total = @max(@abs(d[0]), @abs(d[1]));
        try expectEqual(@as(i32, @intCast(total)), w.steps);
        var count: i32 = 0;
        var last: LineWalk.Step = undefined;
        while (w.next()) |s| : (count += 1) last = s;
        try expectEqual(w.steps + 1, count);
        try expectEqual(50 + d[0], last.x);
        try expectEqual(50 + d[1], last.y);
        try expectEqual(w.steps, last.k);
    }
}

test "LineWalk: an oversized line is dropped, not clipped" {
    try expect(LineWalk.init(0, 0, 1024, 0) == null);
    try expect(LineWalk.init(0, 0, 0, 512) == null);
    try expect(LineWalk.init(0, 0, 1023, 511) != null);
}

test "LineWalk: the walk visits what drawLine paints" {
    const vram = try std.testing.allocator.create(Vram);
    defer std.testing.allocator.destroy(vram);
    var env: Regs.DrawingEnv = .{};
    env.area_top_left = 0;
    env.area_bot_right = 1023 | (@as(u32, 511) << 10);

    var prng = std.Random.DefaultPrng.init(0x11E);
    const rnd = prng.random();
    var n: usize = 0;
    while (n < 200) : (n += 1) {
        vram.* = .{};
        const x0 = rnd.intRangeAtMost(i16, -1100, 1100);
        const y0 = rnd.intRangeAtMost(i16, -1100, 1100);
        const x1 = rnd.intRangeAtMost(i16, -1100, 1100);
        const y1 = rnd.intRangeAtMost(i16, -1100, 1100);
        Renderer.drawLine(vram, &env, x0, y0, x1, y1, 0x7FFF, false);

        var expected = try std.testing.allocator.alloc(bool, constants.vram_width * constants.vram_height);
        defer std.testing.allocator.free(expected);
        @memset(expected, false);
        if (LineWalk.init(x0, y0, x1, y1)) |start| {
            var w = start;
            while (w.next()) |s| {
                if (s.x < 0 or s.x >= constants.vram_width or s.y < 0 or s.y >= constants.vram_height) continue;
                expected[Vram.index(@intCast(s.x), @intCast(s.y))] = true;
            }
        }
        for (expected, 0..) |e, i| try expectEqual(e, vram.data[i] == 0x7FFF);
    }
}
