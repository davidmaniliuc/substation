//! MMPX Enhanced's tests: draw with `filter_harness.filterGrid` and assert on the
//! sidecar it returns.

const std = @import("std");
const harness = @import("../harness.zig");
const fh = @import("../filter_harness.zig");
const image_io = @import("../image_io.zig");
const scale_harness = @import("../scale_harness.zig");

const alloc = std.testing.allocator;
const check = harness.check;

fn rgb5(r: u16, g: u16, b: u16) u16 {
    return r | g << 5 | b << 10;
}

/// A five-bit texel as the sidecar shows an unfiltered one.
fn expand(c: u16) [3]u8 {
    var out: [3]u8 = undefined;
    for (&out, 0..) |*o, i| {
        const v: u8 = @intCast((c >> @intCast(5 * i)) & 0x1F);
        o.* = v << 3 | v >> 2;
    }
    return out;
}

fn sameRgb(a: [3]u8, b: [3]u8) bool {
    return std.mem.eql(u8, &a, &b);
}

/// Every subtexel of texel (tx, ty) is `want`, except the quadrant `other`,
/// which is `want_other`. A quadrant is (0, 0) top-left, (1, 0) top-right,
/// (0, 1) bottom-left, (1, 1) bottom-right.
fn checkQuadrants(g: fh.Grid, scale: usize, tx: usize, ty: usize, want: [3]u8, other: ?[2]usize, want_other: [3]u8, what: []const u8) !void {
    for (0..scale) |sy| for (0..scale) |sx| {
        const qx = sx * 2 / scale;
        const qy = sy * 2 / scale;
        const is_other = if (other) |q| q[0] == qx and q[1] == qy else false;
        const w = if (is_other) want_other else want;
        const got = g.rgb(tx * scale + sx, ty * scale + sy);
        try check(sameRgb(got, w), "{s} @{d}x texel ({d}, {d}) subtexel ({d}, {d}): {any}, want {any}", .{ what, scale, tx, ty, sx, sy, got, w });
    };
}

// The two colours of every staircase: Y is brighter than X, which is what
// lets the darker X cut into the brighter texel's corner.
const stair_x = rgb5(6, 6, 6);
const stair_y = rgb5(24, 24, 24);

/// A 7x7 diagonal: X above-left of the anti-diagonal, Y on and below it,
/// then mirrored per `flip_x` / `flip_y`.
fn staircase(flip_x: bool, flip_y: bool) [49]u16 {
    var t: [49]u16 = undefined;
    for (0..7) |y| for (0..7) |x| {
        const fx = if (flip_x) 6 - x else x;
        const fy = if (flip_y) 6 - y else y;
        t[y * 7 + x] = if (fx + fy < 6) stair_x else stair_y;
    };
    return t;
}

test "MMPX Enhanced: aStaircaseGetsItsCornersFilledAtEveryScale" {
    const m = try harness.metal();
    defer m.deinit();
    // Each Y texel on the step has two X neighbours; the diagonal cuts the
    // corner facing them. The X texels are left alone.
    const Case = struct { flip_x: bool, flip_y: bool, corner: [2]usize };
    const cases = [_]Case{
        .{ .flip_x = false, .flip_y = false, .corner = .{ 0, 0 } },
        .{ .flip_x = true, .flip_y = false, .corner = .{ 1, 0 } },
        .{ .flip_x = false, .flip_y = true, .corner = .{ 0, 1 } },
        .{ .flip_x = true, .flip_y = true, .corner = .{ 1, 1 } },
    };
    for ([_]u32{ 2, 4 }) |scale| for (cases) |c| {
        const grid = staircase(c.flip_x, c.flip_y);
        const g = try fh.filterGrid(m, .{ .texels = &grid, .cols = 7, .scale = scale, .filter = .mmpx_enhanced });
        defer g.deinit();
        for (2..5) |x| {
            const y = 6 - x;
            const tx = if (c.flip_x) 6 - x else x;
            const ty = if (c.flip_y) 6 - y else y;
            try checkQuadrants(g, scale, tx, ty, expand(stair_y), c.corner, expand(stair_x), "step");
            // The texel beside the step on the dark side: untouched.
            const dx = if (c.flip_x) tx + 1 else tx - 1;
            try checkQuadrants(g, scale, dx, ty, expand(stair_x), null, undefined, "dark side");
        }
    };
}

