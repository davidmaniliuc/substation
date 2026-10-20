# The engine into Zig, Swift for the user: design

**Date:** 2026-10-20
**Status:** draft for review (second draft: the Ghostty shape)
**Follows:** `2026-08-23-metal-hardware-renderer-design.md` (the umbrella) and
its phase specs. This spec moves code and threads; it decides no new rendering
or emulation behaviour.
**Followed by:** a second spec, "GPU-only VRAM", that drops the software
rasterizer from the app, with the dual rasterizer kept as a per-game override.
It is not designed here.

## Intent

The Swift app holds two things that are not user interface. One is the Metal
renderer, much of which exists only because Swift cannot see the core:
`DrawEnv.swift` re-implements `registers.zig`, `VramTransfer.swift` the
transfer state, `LineExpander.swift` the line walk in `renderer.zig`, and
`ShadowVram`/`Fnv1a`/`FixtureFile`/`VramDump` are the Swift half of a fixture
bridge built because "no Zig test can run Metal". The other is the machine's
run loop: `EmulatorRunner` (the emulator thread, audio as master clock,
backpressure, rewind and runahead orchestration, request servicing, memory-card
flushing), `AudioOutput`/`AudioRing`/`TempoControl`, `Runahead`, `RewindAudio`
and `StreamQueue`. Every frame is copied from the core into Swift-owned slots
just so it can cross the C ABI, and three threads coordinate across a language
boundary with polls (`StreamBackpressure`'s 2 ms poll, the 250 ms "renderer
gone" guess) because neither side can wait on the other's condition.

Nobody chose Swift for either. The app came first, with Metal only to show the
frame, and both the renderer and the loop grew where the app already was.

Ghostty is the shape to copy. libghostty (Zig) owns the terminal, its I/O
thread, its renderer and the renderer's thread; the Swift app creates a plain
`NSView`, hands it to `ghostty_surface_new`, and from then on sends input,
size, focus and occlusion, and answers callbacks. **This spec does the same:
everything below the user interface moves into Zig, and Swift keeps what the
player sees and touches.**

It is also the groundwork for the GPU-only spec: every readback that spec adds
(GPUREAD, savestates, the 24-bit display, rewind) becomes an ordinary Zig call
on threads Zig owns, instead of a callback across the C ABI into Swift.

## The line between the two languages

**Zig owns everything that is not user-facing:**

- the machine and the only thread that touches it (the emulator thread):
  frame pacing, audio as master clock, backpressure, rewind stepping and its
  reversed audio, runahead's mark/speculate/return sequence, disc swap, reset,
  save/load servicing, the memory-card flush policy and writing the card files;
- audio output: the CoreAudio output unit, the time-pitch unit above 1x, the
  ring, `TempoControl`, the gain;
- the renderer and the thread that drives it: the `CAMetalLayer` on the view
  Swift hands over, the display link, VRAM on the GPU, the rasterizer,
  primitive building and encoding, hazard tracking, the frame queue and every
  resync rule, runahead replay and the region restore, the display pass
  (scanout, letterbox, 24-bit, sidecar, pause saturation, the toolbar band and
  both fades), and screenshot and resume-thumbnail rendering with their PNG
  encoding (ImageIO, a C API);
- the debug switches (`PS1_LIVE_DIFF`, `PS1_SOFTWARE_DISPLAY`,
  `PS1_LIVE_STATS`), read once at session creation.

**Swift keeps everything user-facing:**

- windows, SwiftUI, menus, the HUD, the pause menu, sheets, settings panes,
  the library, covers, onboarding, About;
- the setting types and their `UserDefaults` storage (`DitherMode`,
  `TextureFilter`, `InternalResolution`, the PGXP toggles, rewind, runahead,
  the CPU engine, volume), which call one session setter on change;
- input: keyboard and `GameController` mapping (`InputMap`, `KeyBindings`,
  `PadEdges`), pushed to the session as a button mask and sticks;
- haptics (`PadHaptics`, CoreHaptics), driven from the motor state the session
  publishes;
- choosing files: the BIOS, the disc and its sidecars, which Swift reads and
  hands over as bytes, as today; the directory the cards live in; save-state
  files and their list (`SaveStateStore`); screenshot naming and where they are
  saved;
- the window's aspect lock (`WindowConfigurator`) and the toolbar geometry the
  band is drawn under (passed as points, once).

A rule of thumb for anything not listed: if a player can see it, name it or
pick it, it is Swift's; if it runs per frame or per sample, it is Zig's.

## Goals

1. A new module, `ps1-session/`, written in Zig, owns the emulator thread, the
   audio output and the session C ABI. A second new module, `ps1-metal/`, owns
   the renderer and its thread. Both are linked into `libps1core.a`
   (`zig build capi-lib`) on macOS and nowhere else. `ps1-core` itself gains no
   Metal, no Objective-C, no CoreAudio and no threads.
2. The Swift duplicates are deleted, not ported: the Zig side calls the core's
   own `registers.zig`, `command.zig`, `vram.zig`, the line walk in
   `renderer.zig`, and `ps1-golden/fixture.zig`.
3. Every gate the Swift suite runs today over the renderer, the runner, the
   queue and audio runs under Zig: the Metal ones in a new
   `zig build test-metal`, the rest in `zig build test`. They do not get weaker,
   and Gate 1 gets stronger (see Testing).
4. Nothing changes for the player in pixels, settings, saves or audio. Timing
   changes in one direction only: the 180 fps fast-forward cap at 1x lifts,
   because the renderer executes frames as they arrive rather than at 60 Hz.
   Nothing else may get slower or less smooth, measured.
5. Two cross-thread heuristics become rules: backpressure is a blocking wait
   the renderer wakes, not a 2 ms poll, and "the renderer is gone" is an
   explicit occlusion or teardown, not a 250 ms timeout.

## Non-goals

- **GPU-only VRAM.** The app still builds `gpu_sink = .dual` and the software
  shadow stays complete. That is the next spec.
- **Shader changes.** `Rasterizer.metal`, `DisplayShader.metal`,
  `PrimInstance.h` and `Ps1Color.h` move unchanged.
- **The browser build.** `ps1-wasm` keeps the software rasterizer and its own
  loop.
- **Rethinking the settings UI**, the library, or any Swift surface beyond
  re-pointing it at the session.
- **Disc identification.** `DiscIdentity.swift` and `CueSheet.swift` overlap
  `discid.zig` and `disc.zig`; folding them in is a follow-up, listed below.

## Anti-goals (a failure even if it works)

- **Any golden, fixture hash or `.p1fx` recaptured.** The move is behaviour-
  identical by definition, and a moved hash is a bug in the port.
- **A gate weakened to make the port pass**, or one quietly dropped because it
  was awkward to port. Each Swift test is ported or explicitly retired with a
  reason in the plan.
- **Metal, Objective-C, CoreAudio or threads reaching `ps1-core/src`.**
- **A second copy of anything the core already knows.**
- **Raw `objc_msgSend` spread through the renderer.** It belongs in one file.
- **A lock, an allocation or a blocking call on the CoreAudio render thread.**
  Today's `signalAudioDrained` takes an `NSCondition` there; the Zig version
  wakes the emulator thread with a futex on an atomic, which takes no lock.
- **Swift touching the machine while a session runs.** The emulator thread is
  the only caller of the core; every Swift action is a message.

## Constraints

- **Every rule in CLAUDE.md's "GPU + Metal" and PGXP sections still holds**,
  and the reasoning in the `ps1-gpu-metal` skill moves with the code. In
  particular: coverage decided in the fragment shader; integer blending; one
  instance per primitive with state resolved on the CPU; the hazard rule
  (symmetric, read rects as a list, uploads and fills ordered by the rule while
  copies still bracket); records stay in native units at every scale; the
  recorder is drained exactly once per `runFrame`; VRAM is published before the
  stream under the same seq; `discardThrough` and not `discardAll`; the resync
  flag is cleared before the shadow is sampled; the repair debt for lost
  frames; the real frame is staged until its runahead group commits; between
  frames the texture holds only the real timeline; 24-bit scans out of the 1x
  shadow; the scanout wrap is native, then scaled.
- **Every rule in `EmulatorRunner`'s comments still holds**: audio is the
  master clock and the water marks scale with speed; the rewind high-water mark
  and its drain-time sleep; runahead only at 1x; save before load, load before
  reset, all three serviced above the paused early-out; a load flushes the
  cards first and re-installs them after; a reset and a load both request a
  resync; a rewind step publishes a forced shadow, requests a resync, and only
  then publishes its streams; a vertex-cache, engine or rewind-budget change
  crosses only on CHANGE; every pending request is ANSWERED when the thread
  stops, never dropped; the cards are flushed after the join, never before.
- **Zig 0.17.0.** No new package dependencies: `build.zig.zon` has none today.
  Threads are `std.Thread`; waits are `std.Thread.Condition`/`Futex`. No
  libxev.
- **No file in `ps1-metal/` or `ps1-session/` over about 600 lines.**
- **The shaders stay compiled offline** into `libps1shaders.a`
  (`zig build metallib`). Never `newLibraryWithSource`.
- **`libps1core.a` is still repacked with `xcrun libtool`**, and it now pulls
  in `Metal`, `QuartzCore`, `AudioToolbox`, `ImageIO`, `CoreGraphics`,
  `CoreFoundation` and `libobjc`. The Xcode project adds whichever it does not
  already link.
- **`zig build test` keeps passing on a machine with no Metal and no audio
  device.** `test-metal` is its own step, macOS only. The session's tests run
  against a null audio sink with a clock the test drives.
- **Retain/release is manual, and every thread Zig owns runs its loop body
  inside its own autorelease pool.** There is no implicit pool on a thread Zig
  started.

## Decisions taken

### Objective-C from Zig: our own typed wrapper

`ps1-metal/src/objc.zig` declares `objc_msgSend`, `sel_registerName`,
`objc_getClass`, the autorelease-pool push/pop, **the block ABI** and **runtime
class creation**. On top of it, `mtl.zig` gives each Metal and QuartzCore
object a small Zig type with methods (`Device`, `CommandQueue`,
`CommandBuffer`, `RenderCommandEncoder`, `BlitCommandEncoder`, `Texture`,
`Buffer`, `RenderPipelineState`, `Library`, `Function`, descriptors,
`MetalLayer`, `Drawable`). Nothing outside those two files sees a selector.

That is what Ghostty does through the zig-objc package. We write our own
because the repo has no dependencies. The surface is larger than the selector
count suggests, and two pieces of it are not optional:

- **Blocks.** `-[MTLCommandBuffer addCompletedHandler:]` takes one, and both
  the three-slot frame-buffer cycling and the screenshot readback wait on it.
  `objc.zig` builds a block literal (`isa = _NSConcreteGlobalBlock` or a heap
  copy, the descriptor, the invoke function) around a Zig function and a
  context pointer.
- **A runtime class.** The display link (below) calls a target/selector pair,
  so `objc.zig` creates one small class with `objc_allocateClassPair`, adds the
  one method, and registers it.

A Swift shim exposing `@_cdecl` functions was considered and rejected. It would
split the renderer across two languages again, and `zig build test-metal`
would need `swiftc` and the Swift runtime linked into a Zig test binary.

### One session, three threads

`ps1_session_new` takes a config (BIOS, disc, cue, sbi, ppf bytes; the card
directory; the `NSView*`; the initial value of every setting) and returns a
`Ps1Session*`. It owns the machine, and starts:

- **the emulator thread**, which owns the core: today's `runLoop`, ported;
- **the render thread**, which owns `ps1-metal`: a `CFRunLoop` with the display
  link and a run-loop source the emulator thread signals when a frame is
  published;
- **the CoreAudio render callback**, which is Apple's thread: it reads the
  ring, applies the gain, drives the time-pitch unit above 1x and wakes the
  emulator thread past the low-water mark, lock-free.

`ps1_session_free` stops all three, joins them, answers every pending request,
flushes the cards, then frees. It replaces `EmulatorRunner.stop`'s one-second
join timeout with a real join: the emulator thread's waits are all
interruptible by the session's stop flag, so a join cannot hang, and the
"the join can time out and race the cards" hazard documented in
`flushMemoryCards` goes away.

The `Ps1*` machine handle and its ABI stay as they are, for `capi_test`, the
resume prompt's `ps1_peek_state`, and anything that inspects a machine without
running it. A running session owns its machine, and Swift has no pointer to it.

### The render thread executes on arrival and presents on the display link

Two triggers, one thread:

- **A frame arrives**: the emulator thread publishes it and signals the
  render thread's run-loop source. The render thread drains the queue and
  EXECUTES every frame into `MetalVram` at once. Execution never waits for
  vsync, so the emulator is limited by the GPU and the audio clock, not by a
  60 Hz drain. This is what lifts the fast-forward cap.
- **The display link fires**: the render thread takes a drawable from its
  `CAMetalLayer`, encodes the display pass of the newest executed frame, and
  presents. Drain-all/present-newest is unchanged; only the drain moves earlier.

The display link is `-[NSView displayLinkWithTarget:selector:]` (macOS 14+),
added to the render thread's run loop. `CVDisplayLink`, which Ghostty uses, is
deprecated since macOS 15 and is not used. The link follows the screen the
view is on, so a 120 Hz panel presents at 120 Hz with no change, exactly as
the `MTKView` did.

The layer is a `CAMetalLayer` the renderer creates and installs on the view
Swift hands over (`setWantsLayer:` and `setLayer:` on the main thread, once,
during `ps1_session_new`), with `presentsWithTransaction = NO` so presenting
needs no main-thread transaction. Swift sends the view's size in points and
its backing scale whenever they change (`ps1_session_set_size`); the render
thread sets `drawableSize` before its next drawable. Live resize is a hand
check: if the stretched-frame artifact Ghostty met appears there, the plan
adopts its remedy (an `IOSurface`-backed layer) rather than this spec guessing
now.

### Backpressure and occlusion become rules

- **A full queue blocks the emulator thread on a condition the render thread
  signals as it drains.** No poll. `StreamBackpressure` is deleted.
- **A hidden window is an occlusion message**, sent from the window's
  `occlusionState` (`ps1_session_set_occluded`). While occluded the render
  thread keeps EXECUTING frames (the texture stays a faithful picture, so
  unoccluding needs no resync and no 1x adoption) and stops PRESENTING. The
  emulator keeps running and the audio keeps playing, as today.
- **A torn-down view is `ps1_session_free`**, which ends both threads; there
  is no state in which the producer waits on a consumer that no longer exists.
  The 250 ms rule is deleted.
- **`dropped` and the repair debt stay** for the losses that remain: an
  incomplete (overflowed) recording and an oversized frame. The plan checks
  whether a stalled-renderer drop can still happen at all; if not, it says so
  and the tests that pinned it are retired with that reason.

### Scale and the depth buffer are messages, not rebuilds

Today a scale change or a depth-buffer toggle rebuilds the SwiftUI coordinator
through `.id()`, and the superseded coordinator must not drain
(`claimConsumer`/`ownsStream`): the class of bug behind Crash 1's level
vanishing on 2026-09-27. With one session that owns its renderer, both are
setters. The render thread rebuilds `MetalVram` between frames and raises a
resync **on its own queue, from the thread that consumes it**, so no second
consumer can ever exist. `claimConsumer`, `isConsumer` and the coordinator
rebuild are deleted. The depth-buffer setter reaches the emulator thread
(the core flag, and whether shadows carry a depth plane) and the render thread
(the attachment's storage mode) in that order, and the resync that follows
covers the frames in between.

The 28 pipelines are built once, on the render thread, at session creation, so
the ~1.15 s cold build leaves the main thread for free. A frame published
before they are ready waits in the queue, and backpressure holds the emulator
if it fills.

### The fades and the band move with the display pass

The display pass is drawn on the render thread, so the per-draw values are
computed there: `PauseFade` and the band's `DrawFade` are ported (they are
eight lines of easing), and Swift sends the two booleans they ease toward,
paused and band shown. The band's geometry (`ToolbarBand.height`, `edge`,
`sigma`, in points) is a toolbar metric and stays a Swift constant, passed once
in the session config.

