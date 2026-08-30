/* Integer colour and geometry helpers, transcribed from
   ps1-core/src/gpu/color.zig and the top of gpu/renderer.zig.

   Metal-only: it uses MSL types. Included by Rasterizer.metal after
   <metal_stdlib>.

   INTEGER ARITHMETIC THROUGHOUT, never fixed-function blending and never
   floats: fixed-function blending normalizes to float and rounds differently,
   so it cannot be bit-exact at 1x. */
#ifndef PS1_COLOR_H
#define PS1_COLOR_H

constant int ps1_dither_table[4][4] = {
    { -4,  0, -3,  1 },
    {  2, -2,  3, -1 },
    { -3,  1, -4,  0 },
    {  3, -1,  2, -2 },
};

/// Floor division. `c1 - c0` on a shaded line is routinely negative, and
/// MSL's `/` truncates toward zero — which is a DIFFERENT answer from
/// `@divFloor` for exactly those spans.
inline int ps1_floor_div(int a, int b) {
    int q = a / b;
    if ((a % b != 0) && ((a < 0) != (b < 0))) q -= 1;
    return q;
}

/// Three 8-bit-scale channels down to ABGR1555. The dither offsets are 8-bit
/// channel units, so they are added BEFORE this and the clamp is at 8-bit
/// range — reading them as 5-bit units is the bug 900daa0 fixed.
inline ushort ps1_pack(int r, int g, int b) {
    int r5 = clamp(r, 0, 255) >> 3;
    int g5 = clamp(g, 0, 255) >> 3;
    int b5 = clamp(b, 0, 255) >> 3;
    return ushort(r5 | (g5 << 5) | (b5 << 10));
}

inline int ps1_dither(int px, int py) {
    return ps1_dither_table[py & 3][px & 3];
}

/// color.zig's `blend`. Truncating integer division on 5-bit channels.
/// Blending never touches bit 15 — the drawn pixel keeps the mask bit of the
/// SOURCE colour, carried through every mode.
inline ushort ps1_blend(ushort bg, ushort fg, uint mode) {
    int fr = fg & 0x1F, fg_g = (fg >> 5) & 0x1F, fb = (fg >> 10) & 0x1F;
    int br = bg & 0x1F, bg_g = (bg >> 5) & 0x1F, bb = (bg >> 10) & 0x1F;
    int rr, gg, bo;
    switch (mode) {
        case 0u: rr = (br + fr) / 2; gg = (bg_g + fg_g) / 2; bo = (bb + fb) / 2; break;
        case 1u: rr = br + fr;       gg = bg_g + fg_g;       bo = bb + fb;       break;
        case 2u: rr = br > fr ? br - fr : 0;
                 gg = bg_g > fg_g ? bg_g - fg_g : 0;
                 bo = bb > fb ? bb - fb : 0; break;
        default: rr = br + (fr / 4);  gg = bg_g + (fg_g / 4); bo = bb + (fb / 4); break;
    }
    rr = min(rr, 31); gg = min(gg, 31); bo = min(bo, 31);
    return ushort(rr | (gg << 5) | (bo << 10) | (fg & 0x8000));
}

/// `Vram.index(x, y)` is `y * 1024 + x` with NO masking, so a CLUT whose
/// `clut_x + index` runs past 1023 reads into the NEXT ROW. That row-crossing
/// is the software rasterizer's real behaviour and is reproduced deliberately
/// by converting the flat index back to 2D exactly as Zig's array does.
///
/// The `& 0x7FFFF` below is NOT part of that reproduction. It bounds the one
/// case where `lin` runs past the end of VRAM (524288 entries) rather than
/// merely into the next row — there, Zig's own `[524288]u16` indexing is
/// itself undefined (a safety-checked panic in Debug, UB in ReleaseFast), so
/// there is no defined Zig behaviour left to match. An unmasked `texture.read`
/// out of range is equally undefined on this side, so the mask exists purely
/// as a Metal-side safety bound, not to imitate anything the emulated
/// hardware does.
///
/// At internal resolution the LINEARIZE STAYS NATIVE and only the resulting
/// 2D address is scaled. `y * 1024 + x` reproduces `Vram.index`, which does no
/// masking; doing the same arithmetic in scaled units would invent a different
/// wrap — a row would be 1024*s wide and an overflowing CLUT would land
/// somewhere else entirely. The scaled read then takes the block's TOP-LEFT
/// subtexel, which is the whole of "texture data is never upscaled".
inline ushort ps1_vram_read(texture2d<ushort, access::read> vram,
                            uint x, uint y, uint s) {
    uint lin = (y * 1024u + x) & 0x7FFFFu;
    return vram.read(uint2((lin & 1023u) * s, (lin >> 10) * s)).r;
}

