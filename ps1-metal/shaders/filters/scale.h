#ifndef PS1_FILTER_SCALE_H
#define PS1_FILTER_SCALE_H

inline Ps1Filtered ps1_filter_scale2x(thread const Ps1TexSrc& src, float2 coords) {
    return ps1_filter_nearest(src, coords);
}

inline Ps1Filtered ps1_filter_scale3x(thread const Ps1TexSrc& src, float2 coords) {
    return ps1_filter_nearest(src, coords);
}

#endif /* PS1_FILTER_SCALE_H */
