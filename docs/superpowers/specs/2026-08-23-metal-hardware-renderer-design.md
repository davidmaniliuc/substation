# Metal hardware renderer with internal-resolution upscaling — design

**Date:** 2026-08-23
**Status:** approved; to be implemented across several plans (see § Phases)

## Goal

Render PS1 graphics on the GPU so the internal resolution can exceed 1×, while
the software rasterizer stays bit-exact and keeps working.

**This is not a replacement.** `ps1-core/src/gpu/` remains the renderer for
`ps1-wasm`, `ps1-debug`, `ps1-trace` and the ROM suites, and it is the
reference the Metal backend is diffed against. "Fully Metal" would mean
deleting the only oracle this project has for GPU behaviour.

## Decisions taken

Three forks were settled before design, and everything below follows from them:

1. **Hardware renderer first, PGXP second.** PGXP is an independent subsystem
   (`cop2/`, `cpu/exec.zig`, GPU vertex intake) that needs no Metal and would
   improve the software rasterizer on its own. It is sequenced second because it
   *deliberately changes output*: it moves every `trace-golden` baseline and
   makes `test-roms-pl` meaningless. Landing it first would leave the renderer
   work with no oracle, and every rendering bug afterwards confounded between
   the two. PGXP gets its own spec.
2. **Accuracy-first; upscaling is opt-in.** At scale 1× the Metal backend must
   be pixel-identical to the software rasterizer. Scale > 1 is a separate mode
   that is permitted to diverge (dithering off, and nothing else deliberately).
3. **GPU-authoritative VRAM with a 1× CPU shadow.** The scaled VRAM texture is
   the truth for anything drawn. This is the only model in which
   render-to-texture works at scale.

## Architecture

### The seam

`gpu/gp0.zig` already decodes GP0 commands and calls eight entry points on the
`Renderer` namespace (`drawTriangle`, `drawShadedTriangle`,
`drawTexturedTriangle`, `drawRectangle`, `drawTexturedRectangle`, `drawLine`,
`drawShadedLine`, `putPixel`), passing a `*const DrawingEnv`.

That `DrawingEnv` is **live mutable state** — E1–E6 writes mutate it between
draws (`gpu/registers.zig`). A list of draw calls is therefore *not* replayable
on its own. The command stream must be ordered and must carry the state changes
interleaved with the draws, exactly as a display list does.

`gp0.zig` stops calling `Renderer` directly and emits into a **sink**, selected
at comptime so the existing path pays nothing:

- **`SoftwareSink`** — rasterizes immediately. Today's code, today's behaviour,
  no buffering. Used by wasm, `ps1-debug`, `ps1-trace` and both ROM suites.
- **`RecordSink`** — appends typed POD commands to a per-frame buffer for the
  host to consume.

### What the stream carries

Three categories, in submission order:

- **Draws** — the eight primitives, with vertices, colours, `clut`, `tpage`,
  `opcode` and the transparency flag, exactly as the current signatures carry
  them.
- **State** — E1–E6 writes (`draw_mode`, `tex_window`, `area_top_left`,
  `area_bot_right`, `offset`, `mask_bit`) plus GP1(09)'s
  `texture_disable_allowed` latch.
- **Transfers** — GP0 `A0` (CPU→VRAM, carrying its pixel payload), `C0`
  (VRAM→CPU), `80` (VRAM→VRAM).

Commands are plain data with no pointers, so the buffer crosses the C ABI as a
flat array and can be replayed by either backend.

### VRAM on the GPU

**The VRAM texture is `R16Uint` at `1024·N × 512·N`. It is not RGBA8, and that
is the decision the rest of the renderer hangs on.**

PS1 VRAM is simultaneously framebuffer, texture memory and CLUT storage. A game
draws into it and then samples the result as 4bpp, 8bpp or 16bpp indexed data.
Storing upscaled RGBA8 destroys the bit patterns that texture sampling depends
on. Keeping the raw 16-bit value and decoding ABGR1555/CLUT **in the fragment
shader** preserves them, and is also what lets the shader see bit 15 — the
mask/STP bit whose semantics `gpu/renderer.zig` and `gpu/vram.zig` already
implement carefully and which must not regress.

Texture *data* is never upscaled. At scale N a texel at `(u, v)` reads subtexel
`(u·N, v·N)`; only rendered geometry gains resolution.

