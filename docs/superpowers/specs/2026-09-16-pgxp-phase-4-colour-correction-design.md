# PGXP Phase 4 — perspective-correct colour

Fourth phase of the programme laid out in
`2026-09-09-pgxp-duckstation-parity-audit.md`. Phase 3 built the perspective
interpolant and pointed it at texcoords; this phase points the same expression
at the vertex colour, and adds the one thing the record needs before two
correction settings can act independently.

**Goal.** Gouraud shading stops sliding. A PS1 interpolates vertex colour
linearly in screen space for exactly the reason it interpolates u/v that way,
and it is wrong on exactly the same polygons — a lit floor or wall running away
from the camera has its shading gradient bunched toward the near edge and
stretched across the far one, and the whole gradient swims as the camera moves.

**Success criterion.** A Gouraud triangle whose three vertices carry a W is
shaded perspective-correctly in BOTH rasterizers, bit-for-bit identically; the
setting is independently switchable from texture correction; and every gate
that holds today still holds, unchanged and still strict.

## Scope

In:

- `Command.flags`, replacing the `_pad0` byte, carrying one bit per corrected
  attribute class. This is the phase's only structural change, and it costs no
  bytes.
- `rw` on untextured Gouraud triangles: `reciprocalDepths` at the three
  `drawShadedTriangle` call sites in `gp0.zig`.
- The perspective branch for the colour channels at four sites — `ShadedShader`
  and `TexturedShader` in `renderer.zig`, `PS1_PRIM_GOURAUD_TRI` and
  `PS1_PRIM_TEXTURED_TRI` in `Rasterizer.metal`.
- `pgxp_color_correction`, default OFF: the C ABI setter, the Swift setting,
  the Video menu item.
- The sweep learns a second population, and the PGXP-on capture starts
  exercising both interpolants.

Out, deferred to Phase 5: the depth buffer, `transparent_depth`, `disable_2d`.
Out, deferred to Phase 6: preserve projection precision. Out permanently:
DuckStation's widescreen hack.

**The later phases are renumbered here, deliberately.** Phase 3's spec deferred
the depth buffer, `transparent_depth`, colour correction and `disable_2d` to
Phase 4 as one block, and preserve-projection-precision to Phase 5. That
grouping does not survive contact with the code. Colour correction is a branch
at four sites over an interpolant that already exists; the depth buffer is a
full-size second attachment in BOTH rasterizers with identical test semantics
(the strict-equality parity gate is the constraint, and the reference has no
such gate to copy from), an invalidation story on every VRAM-write path of the
kind the true-colour sidecar already needed, and a carried ABSOLUTE W, which
the per-primitive normalisation in `reciprocalDepths` deliberately discards
because the constant cancels. `transparent_depth` is a sub-flag of it and
meaningless without it. That is its own phase and its own spec, so it becomes
Phase 5 and preserve-projection-precision moves to Phase 6.

`disable_2d` travels with the depth buffer rather than with colour, because
what it is actually for is keeping 2D overlays out of the depth test. Phase 3
already observed that we have the useful half for free on the class where it
matters: textured rectangles are affine by construction.

Textured RECTANGLES stay affine, permanently, for the reason Phase 3 gave: a
sprite arrives as one position and a size, with no per-vertex depth to
interpolate between. Flat-shaded primitives of every class are out by
construction rather than by rule — see "What this can and cannot change".

## What Phase 3 already paid for

Three findings, checked in the tree, that make this phase far smaller than its
position in the roadmap suggests.

**The record already carries `rw` on every vertex.** `command.zig:74` puts it
on `Vertex`, not on a textured-vertex variant, and its doc comment says
"textured triangles only" purely as a statement of who writes it today. A
shaded triangle's three vertices have the field and leave it zero.

**The Metal transport already copies it for every triangle kind.**
`PrimBuilder.triangle` (`PrimBuilder.swift:94`) is shared by the flat, Gouraud
and textured paths and assigns `rw0/rw1/rw2` unconditionally.

