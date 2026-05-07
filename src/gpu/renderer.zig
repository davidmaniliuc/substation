const std = @import("std");
const Vram = @import("vram.zig").Vram;
const DrawingEnv = @import("registers.zig").DrawingEnv;

pub const Renderer = struct {
    pub fn putPixel(vram: *Vram, env: *const DrawingEnv, x: i16, y: i16, color: u16, is_transparent: bool) void {
        // Hardware Clipping
        const draw_x0 = @as(i16, @intCast(env.area_top_left & 0x3FF));
        const draw_y0 = @as(i16, @intCast((env.area_top_left >> 10) & 0x3FF));
        const draw_x1 = @as(i16, @intCast(env.area_bot_right & 0x3FF));
        const draw_y1 = @as(i16, @intCast((env.area_bot_right >> 10) & 0x3FF));

        if (x < draw_x0 or x > draw_x1 or y < draw_y0 or y > draw_y1) return;
        if (x < 0 or x >= 1024 or y < 0 or y >= 512) return;

        const idx = @as(usize, @intCast(y)) * 1024 + @as(usize, @intCast(x));

        // Mask Bit Evaluation
        const mask_ctrl = env.mask_bit;
        const set_mask = (mask_ctrl & 1) != 0;
        const check_mask = (mask_ctrl & 2) != 0;

        const bg_pixel = vram.data[idx];
        if (check_mask and (bg_pixel & 0x8000) != 0) return;

        var final_color = color;

        if (is_transparent) {
            const blend_mode = (env.draw_mode >> 5) & 3;

            const fr = color & 0x1F;
            const fg = (color >> 5) & 0x1F;
            const fb = (color >> 10) & 0x1F;

            const br = bg_pixel & 0x1F;
            const bg = (bg_pixel >> 5) & 0x1F;
            const bb = (bg_pixel >> 10) & 0x1F;

            var rr: u16 = 0;
            var gg: u16 = 0;
            var bb_out: u16 = 0;

            switch (blend_mode) {
                0 => { // 0.5 * Back + 0.5 * Front
                    rr = (br + fr) / 2;
                    gg = (bg + fg) / 2;
                    bb_out = (bb + fb) / 2;
                },
                1 => { // 1.0 * Back + 1.0 * Front
                    rr = br + fr;
                    gg = bg + fg;
                    bb_out = bb + fb;
                },
                2 => { // 1.0 * Back - 1.0 * Front
                    rr = if (br > fr) br - fr else 0;
                    gg = if (bg > fg) bg - fg else 0;
                    bb_out = if (bb > fb) bb - fb else 0;
                },
                3 => { // 1.0 * Back + 0.25 * Front
                    rr = br + (fr / 4);
                    gg = bg + (fg / 4);
                    bb_out = bb + (fb / 4);
                },
                else => unreachable,
            }

            rr = @min(rr, 31);
            gg = @min(gg, 31);
            bb_out = @min(bb_out, 31);

            final_color = rr | (gg << 5) | (bb_out << 10);
        }

        if (set_mask) {
            final_color |= 0x8000;
        } else {
            final_color &= 0x7FFF;
        }

        vram.data[idx] = final_color;
    }

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
        const ox = env.getOffsetX();
        const oy = env.getOffsetY();

        const vx0 = x0 + ox;
        const vy0 = y0 + oy;
        const vx1 = x1 + ox;
        const vy1 = y1 + oy;
        const vx2 = x2 + ox;
        const vy2 = y2 + oy;

        const min_x = @max(@as(i16, 0), @min(vx0, @min(vx1, vx2)));
        const max_x = @min(@as(i16, 1023), @max(vx0, @max(vx1, vx2)));
        const min_y = @max(@as(i16, 0), @min(vy0, @min(vy1, vy2)));
        const max_y = @min(@as(i16, 511), @max(vy0, @max(vy1, vy2)));

        const area = (@as(i32, vx1) - vx0) * (@as(i32, vy2) - vy0) - (@as(i32, vy1) - vy0) * (@as(i32, vx2) - vx0);
        if (area == 0) return;

        var py = min_y;
        while (py <= max_y) : (py += 1) {
            var px = min_x;
            while (px <= max_x) : (px += 1) {
                const w0 = (@as(i32, vx2) - vx1) * (@as(i32, py) - vy1) - (@as(i32, vy2) - vy1) * (@as(i32, px) - vx1);
                const w1 = (@as(i32, vx0) - vx2) * (@as(i32, py) - vy2) - (@as(i32, vy0) - vy2) * (@as(i32, px) - vx2);
                const w2 = (@as(i32, vx1) - vx0) * (@as(i32, py) - vy0) - (@as(i32, vy1) - vy0) * (@as(i32, px) - vx0);

                const inside = if (area > 0) (w0 >= 0 and w1 >= 0 and w2 >= 0) else (w0 <= 0 and w1 <= 0 and w2 <= 0);

                if (inside) {
                    const color_and_transp = Shader.shade(shader_ctx, w0, w1, w2, area, allow_transparency);
                    if (color_and_transp.draw) {
                        putPixel(vram, env, px, py, color_and_transp.color, color_and_transp.is_transparent);
                    }
                }
            }
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
            pub fn shade(ctx: @This(), _: i32, _: i32, _: i32, _: i32, is_transp: bool) struct { color: u16, is_transparent: bool, draw: bool } {
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
        c0: u16,
        x1: i16,
        y1: i16,
        c1: u16,
        x2: i16,
        y2: i16,
        c2: u16,
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
            pub fn shade(ctx: @This(), w0: i32, w1: i32, w2: i32, area: i32, is_transp: bool) struct { color: u16, is_transparent: bool, draw: bool } {
                const f0 = @as(f32, @floatFromInt(w0)) / @as(f32, @floatFromInt(area));
                const f1 = @as(f32, @floatFromInt(w1)) / @as(f32, @floatFromInt(area));
                const f2 = @as(f32, @floatFromInt(w2)) / @as(f32, @floatFromInt(area));

                const r = @as(u16, @intFromFloat(@abs(f0 * ctx.r0 + f1 * ctx.r1 + f2 * ctx.r2)));
                const g = @as(u16, @intFromFloat(@abs(f0 * ctx.g0 + f1 * ctx.g1 + f2 * ctx.g2)));
                const b = @as(u16, @intFromFloat(@abs(f0 * ctx.b0 + f1 * ctx.b1 + f2 * ctx.b2)));

                return .{ .color = (b << 10) | (g << 5) | r, .is_transparent = is_transp, .draw = true };
            }
        };
        rasterizeTriangle(vram, env, x0, y0, x1, y1, x2, y2, is_transparent, ShadedShader, ShadedShader{
            .r0 = @floatFromInt(c0 & 0x1F),
            .g0 = @floatFromInt((c0 >> 5) & 0x1F),
            .b0 = @floatFromInt((c0 >> 10) & 0x1F),
            .r1 = @floatFromInt(c1 & 0x1F),
            .g1 = @floatFromInt((c1 >> 5) & 0x1F),
            .b1 = @floatFromInt((c1 >> 10) & 0x1F),
            .r2 = @floatFromInt(c2 & 0x1F),
            .g2 = @floatFromInt((c2 >> 5) & 0x1F),
            .b2 = @floatFromInt((c2 >> 10) & 0x1F),
        });
    }

    pub fn drawRectangle(vram: *Vram, env: *const DrawingEnv, x: i16, y: i16, w: i16, h: i16, color: u16, is_transparent: bool) void {
        const ox = env.getOffsetX();
        const oy = env.getOffsetY();
        var yy: i16 = 0;
        while (yy < h) : (yy += 1) {
            var xx: i16 = 0;
            while (xx < w) : (xx += 1) {
                putPixel(vram, env, x + xx + ox, y + yy + oy, color, is_transparent);
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

    pub fn drawShadedLine(vram: *Vram, env: *const DrawingEnv, x0: i16, y0: i16, c0: u16, x1: i16, y1: i16, c1: u16, is_transparent: bool) void {
        const ox = env.getOffsetX();
        const oy = env.getOffsetY();
        var cx = x0 + ox;
        var cy = y0 + oy;
        const target_x = x1 + ox;
        const target_y = y1 + oy;
        const dx = @abs(target_x - cx);
        const dy = @abs(target_y - cy);
        const sx: i16 = if (cx < target_x) 1 else -1;
        const sy: i16 = if (cy < target_y) 1 else -1;
        var err = @as(i32, @intCast(dx)) - @as(i32, @intCast(dy));

        const r0 = @as(f32, @floatFromInt(c0 & 0x1F));
        const g0 = @as(f32, @floatFromInt((c0 >> 5) & 0x1F));
        const b0 = @as(f32, @floatFromInt((c0 >> 10) & 0x1F));
        const r1 = @as(f32, @floatFromInt(c1 & 0x1F));
        const g1 = @as(f32, @floatFromInt((c1 >> 5) & 0x1F));
        const b1 = @as(f32, @floatFromInt((c1 >> 10) & 0x1F));

        const steps = @as(f32, @floatFromInt(@max(dx, dy)));
        if (steps == 0) {
            putPixel(vram, env, cx, cy, c0, is_transparent);
            return;
        }

        const dr = (r1 - r0) / steps;
        const dg = (g1 - g0) / steps;
        const db = (b1 - b0) / steps;
        var curr_r = r0;
        var curr_g = g0;
        var curr_b = b0;

        while (true) {
            const r = @as(u16, @intFromFloat(@abs(curr_r)));
            const g = @as(u16, @intFromFloat(@abs(curr_g)));
            const b = @as(u16, @intFromFloat(@abs(curr_b)));
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

            pub fn shade(ctx: @This(), w0: i32, w1: i32, w2: i32, area: i32, is_transp: bool) struct { color: u16, is_transparent: bool, draw: bool } {
                const f0 = @as(f32, @floatFromInt(w0)) / @as(f32, @floatFromInt(area));
                const f1 = @as(f32, @floatFromInt(w1)) / @as(f32, @floatFromInt(area));
                const f2 = @as(f32, @floatFromInt(w2)) / @as(f32, @floatFromInt(area));

                const u = @as(u16, @intFromFloat(@abs(f0 * ctx.tu0 + f1 * ctx.tu1 + f2 * ctx.tu2)));
                const v = @as(u16, @intFromFloat(@abs(f0 * ctx.tv0 + f1 * ctx.tv1 + f2 * ctx.tv2)));

                var texel: u16 = 0;
                if (ctx.tex_depth == 0) {
                    const val = ctx.vram.data[@as(usize, ctx.tpage_y + v) * 1024 + @as(usize, ctx.tpage_x + (u / 4))];
                    const index = (val >> @as(u4, @truncate((u % 4) * 4))) & 0xF;
                    texel = ctx.vram.data[@as(usize, ctx.clut_y) * 1024 + @as(usize, ctx.clut_x + index)];
                } else if (ctx.tex_depth == 1) {
                    const val = ctx.vram.data[@as(usize, ctx.tpage_y + v) * 1024 + @as(usize, ctx.tpage_x + (u / 2))];
                    const index = (val >> @as(u4, @truncate((u % 2) * 8))) & 0xFF;
                    texel = ctx.vram.data[@as(usize, ctx.clut_y) * 1024 + @as(usize, ctx.clut_x + index)];
                } else {
                    texel = ctx.vram.data[@as(usize, ctx.tpage_y + v) * 1024 + @as(usize, ctx.tpage_x + u)];
                }

                if (texel == 0) return .{ .color = 0, .is_transparent = false, .draw = false };

                var final_texel = texel;
                if ((ctx.opcode & 1) == 0) { // Modulation
                    const tr = texel & 0x1F;
                    const tg = (texel >> 5) & 0x1F;
                    const tb = (texel >> 10) & 0x1F;
                    const cr = ctx.color & 0x1F;
                    const cg = (ctx.color >> 5) & 0x1F;
                    const cb = (ctx.color >> 10) & 0x1F;
                    const r: u16 = @min((tr * cr) >> 4, 31);
                    const g: u16 = @min((tg * cg) >> 4, 31);
                    const b: u16 = @min((tb * cb) >> 4, 31);
                    final_texel = r | (g << 5) | (b << 10) | (texel & 0x8000);
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
        });
    }
};
