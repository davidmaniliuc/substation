//! JINC2's tests: draw with `filter_harness.filterGrid` and assert on the
//! sidecar it returns.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const harness = @import("../harness.zig");
const fh = @import("../filter_harness.zig");
const scale_harness = @import("../scale_harness.zig");
const image_io = @import("../image_io.zig");

const TextureFilter = ps1_metal.prim_instance.TextureFilter;
const check = harness.check;
const alloc = std.testing.allocator;

const red: u16 = 0x001F;
const green: u16 = 0x03E0;

fn expand5(v: u16) u8 {
    const c: u8 = @intCast(v & 0x1F);
    return c << 3 | c >> 2;
}

fn expand(c: u16) [3]u8 {
    return .{ expand5(c), expand5(c >> 5), expand5(c >> 10) };
}

test "jinc2KeepsAUniformOpaqueGridUniformAtEveryScale" {
    const m = try harness.metal();
    defer m.deinit();
    const texel: u16 = 0x2B5A;
    const grid: [36]u16 = @splat(texel);
    for ([_]TextureFilter{ .jinc2, .jinc2_no_edge }) |filter| for ([_]u32{ 1, 2, 3, 4 }) |scale| {
        const g = try fh.filterGrid(m, .{ .texels = &grid, .cols = 6, .scale = scale, .filter = filter });
        defer g.deinit();
        for (0..g.height) |y| for (0..g.width) |x| {
            try check(g.present(x, y) and std.mem.eql(u8, &g.rgb(x, y), &expand(texel)), "{t} @{d}x ({d}, {d}): {any}", .{ filter, scale, x, y, g.rgb(x, y) });
        };
    };
}

test "jinc2LeavesVramOnTheNearestTexel" {
    const m = try harness.metal();
    defer m.deinit();
    const grid = [_]u16{
        red, 0x7C00, 0,      0x03E0,
        0,   red,    0x7FFF, 0x0421,
        red, 0,      red,    0x7C00,
        0,   0x03E0, 0x0421, red,
    };
    for ([_]TextureFilter{ .jinc2, .jinc2_no_edge }) |filter| {
        const g = try fh.filterGrid(m, .{ .texels = &grid, .cols = 4, .scale = 4, .filter = filter });
        defer g.deinit();
        for (0..g.height) |y| for (0..g.width) |x| {
            const want = grid[y / 4 * 4 + x / 4];
            try check(g.vram(x, y) == want, "{t} ({d}, {d}): VRAM {x:0>4}, want {x:0>4}", .{ filter, x, y, g.vram(x, y), want });
        };
    }
}

const dark: u16 = 0x0008;
const bright: u16 = 0x0018;

/// The reds along the middle of a step from `dark` to `bright`, 4x: across a
/// vertical edge when `vertical`, down a horizontal one otherwise.
fn stepLine(m: harness.Metal, filter: TextureFilter, vertical: bool) ![32]u8 {
    var grid: [8 * 8]u16 = undefined;
    for (0..8) |y| for (0..8) |x| {
        grid[y * 8 + x] = if ((if (vertical) x else y) < 4) dark else bright;
    };
    const g = try fh.filterGrid(m, .{ .texels = &grid, .cols = 8, .scale = 4, .filter = filter });
    defer g.deinit();
    var line: [32]u8 = undefined;
    for (&line, 0..) |*o, i| o.* = if (vertical) g.rgb(i, 17)[0] else g.rgb(17, i)[0];
    return line;
}

test "jinc2SoftensAStepAndTheAntiRingingBoundsTheRinging" {
    const m = try harness.metal();
    defer m.deinit();
    const lo: i32 = expand5(dark);
    const hi: i32 = expand5(bright);
    // Without the anti-ringing clamp this step rings 19 levels past both
    // sides; its 0.8 strength leaves a fifth of that.
    const slack = 8;
    for ([_]TextureFilter{ .jinc2, .jinc2_no_edge }) |filter| {
        const row = try stepLine(m, filter, true);
        var between: usize = 0;
        for (row, 0..) |byte, x| {
            const r: i32 = byte;
            try check(r + slack >= lo and r <= hi + slack, "{t} x={d}: {d} rings outside [{d}, {d}]", .{ filter, x, r, lo, hi });
            if (r > lo + slack and r + slack < hi) between += 1;
            if (x <= 8) try check(r == lo, "{t} x={d}: {d}, a long way from the edge", .{ filter, x, r });
            if (x >= 23) try check(r == hi, "{t} x={d}: {d}, a long way from the edge", .{ filter, x, r });
        }
        try check(between >= 4, "{t}: only {d} subtexels between the two colours", .{ filter, between });

        // The edge sits at x = 16 and the step is symmetric about it, so a
        // half-texel slip in the sample point or a mirrored tap breaks this.
        for (0..16) |k| {
            const sum = @as(i32, row[15 - k]) + row[16 + k];
            try check(@abs(sum - (lo + hi)) <= 2, "{t}: x={d} and x={d} sum to {d}", .{ filter, 15 - k, 16 + k, sum });
        }

        // The same step turned on its side filters the same way.
        const col = try stepLine(m, filter, false);
        try check(std.mem.eql(u8, &row, &col), "{t}: the horizontal edge filters differently from the vertical one", .{filter});
    }
}

