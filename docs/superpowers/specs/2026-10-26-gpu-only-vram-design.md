# GPU-only VRAM: Metal is the machine's VRAM, dual stays per game

**Date:** 2026-10-26
**Status:** draft for review
**Follows:** `2026-10-20-metal-renderer-into-zig-design.md` (spec 1 of 2, done
2026-10-26), which names this as spec 2 and leaves it undesigned.
**Precedes:** `2026-10-26-session-ghostty-parity-design.md` (bfc0431). That
spec is parked until this one lands. The two touch different files except
`ps1-session/src/session.zig`'s settings, and the parity spec's settings
struct gains one field from this one (below).

## Intent

The macOS app rasterizes every primitive twice. `libps1core.a` builds
`gpu_sink = .dual`: the core records the GP0 stream for Metal, and also
executes every record in the software rasterizer on the raster worker
(`gpu/worker.zig`), so that `Bus.gpu.vram` is a complete, exact VRAM. The
picture the player sees comes from Metal. The software copy exists for the
handful of things that READ VRAM on the CPU side: GPUREAD, savestates, rewind,
runahead, the resume thumbnail, the 24-bit display and the resync that rebuilds
the Metal texture.

**This spec makes the Metal texture the only VRAM in the app by default.** The
software rasterizer stops running, and each of those readers gets its pixels
from Metal instead. The current dual mode stays, unchanged, as a per-game
override for games whose readbacks Metal cannot serve well.

The goal is performance, said by the user. The measured stake (2026-10-16,
Crash Warped in-level, JIT, PGXP, 6x, rewind on): the app used 55% of a core,
of which the raster worker was **13.4%**, on P cores despite utility QoS.
On 2026-10-14, dropping only the per-frame raster sync did not lower total
CPU, because the same work then overlapped. Removing the work is the only
thing that does.

**What success means is the builder's assumption, not the user's answer**: the
user said "for perf mainly" and did not choose between total CPU and power
while playing, and fast-forward headroom. This spec takes **total CPU per
emulated frame while playing at 1x speed** as the primary measure, and
fast-forward headroom as the secondary one. The two move together here, so the
choice does not change what gets built. It changes only what Plan D reports
first.

## Prior art

DuckStation's hardware renderer is this design. Its VRAM lives on the GPU,
and `GPU_HW::ReadVRAM` downloads a rectangle when the CPU reads it
(`gpu_hw.cpp:3459`). Its "software renderer for readbacks" (a software copy
rasterized alongside, i.e. our `.dual`) is OFF by default and forced per game
by the `ForceSoftwareRendererForReadbacks` game-database trait
(`game_database.cpp:671`). Its in-memory states (runahead, rewind) keep a GPU
texture copy of VRAM rather than reading back (`GPU_HW::DoMemoryState`,
`gpu_hw.cpp:452`). Read it for behaviour only. The shape below follows this
codebase's own seams.

## Goals

1. **The software rasterizer does not run in the app by default.** No raster
   worker is attached, no record is executed in software, and no 1 MB VRAM
   copy is made per frame. Draw-environment and transfer bookkeeping still
   run on the emulator thread, as they do today under the worker.
2. **Every CPU-side VRAM reader is served from Metal.** That covers GPUREAD
   (a GP0(C0) transfer), savestate save, the resume thumbnail, rewind capture,
   runahead, the 24-bit display and every resync. The bytes are native
   1024x512 at every scale: the top-left subtexel of each block, which is what
   `MetalVram.readbackNative` already returns.
3. **The stream is lossless.** Under GPU-only nothing can repair a lost
   mutation, so no frame, chunk or record may be dropped. Recorder overflow
   and oversized frames, the two remaining drop causes, are made impossible
   rather than repaired.
4. **Dual stays, per game, and switching is cheap.** A built-in game table
   names the games that need dual. The mode can also change at any frame
   boundary: GPU-only to dual seeds the software VRAM from one full readback,
   and dual to GPU-only stops rasterizing.
