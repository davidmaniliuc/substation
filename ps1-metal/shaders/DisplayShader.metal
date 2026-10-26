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
    float saturation;       // 1 in play, eased toward 0.6 while paused
    // The toolbar band: a blur over the picture's top strip, behind the
    // traffic lights and the title. Drawable pixels throughout.
    float band_px;          // its height, edge included
    float band_edge_px;     // the short fade it ends in
    float band_sigma_px;    // the blur's standard deviation
    float band_mix;         // 0 hidden, 1 shown, eased with the HUD
    float uv_per_px_x;      // one drawable pixel in uv
    float uv_per_px_y;
};

static_assert(sizeof(Params) == 68,
              "Params in ps1-metal/src/display.zig must match field for field");

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut display_vertex(uint vid [[vertex_id]],
                                constant Params& p [[buffer(0)]]) {
    // One oversized triangle covering the viewport: no vertex buffer.
    float2 pos[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    float2 v = pos[vid];

    VertexOut out;
    // The triangle stays FULL viewport and the letterbox is applied to uv,
    // not to the position. Scaling the position instead shrinks the
    // triangle around the origin, which uncovers the left/top bars but
    // leaves the right/bottom ones inside it: those fragments then land
    // outside the picture and the fragment shader's clamp smears the last
    // texel column across them. Doing it here puts every bar outside
    // [0,1) so all four are treated alike.
    out.position = float4(v, 0.0, 1.0);
    // uv (0,0) at top-left of the visible area.
    out.uv = float2((v.x / p.scale_x) * 0.5 + 0.5,
                    (v.y / p.scale_y) * -0.5 + 0.5);
    return out;
}

/// ABGR1555 -> linear float, with the five-bit channels expanded by
/// REPLICATION (`c << 3 | c >> 2`) rather than divided by 31.
///
/// The two must be the same expansion. This is the fallback for a pixel the
/// sidecar has marked absent, and the sidecar itself holds `c << 3 | c >> 2`
/// for every five-bit-derived pixel, so a different expression here would
/// draw a one-level seam along the boundary of every invalidated rect. It is
/// also what `VramImage.write` has always used for a dump, for the reason its
/// own comment gives.
static float4 unpack1555(uint texel) {
    uint r = texel & 0x1F, g = (texel >> 5) & 0x1F, b = (texel >> 10) & 0x1F;
    return float4(float((r << 3) | (r >> 2)) / 255.0,
                  float((g << 3) | (g >> 2)) / 255.0,
                  float((b << 3) | (b >> 2)) / 255.0,
                  1.0);
}

static float4 display_color(VertexOut in,
                            texture2d<uint, access::read> vram,
                            texture2d<uint, access::read> shadow,
                            texture2d<uint, access::read> sidecar,
                            constant Params& p) {
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
        // words, so the packing is native arithmetic: each word is read from
        // the render texture at its block's TOP-LEFT subtexel (the readback
        // rule), addressed at nx/ny with sub_x/sub_y DISCARDED. 24bpp content
        // is FMV, MDEC output uploaded through A0, and a native upload is
        // exact there at every scale. Croc and Silent Hill both depend on this.
        uint byte_off = nx * 3;
        uint w0 = vram.read(uint2(((p.vram_x + (byte_off >> 1)) & 1023) * p.scale, row * p.scale)).r;
        uint w1 = vram.read(uint2(((p.vram_x + (byte_off >> 1) + 1) & 1023) * p.scale, row * p.scale)).r;

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

    // The debug seam reads the 1x shadow, which is native by construction.
    if (p.software_display != 0) {
        return unpack1555(shadow.read(uint2(col, row)).r);
    }

    // The eight-bit sidecar where it has something to say, VRAM expanded where
    // it does not. Alpha is PRESENCE, not opacity: 255 means this pixel's
    // eight-bit colour was written by the draw that produced the VRAM pixel
    // beneath it. Nothing here consults the dither mode: the sidecar's
    // CONTENT is what the mode decides, in Rasterizer.metal.
    uint2 addr = uint2(col * p.scale + sub_x, row * p.scale + sub_y);
    uint4 side = sidecar.read(addr);
    if (side.a != 0) {
        return float4(float(side.r) / 255.0, float(side.g) / 255.0,
                      float(side.b) / 255.0, 1.0);
    }
    // The wrap is NATIVE, then scaled. A scaled mask `& (1024 * s - 1)` -- the
    // form the parent spec specifies -- is a modulo only at power-of-two s and
    // samples the wrong column at s = 3.
    return unpack1555(vram.read(addr).r);
}

/// The taps' spacing, two to a standard deviation, and how far the window
/// reaches either side of the centre, in standard deviations.
constant float band_taps_per_sigma = 2.0;
constant float band_reach_sigmas = 2.0;
/// Enough for any window: the stride rounds, so a sigma holds at most three
/// strides and a window at most thirteen taps per axis.
constant int band_max_taps = 16;
/// The band's tone: darker than the picture, as a dark toolbar is, so the
/// white title reads over a bright scene.
constant float band_tone = 0.8;

/// A Gaussian lowered to reach zero at the window's edge, so a tap enters
/// and leaves the window at no weight as the fragment moves.
static float band_weight(float d, float sigma, float reach) {
    float k = 1.0 / (2.0 * sigma * sigma);
    return max(exp(-d * d * k) - exp(-reach * reach * k), 0.0);
}

/// The picture under the band, Gaussian-blurred. The taps sit on a lattice
/// fixed to the picture's own sample grid, not offset from the fragment:
/// read nearest, fragment-relative taps all cross a texel edge together,
/// which holds the blur flat across each source pixel and draws it as
/// squares. On the lattice only the weights move, and they move smoothly.
/// The taps stay inside the picture, clamped rather than read as the black
/// outside it, or the top edge would darken into a vignette.
static float3 band_color(VertexOut in,
                         texture2d<uint, access::read> vram,
                         texture2d<uint, access::read> shadow,
                         texture2d<uint, access::read> sidecar,
                         constant Params& p) {
    float2 grid = float2(p.width * p.scale, p.height * p.scale);
    float2 sigma = p.band_sigma_px * float2(p.uv_per_px_x, p.uv_per_px_y) * grid;
    float2 stride = max(round(sigma / band_taps_per_sigma), 1.0);
    float2 reach = sigma * band_reach_sigmas;
    float2 centre = in.uv * grid - 0.5;
    float2 first = ceil((centre - reach) / stride) * stride;
    float3 sum = 0.0;
    float total = 0.0;
    for (int j = 0; j < band_max_taps; j++) {
        float y = first.y + float(j) * stride.y;
        if (y - centre.y > reach.y) break;
        float wy = band_weight(y - centre.y, sigma.y, reach.y);
        for (int i = 0; i < band_max_taps; i++) {
            float x = first.x + float(i) * stride.x;
            if (x - centre.x > reach.x) break;
            float w = wy * band_weight(x - centre.x, sigma.x, reach.x);
            VertexOut tap = in;
            tap.uv = (clamp(float2(x, y), 0.0, grid - 1.0) + 0.5) / grid;
            sum += display_color(tap, vram, shadow, sidecar, p).rgb * w;
            total += w;
        }
    }
    return sum / max(total, 1e-6) * band_tone;
}

/// The picture, under the toolbar band while the HUD shows, desaturated
/// toward its Rec. 709 luma by `saturation`: the paused game greys out
/// under the HUD.
fragment float4 display_fragment(VertexOut in [[stage_in]],
                                 texture2d<uint, access::read> vram [[texture(0)]],
                                 texture2d<uint, access::read> shadow [[texture(1)]],
                                 texture2d<uint, access::read> sidecar [[texture(2)]],
                                 constant Params& p [[buffer(0)]]) {
    float4 c = display_color(in, vram, shadow, sidecar, p);
    bool inPicture = all(in.uv >= 0.0) && all(in.uv < 1.0);
    if (p.band_mix > 0.0 && in.position.y < p.band_px && inPicture) {
        float shown = p.band_mix
            * (1.0 - smoothstep(p.band_px - p.band_edge_px, p.band_px, in.position.y));
        c.rgb = mix(c.rgb, band_color(in, vram, shadow, sidecar, p), shown);
    }
    float luma = dot(c.rgb, float3(0.2126, 0.7152, 0.0722));
    return float4(mix(float3(luma), c.rgb, p.saturation), c.a);
}