### Requests and callbacks

Swift's calls are of three kinds, mirroring `EmulatorRunner`'s public surface
one for one:

- **setters** (buttons, sticks, analog press, speed, pause, rewinding, every
  PGXP setting, engine, rewind budget, runahead, gain, dither, both filters,
  scale, depth buffer, size, occlusion, paused, band shown): an atomic store or
  a message, safe from any thread, never blocking;
- **requests with a completion** (save state with thumbnail, load state, disc
  swap, reset, screenshot): a C function pointer and a context, called once on
  a session thread, always, with an error when the session stopped first.
  Swift hops to the main actor itself, as it does today;
- **polled counters** (frames produced, pad status, card writes, rewind
  seconds, motor drive, the newest display mode): atomic loads, read by the
  HUD's existing 60 Hz poll.

The memory-card files are written by Zig, into the directory Swift named, with
today's file names and `MemoryCardFlushPolicy`'s debounce, through a temporary
file and a rename. `MemoryCardStore` keeps the naming and the directory and
loses the write.

## Shape

### Modules

- **`ps1-metal/`**: `objc.zig`, `mtl.zig`, the renderer (`metal_vram`,
  `rasterizer`, `prim_builder`, `prim_encoders`, `hazard_tracker`,
  `live_renderer`, `speculative_region`, `display`, `screenshot`, `png`), and
  the render thread. Depends on the recording core module (`.dual`).
