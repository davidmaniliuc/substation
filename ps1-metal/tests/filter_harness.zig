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