test "MMPX Enhanced: aOneTexelLineSurvives" {
    const m = try harness.metal();
    defer m.deinit();
    const line = rgb5(31, 0, 0);
    const back = rgb5(0, 0, 31);
    var rows: [81]u16 = undefined;
    var cols: [81]u16 = undefined;
    for (0..9) |y| for (0..9) |x| {
        rows[y * 9 + x] = if (y == 4) line else back;
        cols[y * 9 + x] = if (x == 4) line else back;
    };
    for ([_]u32{ 2, 4 }) |scale| for ([_]*const [81]u16{ &rows, &cols }, 0..) |grid, vertical| {
        const g = try fh.filterGrid(m, .{ .texels = grid, .cols = 9, .scale = scale, .filter = .mmpx_enhanced });
        defer g.deinit();
        for (2..7) |along| for (3..6) |across| {
            const tx = if (vertical == 1) across else along;
            const ty = if (vertical == 1) along else across;
            const want = if (across == 4) line else back;
            try checkQuadrants(g, scale, tx, ty, expand(want), null, undefined, "line");
        };
    };
}

/// Whether every channel lies strictly between the two colours' (or equals
/// them where they agree).
fn between(lo: [3]u8, hi: [3]u8, got: [3]u8) bool {
    for (0..3) |i| {
        const a = @min(lo[i], hi[i]);
        const b = @max(lo[i], hi[i]);
        if (a == b) {
            if (got[i] != a) return false;
        } else if (got[i] <= a or got[i] >= b) return false;
    }
    return true;
}

/// How far `got` sits from `from` towards `to`, averaged over the channels
/// that differ.
fn fractionToward(from: [3]u8, to: [3]u8, got: [3]u8) f32 {
    var sum: f32 = 0;
    var n: f32 = 0;
    for (0..3) |i| {
        if (from[i] == to[i]) continue;
        const f: f32 = @floatFromInt(from[i]);
        const t: f32 = @floatFromInt(to[i]);
        const g: f32 = @floatFromInt(got[i]);
        sum += (g - f) / (t - f);
        n += 1;
    }
    return sum / n;
}

/// A 7x7 field of `n` with `put`'s (x, y, colour) overrides.
fn field(n: u16, put: []const [3]u16) [49]u16 {
    var t: [49]u16 = @splat(n);
    for (put) |p| t[p[1] * 7 + p[0]] = p[2];
    return t;
}

test "MMPX Enhanced: theConcaveAdmixBlendsTheDarkNeighbourIntoTheTopHalf" {
    const m = try harness.metal();
    defer m.deinit();
    const e = rgb5(20, 20, 20);
    const b = rgb5(10, 10, 10);
    // E at (3, 3) with G, H, I, S equal to it and A, D, C, F all different:
    // the concave rule mixes B into E's top half, 0.618 of the way back to E.
    const grid = field(rgb5(31, 31, 0), &.{
        .{ 3, 3, e },                .{ 2, 4, e },              .{ 3, 4, e },
        .{ 4, 4, e },                .{ 3, 5, e },              .{ 3, 2, b },
        .{ 2, 2, rgb5(3, 12, 20) },  .{ 4, 2, rgb5(26, 5, 9) }, .{ 2, 3, rgb5(15, 25, 3) },
        .{ 4, 3, rgb5(28, 17, 30) },
    });
    for ([_]u32{ 2, 4 }) |scale| {
        const g = try fh.filterGrid(m, .{ .texels = &grid, .cols = 7, .scale = scale, .filter = .mmpx_enhanced });
        defer g.deinit();
        const k: usize = scale;
        for (0..k) |sy| for (0..k) |sx| {
            const got = g.rgb(3 * k + sx, 3 * k + sy);
            if (sy * 2 < k) {
                try check(between(expand(b), expand(e), got), "@{d}x top ({d}, {d}) {any} is not between B and E", .{ scale, sx, sy, got });
                const f = fractionToward(expand(b), expand(e), got);
                try check(@abs(f - 0.618) < 0.03, "@{d}x top ({d}, {d}): {d:.3} of the way to E, want 0.618", .{ scale, sx, sy, f });
            } else {
                try check(sameRgb(got, expand(e)), "@{d}x bottom ({d}, {d}) {any} is not E", .{ scale, sx, sy, got });
            }
        };
    }
}

