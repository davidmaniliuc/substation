#include <metal_stdlib>
#include "PrimInstance.h"
using namespace metal;
#include "Ps1Color.h"

static_assert(sizeof(Ps1PrimInstance) == 4 * 48,
              "Ps1PrimInstance layout changed — update the Swift stride test too");

/* 1/16 px: `renderer.zig`'s q_unit, and q_unit * q_unit for the fill-rule
   bias. Both sides must agree or the two rasterizers disagree on coverage. */
#define PS1_Q_UNIT       16
#define PS1_Q_BIAS_SCALE 256

static_assert(sizeof(Ps1RasterUniforms) == 8,
              "Ps1RasterUniforms layout changed — update the Swift stride test too");

/// The two colour attachments every fragment in this file writes.
///
/// color(0) is VRAM: ABGR1555, hardware-exact, the authority, and what every
/// gate reads. color(1) is the display-only sidecar: eight bits per channel,
/// with ALPHA AS PRESENCE — 255 where it holds a real colour, 0 where the
/// display must expand VRAM instead.
///
/// `ushort4` and not `uchar4`: MSL's render-target and texture data types are
/// half/float/short/ushort/int/uint, so a uchar vector is not a portable
/// spelling for an .rgba8Uint attachment. Every value here is 0...255 anyway —
/// ps1_pack8 clamps before this struct is ever built.
///
/// A fragment that discards writes NEITHER attachment, which is why the mask
/// bit needs no special case: a check-mask rejection leaves both alone and a
/// set-mask write writes both.
struct Ps1FragOut {
    ushort  vram [[color(0)]];
    ushort4 side [[color(1)]];
};

/// PRESENT: this pixel's eight-bit colour.
inline Ps1FragOut ps1_out(ushort v, ushort3 rgb8) {
    return Ps1FragOut{ v, ushort4(rgb8, 255) };
}

/// ABSENT: VRAM is written and the sidecar says "no extra precision here", so
/// the display expands VRAM. Every invalidation degrades to today's picture
/// rather than to a visible defect.
inline Ps1FragOut ps1_out_absent(ushort v) {
    return Ps1FragOut{ v, ushort4(0, 0, 0, 0) };
}

