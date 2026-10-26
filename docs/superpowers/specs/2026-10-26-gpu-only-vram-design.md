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
   mutation, so no frame, chunk or record may be dropped on the real
   timeline. The one remaining drop cause, recorder overflow, is made
   impossible rather than repaired. (An "oversized frame" is the same cause,
   not a second one: a `StreamSlot` holds exactly one full recorder,
   `max_records` and `max_payload_words` (`stream_queue.zig:44`), so only an
   incomplete recording can fail `fits`.)
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
- **A readback is native, so a read-modify-upload drops that rect to 1x.**
  Above 1x a game that reads a region back, changes it on the CPU and uploads
  it again replaces the rect's scaled detail with its native pixels, since an
  upload is native by definition. DuckStation does the same. A game for which
  that is visible goes in the table.

## The design

### 1. The core: rasterizing becomes a runtime choice

`Sink` gains a runtime flag, `rasterize: bool`, default `true`. It is
meaningful only when `Sink.kind == .dual`, and a `.software` build ignores it.
With it `false`, `submit` records the command and applies env kinds to `env`
(what the worker path already does), but executes no PIXEL effect into
`vram`. `Sink.transfer` keeps tracking every transfer, as it does under the
worker, so GPUSTAT, the FIFO and DMA timing are unchanged.

**The four transfer records still execute into `vram`**: `vram_read_setup`,
`vram_write_setup`, `vram_write_data` and `vram_write_abort`. What is skipped
is exactly draws, fills, copies and depth clears. Two readers need the
transfer cursors:

- `vram.readData` walks the read cursor `Vram.setupRead` sets, so a skipped
  read setup hands GPUREAD a stale cursor.
- The GPU savestate section writes `Vram`'s write AND read cursors
  (`gpu_state.zig:25-39`), and load rebuilds `Sink.transfer` from them
  (`fromVram`, line 116). A state saved mid-upload, a runahead mark included,
  must carry the real write cursor or the load resumes a different transfer.

Executing an upload's payload also writes its pixels into `vram.data`. That
is harmless, because `vram.data` is a landing area (below) that nothing reads
without `settleVram`. It is cheap, too: the emulator thread pays that
per-word cost today whenever there is no worker. The masked store reads
stale mask bits there, which changes only landing-area pixels, never the
cursor. With every transfer record executing, `checkSettled`'s
`transfer.matches(vram)` holds after every transfer step under GPU-only, so
it stays asserted. That is stronger than under a worker, where it is
skipped.

`Gpu` gains host state, set by the frontend, never saved, and re-installed on
every `Bus` the handle builds:

```
host: ?struct {
    ctx: *anyopaque,
    /// Fill `vram.data` (and `vram.depth` when `depth`) over the rect with
    /// the pixels every record pushed so far has produced. Synchronous.
    read: *const fn (ctx, rect, depth: bool) void,
    /// The recorder is full: take its records as a non-final chunk
    /// (section 2). May block on backpressure.
    flush: *const fn (ctx) void,
},
/// Set by the handle while a runahead mark is held (section 5).
speculating: bool = false,
```

The core calls `read` only while `rasterize == false` and `speculating` is
false.

**Two helpers, because the existing call sites need two different things.**
Under a worker, every `syncRaster` site needs the same thing: a drain. Under
GPU-only, a site that is about to READ `vram` needs a readback, and a site
that is about to OVERWRITE it, or that needs no pixels at all, needs nothing.
One helper cannot express both, and a wrong choice is either a stale read or
a GPU round trip on a hot path. So:

- `Gpu.syncRaster()` stays as it is: drain the worker, and do nothing under
  GPU-only. It is for sites that must not race the worker but read no pixels.
- `Gpu.settleVram(rect, depth)` is new: under a worker it is `syncRaster`;
  under GPU-only it calls the hook for `rect`, wrapped at the VRAM edges
  exactly as `Vram` reads it (a rect crossing an edge is up to four rects,
  split as the builder chooses). It is for sites that read pixels.

Every existing site, and what it becomes:

