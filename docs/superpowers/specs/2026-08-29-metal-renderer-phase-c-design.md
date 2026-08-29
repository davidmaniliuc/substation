# Metal renderer Phase C — internal-resolution upscaling — design

**Date:** 2026-08-29
**Status:** approved; one implementation plan
**Parent spec:** `docs/superpowers/specs/2026-08-23-metal-hardware-renderer-design.md`
(§ VRAM on the GPU, § Semi-transparency, § Frame pacing, § Phases → Phase C)
**Predecessor:** `docs/superpowers/specs/2026-08-27-metal-renderer-phase-b-design.md`

## Goal

Render at an internal resolution of N× while the 1× output stays **byte-identical
to the software rasterizer**, and while the scaled output stays a provably exact
supersampling of it.

Like Phase B, Phase C is entirely fixture-driven. Nothing it builds is wired into
the running app; that is Phase D.

## What the parent spec got wrong about this phase

Two of the parent spec's Phase C statements do not survive contact with where
Phase B actually landed. Both are corrected here rather than worked around.

### The gate as written is unrunnable

The parent spec gates Phase C on a **visual checklist** — "no seams along quad
diagonals", "no texture bleeding", "a display window that wraps the VRAM edge
scans out correctly at scale", "24bpp FMV still correct" — each checked on Croc,
Spyro, Silent Hill and Crash.

But Phase B deliberately deferred *all* app integration to Phase D.
`MetalRasterizer` is unreachable from `ContentView`; nothing it produces ever
reaches a screen, and there is no live command stream to feed it. As written,
Phase C cannot run its own gate.

The corpus makes most of that checklist reachable headlessly instead:
`silent-hill-usa.p1fx` is 100 frames of real gameplay geometry (84,045 draws,
132 textured rectangles, 100 copies) and `tr1-usa-v1-1.p1fx` is 100 more (13,419
draws, 979 textured rectangles). Seams, bleeding and gaps are all visible in an
image of scaled VRAM. **The two genuinely display-side items — the scanout wrap
and 24bpp — move to Phase D**, which is where a display path first exists.

### "Render-to-texture sampled at scale" contradicts the rule above it

The parent spec asserts both:

> Texture *data* is never upscaled. At scale N a texel at `(u, v)` reads subtexel
> `(u·N, v·N)`.

and, in the Phase C checklist:

> render-to-texture content sampled at scale rather than at 1×.

The first rule cannot satisfy the second: reading the top-left subtexel of each
N×N block discards exactly the extra detail a scaled render-to-texture produced.
**The rule wins and the checklist item is struck.** Reading `(u·N, v·N)` at all
three depths is what DuckStation's hardware renderer does, it is exactly today's
code at N=1, and it needs no new interpolation precision. Sampling a CLUT *index*
at a sub-position is not a meaningful operation in any case, so the alternative
would have to be depth-dependent — a second rule, with no oracle for its N>1
result.

One thing is *not* lost to that decision: `ps1_copy_fragment` keeps its subpixel
offset and reads the scaled source, so a VRAM→VRAM blit preserves scaled detail.
The content a game moves around VRAM stays sharp; only the moment it is *sampled
as a texture* is it reduced to native.

## Architecture

### The scaling rule: native records, scaled at point of use

**`Ps1PrimInstance` does not change** — not one field, and the
`sizeof == 4 * 42` static assert holds. Every record stays in native units.

That is the decision the phase hangs on, and it is a testability decision rather
than an aesthetic one: it means the N=1 gate compares literally the same instance
bytes Phase B's tests already pin, so "N=1 is unchanged" is a claim about one
`* 1` in a shader rather than about a rebuilt encoder. It also keeps the two
things that are native *by definition* — the oversized-primitive refusal and the
hazard rectangles — from having to be tracked in a second coordinate space.

A 4-byte `scale` is bound with `setVertexBytes` / `setFragmentBytes` at index 2
(index 0 is the instance buffer, index 1 the upload payload). It is a **runtime**
value, not a function constant or a build setting: one build then runs the whole
gate ladder, and Phase D gets a picker without rebuilding pipelines.

- **`ps1_vertex`** sizes the quad from `box_x0 * s` to `(box_x1 + 1) * s`, and
  the NDC divisors follow the scaled target.
- **Every fragment shader** recovers `nx = px / s`, `ny = py / s`,
  `sub_x = px % s`, `sub_y = py % s`, then multiplies by `s` at point of use:
  the vertices for the edge functions, the drawing-area clip, and the texture
  coordinates.
