# True Colour Rendering — design

**Date:** 2026-09-12
**Status:** design approved, plan not yet written
**Scope:** the macOS Metal renderer only. No Zig changes, no golden moves.

## The problem

Reported as "the shadows look far rougher than DuckStation" on Crash
Bandicoot's sand. `eb766d3` answered the first half of that — the fragment
shader gated dithering on `s == 1`, so above 1x a Gouraud ramp went through
`ps1_pack`'s `>> 3` with nothing to break up the steps — and it was not
enough. The residual is not a dithering defect. It is the ceiling dithering
works under.

| | us | DuckStation |
|---|---|---|
| VRAM render target | `.r16Uint` (`MetalVram.swift:58`) | `RGBA8` (`gpu_hw.cpp:48`) |
| levels per channel | 32, at every internal resolution | 256 |
| shipped dithering default | `.scaled` (on) | **off** (`settings.h:230`) |

DuckStation's smoother gradient is not a better dither. It ships with
dithering off entirely and renders at eight bits per channel; its 5-bit
truncation is emulated in the shader and applied only when true colour is off
(`gpu_hw.cpp:3448`, `gpu_hw_shadergen.cpp:2479`). Ours is the storage format.
Every fragment passes through `ps1_pack`'s `>> 3` into a 16-bit texture, so a
Gouraud ramp has 32 stops whatever the scale.

**Dithering redistributes quantisation error. It cannot add levels.** No
further work on the dither table or its index can close this gap.

## What we may not do

`MetalVram.swift:7-13` states the constraint the renderer hangs on:

> R16Uint and NOT RGBA8 is the decision the whole renderer hangs on. PS1 VRAM
> is simultaneously framebuffer, texture memory and CLUT storage: a game draws
> into it and then samples the result as 4bpp, 8bpp or 16bpp indexed data.
> Storing decoded colour destroys the bit patterns texture sampling depends
> on, and hides bit 15.

DuckStation pays exactly that price and can afford to, because it has no
byte-exact software rasterizer to stay equal to. We have three gates that read
VRAM and require it to be bit-exact: Gate 1's fixture hashes, Gate 2's
downsample-invariance, and `PS1_LIVE_DIFF`'s per-frame equality against the
core's software VRAM. Adopting `RGBA8` for VRAM surrenders all three.

## The architecture: a display-only sidecar

VRAM stays `.r16Uint` and stays the authority. Beside it sits a second scaled
texture, `RGBA8`, holding the eight-bit colour of every pixel a draw has
touched.

- **Written** by the same fragment shader invocation, in the same render pass,
  as a second colour attachment. Never its own pass.
- **Read** by the display shader, and by the blend path for its background.
- **Never** sampled as a texel, never read back by the game, never hashed by a
  gate, never compared by `PS1_LIVE_DIFF`.

Three consequences follow, and they are the whole argument for this shape.

**Texel fetch stays bit-exact.** DuckStation samples indexed texture data out
of its `RGBA8` target and converts back down, so its textures are sampled from
the true-colour picture. Ours keeps reading `r16Uint`. On this axis the
sidecar is more accurate than the reference, not less.

**Every gate survives untouched.** All three read VRAM, and VRAM is unchanged
in every mode. No hash can move, so true colour needs no gate exemption and no
opt-in switch file — unlike `.scaled` dithering, which knowingly trades Gate 2
above 1x.

**True colour can therefore be the default at every scale, 1x included.**
DuckStation must rebuild pipelines when this setting changes and gives up
bit-exactness to get the smoothness. We give up neither.

### Why a full eight-bit picture and not a residual

The cheaper shape — store the low three bits per channel in an `r16Uint`
sidecar and reconstruct as `vram << 3 | residual` — was considered and does
not survive blending. A 5-bit blend is not the truncation of an 8-bit blend;
`ps1_blend`'s integer halving differs from the same operation at eight bits by
up to an LSB per layer. After one transparent draw the two representations no
longer reconstruct each other, and the residual encoding has no way to say so.

A full parallel picture has no such constraint. VRAM keeps the hardware-exact
5-bit blend; the sidecar keeps the 8-bit one; the two are *permitted* to drift
sub-5-bit because nothing compares them. Drift in a picture nothing measures
is not a defect.

