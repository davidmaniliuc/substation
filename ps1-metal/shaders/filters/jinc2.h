/*
   Hyllian's jinc windowed-jinc 2-lobe sharper with anti-ringing Shader

   Copyright (C) 2011-2016 Hyllian/Jararaca - sergiogdb@gmail.com

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
#ifndef PS1_FILTER_JINC2_H
#define PS1_FILTER_JINC2_H

constant float PS1_JINC2_AR_STRENGTH = 0.8;

constant float ps1_jinc2_wa = 1.382300768;
constant float ps1_jinc2_wb = 2.576105976;

/// Distance between two points.
inline float ps1_jinc2_d(float2 pt1, float2 pt2) {
    float2 v = pt2 - pt1;
    return sqrt(dot(v, v));
}

inline float4 ps1_jinc2_resampler(float4 x) {
    float4 a = sin(x * ps1_jinc2_wa) * sin(x * ps1_jinc2_wb) / (x * x);
    float4 b = float4(ps1_jinc2_wa * ps1_jinc2_wb);
    bool4 s = (x == float4(0.0));
    return float4(s.x ? b.x : a.x, s.y ? b.y : a.y, s.z ? b.z : a.z, s.w ? b.w : a.w);
}

/// Filters the sixteen texels around `coords`. `blend_edges` keeps the
/// coverage as it is; without it, coverage snaps to 0 or 1 at one half.
inline Ps1Filtered ps1_filter_jinc2(thread const Ps1TexSrc& src, float2 coords, bool blend_edges) {
    float4 weights[4];

    float2 dx = float2(1.0, 0.0);
    float2 dy = float2(0.0, 1.0);

    float2 pc = coords.xy;

    float2 tc = (floor(pc - float2(0.5, 0.5)) + float2(0.5, 0.5));

    weights[0] = ps1_jinc2_resampler(float4(ps1_jinc2_d(pc, tc - dx - dy), ps1_jinc2_d(pc, tc - dy), ps1_jinc2_d(pc, tc + dx - dy), ps1_jinc2_d(pc, tc + 2.0 * dx - dy)));
    weights[1] = ps1_jinc2_resampler(float4(ps1_jinc2_d(pc, tc - dx), ps1_jinc2_d(pc, tc), ps1_jinc2_d(pc, tc + dx), ps1_jinc2_d(pc, tc + 2.0 * dx)));
    weights[2] = ps1_jinc2_resampler(float4(ps1_jinc2_d(pc, tc - dx + dy), ps1_jinc2_d(pc, tc + dy), ps1_jinc2_d(pc, tc + dx + dy), ps1_jinc2_d(pc, tc + 2.0 * dx + dy)));
    weights[3] = ps1_jinc2_resampler(float4(ps1_jinc2_d(pc, tc - dx + 2.0 * dy), ps1_jinc2_d(pc, tc + 2.0 * dy), ps1_jinc2_d(pc, tc + dx + 2.0 * dy), ps1_jinc2_d(pc, tc + 2.0 * dx + 2.0 * dy)));

#define sample_texel(coords) ps1_src_rgba(src, (coords))

    float4 c00 = sample_texel(tc - dx - dy);
    float a00 = float(any(c00 != float4(0.0)));
    float4 c10 = sample_texel(tc - dy);
    float a10 = float(any(c10 != float4(0.0)));
    float4 c20 = sample_texel(tc + dx - dy);
    float a20 = float(any(c20 != float4(0.0)));
    float4 c30 = sample_texel(tc + 2.0 * dx - dy);
    float a30 = float(any(c30 != float4(0.0)));
    float4 c01 = sample_texel(tc - dx);
    float a01 = float(any(c01 != float4(0.0)));
    float4 c11 = sample_texel(tc);
    float a11 = float(any(c11 != float4(0.0)));
    float4 c21 = sample_texel(tc + dx);
    float a21 = float(any(c21 != float4(0.0)));
    float4 c31 = sample_texel(tc + 2.0 * dx);
    float a31 = float(any(c31 != float4(0.0)));
    float4 c02 = sample_texel(tc - dx + dy);
    float a02 = float(any(c02 != float4(0.0)));
    float4 c12 = sample_texel(tc + dy);
    float a12 = float(any(c12 != float4(0.0)));
    float4 c22 = sample_texel(tc + dx + dy);
    float a22 = float(any(c22 != float4(0.0)));
    float4 c32 = sample_texel(tc + 2.0 * dx + dy);
    float a32 = float(any(c32 != float4(0.0)));
    float4 c03 = sample_texel(tc - dx + 2.0 * dy);
    float a03 = float(any(c03 != float4(0.0)));
    float4 c13 = sample_texel(tc + 2.0 * dy);
    float a13 = float(any(c13 != float4(0.0)));
    float4 c23 = sample_texel(tc + dx + 2.0 * dy);
    float a23 = float(any(c23 != float4(0.0)));
    float4 c33 = sample_texel(tc + 2.0 * dx + 2.0 * dy);
    float a33 = float(any(c33 != float4(0.0)));

#undef sample_texel

    //  Get min/max samples
    float4 min_sample = min(c11, min(c21, min(c12, c22)));
    float min_sample_alpha = min(a11, min(a21, min(a12, a22)));
    float4 max_sample = max(c11, max(c21, max(c12, c22)));
    float max_sample_alpha = max(a11, max(a21, max(a12, a22)));

    float4 color;
    color = float4(dot(weights[0], float4(c00.x, c10.x, c20.x, c30.x)), dot(weights[0], float4(c00.y, c10.y, c20.y, c30.y)), dot(weights[0], float4(c00.z, c10.z, c20.z, c30.z)), dot(weights[0], float4(c00.w, c10.w, c20.w, c30.w)));
    color += float4(dot(weights[1], float4(c01.x, c11.x, c21.x, c31.x)), dot(weights[1], float4(c01.y, c11.y, c21.y, c31.y)), dot(weights[1], float4(c01.z, c11.z, c21.z, c31.z)), dot(weights[1], float4(c01.w, c11.w, c21.w, c31.w)));
    color += float4(dot(weights[2], float4(c02.x, c12.x, c22.x, c32.x)), dot(weights[2], float4(c02.y, c12.y, c22.y, c32.y)), dot(weights[2], float4(c02.z, c12.z, c22.z, c32.z)), dot(weights[2], float4(c02.w, c12.w, c22.w, c32.w)));
    color += float4(dot(weights[3], float4(c03.x, c13.x, c23.x, c33.x)), dot(weights[3], float4(c03.y, c13.y, c23.y, c33.y)), dot(weights[3], float4(c03.z, c13.z, c23.z, c33.z)), dot(weights[3], float4(c03.w, c13.w, c23.w, c33.w)));
    color = color / (dot(weights[0], float4(1, 1, 1, 1)) + dot(weights[1], float4(1, 1, 1, 1)) + dot(weights[2], float4(1, 1, 1, 1)) + dot(weights[3], float4(1, 1, 1, 1)));

    float alpha;
    alpha = dot(weights[0], float4(a00, a10, a20, a30));
    alpha += dot(weights[1], float4(a01, a11, a21, a31));
    alpha += dot(weights[2], float4(a02, a12, a22, a32));
    alpha += dot(weights[3], float4(a03, a13, a23, a33));
    alpha = alpha / (dot(weights[0], float4(1, 1, 1, 1)) + dot(weights[1], float4(1, 1, 1, 1)) + dot(weights[2], float4(1, 1, 1, 1)) + dot(weights[3], float4(1, 1, 1, 1)));

    // Anti-ringing
    float4 aux = color;
    float aux_alpha = alpha;
    color = clamp(color, min_sample, max_sample);
    alpha = clamp(alpha, min_sample_alpha, max_sample_alpha);
    color = mix(aux, color, PS1_JINC2_AR_STRENGTH);
    alpha = mix(aux_alpha, alpha, PS1_JINC2_AR_STRENGTH);

    // final sum and weight normalization
    float ialpha = alpha;
    float4 texcol = color;

    // Compensate for partially transparent sampling.
    if (ialpha > 0.0)
        texcol.rgb /= float3(ialpha, ialpha, ialpha);

    if (!blend_edges)
        ialpha = (ialpha >= 0.5) ? 1.0 : 0.0;

    return ps1_filtered_of(texcol, ialpha);
}

#endif /* PS1_FILTER_JINC2_H */
