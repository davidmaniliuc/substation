#ifndef PS1_FILTER_MMPX_H
#define PS1_FILTER_MMPX_H

/* MMPX, ported from MMPX.glc at
   https://casual-effects.com/research/McGuire2021PixelArt/index.html
   Copyright 2020 Morgan McGuire & Mara Gagiu.
   Provided under the Open Source MIT license https://opensource.org/licenses/MIT

   Texels are compared as packed RGBA8 words, as the original does: a hole is
   0, and the luma tie-breaks read the packed channels. MMPX only ever shows
   one of the nine texels it reads, so there is no blend and no coverage but
   all or nothing. */

inline uint ps1_mmpx_luma(uint C) {
    uint alpha = (C & 0xFF000000u) >> 24;
    return (((C & 0x00FF0000u) >> 16) + ((C & 0x0000FF00u) >> 8) + (C & 0x000000FFu) + 1u) * (256u - alpha);
}

inline bool ps1_mmpx_all_eq2(uint B, uint A0, uint A1) {
    return ((B ^ A0) | (B ^ A1)) == 0u;
}

inline bool ps1_mmpx_all_eq3(uint B, uint A0, uint A1, uint A2) {
    return ((B ^ A0) | (B ^ A1) | (B ^ A2)) == 0u;
}

inline bool ps1_mmpx_all_eq4(uint B, uint A0, uint A1, uint A2, uint A3) {
    return ((B ^ A0) | (B ^ A1) | (B ^ A2) | (B ^ A3)) == 0u;
}

inline bool ps1_mmpx_any_eq3(uint B, uint A0, uint A1, uint A2) {
    return B == A0 || B == A1 || B == A2;
}

inline bool ps1_mmpx_none_eq2(uint B, uint A0, uint A1) {
    return (B != A0) && (B != A1);
}

inline bool ps1_mmpx_none_eq4(uint B, uint A0, uint A1, uint A2, uint A3) {
    return B != A0 && B != A1 && B != A2 && B != A3;
}