| Site | Reads pixels? | Becomes |
|---|---|---|
| `Gpu.readData` (`gpu.zig:347`), once per GPUREAD **word** | only after a stale mark (below); the rect was settled at setup | `syncRaster`, plus `settleVram(rect, false)` when the read is marked stale |
| `Sink.vramReadSetup` (new site) | yes, the transfer's rect | `settleVram(rect, false)` |
| `saveTrusted` / `saveTrustedOver` (`savestate.zig:101`, `109`) | depends on the caller | the call moves OUT to the callers; see below |
| `loadTrusted` (`savestate.zig:207`) | no: the load overwrites VRAM | `syncRaster` (unchanged) |
| `pgxp_mark.zig:120`, the depth restore on return | no | `syncRaster`, and the restore is skipped under GPU-only (section 5) |
| `ps1_save_state_size` (`root.zig:334`) | no: a size needs no pixels | `syncRaster` (unchanged) |
| `ps1_save_state` (`root.zig:339`) | yes, all of VRAM | `settleVram(all, false)` |
| `ps1_copy_vram` / `ps1_copy_depth` (`root.zig:1031`, `1037`) | yes | `settleVram(all, false/true)` |
| mode switch to dual (section 6) | yes | `settleVram(all, depth buffer on)` |

`saveTrusted` serves three callers that want three different things: the
runahead mark wants no VRAM (section 5), a rewind capture wants it
asynchronously (section 5), and nothing else calls it. So it stops settling
VRAM itself. Its doc comment ("it drains the raster worker itself") becomes
"the caller settles VRAM", and each caller does: the mark calls
`syncRaster`, a rewind capture under a worker calls `syncRaster`, and a
rewind capture under GPU-only fills the VRAM section from its async readback
instead.