### Presence

The sidecar's alpha channel is the per-pixel presence flag: 255 where the
sidecar holds a real eight-bit colour, 0 where it does not. Absent pixels fall
back to VRAM expanded as `c << 3 | c >> 2`, which is exactly today's picture —
so every invalidation degrades to the current behaviour rather than to a
visible defect.

Per-pixel presence in a channel we already have, rather than CPU-side dirty
rectangles: it costs no bookkeeping, cannot go stale, and is exact at rect
boundaries. DuckStation needs two dirty rectangles (`m_vram_dirty_draw_rect`
and `m_vram_dirty_write_rect`) to tell GPU-drawn regions from CPU-written
ones; the alpha channel answers the same question per pixel, for free.

## Coherence rules

The invariant, stated once:

> For every VRAM pixel, the sidecar either holds the eight-bit colour whose
> five-bit truncation that VRAM pixel is, or is marked absent.

Every path that mutates VRAM must maintain that or invalidate. The complete
set of paths, from `command.Kind` plus the two resync entry points:

| Path | Sidecar action |
|---|---|
| `draw_triangle`, `draw_shaded_triangle`, `draw_textured_triangle`, `draw_rectangle`, `draw_textured_rectangle`, `draw_line`, `draw_shaded_line` | **Maintain.** Shade in eight bits, write VRAM at five (unchanged, hardware-exact) and the sidecar at eight, alpha 255. |
| `fill_rect` (GP0 0x02) | **Maintain.** A flat 5-bit colour expands exactly, so write the expansion, alpha 255. Fill stays unmasked — that rule is unchanged. |
| `vram_write_data` (GP0 0xA0) | **Invalidate.** The payload is genuine 5551 from the game; no extra precision exists. Alpha 0 across the destination. |
| `copy_rect` (GP0 0x80) | **Carry.** Copy the sidecar alongside VRAM, alpha included, in the *same* shader pass. An absent source yields an absent destination and the invariant carries itself. |
| `vram_read_setup` (GP0 0xC0) | **None.** Reads VRAM only. The sidecar must never influence what the game reads back. |
| `set_draw_env`, `latch_texpage`, `set_texture_disable_allowed`, `reset_draw_env`, `vram_write_setup`, `vram_write_abort` | **None.** No VRAM pixel changes. |
| `LiveRenderer.uploadNative` (resync from a software frame) | **Invalidate whole.** The incoming picture is 5551 with no extra precision. |
| `MetalVram.clear` | Alpha 0 everywhere. |

Two rules that are easy to get wrong and cost a pass each:

**The copy must be one pass, not two.** VRAM→VRAM copies handle wrap-around at
the VRAM edges and self-overlap; DuckStation chunks an overlapping copy by
rows (`gpu_hw.cpp:3660`) precisely because the ordering is observable. A
sidecar copied in a second pass can resolve an overlap differently from the
VRAM copy beside it, and the two pictures then disagree about which source row
won. One pass, two attachments, one ordering.

**The mask bit belongs to VRAM alone.** A check-mask rejection discards the
fragment, so neither attachment is written and there is no special case. A
set-mask write writes both. The sidecar has no bit 15 and needs none — its
alpha is presence, not mask.

### Blending

The blend path reads the sidecar for its background where present, and the
`c << 3 | c >> 2` expansion of VRAM where absent. It then writes the
hardware-exact five-bit result to VRAM and the eight-bit result to the
sidecar. This is what carries precision across a composite: fog layers,
additive transparency and overlays stop re-quantising at every layer.

`ps1_blend` gains an eight-bit sibling rather than being replaced — VRAM's
value must keep coming from the existing five-bit integer expression, because
that is what `PS1_LIVE_DIFF` and `renderer.zig` agree on.

## The setting

One enum, as DuckStation does it. Its six modes collapse to four for us:
`UnscaledShaderBlend` and `ScaledShaderBlend` exist because DuckStation
sometimes blends via fixed-function and needs a shader path for accuracy, and
we already read the background in the fragment shader unconditionally.

```
.off        5-bit, no dither        — what Gate 2 has always run at
.native     dither per native pixel — downsample-invariant
.scaled     dither per subtexel     — today's default
.trueColor  8-bit, no dither        — new, and the new default
```