inline Ps1Filtered ps1_filter_mmpx(thread const Ps1TexSrc& src, float2 coords) {
    int2 bcoords = int2(floor(coords));

#define ps1_mmpx_at(xoffs, yoffs) \
    pack_float_to_unorm4x8(ps1_src_rgba(src, bcoords.x + (xoffs), bcoords.y + (yoffs)))

    uint A = ps1_mmpx_at(-1, -1), B = ps1_mmpx_at(+0, -1), C = ps1_mmpx_at(+1, -1);
    uint D = ps1_mmpx_at(-1, +0), E = ps1_mmpx_at(+0, +0), F = ps1_mmpx_at(+1, +0);
    uint G = ps1_mmpx_at(-1, +1), H = ps1_mmpx_at(+0, +1), I = ps1_mmpx_at(+1, +1);

    uint J = E, K = E, L = E, M = E;

    if (((A ^ E) | (B ^ E) | (C ^ E) | (D ^ E) | (F ^ E) | (G ^ E) | (H ^ E) | (I ^ E)) != 0u) {
        uint P = ps1_mmpx_at(+0, -2), S = ps1_mmpx_at(+0, +2);
        uint Q = ps1_mmpx_at(-2, +0), R = ps1_mmpx_at(+2, +0);
        uint Bl = ps1_mmpx_luma(B), Dl = ps1_mmpx_luma(D), El = ps1_mmpx_luma(E), Fl = ps1_mmpx_luma(F), Hl = ps1_mmpx_luma(H);

        // 1:1 slope rules
        if ((D == B && D != H && D != F) && (El >= Dl || E == A) && ps1_mmpx_any_eq3(E, A, C, G) && ((El < Dl) || A != D || E != P || E != Q)) J = D;
        if ((B == F && B != D && B != H) && (El >= Bl || E == C) && ps1_mmpx_any_eq3(E, A, C, I) && ((El < Bl) || C != B || E != P || E != R)) K = B;
        if ((H == D && H != F && H != B) && (El >= Hl || E == G) && ps1_mmpx_any_eq3(E, A, G, I) && ((El < Hl) || G != H || E != S || E != Q)) L = H;
        if ((F == H && F != B && F != D) && (El >= Fl || E == I) && ps1_mmpx_any_eq3(E, C, G, I) && ((El < Fl) || I != H || E != R || E != S)) M = F;

        // Intersection rules
        if ((E != F && ps1_mmpx_all_eq4(E, C, I, D, Q) && ps1_mmpx_all_eq2(F, B, H)) && (F != ps1_mmpx_at(+3, +0))) K = M = F;
        if ((E != D && ps1_mmpx_all_eq4(E, A, G, F, R) && ps1_mmpx_all_eq2(D, B, H)) && (D != ps1_mmpx_at(-3, +0))) J = L = D;
        if ((E != H && ps1_mmpx_all_eq4(E, G, I, B, P) && ps1_mmpx_all_eq2(H, D, F)) && (H != ps1_mmpx_at(+0, +3))) L = M = H;
        if ((E != B && ps1_mmpx_all_eq4(E, A, C, H, S) && ps1_mmpx_all_eq2(B, D, F)) && (B != ps1_mmpx_at(+0, -3))) J = K = B;
        if (Bl < El && ps1_mmpx_all_eq4(E, G, H, I, S) && ps1_mmpx_none_eq4(E, A, D, C, F)) J = K = B;
        if (Hl < El && ps1_mmpx_all_eq4(E, A, B, C, P) && ps1_mmpx_none_eq4(E, D, G, I, F)) L = M = H;
        if (Fl < El && ps1_mmpx_all_eq4(E, A, D, G, Q) && ps1_mmpx_none_eq4(E, B, C, I, H)) K = M = F;
        if (Dl < El && ps1_mmpx_all_eq4(E, C, F, I, R) && ps1_mmpx_none_eq4(E, B, A, G, H)) J = L = D;

        // 2:1 slope rules
        if (H != B) {
            if (H != A && H != E && H != C) {
                if (ps1_mmpx_all_eq3(H, G, F, R) && ps1_mmpx_none_eq2(H, D, ps1_mmpx_at(+2, -1))) L = M;
                if (ps1_mmpx_all_eq3(H, I, D, Q) && ps1_mmpx_none_eq2(H, F, ps1_mmpx_at(-2, -1))) M = L;
            }

            if (B != I && B != G && B != E) {
                if (ps1_mmpx_all_eq3(B, A, F, R) && ps1_mmpx_none_eq2(B, D, ps1_mmpx_at(+2, +1))) J = K;
                if (ps1_mmpx_all_eq3(B, C, D, Q) && ps1_mmpx_none_eq2(B, F, ps1_mmpx_at(-2, +1))) K = J;
            }
        } // H !== B

        if (F != D) {
            if (D != I && D != E && D != C) {
                if (ps1_mmpx_all_eq3(D, A, H, S) && ps1_mmpx_none_eq2(D, B, ps1_mmpx_at(+1, +2))) J = L;
                if (ps1_mmpx_all_eq3(D, G, B, P) && ps1_mmpx_none_eq2(D, H, ps1_mmpx_at(+1, -2))) L = J;
            }

            if (F != E && F != A && F != G) {
                if (ps1_mmpx_all_eq3(F, C, H, S) && ps1_mmpx_none_eq2(F, B, ps1_mmpx_at(-1, +2))) K = M;
                if (ps1_mmpx_all_eq3(F, I, B, P) && ps1_mmpx_none_eq2(F, H, ps1_mmpx_at(-1, -2))) M = K;
            }
        } // F !== D
    } // not constant

#undef ps1_mmpx_at

    // select quadrant based on fractional part of texture coordinates
    float2 fpart = fract(coords);
    uint res = (fpart.x < 0.5f) ? ((fpart.y < 0.5f) ? J : L) : ((fpart.y < 0.5f) ? K : M);

    return ps1_filtered_of(unpack_unorm4x8_to_float(res), float(res != 0u));
}

#endif /* PS1_FILTER_MMPX_H */