- **`ps1-session/`**: the session, the emulator thread (`run_loop`,
  `rewind`, `runahead`, `requests`, `cards`), the frame queue's producer half,
  `audio` (output unit, time-pitch, ring, tempo, gain, reversed rewind audio),
  and the session's C ABI. Depends on the core and on `ps1-metal`.
- **`ps1-capi/`** gains the session header beside `ps1.h` and links both.

### What each Swift file becomes

**Moves to Zig, logic unchanged**: `MetalVram`, `MetalRasterizer`,
`PrimBuilder`, `PrimEncoders`, `HazardTracker`, `LiveRenderer`, `StreamQueue`,
`SpeculativeRegion`, `Runahead`, `Shaders`' library loader, `GpuBench` (into
`ps1-bench`), `EmulatorRunner`, `AudioOutput`, `AudioGain`, `AudioRing`,
`TempoControl`, `RewindAudio`, `MemoryCardFlushPolicy`, `ResumeThumbnail`'s
render and PNG, `Screenshot`'s render and PNG, `letterboxScale`,
`DisplayParams`, `DrawFade`, `PauseFade`.

**Deleted, replaced by the core's own code**: `DrawEnv` (`gpu/registers.zig`),
`VramTransfer` (the core's transfer state), `LineExpander` (the line walk in
`renderer.zig`, exposed so both call the same function), `ShadowVram` (the
fixture tests compare against `command.execute` directly), `Fnv1a` and
`FixtureFile` (`ps1-golden/fixture.zig`), `VramDump` and `VramImage`
(rewritten in Zig next to the tests that use them).

