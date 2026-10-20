//! Turns one recorded drawing command into instance records.
//!
//! Split from the encoder so neither file grows past readable size: the
//! encoder owns passes and resources, this owns the per-primitive geometry
//! that mirrors `gpu/renderer.zig`'s CPU-side setup: the offset, the
//! oversized-primitive refusal, and the bounding box.

const std = @import("std");
const ps1_core = @import("ps1_core");
const pi = @import("prim_instance.zig");

const DrawingEnv = ps1_core.gpu.Regs.DrawingEnv;
const Command = ps1_core.gpu.command.Command;
const command = ps1_core.gpu.command;
const PrimInstance = pi.PrimInstance;
const VramRect = pi.VramRect;
const Kind = pi.Kind;
const Flag = pi.Flag;

fn zeroInstance() PrimInstance {
    return std.mem.zeroes(PrimInstance);
}

/// Everything a primitive inherits from the drawing environment.
pub fn base(env: DrawingEnv) PrimInstance {
    var inst = zeroInstance();
    const clip = env.area();
    inst.clip_x0 = clip.x0;
    inst.clip_y0 = clip.y0;
    inst.clip_x1 = clip.x1;
    inst.clip_y1 = clip.y1;
    inst.blend_mode = (env.draw_mode >> 5) & 3;
    inst.tex_window = env.tex_window;
    inst.flags = (if (env.mask_bit & 1 != 0) Flag.set_mask else 0) |
        (if (env.mask_bit & 2 != 0) Flag.check_mask else 0) |
        (if ((env.draw_mode >> 9) & 1 != 0) Flag.dither else 0);
    return inst;
}

/// 1/16 px relative to a base pixel, rounded.
fn toQ(p: i32, origin: i64) i32 {
    return @intCast((@as(i64, p) - (origin << 16) + 2048) >> 12);
}

