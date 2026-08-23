const std = @import("std");
const Vram = @import("vram.zig").Vram;
const DrawingEnv = @import("registers.zig").DrawingEnv;
const constants = @import("../constants.zig");
const Color = @import("color.zig");

pub const Renderer = struct {
    pub fn putPixel(vram: *Vram, env: *const DrawingEnv, x: i16, y: i16, color: u16, is_transparent: bool) void {
        // Hardware Clipping
        const draw_x0 = @as(i16, @intCast(env.area_top_left & 0x3FF));
        const draw_y0 = @as(i16, @intCast((env.area_top_left >> 10) & 0x3FF));
        const draw_x1 = @as(i16, @intCast(env.area_bot_right & 0x3FF));
        const draw_y1 = @as(i16, @intCast((env.area_bot_right >> 10) & 0x3FF));

        if (x < draw_x0 or x > draw_x1 or y < draw_y0 or y > draw_y1) return;
        if (x < 0 or x >= constants.vram_width or y < 0 or y >= constants.vram_height) return;

        const idx = Vram.index(@as(usize, @intCast(x)), @as(usize, @intCast(y)));

        // Mask Bit Evaluation
        const mask_ctrl = env.mask_bit;
        const set_mask = (mask_ctrl & 1) != 0;
        const check_mask = (mask_ctrl & 2) != 0;

        const bg_pixel = vram.data[idx];
        if (check_mask and (bg_pixel & 0x8000) != 0) return;

        var final_color = color;

        if (is_transparent) {
            const blend_mode: u2 = @intCast((env.draw_mode >> 5) & 3);
            final_color = Color.blend(bg_pixel, color, blend_mode);
        }

        // Bit15 of the written pixel is the source pixel's own bit15 — for a
        // textured primitive that is the texel's semi-transparency bit, for an
        // untextured one it is 0 — OR'd with GP0(E6).bit0. It must NOT be
        // cleared: games mask off already-drawn areas by leaving STP-set texels
        // in VRAM and then drawing with check-mask (Silent Hill brackets its
        // per-character fog quad with E6=3 exactly this way, and the quad shows
        // up as a bright box over the whole sprite bounding rect if every VRAM
        // pixel reads back as unmasked).
        if (set_mask) final_color |= 0x8000;

        vram.data[idx] = final_color;
    }

    /// Twice the signed area of (a, b, c). Positive for one winding, negative
    /// for the other; zero for a degenerate triangle.
    fn orient2d(ax: i32, ay: i32, bx: i32, by: i32, cx: i32, cy: i32) i32 {
        return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
    }

    /// Top-left fill rule. `dx`/`dy` is the edge's direction vector in the
    /// positive-area winding. An edge that fails this test drops the pixels
    /// landing exactly on it, so two triangles sharing an edge paint each
    /// pixel exactly once instead of leaving a seam or double-blending it.
    fn isTopLeft(dx: i32, dy: i32) bool {
        return dy > 0 or (dy == 0 and dx < 0);
    }

    pub const ShadeResult = struct { color: u16, is_transparent: bool, draw: bool };

    fn rasterizeTriangle(
        vram: *Vram,
        env: *const DrawingEnv,
        x0: i16,
        y0: i16,
        x1: i16,
        y1: i16,
        x2: i16,
        y2: i16,
        allow_transparency: bool,
        comptime Shader: type,
        shader_ctx: anytype,
    ) void {
        const ox: i32 = env.getOffsetX();
        const oy: i32 = env.getOffsetY();

        const vx0: i32 = @as(i32, x0) + ox;
        const vy0: i32 = @as(i32, y0) + oy;
        const vx1: i32 = @as(i32, x1) + ox;
        const vy1: i32 = @as(i32, y1) + oy;
        const vx2: i32 = @as(i32, x2) + ox;
        const vy2: i32 = @as(i32, y2) + oy;

        // Hardware refuses any primitive whose vertices span 1024 or more
        // horizontally, or 512 or more vertically -- it is not clipped, it is
        // dropped outright. Games lean on that: geometry that crosses the near
        // plane projects to enormous saturated screen coordinates, and the
        // drop is what keeps it off the screen. Drawing it instead paints
        // scenery across the camera (Silent Hill's roadside foliage).
        if (@max(vx0, @max(vx1, vx2)) - @min(vx0, @min(vx1, vx2)) >= 1024) return;
        if (@max(vy0, @max(vy1, vy2)) - @min(vy0, @min(vy1, vy2)) >= 512) return;

        const draw_x0: i32 = @intCast(env.area_top_left & 0x3FF);
        const draw_y0: i32 = @intCast((env.area_top_left >> 10) & 0x3FF);
        const draw_x1: i32 = @intCast(env.area_bot_right & 0x3FF);
        const draw_y1: i32 = @intCast((env.area_bot_right >> 10) & 0x3FF);

        const min_x = @max(draw_x0, @max(0, @min(vx0, @min(vx1, vx2))));
        const max_x = @min(draw_x1, @min(constants.vram_width - 1, @max(vx0, @max(vx1, vx2))));
        const min_y = @max(draw_y0, @max(0, @min(vy0, @min(vy1, vy2))));
        const max_y = @min(draw_y1, @min(constants.vram_height - 1, @max(vy0, @max(vy1, vy2))));

        if (min_x > max_x or min_y > max_y) return;

        const area_signed = orient2d(vx0, vy0, vx1, vy1, vx2, vy2);
        if (area_signed == 0) return;

        // Normalize to a positive area by flipping the sign of every edge
        // function rather than by swapping two vertices. Avocado swaps
        // (primitive.h assureCcw), but a swap would permute the attributes the
        // shader indexes by vertex number; the sign flip leaves w_i paired
        // with vertex i, and w_i/area is unchanged because both are negated.
        const s: i32 = if (area_signed < 0) -1 else 1;
        const area: i32 = area_signed * s;

        const dw0dx = s * (vy1 - vy2);
        const dw0dy = s * (vx2 - vx1);
        const dw1dx = s * (vy2 - vy0);
        const dw1dy = s * (vx0 - vx2);
        const dw2dx = s * (vy0 - vy1);
        const dw2dy = s * (vx1 - vx0);

        // The edge for barycentric i runs v[i+1] -> v[i+2] in the normalized
        // winding, so its direction picks up the same sign flip.
        const bias0: i32 = if (isTopLeft(s * (vx2 - vx1), s * (vy2 - vy1))) -1 else 0;
        const bias1: i32 = if (isTopLeft(s * (vx0 - vx2), s * (vy0 - vy2))) -1 else 0;
        const bias2: i32 = if (isTopLeft(s * (vx1 - vx0), s * (vy1 - vy0))) -1 else 0;

        var row0 = s * orient2d(vx1, vy1, vx2, vy2, min_x, min_y) + bias0;
        var row1 = s * orient2d(vx2, vy2, vx0, vy0, min_x, min_y) + bias1;
        var row2 = s * orient2d(vx0, vy0, vx1, vy1, min_x, min_y) + bias2;

        var py = min_y;
        while (py <= max_y) : (py += 1) {
            var w0 = row0;
            var w1 = row1;
            var w2 = row2;

            var px = min_x;
            while (px <= max_x) : (px += 1) {
                // Avocado's coverage test verbatim: a negative term sets the
                // sign bit of the OR, so this means "all three non-negative,
                // and not all three zero".
                if ((w0 | w1 | w2) > 0) {
                    const px16: i16 = @intCast(px);
                    const py16: i16 = @intCast(py);
                    // The bias is a coverage device only -- attributes must be
                    // interpolated from the true barycentric numerators.
                    const out = Shader.shade(shader_ctx, w0 - bias0, w1 - bias1, w2 - bias2, area, px16, py16, allow_transparency);
                    if (out.draw) {
                        putPixel(vram, env, px16, py16, out.color, out.is_transparent);
                    }
                }
                w0 += dw0dx;
                w1 += dw1dx;
                w2 += dw2dx;
            }

            row0 += dw0dy;
            row1 += dw1dy;
            row2 += dw2dy;
        }
    }

    pub fn drawTriangle(
        vram: *Vram,
        env: *const DrawingEnv,
        x0: i16,
        y0: i16,
        x1: i16,
        y1: i16,
        x2: i16,
        y2: i16,
        color: u16,
        is_transparent: bool,
    ) void {
        const MonoShader = struct {
            color: u16,
            pub fn shade(ctx: @This(), _: i32, _: i32, _: i32, _: i32, _: i16, _: i16, is_transp: bool) ShadeResult {
                return .{ .color = ctx.color, .is_transparent = is_transp, .draw = true };
            }
        };
        rasterizeTriangle(vram, env, x0, y0, x1, y1, x2, y2, is_transparent, MonoShader, MonoShader{ .color = color });
    }

    pub fn drawShadedTriangle(
        vram: *Vram,
        env: *const DrawingEnv,
        x0: i16,
        y0: i16,
        c0: u32,
        x1: i16,
        y1: i16,
        c1: u32,
        x2: i16,
        y2: i16,
        c2: u32,
        is_transparent: bool,
    ) void {
        const ShadedShader = struct {
            r0: f32,
            g0: f32,
            b0: f32,
            r1: f32,
            g1: f32,
            b1: f32,
            r2: f32,
            g2: f32,
            b2: f32,
            dither_enabled: bool,
            pub fn shade(ctx: @This(), w0: i32, w1: i32, w2: i32, area: i32, px: i16, py: i16, is_transp: bool) ShadeResult {
                const f0 = @as(f32, @floatFromInt(w0)) / @as(f32, @floatFromInt(area));
                const f1 = @as(f32, @floatFromInt(w1)) / @as(f32, @floatFromInt(area));
                const f2 = @as(f32, @floatFromInt(w2)) / @as(f32, @floatFromInt(area));

                var r_f = f0 * ctx.r0 + f1 * ctx.r1 + f2 * ctx.r2;
                var g_f = f0 * ctx.g0 + f1 * ctx.g1 + f2 * ctx.g2;
                var b_f = f0 * ctx.b0 + f1 * ctx.b1 + f2 * ctx.b2;

                if (ctx.dither_enabled) {
                    const offset = @as(f32, @floatFromInt(Color.dither_table[@intCast(@mod(py, 4))][@intCast(@mod(px, 4))]));
                    r_f += offset;
                    g_f += offset;
                    b_f += offset;
                }

                const r = @as(u16, @intFromFloat(std.math.clamp(r_f / 8.0, 0, 31)));
                const g = @as(u16, @intFromFloat(std.math.clamp(g_f / 8.0, 0, 31)));
                const b = @as(u16, @intFromFloat(std.math.clamp(b_f / 8.0, 0, 31)));

                return .{ .color = (b << 10) | (g << 5) | r, .is_transparent = is_transp, .draw = true };
            }
        };
        rasterizeTriangle(vram, env, x0, y0, x1, y1, x2, y2, is_transparent, ShadedShader, ShadedShader{
            .r0 = @floatFromInt(c0 & 0xFF),
            .g0 = @floatFromInt((c0 >> 8) & 0xFF),
            .b0 = @floatFromInt((c0 >> 16) & 0xFF),
            .r1 = @floatFromInt(c1 & 0xFF),
            .g1 = @floatFromInt((c1 >> 8) & 0xFF),
            .b1 = @floatFromInt((c1 >> 16) & 0xFF),
            .r2 = @floatFromInt(c2 & 0xFF),
            .g2 = @floatFromInt((c2 >> 8) & 0xFF),
            .b2 = @floatFromInt((c2 >> 16) & 0xFF),
            .dither_enabled = (env.draw_mode & (1 << 9)) != 0,
        });
    }

    pub fn drawRectangle(vram: *Vram, env: *const DrawingEnv, x: i16, y: i16, w: i32, h: i32, color: u16, is_transparent: bool) void {
        // Same refusal the polygon and line paths apply: a rectangle 1024 or
        // more wide, or 512 or more tall, is dropped rather than clipped. The
        // GP0 size field is 16 bits, so nothing else bounds it.
        if (w >= 1024 or h >= 512) return;
        const ox: i32 = env.getOffsetX();
        const oy: i32 = env.getOffsetY();
        var yy: i32 = 0;
        while (yy < h) : (yy += 1) {
            var xx: i32 = 0;
            while (xx < w) : (xx += 1) {
                const px = @as(i32, x) + xx + ox;
                const py = @as(i32, y) + yy + oy;
                if (px < 0 or px >= constants.vram_width or py < 0 or py >= constants.vram_height) continue;
                putPixel(vram, env, @intCast(px), @intCast(py), color, is_transparent);
            }
        }
    }

    pub fn drawLine(vram: *Vram, env: *const DrawingEnv, x0: i16, y0: i16, x1: i16, y1: i16, color: u16, is_transparent: bool) void {
        const ox = env.getOffsetX();
        const oy = env.getOffsetY();
        var cx = x0 + ox;
        var cy = y0 + oy;
        const target_x = x1 + ox;
        const target_y = y1 + oy;
        const dx = @abs(target_x - cx);
        const dy = @abs(target_y - cy);
        // Same 1023x511 refusal the triangle rasterizer applies -- hardware
        // drops an oversized line rather than clipping it.
        if (dx >= 1024 or dy >= 512) return;
        const sx: i16 = if (cx < target_x) 1 else -1;
        const sy: i16 = if (cy < target_y) 1 else -1;
        var err = @as(i32, @intCast(dx)) - @as(i32, @intCast(dy));
        while (true) {
            putPixel(vram, env, cx, cy, color, is_transparent);
            if (cx == target_x and cy == target_y) break;
            const e2 = 2 * err;
            if (e2 > -@as(i32, @intCast(dy))) {
                err -= @as(i32, @intCast(dy));
                cx += sx;
            }
            if (e2 < @as(i32, @intCast(dx))) {
                err += @as(i32, @intCast(dx));
                cy += sy;
            }
        }
    }

    pub fn drawShadedLine(vram: *Vram, env: *const DrawingEnv, x0: i16, y0: i16, c0: u32, x1: i16, y1: i16, c1: u32, is_transparent: bool) void {
        const ox = env.getOffsetX();
        const oy = env.getOffsetY();
        var cx = x0 + ox;
        var cy = y0 + oy;
        const target_x = x1 + ox;
        const target_y = y1 + oy;
        const dx = @abs(target_x - cx);
        const dy = @abs(target_y - cy);
        // Same 1023x511 refusal the triangle rasterizer applies -- hardware
        // drops an oversized line rather than clipping it.
        if (dx >= 1024 or dy >= 512) return;
        const sx: i16 = if (cx < target_x) 1 else -1;
        const sy: i16 = if (cy < target_y) 1 else -1;
        var err = @as(i32, @intCast(dx)) - @as(i32, @intCast(dy));

        const r0 = @as(f32, @floatFromInt(c0 & 0xFF));
        const g0 = @as(f32, @floatFromInt((c0 >> 8) & 0xFF));
        const b0 = @as(f32, @floatFromInt((c0 >> 16) & 0xFF));
        const r1 = @as(f32, @floatFromInt(c1 & 0xFF));
        const g1 = @as(f32, @floatFromInt((c1 >> 8) & 0xFF));
        const b1 = @as(f32, @floatFromInt((c1 >> 16) & 0xFF));

        const steps = @as(f32, @floatFromInt(@max(dx, dy)));
        if (steps == 0) {
            const r = @as(u16, @intFromFloat(std.math.clamp(r0 / 8.0, 0, 31)));
            const g = @as(u16, @intFromFloat(std.math.clamp(g0 / 8.0, 0, 31)));
            const b = @as(u16, @intFromFloat(std.math.clamp(b0 / 8.0, 0, 31)));
            putPixel(vram, env, cx, cy, (b << 10) | (g << 5) | r, is_transparent);
            return;
        }

        const dr = (r1 - r0) / steps;
        const dg = (g1 - g0) / steps;
        const db = (b1 - b0) / steps;
        var curr_r = r0;
        var curr_g = g0;
        var curr_b = b0;

        const dither_enabled = (env.draw_mode & (1 << 9)) != 0;

        while (true) {
            var r_f = curr_r;
            var g_f = curr_g;
            var b_f = curr_b;

            if (dither_enabled) {
                const offset = @as(f32, @floatFromInt(Color.dither_table[@intCast(@mod(cy, 4))][@intCast(@mod(cx, 4))]));
                r_f += offset;
                g_f += offset;
                b_f += offset;
            }

            const r = @as(u16, @intFromFloat(std.math.clamp(r_f / 8.0, 0, 31)));
            const g = @as(u16, @intFromFloat(std.math.clamp(g_f / 8.0, 0, 31)));
            const b = @as(u16, @intFromFloat(std.math.clamp(b_f / 8.0, 0, 31)));

            putPixel(vram, env, cx, cy, (b << 10) | (g << 5) | r, is_transparent);
            if (cx == target_x and cy == target_y) break;
            const e2 = 2 * err;
            if (e2 > -@as(i32, @intCast(dy))) {
                err -= @as(i32, @intCast(dy));
                cx += sx;
            }
            if (e2 < @as(i32, @intCast(dx))) {
                err += @as(i32, @intCast(dx));
                cy += sy;
            }
            curr_r += dr;
            curr_g += dg;
            curr_b += db;
        }
    }

    pub fn drawTexturedTriangle(
        vram: *Vram,
        env: *const DrawingEnv,
        x0: i16,
        y0: i16,
        tu0: u8,
        tv0: u8,
        x1: i16,
        y1: i16,
        tu1: u8,
        tv1: u8,
        x2: i16,
        y2: i16,
        tu2: u8,
        tv2: u8,
        color: u16,
        clut: u16,
        tpage: u16,
        allow_transparency: bool,
        opcode: u8,
    ) void {
        const TexturedShader = struct {
            vram: *Vram,
            color: u16,
            tu0: f32,
            tv0: f32,
            tu1: f32,
            tv1: f32,
            tu2: f32,
            tv2: f32,
            tex_depth: u32,
            tpage_x: u16,
            tpage_y: u16,
            clut_x: u16,
            clut_y: u16,
            opcode: u8,
            tex_window: u32,
            dither_enabled: bool,

            pub fn shade(ctx: @This(), w0: i32, w1: i32, w2: i32, area: i32, px: i16, py: i16, is_transp: bool) ShadeResult {
                const f0 = @as(f32, @floatFromInt(w0)) / @as(f32, @floatFromInt(area));
                const f1 = @as(f32, @floatFromInt(w1)) / @as(f32, @floatFromInt(area));
                const f2 = @as(f32, @floatFromInt(w2)) / @as(f32, @floatFromInt(area));

                const u = @as(u16, @intFromFloat(@abs(f0 * ctx.tu0 + f1 * ctx.tu1 + f2 * ctx.tu2)));
                const v = @as(u16, @intFromFloat(@abs(f0 * ctx.tv0 + f1 * ctx.tv1 + f2 * ctx.tv2)));

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
                    final_texel = Color.modulate(texel, ctx.color, @as(i32, px), @as(i32, py), ctx.dither_enabled);
                }

                return .{ .color = final_texel, .is_transparent = is_transp and ((final_texel & 0x8000) != 0), .draw = true };
            }
        };

        rasterizeTriangle(vram, env, x0, y0, x1, y1, x2, y2, allow_transparency, TexturedShader, TexturedShader{
            .vram = vram,
            .color = color,
            .tu0 = @floatFromInt(tu0),
            .tv0 = @floatFromInt(tv0),
            .tu1 = @floatFromInt(tu1),
            .tv1 = @floatFromInt(tv1),
            .tu2 = @floatFromInt(tu2),
            .tv2 = @floatFromInt(tv2),
            .tex_depth = (tpage >> 7) & 3,
            .tpage_x = (tpage & 0xF) * 64,
            .tpage_y = if ((tpage & 0x10) != 0) @as(u16, 256) else 0,
            .clut_x = (clut & 0x3F) * 16,
            .clut_y = (clut >> 6) & 0x1FF,
            .opcode = opcode,
            .tex_window = env.tex_window,
            .dither_enabled = (env.draw_mode & (1 << 9)) != 0,
        });
    }

    pub fn drawTexturedRectangle(
        vram: *Vram,
        env: *const DrawingEnv,
        x: i16,
        y: i16,
        w: i32,
        h: i32,
        tu: u8,
        tv: u8,
        color: u16,
        clut: u16,
        tpage: u16,
        allow_transparency: bool,
        opcode: u8,
    ) void {
        // Same refusal the polygon and line paths apply: a rectangle 1024 or
        // more wide, or 512 or more tall, is dropped rather than clipped. The
        // GP0 size field is 16 bits, so nothing else bounds it.
        if (w >= 1024 or h >= 512) return;

        const ox: i32 = env.getOffsetX();
        const oy: i32 = env.getOffsetY();

        const tex_depth = (tpage >> 7) & 3;
        const tpage_x = (tpage & 0xF) * 64;
        const tpage_y = if ((tpage & 0x10) != 0) @as(u16, 256) else 0;
        const clut_x = (clut & 0x3F) * 16;
        const clut_y = (clut >> 6) & 0x1FF;
        const dither_enabled = (env.draw_mode & (1 << 9)) != 0;

        var yy: i32 = 0;
        while (yy < h) : (yy += 1) {
            var xx: i32 = 0;
            while (xx < w) : (xx += 1) {
                const px = @as(i32, x) + xx + ox;
                const py = @as(i32, y) + yy + oy;

                const u = tu +% @as(u8, @truncate(@as(u32, @intCast(xx))));
                const v = tv +% @as(u8, @truncate(@as(u32, @intCast(yy))));

                const mask_x = (env.tex_window & 0x1F) * 8;
                const mask_y = ((env.tex_window >> 5) & 0x1F) * 8;
                const offset_x = ((env.tex_window >> 10) & 0x1F) * 8;
                const offset_y = ((env.tex_window >> 15) & 0x1F) * 8;

                const final_u = (@as(u32, u) & ~mask_x) | (offset_x & mask_x);
                const final_v = (@as(u32, v) & ~mask_y) | (offset_y & mask_y);

                const texel = Color.fetchTexel(vram, tex_depth, tpage_x, tpage_y, clut_x, clut_y, final_u, final_v);

                if (texel == 0) continue;

                var final_texel = texel;
                if ((opcode & 1) == 0) {
                    final_texel = Color.modulate(texel, color, px, py, dither_enabled);
                }

                const is_transp = allow_transparency and ((final_texel & 0x8000) != 0);
                if (px < 0 or px >= constants.vram_width or py < 0 or py >= constants.vram_height) continue;
                putPixel(vram, env, @intCast(px), @intCast(py), final_texel, is_transp);
            }
        }
    }
};