/// The K-type scene: E at (3, 3) with D, Q, C, I equal to it and F, B, H a
/// second colour, so the right half of E mixes F in. Every other texel is a
/// third colour.
fn kTypeField(e: u16, f: u16) [49]u16 {
    return field(rgb5(31, 31, 0), &.{
        .{ 3, 3, e }, .{ 2, 3, e }, .{ 1, 3, e }, .{ 4, 2, e }, .{ 4, 4, e },
        .{ 4, 3, f }, .{ 3, 2, f }, .{ 3, 4, f },
    });
}

test "MMPX Enhanced: theKTypeAdmixBlendsTheRightNeighbourIntoTheRightHalf" {
    const m = try harness.metal();
    defer m.deinit();
    const e = rgb5(31, 0, 0);
    const f = rgb5(0, 0, 31);
    const grid = kTypeField(e, f);
    for ([_]u32{ 2, 4 }) |scale| {
        const g = try fh.filterGrid(m, .{ .texels = &grid, .cols = 7, .scale = scale, .filter = .mmpx_enhanced });
        defer g.deinit();
        const k: usize = scale;
        for (0..k) |sy| for (0..k) |sx| {
            const got = g.rgb(3 * k + sx, 3 * k + sy);
            if (sx * 2 >= k) {
                // Red and blue are sqrt(2) apart in rgb: factor 2 * 0.16666 + 0.5.
                try check(between(expand(f), expand(e), got), "@{d}x right ({d}, {d}) {any} is not between F and E", .{ scale, sx, sy, got });
                const t = fractionToward(expand(f), expand(e), got);
                try check(@abs(t - 0.833) < 0.03, "@{d}x right ({d}, {d}): {d:.3} of the way to E, want 0.833", .{ scale, sx, sy, t });
            } else {
                try check(sameRgb(got, expand(e)), "@{d}x left ({d}, {d}) {any} is not E", .{ scale, sx, sy, got });
            }
        };
    }
}

test "MMPX Enhanced: aSampleOutsideTheUvLimitsIsTransparentNotAnExtendedEdge" {
    const m = try harness.metal();
    defer m.deinit();
    const e = rgb5(31, 0, 0);
    const f = rgb5(0, 0, 31);
    const grid = kTypeField(e, f);
    const vram = try fh.blankVram();
    defer alloc.destroy(vram);
    for (0..7) |y| @memcpy(vram[y * 1024 + fh.page_x ..][0..7], grid[y * 7 ..][0..7]);

    const k = 4;
    // The same VRAM, drawn whole and then as a sprite that starts at E's own
    // column: D and Q are still in VRAM, but past the sprite's limit.
    for ([_]u8{ 0, 3 }) |left| {
        const rect = fh.texturedRectangle(.{ .u0 = left, .w = 7 - left, .h = 7 });
        const frame = try fh.shot(m, k, vram, .true_color, .mmpx_enhanced, .mmpx_enhanced, &.{
            harness.fullDrawingArea(),
            .{ .kind = .fill_rect, .value = 0, .x = 288, .y = 288, .w = 32, .h = 32 },
            rect[1],
        });
        const g: fh.Grid = .{ .frame = frame, .width = (7 - left) * k, .height = 7 * k };
        defer g.deinit();
        const col: usize = 3 - left;
        var mixed: usize = 0;
        for (0..k) |sy| for (0..k) |sx| {
            if (sx * 2 >= k and !sameRgb(g.rgb(col * k + sx, 3 * k + sy), expand(e))) mixed += 1;
        };
        if (left == 0) {
            try check(mixed == k * k / 2, "whole texture: {d} of {d} right-half subtexels mix", .{ mixed, k * k / 2 });
        } else {
            try check(mixed == 0, "a sprite edge at its limit: {d} right-half subtexels mix across it", .{mixed});
        }
    }
}