`DitherMode` gains a case rather than a second setting appearing beside it:
true colour and dithering are mutually exclusive by construction — DuckStation
asserts exactly that (`gpu_hw_shadergen.cpp:2166`) — and two controls that
cannot both be on is a control that silently no-ops, which the PGXP sub-setting
work already ruled against.

The menu is `Video ▸ Dithering`, four entries. `DitherMode` is a runtime
uniform on an already-built pipeline, so it continues to ride `updateNSView`
down to `LiveRenderer` and stays out of `ContentView`'s `.id()`.

### The flat-colour carve-out

DuckStation distinguishes `TrueColor` from `TrueColorFull` in exactly one
place: `ShouldTruncate32To16` (`gpu_hw.cpp:167`) still truncates draws that are
untextured, unshaded *and* undithered — flat-colour polygons — back to sixteen
bits, with per-game traits overriding it both ways. It is a compatibility
carve-out for games that depend on flat fills landing on exact five-bit values.

We adopt the carve-out and not the second menu entry: a flat untextured
undithered draw writes the expanded five-bit colour to the sidecar, which is
what it would have written anyway. There is nothing to see and nothing to
choose until a game asks for it.

## Gates

Nothing existing changes, which is the point.

- Gate 1 fixture hashes, Gate 2 downsample-invariance and `PS1_LIVE_DIFF` all
  read VRAM. They must stay green in every mode, at every scale, unmodified.
  That is the primary assertion of this phase: **a rendering change that moves
  no hash.**
- New: `theSidecarIsAbsentWhereVramWasUploaded` — an upload over a drawn region
  leaves alpha 0 across exactly the destination rect.
- New: `aCopiedGradientKeepsItsPrecision` — a gradient drawn, copied, and read
  back from the sidecar matches the source region.
- New: `trueColourAndDitheringAreMutuallyExclusive` — the shader never applies
  a dither offset in `.trueColor`.
- New: `theSidecarNeverReachesTexelFetch` — a textured draw sampling a region
  drawn in true colour produces the same VRAM bytes as in `.off`.
- Gate 3 (`PS1_DUMP_SCALED`) gains `.trueColor` so the banding is inspectable
  by eye against `.scaled` on the same frame.

## Milestones

1. **Draws only.** The sidecar texture, the second attachment, the display
   read, the four invalidation rules, the setting. Blending still reads VRAM
   and expands. This fixes Crash's sand — a single Gouraud ramp — which is the
   reported case.
2. **The blend path.** Eight-bit background, eight-bit blend, precision across
   a composite.

Milestone 2 is deliberately gated on evidence: before building it, confirm one
scene that bands *because of* layered blending. Most PS1 "fog" is GTE depth
cueing baked into vertex colour, which is a single Gouraud draw and already
fixed by milestone 1. The second case is assumed to exist because later
hardware composites that way; that is not evidence that PS1 titles do.

## Cost

| scale | VRAM (`r16Uint`) | sidecar (`RGBA8`) | copy scratch, both |
|---|---|---|---|
| 1x | 1 MB | 2 MB | 3 MB |
| 3x | 9 MB | 18 MB | 27 MB |
| 8x | 67 MB | 134 MB | 201 MB |

8x is the extreme and doubles an already-large allocation. 2x–3x, where most
players sit, is single-digit to low-double-digit megabytes.

## Out of scope

- PGXP Phase 3 (perspective-correct texturing). Independent: that one is about
  texture *coordinates*, this one about colour *precision*. Its design is
  drafted through §2 and resumes after this.
- DuckStation's downsampling modes (`Box`, `Adaptive`).
- Texture filtering. A separate feature that interacts with this one only in
  that both make a gradient smoother.
- Any change to the software rasterizer, `ps1-core`, or the C ABI.

## Provenance

DuckStation was read for behavioural facts only — which VRAM paths exist, what
coherence each owes, what its defaults and mode semantics are. The sidecar
architecture has no counterpart there: DuckStation's VRAM *is* `RGBA8`, which
is the approach this design rejects. Its licence is CC BY-NC-ND and no code
was adapted.
