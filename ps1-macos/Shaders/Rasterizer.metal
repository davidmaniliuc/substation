#include <metal_stdlib>
#include "PrimInstance.h"
using namespace metal;
#include "Ps1Color.h"

static_assert(sizeof(Ps1PrimInstance) == 4 * 42,
              "Ps1PrimInstance layout changed — update the Swift stride test too");

static_assert(sizeof(Ps1RasterUniforms) == 8,
              "Ps1RasterUniforms layout changed — update the Swift stride test too");

struct PrimVertexOut {
    float4 position [[position]];
    /// `flat`, not interpolated: it is an index, not a quantity.
    uint   iid [[flat]];
};

/// One bounding-box quad per primitive, expanded from vertex_id 0..3 as a
/// triangle strip. The box is INCLUSIVE, so the far edge is +1.
///
/// The GPU rasterizer's only job here is to generate fragments over a
/// conservative box. It is never trusted for coverage: its fill rule and
/// sample positions are not the PS1's, and the disagreement lands exactly on
/// the degenerate triangles that matter.
vertex PrimVertexOut ps1_vertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                const device Ps1PrimInstance* prims [[buffer(0)]],
                                constant Ps1RasterUniforms& uni [[buffer(2)]]) {
    // [[instance_id]] ALREADY includes drawPrimitives's baseInstance on this
    // Metal implementation — it ranges over [baseInstance, baseInstance +
    // instanceCount), not [0, instanceCount). Task 5 was the first caller to
    // ever draw with a nonzero baseInstance (every earlier draw used 0, where
    // adding it back was a no-op and hid the bug); a stray `+ [[base_instance]]`
    // here double-counted it and read one-past-the-real-instance out of a
    // buffer with no such element — undefined bytes landing in every field,
    // observed as a phantom all-zero primitive plus the intended instance
    // never being drawn at all. `[[base_instance]]` is not read at all now.
    uint index = iid;
    const device Ps1PrimInstance& p = prims[index];

    // The box is in NATIVE units, like every other field of the record; the
    // quad is its image at the internal resolution. The far edge is +1 because
    // the box is inclusive, and that +1 happens BEFORE the scale — `(x1+1)*s`,
    // never `x1*s + 1`.
    float s = float(uni.scale);
    float x = (vid & 1u) ? float(p.box_x1 + 1) * s : float(p.box_x0) * s;
    float y = (vid & 2u) ? float(p.box_y1 + 1) * s : float(p.box_y0) * s;

    PrimVertexOut out;
    // The target is 1024s x 512s, so the divisors follow it. Metal's
    // framebuffer origin is top-left, so y is flipped relative to NDC.
    //
    // Exact at every s, including 3: IEEE division is correctly rounded, and
    // (k*s)/(512*s) has the exact value k/512, which is a dyadic rational for
    // every k <= 1024 and therefore representable. No epsilon can creep in to
    // flip a boundary pixel.
    out.position = float4(x / (512.0f * s) - 1.0f, 1.0f - y / (256.0f * s), 0.0f, 1.0f);
    out.iid = index;
    return out;
}

/// GP0(02). DELIBERATELY unmasked and NOT clipped to the drawing area:
/// hardware ignores GP0(E6) for fills, and `vram.zig:183-198` clips only to
/// VRAM bounds — which the encoder has already folded into the box.
fragment ushort ps1_fill_fragment(PrimVertexOut in [[stage_in]],
                                  const device Ps1PrimInstance* prims [[buffer(0)]]) {
    return ushort(prims[in.iid].color);
}

