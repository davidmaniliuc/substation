//! What the texture-filter tests share: the hand-built textured triangle
//! and rectangle at (300, 300), the VRAMs they sample, and the statistics
//! taken over the present sidecar pixels inside their box. Split from
//! filter_test.zig to keep that file in bounds.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const ps1_core = @import("ps1_core");
const harness = @import("harness.zig");

const pi = ps1_metal.prim_instance;
const Command = ps1_core.gpu.command.Command;
const Frame = harness.Frame;
const Metal = harness.Metal;
const DitherMode = pi.DitherMode;
const TextureFilter = pi.TextureFilter;

const alloc = std.testing.allocator;
const w = pi.native_width;
const native_pixels = pi.native_pixels;
const vtx = harness.vtx;
const fullDrawingArea = harness.fullDrawingArea;

/// The 16bpp texture page every hand-built test samples: tpage 0x0104 puts
/// page X at unit 4, i.e. VRAM x = 256, y = 0.
pub const page16: u16 = 0x0104;
pub const page_x = 256;

/// Red 1 -> red 31 -> red 31: a hard edge one texel wide, magnified 64x.
pub const edge_row = [_]u16{ 0x0001, 0x001F, 0x001F, 0x001F };

/// A blank native VRAM on the heap. Free with `alloc.destroy`.
pub fn blankVram() !*[native_pixels]u16 {
    const v = try alloc.create([native_pixels]u16);
    @memset(v, 0);
    return v;
}

/// A native VRAM with `row` written at (256 + u, v) for v in 0..<16.
pub fn vramWithRows(row: []const u16) !*[native_pixels]u16 {
    const v = try blankVram();
    for (0..16) |y| for (row, 0..) |t, u| {
        v[y * w + page_x + u] = t;
    };
    return v;
}

pub const Triangle = struct {
    opcode: u8 = 0x25,
    tpage: u16 = page16,
    clut: u16 = 0,
    u0: u8,
    u1: u8,
    v0: u8 = 0,
    v1: u8 = 2,
    size: i16 = 128,
    colors: [3]u32 = .{ 0, 0, 0 },
    flags: u8 = 0,
    rw: [3]i32 = .{ 0, 0, 0 },
    transparent: u8 = 0,
};

/// The drawing area, then a right triangle at (300, 300) whose legs are
/// `size` px and span texcoords `u0...u1` horizontally and `v0...v1`
/// vertically: a magnified texture.
pub fn texturedTriangle(t: Triangle) [2]Command {
    var tri: Command = .{
        .kind = .draw_textured_triangle,
        .opcode = t.opcode,
        .tpage = t.tpage,
        .clut = t.clut,
        .flags = t.flags,
        .transparent = t.transparent,
        .v = .{
            vtx(300, 300, t.u0, t.v0, t.colors[0]),
            vtx(300 + t.size, 300, t.u1, t.v0, t.colors[1]),
            vtx(300, 300 + t.size, t.u0, t.v1, t.colors[2]),
        },
    };
    for (&tri.v, t.rw) |*v, rw| v.rw = rw;
    return .{ fullDrawingArea(), tri };
}

/// A triangle with explicit vertices and texcoords, for mappings
/// `texturedTriangle` cannot express (turned on its side, mirrored).
pub fn mappedTriangle(xy: [3][2]i16, uv: [3][2]u8, rw: [3]i32) [2]Command {
    var tri: Command = .{ .kind = .draw_textured_triangle, .opcode = 0x25, .tpage = page16 };
    for (0..3) |i| {
        tri.v[i] = vtx(xy[i][0], xy[i][1], uv[i][0], uv[i][1], 0);
        tri.v[i].rw = rw[i];
    }
    return .{ fullDrawingArea(), tri };
}

pub const Rectangle = struct {
    opcode: u8 = 0x65,
    tpage: u16 = page16,
    u0: u8 = 0,
    v0: u8 = 0,
    w: i32 = 4,
    h: i32 = 4,
    color: u32 = 0,
    transparent: u8 = 0,
};

