# PGXP geometry correction — vertex precision — design

**Date:** 2026-08-30
**Status:** approved; one implementation plan
**Parent spec:** `docs/superpowers/specs/2026-08-23-metal-hardware-renderer-design.md`
(§ Decisions taken → 1. Hardware renderer first, PGXP second)
**Predecessor:** `docs/superpowers/specs/2026-08-30-metal-renderer-phase-d2-upscaling-design.md`
— the last phase of the Metal umbrella, and the thing this spec was sequenced behind.

## Goal

Stop PS1 polygons wobbling. The GTE computes each projected vertex with 16
fractional bits and then throws them away; every triangle in every 3D game is
therefore snapped to a whole pixel, and a vertex whose true position drifts
across a pixel boundary jumps a full pixel while its neighbours do not. That is
the shimmer everyone recognises as "PlayStation".

This spec keeps those 16 bits and carries them to the rasterizer. It is not new
math — `opcodes.zig` already computes the exact numbers. It is plumbing, an
invariant, and a setting.

## Scope

In:

- The precise SXY FIFO in `cop2/`, written where `saturateSxy` currently
  discards precision.
- Shadow value tables over the GPRs, RAM and scratchpad, and the propagation
  set in `cpu/exec.zig` and `cpu/cpu.zig` that fills them.
- Provenance carried through the GP0 FIFO from all three producers.
- 16.16 sub-pixel vertices in `command.Command`, the software rasterizer, the
  `Ps1PrimInstance` record and `Rasterizer.metal`.
- A core flag, a `ps1-capi` setter, a persisted app setting and a menu item.
- A `ps1-golden pgxp` sweep: the identity invariant and a ratcheted per-game
  hit-rate.

Out — permanently, or elsewhere:

- **Perspective-correct texturing and colour interpolation.** PGXP's second
  half. It needs W to survive into the primitive record and into both fragment
  shaders, and it is the half that introduces its own artefacts on geometry the
  game intended to be affine. Its own spec if ever.
- **CPU mode** — tracking precision through ordinary CPU arithmetic for games
  that transform coordinates outside the GTE. Every implementation that ships
  it ships it off by default, and it is a large surface for a small tail of
  titles.
- **W-based near-plane culling.** The oversized-primitive drop stays exactly as
  it is; see § 4.
- **Any `trace-golden` recapture.** With PGXP off this spec changes no output
  at all, and that is a checkable claim rather than an aspiration — see § 6.
- The vertex-value cache. Rejected in § 2.

## Decisions taken

### 1. The precision already exists; the work is transport

`cop2/opcodes.zig:65-81`, inside `doPerspectiveTransform`:

```zig
const x = math.setMac0(cop2, h_s3z * ir1 + ofx) >> 16;
const y = math.setMac0(cop2, h_s3z * ir2 + ofy) >> 16;
...
const sxy2 = Cop2.Point2D{
    .x = math.saturateSxy(cop2, x, 14),
    .y = math.saturateSxy(cop2, y, 13),
};
```

`h_s3z` carries 16 fractional bits by construction — the comment three lines
above says so, because OFX/OFY are 16.16 and the sum has to line up. The `>> 16`
is the entire loss. `setMac0` must keep running on the unshifted value (MAC0's
overflow flag is observable), so the precise value is taken *beside* the
existing code rather than in place of it, and the integer path is untouched.

RTPT runs the same function three times, so the FIFO discipline below covers it
without a second case.

### 2. Memory tracking, not a value cache

The rejected alternative is a hash from the packed 32-bit SXY word to its
precise value, filled at RTPS and probed at GP0 intake. It needs no hot-path
hooks at all, which is a real attraction in a codebase that just spent a
release cycle taking 12% out of `cdrom.step`.

It is rejected because the key is ambiguous by construction. Two vertices that
project to the same whole pixel — which is exactly what happens on the dense,
distant geometry PGXP is supposed to fix — collide, and the loser gets the
winner's sub-pixel offset. Every emulator that ships both modes documents the
cache as the lower-accuracy one, and the failure is silent: it produces
*differently* wrong vertices rather than no correction.

Memory tracking follows the actual dataflow, which is the same in every PS1
game because it is what libgpu prescribes: `mfc2` the packed SXY into a GPR,
`sw` it into an ordering-table node, and let DMA hand the node to GP0 some
thousands of instructions later.