/// Coverage for a triangle instance, recomputed per pixel from the three
/// vertices with no incremental state — which is precisely what Phase 0's
/// `interp` doc comment was written to guarantee.
///
/// Returns false when the pixel is outside. `w0`/`w1`/`w2` come back UNBIASED:
/// the fill-rule bias is a coverage device only, and attributes must be
/// interpolated from the true barycentric numerators.
inline bool ps1_triangle_coverage(const device Ps1PrimInstance& p, int s, int px, int py,
                                  thread int& w0, thread int& w1, thread int& w2,
                                  thread int& area) {
    // The vertices are native; the sample point is already scaled. Multiplying
    // the vertices by s is what puts both in the same space — and it leaves
    // every sign unchanged at a top-left subtexel, where each edge function
    // becomes exactly s^2 times its native value.
    int ax = p.x0 * s, ay = p.y0 * s;
    int bx = p.x1 * s, by = p.y1 * s;
    int cx = p.x2 * s, cy = p.y2 * s;

    int area_signed = ps1_orient(ax, ay, bx, by, cx, cy);
    // Normalize to a positive area by flipping the sign of every edge function
    // rather than by swapping two vertices: a swap would permute the
    // attributes the shader indexes by vertex number.
    int sgn = area_signed < 0 ? -1 : 1;
    area = area_signed * sgn;

    // The fill rule reads only the SIGN of each edge delta, and s > 0, so the
    // scaled deltas classify identically to the native ones.
    int bias0 = ps1_top_left(sgn * (cx - bx), sgn * (cy - by)) ? -1 : 0;
    int bias1 = ps1_top_left(sgn * (ax - cx), sgn * (ay - cy)) ? -1 : 0;
    int bias2 = ps1_top_left(sgn * (bx - ax), sgn * (by - ay)) ? -1 : 0;

    int b0 = sgn * ps1_orient(bx, by, cx, cy, px, py) + bias0;
    int b1 = sgn * ps1_orient(cx, cy, ax, ay, px, py) + bias1;
    int b2 = sgn * ps1_orient(ax, ay, bx, by, px, py) + bias2;

    // Avocado's coverage test verbatim: a negative term sets the sign bit of
    // the OR, so this half means "all three non-negative".
    if ((b0 | b1 | b2) < 0) return false;

    // "...and not all three zero" is the ONE part of this function that is not
    // scale-invariant, and it decides sub-pixel slivers. At a top-left
    // subtexel every edge function is exactly s^2 times its native value while
    // the top-left bias stays -1, so a term reading 0 natively (u == 1,
    // bias == -1) reads s^2 - 1 at scale: the triangle is refused at 1x and
    // painted above it. Comparing against s^2 restores the equivalence
    // exactly — at s == 1 this IS the original test, because every term is
    // already known non-negative here — and it cannot open a crack along a
    // shared edge, since near an edge only ONE term is small. It bites only
    // where all three are small at once, which is the degenerate sub-pixel
    // case that has no 1x pixel to match anyway.
    int s2 = s * s;
    if (b0 < s2 && b1 < s2 && b2 < s2) return false;

    w0 = b0 - bias0;
    w1 = b1 - bias1;
    w2 = b2 - bias2;
    return true;
}

/// Texture-window masking, the texel fetch and optional modulation — the
/// tail both textured paths share.
///
/// Returns 0 for a texel-zero HOLE, which the caller must treat as a discard
/// rather than as a black pixel: `renderer.zig:439` returns `.draw = false`.
/// 0 is unambiguous here because a real texel of 0 is that same hole.
inline ushort ps1_sample(const device Ps1PrimInstance& p,
                         texture2d<ushort, access::read> vram, uint s,
                         uint u, uint v, int px, int py, bool dither) {
    uint mask_x   = (p.tex_window & 0x1Fu) * 8u;
    uint mask_y   = ((p.tex_window >> 5) & 0x1Fu) * 8u;
    uint offset_x = ((p.tex_window >> 10) & 0x1Fu) * 8u;
    uint offset_y = ((p.tex_window >> 15) & 0x1Fu) * 8u;

    // The texture window is in TEXEL units, like u and v — nothing here scales.
    uint final_u = (u & ~mask_x) | (offset_x & mask_x);
    uint final_v = (v & ~mask_y) | (offset_y & mask_y);

    ushort texel = ps1_fetch_texel(vram, s, p.tex_depth, p.tpage_x, p.tpage_y,
                                   p.clut_x, p.clut_y, final_u, final_v);
    if (texel == 0) return 0;
    if (p.flags & PS1_PRIM_MODULATE) {
        return ps1_modulate(texel, ushort(p.color), px, py, dither);
    }
    return texel;
}

