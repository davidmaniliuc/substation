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
                                uint base [[base_instance]],
                                const device Ps1PrimInstance* prims [[buffer(0)]]) {
    uint index = base + iid;
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
