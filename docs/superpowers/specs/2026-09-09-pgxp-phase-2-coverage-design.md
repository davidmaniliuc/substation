# PGXP Phase 2 — coverage

Second phase of the programme laid out in
`2026-09-09-pgxp-duckstation-parity-audit.md`. That document is the reference
for what DuckStation does and why; this one specifies what we build.

**Goal.** Make PGXP resolve vertices in the games where it currently resolves
none. Croc, Metal Gear Solid and Resident Evil each resolve exactly 25,854
vertices today — the BIOS licence logo, identical on every disc — with
`identity_fail` at 0 and, for Croc, zero live RAM shadow entries at the end of
a 600M-instruction run. No shadow is ever created for their own geometry.

**Success criterion.** Those three move off 25,854 in
`trace-golden -- pgxp`, and `trace-golden -- verify` stays green with PGXP off.

**Why this phase comes before the visible one.** Texture correction, colour
correction and the depth buffer all consume per-vertex data that only exists
where PGXP resolved the vertex. Shipping them first would change nothing at all
in a third of the library.

## Scope

In:

- The value representation, reworked from a coupled screen-position pair to
  DuckStation's per-halfword form with a depth term.
- Float projection in RTPS/RTPT, which is where the depth term comes from.
- The shadow set: all 64 GTE registers, COP0, `hi`/`lo`.
- The memory-mode hooks we are missing: half-word and byte loads and stores,
  and the unaligned `lwl`/`lwr`/`swl`/`swr`.
- CPU mode: propagation through arithmetic, logical, shift and multiply/divide
  instructions, behind its own setting, defaulting off.
- The vertex cache, behind its own setting, defaulting off.
- The tolerance setting.
- Culling correction — float NCLIP.
- The settings surface for the four new switches, across the core flag, the C
  ABI and the app's Video menu.

Out, deferred to Phase 3: texture correction, perspective-correct colours, the
depth buffer, `disable_2d`, `transparent_depth`. Out, deferred to Phase 4:
preserve projection precision. Out permanently: DuckStation's widescreen
aspect-ratio hack, which shares the RTPS float path but is a different feature.

## The value

`ps1-core/src/pgxp.zig` becomes `ps1-core/src/pgxp/pgxp.zig`, re-exported from
`root.zig` under the old path so no frontend import changes. `Precise` is
replaced by:

```zig
pub const Value = extern struct {
    /// Precise value of the word's LOW halfword.
    x: f32 = 0,
    /// Precise value of the word's HIGH halfword.
    y: f32 = 0,
    /// Depth term. For a projected vertex this is the W texture correction
    /// and the depth buffer will consume in Phase 3.
    z: f32 = 0,
    /// The 32-bit integer this entry was recorded against. The staleness
    /// check compares against it; see below.
    word: u32 = 0,
    flags: u32 = 0,
};
```

Twenty bytes, `extern struct` for the same reason the old one was: it lives in
`Bus`'s shadow tables and in the GP0 FIFO. It does **not** cross the C ABI —
only the record's `px`/`py` do, and those stay 16.16 — so this costs no header
change and no fixture regeneration.

The naming carries the phase's central idea. `x` and `y` are **not** screen x
and screen y; they are the precise values of the two halves of a 32-bit word.
For a packed SXY the two coincide, and for anything else they are two tracked
halves. That generalisation is the entire reason CPU mode is possible: a
coupled screen-position pair has nothing coherent to say the moment a game
splits a word into two registers, which is what the current representation
cannot survive.

Flags: `valid_x`, `valid_y`, `valid_z`, plus `low_z`/`high_z` recording which
half a z arrived from (so a half-word write can retire it) and `tainted_z`
meaning x or y has been altered since the z was recorded, so the z loses to an
untainted one when two values are combined.

Memory cost: the RAM and scratchpad shadows go from 16 to 20 bytes an entry,
8.4 MB to 10.5 MB. `Bus` is heap-allocated, so this is a size change and not a
stack problem.

## Production — the projection recomputed in float

`cop2/opcodes.zig`'s RTPS/RTPT keeps its integer path byte for byte and gains a
float one beside it:

```
z = max(H / 2, SZ3)
x = IR1 * (H / z) + OFX / 65536
y = IR2 * (H / z) + OFY / 65536
```

with x and y clamped to -1024..1023, recorded into `precise_sxy[2]` with
`word` set to the packed SXY2 register and all three valid bits set, then
shifted through the FIFO exactly as the integer registers are.

This **replaces** keeping the raw MAC0. Two reasons, and the second is the one
that forces it:

1. It is the ideal projection rather than the hardware's, so it also removes
   the UNR divide's quantisation, not just the `>> 16`.
2. There is no z on the MAC0 path. Every Phase 3 consumer needs one, and this
   is where it comes from.

The consequence to watch: the float result does not generally reproduce
`MAC0 >> 16`, so the games at 99% today may move. `floors.txt` will say so on
the first sweep. A drop there is a finding to explain, not automatically a bug.

## Staleness

`Precise.resolves(ix, iy)` — admit the shadow only if `px >> 16` reproduces the
integer coordinate on the wire — is replaced by DuckStation's model: each entry
stores the integer word it was recorded against, and any read validates it,
clearing all flags when the register or memory word no longer holds that value.

This is not a weakening. The stored word for a projected vertex **is** its
packed integer SXY, so a match means the precise value agrees with this
vertex's integers exactly — the same "agrees to within a pixel" property the
identity check gives, reached by a different route.

It is however forced, and the reason is worth recording because it is the whole
argument for the representation change. Consumption-time identity checking
requires an integer to check against. Once intermediate arithmetic values are
tracked, a shadow half is not a screen coordinate and has no such integer.
Record-time word matching is the only model that works for CPU mode.

What we give up: the current design's "invalidation is coverage, never
correctness" property, which is why there are no invalidation hooks on OTC,
MDEC or CD DMA today. Under the new model an untracked write that happens to
leave the word unchanged leaves a stale entry admissible. That is precisely
DuckStation's exposure too, and the tolerance setting is its mitigation.

## Storage and the shadow set

Existing, kept: 32 GPR shadows, the two load-delay shadows, one entry per
32-bit word of RAM and scratchpad.

Added:

- `hi` and `lo`, which `mult`/`div` write and `mfhi`/`mflo` read.
- All 64 GTE registers, replacing `Cop2.precise_sxy[3]`. SXY0/1/2 keep their
  FIFO-shift behaviour; the rest are plain slots. `mtc2` to SXYP (register 15)
  pushes the FIFO, and registers 29 and 31 are read-only and ignored.
- COP0, for `mfc0`/`mtc0`.

## Memory mode — the hooks we are missing

Word `lw`/`sw` already exist and keep their behaviour, with the value type
swapped, as do `lb`/`lbu`/`sb`, which invalidate — a byte cannot carry a
coordinate, and the reference invalidates there too. Added:

- **`lh`/`lhu`** — load the addressed half into `x`, validating only that
  half's 16 bits. `y` is then set to the sign extension of `x` (or zero for the
  unsigned form) and marked valid only if `x` is, so no fabricated value is
  produced.
- **`sh`** — write `x` into the addressed half of the destination word,
  leaving the other half alone, and merge the z with the `low_z`/`high_z`
  bookkeeping.
- **`lwl`/`lwr`/`swl`/`swr`** — the unaligned forms. Ours invalidate the whole
  word today; the reference merges the surviving part of the destination
  instead, which is what keeps a coordinate alive across the two-instruction
  unaligned idiom.

Half-word tracking is the leading hypothesis for Croc, whose shadow count is
zero: a game that stores its two coordinates with separate `sh` instructions
never touches the one hook we have.

## CPU mode

Behind `pgxp_cpu`, default off, matching DuckStation — it is a per-game
workaround there, not part of the shipped picture, and it is the part of PGXP
most able to make things worse.

The op set, from the audit: `move`, `addi`/`addiu`, `andi`, `ori`, `xori`,
`slti`/`sltiu`, `lui`, `add`/`addu`, `sub`/`subu`, `and`, `or`, `xor`, `nor`,
`slt`/`sltu`, `mult`/`multu`, `div`/`divu`, `sll`, `srl`, `sra`, `sllv`,
`srlv`, `srav`, `mfc0`, `mtc0`.