/// Every drawing primitive. `dst` is the destination pixel through
/// programmable blending — the same pixel via tile memory, which is a
/// different mechanism from sampling an arbitrary VRAM address and is not
/// affected by the pass-splitting invariant.
fragment ushort ps1_prim_fragment(PrimVertexOut in [[stage_in]],
                                  ushort dst [[color(0)]],
                                  const device Ps1PrimInstance* prims [[buffer(0)]],
                                  constant Ps1RasterUniforms& uni [[buffer(2)]],
                                  texture2d<ushort, access::read> vram [[texture(0)]]) {
    const device Ps1PrimInstance& p = prims[in.iid];
    int s = int(uni.scale);
    // [[position]] in a fragment shader is the pixel CENTRE (px+0.5, py+0.5),
    // so this truncation is exact.
    int px = int(in.position.x);
    int py = int(in.position.y);
    // The NATIVE pixel this subpixel belongs to. Every field of the record is
    // in native units, so anything indexed by a record — a transfer's pixel
    // index, a sprite's texcoord origin, a copy's source — uses these, never
    // px/py.
    int nx = px / s;
    int ny = py / s;
    // Dithering is decided HERE, not in PrimBuilder: clearing the flag on the
    // CPU would make the instance record differ between s == 1 and s > 1 and
    // forfeit the byte-identical-records property the phase rests on. It is
    // also the single exception to downsample-invariance, which is why it is
    // off above 1x at all.
    bool dither = (p.flags & PS1_PRIM_DITHER) && s == 1 && uni.dither_off == 0u;

    bool transparent = (p.flags & PS1_PRIM_TRANSPARENT) != 0;
    ushort src;

    if (p.kind == PS1_PRIM_FLAT_TRI) {
        int w0, w1, w2, area;
        if (!ps1_triangle_coverage(p, s, px, py, w0, w1, w2, area)) { discard_fragment(); return 0; }
        src = ushort(p.color);
    } else if (p.kind == PS1_PRIM_GOURAUD_TRI) {
        int w0, w1, w2, area;
        if (!ps1_triangle_coverage(p, s, px, py, w0, w1, w2, area)) { discard_fragment(); return 0; }
        // Wire colours are 24-bit BGR: red in the low byte.
        int r = ps1_interp(w0, w1, w2, area,
                           int(p.c0 & 0xFFu), int(p.c1 & 0xFFu), int(p.c2 & 0xFFu));
        int g = ps1_interp(w0, w1, w2, area,
                           int((p.c0 >> 8) & 0xFFu), int((p.c1 >> 8) & 0xFFu), int((p.c2 >> 8) & 0xFFu));
        int b = ps1_interp(w0, w1, w2, area,
                           int((p.c0 >> 16) & 0xFFu), int((p.c1 >> 16) & 0xFFu), int((p.c2 >> 16) & 0xFFu));
        if (dither) {
            int o = ps1_dither(px, py);
            r += o; g += o; b += o;
        }
        src = ps1_pack(r, g, b);
    } else if (p.kind == PS1_PRIM_TEXTURED_TRI) {
        int w0, w1, w2, area;
        if (!ps1_triangle_coverage(p, s, px, py, w0, w1, w2, area)) { discard_fragment(); return 0; }

        // u/v are 8-bit fields on the wire, and coverage guarantees every
        // unbiased w_i >= 0 with w0+w1+w2 == area exactly, so the interpolant
        // is a convex combination of three in-range values on every covered
        // pixel. The clamp cannot actually trigger; it is the same defensive
        // guard renderer.zig:425-426 keeps, for the same reason.
        uint u = uint(clamp(ps1_interp(w0, w1, w2, area, p.u0, p.u1, p.u2), 0, 255));
        uint v = uint(clamp(ps1_interp(w0, w1, w2, area, p.v0, p.v1, p.v2), 0, 255));

        src = ps1_sample(p, vram, uint(s), u, v, px, py, dither);
        if (src == 0u) { discard_fragment(); return 0; }
        // A textured primitive's transparency is decided PER TEXEL by the
        // STP bit, not by the opcode alone.
        transparent = transparent && (src & 0x8000) != 0;
    } else if (p.kind == PS1_PRIM_RECT) {
        // Covered by construction: the box IS the primitive.
        src = ushort(p.color);
    } else if (p.kind == PS1_PRIM_LINE_PIXEL) {
        // A mono line does NOT dither — `drawLine` has no dither branch at all,
        // unlike `drawShadedLine`.
        src = ushort(p.color);
    } else if (p.kind == PS1_PRIM_SHADED_LINE_PIXEL) {
        int r = int(p.c0 & 0xFFu);
        int g = int((p.c0 >> 8) & 0xFFu);
        int b = int((p.c0 >> 16) & 0xFFu);
        if (p.steps != 0) {
            // floor, NOT truncation: (c1 - c0) is negative on a falling span.
            r += ps1_floor_div((int(p.c1 & 0xFFu) - r) * p.k, p.steps);
            g += ps1_floor_div((int((p.c1 >> 8) & 0xFFu) - g) * p.k, p.steps);
            b += ps1_floor_div((int((p.c1 >> 16) & 0xFFu) - b) * p.k, p.steps);
        }
        if (dither) {
            int o = ps1_dither(px, py);
            r += o; g += o; b += o;
        }
        src = ps1_pack(r, g, b);
    } else if (p.kind == PS1_PRIM_TEXTURED_RECT) {
        // `tu +% @truncate(xx)` on u8 — a WRAP, not the triangle path's
        // interpolate-and-clamp. This is why the sprite path is a separate
        // shader path rather than a special case of the triangle one. It is
        // computed from the NATIVE pixel: the wrap is in texel units and has
        // nothing to do with internal resolution.
        uint u = uint((nx - p.x0) + p.u0) & 0xFFu;
        uint v = uint((ny - p.y0) + p.v0) & 0xFFu;
        src = ps1_sample(p, vram, uint(s), u, v, px, py, dither);
        if (src == 0u) { discard_fragment(); return 0; }
        transparent = transparent && (src & 0x8000) != 0;
    } else {
        discard_fragment();
        return 0;
    }

    // ---- putPixel's tail (renderer.zig:8-46) ----------------------------
    // The drawing-area clip could be a scissor rect — it is exactly a
    // rectangle — but a scissor is per-encoder state and would break the
    // single instanced draw. In-shader keeps the batch.
    // The native drawing area is INCLUSIVE, so the scaled right/bottom bound
    // is (x1 + 1) * s - 1, NOT x1 * s. The wrong form agrees with this one at
    // every top-left subtexel — `p*s > x1*s` and `p*s > (x1+1)*s - 1` are the
    // same predicate for integer p — so Gate 1 and Gate 2 both pass with it,
    // and it silently drops the last (s-1) columns and rows of every clipped
    // primitive. Gate 2b's clip test is what catches it.
    if (px < p.clip_x0 * s || px > (p.clip_x1 + 1) * s - 1 ||
        py < p.clip_y0 * s || py > (p.clip_y1 + 1) * s - 1) {
        discard_fragment();
        return 0;
    }
    if ((p.flags & PS1_PRIM_CHECK_MASK) && (dst & 0x8000)) { discard_fragment(); return 0; }

    ushort out = transparent ? ps1_blend(dst, src, p.blend_mode) : src;

    // Bit 15 of the written pixel is the SOURCE pixel's own bit 15 — for a
    // textured primitive the texel's STP bit, for an untextured one 0 — OR'd
    // with GP0(E6).bit0. It must NOT be cleared: games mask off already-drawn
    // areas by leaving STP-set texels in VRAM and drawing with check-mask.
    if (p.flags & PS1_PRIM_SET_MASK) out |= 0x8000;
    return out;
}

