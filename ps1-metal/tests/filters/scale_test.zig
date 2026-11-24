//! Scale2x and Scale3x's tests: draw with `filter_harness.filterGrid` and assert on the
//! sidecar it returns.
//!
//! Colours are single-channel or white so a sidecar byte names its texel, and every case sits
//! in a 3x3 neighbourhood letter-for-letter as the published algorithm draws it:
//!
//!     A B C
//!     D E F
//!     G H I
//!
//! The texel under test is E, at (1, 1), so its subtexels are the block at (scale, scale).

const std = @import("std");
const harness = @import("../harness.zig");
const fh = @import("../filter_harness.zig");
const image_io = @import("../image_io.zig");

const alloc = std.testing.allocator;

const red: u16 = 0x001F;
const green: u16 = 0x03E0;
const blue: u16 = 0x7C00;
const white: u16 = 0x7FFF;
const yellow: u16 = 0x03FF;

fn rgbOf(t: u16) [3]u8 {
    var out: [3]u8 = undefined;
    for (&out, 0..) |*c, i| {
        const v: u8 = @intCast((t >> @intCast(5 * i)) & 0x1F);
        c.* = (v << 3) | (v >> 2);
    }
    return out;
}

fn expectBlock(g: fh.Grid, x0: usize, y0: usize, w: usize, h: usize, texel: u16) !void {
    const want = rgbOf(texel);
    for (y0..y0 + h) |y| for (x0..x0 + w) |x| {
        if (!g.present(x, y) or !std.mem.eql(u8, &want, &g.rgb(x, y))) {
            std.debug.print("subtexel ({d}, {d}) is {any} present={}, want {any}\n", .{ x, y, g.rgb(x, y), g.present(x, y), want });
            return error.TestExpectedEqual;
        }
    };
}

const Scale2xCase = struct {
    name: []const u8,
    grid: [9]u16,
    /// The quadrant that takes the neighbour's colour: 0 TL (J), 1 TR (K), 2 BL (L), 3 BR (M).
    quadrant: usize,
    neighbour: u16,
};

const scale2x_cases = [_]Scale2xCase{
    .{ .name = "J", .grid = .{ yellow, green, yellow, green, red, blue, yellow, white, yellow }, .quadrant = 0, .neighbour = green },
    .{ .name = "K", .grid = .{ yellow, green, yellow, blue, red, green, yellow, white, yellow }, .quadrant = 1, .neighbour = green },
    .{ .name = "L", .grid = .{ yellow, blue, yellow, green, red, white, yellow, green, yellow }, .quadrant = 2, .neighbour = green },
    .{ .name = "M", .grid = .{ yellow, blue, yellow, white, red, green, yellow, green, yellow }, .quadrant = 3, .neighbour = green },
};

fn expectScale2xQuadrants(g: fh.Grid, scale: usize, case: Scale2xCase) !void {
    const half = scale / 2;
    for (0..4) |q| {
        const texel = if (q == case.quadrant) case.neighbour else red;
        try expectBlock(g, scale + (q % 2) * half, scale + (q / 2) * half, half, half, texel);
    }
}

test "Scale2x: each of the four rules paints exactly its own quadrant" {
    const m = try harness.metal();
    defer m.deinit();
    for (scale2x_cases) |case| for ([_]u32{ 2, 4 }) |scale| {
        const g = try fh.filterGrid(m, .{ .texels = &case.grid, .cols = 3, .scale = scale, .filter = .scale2x });
        defer g.deinit();
        expectScale2xQuadrants(g, scale, case) catch |e| {
            std.debug.print("rule {s} at {d}x\n", .{ case.name, scale });
            return e;
        };
    };
}

test "Scale2x: the triangle path picks the same quadrants" {
    const m = try harness.metal();
    defer m.deinit();
    for (scale2x_cases) |case| {
        const g = try fh.filterGrid(m, .{ .texels = &case.grid, .cols = 3, .shape = .triangles, .magnify = 4, .filter = .scale2x });
        defer g.deinit();
        expectScale2xQuadrants(g, 4, case) catch |e| {
            std.debug.print("rule {s} on triangles\n", .{case.name});
            return e;
        };
    }
}

