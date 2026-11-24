//! xBR's tests: draw with `filter_harness.filterGrid` and assert on the
//! sidecar it returns.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const harness = @import("../harness.zig");
const fh = @import("../filter_harness.zig");
const image_io = @import("../image_io.zig");

const TextureFilter = ps1_metal.prim_instance.TextureFilter;
const check = harness.check;

const red: u16 = 0x001F;
const green: u16 = 0x03E0;
const blue: u16 = 0x7C00;
const yellow: u16 = 0x03FF;
const white: u16 = 0x7FFF;
const grey: u16 = 0x2108;

const both = [_]TextureFilter{ .xbr, .xbr_no_edge };

fn expand(c: u16) [3]u8 {
    var out: [3]u8 = undefined;
    for (&out, 0..) |*o, i| {
        const v: u8 = @intCast((c >> @intCast(5 * i)) & 0x1F);
        o.* = v << 3 | v >> 2;
    }
    return out;
}

/// An `n` x `n` grid, `lit` where `x + y >= n - 1` and `unlit` elsewhere: a
/// one-texel staircase along the anti-diagonal.
fn staircase(comptime n: usize, lit: u16, unlit: u16) [n * n]u16 {
    var grid: [n * n]u16 = undefined;
    for (0..n) |y| for (0..n) |x| {
        grid[y * n + x] = if (x + y >= n - 1) lit else unlit;
    };
    return grid;
}

fn isBlueish(c: [3]u8) bool {
    return c[2] >= c[0];
}

test "aUniformGridFiltersToItselfAtEveryScale" {
    const m = try harness.metal();
    defer m.deinit();
    const grid: [25]u16 = @splat(green);
    for (both) |filter| for ([_]u32{ 1, 2, 3, 4 }) |scale| {
        const g = try fh.filterGrid(m, .{ .texels = &grid, .cols = 5, .scale = scale, .filter = filter });
        defer g.deinit();
        for (0..g.height) |y| for (0..g.width) |x| {
            try check(g.present(x, y) and std.mem.eql(u8, &g.rgb(x, y), &expand(green)), "{t} @{d}x ({d}, {d}): {any}, want the texel", .{ filter, scale, x, y, g.rgb(x, y) });
        };
    };
}

test "vramStaysTheNearestTexelWhateverXbrDraws" {
    const m = try harness.metal();
    defer m.deinit();
    const grid = staircase(8, blue, red);
    for (both) |filter| {
        const g = try fh.filterGrid(m, .{ .texels = &grid, .cols = 8, .scale = 4, .filter = filter });
        defer g.deinit();
        for (0..g.height) |y| for (0..g.width) |x| {
            const want = grid[(y / 4) * 8 + x / 4];
            try check(g.vram(x, y) == want, "{t} ({d}, {d}): VRAM {x:0>4}, want {x:0>4}", .{ filter, x, y, g.vram(x, y), want });
        };
    }
}

test "aOneTexelStaircaseBecomesASmoothDiagonal" {
    const m = try harness.metal();
    defer m.deinit();
    const grid = staircase(8, blue, red);
    for (both) |filter| {
        const g = try fh.filterGrid(m, .{ .texels = &grid, .cols = 8, .scale = 4, .filter = filter });
        defer g.deinit();

        // Nearest steps four subtexels every four rows; the diagonal steps
        // one subtexel every row. Rows near the grid's border have no
        // staircase left to smooth.
        var prev: ?usize = null;
        for (3..26) |y| {
            var first: ?usize = null;
            for (0..g.width) |x| {
                const blueish = isBlueish(g.rgb(x, y));
                if (first == null and blueish) first = x;
                try check(first == null or blueish, "{t} row {d}: the edge turns back at {d}", .{ filter, y, x });
            }
            try check(first != null, "{t} row {d}: no blue", .{ filter, y });
            if (prev) |p| try check(p == first.? + 1, "{t} rows {d}-{d}: the edge moves {d} -> {d}, not one subtexel", .{ filter, y - 1, y, p, first.? });
            prev = first;
        }

        var changed: usize = 0;
        for (0..g.height) |y| for (0..g.width) |x| {
            const want = expand(grid[(y / 4) * 8 + x / 4]);
            if (!std.mem.eql(u8, &g.rgb(x, y), &want)) changed += 1;
            // A texel's own centre is never repainted, border texels aside:
            // their neighbours past the grid are clamped copies.
            if (x % 4 >= 1 and x % 4 <= 2 and y % 4 >= 1 and y % 4 <= 2 and x >= 4 and y >= 4 and x < 28 and y < 28)
                try check(std.mem.eql(u8, &g.rgb(x, y), &want), "{t} ({d}, {d}): a texel centre changed", .{ filter, x, y });
        };
        try check(changed > 0, "{t}: nothing changed relative to nearest", .{filter});
    }
}

