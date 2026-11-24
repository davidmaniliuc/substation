/* Texture filtering: what every filter reads, what it returns, the bilinear
   filter, and the dispatch from a PS1_FILTER_* id.

   Metal-only. Included by Rasterizer.metal after PrimInstance.h and
   Ps1Color.h.

   A filter is one function

       Ps1Filtered ps1_filter_<name>(thread const Ps1TexSrc& src, float2 coords)

   (JINC2 and xBR take a third argument, `bool blend_edges`). `coords` is in
   TEXELS with the texel centre at +0.5: `float2(u6, v6) / 64.0` for the
   six-bit centre texcoords, so a 1:1 mapping at 1x lands exactly on centres.
   It reads texels only through `ps1_src_*`, which apply the primitive's UV
   limits, the texture window and the CLUT. What it returns reaches the
   SIDECAR only: VRAM's value, its STP bit and the depth stay on the nearest
   texel, and `ps1_prim_shade` composites the result (see `ps1_filter_cover`).

   Each filter's helpers carry a prefix of its own (`ps1_jinc2_`, `ps1_xbr_`,
   `ps1_scale_`, `ps1_mmpx_`, `ps1_mmpxe_`, `ps1_mmpxa_`), because every
   header lands in one translation unit. */
#ifndef PS1_FILTER_H
#define PS1_FILTER_H

/// The texture window, then the fetch: the RAW texel at (u, v), 0 meaning a
/// hole. Everything that reads a texel goes through here, so a filter's
/// neighbour wraps inside the window exactly as the nearest texel does.
/// The window is in TEXEL units, like u and v: nothing here scales.
inline ushort ps1_window_fetch(const device Ps1PrimInstance& p,
                               texture2d<ushort, access::read> vram, uint s,
                               uint u, uint v) {
    uint mask_x   = (p.tex_window & 0x1Fu) * 8u;
    uint mask_y   = ((p.tex_window >> 5) & 0x1Fu) * 8u;
    uint offset_x = ((p.tex_window >> 10) & 0x1Fu) * 8u;
    uint offset_y = ((p.tex_window >> 15) & 0x1Fu) * 8u;
    uint final_u = (u & ~mask_x) | (offset_x & mask_x);
    uint final_v = (v & ~mask_y) | (offset_y & mask_y);
    return ps1_fetch_texel(vram, s, p.tex_depth, p.tpage_x, p.tpage_y,
                           p.clut_x, p.clut_y, final_u, final_v);
}

/// A raw texel per channel in 1/8 of a five-bit step: `t5 << 3`.
inline int3 ps1_texel8(ushort t) {
    return int3(t & 0x1F, (t >> 5) & 0x1F, (t >> 10) & 0x1F) << 3;
}

/// One primitive's texture as a filter reads it.
///
/// `ul`/`vl` are the inclusive UV limits per axis in UNWRAPPED texels:
/// `ps1_uv_limit` for a triangle, `ps1_wrap_limit` for a rectangle, whose
/// texcoords keep counting past 255 and wrap only at the fetch.
struct Ps1TexSrc {
    const device Ps1PrimInstance* p;
    texture2d<ushort, access::read> vram;
    uint s;
    int2 ul;
    int2 vl;
};

/// The raw texel at (u, v): clamped to the limits, wrapped into the page,
/// then windowed and fetched. 0 is a hole.
inline ushort ps1_src_raw(thread const Ps1TexSrc& src, int u, int v) {
    return ps1_window_fetch(*src.p, src.vram, src.s,
                            uint(clamp(u, src.ul.x, src.ul.y)) & 0xFFu,
                            uint(clamp(v, src.vl.x, src.vl.y)) & 0xFFu);
}

/// Whether (u, v) lies inside the limits, i.e. `ps1_src_raw` reads it
/// rather than a clamped neighbour.
inline bool ps1_src_inside(thread const Ps1TexSrc& src, int u, int v) {
    return u >= src.ul.x && u <= src.ul.y && v >= src.vl.x && v <= src.vl.y;
}

/// The texel at (u, v) normalised: each five-bit channel / 31, alpha the STP
/// bit (1 or 0), and a hole all zero, so a hole is the only texel equal to
/// float4(0).
inline float4 ps1_src_rgba(thread const Ps1TexSrc& src, int u, int v) {
    ushort t = ps1_src_raw(src, u, v);
    if (t == 0) return float4(0.0);
    return float4(float3(float(t & 0x1F), float((t >> 5) & 0x1F), float((t >> 10) & 0x1F)) / 31.0,
                  (t & 0x8000) != 0 ? 1.0 : 0.0);
}

/// The texel holding the point `coords` (texel space, centre at +0.5).
inline float4 ps1_src_rgba(thread const Ps1TexSrc& src, float2 coords) {
    int2 t = int2(floor(coords));
    return ps1_src_rgba(src, t.x, t.y);
}

/// A filter's answer for one sample point.
///
/// `t8` is the colour per channel in 1/8 of a five-bit step (0..248, what
/// `ps1_texel8` returns), `a` the coverage in 0..1 (0 when the filter found
/// only holes) and `stp` the filtered texel's STP bit, which decides the
/// composite where the nearest texel is a hole.
struct Ps1Filtered {
    int3 t8;
    float a;
    bool stp;
};