test "Scale2x: a uniform grid and VRAM stay what nearest draws" {
    const m = try harness.metal();
    defer m.deinit();
    const uniform: [16]u16 = @splat(red);
    for ([_]u32{ 1, 2, 3, 4 }) |scale| {
        const g = try fh.filterGrid(m, .{ .texels = &uniform, .cols = 4, .scale = scale, .filter = .scale2x });
        defer g.deinit();
        try expectBlock(g, 0, 0, g.width, g.height, red);
    }
    const case = scale2x_cases[0];
    const g = try fh.filterGrid(m, .{ .texels = &case.grid, .cols = 3, .scale = 4, .filter = .scale2x });
    defer g.deinit();
    for (0..g.height) |y| for (0..g.width) |x| {
        const texel = case.grid[(y / 4) * 3 + x / 4];
        try std.testing.expectEqual(texel, g.vram(x, y));
    };
}

test "Scale2x: a hole quadrant is left unpainted while VRAM keeps the nearest texel" {
    const m = try harness.metal();
    defer m.deinit();
    // Rule J with D == B == hole: the top-left quadrant of E becomes a hole.
    const grid = [9]u16{ yellow, 0, yellow, 0, red, blue, yellow, white, yellow };
    const g = try fh.filterGrid(m, .{ .texels = &grid, .cols = 3, .scale = 4, .filter = .scale2x, .background = green });
    defer g.deinit();
    for (4..6) |y| for (4..6) |x| {
        try std.testing.expect(!std.mem.eql(u8, &rgbOf(red), &g.rgb(x, y)) or !g.present(x, y));
        try std.testing.expectEqual(red, g.vram(x, y));
    };
    try expectBlock(g, 6, 4, 2, 4, red);
}

const Scale3xCase = struct {
    name: []const u8,
    grid: [9]u16,
    /// The nine cells E0..E8 of the centre texel, row-major.
    cells: [9]u16,
};

const r = red;
const gr = green;
const scale3x_cases = [_]Scale3xCase{
    .{ .name = "E0", .grid = .{ yellow, gr, r, gr, r, blue, r, white, yellow }, .cells = .{ gr, r, r, r, r, r, r, r, r } },
    .{ .name = "E2", .grid = .{ r, gr, yellow, blue, r, gr, yellow, white, r }, .cells = .{ r, r, gr, r, r, r, r, r, r } },
    .{ .name = "E6", .grid = .{ r, blue, yellow, gr, r, white, yellow, gr, r }, .cells = .{ r, r, r, r, r, r, gr, r, r } },
    .{ .name = "E8", .grid = .{ yellow, blue, r, white, r, gr, r, gr, yellow }, .cells = .{ r, r, r, r, r, r, r, r, gr } },
    .{ .name = "E0+E1", .grid = .{ yellow, gr, yellow, gr, r, blue, r, white, yellow }, .cells = .{ gr, gr, r, r, r, r, r, r, r } },
    .{ .name = "E0+E3", .grid = .{ yellow, gr, r, gr, r, blue, yellow, white, yellow }, .cells = .{ gr, r, r, gr, r, r, r, r, r } },
    .{ .name = "E8+E5", .grid = .{ yellow, blue, yellow, white, r, gr, r, gr, yellow }, .cells = .{ r, r, r, r, r, gr, r, r, gr } },
    .{ .name = "E8+E7", .grid = .{ yellow, blue, r, white, r, gr, yellow, gr, yellow }, .cells = .{ r, r, r, r, r, r, r, gr, gr } },
    .{ .name = "B == H", .grid = .{ yellow, gr, yellow, gr, r, blue, yellow, gr, yellow }, .cells = .{ r, r, r, r, r, r, r, r, r } },
    .{ .name = "D == F", .grid = .{ yellow, gr, yellow, blue, r, blue, yellow, white, yellow }, .cells = .{ r, r, r, r, r, r, r, r, r } },
};

test "Scale3x: each rule paints exactly its own thirds" {
    const m = try harness.metal();
    defer m.deinit();
    for (scale3x_cases) |case| for ([_]usize{ 3, 6 }) |scale| {
        const g = try fh.filterGrid(m, .{ .texels = &case.grid, .cols = 3, .scale = @intCast(scale), .filter = .scale3x });
        defer g.deinit();
        const third = scale / 3;
        for (case.cells, 0..) |texel, c| {
            expectBlock(g, scale + (c % 3) * third, scale + (c / 3) * third, third, third, texel) catch |e| {
                std.debug.print("case {s} cell E{d} at {d}x\n", .{ case.name, c, scale });
                return e;
            };
        }
    };
}

