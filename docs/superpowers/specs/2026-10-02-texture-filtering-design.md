# Texture Filtering — design

**Date:** 2026-10-02
**Status:** design approved in chat; awaiting spec review
**Scope:** the macOS Metal renderer and its Settings. No Zig changes, no golden
moves, no `.p1fx` change.

## The problem

At 4x and 8x a magnified texture is a grid of hard-edged squares: every
subtexel of a textured triangle fetches the texel `floor(u), floor(v)`. This
is the most visible difference left between Substation and DuckStation at the
scales players pick, and DuckStation's Texture Filtering is the enhancement its
users actually turn on.

## What we may not do

Exactly what the true-colour sidecar could not do (see
`2026-09-12-true-colour-rendering-design.md`): VRAM is `.r16Uint`, it is the
authority, and Gate 1, Gate 2 and `PS1_LIVE_DIFF` all require it bit-exact
against the software rasterizer. A filtered colour is not a value the console
can produce, so it may never reach VRAM.

## The architecture: filtering is a SIDECAR-ONLY effect

VRAM is written exactly as today, from the nearest texel. The filtered colour
goes to `color(1)` only. Nothing a gate reads can move, by construction, and
one test asserts it over the whole fixture corpus.

What stays decided by the NEAREST texel, in every mode:

- the VRAM value (`out`), including its modulation, dither and mask bit;
- the hole (raw texel 0 discards the fragment), so silhouettes do not change;
- the STP bit, so whether the pixel is semi-transparent does not change.

The price: a cut-out sprite or foliage edge stays nearest-pixel-shaped at
8x. Softening it is a separate, follow-up mode (below), not an impossibility:
at a hole pixel the fragment can write `dst` back to VRAM unchanged (exactly
what a discard leaves) and still write a blended colour to the sidecar.

### Scope

- **Textured TRIANGLES only.** Textured rectangles (HUDs, text, 2D sprites)
  stay nearest, which is DuckStation's default for its separate sprite
  setting. A sprite option is a later, separate change if anyone asks.
- **Bilinear only.** DuckStation's list also has JINC2, xBR, Scale2x/3x and
  three MMPX variants. Each one is a different kernel over the same fetch
  and the same sidecar rule, so the enum leaves room for them, but none is
  built here.
- **This is DuckStation's "Bilinear (No Edge Blending)", and the picker says
  so.** Their plain "Bilinear" blends alpha into cut-out edges. That is the
  NEXT spec, built on this one: alpha-weighted filtering plus a sidecar-only
  write at hole pixels (VRAM gets `dst` back, so the gates still hold). It
  gets the plain "Bilinear" label when it lands.
- **Independent of true colour, as in DuckStation.** There, True Color is a
  separate checkbox and filtering works with it on or off, because their VRAM
  is RGBA8. Here, true colour is one of the Dithering modes, so filtering has
  to define its result in all four (the per-mode table below).
- **Ships OFF** (Nearest), matching DuckStation's default.

## Fractional texcoords, without moving the integer one

`iu`/`iv` are truncated interpolants today. Interpolate `a_i << 6` through the
SAME `ps1_interp_attr` instead:

    U6 = ps1_interp_attr(tex_persp, ..., p.u0 << 6, p.u1 << 6, p.u2 << 6, ...)
    iu = U6 >> 6

For non-negative values `floor(floor(64x) / 64) == floor(x)`, so `iu` is
exactly today's value on both the affine and the perspective path, and it
replaces the existing interpolant rather than adding one. Six bits is the
bound: `ps1_interp_w`'s numerator reaches 2^55 with an 8-bit attribute, so a
14-bit one reaches 2^61, inside `long`. The affine path's numerator is
`w * a` with `w <= area`, far below that. Both bounds go in the comment beside
the call.

That interpolant is taken at the subtexel CORNER, the native sample point,
and stays the nearest texel: VRAM, the hole and STP read `iu` and nothing
else. The FILTER takes a second, bilinear-only interpolation of the same
`a_i << 6` at the subtexel CENTRE, `q = ((2 * px + 1) * 16) / (2 * s)`. At the
corner a 1:1-mapped polygon at 1x samples every texel on its corner and
blurs a 2x2 block half a texel up and to the left; at the centre it filters to
the nearest texel exactly, as DuckStation's does.

Sample positions are texel CENTRES: `Uc = U6c - 32`, base texel
`floor(Uc / 64)` (a floor, since `Uc` can be negative), weight `Uc & 63`.

## The filter

Four fetches, `(b_u, b_v)`, `(b_u+1, b_v)`, `(b_u, b_v+1)`, `(b_u+1, b_v+1)`,
each through `ps1_sample`'s existing texture-window masking and
`ps1_fetch_texel`'s CLUT lookup.

