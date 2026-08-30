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
    uint  scale;            // internal resolution, 1...8
};

static_assert(sizeof(Params) == 40,
              "DisplayParams in MetalDisplayView.swift must match field for field");

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

static float4 unpack1555(uint texel) {
    // ABGR1555: bits 0-4 red, 5-9 green, 10-14 blue, bit 15 mask/STP.
    float r = float( texel        & 0x1F) / 31.0;
    float g = float((texel >>  5) & 0x1F) / 31.0;
    float b = float((texel >> 10) & 0x1F) / 31.0;
    return float4(r, g, b, 1.0);
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

    // The sample grid is N times finer than the programmed display area, which
    // stays in NATIVE units (registers.zig's getVisibleWidth/Height). This
    // multiplication IS the phase: scaling only the wraps below leaves every
    // sample on its block's top-left subtexel, which by Phase C's exactness
    // property is byte-identical to the 1x picture -- 67 MB at 8x for no
    // visible change.
    uint sw = p.width  * p.scale;
    uint sh = p.height * p.scale;

    uint px = uint(in.uv.x * float(sw));
    uint py = uint(in.uv.y * float(sh));
    if (px >= sw) px = sw - 1;
    if (py >= sh) py = sh - 1;

    // The same split Rasterizer.metal applies to a scaled fragment. Everything
    // that wraps, addresses the shadow or packs bytes is computed from nx/ny;
    // only the 15bpp read of the render texture re-adds sub_x/sub_y.
    uint nx = px / p.scale, sub_x = px % p.scale;
    uint ny = py / p.scale, sub_y = py % p.scale;

    uint col = (p.vram_x + nx) & 1023;
    uint row = (p.vram_y + ny) & 511;

    if (p.depth24 != 0) {
        // 24bpp: three bytes per pixel packed across ADJACENT 16-bit VRAM
        // words. That arithmetic is meaningless once uploads are replicated
        // N x N in the scaled texture, and 24bpp content is FMV -- MDEC output
        // uploaded through A0, never upscaled geometry -- so it scans out of
        // the 1x shadow permanently, addressed at nx/ny with sub_x/sub_y
        // DISCARDED. Croc and Silent Hill both depend on this.
        uint byte_off = nx * 3;
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

    // The debug seam reads the 1x shadow, so it is native for the same reason.
    if (p.software_display != 0) {
        return unpack1555(shadow.read(uint2(col, row)).r);
    }

    // The wrap is NATIVE, then scaled. A scaled mask `& (1024 * s - 1)` -- the
    // form the parent spec specifies -- is a modulo only at power-of-two s and
    // samples the wrong column at s = 3; a scaled modulo is correct but invents
    // a second coordinate space, which Phase C's rule that ps1_vram_read
    // linearizes natively already declined.
    return unpack1555(vram.read(uint2(col * p.scale + sub_x,
                                      row * p.scale + sub_y)).r);
}
