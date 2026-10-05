# Metal renderer performance: design

Date: 2026-10-05. Status: approved in conversation; spec under review.

## Goal

Raise the internal resolution a player can actually play at. Today the
ceiling on the reference machine (MacBook Air M1, 7-core GPU) is 4x: Crash at
4x costs ~15-16 ms of GPU per frame live, which leaves ~20% headroom at 50 Hz
and caps fast-forward at ~60-70 fps.

- **Primary:** Crash and Silent Hill run at full speed (50/60 fps, every frame
  rendered) with headroom at **6x**. **8x** is the stretch goal.
- **Secondary:** more headroom at 4x, which is also the fast-forward ceiling.

Every change keeps the renderer **byte-exact** with the software rasterizer
(option A in the conversation). A non-exact fast renderer in the DuckStation
style (`gpu_hw.cpp` draws through fixed-function triangle setup and is checked
against nothing) is a possible later spec, decided once this one has measured
what exactness costs.

## Where the cost is (measured 2026-10-05)

Throwaway replay test, Debug host, CPU encode and GPU overlapped, ms/frame:

| fixture | 1x | 4x, player settings (true colour, bilinear) | 4x, nearest |
|---|---|---|---|
| `crash-bandicoot-warped` (~890 draws/frame, max 2,102) | 6.0 | 12.4 | 9.8 |
| `silent-hill-usa` | 6.1 | 14.5 | 11.5 |

- Render passes per frame: Crash **1.01**, Silent Hill 2.67. Crash has **no**
  VRAM->VRAM copies in the window. Pass breaks and the whole-texture copy
  snapshot are not Crash's cost.
- 1x is ~6 ms in Debug: CPU frame building, since 1x GPU work is small. The
  Release figure is unknown and is the first thing the benchmark measures.
- What 4x adds is fragment work. Bilinear alone is +27% on Crash at 4x.

The structural reasons, read from `Rasterizer.metal` and `MetalRasterizer.swift`:

1. **Bounding-box quads.** `ps1_vertex` emits each primitive's inclusive box;
   `ps1_triangle_coverage` discards everything outside the triangle. A typical
   triangle fills about half its box, a thin diagonal one far less, and at
   scale `s` every wasted native pixel is `s*s` wasted invocations.
2. **One uber-shader.** `ps1_prim_fragment` branches on `p.kind`, the dither
   mode, true colour, the filter and the perspective flags. Register allocation
   is sized for the heaviest path (perspective-correct, bilinear, eight-bit
   blend) for every fragment, which lowers occupancy for the light ones.
3. **Framebuffer fetch everywhere.** Every invocation declares `dst`,
   `dst_side` and `dst_depth`, including opaque, unmasked, depth-off draws that
   do not need them.
4. **The bilinear filter** does four `ps1_window_fetch` calls, each with its
   own CLUT read.

## Units

### 0. The benchmark (lands first, gates everything after it)

An env switch read by the APP, like `PS1_LIVE_DIFF`: launching the app with
`PS1_GPU_BENCH=<fixture>[,<fixture>...]` replays each fixture from
`zig-out/fixtures/` at 1x, 4x, 6x and 8x under the player's current settings
(dither mode, texture filter, sprite filter, read from `UserDefaults`), prints
one line per (fixture, scale) and exits. It runs in the **Release** app because
tests cannot be built in Release (the module has no testability there), and
because the Debug Swift encode cost is not what players pay.

Each line reports:

- **GPU ms/frame:** the sum of `gpuEndTime - gpuStartTime` over the frame's
  command buffers, taken with each frame waited on (`synchronous = true`) so
  frames do not overlap and the figure is per-frame cost, not a throughput
  artefact. (Live, overlapping buffers summed to 1.5-1.8 s per second, which is
  why overlap must be excluded.)
- **CPU ms/frame:** wall time of `beginFrame` + `apply` + `endFrame` encode.
- **Throughput fps:** a second, pipelined run (`synchronous = false`), which is
  the number a player sees.

`MetalRasterizer` gains one optional completion hook so the benchmark can read
GPU timestamps; nothing else in the renderer learns about benchmarking.

**Corpus:** `crash-bandicoot-warped` (captured 2026-10-05 at instructions
500M-700M), `silent-hill-usa`, `tr1-usa-v1-1`, and a new Crash 1 gameplay
window captured with a pad script (`stream-capture --input=...`). Fixture
format version 2 copies are stale (`badVersion(2)`) and must be recaptured,
never patched.

**Method:** best of five per configuration, with A and B builds interleaved
(A, B, A, B) on one machine after it has settled, as the existing Gate 4
tables already require. Compare columns within one session's table only, never
across sessions.

### 1. Triangle geometry instead of the bounding box

`ps1_vertex` emits a triangle's own three vertices for the three triangle
kinds (flat, Gouraud, textured), pushed outward by a conservative margin and
then clamped to the existing inclusive box, so the generated fragment set is
a subset of today's and a superset of the covered set.

- **The margin** is one native pixel along each edge's outward normal (in
  scaled space, `s` subpixels), plus the same `+1` inclusive far edge the box
  has. Coverage is still decided by `ps1_triangle_coverage` alone; the
  geometry only has to generate every fragment that could pass, so a margin
  that is too generous costs speed and never correctness, and one that is too
  tight is caught by the test below.
