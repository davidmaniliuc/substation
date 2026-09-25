# PGXP Phase 5 — the depth buffer

Fifth phase of the programme laid out in
`2026-09-09-pgxp-duckstation-parity-audit.md`. Phases 3 and 4 used the
vertex depth to decide *how* a primitive is shaded; this phase uses it to
decide *whether* a pixel is drawn at all.

**Goal.** DuckStation parity for its three depth settings —
`gpu_pgxp_depth_buffer`, `gpu_pgxp_transparent_depth`, `gpu_pgxp_disable_2d`
— so that 3D polygons sort per pixel by depth instead of by the game's
ordering table, which removes polygons poking through each other wherever a
game's coarse sort got the order wrong.

**Success criterion.** Two interpenetrating opaque 3D triangles produce the
same picture in either draw order, in BOTH rasterizers, bit-for-bit
identically; the three settings behave as DuckStation's do (differences
listed below, each deliberate); and every gate that holds today still holds,
unchanged and still strict.

**Motivation, stated honestly.** The report that opened this phase — Crash
1's N. Sanity Beach, "textures glitching, moving, popping" with PGXP on — was
first traced to something else: `thinPrimitive` cleared the depths of every
thin primitive, leaving wall and fence quads affine beside corrected
neighbours (fixed in `01066de`, texture correction 71.5% -> 100.0% on Crash).
The user reports the scene is still not right after that fix. A depth buffer
changes only which of two overlapping polygons wins a pixel; it does not move
a texture within a surface. So this phase ships a switch and a lockstep A/B on
that scene, and reports what the A/B shows rather than presuming it.

## Scope

In:

- `Vertex.iz`, an absolute integer reciprocal depth per vertex. The record
  grows 108 -> 120 bytes; `.p1fx` version bump.
- `flag_depth_test` and `flag_depth_write` in `Command.flags` (bits 2 and 3).
- A `clear_depth` record kind carrying a rectangle.
- All depth decisions in `gp0`: which polygons test, which write, when to
  clear, and `disable_2d`.
- A `u32` depth plane beside VRAM in the software rasterizer, and a third
  `.r32Uint` attachment in the Metal backend, with one integer test shared by
  both.
- Depth resets under Fill Rectangle, CPU->VRAM uploads and a VRAM copy's
  destination, in both rasterizers.
- `ps1_copy_depth`, so a Metal resync adopts the software depth plane.
- `pgxp_depth_buffer`, `pgxp_transparent_depth`, `pgxp_disable_2d`, all
  default OFF: C ABI setters, Swift settings, three Video menu items.
- Sweep counters `depth_tested` and `depth_clears`, with floors.
- A `depth` knob for `ps1-trace`, and the A/B on Crash 1.

Out:

- DuckStation's per-game database (`DisablePGXPDepthBuffer`,
  `gpuPGXPDepthThreshold`). The clear threshold is the constant 4096.
- Depth on LINES. DuckStation's `DrawPreciseLine` depth-tests lines; our
  lines have no sub-pixel path at all (`drawLine` takes `i16`), so there is no
  per-vertex depth to carry. Rectangles never test, as in DuckStation.
- Preserve projection precision (Phase 6).

## What the depth is

**`iz = round(2^30 / W)`**, where `W` is the vertex's PGXP depth in GTE units
(`pgxp.Value.z`, 1..65535), clamped to `[1, 2^30]`, and **0 when the vertex
carries no depth**. Computed once per vertex in `gp0`, in `f64`, and carried
in the record — never re-derived at replay time.

Three properties decide this shape.

- **1/W is affine in screen space.** A planar triangle's 1/W varies linearly
  across its screen projection, so the existing exact `interp` produces the
  per-pixel value and no perspective divide is needed. Storing W instead (the
  rejected option C) orders pixels identically and costs a per-pixel divide
  for nothing.
- **It is ABSOLUTE, not `rw`.** `rw` is normalised per primitive on its
  nearest vertex, because for interpolation the constant cancels. A depth
  TEST compares across primitives, where nothing cancels, so it needs a scale
  every primitive shares. That is why `rw` cannot be reused and why the
  record must grow.
- **It fits.** Every barycentric weight is under 2^29 (the oversized-primitive
  bound), `iz` is at most 2^30, so `interp`'s numerator is under 3 * 2^59 <
  2^61 — inside `i64` / Metal `long`, at every internal resolution, because
  neither the weights nor the area carries a factor of the scale.

**Larger `iz` is nearer.** The test is `iz_pixel >= stored`, which is
DuckStation's `LessEqual` on W. The plane clears to 0, which is infinitely
far, so the first 3D pixel always passes. Precision: at W = 65535, `iz` is
about 16384, so the far end resolves 1/W to one part in 16k — the same class
as DuckStation's `D32F`.

