# Engine into Zig, Plan B: the session and its threads

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Zig module, `ps1-session/`, that runs a whole game below the user interface: the emulator thread (today's `EmulatorRunner.runLoop`), CoreAudio output, the memory-card files, every request, and (in `ps1-metal/`) the render thread that executes frames on arrival and presents them to a `CAMetalLayer` on a display link. It is reached through a new session C ABI that is built into `libps1core.a`. Every runner, audio and card test the Swift suite runs today is ported.

**Architecture:** The emulator thread is a state machine, `RunLoop(Machine)`, generic over the machine it drives: the real one wraps the existing `ps1-capi` `Handle`, and the tests drive a scripted fake that records calls. Every exchange between the emulator thread and the render thread lives in one `ps1-metal` value, `Exchange`: the frame queue, a triple-buffered shadow, the newest display mode and the wake hook. The render thread is a thin shell (a `CFRunLoop`, a run-loop source and a display link) around a thread-free `FrameRenderer` that the tests drive directly. Every wait the emulator thread makes is ONE futex word that every event bumps, so the audio callback wakes it without a lock.

**Tech Stack:** Zig 0.17.0 (`std.Thread`, `std.Io` futex/clock through a session-owned `std.Io.Threaded`), AudioToolbox, CoreFoundation, QuartzCore, Metal, AppKit (`NSView`, `CADisplayLink`) through `objc.zig`, CoreGraphics and ImageIO.

**Spec:** `docs/superpowers/specs/2026-10-20-metal-renderer-into-zig-design.md`. This plan implements the spec's "Order of work" step 6 and step 7, plus the runtime class and display link that Plan A deferred from step 1. It starts from Plan A's carry-list (memory `project-engine-into-zig-plan-a-done`).

## The three plans

- **Plan A (done, 728f9bf):** `ps1-metal/`, headless, gated by `test-metal`.
- **Plan B (this one):** `ps1-session/`, the render thread, the session C ABI. **The app is not switched over:** it keeps running on the Swift path. The only app-side edit is linking (Task 15).
- **Plan C:** the lockstep against the Swift renderer, the performance comparison, switching the app over, the hand checks, deleting the Swift code, and the docs (CLAUDE.md test-binary count, `zig build`'s shader/bench behaviour, the `test-metal` and session rows).

## Global Constraints

- Zig **0.17.0**; `build.zig.zon` gains **no** dependency. 0.17 has no `std.Thread.Mutex`, `Condition` or `Futex`: waits go through `std.Io` (`futexWaitTimeout`, `futexWake`, `Io.Clock.awake`), using an `Io` the session owns (`std.Io.Threaded.init_single_threaded`, as `Handle.io_impl` does, so no signal handlers are installed in the host app). The spec's "std.Thread.Condition/Futex" line predates 0.17; this is its 0.17 form.
- **No file in `ps1-session/` or `ps1-metal/` over about 600 lines.**
- **Raw `objc_msgSend` appears in `ps1-metal/src/objc.zig` only.** Selectors appear in `objc.zig` and `mtl*.zig` only, so the AppKit/QuartzCore wrappers go in `mtl_layer.zig`. AudioToolbox and CoreFoundation are plain C and need neither.
- **No Metal, Objective-C, CoreAudio or threads in `ps1-core/src`.** This plan does not touch `ps1-core/src` at all.
- **No golden, fixture hash or `.p1fx` is recaptured.**
- **No gate is weakened.** Each Swift test in the port table is ported with the same inputs and assertions, or its row says why it is retired or deferred.
- **Nothing on the CoreAudio render thread locks, allocates or blocks.** The callback's whole reach is the ring, atomics and one `futexWake`.
- **The emulator thread is the only caller of the machine.** Every other thread's action is an atomic store or a queued request.
- **Every thread Zig starts runs each loop iteration inside an `objc.Pool`.** No implicit pool exists on a thread Zig started.
- **`zig build test` keeps passing on a machine with no Metal and no audio device.** The session's pure tests join it on macOS hosts only (the module is macOS-only). Anything needing a device joins `test-metal`, and skips with a message that names what is missing, never with a pass.
- **Every rule in `EmulatorRunner`'s comments holds** (the spec's Constraints list them), and the comments that carry a rule are ported with the code. The comments that only explain Swift are dropped.
- Commit messages are **a title line only**. Commit at least once per task, on master, and do not push. Run `zig fmt` before every commit.

## Review Focus

1. **Freeing a session while a request is in flight.** A screenshot's completion block, or a save the emulator thread is servicing, can still be running when `ps1_session_free` is called. Expected: every completion runs exactly once, with `PS1_ERR_SESSION_STOPPED` if it did not complete, and none runs after `free` returns. *Test: Task 14.*
2. **A rewind step at a high scale.** A step publishes four frames at once; waiting only for "not full" lets three of them drop, and above 1x a drop is the repair path. Expected: a held rewind never drops a frame. *Test: Task 8.*
3. **Freeing a session whose emulator thread is parked** (paused, ring full, queue full, or rewinding at the end of the history). Expected: `free` returns within 200 ms and every request is answered. *Test: Task 9.*
4. **No audio device, or an output unit that refuses to start.** Expected: `ps1_session_start` returns `PS1_ERR_AUDIO`, leaves no thread running and leaks nothing, and the session can still be freed. *Test: Task 14.*
5. **A missing or unwritable card directory.** Expected: a missing directory is created on the first write; a write that fails is logged, and the bytes are kept and retried on the next settle rather than dropped. That is one deliberate change from Swift, which dropped them, and the plan owns it. *Test: Task 5.*

---

## File structure

```
ps1-metal/src/lock.zig                NEW  Lock: os_unfair_lock on Darwin, spin elsewhere
ps1-metal/src/waker.zig               NEW  Waker {ctx, fn} and Pacer (the futex word)
ps1-metal/src/stream_queue.zig        MOD  Lock, groups allocated outside it, failure latched, drain wakes, freeSlots
ps1-metal/src/frame_exchange.zig      NEW  Exchange: queue + ShadowSlots + newest Display + counters
ps1-metal/src/pipelines.zig           MOD  (unchanged API) owned by FrameRenderer, borrowed by Rasterizer
ps1-metal/src/rasterizer.zig          MOD  init takes *const pipelines.Set
ps1-metal/src/live_renderer.zig       MOD  init takes *const pipelines.Set; rebuildVram(scale, depth)
ps1-metal/src/display.zig             MOD  paramsFor(Display) Params
ps1-metal/src/objc.zig                MOD  runtime class creation
ps1-metal/src/cf.zig                  NEW  CFRunLoop / CFRunLoopSource externs (plain C)
ps1-metal/src/mtl_layer.zig           NEW  CAMetalLayer, CAMetalDrawable, NSView, CADisplayLink, NSRunLoop
ps1-metal/src/frame_renderer.zig      NEW  the render thread's work, thread-free: settings, execute, present, screenshots
ps1-metal/src/render_thread.zig       NEW  the thread: CFRunLoop, the arrival source, the display link or a timer

ps1-session/src/root.zig              NEW  re-exports
ps1-session/src/pacing.zig            NEW  ring_capacity, waterMarks, rewindHighWater, drainTime
ps1-session/src/audio_ring.zig        NEW  port of AudioRing
ps1-session/src/mixer.zig             NEW  the render callback's work: pull, deinterleave, gain, tempo (pure)
ps1-session/src/tempo.zig             NEW  port of TempoControl + RewindAudio.reverse
ps1-session/src/coreaudio.zig         NEW  AudioToolbox externs, the output + time-pitch units, the callbacks
ps1-session/src/cards.zig             NEW  CardStore (files) + FlushPolicy
ps1-session/src/machine.zig           NEW  the Machine contract, HandleMachine (real), FakeMachine (tests)
ps1-session/src/thumbnail.zig         NEW  ResumeThumbnail: crop/decode (pure) + 320x240 PNG
ps1-session/src/runahead.zig          NEW  port of Runahead.speculate
ps1-session/src/requests.zig          NEW  the request queues and their completions
ps1-session/src/run_loop.zig          NEW  RunLoop(Machine): controls, iterate(), services, publish, rewind step
ps1-session/src/emulator_thread.zig   NEW  the thread around iterate() and the Pacer waits
ps1-session/src/session.zig           NEW  Session: new / start / free, setters, requests, counters
ps1-session/src/abi.zig               NEW  the exported ps1_session_* functions
ps1-session/pure_test.zig             NEW  root of the no-device test binary (zig build test, macOS)
ps1-session/device_test.zig           NEW  root of the Metal/audio test binary (test-metal)
ps1-session/tests/*_test.zig          NEW  one file per area (see the port table)

ps1-capi/include/ps1_session.h        NEW  the session ABI
ps1-capi/include/module.modulemap     MOD  adds ps1_session.h
ps1-capi/src/lib.zig                  NEW  capi-lib's root: the machine ABI plus, on arm64 macOS, the session ABI
ps1-metal/tests/*_test.zig            NEW/MOD  per task
build.zig                             MOD  session module, its two test binaries, capi-lib over both modules
ps1-macos/PS1.xcodeproj/project.pbxproj  MOD  explicit -framework flags (Task 15)
```

## The port table

"Port" means the same test name, inputs and assertions in Zig test syntax. The implementer reads the Swift test and transcribes it.

| Swift file | Fate | Zig file | Task |
|---|---|---|---|
| `StreamQueueTests`: the two retired in Plan A (`theProducerWaitsForAFullQueue…`, `aRendererThatStopsDraining…`) | **replaced** by tests of the condition they stood for: `aFullQueueParksTheProducerUntilADrainWakesIt`, `aRewindStepWaitsForRoomForEveryFrameItPublishes`. There is no "renderer gone" state left to give up on: see Task 8 | `ps1-session/tests/run_loop_frame_test.zig` | 8 |
| `AudioRingTests` (7), `AudioGainTests` (4), `TempoControlTests` (4), `RewindAudioTests` (1) | port | `audio_test.zig` (pure) | 4 |
| `SpeedSettingTests`: the 4 water-mark and drain-time cases | port; the setting cases stay in Swift | `audio_test.zig` | 4 |
| `MemoryCardFlushPolicyTests` (6), `MemoryCardStoreTests` (7) | port | `cards_test.zig` (pure) | 5 |
| `RunaheadTests`: `runaheadMarksRunsDrainsAndReturnsInThatOrder` | port against `FakeMachine`; `runaheadIsOffWhenNeverSetAndPersists` stays in Swift (a setting) | `runahead_test.zig` | 6 |
| `ResumeThumbnailTests` (4) | port | `thumbnail_test.zig` | 6 |
| `EmulatorRunnerSaveStateTests` (5), `EmulatorRunnerLoadStateTests` (6), `EmulatorRunnerMemoryCardTests` (3), `EmulatorRunnerResetTests`: the first 2 | port against `HandleMachine` with a zeroed 512 KB BIOS, as the Swift tests do. `reinstalledCardsForTesting` becomes `FakeMachine`'s call log | `run_loop_requests_test.zig` | 7 |
| `EmulatorRunnerResetTests.theViewModelsResetGoesThroughTheRunner`, `PadStateTests.aPressIsDrainedOnce`, `EmulatorViewModelStageTests`' runner cases | **Plan C**: view-model tests. `aPressIsDrainedOnce` is also ported here, against `Controls` | `run_loop_frame_test.zig` | 8 |
| `LiveRendererScaleTests`: `buildingTheCoordinatorRaisesAResyncOnTheRunnersQueue`, `aRebuildSupersedesTheCoordinatorItReplaces`, `theCoordinatorBuildsItsRendererAtTheScaleItWasGiven` | port as `aScaleChangeRaisesAResyncFromTheRenderThread`, `aScaleChangeLeavesExactlyOneConsumer` (the renderer before the change never drains again because it no longer exists: the test asserts the old VRAM was freed and the queue was drained by the new one) and `theRendererBuildsAtTheScaleItWasGiven` | `ps1-metal/tests/frame_renderer_test.zig` | 12 |
| `ScreenshotTests.aRequestIsTakenOnce` | port against the session's screenshot request; `theFileIsNamedForTheGameAndTheMoment` stays in Swift | `frame_renderer_test.zig` | 12 |
| `HudInputTests`, `HudSurfacesTests`, `SaveStateViewModelTests`, `PlayingForTests`, `FpsCounterTests`, `TextureFilterSettingTests` (their runner uses) | **Plan C**: they test the view model through a runner, and move when the view model holds a session | — | — |

---

### Task 1: Pipelines built once; a rebuild keeps them

The carry-list's first item. Today every `Rasterizer.init` builds all 28 pipelines (~1.15 s cold), so a scale change would rebuild them on the render thread. After this task the owner of a `pipelines.Set` builds it once and every rasterizer borrows it.

**Files:**
- Modify: `ps1-metal/src/rasterizer.zig` (`init` signature, `deinit` stops releasing pipelines), `ps1-metal/src/live_renderer.zig`, `ps1-metal/src/metal_context.zig` (`Rig` owns a `Set`), `ps1-metal/src/display.zig`
- Modify: every caller of `Rasterizer.init`/`LiveRenderer.init` under `ps1-metal/tests/`, `ps1-bench/src/`
- Test: `ps1-metal/tests/live_renderer_scale_test.zig`, `ps1-metal/tests/display_test.zig`

**Interfaces:**
- Produces: `Rasterizer.init(alloc, vram: *MetalVram, set: *const pipelines.Set) !Rasterizer`; `LiveRenderer.init(alloc, m: Metal, set: *const pipelines.Set, scale: u32, depth_buffer: bool, o: Options) !*LiveRenderer`; `LiveRenderer.rebuildVram(self, scale: u32, depth_buffer: bool) !void`, which frees the old `MetalVram`, builds the new one, re-points the rasterizer at it (its `State`, env and transfer, carried over unchanged) and calls `requestResync` on nothing: the CALLER raises the resync (Task 12 owns that rule); `display.paramsFor(d: stream_queue.Display) Params` (vram_x/y, width, height, depth24, enabled; everything else at its default).

- [ ] **Step 1: Write the failing tests**

```zig
test "aRebuildAtANewScaleMatchesAFreshRendererAtThatScale" {
    // Same stream into (a) a renderer built at 1x then rebuildVram(3, false) then resynced
    // from a blank shadow, and (b) a renderer built at 3x and resynced the same way.
    // Readback of both at native must be byte-identical; both rasterizers point at the
    // SAME *const pipelines.Set (pointer equality).
}
test "aRebuildBuildsNoPipelines" {
    // set.variantCount() before == after, and the Set's first prim pipeline id is unchanged.
}
test "paramsForCopiesTheDisplayAndDefaultsTheRest" {
    const p = display.paramsFor(.{ .vram_x = 320, .vram_y = 8, .width = 256, .height = 240, .depth24 = true, .enabled = true });
    try expectEqual(@as(u32, 320), p.vram_x); try expectEqual(@as(u32, 1), p.depth24);
    try expectEqual(@as(f32, 1), p.saturation); try expectEqual(@as(u32, 1), p.scale);
}
```

- [ ] **Step 2: Run them; they fail to compile** (`zig build test-metal -Dmetal-filter=Rebuild`)
- [ ] **Step 3: Implement.** `Rig` and the bench build one `Set` per `Metal` and pass it in; the tests' harness owns a `Set` beside its `Metal`.
- [ ] **Step 4: `zig build test-metal -Doptimize=ReleaseFast` passes, the three new tests included, and `zig build test` passes**
- [ ] **Step 5: Commit** `refactor(metal): build the pipelines once and let a renderer rebuild its VRAM`

---

### Task 2: The queue's lock, its group allocation and its drain hook

The carry-list's second and third items, plus what the emulator thread needs from the queue.

**Files:**
- Create: `ps1-metal/src/lock.zig`, `ps1-metal/src/waker.zig`
- Modify: `ps1-metal/src/stream_queue.zig`
- Test: `ps1-metal/tests/queue_test.zig` (pure)

**Interfaces:**
- Produces: `lock.Lock` (`.{}` init, `lock()`, `unlock()`): `std.c.os_unfair_lock` on Darwin (it donates priority across QoS classes, which a spin lock cannot), `std.atomic.Mutex` spin elsewhere so the pure tests still build off macOS.
- Produces: `waker.Waker = struct { ctx: *anyopaque, wake: *const fn (*anyopaque) void }` with `pub fn call(self) void`.
- Produces: `waker.Pacer`: `word: std.atomic.Value(u32)`; `pub fn bump(self: *Pacer, io: std.Io) void` (fetchAdd 1, then `io.futexWake(…, 1)`); `pub fn generation(self) u32`; `pub fn wait(self, io, seen: u32, timeout: std.Io.Timeout) void` (`futexWaitTimeout`, returning on wake, timeout or a changed word, and swallowing `Canceled`). `bump` takes no lock and allocates nothing, which is what makes it legal on the audio thread.
- Produces on `StreamQueue`: `on_drained: ?Waker = null`, called once at the end of any `drain`/`discardThrough`/`discardAll` that moved `head`; `pub fn freeSlots(self) usize` (`capacity - pendingCount`); `group_alloc_failed: bool` (producer-only), so the allocation is tried once per queue and never again; `groups_wanted` handled by `beginSpeculativeGroup` allocating **before** `lock()`.

- [ ] **Step 1: Write the failing tests**

```zig
test "aDrainThatTakesAFrameWakesTheProducer" { // count calls through a Waker; drain of an empty queue does not call it
}
test "aDiscardThatTakesAFrameWakesTheProducerToo" {}
test "freeSlotsIsWhatTheProducerMayStillPublish" { // 5, publish 2 -> 3, drain -> 5
}
test "aGroupThatCannotBeAllocatedIsTriedOnceAndRunaheadStaysOff" {
    // std.testing.FailingAllocator with fail_index = slots so the queue itself builds but the
    // groups do not: beginSpeculativeGroup twice -> exactly one allocation attempt (count it),
    // takeSpeculativeGroup returns null, group_alloc_failed is true.
}
test "theLockIsTakenAroundEveryGroupIndexChange" { // build-only on non-Darwin: a Lock locks and unlocks
}
```

- [ ] **Step 2: Run them; they fail** (`zig build test`)
- [ ] **Step 3: Implement** `lock.zig`, `waker.zig` and the queue changes. Rewrite `group_lock`'s comment: the lock is now `os_unfair_lock` because the producer (emulator thread, `.userInteractive`) and the consumer (render thread) run at different QoS.
- [ ] **Step 4: `zig build test` passes; `zig build test-metal -Dmetal-filter=Speculat` passes**
- [ ] **Step 5: Commit** `feat(metal): an unfair lock for the group indices, a drain wake and a latched group allocation`

---

### Task 3: The exchange: queue, shadows and display in one place

Swift spreads these across `EmulatorRunner` (three slots, `newest`, `displayLock`, `seqs`, `depthValid`) and `StreamQueue`. Here they are one value both threads hold. The shadow is a real triple buffer, so the reader never copies and the producer never writes the slot the reader holds. Swift's version could overwrite the reader's slot after two publishes during one 1 MB copy.

**Files:**
- Create: `ps1-metal/src/frame_exchange.zig`
- Modify: `ps1-metal/src/root.zig`, `ps1-metal/src/live_renderer.zig` (only if `Shadow` needs a constructor from a slot)
- Test: `ps1-metal/tests/exchange_test.zig` (pure; add to `pure_test.zig`)

**Interfaces:**
- Produces: `frame_exchange.ShadowSlot = struct { pixels: [native_pixels]u16, depth: [native_pixels]u32, depth_valid: bool, seq: u64 }`. 3 slots, heap-allocated once (~9 MB).
- Produces: `frame_exchange.Exchange`:
  - `pub fn init(alloc) !*Exchange`, `deinit`;
  - `queue: *StreamQueue`;
  - producer: `pub fn shadowBack(self) *ShadowSlot` (the slot to fill), `pub fn publishShadow(self) void` (swaps back with middle and marks it fresh, with release ordering);
  - consumer: `pub fn acquireShadow(self) ?live_renderer.Shadow` (swaps front with middle if fresh, then returns front, or null before the first publish), `pub fn heldShadow(self) ?live_renderer.Shadow` (front without swapping);
  - `pub fn publishDisplay(self, d: Display) void` / `pub fn newestDisplay(self) Display` under a `Lock`;
  - `frames_produced: std.atomic.Value(u64)`.
- The triple buffer is three indices packed in one `std.atomic.Value(u32)`: back, middle, front and a fresh bit. The producer owns back, the consumer owns front, and both exchange middle with `swap`. No lock, no copy.

- [ ] **Step 1: Write the failing tests**

```zig
test "theReaderSeesTheNewestPublishedShadow" { // seq 1, 2 published -> acquire gives seq 2
}
test "theProducerNeverWritesTheSlotTheReaderHolds" {
    // acquire (seq 1, pixel[0]=0x1111); then publish seq 2 and 3, writing 0xFFFF into every back slot;
    // the held slot's pixel[0] is still 0x1111 and its seq still 1.
}
test "aReaderThatAcquiresTwiceWithoutAPublishKeepsItsSlot" {}
test "nothingIsAcquiredBeforeTheFirstPublish" {}
test "theDepthPlaneTravelsWithItsSlot" { // depth_valid false -> Shadow.depth == null
}
test "aThreadedPublisherAndReaderNeverTear" {
    // std.Thread producer publishes 10_000 slots whose pixels are all = seq; the reader acquires
    // in a loop and asserts every pixel of what it holds equals its seq.
}
```

- [ ] **Step 2: Run them; they fail**
- [ ] **Step 3: Implement**
- [ ] **Step 4: `zig build test` passes**
- [ ] **Step 5: Commit** `feat(metal): one exchange for the queue, a triple-buffered shadow and the display mode`

---

### Task 4: `ps1-session` begins: the audio arithmetic

**Files:**
- Create: `ps1-session/src/root.zig`, `pacing.zig`, `audio_ring.zig`, `tempo.zig`, `mixer.zig`; `ps1-session/pure_test.zig`; `ps1-session/tests/audio_test.zig`
- Modify: `build.zig`: a `session_mod` (imports `ps1_core` = `record_core_mod`, `ps1_metal` = `metal_mod`, `ps1_capi` = a module over `ps1-capi/src/root.zig` with the recording core), and a `session_pure_test` added to `test_step` **only when the host is macOS**

**Interfaces:**
- Produces in `pacing.zig`: `ring_capacity = 1 << 15`; `floats_per_frame = 1470`; `waterMarks(speed: u32) struct { high: usize, low: usize }` = `{1470*4*speed, 1470*2*speed}`; `rewindHighWater(speed) usize` = `min(high + picture_frames*1470, ring_capacity - picture_frames*1470)` with `picture_frames` from `ps1_core.savestate.rewind.picture_frames`; `drainTime(floats: usize, speed: u32) u64` in **nanoseconds**, `max(1 ms, floats / (88_200 * speed) s)`; `rewind_step_interval_ns = 1_000_000_000 / 30`; `max_speed = 4`.
- Produces `audio_ring.AudioRing` (capacity rounded up to a power of two; `filled`, `freeSpace`, `write([]const f32) usize`, `read([]f32) usize`), the same SPSC algorithm, buffer allocated once.
- Produces `tempo.Tempo` (`smoothing = 0.02`, `current: f32 = 1`, `rate(target: u32, fill: usize) f32`, `reset(rate)`, `step(toward) f32`) and `tempo.reverseFrames(samples: []f32)`.
- Produces `mixer.Mixer`: holds `*AudioRing`, `gain_bits: std.atomic.Value(u32)`, `speed: std.atomic.Value(u32)`, `rendered_speed`, `tempo`, a `scratch: [4096 * 2]f32` **array in the struct** (no allocator anywhere in the type), and `drained: Waker`. `pub fn render(self, left: []f32, right: []f32, stretch: ?Stretch) void`, where `Stretch = struct { ctx: *anyopaque, reset: fn, set_rate: fn (ctx, f32) void, render: fn (ctx, left, right) bool }` is how `coreaudio.zig` (Task 10) plugs the time-pitch unit in and the tests plug in a fake; `pub fn pull(self, left, right) void` (deinterleave, silence on underrun, then `drained.call()` only when `filled < waterMarks(speed).low`). Real-time rule: `render` calls nothing but these.

- [ ] **Step 1: Write the failing tests.** Port `AudioRingTests` (7), `AudioGainTests` (4, against `Mixer`'s gain), `TempoControlTests` (4), `RewindAudioTests` (1) and the four `SpeedSettingTests` water-mark cases (`theRingBuffersTheSameTimeOfAudioAtEverySpeed`, `theRingHoldsTheHighWaterMarkAtTheFastestSpeed`, `aRewindStepStartsWithAWholeStepQueuedAndAlwaysFitsTheRing`, `theRewindSleepsUntilTheRingDrainsToItsMark`, the last in nanoseconds). Add:

```zig
test "atOneXTheMixerIsBitIdenticalToTheRing" {} // no stretch call, samples deinterleaved exactly
test "aStretchReenteredFromOneXStartsFromAResetUnit" {} // fake Stretch counts reset: 1x,2x,2x,1x,3x -> 2 resets
test "theMixerWakesTheProducerOnlyBelowTheLowMark" {}
test "theMixerTypeHoldsNoAllocator" {
    // comptime: no field of Mixer (recursively through its own fields) is std.mem.Allocator.
}
```

- [ ] **Step 2: Run them; they fail** (`zig build test`)
- [ ] **Step 3: Implement**
- [ ] **Step 4: `zig build test` passes**
- [ ] **Step 5: Commit** `feat(session): the audio ring, mixer, tempo and water marks`

---

### Task 5: Memory cards on disk

**Files:**
- Create: `ps1-session/src/cards.zig`, `ps1-session/tests/cards_test.zig`

**Interfaces:**
- Produces: `cards.bytes = 128 * 1024`, `cards.slots = 2`; `CardStore = struct { dir: std.Io.Dir, … }` with `pub fn open(io, path: []const u8) CardStore` (does NOT create the directory: it is created on the first write), `pub fn load(self, io, slot: u1, out: *[bytes]u8) bool` (false for missing and for wrong-size files), `pub fn write(self, io, slot: u1, image: *const [bytes]u8) bool` (creates the directory, writes `card<N>.mcd.tmp`, then renames over `card<N>.mcd`; returns false and logs on failure); `fileName(slot) []const u8` = `"card1.mcd"`/`"card2.mcd"`.
- Produces: `FlushPolicy = struct { pending_since_ns: ?u64 = null, pub const settle_ns = 1_000_000_000; pub fn shouldWrite(self, dirty: bool, now_ns: u64) bool; pub fn hasPendingWrite(self) bool }`, with the same rule as Swift: the window restarts on every new write.
- Produces: `Pending = struct { images: [slots]?[bytes]u8 }` (fixed storage, no allocation). `writeAll(store, io) void` keeps an image whose write failed (Review Focus 5).

- [ ] **Step 1: Write the failing tests.** Port `MemoryCardFlushPolicyTests` (6, with nanosecond timestamps) and `MemoryCardStoreTests` (7) against `std.testing.tmpDir`. Add:

```zig
test "aMissingDirectoryIsCreatedOnTheFirstWrite" {}
test "aFailedWriteKeepsTheImageForTheNextSettle" {
    // dir path is a FILE, not a directory: write returns false, Pending still holds the image;
    // replace it with a directory: the next writeAll writes it and clears Pending.
}
test "aWriteLeavesNoTemporaryFileBehind" {}
```

- [ ] **Step 2: Run them; they fail**
- [ ] **Step 3: Implement**
- [ ] **Step 4: `zig build test` passes**
- [ ] **Step 5: Commit** `feat(session): memory-card files and the flush policy`

---

### Task 6: The machine contract, runahead and the resume thumbnail

**Files:**
- Create: `ps1-session/src/machine.zig`, `runahead.zig`, `thumbnail.zig`; `ps1-session/tests/runahead_test.zig`, `thumbnail_test.zig`
- Modify: `ps1-metal/src/png.zig` (`encodeScaled`)

**Interfaces:**
- Produces: the **Machine contract**, which `RunLoop(M)` checks at comptime. Each method is a thin call on the real side:

| method | `HandleMachine` (wraps `*ps1_capi.Handle`) |
|---|---|
| `runFrame()` | `ps1_run_frame` |
| `readAudio(dst: []f32) usize` | `ps1_read_audio` |
| `takeFrameStream() command.Stream` | `h.cpu.bus.gpu.sink.rec.takeFrame()` |
| `display() stream_queue.Display` | `ps1_get_display`, converted |
| `copyVram(dst: *[native_pixels]u16)`, `copyDepth(dst: *[native_pixels]u32)` | `ps1_copy_vram`, `ps1_copy_depth` |
| `saveStateSize() usize`, `saveState(dst: []u8) Error!usize`, `loadState(src: []const u8) Error!void` | `ps1_save_state*`, `ps1_load_state` |
| `snapshotMark() Error!void`, `snapshotReturn() Error!void` | `ps1_snapshot_*` |
| `reset()`, `swapDisc(disc: DiscBytes) Error!void` | `ps1_reset`, `ps1_swap_disc` |
| `setButtons(u16)`, `setAnalog([4]u8)`, `pressAnalogButton()`, `padStatus() u32` | `ps1_set_*`, `ps1_get_pad_status` packed as Swift's `PadStatus.packed` |
| `takeMemcard(slot: u1, dst: *[cards.bytes]u8) bool`, `loadMemcard(slot: u1, src: *const [cards.bytes]u8) Error!void` | `ps1_take_memcard`, `ps1_load_memcard` |
| `applyPgxp(p: Pgxp)` (all nine re-applied flags and the tolerance) | the nine `ps1_set_pgxp_*` setters, in Swift's order |
| `setVertexCache(bool)`, `setEngine(Engine) Error!void` | `ps1_set_pgxp_vertex_cache`, `ps1_set_cpu_engine` |
| `configureRewind(bytes: usize) Error!void`, `rewindStep() bool`, `rewindFramesCovered() u32` | `ps1_rewind_*` |

  `Error` maps each `PS1_ERR_*` the calls return to a named error, and `errorCode(Error) i32` maps it back for the ABI. `FakeMachine` implements the same contract and appends each call's name to `calls: std.ArrayList([]const u8)`. Its outputs are scripted (`audio_per_frame`, `streams`, `display_value`, `rewind_history: u32`, `fail_load: bool`, `fail_engine: bool`). `machine.check(M)` is the comptime contract check that both pass.
- Produces: `runahead.speculate(m: anytype, frames: u32, after: u64, queue: *StreamQueue, audio_scratch: []f32) void`, a line-for-line port. A refused mark does nothing; an empty (incomplete) stream appends an incomplete frame, which spoils the group.
- Produces: `thumbnail.decode(vram: *const [native_pixels]u16, d: Display, out_rgba: []u8) ?struct { w: u32, h: u32 }` (pure; 15 bpp expanded with `c << 3 | c >> 2`, 24 bpp unpacked across words, rows and columns wrapping as `ResumeThumbnail` does) and `thumbnail.png(alloc, vram, d) !?[]u8`, which calls `png.encodeScaled(alloc, rgba, w, h, 320, 240)`.
- Produces: `png.encodeScaled(alloc, rgba: []const u8, w, h, out_w, out_h) ![]u8`: a `CGBitmapContext` with `kCGInterpolationHigh`, `noneSkipLast`, device RGB, then the same ImageIO encode as `png.encode`.

- [ ] **Step 1: Write the failing tests.** Port `runaheadMarksRunsDrainsAndReturnsInThatOrder` (calls must be exactly `mark, run, audio, stream, run, audio, stream, display, return`, and the group holds 2 frames with `display.vram_x == 320`). Port `ResumeThumbnailTests` (4), decoding the PNG back through ImageIO to check pixels as the Swift tests do. Add `test "machineContractHoldsForBothMachines"` (comptime `check` on both) and `test "aHandleMachineOverAZeroBiosRunsAFrameAndSavesAState"`.
- [ ] **Step 2: Run them; they fail**
- [ ] **Step 3: Implement**
- [ ] **Step 4: `zig build test` passes**
- [ ] **Step 5: Commit** `feat(session): the machine contract, runahead and the resume thumbnail`

---

### Task 7: The run loop's requests: save, load, reset, swap, cards

**Files:**
- Create: `ps1-session/src/requests.zig`, `ps1-session/src/run_loop.zig` (services half); `ps1-session/tests/run_loop_requests_test.zig`

**Interfaces:**
- Produces in `requests.zig` (a `lock.Lock` guards every list; each `take*` swaps the list out under the lock, so a completion runs exactly once whichever thread reaches it):
  - `SaveDone = *const fn (ctx: ?*anyopaque, code: i32, state: [*]const u8, state_len: usize, png: ?[*]const u8, png_len: usize) callconv(.c) void`
  - `LoadDone = *const fn (ctx: ?*anyopaque, code: i32, undo: [*]const u8, undo_len: usize) callconv(.c) void`
  - `Done = *const fn (ctx: ?*anyopaque, code: i32) callconv(.c) void` (reset, swap)
  - `Requests` with bounded lists (`max_pending = 16` per kind; past it a request is answered at once with `PS1_ERR_BUSY`), `addSave`, `addLoad(state: owned []u8)`, `setReset`, `setSwap(DiscBytes)` (a newer swap answers the older one with `PS1_ERR_SUPERSEDED`), `failAll(code)`.
  - Bytes handed to a completion are valid only during the call; the C caller copies them.
- Produces in `run_loop.zig`: `pub fn RunLoop(comptime M: type) type` with fields `m: *M`, `x: *Exchange`, `ring: *AudioRing`, `requests: Requests`, `controls: Controls` (Task 8), `cards: ?*CardStore`, `pending_cards: cards.Pending`, `flush: cards.FlushPolicy`, `card_lock: Lock`, `card_writes: atomic u64`, `pad_status: atomic u32`, `io: std.Io`, `alloc` (used ONLY by save/load, which allocate the state buffer: that is the existing contract, not a new allocation on the frame path), plus `pub fn serviceMemoryCards(self, now_ns)`, `flushMemoryCards(self)`, `serviceSaveRequests(self)`, `serviceLoadRequests(self)`, `serviceResetRequest(self)`, `takeSwap(self) ?DiscBytes`, `failPendingRequests(self)`. Every ordering rule in Swift's comments carries over: save before load; a load flushes the cards first, then saves the undo state, then loads, re-installs every card on disk, publishes the pad status and requests a resync; a refused load re-installs nothing; reset requests a resync; all saves pending at once are answered from ONE snapshot.

- [ ] **Step 1: Write the failing tests.** Port `EmulatorRunnerSaveStateTests` (5), `EmulatorRunnerLoadStateTests` (6), `EmulatorRunnerMemoryCardTests` (3) and the first two `EmulatorRunnerResetTests`, against `HandleMachine` + zero BIOS + a tmp `CardStore`. For the re-install assertions use `FakeMachine`, whose log must hold `loadMemcard 1` and no other `loadMemcard`. Add:

```zig
test "aSaveAskedBeforeALoadCapturesTheMachineThePlayerWasLookingAt" {} // Fake: calls order saveState(save) < saveState(undo) < loadState
test "aLoadAndAResetBothRequestAResync" {} // clearResync first, then each sets needsResync
test "aRequestPastTheBoundIsAnsweredAtOnceWithBusy" {}
test "aNewerSwapAnswersTheOlderOneSuperseded" {}
```

- [ ] **Step 2: Run them; they fail**
- [ ] **Step 3: Implement**
- [ ] **Step 4: `zig build test` passes**
- [ ] **Step 5: Commit** `feat(session): save, load, reset, swap and card servicing on the emulator thread`

---

### Task 8: The run loop's frame path: iterate, publish, runahead, rewind

`iterate()` is one pass of Swift's `while running` body, returning what the thread must wait for instead of waiting itself. That is what lets every pacing rule be tested deterministically.

**Files:**
- Modify: `ps1-session/src/run_loop.zig` (frame half); create `ps1-session/tests/run_loop_frame_test.zig`
- If `run_loop.zig` passes ~600 lines, the frame half moves to `ps1-session/src/frame_path.zig`.

**Interfaces:**
- Produces: `Controls` (all atomics, written from any thread): `speed: u32 = 1`, `paused`, `buttons: u32 = 0xFFFF`, `sticks: u32` (Swift's `Sticks.centred.packed`), `analog_presses: u32`, `pgxp: Pgxp` (nine flags plus the tolerance bits), `vertex_cache`, `engine: u8`, `rewind_budget: usize`, `rewinding`, `runahead: u32`, `depth_buffer` (decides whether shadows carry depth), `shadow_every_frame: bool` (the `PS1_SOFTWARE_DISPLAY`/`PS1_LIVE_DIFF` switch, set once), and `pub fn takeAnalogPress(self) bool`. The defaults are deliberately the "off" values, because the session's owner re-applies every setting before `start` (Swift's `play()` rule).
- Produces: `Outcome = union(enum) { ran_frame, rewound, wait: Wait }` with `Wait = struct { reason: enum { paused, audio, queue, rewind_drain, rewind_idle }, timeout_ns: ?u64 }`. Timeouts: `paused` = 50 ms, because the card service must keep running while paused; `audio` = 50 ms backstop; `queue` = none, since a drain wakes it; `rewind_drain` = `drainTime(filled - mark)`; `rewind_idle` = `rewind_step_interval_ns`.
- Produces: `pub fn iterate(self, now_ns: u64) Outcome`, Swift's order exactly: cards, saves, loads, reset; paused; the rewind budget on change; a held rewind (requires `freeSlots() >= picture_frames` AND `filled <= rewindHighWater`); the audio high-water mark; **queue room: `freeSlots() >= 1`**; the swap; inputs; PGXP; the vertex cache and engine on CHANGE only (a refusal is recorded and not retried); `runFrame`; pad status; audio to the ring; `publishFrame`; runahead at speed 1 only (`stage`, `speculate`, `commitStaged`), else `publish`; rewind frames covered.
- `publishFrame(force)`: bump seq and `frames_produced`; `wanted = queue.wantsShadow()` (asked every frame, since it clears); the shadow when `force or wanted or depth24 or shadow_every_frame`: `copyVram` into `shadowBack()`, `copyDepth` when `controls.depth_buffer`, set seq and depth_valid, `publishShadow()`; and **only then** `publishDisplay`.
- `rewindStep` is a port of Swift's, keeping its order: publish the forced shadow, request a resync, THEN publish the `picture_frames` streams; reversed audio goes to the ring.
- **A stalled renderer can no longer drop a frame.** The producer waits for room before every frame and for `picture_frames` of room before every rewind step, and nothing else publishes. The only drops left are an incomplete recording and an oversized frame, which `stage` still notes. Write this in `iterate`'s doc comment, since it is the spec's "the plan checks whether a stalled-renderer drop can still happen" answered.

- [ ] **Step 1: Write the failing tests** (all against `FakeMachine` and a real `Exchange`):

```zig
test "aFullQueueParksTheProducerUntilADrainWakesIt" {} // fill 5 -> .wait{queue, null}; drain one -> ran_frame
test "aRewindStepWaitsForRoomForEveryFrameItPublishes" {} // 3 free -> wait; 4 free -> rewound; dropped_count unchanged
test "theRingAboveItsHighMarkParksTheProducer" {} // per speed 1..4
test "aPausedLoopStillServicesRequestsAndTheCards" {}
test "theVertexCacheEngineAndRewindBudgetCrossOnlyOnChange" {} // two iterates, one call each
test "aRefusedEngineIsNotRetried" {}
test "runaheadRunsOnlyAtOneXAndStagesTheRealFrameUntilItsGroupIsIn" {}
test "aRewindStepPublishesItsShadowAndResyncBeforeItsStreams" {} // seq of the shadow < every stream's seq; resync set before the first stream is visible
test "aRewindStepWritesTheWentBackStretchReversedAndDropsThePicturesOwnAudio" {}
test "theShadowIsPublishedOnlyWhenSomethingReadsIt" {} // !wanted, !24-bit -> no publishShadow; wantsShadow -> one
test "theDisplayIsPublishedAfterTheShadow" {}
test "aPressIsDrainedOnce" {} // PadStateTests port, against Controls
```

- [ ] **Step 2: Run them; they fail**
- [ ] **Step 3: Implement**
- [ ] **Step 4: `zig build test` passes**
- [ ] **Step 5: Commit** `feat(session): the frame path, runahead and rewind as one testable iteration`

---

### Task 9: The emulator thread

**Files:**
- Create: `ps1-session/src/emulator_thread.zig`, `ps1-session/tests/emulator_thread_test.zig`

**Interfaces:**
- Produces: `EmulatorThread(M)`: `pub fn start(self: *Self, loop: *RunLoop(M), pacer: *Pacer, io) !void` spawns a thread with a 1 MB stack and QoS `QOS_CLASS_USER_INTERACTIVE` (`pthread_set_qos_class_self_np` at thread entry) and names it `ps1.emulator`. Each pass: an `objc.Pool`, `seen = pacer.generation()`, `iterate(now)`, then on `.wait` `pacer.wait(seen, timeout)`; exit when `running` is false. `pub fn stop(self)` stores `running = false`, bumps the pacer and **joins with no timeout** (every wait is bounded or woken by the bump). The caller then runs `failPendingRequests` and THEN `flushMemoryCards`, never before the join.
- Every producer-side setter in Task 14 bumps the pacer after its store, and so do the mixer's `drained` waker and the queue's `on_drained` waker.

- [ ] **Step 1: Write the failing tests** (`FakeMachine`, `std.testing.io`):

```zig
test "stopReturnsPromptlyFromEveryWait" {} // park in paused, audio, queue, rewind_idle: stop() < 200 ms each (Review Focus 3)
test "stopAnswersEveryPendingRequest" {} // a save and a load queued while paused -> both get PS1_ERR_SESSION_STOPPED
test "theCardsAreFlushedAfterTheJoin" {} // Fake records takeMemcard after the last runFrame
test "aSetterWakesAPausedThreadWithoutWaitingOutItsTimeout" {} // unpause -> first runFrame within 10 ms
test "theMixersWakeReachesTheProducerWithoutALock" {}
    // ring above high water; render through Mixer.pull on the test thread below the low mark;
    // the producer runs a frame; Mixer.pull takes no Lock (Lock in debug builds counts acquisitions
    // per thread; assert the test thread's count is 0).
```

- [ ] **Step 2: Run them; they fail**
- [ ] **Step 3: Implement.** Give `Lock` a debug-only per-thread acquisition counter (`threadlocal var held_total: usize`) for the last test.
- [ ] **Step 4: `zig build test` passes, five runs in a row** (`for i in 1 2 3 4 5; do zig build test || break; done`): the thread tests must not flake
- [ ] **Step 5: Commit** `feat(session): the emulator thread on one futex word`

---

### Task 10: CoreAudio output

**Files:**
- Create: `ps1-session/src/coreaudio.zig`; `ps1-session/device_test.zig`; `ps1-session/tests/coreaudio_test.zig`
- Modify: `build.zig`: a `session_device_test` binary under the `metal_available` branch, linking `linkMetal` + `AudioToolbox`, run by `test-metal`

**Interfaces:**
- Produces: `Output = struct { unit, stretch, mixer: *Mixer }` with `pub fn init(mixer: *Mixer) Error!Output` (the same format, max frames per slice 4096, both callbacks and initialisation as `AudioOutput.setup`), `start() Error!void`, `stop()` (stop, uninitialise, dispose; idempotent), and `Error = error{ NoComponent, OsStatus }` carrying the `OSStatus` in a field for the log. Every constant (`kAudioUnitType_Output`, `kAudioUnitSubType_DefaultOutput`, `kAudioUnitType_FormatConverter`, `kAudioUnitSubType_NewTimePitch`, `kAudioUnitManufacturer_Apple`, `kAudioFormatLinearPCM`, the flag bits, `kAudioUnitProperty_StreamFormat` / `_MaximumFramesPerSlice` / `_SetRenderCallback`, the scopes, `kNewTimePitchParam_Rate`) is declared once and pinned in a comment to its SDK header line, as `mtl_enums.zig` does.
- The output callback calls `mixer.render(left, right, stretch)`, where `stretch` wraps `AudioUnitReset`, `AudioUnitSetParameter` and `AudioUnitRender` on the time-pitch unit. The stretch's input callback calls `mixer.pull`. Both callbacks are `callconv(.c)` and touch nothing else.
- Produces: `NullOutput` for tests and headless sessions. Nothing drains it until a test calls `mixer.pull` itself.

- [ ] **Step 1: Write the failing tests:** `test "theOutputUnitBuildsStartsAndStops"` (skips naming "no default output device" when `AudioComponentFindNext` returns null or start fails with no device); `test "aStoppedOutputStopsAgainHarmlessly"`; `test "theRealCallbackPullsFromTheRing"` (start, fill the ring, wait up to 1 s for `filled` to fall).
- [ ] **Step 2: Run; they fail** (`zig build test-metal -Dmetal-filter=Output`)
- [ ] **Step 3: Implement**
- [ ] **Step 4: `zig build test-metal` passes**
- [ ] **Step 5: Commit** `feat(session): CoreAudio output and the time-pitch unit behind the mixer`

---

### Task 11: The runtime class, the run loop and the layer

**Files:**
- Modify: `ps1-metal/src/objc.zig`: `allocateClassPair(super: Class, name: [:0]const u8) ?Class`, `addMethod(cls, comptime selector, imp: *const anyopaque, types: [:0]const u8) bool`, `registerClassPair(cls)`, `getAssociated/setIvar`-free design: the target object carries its Zig context as ONE ivar, `zig_ctx` (`class_addIvar` before registering, then `object_setInstanceVariable`/`object_getInstanceVariable`)
- Create: `ps1-metal/src/cf.zig`: `CFRunLoopGetCurrent`, `CFRunLoopRun`, `CFRunLoopStop`, `CFRunLoopWakeUp`, `CFRunLoopSourceCreate` (version-0 context with `perform`), `CFRunLoopAddSource`, `CFRunLoopSourceSignal`, `CFRunLoopSourceInvalidate`, `CFRunLoopTimerCreate`/`AddTimer`/`Invalidate`, `kCFRunLoopDefaultMode`, `kCFRunLoopCommonModes`, `CFRelease`
- Create: `ps1-metal/src/mtl_layer.zig`: `MetalLayer` (`new`, `setDevice`, `setPixelFormat(.bgra8_unorm)`, `setFramebufferOnly(true)`, `setPresentsWithTransaction(false)`, `setDrawableSize(w, h)`, `setContentsScale`, `nextDrawable() ?Drawable`), `Drawable` (`texture()`, and `present` through `CommandBuffer.presentDrawable`, which this task adds to `mtl_encode.zig`), `View` (`setWantsLayer`, `setLayer`, `displayLink(target: objc.Id, sel) DisplayLink`), `DisplayLink` (`addToCurrentRunLoop(common modes)`, `setPaused`, `invalidate`), `Window` (test-only helper: a borderless `NSWindow` holding a view, `orderFront`, `close`), `onMainThread() bool`
- Test: `ps1-metal/tests/layer_test.zig`

**Interfaces:**
- Produces: `objc.TargetClass(comptime name, comptime Ctx, comptime method: fn (*Ctx) void)`, a class with one method `-fire:` that calls `method` on the ivar's context. It is registered once per process (cached like `class()`), and `instance(ctx: *Ctx) objc.Id` returns a retained object. The display link's target and the timer fallback both use it.

- [ ] **Step 1: Write the failing tests**

```zig
test "aRuntimeClassCallsItsZigMethodWithItsContext" {} // msg(void, obj, "fire:", .{null}) increments ctx.count
test "aStandaloneLayerVendsADrawableAndPresentsIt" {} // drawableSize 64x48, clear pass into drawable, present, wait completed
test "aRunLoopSourceSignalledFromAnotherThreadPerformsOnTheLoopsThread" {}
test "aDisplayLinkOnAViewInAWindowFiresOnTheThreadThatAddedIt" {
    // NSApplication.sharedApplication; a borderless window on the main screen; the link created on
    // the main (test) thread, added to a spawned thread's run loop; it fires within 1 s on THAT thread.
    // Skips naming "no screen" when NSScreen.mainScreen is nil.
}
```

- [ ] **Step 2: Run; they fail** (`zig build test-metal -Dmetal-filter=Layer` and the others by name)
- [ ] **Step 3: Implement.** `linkMetal` gains `AppKit`.
- [ ] **Step 4: `zig build test-metal` passes; `zig build test-metal-validate` passes**
- [ ] **Step 5: Commit** `feat(metal): a runtime class, the CFRunLoop calls and the layer, view and display link`

---

### Task 12: `FrameRenderer`: the render thread's work, without the thread

This is `MetalDisplayView.Coordinator.draw` split into its two triggers, with the settings that used to be SwiftUI updates arriving as values.

**Files:**
- Create: `ps1-metal/src/frame_renderer.zig`, `ps1-metal/tests/frame_renderer_test.zig`

**Interfaces:**
- Consumes: `Exchange` (Task 3), `pipelines.Set`, `LiveRenderer.rebuildVram`, `display.paramsFor` (Task 1), `MetalLayer`/`Drawable` (Task 11), `screenshot.*`, `png.encode`.
- Produces: `Settings = struct { scale: u32 = 1, depth_buffer: bool = false, dither: pi.DitherMode, texture_filter: pi.TextureFilter, sprite_filter: pi.TextureFilter, size_points: [2]f64 = .{0, 0}, backing_scale: f64 = 1, occluded: bool = false, paused: bool = false, band_shown: bool = false }` and `Mailbox` (a `Lock` around a `Settings` plus a `changed` flag; `post(Settings)` from any thread, `take() ?Settings` on the render thread).
- Produces: `FrameRenderer`:
  - `pub fn init(alloc, m: Metal, x: *Exchange, band: display.Band, debug: Debug, initial: Settings) !*FrameRenderer` builds the `Set` and `DisplayPass` once and the `LiveRenderer` at `initial.scale`/`depth_buffer`; `Debug = struct { live_diff, software_display, live_stats }`.
  - `pub fn applySettings(self) !void`: takes the mailbox; on a scale or depth change, `live.rebuildVram` and then `x.queue.requestResync()`, **from this thread, the only consumer**; dither and filters go straight onto the rasterizer.
  - `pub fn executeArrived(self) void` drains with `x.acquireShadow` as the shadow source, and runs the `PS1_LIVE_DIFF` oracle when on. It runs whether occluded or not, so the texture stays faithful and unoccluding needs no resync.
  - `pub fn present(self, layer: ?MetalLayer, now_s: f64) void`: nothing when occluded or `layer == null`; else Swift's `draw` from "A runahead picture is shown…" on: the display choice, the shadow upload for 24-bit/software display, letterbox, band, pause fade, encode, the screenshots, present, commit. `drawableSize` is set from `size_points * backing_scale` before `nextDrawable` when it changed.
  - `pub fn requestScreenshot(self, done: ScreenshotDone, ctx: ?*anyopaque) void` (any thread; a bounded list under a `Lock`). `ScreenshotDone = *const fn (ctx, png: ?[*]const u8, len: usize) callconv(.c) void`. Answered from the next PRESENT, or from the next execute when `layer == null` or occluded, so a hidden window still answers. Every block owns its target texture and its request list, per `screenshot_test`'s owned-context pattern: nothing it touches belongs to the renderer.
  - `pub fn failPendingScreenshots(self)` answers each with `null`.
  - `pub fn deinit(self)` waits for in-flight command buffers (the rasterizer's three frame slots and any screenshot), then frees.

- [ ] **Step 1: Write the failing tests** (standalone `CAMetalLayer`, no window):

```zig
test "theRendererBuildsAtTheScaleItWasGiven" {}
test "aScaleChangeRaisesAResyncFromTheRenderThread" {} // clearResync; post scale 3; applySettings; needsResync
test "aScaleChangeLeavesExactlyOneConsumer" {} // after the change, a published frame is executed into the NEW vram (readback matches Rig at 3x)
test "aDepthToggleRebuildsTheVramAndResyncs" {}
test "anOccludedRendererExecutesButDoesNotPresent" {} // executed seq advances; layer presented count 0
test "aRunaheadPictureIsShownWhereItsOwnFrameDisplaysUnlessEitherIs24Bit" {} // the three cases
test "aRequestIsTakenOnce" {} // two presents after one request -> one answer
test "aScreenshotOfADisabledDisplayIsAPlainBlackVgaFrame" {} // 640x480
test "anOccludedRendererStillAnswersAScreenshot" {}
test "aRendererFreedWithAScreenshotInFlightStillAnswersIt" {}
```

- [ ] **Step 2: Run; they fail**
- [ ] **Step 3: Implement**
- [ ] **Step 4: `zig build test-metal -Doptimize=ReleaseFast` and `zig build test-metal-validate` pass**
- [ ] **Step 5: Commit** `feat(metal): the frame renderer: execute on arrival, present on demand, settings as messages`

---

### Task 13: The render thread

**Files:**
- Create: `ps1-metal/src/render_thread.zig`, `ps1-metal/tests/render_thread_test.zig`

**Interfaces:**
- Produces: `RenderThread`:
  - `pub fn start(self, r: *FrameRenderer, layer: ?MetalLayer, link: ?DisplayLink, fallback_hz: ?f64) !void` spawns `ps1.render` (QoS user-interactive). The thread creates its arrival source and adds it to its own `CFRunLoop`. If `link` is given it adds the link to that run loop (common modes); else, if `fallback_hz` is given, it adds a `CFRunLoopTimer` calling `present` at that rate (the tests' trigger); else it never presents. Then it runs the loop. Every callout is wrapped in an `objc.Pool`.
  - `pub fn frameArrived(self) void` (emulator thread): signals the source and wakes the run loop. `Exchange` takes it as a `Waker`, `on_published`, which `RunLoop` calls after each publish and each committed group.
  - The source's `perform`: `applySettings`, then `executeArrived`. The link's or timer's `fire:`: `applySettings`, `executeArrived`, `present(layer, now)`. The two never interleave, because they run on the same run loop.
  - `pub fn stop(self)`: invalidates the link or timer and the source, `CFRunLoopStop`, joins, then `r.failPendingScreenshots()`.
- `Exchange` gains `on_published: ?Waker`, which Task 8's `publish`/`commitStaged`/`commitSpeculativeGroup` call sites invoke. Task 8's tests keep passing with it null.

- [ ] **Step 1: Write the failing tests**

```zig
test "aPublishedFrameIsExecutedWithoutWaitingForAPresent" {} // no link, no timer; publish -> executed seq advances within 50 ms
test "theTimerPresentsTheNewestExecutedFrame" {} // fallback_hz 120, standalone layer, 10 presents observed
test "aDrainWakesAProducerParkedOnAFullQueue" {} // real Pacer + Exchange: queue full, producer waits, render thread drains, producer resumes
test "stopJoinsAndAnswersPendingScreenshots" {}
test "theDisplayLinkDrivesPresentsOnAViewInAWindow" {} // skips naming "no screen"
```

- [ ] **Step 2: Run; they fail**
- [ ] **Step 3: Implement**
- [ ] **Step 4: `zig build test-metal` passes five times in a row**
- [ ] **Step 5: Commit** `feat(metal): the render thread, woken by arrivals and paced by the display link`

---

### Task 14: The session

**Files:**
- Create: `ps1-session/src/session.zig`, `ps1-session/tests/session_test.zig` (device binary)

**Interfaces:**
- Produces: `Session`:
  - `pub fn create(alloc, cfg: Config) Error!*Session` builds the `Handle` (`ps1_create`, engine, fast boot, BIOS, disc, then the resume state if given; a refused resume returns its `PS1_ERR_STATE_*`), the `Exchange`, the ring, the `Mixer`, the `RunLoop`, the `CardStore` (opened, not read) and the `FrameRenderer`. On the main thread, when `cfg.view` is set, it builds the `CAMetalLayer`, installs it on the view (`setWantsLayer`, `setLayer`), and creates the display link with the view. Starts nothing. `Config = struct { bios: []const u8, disc: DiscBytes, resume_state: ?[]const u8, card_dir: []const u8, view: ?objc.Id, band: display.Band, engine: Engine, fast_boot: bool, audio: enum { core_audio, none } = .core_audio }`. `DiscBytes = struct { bin: []const u8, release: ?*const fn (?*anyopaque) callconv(.c) void, release_ctx: ?*anyopaque, cue: ?[]const u8, sbi: ?[]const u8, ppf: ?[]const u8 }`: the session BORROWS `bin` (the `Handle` keeps slices into it, as today) and calls `release` when that disc is replaced or the session freed. `cue`/`sbi`/`ppf` are read during the call only.
  - `pub fn start(self) Error!void`: re-installs both cards from disk, then starts the output, the render thread and the emulator thread. Any failure stops whatever started, in reverse order, and returns `error.Audio`/`error.Thread` (Review Focus 4). Splitting `create` from `start` is what lets the app keep today's ordering: build the new game, free the old session (which FLUSHES its cards), then `start` the new one, which READS them.
  - Setters, each an atomic store or a mailbox post, followed by a pacer bump: buttons, sticks, `pressAnalogButton`, speed (to `Controls` and to the `Mixer`), paused (also to the renderer's settings, for the fade), rewinding, the nine PGXP flags and the tolerance, vertex cache, engine, rewind budget, runahead, gain, dither, texture filter, sprite filter, scale, depth buffer (`Controls` first, then the renderer: the spec's order), size and backing scale, occluded, band shown.
  - Requests: `requestSave`, `requestLoad` (copies the state bytes), `requestReset`, `requestSwap(DiscBytes)`, `requestScreenshot`.
  - Counters: `framesProduced`, `padStatus`, `cardWrites`, `rewindSeconds` (`frames_covered / 60`, as `RewindInfo.seconds`), `motor` (the pad's two motor bytes from the pad status), `newestDisplay`.
  - `pub fn destroy(self)`: output stop → emulator thread stop and join → `failPendingRequests` → `flushMemoryCards` → render thread stop → renderer deinit → the display link invalidated and the layer released (layer removal on the main thread) → `release` on the disc → `ps1_destroy`.
- Debug switches: `PS1_LIVE_DIFF`, `PS1_SOFTWARE_DISPLAY`, `PS1_LIVE_STATS` read once in `create` through `std.c.getenv`.

- [ ] **Step 1: Write the failing tests** (zero BIOS, `audio = .none`, `view = null`, the renderer presenting nowhere):

```zig
test "aSessionStartsRunsAndStops" {} // drain the mixer by hand; framesProduced > 0; destroy
test "aSaveRequestRoundTripsThroughALoad" {}
test "freeingASessionAnswersEveryRequestExactlyOnce" {} // a save, a load, a screenshot queued while paused; destroy; each answered once, none after destroy returns (Review Focus 1)
test "aFailedAudioStartLeavesNoThreadAndFreesCleanly" {} // inject a failing Output; testing allocator reports no leak (Review Focus 4)
test "startReadsTheCardsCreateDoesNot" {} // a card written to disk between create and start is the one installed
test "theDiscIsReleasedOnSwapAndOnFree" {}
test "theDepthBufferReachesTheMachineBeforeTheRenderer" {}
```

- [ ] **Step 2: Run; they fail** (`zig build test-metal -Dmetal-filter=session`)
- [ ] **Step 3: Implement**
- [ ] **Step 4: `zig build test-metal` passes; `zig build test` passes**
- [ ] **Step 5: Commit** `feat(session): one session owning the machine, its threads, its audio and its cards`

---

### Task 15: The session C ABI, built into `libps1core.a`

**Files:**
- Create: `ps1-capi/include/ps1_session.h`, `ps1-session/src/abi.zig`, `ps1-capi/src/lib.zig`, `ps1-session/tests/abi_test.zig`
- Modify: `ps1-capi/include/module.modulemap` (`header "ps1_session.h"`), `ps1-capi/src/root.zig` (new codes), `build.zig` (`capi_obj`'s root becomes `lib.zig`; `ps1_capi`, `ps1_metal` and `ps1_session` modules over `capi_core_mod` at ReleaseFast and `app_target`; `metal_mod` construction factored into `fn metalModule(b, target, optimize, core_mod, fixture_mod) *Module` so it is built twice, once per core), `ps1-macos/PS1.xcodeproj/project.pbxproj` (`OTHER_LDFLAGS` gains `-framework Metal -framework QuartzCore -framework AppKit -framework AudioToolbox -framework CoreGraphics -framework ImageIO -framework CoreFoundation -lobjc`, which are autolinked through Swift's imports today and will not be once Plan C deletes them)

**Interfaces:**
- New codes appended in `root.zig` and both headers: `PS1_ERR_AUDIO = -21`, `PS1_ERR_NO_METAL = -22`, `PS1_ERR_SESSION_STOPPED = -23`, `PS1_ERR_BUSY = -24`, `PS1_ERR_SUPERSEDED = -25`.
- `ps1_session.h` declares (C names; each forwards to Task 14):
  - `typedef struct Ps1Session Ps1Session;`
  - `typedef struct { const uint8_t *bin; size_t bin_len; void (*release)(void *ctx); void *release_ctx; const uint8_t *cue; size_t cue_len; const uint8_t *sbi; size_t sbi_len; const uint8_t *ppf; size_t ppf_len; } Ps1DiscBytes;`
  - `typedef struct { const uint8_t *bios; size_t bios_len; Ps1DiscBytes disc; const uint8_t *resume_state; size_t resume_len; const char *card_dir; void *ns_view; double band_height, band_edge, band_sigma; int cpu_engine; uint8_t fast_boot; } Ps1SessionConfig;`
  - `int32_t ps1_session_new(const Ps1SessionConfig *, Ps1Session **out)`; `int32_t ps1_session_start(Ps1Session *)`; `void ps1_session_free(Ps1Session *)`
  - setters `ps1_session_set_buttons(s, uint16_t)`, `_set_sticks(s, uint8_t lx, ly, rx, ry)`, `_press_analog(s)`, `_set_speed(s, int)`, `_set_paused(s, uint8_t)`, `_set_rewinding`, `_set_pgxp(s, const Ps1PgxpSettings *)` (one struct: the ten flags and the tolerance, so the app's per-frame re-apply is one call), `_set_cpu_engine`, `_set_rewind_budget(s, size_t)`, `_set_runahead`, `_set_gain(s, float)`, `_set_dither(s, int)`, `_set_texture_filter`, `_set_sprite_filter`, `_set_scale`, `_set_size(s, double w_pt, double h_pt, double backing_scale)`, `_set_occluded`, `_set_band_shown`
  - requests `ps1_session_request_save(s, Ps1SaveDone, void *ctx)`, `_request_load(s, const uint8_t *, size_t, Ps1LoadDone, void *)`, `_request_reset(s, Ps1Done, void *)`, `_request_swap(s, const Ps1DiscBytes *, Ps1Done, void *)`, `_request_screenshot(s, Ps1ScreenshotDone, void *)`, with the four callback typedefs matching Task 7/12, and the header saying: "called exactly once, on a session thread, with bytes valid only during the call".
  - counters `uint64_t ps1_session_frames_produced(s)`, `void ps1_session_pad_status(s, Ps1PadStatus *)`, `uint64_t ps1_session_card_writes(s)`, `double ps1_session_rewind_seconds(s)`, `void ps1_session_newest_display(s, Ps1Display *)`
- `lib.zig`: `comptime { _ = @import("ps1_capi"); if (arm64 macOS) _ = @import("ps1_session").abi; }`.

- [ ] **Step 1: Write the failing tests:** `abi_test.zig` (device binary) calls the exported functions through their C signatures with C callbacks: new with a zero BIOS and a null view, start with `audio = none` reached through a test-only `ps1_session_new_headless` **declared in `abi.zig` only under `builtin.is_test`**, a save completion, free answering a pending load with `PS1_ERR_SESSION_STOPPED`. Add a build check that `nm zig-out/lib/libps1core.a` lists `_ps1_session_new` and still lists `_ps1_take_frame_stream` (Plan C removes it).
- [ ] **Step 2: Run; they fail**
- [ ] **Step 3: Implement**
- [ ] **Step 4: Verify.** `zig build test` passes; `zig build test-metal -Doptimize=ReleaseFast` passes; `zig build capi-lib` succeeds and the `nm` check holds; **`zig build macos` still builds the app**, and the app still plays a disc on the Swift path (launch Crash, play ten seconds, quit: no regression, because nothing in the app calls the session yet); `pkill -x Substation; ps1-macos/test.sh` passes; `zig build trace-golden -Doptimize=ReleaseFast -- verify` passes.
- [ ] **Step 5: Commit** `feat(capi): the session ABI in libps1core.a`

---

## Self-review notes

- **Spec coverage.** Step 6 is covered: the emulator thread (Tasks 7-9), requests (Task 7), cards (Task 5), rewind and runahead orchestration (Tasks 6 and 8), and audio (Tasks 4 and 10), tested against the scripted machine and a null sink. Step 7 is covered: the runtime class, the CFRunLoop and the layer (Task 11), the render thread and the display link (Tasks 12-13), and the session C ABI (Task 15). Backpressure as a rule is Tasks 2, 8 and 9; occlusion as a message is Task 12; scale and depth as messages are Tasks 1 and 12; pipelines once is Task 1; the fades and band on the render thread are Task 12; the debug switches read once are Task 14; the cards written by Zig through temp-and-rename are Task 5. Steps 8-10 belong to Plan C.
- **Deliberate departures, each stated where it lands:** waits use `std.Io` (0.17 has no `std.Thread` primitives); a failed card write is retried rather than dropped (Task 5); the shadow is a real triple buffer rather than three slots with a copy (Task 3); `create`/`start` are split for the card ordering (Task 14); the disc bytes carry a release callback (Task 14).