The readback happens once, at GP0(C0) setup, rather than per word. Today's
software path reads `vram` word by word, so a pixel record pushed while the
read is still draining shows up in the words read after it. To keep exactly
that behaviour, `Sink` marks the read **stale** when it pushes any pixel
effect (a draw, a fill, a copy, or an upload's setup or payload word) while
`transfer.readActive()` holds. The upload is included because its payload
also writes the landing area, over the rect that was just settled. The next `readData` then calls
`settleVram` again over the transfer's rect before it reads, and clears the
mark. A well-behaved game never sets the mark, so it costs nothing, and a
game that does gets the software path's bytes rather than a guess about
hardware. The mark is counted in `PS1_LIVE_STATS`.

CLAUDE.md's rule "nothing on the emulator thread reads `vram` without
`Gpu.syncRaster` first" becomes "…without `Gpu.settleVram` over what it
reads; `syncRaster` alone only orders against the worker".

Under GPU-only, `vram.data` is a **landing area**: correct over the last rect
read back, and stale elsewhere apart from upload payloads, which are written
as they arrive. Only `settleVram` makes a region readable. `verify
--threaded=deferred` is the existing gate for the worker version of this
rule; section 7's gate is the GPU-only version.

### 2. The stream becomes chunked, and therefore lossless

A readback needs Metal to have executed every record pushed so far,
including those of the frame still being emulated. So a frame can now reach
the renderer in **chunks**:

- `Recorder` gains `takeChunk`: the records and payload since the last chunk,
  marked non-final. `takeFrame` stays the per-`runFrame` drain and returns
  the final chunk. Its exactly-once contract is unchanged.
- **A full recorder flushes a chunk instead of overflowing.** Under GPU-only
  the core calls a second hook, `flush`, at the point `push` or
  `pushVramWriteData` would set `overflow`. The session publishes the chunk,
  and recording carries on into an empty recorder. `complete == 0` becomes
  unreachable on the real timeline under GPU-only, and the recorder's
  capacity then stops being a correctness limit. A slot is exactly one full
  recorder, so a chunk always fits one.
- **Payload offsets become chunk-relative.** A `vram_write_data` record's
  `.x` indexes its own frame's payload run today. After this change it
  indexes its own chunk's. An upload whose payload crosses a chunk boundary
  continues in the next chunk, exactly as an upload already continues across
  a frame boundary through the renderer's `VramTransfer` state.
- **A flush while a runahead mark is held goes to the speculative group,
  never to the real queue.** `runahead.speculate` appends each speculative
  frame with `appendSpeculative`. A `flush` there that published to the real
  ring would put speculative mutations on the real timeline, past the reach
  of the region restore. Inside a mark the hook therefore appends the chunk
  to the group. A group that then exceeds its `maxSpeculativeFrames` slots,
  or holds an incomplete stream, is spoiled and never handed over, as today.
  A lost speculative frame is harmless by construction, because the restore
  puts the region back whatever the group did.
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
- **A half-executed seq is never presented.** Once non-final chunks execute
  as they arrive, the texture can briefly hold part of frame N. A
  double-buffered game would never show that, but a game drawing into its
  displayed buffer would flash. So `FrameRenderer.present` skips the
  display link's tick while the newest executed chunk is non-final, which
  leaves the last presented drawable on screen, and presents again once the
  seq completes. The display shader samples the live render texture, so
  skipping the tick is the only way to hold a picture; it costs one late
  frame, and only when a chunk was cut. Under dual no chunk is ever
  non-final, so the rule is inert there.
- **A mid-frame wait blocks inside `runFrame`.** Every wait the session has
  today is an `Outcome.wait` returned at the top of `iterate`, where stop,
  pause, load and reset requests are serviced. A `flush` or readback wait is
  inside the frame instead, so a request waits for that frame to finish.
  That is acceptable, because the render thread is draining and the wait
  ends, as long as section 3's teardown order holds.

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

A real-timeline readback can never wait behind a STAGED frame. Staging
happens after `runFrame` returns (`frame_path.zig:112`), and the previous
iteration committed its staged frame before returning. So while a real frame
runs, nothing is staged, and the only readback that could meet a staged
frame is one inside a mark, which section 5 never serves.

Rules, each an anti-goal above:

- **Execution never stops for occlusion.** It already does not: "a hidden
  window still executes every frame" (`frame_renderer.zig:42`). The readback
  request is served on the same run-loop source as an arriving frame, never on
  the display link. A test pins that a readback completes while occluded.
- **The render thread outlives the emulator thread.** A stop request can find
  the emulator thread blocked inside `runFrame` on a readback or a `flush`,
  and only the render thread can end that wait. So teardown stops AND JOINS
  the emulator thread first, while the render thread keeps serving, and only
  then stops the render thread. Asking the emulator thread to stop is not
  enough on its own. As a backstop, a render thread that exits anyway
  answers every pending readback with the texture's current contents and
  releases every `flush` waiter, so a teardown bug shows up as a wrong pixel
  and never as a hang.
- **A scale or depth rebuild never discards VRAM** (section 4), so a readback
  that lands during one reads the rebuilt texture.
- **The wait has no timeout in release.** A timeout would hand the game
  garbage. A Debug build asserts after a generous bound (the builder picks it,
  around 2 s), so a deadlock fails loudly in tests rather than hanging.

**A readback costs the whole backlog, not one round trip.** The request
waits until the renderer has executed everything queued, which can be up to
`StreamQueue.capacity` (5) real frames plus the open chunk. With the GPU as
the limit (6x Crash, ~9 ms of GPU a frame) that is tens of milliseconds, not
one. With an empty queue (1x, where the GPU idles) it is close to one GPU
round trip. The emulator thread waits for all of it, and the audio ring
drains meanwhile. A game that reads back every frame therefore runs at the
renderer's pace with the queue's buffering gone, and that is what the
per-game table is for. Plan D's readback measurement reports the wait split
into "backlog" and "blit", at 1x and 6x.

### 4. Resync without a software shadow

Today a resync adopts the newest software shadow (`LiveRenderer.drain`). Under
GPU-only there is no shadow, so each cause gets its own answer:

| Cause | Today | GPU-only |
|---|---|---|
| Fresh queue / boot | adopt the blank shadow | the texture starts blank (power-on VRAM is zero); nothing to adopt |
| Scale change, depth toggle (`rebuildVram`) | blank texture, adopt shadow | **carry**: read back native VRAM (and depth while it persists) from the old texture, `uploadNative` it into the new one. The picture drops to 1x until the game repaints, exactly as adopting a native shadow does today. A scaled GPU-side carry is allowed if the builder finds it cheap; it is not required. |
| State load (`ps1_load_state`, resume) | adopt the shadow published after the load | the session uploads the loaded state's `vram.data` as the shadow, under the load's seq. The loaded `Bus`'s VRAM IS complete: it came from the file. |
| Rewind step | adopt the step's shadow | the same as a state load: the step's restored `vram.data` is complete (section 5). |
| Reset (`serviceResetRequest`, `run_loop.zig:253`) | adopt the shadow, which the reset zeroed | the session pushes a zeroed VRAM (and depth) as the upload under the reset's seq, exactly as a state load pushes the loaded one. The reset rebuilds the machine, so the mode and both hooks are re-installed on it first (section 6's constraint). |
| Disc swap | the coordinator's unconditional request | nothing: a swap does not touch VRAM. The unconditional request is dropped under GPU-only. |
| Dropped frame / repair debt | adopt the shadow once drops stop | unreachable (section 2). A drop that happens anyway is a bug: Debug asserts, release counts it in `PS1_LIVE_STATS` and raises the resync with a full readback-and-upload, which is a no-op picture-wise but keeps the rule "the texture is never silently wrong". |

