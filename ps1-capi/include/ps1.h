/* ps1.h — the C ABI for ps1-core.
 *
 * CONTRACT RULES. These three are stated here because getting them wrong is
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
#define PS1_ERR_BAD_CHD          (-15)
#define PS1_ERR_NO_SNAPSHOT      (-16)
#define PS1_ERR_NO_HISTORY       (-17)
#define PS1_ERR_BAD_PPF          (-18)
#define PS1_ERR_PPF_MISMATCH     (-19)
#define PS1_ERR_STATE_PATCH      (-20)
/* The session's (ps1_session.h): no audio output, no Metal device, a request
 * still waiting when the session stopped, a request past the bound, a disc
 * swap replaced by a newer one before it went in, and a settings struct whose
 * size this library does not know (a header and library that do not match). */
#define PS1_ERR_AUDIO            (-21)
#define PS1_ERR_NO_METAL         (-22)
#define PS1_ERR_SESSION_STOPPED  (-23)
#define PS1_ERR_BUSY             (-24)
#define PS1_ERR_SUPERSEDED       (-25)
#define PS1_ERR_SETTINGS_SIZE    (-26)
/* A file ps1_load_exe or ps1_identify_exe cannot boot: not a PS-X EXE, CPE
 * or MIPS ELF, cut short, or placing bytes outside main RAM. */
#define PS1_ERR_BAD_EXE          (-27)
/* An ECM image that does not decode: bad magic, a truncated or corrupt chunk
 * stream, or a length that is not whole sectors. */
#define PS1_ERR_BAD_ECM          (-28)
/* A CloneCD control file that does not describe its image: a missing
 * section, no track 1, a gap in the track numbers, a track out of order or
 * past the lead-out, or an image shorter than the lead-out. */
#define PS1_ERR_BAD_CCD          (-29)
/* An eboot (.pbp) that does not parse: bad container, disc table or block
 * table, a disc index past its last disc, or a cue passed beside it. */
#define PS1_ERR_BAD_PBP          (-30)
/* An eboot whose disc is encrypted (a "\0PGD" image). Never decrypted. */
#define PS1_ERR_ENCRYPTED_PBP    (-31)
/* An Alcohol 120% descriptor (.mds) that does not describe its .mdf. */
#define PS1_ERR_BAD_MDS          (-32)

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

/* Skips the BIOS shell (the logos and the memory-card / CD menu) when a
 * PlayStation disc boots, as DuckStation's "Fast Boot" does: the kernel
 * still initialises and the game still loads through SYSTEM.CNF.
 *
 * Calling this changes nothing by itself. The setting is read whenever the
 * BIOS is installed, which ps1_reset, ps1_load_disc, ps1_load_bios and
 * ps1_load_state all do, so call it before the last of ps1_load_bios /
 * ps1_load_disc. ps1_load_disc on a machine already running re-installs the
 * BIOS as well; between ps1_run_frame calls that is harmless, because the
 * patched routine runs once, at boot, and never again.
 *
 * A BIOS the patch does not recognise boots in full, silently, and so does a
 * disc that is not a PlayStation disc (an audio CD gets the BIOS CD player,
 * as it should). Off on a new handle; survives a reset. A savestate records
 * the ORIGINAL BIOS, so it resumes with this either way. */
void    ps1_set_fast_boot(Ps1*, uint8_t enabled);