- **The clip conversion is the likely off-by-one.** The native drawing area is
  *inclusive* `[x0, x1]`, so the scaled test is
  `px < x0 * s || px > (x1 + 1) * s - 1`. Gate 2b exists partly to catch this.

Supported range is N ∈ 1…8. At N=8 the render texture is 8192×4096×2 = 67 MB,
plus the same again for the copy scratch — comfortable on Apple silicon.

### `ps1_interp` widens to 64-bit

At scale the barycentric weights and the area both grow by N², so the numerator
`Σ wᵢ·aᵢ ≤ area · 255` grows by N² too. An oversized-capped primitive
(1023 × 511 native) reaches `area · 255 ≈ 2.13e9` at **N=4** — under int32's
2.147e9 ceiling by about 1%, and over it at N=5.

The cap is therefore raised by widening the intermediate to MSL `long` rather
than by capping N at 4. A supported scale range should be decided by what looks
good, not by an accident of where an overflow lands.

### Two reads that must stay native

- **`ps1_vram_read` linearizes in native space, then scales.** Its
  `y * 1024 + x` row-crossing — a CLUT whose `clut_x + index` runs past 1023
  reads into the *next row* — is a faithful reproduction of `Vram.index`, which
  does no masking. Linearizing at scale would invent a different wrap. So:
  `lin = (ny * 1024 + nx) & 0x7FFFF`, then read
  `((lin & 1023) * s, (lin >> 10) * s)`.
- **A textured rectangle's `u`/`v` wrap is native.** `(nx - x0 + u0) & 0xFF`,
  computed from `nx`, not `px` — the `+%` on `u8` that `renderer.zig:503-512`
  performs is in texel units and has nothing to do with internal resolution.

### The movers at scale

- **Fill (02)** — the box is already VRAM-clamped in native units by the
  encoder, then scaled by the vertex shader. Constant colour, no clip, no mask,
  as before.
- **Upload (A0)** — `pix = (ny - y0) * w + (nx - x0)`. Every subpixel of a block
  resolves to the same payload word, so N×N replication falls out; there is no
  replication code.
