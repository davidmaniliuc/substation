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
    PS1_GPU_VRAM_READ_SETUP
} Ps1GpuCommandKind;

#define PS1_GPU_KIND_COUNT      17
#define PS1_GPU_COMMAND_STRIDE  96

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
} Ps1GpuVertex;

typedef struct {
    uint8_t  kind;    /* Ps1GpuCommandKind */
    uint8_t  opcode;
    uint8_t  transparent;
    uint8_t  _pad0;
    uint32_t value;
    uint16_t clut;
    uint16_t tpage;
    int32_t  x, y, x2, y2, w, h;
    Ps1GpuVertex v[3];
} Ps1GpuCommand;

_Static_assert(sizeof(Ps1GpuVertex) == 20, "Ps1GpuVertex layout changed");
_Static_assert(sizeof(Ps1GpuCommand) == PS1_GPU_COMMAND_STRIDE,
               "Ps1GpuCommand layout changed — command.zig pins 96");
_Static_assert(PS1_GPU_VRAM_READ_SETUP + 1 == PS1_GPU_KIND_COUNT,
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
 * spins straight back out of it. */
void    ps1_run_frame(Ps1*);

/* Mask is sio.zig's convention: 0 = PRESSED, 1 = released, 0xFFFF = idle. */
void    ps1_set_buttons(Ps1*, uint16_t mask);

/* PGXP geometry correction: keep the sub-pixel screen position the GTE
 * computes instead of snapping every vertex to a whole pixel.
 * 0 = off (the default), non-zero = on. Safe to call at any time. */
void    ps1_set_pgxp(Ps1*, int enabled);

/* The four below are SUB-SETTINGS of ps1_set_pgxp, not peers of it: each is
 * ANDed with the master flag inside the core, so setting one while geometry
 * correction is off does nothing at all. A menu should disable them rather
 * than offer a control that silently no-ops. */

/* Propagation through ordinary CPU arithmetic, for games that move a projected
 * vertex through instructions the GTE hooks never see. 0 = off (the default),
 * non-zero = on. It is the part of PGXP most able to make a picture worse. */
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
void    ps1_get_display(const Ps1*, Ps1Display* out);

/* Drains the SPU ring into dst. Returns the number of floats written —
 * interleaved stereo, 44100 Hz. The core owns the ring indices; this call
 * advances them. max_floats should be even; an odd value is truncated down so
 * a stereo pair is never split across two calls. */
size_t  ps1_read_audio(Ps1*, float* dst, size_t max_floats);

#endif /* PS1_H */
