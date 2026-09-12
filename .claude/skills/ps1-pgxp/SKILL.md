---
name: ps1-pgxp
description: Use when touching pgxp.zig or PGXP-related code in cop2/, cpu/, memory.zig, dma.zig or gpu/ - sub-pixel geometry correction, the precise shadow tables, the identity check, vertex provenance through the GP0 FIFO, or the unify/weldPoint/thinIntegerTriangle rules that bound what PGXP may do to a primitive.
---

# PGXP

**PGXP** (`pgxp/`, `cop2/`, `cpu/`, `memory.zig`, `dma.zig`, `gpu/`) — keeps
the sub-pixel screen position the GTE actually computed instead of snapping
every vertex to a whole pixel. **Off by default** (`Bus.pgxp_enabled`,
`ps1_set_pgxp`, Video ▸ PGXP Geometry Correction), because off is the
configuration the byte-exact oracles cover.

**Four sub-settings hang off it** (`pgxp_cpu`, `pgxp_culling`,
`pgxp_vertex_cache`, `pgxp_tolerance`), each ANDed with the master flag in
exactly one place, `Bus.pgxpConfig` — so there is no state in which one acts
while geometry correction does not, and the Video menu greys them rather than
offering a control that silently no-ops. `cpu` and `culling` default ON;
a default-ON flag on `Bus` must ALSO be assigned in `Bus.init`, because the
`@memset` there does not respect field defaults. Both of them shipped broken
for one build over exactly that.

**`Cop2` cannot be handed a setting by `Bus`** — it is a field of `Cpu`, which
`Bus` cannot reach. Everything PGXP contributes to a GTE command travels in one
`pgxp.Config` passed at the dispatch site in `exec.zig`. `Gp0Engine` has the
same problem and solves it the other way, with mirrors `Bus` keeps in step.

Five things will otherwise be re-derived painfully:

- **The identity check is the safety net, not just the gate.** A `pgxp.Value`
  is judged by the WORD it was recorded against, not by its coordinates: a
  candidate is admitted only when `p.flags & Value.valid_xy == Value.valid_xy
  and p.word == word`, where `word` is the raw command word the wire is
  carrying right now. A stale shadow entry was recorded against some other
  word, so it fails the match and is discarded; one that passes was recorded
  against exactly this integer SXY. That is why there is no invalidation hook
  on OTC, MDEC or CD DMA, and why adding one is not a bug fix — missed
  invalidation costs coverage, never correctness. **Never make the predicate an
  assertion**, and never log per vertex: a busy frame carries tens of
  thousands.
  Two guards sit either side of the match and are easy to mistake for
  redundant:
  - **A production-site saturation rejection** (`cop2/opcodes.zig`): a
    projection whose unsaturated `x`/`y` disagree with the saturated `SX2`/
    `SY2` that actually got written records `Value.none` instead. Without it,
    an overflowing MAC0 would still record a word that matches the (clamped)
    register, and the shadow would describe a vertex 1000+ px from where
    hardware drew it.
  - **A clamp in `gpu/primitive.zig`'s `toFixed`**, which pins a resolved
    vertex's converted 16.16 position inside the pixel its own wire word
    names, `[x << 16, (x << 16) + 0xFFFF]`. It exists because `f32` cannot
    represent every 16.16 position: for `|x|` in `[512, 1024)` an ulp is
    `4/65536`, so a fraction of `65534/65536` or more rounds UP onto the next
    integer, and the GPU's 11-bit coordinate fold then turns 1024 into -1024 —
    a vertex 2047 columns adrift, silently, from a word match that was
    perfectly correct. The clamp is not a second identity check; staleness is
    decided solely by the word match above.
- **The GP0 write path is address-blind at all three producers**, and the FIFO
  is 16 words deep, so provenance rides the FIFO (`Gpu.fifo_pgxp`,
  `Gp0Engine.cmd_buffer_pgxp`). `Bus.pgxp_pending` is only the device that
  carries it across `write`'s generic signature, and is consumed-and-cleared by
  the `gpu_data` arm.
- **The propagation set was deliberately tiny until Phase 2 and is now
  broad.** The original six: `lw`/`sw` on the RAM and scratchpad shadows,
  `or`/`addu` against `$zero` (the register-move idiom), MFC2 of SXY0/1/2,
  `swc2`, and — since 2026-08-31 — **`mtc2`/`lwc2` INTO SXY0/1/2, which is the
  other direction and was the last big hole.** Phase 2 added half-word loads
  and stores, the unaligned forms, all 64 GTE registers, `hi`/`lo`, COP0, and
  CPU mode's full instruction set (immediates, register arithmetic, logicals,
  shifts, multiply/divide) behind `Bus.pgxp_cpu`.
  `swc2` is the one that matters most on the way out: libgte's `gte_stsxy*`
  macros are `swc2` straight into a display-list primitive, and it is how most
  games move a projected vertex. It was missing from the first implementation
  and adding it took Crash Bandicoot from 0% to 99% and Silent Hill from 0% to
  76%. The inbound direction matters because a game may **cache projected
  vertices rather than re-project them**, loading a packed SXY back into the
  GTE (`gte_ldsxy*`) to emit a second primitive; `writeData`'s blanket clear
  threw the sub-pixel away on the way in. Hooking it is
  `Cop2.writeDataPrecise`, and it took Crash Warped 92.9% -> 99.2%, Crash 2
  94.4% -> 99.2% and **Tomb Raider 47.0% -> 92.5%**. Everything else falls
  through `writeReg` and clears the shadow. Do not add hooks without a
  measurement from `trace-golden -- pgxp` showing the hit-rate needs them.
