# PGXP Phase 6 — preserve projection precision

Sixth and last phase of the programme laid out in
`2026-09-09-pgxp-duckstation-parity-audit.md`. It adds the one DuckStation
PGXP setting this core still lacks, `gpu_pgxp_preserve_proj_fp`.

**Goal.** Parity completeness. The setting exists end to end (core, C ABI,
macOS menu, harnesses) and **ships OFF**, as DuckStation's does.

**Success criterion.** With the setting on, the GTE's float projection reads
the exact accumulator instead of the hardware-rounded IR1/IR2/SZ3; with it off,
or with PGXP off, every precise value is bit-identical to today's; no hardware
register or FLAG bit moves either way; and every gate that holds today still
holds, unchanged and still strict.

**Not the goal.** A visible improvement on a named scene, or shipping it ON.
Either would need its own measurement and its own decision.

## What DuckStation's setting does

`duckstation_ref/src/core/gte.cpp:789-883`. With PGXP on, DuckStation always
recomputes the projection in float: `IR · H/max(H/2, SZ3) + OF`. The setting
only changes where `IR1`, `IR2` and `SZ3` come from:

- **off**: the hardware registers, already truncated (`IR = MAC >> sf·12`,
  `SZ3 = MAC3 >> 12`) and saturated.
- **on**: recomputed from the vertex in float. For `sf = 1` that is a float
  dot product `RT/4096 · V + TR`; for `sf = 0` it is the unshifted MAC, which
  equals the register anyway. A `// TODO` there admits the float dot product
  does not handle the sign-extended cases. `lm` then clamps IR1/IR2 to
  `[-8000h, 7FFFh]` when set, and only from above when clear.

The setting is reset to off whenever PGXP is (`settings.cpp:1243`).

## Where we stand

**The audit's Fork 1 is stale, and so is its "projection source" row.** Both
describe a design that kept the hardware `MAC0` before its `>> 16`. The code
has since moved to DuckStation's default path: `doPerspectiveTransform`
(`ps1-core/src/cop2/opcodes.zig:96-125`) recomputes the projection in float
from the integer `IR1`/`IR2`/`SZ3`, beside the hardware one, and the identity
check judges a value by the WORD it was recorded against, not by its position.
So nothing about Fork 1's incompatibility applies. Phase 6 swaps three inputs
to an existing computation.

## Design

### The core change

`pgxp.Config` gains `preserve_projection: bool = false`. `opRtps`, `opRtpt`
and `doPerspectiveTransform` take the whole `pgxp.Config` instead of the bare
`vertex_cache`, so this setting does not add a third loose parameter and the
next one will not either. `cop2.zig`'s dispatch passes `pgxp` through
unchanged.

Under the flag, and only there, the three inputs to the float projection
change:

| input | flag off (today)               | flag on                                               |
| ----- | ------------------------------ | ----------------------------------------------------- |
| X     | `IR1` register (i16)           | `result[0] / 2^sf`, saturated exactly as IR1 is       |
| Y     | `IR2` register (i16)           | `result[1] / 2^sf`, saturated exactly as IR2 is       |
| Z     | `SZ3` register                 | `result[2] / 4096`, clamped to `[0, 0xFFFF]` like SZ3 |

`result[i]` is the exact `i64` accumulator `doPerspectiveTransform` already
holds; the division is done in `f64` and narrowed to `f32` once. Everything
after is unchanged: `zf = max(H/2, z)`, the `0x1FFFF / 65536` ratio cap, the
offset, the `[-1024, 1023]` clamp, the `valid_xyz` flags.

**Deliberate difference: we use the accumulator, not a float dot product.**
Ours is exact, so DuckStation's sign-extension `TODO` has nothing to
reproduce.

**Deliberate difference: saturation follows the hardware.** DuckStation's
`lm ? clamp(-8000h, 7FFFh) : min(7FFFh)` is inverted from the hardware, where
`lm` raises the lower bound to 0. Here the float is saturated with exactly the
bounds the register uses (`lm ? [0, 7FFFh] : [-8000h, 7FFFh]`), so a vertex
whose IR saturated is projected from exactly the register's value. That is the
only choice consistent with the production-site saturation rejection beside
it.

**Unchanged by construction:** every hardware register and FLAG bit; the
recorded `word`; the saturation rejection, which is still decided on the
integer `x`/`y` against `SXY2`; the vertex-cache insert; all of `gp0` and both
rasterizers. With `sf = 0` the accumulator is the register, so the setting is
a no-op there, as it is in DuckStation.

**The `toFixed` clamp stays.** A resolved vertex is still pinned inside the
pixel its wire word names (`gpu/primitive.zig:183`). Part of DuckStation's
on-screen effect is clamped away by that, but this is not specific to the
setting: the default float projection already drifts up to ~2 px from the wire
and is clamped the same way (croc's and spyro's `drift_far`). Loosening it
would reopen the rasterizers' 2^14-per-coordinate bound, the weld keys, the
oversized-primitive drop and the Metal parity gate, and is out of scope. What
the setting does still change is sub-pixel placement within the wire pixel and
the depth term `w`, which is never clamped and feeds texture correction,
colour correction and the depth buffer directly.

