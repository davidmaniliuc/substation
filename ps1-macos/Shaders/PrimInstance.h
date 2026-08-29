/* The per-primitive instance record: everything one PS1 primitive needs,
 * resolved on the CPU by the encoder and indexed in the shader by
 * `instance_id`.
 *
 * Declared in C, and included by BOTH the Metal compiler and clang-as-C
 * (through the CPs1 module map), for the same reason Ps1GpuCommand is:
 * Swift does not guarantee C-compatible layout for its own structs.
 *
 * Plain `int` / `unsigned int` throughout — NEVER <stdint.h>, which MSL does
 * not ship. Both compilers agree that int is 32 bits on every target this
 * project builds for. Every field is 4 bytes, so the struct's alignment is 4
 * and its stride is exactly 4 * the field count in both languages.
 *
 * Because there is no Metal pipeline state that differs between drawing
 * primitives, a whole run of them is one instanced draw and ordering is
 * preserved by instance index. That is why this record is wide: everything
 * that would otherwise have been encoder state lives here instead.
 */
#ifndef PS1_PRIM_INSTANCE_H
#define PS1_PRIM_INSTANCE_H

enum {
    PS1_PRIM_FLAT_TRI = 0,
    PS1_PRIM_GOURAUD_TRI = 1,
    PS1_PRIM_TEXTURED_TRI = 2,
    PS1_PRIM_RECT = 3,
    PS1_PRIM_TEXTURED_RECT = 4,
    PS1_PRIM_LINE_PIXEL = 5,
    PS1_PRIM_SHADED_LINE_PIXEL = 6,
    PS1_PRIM_FILL = 7,
    PS1_PRIM_UPLOAD = 8,
    PS1_PRIM_COPY = 9
};

#define PS1_PRIM_TRANSPARENT (1u << 0) /* the primitive's own opcode bit */
#define PS1_PRIM_DITHER      (1u << 1) /* GP0(E1) bit 9 */
#define PS1_PRIM_MODULATE    (1u << 2) /* textured opcode bit 0 CLEAR */
#define PS1_PRIM_SET_MASK    (1u << 3) /* GP0(E6) bit 0 */
#define PS1_PRIM_CHECK_MASK  (1u << 4) /* GP0(E6) bit 1 */

typedef struct {
    int kind;

    /* Inclusive pixel box, ALREADY clamped to VRAM. The vertex shader expands
       vertex_id 0..3 into its corners; the fragment shader decides coverage. */
    int box_x0, box_y0, box_x1, box_y1;

    /* Screen-space vertices with GP0(E5)'s offset ALREADY APPLIED. Triangles
       use all six; rectangles and uploads use (x0, y0) as the origin; a line
       pixel uses (x0, y0) as the pixel itself. */
    int x0, y0, x1, y1, x2, y2;

    /* Texture coordinates. Triangles use all six; a textured rectangle uses
       (u0, v0) as its origin texcoord. */
    int u0, v0, u1, v1, u2, v2;

    /* 24-bit BGR as it arrives on the wire — Gouraud triangles and shaded
       lines only. */
    unsigned int c0, c1, c2;

    /* ABGR1555: the flat colour, the modulation colour, or the fill colour. */
    unsigned int color;

    unsigned int clut_x, clut_y, tpage_x, tpage_y, tex_depth;
    unsigned int tex_window; /* raw GP0(E2) */

    /* The drawing area, INCLUSIVE, from GP0(E3)/(E4). Not a scissor rect: a
       scissor is per-encoder state and would break the single instanced draw. */
    int clip_x0, clip_y0, clip_x1, clip_y1;

    unsigned int blend_mode; /* (draw_mode >> 5) & 3 */
    unsigned int flags;

    int k, steps; /* shaded line: the step index and the span length */
    int w, h;     /* rectangle extents, or a transfer's width/height */

    int src_x, src_y; /* copy_rect source origin */

    /* Upload only. `word_base` is chosen so that payload word index
       (word_base + pixel/2) is the word carrying that pixel; `pixel_first` and
       `pixel_last` bound this run's contiguous slice of transfer pixels. */
    int word_base, pixel_first, pixel_last;
} Ps1PrimInstance;

/* Per-DRAW state that is not per-primitive: the internal resolution, and one
 * debug switch. Bound at buffer index 2 for BOTH stages (index 0 is the
 * instance buffer, index 1 the upload payload).
 *
 * RUNTIME, not a function constant and not a build setting: one build then
 * runs the whole gate ladder, and Phase D gets a resolution picker without
 * rebuilding pipelines.
 *
 * `dither_off` is a TEST switch, and it lives here rather than in the instance
 * record for a specific reason. Dithering is the one thing that breaks
 * downsample-invariance, so Gate 2 must run with it off on both sides — but
 * clearing PS1_PRIM_DITHER in PrimBuilder instead would make the instance
 * bytes Gate 2 checks differ from the ones Gate 1 checks, and the whole point
 * of keeping records native is that those two are the same bytes. */
typedef struct {
    unsigned int scale;      /* internal resolution, 1...8 */
    unsigned int dither_off; /* force dithering off at EVERY scale */
} Ps1RasterUniforms;

#endif /* PS1_PRIM_INSTANCE_H */
