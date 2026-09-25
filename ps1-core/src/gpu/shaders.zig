//! The per-primitive shaders `Renderer.rasterizeTriangle` calls once per
//! covered pixel. Each takes the pixel's three un-biased barycentric weights
//! and the triangle's twice-area and decides that pixel's colour; coverage,
//! the fill rule and the VRAM write stay in `renderer.zig`.

const std = @import("std");
const Vram = @import("vram.zig").Vram;
const Color = @import("color.zig");
const Renderer = @import("renderer.zig").Renderer;

pub const ShadeResult = struct { color: u16, is_transparent: bool, draw: bool };

pub const MonoShader = struct {
    color: u16,

    pub fn shade(ctx: MonoShader, _: i32, _: i32, _: i32, _: i32, _: i16, _: i16, is_transp: bool) ShadeResult {
        return .{ .color = ctx.color, .is_transparent = is_transp, .draw = true };
    }
};

pub const ShadedShader = struct {
    r: [3]i32,
    g: [3]i32,
    b: [3]i32,
    rw: [3]i32,
    perspective: bool,
    dither_enabled: bool,

    pub fn shade(ctx: ShadedShader, w0: i32, w1: i32, w2: i32, area: i32, px: i16, py: i16, is_transp: bool) ShadeResult {
        var r = Renderer.interpAttr(ctx.perspective, w0, w1, w2, area, ctx.r[0], ctx.r[1], ctx.r[2], ctx.rw[0], ctx.rw[1], ctx.rw[2]);
        var g = Renderer.interpAttr(ctx.perspective, w0, w1, w2, area, ctx.g[0], ctx.g[1], ctx.g[2], ctx.rw[0], ctx.rw[1], ctx.rw[2]);
        var b = Renderer.interpAttr(ctx.perspective, w0, w1, w2, area, ctx.b[0], ctx.b[1], ctx.b[2], ctx.rw[0], ctx.rw[1], ctx.rw[2]);

        if (ctx.dither_enabled) {
            const offset: i32 = Color.dither_table[@intCast(@mod(py, 4))][@intCast(@mod(px, 4))];
            r += offset;
            g += offset;
            b += offset;
        }

        // Dither is an 8-bit-scale offset, so it is added before the
        // shift to 5 bits, and the clamp is at 8-bit range. That
        // ordering is also why the interpolant's inputs stay unsigned:
        // nothing subtracts from a channel before it is interpolated.
        const r5: u16 = @intCast(std.math.clamp(r, 0, 255) >> 3);
        const g5: u16 = @intCast(std.math.clamp(g, 0, 255) >> 3);
        const b5: u16 = @intCast(std.math.clamp(b, 0, 255) >> 3);

        return .{ .color = (b5 << 10) | (g5 << 5) | r5, .is_transparent = is_transp, .draw = true };
    }
};

pub const TexturedShader = struct {
    vram: *Vram,
    cr: [3]i32,
    cg: [3]i32,
    cb: [3]i32,
    tu: [3]i32,
    tv: [3]i32,
    tex_depth: u32,
    tpage_x: u16,
    tpage_y: u16,
    clut_x: u16,
    clut_y: u16,
    opcode: u8,
    tex_window: u32,
    dither_enabled: bool,
    rw: [3]i32,
    perspective_texture: bool,
    perspective_color: bool,

    pub fn shade(ctx: TexturedShader, w0: i32, w1: i32, w2: i32, area: i32, px: i16, py: i16, is_transp: bool) ShadeResult {
        // u/v are 8-bit fields on the wire, and coverage guarantees
        // every un-biased w_i >= 0 with w0+w1+w2 == area exactly, so
        // the interpolant is a convex combination of three in-range
        // values on every covered pixel, boundary ones included --
        // this clamp cannot actually trigger. Kept as a defensive
        // guard anyway; a future Metal shader may want the same one.
        const iu = Renderer.interpAttr(ctx.perspective_texture, w0, w1, w2, area, ctx.tu[0], ctx.tu[1], ctx.tu[2], ctx.rw[0], ctx.rw[1], ctx.rw[2]);
        const iv = Renderer.interpAttr(ctx.perspective_texture, w0, w1, w2, area, ctx.tv[0], ctx.tv[1], ctx.tv[2], ctx.rw[0], ctx.rw[1], ctx.rw[2]);
        const u: u32 = @intCast(std.math.clamp(iu, 0, 255));
        const v: u32 = @intCast(std.math.clamp(iv, 0, 255));

        // T-Window masking
        const mask_x = (ctx.tex_window & 0x1F) * 8;
        const mask_y = ((ctx.tex_window >> 5) & 0x1F) * 8;
        const offset_x = ((ctx.tex_window >> 10) & 0x1F) * 8;
        const offset_y = ((ctx.tex_window >> 15) & 0x1F) * 8;

        const final_u = (u & ~mask_x) | (offset_x & mask_x);
        const final_v = (v & ~mask_y) | (offset_y & mask_y);

        const texel = Color.fetchTexel(ctx.vram, ctx.tex_depth, ctx.tpage_x, ctx.tpage_y, ctx.clut_x, ctx.clut_y, final_u, final_v);

        if (texel == 0) return .{ .color = 0, .is_transparent = false, .draw = false };

        var final_texel = texel;
        if ((ctx.opcode & 1) == 0) { // Modulation
            // The three colours are equal on a flat-shaded primitive,
            // and both interpolants reproduce an equal triple exactly —
            // `interp` because w0+w1+w2 == area, `interpW` because the
            // weighted sum factors out — so a flat-shaded textured
            // polygon is bit-identical whether colour correction is on
            // or off. `gp0` refuses it the bit as well.
            const cr: u16 = @intCast(Renderer.interpAttr(ctx.perspective_color, w0, w1, w2, area, ctx.cr[0], ctx.cr[1], ctx.cr[2], ctx.rw[0], ctx.rw[1], ctx.rw[2]) >> 3);
            const cg: u16 = @intCast(Renderer.interpAttr(ctx.perspective_color, w0, w1, w2, area, ctx.cg[0], ctx.cg[1], ctx.cg[2], ctx.rw[0], ctx.rw[1], ctx.rw[2]) >> 3);
            const cb: u16 = @intCast(Renderer.interpAttr(ctx.perspective_color, w0, w1, w2, area, ctx.cb[0], ctx.cb[1], ctx.cb[2], ctx.rw[0], ctx.rw[1], ctx.rw[2]) >> 3);
            const shade_color: u16 = (cb << 10) | (cg << 5) | cr;
            final_texel = Color.modulate(texel, shade_color, @as(i32, px), @as(i32, py), ctx.dither_enabled);
        }

        return .{ .color = final_texel, .is_transparent = is_transp and ((final_texel & 0x8000) != 0), .draw = true };
    }
};
