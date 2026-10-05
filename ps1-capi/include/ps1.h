/* ps1.h — the C ABI for ps1-core.
 *
 * CONTRACT RULES. These four are stated here because getting them wrong is
 * silent rather than loud.
 *
 * 1. The caller owns every buffer that crosses this boundary, with one
 *    exception: ps1_load_disc BORROWS the .bin data and does not copy it. Those
 *    bytes must outlive the handle, or the next ps1_load_disc call. The cue
 *    bytes are parsed immediately and the .sbi bytes are copied, so neither is
 *    borrowed.
 *
 * 2. Nothing traps across this boundary. Every failure is a negative code.
 *
 * 3. ps1_reset keeps the loaded BIOS and disc. It is the front-panel reset
 *    button, not a teardown. Running with no disc is valid and boots to the
 *    BIOS shell, so it is not an error condition.
 *
 * 4. ps1_take_frame_stream returns a CORE-OWNED buffer pair (records and
 *    payload). It is valid until the next ps1_run_frame on the same handle.
 *    The caller must not free it and must not retain it across a frame.
 */
#ifndef PS1_H
#define PS1_H

#include <stdint.h>
#include <stddef.h>

typedef struct Ps1 Ps1;

/* Error codes. 0 is success; all failures are negative. */
#define PS1_OK                   0
#define PS1_ERR_BAD_BIOS_SIZE    (-1)
#define PS1_ERR_BAD_CUE          (-2)
#define PS1_ERR_MULTI_FILE_CUE   (-3)
#define PS1_ERR_OOM              (-4)
#define PS1_ERR_BAD_SBI          (-5)
#define PS1_ERR_BAD_MEMCARD_SIZE (-6)
#define PS1_ERR_BAD_SLOT         (-7)
#define PS1_ERR_STATE_BAD_MAGIC  (-8)
#define PS1_ERR_STATE_VERSION    (-9)
#define PS1_ERR_STATE_BIOS       (-10)
#define PS1_ERR_STATE_DISC       (-11)
#define PS1_ERR_STATE_CORRUPT    (-12)
#define PS1_ERR_STATE_NO_SPACE   (-13)
#define PS1_ERR_ENGINE_UNAVAILABLE (-14)

/* CPU engines, numbered as ps1-wasm's setCpuEngine numbers them. */
#define PS1_ENGINE_INTERPRETER 0
#define PS1_ENGINE_CACHED      1
#define PS1_ENGINE_JIT         2

/* Returns NULL on allocation failure. */
Ps1*    ps1_create(void);
/* Tolerates NULL. */
void    ps1_destroy(Ps1*);
void    ps1_reset(Ps1*);

/* len must be exactly 524288, or PS1_ERR_BAD_BIOS_SIZE. */
int32_t ps1_load_bios(Ps1*, const uint8_t* bytes, size_t len);

/* Attaches a disc.
 *
 * BORROWS `bin` — the bytes must outlive the handle, or the next call here.
 * `cue` is parsed immediately and is not borrowed; pass NULL/0 for the raw
 * .bin fallback, which is a single data track at LBA 0 and CANNOT represent
 * audio tracks (a CD-DA title opened this way is silent — say so in the UI).
 *
 * A cue may split its tracks across several FILEs. `Disc` holds ONE slice, so
 * pass those images concatenated in cue order, with a `REM FILESIZE <bytes>`
 * line before each FILE — the sizes are the only record of where the seams
 * were. A multi-FILE cue that arrives without them is rejected with
 * PS1_ERR_MULTI_FILE_CUE rather than mis-laid-out, because `initFromCue`
 * would silently stack every FILE at the same base LBA.
 *
 * `sbi` is the disc's LibCrypt sidecar, or NULL/0 when it has none — which is
 * every disc that is not protected, so its absence is not an error. Much of
 * Sony Europe's own PAL catalogue (Final Fantasy IX among it) hides a key in
 * the subchannel Q of a few dozen sectors, and no .bin/.cue can carry it: pass
 * the sidecar or the game loops on its check forever behind a black screen.
 * The bytes are COPIED into the handle rather than borrowed, so the caller
 * need not retain them and a stale one cannot outlive the disc it came with.
 * Pass the sidecar that shipped with THIS disc: another's records are
 * addresses of sectors on a different image and mean nothing here. A buffer
 * that does not begin with the "SBI\0" magic is refused with PS1_ERR_BAD_SBI
 * rather than parsed as records.
 */