Arithmetic is done on the two halves in `f64`, with three shared helpers
modelling the 16-bit boundary: a sign fold (round to a 1/65536 grid and
reinterpret as signed), an unsign (add 65536 to a negative), and an overflow
extract (arithmetic shift of the truncated integer part down 16). Addition
carries between halves and truncates on 16-bit overflow; multiply splits into
four half-products recombined into a hi/lo pair; the shifts special-case 16 as
a whole-half move, which is the pack/unpack idiom that matters most.

Three behaviours are deliberate carve-outs in the reference and are reproduced
because they are bug fixes, not taste. Recorded here so nobody "simplifies"
them later:

- `sll` by 16 or more sets the valid bits from the source's *y* bit rather than
  marking x valid outright. Marking x valid when y was not **breaks Spyro**.
- The right shifts fall back to the rounded integer values when the shift is
  signed, non-variable, under 16, and the source carries no valid z — too many
  false positives otherwise, Persona 2 named.
- The three-way split in the right shifts on whether a component survives the
  shift at all, rather than shifting both halves unconditionally.

Every op validates its sources before reading them and marks its result
`tainted_z`, except the pure moves.

## Vertex cache

Behind `pgxp_vertex_cache`, default off. A table keyed on the packed integer
position, written on every RTPS and consulted when the address lookup misses.
DuckStation's is 2048x2048 entries covering the ±1024 SXY range, which at our
20-byte value is 83 MB, allocated only when the setting is on; we size ours the
same rather than inventing a number, and it is heap-allocated on enable, not a
field in `Bus`.

A cache hit deliberately reports its z as **not** valid even when it has one:
the position is enough to remove jitter, and the depth is untrustworthy for a
vertex found this way.

## Tolerance

`pgxp_tolerance`, a float, default -1 meaning disabled. When non-negative, a
resolved vertex whose precise position sits further than the tolerance from the
integer one in either axis is rejected in favour of the integer. It is the
mitigation for the staleness exposure noted above.

Open question flagged for the first sweep: our floors were measured against an
exact predicate. If the float projection plus word matching admits vertices the
old check rejected and the picture suffers, a small positive default may be
better for us than DuckStation's -1. Decide on measurement, not up front.

## Culling correction

Behind `pgxp_culling`, default **on** when PGXP is on, matching DuckStation.

`cop2/opcodes.zig`'s `opNclip` currently reads the three packed integer SXY
registers and writes the cross product to MAC0. With correction on, and only
when all three precise SXY entries validate and carry x, y and z, the same
cross product is computed in `f32` from the precise positions, and a result
whose magnitude lands between 0.1 and 1.0 is pushed away from zero before being
written back.

That last clause is the point of the feature. NCLIP's sign decides backface
culling, and on a triangle near-degenerate at integer precision the sign flips
essentially at random, so facets on a curved surface blink as the camera moves.
Requiring a valid z is what keeps game-constructed SXY values, which have no
depth, out of the accurate path.

It touches one function and nothing downstream: no record change, no ABI
change, no rasterizer work, no fixture regeneration.

## Consumption

`gpu/gp0.zig`'s `getPointPrecise` keeps its shape. The candidate now arrives
from the FIFO as a `Value`; it is admitted on the word match plus the tolerance
check instead of the identity check, and its `x`/`y` floats are converted to
the record's 16.16 `px`/`py` at that boundary. The z is carried no further in
this phase — Phase 3 adds the record field.

Provenance still rides the GP0 FIFO (`Bus.pgxp_pending`, `Gpu.fifo_pgxp`,
`Gp0Engine.cmd_buffer_pgxp`) rather than DuckStation's address-keyed lookup,
because our GP0 write path is address-blind. That difference is deliberate and
unchanged.

**`unify`, `thinIntegerTriangle` and `weldPoint` are untouched.** They are
consequences of our integer rasterizers, DuckStation has no counterpart to any
of them, and nothing in this phase removes the need for them. `weldPoint` in
particular is not the vertex cache under another name: it makes one frame agree
with itself, where the cache is a fallback lookup across frames.

## File layout

`pgxp.zig` grows past the ~600-line limit, so it becomes a directory following
the `spu/`, `cdrom/` pattern:

```
pgxp/pgxp.zig    the Value type, the flags, the f16 boundary helpers
pgxp/ops.zig     the CPU-mode instruction implementations
pgxp/cache.zig   the vertex cache
```

split further if `ops.zig` runs long. `root.zig` re-exports so
`ps1_core.pgxp.Value` resolves.

## Settings surface

Four new switches beside the existing one, each following `ps1_set_pgxp`'s
shape: `ps1_set_pgxp_cpu`, `ps1_set_pgxp_vertex_cache`,
`ps1_set_pgxp_culling`, `ps1_set_pgxp_tolerance`. In the app they join Video ▸
PGXP as toggles, with tolerance a submenu of a few values plus Off, persisted
the way `PgxpSetting` already is. Defaults: geometry off, culling on, CPU off,
vertex cache off, tolerance off.

**The four are sub-settings of geometry correction, not peers of it.** Every
one is `&&`-gated on the master flag in the core, exactly as the reference
gates its own (`gte.cpp:1274` for culling, `gpu_hw.cpp:126` for texture
correction). "Culling on by default" therefore means on the moment the player
ticks Geometry Correction, never on out of the box — there is no state in
which culling correction acts while geometry correction does not. In the menu
the four are **disabled** while the master is off rather than merely
ineffective: a tickable box that does nothing is worse than a greyed one, and
greyed is what the `&&` already means.

**Revisit CPU mode's default at the end of the phase, with the sweep in
hand.** It is off here because it is off in the reference, where it is a
per-game workaround. If it turns out to be what moves Croc, Metal Gear Solid
and Resident Evil off the licence logo, then off means shipping a fix nobody
turns on, and the reference's reasoning does not transfer. Decide on the
measurement.

## Testing

**The hard gate is `trace-golden -- verify` green with PGXP off.** The
representation change must be invisible there. Nothing in this phase is allowed
to move a trace golden; if one moves, that is a bug in the gating, not a
behaviour change to recapture.

**The coverage gate is `trace-golden -- pgxp`.** Croc, MGS and Resident Evil
moving off 25,854 is the success criterion. Floors are re-pinned in their own
commit at the end, with the sweep quoted in the message.

**Unit tests** in a new `ps1-core/tests/pgxp_test.zig`, added to
`unit_test_files` in `build.zig`. Each behaviour that has a name in this
document gets a test written before its implementation, and the ones that
encode a carve-out must be verified to fail against the naive version:

- the pack/unpack round trip — `sra 16` then `sll 16` returns the half
- `sll 16` does not mark x valid from an invalid y (the Spyro rule)
- the signed-shift integer fallback (the Persona 2 rule)
- half-word load and store keep the untouched half
- a word validate clears an entry whose register has changed
- addition carries between halves and truncates at the 16-bit boundary
- a vertex-cache hit reports its z invalid
- tolerance rejects a vertex outside it and admits one inside
- float NCLIP nudges a magnitude in (0.1, 1.0) away from zero
- `unify` and `thinIntegerTriangle` still hold on the new value type

**The BIOS logo A/B** stays the cheap visual reproduction: `ps1-trace` at 150M
instructions with `PS1_VRAM_DUMP=1`, once with the flag and once without,
diffing `vram_140.ppm`. Classify a changed pixel as interior or silhouette
before reading anything into it.

## Risks

**The float projection may move the games that already work.** Nothing else in
the phase is as likely to. It is measured on the first sweep and it is
reversible in isolation — the integer path is untouched, so falling back to
MAC0 for x/y while keeping the float z is a one-line retreat if the numbers
demand it.

**CPU mode's carve-outs are game-specific and we cannot test the games they
name.** Spyro is in `games/`; Persona 2, Jet Moto and Racingroovy VS are not.
Those rules are reproduced on the reference's authority and the tests pin the
behaviour, not the game.

**83 MB for the vertex cache is a lot on a Mac app.** It is opt-in and
allocated on enable. If it proves useful enough to default on, shrinking it is
its own measurement.

**The staleness model loses a property we currently rely on.** Documented above
under Staleness; the tolerance setting is the mitigation, and the first sweep
is what says whether it needs a non-default value.
