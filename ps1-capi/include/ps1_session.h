/* ps1_session.h — one running game below the user interface.
 *
 * A session owns the machine, the emulator thread, the render thread, the
 * audio output and the memory-card files. The host sets controls and settings
 * (each a store the session's threads pick up) and queues requests; only the
 * emulator thread ever calls the machine. Error codes are ps1.h's.
 *
 * CONTRACT RULES.
 *
 * 1. Every completion is called EXACTLY ONCE, on a session thread (or, for a
 *    request refused at once, on the caller's), with bytes valid only during
 *    the call. A request still waiting when the session stops is answered
 *    PS1_ERR_SESSION_STOPPED, and no completion runs after ps1_session_free
 *    returns.
 *
 * 2. A disc's .bin bytes are BORROWED: the session calls `release` once it
 *    no longer reads them (the disc replaced, a swap refused or superseded,
 *    the session freed). The cue, sbi and ppf bytes are read during the call
 *    only. A ps1_session_new that fails does NOT call `release`: the bytes
 *    are still the caller's.
 *
 * 3. ps1_session_new builds everything and starts nothing; ps1_session_start
 *    reads both cards from `card_dir` and starts the threads. Free the old
 *    session (which writes its cards) BETWEEN the two, and the new one reads
 *    what the old one wrote.
 *
 * 4. With a non-NULL `ns_view`, ps1_session_new and ps1_session_free must be
 *    called on the main thread: they install and remove the view's layer.
 */
#ifndef PS1_SESSION_H
#define PS1_SESSION_H

#include <stdint.h>
#include <stddef.h>

#include "ps1.h"

typedef struct Ps1Session Ps1Session;

typedef struct {
    const uint8_t* bin;
    size_t         bin_len;
    void         (*release)(void* ctx); /* may be NULL */
    void*          release_ctx;
    const uint8_t* cue;                 /* NULL: a single-track .bin, or a CHD */
    size_t         cue_len;
    const uint8_t* sbi;
    size_t         sbi_len;
    const uint8_t* ppf;
    size_t         ppf_len;
} Ps1DiscBytes;

typedef struct {
    const uint8_t* bios;
    size_t         bios_len;
    Ps1DiscBytes   disc;          /* disc.bin NULL boots the BIOS shell */
    const uint8_t* resume_state;  /* NULL: a cold boot. Read during the call */
    size_t         resume_len;
    const char*    card_dir;      /* NUL-terminated; created on the first write */
    void*          ns_view;       /* NSView*, or NULL to present nowhere */
    double         band_height;   /* the unified toolbar band, in points */
    double         band_edge;
    double         band_sigma;
    int32_t        cpu_engine;    /* PS1_ENGINE_* */
    uint8_t        fast_boot;
} Ps1SessionConfig;

/* The ten PGXP switches and the tolerance, in one call so a host re-applying
 * every setting every frame makes one call. A negative tolerance is "none". */
typedef struct {
    uint8_t enabled;
    uint8_t cpu;
    uint8_t culling;
    uint8_t vertex_cache;
    uint8_t texture_correction;
    uint8_t color_correction;
    uint8_t depth_buffer;
    uint8_t transparent_depth;
    uint8_t disable_2d;
    uint8_t preserve_projection;
    float   tolerance;
} Ps1PgxpSettings;

/* `code` is PS1_OK or negative. On success `state` is the save state and
 * `png` its 320x240 thumbnail (NULL, 0 when none could be made). */
typedef void (*Ps1SaveDone)(void* ctx, int32_t code,
                            const uint8_t* state, size_t state_len,
                            const uint8_t* png, size_t png_len);
/* On success `undo` is the state the load replaced. */
typedef void (*Ps1LoadDone)(void* ctx, int32_t code,
                            const uint8_t* undo, size_t undo_len);
typedef void (*Ps1Done)(void* ctx, int32_t code);
/* `png` is NULL when no picture could be taken. */
typedef void (*Ps1ScreenshotDone)(void* ctx, const uint8_t* png, size_t len);

/* PS1_OK and `*out` set, or a negative code: a refused BIOS, disc or resume
 * state gives its own (PS1_ERR_STATE_* for the state), no GPU gives
 * PS1_ERR_NO_METAL. */
int32_t ps1_session_new(const Ps1SessionConfig* cfg, Ps1Session** out);
/* PS1_ERR_AUDIO when the output will not start; whatever did start is
 * stopped again, and the session can still be freed. */
int32_t ps1_session_start(Ps1Session*);
/* Tolerates NULL. Stops every thread, answers every waiting request, writes
 * the cards and releases the disc. */
void    ps1_session_free(Ps1Session*);

/* Controls and settings. Each returns at once. */
void ps1_session_set_buttons(Ps1Session*, uint16_t mask); /* as ps1_set_buttons */
void ps1_session_set_sticks(Ps1Session*, uint8_t lx, uint8_t ly, uint8_t rx, uint8_t ry);
void ps1_session_press_analog(Ps1Session*);
void ps1_session_set_speed(Ps1Session*, int32_t speed);   /* 1 = real time */
void ps1_session_set_paused(Ps1Session*, uint8_t paused);
void ps1_session_set_rewinding(Ps1Session*, uint8_t rewinding);
void ps1_session_set_pgxp(Ps1Session*, const Ps1PgxpSettings*);
void ps1_session_set_cpu_engine(Ps1Session*, int32_t engine); /* PS1_ENGINE_*; others ignored */
void ps1_session_set_rewind_budget(Ps1Session*, size_t bytes); /* 0: rewind off */
void ps1_session_set_runahead(Ps1Session*, int32_t frames);
void ps1_session_set_gain(Ps1Session*, float gain);
void ps1_session_set_dither(Ps1Session*, int32_t mode);   /* PS1_DITHER_* (PrimInstance.h) */
void ps1_session_set_texture_filter(Ps1Session*, int32_t filter); /* PS1_FILTER_* */
void ps1_session_set_sprite_filter(Ps1Session*, int32_t filter);
void ps1_session_set_scale(Ps1Session*, int32_t scale);   /* 1..8 */
void ps1_session_set_size(Ps1Session*, double w_pt, double h_pt, double backing_scale);
void ps1_session_set_occluded(Ps1Session*, uint8_t occluded);
void ps1_session_set_band_shown(Ps1Session*, uint8_t shown);

/* Requests. Each completion is called exactly once (rule 1). */
void ps1_session_request_save(Ps1Session*, Ps1SaveDone done, void* ctx);
/* The state bytes are copied. */
void ps1_session_request_load(Ps1Session*, const uint8_t* state, size_t len,
                              Ps1LoadDone done, void* ctx);
void ps1_session_request_reset(Ps1Session*, Ps1Done done, void* ctx);
/* A newer swap answers an older one PS1_ERR_SUPERSEDED. */
void ps1_session_request_swap(Ps1Session*, const Ps1DiscBytes* disc,
                              Ps1Done done, void* ctx);
void ps1_session_request_screenshot(Ps1Session*, Ps1ScreenshotDone done, void* ctx);

/* Counters, readable from any thread. */
uint64_t ps1_session_frames_produced(Ps1Session*);
void     ps1_session_pad_status(Ps1Session*, Ps1PadStatus* out);
uint64_t ps1_session_card_writes(Ps1Session*);
double   ps1_session_rewind_seconds(Ps1Session*);
/* `pal` is always 0: the session does not carry it. */
void     ps1_session_newest_display(Ps1Session*, Ps1Display* out);

#endif
