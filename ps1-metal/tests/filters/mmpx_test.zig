//! MMPX's tests: draw with `filter_harness.filterGrid` and assert on the
//! sidecar it returns.

const std = @import("std");
const harness = @import("../harness.zig");
const fh = @import("../filter_harness.zig");
const image_io = @import("../image_io.zig");

const alloc = std.testing.allocator;
const check = harness.check;

const red: u16 = 0x001F;
const green: u16 = 0x03E0;
const blue: u16 = 0x7C00;
const yellow: u16 = 0x03FF;
const grey: u16 = 0x0421;

fn expand(c: u16) [3]u8 {
    var out: [3]u8 = undefined;
    for (&out, 0..) |*o, i| {
        const v: u8 = @intCast((c >> @intCast(5 * i)) & 0x1F);
        o.* = v << 3 | v >> 2;
    }
    return out;
}

/// `n` x `n` texels, `pick(column, row)` each.
fn gridOf(comptime n: usize, comptime pick: fn (usize, usize) u16) [n * n]u16 {
    var g: [n * n]u16 = undefined;
    for (0..n) |y| for (0..n) |x| {
        g[y * n + x] = pick(x, y);
    };
    return g;
}

fn staircase(x: usize, y: usize) u16 {
    return if (x >= y) blue else red;
}

fn verticalLine(x: usize, _: usize) u16 {
    return if (x == 3) blue else red;
}

fn antiDiagonalOverHoles(x: usize, y: usize) u16 {
    return if (x + y == 3) blue else 0;
}

fn mixed(x: usize, y: usize) u16 {
    const palette = [_]u16{ red, green, blue, yellow };
    if (x == y) return palette[0];
    if ((x + y) % 5 == 0) return palette[1];
    if (x > 4 and y < 3) return palette[2 + (x + y) % 2];
    return palette[(x / 2 + y / 3) % 4];
}

test "aUniformGridFiltersToItselfAtEveryScale" {
    const m = try harness.metal();
    defer m.deinit();
    const grid: [25]u16 = @splat(0x2D6B);
    for ([_]u32{ 1, 2, 3, 4 }) |scale| {
        const g = try fh.filterGrid(m, .{ .texels = &grid, .cols = 5, .scale = scale, .filter = .mmpx });
        defer g.deinit();
        for (0..g.height) |y| for (0..g.width) |x| {
            try check(g.present(x, y) and std.mem.eql(u8, &g.rgb(x, y), &expand(0x2D6B)), "{d}x ({d}, {d}): a uniform grid changed to {any}", .{ scale, x, y, g.rgb(x, y) });
        };
    }
}

test "vramStaysOnTheNearestTexel" {
    const m = try harness.metal();
    defer m.deinit();
    const grid = gridOf(6, staircase);
    const g = try fh.filterGrid(m, .{ .texels = &grid, .cols = 6, .scale = 4, .filter = .mmpx });
    defer g.deinit();
    for (0..g.height) |y| for (0..g.width) |x| {
        const want = grid[(y / 4) * 6 + x / 4];
        try check(g.vram(x, y) == want, "({d}, {d}): VRAM {x:0>4}, want {x:0>4}", .{ x, y, g.vram(x, y), want });
    };
}

test "aStaircaseGetsItsCornersFilled" {
    // Blue where column >= row, red below it. Worked by hand from the rules:
    // the red texel (2, 3) takes blue in its top-right quarter (1:1 slope
    // rule K) and the blue texel (3, 3) takes red in its bottom-left one
    // (rule L). Every other quarter of both keeps its texel's colour.
    const m = try harness.metal();
    defer m.deinit();
    const grid = gridOf(6, staircase);
    for ([_]u32{ 2, 4 }) |scale| {
        const g = try fh.filterGrid(m, .{ .texels = &grid, .cols = 6, .scale = scale, .filter = .mmpx });
        defer g.deinit();
        const half = scale / 2;
        for (0..scale) |dy| for (0..scale) |dx| {
            const right = dx >= half;
            const bottom = dy >= half;
            const red_texel: u16 = if (right and !bottom) blue else red;
            const blue_texel: u16 = if (!right and bottom) red else blue;
            const rx = 2 * scale + dx;
            const bx = 3 * scale + dx;
            const y = 3 * scale + dy;
            try check(std.mem.eql(u8, &g.rgb(rx, y), &expand(red_texel)), "{d}x red texel ({d}, {d}): {any}", .{ scale, dx, dy, g.rgb(rx, y) });
            try check(std.mem.eql(u8, &g.rgb(bx, y), &expand(blue_texel)), "{d}x blue texel ({d}, {d}): {any}", .{ scale, dx, dy, g.rgb(bx, y) });
        };
    }
}

