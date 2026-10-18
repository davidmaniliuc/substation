#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// The animated backdrop of the Substation and Graphite library themes, a
// SwiftUI `colorEffect`. Colour points drift on slow Lissajous paths and are
// blended by inverse squared distance in Oklab, so two saturated colours meet
// in a saturated middle rather than RGB's grey one; a few 8-bit steps of
// grain then hide the banding a dark gradient shows on an 8-bit panel.

static float3 linearFromSrgb(float3 c) {
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

static float3 srgbFromLinear(float3 c) {
    c = max(c, 0.0);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

static float3 oklabFromLinear(float3 c) {
    float3 lms = float3(0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b,
                        0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b,
                        0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b);
    lms = sign(lms) * pow(abs(lms), 1.0 / 3.0);
    return float3(0.2104542553 * lms.x + 0.7936177850 * lms.y - 0.0040720468 * lms.z,
                  1.9779984951 * lms.x - 2.4285922050 * lms.y + 0.4505937099 * lms.z,
                  0.0259040371 * lms.x + 0.7827717662 * lms.y - 0.8086757660 * lms.z);
}

static float3 linearFromOklab(float3 c) {
    float3 lms = float3(c.x + 0.3963377774 * c.y + 0.2158037573 * c.z,
                        c.x - 0.1055613458 * c.y - 0.0638541728 * c.z,
                        c.x - 0.0894841775 * c.y - 1.2914855480 * c.z);
    lms = lms * lms * lms;
    return float3( 4.0767416621 * lms.x - 3.3077115913 * lms.y + 0.2309699292 * lms.z,
                  -1.2684380046 * lms.x + 2.6097574011 * lms.y - 0.3413193965 * lms.z,
                  -0.0041960863 * lms.x - 0.7034186147 * lms.y + 1.7076147010 * lms.z);
}

static float grainHash(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

/// `colors` is sRGB triples, one per point; `falloff` is the distance
/// exponent (higher keeps each colour to its own patch); `grain` is in 8-bit
/// steps.
[[ stitchable ]] half4 libraryBackdrop(float2 position, half4 color, float2 size, float time,
                                       device const float *colors, int count,
                                       float falloff, float grain) {
    float side = max(size.x, size.y);
    float2 uv = position / side;
    float2 extent = size / side;
    float3 sum = 0.0;
    float total = 0.0;
    for (int i = 0; i < count / 3; i++) {
        float fi = float(i);
        float2 centre = extent * float2(0.5 + 0.42 * sin(time * (0.13 + 0.031 * fi) + fi * 2.39),
                                        0.5 + 0.42 * cos(time * (0.11 + 0.027 * fi) + fi * 1.71));
        float2 d = uv - centre;
        float w = 1.0 / pow(dot(d, d) + 0.002, falloff);
        float3 srgb = float3(colors[i * 3], colors[i * 3 + 1], colors[i * 3 + 2]);
        sum += oklabFromLinear(linearFromSrgb(srgb)) * w;
        total += w;
    }
    float3 rgb = srgbFromLinear(linearFromOklab(sum / total));
    rgb += (grainHash(floor(position)) - 0.5) * grain / 255.0;
    return half4(half3(rgb), 1.0h);
}