/// GP0(A0). The payload run is a device buffer; this maps each covered pixel
/// back to the word carrying it. `word_base` is pre-biased by the encoder so
/// that `word_base + pixel/2` is that word, with the parity selecting the half.
///
/// Respects the E6 mask, unlike the fill above — `vram.zig` routes CPU->VRAM
/// through `maskedWrite` and Fill Rectangle around it.
fragment ushort ps1_upload_fragment(PrimVertexOut in [[stage_in]],
                                    ushort dst [[color(0)]],
                                    const device Ps1PrimInstance* prims [[buffer(0)]],
                                    constant Ps1RasterUniforms& uni [[buffer(2)]],
                                    const device uint* words [[buffer(1)]]) {
    const device Ps1PrimInstance& p = prims[in.iid];
    int s = int(uni.scale);
    int nx = int(in.position.x) / s;
    int ny = int(in.position.y) / s;

    // The box spans whole rows, so the first and last rows of a run are
    // partial and are trimmed here rather than by more instances.
    //
    // `pix` is a NATIVE pixel index into the transfer, so every subpixel of a
    // block resolves to the same payload word and the N x N replication falls
    // out. There is no replication code, deliberately.
    int pix = (ny - p.y0) * p.w + (nx - p.x0);
    if (pix < p.pixel_first || pix > p.pixel_last) { discard_fragment(); return 0; }
    if ((p.flags & PS1_PRIM_CHECK_MASK) && (dst & 0x8000)) { discard_fragment(); return 0; }

    uint word = words[p.word_base + (pix >> 1)];
    ushort v = ushort((pix & 1) ? (word >> 16) : word);
    if (p.flags & PS1_PRIM_SET_MASK) v |= 0x8000;
    return v;
}