- **Degenerate and near-degenerate triangles** (zero area, slivers under 1.5
  native px^2) fall back to the box: the margin computation on a degenerate
  edge has no stable normal, and those primitives are cheap anyway.
- **Rectangles, fills, uploads, copies and depth clears stay boxes**: for them
  the box *is* the primitive. Lines stay boxes in this spec.
- The instance record is unchanged: the vertex shader already has `x0..y2` and
  the sub-pixel `qx0..qy2`. The draw becomes 3 vertices (triangle) or 4 (strip)
  per instance, which means separate draw calls for triangle and box kinds
  within a run. Order is preserved because runs stay in record order.

### 2. Specialised pipelines by function constant

`ps1_prim_fragment` becomes one source compiled into variants through Metal
function constants:

- **Primitive class:** flat triangle, Gouraud triangle, textured triangle,
  rectangle, textured rectangle, line, shaded line.
- **Filter: NOT a variant axis.** Which filter a textured primitive follows is
  `ps1_is_sprite`'s per-primitive decision in the shader, and moving it to the
  CPU would be a second implementation of that classifier. It stays a runtime
  branch inside the textured variants; unit 3 is where the filter gets cheaper.
- **Colour mode:** the three dithering modes vs `.trueColor`.
- **Destination read:** whether the variant reads `dst`/`dst_side`/`dst_depth`
  at all. A draw needs it if it is semi-transparent, mask-checked, or the depth
  buffer is on; otherwise its outputs do not depend on the destination and the
  variant declares no framebuffer inputs.

`PrimBuilder` already emits `.draw(kind, range)` runs; a run now breaks
wherever the variant changes. Records are unchanged, and the uniforms remain
the single source of the player settings. Pipelines are built once per
`MetalRasterizer` (the number of combinations is bounded and small), never per
frame.

### 3. Cheaper bilinear

Inside the bilinear path only, so VRAM, the hole, STP and the nearest texel are
untouched:

- When the four sample texels resolve to the same texel (magnification inside
  one texel, or every limit collapsed), take the nearest texel's colour and skip
  three fetches.
- Fetch each distinct VRAM word once and resolve the CLUT once per distinct
  index.

Bilinear output must stay bit-identical to today's sidecar (`T` per channel in
1/8 five-bit steps, renormalised hole weights). This is a pure refactor of an
existing function with its tests unchanged.

### 4. CPU frame building (conditional)

Only if unit 0 shows the Release CPU encode is a ceiling for fast-forward at the
target scales: profile `PrimBuilder` / `MetalRasterizer.apply` with xctrace and
fix what it shows. No design is committed here in advance.

## What does not change

- No record, no `Ps1PrimInstance` field, no uniform layout
  (`static_assert(sizeof(Ps1PrimInstance) == 4 * 54)` and the 16-byte
  `Ps1RasterUniforms` stay where they are).
- The sidecar, the depth plane, `HazardTracker`, the snapshot copy, the
  scanout and every rule in `ps1-gpu-metal` stay as they are.
- `.trueColor` keeps writing VRAM exactly as `.off`.

## Testing

Existing gates, unchanged, run on every step: Gate 1 (fixture replay against
the software rasterizer), Gate 2 (downsample-invariance at N in {2, 3, 4, 8}),
`theCorpusRendersIdenticalVramInTrueColourAndOff`,
`theCorpusRendersIdenticalVramUnderEverySetting`, the PGXP-on parity fixture
and the whole Swift suite.

New:

- **Unit 1:** `theTriangleHullPaintsExactlyWhatTheBoxPainted`. Replays the
  whole corpus at s in {1, 2, 3, 4, 8} twice, once with the box path forced and
  once with the hull, and requires the FULL scaled VRAM, sidecar and (with the
  depth buffer on) depth to be byte-identical. Full, not `readbackNative()`:
  the corner-only view is the scaled path's known blind spot, and a hull that
  is too tight drops interior subtexels first. Forcing the box path is a
  test-only switch on `MetalRasterizer`.
- **Unit 1:** a hand-built thin diagonal triangle and a near-degenerate
  sliver, asserted identical between hull and box at every scale, so the
  margin is pinned by something smaller than a whole frame.
- **Unit 2:** the same full-VRAM equality between the uber-shader and the
  specialised variants over the corpus, under every combination of dither
  mode x filter x sprite filter x depth on/off. The uber-shader stays
  compiled (as the reference this test compares against) until the test has
  passed in two consecutive full-suite runs, and is deleted in a commit of its
  own after that.
- **Unit 3:** the existing filter tests plus a full-sidecar equality over the
  corpus at 4x with bilinear on, old function against new.

## Success measure

Reported per step in the benchmark's format and recorded in `ps1-gpu-metal`:
GPU ms/frame for Crash and Silent Hill at 4x, 6x and 8x, before and after.
Today's anchor (Debug replay, pipelined): Crash 12.4 ms and Silent Hill
14.5 ms at 4x with player settings. The spec is done when units 1-3 are each
landed or reverted with a measured reason, and unit 4 is either done or shown
unnecessary. Whether 6x reaches full speed with headroom is reported, not
promised.

## Out of scope

- Skipping draws for frames that will not be presented (fast-forward); its own
  spec.
- A non-exact fast renderer.
- Emulator-core CPU cost.
- Line geometry tightening.