int32_t ps1_load_disc(Ps1*, const uint8_t* bin, size_t bin_len,
                            const uint8_t* cue, size_t cue_len,
                            const uint8_t* sbi, size_t sbi_len);

/* Exchanges the disc on a RUNNING machine, the way a player swaps one.
 *
 * Same arguments, same validation and same return codes as ps1_load_disc,
 * including the borrow contract: `bin` is BORROWED and must outlive the handle
 * or the next call here, and `sbi` is copied. Pass the sidecar that shipped
 * with the disc going IN — the outgoing disc's is discarded, and each disc of
 * a multi-disc set names sectors of its own image.
 *
 * The difference is the tray. This raises the drive's shell-open state, puts
 * the new disc in, and closes the tray one emulated second later; status bit 4
 * then stays set until the game reads it with Getstat, which is how it learns
 * to re-read the TOC rather than trust the file table it cached from the disc
 * that just came out. Replacing the disc without that sequence — which is what
 * calling ps1_load_disc on a running machine does — is invisible to the game.
 *
 * Commands issued during that one-second window are refused with the
 * door-open error, exactly as on hardware. A rejection here changes nothing:
 * the machine keeps the disc it had.
 */
int32_t ps1_swap_disc(Ps1*, const uint8_t* bin, size_t bin_len,
                            const uint8_t* cue, size_t cue_len,
                            const uint8_t* sbi, size_t sbi_len);

/* ---- Disc identification --------------------------------------------------
 *
 * What the disc says about itself: the licence string the BIOS checks at
 * LBA 4, and the boot executable named by SYSTEM.CNF, whose four-letter
 * prefix carries a region of its own. No filename rule and no database, so a
 * renamed rip still identifies and an obscure disc identifies as well as a
 * famous one.
 *
 * There is deliberately no title and no disc-set membership ON THE DISC. The
 * separate catalog lookup below maps known serials to a game and disc ordinal.
 */

typedef enum {
    PS1_REGION_UNKNOWN = 0,   /* fall back to your own rule; not a console */
    PS1_REGION_AMERICA = 1,
    PS1_REGION_EUROPE  = 2,
    PS1_REGION_JAPAN   = 3
} Ps1Region;

typedef struct {
    uint8_t region;        /* Ps1Region */
    char    serial[16];    /* "SLUS-00530", NUL-terminated; empty if unknown */
    char    volume_id[33]; /* ISO volume id, NUL-terminated; often empty, and
                              never a title */
} Ps1DiscId;

/* Identifies a disc without building a machine: no handle, no BIOS, no
 * allocation, so a library scan can call it once per disc.
 *
 * `bin` must be the WHOLE image, not a head window: SYSTEM.CNF is reached
 * through the ISO directory and its extent sits 497 MB into Croc and 607 MB
 * into Resident Evil. A truncated buffer silently yields no serial rather
 * than an error. Mapping the file instead of reading it keeps that cheap.
 *
 * Returns PS1_OK, or PS1_ERR_BAD_CUE for an image too small to hold one
 * sector. Fields the disc does not answer are left zeroed.
 */
int32_t ps1_identify_disc(const uint8_t* bin, size_t bin_len, Ps1DiscId* out);

/* A catalogued multi-disc set. This is deliberately a separate output struct:
 * Ps1DiscId is part of the long-lived ABI and callers allocate it themselves.
 */
typedef struct {
    char    game_title[256]; /* canonical title, NUL-terminated */
    uint8_t disc_number;     /* one-based ordinal */
} Ps1DiscSet;

/* Looks up a SYSTEM.CNF serial in the bundled multi-disc catalog. Returns 1
 * when found and writes `out`; returns 0 for an unknown/empty serial and
 * zeroes `out`. `serial` must be NUL-terminated. */
uint8_t ps1_lookup_disc_set(const char* serial, Ps1DiscSet* out);

