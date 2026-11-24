//! MMPX Advanced's tests: draw with `filter_harness.filterGrid` and assert on the
//! sidecar it returns.

const std = @import("std");
const harness = @import("../harness.zig");
const fh = @import("../filter_harness.zig");
const image_io = @import("../image_io.zig");

const alloc = std.testing.allocator;
const check = harness.check;

const red: u16 = 0x001F;
const blue: u16 = 0x7C00;
const green: u16 = 0x03E0;

fn expand(c: u16) [3]u8 {
    var out: [3]u8 = undefined;
    for (&out, 0..) |*o, i| {
        const v: u8 = @intCast((c >> @intCast(5 * i)) & 0x1F);
        o.* = v << 3 | v >> 2;
    }
    return out;
}

/// `A` red, `x` blue, `.` a hole.
fn parse(comptime pattern: []const u8) [pattern.len]u16 {
    var out: [pattern.len]u16 = undefined;
    inline for (pattern, 0..) |c, i| out[i] = switch (c) {
        'A' => red,
        'x' => blue,
        '.' => 0,
        else => @compileError("pattern letter"),
    };
    return out;
}

/// The sidecar's colour at a subtexel, or VRAM's where the sidecar defers to it.
fn colourAt(g: fh.Grid, x: usize, y: usize) [3]u8 {
    return if (g.present(x, y)) g.rgb(x, y) else expand(g.vram(x, y));
}

/// The four sample-point quadrants of a texel, named as the reference names
/// its outputs: J top left, K top right, L bottom left, M bottom right.
const Quad = enum { j, k, l, m };

const Cut = struct { tx: usize, ty: usize, quad: Quad, colour: u16 };

fn quadOf(sub_x: usize, sub_y: usize, per_texel: usize) Quad {
    const right = sub_x * 2 >= per_texel;
    const bottom = sub_y * 2 >= per_texel;
    return if (bottom) (if (right) .m else .l) else (if (right) .k else .j);
}

/// Every subtexel of the drawing shows its texel's colour (a hole shows
/// `bg`), except the quadrants in `cuts`, which show their own.
fn expectCuts(g: fh.Grid, texels: []const u16, cols: usize, per_texel: usize, bg: u16, cuts: []const Cut) !void {
    return expectCutsInside(g, texels, cols, per_texel, bg, cuts, 0);
}

/// `expectCuts` over the texels at least `margin` texels from the drawing's
/// border, where a neighbour past the edge being a hole does not apply.
fn expectCutsInside(g: fh.Grid, texels: []const u16, cols: usize, per_texel: usize, bg: u16, cuts: []const Cut, margin: usize) !void {
    const rows = texels.len / cols;
    for (0..g.height) |y| for (0..g.width) |x| {
        const tx = x / per_texel;
        const ty = y / per_texel;
        if (tx < margin or ty < margin or tx + margin >= cols or ty + margin >= rows) continue;
        const quad = quadOf(x % per_texel, y % per_texel, per_texel);
        const t = texels[ty * cols + tx];
        var want = expand(if (t == 0) bg else t);
        for (cuts) |c| {
            if (c.tx == tx and c.ty == ty and c.quad == quad) want = expand(c.colour);
        }
        const got = colourAt(g, x, y);
        try check(std.mem.eql(u8, &want, &got), "subtexel ({d},{d}) texel ({d},{d}) {s}: want {any} got {any}", .{ x, y, tx, ty, @tagName(quad), want, got });
    };
}

/// VRAM holds the nearest texel at every subtexel, whatever the sidecar shows.
fn expectNearestVram(g: fh.Grid, texels: []const u16, cols: usize, per_texel: usize, bg: u16) !void {
    for (0..g.height) |y| for (0..g.width) |x| {
        const t = texels[y / per_texel * cols + x / per_texel];
        const want = if (t == 0) bg else t;
        try check(g.vram(x, y) == want, "vram ({d},{d}): want {x} got {x}", .{ x, y, want, g.vram(x, y) });
    };
}