### 3. Provenance rides the GP0 FIFO, because the write path is address-blind

This is the sharpest edge in the spec and the one place the existing
architecture actively resists the feature.

There are three producers of a GP0 word, and not one of them tells the GPU
where the word came from:

| Producer | Site | True source of the value |
|---|---|---|
| CPU store | `memory.zig:516` — `self.gpu.writeGp0(value)` | a **GPR** (`sw $t0, GP0`) |
| DMA block | `dma.zig:530` — `bus.write32(target_gpu_data, val)` | the RAM word at `addr` |
| DMA linked list | `dma.zig:578` — `bus.write32(target_gpu_data, data)` | the RAM word at the node address |

Both DMA sites know the source address and discard it by routing through the
generic `bus.write32`. The CPU site is worse: the value's provenance is a
register number that `memory.zig` never sees, because by the time the store
reaches the bus the operand is a bare `u32`.

A single "pending provenance" slot on `Bus`, set by each producer and consumed
by the GPU, is the obvious shape and is **wrong**. `writeGp0` does not consume
the word where it receives it — it pushes into a 16-word FIFO
(`gpu.zig:212-214`) drained later against `cycle_debt` (`gpu.zig:81`). A single
slot would be overwritten by the next fifteen words before the first was
parsed.

So the FIFO carries pairs. `Gpu` gains `fifo_pgxp: [16]Precise` alongside
`fifo: [16]u32`, indexed by the same head/tail; `writeGp0` takes the provenance
as a second parameter; `Gp0Engine.write` receives it with the value and stashes
it into a `cmd_buffer_pgxp: [16]Precise` parallel to `cmd_buffer`, so a
multi-word primitive's vertices each keep their own.

Threading a second parameter through `writeGp0` means every caller must supply
one. That is a feature: a new producer of GP0 words cannot be added without
deciding what its provenance is, and `Precise.none` is an explicit answer
rather than a default that silently degrades coverage.

### 4. The identity check is both the gate and the safety net

The hard problem in every PGXP implementation is invalidation. A shadow entry
that outlives the value it described will attach a precise vertex to an
unrelated integer word, and the vertex flies across the screen — a far worse
artefact than the wobble being corrected. Guarding it properly means hooking
every path that writes RAM: OTC clearing the ordering table every frame, MDEC
output, CD and SPU DMA, the BIOS's own memcpy.

None of that is necessary, because of one predicate at GP0 intake:

```
resolved = precise.valid
        and precise.x >> 16 == vertex.x
        and precise.y >> 16 == vertex.y
```

**The precise value is stored as raw 16.16, and that shift is literally the
GTE's own.** `opcodes.zig:65` computes `x` as `setMac0(...) >> 16` — so MAC0
*is* the 16.16 screen coordinate, and keeping it costs a copy rather than a
conversion. The check is then exact integer arithmetic that reproduces the
truncation bit for bit, including for negative coordinates, where a float
`round` would disagree with an arithmetic shift by one on every value with a
non-zero fraction. Off-screen geometry is routinely negative here, so that is
not a corner case.

It also keeps the promise CLAUDE.md makes about the rasterizer: no `f32`
anywhere in the inner loop, and none introduced on the way to it.

A stale entry either fails the check and is discarded, or it passes — in which
case it agrees with the integer vertex to within a pixel, and the residual
error is smaller than the pixel-snapping PGXP exists to remove. **Invalidation
therefore only has to be good enough for coverage, never for correctness.**

The ±1024 clamp falls out of this for free. `saturateSxy` (`opcodes.zig:76-79`)
pins an off-screen vertex to the clamp while MAC0 keeps the true value, so the
shift disagrees and the vertex resolves to the integer path — which is the
behaviour hardware has and games rely on.

This inverts the usual cost structure of the feature. We hook the cheap,
high-yield paths (`sw`, `sh`/`sb` over a tracked word, `cpu.writeReg`) and let
the predicate absorb everything else. It also means the deterministic gate in
§ 6 is not an extra mechanism bolted on for testing: it is the same predicate
the emulator runs at every vertex, reported instead of applied.