/* A game's PGXP overrides, from DuckStation's per-game database. Each switch
 * is -1 where the game keeps the player's setting, else 0 (off) or 1 (on),
 * and names the ps1_set_pgxp_* call it overrides; `tolerance` counts only
 * when `has_tolerance` is 1. Nothing is applied by the lookup: the frontend
 * folds the overrides into the values it passes to ps1_set_pgxp_*. */
typedef struct {
    float   tolerance;
    uint8_t has_tolerance;
    int8_t  enabled;
    int8_t  cpu;
    int8_t  culling;
    int8_t  vertex_cache;
    int8_t  texture_correction;
    int8_t  color_correction;
    int8_t  depth_buffer;
    int8_t  disable_2d;
    int8_t  preserve_projection;
} Ps1PgxpPreset;

/* Looks up a SYSTEM.CNF serial in the bundled PGXP preset table. Returns 1
 * when found and writes `out`; returns 0 for an unknown/empty serial and
 * leaves `out` overriding nothing. `serial` must be NUL-terminated. */
uint8_t ps1_lookup_pgxp_preset(const char* serial, Ps1PgxpPreset* out);

typedef struct {
    uint32_t vram_x;     /* disp_env.vram_x_start */
    uint32_t vram_y;     /* disp_env.vram_y_start */
    uint32_t width;      /* getVisibleWidth()  — the PROGRAMMED display area,
                            not the nominal mode size */
    uint32_t height;     /* getVisibleHeight() */
    uint8_t  depth24;    /* GP1(08h) bit 4 */
    uint8_t  enabled;    /* !disp_env.display_disabled */
    uint8_t  pal;        /* for aspect correction */
    uint8_t  _pad;
} Ps1Display;

/* ---- GP0 command stream records -------------------------------------------
 *
 * The mirror of ps1-core/src/gpu/command.zig's `Command`, which is an
 * `extern struct` pinned at 72 bytes by a comptime block in that file.
 *
 * Declared HERE rather than in Swift because Swift does not guarantee
 * C-compatible layout for its own structs: a raw read of a 72-byte record into
 * a Swift struct would rely on something the language does not promise. Coming
 * through this header makes the layout a fact.
 *
 * Phase A2 uses these to read .p1fx fixtures. Phase B stayed fixture-driven on
 * purpose. Phase D1 shipped the live handoff: this library builds
 * gpu_sink = .dual, and ps1_take_frame_stream now has a consumer.
 */

typedef enum {
    PS1_GPU_DRAW_TRIANGLE = 0,
    PS1_GPU_DRAW_SHADED_TRIANGLE,
    PS1_GPU_DRAW_TEXTURED_TRIANGLE,
    PS1_GPU_DRAW_RECTANGLE,
    PS1_GPU_DRAW_TEXTURED_RECTANGLE,
    PS1_GPU_DRAW_LINE,
    PS1_GPU_DRAW_SHADED_LINE,
    PS1_GPU_SET_DRAW_ENV,
    PS1_GPU_LATCH_TEXPAGE,
    PS1_GPU_SET_TEXTURE_DISABLE_ALLOWED,
    PS1_GPU_RESET_DRAW_ENV,
    PS1_GPU_FILL_RECT,
    PS1_GPU_COPY_RECT,
    PS1_GPU_VRAM_WRITE_SETUP,
    PS1_GPU_VRAM_WRITE_DATA,
    PS1_GPU_VRAM_WRITE_ABORT,
    PS1_GPU_VRAM_READ_SETUP,
    /* APPENDED, not inserted: every existing kind keeps its ordinal, so a
       version-3 reader's kind table is a prefix of this one. */
    PS1_GPU_CLEAR_DEPTH
} Ps1GpuCommandKind;

#define PS1_GPU_KIND_COUNT      18
#define PS1_GPU_COMMAND_STRIDE  120