/// GP0(80). Masked, and WRAPS on both axes rather than clipping.
///
/// `scratch` is a snapshot of VRAM taken at the pass boundary just before this
/// draw, which is what makes `vram.zig:154`'s backwards-iteration branch
/// unnecessary: a self-overlapping copy reads a frozen source, so the
/// direction question disappears instead of having to be reproduced.
fragment ushort ps1_copy_fragment(PrimVertexOut in [[stage_in]],
                                  ushort dst [[color(0)]],
                                  const device Ps1PrimInstance* prims [[buffer(0)]],
                                  constant Ps1RasterUniforms& uni [[buffer(2)]],
                                  texture2d<ushort, access::read> scratch [[texture(0)]]) {
    const device Ps1PrimInstance& p = prims[in.iid];
    int s = int(uni.scale);
    int px = int(in.position.x);
    int py = int(in.position.y);
    int nx = px / s, ny = py / s;
    int sub_x = px % s, sub_y = py % s;

    // The destination wraps, so the encoder splits it into up to four boxes
    // and this recovers the in-rect offset by the same modular arithmetic —
    // in NATIVE units, which is the space the encoder split in.
    int xx = (nx - p.x0) & 0x3FF;
    int yy = (ny - p.y0) & 0x1FF;
    if (xx >= p.w || yy >= p.h) { discard_fragment(); return 0; }
    if ((p.flags & PS1_PRIM_CHECK_MASK) && (dst & 0x8000)) { discard_fragment(); return 0; }

    // The ONE read in this backend that is not reduced to native. The source
    // address is native and wrapping; the subpixel offset is added after the
    // scale, so a blit MOVES scaled detail rather than flattening it to each
    // block's top-left subtexel. At a top-left subtexel both offsets are 0, so
    // the exactness property is untouched — which is exactly why a shader that
    // dropped them would still pass Gate 2.
    ushort v = scratch.read(uint2(uint(((p.src_x + xx) & 0x3FF) * s + sub_x),
                                  uint(((p.src_y + yy) & 0x1FF) * s + sub_y))).r;
    if (p.flags & PS1_PRIM_SET_MASK) v |= 0x8000;
    return v;
}
