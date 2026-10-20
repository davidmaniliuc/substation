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

const WriteCursor = ps1_core.gpu.WriteCursor;

test "WriteCursor: a zero extent means the whole axis" {
    const t = WriteCursor.setup(0, 0, 0, 0);
    try expectEqual(@as(usize, 1024), t.w);
    try expectEqual(@as(usize, 512), t.h);
    try expectEqual(@as(usize, 1024 * 512), t.pixelCount());
    const u = WriteCursor.setup(0, 0, 7, 0);
    try expectEqual(@as(usize, 7), u.w);
    try expectEqual(@as(usize, 512), u.h);
}

test "WriteCursor: each word is two pixels in row-major order" {
    var t = WriteCursor.setup(10, 20, 3, 2);
    try expect(t.active);
    try expectEqual(@as(usize, 6), t.pixelCount());
    const a = t.plan(1).?;
    try expectEqual(@as(usize, 0), a.first);
    try expectEqual(@as(usize, 1), a.last);
    const b = t.plan(1).?;
    try expectEqual(@as(usize, 2), b.first);
    try expectEqual(@as(usize, 3), b.last);
}

test "WriteCursor: the final half word of an odd sized run is dropped" {
    var t = WriteCursor.setup(0, 0, 3, 1);
    _ = t.plan(1).?;
    const last = t.plan(1).?;
    try expectEqual(@as(usize, 2), last.first);
    try expectEqual(@as(usize, 2), last.last);
    try expect(!t.active);
}

test "WriteCursor: words after the transfer ends are ignored" {
    var t = WriteCursor.setup(0, 0, 2, 1);
    _ = t.plan(1).?;
    try expect(!t.active);
    try expect(t.plan(1) == null);
}

test "WriteCursor: abort stops the transfer mid flight" {
    var t = WriteCursor.setup(0, 0, 8, 8);
    _ = t.plan(1).?;
    t.abort();
    try expect(!t.active);
    try expect(t.plan(1) == null);
}

test "WriteCursor: plan reports the contiguous pixel run a word batch covers" {
    var t = WriteCursor.setup(4, 8, 5, 3);
    const a = t.plan(3).?;
    try expect(a.first == 0 and a.last == 5 and a.consumed == 3);
    const b = t.plan(100).?;
    try expect(b.first == 6 and b.last == 14 and b.consumed == 5);
    try expect(!t.active);
    try expect(t.plan(1) == null);
    var z = WriteCursor.setup(0, 0, 1, 1);
    try expect(z.plan(0) == null);
}

test "WriteCursor: plan agrees with Vram.writeData on where the cursor ends up" {
    const alloc = std.testing.allocator;
    const vram = try alloc.create(Vram);
    defer alloc.destroy(vram);

    const Case = struct { w: usize, h: usize };
    var cases: std.ArrayList(Case) = .empty;
    defer cases.deinit(alloc);
    for (1..6) |w| for (1..5) |h| try cases.append(alloc, .{ .w = w, .h = h });
    try cases.appendSlice(alloc, &.{ .{ .w = 0, .h = 1 }, .{ .w = 1024, .h = 1 }, .{ .w = 3, .h = 512 } });

    const touched = try alloc.alloc(bool, constants.vram_width * constants.vram_height);
    defer alloc.free(touched);
    const planned = try alloc.alloc(bool, constants.vram_width * constants.vram_height);
    defer alloc.free(planned);

    for (cases.items) |c| for ([_]usize{ 1, 2, 3, 7 }) |batch| {
        vram.* = .{};
        @memset(planned, false);
        var cur = WriteCursor.setup(0, 0, @intCast(c.w), @intCast(c.h));
        vram.setupWrite(0, 0, c.w, c.h);
        try expectEqual(vram.write_active, cur.active);

        const total_words = Vram.transferWords(c.w, c.h);
        var fed: usize = 0;
        var next_pixel: usize = 0;
        while (fed < total_words + 2 * batch) : (fed += batch) {
            for (0..batch) |_| vram.writeData(0x0001_0001, .{});
            if (cur.plan(batch)) |run| {
                try expectEqual(next_pixel, run.first);
                try expect(run.first % 2 == 0);
                for (run.first..run.last + 1) |i| planned[(i / cur.w) * constants.vram_width + i % cur.w] = true;
                next_pixel = run.last + 1;
            }
            try expectEqual(vram.write_active, cur.active);
        }
        for (touched, 0..) |*t, i| t.* = vram.data[i] != 0;
        try std.testing.expectEqualSlices(bool, touched, planned);
        try expectEqual(cur_pixels(c.w, c.h), next_pixel);
    };
}

fn cur_pixels(w: usize, h: usize) usize {
    return (if (w == 0) 1024 else w) * (if (h == 0) 512 else h);
}