typedef struct {
    int16_t  x, y;
    uint8_t  u, v;
    uint16_t _pad;
    uint32_t color;   /* 24-bit BGR as it arrives on the wire. The Gouraud
                         paths carry the vertex's own colour; the textured
                         paths carry its modulation colour, which a
                         flat-shaded primitive repeats across all three. */
    /* Screen position in 16.16 — the exact value the GTE's projection
       produced, `x << 16` unless PGXP resolved a sub-pixel for this vertex.
       Archival: the rasterizers work in 1/16 px relative to the primitive's
       bounding box, which is what bounds the edge functions by the span the
       oversized-primitive rule already caps. Triangles only. */
    int32_t  px, py;
    /* Quantised reciprocal depth, round(2^16 * Wmin / W) for this triangle —
       see command.zig. Zero means no depth; a triangle is sampled
       perspective-correctly if and only if all three are non-zero. Textured
       triangles only. */
    int32_t  rw;
    /* Absolute reciprocal depth, round(2^30 / W) — see command.zig. Zero means
       no depth. Triangles only, and only while the depth buffer is on. */
    int32_t  iz;
} Ps1GpuVertex;

/* Which attributes of a triangle may be interpolated through the vertex
 * depths in Ps1GpuVertex.rw. Each is ANDed with "all three rw non-zero" at the
 * point of use, never substituted for it: with PGXP off no vertex resolves, so
 * every rw is zero and no flag can widen anything. */
#define PS1_GPU_FLAG_TEXTURE_PERSPECTIVE (1u << 0)
#define PS1_GPU_FLAG_COLOR_PERSPECTIVE   (1u << 1)

/* The depth-buffer pair: a transparent polygon under transparent_depth tests
 * but does not write. Each is ANDed with "all three iz non-zero" at use. */
#define PS1_GPU_FLAG_DEPTH_TEST  (1u << 2)
#define PS1_GPU_FLAG_DEPTH_WRITE (1u << 3)

typedef struct {
    uint8_t  kind;    /* Ps1GpuCommandKind */
    uint8_t  opcode;
    uint8_t  transparent;
    uint8_t  flags;   /* PS1_GPU_FLAG_* above. Was a pad byte, so the stride is
                         unchanged and a fixture written before this existed
                         decodes its zero as "neither attribute corrected". */
    uint32_t value;
    uint16_t clut;
    uint16_t tpage;
    int32_t  x, y, x2, y2, w, h;
    Ps1GpuVertex v[3];
} Ps1GpuCommand;

_Static_assert(sizeof(Ps1GpuVertex) == 28, "Ps1GpuVertex layout changed");
_Static_assert(sizeof(Ps1GpuCommand) == PS1_GPU_COMMAND_STRIDE,
               "Ps1GpuCommand layout changed — command.zig pins 120");
_Static_assert(PS1_GPU_CLEAR_DEPTH + 1 == PS1_GPU_KIND_COUNT,
               "Ps1GpuCommandKind count drifted from command.Kind");

/* Recorder capacities, mirrored from ps1-core/src/gpu/recorder.zig. A comptime
   block in ps1-capi/src/root.zig fails the build if these drift. The Swift
   side sizes its queue slots from them. */
#define PS1_GPU_MAX_RECORDS       65536
#define PS1_GPU_MAX_PAYLOAD_WORDS 524288

/* One frame of recorded GP0 commands.
 *
 * ps1_take_frame_stream is a DRAIN, not a peek: it resets the recorder. Call it
 * exactly once per ps1_run_frame. Skipping it does not keep the frame — the
 * next one stacks on top until the capacity overruns.
 *
 * complete == 0 means the records are a PREFIX of the frame, NOT a shorter
 * frame. Applying a prefix leaves a shadow VRAM permanently out of step with
 * the rasterizer, so an incomplete stream must be DISCARDED and the renderer
 * resynced from the shadow — never replayed. */
typedef struct {
    const Ps1GpuCommand* records;
    size_t               record_count;
    const uint32_t*      payload;
    size_t               payload_count;
    uint8_t              complete;
    uint8_t              _pad[7];
} Ps1GpuStream;

void ps1_take_frame_stream(Ps1*, Ps1GpuStream* out);

/* Runs one frame, vblank to vblank. No-op until a BIOS is loaded.
 * A frame ENDS inside vblank, as ps1-wasm's stepFrame does; the next call
 * spins straight back out of it. Under the JIT, linked blocks run back to
 * back inside the frame. */
void    ps1_run_frame(Ps1*);