5. **The core's other frontends are untouched.** `ps1-wasm`, `ps1-golden`,
   both ROM suites, `ps1-debug`, `ps1-trace` and the bench keep the software
   rasterizer. With the new switch at its default, the core behaves exactly as
   today, so **no golden can move**.

## Non-goals

- **Changing what Metal draws.** No shader change to the rasterizer. The
  display shader changes only where it reads 24bpp (below).
- **Faster readback through a texture cache, or partial invalidation.** One
  synchronous readback per GP0(C0) is the model, as in DuckStation.
- **DuckStation's `ForceSoftwareRenderer` trait** (display from the software
  rasterizer). At 1x our Metal VRAM is already byte-exact, so the trait has
  nothing to fix here.
- **The browser build.** It has no Metal and keeps software.
- **Removing `.dual` or the raster worker.** Both stay for the override and
  for `capi_test`.
- **The parity spec's settings struct.** If the parity spec lands first, the
  mode becomes one more field of it. If not, it is one more session setter.

## Anti-goals

These would count as failures even if the code worked:

- **A game that renders correctly today renders wrong by default.** A
  readback-dependent game missing from the table is the expected way this
  fails. The per-game override and a menu switch (below) are the escape, so
  the player is never stuck.
- **A hang.** The emulator thread now waits on the render thread mid-frame. A
  wait that can deadlock against teardown, occlusion, a scale rebuild or a
  full queue is worse than any CPU saving.
- **A silent loss.** A frame dropped under GPU-only corrupts VRAM for the rest
  of the scene, as FF7's menu CLUT showed (`ps1-gpu-metal`, "keeping the
  picture is only HALF an answer"). Any remaining loss path must be loud in
  Debug and counted in release.
- **A slower GPU-only path than dual on a game that does not read back.**
  Plan D measures this on the three bench fixtures and on in-app play.

## Constraints

- Everything in CLAUDE.md's rules stands. Two matter most here: **VRAM stays
  `.r16Uint`** (readback reads it, never the sidecar), and **`Recorder.takeFrame`
  is a drain exactly once per `runFrame`**. Mid-frame chunks (below) must keep
  that second rule true for the frame as a whole, and the frame path's tests
  must still pin it.
- **Mode is installed on every `Bus` the handle builds**, before a state
  loads, exactly as the CPU engine is (`ps1_run_frame calls runFor` rule:
  "re-installed on every `Bus` it rebuilds, BEFORE a state loads"). A state
  load decodes into a scratch `Bus`, and that `Bus` must come up in the
  handle's mode.
- **The core still never imports Metal.** It gets VRAM through a host hook on
  `Gpu`, the way it reports TTY. Only `ps1-session` connects that hook to the
  renderer.
- **Readback values are native and exact at 1x under `.native` dithering**,
  which is the property the gate below relies on. Under the shipped `.trueColor`
  default, Metal writes VRAM undithered (`.trueColor` writes VRAM exactly as
  `.off` does), while software dithers where the game asks. So **a GPUREAD in
  GPU-only mode returns undithered pixels where the software path returned
  dithered ones.** DuckStation in true-colour mode does the same. That is an
  accepted divergence, written down here so it is not later found and called
  a bug. A game it breaks goes in the table.

## The design

### 1. The core: rasterizing becomes a runtime choice

`Sink` gains a runtime flag, `rasterize: bool`, default `true`. It is
meaningful only when `Sink.kind == .dual`, and a `.software` build ignores it.
With it `false`, `submit` records the command and applies env kinds to `env`
(what the worker path already does), but executes nothing into `vram`.
`Sink.transfer` keeps tracking every transfer, as it does under the worker,
so GPUSTAT, the FIFO and DMA timing are unchanged. Only pixel effects move.

`Gpu` gains a host hook, set by the frontend and never saved:

```
readback: ?struct {
    ctx: *anyopaque,
    /// Fill `vram.data` (and `vram.depth` when `depth`) over the rect with
    /// the pixels every record pushed so far has produced. Synchronous.
    read: *const fn (ctx, rect, depth: bool) void,
}
```

It is called at three points, and the core calls it only while
`rasterize == false`:

- **GPUREAD.** When a GP0(C0) transfer begins (its setup, in `Sink`, where the
  transfer window is known), the core hands the hook the transfer's rect,
  wrapped at the VRAM edges exactly as `Vram` reads it. The existing
  `vram.readData` path is then unchanged: it reads `vram.data`, which now
  holds the rect. A transfer that crosses the edge reads as up to four rects.
  How it is split is the builder's choice.
- **Savestate save and trusted snapshot** (`savestate.zig`'s `syncRaster`
  sites): the whole of VRAM. The depth plane is not in a state, so `depth` is
  `false` here, except for the runahead mark, which is handled by section 5
  instead.
- **Mode switch to dual** (section 6): the whole of VRAM and, while the depth
  buffer is on, the depth plane.

`syncRaster`'s current call sites become one helper, `Gpu.settleVram(rect)`:
under a worker it syncs, and under GPU-only it reads back. A new `vram` reader
then cannot pick the wrong one. CLAUDE.md's rule "nothing on the emulator
thread reads `vram` without `Gpu.syncRaster` first" is reworded around it.

Under GPU-only, `vram.data` is a **landing area**: correct over the last rect
read back and stale elsewhere. Only `settleVram` makes a region readable.
`verify --threaded=deferred` is the existing gate for the worker version of
this rule. Section 7's gate is the GPU-only version.

### 2. The stream becomes chunked, and therefore lossless

A readback needs Metal to have executed every record pushed so far,
including those of the frame still being emulated. So a frame can now reach
the renderer in **chunks**:

- `Recorder` gains `takeChunk`: the records and payload since the last chunk,
  marked non-final. `takeFrame` stays the per-`runFrame` drain and returns
  the final chunk. Its exactly-once contract is unchanged.
- **A full recorder flushes a chunk instead of overflowing.** Under GPU-only
  the core calls a second hook, `flush`, at the point `push` would set
  `overflow`. The session publishes the chunk, and recording carries on into
  an empty recorder. `complete == 0` becomes unreachable under GPU-only, and
  the recorder's capacity then stops being a correctness limit. That removes
  the "incomplete recording" drop. **Oversized frames** (bigger than a queue
  slot) go the same way: the session publishes in slot-sized chunks.
- `StreamQueue` carries chunks under the frame's seq. A non-final chunk
  occupies a slot but does not count as a frame for backpressure, and does not
  advance `frames_produced`. The renderer executes chunks in order as they
  arrive, which it already does for frames. A seq is complete when its final
  chunk has executed. The resync rule (`discardThrough(S)`) and runahead's
  staging are written in terms of complete seqs. The builder decides how a
  chunk sits inside the existing slot and staged-frame structure, under one
  invariant: **the renderer never executes a later chunk before an earlier
  one, and a resync never discards part of a seq.**
- A full queue still blocks the producer (backpressure), now also between
  chunks. A readback publishes its chunk first, so it can block there too.
  That is correct: the renderer is draining.

Under dual, nothing in this section runs. `rasterize == true` keeps
`overflow` and `complete == 0`, so the existing repair path stays for the
override.

### 3. The renderer answers readbacks

`ps1-metal` gains one request on the render thread: **read back a native rect
after executing everything queued up to chunk N.** The emulator thread
publishes the open chunk, posts the request and blocks on a condition until
the render thread has executed through N, encoded a blit of the rect's native
subtexels (and depth if asked) into a shared buffer, committed, and waited for
completion. The rect is then copied into `vram.data`. `readbackNative`'s
top-left-subtexel rule is the definition of "native". At 1x it is the
texture itself.

Rules, each an anti-goal above:

- **Execution never stops for occlusion.** It already does not: "a hidden
  window still executes every frame" (`frame_renderer.zig:42`). The readback
  request is served on the same run-loop source as an arriving frame, never on
  the display link. A test pins that a readback completes while occluded.
- **Teardown answers every pending readback** before the render thread exits,
  with the texture's current contents. The session stops the emulator thread
  first, so in practice none is pending. The rule is the backstop.