- **The BIOS logo is the cheapest reproduction this feature has** — no disc,
  no game, no Metal, `bios-only`, deterministic, the frame at ~140M
  instructions. `ps1-trace <bios> <any cue> 150000000 <dir> lean pgxp` with
  `PS1_VRAM_DUMP=1`, run once with the `pgxp` flag and once without, then diff
  `vram_140.ppm`. Two things make the diff readable. **Classify a changed
  pixel as INTERIOR or SILHOUETTE before reading anything into it**: 386 of
  the 398 pixels PGXP darkens there are the logo's outline moving by a
  sub-pixel, which is the feature working, and only 12 are cracks. An earlier
  pass called all 434 cracks on the grounds that they had no newly-painted
  pixel beside them, and that test does not distinguish the two — a shrinking
  silhouette has nothing to pair with either. And **`resolved=0` is what tells
  you the run never reached the logo**: the first A/B here diffed to zero at
  120M and looked like "PGXP changes nothing".
- **A missing hook is a VISIBLE artifact, not just a lower number, and the
  shape is specific**: sparse dotted-line cracks tracing polygon edges, which
  over an additively-blended primitive read as dark dashes and over a textured
  surface read as speckled holes. The cause is a vertex shared by two
  primitives that resolves in one and not the other — the two no longer meet,
  and the sub-pixel gap goes unpainted. So partial coverage is not merely
  partial benefit; it is its own defect, which is the argument for chasing the
  hit-rate rather than accepting it.
- **To find the missing hook, count WHY a `precise_sxy` slot is empty, not
  where the vertex came from.** Chasing provenance from the GP0 end is the
  obvious move and it is the long way round: a writer-PC table over the RAM
  shadow named one `swc2 sxy0` site for 97% of Crash Warped's misses, which
  only says the store was reached with an empty slot. A four-way counter on the
  slot itself (shifted in from an empty slot / `make` out of i32 range /
  cleared by `writeData` / never touched) attributed **100%** of them to
  `writeData` in one run and ended the search.
- **Neither rasterizer computes in 16.16.** Both reduce to 1/16 px taken
  relative to the primitive's bounding box, which the oversized-primitive rule
  caps at 1023 px — hence 2^14 per coordinate, 2^29 per cross product, `i32`.
  **The fill-rule bias stays at `-1` in both**, and it is the "not all three
  zero" clause that is restated at whole-pixel granularity (`w_i >= 256`)
  instead. Scaling the bias is exactly equivalent with PGXP off and wrong with
  it on: an edge function IS twice the area of (edge, pixel), so a bias of B
  discards every interior pixel closer than `B / |edge|` to a top-left edge —
  about 1/L px for an L-pixel edge, which reads as sparse single-pixel dropouts
  that flicker as geometry moves. Both rasterizers shipped with the scaled bias
  first and both had to be corrected; the two tests that pin it
  (`gpu_test.zig`, `MetalScaleTests.swift`) were each verified to FAIL against
  it, and an earlier version of each could not, because the erosion is
  invisible on a long edge and on the mirror image of the same edge.