**Deleted, made unnecessary by the shape**: `StreamBackpressure`,
`SpeculativeCore`, the coordinator's `claimConsumer`/`ownsStream`, the three
Swift shadow slots and their lock.

**Stays in Swift, re-pointed**: `MetalDisplayView` (now a plain `NSView`
representable that creates the session's view and forwards size and
occlusion; no `MTKView`), `Ps1Core` (shrinks to the session wrapper plus the
static calls the library and resume prompt use), `EmulatorViewModel` (its
`runner` becomes the session), every setting type, `InputMap`, `KeyBindings`,
`PadEdges`, `PadHaptics`, `MemoryCardStore` (naming and directory),
`SaveStateStore`, `Screenshot`'s naming and saving, `WindowConfigurator`,
`ToolbarBand`'s constants.

`PrimInstance.h` and `prim_instance_shim.h` stop being a Swift-facing header.
The Zig side declares `Ps1PrimInstance` itself (an `extern struct`) and checks
its size against the shader's `static_assert` value (54 words) with a
`comptime` assert; `DisplayParams` the same against its 68 bytes.

### The C ABI

The session header is new; its names are the builder's call. Removed from
`ps1.h`: `ps1_take_frame_stream`, `Ps1GpuStream`, `Ps1GpuCommand` and the
record constants, which only the Swift renderer and the fixture bridge use.
`ps1_copy_vram`, `ps1_copy_depth` and `ps1_get_display` stay on the machine
handle for `capi_test`. `capi_test` keeps its coverage of the drain rule
(exercised now through the Zig queue directly) and gains session tests.

