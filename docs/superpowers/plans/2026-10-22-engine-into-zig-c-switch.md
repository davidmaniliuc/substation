# Engine into Zig, Plan C: the switch

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The macOS app runs every game through the Zig session (`ps1_session_*`), after a lockstep and a benchmark have shown the Zig renderer to be identical to the Swift one. Then the Swift renderer, runner, audio, queue, runahead and fixture bridge are deleted, along with their tests and `ps1_take_frame_stream`, and the docs describe the new shape.

**Architecture:** Swift reaches the session through one protocol, `GameSession`. The real conformer, `Session`, wraps the C ABI. The tests use `ScriptedSession`, which records calls and lets a test answer requests by hand, as the runner's `service*` seams did. The view model owns the session and a plain `NSView`, `SessionHostView`. It creates the view before `ps1_session_new` and keeps it for the session's life, and the SwiftUI representable only ever returns that one view. The order is: measure (Tasks 1-3), switch (Tasks 4-6), check by hand (Task 7), delete (Tasks 8-9), write it down (Task 10).

**Tech Stack:** Zig 0.17.0, Swift/SwiftUI/AppKit (`xcodebuild`, swift-testing), Metal.

**Spec:** `docs/superpowers/specs/2026-10-20-metal-renderer-into-zig-design.md`, "Order of work" steps 8, 9 and 10, plus the "Testing" section's lockstep, performance and hand-check paragraphs. Plan A (`2026-10-20-engine-into-zig-a-renderer.md`) and Plan B (`2026-10-21-engine-into-zig-b-session.md`) are done; their port tables say what already lives in Zig.

## The three plans

- **Plan A (done, 728f9bf):** `ps1-metal/`, headless, gated by `test-metal`.
- **Plan B (done, f717058):** `ps1-session/`, the render thread, the session C ABI in `libps1core.a`. The app was not switched over.
- **Plan C (this one):** the lockstep, the performance comparison, the switch, the hand checks, the deletion and the docs.

## Global Constraints

- Zig **0.17.0**. `build.zig.zon` gains no dependency.
- **No golden, fixture hash or `.p1fx` is recaptured.** A moved hash is a bug in the port.
- **No gate is weakened.** Every Swift test this plan deletes is either already ported (Plan A/B port tables), ported here, or retired in this plan's table with a reason.
- **Metal, Objective-C, CoreAudio and threads stay out of `ps1-core/src`.**
- **Swift never touches the machine while a session runs.** Every action is a session setter or request.
- **A completion never blocks on the main thread.** Session completions run on a session thread, or on the caller's thread during `ps1_session_free`. The Swift trampolines hop with `DispatchQueue.main.async` / `Task { @MainActor }`, never `.sync`.
- **`ps1_session_new` and `ps1_session_free` run on the main thread** whenever `ns_view` is non-NULL (header rule 4).
- **The app keeps working at every commit.** Tasks 1-3 leave the app on the Swift path. Task 6 switches it in one commit. Task 8 deletes only what Task 6 left without a caller.
- **The lockstep entry and its Swift harness are TEMPORARY.** Task 8 deletes both.
- **`pkill -x Substation` before `ps1-macos/test.sh`.**
- Commit messages are **a title line only** (plus the Co-Authored-By trailer). Commit on master and do not push. Run `zig fmt` on every touched Zig file before committing.
- **Hand checks are the user's.** Steps marked **HUMAN** stop the run: report what is ready and wait. Never mark one done on the user's behalf.

## Review Focus

1. **A completion arriving after the game it belongs to is gone.** For example, eject during a save, or a load answered after a disc change. Expected: the view model drops it, using the same identity guards the runner had (`self.session === session`). *Test: Task 6, `aSaveAnsweredAfterEjectIsIgnored`.*
2. **A completion answered inside `ps1_session_free`, on the main thread.** Expected: no deadlock; the closure runs once, later, on the main actor. *Test: Task 4, `aRequestAnsweredDuringFreeDoesNotDeadlock`.*
3. **`ps1_session_new` refuses** (no Metal, bad BIOS, refused resume state). Expected: the disc bytes are not released by the session (header rule 2). The Swift box that retains them is freed exactly once, the view model shows the same error the Swift path showed, and no session is left. *Tests: Task 4, `aRefusedNewReleasesTheDiscBoxOnce`; Task 6, `aRefusedResumeShowsTheStateError`.*
4. **SwiftUI rebuilds the representable.** This happens on a fullscreen toggle, on a HUD change, and when the library window and the game's own window swap between games. Expected: the representable hands back the SAME `SessionHostView`, so the layer the session installed survives, and a new session gets a new view. *Test: Task 5, `theRepresentableReturnsTheModelsHostView`; hand check in Task 7.*
5. **A disc swap superseded by a second swap.** Expected: the first swap is answered `PS1_ERR_SUPERSEDED`, and its bytes' `release` runs exactly once. *Test: Task 4, `aSupersededSwapReleasesItsBytesOnce`.*

---

## File structure

```
ps1-session/src/lockstep_abi.zig        NEW (Task 1, deleted Task 8)  ps1_lockstep_replay: a fixture through ps1-metal
ps1-capi/include/ps1_lockstep.h         NEW (Task 1, deleted Task 8)
ps1-macos/Tests/PS1Tests/LockstepTests.swift  NEW (Task 1, deleted Task 8)
docs/superpowers/notes/2026-10-22-engine-into-zig-measurements.md  NEW (Tasks 2, 3, 7)  every number this plan takes

ps1-macos/Sources/PS1/GameSession.swift NEW  the protocol + Session (the C ABI wrapper) + SessionError
ps1-macos/Sources/PS1/SessionHostView.swift NEW  the NSView the session draws into; size and backing scale out
ps1-macos/Sources/PS1/MetalDisplayView.swift  MOD  only ToolbarBand's constants and the representable remain
ps1-macos/Sources/PS1/EmulatorViewModel.swift MOD  runner/core/ring/audio -> session + hostView
ps1-macos/Sources/PS1/GameWindowView.swift    MOD  DisplayIdentity and .id() deleted; occlusion forwarded
ps1-macos/Sources/PS1/Ps1Core.swift            MOD  Ps1Error gains -21..-25; frame-stream API deleted (Task 8)
ps1-macos/Tests/PS1Tests/ScriptedSession.swift NEW  the test conformer
ps1-macos/Tests/PS1Tests/SessionTests.swift    NEW  the real wrapper, headless

ps1-macos/Shaders/ -> ps1-metal/shaders/       MOVE (Task 9)
ps1-capi/include/ps1.h, ps1-capi/src/root.zig, ps1-capi/src/capi_test.zig  MOD (Task 8) the frame-stream export goes
build.zig                                      MOD  lockstep header (Task 1), nm check (Task 8), shader paths (Task 9)
CLAUDE.md, .claude/skills/ps1-gpu-metal/SKILL.md, .claude/skills/ps1-macos-app/SKILL.md, ps1-macos/test.sh  MOD (Task 10)
```