- **A scale or depth rebuild never discards VRAM** (section 4), so a readback
  that lands during one reads the rebuilt texture.
- **The wait has no timeout in release.** A timeout would hand the game
  garbage. A Debug build asserts after a generous bound (the builder picks it,
  around 2 s), so a deadlock fails loudly in tests rather than hanging.

The cost of a readback is one GPU round trip (expected around a millisecond,
the builder measures it) while the emulator thread waits. A game that reads
back every frame pays that every frame. That is what the per-game table is
for.

### 4. Resync without a software shadow

Today a resync adopts the newest software shadow (`LiveRenderer.drain`). Under
GPU-only there is no shadow, so each cause gets its own answer:

| Cause | Today | GPU-only |
|---|---|---|
| Fresh queue / boot | adopt the blank shadow | the texture starts blank (power-on VRAM is zero); nothing to adopt |
| Scale change, depth toggle (`rebuildVram`) | blank texture, adopt shadow | **carry**: read back native VRAM (and depth while it persists) from the old texture, `uploadNative` it into the new one. The picture drops to 1x until the game repaints, exactly as adopting a native shadow does today. A scaled GPU-side carry is allowed if the builder finds it cheap; it is not required. |
| State load (`ps1_load_state`, resume) | adopt the shadow published after the load | the session uploads the loaded state's `vram.data` as the shadow, under the load's seq. The loaded `Bus`'s VRAM IS complete: it came from the file. |
| Rewind step | adopt the step's shadow | the same as a state load: the step's restored `vram.data` is complete (section 5). |
| Disc swap | the coordinator's unconditional request | nothing: a swap does not touch VRAM. The unconditional request is dropped under GPU-only. |
| Dropped frame / repair debt | adopt the shadow once drops stop | unreachable (section 2). A drop that happens anyway is a bug: Debug asserts, release counts it in `PS1_LIVE_STATS` and raises the resync with a full readback-and-upload, which is a no-op picture-wise but keeps the rule "the texture is never silently wrong". |

So the shadow becomes a **pushed upload**, published only by a state load or
a rewind step, and never sampled by the renderer. `publishShadow` stays for
dual.

### 5. Rewind and runahead

**Rewind.** A capture is a trusted snapshot, so its VRAM section needs the
whole of VRAM every `capture_interval` (2) frames. A synchronous full readback
there costs a GPU round trip every other frame, which is the stall this spec
removes. So **capture readback is asynchronous**. At a capture frame the
session asks the renderer to blit native VRAM into one of a small ring of
shared buffers after that frame's final chunk, and fills the capture's VRAM
section from the buffer when it completes. Capture is a diff written over
`head` (`rewind.Diff`), so the builder may either delay the capture by a
frame or two until the buffer lands, or diff VRAM separately when it does.
The constraint: **a rewind step never restores a VRAM older or newer than the
rest of the capture it belongs to.** A step then loads as today, and its VRAM
is uploaded as in section 4. The rewind memory budget is unchanged: still
1 MB of native VRAM per capture, before the delta.

DuckStation keeps a GPU texture per state instead. At our scales that is 2 MB
(1x) to 192 MB (8x, with the sidecar) per capture, which is why this spec
reads back instead.

**Runahead.** The speculative frames already execute on Metal and are rolled
back there (`MetalVram.saveRegion`/`restoreRegion`, the deferred restore). So
under GPU-only, the machine's mark and return need no VRAM at all. The
trusted snapshot's VRAM section is skipped for a mark (or written and ignored:
the builder's choice, measured). The one open case is **a GPUREAD inside a
speculative frame**: Metal has not executed that group, so a readback at that
point would return the real timeline's VRAM.

*The builder's call, flagged for the user's review:* serve it from the real
timeline (a readback that does not wait for the speculative chunks), and
count it. The real timeline is never affected, because the machine returns,
and the cost is a possibly wrong speculative picture in a game that reads
back during gameplay. Such a game should be in the table anyway. The
alternative, executing the partial group onto the texture early, breaks the
region-bound restore (the region is computed from the whole group) and is
not worth it for a case the table already covers.