### Build

- `capi-lib` adds both modules and links the frameworks above, macOS only.
- `test-metal` builds a test binary over `ps1-metal/` that links the metallib
  archive and the frameworks, macOS only, reading fixtures from
  `zig-out/fixtures/` and the committed ones from
  `ps1-core/tests/goldens/fixtures/`, and skipping a fixture that has not been
  generated, as the Swift gates do today. Run it `-Doptimize=ReleaseFast` for
  the corpus gates.
- `ps1-session/`'s pure tests (water marks, rewind high water and drain time,
  the flush policy, tempo, the ring, reversed audio, the request ordering
  against a scripted machine) join `zig build test`'s list.
- `PS1_DUMP_SCALED` and `PS1_SCALE_TIMING` become environment variables: a Zig
  test binary inherits the environment, which the hosted Swift test process
  never did.
- `ps1-bench` gains a renderer mode that replays fixtures at chosen scales and
  reports GPU and CPU ms per frame and fps, replacing `PS1_GPU_BENCH`. The
  output format stays comparable to the tables in the `ps1-gpu-metal` skill.

## Testing

**Gate 1 gets stronger.** Today the Swift harness compares a replay against
hashes Zig recorded when the fixture was captured, because Swift cannot run the
software rasterizer. In Zig it can: `test-metal` replays each fixture frame
through `command.execute` into a software `Vram` AND through Metal at 1x, and
compares full VRAM after every frame. The recorded hashes are still checked
too, so an old fixture cannot drift silently.