So this phase changes **no stride**: not `Vertex` (24 bytes), not `Command`
(108), not `Ps1PrimInstance` (51 ints), and not the `.p1fx` version. The
`_pad0` byte it claims is dead in both declarations — `command.zig:106` and
`ps1.h:229` — and referenced nowhere else in the repo. Old version-3 fixtures
stay valid by construction, because a byte that was written zero decodes as
"neither attribute corrected", which is what those captures did.

**The interpolant needs no new mathematics.** `interpW` (`renderer.zig:164`)
and `ps1_interp_w` (`Ps1Color.h:272`) already take an arbitrary integer
attribute. A colour channel arrives on the wire as 8 bits, the same range as a
texcoord, so Phase 3's overflow derivation carries over unchanged rather than
needing a second one: `w_i·rw_i` reaches 2^45 and the numerator 2^55, inside
i64 at every internal resolution.

## Why DuckStation's setting reads backwards

Worth stating, because reading `gpu_pgxp_color_correction` as an opt-in
misdescribes the code. DuckStation's hardware renderer gets perspective colour
for **free** — the vertex shader emits a projected W, so every varying is
perspective-correct unless told otherwise. `gpu_hw.cpp:124` is therefore named
`ShouldDisableColorPerspective()`, and it is true when PGXP and texture
correction are on and colour correction is off; the setting's real job is to
stop stamping a `noperspective` qualifier. Its default (`settings.h:93`, `false`)
means DuckStation's shipped behaviour is *affine colour, by explicit
suppression*.

Two consequences for us. First, ours is affine by construction instead, so
"off" costs us nothing to implement and needs no suppression mechanism.
Second, the feature is known to misbehave on specific titles: DuckStation
carries a per-game `DisablePGXPColorCorrection` trait
(`game_database.cpp:832`) alongside its texture-correction equivalent. A
feature with a per-game disable list in the reference is not a feature to
default on.

## The signal problem, and the flags byte

Today the perspective path is gated by `rw != 0` alone, in both rasterizers
(`renderer.zig:612`, `Rasterizer.metal:360`), and `Gp0Engine.reciprocalDepths`
(`gp0.zig:454`) returns zeros when `pgxp_texture_correction` is off. That works
because exactly one setting consumes `rw`.

With two settings it stops working. A triangle drawn with colour correction on
and texture correction off must carry `rw` — and under today's gate its
texcoords would then be corrected too, by a setting the player turned off. The
record has to say which attribute may use the depth, because the rasterizers
cannot see the settings: a record is replayed by a Metal backend that has only
the record.

**`Command._pad0` becomes `Command.flags: u8`**, with two bits:

```zig
pub const flag_texture_perspective: u8 = 1 << 0;
pub const flag_color_perspective: u8 = 1 << 1;
```

Each is ANDed with `rw != 0` at the point of use. `Ps1PrimInstance` needs no
new field either: it already has `flags` carrying five bits
(`PrimInstance.h:35-39`), so this is `PS1_PRIM_TEXTURE_PERSPECTIVE` and
`PS1_PRIM_COLOR_PERSPECTIVE` beside them.

The bits are decided in `gp0.zig`, on the way to the sink, for the same reason
`unify`, `weldPoint` and `rw` itself are: the record a Metal replay consumes
must already be normalised, so the two rasterizers cannot disagree about it.
`Sink` holds no PGXP state and cannot reach `Bus`.

**Phase 3's central invariant survives untouched, and it is worth restating
because this phase must not weaken it.** With PGXP off, no vertex resolves, so
no W exists, so every `rw` is 0, so the affine branch runs and **every output
byte is unchanged by construction** — not "expected to be unchanged". The new
bits narrow the perspective path; they can never widen it, because `rw != 0`
remains a necessary condition. `trace-golden -- verify`, `stream-verify`,
Gate 1 and Gate 2 cannot move. If one moves it is a bug in the gating, never a
behaviour change to recapture.

The texture path's gate changes shape without changing behaviour: the new bit
is set exactly when `pgxp_texture_correction` is on, which is the condition
that produces a non-zero `rw` today.

## What this can and cannot change

**Colour correction can only change a Gouraud primitive.** This is a property
of the interpolant, not a rule imposed on top of it, and it is the reason the
feature is narrow enough to be safe.

Set `a0 = a1 = a2 = c`. Then

    num = c·(t0 + t1 + t2),  den = t0 + t1 + t2