## The port table (the Swift tests Plans A and B left)

| Swift test | Fate | Where | Task |
|---|---|---|---|
| Everything Plans A/B list as ported (LineExpander, DrawEnv, FixtureBridge, DisplayShader, MetalVram, HazardTracker, MetalMover, MetalRasterizer, MetalScale, TextureFilter, TrueColour, PgxpParity, InterpolationExactness, StreamQueue, Speculation, LiveRenderer, LiveRendererScale, DisplayRender, DisplayScale, Letterbox, GpuBench, AudioRing, AudioGain, TempoControl, RewindAudio, MemoryCardFlushPolicy, ResumeThumbnail, EmulatorRunnerSaveState, EmulatorRunnerLoadState, EmulatorRunnerMemoryCard) | **delete** | already in `ps1-metal/tests`, `ps1-session/tests` | 8 |
| `ScreenshotTests`, `RunaheadTests`, `SpeedSettingTests`, `EmulatorRunnerResetTests`: the cases Plan B ported | **delete those cases**; the setting/naming cases stay | — | 8 |
| `MemoryCardStoreTests` | the write/load cases (ported to `cards_test.zig`) **delete**; any case on the directory or names `MemoryCardStore` still offers **stays** | — | 8 |
| `EmulatorRunnerResetTests.theViewModelsResetGoesThroughTheRunner` | **port** as `theViewModelsResetGoesThroughTheSession` (ScriptedSession records `requestReset`) | `SaveStateViewModelTests.swift` | 6 |
| `EmulatorViewModelStageTests` (26), `HudInputTests` (17), `HudSurfacesTests` (18), `SaveStateViewModelTests` (17), `PlayingForTests` (7) | **re-point**: `installRunnerForTesting(runner, …)` becomes `installSessionForTesting(ScriptedSession(), …)`. `runner.serviceSaveRequest()` / `serviceLoadRequests()` become `session.answerSave(…)` / `answerLoad(…)`, and `.runnerStopped` becomes `.sessionStopped`. Same names, same assertions | same files | 6 |
| `PadStateTests.aPressIsDrainedOnce` | **delete** (ported to `Controls` by Plan B) | — | 8 |
| `PadStateTests.aFreshCoreReportsADigitalPadAtRest` | **stays**: a machine-handle test, and `Ps1Core` keeps that surface | — | — |
| `TextureFilterSettingTests`: `aFreshRasterizerCarriesNearest`, `aFreshRasterizerCarriesANearestSpriteFilter`, `theTextureFilterReachesTheRasterizerWithoutARebuild`, `theSpriteFilterReachesTheRasterizerWithoutARebuild` | **port** to Zig (below); the setting cases stay | `ps1-metal/tests/rasterizer_test.zig`, `frame_renderer_test.zig` | 8 |
| `DitherModeTests.aFreshRasterizerCarriesTheShippedMode` | **port** to Zig | `rasterizer_test.zig` | 8 |
| `FpsCounterTests` | **stays**; only a doc comment names the runner, so fix the comment | — | 6 |
| `BiosIdentityTests` | **stays**; replace `FixtureFile.repoURL` with a local repo-root helper | — | 8 |
| `Ps1CoreTests`, `DiscImageTests`, `SidecarTests`, `ResumeOfferTests` | **stay**: they test the machine handle, which the spec keeps for "anything that inspects a machine without running it". Only a case that calls a method Task 8 deletes changes; there should be none | — | 8 |
| Helpers `MetalFixtureHarness`, `MetalScaleHarness`, `DisplayPassHarness`, `Ps1GpuVertexTestSupport` | **delete**; every user is deleted | — | 8 |
| `LockstepTests` (Task 1) | **delete**: temporary by spec | — | 8 |

---

### Task 1: The lockstep: the Zig renderer against the Swift renderer

The spec's "checked against the Swift renderer before the Swift renderer is deleted". This adds a TEMPORARY C entry that replays a `.p1fx` through `ps1-metal`, and a Swift test that requires byte-identical VRAM and sidecar against `MetalRasterizer` over the corpus.