- **Copy (80)** — destination wrap stays native (`(nx - x0) & 0x3FF`, and the
  encoder's up-to-four-box split is unchanged), while the source read carries
  the subpixel offset: `scratch[((src_x + xx) & 0x3FF) * s + sub_x, …]`. This is
  the one mover that preserves scaled detail rather than replicating.

### What does not change

`PrimBuilder` and `PrimEncoders` change **zero lines of logic**. Their only edit
is re-pointing `MetalVram.width` / `.height` at new `nativeWidth` /
`nativeHeight` constants, because every clamp they perform — the box clamp, the
line's VRAM bounds check, `wrapRanges`' axis, and the oversized-primitive
refusal — is native by definition.

`HazardTracker` is untouched for the same reason: both the rectangles it
compares are derived from native geometry, and comparing them at scale would
change no answer.

Neither is `ps1-core/src`, `ps1-capi`, `ps1-golden`, `DisplayShader.metal`, or
any app-facing file. **Phase C adds no Zig code at all.**

## The gate

### The exactness property

The backend is **exactly downsample-invariant at every N**: taking the top-left
subtexel of each N×N block reproduces the 1× image byte-for-byte, over the whole
1024×512, on every frame of every fixture.

This is not an approximation to be measured against a tolerance; it follows from
the scaling rule. Scaled subpixel `(p·N, p·N)` evaluates every predicate at
native coordinate exactly `p`:

- **Coverage** — vertices scale by N, the sample point scales by N, so each edge
  function is N²× its native value and its sign is unchanged. The top-left bias
  of −1 still only decides exactly-zero cases.
- **Interpolation** — weights and area both scale by N², and integer division
  satisfies `floor(N²·num / N²·den) == floor(num/den)`. Exact, not approximate.
- **The clip and the mask check** — both are predicates on the sample position
  and the destination pixel.
- **The texel fetch** — `(u·N, v·N)` is the block's top-left subtexel, which by
  induction holds the native texel.
- **The blend destination** — read through `[[color(0)]]` at the same subpixel,
  which by induction holds the native destination.
- **The copy source** — at the top-left subtexel `sub_x` and `sub_y` are both 0,
  so the scratch read lands on the source block's own top-left, which by
  induction holds the native source pixel. The subpixel offset that makes a blit
  preserve scaled detail is exactly the term that vanishes here.

Induction runs over the frame from a blank VRAM, which is the fixture format's
own starting rule. Subpixels other than the top-left may legitimately differ
from their block's native value — that is what supersampling *is* — and
downsampling discards them.

**Dithering is the single exception**, and it is deliberate: it is disabled
above 1× (§ Dithering below).

### The ladder

The corpus is **eleven fixtures**: the nine `allGeneratedFixtures` in
`MetalRasterizerTests.swift` (six PL ROMs, Croc, Silent Hill, TR1) plus the two
committed synthetics.

| # | gate | scope |
|---|---|---|
| 1 | **N=1 unchanged.** Metal == Zig, full 1024×512. | Phase B's gate, re-run verbatim: all eleven fixtures, every frame |
| 2 | **Downsample-invariance.** `readbackNative()` at N == full VRAM at N=1, byte-for-byte, dither forced off on both sides. | N ∈ {2,3,4,8}, all eleven fixtures, every frame — ~400 frames of real Silent Hill and TR1 gameplay, all seven primitive kinds, all three movers |
| 2b | **Bounds and density.** Nothing is written outside `box*s` or outside `clip*s`; and the covered-pixel count at N is within `perimeter · s` of `N² ×` the 1× count, where `perimeter` is the 1× count's boundary length. | `synthetic-primitives` frames 0 (flat triangles), 3 (rectangles), 5 (lines), each replayed from blank |
| 3 | **Images.** `PS1_DUMP_SCALED=<N>` writes PNGs of chosen Silent Hill and TR1 frames at 1× and N. | eyeballed for seams, texture bleeding, gaps between adjacent primitives |
| 4 | **Cost.** Wall-clock per fixture at N = 1/2/4/8, printed. | the N² bounding-box overdraw measured rather than assumed |

**N=3 is in Gate 2 on purpose.** `px / s` and `px % s` compile to shifts and
masks at every power of two, so a whole class of mistake — writing `>> log2(s)`,
or assuming `s` divides some extent — is invisible at 2, 4 and 8 and fires at 3.
It costs one more pass over the corpus.

Gate 2 needs **no new fixtures and no Zig changes**, which is why it is available
at all: the corpus Phase B built for a different purpose already covers every
code path this phase touches.

Gate 2b is not redundant with Gate 2. Gate 2 constrains only the top-left
subtexel of each block, so a bug that left every *other* subpixel black would
pass it and look catastrophic. Gate 3 would catch that by eye; Gate 2b catches it
mechanically.

Gate 1 is a **freeze**: a moved fixture hash is a bug in this phase, never a
baseline to update. Phase 0 was the only phase permitted to change output.

## Dithering

The shipping rule is the parent spec's: **on at 1×, off above it**, decided in
the shader as `dither = (flags & PS1_PRIM_DITHER) && scale == 1`.

It is decided in the shader and not on the CPU on purpose. Clearing the flag in
`PrimBuilder` would make the instance record differ between N=1 and N>1 and
forfeit the property § The scaling rule exists to buy.

The 4×4 table is indexed by the *scaled* pixel when it runs, so at N=1 — the
only case where it runs — this is exactly today's `ps1_dither(px, py)`.

Dither is the one thing that breaks exactness, so **Gate 2 runs with dithering
forced off on both sides** via a debug flag on the rasterizer. That does not
weaken it: Gate 1 already checks the dithered 1× output against Zig, per frame,
per fixture.

Note the two live alternatives, neither taken: indexing the table by *native*
coordinates would preserve exactness but produce an N× coarser, more visible
pattern; indexing by scaled coordinates with dithering left on would look finer
than either but forfeits the gate. Off is the parent spec's decision and stands.

## New surfaces

- **`MetalVram(device:queue:scale:)`** — `nativeWidth`/`nativeHeight` as
  statics, `width`/`height`/`scale` as instance properties. `readback()` returns
  the scaled image; **`readbackNative()`** downsamples by taking each block's
  top-left subtexel, and **`nativeHash`** hashes that. `hash` stays the full
  texture, identical to today's at N=1.
- **`uploadNative(_:)`** — a 1× image replicated N×N into the scaled texture.
  This is the resync path the parent spec's § Frame pacing requires on queue
  overflow or a stream-buffer overflow. It is built here, where it is a scale
  concern and headlessly testable (upload → `readbackNative()` round-trips; every
  block is uniform), and consumed in Phase D. CPU-side replication into the
  existing staging buffer is sufficient — the path is rare by construction.
- **`VramImage.swift`** — ABGR1555 → PNG via ImageIO, for Gate 3.
- **`MetalScaleTests.swift`** — Gates 2, 2b and the `uploadNative` round trip.
- **`ps1_interp`** — `long` intermediates.

## Tasks

Six, strictly ordered. Unlike Phase B, most tasks here carry a gate that is
meetable on the spot, because Gate 2 applies to whatever subset of the corpus
already works — the fixtures are not a ladder of features this time, they are one
property checked at every N.

| # | task | gate |
|---|---|---|
| 1 | **Scale-aware `MetalVram`.** `nativeWidth`/`nativeHeight` statics, instance `width`/`height`/`scale`, `readbackNative()`, `nativeHash`, `uploadNative()`. Re-point `PrimBuilder`/`PrimEncoders` at the native constants. | `uploadNative` → `readback` round-trips with every N×N block uniform; `readbackNative` recovers the original; Gate 1 still green at N=1 |
| 2 | **The `scale` uniform and `ps1_vertex`.** Quad sized `box*s`, NDC divisors follow, `setVertexBytes`/`setFragmentBytes` at index 2. | Gate 1 unchanged; at N>1 the drawn region is `box*s` — Gate 2b's bounds half |
| 3 | **`ps1_prim_fragment` at scale.** `nx`/`ny`/`sub_x`/`sub_y`, vertices and clip scaled, `ps1_interp` widened to `long`, dither gated on `scale == 1`. | Gate 2 on the synthetics and PL ROMs; Gate 2b in full |
| 4 | **The samplers at scale.** `ps1_vram_read` linearizing natively then scaling; `ps1_fetch_texel` at `(u·N, v·N)`; the sprite path's `u8` wrap from `nx`. | Gate 2 additionally on `pl-render-texture-polygon` and the geometry fixtures |
| 5 | **The movers at scale.** Upload from native indices; copy carrying `sub_x`/`sub_y` against the scaled scratch. | Gate 2 on `synthetic-movers` and Croc — the pure-mover fixtures, where replication is the whole behaviour |
| 6 | **Images and cost.** `VramImage.swift`, `PS1_DUMP_SCALED`, the per-N timing print. | Gate 2 across all eleven fixtures at N ∈ {2,3,4,8}; Gates 3 and 4 produced and read |

## Risks

- **The clip's inclusive-bound conversion.** `[x0, x1]` native becomes
  `[x0·s, (x1+1)·s − 1]`, and the plausible wrong answer (`x1·s`) is wrong by
  `s−1` pixels on two edges of every primitive — invisible at N=1, where it is
  correct, so Gate 1 cannot see it. Gate 2b is aimed at this.
- **Fill rate.** The bounding-box overdraw Phase B accepted deliberately costs N²
  more fragments, and it has never been measured at any N. Gate 4 measures it. If
  N=8 is not viable the answer is to cap the shipped range in Phase D, not to
  weaken the hazard test — the parent spec's standing instruction.
- **Readback volume in the gate.** Gate 2 reads back 67 MB per frame at N=8
  across ~400 frames of the two geometry fixtures alone. If that makes the suite
  too slow to run habitually, the fallback is to narrow **N=8 only** to the
  synthetics and the PL ROMs, keeping N ∈ {2,3,4} across the full corpus. What
  must not be dropped is N=3 (§ The ladder) or the geometry fixtures, which are
  the only real-game coverage there is.
- **Exactness proves containment, not sanity.** The property says the scaled
  image *contains* the 1× image at its top-left subtexels. It says nothing about
  the other N²−1. Gates 2b and 3 exist for that, and the phase is not done on
  Gate 2 alone.

## Out of scope

- **Everything display-side** — the scale-aware scanout wraps
  (`& (1024N−1)` / `& (512N−1)`), 24bpp scanout staying on the shadow, and
  `DisplayShader.metal` generally. Phase D, where a display path first exists.
- **The live ABI handoff**, the bounded stream queue, drain-all/present-newest
  pacing, app wiring and the scale picker. Phase D.
- **Render-to-texture sampled at scale** — struck, see § What the parent spec got
  wrong. Sampling reads the block's top-left subtexel at every depth.
- **Texture filtering, widescreen hacks, PGXP.** Out of scope for the whole
  renderer spec, not just this phase.
- **Any change to the software rasterizer's output**, and any change to
  `ps1-core/src`, `ps1-capi` or `ps1-golden` at all.
