# Metal renderer Phase B — the backend at 1× — design

**Date:** 2026-08-27
**Status:** approved; one implementation plan, ten tasks
**Parent spec:** `docs/superpowers/specs/2026-08-23-metal-hardware-renderer-design.md`
(§ Architecture, § Semi-transparency, § The feedback loop, § Phases → Phase B)

## Goal

A Metal backend that consumes a recorded GP0 command stream and produces VRAM
**byte-identical** to the software rasterizer at 1×, gated by `.p1fx` fixtures
under `ps1-macos/test.sh`.

Phase B is entirely fixture-driven. Nothing it builds is wired into the running
app; that is Phase D.

## What Phase A2 actually banked, and what it did not

A2 delivered the bridge — `.p1fx`, `FixtureFile`, `ShadowVram`, FNV-1a on both
sides — and seven fixtures. Reading the fixtures back tells a sharper story than
"seven fixtures exist":

| fixture | frames | draw records | other |
|---|---|---|---|
| `croc-legend-of-the-gobbos` | 200 | **0** | 1014 `vram_write_setup`+`_data`, 50 `fill_rect`, 306 `set_draw_env` |
| `pl-render-polygon` | 17 | 18 flat + 6 Gouraud triangles | |
| `pl-render-texture-polygon` | 17 | 48 textured triangles | 34 `latch_texpage`, 4 uploads |
| `pl-render-rectangle` | 17 | 18 rectangles | |
| `pl-render-line` | 17 | 60 lines + 20 shaded lines | |
| `pl-cpu-add`, `pl-hello-world` | 17 | 0 | uploads and a fill |
| `synthetic-movers` | 6 | 0 | 2 fills, 2 copies, 3 uploads, 1 abort |

**The real-game fixture contains no geometry at all.** That is not a defect in
A2: its Task 6 pinned "the densest 200 frames of **A0 payload** in a 600M
instruction run — i.e. where the FMV is", because A2 only ever verified the
memory movers, and it did exactly what it was told. But it means the parent
spec's Phase B gate — "byte-identical … on the PL ROMs **and on real-game
captures**" — has no real-game half today.

Three record kinds are absent from the whole corpus:

- **`draw_textured_rectangle`** — sprites. Every 2D HUD, every font glyph, and
  a large share of what a real game submits. Its texture-window and wrap
  arithmetic differs from the textured *triangle* path (`renderer.zig:503-512`
  wraps `u`/`v` with `+%` on `u8`, the triangle path interpolates and clamps),
  so it is a genuinely separate shader path with no coverage anywhere.
- **`copy_rect`** — only in the committed synthetic fixture, never from real
  software.
- **`vram_read_setup`** — absent, and it does not matter: it moves no pixel and
  Decision 3 serves reads from the shadow.

`trace-golden -- stream-verify` does cover all of these across 23,449 frames of
ten workloads, but that is a *Zig-side* proof that the stream is lossless. It
cannot gate a Metal backend, which runs only under `xcodebuild`.

**Phase B therefore opens by fixing the corpus** (Task 1), before any Metal
exists to confound the result.

## Architecture

### Uniform primitive submission

Every primitive — flat triangle, Gouraud triangle, textured triangle,
rectangle, textured rectangle, and each expanded line pixel — is submitted the
same way: **a bounding-box quad, one instance per primitive**, with the
per-primitive record living in a device buffer indexed by `instance_id`. The
vertex shader expands `vertex_id 0..3` into the box corners and passes the
instance index through.

The fragment shader takes `uint2(in.position.xy)` — `[[position]]` in a
fragment shader is the pixel centre `(px+0.5, py+0.5)`, so the truncation is
exact — and evaluates coverage itself:

- **triangle:** the integer edge functions and top-left bias from
  `renderer.zig:138-182`, recomputed per pixel from the three vertices. No
  incremental state, which is precisely what Phase 0's `interp` doc comment
  was written to guarantee.
- **rectangle:** covered by construction; the box *is* the primitive.
- **line pixel:** a 1×1 box, always covered.

**Metal's own rasterizer is never trusted for coverage.** Its fill rule and
sample positions are not the PS1's, and the disagreement lands exactly on the
degenerate triangles that matter. The GPU rasterizer's only job here is to
generate fragments over a conservative box; the shader decides.

Cost is bounding-box overdraw. PS1 triangles are small, the oversized-primitive
rule already caps any primitive at 1023×511, and the discard is a handful of
integer ops. Measure before optimising.

### Batching falls out for free

Every piece of state a primitive needs — the drawing environment at that point
in the stream, `clut`, `tpage`, colours, the transparency flag — is resolved on
the CPU by the encoder and written into the instance record. **There is no
Metal pipeline state that differs between primitives**, so there is nothing to
break a batch on: a whole run of primitives becomes one instanced draw call.

The only thing that ends a run is a hazard (below). Ordering is preserved
because instances rasterize in submission order.

This is stronger than the parent spec's "batch only within a run of identical
state *and* within a single render pass" — the first clause is vacuous once
state is per-instance data.