// A 6x6 staircase of red on blue, once per direction the red can face. The
// texels on the diagonal are the ones whose outer corner gets cut.
const stair_lower_left = parse("Axxxxx" ++ "AAxxxx" ++ "AAAxxx" ++ "AAAAxx" ++ "AAAAAx" ++ "AAAAAA");
const stair_upper_left = parse("AAAAAA" ++ "AAAAAx" ++ "AAAAxx" ++ "AAAxxx" ++ "AAxxxx" ++ "Axxxxx");
const stair_upper_right = parse("AAAAAA" ++ "xAAAAA" ++ "xxAAAA" ++ "xxxAAA" ++ "xxxxAA" ++ "xxxxxA");
const stair_lower_right = parse("xxxxxA" ++ "xxxxAA" ++ "xxxAAA" ++ "xxAAAA" ++ "xAAAAA" ++ "AAAAAA");

/// The four red texels on a staircase's diagonal that have a corner to cut:
/// each loses the quadrant pointing at the blue (`facing`), to `colour`.
fn staircaseCuts(comptime facing: Quad, comptime anti: bool, colour: u16) [4]Cut {
    var cuts: [4]Cut = undefined;
    for (&cuts, 1..) |*c, i| c.* = .{ .tx = i, .ty = if (anti) 5 - i else i, .quad = facing, .colour = colour };
    return cuts;
}

const StaircaseDraw = struct {
    scale: u32,
    shape: @FieldType(fh.GridOptions, "shape") = .rectangle,
    magnify: usize = 1,
};

fn expectStaircase(m: harness.Metal, texels: []const u16, cuts: []const Cut, d: StaircaseDraw) !void {
    const g = try fh.filterGrid(m, .{ .texels = texels, .cols = 6, .scale = d.scale, .shape = d.shape, .magnify = d.magnify, .filter = .mmpx_advanced, .background = green });
    defer g.deinit();
    try expectCuts(g, texels, 6, d.scale * d.magnify, green, cuts);
}

test "MMPX Advanced: a uniform grid filters to itself at every scale" {
    const m = try harness.metal();
    defer m.deinit();
    const texels = parse("AAAAA" ++ "AAAAA" ++ "AAAAA" ++ "AAAAA" ++ "AAAAA");
    for ([_]u32{ 1, 2, 3, 4 }) |scale| {
        const g = try fh.filterGrid(m, .{ .texels = &texels, .cols = 5, .scale = scale, .filter = .mmpx_advanced, .background = green });
        defer g.deinit();
        try expectCuts(g, &texels, 5, scale, green, &.{});
    }
}

test "MMPX Advanced: vram stays on the nearest texel" {
    const m = try harness.metal();
    defer m.deinit();
    const texels = stair_lower_left;
    const rect = try fh.filterGrid(m, .{ .texels = &texels, .cols = 6, .scale = 4, .filter = .mmpx_advanced, .background = green });
    defer rect.deinit();
    try expectNearestVram(rect, &texels, 6, 4, green);
    const tri = try fh.filterGrid(m, .{ .texels = &texels, .cols = 6, .scale = 1, .shape = .triangles, .magnify = 4, .filter = .mmpx_advanced, .background = green });
    defer tri.deinit();
    try expectNearestVram(tri, &texels, 6, 4, green);
}

test "MMPX Advanced: a staircase gets its diagonal corners cut" {
    const m = try harness.metal();
    defer m.deinit();
    for ([_]u32{ 2, 4 }) |scale| {
        try expectStaircase(m, &stair_lower_left, &staircaseCuts(.k, false, blue), .{ .scale = scale });
        try expectStaircase(m, &stair_upper_left, &staircaseCuts(.m, true, blue), .{ .scale = scale });
        try expectStaircase(m, &stair_upper_right, &staircaseCuts(.l, false, blue), .{ .scale = scale });
        try expectStaircase(m, &stair_lower_right, &staircaseCuts(.j, true, blue), .{ .scale = scale });
    }
}

test "MMPX Advanced: a staircase gets its corners cut on the triangle path too" {
    const m = try harness.metal();
    defer m.deinit();
    try expectStaircase(m, &stair_lower_left, &staircaseCuts(.k, false, blue), .{ .scale = 2, .shape = .triangles, .magnify = 2 });
    try expectStaircase(m, &stair_lower_right, &staircaseCuts(.j, true, blue), .{ .scale = 1, .shape = .triangles, .magnify = 4 });
}

