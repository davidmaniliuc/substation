# Metal renderer Phase D1 — the live path at 1× — design

**Date:** 2026-08-30
**Status:** approved; one implementation plan
**Parent spec:** `docs/superpowers/specs/2026-08-23-metal-hardware-renderer-design.md`
(§ The C ABI, § Frame pacing, § Buffers, § Ownership and sync, § Display and
scanout, § Phases → Phase D)
**Predecessor:** `docs/superpowers/specs/2026-08-29-metal-renderer-phase-c-design.md`

## Goal

Put the Metal rasterizer on the screen. A real game's GP0 command stream leaves
the core through the C ABI, crosses to the render thread, and becomes the picture
the player sees — at internal resolution 1×, byte-identical to the software
rasterizer.

This is the first phase in which anything Metal-rasterized reaches a display.

## Phase D is split, and this is the first half

The parent spec's Phase D bundles two things with different risk profiles: the
live plumbing (ABI handoff, `gpu_sink = .dual` for `ps1-capi`, the bounded queue,
drain-all/present-newest pacing, 24bpp on the shadow, the `uploadNative` resync,
app wiring) and the upscaling UI (scale picker, scale-aware scanout wraps,
persistence, the 4:3 aspect-lock interaction).

They are separated because only the first half has an oracle. At 1× the software
shadow is a per-frame, per-pixel reference for whatever the player is actually
playing — the second live oracle the parent spec identifies in § Ownership and
sync. Above 1× there is no such thing outside the fixture corpus. Landing both at
once would mean the first live game runs at N > 1 with a divergence confounded
between the plumbing and the scaling.

**D1 is the live path at 1×. D2 is upscaling in the app**, and gets its own spec.

Everything Phase D owns that is not listed under § Scope below belongs to D2.

## Scope

In:

- `gpu_sink = .dual` for `ps1-capi`, and arming the recorder.
- `ps1_take_frame_stream`, `Ps1GpuStream`, and the parent spec's fourth contract
  rule in `ps1.h`.
- The bounded stream queue in `EmulatorRunner`, and drain-all/present-newest.
- `MetalVram.uploadNative` consumed as the overflow/reset resync.
- `MetalRasterizer` made fit for a real-time thread.
- `LiveRenderer`, and the `MTKView` coordinator wired to it.
- 24bpp scanout routed permanently to the 1× shadow.
- The `PS1_LIVE_DIFF` exploratory oracle.

Out — D2:

- The scale picker, its persistence, and any user-facing renderer setting.
- Scale-aware scanout wraps (`& (1024N−1)` / `& (512N−1)`).
- The 4:3 aspect lock and letterbox interaction at scale.

Out — permanently, or elsewhere:

- Any change to the software rasterizer's output. Phase 0 was the only phase
  permitted that.
- PGXP, texture filtering, widescreen hacks, 24bpp display *enhancement*.

## Decisions taken

1. **The hardware path is what you see, and there is no setting.** The 15bpp
   display branch samples the Metal render texture, full stop.

   This was weighed against shipping a software/hardware toggle and rejected on
   the merits. The argument for a toggle was fallback, and it does not hold: the
   shadow presentation path, the shadow texture, its upload and the 24bpp branch
   all survive regardless, because 24bpp scanout and the resync path both require
   them. What a "software mode" would add is therefore one boolean choosing which
   texture an already-bound, already-uploaded branch reads — a uniform, not a
   parallel code path. The thing that would cost real surface is a *user-facing
   setting*, and D2 already owns a settings surface; building a second one here
   is churn to be rewritten a phase later.

   The software-present route stays reachable as a debug seam:
   `PS1_SOFTWARE_DISPLAY=1` routes the 15bpp branch back to the shadow, so a
   suspect frame can be A/B'd against the software rasterizer without a
   rebuild. It sits next to `PS1_LIVE_DIFF` and costs one bool in
   `DisplayParams` and one line in the fragment shader, because both textures
   are bound and uploaded already. It is not a mode and not a setting.

2. **The renderer never sees the core's buffer.** `ps1_take_frame_stream` hands
   back a core-owned pair valid only until the next `ps1_run_frame`, so the
   emulator thread copies it into a preallocated queue slot and returns. This is
   the one place the parent spec's "no allocation on the emulator thread" and its
   "the emulator thread never blocks on the renderer" meet, and a copy satisfies
   both.

3. **Record→instance translation runs on the render thread**, not the emulator
   thread. The queue carries raw records; `MetalRasterizer` is used as Phases B
   and C tested it. Putting `PrimBuilder` and `HazardTracker` on the
   `.userInteractive` audio-paced thread would move per-draw CPU work onto the
   one clock in this system that cannot be made to wait.