/// Red on the left half, a hole on the right, over a green fill.
fn holeGrid(m: harness.Metal, filter: TextureFilter) !fh.Grid {
    var grid: [8 * 4]u16 = undefined;
    for (0..4) |y| for (0..8) |x| {
        grid[y * 8 + x] = if (x < 4) red else 0;
    };
    return fh.filterGrid(m, .{ .texels = &grid, .cols = 8, .scale = 4, .filter = filter, .background = green });
}

test "jinc2EdgeBlendingAndNoEdgeDifferOnlyInCoverageAtAHole" {
    const m = try harness.metal();
    defer m.deinit();
    const edge = try holeGrid(m, .jinc2);
    defer edge.deinit();
    const plain = try holeGrid(m, .jinc2_no_edge);
    defer plain.deinit();

    var blended: usize = 0;
    for (4..12) |y| for (0..edge.width) |x| {
        const e = edge.rgb(x, y);
        const p = plain.rgb(x, y);
        try check(p[0] + p[1] == 255 and (p[0] == 0 or p[0] == 255), "no-edge ({d}, {d}) mixes: {any}", .{ x, y, p });
        // The edge variant is the other's colour at some cover in 0...1:
        // both channels must agree on it, or the colour was darkened.
        const cover_r: i32 = e[0];
        const cover_g: i32 = 255 - e[1];
        try check(@abs(cover_r - cover_g) <= 3, "edge ({d}, {d}): {any} is not a blend of the fill and the texel", .{ x, y, e });
        try check(e[0] <= p[0] and e[1] >= p[1], "edge ({d}, {d}): {any} shows more texel than no-edge {any}", .{ x, y, e, p });
        if (p[0] == 0) try check(std.mem.eql(u8, &e, &p), "edge ({d}, {d}): {any} paints where no-edge shows the fill", .{ x, y, e });
        if (e[0] != 0 and e[0] != p[0]) blended += 1;
    };
    try check(blended > 0, "no subtexel blends the fill into the texel", .{});
}

const sprite_size = 16;
const sprite_scale = 6;

/// A diagonal edge, a one-texel line, a ring with a hole in its middle and a
/// checker corner, over transparent.
fn sprite() [sprite_size * sprite_size]u16 {
    var t: [sprite_size * sprite_size]u16 = @splat(0);
    for (0..sprite_size) |y| for (0..sprite_size) |x| {
        const at = &t[y * sprite_size + x];
        if (x < 8 and y < 8 and x + y < 8) at.* = 0x5C20;
        if (y == 10 and x < 8) at.* = 0x03FF;
        if (x >= 8 and y < 8) {
            const dx = @as(i32, @intCast(x)) * 2 - 23;
            const dy = @as(i32, @intCast(y)) * 2 - 7;
            const d2 = dx * dx + dy * dy;
            if (d2 >= 10 and d2 <= 50) at.* = red;
        }
        if (x >= 8 and y >= 8) at.* = if ((x + y) % 2 == 0) 0x7FFF else 0x4210;
    };
    return t;
}

test "jinc2DrawsTheEyeballImage" {
    if (scale_harness.gateSwitch("PS1_FILTER_DUMP") == null) return error.SkipZigTest;
    const m = try harness.metal();
    defer m.deinit();
    const texels = sprite();
    const filters = [_]TextureFilter{ .nearest, .jinc2, .jinc2_no_edge };
    const side = sprite_size * sprite_scale;
    const gap = 8;
    const width = filters.len * side + (filters.len - 1) * gap;
    const rgba = try alloc.alloc(u8, width * side * 4);
    defer alloc.free(rgba);
    @memset(rgba, 255);
    for (filters, 0..) |filter, n| {
        const g = try fh.filterGrid(m, .{ .texels = &texels, .cols = sprite_size, .scale = sprite_scale, .filter = filter, .background = 0x1084 });
        defer g.deinit();
        for (0..side) |y| for (0..side) |x| {
            const rgb = if (g.present(x, y)) g.rgb(x, y) else expand(g.vram(x, y));
            @memcpy(rgba[(y * width + n * (side + gap) + x) * 4 ..][0..3], &rgb);
        };
    }
    const path = "/private/tmp/claude-501/-Users-david-Documents-develop-substation/ee0612e2-d935-40e3-9807-dffcf08b94d6/scratchpad/filters/jinc2.png";
    try image_io.writeRgba(path, rgba, width, side);
}
