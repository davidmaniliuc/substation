#include <metal_stdlib>
#include "PrimInstance.h"
using namespace metal;
#include "Ps1Color.h"

static_assert(sizeof(Ps1PrimInstance) == 4 * 42,
              "Ps1PrimInstance layout changed — update the Swift stride test too");

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
                                const device Ps1PrimInstance* prims [[buffer(0)]]) {
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

    float x = (vid & 1u) ? float(p.box_x1 + 1) : float(p.box_x0);
    float y = (vid & 2u) ? float(p.box_y1 + 1) : float(p.box_y0);

    PrimVertexOut out;
    // 1024 x 512 target: x/512 - 1 and 1 - y/256. Metal's framebuffer origin
    // is top-left, so y is flipped relative to NDC.
    out.position = float4(x / 512.0f - 1.0f, 1.0f - y / 256.0f, 0.0f, 1.0f);
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
inline bool ps1_triangle_coverage(const device Ps1PrimInstance& p, int px, int py,
                                  thread int& w0, thread int& w1, thread int& w2,
                                  thread int& area) {
    int area_signed = ps1_orient(p.x0, p.y0, p.x1, p.y1, p.x2, p.y2);
    // Normalize to a positive area by flipping the sign of every edge function
    // rather than by swapping two vertices: a swap would permute the
    // attributes the shader indexes by vertex number.
    int s = area_signed < 0 ? -1 : 1;
    area = area_signed * s;

    int bias0 = ps1_top_left(s * (p.x2 - p.x1), s * (p.y2 - p.y1)) ? -1 : 0;
    int bias1 = ps1_top_left(s * (p.x0 - p.x2), s * (p.y0 - p.y2)) ? -1 : 0;
    int bias2 = ps1_top_left(s * (p.x1 - p.x0), s * (p.y1 - p.y0)) ? -1 : 0;

    int b0 = s * ps1_orient(p.x1, p.y1, p.x2, p.y2, px, py) + bias0;
    int b1 = s * ps1_orient(p.x2, p.y2, p.x0, p.y0, px, py) + bias1;
    int b2 = s * ps1_orient(p.x0, p.y0, p.x1, p.y1, px, py) + bias2;

    // Avocado's coverage test verbatim: a negative term sets the sign bit of
    // the OR, so this means "all three non-negative, and not all three zero".
    if ((b0 | b1 | b2) <= 0) return false;

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
                         texture2d<ushort, access::read> vram,
                         uint u, uint v, int px, int py) {
    uint mask_x   = (p.tex_window & 0x1Fu) * 8u;
    uint mask_y   = ((p.tex_window >> 5) & 0x1Fu) * 8u;
    uint offset_x = ((p.tex_window >> 10) & 0x1Fu) * 8u;
    uint offset_y = ((p.tex_window >> 15) & 0x1Fu) * 8u;

    uint final_u = (u & ~mask_x) | (offset_x & mask_x);
    uint final_v = (v & ~mask_y) | (offset_y & mask_y);

    ushort texel = ps1_fetch_texel(vram, p.tex_depth, p.tpage_x, p.tpage_y,
                                   p.clut_x, p.clut_y, final_u, final_v);
    if (texel == 0) return 0;
    if (p.flags & PS1_PRIM_MODULATE) {
        return ps1_modulate(texel, ushort(p.color), px, py,
                            (p.flags & PS1_PRIM_DITHER) != 0);
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
                                  texture2d<ushort, access::read> vram [[texture(0)]]) {
    const device Ps1PrimInstance& p = prims[in.iid];
    // [[position]] in a fragment shader is the pixel CENTRE (px+0.5, py+0.5),
    // so this truncation is exact.
    int px = int(in.position.x);
    int py = int(in.position.y);

    bool transparent = (p.flags & PS1_PRIM_TRANSPARENT) != 0;
    ushort src;

    if (p.kind == PS1_PRIM_FLAT_TRI) {
        int w0, w1, w2, area;
        if (!ps1_triangle_coverage(p, px, py, w0, w1, w2, area)) { discard_fragment(); return 0; }
        src = ushort(p.color);
    } else if (p.kind == PS1_PRIM_GOURAUD_TRI) {
        int w0, w1, w2, area;
        if (!ps1_triangle_coverage(p, px, py, w0, w1, w2, area)) { discard_fragment(); return 0; }
        // Wire colours are 24-bit BGR: red in the low byte.
        int r = ps1_interp(w0, w1, w2, area,
                           int(p.c0 & 0xFFu), int(p.c1 & 0xFFu), int(p.c2 & 0xFFu));
        int g = ps1_interp(w0, w1, w2, area,
                           int((p.c0 >> 8) & 0xFFu), int((p.c1 >> 8) & 0xFFu), int((p.c2 >> 8) & 0xFFu));
        int b = ps1_interp(w0, w1, w2, area,
                           int((p.c0 >> 16) & 0xFFu), int((p.c1 >> 16) & 0xFFu), int((p.c2 >> 16) & 0xFFu));
        if (p.flags & PS1_PRIM_DITHER) {
            int o = ps1_dither(px, py);
            r += o; g += o; b += o;
        }
        src = ps1_pack(r, g, b);
    } else if (p.kind == PS1_PRIM_TEXTURED_TRI) {
        int w0, w1, w2, area;
        if (!ps1_triangle_coverage(p, px, py, w0, w1, w2, area)) { discard_fragment(); return 0; }

        // u/v are 8-bit fields on the wire, and coverage guarantees every
        // unbiased w_i >= 0 with w0+w1+w2 == area exactly, so the interpolant
        // is a convex combination of three in-range values on every covered
        // pixel. The clamp cannot actually trigger; it is the same defensive
        // guard renderer.zig:425-426 keeps, for the same reason.
        uint u = uint(clamp(ps1_interp(w0, w1, w2, area, p.u0, p.u1, p.u2), 0, 255));
        uint v = uint(clamp(ps1_interp(w0, w1, w2, area, p.v0, p.v1, p.v2), 0, 255));

        src = ps1_sample(p, vram, u, v, px, py);
        if (src == 0u) { discard_fragment(); return 0; }
        // A textured primitive's transparency is decided PER TEXEL by the
        // STP bit, not by the opcode alone.
        transparent = transparent && (src & 0x8000) != 0;
    } else {
        discard_fragment();
        return 0;
    }

    // ---- putPixel's tail (renderer.zig:8-46) ----------------------------
    // The drawing-area clip could be a scissor rect — it is exactly a
    // rectangle — but a scissor is per-encoder state and would break the
    // single instanced draw. In-shader keeps the batch.
    if (px < p.clip_x0 || px > p.clip_x1 || py < p.clip_y0 || py > p.clip_y1) {
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
                                    const device uint* words [[buffer(1)]]) {
    const device Ps1PrimInstance& p = prims[in.iid];
    int px = int(in.position.x);
    int py = int(in.position.y);

    // The box spans whole rows, so the first and last rows of a run are
    // partial and are trimmed here rather than by more instances.
    int pix = (py - p.y0) * p.w + (px - p.x0);
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
                                  texture2d<ushort, access::read> scratch [[texture(0)]]) {
    const device Ps1PrimInstance& p = prims[in.iid];
    int px = int(in.position.x);
    int py = int(in.position.y);

    // The destination wraps, so the encoder splits it into up to four boxes
    // and this recovers the in-rect offset by the same modular arithmetic.
    int xx = (px - p.x0) & 0x3FF;
    int yy = (py - p.y0) & 0x1FF;
    if (xx >= p.w || yy >= p.h) { discard_fragment(); return 0; }
    if ((p.flags & PS1_PRIM_CHECK_MASK) && (dst & 0x8000)) { discard_fragment(); return 0; }

    ushort v = scratch.read(uint2(uint((p.src_x + xx) & 0x3FF),
                                  uint((p.src_y + yy) & 0x1FF))).r;
    if (p.flags & PS1_PRIM_SET_MASK) v |= 0x8000;
    return v;
}