test "theDiagonalIsTheSameFromEveryCorner" {
    // The staircase is symmetric under a transpose, and a left-right mirror
    // of it is the other diagonal: a quadrant or a branch taken the wrong
    // way round breaks one of them.
    const m = try harness.metal();
    defer m.deinit();
    const grid = staircase(8, blue, red);
    var mirrored: [64]u16 = undefined;
    for (0..8) |y| for (0..8) |x| {
        mirrored[y * 8 + x] = grid[y * 8 + 7 - x];
    };
    for (both) |filter| {
        const a = try fh.filterGrid(m, .{ .texels = &grid, .cols = 8, .scale = 4, .filter = filter });
        defer a.deinit();
        const b = try fh.filterGrid(m, .{ .texels = &mirrored, .cols = 8, .scale = 4, .filter = filter });
        defer b.deinit();
        for (0..a.height) |y| for (0..a.width) |x| {
            try check(std.mem.eql(u8, &a.rgb(x, y), &a.rgb(y, x)), "{t} ({d}, {d}): not symmetric under a transpose", .{ filter, x, y });
            try check(std.mem.eql(u8, &a.rgb(x, y), &b.rgb(a.width - 1 - x, y)), "{t} ({d}, {d}): the mirrored diagonal differs", .{ filter, x, y });
        };
    }
}

test "aStraightEdgeIsNotBent" {
    const m = try harness.metal();
    defer m.deinit();
    var horizontal: [64]u16 = undefined;
    var vertical: [64]u16 = undefined;
    for (0..8) |y| for (0..8) |x| {
        horizontal[y * 8 + x] = if (y >= 4) blue else red;
        vertical[y * 8 + x] = if (x >= 3) blue else red;
    };
    for (both) |filter| for ([_]u32{ 2, 3, 4 }) |scale| for ([_][]const u16{ &horizontal, &vertical }) |grid| {
        const g = try fh.filterGrid(m, .{ .texels = grid, .cols = 8, .scale = scale, .filter = filter });
        defer g.deinit();
        for (0..g.height) |y| for (0..g.width) |x| {
            const want = expand(grid[(y / scale) * 8 + x / scale]);
            try check(std.mem.eql(u8, &g.rgb(x, y), &want), "{t} @{d}x ({d}, {d}): {any}, a straight edge moved", .{ filter, scale, x, y, g.rgb(x, y) });
        };
    };
}

test "aHoleCornerIsPaintedAndAnOpaqueCornerIsCutAndVramKeepsTheConsolesEdge" {
    // Opaque blue past the anti-diagonal, a hole before it, over green. At
    // the staircase's corners the diagonal passes through the texels: the
    // hole texel (3, 3) has its far corner painted blue and the blue texel
    // (4, 3) its near corner shown as the background, while VRAM keeps the
    // nearest texel in both.
    const m = try harness.metal();
    defer m.deinit();
    const grid = staircase(8, blue, 0);
    for (both) |filter| {
        const g = try fh.filterGrid(m, .{ .texels = &grid, .cols = 8, .scale = 4, .filter = filter, .background = green });
        defer g.deinit();

        try check(g.vram(15, 15) == green, "{t}: the hole's VRAM is {x:0>4}", .{ filter, g.vram(15, 15) });
        try check(g.present(15, 15) and std.mem.eql(u8, &g.rgb(15, 15), &expand(blue)), "{t}: the hole's far corner is {any}, want blue", .{ filter, g.rgb(15, 15) });

        try check(g.vram(16, 12) == blue, "{t}: the texel's VRAM is {x:0>4}", .{ filter, g.vram(16, 12) });
        try check(std.mem.eql(u8, &g.rgb(16, 12), &expand(green)), "{t}: the texel's near corner is {any}, want the background", .{ filter, g.rgb(16, 12) });

        // And the far side of the hole, nowhere near the edge, shows the fill.
        try check(std.mem.eql(u8, &g.rgb(2, 2), &expand(green)), "{t}: the hole far from the edge is {any}", .{ filter, g.rgb(2, 2) });
    }
}