**UV limits.** Before the window is applied, each sample coordinate is
clamped to `[min(u0,u1,u2), max(u0,u1,u2) - 1]` (and likewise `v`), the `- 1`
dropped for a degenerate range and the top widened to `iu` wherever the
nearest texel reaches it. The PS1 never draws a primitive's right or bottom
edge, so its last texel is never shown (DuckStation's
`ComputePolygonUVLimits`). Without this, a texture that is one cell of an
atlas pulls in its neighbour along every edge, which is the seam artifact
DuckStation's "UV limits" exist to fix. The limits come from the instance's
own `u0..v2`, so the record does not change.

**Holes are weight zero.** A sample whose raw texel is 0 contributes nothing
and the remaining weights are renormalised. Filtering a hole as black is what
draws a dark fringe around every cut-out. The weight sum can be zero (the
centre need not neighbour the nearest texel), and there `T` is the nearest
texel's `t5 << 3`: it is never a hole, or the fragment would already have
discarded.

The filtered texel `T` is per channel, in units of 1/8 of a five-bit step:

    T = sum(wt_i * (t5_i << 3)) / sum(wt_i)     // 0..248, integer

At a texel centre `T == t5 << 3` exactly, and every formula below is chosen
so that `T == t5 << 3` reproduces today's sidecar value bit for bit. That is
the invariant the tests lean on.

## The sidecar value, per mode

| | modulated | raw texel |
|---|---|---|
| `.trueColor` | `(T * c8) >> 7` | `T + (T >> 5)` |
| `.off` / `.native` / `.scaled` | `expand(pack(((T * c5) >> 4) + dither_o))` | `expand(pack(T))` |

Each reduces to today's expression at `T == t5 << 3`: `(t5 * c8) >> 4`,
`t5 << 3 | t5 >> 2`, `(t5 * c5) >> 1` and `expand(t5)` respectively. In the
dithering modes the sidecar stays a five-bit, dithered picture (the player
asked for that look), just a spatially smoother one. Raw texels are not
dithered, as today.

**Blending.** In `.trueColor` `ps1_blend8` takes the filtered `src8`
unchanged. In the dithering modes today's `out8 = expand(out)` would show the
UNFILTERED blend, so it becomes `expand(ps1_blend(dst, src5f, mode))`, where
`src5f` is the five-bit filtered value above with the nearest texel's STP bit.

## Plumbing

- `PrimInstance.h`: `PS1_FILTER_NEAREST 0`, `PS1_FILTER_BILINEAR 1`, and
  `Ps1RasterUniforms` gains `texture_filter` (8 -> 12 bytes; the
  `static_assert` pair moves with it).
- A runtime uniform, exactly like `dither_mode`: NOT part of `ContentView`'s
  `.id()`, rides `updateNSView` to `LiveRenderer`/`MetalRasterizer`.
- `TextureFilter` enum and `TextureFilterSetting` beside `DitherMode`. It
  reads `object(forKey:)` for `DitherSetting`'s reason: 0 is a valid value.
  A raw-value test pins it to the header.
- Video settings pane: a third picker, with a `SettingsCopy` entry whose info
  text says triangles only and that 2D stays sharp. Video menu: a
  Texture Filtering submenu beside Dithering, same shape.
- `MetalFixtureHarness.replay` pins `.nearest`, as it pins `.native`: Gate 1
  must not inherit a player default.

## Testing

All in the Swift suite (`MetalRasterizerTests` and siblings):

1. **VRAM never moves**: every fixture, every frame, at 1x and 3x, renders
   byte-identical VRAM with Bilinear and with Nearest. This is the gate.
2. **A uniform texture filters to itself**: a triangle over a single-colour
   texture writes the same sidecar under both filters, in all four modes.
3. **Bilinear adds levels**: a black/white two-texel texture magnified across
   64 native px has exactly 2 sidecar values under Nearest and more than 16
   under Bilinear (`.trueColor`).
4. **No hole fringe**: an opaque texel beside a hole texel, magnified; no
   filtered sidecar pixel is darker than the opaque texel.
5. **UV limits hold**: a triangle mapping texels 0..3 of a row whose texel 4
   is red never shows red in the sidecar.
6. **Dithering modes stay five-bit**: under Bilinear at `.off` and `.native`,
   every present sidecar pixel is `expand` of a five-bit value.
7. **Sprites are untouched**: a textured rectangle's sidecar is identical
   under both filters.
8. **Perspective path**: with `flag_texture_perspective` set, test 1's
   invariance and test 3's levels both hold.

**Cost**: Gate 4's `PS1_SCALE_TIMING` at 4x and 8x on `silent-hill-usa` and
`tr1-usa-v1-1`, filter on vs off, interleaved, numbers written into the
`ps1-gpu-metal` skill.

## Documentation

`ps1-gpu-metal` gains a section; CLAUDE.md's GPU + Metal rules gain one line:
**texture filtering is sidecar-only: VRAM, the hole and the STP bit stay on
the nearest texel.**