so `interpW` returns exactly `c`, with no rounding and no dependence on the
weights. `interp` already reproduces a flat colour exactly for the analogous
reason — `w0 + w1 + w2 == area` — so the two agree bit-for-bit on any primitive
whose three colours are equal.

That covers more of a real frame than it sounds like. `gp0.zig:694` and `:706`
pass `color, color, color` for the flat-shaded textured opcodes, so every
flat-shaded textured triangle and quad in the corpus is bit-identical whether
the setting is on or off. Only the Gouraud opcodes — `drawShadedTriangle`,
`drawShadedQuad`, and the Gouraud-textured sites at `gp0.zig:725`, `:742`,
`:743` — can move a pixel.

This is a property to PIN, not to reason about once: a flat-shaded triangle
rendered with the setting on must equal the same triangle with it off, exactly,
and the test must be verified to fail against an implementation that drops the
`rw != 0` guard.

## Which primitives take the path

A record takes the colour-perspective path if and only if all three vertices
carry a depth AND the bit is set. Untextured Gouraud triangles need `unify` to
have run first, and it has: `drawShadedTriangle` (`gp0.zig:658`) and
`drawShadedQuad` (`:669`) both call `self.unify(&pts)`, which forces a
primitive all-resolved or none-resolved and already clears `w` on the vertices
it de-resolves (`gp0.zig:425`, `:435`). So a shaded triangle's W is
all-or-nothing before the sink sees it, exactly as a textured one's is, and
`reciprocalDepths` needs a `Point` variant beside today's `TexturedPoint` one
rather than any new rule.

A quad is split into two triangles after `unify` has run on all four points.
Each half normalises independently, which is safe because the normalisation
constant cancels.

## Plumbing

| Where | Change |
|---|---|
| `command.zig` | `_pad0` → `flags: u8`; the two bit constants; `execute` passes `rw` and the colour bit to both triangle renderers |
| `gp0.zig` | a `Point` overload of `reciprocalDepths`; the three `drawShadedTriangle` call sites gain it; both bits decided here; the `pgxp_color_correction` mirror |
| `sink.zig` | `drawShadedTriangle` gains `rw: [3]i32`; both triangle entry points write `flags` |
| `renderer.zig` | the perspective branch for `r/g/b` in `ShadedShader` and for `cr/cg/cb` in `TexturedShader` |
| `memory.zig` | `Bus.pgxp_color_correction`, `pgxpColorCorrection()`, `setPgxpColorCorrection`, and — see below — nothing in `Bus.init` |
| `pgxp_sweep.zig` | `shaded_triangles` and `color_perspective_primitives`, reported and floored |
| `ps1-golden/src/main.zig` | `--pgxp-on` enables every correction sub-setting |
| `Rasterizer.metal` / `PrimInstance.h` | the two flag bits; the branch at `:339` and `:380` |
| `PrimBuilder.swift` | translate the record's bits into the instance's |
| `ps1-capi` | `void ps1_set_pgxp_color_correction(Ps1*, int enabled)`; `_pad0` → `flags` in `ps1.h` |
| `ps1-macos` | `PgxpSetting.colorCorrection`, `Ps1Core`, `EmulatorRunner`, `EmulatorViewModel`, the Video menu |

`ps1-wasm` exposes no PGXP surface at all, so there is no frontend parity gap
to close here.

## The setting

`pgxp_color_correction`, default **OFF**, ANDed with the master flag in
`Bus.pgxpConfig` like the other five. There is no state in which it acts while
geometry correction does not, and the menu greys it rather than letting it
silently no-op.

Off matches DuckStation's default, and it matches the precedent set when
texture correction shipped ON: the rule we followed then was "take the
reference's default, because its defaults encode which settings are the picture
and which are workarounds". Texture correction and culling correction are the
picture. Colour correction is the one with a per-game disable list.

**Being default-OFF is what keeps it out of `Bus.init`.** A default-ON flag on
`Bus` must ALSO be assigned there, because the `@memset` does not respect field
defaults — `pgxp_culling` and `pgxp_cpu` both shipped broken for a build over
exactly this, and `pgxp_texture_correction` carries the assignment for that
reason. A default-OFF flag wants the opposite: `@memset` gives it `false`,
which is correct, and adding an assignment would be noise. The Swift side reads
it with `object(forKey:)` like the others, because a missing key must decode as
the default rather than as `false`-by-accident — the distinction that matters
for the ON settings and that should stay uniform.