### Semi-transparency

The four modes are `B/2+F/2`, `B+F`, `B−F`, `B+F/4`. They need the destination
pixel, which on Apple Silicon means **programmable blending** — reading
`[[color(0)]]` in the fragment shader through tile memory. Exact, no barriers,
no resolve copies.

**It must be integer arithmetic on 5-bit channels, not Metal's fixed-function
blending.** `gpu/color.zig`'s `blend(bg, fg, mode)` works on `u16` ABGR1555 with
expressions like `(br + fr) / 2` — integer division, truncating. Fixed-function
blending operates on normalized floats and rounds differently, so it cannot be
bit-exact at 1×. The shader must decode to 5-bit integers, apply the same
truncating arithmetic, and re-encode.

Dithering runs in-shader at 1× and is disabled above it.

### Ownership and sync

CPU→VRAM uploads write both the GPU texture and the 1× CPU shadow. VRAM→CPU
(`C0`) is the only forced sync: downsample the region and stall. Dirty-region
tracking exists to keep those *rare*, not to make them fast.

## Phases

Each phase is its own implementation plan. They are strictly ordered.

### Phase A — the command stream (no Metal)

Introduce the sink seam, the command types, `RecordSink`, and a replay function
that feeds a recorded stream back into the software rasterizer.

**Gate:** replaying a recorded stream produces a framebuffer **byte-identical**
to rasterizing directly, across the PeterLemon ROMs and several thousand frames
of real-game boot. Plus `zig build trace-golden -- verify` green and
`test-roms-pl` green — the seam must not change core behaviour.

This phase contains no GPU code and is fully testable headlessly. It exists
because "the stream is lossless" is the assumption every later phase rests on,
and it is much cheaper to falsify here than through a Metal backend.

### Phase B — Metal backend at 1×

Extend `ps1-capi/include/ps1.h` with the command-buffer handoff. Build the Swift
renderer: `R16Uint` VRAM texture, in-shader decode of 4/8/16bpp and CLUT,
programmable blending with the integer arithmetic above, dithering, mask-bit
handling, drawing-area clip, texture window wrap.

**Gate:** for a recorded stream, the Metal framebuffer at 1× is byte-identical
to the software one, per frame, on the PL ROMs and on real-game captures.

### Phase C — upscaling

Scale factor N: geometry coordinate scaling, subtexel texture reads, readback
and downsample on `C0`, dirty-region tracking, dithering disabled.

**Gate:** 1× remains byte-identical (Phase B's test re-run at N=1). At N > 1
there is no golden to compare against, so the gate is a checklist of the
failures upscaling actually produces, each checked on Croc, Spyro, Silent Hill
and Crash: no seams along quad diagonals, no texture bleeding across texture-page
or CLUT boundaries, no gaps between adjacent primitives, render-to-texture
content sampled at scale rather than at 1×, and the oversized-primitive drop
rule (`>=1024` horizontally / `>=512` vertically) still applied in *native*
units rather than scaled ones. Plus: readback stalls do not disturb the
audio-paced emulator thread.

### Phase D — frontend integration

Scale setting in the app, interaction with the 4:3 aspect lock and the letterbox
path in `MetalDisplayView`, persistence of the choice.

## Risks

- **Readback stalls.** `ps1-macos` paces the emulator from the audio device's
  clock. A synchronous GPU→CPU readback on the emulator thread can miss the
  audio deadline and glitch. Mitigation is dirty-region tracking plus measuring
  before optimising; the risk is real and belongs to Phase C.
- **Render-to-texture ordering.** A game that draws into VRAM and samples it in
  the same frame requires the draw to have landed before the sample. Ordering is
  preserved by the stream, but the Metal backend must not reorder or batch
  across a region it will later read.
- **Batching versus correctness.** Many small draws with differing state are
  slow, but merging them across state changes breaks the ordering guarantee.
  Batch only within a run of identical state.
- **Behavioural leakage.** The sink seam touches `gp0.zig`, which every frontend
  depends on. `trace-golden` is the guard and must stay green in every phase.

## Out of scope

PGXP (its own spec, sequenced after this), texture filtering, widescreen hacks,
24bpp display enhancement, and any change to the software rasterizer's output.