/// The return value of a discarded fragment: neither attachment is written, so
/// only the type matters.
inline Ps1FragOut ps1_discarded() { return Ps1FragOut{ 0, ushort4(0) }; }

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
fragment Ps1FragOut ps1_fill_fragment(PrimVertexOut in [[stage_in]],
                                      const device Ps1PrimInstance* prims [[buffer(0)]]) {
    ushort v = ushort(prims[in.iid].color);
    // MAINTAIN, at five bits. A fill's colour is a flat 5-bit value that
    // expands exactly, so there is no extra precision to keep — the same
    // reasoning as the flat-colour carve-out in ps1_prim_fragment.
    return ps1_out(v, ps1_expand(v));
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
    // Phase C scaled the VERTICES up by s. That inverts here: the vertices
    // arrive in native 1/16-px units, relative to the primitive's own box, and
    // the SAMPLE POINT is reduced to them. Scaling 1/16-px vertices up by s
    // instead would put ps1_orient at 2^35 and force `long` into the
    // per-fragment inner loop of every triangle in every game.
    //
    // At a top-left subtexel px == nx * s, so (px * 16) / s is exactly nx * 16
    // for every s including 3 — downsample-invariance holds by construction
    // rather than by argument. px * 16 peaks at 1024 * 8 * 16 = 2^17.
    int ox = min(p.x0, min(p.x1, p.x2));
    int oy = min(p.y0, min(p.y1, p.y2));
    int qpx = (px * PS1_Q_UNIT) / s - ox * PS1_Q_UNIT;
    int qpy = (py * PS1_Q_UNIT) / s - oy * PS1_Q_UNIT;

    int ax = p.qx0, ay = p.qy0;
    int bx = p.qx1, by = p.qy1;
    int cx = p.qx2, cy = p.qy2;

    int area_signed = ps1_orient(ax, ay, bx, by, cx, cy);
    // Normalize to a positive area by flipping the sign of every edge function
    // rather than by swapping two vertices: a swap would permute the
    // attributes the shader indexes by vertex number.
    int sgn = area_signed < 0 ? -1 : 1;
    area = area_signed * sgn;

    // The fill rule reads only the SIGN of each edge delta, so the q-space
    // deltas classify identically to the native ones.
    //
    // The bias stays at -1 here, where `renderer.zig` uses -PS1_Q_BIAS_SCALE,
    // and the difference is load-bearing rather than an oversight. The bias is
    // a TIEBREAK: it must exclude an edge function of exactly zero and nothing
    // more. `renderer.zig` samples once per whole pixel, so with PGXP off
    // every edge function it sees is a multiple of PS1_Q_BIAS_SCALE and -256
    // excludes exactly zero. This shader samples once per SUBTEXEL, so at
    // s = 8 an edge function can be as fine as 32 q-units and a bias of 256
    // erodes up to a whole native pixel from every top-left edge — a crack
    // along every shared edge in the scene, with whatever was drawn earlier
    // showing through it.
    int bias0 = ps1_top_left(sgn * (cx - bx), sgn * (cy - by)) ? -1 : 0;
    int bias1 = ps1_top_left(sgn * (ax - cx), sgn * (ay - cy)) ? -1 : 0;
    int bias2 = ps1_top_left(sgn * (bx - ax), sgn * (by - ay)) ? -1 : 0;

    int b0 = sgn * ps1_orient(bx, by, cx, cy, qpx, qpy) + bias0;
    int b1 = sgn * ps1_orient(cx, cy, ax, ay, qpx, qpy) + bias1;
    int b2 = sgn * ps1_orient(ax, ay, bx, by, qpx, qpy) + bias2;

    // Avocado's coverage test, in two halves. A negative term sets the sign bit
    // of the OR, so this first half means "all three non-negative" — a pure
    // statement about geometry, and it is asked of every subtexel.
    if ((b0 | b1 | b2) < 0) return false;

    // The second half — "and not all three zero", restated at whole-pixel
    // granularity as `b_i < PS1_Q_BIAS_SCALE` — is asked at the NATIVE SAMPLE
    // POINT and nowhere else.
    //
    // It is a statement about SAMPLING, not about the shape: hardware takes one
    // sample per pixel, and a triangle enclosing no sample point paints nothing.
    // The three terms sum to the twice-area, so it can only fire under
    // 3 * PS1_Q_BIAS_SCALE — 1.5 native px^2, a triangle smaller than the pixels
    // it lands in. Off the native lattice there is no hardware decision to
    // reproduce: those are samples the console never took, so geometry alone
    // decides them, and reproducing a one-sample-per-pixel artifact 64 times a
    // pixel is faithful to the wrong thing.
    //
    // Two narrower readings of this both shipped and both cut real geometry out
    // of a sub-pixel mesh. Evaluated at the SUBTEXEL, it refuses the band around
    // the centroid where all three terms are smallest, and a ~1px triangle comes
    // out as a RING. Evaluated once per native pixel with the whole block taking
    // that answer, it rescues the pixel's OWNER and nobody else — a non-owner's
    // native sample point lies outside it by definition — so every neighbour's
    // share of a shared pixel stayed background, and a mesh of ~1px facets is
    // nothing but neighbours. Measured on FF7's Cloud at 8x, whose facets are
    // 67% under 1.5 native px^2: over the model's 1x-painted blocks, 387
    // subtexels were unpainted while covered by a triangle.
    //
    // Gate 2 survives as a STRICT equality rather than being restated
    // one-directionally, because the top-left subtexel IS the native sample
    // point: px == nx * s makes qpx exactly nqx, so this reproduces the 1x
    // answer there by construction. At s == 1 every fragment is a native sample
    // point, which is also why the 1x gate against `renderer.zig` cannot move —
    // and why there is no `area` guard here, unlike the branch this replaced:
    // `renderer.zig` asks the clause of every pixel unconditionally, and the
    // terms summing to the twice-area is what keeps it from firing on a large
    // triangle.
    //
    // A genuine sliver — one 1x refuses everywhere — therefore stays refused at
    // every native sample point at every scale, which is the half of the rule
    // upscaling must not quietly undo. It does now paint the off-lattice
    // subtexels it covers: 1/s^2 of a pixel apiece, on samples no oracle reads.
    // That is the price of a hole-free sub-pixel mesh, and it is the cheaper
    // side of the trade.
    if (px % s == 0 && py % s == 0
        && b0 < PS1_Q_BIAS_SCALE && b1 < PS1_Q_BIAS_SCALE && b2 < PS1_Q_BIAS_SCALE) {
        return false;
    }

    w0 = b0 - bias0;
    w1 = b1 - bias1;
    w2 = b2 - bias2;
    return true;
}