**Every other renderer gate ports as it stands**: Gate 2 downsample-invariance
at N in {2, 3, 4, 8} (3 stays on purpose); the setting-equality gates; the
speculation gate; the hazard tracker; the queue and live-renderer rules
(resync, `discardThrough`, the repair debt and the tests aimed at each half);
`ps1_interp_fuzz`; the hand-built cases named in the skill. The plan carries a
table of every Swift test file this spec touches with its fate: ported to
which Zig test, or retired and why.

**The runner's tests port against a scripted machine.** The orderings that
matter (save before load, the load's card flush and re-install, the rewind
step's shadow/resync/streams order, the staged real frame around a runahead
group, the change-only setters, answering every request at stop) are tested
against a fake core that records calls, so they need no BIOS and no disc. The
audio path is tested against the null sink: the water marks hold, a held rewind
reaches real time, and the render callback path performs no lock and no
allocation (checked by running it under a counting allocator and a mutex that
fails if taken).

**The port is checked against the Swift renderer before the Swift renderer is
deleted.** While both exist, a temporary harness in the Swift test host calls
a temporary ABI entry that replays a fixture through `ps1-metal`, and requires
byte-identical VRAM and sidecar against the Swift renderer over the corpus at
1x, 3x and 8x. The entry and the harness are deleted with the Swift code.