test "onlyTheEdgeBlendingVariantMixesTheBackgroundIntoACutOutEdge" {
    const m = try harness.metal();
    defer m.deinit();
    const grid = staircase(8, blue, 0);
    const fill = expand(green);
    const ink = expand(blue);
    for (both) |filter| {
        const g = try fh.filterGrid(m, .{ .texels = &grid, .cols = 8, .scale = 4, .filter = filter, .background = green });
        defer g.deinit();
        var mixed: usize = 0;
        for (0..g.height) |y| for (0..g.width) |x| {
            const c = g.rgb(x, y);
            if (std.mem.eql(u8, &c, &fill) or std.mem.eql(u8, &c, &ink)) continue;
            // Strictly between the two, channel by channel.
            try check(c[1] > 0 and c[1] < fill[1] and c[2] > 0 and c[2] < ink[2], "{t} ({d}, {d}): {any} is neither colour nor between them", .{ filter, x, y, c });
            mixed += 1;
        };
        if (filter == .xbr) {
            try check(mixed > 0, "xbr: no partially covered subtexel", .{});
        } else {
            try check(mixed == 0, "xbr_no_edge: {d} subtexels are mixed", .{mixed});
        }
    }
}

/// A 16 x 16 sprite: a diagonal edge, a one-texel line, a ring around a hole
/// and a two-colour checker corner, on a transparent field.
fn sprite() [256]u16 {
    var s: [256]u16 = @splat(0);
    for (0..8) |y| for (0..8) |x| {
        if (x >= y) s[y * 16 + x] = yellow;
    };
    for (9..16) |x| s[2 * 16 + x] = red;
    for (4..8) |y| s[y * 16 + 9] = red;
    for (8..16) |y| for (0..8) |x| {
        const dx = @as(i32, @intCast(x)) * 2 - 7;
        const dy = (@as(i32, @intCast(y)) - 8) * 2 - 7;
        const d2 = dx * dx + dy * dy;
        if (d2 >= 16 and d2 <= 60) s[y * 16 + x] = blue;
    };
    for (8..16) |y| for (8..16) |x| {
        s[y * 16 + x] = if ((x + y) % 2 == 0) red else white;
    };
    return s;
}

test "dumpTheSpriteUnderXbr" {
    const dir = harness.gateSwitch("PS1_FILTER_DUMP") orelse return error.SkipZigTest;
    const m = try harness.metal();
    defer m.deinit();
    const grid = sprite();
    var dir_z: [512]u8 = undefined;
    const out_dir = if (std.mem.eql(u8, dir, "1")) "zig-out/filters" else dir;
    @memcpy(dir_z[0..out_dir.len], out_dir);
    dir_z[out_dir.len] = 0;
    _ = std.c.mkdir(@ptrCast(&dir_z), 0o755);

    for (both) |filter| {
        const g = try fh.filterGrid(m, .{ .texels = &grid, .cols = 16, .scale = 6, .filter = filter, .background = grey });
        defer g.deinit();
        const rgba = try std.testing.allocator.alloc(u8, g.width * g.height * 4);
        defer std.testing.allocator.free(rgba);
        for (0..g.height) |y| for (0..g.width) |x| {
            const c = if (g.present(x, y)) g.rgb(x, y) else expand(g.vram(x, y));
            rgba[(y * g.width + x) * 4 ..][0..4].* = .{ c[0], c[1], c[2], 255 };
        };
        const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}.png", .{ out_dir, if (filter == .xbr) "xbr" else "xbr-no-edge" });
        defer std.testing.allocator.free(path);
        try image_io.writeRgba(path, rgba, g.width, g.height);
        std.debug.print("[filters] {s}\n", .{path});
    }
}