4. **All Metal stays on the `MTKView` draw callback.** One device, one command
   queue, one thread. A dedicated render thread was the alternative and remains
   available if measurement demands it — see § Risks — but the measured shape of
   the corpus does not motivate it up front: `silent-hill-usa.p1fx` is 84,045
   draws and 244 passes over 100 frames, about 840 draws and 2.4 passes a frame.

## Architecture

### `ps1-capi` builds `.dual`

`build.zig:273-278` hands `capi_core_mod` the `software_sink` options today; it
gets `recording_sink` instead. The cost is Decision 3 of the parent spec, already
accepted there: `Bus` grows by `Recorder` — 65,536 records × 72 bytes plus
524,288 payload words, about 6.8 MB — and every `Sink.submit` gains a `push`.

`Recorder.enabled` defaults false (`recorder.zig:36`), so `buildMachine` arms it.
Arming *there* rather than in `ps1_create` is load-bearing: `ps1_reset` rebuilds
`Bus` through the same function, and a reset that left the recorder disarmed
would produce a permanently empty stream with nothing to say why.

`root.zig` keeps a `comptime` guard on `Sink.kind` so the library still compiles
against a `.software` core, but nothing ships that way: **`capi_test` moves to
`record_core_mod` as well**, so the test binary matches the shipped library
rather than exercising a configuration no frontend links.

### The handoff

```c
typedef struct {
    const Ps1GpuCommand* records;
    size_t               record_count;
    const uint32_t*      payload;
    size_t               payload_count;
    uint8_t              complete;   /* 0 = overran capacity: DISCARD, resync */
    uint8_t              _pad[7];
} Ps1GpuStream;

void ps1_take_frame_stream(Ps1*, Ps1GpuStream* out);
```

The parent spec's fourth contract rule goes into `ps1.h`'s header block verbatim:

> 4. `ps1_take_frame_stream` returns a CORE-OWNED buffer pair (records and
>    payload). It is valid until the next `ps1_run_frame` on the same handle.
>    The caller must not free it and must not retain it across a frame.

Two further facts belong in the header as prose, because both are silent when
got wrong:

- **The call resets the recorder.** `Recorder.takeFrame` hands out the slices and
  clears the counters (`recorder.zig:87-95`). So this is a once-per-frame call:
  skipping it does not "keep" the frame, it accumulates the next one on top until
  the capacity overruns.
- **`complete == 0` means the records are a prefix**, not a shorter frame.
  Applying a prefix leaves a shadow VRAM permanently out of step with the
  rasterizer — `recorder.zig:1-7` states this on the Zig side and the C side must
  state it too, because the C caller is the one that can act on it.

`Ps1GpuCommand`, its `Kind` enum and the 72-byte stride assertions are already in
`ps1.h` from Phase A2. Nothing about the record type changes.

### The queue

A 4-slot single-producer/single-consumer ring in `EmulatorRunner`, beside the
existing VRAM triple buffer. Each slot is preallocated at full recorder capacity
— records and payload both — so the producer's work is one bounded `memcpy` and
never an allocation. Four slots is about 27 MB, which is the right trade against
a `.userInteractive` thread touching an allocator, and small beside the 67 MB
render texture Phase C already sizes for N=8.

Fixed-capacity slots rather than typical-case ones with overflow-to-resync: a
full-screen CPU→VRAM upload is 262,144 payload words and Croc's FMV window is
1,014 transfers, so a "typical" ceiling would resync continuously on exactly the
content the renderer most needs to get right.

### Ordering and resync are one rule

Frame `k` publishes its VRAM into `slots[next]` **first**, then enqueues its
stream, both tagged `seq = k`. A stream visible to the consumer therefore always
has its shadow already published.

`resyncNeeded` is one atomic flag with three producers:

- the ring is full (the renderer has fallen behind, or the window is backgrounded),
- a stream came back `complete == 0`,
- a front-panel reset happened.

The consumer's response is the same in all three cases: drain the ring entirely,
`MetalVram.uploadNative(newest shadow)`, clear the flag. Because the newest
shadow is at least as new as any queued stream, "discard the backlog and adopt
the shadow" needs no per-slot reconciliation — that is what the publish ordering
above buys, and it is the whole reason to state it.

The picture is momentarily whatever the shadow holds and then resumes from the
stream. At 1× that is not even a visible degradation; at N > 1 in D2 it is the
parent spec's "momentarily 1×, then resumes at N".

### Pacing

`drain-all, present-newest`, as the parent spec's § Frame pacing specifies. The
draw callback executes **every** queued stream in order into the render texture,
then presents once. Execution is never skipped, because a command stream is a set
of incremental mutations and a dropped one is lost permanently; presentation
still is, so 59.94-against-60 and 120 Hz ProMotion stay as invisible as they are
today.