/// Texture-window masking, the texel fetch and optional modulation — the
/// tail both textured paths share.
///
/// Returns false for a texel-zero HOLE, which the caller treats as a discard:
/// `renderer.zig:439` returns `.draw = false`. The hole is decided on the RAW
/// texel, BEFORE modulation, and the resulting colour comes back through an
/// out-param rather than as a return value — because modulation maps plenty of
/// non-zero texels onto 0x0000 and `renderer.zig:441-446` draws every one of
/// them BLACK. Signalling the hole with a colour of 0 conflates the two, and
/// what shows through the wrongly-discarded pixel is whatever was already in
/// VRAM: green speckle over Croc's dark rock, door and crate. Dithering makes
/// it scale-dependent — its 8-bit offset pushes marginal channels under 8 at
/// 1x only — so the same bug reads as two different artifacts.
/// `shade` is the modulation colour AT THIS PIXEL: one flat colour for a
/// textured rectangle, the colour interpolated across the primitive for a
/// Gouraud-shaded textured triangle (GP0 0x34-0x37, 0x3C-0x3F). Taking the
/// first vertex's colour for the whole triangle is what flattened Crash
/// Warped's title glow into hard shards.
inline bool ps1_sample(const device Ps1PrimInstance& p,
                       texture2d<ushort, access::read> vram, uint s,
                       uint u, uint v, int dither_o,
                       ushort shade, thread ushort& out) {
    uint mask_x   = (p.tex_window & 0x1Fu) * 8u;
    uint mask_y   = ((p.tex_window >> 5) & 0x1Fu) * 8u;
    uint offset_x = ((p.tex_window >> 10) & 0x1Fu) * 8u;
    uint offset_y = ((p.tex_window >> 15) & 0x1Fu) * 8u;

    // The texture window is in TEXEL units, like u and v — nothing here scales.
    uint final_u = (u & ~mask_x) | (offset_x & mask_x);
    uint final_v = (v & ~mask_y) | (offset_y & mask_y);

    ushort texel = ps1_fetch_texel(vram, s, p.tex_depth, p.tpage_x, p.tpage_y,
                                   p.clut_x, p.clut_y, final_u, final_v);
    if (texel == 0) return false;
    out = (p.flags & PS1_PRIM_MODULATE)
        ? ps1_modulate(texel, shade, dither_o)
        : texel;
    return true;
}