## What gp0 decides

Everything below is decided in `gp0` on the way to the sink, for the reason
`unify` and the Phase 4 bits are: a Metal replay has only the record.

**A polygon TESTS iff** the depth buffer is on (the accessor folds in the
master flag), every vertex carries a depth (`iz != 0` on all), the `f32` W
values are not all equal — compared on W, not on the quantised `iz`, as
DuckStation compares them (DuckStation's `is_3d` — a polygon at one depth is a 2D overlay
drawn with a projected position), and it is opaque OR `transparent_depth` is
on. A quad is judged across all FOUR vertices and both halves receive the same
bits, for the same reason `unify` judges quads whole: the halves share an edge.

**A polygon WRITES iff** it tests and it is opaque. A transparent polygon under
`transparent_depth` tests but never writes — DuckStation's
`depth_write = depth_test && transparency == Disabled`.

**Everything else neither tests nor writes**: rectangles, lines, polygons
without depths, and every polygon while the setting is off. Depth being
separate from `rw` means texture and colour correction are unaffected by any
of this.

**Clears**, recorded as `clear_depth` with a rectangle:

- **On a drawing-area change** (a GP0 E3/E4 whose value differs from the
  current one) — the whole plane, and only if
  something has been written since the last clear. DuckStation gates the same
  clear on `m_last_depth_z < 1.0`; ours is an explicit `depth_dirty` flag.
- **On a depth jump** — the drawing area, when a depth-tested polygon's
  average W is at least 4096 GREATER than the previous depth-tested polygon's
  (`average_z - last_z >= threshold`: signed, so only a jump AWAY from the
  camera clears). This is DuckStation's guess at "the game started a new
  pass", and like it the last-Z resets to the far end on every clear, so the
  polygon after a clear never triggers another. The average is taken over the
  polygon's own vertices (four for a quad) in `f32`, as DuckStation does; the
  decision is made once on the CPU and recorded, so no float reaches either
  rasterizer.