### `LiveRenderer`

The drain/resync/present policy does not live in the `MTKView` coordinator,
because a coordinator is not reachable without a view. `LiveRenderer` owns the
`MetalVram(scale: 1)`, the `MetalRasterizer` and the resync decision, and exposes
`drain(from:)`. The coordinator keeps only MTKView plumbing — acquire the
drawable, call `drain`, fill in `DisplayParams`, encode the display triangle,
present.

This is the split `DisplayRenderTests` already depends on for the letterbox: the
render logic is reachable offscreen, the view is not. The letterbox bug of
2026-08-20 survived every compile-and-pipeline test precisely because only the
pixels were ever wrong, and the same shape of defect is available here.

### One device, one queue

The coordinator stops calling `MTLCreateSystemDefaultDevice` for itself and hands
its device and queue to `MetalVram` and `MetalRasterizer`. Sharing the queue is
what makes commit order the ordering guarantee between the rasterizer's writes
and the display pass's sampling, and that in turn is what lets `endFrame` drop
`waitUntilCompleted` on the live path.

`MetalRasterizer` gains a `synchronous` stored flag defaulting `true`, mirroring
`ditherDisabled`'s pattern. Every Phase B and C test keeps today's behaviour
untouched; only `LiveRenderer` clears it.

### `MetalRasterizer` on a real-time thread

Two allocations per frame have to go. They are correct today — Phase B is
fixture-driven and says so in the class's own header comment ("Allocation on this
path is fine… Phase D owns the no-allocation requirement") — and neither is
acceptable at 60 Hz:

- `beginFrame` builds a payload `MTLBuffer` per frame, up to 2 MB.
- `endFrame` builds the instance buffer per frame, sized to the draw count.

Both become persistent buffers sized to the recorder's caps and `memcpy`'d into.
The same bytes reach the same binding points; there is no behaviour change, which
is what makes the existing fixture gates the check on this task.

### Display

`DisplayShader.metal` gains a second texture binding and routes by depth:

- **15bpp reads the render texture.**
- **24bpp reads the shadow, permanently.** The parent spec's § Display and
  scanout: that path reconstructs pixels by byte-packing across *adjacent 16-bit
  VRAM words* (`DisplayShader.metal:59-75`), arithmetic that N×N replication
  makes meaningless. 24bpp content is FMV — MDEC output uploaded through `A0`,
  never upscaled geometry — so scanning it from the shadow loses nothing. Croc
  and Silent Hill both depend on this.

At D1 both textures are 1024×512, so the `& 1023` / `& 511` wraps are untouched.
Scaling them is D2's, and the parent spec flags that a display window crossing
the VRAM edge at scale is not N independent 1× wraps.

The shadow texture's per-frame `replace` becomes conditional on `depth24 != 0`
rather than paid unconditionally. The frame a game switches into 24bpp already
reports `depth24 == 1`, so nothing is a frame stale.

### Lifecycle

Three transitions, each with a defect if ignored:

- **Disc change.** `ContentView` builds `MetalDisplayView(runner:)` inside
  `if let runner`, so SwiftUI may preserve the view identity across a
  `load(disc:)` and leave the coordinator holding the *previous* runner. That is
  harmless today, because the coordinator only reads frames; it is wrong once
  streams are involved. Fixed with `.id()` keyed on the runner's identity, which
  rebuilds the coordinator and its blank render texture. Rebuilding pipelines and
  a texture per disc load is fine — it is rare by construction.
- **Front-panel reset.** `ps1_reset` rebuilds `Bus`, which clears software VRAM
  and disarms the recorder, while the GPU texture keeps the old picture.
  `buildMachine` re-arms (§ `ps1-capi` builds `.dual`), and reset routes through
  the runner so it raises `resyncNeeded`.
- **Eject.** `teardownRunningMachine` already joins the emulator thread before
  dropping the core. The queue is owned by the runner and dies with it, so no
  additional teardown exists — but the coordinator must not hold a stream slot
  across it, which the `.id()` rebuild also covers.

**A pre-existing race is flagged, not fixed.** `EmulatorViewModel.reset()` calls
`core.reset()` from the main actor while the emulator thread is mid-frame. That
is live today and is not made worse here. Routing reset through the runner is the
natural place to close it later; doing so now is scope this phase did not ask
for.

## The gate

### Deterministic

- **Zig, `capi_test`** (now on the recording core): record and payload contents
  for a known frame; `complete == 0` on a forced overflow, driven by pushing more
  than `max_records` GP0 primitives through the bus; and the reset-on-take
  semantics — a second `ps1_take_frame_stream` within one frame returns an empty
  stream.