/// Every drawing primitive. `dst` is the destination pixel through
/// programmable blending — the same pixel via tile memory, which is a
/// different mechanism from sampling an arbitrary VRAM address and is not
/// affected by the pass-splitting invariant.
fragment Ps1FragOut ps1_prim_fragment(PrimVertexOut in [[stage_in]],
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
    // The dither offset, resolved ONCE and then added unconditionally: 0 is
    // the no-op, so nothing below needs a branch of its own.
    //
    // WHICH coordinate indexes the table is the setting — see the PS1_DITHER_*
    // comment in PrimInstance.h. Indexing by the NATIVE pixel hands every
    // subtexel of a pixel that pixel's own 1x offset, so the top-left subtexel
    // reproduces the 1x answer exactly; indexing by the subtexel gives the
    // finest pattern and is the one mode that breaks that. At s == 1 the two
    // expressions are the same, so neither can move Gate 1.
    //
    // Decided HERE, not in PrimBuilder: clearing the flag on the CPU would
    // make the instance record differ between modes and forfeit the
    // byte-identical-records property the phase rests on.
    int dither_o = 0;
    if (p.flags & PS1_PRIM_DITHER) {
        if (uni.dither_mode == PS1_DITHER_SCALED)      dither_o = ps1_dither(px, py);
        else if (uni.dither_mode == PS1_DITHER_NATIVE) dither_o = ps1_dither(nx, ny);
    }

    bool transparent = (p.flags & PS1_PRIM_TRANSPARENT) != 0;
    ushort src;

    if (p.kind == PS1_PRIM_FLAT_TRI) {
        int w0, w1, w2, area;
        if (!ps1_triangle_coverage(p, s, px, py, w0, w1, w2, area)) { discard_fragment(); return ps1_discarded(); }
        src = ushort(p.color);
    } else if (p.kind == PS1_PRIM_GOURAUD_TRI) {
        int w0, w1, w2, area;
        if (!ps1_triangle_coverage(p, s, px, py, w0, w1, w2, area)) { discard_fragment(); return ps1_discarded(); }
        // Wire colours are 24-bit BGR: red in the low byte.
        int r = ps1_interp(w0, w1, w2, area,
                           int(p.c0 & 0xFFu), int(p.c1 & 0xFFu), int(p.c2 & 0xFFu));
        int g = ps1_interp(w0, w1, w2, area,
                           int((p.c0 >> 8) & 0xFFu), int((p.c1 >> 8) & 0xFFu), int((p.c2 >> 8) & 0xFFu));
        int b = ps1_interp(w0, w1, w2, area,
                           int((p.c0 >> 16) & 0xFFu), int((p.c1 >> 16) & 0xFFu), int((p.c2 >> 16) & 0xFFu));
        src = ps1_pack(r + dither_o, g + dither_o, b + dither_o);
    } else if (p.kind == PS1_PRIM_TEXTURED_TRI) {
        int w0, w1, w2, area;
        if (!ps1_triangle_coverage(p, s, px, py, w0, w1, w2, area)) { discard_fragment(); return ps1_discarded(); }

        // u/v are 8-bit fields on the wire, and coverage guarantees every
        // unbiased w_i >= 0 with w0+w1+w2 == area exactly, so the interpolant
        // is a convex combination of three in-range values on every covered
        // pixel. The clamp cannot actually trigger; it is the same defensive
        // guard renderer.zig:425-426 keeps, for the same reason.
        uint u = uint(clamp(ps1_interp(w0, w1, w2, area, p.u0, p.u1, p.u2), 0, 255));
        uint v = uint(clamp(ps1_interp(w0, w1, w2, area, p.v0, p.v1, p.v2), 0, 255));

        // The modulation colour is interpolated exactly as the Gouraud path's
        // is. A flat-shaded textured polygon carries the same colour in all
        // three slots, and `w0 + w1 + w2 == area` exactly, so this reproduces
        // the single-colour result bit for bit rather than approximating it.
        // NOT dithered here: `ps1_modulate` adds the offset to the MODULATED
        // channel, at 8-bit scale, exactly as `Color.modulate` does.
        ushort shade = ps1_pack(
            ps1_interp(w0, w1, w2, area,
                       int(p.c0 & 0xFFu), int(p.c1 & 0xFFu), int(p.c2 & 0xFFu)),
            ps1_interp(w0, w1, w2, area,
                       int((p.c0 >> 8) & 0xFFu), int((p.c1 >> 8) & 0xFFu), int((p.c2 >> 8) & 0xFFu)),
            ps1_interp(w0, w1, w2, area,
                       int((p.c0 >> 16) & 0xFFu), int((p.c1 >> 16) & 0xFFu), int((p.c2 >> 16) & 0xFFu)));

        if (!ps1_sample(p, vram, uint(s), u, v, dither_o, shade, src)) { discard_fragment(); return ps1_discarded(); }
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
        src = ps1_pack(r + dither_o, g + dither_o, b + dither_o);
    } else if (p.kind == PS1_PRIM_TEXTURED_RECT) {
        // `tu +% @truncate(xx)` on u8 — a WRAP, not the triangle path's
        // interpolate-and-clamp. This is why the sprite path is a separate
        // shader path rather than a special case of the triangle one. It is
        // computed from the NATIVE pixel: the wrap is in texel units and has
        // nothing to do with internal resolution.
        uint u = uint((nx - p.x0) + p.u0) & 0xFFu;
        uint v = uint((ny - p.y0) + p.v0) & 0xFFu;
        if (!ps1_sample(p, vram, uint(s), u, v, dither_o, ushort(p.color), src)) { discard_fragment(); return ps1_discarded(); }
        transparent = transparent && (src & 0x8000) != 0;
    } else {
        discard_fragment();
        return ps1_discarded();
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
        return ps1_discarded();
    }
    if ((p.flags & PS1_PRIM_CHECK_MASK) && (dst & 0x8000)) { discard_fragment(); return ps1_discarded(); }

    ushort out = transparent ? ps1_blend(dst, src, p.blend_mode) : src;

    // Bit 15 of the written pixel is the SOURCE pixel's own bit 15 — for a
    // textured primitive the texel's STP bit, for an untextured one 0 — OR'd
    // with GP0(E6).bit0. It must NOT be cleared: games mask off already-drawn
    // areas by leaving STP-set texels in VRAM and drawing with check-mask.
    if (p.flags & PS1_PRIM_SET_MASK) out |= 0x8000;
    // MAINTAIN, at five bits for now. Task 4 replaces the second argument with
    // the eight-bit shade in `.trueColor`; until then the sidecar is an exact
    // mirror of VRAM and the picture cannot move.
    return ps1_out(out, ps1_expand(out));
}

