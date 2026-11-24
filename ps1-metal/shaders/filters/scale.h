/* Scale2x and Scale3x, after https://www.scale2x.it/algorithm */
#ifndef PS1_FILTER_SCALE_H
#define PS1_FILTER_SCALE_H

/// The raw texel at (`b` + (dx, dy)); a hole is 0, so equality on it is
/// equality on the reference's packed colour.
inline ushort ps1_scale_at(thread const Ps1TexSrc& src, int2 b, int dx, int dy) {
    return ps1_src_raw(src, b.x + dx, b.y + dy);
}

/// The filter's answer for the chosen raw texel: its normalised colour, and
/// a hole covering nothing.
inline Ps1Filtered ps1_scale_result(ushort res) {
    float4 texcol = float4(0.0);
    if (res != 0) {
        texcol = float4(float3(float(res & 0x1F), float((res >> 5) & 0x1F), float((res >> 10) & 0x1F)) / 31.0,
                        (res & 0x8000) != 0 ? 1.0 : 0.0);
    }
    return ps1_filtered_of(texcol, res != 0 ? 1.0 : 0.0);
}

inline Ps1Filtered ps1_filter_scale2x(thread const Ps1TexSrc& src, float2 coords) {
    int2 bcoords = int2(floor(coords));

    ushort E = ps1_scale_at(src, bcoords, +0, +0);
    ushort B = ps1_scale_at(src, bcoords, +0, -1);
    ushort D = ps1_scale_at(src, bcoords, -1, +0);
    ushort F = ps1_scale_at(src, bcoords, +1, +0);
    ushort H = ps1_scale_at(src, bcoords, +0, +1);

    ushort J = (D == B && B != F && D != H) ? D : E;
    ushort K = (B == F && D != F && H != F) ? F : E;
    ushort L = (H == D && F != D && B != D) ? D : E;
    ushort M = (H == F && D != H && B != F) ? F : E;

    // select quadrant based on fractional part of texture coordinates
    float2 fpart = fract(coords);
    ushort res = (fpart.x < 0.5f) ? ((fpart.y < 0.5f) ? J : L) : ((fpart.y < 0.5f) ? K : M);

    return ps1_scale_result(res);
}

inline Ps1Filtered ps1_filter_scale3x(thread const Ps1TexSrc& src, float2 coords) {
    int2 bcoords = int2(floor(coords));

    ushort E = ps1_scale_at(src, bcoords, +0, +0);
    ushort B = ps1_scale_at(src, bcoords, +0, -1);
    ushort D = ps1_scale_at(src, bcoords, -1, +0);
    ushort F = ps1_scale_at(src, bcoords, +1, +0);
    ushort H = ps1_scale_at(src, bcoords, +0, +1);

    ushort res = E;
    if (B != H && D != F) {
        ushort A = ps1_scale_at(src, bcoords, -1, -1);
        ushort C = ps1_scale_at(src, bcoords, +1, -1);
        ushort G = ps1_scale_at(src, bcoords, -1, +1);
        ushort I = ps1_scale_at(src, bcoords, +1, +1);

        ushort E0 = (D == B) ? D : E;
        ushort E1 = ((D == B && E != C) || (B == F && E != A)) ? B : E;
        ushort E2 = (B == F) ? F : E;
        ushort E3 = ((D == B && E != G) || (D == H && E != A)) ? D : E;
        ushort E4 = E;
        ushort E5 = ((B == F && E != I) || (H == F && E != C)) ? F : E;
        ushort E6 = (D == H) ? D : E;
        ushort E7 = ((D == H && E != I) || (H == F && E != G)) ? H : E;
        ushort E8 = (H == F) ? F : E;

        // select quadrant based on fractional part of texture coordinates
        float2 fpart = fract(coords);
        ushort R0, R1, R2;
        if (fpart.y < 0.34f) {
            R0 = E0;
            R1 = E1;
            R2 = E2;
        } else if (fpart.y < 0.67f) {
            R0 = E3;
            R1 = E4;
            R2 = E5;
        } else {
            R0 = E6;
            R1 = E7;
            R2 = E8;
        }

        res = (fpart.x < 0.34f) ? R0 : ((fpart.x < 0.67f) ? R1 : R2);
    }

    return ps1_scale_result(res);
}

#endif /* PS1_FILTER_SCALE_H */
