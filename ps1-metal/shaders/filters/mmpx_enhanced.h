#ifndef PS1_FILTER_MMPX_ENHANCED_H
#define PS1_FILTER_MMPX_ENHANCED_H

/* MMPX Enhanced
 * An optimized refinement of the original MMPX shader that addresses key
 * visual artifacts while fully preserving the baseline's signature performance and efficiency.
 *
 * License: MIT
 * (C) 2025-2026 by crashGG.
 */

/// The texel at `b` + (dx, dy) as colour, all zero outside the UV limits: a
/// neighbour past a sprite's edge reads as transparent, not as the clamped
/// edge texel.
inline float4 ps1_mmpxe_srcf(thread const Ps1TexSrc& src, int2 b, int dx, int dy) {
    int u = b.x + dx, v = b.y + dy;
    return ps1_src_inside(src, u, v) ? ps1_src_rgba(src, u, v) : float4(0.0);
}

/// The same texel as its raw value, for equality: 0 for a hole or outside the
/// limits.
inline uint ps1_mmpxe_src(thread const Ps1TexSrc& src, int2 b, int dx, int dy) {
    int u = b.x + dx, v = b.y + dy;
    return ps1_src_inside(src, u, v) ? uint(ps1_src_raw(src, u, v)) : 0u;
}

inline float ps1_mmpxe_luma(float4 col) {
    // CRT-era BT.601 standard.
    return dot(col.rgb, float3(0.299, 0.587, 0.114));
}

inline float ps1_mmpxe_mix_gate(float4 col1, float4 col2) {
    float4 diff = col1 - col2;
    float delta_range = max(diff.r, max(diff.g, diff.b)) - min(diff.r, min(diff.g, diff.b));
    float dot_diff = dot(diff, diff);
    float factor = (delta_range * delta_range) * 2.618034;
    return step(dot_diff, mix(0.75, 0.0, factor));
}

inline bool ps1_mmpxe_all_eq2(uint a, uint b1, uint b2) {
    return a == b1 && a == b2;
}
inline bool ps1_mmpxe_all_eq4(uint a, uint b1, uint b2, uint b3, uint b4) {
    return a == b1 && a == b2 && a == b3 && a == b4;
}
inline bool ps1_mmpxe_any_eq2(uint a, uint b1, uint b2) {
    return a == b1 || a == b2;
}
inline bool ps1_mmpxe_none_eq4(uint a, uint b1, uint b2, uint b3, uint b4) {
    return a != b1 && a != b2 && a != b3 && a != b4;
}

inline float4 ps1_mmpxe_admix_c(float4 vX, float4 vE) {
    float mix_factor = ps1_mmpxe_mix_gate(vX, vE) * (-0.381966) + 1.0;
    return mix(vX, vE, mix_factor);
}

inline float4 ps1_mmpxe_admix_k(float4 vX, float4 vE) {
    float4 diff = vX - vE;
    float mix_factor = dot(diff.rgb, diff.rgb) * 0.16666 + 0.5;
    return mix(vX, vE, mix_factor);
}