/// GP0(A0). The payload run is a device buffer; this maps each covered pixel
/// back to the word carrying it. `word_base` is pre-biased by the encoder so
/// that `word_base + pixel/2` is that word, with the parity selecting the half.
///
/// Respects the E6 mask, unlike the fill above — `vram.zig` routes CPU->VRAM
/// through `maskedWrite` and Fill Rectangle around it.
fragment Ps1FragOut ps1_upload_fragment(PrimVertexOut in [[stage_in]],
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
    if (pix < p.pixel_first || pix > p.pixel_last) { discard_fragment(); return ps1_discarded(); }
    if ((p.flags & PS1_PRIM_CHECK_MASK) && (dst & 0x8000)) { discard_fragment(); return ps1_discarded(); }

    uint word = words[p.word_base + (pix >> 1)];
    ushort v = ushort((pix & 1) ? (word >> 16) : word);
    if (p.flags & PS1_PRIM_SET_MASK) v |= 0x8000;
    // INVALIDATE. The payload is genuine 5551 from the game; no extra
    // precision exists for this pixel and claiming any would show the pixel
    // that USED to be here.
    return ps1_out_absent(v);
}

/// GP0(80). Masked, and WRAPS on both axes rather than clipping.
///
/// `scratch` is a snapshot of VRAM taken at the pass boundary just before this
/// draw, which is what makes `vram.zig:154`'s backwards-iteration branch
/// unnecessary: a self-overlapping copy reads a frozen source, so the
/// direction question disappears instead of having to be reproduced.
fragment Ps1FragOut ps1_copy_fragment(PrimVertexOut in [[stage_in]],
                                      ushort dst [[color(0)]],
                                      const device Ps1PrimInstance* prims [[buffer(0)]],
                                      constant Ps1RasterUniforms& uni [[buffer(2)]],
                                      texture2d<ushort, access::read> scratch [[texture(0)]],
                                      texture2d<ushort, access::read> side_scratch [[texture(1)]]) {
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
    if (xx >= p.w || yy >= p.h) { discard_fragment(); return ps1_discarded(); }
    if ((p.flags & PS1_PRIM_CHECK_MASK) && (dst & 0x8000)) { discard_fragment(); return ps1_discarded(); }

    // The ONE read in this backend that is not reduced to native. The source
    // address is native and wrapping; the subpixel offset is added after the
    // scale, so a blit MOVES scaled detail rather than flattening it to each
    // block's top-left subtexel. At a top-left subtexel both offsets are 0, so
    // the exactness property is untouched — which is exactly why a shader that
    // dropped them would still pass Gate 2.
    uint2 src = uint2(uint(((p.src_x + xx) & 0x3FF) * s + sub_x),
                      uint(((p.src_y + yy) & 0x1FF) * s + sub_y));
    ushort v = scratch.read(src).r;
    if (p.flags & PS1_PRIM_SET_MASK) v |= 0x8000;
    // CARRY, in THIS pass and from the same frozen snapshot. A VRAM->VRAM copy
    // wraps at the VRAM edges and may overlap itself; a sidecar copied in a
    // second pass can resolve that overlap differently from the VRAM copy
    // beside it, and the two pictures then disagree about which source row won.
    // One pass, two attachments, one ordering — so an absent source yields an
    // absent destination with no rule of its own.
    return Ps1FragOut{ v, side_scratch.read(src) };
}