**Files:**
- Create: `ps1-session/src/lockstep_abi.zig` (referenced from `abi.zig`'s top-level `comptime` block, so `lib.zig` already pulls it in on arm64 macOS), `ps1-capi/include/ps1_lockstep.h`, `ps1-macos/Tests/PS1Tests/LockstepTests.swift`
- Modify: `ps1-capi/include/module.modulemap` (`header "ps1_lockstep.h"`), `build.zig`'s `nm` check (also require `_ps1_lockstep_replay`)

**Interfaces:**
- Produces (C):

```c
/* TEMPORARY (Plan C Task 8 deletes it). Replays frames [0, up_to) of the .p1fx
 * `bytes` through ps1-metal at cfg->scale, synchronously, on the caller's thread.
 * vram_hashes[i] / sidecar_hashes[i]: FNV-1a 64 of the SCALED VRAM readback
 * (u16 little-endian) / the scaled sidecar readback (RGBA8) after frame i.
 * vram_out (scale^2*1024*512 u16) and sidecar_out (x4 bytes): the state after
 * the last replayed frame; either may be NULL. Returns the number of frames
 * replayed, or a negative code (PS1_ERR_NO_METAL, PS1_ERR_OOM, PS1_ERR_BAD_CUE
 * for bytes that do not parse as a fixture). */
typedef struct { int32_t scale; int32_t dither; int32_t texture_filter;
                 int32_t sprite_filter; uint8_t depth_buffer; } Ps1LockstepConfig;
int32_t ps1_lockstep_replay(const uint8_t* bytes, size_t len, const Ps1LockstepConfig* cfg,
                            uint32_t up_to, uint64_t* vram_hashes, uint64_t* sidecar_hashes,
                            uint16_t* vram_out, uint8_t* sidecar_out);
```

- Consumes: `fixture.parse` / `Parsed.frameStream(i)` (`ps1-golden/src/fixture.zig`, re-exported as `ps1_metal.fixture`); `Metal.open`, `Rig.create(alloc, m, .{ .scale, .depth_buffer, .set })`, `rig.frame(payload, records)`, `MetalVram.readback` / `readbackSidecar` (`ps1-metal/src/metal_context.zig`, `metal_vram.zig`); `fixture.fnv1a`. Mirror `ps1-metal/tests/scale_harness.zig`'s `replayTo`/`capture`: each frame runs inside an `objc.Pool`, and the rasterizer's `dither_mode`, `texture_filter` and `sprite_filter` are set before the first frame.

- [ ] **Step 1: Write the Swift test** `LockstepTests.swift`. It runs over every fixture `FixtureFile.url(named:)` resolves (the committed memory mover plus everything in `zig-out/fixtures/`), at scales `[1, 3, 8]`, in three configs:
  - `shipped`: `.trueColor`, `.nearest`, `.nearest`, depth off.
  - `native-bilinear`: `.native`, `.bilinear`, `.bilinear`, depth off.
  - `depth`: `shipped` with the depth buffer on. Run this config only for fixtures whose name ends in `-pgxp`.

  For each run:

```swift
// Swift side: MetalScaleHarness's per-frame loop (MetalVram(scale:depthBuffer:), MetalRasterizer,
// begin/apply/end), recording Fnv1a.hash(vram: vram.readback()) and Fnv1a over
// vram.readbackSidecar() after every frame; keep the final readback() and readbackSidecar().
// Zig side: ps1_lockstep_replay with the same config and up_to = fixture.frameCount.
#expect(zigFrames == fixture.frameCount)
#expect(zigVramHashes == swiftVramHashes)         // every frame, not just the last
#expect(zigSidecarHashes == swiftSidecarHashes)
#expect(zigVram == swiftVram)                     // full bytes, final frame
#expect(zigSidecar == swiftSidecar)
```

  On a mismatch, record the first differing frame and the first differing pixel `(x, y)` in the failure message. The test skips (with a printed reason, not a pass) when no Metal device exists. It also prints `lockstep: N fixtures, M runs` so a run over the committed fixture alone is visible as such.

- [ ] **Step 2: Run it; it fails to compile** (`ps1_lockstep_replay` undeclared).
  Run: `zig build capi-lib && zig build metallib && pkill -x Substation; ps1-macos/test.sh -only-testing:PS1Tests/LockstepTests`. The `-only-testing` argument passes through to xcodebuild; see memory `reference-swift-testing-only-testing-filter` for the syntax free functions need.

- [ ] **Step 3: Implement `ps1_lockstep_replay`** in `lockstep_abi.zig`, as a `pub export fn`. Do not gate it on `builtin.is_test`: the Swift test host links the shipped `libps1core.a`. Allocate with `std.heap.c_allocator`. Map `Ps1LockstepConfig`'s ints through `prim_instance.zig`'s `DitherMode`/`TextureFilter` (their values equal `PS1_DITHER_*`/`PS1_FILTER_*`), and refuse an out-of-range value with `PS1_ERR_BAD_SLOT`.

- [ ] **Step 4: Run.** First `zig build fixtures -Doptimize=ReleaseFast`, so the whole corpus is present. Then `zig build capi-lib && pkill -x Substation; ps1-macos/test.sh -only-testing:PS1Tests/LockstepTests`. Expected: PASS, and the printed run count covers every generated fixture. A mismatch is a port bug: **stop and report it** with the frame and pixel. Do not change either renderer to make it pass without the user's say-so.

- [ ] **Step 5: Commit** `test(metal): the temporary lockstep of the Zig renderer against the Swift one`

---

### Task 2: The renderer benchmark, Zig against Swift

**Files:**
- Create: `docs/superpowers/notes/2026-10-22-engine-into-zig-measurements.md`

- [ ] **Step 1: Build both benchmarks.** Run `zig build -Doptimize=ReleaseFast` (it installs `zig-out/bin/ps1-bench-gpu`), then `zig build macos -Doptimize=ReleaseFast` (the Release app, which `GpuBench` runs in).
- [ ] **Step 2: Run them interleaved, five rounds**, after letting the machine settle (no `trace-golden` run just before). The fixtures are `crash-bandicoot-warped,silent-hill-usa,tr1-usa-v1-1`, at scales `1,4,6,8`. Pin the settings explicitly on BOTH sides to the app's shipped defaults, `trueColor`/`nearest`/`nearest`:
  - Swift: `defaults write <bundle id> ditherMode/textureFilter/spriteTextureFilter`. Use the keys `DitherSetting`, `TextureFilterSetting` and `SpriteFilterSetting` read, and restore the user's values afterwards. Then `PS1_GPU_BENCH=<fixtures> PS1_GPU_BENCH_SCALES=1,4,6,8 zig-out/Substation.app/Contents/MacOS/Substation`.
  - Zig: `zig-out/bin/ps1-bench-gpu <fixtures> --scales=1,4,6,8 --dither=true-color --filter=nearest --sprite-filter=nearest`.

  Alternate Swift, Zig, Swift, Zig… for five rounds each.
- [ ] **Step 3: Write the table** into the notes file: per fixture × scale, the best of five GPU ms, CPU ms and fps for each side, and the ratio. Pass criteria:
  - **GPU ms:** within 5% of Swift's (same shaders).
  - **CPU ms:** Zig ≤ Swift × 1.03 (the 3% is run-to-run noise; say so in the notes).

  A row outside either bound is **reported to the user, not fixed in this task.**
- [ ] **Step 4: Commit** `docs: the renderer benchmark, Zig against Swift`

---

### Task 3: HUMAN: the app's baseline, before the switch

The spec's in-app targets are relative to today's app, so today's numbers must be taken before Task 6 replaces it.

- [ ] **Step 1: Prepare.** Run `zig build macos -Doptimize=ReleaseFast`. Write the checklist below into the notes file under "Baseline (Swift path)", with blank cells.
- [ ] **Step 2: HUMAN.** The user launches the Release app and plays Spyro, then reads the HUD fps for:
  - fast-forward at 1x, 4x and 6x internal resolution;
  - the process CPU share at 1x, normal speed, over 30 s of play, from `top -pid $(pgrep -x Substation) -l 31 -s 1 -stats cpu`, averaging the last 30 samples.

  Stop here and ask the user for the numbers.
- [ ] **Step 3: Record** them in the notes file and **commit** `docs: the app's performance before the switch`

---

### Task 4: `GameSession`: the Swift face of the session

**Files:**
- Create: `ps1-macos/Sources/PS1/GameSession.swift`, `ps1-macos/Tests/PS1Tests/SessionTests.swift`, `ps1-macos/Tests/PS1Tests/ScriptedSession.swift`
- Modify: `ps1-macos/Sources/PS1/Ps1Core.swift` (`Ps1Error` gains `.audio`, `.noMetal`, `.sessionStopped`, `.busy` and `.superseded`, for -21…-25)

**Interfaces:**
- Consumes: `ps1_session.h` (Plan B Task 15).
- Produces:

```swift
struct DiscBytes { var bin: Data; var cue: Data?; var sbi: Data?; var ppf: Data? }
struct SessionConfig {
    var bios: Data; var disc: DiscBytes?; var resumeState: Data?
    var cardDirectory: URL; var view: NSView?
    var cpuEngine: CpuEngine; var fastBoot: Bool
}   // band_* are filled from ToolbarBand inside Session.init
struct PgxpSettings { /* the 10 Bools + tolerance: Float? (nil = none) */ }

@MainActor protocol GameSession: AnyObject {
    func start() throws(Ps1Error)
    // setters
    func setButtons(_ mask: UInt16); func setSticks(_ s: Sticks); func pressAnalog()
    func setSpeed(_ speed: Int); func setPaused(_ paused: Bool); func setRewinding(_ on: Bool)
    func setPgxp(_ p: PgxpSettings); func setCpuEngine(_ e: CpuEngine)
    func setRewindBudget(bytes: Int); func setRunahead(frames: Int); func setGain(_ g: Float)
    func setDither(_ m: DitherMode); func setTextureFilter(_ f: TextureFilter); func setSpriteFilter(_ f: TextureFilter)
    func setScale(_ s: Int); func setSize(points: CGSize, backingScale: CGFloat)
    func setOccluded(_ o: Bool); func setBandShown(_ b: Bool)
    // requests: each completion runs exactly once, on the main actor
    func requestSave(_ done: @escaping @MainActor (Result<ResumeSnapshot, Ps1Error>) -> Void)
    func requestLoad(_ state: Data, _ done: @escaping @MainActor (Result<Data, Ps1Error>) -> Void) // success: undo bytes
    func requestReset(_ done: @escaping @MainActor (Ps1Error?) -> Void)
    func requestSwap(_ disc: DiscBytes, _ done: @escaping @MainActor (Ps1Error?) -> Void)
    func requestScreenshot(_ done: @escaping @MainActor (Data?) -> Void)               // PNG
    // counters
    var framesProduced: UInt64 { get }; var padStatus: PadStatus { get }
    var cardWrites: UInt64 { get }; var rewindSeconds: Double { get }
    var newestDisplay: Ps1Display { get }
    func free()   // idempotent; main thread
}
final class Session: GameSession { init(_ cfg: SessionConfig) throws(Ps1Error) }
```

  `ResumeSnapshot` is the view model's existing `{state, thumbnail}` type. Its thumbnail is the session's PNG, decoded with `NSImage(data:)` where the type holds an image. Each completion is boxed with `Unmanaged.passRetained` and released in its C trampoline, which hops to the main actor with `DispatchQueue.main.async`. The `Data` behind the `bin` pointer is kept alive by a retained box passed as `release_ctx`, released in the release callback. `Session.free()` calls `ps1_session_free` once and nils the pointer. `deinit` calls `free()`.
- Produces (tests): `ScriptedSession: GameSession`. It records every setter in `calls: [String]` (e.g. `"setSpeed(4)"`), holds pending completions, and offers `answerSave(_:)`, `answerLoad(_:)`, `answerReset(_:)`, `answerSwap(_:)`, `answerScreenshot(_:)` and settable counters. Its `free()` answers every pending request `.sessionStopped`, as the real one does.

- [ ] **Step 1: Write the failing tests** in `SessionTests.swift`. Each uses a real `Session` with a zeroed 512 KB BIOS, `view: nil`, and a temp card directory, and is never started. `start()` needs an audio device, and the session's own tests already cover that path.

```swift
@Test func aSessionBuildsAndFreesHeadless()                 // init succeeds; free() twice is fine
@Test func aRequestWaitingAtFreeIsAnsweredSessionStopped()  // requestSave before free -> exactly one .failure(.sessionStopped)
@Test func aRequestAnsweredDuringFreeDoesNotDeadlock() async // requestLoad, then free() ON THE MAIN ACTOR; the completion
                                                            // arrives within 1 s, exactly once
@Test func aSupersededSwapReleasesItsBytesOnce()            // two requestSwap: first answered .superseded; a weak ref to the
                                                            // first DiscBytes box is nil after the answer; second answered at free
@Test func aRefusedNewReleasesTheDiscBoxOnce()              // a 3-byte BIOS -> throws .badBIOSSize; the disc box is gone
                                                            // (weak ref nil) and release was NOT called by the session
@Test func everyNewErrorCodeMaps()                          // Ps1Error.from(-21...-25) == [.audio,.noMetal,.sessionStopped,.busy,.superseded]
```

- [ ] **Step 2: Run them; they fail to compile.** Run: `pkill -x Substation; ps1-macos/test.sh -only-testing:PS1Tests/SessionTests`.
- [ ] **Step 3: Implement** `GameSession.swift` and the `Ps1Error` cases. Write `ScriptedSession.swift` too; Task 6 is its first user.
- [ ] **Step 4: Run.** `SessionTests` pass, and the whole `ps1-macos/test.sh` stays green (the app is untouched).
- [ ] **Step 5: Commit** `feat(macos): GameSession, the Swift face of the session ABI`

---

### Task 5: `SessionHostView`: the view the session draws into

**Files:**
- Create: `ps1-macos/Sources/PS1/SessionHostView.swift`
- Modify: `ps1-macos/Sources/PS1/MetalDisplayView.swift`. Add `GameDisplayView: NSViewRepresentable`; leave the old `MetalDisplayView` in place until Task 8.
- Test: `ps1-macos/Tests/PS1Tests/GameWindowTests.swift` (or a new `SessionHostViewTests.swift`)

**Interfaces:**
- Produces:
  - `final class SessionHostView: NSView`, with `var onGeometry: ((CGSize, CGFloat) -> Void)?`, called from `setFrameSize` and `viewDidChangeBackingProperties` with `bounds.size` and `window?.backingScaleFactor ?? 1`.
  - `struct GameDisplayView: NSViewRepresentable { let host: SessionHostView }`. Its `makeNSView` returns `host`; `updateNSView` does nothing.

  The session installs the layer, so this view never sets `wantsLayer` or its layer itself.

- [ ] **Step 1: Write the failing tests:**

```swift
@MainActor @Test func theHostViewReportsItsSizeAndBackingScale()  // setFrameSize(640x480) -> onGeometry((640,480), scale)
@MainActor @Test func theRepresentableReturnsTheModelsHostView()  // two makeNSView calls (through a
    // NSHostingView rebuilt twice) return the identical SessionHostView instance
```

- [ ] **Step 2: Run; they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** They pass, and `ps1-macos/test.sh` stays green.
- [ ] **Step 5: Commit** `feat(macos): the host view a session draws into`

---

### Task 6: Switch the app to the session

One commit, by the spec's rule: a half-way point would need the two-handle ABI this work exists to delete. Afterwards nothing in `Sources/` calls `EmulatorRunner`, `AudioOutput`, `LiveRenderer`, `StreamQueue`, `MetalDisplayView`'s coordinator, `ResumeThumbnail`, `Screenshot.encode/bytes/png` or `GpuBench`. They still compile until Task 8 deletes them.

**Files:**
- Modify: `EmulatorViewModel.swift`, `GameWindowView.swift`, `ContentView.swift` (if it names the runner), `PS1App/AppDelegate.swift` (drop the `GpuBench.runFromEnvironment` call; its replacement is `ps1-bench-gpu`), `RunaheadSetting.swift` (`StreamQueue.maxSpeculativeFrames` becomes a constant there, with the same value), `Screenshot.swift` (`write` takes PNG `Data`)
- Modify: the tests in the port table's "re-point" rows, plus `EmulatorRunnerResetTests.theViewModelsResetGoesThroughTheRunner`, moved and renamed

**Interfaces:**
- Consumes: `GameSession`/`Session`/`ScriptedSession` (Task 4); `SessionHostView`/`GameDisplayView` (Task 5).
- Produces:
  - In `EmulatorViewModel`: `private(set) var session: (any GameSession)?`, `private(set) var hostView: SessionHostView?` and `installSessionForTesting(_ s: any GameSession, resumeKey: String?)`, which replaces `installRunnerForTesting`.
  - `WindowRouting`'s `.game(...)` keys on `ObjectIdentifier(session)`.

The mapping, one runner touch point to one session call. The research for this plan located each one in `EmulatorViewModel.swift`. Line numbers are as of f717058.

| Today | After |
|---|---|
| `load(disc:)` (~:1385-1456): `Ps1Core()`, `loadBIOS`, `loadDisc`, `loadState(resume)`, `AudioRing`, `EmulatorRunner`, `AudioOutput`, then teardown, `cards.load` + `loadMemcard`, the settings, `runner.start()`, `audio.start()` | build `SessionHostView`. Then `Session(SessionConfig(bios:, disc:, resumeState:, cardDirectory: cards.directory, view: hostView, cpuEngine:, fastBoot:))`. Then `teardownRunningMachine()` (frees the old session, which writes its cards; header rule 3). Then every setter, then `start()`. A thrown `.state*` takes the existing resume-refusal path (:1398-1407); `.noMetal`/`.audio` take the existing load-failure path (:1484) |
| `isPaused` get/set → `runner.isPaused` | a stored `Bool` on the view model; the setter also calls `session?.setPaused` |
| `applyPgxp` (11 setters, :684-705) | one `setPgxp(PgxpSettings)`. The preset fold-in stays exactly where it is (transparent depth still skips the preset) |
| `applySpeed`: `runner.setSpeed` + `audio.setSpeed` | `setSpeed` |
| `audio.setGain` | `setGain` |
| `setCpuEngine`, `setRunahead`, `setRewindBudget`, `setRewinding`, `rewindSeconds` | the same-named session calls |
| `changeDisc`: `requestDiscSwap` (fire-and-forget) | `requestSwap`. `.superseded` is silent; any other error shows the existing disc-error notice |
| `requestReset` | `requestReset`, completion ignored |
| `requestScreenshot` then `Screenshot.write` | `requestScreenshot { png in Screenshot.write(png, …) }`; a nil PNG shows nothing, as today's nil image did |
| `requestSaveState` / `requestLoadState`, guarded by `self.runner === runner` | `requestSave` / `requestLoad`, guarded by `self.session === session`. `.sessionStopped` takes today's `.runnerStopped` path |
| `teardownRunningMachine`: `audio.stop()`, `runner.stop()` | `session?.free(); session = nil; hostView = nil` |
| FPS sampler `totalFramesProduced`; pad poll `padStatus`, `memoryCardWrites`, `rewindSeconds` | `framesProduced`, `padStatus`, `cardWrites`, `rewindSeconds` |
| `outputSize` from `runner.newestDisplay` | `session?.newestDisplay` |
| `setButtons`, `setSticks`, `pressAnalogButton` | the session calls |
| `MemoryCardFlushPolicy.settleDelay` (:1912) | a `private static let` with the same value, with a comment naming `ps1-session/src/cards.zig`'s policy as the one that writes |
| `GameWindowView`: `MetalDisplayView(runner:scale:depthBuffer:…)` and `.id(DisplayIdentity…)` | `GameDisplayView(host: model.hostView!)` with no `.id`. Scale, dither, the two filters and the band go through `.onChange` → `setScale`/`setDither`/`setTextureFilter`/`setSpriteFilter`/`setBandShown`, and the view model also applies them once at load. The existing `didChangeOcclusionState` observer (:263) → `setOccluded(!window.occlusionState.contains(.visible))`. `hostView.onGeometry` → `setSize` |

The depth buffer has no setter of its own: it is `PgxpSettings.depthBuffer`, and the session rebuilds the renderer on a change (Plan B Task 12).

- [ ] **Step 1: Re-point the tests first.** In the port table's "re-point" rows, `installRunnerForTesting(runner…)` becomes `installSessionForTesting(ScriptedSession()…)`. `runner.service*()` becomes `session.answer*(…)` with the bytes the old core produced replaced by fixed test bytes (`Data([1,2,3])`), because these tests are about the view model, not the machine. Delete each `makeRunner`/`makeMachine` helper. Add:

```swift
@MainActor @Test func theViewModelsResetGoesThroughTheSession()   // model.reset() -> session.calls.contains("requestReset")
@MainActor @Test func aSaveAnsweredAfterEjectIsIgnored()          // requestSave, eject, answerSave(.success) -> no resume written,
                                                                  // no notice, no crash (the identity guard)
@MainActor @Test func aRefusedResumeShowsTheStateError()          // a SessionFactory seam that throws .stateVersion ->
                                                                  // the same resume-failure UI the Swift path showed
@MainActor @Test func everySettingIsAppliedBeforeStart()          // ScriptedSession's calls: every setter precedes "start()"
```

  For the last two, `load(disc:)` builds its session through `var makeSession: (SessionConfig) throws(Ps1Error) -> any GameSession = Session.init`, a stored property tests can replace. That is the only new seam.
- [ ] **Step 2: Run; the re-pointed tests fail to compile.**
- [ ] **Step 3: Implement the switch** per the table.
- [ ] **Step 4: Verify:**
  - `zig build capi-lib && zig build metallib && pkill -x Substation; ps1-macos/test.sh` passes.
  - `zig build macos` builds.
  - Grep: `rg -n "EmulatorRunner|AudioOutput|LiveRenderer|StreamQueue|ResumeThumbnail|GpuBench|MetalDisplayView\(" ps1-macos/Sources` lists only the files Task 8 deletes (and `MetalDisplayView.swift` itself).
  - Smoke: launch the Debug app, play Crash for ten seconds, quit. The picture, the sound and the input all work. Report anything else as a failure.
- [ ] **Step 5: Commit** `feat(macos): the app runs on the Zig session`

---

### Task 7: HUMAN: hand checks and the app's performance after the switch

The spec lists every check below. **Nothing in Task 8 starts until the user has signed this off.**

- [ ] **Step 1: Prepare.** Run `zig build macos -Doptimize=ReleaseFast`. Write the checklist into the notes file under "Hand checks (session path)":
  - Crash.
  - Silent Hill (24-bit FMV and fog).
  - FF7's menu (the lost-upload repair).
  - FF8's movie uploads.
  - Runahead on and off.
  - Rewind held to the end of the history.
  - A scale change and a depth-buffer toggle mid-game.
  - A disc swap.
  - Save, load and reset.
  - The window hidden and shown again.
  - A live resize (watch for the stretched-frame artifact; if it appears, the remedy is the spec's `IOSurface` follow-up, not part of this plan).
  - A move to a 120 Hz screen.
  - Screenshots at 1x and 4x.
  - The resume thumbnail.
  - Quitting during a card write.
  - One `PS1_LIVE_DIFF=1` run at `.native` with its checked/skipped tally read.
  - Library ↔ own-window launches back to back, and a fullscreen toggle (Review Focus 4).

  Add the performance rows: Spyro fast-forward at 1x (must exceed the Task 3 figure and ~240 fps), at 4x and 6x (must not fall below Task 3's), and process CPU at 1x normal speed (must not rise).
- [ ] **Step 2: HUMAN.** Stop and hand the checklist to the user. Wait.
- [ ] **Step 3: Record** the results. If anything fails, it becomes a fix task, inserted here, on the session path. The Swift code still exists for comparison until this passes.
- [ ] **Step 4: Commit** `docs: the hand checks and performance on the session path`

---

### Task 8: Delete the Swift engine, its tests and the frame-stream export

**Files:**
- Delete (Sources/PS1): `EmulatorRunner`, `AudioOutput`, `AudioRing`, `AudioGain` (if it is its own file), `TempoControl`, `RewindAudio`, `StreamQueue`, `StreamBackpressure` (if separate), `LiveRenderer`, `MetalVram`, `MetalRasterizer`, `PrimBuilder`, `PrimEncoders`, `HazardTracker`, `SpeculativeRegion`, `SpeculativeCore` (if separate), `Runahead`, `ShadowVram`, `DrawEnv`, `VramTransfer`, `LineExpander`, `Fnv1a`, `FixtureFile`, `VramDump`, `VramImage`, `GpuBench`, `ResumeThumbnail`, `MemoryCardFlushPolicy`, `Shaders.swift`. In `MetalDisplayView.swift`, delete everything except `ToolbarBand`'s three constants and `GameDisplayView`, and rename the file `GameDisplayView.swift`. In `Screenshot.swift`, delete `encode`/`bytes`/`png`. In `MemoryCardStore.swift`, delete the read/write; keep the directory and whatever names still have a caller.
- Delete (Tests): every row the port table marks delete, the four helpers, and `LockstepTests.swift`.
- Delete: `ps1-session/src/lockstep_abi.zig` and `ps1-capi/include/ps1_lockstep.h`, plus their module-map line and `nm` requirement.
- Modify: `ps1-macos/Sources/CPs1/include/module.modulemap`. Drop `prim_instance_shim.h` and `metallib.h` (no Swift reader is left). Delete both headers. **Keep linking `libps1shaders.a`**: `ps1-metal/src/shaders.zig` references `ps1_metallib_ptr`.
- Modify: `ps1-macos/Sources/PS1/Ps1Core.swift`. Delete `takeFrameStream`, the `Ps1GpuStream` typealias, and every instance method left with no caller (expected: `runFrame`, `readAudio`, `copyVRAM`, `copyDepth`, the rewind and snapshot calls). Keep whatever `Ps1CoreTests`, `DiscImageTests`, `SidecarTests`, `ResumeOfferTests`, `PadStateTests` and the statics still use.
- Modify: `ps1-capi/include/ps1.h` and `ps1-capi/src/root.zig`. Delete `ps1_take_frame_stream`, `Ps1GpuStream`, `Ps1GpuCommand`, `Ps1GpuVertex` (if separate), the `Ps1GpuCommandKind` enum, `PS1_GPU_KIND_COUNT` and the `PS1_GPU_FLAG_*` record constants, together with any `comptime` layout assertion that exists only for them. `PrimInstance.h`'s comments that cite `PS1_GPU_FLAG_*` now cite `gpu/command.zig`'s flag names instead.
- Modify: `ps1-capi/src/capi_test.zig`. The two drain tests (`take_frame_stream hands out…`, `…RESETS the recorder…`) are renamed `the recorder hands out the frame's records and payload` and `taking a frame RESETS the recorder, so a second take in one frame is empty`. They call `h.cpu.bus.gpu.sink.rec.takeFrame()`, the same call `HandleMachine.takeFrameStream` makes, with the same assertions. `build.zig`'s comment at ~:284 is updated to match.
- Modify: `build.zig`'s `nm` check now requires `_ps1_session_new` and requires `_ps1_take_frame_stream` to be ABSENT. `ps1-metal/src/stream_queue.zig:28`'s comment names the recorder, not the export.
- Modify: `ps1-macos/Tests/PS1Tests/BiosIdentityTests.swift` gets a local `repoURL` (`#filePath`, up four directories).
- Test (new Zig ports): `ps1-metal/tests/rasterizer_test.zig` and `frame_renderer_test.zig`.

- [ ] **Step 1: Write the Zig ports** of the four gap tests:

```zig
test "aFreshRasterizerCarriesTheShippedMode" { // dither_mode == .true_color, texture_filter == .nearest, sprite_filter == .nearest
}
test "theFiltersReachTheRasterizerWithoutARebuild" { // FrameRenderer: set texture and sprite filter -> the live rasterizer's
    // fields change, and its MetalVram pointer is the one it had before
}
```

  If `frame_renderer_test.zig` already pins the second test, cite it in the commit's task report instead of duplicating it.
- [ ] **Step 2: Run** `zig build test-metal -Doptimize=ReleaseFast -Dmetal-filter=Fresh` and `-Dmetal-filter=WithoutARebuild`. Expected: PASS. These pin existing behaviour; a failure means the Zig defaults differ from the Swift ones, and that is a finding to report.
- [ ] **Step 3: Delete and modify** per the file list. Then:

```bash
rg -n "EmulatorRunner|AudioOutput|AudioRing|StreamQueue|LiveRenderer|MetalVram|MetalRasterizer|FixtureFile|Fnv1a|ShadowVram|GpuBench|take_frame_stream|Ps1GpuStream|Ps1GpuCommand|lockstep" ps1-macos ps1-capi ps1-session ps1-metal build.zig
```

  The only expected hits are comments that describe history, and each of those is rewritten to describe the present.
- [ ] **Step 4: Verify:**
  - `zig build test` passes; read the Build Summary and exit code, not the `failed command:` lines (memory `project-engine-into-zig-plan-b-done`).
  - `zig build test-metal -Doptimize=ReleaseFast` passes.
  - `zig build capi-lib` passes (the `nm` check included).
  - `zig build trace-golden -Doptimize=ReleaseFast -- verify` passes, and so does `-- stream-verify`.
  - `zig build macos` builds.
  - `pkill -x Substation; ps1-macos/test.sh` passes. Record its test count.
  - Smoke: Crash plays for ten seconds in the Debug app.
- [ ] **Step 5: Commit** `refactor(macos): delete the Swift renderer, runner, audio and fixture bridge`

---

### Task 9: The shaders move to `ps1-metal/`

Nothing in Swift reads a shader file any more. `ps1-metal` is their only consumer.

**Files:**
- Move: `ps1-macos/Shaders/` → `ps1-metal/shaders/` (`DisplayShader.metal`, `Rasterizer.metal`, `PrimInstance.h`, `Ps1Color.h`, `embed.zig`), with `git mv` and the content unchanged.
- Modify: `build.zig`'s `metallib` step inputs, and every `@embedFile`/include path that names the old directory (`rg -n "ps1-macos/Shaders|Shaders/" build.zig ps1-metal ps1-bench ps1-macos`). The headers stay metallib cache inputs (CLAUDE.md, Harnesses: "Shader headers are metallib cache inputs").
- Modify: `ps1-macos/PS1.xcodeproj/project.pbxproj`, removing any reference to the old folder, and `ps1-macos/test.sh`'s `libps1shaders.a` comment ("the display tests load the real shader"), which is no longer true. The check stays, because the app links the archive.

- [ ] **Step 1: Move and re-point.**
- [ ] **Step 2: Prove the cache still sees the headers.** Touch `ps1-metal/shaders/Ps1Color.h`, run `zig build metallib`, and confirm the step re-ran (the archive's mtime changes).
- [ ] **Step 3: Verify.** `zig build metallib`, `zig build test-metal -Doptimize=ReleaseFast` and `zig build macos` all succeed, and Crash plays for ten seconds.
- [ ] **Step 4: Commit** `refactor(metal): the shaders live with the renderer`

---

### Task 10: The docs

**Files:**
- Modify: `CLAUDE.md`:
  - The intro's frontend list, which gains the session.
  - The Quick-commands rows:
    - `zig build test`: the binary count, counted from `build.zig`'s list.
    - `capi-lib`: it now holds the session and `ps1-metal`.
    - `metallib`: the new path.
    - `ps1-macos/test.sh`: the count from Task 8 and the time.
    - New rows for `zig build test-metal` and `ps1-bench-gpu`.
    - `zig build`: it now compiles the shaders and installs `ps1-bench-gpu` where the Metal toolchain runs.
  - The repository layout, which gains `ps1-metal/` and `ps1-session/`.
  - Every rule that names a deleted Swift file or `ps1_take_frame_stream`. The drain rule becomes "`Recorder.takeFrame` is a DRAIN, not a peek: exactly once per `runFrame`".
  - Under macOS app, a new rule: **the session owns the machine; Swift holds a `GameSession` and a `SessionHostView`, never a `Ps1*` of a running game.**
- Modify: `.claude/skills/ps1-gpu-metal/SKILL.md`. Re-point every line that names `MetalRasterizer`, `LiveRenderer`, `StreamQueue`, `claimConsumer`, `MTKView`, `MetalScaleTests.swift`, `MetalMoverTests.swift`, `PrimEncoders.swift`, `DitherMode.swift`'s uniform, or `ps1_take_frame_stream` (the research for this plan found 36 sites: the description, ~:126-155, :202-378, :542, :704, :789-800, :912, :1105-1142, :1186, :1263, :1292, :1420-1432). The ~:794-800 rule "switched by a FILE, not an environment variable" is now false: `PS1_DUMP_SCALED`/`PS1_SCALE_TIMING` are env vars of `test-metal`. The benchmark section names `ps1-bench-gpu`, and gets Task 2's table as the new baseline.
- Modify: `.claude/skills/ps1-macos-app/SKILL.md`. Re-point:
  - the description;
  - ~:14 ("hands frames to a Metal view through a triple buffer");
  - the `AudioOutput` lines (~:326-507);
  - the `EmulatorRunner` lines (~:516-1122);
  - ~:1170-1225 (resync, runahead and rewind now live in `ps1-session`; name its files);
  - ~:632.

  Add a short "The session" section: `GameSession`/`ScriptedSession`, `SessionHostView` returned by every `makeNSView`, completions hop with `async`, and `makeSession` as the one test seam.
- Modify: `ps1-macos/test.sh`'s header comment and its fixture warning (no Swift test reads `zig-out/fixtures` any more: delete the warning if `rg -n "fixtures" ps1-macos/Tests` is empty).
- Memory: update `project-metal-renderer-into-zig.md` and write `project-engine-into-zig-plan-c-done.md` (its index line goes in `MEMORY.md`).

- [ ] **Step 1: Edit** per the list. Every number written is one measured in this plan (the counts from Task 8, the table from Task 2), never a guess.
- [ ] **Step 2: Check:** `rg -n "EmulatorRunner|MetalRasterizer|LiveRenderer|StreamQueue|claimConsumer|MTKView|take_frame_stream|PS1_GPU_BENCH|FixtureFile" CLAUDE.md .claude/skills` returns only lines that describe the history on purpose.
- [ ] **Step 3: Commit** `docs: the engine lives in Zig`

---

## Self-review notes

- **Spec coverage.**
  - Step 8: the lockstep is Task 1, at 1x, 3x and 8x, VRAM and sidecar; the benchmark is Task 2.
  - Step 9: the switch is Task 6, the hand checks are Task 7, and the deletion is Task 8. Task 8 covers the renderer, runner, audio, queue, runahead and fixture bridge with their tests, and `ps1_take_frame_stream` with its C types.
  - Step 10: Task 10.
  - The spec's in-app performance targets need a before figure, which is Task 3, and an after figure, in Task 7.
  - `capi_test` keeps its drain coverage through the recorder directly (Task 8).
  - The spec's "Shaders' library loader" and the shader sources leave Swift in Tasks 8-9.
  - The spec's "re-pointed" Swift files: `MetalDisplayView` → `GameDisplayView` + `SessionHostView` (Tasks 5, 8), `Ps1Core` shrinks (Task 8), `EmulatorViewModel` (Task 6), `MemoryCardStore` keeps the directory (Task 8), `Screenshot` keeps the naming (Tasks 6, 8).
- **Deliberate choices, each stated where it lands.**
  - The view model reaches the session through a protocol, so the 85 view-model tests keep their hand-serviced requests (Task 4).
  - The host view is created by the view model, not by SwiftUI, because `ns_view` is fixed at `ps1_session_new` (Task 5).
  - `Ps1Core` keeps its machine-handle surface for the tests that inspect a machine, which the spec allows (Task 8).
  - The shaders move (Task 9). The spec says "move unchanged", and their only reader is now `ps1-metal`.
- **Not in this plan:** the `IOSurface` layer (only if Task 7's live resize needs it), disc identification into Zig, and GPU-only VRAM, which are the spec's follow-ups.
