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

    /// Exact barycentric interpolation of one integer attribute.
    ///
    /// Position-evaluable by construction: a Metal fragment shader gets (px,
    /// py), recomputes the three weights from the plane equations and
    /// evaluates this same expression, with no incremental state to carry.
    /// That is why this is NOT the fixed-point delta stepping Avocado
    /// implements and then disables ("Fixed point has some rounding issue",
    /// render_triangle.cpp) -- stepping accumulates error along a span and
    /// cannot be reproduced per-pixel.
    ///
    /// i64 is load-bearing: the constant term of the expanded plane equation
    /// exceeds i32 for a triangle at the far end of VRAM.
    ///
    /// Deliberately diverges from Avocado's `calculateStartAttribute`
    /// (render_triangle.cpp), which adds `+ 0.5f` before truncating and folds
    /// the fill-rule bias into the constant term. This is a pure `@divFloor`
    /// of the exact numerator over un-biased weights instead, which sits a
    /// systematic half-LSB below Avocado's rounded result. That is intended
    /// and frozen with the Phase 0 goldens -- do not "fix" it to match
    /// Avocado during a later diff, or the frozen baseline breaks.
    fn interp(w0: i32, w1: i32, w2: i32, area: i32, a0: i32, a1: i32, a2: i32) i32 {
        const num = @as(i64, w0) * @as(i64, a0) +
            @as(i64, w1) * @as(i64, a1) +
            @as(i64, w2) * @as(i64, a2);
        // area > 0 and, inside the triangle, every w_i >= 0 and every a_i >= 0,
        // so @divFloor and @divTrunc agree; @divFloor is used because it stays
        // defined on the boundary pixels the fill rule admits.
        return @intCast(@divFloor(num, @as(i64, area)));
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
            r: [3]i32,
            g: [3]i32,
            b: [3]i32,
            dither_enabled: bool,
            pub fn shade(ctx: @This(), w0: i32, w1: i32, w2: i32, area: i32, px: i16, py: i16, is_transp: bool) ShadeResult {
                var r = interp(w0, w1, w2, area, ctx.r[0], ctx.r[1], ctx.r[2]);
                var g = interp(w0, w1, w2, area, ctx.g[0], ctx.g[1], ctx.g[2]);
                var b = interp(w0, w1, w2, area, ctx.b[0], ctx.b[1], ctx.b[2]);

                if (ctx.dither_enabled) {
                    const offset: i32 = Color.dither_table[@intCast(@mod(py, 4))][@intCast(@mod(px, 4))];
                    r += offset;
                    g += offset;
                    b += offset;
                }

                // Dither is an 8-bit-scale offset, so it is added before the
                // shift to 5 bits, and the clamp is at 8-bit range.
                const r5: u16 = @intCast(std.math.clamp(r, 0, 255) >> 3);
                const g5: u16 = @intCast(std.math.clamp(g, 0, 255) >> 3);
                const b5: u16 = @intCast(std.math.clamp(b, 0, 255) >> 3);

                return .{ .color = (b5 << 10) | (g5 << 5) | r5, .is_transparent = is_transp, .draw = true };
            }
        };
        rasterizeTriangle(vram, env, x0, y0, x1, y1, x2, y2, is_transparent, ShadedShader, ShadedShader{
            .r = .{ @intCast(c0 & 0xFF), @intCast(c1 & 0xFF), @intCast(c2 & 0xFF) },
            .g = .{ @intCast((c0 >> 8) & 0xFF), @intCast((c1 >> 8) & 0xFF), @intCast((c2 >> 8) & 0xFF) },
            .b = .{ @intCast((c0 >> 16) & 0xFF), @intCast((c1 >> 16) & 0xFF), @intCast((c2 >> 16) & 0xFF) },
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

        const r0: i32 = @intCast(c0 & 0xFF);
        const g0: i32 = @intCast((c0 >> 8) & 0xFF);
        const b0: i32 = @intCast((c0 >> 16) & 0xFF);
        const r1: i32 = @intCast(c1 & 0xFF);
        const g1: i32 = @intCast((c1 >> 8) & 0xFF);
        const b1: i32 = @intCast((c1 >> 16) & 0xFF);

        const steps: i32 = @intCast(@max(dx, dy));
        const dither_enabled = (env.draw_mode & (1 << 9)) != 0;

        // The channel at step k is r0 + floor((r1 - r0) * k / steps): exact,
        // and evaluable from k alone rather than from an accumulator, which is
        // what a Phase B shader would need. The old code accumulated an f32
        // (r1 - r0) / steps and drifted below the true value along the span.
        var k: i32 = 0;
        while (true) {
            var r = r0;
            var g = g0;
            var b = b0;
            if (steps != 0) {
                r += @divFloor((r1 - r0) * k, steps);
                g += @divFloor((g1 - g0) * k, steps);
                b += @divFloor((b1 - b0) * k, steps);
            }

            if (dither_enabled) {
                const offset: i32 = Color.dither_table[@intCast(@mod(cy, 4))][@intCast(@mod(cx, 4))];
                r += offset;
                g += offset;
                b += offset;
            }

            const r5: u16 = @intCast(std.math.clamp(r, 0, 255) >> 3);
            const g5: u16 = @intCast(std.math.clamp(g, 0, 255) >> 3);
            const b5: u16 = @intCast(std.math.clamp(b, 0, 255) >> 3);

            putPixel(vram, env, cx, cy, (b5 << 10) | (g5 << 5) | r5, is_transparent);
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
            k += 1;
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

            pub fn shade(ctx: @This(), w0: i32, w1: i32, w2: i32, area: i32, px: i16, py: i16, is_transp: bool) ShadeResult {
                // u/v are 8-bit fields on the wire, and coverage guarantees
                // every un-biased w_i >= 0 with w0+w1+w2 == area exactly, so
                // the interpolant is a convex combination of three in-range
                // values on every covered pixel, boundary ones included --
                // this clamp cannot actually trigger. Kept as a defensive
                // guard anyway; a future Metal shader may want the same one.
                const u: u32 = @intCast(std.math.clamp(interp(w0, w1, w2, area, ctx.tu[0], ctx.tu[1], ctx.tu[2]), 0, 255));
                const v: u32 = @intCast(std.math.clamp(interp(w0, w1, w2, area, ctx.tv[0], ctx.tv[1], ctx.tv[2]), 0, 255));

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
            .tu = .{ tu0, tu1, tu2 },
            .tv = .{ tv0, tv1, tv2 },
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