test "aOneTexelLineIsNotEroded" {
    const m = try harness.metal();
    defer m.deinit();
    const grid = gridOf(7, verticalLine);
    for ([_]u32{ 2, 3, 4 }) |scale| {
        const g = try fh.filterGrid(m, .{ .texels = &grid, .cols = 7, .scale = scale, .filter = .mmpx });
        defer g.deinit();
        for (0..g.height) |y| for (0..g.width) |x| {
            const want: u16 = if (x / scale == 3) blue else red;
            try check(std.mem.eql(u8, &g.rgb(x, y), &expand(want)), "{d}x ({d}, {d}): {any}, want {x:0>4}", .{ scale, x, y, g.rgb(x, y), want });
        };
    }
}

test "onlyTheInputColoursAppearAndSomeMove" {
    const m = try harness.metal();
    defer m.deinit();
    const grid = gridOf(8, mixed);
    for ([_]u32{ 2, 3, 4 }) |scale| {
        const g = try fh.filterGrid(m, .{ .texels = &grid, .cols = 8, .scale = scale, .filter = .mmpx });
        defer g.deinit();
        var moved: usize = 0;
        for (0..g.height) |y| for (0..g.width) |x| {
            const rgb = g.rgb(x, y);
            var known = false;
            for ([_]u16{ red, green, blue, yellow }) |c| known = known or std.mem.eql(u8, &rgb, &expand(c));
            try check(known, "{d}x ({d}, {d}): {any} is no input colour", .{ scale, x, y, rgb });
            if (!std.mem.eql(u8, &rgb, &expand(grid[(y / scale) * 8 + x / scale]))) moved += 1;
        };
        try check(moved > 0, "{d}x: no subtexel differs from nearest", .{scale});
    }
}

test "aHoleBesideAnOpaqueCornerIsPaintedInTheSidecarOnly" {
    // A one-texel blue anti-diagonal over holes, over a grey fill. The hole
    // at (2, 2) has blue above and to its left and a hole in the corner
    // between them, so its top-left quarter takes blue (rule J) in the
    // sidecar while VRAM keeps the fill and its other quarters show the fill.
    const m = try harness.metal();
    defer m.deinit();
    const grid = gridOf(6, antiDiagonalOverHoles);
    const g = try fh.filterGrid(m, .{ .texels = &grid, .cols = 6, .scale = 2, .filter = .mmpx, .background = grey });
    defer g.deinit();
    try check(g.present(4, 4) and std.mem.eql(u8, &g.rgb(4, 4), &expand(blue)), "the hole's top-left quarter is {any}", .{g.rgb(4, 4)});
    try check(g.vram(4, 4) == grey, "VRAM under the painted hole is {x:0>4}", .{g.vram(4, 4)});
    for ([_][2]usize{ .{ 5, 4 }, .{ 4, 5 }, .{ 5, 5 } }) |p| {
        try check(std.mem.eql(u8, &g.rgb(p[0], p[1]), &expand(grey)), "({d}, {d}) of the hole shows {any}, not the fill", .{ p[0], p[1], g.rgb(p[0], p[1]) });
    }
}

test "dumpMmpxSprite" {
    _ = harness.gateSwitch("PS1_FILTER_DUMP") orelse return error.SkipZigTest;
    const m = try harness.metal();
    defer m.deinit();
    const n = 16;
    var sprite: [n * n]u16 = @splat(0);
    for (0..n) |y| for (0..n) |x| {
        const i = y * n + x;
        if (x > y + 1 and y < 7) sprite[i] = blue;
        if (y == 9 and x < 8) sprite[i] = green;
        const dx = @as(i32, @intCast(x)) - 11;
        const dy = @as(i32, @intCast(y)) - 11;
        const d2 = dx * dx + dy * dy;
        if (d2 <= 16 and d2 >= 5) sprite[i] = red;
        if (x < 4 and y >= 12) sprite[i] = if ((x + y) % 2 == 0) yellow else red;
    };
    const g = try fh.filterGrid(m, .{ .texels = &sprite, .cols = n, .scale = 6, .filter = .mmpx, .background = grey });
    defer g.deinit();
    const rgba = try alloc.alloc(u8, g.width * g.height * 4);
    defer alloc.free(rgba);
    for (0..g.height) |y| for (0..g.width) |x| {
        const px = if (g.present(x, y)) g.rgb(x, y) else expand(g.vram(x, y));
        const o = (y * g.width + x) * 4;
        @memcpy(rgba[o..][0..3], &px);
        rgba[o + 3] = 255;
    };
    const dir = "/private/tmp/claude-501/-Users-david-Documents-develop-substation/ee0612e2-d935-40e3-9807-dffcf08b94d6/scratchpad/filters";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try image_io.writeRgba(dir ++ "/mmpx.png", rgba, g.width, g.height);
}