/* Mask is sio.zig's convention: 0 = PRESSED, 1 = released, 0xFFFF = idle. */
void    ps1_set_buttons(Ps1*, uint16_t mask);

/* PGXP geometry correction: keep the sub-pixel screen position the GTE
 * computes instead of snapping every vertex to a whole pixel.
 * 0 = off (the default), non-zero = on. Safe to call at any time. */
void    ps1_set_pgxp(Ps1*, int enabled);

/* The six below are SUB-SETTINGS of ps1_set_pgxp, not peers of it: each is
 * ANDed with the master flag inside the core, so setting one while geometry
 * correction is off does nothing at all. A menu should disable them rather
 * than offer a control that silently no-ops. */

/* Propagation through ordinary CPU arithmetic, for games that move a projected
 * vertex through instructions the GTE hooks never see. Non-zero = on, and this
 * is the DEFAULT -- measured, it is the difference between PGXP working and
 * not working at all: croc 12.6% -> 99.4%%, spyro 41.6% -> 99.9%%, three
 * games that had been resolving nothing but the BIOS licence logo. */
void    ps1_set_pgxp_cpu(Ps1*, int enabled);

/* Float NCLIP. NCLIP's sign decides backface culling, and on a triangle
 * near-degenerate at integer precision it flips essentially at random --
 * facets on a curved surface blink in and out as the camera moves.
 * Non-zero = on, and unlike the other three this is the DEFAULT. */
void    ps1_set_pgxp_culling(Ps1*, int enabled);

/* A second, position-keyed lookup for a vertex whose memory word cannot be
 * found. Allocates 83 MB while on and frees it when turned off, so a frontend
 * that never enables it never pays for it. 0 = off (the default). */
void    ps1_set_pgxp_vertex_cache(Ps1*, int enabled);

/* How far a PGXP candidate may sit from the integer vertex it claims to
 * describe, in pixels, per axis. Negative disables the check, which is the
 * default; 0 admits only a candidate exactly on the integer grid. */
void    ps1_set_pgxp_tolerance(Ps1*, float tolerance);

/* Perspective-correct texturing. A PS1 interpolates u/v linearly in screen
 * space, which is only correct for a polygon parallel to the screen; on a
 * floor or a wall the texture shears and slides as the camera moves.
 * Non-zero = on, and this is the DEFAULT — texture correction and culling
 * correction are the picture, while the vertex cache and CPU mode are the
 * workarounds. Textured RECTANGLES stay affine: a sprite has one position and
 * a size, no per-vertex depth, and is 2D by construction. */
void    ps1_set_pgxp_texture_correction(Ps1*, int enabled);

/* Perspective-correct vertex COLOUR. A PS1 interpolates a Gouraud gradient
 * linearly in screen space for the same reason it interpolates u/v that way,
 * and it is wrong on the same polygons: a lit floor running away from the
 * camera has its shading bunched toward the near edge and stretched across the
 * far one, and the whole gradient swims as the camera moves.
 * Non-zero = on; 0 is the DEFAULT, matching the reference, which carries a
 * per-game disable list for this correction and for no other. Only a GOURAUD
 * primitive can change: three equal colours reproduce the affine result
 * exactly, so every flat-shaded primitive is identical either way. */
void    ps1_set_pgxp_color_correction(Ps1*, int enabled);

/* The PGXP depth buffer. OFF by default, gated on ps1_set_pgxp. A change
 * resets the plane through the command stream, so Metal's resets with it. */
void    ps1_set_pgxp_depth_buffer(Ps1*, int enabled);

/* Transparent polygons test (never write) the depth buffer. OFF by default;
 * acts only while the depth buffer is on. */
void    ps1_set_pgxp_transparent_depth(Ps1*, int enabled);

/* A primitive whose positions resolved but which lacks depths is drawn at
 * integer positions. OFF by default, gated on ps1_set_pgxp. */
void    ps1_set_pgxp_disable_2d(Ps1*, int enabled);

/* Project from the GTE's exact accumulator instead of its rounded IR1/IR2/SZ3.
 * OFF by default, gated on ps1_set_pgxp. Changes no GTE register. */
void    ps1_set_pgxp_preserve_projection(Ps1*, int enabled);

