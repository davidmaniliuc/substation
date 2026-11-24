#ifndef PS1_FILTER_MMPX_ADVANCED_H
#define PS1_FILTER_MMPX_ADVANCED_H

inline Ps1Filtered ps1_filter_mmpx_advanced(thread const Ps1TexSrc& src, float2 coords) {
    return ps1_filter_nearest(src, coords);
}

#endif /* PS1_FILTER_MMPX_ADVANCED_H */