/// The drawing area, then a textured rectangle at (300, 300), `w` x `h` px,
/// texcoord origin (u0, v0).
pub fn texturedRectangle(r: Rectangle) [2]Command {
    return .{ fullDrawingArea(), .{
        .kind = .draw_textured_rectangle,
        .opcode = r.opcode,
        .tpage = r.tpage,
        .value = r.color,
        .transparent = r.transparent,
        .x = 300,
        .y = 300,
        .w = r.w,
        .h = r.h,
        .v = .{ vtx(0, 0, r.u0, r.v0, 0), .{}, .{} },
    } };
}

/// One frame over a preloaded VRAM, with the sidecar. `sprite` null follows
/// `filter`, as the harness's own default does.
pub fn shot(m: Metal, scale: u32, vram: *const [native_pixels]u16, dither: DitherMode, filter: TextureFilter, sprite: ?TextureFilter, records: []const Command) !Frame {
    return harness.frameOf(alloc, m, scale, .{
        .preload = vram,
        .dither = dither,
        .filter = filter,
        .sprite_filter = sprite,
        .want_sidecar = true,
    }, records);
}

/// What the PRESENT sidecar pixels inside the box at (300, 300), `size`
/// native px square, add up to.
pub const Stats = struct {
    count: usize = 0,
    reds: std.StaticBitSet(256) = .empty,
    min_r: u8 = 255,
    max_r: u8 = 0,
    /// Every red is `expand` of a five-bit value: `(c << 3) | (c >> 2)`.
    five_bit: bool = true,
    /// Some pixel has both green and blue: a sample crossed a seam.
    mixed_gb: bool = false,

    pub fn distinct(self: Stats) usize {
        return self.reds.count();
    }
};

pub fn sidecarStats(f: Frame, size: usize) Stats {
    var s: Stats = .{};
    const side = f.sidecar orelse return s;
    const k = f.scale;
    for (300 * k..(300 + size) * k) |y| for (300 * k..(300 + size) * k) |x| {
        const i = (y * f.width + x) * 4;
        if (side[i + 3] != 255) continue;
        const r = side[i];
        s.count += 1;
        s.reds.set(r);
        s.min_r = @min(s.min_r, r);
        s.max_r = @max(s.max_r, r);
        const c = r >> 3;
        if (r != (c << 3) | (c >> 2)) s.five_bit = false;
        if (side[i + 1] != 0 and side[i + 2] != 0) s.mixed_gb = true;
    };
    return s;
}

/// The distinct present sidecar reds of `records` under one pair of settings.
pub fn distinctReds(m: Metal, records: []const Command, vram: *const [native_pixels]u16, texture: TextureFilter, sprite: TextureFilter) !usize {
    const f = try shot(m, 1, vram, .true_color, texture, sprite, records);
    defer f.deinit(alloc);
    return sidecarStats(f, 128).distinct();
}

pub fn sameSidecar(a: Frame, b: Frame) bool {
    return std.mem.eql(u8, a.sidecar.?, b.sidecar.?);
}

pub fn sameVram(a: Frame, b: Frame) bool {
    return std.mem.eql(u16, a.scaled, b.scaled);
}

/// Blue inside the 8x8 texture window at the page origin, red outside it.
pub fn windowVram() !*[native_pixels]u16 {
    const v = try blankVram();
    for (0..24) |y| for (0..24) |u| {
        v[y * w + page_x + u] = if (u < 8 and y < 8) 0x7C00 else 0x001F;
    };
    return v;
}

/// A dark red fill under the box, the texpage latched with blend mode 1
/// (add), then `draw`: the shape both semi-transparent filtered tests share.
pub fn overDarkRed(fill_size: i32, draw: [2]Command) [5]Command {
    return [_]Command{
        fullDrawingArea(),
        .{ .kind = .fill_rect, .value = 0x0008, .x = 288, .y = 288, .w = fill_size, .h = fill_size },
        .{ .kind = .latch_texpage, .tpage = page16 | (1 << 5) },
    } ++ draw;
}

// MARK: A filter's own picture