- **Swift, the queue** against a fake producer: drain order, present-newest,
  ring-full → resync, `complete == 0` → resync, reset → resync.
- **Swift, offscreen display**: a `DisplayRenderTests` case pinning both routes —
  15bpp samples the render texture, 24bpp samples the shadow.
- **Swift, `LiveRenderer`**: two queued streams drain in order into one texture;
  the resync path replaces the texture with the shadow.
- **All eleven Phase B and C fixture gates re-run unchanged.** Gate 1 remains a
  freeze: a moved fixture hash is a bug in this phase, never a baseline to
  update.

### Exploratory

`PS1_LIVE_DIFF=1` turns on a per-frame `readbackNative()` against the shadow,
logging the first diverging frame with its mismatch count, first differing
coordinate, record count and pass count. Run by hand on Croc, Silent Hill, Spyro,
Crash and TR1.

`PS1_SOFTWARE_DISPLAY=1` is its companion (Decision 1): the diff says *that* a
frame diverged, and flipping the display to the shadow in place says *what it
should have looked like*.

An environment variable is the right mechanism **here specifically**. The
standing note in CLAUDE.md — that the Metal gates are switched by a file because
the hosted test process sees neither an exported variable nor xcodebuild's
`TEST_RUNNER_` prefix — is about the *test* host. The app launched from a shell
has an ordinary environment, and this switch is never read from a test.

This cannot be a CI gate and is not pretending to be one: Metal runs only under
`ps1-macos/test.sh`, and that suite deliberately depends on no BIOS and no disc.
`games/` is gitignored and `simulatePlayingForTesting` exists precisely to avoid
them, so a boot-a-real-disc test would be the first machine-dependent test in the
suite and a green run would stop meaning the same thing on two machines.

**When it diverges, bank the window as a fixture with `stream-capture`; never
weaken the check.** The parent spec already names the one divergence class no GPU
backend can reproduce in any phase — a primitive that samples its own destination
— so a handful of unexplained pixels is a thing to recognise rather than chase.

## Tasks

Eight, strictly ordered.

| # | task | gate |
|---|---|---|
| 1 | `.dual` for `ps1-capi`; arm in `buildMachine`; `capi_test` onto the recording core | `zig build test` and `zig build capi-lib` green; a stream exists after one frame |
| 2 | `ps1_take_frame_stream`, `Ps1GpuStream`, contract rule 4 and the two prose facts in `ps1.h` | capi_test: contents, forced overflow, take-resets |
| 3 | `Ps1Core.takeFrameStream`; the ring, `seq` tagging and `resyncNeeded` in `EmulatorRunner` | Swift queue tests against a fake producer |
| 4 | `MetalRasterizer` real-time fitness: persistent instance and payload buffers, `synchronous` flag | every Phase B and C fixture gate unchanged |
| 5 | `LiveRenderer`; coordinator wiring; shared device and queue | offscreen: two streams drain in order; the resync path |
| 6 | `DisplayShader.metal` second texture and depth routing; conditional shadow upload | offscreen render tests, both routes |
| 7 | Lifecycle: `.id()` on the view, reset → resync, recorder re-armed | queue and stage tests |
| 8 | `PS1_LIVE_DIFF` and the five-game run | exploratory; zero divergence, or a banked fixture |

## Risks

- **Main-thread cost on a pathological frame.** Decision 4 puts per-draw
  translation on the draw callback. The corpus says ~840 draws and ~2.4 passes a
  frame for Silent Hill, but `max_records` is 65,536 and this project already has
  a documented pathological frame (Tekken 3's self-referential ordering table,
  guarded at 65,536 nodes in `dma.zig`). The ring's slot capacity bounds the
  work; a dedicated render thread stays available and changes nothing else in
  this design, because the queue is already the seam.
- **The 1× exactness property meets real games for the first time.** Eleven
  fixtures is real coverage, but it is not the coverage of five games booting and
  playing. `PS1_LIVE_DIFF` is the instrument; a banked fixture is the response.
- **Pass-splitting cost is still unmeasured on live content.** Phase C's Gate 4
  measured replay cost per fixture, not passes per frame on a game that
  alternates draw and sample. The parent spec's standing instruction holds: do
  not weaken the hazard test to buy speed.
- **`.dual` is now paid by the shipping app** — 6.8 MB in `Bus` and a `push` per
  GP0 effect, plus the software rasterizer's time, always. All of this is
  Decision 3 of the parent spec, which accepts it explicitly on the grounds that
  the app already pays the rasterizer at playable speed.
