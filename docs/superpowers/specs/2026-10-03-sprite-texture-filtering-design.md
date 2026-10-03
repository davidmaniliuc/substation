# Sprite Texture Filtering — design

**Date:** 2026-10-03
**Status:** design approved in chat; awaiting spec review
**Builds on:** `2026-10-02-texture-filtering-design.md` (every rule there still
holds; this spec only adds a second setting and decides which one applies)
**Scope:** the macOS Metal renderer and its Settings. No Zig changes, no golden
moves, no `.p1fx` change.

## The goal: DuckStation parity

DuckStation has two settings, Texture Filtering and Sprite Texture Filtering,
and it applies the second to anything it classes as a SPRITE. Substation has
the first only, and today it filters every textured triangle, including the
screen-flat polygons many games draw their HUDs and 2D with. Parity means two
things, both decided here:

- a second setting, for sprites, that ships Nearest;
- the same sprite/3D split, so that Texture Filtering = Bilinear with Sprite
  Texture Filtering = Nearest smooths 3D surfaces and keeps 2D sharp, as it
  does in DuckStation. That is a deliberate change from today, where
  polygon-drawn 2D is smoothed with the 3D.

## What may not change

Everything the triangle spec forbids. A filtered colour reaches `color(1)` and
never VRAM; the VRAM value, the hole and the STP bit stay on the nearest texel.
The classification below chooses only WHICH setting applies, so it cannot move
a gate either.

## The classification

Decided in the fragment shader, per primitive, from the instance's own fields.
No record or instance field is added.

| primitive | class |
|---|---|
| textured rectangle (`PS1_PRIM_TEXTURED_RECT`) | sprite, always |
| textured triangle with `rw != 0` on all three vertices | 3D, always |
| any other textured triangle | sprite iff its texture is screen-aligned (below) |
| a triangle with zero screen area or zero texture area | 3D |

**Screen-aligned** means u does not change down the screen and v does not
change across it, DuckStation's `zero_dudy && zero_dvdx`. With every delta
taken from vertex 0, both are exact integer zero tests:

    du/dy == 0  <=>  du1 * (x2 - x0) == du2 * (x1 - x0)
    dv/dx == 0  <=>  dv1 * (y2 - y0) == dv2 * (y1 - y0)

Scaled and mirrored 2D quads pass; a rotated or perspective-mapped one fails.

**The PGXP rule**, DuckStation's `is_precise ? !is_3d : derivative test`: a
triangle carrying a depth on all three vertices is 3D whatever its mapping.
One difference, recorded rather than reproduced: a triangle PGXP resolved
WITHOUT a depth is judged here by the derivative test, where DuckStation would
call it a sprite outright. In this core `rw != 0` is exactly "has a depth", and
CPU-mode PGXP does not give game-built 2D one, so the case is rare.

**Which filter:** `sprite ? uni.sprite_filter : uni.texture_filter`. When the
two settings agree the classification decides nothing, which is DuckStation's
"sprite mode only when the filters differ".

## Filtering a rectangle

**The sample point.** A sprite maps one texel to one native pixel, so the
fractional texcoord is taken at the SUBTEXEL CENTRE in the triangle path's
six-bit units, unwrapped:

    u6 = ((2*px + 1) * 64) / (2*s) - 64*x0 + 64*u0      (likewise v6)

At 1x the centre is the texel centre and Bilinear reproduces Nearest exactly,
as it now does for a 1:1-mapped triangle; filtering shows from 2x up. The
NEAREST texel stays `((nx - x0) + u0) & 0xFF`, so VRAM cannot move.

**Limits follow the 256 wrap.** A rectangle's texcoord wraps, so a wide one
repeats the page. DuckStation splits such a rectangle into quads and limits each
to its own range; the shader does the same without splitting. For the unwrapped
coordinate `U` of the pixel's nearest texel, segment `k = U >> 8` has limits

    [max(u0, 256k), min(u0 + w - 1, 256k + 255)]       (likewise v, with h)

and each sample is clamped into them, then wrapped `& 0xFF`, then windowed. The
high limit is `u0 + w - 1` exactly: a rectangle's last column IS that texel, so
the triangle path's `max - 1` does not apply. The nearest texel always lies
inside its own segment's limits, so the `wsum == 0` fallback still holds.

**One filter body.** `ps1_bilinear` takes its limits as arguments instead of
deriving them from `p.u0..p.v2`, and wraps each clamped sample `& 0xFF` before
`ps1_window_fetch` (a no-op for a triangle, whose limits lie in 0..255). The
triangle path passes `ps1_uv_limit`'s `max - 1` limits, the rectangle path its
wrap-segment limits; the four-texel fetch, the hole rule and `ps1_filtered`
stay shared. Modulation needs nothing: a sprite's `shade8 = c5 << 3` already
makes every `ps1_filtered` formula reduce to today's value at a texel centre.

## Plumbing

- `PrimInstance.h`: `Ps1RasterUniforms` gains `sprite_filter` (12 -> 16 bytes;
  the `static_assert` and the Swift size test move together).
- `SpriteFilterSetting`, the same shape as `TextureFilterSetting` over the same
  `TextureFilter` enum through `PersistedChoice`, key `spriteTextureFilter`,
  default `.nearest`.
- A runtime uniform like `textureFilter`: through `EmulatorViewModel`,
  `MetalDisplayView` (not in `.id()`), `LiveRenderer`, `MetalRasterizer`.
- Settings ▸ Video: a fourth picker, Sprite Texture Filtering, under Texture
  Filtering, with its own `SettingsCopy` entry: sprites, HUDs, text and
  screen-flat 2D polygons; 3D surfaces follow Texture Filtering. The Texture
  Filtering copy drops "menus, text and 2D sprites stay sharp", which now
  depends on the sprite setting. The Video menu gains the matching submenu.
- `MetalFixtureHarness.replay` and `MetalScaleHarness` pin `.nearest` for the
  sprite setting too.

## Testing

All in the Swift suite.

1. **VRAM never moves**: every fixture, every frame, renders byte-identical VRAM
   under all four combinations of the two settings, at 1x and 3x.
2. **Classification**: a screen-aligned textured quad follows the sprite
   setting; a rotated one and a perspective-mapped one follow the texture
   setting; a screen-aligned triangle with `rw != 0` on all three follows the
   texture setting; a rectangle follows the sprite setting.
3. **A rectangle at 1x filters to itself**: identical sidecar under both.
4. **A rectangle at 4x adds levels** across a two-texel edge.
5. **Wrap limits**: a rectangle crossing u = 256 never shows a colour planted
   just outside its segments, nor the texel past its last column.
6. **A uniform sprite filters to itself** in all four dither modes.
7. **No hole fringe** on a cut-out sprite.
8. **The triangle tests still pass.** Any whose triangle turns out to be
   screen-aligned sets the sprite setting as well.
9. **The setting**: round trip, default Nearest, an unknown stored value
   rejected, the 16-byte uniform on both sides, and the value reaching the
   rasterizer with no rebuild.

**Cost**: Gate 4 gains a both-settings-on pass, `silent-hill-usa` and
`tr1-usa-v1-1` at 4x and 8x; the numbers go into `ps1-gpu-metal`.

## Documentation

`ps1-gpu-metal` gains a sprite-filtering section: the classification, the
wrap-segment limits, and the PGXP-without-depth difference. The CLAUDE.md
texture-filtering rule gains one clause: the sprite/3D class is decided in the
shader from the primitive's own vertices and chooses only which setting
applies.