/* Attaches a disc.
 *
 * BORROWS `bin` — the bytes must outlive the handle, or the next call here.
 * `cue` is parsed immediately and is not borrowed; pass NULL/0 for a lone
 * image, which is ONE track at LBA 0 and CANNOT represent audio tracks beside
 * data (a CD-DA title opened this way is silent — say so in the UI).
 *
 * There is one entry point for every format; each slot is told apart by its
 * content:
 *
 *   slot  content                              meaning
 *   bin   "MComprHD"                           a CHD, decoded on demand
 *   bin   "ECM\0"                              an ECM image, decoded on demand
 *   bin   "\0PBP"                              an eboot; `disc` picks which of
 *                                              its discs (cue must be empty)
 *   cue   an Alcohol 120% descriptor           a .mds; `bin` is its .mdf (a
 *                                              2448-byte stride carries
 *                                              LibCrypt, which wins over `sbi`
 *                                              when it has any)
 *   bin   anything else, with no cue           a raw Mode 1/2 track (a sync
 *                                              pattern), one audio track (whole
 *                                              2352-byte sectors), or a cooked
 *                                              2048-byte image (.iso)
 *   cue   a "[CloneCD]" section                a CloneCD control file; `bin`
 *                                              is its .img
 *   sbi   "SBI\0"                              a LibCrypt sidecar
 *   sbi   no magic, a CloneCD sheet in `cue`,  a CloneCD .sub, read once for
 *         a multiple of 96 bytes               its LibCrypt records
 *
 * A cue may name a cooked track (MODE1/2048, MODE2/2048, MODE2/2336...) on a
 * single-TRACK, single-FILE disc, and may name an ECM as its one FILE; a
 * cooked mode beside another TRACK or FILE, an ECM among several FILEs, or
 * a cooked mode naming an ECM (which always decodes to raw sectors), is
 * PS1_ERR_BAD_CUE. A corrupt ECM is PS1_ERR_BAD_ECM; a CloneCD sheet that
 * does not describe its image is PS1_ERR_BAD_CCD.
 *
 * A cue may split its tracks across several FILEs. `Disc` holds ONE slice, so
 * pass those images concatenated in cue order, with a `REM FILESIZE <bytes>`
 * line before each FILE — the sizes are the only record of where the seams
 * were. A multi-FILE cue that arrives without them is rejected with
 * PS1_ERR_MULTI_FILE_CUE rather than mis-laid-out, because `initFromCue`
 * would silently stack every FILE at the same base LBA.
 *
 * `disc` is the index (from 0) of the disc to open in an eboot, whose
 * `ps1_identify_disc_image` reports the count. Any other format wants 0, and
 * anything else is PS1_ERR_BAD_CUE; past an eboot's last disc is
 * PS1_ERR_BAD_PBP. An encrypted eboot is PS1_ERR_ENCRYPTED_PBP and a bad
 * Alcohol descriptor PS1_ERR_BAD_MDS.
 *
 * `bin` may instead be a whole CHD image (it begins "MComprHD"), with `cue`
 * NULL/0: the tracks come from the CHD itself. It is BORROWED exactly like a
 * flat image. Only CHD v5 CD images are read; an older version, a parent
 * (delta) CHD, an unknown codec, or a CHD passed with a cue is refused with
 * PS1_ERR_BAD_CHD.
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
 * rather than parsed as records, unless it is a CloneCD .sub beside its sheet:
 * then it must cover the whole image, and only its records are kept.
 *
 * A NULL `cue` or `sbi` with a non-zero length is that slot's own code
 * (PS1_ERR_BAD_CUE, PS1_ERR_BAD_SBI), whatever `bin` holds: a CHD included.
 * Otherwise the image and its cue are judged before the sidecar, so a disc
 * wrong in both reports the image's or the cue's code, never PS1_ERR_BAD_SBI.
 *
 * `ppf` is a PPF patch (versions 1-3) to apply to the disc's sectors, or
 * NULL/0 for none: a fan translation or fix patch kept beside an untouched
 * rip. It is applied here, into memory the handle owns, so the bytes need not
 * outlive the call and the image is never written. A file this library cannot
 * read as a PPF is PS1_ERR_BAD_PPF; a patch made for a different rip of the
 * game, whose blockcheck or undo data disagrees with this image, is
 * PS1_ERR_PPF_MISMATCH. The patch is part of the disc a savestate records.
 */
int32_t ps1_load_disc(Ps1*, const uint8_t* bin, size_t bin_len,
                            const uint8_t* cue, size_t cue_len,
                            const uint8_t* sbi, size_t sbi_len,
                            const uint8_t* ppf, size_t ppf_len,
                            uint32_t disc);

/* Exchanges the disc on a RUNNING machine, the way a player swaps one.
 *
 * Same arguments, same validation and same return codes as ps1_load_disc,
 * including the borrow contract: `bin` is BORROWED and must outlive the handle
 * or the next call here, and `sbi` is copied. Pass the sidecar and the patch
 * that belong to the disc going IN — the outgoing disc's are discarded, and
 * each disc of a multi-disc set names sectors of its own image.
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
 *
 * A machine running an executable (ps1_load_exe) has no disc to exchange:
 * PS1_ERR_BUSY, and the program runs on. ps1_load_disc replaces it.
 */
int32_t ps1_swap_disc(Ps1*, const uint8_t* bin, size_t bin_len,
                            const uint8_t* cue, size_t cue_len,
                            const uint8_t* sbi, size_t sbi_len,
                            const uint8_t* ppf, size_t ppf_len,
                            uint32_t disc);

/* Boots an executable in place of a disc: a PS-X EXE, a Psy-Q CPE or a
 * 32-bit little-endian MIPS ELF, told apart by content, never by extension.
 *
 * Both buffers are COPIED, so neither need outlive the call. `libps` is a
 * `libps.exe` found beside the program, or NULL/0 for none; it is placed in
 * RAM first and does not take the PC, and anything but a PS-X EXE there is
 * refused. Any disc is taken out, and the machine resets to a cold BIOS
 * boot: the moment the kernel reports itself initialised, the program is put
 * in RAM and jumped to, so the shell and the logo never run. ps1_reset and
 * ps1_load_state re-arm it; ps1_load_disc drops it.
 *
 * A file that is none of the three, is cut short, or would place bytes
 * outside main RAM is PS1_ERR_BAD_EXE, and the machine keeps what it had.
 * A savestate taken while it runs names the program (and its libps) in
 * place of a disc serial, so it is refused on any other program or disc. */