## Gates

Unchanged and still strict, all of them PGXP-off guarantees:
`trace-golden -- verify`, `trace-golden -- stream-verify`, Gate 1 (fixture
hashes at 1x), Gate 2 (`readbackNative` at scale equals 1x).

**The PGXP-on parity fixture starts covering both interpolants.** It exists
already — `tr1-usa-v1-1-pgxp.p1fx`, captured by `stream-capture --pgxp-on`,
compared between the two rasterizers at strict equality. But `--pgxp-on` today
is `bus.setPgxp(true)` and nothing else (`main.zig:810`), so with colour
correction defaulting off that fixture would exercise none of this phase.

`--pgxp-on` therefore enables **every** correction sub-setting, not just the
master flag. The fixture's purpose is to prove the two rasterizers evaluate the
shared integer expressions identically, so it should maximise the corrected
surface; it is a test artifact and deliberately **not** the shipped
configuration. Say so in the flag's help text and in the fixture's doc comment,
or the next reader will take the fixture for a picture of the default. A third
fixture was the alternative and buys nothing: the property under test is
per-fragment agreement, and one capture with both interpolants live tests it
strictly more than two captures with one each.

The fixture is generated into `zig-out/fixtures/`, not committed, so widening
the capture costs no repo churn.

**`trace-golden -- pgxp` gains a second population.** `perspective_primitives`
over `textured_triangles` gets a sibling: `color_perspective_primitives` over
`shaded_triangles`, reported and ratcheted in `floors.txt` the same way. The
sweep must force the correction sub-settings on for the same reason the fixture
does — it measures propagation coverage, and a counter that reads zero because
of a shipped default measures nothing. Note in `floors.txt` that the new
numbers were measured with colour correction forced on, as the existing header
notes that its numbers were measured with CPU mode on.

Gate 2's blind spot applies here as everywhere: `readbackNative()` reads the
top-left subtexel of each block, where the sample point IS the native pixel, so
anything decided from `px`/`py` reproduces its 1x answer there by construction.
The scaled-path assertion for this phase is the one Phase 3 arrived at after
discarding a weaker one — a perspective render must DIFFER from the affine
render at subtexels that are not on the native lattice. A steep Gouraud
triangle at 8x, sampled off-lattice, with the colour bit set and then clear.

## Testing

Unit, in `ps1-core/tests/pgxp_test.zig` and `gpu_test.zig`:

- Three equal colours reproduce the affine result exactly, for a spread of
  weights and a spread of `rw` — the flat-shaded carve-out of "What this can
  and cannot change", asserted rather than reasoned about.
- A Gouraud triangle at a known depth ratio shades the hand-computed channel
  value at a hand-computed fragment: the correctness of the formula against
  arithmetic done on paper, not against our own implementation.
- The two bits are independent: each of the four combinations of
  `pgxp_texture_correction` and `pgxp_color_correction` produces the expected
  pair of bits and the expected pair of branches on one Gouraud-textured
  triangle. This is the test that catches the defect the flags byte exists to
  prevent, so it must be verified to fail against a single-bit implementation.
- `unify` clears `w`, and hence `rw`, on a mixed and on a thin SHADED
  primitive — the textured equivalents are pinned already.
- A record with `rw` set and the colour bit clear interpolates colour affinely.

Swift, in `ps1-macos/Tests`:

- The widened PGXP-on parity fixture at strict equality.
- The off-lattice difference assertion described under Gates.
- `PgxpSettingTests`: `colorCorrection` defaults OFF on a fresh install and
  persists when turned on — the mirror of the existing texture-correction pair,
  which tests the ON default and persistence when turned off.
- The sub-setting count assertions in the menu tests, which have gone stale
  twice now and will need the same increment again.

Every carve-out test must be verified to FAIL against the naive implementation
before the implementation lands. A guard test that cannot fail is worse than
none — `0xa96777069d622325` is the standing reminder.
