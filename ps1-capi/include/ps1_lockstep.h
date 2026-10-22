/* ps1_lockstep.h — TEMPORARY (Plan C Task 8 deletes it).
 *
 * Replays a .p1fx fixture through the Zig Metal renderer so the Swift suite
 * can require it byte-identical to the Swift one before that is deleted.
 * Error codes are ps1.h's.
 */
#ifndef PS1_LOCKSTEP_H
#define PS1_LOCKSTEP_H

#include <stdint.h>
#include <stddef.h>

#include "ps1.h"

typedef struct {
    int32_t scale;          /* 1...8 */
    int32_t dither;         /* PS1_DITHER_* */
    int32_t texture_filter; /* PS1_FILTER_* */
    int32_t sprite_filter;  /* PS1_FILTER_* */
    uint8_t depth_buffer;
} Ps1LockstepConfig;

/* Replays frames [0, up_to) of the .p1fx `bytes` at cfg->scale, synchronously,
 * on the caller's thread. vram_hashes[i] / sidecar_hashes[i]: FNV-1a 64 of the
 * SCALED VRAM readback (u16 little-endian) / the scaled sidecar readback
 * (RGBA8) after frame i. vram_out (scale^2*1024*512 u16) and sidecar_out (x4
 * bytes): the state after the last replayed frame; either may be NULL.
 * Returns the number of frames replayed (up_to clamped to the fixture's), or
 * PS1_ERR_NO_METAL, PS1_ERR_OOM, PS1_ERR_BAD_CUE for bytes that do not parse
 * as a fixture, or PS1_ERR_BAD_SLOT for a config value out of range. */
int32_t ps1_lockstep_replay(const uint8_t* bytes, size_t len, const Ps1LockstepConfig* cfg,
                            uint32_t up_to, uint64_t* vram_hashes, uint64_t* sidecar_hashes,
                            uint16_t* vram_out, uint8_t* sidecar_out);

#endif