/// One triangle. A record always carries exactly one (`gp0.zig` already
/// decomposes quads into two records), so the oversized refusal is judged per
/// triangle, each half of a quad separately, exactly as `renderer.zig` does.
///
/// Returns null for every case the software rasterizer refuses outright: an
/// oversized span, a degenerate area, or an empty box after clipping.
pub fn triangle(cmd: Command, env: DrawingEnv, kind: i32) ?PrimInstance {
    const ox: i64 = env.getOffsetX();
    const oy: i64 = env.getOffsetY();
    var vx: [3]i64 = undefined;
    var vy: [3]i64 = undefined;
    for (0..3) |i| {
        vx[i] = @as(i64, cmd.v[i].x) + ox;
        vy[i] = @as(i64, cmd.v[i].y) + oy;
    }
    const minx = @min(vx[0], @min(vx[1], vx[2]));
    const maxx = @max(vx[0], @max(vx[1], vx[2]));
    const miny = @min(vy[0], @min(vy[1], vy[2]));
    const maxy = @max(vy[0], @max(vy[1], vy[2]));

    // Hardware refuses any primitive whose vertices span 1024 or more
    // horizontally, or 512 or more vertically: it is not clipped, it is
    // DROPPED. Geometry crossing the near plane projects to saturated screen
    // coordinates, and the drop is what keeps it off the screen.
    if (maxx - minx >= 1024 or maxy - miny >= 512) return null;

    // `px` is PRE-offset (straight off the wire record) while `vx`/`vy` are
    // post-offset, so `minx - ox` is the pre-offset minimum: the same base
    // `renderer.zig`'s `toQ` uses.
    var qx: [3]i32 = undefined;
    var qy: [3]i32 = undefined;
    for (0..3) |i| {
        qx[i] = toQ(cmd.v[i].px, minx - ox);
        qy[i] = toQ(cmd.v[i].py, miny - oy);
    }

    // Twice the signed area, in q-space rather than in whole pixels: a
    // triangle degenerate at integer precision can have real area once PGXP
    // resolves its vertices.
    const area = (qx[1] - qx[0]) * (qy[2] - qy[0]) - (qy[1] - qy[0]) * (qx[2] - qx[0]);
    if (area == 0) return null;

    // One pixel wider than the integer vertices on every side, because a
    // sub-pixel vertex can push coverage past them.
    const clip = env.area();
    const x0 = @max(clip.x0, @max(0, minx - 1));
    const x1 = @min(clip.x1, @min(pi.native_width - 1, maxx + 1));
    const y0 = @max(clip.y0, @max(0, miny - 1));
    const y1 = @min(clip.y1, @min(pi.native_height - 1, maxy + 1));
    if (x0 > x1 or y0 > y1) return null;

    var inst = base(env);
    inst.kind = kind;
    inst.box_x0 = @intCast(x0);
    inst.box_y0 = @intCast(y0);
    inst.box_x1 = @intCast(x1);
    inst.box_y1 = @intCast(y1);
    inst.x0 = @intCast(vx[0]);
    inst.y0 = @intCast(vy[0]);
    inst.x1 = @intCast(vx[1]);
    inst.y1 = @intCast(vy[1]);
    inst.x2 = @intCast(vx[2]);
    inst.y2 = @intCast(vy[2]);
    inst.qx0 = qx[0];
    inst.qy0 = qy[0];
    inst.qx1 = qx[1];
    inst.qy1 = qy[1];
    inst.qx2 = qx[2];
    inst.qy2 = qy[2];
    inst.u0 = cmd.v[0].u;
    inst.v0 = cmd.v[0].v;
    inst.u1 = cmd.v[1].u;
    inst.v1 = cmd.v[1].v;
    inst.u2 = cmd.v[2].u;
    inst.v2 = cmd.v[2].v;
    // Native, like every other field: the reciprocal is a property of the
    // geometry. Zero on every non-PGXP vertex, which is the affine path.
    inst.rw0 = cmd.v[0].rw;
    inst.rw1 = cmd.v[1].rw;
    inst.rw2 = cmd.v[2].rw;
    inst.iz0 = cmd.v[0].iz;
    inst.iz1 = cmd.v[1].iz;
    inst.iz2 = cmd.v[2].iz;
    inst.c0 = cmd.v[0].color;
    inst.c1 = cmd.v[1].color;
    inst.c2 = cmd.v[2].color;
    inst.color = cmd.value & 0xFFFF;
    if (cmd.transparent != 0) inst.flags |= Flag.transparent;
    // Two namespaces, deliberately: the record's bits describe a GP0
    // primitive, the instance's describe one Metal draw. Translated here
    // rather than shared as one constant: the two structs version
    // independently.
    if (cmd.flags & command.flag_texture_perspective != 0) inst.flags |= Flag.texture_perspective;
    if (cmd.flags & command.flag_color_perspective != 0) inst.flags |= Flag.color_perspective;
    if (cmd.flags & command.flag_depth_test != 0) inst.flags |= Flag.depth_test;
    if (cmd.flags & command.flag_depth_write != 0) inst.flags |= Flag.depth_write;
    return inst;
}

/// A rectangle's box is clamped to VRAM ONLY: the drawing-area clip stays in
/// the shader, because `renderer.zig` does the VRAM bounds check itself and
/// then lets `putPixel` apply the clip.
pub fn rectangle(cmd: Command, env: DrawingEnv, kind: i32) ?PrimInstance {
    const w: i64 = cmd.w;
    const h: i64 = cmd.h;
    // The same refusal the polygon and line paths apply: 1024 or more wide,
    // or 512 or more tall, is DROPPED rather than clipped.
    if (!(w > 0 and h > 0 and w < 1024 and h < 512)) return null;

    const ox = @as(i64, cmd.x) + env.getOffsetX();
    const oy = @as(i64, cmd.y) + env.getOffsetY();
    const x0 = @max(ox, 0);
    const y0 = @max(oy, 0);
    const x1 = @min(ox + w - 1, pi.native_width - 1);
    const y1 = @min(oy + h - 1, pi.native_height - 1);
    if (x0 > x1 or y0 > y1) return null;

    var inst = base(env);
    inst.kind = kind;
    inst.box_x0 = @intCast(x0);
    inst.box_y0 = @intCast(y0);
    inst.box_x1 = @intCast(x1);
    inst.box_y1 = @intCast(y1);
    inst.x0 = @intCast(ox);
    inst.y0 = @intCast(oy);
    inst.w = @intCast(w);
    inst.h = @intCast(h);
    inst.color = cmd.value & 0xFFFF;
    inst.u0 = cmd.v[0].u;
    inst.v0 = cmd.v[0].v;
    if (cmd.transparent != 0) inst.flags |= Flag.transparent;
    return inst;
}