### `putPixel` is the fragment shader's tail

`renderer.zig:8-46` is the model, transcribed in order:

1. drawing-area clip (`area_top_left`/`area_bot_right`) and the VRAM bounds
   check → `discard_fragment()`;
2. mask check — E6 bit 1: if the destination's bit 15 is set, discard;
3. blend, if the primitive is transparent, per `color.zig:23-64` — integer
   arithmetic on 5-bit channels with truncating division, **not**
   fixed-function blending, which normalizes to float and rounds differently;
4. bit 15 of the result is the *source* pixel's own bit 15 OR'd with E6 bit 0.

Steps 2-4 need the destination pixel. That is programmable blending: the
fragment function declares the colour attachment as an input,

```metal
fragment ushort ps1_fragment(VertexOut in [[stage_in]],
                             ushort dst [[color(0), raster_order_group(0)]],
                             ...)
```

**The raster order group is load-bearing, not decoration.** Without it, two
instances covering the same pixel are a data race, and the later one may read a
value the earlier one has not yet written. With it, the ordering the PS1's
display list assumes is the ordering the GPU delivers.

The drawing-area clip could be a scissor rect instead — it is exactly a
rectangle — but a scissor is per-encoder state and would break the single
instanced draw. In-shader keeps the batch and matches `putPixel` line for line.

**The oversized-primitive drop stays on the CPU**, in the encoder, as a skipped
instance. It is a refusal to draw, not a clip, and it is judged per triangle
(each quad half separately) exactly as `renderer.zig:123-124` does.

### Lines

`drawLine`/`drawShadedLine` are Bresenham with an error accumulator
(`renderer.zig:300-313`, `:370-379`). No GPU triangle setup reproduces that, and
no closed form for the step→coordinate mapping is worth deriving and proving.

**The Swift encoder walks the same loop and emits one instance per step**, at
most 1024 of them, carrying `k` alongside the coordinate. The per-pixel colour
stays in the shader: `c0 + floor((c1-c0)·k / steps)`, which Phase 0 rewrote from
an f32 accumulator into exactly this form so that a shader could evaluate it
from `k` alone (`renderer.zig:342-345`).

This is a transcription of a twenty-line loop, and it is unit-tested against the
`pl-render-line` fixture, which carries 60 mono and 20 shaded lines.

### The feedback loop, and why pass-splitting is sound

PS1 VRAM is the render target and the texture source simultaneously. The
`R16Uint` texture is bound as `[[color(0)]]` and `read()` at arbitrary
coordinates by the same draw.

**The invariant that makes this legal: nothing sampled during a render pass may
have been written during that pass.** A tile-based GPU holds the tile being
rendered in tile memory and leaves the rest of the attachment in device memory
until the store action runs; a `read()` therefore sees the *pre-pass* contents.
For a region written by an earlier pass that is correct, because that pass
stored. For a region written by an earlier draw in the *same* pass it is stale —
which is exactly what the hazard test forbids.

The encoder tracks the union of what the current pass has written. A draw whose
sampled region — tpage plus CLUT for a textured primitive, the source rect for a
`copy_rect` — intersects that dirty rect **ends the pass and starts a new one**.
Ordering is preserved by construction; pathological content degrades into many
small passes rather than into wrong pixels.

Programmable blending is unaffected: it reads the *same* pixel through tile
memory, which is a different mechanism from sampling an arbitrary address.

**This is the design's one foundational risk and it is checked in Task 3, not
Task 10.** If binding one texture as attachment and read source proves
unreliable in practice, the fallback is a second `.private` texture holding the
last committed VRAM, refreshed by a blit at each pass boundary and sampled
instead of the attachment. That costs bandwidth and complicates Phase C's
render-to-texture story, but it is a substitution behind the same encoder
interface, not a redesign.

### The movers

`fill_rect`, `copy_rect` and the `vram_write_setup`/`_data`/`_abort` FSM must
run on the GPU texture too — at 1× the shadow is authoritative for readback, but
the GPU texture is what the GPU samples, so it has to be complete.

- **`fill_rect` (GP0(02))** — its own pipeline, **deliberately unmasked**:
  hardware ignores E6 for fills, and it *clips* rather than wrapping
  (`vram.zig:183-198`).
- **`copy_rect` (GP0(80))** — masked, wraps both axes, and reverses iteration
  order when the rectangles overlap (`vram.zig:150-181`). A self-overlapping
  copy is a read/write hazard on one resource: it is executed as a blit to a
  scratch texture and back, which makes the direction question disappear
  entirely rather than requiring the reversal to be reproduced.
- **`vram_write_*` (GP0(A0))** — the payload run is uploaded to a staging
  buffer and applied by a pass that respects the E6 mask. The transfer FSM
  (`write_curr_x/y`, the odd-pixel tail, the abort) is CPU-side state in the
  encoder, already transcribed once in `ShadowVram` and reused here.

`ShadowVram` is not scaffolding to be deleted — the parent spec calls these
"Phase B's 02/80/A0 passes, written a phase early". Phase B keeps its FSM and
moves only the pixel writes onto the GPU.