### 6. The mode, the table and the switch

A machine is in one of two **VRAM modes**: `gpu` (this spec) or `dual`
(today). The session picks it per disc:

- **The built-in table.** `ps1-core/src/resources/` gains the games that need
  dual, generated like `pgxp_presets.zon` from the same upstream game database
  by the same script (`gen_pgxp_presets.py` grows a second output, or a
  sibling generator). Only the `ForceSoftwareRendererForReadbacks` trait is
  read. The file is generated and never hand-edited. The session folds the
  table in at boot and at a swap, for the serial `discid.zig` reads. That is
  the same moment, and the same rule, as the PGXP preset: "folded in by the
  frontend, never applied by the core".
- **The player's switch.** A menu item (Video ▸ "Accurate VRAM Readbacks" is
  the working name; the HIG pass names it) with three states: Automatic
  (follow the table, the default), On (dual), Off (GPU-only). It is per game,
  stored by serial in `UserDefaults`, like the other per-game Swift state. It
  is the escape hatch from the first anti-goal.
- **Switching at a frame boundary.** `gpu` to `dual`: one full readback (VRAM,
  and depth while the depth buffer is on) into `vram.data`/`vram.depth`, then
  `rasterize = true` and the worker attached. `dual` to `gpu`: sync and detach
  the worker, then `rasterize = false`. The Metal texture is already current
  in both directions, so neither needs a resync. The switch is a session
  setting applied on the emulator thread, like the engine.
- **The handle alone defaults to dual.** A `Ps1Core` used for inspection or
  tests, with no renderer, has nothing to read back from. GPU-only exists only
  inside a session that owns a render thread. The session installs the hooks
  and sets the mode, and `ps1_session_new` documents this.

### 7. Gates

The new path needs its own proof that every reader got the right bytes. The
existing gates cannot provide it, because none of them runs Metal as the
machine's VRAM.

- **GPU-only trace equivalence (the main gate).** Boot every `trace-golden`
  workload with Metal as the machine's only VRAM, at 1x, `.native`
  dithering, both filters nearest, through a headless session-like loop. Every
  sample's state hash must match the existing software golden **unchanged**.
  At each sample, the harness obtains the hashed VRAM through `settleVram` of
  the whole of VRAM, so the sample itself exercises readback. GPUREAD values
  feed the CPU, so a wrong readback moves the CPU state and fails the hash.
  The gate needs Metal, so it lives with `test-metal` or as a macOS-only
  `trace-golden` mode. The builder decides which. It must be ReleaseFast and
  must not need `games/` to compile, only to find workloads, as `verify`
  does today.
- **Readback under stress.** Tests in `ps1-metal/tests/` that pin each rule in
  section 3: a readback mid-chunk sees the chunk's own earlier draws; one
  while occluded completes; one across a `rebuildVram` reads the carried
  pixels; one across the VRAM edge wraps like `Vram`; teardown answers a
  pending one.
- **Losslessness.** A frame that overflows the recorder under GPU-only
  reaches Metal whole: the full-VRAM hash equals software's at 1x. The
  `Recorder` capacity is shrunk in the test to force it.
- **Mode switch.** Switching `gpu` to `dual` mid-workload and back leaves the
  trace hash on the golden.
- **Rewind and runahead.** The existing `speculationLeavesTheRealTimelineUntouched`
  shape, run under GPU-only. A rewind step under GPU-only restores the same
  VRAM a dual rewind does, at 1x `.native`.
- **Unchanged.** With `rasterize` at its default, every existing gate
  (`zig build test`, `trace-golden -- verify` and its modes, the ROM suites,
  `test-metal`) passes untouched. No golden is recaptured by this spec.

### 8. What the debug seams become

`PS1_LIVE_DIFF` and `PS1_SOFTWARE_DISPLAY` compare against, or show, the
software shadow, so they need dual. Setting either forces the session into
dual mode and logs that it did. The 24-bit display reads the Metal texture
(next section), so it works in both modes.