So the shadow becomes a **pushed upload**, published only by a state load, a
reset or a rewind step, and never sampled by the renderer. `publishShadow`
stays for dual. Under GPU-only, `publishFrame` never publishes a shadow on
its own account: `wantsShadow` is never raised (no cause above asks for an
adoption), the 24-bit display reads the render texture (section 9), and
`shadow_every_frame` belongs to the debug seams, which force dual (section
8). Each of the three pushes settles nothing, because the `vram.data` it
uploads came from a file, a zeroing or a rewind capture, all of them complete.

### 5. Rewind and runahead

**Rewind.** A capture is a trusted snapshot (`saveTrustedOver`), so its VRAM
section needs the whole of VRAM every `capture_interval` (2) frames. Since
`saveTrusted*` no longer settles VRAM itself (section 1), the capture's
caller decides how to fill that section. A synchronous full readback
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
under GPU-only, the machine's mark and return need no VRAM pixels at all:

- The mark calls `syncRaster` (a no-op under GPU-only) and settles nothing.
  Whether the trusted snapshot's VRAM section is skipped for a mark, or
  written from the landing area and ignored, is the builder's choice,
  measured. Either way the transfer cursors in that section are real
  (section 1), so a mark taken mid-upload returns to the right transfer.
- The return writes the landing area at most, which is harmless.
- `pgxp_mark`'s depth plane (`pgxp_mark.zig:120`, held while the depth
  buffer is on) is neither captured nor restored under GPU-only. Metal's
  `restoreRegion` already puts depth back, and `vram.depth` is a landing
  area like `vram.data`. Its `depth_state` half is CPU state and is still
  carried.

**A GPUREAD inside a speculative frame is served from the landing area,
without calling the hook, and counted.** Nothing correct can be returned
there. The real frame is STAGED, not committed, while speculation runs
(`frame_path.zig:112`), so the renderer has executed neither it nor the
group. A readback that waited for the real frame would deadlock behind its
own staging. One that executed the staged frame early would show a frame
without its runahead, breaking the staging rule. One that executed the
partial group would break the region-bound restore, since the region is
computed from the whole group. Every one of those costs something to buy a
better value for a frame that is about to be thrown away, and the machine
returns either way, so the real timeline never sees what was read. The only
cost is a possibly wrong speculative picture in a game that reads back
during gameplay, and such a game belongs in the table regardless. Today only
the handle knows a mark is held (`h.speculating`, set by
`ps1_snapshot_mark` and cleared by `ps1_snapshot_return`, `root.zig:382`).
`Gpu` gains a matching host flag, never saved, that the handle sets and
clears in the same two places, and `settleVram` returns without calling the
hook while it is set. The `flush` hook in section 2 reads the same flag to
pick the group over the real queue, and the stale-read mark from section 1
is ignored inside a mark for the same reason.

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

