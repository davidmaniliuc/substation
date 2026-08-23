const std = @import("std");
const Vram = @import("vram.zig").Vram;

pub const dither_table = [4][4]i8{
    .{ -4, 0, -3, 1 },
    .{ 2, -2, 3, -1 },
    .{ -3, 1, -4, 0 },
    .{ 3, -1, 2, -2 },
};

/// 24bpp command word -> ABGR1555.
pub fn getColor16(value: u32) u16 {
    const r = (value & 0xFF) >> 3;
    const g = ((value >> 8) & 0xFF) >> 3;
    const b = ((value >> 16) & 0xFF) >> 3;
    return @intCast((b << 10) | (g << 5) | r);
}

/// Alpha-blend `fg` over `bg` per one of the four hardware modes (GP0(E1)
/// bits 5-6, `putPixel`'s `blend_mode`). Blending never touches bit15 — the
/// drawn pixel keeps the mask bit of the *source* colour, carried through
/// every mode.
pub fn blend(bg: u16, fg: u16, mode: u2) u16 {
    const fr = fg & 0x1F;
    const fg_g = (fg >> 5) & 0x1F;
    const fb = (fg >> 10) & 0x1F;

    const br = bg & 0x1F;
    const bg_g = (bg >> 5) & 0x1F;
    const bb = (bg >> 10) & 0x1F;

    var rr: u16 = 0;
    var gg: u16 = 0;
    var bb_out: u16 = 0;

    switch (mode) {
        0 => { // 0.5 * Back + 0.5 * Front
            rr = (br + fr) / 2;
            gg = (bg_g + fg_g) / 2;
            bb_out = (bb + fb) / 2;
        },
        1 => { // 1.0 * Back + 1.0 * Front
            rr = br + fr;
            gg = bg_g + fg_g;
            bb_out = bb + fb;
        },
        2 => { // 1.0 * Back - 1.0 * Front
            rr = if (br > fr) br - fr else 0;
            gg = if (bg_g > fg_g) bg_g - fg_g else 0;
            bb_out = if (bb > fb) bb - fb else 0;
        },
        3 => { // 1.0 * Back + 0.25 * Front
            rr = br + (fr / 4);
            gg = bg_g + (fg_g / 4);
            bb_out = bb + (fb / 4);
        },
    }

    rr = @min(rr, 31);
    gg = @min(gg, 31);
    bb_out = @min(bb_out, 31);

    return rr | (gg << 5) | (bb_out << 10) | (fg & 0x8000);
}

/// One texel, at any of the three depths. `tex_depth` is (tpage >> 7) & 3.
/// Coordinates are widened to usize here rather than at each call site — the
/// original wrote `@as(usize, tpage_y + final_v) * 1024 + ...` out by hand in
/// both the triangle shader and the rectangle loop.
pub fn fetchTexel(
    vram: *const Vram,
    tex_depth: u32,
    tpage_x: u16,
    tpage_y: u16,
    clut_x: u16,
    clut_y: u16,
    u: u32,
    v: u32,
) u16 {
    const px: usize = @as(usize, tpage_x);
    const py: usize = @as(usize, tpage_y) + @as(usize, v);
    const cy: usize = @as(usize, clut_y);
    if (tex_depth == 0) {
        const word = vram.data[Vram.index(px + @as(usize, u / 4), py)];
        const idx = (word >> @as(u4, @truncate((u % 4) * 4))) & 0xF;
        return vram.data[Vram.index(@as(usize, clut_x) + idx, cy)];
    } else if (tex_depth == 1) {
        const word = vram.data[Vram.index(px + @as(usize, u / 2), py)];
        const idx = (word >> @as(u4, @truncate((u % 2) * 8))) & 0xFF;
        return vram.data[Vram.index(@as(usize, clut_x) + idx, cy)];
    }
    return vram.data[Vram.index(px + @as(usize, u), py)];
}

/// Texture-colour modulation (opcode bit0 == 0): texel * vertex-colour / 16,
/// with the optional dither offset added before clamping. Keeps
/// `(texel & 0x8000)` on the result — a textured primitive's semi-transparency
/// bit lives there and must survive modulation untouched.
pub fn modulate(texel: u16, color: u16, px: i32, py: i32, dither_enabled: bool) u16 {
    const tr: i32 = texel & 0x1F;
    const tg: i32 = (texel >> 5) & 0x1F;
    const tb: i32 = (texel >> 10) & 0x1F;
    const cr: i32 = color & 0x1F;
    const cg: i32 = (color >> 5) & 0x1F;
    const cb: i32 = (color >> 10) & 0x1F;

    var r = @divFloor(tr * cr, 16);
    var g = @divFloor(tg * cg, 16);
    var b = @divFloor(tb * cb, 16);

    if (dither_enabled) {
        const offset: i32 = dither_table[@intCast(@mod(py, 4))][@intCast(@mod(px, 4))];
        r += offset;
        g += offset;
        b += offset;
    }

    const r5: u16 = @intCast(std.math.clamp(r, 0, 31));
    const g5: u16 = @intCast(std.math.clamp(g, 0, 31));
    const b5: u16 = @intCast(std.math.clamp(b, 0, 31));
    return r5 | (g5 << 5) | (b5 << 10) | (texel & 0x8000);
}