inline Ps1Filtered ps1_filter_mmpx_enhanced(thread const Ps1TexSrc& src, float2 coords) {
    int2 bcoords = int2(floor(coords));

    float4 vE = ps1_src_rgba(src, bcoords.x, bcoords.y);

    float4 vB = ps1_mmpxe_srcf(src, bcoords, 0, -1);
    float4 vD = ps1_mmpxe_srcf(src, bcoords, -1, 0);
    float4 vF = ps1_mmpxe_srcf(src, bcoords, +1, 0);
    float4 vH = ps1_mmpxe_srcf(src, bcoords, 0, +1);

    uint E = uint(ps1_src_raw(src, bcoords.x, bcoords.y));
    uint B = ps1_mmpxe_src(src, bcoords, 0, -1);
    uint D = ps1_mmpxe_src(src, bcoords, -1, 0);
    uint F = ps1_mmpxe_src(src, bcoords, +1, 0);
    uint H = ps1_mmpxe_src(src, bcoords, 0, +1);

    // default pixel
    float ialpha = float(E != 0u);
    float4 texcol = vE;

    bool skiprest = (E == D && E == F) || (E == B && E == H) || (B == H && D == F);
    if (!skiprest) {

        // 5x5
        uint A = ps1_mmpxe_src(src, bcoords, -1, -1);
        uint C = ps1_mmpxe_src(src, bcoords, +1, -1);
        uint G = ps1_mmpxe_src(src, bcoords, -1, +1);
        uint I = ps1_mmpxe_src(src, bcoords, +1, +1);

        uint P  = ps1_mmpxe_src(src, bcoords, 0, -2);
        uint Q  = ps1_mmpxe_src(src, bcoords, -2, 0);
        uint R  = ps1_mmpxe_src(src, bcoords, +2, 0);
        uint S  = ps1_mmpxe_src(src, bcoords, 0, +2);

        uint PA = ps1_mmpxe_src(src, bcoords, -1, -2);
        uint PC = ps1_mmpxe_src(src, bcoords, +1, -2);
        uint QA = ps1_mmpxe_src(src, bcoords, -2, -1);
        uint QG = ps1_mmpxe_src(src, bcoords, -2, +1);
        uint RC = ps1_mmpxe_src(src, bcoords, +2, -1);
        uint RI = ps1_mmpxe_src(src, bcoords, +2, +1);
        uint SG = ps1_mmpxe_src(src, bcoords, -1, +2);
        uint SI = ps1_mmpxe_src(src, bcoords, +1, +2);

        float4 J = vE;  float4 K = vE;  float4 L = vE;  float4 M = vE;

        float Bl = ps1_mmpxe_luma(vB) + float(B == 0u) * 2.0;
        float Dl = ps1_mmpxe_luma(vD) + float(D == 0u) * 2.0;
        float El = ps1_mmpxe_luma(vE) + float(E == 0u) * 2.0;
        float Fl = ps1_mmpxe_luma(vF) + float(F == 0u) * 2.0;
        float Hl = ps1_mmpxe_luma(vH) + float(H == 0u) * 2.0;

        bool slope1 = false;  bool slope2 = false;  bool slope3 = false;  bool slope4 = false;

        // B - D
        if (E != B && (D == B && D != H && D != F) && (El >= Dl || E == A && B != PA && D != QA) && ps1_mmpxe_any_eq2(E, C, G) && ((El < Dl) || A != D || E != P || E != Q)) {
            J = vB;
            slope1 = true;
        }

        // B - F
        if (E != B && (B == F && B != D && B != H) && (El >= Bl || E == C && B != PC && F != RC) && ps1_mmpxe_any_eq2(E, A, I) && ((El < Bl) || C != B || E != P || E != R)) {
            K = vB;
            slope2 = true;
        }

        // D - H
        if (E != H && (H == D && H != F && H != B) && (El >= Hl || E == G && D != QG && H != SG) && ps1_mmpxe_any_eq2(E, A, I) && ((El < Hl) || G != H || E != S || E != Q)) {
            L = vH;
            slope3 = true;
        }

        // F - H
        if (E != H && (F == H && F != B && F != D) && (El >= Fl || E == I && F != RI && H != SI) && ps1_mmpxe_any_eq2(E, C, G) && ((El < Fl) || I != H || E != R || E != S)) {
            M = vH;
            slope4 = true;
        }

        // long gentle 2:1 slope

        if (slope4) { // zone4 long slope
            if (ps1_mmpxe_all_eq2(R, F, G) && R != RC && Q != G) L = M;
            // vertical
            if (ps1_mmpxe_all_eq2(S, H, C) && S != SG && P != C) K = M;
        }

        if (slope3) { // zone3 long slope
            // horizontal
            if (ps1_mmpxe_all_eq2(Q, D, I) && Q != QA && R != I) M = L;
            // vertical
            if (ps1_mmpxe_all_eq2(S, H, A) && S != SI && A != P) J = L;
        }

        if (slope2) { // zone2 long slope
            // horizontal
            if (ps1_mmpxe_all_eq2(R, F, A) && R != RI && A != Q) J = K;
            // vertical
            if (ps1_mmpxe_all_eq2(P, B, I) && P != PA && I != S) M = K;
        }

        if (slope1) { // zone1 long slope
            // horizontal
            if (ps1_mmpxe_all_eq2(Q, D, C) && Q != QG && C != R) K = J;
            // vertical
            if (ps1_mmpxe_all_eq2(P, B, G) && P != PC && G != S) L = J;
        }

        skiprest = skiprest || slope1 || slope2 || slope3 || slope4 || E == 0u || B == 0u || D == 0u || F == 0u || H == 0u;

        /* Concave + Cross type */

        if (!skiprest && Bl < El && ps1_mmpxe_all_eq4(E, G, H, I, S) && ps1_mmpxe_none_eq4(E, A, D, C, F)) { J = ps1_mmpxe_admix_c(vB, J);  K = J;  skiprest = true; }
        if (!skiprest && Hl < El && ps1_mmpxe_all_eq4(E, A, B, C, P) && ps1_mmpxe_none_eq4(E, D, G, I, F)) { L = ps1_mmpxe_admix_c(vH, L);  M = L;  skiprest = true; }
        if (!skiprest && Fl < El && ps1_mmpxe_all_eq4(E, A, D, G, Q) && ps1_mmpxe_none_eq4(E, B, C, I, H)) { K = ps1_mmpxe_admix_c(vF, K);  M = K;  skiprest = true; }
        if (!skiprest && Dl < El && ps1_mmpxe_all_eq4(E, C, F, I, R) && ps1_mmpxe_none_eq4(E, B, A, G, H)) { J = ps1_mmpxe_admix_c(vD, J);  L = J;  skiprest = true; }

        /* K type */

        if (!skiprest && (E != F && ps1_mmpxe_all_eq4(E, C, I, D, Q) && ps1_mmpxe_all_eq2(F, B, H)) && (F != ps1_mmpxe_src(src, bcoords, +3, +0))) { K = ps1_mmpxe_admix_k(vF, K);  M = K;  skiprest = true; }  // RIGHT
        if (!skiprest && (E != D && ps1_mmpxe_all_eq4(E, A, G, F, R) && ps1_mmpxe_all_eq2(D, B, H)) && (D != ps1_mmpxe_src(src, bcoords, -3, +0))) { J = ps1_mmpxe_admix_k(vD, J);  L = J;  skiprest = true; }  // LEFT
        if (!skiprest && (E != H && ps1_mmpxe_all_eq4(E, G, I, B, P) && ps1_mmpxe_all_eq2(H, D, F)) && (H != ps1_mmpxe_src(src, bcoords, +0, +3))) { L = ps1_mmpxe_admix_k(vH, L);  M = L;  skiprest = true; }  // BOTTOM
        if (!skiprest && (E != B && ps1_mmpxe_all_eq4(E, A, C, H, S) && ps1_mmpxe_all_eq2(B, D, F)) && (B != ps1_mmpxe_src(src, bcoords, +0, -3))) { J = ps1_mmpxe_admix_k(vB, J);  K = J; }  // TOP

        // final write
        float2 fpart = fract(coords);

        float4 res = (fpart.x < 0.5) ? ((fpart.y < 0.5) ? J : L) : ((fpart.y < 0.5) ? K : M);

        ialpha = step(0.002, res.r + res.g + res.b + res.a);
        texcol = res;
    }

    return ps1_filtered_of(texcol, ialpha);
}

#endif /* PS1_FILTER_MMPX_ENHANCED_H */