/// color.zig's `fetchTexel`, at all three depths.
///
/// Every coordinate reaching this and `ps1_vram_read` is a NATIVE texel
/// address: tpage_x/tpage_y/clut_x/clut_y come straight out of the instance
/// record and u/v are 8-bit texel indices. None of them is ever pre-multiplied
/// by the scale — only the final 2D VRAM address is.
inline ushort ps1_fetch_texel(texture2d<ushort, access::read> vram, uint s, uint depth,
                              uint tpage_x, uint tpage_y,
                              uint clut_x, uint clut_y, uint u, uint v) {
    uint py = tpage_y + v;
    if (depth == 0u) {
        ushort word = ps1_vram_read(vram, tpage_x + (u >> 2), py, s);
        uint idx = (uint(word) >> ((u & 3u) * 4u)) & 0xFu;
        return ps1_vram_read(vram, clut_x + idx, clut_y, s);
    }
    if (depth == 1u) {
        ushort word = ps1_vram_read(vram, tpage_x + (u >> 1), py, s);
        uint idx = (uint(word) >> ((u & 1u) * 8u)) & 0xFFu;
        return ps1_vram_read(vram, clut_x + idx, clut_y, s);
    }
    return ps1_vram_read(vram, tpage_x + u, py, s);
}

/// color.zig's `modulate`: texel * vertex-colour at 8-bit scale, i.e.
/// `(t << 3) * (c << 3) >> 7` == `(t * c) >> 1`. Working at 8-bit scale is
/// what makes the dither offsets mean what they say. Keeps `texel & 0x8000` —
/// a textured primitive's semi-transparency bit lives there.
inline ushort ps1_modulate(ushort texel, ushort color, int px, int py, bool dither) {
    int tr = texel & 0x1F, tg = (texel >> 5) & 0x1F, tb = (texel >> 10) & 0x1F;
    int cr = color & 0x1F, cg = (color >> 5) & 0x1F, cb = (color >> 10) & 0x1F;
    int r = (tr * cr) >> 1, g = (tg * cg) >> 1, b = (tb * cb) >> 1;
    if (dither) {
        int o = ps1_dither(px, py);
        r += o; g += o; b += o;
    }
    return ps1_pack(r, g, b) | (texel & 0x8000);
}

/// Twice the signed area of (a, b, c).
inline int ps1_orient(int ax, int ay, int bx, int by, int cx, int cy) {
    return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
}

/// The top-left fill rule. An edge that fails it drops the pixels landing
/// exactly on it, so two triangles sharing an edge paint each pixel once.
inline bool ps1_top_left(int dx, int dy) {
    return dy > 0 || (dy == 0 && dx < 0);
}

/// Exact barycentric interpolation of one integer attribute.
///
/// `renderer.zig:82-90` does this in i64 because the EXPANDED plane equation's
/// constant term exceeds i32. Nothing is expanded here — the weights are
/// evaluated at the pixel — but at internal resolution s BOTH the weights and
/// the area scale by s^2, so the numerator, bounded by area * 255, does too.
/// An oversized-capped primitive (1023 x 511) reaches about 2.13e9 at s = 4,
/// roughly 1% under int32's ceiling, and passes it at s = 5. The intermediate
/// is therefore `long`: the supported scale range should be decided by what
/// looks good, not by where an overflow lands.
///
/// The DIVISION is still exact and still scale-invariant: numerator and
/// denominator both carry the same s^2 factor, and integer division satisfies
/// floor(s^2*num / s^2*den) == floor(num/den). Plain `/` rather than a floor
/// because on a covered pixel num >= 0 and area > 0, exactly as
/// `renderer.zig`'s own comment says.
inline int ps1_interp(int w0, int w1, int w2, int area, int a0, int a1, int a2) {
    long num = long(w0) * long(a0) + long(w1) * long(a1) + long(w2) * long(a2);
    return int(num / long(area));
}

#endif /* PS1_COLOR_H */