### 5. Records carry 16.16; both rasterizers reduce to box-relative 1/16 px

`command.Vertex` gains `px: i32, py: i32`, screen coordinates in 16.16,
defaulting to `x << 16`. That is the archival representation — the exact MAC0
value, matching the shadow table, losing nothing.

**Neither rasterizer computes edge functions in 16.16.** They cannot:
`Rasterizer.metal`'s `ps1_orient` returns `int`, and a cross product of 16.16
coordinates reaches 2⁵⁶. Widening MSL to `long` would put 64-bit integer
arithmetic in the per-fragment inner loop of every triangle in every game, to
carry sixteen fractional bits of which the bottom twelve are far below what a
pixel can show.

Instead, both rasterizers reduce at draw time, identically:

```
origin  = (min integer x, min integer y) over the three vertices, offset applied
qx      = ((px - (origin_x << 16)) + 2048) >> 12      // 1/16 px, box-relative
```

Four properties, and each is why a term is there:

- **1/16 px is the precision, and it is a deliberate ceiling.** It is what
  D3D11 mandates and more than OpenGL requires; the artefact being removed is a
  *whole* pixel of snapping. The remaining 1/16 px of quantisation is not
  visible and buys an `int` inner loop.
- **Box-relative is what keeps it inside `int`.** The oversized-primitive rule
  bounds the span at 1023 px, so a relative coordinate is at most 1023·16 <
  2¹⁴ and `ps1_orient` at most 2²⁹ — comfortable at every internal scale.
  Absolute coordinates are not bounded that way: `vx = x + offsetX` can sit
  ~3000 px out while the box is still on screen, which at 1/16 px overflows.
  `orient2d` is a cross product of *differences*, so the translation is exactly
  invariant and costs nothing.
- **The top-left `bias` of `-1` is NOT scaled.** It only ever changes the
  verdict against an exact zero, so it stays `-1` and breaks exactly the same
  ties. Scaling it turns a tiebreak into an inset: an edge function IS twice
  the area of (edge, pixel), so a bias of B discards every interior pixel
  closer than `B / |edge|` to a top-left edge — about 1/L px for an L-pixel
  edge with B = 256. With PGXP off that is invisible, because every edge
  function is a multiple of 256 there; with PGXP on it is sparse single-pixel
  dropouts across the whole scene. *(Both rasterizers shipped with the scaled
  bias first, on the strength of the argument in the next paragraph, and both
  had to be corrected. The plan's Ruling P6 endorsed the scaling; it was wrong,
  and this bullet was right.)*
- **The "not all three zero" clause is what has to be restated, not the bias.**
  Avocado's test is `(w0 | w1 | w2) > 0` — "all three non-negative AND not all
  three zero" — and it is that second half, not the tiebreak, that stops being
  scale-invariant. It becomes `any w_i >= 256`, i.e. the same clause measured
  at whole-pixel granularity. The pair is exactly equivalent to the original
  with PGXP off: a native weight of 1 on a top-left edge reads 255 and is
  refused, one on a non-top-left edge reads 256 and is kept.
- **`interp` is unchanged.** `@divFloor(k·num, k·den) == @divFloor(num, den)`
  for `k > 0`, and both the numerator's weights and the area pick up the same
  256×, so every interpolated attribute is bit-identical.

PGXP off is therefore byte-identical rather than merely expected to be: every
`px` is `x << 16`, every `qx` is `(x - origin_x) · 16` exactly, and `orient2d`
returns 256× its former value with every sign and every ratio preserved.

The bounding box takes `floor`/`ceil` of the sub-pixel coordinates. With PGXP
off those are the integer coordinates; with PGXP on the box may grow by one
pixel on a side, which is correct.

**The oversized-primitive drop stays on the integer coordinates.** CLAUDE.md
marks that rule load-bearing — it is the only near-plane clip Silent Hill has,
and without it the roadside foliage sweeps across the camera. By the identity
invariant PGXP moves a vertex less than a pixel, so it can never flip a
`>= 1024` or `>= 512` span verdict. Evaluating the drop on the integer
coordinates is therefore a genuine no-op, not a risk being accepted. The same
argument covers the two line paths and both rectangle paths, which this spec
leaves entirely alone — rectangles are axis-aligned screen-space blits with no
GTE provenance, and PGXP has nothing to offer them.

