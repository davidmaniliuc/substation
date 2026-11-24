/* xBR. Included by Filter.h; the contract is there.

   Hyllian's xBR-vertex code and texel mapping

   Copyright (C) 2011/2016 Hyllian - sergiogdb@gmail.com

   Permission is hereby granted, free of charge, to any person obtaining a copy
   of this software and associated documentation files (the "Software"), to deal
   in the Software without restriction, including without limitation the rights
   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
   copies of the Software, and to permit persons to whom the Software is
   furnished to do so, subject to the following conditions:

   The above copyright notice and this permission notice shall be included in
   all copies or substantial portions of the Software.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
   THE SOFTWARE.
*/
#ifndef PS1_FILTER_XBR_H
#define PS1_FILTER_XBR_H

constant int PS1_XBR_BLEND_NONE = 0;
constant int PS1_XBR_BLEND_NORMAL = 1;
constant int PS1_XBR_BLEND_DOMINANT = 2;
constant float PS1_XBR_LUMINANCE_WEIGHT = 1.0;
constant float PS1_XBR_EQUAL_COLOR_TOLERANCE = 0.1176470588235294;
constant float PS1_XBR_STEEP_DIRECTION_THRESHOLD = 2.2;
constant float PS1_XBR_DOMINANT_DIRECTION_THRESHOLD = 3.6;
constant float4 ps1_xbr_w = float4(0.2627, 0.6780, 0.0593, 0.5);

inline float ps1_xbr_dist_ycbcr(float4 pixA, float4 pixB) {
    const float scaleB = 0.5 / (1.0 - ps1_xbr_w.b);
    const float scaleR = 0.5 / (1.0 - ps1_xbr_w.r);
    float4 diff = pixA - pixB;
    float Y = dot(diff, ps1_xbr_w);
    float Cb = scaleB * (diff.b - Y);
    float Cr = scaleR * (diff.r - Y);

    return sqrt(((PS1_XBR_LUMINANCE_WEIGHT * Y) * (PS1_XBR_LUMINANCE_WEIGHT * Y)) + (Cb * Cb) + (Cr * Cr));
}

inline bool ps1_xbr_is_pix_equal(const float4 pixA, const float4 pixB) {
    return (ps1_xbr_dist_ycbcr(pixA, pixB) < PS1_XBR_EQUAL_COLOR_TOLERANCE);
}

inline float ps1_xbr_get_left_ratio(float2 center, float2 origin, float2 direction, float2 scale) {
    float2 P0 = center - origin;
    float2 proj = direction * (dot(P0, direction) / dot(direction, direction));
    float2 distv = P0 - proj;
    float2 orth = float2(-direction.y, direction.x);
    float side = sign(dot(P0, orth));
    float v = side * length(distv * scale);

    return smoothstep(-sqrt(2.0) / 2.0, sqrt(2.0) / 2.0, v);
}

inline bool ps1_xbr_eq(float4 a, float4 b) { return all(a == b); }
inline bool ps1_xbr_neq(float4 a, float4 b) { return any(a != b); }

#define PS1_XBR_P(xoffs, yoffs) ps1_src_rgba(src, at.x + (xoffs), at.y + (yoffs))

