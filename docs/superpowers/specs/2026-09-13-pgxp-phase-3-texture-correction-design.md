# PGXP Phase 3 — perspective-correct texturing

Third phase of the programme laid out in
`2026-09-09-pgxp-duckstation-parity-audit.md`. Phase 2 built the value that
carries a depth term and made it resolve in every workload; this phase is the
first one a player can see.

**Goal.** Textures stop swimming. A PS1 interpolates u/v linearly in screen
space, which is only correct for a polygon parallel to the screen; on a floor
or a wall the texture shears and slides as the camera moves. Interpolating
`u/W` and `1/W` instead and dividing per fragment removes it.

**Success criterion.** A textured triangle whose three vertices carry a W is
sampled perspective-correctly in BOTH rasterizers, bit-for-bit identically; and
every gate that holds today still holds, unchanged and still strict.

## Scope

In:

- `Primitive.Point` and `command.Vertex` carry the depth term through to the
  rasterizers. Today `cop2/opcodes.zig:113` records it and
  `getPointPrecise` drops it on the floor.
- The perspective interpolant, in `renderer.zig` and `Rasterizer.metal`, as
  one shared integer expression.
- `.p1fx` version 3, the `Ps1PrimInstance` fields, the C ABI setter, the Swift
  setting and the menu item.
- A new gate: a PGXP-on fixture compared between the two rasterizers at strict
  equality.

Out, deferred to Phase 4: the depth buffer, `transparent_depth`, colour
correction, `disable_2d`. Out, deferred to Phase 5: preserve projection
precision. Out permanently: DuckStation's widescreen hack.

Textured RECTANGLES stay affine and are out of scope permanently. A sprite
arrives as one position and a size, has no per-vertex depth to interpolate
between, and is 2D by construction — which gives us the useful half of
`disable_2d` for free, on the class where it matters.

## Why we do not do what DuckStation does

DuckStation gets this feature for nothing. `gpu_hw_shadergen.cpp:159` emits

```glsl
v_pos = float4(pos_x * pos_w, pos_y * pos_w, pos_z * pos_w, pos_w);
```

and lets the hardware rasterizer's own interpolator perform the divide.
Perspective-correct interpolation is a GPU's default; `gpu_pgxp_color_correction`
is the INVERSE operation, dropping the `noperspective` qualifier from the
colour varying. `gpu_sw.cpp` contains zero PGXP references, because in that
architecture PGXP is a hardware-renderer feature outright and there is no
second rasterizer to be in parity with.

**That deal is not available to us.** Our Metal backend deliberately does not
use hardware interpolation: Phase 0 draws a bounding-box quad per primitive and
recomputes coverage and every attribute per fragment from the plane equations,
precisely so that it reproduces the software rasterizer exactly. So the choice
in front of us is not DuckStation's. Ours is "write an explicit per-fragment
divide in Metal", and the only question left is whether to write the same three
lines in Zig beside it.

The audit's Fork 3 posed this as "either the software rasterizer takes floats
on the PGXP path, or the feature is Metal-only". **Both branches assume float,
and that assumption is what was wrong.** Our attribute interpolation is already
exact integer math on both sides — `renderer.zig:123` and `Ps1Color.h:237` —
so a third option exists that DuckStation's architecture cannot express.

One caution for anyone re-opening this. CLAUDE.md says to read
`duckstation_ref` for behaviour, not architecture, and to ask it "what does the
hardware do here". Texture correction is not a hardware behaviour at all; the
console never did it. On this question DuckStation is not an oracle, it is one
implementation's engineering trade-off, taken under constraints we do not
share.

## The interpolant

Per fragment, for attribute `a` (u or v):

```
a = (w0*aw0 + w1*aw1 + w2*aw2) / (w0*rw0 + w1*rw1 + w2*rw2)
```