- **Two rules bound what PGXP is allowed to do to a primitive, and both are
  decided in `gp0` on the INTEGER geometry, before the sink — so the record a
  Metal replay consumes is already normalised and the two rasterizers cannot
  disagree.** Neither needs a `pgxp_enabled` gate: with PGXP off no vertex is
  ever marked `resolved`, so neither can fire, and `verify` stays green.
  - **A primitive's vertices come from ONE coordinate space** (`unify`). A
    triangle holding one sub-pixel corner and two integer ones is not a
    refinement of the shape hardware drew, it is a third shape. A quad is
    judged across all FOUR vertices, because its halves share an edge and
    unifying them separately leaves that edge in two spaces. `Point.resolved`
    is an explicit flag, NOT `px != x << 16`: a vertex whose sub-pixel lands
    exactly on the grid is indistinguishable from an unresolved one that way,
    and the rule would then drag its neighbours back on account of a vertex
    that had in fact resolved — two existing tests caught exactly that.
  - **A sub-pixel move must not DELETE geometry hardware draws**
    (`thinIntegerTriangle`). Sampling is at whole-pixel positions and the
    integer vertices are what guarantee hardware covers one; translate a thin
    triangle by a fraction and it can miss every sample point. A 2x1 triangle
    hardware paints with 2 pixels painted **ZERO** at 7 of the 15 sub-pixel
    offsets. So a primitive thinner than 1.5 px anywhere keeps its integers.
    **The criterion is THINNESS, and the two cheaper guesses were both tried
    and both fail**: area does not work (a right isoceles triangle survives
    from leg 2 up, twice-area 4, while a 2x1 at twice-area 2 does not) and
    neither does the bounding box (a diagonal sliver in an 8x8 box still
    vanishes at 8 of 255 offsets). The 1.5 is measured: over 3,678 random
    small triangles that paint at integer positions, a translation deleted 35
    with no rule, 3 at a 1.0 threshold, none at 1.25 or above.
  - **A FRAME's vertices come from one coordinate space too** (`weldPoint`).
    The rule above is per PRIMITIVE, and that is not enough: two primitives
    sharing an edge are judged separately, so one can be fully resolved and the
    other fully unresolved — each internally consistent, `mixed_primitives`
    counting NEITHER — and the shared edge is then drawn in two places up to a
    pixel apart, with nothing painting the gap. Measured on the BIOS logo:
    of 32,043 shared integer edges, 372 were placed differently by their two
    primitives and **every one was a resolved vertex meeting an unresolved
    one** — none was a disagreement between two accepted sub-pixel values.
    The rule is that the FIRST vertex at an integer position fixes the position
    every later vertex there is drawn at, so an unresolved vertex can adopt a
    sub-pixel position and a resolved one can lose its own; the point is only
    that the frame agrees with itself. It runs AFTER `unify` (a primitive
    snapped back to integers must publish its integers), the table is cleared
    at the frame boundary (the same integer coordinate is a different model
    vertex next frame, and a surviving entry pins geometry instead of letting
    it move), and a collision is a MISSED weld and never a wrong vertex — the
    key is compared before the position is used and an occupied slot is left
    alone rather than evicted. Two cheaper explanations were tested and both
    eliminated first: **stale shadow entries** (wiping the whole shadow once a
    frame gives a byte-identical image) and **bounding-box-relative
    quantisation** (`base << 16` is an exact multiple of the 1/16-px step, so
    it cancels out of `toQ`'s rounding and two boxes cannot round a shared
    vertex differently).
  Both hold back real geometry and the sweep reports how much
  (`mixed_primitives`, `thin_primitives`): silent-hill snaps 43,850 mixed
  primitives, and ~19% of Crash Warped's primitives are thinner than 1.5 px.
- **Partial coverage is its own defect, not merely partial benefit, and that
  is the argument for chasing the hit-rate rather than accepting it.** The two
  rules above bound the damage; they do not remove it. A vertex shared by two
  primitives that resolves in one and not the other still leaves the two not
  meeting. A game in the 40-90% band can therefore look WORSE with PGXP on
  than off, which is the real reason the feature ships off by default.
- **1/16 px is a ceiling, not an accident**: raising it means putting `long`
  into Metal's per-fragment inner loop. The shadow tables and the records carry
  the full 16.16, so nothing upstream changes if that trade is ever reopened.
  Its counters (`Gp0Engine.PgxpStats`) and the shadow tables are deliberately
  **NOT** in `ps1-golden/src/state_hash.zig`: with PGXP off they are always
  zero, and with it on there is no golden to compare against. Their coverage is
  `trace-golden -- pgxp`, whose per-game floors are re-pinned deliberately in
  their own commit.

**CLOSED 2026-09-12: the three games stuck at exactly 25,854.** `croc`,
`resident-evil` and `metal-gear-solid` each resolved precisely that many
vertices — the BIOS licence logo alone, identical on every disc — with
`identity_fail` at 0, so no entry ever existed for their own geometry rather
than a stale one being rejected. **The cause was CPU-side geometry, and CPU
mode is the whole fix**: croc 12.6% -> 99.4%, resident-evil 44.5% -> 98.5%,
mgs 50.6% -> 96.5%. The half-word memory hooks, which were the leading
hypothesis going in, did not move them by a single vertex. The standing note
that "Croc ends a 600M run with zero live RAM shadow entries" was a true
observation pointing at the right conclusion — its vertices never reach RAM by
`sw` or `swc2` because they never leave the CPU registers in a form those hooks
see.

**CPU mode therefore ships ON, diverging from the reference**, which treats it
as a per-game workaround. Off would mean shipping a fix nobody turns on. The
argument is the partial-coverage one below: the 40-90% band is where PGXP looks
WORSE than off, and CPU mode is what empties it. PGXP itself still ships off,
so this default only reaches a player who opted in.

**The open question this left is `clamped`.** Nine of ten workloads clamped
ZERO vertices before CPU mode shipped on; croc now clamps 81,466 of its 199,788
resolved vertices and spyro 52,591. The counter cannot distinguish a shadow
that landed a hair below its own integer (benign, 1/65536 px) from one that
genuinely drifted a pixel or more (not benign, and what `pgxp_tolerance`
exists to refuse). Splitting that counter is the cheapest next measurement, and
it belongs before any claim that CPU mode's PICTURE is as good as its hit rate.
Nobody has looked at a frame.