inline Ps1Filtered ps1_filter_xbr(thread const Ps1TexSrc& src, float2 coords, bool blend_edges) {
    //---------------------------------------
    // Input Pixel Mapping:  -|x|x|x|-
    //                       x|A|B|C|x
    //                       x|D|E|F|x
    //                       x|G|H|I|x
    //                       -|x|x|x|-

    float2 scale = float2(8.0, 8.0);
    float2 pos = fract(coords.xy) - float2(0.5, 0.5);
    int2 at = int2(floor(coords));

    float4 A = PS1_XBR_P(-1, -1);
    A.w = float(ps1_xbr_neq(A, float4(0.0)));
    float4 B = PS1_XBR_P(0, -1);
    float Bw = B.w;
    B.w = float(ps1_xbr_neq(B, float4(0.0)));
    float4 C = PS1_XBR_P(1, -1);
    C.w = float(ps1_xbr_neq(C, float4(0.0)));
    float4 D = PS1_XBR_P(-1, 0);
    float Dw = D.w;
    D.w = float(ps1_xbr_neq(D, float4(0.0)));
    float4 E = PS1_XBR_P(0, 0);
    float Ew = E.w;
    E.w = float(ps1_xbr_neq(E, float4(0.0)));
    float4 F = PS1_XBR_P(1, 0);
    float Fw = F.w;
    F.w = float(ps1_xbr_neq(F, float4(0.0)));
    float4 G = PS1_XBR_P(-1, 1);
    G.w = float(ps1_xbr_neq(G, float4(0.0)));
    float4 H = PS1_XBR_P(0, 1);
    float Hw = H.w;
    H.w = float(ps1_xbr_neq(H, float4(0.0)));
    float4 I = PS1_XBR_P(1, 1);
    I.w = float(ps1_xbr_neq(H, float4(0.0)));

    // blendResult Mapping: x|y|
    //                      w|z|
    int4 blendResult = int4(PS1_XBR_BLEND_NONE, PS1_XBR_BLEND_NONE, PS1_XBR_BLEND_NONE, PS1_XBR_BLEND_NONE);

    // Preprocess corners
    // Pixel Tap Mapping: -|-|-|-|-
    //                    -|-|B|C|-
    //                    -|D|E|F|x
    //                    -|G|H|I|x
    //                    -|-|x|x|-
    if (!((ps1_xbr_eq(E, F) && ps1_xbr_eq(H, I)) || (ps1_xbr_eq(E, H) && ps1_xbr_eq(F, I)))) {
        float dist_H_F = ps1_xbr_dist_ycbcr(G, E) + ps1_xbr_dist_ycbcr(E, C) + ps1_xbr_dist_ycbcr(PS1_XBR_P(0, 2), I) + ps1_xbr_dist_ycbcr(I, PS1_XBR_P(2, 0)) + (4.0 * ps1_xbr_dist_ycbcr(H, F));
        float dist_E_I = ps1_xbr_dist_ycbcr(D, H) + ps1_xbr_dist_ycbcr(H, PS1_XBR_P(1, 2)) + ps1_xbr_dist_ycbcr(B, F) + ps1_xbr_dist_ycbcr(F, PS1_XBR_P(2, 1)) + (4.0 * ps1_xbr_dist_ycbcr(E, I));
        bool dominantGradient = (PS1_XBR_DOMINANT_DIRECTION_THRESHOLD * dist_H_F) < dist_E_I;
        blendResult.z = ((dist_H_F < dist_E_I) && ps1_xbr_neq(E, F) && ps1_xbr_neq(E, H)) ? ((dominantGradient) ? PS1_XBR_BLEND_DOMINANT : PS1_XBR_BLEND_NORMAL) : PS1_XBR_BLEND_NONE;
    }

    // Pixel Tap Mapping: -|-|-|-|-
    //                    -|A|B|-|-
    //                    x|D|E|F|-
    //                    x|G|H|I|-
    //                    -|x|x|-|-
    if (!((ps1_xbr_eq(D, E) && ps1_xbr_eq(G, H)) || (ps1_xbr_eq(D, G) && ps1_xbr_eq(E, H)))) {
        float dist_G_E = ps1_xbr_dist_ycbcr(PS1_XBR_P(-2, 1), D) + ps1_xbr_dist_ycbcr(D, B) + ps1_xbr_dist_ycbcr(PS1_XBR_P(-1, 2), H) + ps1_xbr_dist_ycbcr(H, F) + (4.0 * ps1_xbr_dist_ycbcr(G, E));
        float dist_D_H = ps1_xbr_dist_ycbcr(PS1_XBR_P(-2, 0), G) + ps1_xbr_dist_ycbcr(G, PS1_XBR_P(0, 2)) + ps1_xbr_dist_ycbcr(A, E) + ps1_xbr_dist_ycbcr(E, I) + (4.0 * ps1_xbr_dist_ycbcr(D, H));
        bool dominantGradient = (PS1_XBR_DOMINANT_DIRECTION_THRESHOLD * dist_D_H) < dist_G_E;
        blendResult.w = ((dist_G_E > dist_D_H) && ps1_xbr_neq(E, D) && ps1_xbr_neq(E, H)) ? ((dominantGradient) ? PS1_XBR_BLEND_DOMINANT : PS1_XBR_BLEND_NORMAL) : PS1_XBR_BLEND_NONE;
    }

    // Pixel Tap Mapping: -|-|x|x|-
    //                    -|A|B|C|x
    //                    -|D|E|F|x
    //                    -|-|H|I|-
    //                    -|-|-|-|-
    if (!((ps1_xbr_eq(B, C) && ps1_xbr_eq(E, F)) || (ps1_xbr_eq(B, E) && ps1_xbr_eq(C, F)))) {
        float dist_E_C = ps1_xbr_dist_ycbcr(D, B) + ps1_xbr_dist_ycbcr(B, PS1_XBR_P(1, -2)) + ps1_xbr_dist_ycbcr(H, F) + ps1_xbr_dist_ycbcr(F, PS1_XBR_P(2, -1)) + (4.0 * ps1_xbr_dist_ycbcr(E, C));
        float dist_B_F = ps1_xbr_dist_ycbcr(A, E) + ps1_xbr_dist_ycbcr(E, I) + ps1_xbr_dist_ycbcr(PS1_XBR_P(0, -2), C) + ps1_xbr_dist_ycbcr(C, PS1_XBR_P(2, 0)) + (4.0 * ps1_xbr_dist_ycbcr(B, F));
        bool dominantGradient = (PS1_XBR_DOMINANT_DIRECTION_THRESHOLD * dist_B_F) < dist_E_C;
        blendResult.y = ((dist_E_C > dist_B_F) && ps1_xbr_neq(E, B) && ps1_xbr_neq(E, F)) ? ((dominantGradient) ? PS1_XBR_BLEND_DOMINANT : PS1_XBR_BLEND_NORMAL) : PS1_XBR_BLEND_NONE;
    }

    // Pixel Tap Mapping: -|x|x|-|-
    //                    x|A|B|C|-
    //                    x|D|E|F|-
    //                    -|G|H|-|-
    //                    -|-|-|-|-
    if (!((ps1_xbr_eq(A, B) && ps1_xbr_eq(D, E)) || (ps1_xbr_eq(A, D) && ps1_xbr_eq(B, E)))) {
        float dist_D_B = ps1_xbr_dist_ycbcr(PS1_XBR_P(-2, 0), A) + ps1_xbr_dist_ycbcr(A, PS1_XBR_P(0, -2)) + ps1_xbr_dist_ycbcr(G, E) + ps1_xbr_dist_ycbcr(E, C) + (4.0 * ps1_xbr_dist_ycbcr(D, B));
        float dist_A_E = ps1_xbr_dist_ycbcr(PS1_XBR_P(-2, -1), D) + ps1_xbr_dist_ycbcr(D, H) + ps1_xbr_dist_ycbcr(PS1_XBR_P(-1, -2), B) + ps1_xbr_dist_ycbcr(B, F) + (4.0 * ps1_xbr_dist_ycbcr(A, E));
        bool dominantGradient = (PS1_XBR_DOMINANT_DIRECTION_THRESHOLD * dist_D_B) < dist_A_E;
        blendResult.x = ((dist_D_B < dist_A_E) && ps1_xbr_neq(E, D) && ps1_xbr_neq(E, B)) ? ((dominantGradient) ? PS1_XBR_BLEND_DOMINANT : PS1_XBR_BLEND_NORMAL) : PS1_XBR_BLEND_NONE;
    }

    float4 res = E;
    float resW = Ew;

    // Pixel Tap Mapping: -|-|-|-|-
    //                    -|-|B|C|-
    //                    -|D|E|F|x
    //                    -|G|H|I|x
    //                    -|-|x|x|-
    if (blendResult.z != PS1_XBR_BLEND_NONE) {
        float dist_F_G = ps1_xbr_dist_ycbcr(F, G);
        float dist_H_C = ps1_xbr_dist_ycbcr(H, C);
        bool doLineBlend = (blendResult.z == PS1_XBR_BLEND_DOMINANT ||
                            !((blendResult.y != PS1_XBR_BLEND_NONE && !ps1_xbr_is_pix_equal(E, G)) || (blendResult.w != PS1_XBR_BLEND_NONE && !ps1_xbr_is_pix_equal(E, C)) ||
                              (ps1_xbr_is_pix_equal(G, H) && ps1_xbr_is_pix_equal(H, I) && ps1_xbr_is_pix_equal(I, F) && ps1_xbr_is_pix_equal(F, C) && !ps1_xbr_is_pix_equal(E, I))));

        float2 origin = float2(0.0, 1.0 / sqrt(2.0));
        float2 direction = float2(1.0, -1.0);
        if (doLineBlend) {
            bool haveShallowLine = (PS1_XBR_STEEP_DIRECTION_THRESHOLD * dist_F_G <= dist_H_C) && ps1_xbr_neq(E, G) && ps1_xbr_neq(D, G);
            bool haveSteepLine = (PS1_XBR_STEEP_DIRECTION_THRESHOLD * dist_H_C <= dist_F_G) && ps1_xbr_neq(E, C) && ps1_xbr_neq(B, C);
            origin = haveShallowLine ? float2(0.0, 0.25) : float2(0.0, 0.5);
            direction.x += haveShallowLine ? 1.0 : 0.0;
            direction.y -= haveSteepLine ? 1.0 : 0.0;
        }

        float4 blendPix = mix(H, F, step(ps1_xbr_dist_ycbcr(E, F), ps1_xbr_dist_ycbcr(E, H)));
        float blendW = mix(Hw, Fw, step(ps1_xbr_dist_ycbcr(E, F), ps1_xbr_dist_ycbcr(E, H)));
        res = mix(res, blendPix, ps1_xbr_get_left_ratio(pos, origin, direction, scale));
        resW = mix(resW, blendW, ps1_xbr_get_left_ratio(pos, origin, direction, scale));
    }

    // Pixel Tap Mapping: -|-|-|-|-
    //                    -|A|B|-|-
    //                    x|D|E|F|-
    //                    x|G|H|I|-
    //                    -|x|x|-|-
    if (blendResult.w != PS1_XBR_BLEND_NONE) {
        float dist_H_A = ps1_xbr_dist_ycbcr(H, A);
        float dist_D_I = ps1_xbr_dist_ycbcr(D, I);
        bool doLineBlend = (blendResult.w == PS1_XBR_BLEND_DOMINANT ||
                            !((blendResult.z != PS1_XBR_BLEND_NONE && !ps1_xbr_is_pix_equal(E, A)) || (blendResult.x != PS1_XBR_BLEND_NONE && !ps1_xbr_is_pix_equal(E, I)) ||
                              (ps1_xbr_is_pix_equal(A, D) && ps1_xbr_is_pix_equal(D, G) && ps1_xbr_is_pix_equal(G, H) && ps1_xbr_is_pix_equal(H, I) && !ps1_xbr_is_pix_equal(E, G))));

        float2 origin = float2(-1.0 / sqrt(2.0), 0.0);
        float2 direction = float2(1.0, 1.0);
        if (doLineBlend) {
            bool haveShallowLine = (PS1_XBR_STEEP_DIRECTION_THRESHOLD * dist_H_A <= dist_D_I) && ps1_xbr_neq(E, A) && ps1_xbr_neq(B, A);
            bool haveSteepLine = (PS1_XBR_STEEP_DIRECTION_THRESHOLD * dist_D_I <= dist_H_A) && ps1_xbr_neq(E, I) && ps1_xbr_neq(F, I);
            origin = haveShallowLine ? float2(-0.25, 0.0) : float2(-0.5, 0.0);
            direction.y += haveShallowLine ? 1.0 : 0.0;
            direction.x += haveSteepLine ? 1.0 : 0.0;
        }

        float4 blendPix = mix(H, D, step(ps1_xbr_dist_ycbcr(E, D), ps1_xbr_dist_ycbcr(E, H)));
        float blendW = mix(Hw, Dw, step(ps1_xbr_dist_ycbcr(E, D), ps1_xbr_dist_ycbcr(E, H)));
        res = mix(res, blendPix, ps1_xbr_get_left_ratio(pos, origin, direction, scale));
        resW = mix(resW, blendW, ps1_xbr_get_left_ratio(pos, origin, direction, scale));
    }

    // Pixel Tap Mapping: -|-|x|x|-
    //                    -|A|B|C|x
    //                    -|D|E|F|x
    //                    -|-|H|I|-
    //                    -|-|-|-|-
    if (blendResult.y != PS1_XBR_BLEND_NONE) {
        float dist_B_I = ps1_xbr_dist_ycbcr(B, I);
        float dist_F_A = ps1_xbr_dist_ycbcr(F, A);
        bool doLineBlend = (blendResult.y == PS1_XBR_BLEND_DOMINANT ||
                            !((blendResult.x != PS1_XBR_BLEND_NONE && !ps1_xbr_is_pix_equal(E, I)) || (blendResult.z != PS1_XBR_BLEND_NONE && !ps1_xbr_is_pix_equal(E, A)) ||
                              (ps1_xbr_is_pix_equal(I, F) && ps1_xbr_is_pix_equal(F, C) && ps1_xbr_is_pix_equal(C, B) && ps1_xbr_is_pix_equal(B, A) && !ps1_xbr_is_pix_equal(E, C))));

        float2 origin = float2(1.0 / sqrt(2.0), 0.0);
        float2 direction = float2(-1.0, -1.0);

        if (doLineBlend) {
            bool haveShallowLine = (PS1_XBR_STEEP_DIRECTION_THRESHOLD * dist_B_I <= dist_F_A) && ps1_xbr_neq(E, I) && ps1_xbr_neq(H, I);
            bool haveSteepLine = (PS1_XBR_STEEP_DIRECTION_THRESHOLD * dist_F_A <= dist_B_I) && ps1_xbr_neq(E, A) && ps1_xbr_neq(D, A);
            origin = haveShallowLine ? float2(0.25, 0.0) : float2(0.5, 0.0);
            direction.y -= haveShallowLine ? 1.0 : 0.0;
            direction.x -= haveSteepLine ? 1.0 : 0.0;
        }

        float4 blendPix = mix(F, B, step(ps1_xbr_dist_ycbcr(E, B), ps1_xbr_dist_ycbcr(E, F)));
        float blendW = mix(Fw, Bw, step(ps1_xbr_dist_ycbcr(E, B), ps1_xbr_dist_ycbcr(E, F)));
        res = mix(res, blendPix, ps1_xbr_get_left_ratio(pos, origin, direction, scale));
        resW = mix(resW, blendW, ps1_xbr_get_left_ratio(pos, origin, direction, scale));
    }

    // Pixel Tap Mapping: -|x|x|-|-
    //                    x|A|B|C|-
    //                    x|D|E|F|-
    //                    -|G|H|-|-
    //                    -|-|-|-|-
    if (blendResult.x != PS1_XBR_BLEND_NONE) {
        float dist_D_C = ps1_xbr_dist_ycbcr(D, C);
        float dist_B_G = ps1_xbr_dist_ycbcr(B, G);
        bool doLineBlend = (blendResult.x == PS1_XBR_BLEND_DOMINANT ||
                            !((blendResult.w != PS1_XBR_BLEND_NONE && !ps1_xbr_is_pix_equal(E, C)) || (blendResult.y != PS1_XBR_BLEND_NONE && !ps1_xbr_is_pix_equal(E, G)) ||
                              (ps1_xbr_is_pix_equal(C, B) && ps1_xbr_is_pix_equal(B, A) && ps1_xbr_is_pix_equal(A, D) && ps1_xbr_is_pix_equal(D, G) && !ps1_xbr_is_pix_equal(E, A))));

        float2 origin = float2(0.0, -1.0 / sqrt(2.0));
        float2 direction = float2(-1.0, 1.0);
        if (doLineBlend) {
            bool haveShallowLine = (PS1_XBR_STEEP_DIRECTION_THRESHOLD * dist_D_C <= dist_B_G) && ps1_xbr_neq(E, C) && ps1_xbr_neq(F, C);
            bool haveSteepLine = (PS1_XBR_STEEP_DIRECTION_THRESHOLD * dist_B_G <= dist_D_C) && ps1_xbr_neq(E, G) && ps1_xbr_neq(H, G);
            origin = haveShallowLine ? float2(0.0, -0.25) : float2(0.0, -0.5);
            direction.x -= haveShallowLine ? 1.0 : 0.0;
            direction.y += haveSteepLine ? 1.0 : 0.0;
        }

        float4 blendPix = mix(D, B, step(ps1_xbr_dist_ycbcr(E, B), ps1_xbr_dist_ycbcr(E, D)));
        float blendW = mix(Dw, Bw, step(ps1_xbr_dist_ycbcr(E, B), ps1_xbr_dist_ycbcr(E, D)));
        res = mix(res, blendPix, ps1_xbr_get_left_ratio(pos, origin, direction, scale));
        resW = mix(resW, blendW, ps1_xbr_get_left_ratio(pos, origin, direction, scale));
    }

    float ialpha = res.w;
    float4 texcol = float4(res.xyz, resW);

    // Compensate for partially transparent sampling.
    if (ialpha > 0.0)
        texcol.rgb /= float3(ialpha, ialpha, ialpha);

    if (!blend_edges)
        ialpha = (ialpha >= 0.5) ? 1.0 : 0.0;

    return ps1_filtered_of(texcol, ialpha);
}

#undef PS1_XBR_P

#endif /* PS1_FILTER_XBR_H */