**`disable_2d`**: a primitive whose positions resolved but where some vertex
has no depth is drawn at its integer positions. DuckStation's `valid_w ==
false` path. Our `unify` already snaps a primitive with an UNRESOLVED vertex,
so the only new case is "resolved position, no `valid_z`" — typically a 2D
element a game built with CPU arithmetic, which CPU mode resolves. Counted as
`flat_2d_primitives`.

## The rasterizers

**One test, spelled the same way in both** — `renderer.zig` and
`Rasterizer.metal`, same scalar parameters in the same order, so the call
sites are comparable by eye, as `interpAttr` / `ps1_interp_attr` are:

    iz = interp(w0, w1, w2, area, iz0, iz1, iz2)
    pass = !test || iz >= stored
    written = pass && <the pixel is drawn: not a hole, clip and mask pass>
    if (written && write) stored = iz

**The depth is written only when the COLOUR is written.** A texel hole, a
pixel clipped by the drawing area and a pixel refused by the mask bit all
leave the stored depth alone. `putPixel` returns whether it wrote, which is
the one signature change in the software path.

**Software.** A `[1024 * 512]u32` depth plane beside VRAM (2 MB, inside the
heap-allocated `Bus`). NOT hashed by `state_hash.zig`: with the setting off it
is always zero, and with it on there is no golden to compare against — the
same argument that keeps the PGXP shadow tables out.

**Metal.** A third attachment, `.r32Uint`, at `[[color(2)]]`, scaled N x N
like VRAM, read and written through tile memory exactly as the sidecar is at
`[[color(1)]]`. No fixed-function depth: the test must be the integer
expression above, and fixed-function depth normalises to float. Tile-memory
access is ordered per pixel in submission order, the property the sidecar's
blend already relies on, so `HazardTracker` needs nothing new: depth is only
ever read at the fragment's own pixel. `Ps1PrimInstance` grows 51 -> 54 words
(`iz0..iz2`) and its `static_assert` moves with it.

**Allocated only while the setting is on.** The depth setting joins
`ContentView`'s `.id()` key beside the runner identity and the scale, so
toggling it rebuilds the coordinator, `MetalVram` and the pipelines through
the path a scale change already uses. Pipelines take a function constant for
the attachment's presence. Cost at 8x: 128 MB, and only when on.

## VRAM writes reset depth

Fill Rectangle, a CPU->VRAM upload and a VRAM->VRAM copy's destination set the
depth under them to 0, in both rasterizers, with the same wrapping as the
VRAM write beside them. Without it a later 3D polygon would test against
depth left by geometry the game has since painted over. DuckStation writes
`GetCurrentNormalizedVertexDepth()` there, which is FAR minus a batch counter;
we write exactly far. The difference is one batch step at the far plane and is
deliberate: ours is a constant, theirs depends on batching this core does not
have.

The copy writes its reset in the SAME pass that moves colour and sidecar —
the existing rule that a VRAM->VRAM copy moves every attachment in one pass,
so no second pass can resolve a self-overlap differently.

Resets happen whether or not the setting is on. Nothing reads the plane when
it is off, so they cannot change a pixel, and gating them would add a branch
to three paths for no behaviour.

## Resync

A resync adopts the software shadow as the picture. With depth on, the shadow's
depth plane must come too, or the next frame's depth tests run against a blank
plane and `PS1_LIVE_DIFF` reports a divergence that is the resync's fault.
`ps1_copy_depth(const Ps1*, uint32_t* dst)` publishes it beside
`ps1_copy_vram`, under the SAME seq, and `MetalVram` replicates it N x N as
`uploadNative` does VRAM. The runner copies it per frame only while the
setting is on (2 MB/frame).

## The settings

`pgxp_depth_buffer`, `pgxp_transparent_depth`, `pgxp_disable_2d` on `Bus`, all
**default OFF** — DuckStation's defaults — and therefore **not** assigned in
`Bus.init`. Each folds in the master flag in exactly one accessor per consumer
(`Bus.pgxpDepthBuffer`, `Bus.pgxpTransparentDepth`, `Bus.pgxpDisable2d`), and
`Gp0Engine` mirrors are set from those. `pgxp_transparent_depth` additionally
folds in `pgxp_depth_buffer`: it is a sub-flag and meaningless without it.

C ABI: `ps1_set_pgxp_depth_buffer`, `ps1_set_pgxp_transparent_depth`,
`ps1_set_pgxp_disable_2d`. Swift: three settings, three Video menu items,
greyed while PGXP is off; Transparent Depth is also greyed while the depth
buffer is off — the rule that a control which would silently no-op is shown
disabled.

## Gates

- **`verify` and `stream-verify` cannot move.** With PGXP off no vertex
  resolves, so every `iz` is 0, no polygon tests, and no `clear_depth` record
  is produced. The resets write a plane nothing reads. A moved golden is a
  gating bug, never a behaviour change to recapture.
- **Depth off, PGXP on: nothing changes.** No bit, no record.
- **`--pgxp-on` and the `pgxp` sweep force all three settings on**, per the
  rule that those instruments turn on every correction sub-setting. The tr1
  PGXP-on fixture therefore becomes the Metal parity gate for depth, and must
  be regenerated with the `.p1fx` version bump.
- **The sweep gains `depth_tested` (polygons that tested) and `depth_clears`**,
  each floored per workload, re-pinned in their own commit.
- **`synthetic-primitives.p1fx` gains one frame, APPENDED** (never reordered):
  two interpenetrating opaque triangles drawn in the "wrong" order, one
  transparent triangle under `transparent_depth`, a fill over part of the
  result, and a `clear_depth`. It is the per-feature rung for the Metal gate
  ladder.

## Testing

`gp0` (record-level, `gpu_stream_test.zig`):

- a 3D polygon records `flag_depth_test | flag_depth_write` and three `iz`;
- equal depths (2D) record neither;
- a transparent polygon records neither, then `flag_depth_test` alone under
  `transparent_depth`;
- both halves of a quad record the same bits;
- a drawing-area change records `clear_depth` only after a depth write;
- a depth jump of >= 4096 records a drawing-area `clear_depth`; a jump toward
  the camera does not;
- `disable_2d` snaps a resolved primitive lacking depths to integers;
- every one of the above records nothing with the setting off, or with PGXP
  off.

Renderer (`gpu_test.zig`):

- two interpenetrating triangles, both draw orders, identical VRAM;
- a transparent triangle under `transparent_depth` is hidden behind a nearer
  opaque one but writes no depth of its own;
- a mask-refused pixel and a texel hole leave the stored depth unchanged;
- fill, upload and copy reset the depth under them, wrapping at the VRAM edge.

Metal (`ps1-macos/test.sh`): the appended synthetic frame at 1x and
downsample-invariant at N in {2, 3, 4, 8}; the PGXP-on parity fixture with
depth on; a resync mid-scene adopts the depth plane (a hand-built case, since
no fixture exercises resync); the three settings and their greying.

Real game: `ps1-trace ... pgxp depth` — lockstep, since only `gp0` consumes
the setting and no game reads the depth plane — on Crash 1's N. Sanity Beach
(`explore`, frames 800-1250M) and every sweep workload, diffed against the same
run without `depth`, classifying changed pixels as "a polygon now hidden or
revealed" versus anything else. The report states whether the Crash scene the
user flagged changed, with frames.
