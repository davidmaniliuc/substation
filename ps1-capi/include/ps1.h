/* ps1.h — the C ABI for ps1-core.
 *
 * CONTRACT RULES. These four are stated here because getting them wrong is
 * silent rather than loud.
 *
 * 1. The caller owns every buffer that crosses this boundary, with one
 *    exception: ps1_load_disc BORROWS the .bin data and does not copy it. Those
 *    bytes must outlive the handle, or the next ps1_load_disc call. The cue
 *    bytes are parsed immediately and are NOT borrowed.
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
#define PS1_OK                  0
#define PS1_ERR_BAD_BIOS_SIZE  (-1)
#define PS1_ERR_BAD_CUE        (-2)
#define PS1_ERR_MULTI_FILE_CUE (-3)
#define PS1_ERR_OOM            (-4)

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
 * A cue declaring more than one FILE is rejected with PS1_ERR_MULTI_FILE_CUE
 * rather than mis-laid-out.
 */
int32_t ps1_load_disc(Ps1*, const uint8_t* bin, size_t bin_len,
                            const uint8_t* cue, size_t cue_len);

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
 * purpose, so the live handoff (ps1_take_frame_stream, and gpu_sink = .dual for
 * this library) is Phase D: an entry point shipped before it has a consumer is
 * untested surface.
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
#define PS1_GPU_COMMAND_STRIDE  72

typedef struct {
    int16_t  x, y;
    uint8_t  u, v;
    uint16_t _pad;
    uint32_t color;   /* 24-bit BGR as it arrives on the wire; Gouraud only */
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

_Static_assert(sizeof(Ps1GpuVertex) == 12, "Ps1GpuVertex layout changed");
_Static_assert(sizeof(Ps1GpuCommand) == PS1_GPU_COMMAND_STRIDE,
               "Ps1GpuCommand layout changed — command.zig pins 72");
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