### The gate, and how a failure gets localised

`MetalVram` owns the `R16Uint` `.private` render texture plus a blit-to-buffer
readback, and hashes the result with the existing `Fnv1a` — the same convention
`ShadowVram` already passes. A test drives a `FixtureFile` frame by frame and
compares against the fixture's per-frame hash.

A hash says *that* a frame diverged, never *where*. So `ps1-golden` gains
`stream-capture --dump-frame=<n>`, which writes the reference VRAM for one
frame as a raw 1 MB blob; the Swift side dumps its own on mismatch and the two
diff pixel-wise. Building this in Task 2, before there is anything to debug, is
deliberate — it is worthless to write it while staring at a red frame 137.

### Shader packaging

`build.zig:304-311` compiles one `.metal` to IR and runs `metallib` over it. The
rasterizer is a second source. **Both IRs go into one metallib**: `metallib`
takes several inputs, so the existing single symbol pair keeps working and Swift
keeps making one `MTLLibrary`.

The symbol pair is renamed `ps1_display_metallib_ptr/len` →
`ps1_metallib_ptr/len` (and `DisplayShader.makeLibrary` → `Shaders.makeLibrary`),
because it no longer carries only the display shader. It is not a published ABI —
`Sources/CPs1/include/display_metallib.h` is a local header — so the rename is
three files and a CLAUDE.md line.

## Tasks

Ten, strictly ordered, each with its own gate. The phase gate — byte-identical
full VRAM on every fixture frame — is only meetable at Task 10, which is why
this is one plan and not two phases.

| # | task | gate |
|---|---|---|
| 1 | **Geometry fixtures.** Change `--probe` to report *draw* records, not total; re-measure per workload; pin a geometry window; capture. | fixtures contain triangles, textured rectangles and copies; reproducible byte-for-byte on a second run |
| 2 | **`MetalVram`.** `R16Uint` render texture, blit readback, FNV-1a; second `.metal` merged into the metallib; `--dump-frame`. | a texture round-trips through upload → readback → hash |
| 3 | **The movers as GPU passes.** 02, 80 (via scratch), A0, the abort, E6 semantics. | `synthetic-movers`, all six frames, against the recorded hashes — plus the attachment/read-source probe |
| 4 | **`DrawEnv` in Swift.** E1–E6, `latchPolygonTexpage`, `reset_draw_env`, GP1(09), the offset sign extension. | unit tests mirroring `registers.zig` |
| 5 | **Flat triangles + the whole of `putPixel`.** Edge functions, top-left rule, clip, mask check, blend, STP. | `pl-render-polygon` frame 0 |
| 6 | **Gouraud + dither.** `interp` in the shader, dither at 8-bit scale before the `>> 3`. | `pl-render-polygon`, all frames |
| 7 | **Textured triangles.** 4/8/16bpp, CLUT, texture window, `modulate`, `texel == 0` discard, STP-gated transparency. | `pl-render-texture-polygon` |
| 8 | **Rectangles, plain and textured.** Including the `u8` `+%` wrap the sprite path uses. | `pl-render-rectangle` + a Task 1 geometry fixture |
| 9 | **Lines.** CPU-expanded to per-pixel instances, colour from `k` in the shader. | `pl-render-line` |
| 10 | **Hazard detection, pass splitting, and the closing gate.** | every fixture, every frame, byte-identical; pass-count and frame-time reported on the geometry fixtures |

## Risks

- **Attachment-as-read-source.** The foundational one, checked at Task 3 with a
  named fallback (second texture + pass-boundary blit). Everything downstream
  assumes it holds.
- **A geometry window may not exist inside 600M instructions for every
  workload.** Task 1 measures rather than assumes; if a title's densest window
  is still thin, the budget is raised with `--instructions` or the title is
  dropped from the corpus. What must not happen is pinning a thin window and
  calling it a real-game gate — that is the mistake this phase opens by fixing.
- **Pass-splitting cost.** Unknown until Task 1's fixtures exist to measure it
  on. Do not weaken the hazard test to buy speed.
- **Second transcription.** Phase B *is* a second rasterizer, by necessity, and
  the parent spec accepts it: that is why the byte-exactness gate is per-frame
  and per-fixture rather than eyeballed. The mitigation is that no *third* one
  appears — `ShadowVram`'s FSM is reused, not rewritten.

## Out of scope

- **The live ABI handoff.** No `ps1_take_frame_stream`, no `gpu_sink = .dual`
  for `ps1-capi`, no queue, no frame pacing, no app integration. Adding an ABI
  entry point a phase before it has a consumer ships untested surface; Phase D
  adds it with a live consumer on day one.
- **Any upscaling.** Scale is fixed at 1 throughout. Phase C.
- **24bpp scanout**, which stays on the shadow permanently, and the display
  path generally — Phase B never presents anything.
- **Any change to the software rasterizer's output.** Phase 0 was the only
  phase permitted that, and every fixture hash in the corpus is frozen against
  it.