**Widening `Vertex` reshapes the fixture format, and that is a deliberate,
loud break.** `command.zig` pins `@sizeOf(Vertex) != 12` and
`@sizeOf(Command) != 72` as compile errors precisely so a field added later
cannot silently reshape the file format; `px`/`py` take `Vertex` to 20 and
`Command` to 96. Three consequences, all of them intended by that pin:

- The two comptime assertions are updated in the same commit, to 20 and 96.
- `FixtureFile`'s `record_stride` check fails on every existing `.p1fx` until
  they are regenerated — which is the check doing its job, not an obstacle.
  `zig build fixtures` re-runs, and the committed
  `ps1-core/tests/goldens/fixtures/synthetic-primitives.p1fx` is regenerated
  and re-committed.
- **No fixture VRAM hash moves.** The records are wider; with PGXP off they
  describe the same primitives, `px == x << 16`, and § 5's argument says the
  rasterizer output is identical. A hash that *does* move is the same signal as
  a `trace-golden` move: stop, do not recapture.

Frame ordering in `synthetic-primitives.p1fx` is untouched — the ladder is
indexed by frame number and appended to, never reordered.

Metal: `Ps1PrimInstance` gains `qx0, qy0, qx1, qy1, qx2, qy2` — the three
vertices in 1/16 px, box-relative — **beside** the existing `x0..y2` rather
than changing their units. Reusing
`x0..y2` would move every fixture hash and every pinned instance byte in
Phases B and C, turning a plumbing change into a renderer recapture. Records
stay native and exact, exactly as Phase C requires.

`ps1_triangle_coverage` inverts Phase C's move: rather than scaling the
vertices up by `s`, it reduces the scaled sample point to native 1/16-px units,
`(px * 16) / s`, and takes the vertices box-relative in the same units. At a
top-left subtexel `px = nx * s`, so that is exactly `nx * 16` for every `s`
including 3 — downsample-invariance survives by construction rather than by
argument, and the intermediate `px * 16` peaks at 2¹⁷, well inside `int`.

`PrimInstance.h`'s contract holds: every field is 4 bytes, `int` throughout,
never `<stdint.h>`.

### 6. Default off, for the same reason internal resolution defaults to 1×

A core `pgxp_enabled: bool`, a `ps1_set_pgxp` in `ps1-capi`, a `PgxpSetting` in
the app shaped exactly like `InternalResolution` — resolve from `UserDefaults`
in `init`, persist in `set`, keep the rule in the type so it is reachable from
a test without a window — and a `Video ▸ PGXP` toggle.

Default **off**. Off is the configuration the byte-exact oracle covers: it is
the only state in which the software rasterizer and the Metal backend can be
compared against a recorded truth rather than against each other. Selecting
PGXP opts out of that knowingly, exactly as selecting 4× does; the shipped
configuration must not opt out for the player.

Unlike `VolumeSetting`, absence of the key is not ambiguous here — `bool(forKey:)`
returns `false` for a missing key and `false` is the intended default, so no
`object(forKey:)` probe is needed.

## Architecture

### The shadow tables

```
cop2.precise_sxy: [3]Precise     shifted in lockstep with data_regs[12..14]
cpu.gpr_shadow:   [32]Precise    filled by mfc2 of sxy0/1/2/p
cpu.load_shadow, cpu.delay_shadow
                                 parallel to load_delay.load_r / delay_r
bus.ram_shadow:     [512K]Precise   2 MB / 4
bus.scratch_shadow: [256]Precise    1 KB / 4, for 0x1F800000
```

```zig
pub const Precise = extern struct {
    /// Screen X in 16.16 — the raw MAC0 from the projection, unshifted.
    x: i32 = 0,
    y: i32 = 0,
    valid: u32 = 0,
    _pad: u32 = 0,
};
```

16 bytes rather than a packed 12 plus a side validity bitmap: a bitmap saves
4 MB and costs a second dependent load on the hottest lookup in the feature,
and `Bus` already carries a 6.8 MB `Recorder` and a 768 KB MDEC. Total ~8.4 MB,
a fixed field on the heap-allocated `Bus`. `ps1-wasm` pays it too; that is
accepted.