int32_t ps1_load_exe(Ps1*, const uint8_t* exe, size_t exe_len,
                           const uint8_t* libps, size_t libps_len);

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
 * allocation but a CHD's map or an ECM's index, so a library scan can call
 * it once per disc.
 *
 * `bin` must be the WHOLE image, not a head window: SYSTEM.CNF is reached
 * through the ISO directory and its extent sits 497 MB into Croc and 607 MB
 * into Resident Evil. A truncated buffer silently yields no serial rather
 * than an error. Mapping the file instead of reading it keeps that cheap.
 *
 * The image is sniffed as ps1_load_disc sniffs a `bin` with no cue: a CHD, an
 * ECM, an eboot (read as its disc 0), a raw image or a cooked one. Returns
 * PS1_OK; PS1_ERR_BAD_CUE for an image too small to hold one sector;
 * PS1_ERR_BAD_CHD, PS1_ERR_BAD_ECM or PS1_ERR_BAD_PBP for one of those that
 * does not decode; PS1_ERR_ENCRYPTED_PBP for an eboot whose disc is
 * encrypted. Fields the disc does not answer are left zeroed.
 */
int32_t ps1_identify_disc(const uint8_t* bin, size_t bin_len, Ps1DiscId* out);

typedef struct {
    uint32_t disc_count;   /* discs in an eboot; 1 for every other image */
    char     title[129];   /* an eboot's title, truncated at 128 bytes and
                              NUL-terminated; empty for any other image */
} Ps1ImageInfo;

/* ps1_identify_disc with the image's sheet (NULL/0 for none: the .mds of an
 * Alcohol image, a .ccd, a cue) and the disc of an eboot to read. `info` may
 * be NULL. Same codes as ps1_load_disc's image checks. */
int32_t ps1_identify_disc_image(const uint8_t* bin, size_t bin_len,
                                const uint8_t* sheet, size_t sheet_len,
                                uint32_t disc, Ps1DiscId* out, Ps1ImageInfo* info);

typedef struct {
    uint8_t  region;      /* Ps1Region: a PS-X EXE header's marker, else 0 */
    uint8_t  format;      /* 1 PS-X EXE, 2 CPE, 3 ELF */
    uint64_t fingerprint; /* the file alone, without a libps */
} Ps1ExeId;

/* Whether `exe` is an executable ps1_load_exe would boot, without a handle:
 * a library scan calls it to keep a Windows `.exe` out of the list. Returns
 * PS1_OK, or PS1_ERR_BAD_EXE with `out` zeroed. */
int32_t ps1_identify_exe(const uint8_t* exe, size_t exe_len, Ps1ExeId* out);

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

/* A disc's catalogued title. Per disc: a multi-disc game's rows read
 * "Final Fantasy VII (Disc 1)". */
typedef struct {
    char title[256]; /* NUL-terminated */
} Ps1GameTitle;

/* Looks up a SYSTEM.CNF serial in the bundled title table. Returns 1 when
 * found and writes `out`; returns 0 for an unknown/empty serial and zeroes
 * `out`. `serial` must be NUL-terminated. */
uint8_t ps1_lookup_game_title(const char* serial, Ps1GameTitle* out);

/* What a BIOS image is, from its bytes. Every string is NUL-terminated. */
typedef struct {
    uint8_t region;          /* Ps1Region */
    char    description[64]; /* "SCPH-7002, 7502, 9002 (v4.1 12-16-97 E)" */
    char    version[8];      /* "4.1" */
    char    models[96];      /* "SCPH-7002,SCPH-7502,SCPH-9002": aliases expanded */
} Ps1BiosId;

/* Identifies a BIOS image by content, without a handle. Returns 1 and fills
 * `out` for an image in the core's table; returns 0 and zeroes `out` for any
 * other, including a buffer that is not 524288 bytes. The table is
 * DuckStation's 24 PS1 images (every retail revision and the DTL units);
 * unidentified means unlisted, not invalid. */
uint8_t ps1_identify_bios(const uint8_t* bytes, size_t len, Ps1BiosId* out);

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
 * leaves `out` overriding nothing. `serial` must be NUL-terminated. A session
 * folds the preset in itself; for a bare handle its host folds it. */
uint8_t ps1_lookup_pgxp_preset(const char* serial, Ps1PgxpPreset* out);

/* Returns 1 when the bundled table lists the serial as a game that needs dual
 * VRAM. Applies nothing: a session folds it in itself; for a bare handle its
 * host folds it into the mode it asks for. */
uint8_t ps1_game_needs_dual_vram(const char* serial);

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