- **Metal stream parity (the main gate's prerequisite).** The main gate
  assumes that Metal at 1x with `.native` dithering produces software's VRAM
  byte for byte on every `trace-golden` workload. That has never been shown.
  Gate 1 covers the `.p1fx` corpus only, and `ps1-gpu-metal` names one
  divergence class no GPU backend can reproduce: a primitive that samples its
  own destination. So Plan A first replays every workload's recorded stream
  through Metal at 1x, `.native`, both filters nearest, and requires
  full-VRAM equality with the software shadow at every frame. That is
  `stream-verify` with Metal as the replayer. A workload that diverges is
  either a Metal bug, fixed before Plan B starts, or a member of a
  documented divergence class. A workload in such a class is excluded from
  the main gate by name, with the class and the first diverging frame
  printed on every run, the way `test-metal` skips a v2 fixture with a
  printed reason. It is never excluded silently, and never by loosening the
  equality.

#### Metal stream parity: result (2026-10-26)

`zig build trace-golden-metal -Doptimize=ReleaseFast -- parity` (Plan A,
Task 2): every `trace-golden` workload booted for 600M instructions, each
frame's stream replayed through Metal at 1x, `.native`, both filters
nearest, full native VRAM compared with the software VRAM after every frame.
Runtime 2 min 20 s on the M1.

| Workload | Frames | Result | First diverging frame | Class or bug |
|---|---|---|---|---|
| bios-only | 2291 | OK | none | none |
| crash-bandicoot-europe-edc | 2257 | OK | none | none |
| crash-bandicoot-warped | 2495 | OK | none | none |
| crash-bandicoot-2-cortex-strikes-back-europe-australia-en-fr-de-es-it-edc | 2120 | OK | none | none |
| resident-evil-usa | 2578 | OK | none | none |
| croc-legend-of-the-gobbos | 2430 | OK | none | none |
| silent-hill-usa | 2507 | OK | none | none |
| tr1-usa-v1-1 | 2282 | OK | none | none |
| spyro-the-dragon-usa | 2440 | OK | none | none |

No workload diverged on any frame, so there is no Metal bug for Plan B to
wait on and `known_divergences` starts and stays empty: **the Plan B gate
excludes no workload.** The "primitive samples its own destination" class
did not occur in any of the nine windows.

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
  pixels; one across the VRAM edge wraps like `Vram`; a render thread that
  exits with a readback or a `flush` pending releases it; `present` skips
  while the newest executed chunk is non-final.
- **Teardown order.** A session test that stops the session while the
  emulator thread is blocked in a readback: the stop returns, and the
  render thread was still serving when the emulator thread was joined.
- **The core's GPU-only rules**, in `zig build test` with a fake host that
  serves `read` from a software VRAM it owns:
  - a GPUREAD reads the settled rect;
  - a pixel record pushed mid-read marks the read stale, and the words after
    it carry the new pixels, exactly as under `.software`;
  - a state saved mid-upload under GPU-only carries the same transfer
    cursors as one saved under `.software`, and loads to the same machine;
  - nothing calls `read` while `speculating` is set, and `flush` there goes
    to the group;
  - `saveTrusted` no longer settles anything on its own.
- **Losslessness.** A frame that overflows the recorder under GPU-only
  reaches Metal whole: the full-VRAM hash equals software's at 1x. The
  `Recorder` capacity is shrunk in the test to force it, on a frame with an
  upload whose payload crosses the cut, so the chunk-relative offsets are
  exercised too.
- **Reset.** A reset under GPU-only leaves the texture zeroed (and the depth
  plane far) before the next frame's records execute.
- **Mode switch.** Switching `gpu` to `dual` mid-workload and back leaves the
  trace hash on the golden.
- **Rewind and runahead.** The existing `speculationLeavesTheRealTimelineUntouched`
  shape, run under GPU-only, including a speculative frame that overflows
  the recorder (its group is spoiled, and the real timeline is untouched). A
  rewind step under GPU-only restores the same VRAM a dual rewind does, at
  1x `.native`. `trace-golden -- snapshot` (mark, run ahead, return at every
  sample) is run under GPU-only too, and stays on the golden.
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
  capture blit, `rebuildVram` carry, 24bpp from the render texture, and
  `present` skipping a non-final chunk. Gated by the `ps1-metal` tests in
  section 7. **Metal stream parity runs first**, and its result (which
  workloads match, which classes diverge) is written into this spec before
  Plan B is planned. Nothing calls readback from the core yet.
- **Plan B: the machine can run without software rasterization.** Sections 1
  and 2: `Sink.rasterize` with the transfer records still executing, the
  `host` hooks and the `speculating` flag, the `syncRaster`/`settleVram`
  split and the stale-read mark, chunked recording with chunk-relative
  payload offsets and `StreamQueue` chunks, the session wiring and mode
  installation on every `Bus`, the teardown order, state load and reset as
  pushed uploads, and savestate save and thumbnail through readback. The
  GPU-only trace-equivalence gate, the core's GPU-only rules and the
  losslessness gate land here. Behind a debug switch only; the app ships
  dual.
- **Plan C: rewind and runahead under GPU-only.** Section 5, its gates, and
  `PS1_LIVE_DIFF`/`PS1_SOFTWARE_DISPLAY` forcing dual (section 8).
- **Plan D: the table, the switch, the flip, the measurement.** Section 6
  (the generated table, the per-game menu, the frame-boundary switch and its
  gate), GPU-only becomes the default, and the measurement below. CLAUDE.md
  and `ps1-gpu-metal` are updated with:
  - the shadow and resync rules;
  - the `syncRaster`/`settleVram` split;
  - "the transfer records execute under GPU-only";
  - "a flush inside a mark goes to the group";
  - "the render thread outlives the emulator thread";
  - "a GPUREAD inside a mark is never served".

### Measurement (Plan D)

- **In-app, per thread**, repeating the 2026-10-16 profile (Crash Warped
  in-level, JIT, PGXP, 6x, rewind on; the CPU Profiler template, comparing
  cycles, not %, because the P cluster clocks down). Dual against GPU-only.
  The raster worker's 13.4% should go to zero. The emulator thread's change
  and the render thread's change are reported separately. Readback and chunk
  overhead lands on those two.
- **Bench.** `ps1-bench-dual` gains a mode that records without rasterizing
  (the `rasterize = false` path, with no `host` installed, so no readbacks are
  served). That isolates the emulator thread's cost. Without a host, a game
  that reads back would read the landing area, diverge, and time a different
  workload. So the mode counts every `settleVram` that found no host, and
  **refuses the run** (non-zero exit, the count printed) if any occurred.
  Best of five, with the bench's existing settling rule.
- **A readback-heavy game.** One game from the table, run GPU-only by the
  switch, at 1x and at 6x: readbacks per second, and the emulator thread's
  wait split into backlog (executing what was queued) and blit. This shows
  what the table protects against, and whether the backlog dominates as
  section 3 predicts.

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
- A GPUREAD inside a runahead frame reads the landing area without a
  readback, and is counted. No correct value is reachable there without a
  deadlock or a broken staging or restore rule, and the frame is discarded
  either way. The table, not runahead, protects the games that need more.
- A pixel record pushed during a GPUREAD re-settles the read, which
  reproduces today's software bytes, rather than relying on a claim about
  what hardware does there.
- A non-final chunk holds the display link's tick, which costs one late frame
  and only when a chunk was cut, rather than showing a half-drawn frame.
- GPU-only GPUREAD returns undithered pixels under the shipped `.trueColor`,
  as DuckStation does.
- The player gets a per-game three-state switch (Automatic, On, Off) on top
  of the built-in table, not the table alone.
- The handle without a session stays dual. GPU-only is a session-only mode.
- Rewind reads VRAM back asynchronously rather than keeping GPU textures per
  capture.