/// A filter's normalised colour and coverage as a `Ps1Filtered`: rgb in
/// 0..1 to `t8`, and STP set where the filtered alpha is at least half.
/// Coverage is clamped to 0..1 here, for every port (Nearest and Bilinear
/// build theirs in range by construction): a ringing kernel
/// (JINC2's anti-ringing lerp) can push it past 1, and `ps1_cover` would
/// extrapolate through it and paint colours no texel holds beside a hole.
inline Ps1Filtered ps1_filtered_of(float4 texcol, float a) {
    return Ps1Filtered{ clamp(int3(round(texcol.rgb * 248.0)), 0, 248), saturate(a), texcol.a >= 0.5 };
}

/// The one texel holding `coords`, at full coverage unless it is a hole:
/// what a filter with nothing to add shows.
inline Ps1Filtered ps1_filter_nearest(thread const Ps1TexSrc& src, float2 coords) {
    int2 at = int2(floor(coords));
    ushort t = ps1_src_raw(src, at.x, at.y);
    return Ps1Filtered{ ps1_texel8(t), t != 0 ? 1.0 : 0.0, (t & 0x8000) != 0 };
}

/// Bilinear over the four texels around `coords`, both variants: whether a
/// cut-out edge blends is decided by `ps1_filter_cover`, not here.
///
/// Integer throughout. Samples are texel CENTRES, so the base texel is
/// floor((u6 - 32) / 64), a real floor because u6 - 32 can be negative, and
/// each weight is in 1/64 texel per axis. A HOLE has weight zero and the rest
/// renormalise (filtering it as black draws a dark fringe around every
/// cut-out); the coverage is the weight that was not a hole, out of 64 * 64.
/// STP comes from the heaviest tap that is not a hole.
inline Ps1Filtered ps1_filter_bilinear(thread const Ps1TexSrc& src, float2 coords) {
    int2 c6 = int2(round(coords * 64.0));
    int bu = ps1_floor_div(c6.x - 32, 64), bv = ps1_floor_div(c6.y - 32, 64);
    int fu = (c6.x - 32) - bu * 64, fv = (c6.y - 32) - bv * 64;
    int3 acc = int3(0);
    int wsum = 0, heaviest = -1;
    bool stp = false;
    for (int j = 0; j < 2; j++) {
        for (int i = 0; i < 2; i++) {
            ushort t = ps1_src_raw(src, bu + i, bv + j);
            if (t == 0) continue;
            int wt = (i == 0 ? 64 - fu : fu) * (j == 0 ? 64 - fv : fv);
            acc += wt * ps1_texel8(t);
            wsum += wt;
            if (wt > heaviest) { heaviest = wt; stp = (t & 0x8000) != 0; }
        }
    }
    return Ps1Filtered{ wsum != 0 ? acc / wsum : int3(0), float(wsum) / 4096.0, stp };
}

#include "filters/jinc2.h"
#include "filters/xbr.h"
#include "filters/scale.h"
#include "filters/mmpx.h"
#include "filters/mmpx_enhanced.h"
#include "filters/mmpx_advanced.h"

/// The filters that blend a cut-out's edge into what is behind it, as one
/// bit per PS1_FILTER_* id.
constant uint ps1_edge_blending_filters =
    (1u << PS1_FILTER_BILINEAR) | (1u << PS1_FILTER_JINC2) | (1u << PS1_FILTER_XBR);

inline bool ps1_filter_blends_edges(uint f) {
    return ((ps1_edge_blending_filters >> f) & 1u) != 0;
}

/// How much of the filtered colour a sample shows over the destination's
/// sidecar, 0 meaning none. Below half coverage a sample shows nothing;
/// above it an edge-blending filter shows its coverage and every other
/// filter shows all of it.
inline float ps1_filter_cover(uint f, float a) {
    if (a < 0.5) return 0.0;
    return ps1_filter_blends_edges(f) ? a : 1.0;
}

/// The sidecar once a filtered colour `fg8` covers `cover` of a pixel whose
/// sidecar shows `bg8`: exactly `fg8` at full cover and `bg8` at none. The
/// dithering modes keep a five-bit picture, so there the mix goes back to
/// five bits.
inline ushort3 ps1_cover(ushort3 bg8, ushort3 fg8, float cover, bool true_colour) {
    int3 c = int3(round(float3(bg8) + (float3(fg8) - float3(bg8)) * cover));
    return true_colour ? ushort3(c) : ps1_expand(ps1_pack(c.x, c.y, c.z));
}

/// Every filter but NEAREST, by id. NEAREST never reaches here: the caller
/// samples the nearest texel itself.
inline Ps1Filtered ps1_filter(uint f, thread const Ps1TexSrc& src, float2 coords) {
    switch (f) {
        case PS1_FILTER_BILINEAR:
        case PS1_FILTER_BILINEAR_NO_EDGE: return ps1_filter_bilinear(src, coords);
        case PS1_FILTER_JINC2:            return ps1_filter_jinc2(src, coords, true);
        case PS1_FILTER_JINC2_NO_EDGE:    return ps1_filter_jinc2(src, coords, false);
        case PS1_FILTER_XBR:              return ps1_filter_xbr(src, coords, true);
        case PS1_FILTER_XBR_NO_EDGE:      return ps1_filter_xbr(src, coords, false);
        case PS1_FILTER_SCALE2X:          return ps1_filter_scale2x(src, coords);
        case PS1_FILTER_SCALE3X:          return ps1_filter_scale3x(src, coords);
        case PS1_FILTER_MMPX:             return ps1_filter_mmpx(src, coords);
        case PS1_FILTER_MMPX_ENHANCED:    return ps1_filter_mmpx_enhanced(src, coords);
        case PS1_FILTER_MMPX_ADVANCED:
        default:                          return ps1_filter_mmpx_advanced(src, coords);
    }
}

#endif /* PS1_FILTER_H */