test "MMPX Advanced: a staircase against a hole grows into the hole" {
    const m = try harness.metal();
    defer m.deinit();
    const texels = parse("A....." ++ "AA...." ++ "AAA..." ++ "AAAA.." ++ "AAAAA." ++ "AAAAAA");
    // Each hole beside the diagonal gets the quadrant facing the red painted
    // into the sidecar; VRAM keeps the hole.
    var grown: [5]Cut = undefined;
    for (&grown, 0..) |*c, i| c.* = .{ .tx = i + 1, .ty = i, .quad = .l, .colour = red };
    for ([_]u32{ 2, 4 }) |scale| {
        const g = try fh.filterGrid(m, .{ .texels = &texels, .cols = 6, .scale = scale, .filter = .mmpx_advanced, .background = green });
        defer g.deinit();
        try expectCuts(g, &texels, 6, scale, green, &grown);
        try expectNearestVram(g, &texels, 6, scale, green);
    }
}

test "MMPX Advanced: a one texel line survives" {
    const m = try harness.metal();
    defer m.deinit();
    const horizontal = parse("xxxxxxx" ++ "xxxxxxx" ++ "AAAAAAA" ++ "xxxxxxx" ++ "xxxxxxx");
    const vertical = parse("xxAxx" ++ "xxAxx" ++ "xxAxx" ++ "xxAxx" ++ "xxAxx" ++ "xxAxx" ++ "xxAxx");
    for ([_]u32{ 2, 4 }) |scale| {
        const h = try fh.filterGrid(m, .{ .texels = &horizontal, .cols = 7, .scale = scale, .filter = .mmpx_advanced, .background = green });
        defer h.deinit();
        try expectCuts(h, &horizontal, 7, scale, green, &.{});
        const v = try fh.filterGrid(m, .{ .texels = &vertical, .cols = 5, .scale = scale, .filter = .mmpx_advanced, .background = green });
        defer v.deinit();
        try expectCuts(v, &vertical, 5, scale, green, &.{});
    }
}

test "MMPX Advanced: a checker is not bubbled" {
    const m = try harness.metal();
    defer m.deinit();
    const single = parse("AxAxAxAx" ++ "xAxAxAxA" ++ "AxAxAxAx" ++ "xAxAxAxA" ++ "AxAxAxAx" ++ "xAxAxAxA" ++ "AxAxAxAx" ++ "xAxAxAxA");
    const blocks = parse("AAxxAAxx" ++ "AAxxAAxx" ++ "xxAAxxAA" ++ "xxAAxxAA" ++ "AAxxAAxx" ++ "AAxxAAxx" ++ "xxAAxxAA" ++ "xxAAxxAA");
    for ([_]u32{ 2, 4 }) |scale| {
        const a = try fh.filterGrid(m, .{ .texels = &single, .cols = 8, .scale = scale, .filter = .mmpx_advanced, .background = green });
        defer a.deinit();
        try expectCutsInside(a, &single, 8, scale, green, &.{}, 2);
        const c = try fh.filterGrid(m, .{ .texels = &blocks, .cols = 8, .scale = scale, .filter = .mmpx_advanced, .background = green });
        defer c.deinit();
        try expectCutsInside(c, &blocks, 8, scale, green, &.{}, 2);
    }
}

test "MMPX Advanced: a hole inside an opaque ring stays unpainted" {
    const m = try harness.metal();
    defer m.deinit();
    const texels = parse("AAAAA" ++ "A...A" ++ "A...A" ++ "A...A" ++ "AAAAA");
    for ([_]u32{ 2, 4 }) |scale| {
        const g = try fh.filterGrid(m, .{ .texels = &texels, .cols = 5, .scale = scale, .filter = .mmpx_advanced, .background = green });
        defer g.deinit();
        try expectCuts(g, &texels, 5, scale, green, &.{});
        try expectNearestVram(g, &texels, 5, scale, green);
    }
}

// MARK: Out-of-limit samples

const patch = 8;
const checker = parse("AxAxAx" ++ "xAxAxA" ++ "AxAxAx" ++ "xAxAxA" ++ "AxAxAx" ++ "xAxAxA");

/// The checker at texel (1, 1) of an 8x8 patch with `ring` all
/// round it, drawn as a sprite at (300, 300): limited to the staircase, or,
/// with `wide`, to the whole patch from one pixel up and left.
fn limitFrame(m: harness.Metal, scale: u32, ring: u16, wide: bool) !harness.Frame {
    const v = try fh.blankVram();
    defer alloc.destroy(v);
    for (0..patch) |y| for (0..patch) |x| {
        const inside = x >= 1 and x <= 6 and y >= 1 and y <= 6;
        v[y * 1024 + fh.page_x + x] = if (inside) checker[(y - 1) * 6 + x - 1] else ring;
    };
    var records = fh.texturedRectangle(if (wide)
        .{ .u0 = 0, .v0 = 0, .w = patch, .h = patch }
    else
        .{ .u0 = 1, .v0 = 1, .w = 6, .h = 6 });
    if (wide) {
        records[1].x = 299;
        records[1].y = 299;
    }
    return fh.shot(m, scale, v, .true_color, .mmpx_advanced, null, &records);
}