`@memset(0)` at `Bus` init leaves every entry invalid, which is the correct
initial state — unlike several devices, `Precise` needs no `.init()`.

### Where the FIFO is written

`doPerspectiveTransform` shifts `precise_sxy` on the same three lines that
shift `data_regs[12..14]`, and writes index 2 with the two MAC0 values from
lines 65-66 *before* their `>> 16`. Two rules that are easy to get wrong:

- **`sxyp` (data reg 15) mirrors sxy2 on read** (`cop2.zig:181`) and on write
  shifts the FIFO (`cop2.zig:200-203`). The precise FIFO must mirror both.
- **`mtc2` to sxy0/1/2 invalidates** the corresponding precise entry. The game
  is supplying its own screen coordinate; there is no sub-pixel to recover and
  a leftover one from three frames ago is exactly the stale-entry case.

### The propagation set

Minimal, and deliberately so:

| Site | Action |
|---|---|
| `mfc2` of data regs 12/13/14/15 | `gpr_shadow[rt] = precise_sxy[i]` |
| `lw` | `load_shadow = ram_shadow[addr >> 2]` (or scratchpad) |
| `sw` | `ram_shadow[addr >> 2] = gpr_shadow[rt]` |
| `sh`, `sb` into RAM | invalidate the covering word |
| `cpu.writeReg` | invalidate `gpr_shadow[index]` |
| `or rd, rs, $zero` / `addu rd, rs, $zero` | copy the shadow — the `move` idiom |

Everything else clears by falling through `writeReg`. Two traps:

- **The load shadow must obey the load-delay slot.** `cpu.zig:164-177` retires
  `load_r → delay_r → regs[]` across two steps, and `writeReg` cancels a
  pending load by clearing `delay_r` (`cpu.zig:255`). A shadow that ignores
  that attaches the precise vertex to whatever register the *previous*
  instruction loaded. `load_shadow`/`delay_shadow` shift on exactly the lines
  the register numbers do, and the `writeReg` cancel clears the shadow with it.
- **`or rd, rs, $zero` is the register-move idiom**, and dropping it costs real
  coverage: compilers emit it between the `mfc2` and the `sw` constantly. It is
  two lines in the existing opcode, guarded on `rt == 0`.

### The lookup

`Gp0Engine` resolves a vertex where it currently parses one, in the shared
vertex decode: the packed word gives `x`/`y` as today, and the parallel
`cmd_buffer_pgxp` entry gives `px`/`py` when the § 4 predicate holds and
`x << 16` / `y << 16` when it does not. `Sink` copies all four into
`command.Vertex`. `command.execute` is unchanged in shape — it already forwards
vertex fields to `Renderer`.

Only the three triangle paths consume `px`/`py`. Lines and rectangles carry the
defaults.

### Counters

`Gp0Engine` keeps four `u64`s — vertices seen, vertices resolved, identity
violations, and a fixed-point accumulator of displacement — exposed on `Gpu`
and read by `ps1-golden`. They are host-side instrumentation, not machine
state, and are excluded from the state hash for the same reason
`cdrom.pending_cycles` is.

## The gate

### With PGXP off — no output change, checked

`zig build test`, `zig build test-roms-pl`, `zig build test-roms-ja`,
`zig build trace-golden -- verify`, `zig build trace-golden -- stream-verify`
and `ps1-macos/test.sh` all byte-for-byte unchanged. No golden is recaptured
by this spec. If any of them moves, § 5's argument is wrong and the
implementation stops there rather than recapturing around it.

### With PGXP on — invariants and a ratchet

`zig build trace-golden -- pgxp` sweeps the ten workloads and reports:

```
croc-legend-of-the-gobbos
  GP0 vertices      1,284,551
  shadow resolved   1,197,832   (93.2%)  floor 90.0%  OK
  displacement      max 0.996 px, mean 0.263 px
  identity          0 violations                      OK
```

- **Identity violations must be 0.** Not a hope: the predicate *is* the
  fallback, so a violation counted here is a vertex that was correctly
  rejected. A non-zero count is a coverage diagnostic — it says invalidation is
  leaking — and the floor for it is 0 only in the sense that a leak worth
  reporting should be fixed at its source.
- **Max displacement must be < 1.0 px**, which follows from the predicate and
  so is really a check that the check is wired up. It is reported in 1/256ths.