test "Scale3x: a uniform grid and VRAM stay what nearest draws" {
    const m = try harness.metal();
    defer m.deinit();
    const uniform: [16]u16 = @splat(blue);
    for ([_]u32{ 1, 2, 3, 4 }) |scale| {
        const g = try fh.filterGrid(m, .{ .texels = &uniform, .cols = 4, .scale = scale, .filter = .scale3x });
        defer g.deinit();
        try expectBlock(g, 0, 0, g.width, g.height, blue);
    }
    const case = scale3x_cases[0];
    const g = try fh.filterGrid(m, .{ .texels = &case.grid, .cols = 3, .scale = 4, .filter = .scale3x });
    defer g.deinit();
    for (0..g.height) |y| for (0..g.width) |x| {
        try std.testing.expectEqual(case.grid[(y / 4) * 3 + x / 4], g.vram(x, y));
    };
}

// MARK: The eyeball picture

const sprite_side = 16;

/// A diagonal edge, a one-texel line, a ring around a hole and a checker corner.
fn sprite() [sprite_side * sprite_side]u16 {
    var t: [sprite_side * sprite_side]u16 = @splat(0x2108);
    for (0..8) |y| for (0..8) |x| {
        if (x < y) t[y * sprite_side + x] = white;
    };
    for (0..8) |x| t[10 * sprite_side + x] = green;
    for (8..16) |y| t[y * sprite_side + 3] = green;
    for (0..8) |y| for (8..16) |x| {
        const dx = @as(i32, @intCast(x)) - 11;
        const dy = @as(i32, @intCast(y)) - 3;
        const d2 = dx * dx + dy * dy;
        if (d2 <= 1) t[y * sprite_side + x] = 0 else if (d2 <= 9) t[y * sprite_side + x] = red;
    };
    for (8..16) |y| for (8..16) |x| {
        if (x + y >= 22) t[y * sprite_side + x] = if ((x + y) % 2 == 0) yellow else blue;
    };
    return t;
}

// Writes each filter beside nearest at 6x into the directory named by PS1_FILTER_DUMP,
// for looking at: nothing asserts on it.
//
//     PS1_FILTER_DUMP=/path/to/dir zig build test-metal -Doptimize=ReleaseFast -Dmetal-filter="Scale2x and Scale3x"
test "Scale2x and Scale3x: eyeball picture" {
    const dir = harness.gateSwitch("PS1_FILTER_DUMP") orelse return error.SkipZigTest;
    const m = try harness.metal();
    defer m.deinit();
    const texels = sprite();
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    const filters = .{ .{ .scale2x, "scale2x" }, .{ .scale3x, "scale3x" } };
    inline for (filters) |f| {
        const left = try fh.filterGrid(m, .{ .texels = &texels, .cols = sprite_side, .scale = 6, .filter = .nearest, .background = 0x2108 });
        defer left.deinit();
        const right = try fh.filterGrid(m, .{ .texels = &texels, .cols = sprite_side, .scale = 6, .filter = f[0], .background = 0x2108 });
        defer right.deinit();
        const zoom = 4;
        const gap = 8;
        const w = left.width * 2 + gap;
        const out = try alloc.alloc(u8, w * zoom * left.height * zoom * 4);
        defer alloc.free(out);
        @memset(out, 0);
        for ([_]fh.Grid{ left, right }, 0..) |g, panel| for (0..g.height) |y| for (0..g.width) |x| {
            const c = if (g.present(x, y)) g.rgb(x, y) else rgbOf(g.vram(x, y));
            for (0..zoom) |dy| for (0..zoom) |dx| {
                const ox = (panel * (g.width + gap) + x) * zoom + dx;
                const oy = y * zoom + dy;
                out[(oy * w * zoom + ox) * 4 ..][0..3].* = c;
                out[(oy * w * zoom + ox) * 4 + 3] = 255;
            };
        };
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}.png", .{ dir, f[1] });
        defer alloc.free(path);
        try image_io.writeRgba(path, out, w * zoom, left.height * zoom);
        std.debug.print("[filters] {s}\n", .{path});
    }
}