where `w_i` are the unbiased barycentric numerators the coverage test already
produces and `rw_i` is a quantised reciprocal depth. `rw_i` is an integer
computed ONCE per primitive, on the CPU, in shared Zig, and carried in the
record. `aw_i` is just `a_i * rw_i` — an exact integer multiply of two fields
both rasterizers read from that record, so it is computed where it is used
rather than carried. That is not the kind of re-derivation the record rule
forbids: nothing is being decided twice, and an integer product cannot drift
between two implementations.

Note what is absent: `area`. It cancels, because numerator and denominator are
both first-order in `w`. Today's affine `interp` divides by `area`; this does
not need it at all.

### Four properties this has, and one it does not

**It is exact.** Every term is an integer and the division is an integer
division. The two rasterizers evaluate one expression over identical inputs, so
they agree by construction rather than by a promise about two compilers'
rounding. That is what lets the new PGXP-ON parity gate below be a STRICT
equality rather than a tolerance — which no float formulation could offer, and
which matters because Gate 1 is a hash: under float, one ULP anywhere is a red
gate with no diagnostic.

**It is scale-invariant, by the same argument `ps1_interp` uses.** If every
`w_i` picks up a common factor at internal resolution, numerator and
denominator pick it up equally, and `floor(λp / λq) == floor(p / q)` because
the rationals are equal before the floor.

**The normalisation constant cancels.** Scaling all three `rw_i` by a common λ
scales `aw_i` and the denominator by λ alike and leaves the quotient untouched.
So the choice of how to normalise `rw` affects QUANTISATION ONLY and can never
change a result. That is what makes per-primitive normalisation safe.

**The divide is already being paid.** `Ps1Color.h:237` is `long num = ...;
return int(num / long(area));` — a 64-bit integer division in Metal's
per-fragment loop, five of them on a modulated textured triangle, at every
scale. This replaces two of those five with two of the same shape. The marginal
cost is three extra 64-bit multiply-adds for the denominator.

CLAUDE.md's "1/16 px is a deliberate ceiling — more means `long` in Metal's
per-fragment loop" is about the COVERAGE math, which is `int` and stays `int`.
The attribute math crossed into `long` in Phase 0 and has been there ever
since. Do not read that rule as forbidding this; it does not reach it.

**What it does not have is precision in the depth ratio.** `rw` is quantised.
See below.

### Quantisation

`rw_i = round(2^16 * Wmin / W_i)`, where `Wmin` is the smallest of the
triangle's three W values, so the nearest vertex gets exactly `2^16` and the
others less. `rw_i` is clamped to a minimum of 1, and that clamp is what makes
the denominator provably positive: the coverage rule already guarantees every
`w_i >= 0` and not all three zero, so `den = sum(w_i * rw_i) >= 1` once no
`rw_i` can be zero. Without it, a pixel sitting exactly on the one vertex whose
`rw` rounded to zero would divide by zero. What the clamp gives up is a vertex
a million times further away than its neighbours, which is not a case worth
representing exactly.

16 bits of relative reciprocal precision. A triangle with a 100:1 depth ratio
resolves its far vertex's `1/W` to about 0.15%; at 1000:1, about 1.5%. The
artefact being removed is whole-texel swim, so this is far below what is
visible. The constant is named and its overflow derivation is written beside
it, so dropping to 2^14 is a one-line change if the bound below turns out
tighter in practice than on paper.

### The overflow bound

A primitive spanning >=1024 horizontally or >=512 vertically is DROPPED, so in
the box-relative 1/16-px space the coverage math works in, `qx < 2^14` and
`qy < 2^13`, and `ps1_orient` — and therefore `area` and every `w_i` — is
under 2^29.

```
aw_i  <= 255 * 2^16                     < 2^24
num   <= 3 * 2^29 * 2^24                < 2^55
den   <= 3 * 2^29 * 2^16                < 2^47
```

Both inside `i64`, with about 2^8 of headroom on the numerator.