### 9. The 24-bit display

`DisplayShader.metal` reads 24bpp from the 1x `shadow` texture, because the
byte-packing across adjacent 16-bit words does not survive N x N replication.
Under GPU-only it reads the **render texture at the native subtexel**
(`nx * s`, `ny * s`) instead: the same words, by the same top-left-subtexel
rule as readback. Croc and Silent Hill FMVs are the hand check above 1x. The
shadow texture and its per-frame upload stay only for dual's
`PS1_SOFTWARE_DISPLAY`. The builder may also move dual's 24bpp onto the render
texture if it is exact there, which removes one difference between the modes.

## Plans

Four plans, in order. Each leaves the app shippable, and the default stays
dual until Plan D flips it.

- **Plan A: the renderer can serve readbacks.** Sections 3, 4's carry on
  rebuild, and 9: the render-thread readback request, native rect blit, async
  capture blit, `rebuildVram` carry, 24bpp from the render texture. Gated by
  the `ps1-metal` tests in section 7. Nothing calls readback from the core
  yet.
- **Plan B: the machine can run without software rasterization.** Sections 1
  and 2: `Sink.rasterize`, the `readback`/`flush` hooks, `settleVram`,
  chunked recording and `StreamQueue` chunks, the session wiring and mode
  installation on every `Bus`, state load as a pushed upload, savestate save
  and thumbnail through readback. The GPU-only trace-equivalence gate and the
  losslessness gate land here. Behind a debug switch only; the app ships dual.
- **Plan C: rewind and runahead under GPU-only.** Section 5, its gates, and
  `PS1_LIVE_DIFF`/`PS1_SOFTWARE_DISPLAY` forcing dual (section 8).
- **Plan D: the table, the switch, the flip, the measurement.** Section 6
  (the generated table, the per-game menu, the frame-boundary switch and its
  gate), GPU-only becomes the default, CLAUDE.md and `ps1-gpu-metal` updated
  (the shadow rules, the resync rules, the reworded `syncRaster` rule), and
  the measurement below.

### Measurement (Plan D)

- **In-app, per thread**, repeating the 2026-10-16 profile (Crash Warped
  in-level, JIT, PGXP, 6x, rewind on; the CPU Profiler template, comparing
  cycles, not %, because the P cluster clocks down). Dual against GPU-only.
  The raster worker's 13.4% should go to zero. The emulator thread's change
  and the render thread's change are reported separately. Readback and chunk
  overhead lands on those two.
- **Bench.** `ps1-bench-dual` gains a mode that records without rasterizing
  (the `rasterize = false` path, with no readback hook, so no readbacks are
  served). That isolates the emulator thread's cost. Best of five, with the
  bench's existing settling rule.
- **A readback-heavy game.** One game from the table, run GPU-only by the
  switch: readbacks per second and the emulator thread's wait time. This
  shows what the table protects against.

## Left to the builder

- Where the GPU-only trace gate lives (`test-metal` or a macOS-only
  `trace-golden` mode).
- How chunks sit in `StreamQueue` slots and in the staged runahead frame,
  under section 2's invariant.
- How an async rewind capture lines up with its VRAM (delay or separate diff),
  under section 5's constraint.
- Whether a mark writes or skips VRAM.
- The Debug deadlock bound, the readback buffer ring size, and whether the
  scale-rebuild carry is native or scaled.
- The menu item's final name and placement, through the Apple HIG pass.

## Calls made in this spec, for the user to check

- Success is total CPU per frame at 1x speed first, fast-forward second
  (the user said "perf", not which).
- A GPUREAD inside a runahead frame reads the real timeline's VRAM and is
  counted. The table, not runahead, protects the games that need more.
- GPU-only GPUREAD returns undithered pixels under the shipped `.trueColor`,
  as DuckStation does.
- The player gets a per-game three-state switch (Automatic, On, Off) on top
  of the built-in table, not the table alone.
- The handle without a session stays dual. GPU-only is a session-only mode.
- Rewind reads VRAM back asynchronously rather than keeping GPU textures per
  capture.