/// `clut` and `tpage` decoded exactly as `renderer.zig` does. `tpage & 0xF` is
/// the page X in 64-pixel units; bit 4 is page Y (0 or 256); bits 7-8 the
/// colour depth. The clut row is 9 bits (it can reach row 511), and `clut_x`
/// is in 16-pixel units.
pub fn applyTexture(cmd: Command, inst: *PrimInstance) void {
    inst.tex_depth = (@as(u32, cmd.tpage) >> 7) & 3;
    inst.tpage_x = @as(u32, cmd.tpage & 0xF) * 64;
    inst.tpage_y = if (cmd.tpage & 0x10 != 0) 256 else 0;
    inst.clut_x = @as(u32, cmd.clut & 0x3F) * 16;
    inst.clut_y = (@as(u32, cmd.clut) >> 6) & 0x1FF;
    // Opcode bit 0 CLEAR means modulate; set means raw.
    if (cmd.opcode & 1 == 0) inst.flags |= Flag.modulate;
}

/// One read span as a conservative superset of VRAM rects, written to
/// `out[0..n]`. `ps1_vram_read` (`Ps1Color.h`) does NOT clamp `x` to the row:
/// it linearizes `y*1024+x` and masks the result with `& 0x7FFFF`, which is
/// wraparound over the WHOLE linear space, not per row: an `x` past 1023 lands
/// at the START of row `y+1`, UNLESS `y` was already VRAM's last row (511), in
/// which case the mask wraps the address back to row 0.
///
/// A row in the middle of a span wrapping to the row below needs no special
/// handling: that row is still inside the span, and widening every row in
/// `[y0, lastRow]` to the full VRAM width already covers it. Only the span's
/// own last row can overflow past a row that doesn't exist, so exactly two
/// cases follow: extend by one row when there is a next row, or add a second
/// rect for the row-0 wrap target. One extra row/rect is always enough: the
/// overflow is `(x0 + width - 1) - 1023` columns, with `x0 < 1024` and
/// `width <= 256`, so the wrapped tail never wraps a second time.
fn conservativeRect(out: []VramRect, x0: i32, y0: i32, width: i32, height: i32) usize {
    if (x0 + width - 1 < pi.native_width) {
        out[0] = .{
            .x0 = x0,
            .y0 = y0,
            .x1 = @min(x0 + width - 1, pi.native_width - 1),
            .y1 = @min(y0 + height - 1, pi.native_height - 1),
        };
        return 1;
    }
    const last_row = y0 + height - 1;
    var span: VramRect = .{ .x0 = 0, .y0 = y0, .x1 = pi.native_width - 1, .y1 = last_row };
    if (last_row == pi.native_height - 1) {
        out[0] = span;
        out[1] = .{ .x0 = 0, .y0 = 0, .x1 = pi.native_width - 1, .y1 = 0 };
        return 2;
    }
    span.y1 = last_row + 1;
    out[0] = span;
    return 1;
}

/// What a primitive reads, as up to four rectangles: its texture page,
/// possibly split by the row-511 wrap above, and, at 4bpp/8bpp, its CLUT row,
/// same split possible.
///
/// Two rectangles (page, CLUT) rather than one bounding box on purpose. A CLUT
/// usually sits far from the page it serves, and a box spanning both would
/// cover most of VRAM: splitting passes that need no split costs throughput
/// without moving a single pixel, so no hash gate would ever notice.
///
/// Conservative on the page: v is an 8-bit field, so a page is 256 rows tall,
/// and its width in VRAM words is 64 / 128 / 256 by depth.
pub fn sampledRects(inst: PrimInstance, out: *[4]VramRect) []const VramRect {
    if (inst.kind != Kind.textured_tri and inst.kind != Kind.textured_rect) return out[0..0];
    const words = [3]i32{ 64, 128, 256 };
    var n = conservativeRect(out[0..], @intCast(inst.tpage_x), @intCast(inst.tpage_y), words[@min(inst.tex_depth, 2)], 256);
    if (inst.tex_depth < 2) {
        const entries: i32 = if (inst.tex_depth == 0) 16 else 256;
        n += conservativeRect(out[n..], @intCast(inst.clut_x), @intCast(inst.clut_y), entries, 1);
    }
    return out[0..n];
}