- **The hit-rate carries a committed per-game floor**, ratcheted exactly like
  `test-roms-pl`'s `floor.txt`: a propagation regression shows up as a drop
  rather than as a subtly worse picture nobody notices. Floors are set from the
  first measured sweep, rounded down, and re-pinned deliberately when
  propagation improves.

The floors live beside the trace goldens. A game with no floor is a
`pgxp`-only warning, not an error — unlike a missing trace golden, which
stays fatal.

### Performance

`zig build ps1-bench-dual`, `-Doptimize=ReleaseFast`, best of five on a settled
machine, against the current HEAD number:

- **PGXP off must be within noise.** `cpu.writeReg` clearing a shadow entry is
  one store in the hottest function in the emulator, and `lw`/`sw` gain a
  branch each. This is not a formality — if it does not hold, the propagation
  moves behind a comptime-specialised `step()`, the same shape the `gpu_sink`
  build option already uses, and the fallback is written into the plan rather
  than improvised.
- **PGXP on is measured and reported, not gated.** It is an opt-in enhancement;
  a number is owed to the player, not a threshold.

## Tasks

Seven, strictly ordered.

| # | task | gate |
|---|---|---|
| 1 | `Precise`; the precise SXY FIFO in `cop2/`; `mtc2` invalidation | `gte_test`: RTPS/RTPT sub-pixel values, incl. negative; `sxyp` mirror; `mtc2` clears |
| 2 | Shadow tables on `Cpu`/`Bus`; the propagation set; load-delay discipline | `cpu_test`: mfc2→move→sw→lw round trip; the delay-slot cancel |
| 3 | Provenance through `writeGp0`, the FIFO, `Gp0Engine`, `Sink` | `gpu_test`: a vertex written by CPU store and by both DMA shapes |
| 4 | `px`/`py` on `command.Vertex`; `rasterizeTriangle` box-relative in 1/16 px | PGXP off byte-identical (§ the gate); a hand-built sub-pixel triangle |
| 5 | `sx0..sy2` on `Ps1PrimInstance`; `PrimBuilder`; `Rasterizer.metal` | Phase B/C fixture hashes unchanged; invariance at N ∈ {2,3,4,8} |
| 6 | `ps1_set_pgxp`; `PgxpSetting`; the `Video` menu item | round trip, absent key, `capi_test` |
| 7 | `pgxp` sweep in `ps1-golden`; the floors; the bench numbers | the sweep itself, on all ten workloads |

Task 4 is the one that can invalidate the spec, and it lands before any Metal
or app work for that reason: if the box-relative 1/16-px edge functions are not
byte-identical with PGXP off, § 5's argument has a hole and everything
downstream waits.

## Risks

- **`writeReg` is the hottest function in the emulator** and task 2 puts a
  store in it. The comptime-specialisation fallback is real but doubles the
  core module matrix (`gpu_sink` × `pgxp`), which is why it is a fallback and
  not the design.
- **1/16 px is a ceiling this design cannot raise later without revisiting
  Metal.** Going to 1/64 px would put `ps1_orient` at 2³⁵ and force `long` into
  the fragment shader. If the residual crawl at 1/16 px turns out to be visible
  on real content, that is the trade to reopen — the shadow table and the
  records already carry the full 16.16, so nothing upstream would change.
- **Coverage is unknown until task 7 runs.** The propagation set in § The
  propagation set is derived from what libgpu prescribes, not from a measured
  trace. If the hit-rate comes back at 40% rather than 90%, the missing idiom
  is found by instrumenting the *unresolved* vertices — which is what the
  counters are for — and the set grows. The identity net means a low hit-rate
  is a disappointing picture, never a broken one.
- **Games that build vertices outside the GTE get nothing**, by construction,
  since CPU mode is out of scope. 2D titles and software-transformed geometry
  will show a low hit-rate that is correct and not worth chasing.
- **PGXP on has no reference implementation to diff against.** Unlike every
  Metal phase, there is no software oracle for "correct sub-pixel position" —
  the identity invariant bounds the error but does not confirm the value.
  Avocado does not implement PGXP, so it is not an oracle here either. This is
  inherent to the feature and is the reason the default is off.