/* Runs one frame, vblank to vblank. No-op until a BIOS is loaded.
 * A frame ENDS inside vblank, as ps1-wasm's stepFrame does; the next call
 * spins straight back out of it. Under the JIT, linked blocks run back to
 * back inside the frame. */
void    ps1_run_frame(Ps1*);

/* Mask is sio.zig's convention: 0 = PRESSED, 1 = released, 0xFFFF = idle. */
void    ps1_set_buttons(Ps1*, uint16_t mask);

/* Sticks: 0x00..0xFF, 0x80 centre; Y grows DOWN (0xFF = full down). */
void    ps1_set_analog(Ps1*, uint8_t lx, uint8_t ly, uint8_t rx, uint8_t ry);

/* The pad's ANALOG button. Queued; ignored while the game locks the mode. */
void    ps1_press_analog_button(Ps1*);

typedef struct {
    uint8_t analog;  /* 1 = analog mode (the LED) */
    uint8_t small;   /* small motor: 0 or 255 */
    uint8_t large;   /* large motor: 0..255 */
} Ps1PadStatus;
/* Read once after each ps1_run_frame. ps1_reset powers the pad up digital
 * with both motors stopped; a state load restores the motors, so the next
 * poll resumes rumble with no special case. */
void    ps1_get_pad_status(Ps1*, Ps1PadStatus* out);

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
   bits 0-4 red, 5-9 green, 10-14 blue, bit 15 mask/STP. Non-const: on a
   GPU-only machine the pixels are read back from the renderer. */
void    ps1_copy_vram(Ps1*, uint16_t* dst);

/* The software depth plane, 1024*512 uint32_t — what a Metal resync adopts
 * beside ps1_copy_vram, under the same frame. */
void    ps1_copy_depth(Ps1*, uint32_t* dst);
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
 * the BIOS's SHA-256, the disc's serial and the disc's .ppf patch, and refuses
 * a mismatch with PS1_ERR_STATE_BIOS / PS1_ERR_STATE_DISC /
 * PS1_ERR_STATE_PATCH), then call ps1_load_state. A patch keeps the serial,
 * so a state saved without one refuses the patched disc, and the reverse.
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

/* Runahead. ps1_snapshot_mark snapshots the running machine and both memory
 * cards into a buffer the handle owns (no checksum, no identity, ~1 ms);
 * ps1_snapshot_return puts the machine back IN PLACE and keeps the mark, so
 * it can be returned to again. Drain ps1_read_audio before marking: the
 * samples read between the two calls are then exactly the speculative
 * frames'. Returning with no mark, or after ps1_reset, ps1_load_state,
 * ps1_load_disc, ps1_swap_disc, ps1_load_bios or ps1_load_memcard, is
 * PS1_ERR_NO_SNAPSHOT. Do not ps1_take_memcard between the two: a save the
 * speculative frames made would reach the host's file before the return
 * rolls it back. Not for persistence: use ps1_save_state for anything that
 * leaves the process. */
int32_t ps1_snapshot_mark(Ps1*);
int32_t ps1_snapshot_return(Ps1*);

/* Rewind. ps1_rewind_configure turns it on with a memory budget in bytes
 * (the two full-state buffers, ~14 MB, included) or off with 0, which frees
 * everything. While on, ps1_run_frame captures the machine every 2 frames,
 * except between ps1_snapshot_mark and ps1_snapshot_return; the oldest
 * history goes first once the budget is reached. ps1_rewind_step goes back
 * one capture IN PLACE and runs nothing: publish the machine as it now is
 * (ps1_copy_vram for a resync), then ps1_run_frame PS1_REWIND_PICTURE_FRAMES
 * times for the picture, whose streams replay on top of it. One frame is not
 * enough: a double-buffered game shows the buffer it drew the frame before,
 * which is the native shadow. Those frames capture nothing, so a step after
 * them goes further back; stepping until PS1_REWIND_PICTURE_FRAMES frames
 * are gone before running them keeps a held rewind at the game's speed.
 * A step leaves no audio to read: the capture's had already been played. With no history left it is
 * PS1_ERR_NO_HISTORY and nothing changes. ps1_reset,
 * ps1_load_state, ps1_load_disc, ps1_swap_disc and ps1_load_bios clear the
 * history. */
typedef struct {
    uint32_t entries;
    uint32_t frames_covered;
    size_t   bytes_used;
} Ps1RewindInfo;

#define PS1_REWIND_PICTURE_FRAMES 4

int32_t ps1_rewind_configure(Ps1*, size_t budget_bytes);
int32_t ps1_rewind_step(Ps1*);
void    ps1_rewind_info(Ps1*, Ps1RewindInfo* out);
int32_t ps1_peek_state(const uint8_t* src, size_t len, Ps1StateInfo* out);

#endif /* PS1_H */
