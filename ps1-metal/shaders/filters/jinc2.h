#ifndef PS1_FILTER_JINC2_H
#define PS1_FILTER_JINC2_H

inline Ps1Filtered ps1_filter_jinc2(thread const Ps1TexSrc& src, float2 coords, bool blend_edges) {
    return ps1_filter_nearest(src, coords);
}

#endif /* PS1_FILTER_JINC2_H */