fn expectSamePatch(a: harness.Frame, b: harness.Frame, what: []const u8) !void {
    const k = a.scale;
    for (300 * k..306 * k) |y| for (300 * k..306 * k) |x| {
        const i = y * a.width + x;
        const same = std.mem.eql(u8, a.sidecar.?[i * 4 ..][0..4], b.sidecar.?[i * 4 ..][0..4]) and a.scaled[i] == b.scaled[i];
        try check(same, "{s}: pixel ({d},{d}) differs", .{ what, x - 300 * k, y - 300 * k });
    };
}

test "MMPX Advanced: a sample outside the limits reads as a hole" {
    const m = try harness.metal();
    defer m.deinit();
    for ([_]u32{ 2, 4 }) |scale| {
        const over_texels = try limitFrame(m, scale, green, false);
        defer over_texels.deinit(alloc);
        const over_holes = try limitFrame(m, scale, 0, false);
        defer over_holes.deinit(alloc);
        const in_limits = try limitFrame(m, scale, 0, true);
        defer in_limits.deinit(alloc);
        try expectSamePatch(over_texels, over_holes, "a texel past the limits was read");
        try expectSamePatch(over_holes, in_limits, "past the limits is not a hole");

        // A hole beyond the corner texel blends its sample point with the
        // blue beside it, so the three frames are not three plain checkers.
        const k = scale;
        const corner = (300 * k + k - 1) + (300 * k + k - 1) * over_texels.width;
        try check(!std.mem.eql(u8, over_texels.sidecar.?[corner * 4 ..][0..3], &expand(red)), "the corner texel was not blended", .{});
    }
}

// MARK: Eyeball

fn sprite() [256]u16 {
    const orange: u16 = 0x02BF;
    const sky: u16 = 0x7E10;
    var out: [256]u16 = undefined;
    for (0..16) |y| for (0..16) |x| {
        const lx = x % 8;
        const ly = y % 8;
        out[y * 16 + x] = switch (y / 8 * 2 + x / 8) {
            0 => if (lx <= ly) orange else sky,
            1 => if (ly == 3 or lx == 3) orange else sky,
            2 => blk: {
                const in_ring = lx >= 1 and lx <= 6 and ly >= 1 and ly <= 6;
                const corner = (lx == 1 or lx == 6) and (ly == 1 or ly == 6);
                const centre = lx >= 3 and lx <= 4 and ly >= 3 and ly <= 4;
                break :blk if (in_ring and !corner and !centre) orange else 0;
            },
            else => if (lx < 4 and ly < 4 and (lx + ly) % 2 == 0) orange else sky,
        };
    };
    return out;
}

test "MMPX Advanced eyeball: a sprite under the filter beside nearest" {
    const dir = harness.gateSwitch("PS1_FILTER_DUMP") orelse return error.SkipZigTest;
    const m = try harness.metal();
    defer m.deinit();
    const texels = sprite();
    const dark: u16 = 0x1084;
    const nearest = try fh.filterGrid(m, .{ .texels = &texels, .cols = 16, .scale = 6, .filter = .nearest, .background = dark });
    defer nearest.deinit();
    const filtered = try fh.filterGrid(m, .{ .texels = &texels, .cols = 16, .scale = 6, .filter = .mmpx_advanced, .background = dark });
    defer filtered.deinit();

    const gap = 8;
    const w = nearest.width * 2 + gap;
    const pixels = try alloc.alloc(u8, w * nearest.height * 4);
    defer alloc.free(pixels);
    @memset(pixels, 255);
    for (0..nearest.height) |y| for (0..nearest.width) |x| {
        for ([_]fh.Grid{ nearest, filtered }, 0..) |g, side| {
            const o = (y * w + x + side * (nearest.width + gap)) * 4;
            pixels[o..][0..3].* = colourAt(g, x, y);
        }
    };
    const path = try std.fmt.allocPrint(alloc, "{s}/mmpx-advanced.png", .{dir});
    defer alloc.free(path);
    try image_io.writeRgba(path, pixels, w, nearest.height);
}