/* The CPU engine. A HOST setting like the PGXP ones: it is not part of a
 * savestate, and it survives ps1_reset and ps1_load_state, which select it
 * on the machine they rebuild. Call between ps1_run_frame calls, from the
 * thread that makes them, or from any thread before the first frame runs
 * (before a state loads, so the restored I-cache is kept). Re-selecting the
 * current engine is free.
 *
 * Returns PS1_ERR_ENGINE_UNAVAILABLE for a number that names no engine or
 * an engine this build lacks (the JIT exists only on arm64 macOS), and
 * PS1_ERR_OOM. On any error the current engine stays selected. */
int32_t ps1_set_cpu_engine(Ps1*, int engine);

/* The engine the machine is running on now. */
int     ps1_get_cpu_engine(const Ps1*);

/* 1 if this build has the engine, 0 if not. Needs no handle. */
int     ps1_cpu_engine_available(int engine);

/* Memory cards. Two slots, as a console has, selected by JOY_CTRL bit 13 from
 * the game's side. One shared pair of images for the whole library is the
 * intended frontend policy: a multi-disc game then finds its own save on disc
 * 2 because it is the same card.
 *
 * ps1_load_memcard COPIES the bytes, unlike the disc .bin and like the .sbi
 * sidecar. len must be exactly PS1_MEMCARD_BYTES.
 *
 * ps1_take_memcard is a DRAIN: it returns 1 having written PS1_MEMCARD_BYTES
 * to dst and cleared the dirty flag, or 0 having left dst untouched. Poll it
 * per frame; the copy is paid only on a frame where the game committed a
 * block, which is rare. Both return PS1_ERR_BAD_SLOT for a slot outside
 * 0..PS1_MEMCARD_SLOTS-1.
 *
 * A card survives ps1_reset, as it does on hardware. */
#define PS1_MEMCARD_BYTES 131072
#define PS1_MEMCARD_SLOTS 2

int32_t ps1_load_memcard(Ps1*, int32_t slot, const uint8_t* bytes, size_t len);
int32_t ps1_take_memcard(Ps1*, int32_t slot, uint8_t* dst);

/* dst must hold 1024*512 uint16_t (1 MB), ABGR1555:
   bits 0-4 red, 5-9 green, 10-14 blue, bit 15 mask/STP. */
void    ps1_copy_vram(const Ps1*, uint16_t* dst);

/* The software depth plane, 1024*512 uint32_t — what a Metal resync adopts
 * beside ps1_copy_vram, under the same frame. */
void    ps1_copy_depth(const Ps1*, uint32_t* dst);
void    ps1_get_display(const Ps1*, Ps1Display* out);

/* Drains the SPU ring into dst. Returns the number of floats written —
 * interleaved stereo, 44100 Hz. The core owns the ring indices; this call
 * advances them. max_floats should be even; an odd value is truncated down so
 * a stereo pair is never split across two calls. */
size_t  ps1_read_audio(Ps1*, float* dst, size_t max_floats);

/* ---- Savestates -----------------------------------------------------------
 *
 * A state is the whole emulated machine, versioned per device so a state
 * survives an update of this library. It does NOT contain the BIOS, the disc
 * or the memory cards: load the same BIOS and disc first (the state records
 * the BIOS's SHA-256 and the disc's serial, and refuses a mismatch with
 * PS1_ERR_STATE_BIOS / PS1_ERR_STATE_DISC), then call ps1_load_state.
 *
 * ps1_load_state is all-or-nothing: on any error the running machine is
 * untouched. Renderer settings and an undrained memory-card write survive it.
 * A state from a NEWER library is PS1_ERR_STATE_VERSION. */
typedef struct {
    char    serial[16];        /* NUL-padded; all zero for a disc with none */
    uint8_t bios_sha256[32];
} Ps1StateInfo;

size_t  ps1_save_state_size(Ps1*);
int32_t ps1_save_state(Ps1*, uint8_t* dst, size_t cap, size_t* out_len);
int32_t ps1_load_state(Ps1*, const uint8_t* src, size_t len);
int32_t ps1_peek_state(const uint8_t* src, size_t len, Ps1StateInfo* out);

#endif /* PS1_H */