**Toggling the setting is not lockstep.** Float NCLIP (culling, ships ON) reads
the precise X/Y and writes MAC0, which the game reads, so an on/off A/B
diverges into a different scene exactly as a PGXP on/off one does. A lockstep
A/B needs culling off on both sides.

### Plumbing

The setting follows `pgxp_disable_2d`'s path, hop for hop:

| layer                                                  | change                                                                                                                                                                                                                   |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `ps1-core/src/memory.zig`                              | `pgxp_preserve_projection: bool = false`. Default-OFF, so **not** assigned in `Bus.init`. `pgxpConfig()` passes it into `Config`; no separate accessor, because the GTE is its only consumer and `pgxpConfig` already returns `.{}` when PGXP is off. |
| `ps1-capi/include/ps1.h`, `src/root.zig`               | `ps1_set_pgxp_preserve_projection(Ps1*, int enabled)`, documented as gated on `ps1_set_pgxp`; a `.preserve_projection` field in `ps1_reset`'s settings snapshot (`root.zig:122`).                                        |
| `ps1-macos/Sources/PS1/PgxpSetting.swift`              | `preserveProjection`, persisted under `<key>.preserveProjection`, default false.                                                                                                                                         |
| `EmulatorRunner`, `EmulatorViewModel`, `Ps1Core.swift` | the `disable2d` pattern: an `Atomic<Bool>`, re-applied every frame (cheap: applying it records nothing).                                                                                                                 |
| `ps1-macos/Sources/PS1App/VideoCommands.swift`         | Video ▸ "PGXP Preserve Projection Precision", greyed while PGXP is off like its siblings.                                                                                                                                |
| `ps1-golden/src/main.zig`                              | forced ON in the `pgxp` sweep (beside the other forced settings, `:549-554`) and by `--pgxp-on` (`:837`), per the rule that both instruments force every correction sub-setting. A plain field assignment like `pgxp_cpu`: with no `gp0` mirror to keep in step, it needs no `Bus` setter.                                                                               |

**Not added: a `ps1-trace` knob.** The existing knobs are lockstep A/B
instruments; this setting is not lockstep, and a knob would invite the
scene-divergence diff the `ps1-pgxp` skill warns against.

**Docs, in the same change:** CLAUDE.md's sub-setting count and accessor list;
the `ps1-pgxp` skill (a Phase 6 section, and its sub-settings line, which says
six and is already stale); and the parity audit's "projection source" row and
Fork 1, corrected with a pointer here.

## Testing

Unit tests go beside the existing RTPS precise tests in
`ps1-core/tests/pgxp_test.zig`, each written failing first:

1. **Off is byte-identical.** Flag false: `precise[14]` matches today's value
   bit for bit with the register-based formula over a spread of `sf`, `lm` and
   vertex inputs.
2. **On uses the fraction.** `sf = 1`, a MAC1 with a fractional part: precise
   X equals `(MAC1_exact / 4096) · H/z + OFX`, with inputs chosen so the
   expected value is exact in `f32` and differs from the register-based one.
3. **On refines Z.** A fractional `MAC3 / 4096` reaches `.z`.
4. **`sf = 0` is a no-op.** On and off produce identical precise values.
5. **Saturation parity.** With IR1/IR2 saturated, under both `lm` values, the
   float equals the saturated register.
6. **No hardware state moves.** All 64 GTE registers and FLAG are identical
   with the setting on and off.
7. **The master flag gates it.** `Bus.pgxpConfig()` with PGXP off yields
   `preserve_projection = false` even with the raw field true.

Frontends: `capi_test` checks the setter reaches the bus and survives
`ps1_reset`; `PgxpSettingTests.swift` checks the default (false) and
persistence.

Gates, all `-Doptimize=ReleaseFast`:

- **`trace-golden -- verify` and `-- stream-verify` must not move.** With PGXP
  off nothing reads the setting; a moved golden is a gating bug, never a
  recapture.
- **`trace-golden -- pgxp`:** the identity invariant holds. Because the sweep
  now forces the setting on and it is not lockstep, per-game counters may
  move. Any re-pin of `ps1-core/tests/goldens/pgxp/floors.txt` is its own
  commit, with before/after `resolved`, `drift_far` and `drift_max` per
  workload recorded in the `ps1-pgxp` skill. No direction is predicted.
- **`zig build fixtures` then `ps1-macos/test.sh`:** `tr1-usa-v1-1-pgxp.p1fx`
  is recaptured with the setting forced on, and the Metal-vs-software parity
  gate stays a strict equality.

## Done

The setting exists end to end and ships OFF; every gate is green; the measured
sweep deltas, the corrected audit, the skill and CLAUDE.md are committed.

## Out of scope

- Loosening the `toFixed` clamp.
- A `ps1-trace` knob.
- Any default-ON decision.