test "MMPX Enhanced: vramStaysTheNearestTexelEverywhere" {
    const m = try harness.metal();
    defer m.deinit();
    const grid = staircase(false, false);
    const g = try fh.filterGrid(m, .{ .texels = &grid, .cols = 7, .scale = 4, .filter = .mmpx_enhanced });
    defer g.deinit();
    for (0..g.height) |y| for (0..g.width) |x| {
        const want = grid[(y / 4) * 7 + x / 4];
        try check(g.vram(x, y) == want, "({d}, {d}): VRAM {x:0>4}, want {x:0>4}", .{ x, y, g.vram(x, y), want });
    };
}

test "MMPX Enhanced: aUniformGridFiltersToItself" {
    const m = try harness.metal();
    defer m.deinit();
    const grid: [25]u16 = @splat(rgb5(9, 17, 25));
    for ([_]u32{ 1, 2, 3, 4 }) |scale| {
        const g = try fh.filterGrid(m, .{ .texels = &grid, .cols = 5, .scale = scale, .filter = .mmpx_enhanced });
        defer g.deinit();
        for (0..g.height) |y| for (0..g.width) |x| {
            try check(g.present(x, y) and sameRgb(g.rgb(x, y), expand(rgb5(9, 17, 25))), "@{d}x ({d}, {d}) drifted from the texel", .{ scale, x, y });
        };
    }
}

test "MMPX Enhanced: eyeballSprite" {
    const dump = scale_harness.gateSwitch("PS1_FILTER_DUMP") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, dump, "1")) return error.SkipZigTest;
    const m = try harness.metal();
    defer m.deinit();

    const bg: u16 = 0x0421;
    const cream = rgb5(30, 26, 14);
    const navy = rgb5(3, 5, 14);
    const red = rgb5(28, 4, 4);
    var grid: [256]u16 = @splat(bg);
    for (0..16) |y| for (0..16) |x| {
        const t = &grid[y * 16 + x];
        // diagonal edge, upper-left quadrant
        if (x < 8 and y < 8) t.* = if (x + y < 9) cream else navy;
        // a one-texel line across the top right
        if (x >= 8 and y == 2) t.* = red;
        // a ring with a transparent centre, lower left
        if (x < 8 and y >= 8) {
            const dx = @as(i32, @intCast(x)) - 4;
            const dy = @as(i32, @intCast(y)) - 12;
            const d = dx * dx + dy * dy;
            t.* = if (d <= 1) 0 else if (d <= 12) cream else bg;
        }
        // a two-colour checker corner, lower right
        if (x >= 8 and y >= 8) t.* = if (((x + y) & 1) == 0) cream else navy;
    };
    const k: usize = 6;
    const g = try fh.filterGrid(m, .{ .texels = &grid, .cols = 16, .scale = k, .filter = .mmpx_enhanced, .background = bg });
    defer g.deinit();
    const rgba = try alloc.alloc(u8, g.width * g.height * 4);
    defer alloc.free(rgba);
    for (0..g.height) |y| for (0..g.width) |x| {
        const c = if (g.present(x, y)) g.rgb(x, y) else expand(g.vram(x, y));
        rgba[(y * g.width + x) * 4 ..][0..4].* = .{ c[0], c[1], c[2], 255 };
    };
    const path = "/private/tmp/claude-501/-Users-david-Documents-develop-substation/ee0612e2-d935-40e3-9807-dffcf08b94d6/scratchpad/filters/mmpx-enhanced.png";
    try image_io.writeRgba(path, rgba, g.width, g.height);
}