/// What a filter port's test draws: `texels` (row-major, `cols` a row, raw
/// 16bpp with 0 a hole) placed at the page origin, drawn at (300, 300) over a
/// `background` fill with `filter` as BOTH settings, so the primitive's class
/// does not matter.
///
/// `.rectangle` maps one texel to one native pixel, so each texel covers
/// `scale` x `scale` subtexels. `.triangles` draws the same grid as two
/// screen-aligned triangles magnified `magnify` times, which takes the
/// triangle path's UV limits and centre interpolation instead.
///
///     const g = try fh.filterGrid(m, .{ .texels = &grid, .cols = 4, .scale = 4, .filter = .xbr });
///     defer g.deinit();
///     const c = g.rgb(5, 3); // the sidecar at subtexel (5, 3) of the drawing
pub const GridOptions = struct {
    texels: []const u16,
    cols: usize,
    filter: TextureFilter,
    scale: u32 = 1,
    shape: enum { rectangle, triangles } = .rectangle,
    magnify: usize = 1,
    dither: DitherMode = .true_color,
    background: u16 = 0,
};

/// One `filterGrid` frame, addressed relative to the drawing.
pub const Grid = struct {
    frame: Frame,
    /// The drawing's size in subtexels.
    width: usize,
    height: usize,

    pub fn deinit(self: Grid) void {
        self.frame.deinit(alloc);
    }

    fn sidecarIndex(self: Grid, x: usize, y: usize) usize {
        const k = self.frame.scale;
        return ((300 * k + y) * self.frame.width + 300 * k + x) * 4;
    }

    /// The sidecar's colour at subtexel (x, y) of the drawing.
    pub fn rgb(self: Grid, x: usize, y: usize) [3]u8 {
        const i = self.sidecarIndex(x, y);
        return self.frame.sidecar.?[i..][0..3].*;
    }

    /// Whether the sidecar holds a colour of its own at subtexel (x, y)
    /// rather than deferring to VRAM's.
    pub fn present(self: Grid, x: usize, y: usize) bool {
        return self.frame.sidecar.?[self.sidecarIndex(x, y) + 3] == 255;
    }

    /// VRAM at subtexel (x, y) of the drawing.
    pub fn vram(self: Grid, x: usize, y: usize) u16 {
        const k = self.frame.scale;
        return self.frame.scaled[(300 * k + y) * self.frame.width + 300 * k + x];
    }
};

pub fn filterGrid(m: Metal, o: GridOptions) !Grid {
    const rows = o.texels.len / o.cols;
    const v = try blankVram();
    defer alloc.destroy(v);
    for (0..rows) |y| @memcpy(v[y * w + page_x ..][0..o.cols], o.texels[y * o.cols ..][0..o.cols]);

    const span = if (o.shape == .rectangle) 1 else o.magnify;
    const pw: i16 = @intCast(o.cols * span);
    const ph: i16 = @intCast(rows * span);
    const fill: i32 = (@max(pw, ph) + 24 + 15) & ~@as(i32, 15);
    var records: [4]Command = undefined;
    records[0] = fullDrawingArea();
    records[1] = .{ .kind = .fill_rect, .value = o.background, .x = 288, .y = 288, .w = fill, .h = fill };
    var n: usize = 2;
    switch (o.shape) {
        .rectangle => {
            records[n] = texturedRectangle(.{ .w = pw, .h = ph })[1];
            n += 1;
        },
        .triangles => {
            const uw: u8 = @intCast(o.cols);
            const vh: u8 = @intCast(rows);
            records[n] = mappedTriangle(.{ .{ 300, 300 }, .{ 300 + pw, 300 }, .{ 300, 300 + ph } }, .{ .{ 0, 0 }, .{ uw, 0 }, .{ 0, vh } }, .{ 0, 0, 0 })[1];
            records[n + 1] = mappedTriangle(.{ .{ 300 + pw, 300 }, .{ 300 + pw, 300 + ph }, .{ 300, 300 + ph } }, .{ .{ uw, 0 }, .{ uw, vh }, .{ 0, vh } }, .{ 0, 0, 0 })[1];
            n += 2;
        },
    }
    const f = try shot(m, o.scale, v, o.dither, o.filter, o.filter, records[0..n]);
    return .{
        .frame = f,
        .width = @as(usize, @intCast(pw)) * o.scale,
        .height = @as(usize, @intCast(ph)) * o.scale,
    };
}