**Performance is a gate, not an afterthought.** Before deletion, `ps1-bench`'s
renderer mode and the old `PS1_GPU_BENCH` run on the same fixtures, scales and
machine, interleaved, best of five. GPU ms must match (same shaders); CPU ms
for encoding must not be worse. In the app: fast-forward at 1x on Spyro must
exceed today's ~240 fps, fast-forward at 4x and 6x must not fall below today's
figures, and the emulator thread's CPU share at 1x normal speed must not rise.

**Hand checks in the app** before any Swift code is deleted: Crash, Silent
Hill (24-bit FMV and fog), FF7's menu (the lost-upload repair), FF8's movie
uploads, runahead on and off, rewind held to the end of the history, a scale
change and a depth-buffer toggle mid-game, a disc swap, save/load/reset, the
window hidden and shown again, a live resize, a move to a 120 Hz screen,
screenshots at 1x and 4x, the resume thumbnail, quitting during a card write,
and one `PS1_LIVE_DIFF=1` run at `.native` with its checked/skipped tally read.

All existing gates stay green throughout: `zig build test`,
`trace-golden -- verify` (and `stream-verify`), and `ps1-macos/test.sh` for
what is left of it.

## Order of work (suggested; the plan may refine it)

The app keeps running on today's Swift path, untouched, until step 9. The
switch is one change because a half-way point (a Zig renderer under a Swift
runner) needs the two-handle ABI this spec exists to delete; the lockstep,
the benchmarks and the hand checks are what make one switch safe.

1. `objc.zig` and `mtl.zig`, blocks and the runtime class included, plus a
   `test-metal` step that clears a texture, reads it back in a completion
   block, and fires a display link once.
2. `MetalVram` and the movers in Zig, with the mover gates and the in-process
   comparison against `command.execute`.
3. Primitive building and encoding with the 28 pipelines, and hazard tracking.
   Gate 1 and Gate 2 over the full corpus.
4. The display pass, the fades, screenshots and thumbnails with PNG, offscreen,
   with the display tests (letterbox, 24-bit, native-then-scaled wrap, sidecar
   presence).
5. The queue, the live-renderer rules, runahead replay and the region restore,
   with their tests.
6. `ps1-session`: the emulator thread, requests, cards, rewind and runahead
   orchestration, audio, all tested against the scripted machine and the null
   sink.
7. The render thread, the layer and the display link; the session C ABI.
8. The lockstep against the Swift renderer and the performance comparison.
9. Switch the app over, run the hand checks, then delete the Swift renderer,
   runner, audio, queue, runahead and the fixture bridge, and their tests.
10. Update CLAUDE.md (the layout section, the quick commands, the frontend
    count, the rules that name Swift files or `ps1_take_frame_stream`), the
    `ps1-gpu-metal` and `ps1-macos-app` skills, and the test count in
    `ps1-macos/test.sh`'s line.

## Left to the builder

- Exact C ABI names and signatures.
- Whether the recorder hands its buffers to the queue by swapping or copying,
  provided the emulator thread stays allocation-free.
- File layout inside both modules.
- How `test-metal` is organised, provided every gate in the port table is
  there.
- Whether the 120 Hz present path needs anything beyond the display link
  following the view's screen.

## Follow-ups (not in this spec)

- GPU-only VRAM with the dual rasterizer as a per-game override (the next
  spec).
- Disc identification into Zig: `DiscIdentity.swift` and `CueSheet.swift`
  against `discid.zig` and `disc.zig`.
- An `IOSurface`-backed layer, if live resize needs it.
