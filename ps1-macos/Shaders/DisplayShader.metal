#include <metal_stdlib>
using namespace metal;

struct Params {
    uint  vram_x;
    uint  vram_y;
    uint  width;
    uint  height;
    uint  depth24;
    uint  enabled;
    float scale_x;   // letterboxing: 1.0 on the axis that fills
    float scale_y;
    uint  software_display; // debug seam: read the 1x shadow at 15bpp too
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut display_vertex(uint vid [[vertex_id]],
                                constant Params& p [[buffer(0)]]) {
    // One oversized triangle covering the viewport — no vertex buffer.
    float2 pos[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    float2 v = pos[vid];

    VertexOut out;
    // The triangle stays FULL viewport and the letterbox is applied to uv,
    // not to the position. Scaling the position instead shrinks the
    // triangle around the origin, which uncovers the left/top bars but
    // leaves the right/bottom ones inside it — those fragments then land
    // outside the picture and the fragment shader's clamp smears the last
    // texel column across them. Doing it here puts every bar outside
    // [0,1) so all four are treated alike.
    out.position = float4(v, 0.0, 1.0);
    // uv (0,0) at top-left of the visible area.
    out.uv = float2((v.x / p.scale_x) * 0.5 + 0.5,
                    (v.y / p.scale_y) * -0.5 + 0.5);
    return out;
}

fragment float4 display_fragment(VertexOut in [[stage_in]],
                                 texture2d<uint, access::read> vram [[texture(0)]],
                                 texture2d<uint, access::read> shadow [[texture(1)]],
                                 constant Params& p [[buffer(0)]]) {
    // Outside the picture: a letterbox bar.
    if (any(in.uv < 0.0) || any(in.uv >= 1.0)) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    if (p.enabled == 0 || p.width == 0 || p.height == 0) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    uint px = uint(in.uv.x * float(p.width));
    uint py = uint(in.uv.y * float(p.height));
    if (px >= p.width)  px = p.width  - 1;
    if (py >= p.height) py = p.height - 1;

    uint row = (p.vram_y + py) & 511;

    if (p.depth24 != 0) {
        // 24bpp: three bytes per pixel packed across ADJACENT 16-bit VRAM
        // words. That arithmetic is meaningless once uploads are replicated
        // N x N in the scaled texture, and 24bpp content is FMV -- MDEC output
        // uploaded through A0, never upscaled geometry -- so it scans out of
        // the 1x shadow permanently. Croc and Silent Hill both depend on this.
        uint byte_off = px * 3;
        uint w0 = shadow.read(uint2((p.vram_x + (byte_off >> 1)) & 1023, row)).r;
        uint w1 = shadow.read(uint2((p.vram_x + (byte_off >> 1) + 1) & 1023, row)).r;

        uint r, g, b;
        if ((byte_off & 1) == 0) {
            r =  w0        & 0xFF;
            g = (w0 >> 8)  & 0xFF;
            b =  w1        & 0xFF;
        } else {
            r = (w0 >> 8)  & 0xFF;
            g =  w1        & 0xFF;
            b = (w1 >> 8)  & 0xFF;
        }
        return float4(float(r) / 255.0, float(g) / 255.0, float(b) / 255.0, 1.0);
    }

    // ABGR1555: bits 0-4 red, 5-9 green, 10-14 blue, bit 15 mask/STP.
    uint2 at = uint2((p.vram_x + px) & 1023, row);
    uint texel = p.software_display != 0 ? shadow.read(at).r : vram.read(at).r;
    float r = float( texel        & 0x1F) / 31.0;
    float g = float((texel >>  5) & 0x1F) / 31.0;
    float b = float((texel >> 10) & 0x1F) / 31.0;
    return float4(r, g, b, 1.0);
}
