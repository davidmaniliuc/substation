#include <metal_stdlib>
#include "PrimInstance.h"
using namespace metal;

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

/// Placeholder until Task 6 lands the real one. It discards everything, so a
/// mover-only fixture is unaffected and a drawing record is a visible hole
/// rather than a wrong pixel.
fragment ushort ps1_prim_fragment(PrimVertexOut in [[stage_in]]) {
    discard_fragment();
    return 0;
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