**One thing to verify during implementation rather than trust.** `Ps1Color.h`'s
`ps1_interp` comment claims "at internal resolution s BOTH the weights and the
area scale by s^2". `ps1_triangle_coverage` appears to contradict it: Phase C
inverted the scaling so vertices arrive in native 1/16-px units and the SAMPLE
POINT is reduced to them (`qpx = (px * 16) / s`), which would leave the weights
native and unscaled. One of those two comments is stale. If the weights DO
carry an s^2 factor, at s=8 the numerator reaches 2^61 — still inside `i64`,
but with the headroom gone, and 2^14 becomes the right constant. Settle it by
reading the code, not by re-reading the comments, and correct whichever comment
is wrong as part of this phase.

## Which primitives take the path

**A record takes the perspective path if and only if all three of its vertices
carry a depth term**, signalled by `rw_i != 0`. Otherwise it takes today's
`interp`, unchanged, and produces today's bytes.

This is cheap to guarantee because `unifyTexturedSpace` (`gp0.zig:398`) already
forces a primitive to be all-resolved or none-resolved: a mixed primitive is
snapped back to integers wholesale, and so is a thin one. So a textured
triangle's W is all-or-nothing before the sink ever sees it, and `unify` gains
one obligation — clear `rw` to 0 on the vertices it de-resolves.

**The consequence worth stating plainly: with PGXP off, every output byte in
this phase is unchanged by construction.** Not "expected to be unchanged" —
there is no W, so `rw` is 0, so the affine branch runs. The trace goldens,
`stream-verify`, Gate 1 and Gate 2 cannot move, and if one does it is a bug in
the gating rather than a behaviour change to recapture.

A quad is split into two triangles at `gp0.zig:640-641` AFTER `unify` has run
on all four points. Each half is normalised independently. That is safe
because the normalisation constant cancels.

## Plumbing

| Where | Change |
|---|---|
| `primitive.zig` | `Point` gains `w: f32 = 0`; `getPointPrecise` copies `p.z` into it when it accepts a candidate |
| `gp0.zig` | `unify`/`unifyTextured` clear `w` when de-resolving; the sink call computes `rw_i` for the triangle |
| `command.zig` | `Vertex` gains `rw: i32 = 0`; stride 20 -> 24, `Command` 96 -> 108, both `@compileError` tripwires updated |
| `fixture.zig` | `version` 2 -> 3, `record_stride` assertion 96 -> 108 |
| `renderer.zig` | the perspective branch in `drawTexturedTriangle`'s shader |
| `Rasterizer.metal` / `Ps1Color.h` | `ps1_interp_w`, beside `ps1_interp` |
| `PrimInstance.h` | `Ps1PrimInstance` gains `rw0, rw1, rw2` |
| `ps1-capi` | `void ps1_set_pgxp_texture_correction(Ps1*, int)`, `ps1.h` struct update |
| `ps1-macos` | `PgxpSetting.textureCorrection`, `FixtureFile.swift`, the Video menu |

`Vertex` carries the derived integer `rw`, not the `f32` W. Two reasons. A
record must carry every input its effect needs and nothing may be re-derived at
replay time — deriving `rw` on each side is exactly the kind of second
transcription that drifts. And `rw` is what the effect actually consumes; the
`f32` W is an intermediate. Phase 4's depth buffer will want absolute W, which
per-primitive normalisation discards; it can add that field when it needs it
rather than this phase carrying a value nothing reads.

## The setting

`pgxp_texture_correction`, default **ON**, ANDed with the master flag in
`Bus.pgxpConfig` like the other four — there is no state in which it acts while
geometry correction does not, and the menu greys it rather than letting it
silently no-op.

On-by-default matches DuckStation's own default and its intent: texture
correction and culling correction are the picture, and the vertex cache and CPU
mode are the workarounds. PGXP itself still ships off, so this default only
reaches a player who opted in. A default-ON flag on `Bus` must ALSO be set in
`Bus.init` — the `@memset` there does not respect field defaults, and
`pgxp_culling` and `pgxp_cpu` both shipped broken for a build over exactly
this.

## Gates

Unchanged and still strict, all of them PGXP-off guarantees:
`trace-golden -- verify`, `trace-golden -- stream-verify`, Gate 1 (fixture
hashes at 1x), Gate 2 (`readbackNative` at scale equals 1x).

