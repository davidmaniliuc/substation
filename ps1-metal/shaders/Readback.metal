#include <metal_stdlib>
using namespace metal;

/// A native rect of the scaled VRAM: `live_renderer.zig`'s `GatherParams`
/// declares the same five words.
struct Ps1GatherParams {
    uint x0;
    uint y0;
    uint width;
    uint height;
    uint scale;
};

/// One thread per NATIVE pixel of the rect, reading its block's top-left
/// subtexel: `MetalVram.readbackNative`'s rule, so a readback costs the rect
/// and never the scaled texture.
kernel void ps1_gather_colour(texture2d<uint, access::read> src [[texture(0)]],
                              device ushort* out [[buffer(0)]],
                              constant Ps1GatherParams& p [[buffer(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.width || gid.y >= p.height) return;
    out[gid.y * p.width + gid.x] = ushort(src.read(uint2((p.x0 + gid.x) * p.scale, (p.y0 + gid.y) * p.scale)).r);
}

/// The depth plane by the same rule.
kernel void ps1_gather_depth(texture2d<uint, access::read> src [[texture(0)]],
                             device uint* out [[buffer(0)]],
                             constant Ps1GatherParams& p [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.width || gid.y >= p.height) return;
    out[gid.y * p.width + gid.x] = src.read(uint2((p.x0 + gid.x) * p.scale, (p.y0 + gid.y) * p.scale)).r;
}