**New: a PGXP-on parity fixture, at STRICT equality.** `stream-capture
--pgxp-on` already exists. Capture one 3D workload with PGXP on, run it through
both rasterizers at 1x, and require full-VRAM equality. This is the gate that
proves the shared integer path, and it is only expressible because the
interpolant is exact — under approach B or C it would have had to be a
tolerance.

`trace-golden -- pgxp` gains a `perspective_primitives` counter in the sweep:
how many textured triangles took the path. Reported, and ratcheted in the same
file as the hit rates and clamp ceilings.

Gate 2's known blind spot applies here as everywhere: `readbackNative()` reads
the top-left subtexel of each block, where the sample point IS the native
pixel, so anything decided from `px`/`py` reproduces its 1x answer there by
construction. A new scaled-path test must assert something about the INTERIOR
of a block. For this phase that means: a steeply-angled textured triangle at
8x must sample a monotonically varying texel sequence across a block, not the
same texel repeated.

## The open question this phase inherits

Phase 2 closed with croc clamping 81,466 of 199,788 resolved vertices, 75,726
of them drifting a full pixel or more, peaking at 2.03 px. `toFixed` pins a
drifted vertex's POSITION inside the wire's own pixel. **Nothing pins its W**,
and there is nothing to pin it against — the wire carries an integer SXY, so
there is a hardware value to clamp a position to, and no hardware value
whatsoever to clamp a depth to.

This phase is where that stops being theoretical: texture correction reads W
per fragment.

It is specified as a MEASUREMENT, not a design decision taken blind, because
nothing measured says those 75,726 W values are wrong and nothing says they are
right. The tool already exists: `ps1-trace`'s `tol=<px>` is a lockstep A/B,
because tolerance is consumed only at the GP0 vertex decode, so `tol=1.0`
(which rejects exactly the `drift_far` set) and the default `-1` run the
identical instruction stream and land on the same frame. Run croc — the worst
population in the corpus — with texture correction on, at `tol=-1` against
`tol=1.0`, and look at whether the drifted set produces visible texture swim on
a 3D surface.

If it does, the mitigation is `pgxp_tolerance`, which already exists and already
ships off, and the finding would be an argument for a W-specific admission test
rather than a position-based one. **Do not pre-emptively build that test.**
Phase 2 measured the cost of refusing the drifted set on position — croc falls
1,150,338 -> 817,838 resolved and `mixed_primitives` goes 4,938 -> 111,405,
because `unify` snaps a whole primitive back when one vertex is refused. A
refusal that costs twenty times what it repairs needs evidence first.

## Testing

Unit, in `ps1-core/tests/pgxp_test.zig` and `gpu_test.zig`:

- `rw` normalisation: the nearest vertex gets exactly 2^16; a common scaling of
  all three W values leaves every `rw` unchanged.
- The quotient is invariant under scaling all three `rw_i` by a common factor —
  the cancellation property, asserted rather than assumed.
- Three equal W values reproduce the affine `interp` result exactly, for a
  spread of weights. This is the property that makes the fallback safe and it
  should be pinned, not reasoned about.
- `rw_i == 0` on any vertex takes the affine branch.
- `unify` clears `w` and `rw` on a mixed primitive and on a thin one.
- A textured triangle at a known depth ratio samples the hand-computed texel at
  a hand-computed fragment — the actual correctness of the formula, against
  arithmetic done on paper, not against our own implementation.
- The overflow bound: a primitive at the oversized cap, at maximum depth ratio,
  with u = v = 255, does not overflow `i64`.

Swift, in `ps1-macos/Tests`:

- The PGXP-on parity fixture at strict equality (the new gate).
- The interior-of-block assertion described under Gates.
- `.p1fx` version 3 round-trips; a version 2 file is rejected.

Every carve-out test must be verified to FAIL against the naive implementation
before the implementation lands. A guard test that cannot fail is worse than
none.
