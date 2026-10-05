# Metal Renderer Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Metal rasterizer cheap enough per frame that Crash and Silent Hill run at full speed with headroom at 6x on an M1 Air (8x stretch), without changing one byte of VRAM output.

**Architecture:** A Release-build benchmark lands first and gates every later change. Three optimisations follow, each behind a temporary *reference switch* (`RasterizerReference`) that keeps the old behaviour selectable so a test can replay the corpus both ways in lockstep and require full scaled VRAM + sidecar equality, and so the benchmark can A/B both ways inside one binary. A final task deletes the switches and the old code.

**Tech Stack:** Swift 6 / Metal Shading Language (offline `metallib`), swift-testing, `xcodebuild`, Zig 0.17 (`ps1-golden` fixture capture).

**Spec:** `docs/superpowers/specs/2026-10-05-metal-renderer-performance-design.md`

**Deviations from the spec, decided while planning:** (1) the corpus drops the
Crash 1 gameplay window: no pad script reaching gameplay is known, and the
Crash Warped window (~890 draws/frame) already covers that workload. (2) Unit 3
shares fetches for COINCIDENT texels only, not per VRAM word/CLUT index: the
word-level sharing needs `ps1_fetch_texel` restructured, and is a follow-up if
Task 5's numbers justify it. (3) The lockstep comparisons check VRAM and the
sidecar, not the depth plane, which has no readback; depth-on runs still
compare colour, which a wrong depth test changes.

## Global Constraints

- **Byte-exact:** VRAM (`.r16Uint`) must stay bit-identical to the software rasterizer. Gate 1, Gate 2, `theCorpusRendersIdenticalVramInTrueColourAndOff`, `theCorpusRendersIdenticalVramUnderEverySetting` and the full Swift suite must pass after every task.
- **No layout change:** `static_assert(sizeof(Ps1PrimInstance) == 4 * 54)` and `static_assert(sizeof(Ps1RasterUniforms) == 16)` stay. No record field changes.
- **Every rule in `.claude/skills/ps1-gpu-metal/SKILL.md` holds.** Read it before Task 2. In particular: coverage is decided in the FRAGMENT shader, never by Metal's rasterizer; blending is integer arithmetic; records stay native.
- **Measure, don't assume:** an optimisation lands only if the benchmark shows it faster (best of 5, A/B interleaved, same session). Otherwise revert it and record the measured reason in the skill doc.
- **Commits:** title line only, no body, no trailer (user rule). Commit directly on `master`. **Never `git push`.**
- **Before any Swift test run:** `pkill -x Substation` (a running app fails the suite in a way that looks real).
- **Swift suite:** `ps1-macos/test.sh` (needs `zig build capi-lib metallib` already built). Single tests: `xcodebuild -project ps1-macos/PS1.xcodeproj -scheme PS1 -configuration Debug -destination "platform=macOS,arch=$(uname -m)" SYMROOT=.build/xcode -parallel-testing-enabled NO "-only-testing:PS1Tests/<testName>()" test` from the repo root. Free functions need the `()`; a filter matching nothing reports "passed" with 0 tests, so check the executed count.
- **Release app:** `zig build macos -Doptimize=ReleaseFast` → `zig-out/Substation.app`.

## Review Focus

1. **A triangle much larger than its drawing-area clip** (sky/floor polygons extending far off-screen): the hull must not generate more fragments than the clipped box did. Expected: hull chosen only when its area is smaller than the box's. Pinned in Task 2 by `aClippedGiantTriangleKeepsTheBox`.
2. **Needle triangles** (one very acute angle): the miter offset explodes. Expected: fall back to the box, never a huge or NaN hull. Pinned in Task 2 by `aNeedleTriangleMatchesTheBoxAtEveryScale`.
3. **Non-power-of-two scales (3, 5, 6, 7)**: `/ s` and `% s` are not shifts there. Expected: hull and variants byte-identical at 3 and 6. Pinned in Task 2 and Task 4 by including 3 and 6 in every equality ladder.
4. **The depth buffer ON**: a variant that skips the destination read must not be chosen, or depth reads 0. Expected: `readsDst` is forced true when `vram.depthPersists`. Pinned in Task 4 by running the variant equality with the depth buffer on.
5. **First use of a pipeline variant mid-game**: a synchronous compile on the render thread is a visible hitch. Expected: all variants are compiled when `MetalRasterizer` is created, and the benchmark reports the init time. Pinned in Task 4 by `everyVariantIsBuiltAtInit`.

---

## File map

| File | Responsibility | Tasks |
|---|---|---|
| `ps1-macos/Sources/PS1/GpuBench.swift` (new) | The `PS1_GPU_BENCH` replay benchmark: runs fixtures at scales, prints GPU/CPU/throughput | 1 |
| `ps1-macos/Sources/PS1App/AppDelegate.swift` | Starts the benchmark instead of the UI when the env var is set | 1 |
| `ps1-macos/Sources/PS1/MetalRasterizer.swift` | `onCommit` hook (1); `RasterizerReference` + function-constant pipelines (2, 4, 5); variant runs (4) | 1, 2, 4, 5, 7 |
| `ps1-macos/Shaders/Rasterizer.metal` | hull in `ps1_vertex` (2); `ps1_prim_shade` refactor (3); specialised entries (4); bilinear (5) | 2-5, 7 |
| `ps1-macos/Tests/PS1Tests/MetalScaleHarness.swift` | `reference:` parameter; lockstep corpus comparison helper | 2 |
| `ps1-macos/Tests/PS1Tests/RasterizerReferenceTests.swift` (new) | Full-VRAM equality, reference vs optimised, over the corpus | 2, 4, 5 |
| `ps1-macos/Tests/PS1Tests/GpuBenchTests.swift` (new) | The benchmark's own test | 1 |
| `build.zig` | Adds the Crash Warped window to `zig build fixtures` | 1 |
| `.claude/skills/ps1-gpu-metal/SKILL.md` | Measured results per task | 1-7 |

`RasterizerReference` (Task 2) is the one mechanism every optimisation uses:

```swift
/// Selects the OLD implementation of an optimised path, for the lockstep
/// equality tests and the benchmark's A/B. Temporary: Task 7 deletes it.
struct RasterizerReference: OptionSet, Sendable {
    let rawValue: Int
    /// Every primitive as its bounding box (pre-Task 2 geometry).
    static let boxGeometry = RasterizerReference(rawValue: 1 << 0)
    /// The single branching `ps1_prim_fragment` (pre-Task 4).
    static let uberShader = RasterizerReference(rawValue: 1 << 1)
    /// The four-fetch `ps1_bilinear` (pre-Task 5).
    static let referenceBilinear = RasterizerReference(rawValue: 1 << 2)
}
```

Function constant indices (shader side), reserved here so tasks do not collide:

| index | name | type | used by |
|---|---|---|---|
| 0 | `PS1_FC_BOX_ONLY` | bool | `ps1_vertex` (Task 2) |
| 1 | `PS1_FC_CLASS` | int | specialised fragment (Task 4) |
| 2 | `PS1_FC_TRUE_COLOR` | bool | specialised fragment (Task 4) |
| 3 | `PS1_FC_REF_BILINEAR` | bool | `ps1_bilinear` callers (Task 5) |

---

### Task 1: The benchmark

**Files:**
- Create: `ps1-macos/Sources/PS1/GpuBench.swift`
- Create: `ps1-macos/Tests/PS1Tests/GpuBenchTests.swift`
- Modify: `ps1-macos/Sources/PS1/MetalRasterizer.swift` (add `onCommit`, call it in `endFrame` before `cmd.commit()`)
- Modify: `ps1-macos/Sources/PS1App/AppDelegate.swift` (add `applicationDidFinishLaunching`)
- Modify: `build.zig` (Crash Warped capture in the `fixtures` chain)
- Modify: `.claude/skills/ps1-gpu-metal/SKILL.md` (baseline table)

**Interfaces:**
- Produces: `MetalRasterizer.onCommit: ((MTLCommandBuffer) -> Void)?`; `GpuBench.run(fixtures:scales:configs:repeats:) -> [GpuBench.Result]`; `GpuBench.Result { fixture: String, scale: Int, config: String, gpuMs: Double, cpuMs: Double, fps: Double, frames: Int }`; `GpuBench.Config { name: String, reference: RasterizerReference }` (Task 2 adds `RasterizerReference`; until then `Config` carries only `name`, see Step 3).

- [ ] **Step 1: Write the failing test**

`ps1-macos/Tests/PS1Tests/GpuBenchTests.swift`:

```swift
import Testing
import Metal
@testable import PS1

/// The benchmark is a measuring instrument: the one property worth pinning is
/// that it actually replays frames and reports a positive GPU time for each
/// scale, so a silently empty run (a missing fixture, a hook never called)
/// cannot read as "infinitely fast".
@Test func theBenchmarkReplaysEveryFrameAndTimesTheGpu() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let results = try GpuBench.run(fixtures: ["synthetic-primitives"], scales: [1, 3],
                                   configs: [GpuBench.Config(name: "current")],
                                   repeats: 1)
    #expect(results.count == 2)
    for r in results {
        #expect(r.frames > 0)
        #expect(r.gpuMs > 0)
        #expect(r.cpuMs > 0)
        #expect(r.fps > 0)
    }
    #expect(results.map(\.scale) == [1, 3])
}
```

- [ ] **Step 2: Run it to verify it fails**

Run (repo root): `pkill -x Substation; xcodebuild -project ps1-macos/PS1.xcodeproj -scheme PS1 -configuration Debug -destination "platform=macOS,arch=$(uname -m)" SYMROOT=.build/xcode -parallel-testing-enabled NO "-only-testing:PS1Tests/theBenchmarkReplaysEveryFrameAndTimesTheGpu()" test 2>&1 | grep -E "error:|✘|✔|TEST"`
Expected: build error `cannot find 'GpuBench' in scope`.

- [ ] **Step 3: Add the commit hook to `MetalRasterizer`**

Below `var synchronous = true`:

```swift
    /// Called with each frame's command buffer just before it is committed.
    /// The benchmark's only way in: it adds a completed handler that reads
    /// the GPU's own timestamps. Nil on every other path.
    var onCommit: ((MTLCommandBuffer) -> Void)?
```

In `endFrame()`, immediately before `cmd.commit()`:

```swift
        onCommit?(cmd)
```

- [ ] **Step 4: Write `GpuBench.swift`**

```swift
import Foundation
import Metal
import Synchronization

/// A class around the counter, because an `Atomic` is non-copyable and cannot
/// be captured by the command buffer's escaping completion handler.
private final class GpuNanos: @unchecked Sendable {
    let value = Atomic<UInt64>(0)
}

/// `PS1_GPU_BENCH`: replays `.p1fx` fixtures at several internal resolutions
/// and prints what each frame costs. Read by the APP (like `PS1_LIVE_DIFF`)
/// because the test bundle only builds in Debug, and the Debug Swift encode
/// cost is not what a player pays.
///
/// Two passes per (fixture, scale, config):
/// - SYNCHRONOUS: each frame waited on, so the summed `gpuEndTime -
///   gpuStartTime` is a per-frame cost. Overlapping buffers would otherwise
///   sum past wall time (measured live: 1.5-1.8 s of GPU per second).
/// - PIPELINED: `synchronous = false`, timed wall-clock over the whole run,
///   which is the frame rate a player can actually get.
///
/// Settings come from the player's own `UserDefaults`, so the numbers are
/// for the configuration actually played.
enum GpuBench {
    struct Config {
        let name: String
    }

    struct Result {
        let fixture: String
        let scale: Int
        let config: String
        let gpuMs: Double
        let cpuMs: Double
        let fps: Double
        let frames: Int

        var line: String {
            // Padded by hand: `%-24@` does not pad an object argument.
            "[gpu-bench] " + fixture.padding(toLength: 24, withPad: " ", startingAt: 0)
                + " \(scale)x " + config.padding(toLength: 10, withPad: " ", startingAt: 0)
                + String(format: " gpu %6.2f ms  cpu %6.2f ms  %6.1f fps  (%d frames)",
                         gpuMs, cpuMs, fps, frames)
        }
    }

    /// Best of `repeats` per row, by GPU ms. Configs are interleaved inside
    /// each repeat (A, B, A, B), never run as blocks: thermal drift on a
    /// fanless machine would otherwise land on one config.
    static func run(fixtures: [String], scales: [Int], configs: [Config],
                    repeats: Int) throws -> [Result] {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return [] }
        var best: [String: Result] = [:]
        var order: [String] = []
        for fixture in fixtures {
            let file = try FixtureFile(contentsOf: FixtureFile.url(named: fixture))
            for scale in scales {
                for _ in 0..<repeats {
                    for config in configs {
                        let r = try withExtendedLifetime(file) {
                            try measure(file, fixture: fixture, scale: scale, config: config,
                                        device: device, queue: queue)
                        }
                        let key = "\(fixture)|\(scale)|\(config.name)"
                        if best[key] == nil { order.append(key) }
                        if best[key].map({ r.gpuMs < $0.gpuMs }) ?? true { best[key] = r }
                    }
                }
            }
        }
        return order.compactMap { best[$0] }
    }

    private static func makeRasterizer(_ device: MTLDevice, _ queue: MTLCommandQueue,
                                       scale: Int, config: Config) throws -> MetalRasterizer? {
        guard let vram = MetalVram(device: device, queue: queue, scale: scale) else { return nil }
        let r = try MetalRasterizer(vram: vram)
        r.ditherMode = DitherSetting().mode
        r.textureFilter = TextureFilterSetting().filter
        r.spriteFilter = SpriteFilterSetting().filter
        return r
    }

    private static func replay(_ r: MetalRasterizer, _ file: FixtureFile) {
        for i in 0..<file.frames.count {
            r.beginFrame(payload: file.payload(for: i))
            for cmd in file.records(for: i) { r.apply(cmd) }
            r.endFrame()
        }
    }

    private static func measure(_ file: FixtureFile, fixture: String, scale: Int, config: Config,
                                device: MTLDevice, queue: MTLCommandQueue) throws -> Result {
        // Synchronous pass: per-frame GPU and CPU cost.
        guard let sync = try makeRasterizer(device, queue, scale: scale, config: config) else {
            return Result(fixture: fixture, scale: scale, config: config.name,
                          gpuMs: 0, cpuMs: 0, fps: 0, frames: 0)
        }
        sync.synchronous = true
        let gpuNs = GpuNanos()
        sync.onCommit = { cmd in
            cmd.addCompletedHandler { cb in
                let ns = max(0, (cb.gpuEndTime - cb.gpuStartTime) * 1e9)
                gpuNs.value.wrappingAdd(UInt64(ns), ordering: .relaxed)
            }
        }
        replay(sync, file)                       // warm-up: pipelines, caches
        gpuNs.value.store(0, ordering: .relaxed)
        var cpuNs: UInt64 = 0
        for i in 0..<file.frames.count {
            let t0 = DispatchTime.now().uptimeNanoseconds
            sync.beginFrame(payload: file.payload(for: i))
            for cmd in file.records(for: i) { sync.apply(cmd) }
            // CPU encode only: endFrame's synchronous wait is GPU time, and
            // is excluded by stopping the clock before it.
            cpuNs += DispatchTime.now().uptimeNanoseconds - t0
            sync.endFrame()
        }
        let frames = file.frames.count

        // Pipelined pass: the throughput a player gets.
        guard let piped = try makeRasterizer(device, queue, scale: scale, config: config) else {
            return Result(fixture: fixture, scale: scale, config: config.name,
                          gpuMs: 0, cpuMs: 0, fps: 0, frames: 0)
        }
        piped.synchronous = false
        replay(piped, file)                      // warm-up
        let t0 = DispatchTime.now().uptimeNanoseconds
        replay(piped, file)
        let fence = queue.makeCommandBuffer()!
        fence.commit()
        fence.waitUntilCompleted()
        let wallNs = DispatchTime.now().uptimeNanoseconds - t0

        return Result(fixture: fixture, scale: scale, config: config.name,
                      gpuMs: Double(gpuNs.value.load(ordering: .relaxed)) / 1e6 / Double(frames),
                      cpuMs: Double(cpuNs) / 1e6 / Double(frames),
                      fps: Double(frames) / (Double(wallNs) / 1e9),
                      frames: frames)
    }

    /// The app-launch entry: `PS1_GPU_BENCH=crash-bandicoot-warped,silent-hill-usa`
    /// and optionally `PS1_GPU_BENCH_SCALES=4,6,8` (default 1,4,6,8).
    /// Prints one line per row and exits the process.
    static func runFromEnvironment(_ env: [String: String]) -> Bool {
        guard let list = env["PS1_GPU_BENCH"], !list.isEmpty else { return false }
        let fixtures = list.split(separator: ",").map(String.init)
        let scales = (env["PS1_GPU_BENCH_SCALES"] ?? "1,4,6,8")
            .split(separator: ",").compactMap { Int($0) }
        Thread.detachNewThread {
            do {
                let results = try run(fixtures: fixtures, scales: scales,
                                      configs: configs(env), repeats: 5)
                for r in results { print(r.line) }
                exit(0)
            } catch {
                print("[gpu-bench] failed: \(error)")
                exit(1)
            }
        }
        return true
    }

    /// The configs to A/B. Task 2 onward extends this from
    /// `PS1_GPU_BENCH_AB`; until then there is only the current renderer.
    static func configs(_ env: [String: String]) -> [Config] {
        [Config(name: "current")]
    }
}
```

- [ ] **Step 5: Wire it into the app**

In `AppDelegate`, add:

```swift
    /// `PS1_GPU_BENCH` turns the launch into a benchmark run: see `GpuBench`.
    /// The window still opens (SwiftUI owns the scene), and the process exits
    /// when the run finishes.
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = GpuBench.runFromEnvironment(ProcessInfo.processInfo.environment)
    }
```

- [ ] **Step 6: Run the test to verify it passes**

Same command as Step 2. Expected: `✔ Test theBenchmarkReplaysEveryFrameAndTimesTheGpu() passed`, 1 test executed.

- [ ] **Step 7: Add the Crash Warped window to `zig build fixtures`**

In `build.zig`, after the `fixtures_run_pgxp` block and before `const fixtures_step`, insert:

```zig
    // The benchmark's Crash window (Metal renderer performance spec): ~890
    // draws per frame at 500M-700M instructions, one render pass per frame,
    // no VRAM->VRAM copies. A per-filter window, so its own run.
    const fixtures_run_crash = b.addRunArtifact(golden_exe);
    fixtures_run_crash.step.dependOn(&prev_fixture_run.step);
    fixtures_run_crash.addArgs(&.{
        "stream-capture",            "--filter=crash-bandicoot-warped",
        "--capture-from=500000000", "--frames=100",
        "--instructions=700000000",
    });
    prev_fixture_run = fixtures_run_crash;
```

Run: `zig build fixtures -Doptimize=ReleaseFast 2>&1 | grep -E "crash-bandicoot-warped|error"`
Expected: `crash-bandicoot-warped 100 frames ... WRITTEN`.

- [ ] **Step 8: Take the baseline**

```bash
zig build macos -Doptimize=ReleaseFast
pkill -x Substation
PS1_GPU_BENCH=crash-bandicoot-warped,silent-hill-usa,tr1-usa-v1-1 \
  zig-out/Substation.app/Contents/MacOS/Substation 2>/dev/null | grep gpu-bench
```

Expected: 12 lines (3 fixtures x 4 scales). Copy them verbatim into a new section at the end of `.claude/skills/ps1-gpu-metal/SKILL.md`:

```markdown
## Renderer performance (2026-10-05 spec)

Benchmark: `PS1_GPU_BENCH=<fixtures>` on the Release app (`GpuBench`), best
of 5, the player's own settings. GPU ms is per frame from command-buffer
timestamps with frames serialised; fps is pipelined throughput. Compare rows
within one table only.

Baseline (<machine>, <settings: dither / filter / sprite filter>):

<the 12 lines>
```

- [ ] **Step 9: Run the whole suite and commit**

Run: `pkill -x Substation; ps1-macos/test.sh 2>&1 | grep -E "✘|Test run with|TEST (SUCC|FAIL)"`
Expected: `** TEST SUCCEEDED **`.

```bash
git add ps1-macos/Sources/PS1/GpuBench.swift ps1-macos/Tests/PS1Tests/GpuBenchTests.swift \
  ps1-macos/Sources/PS1/MetalRasterizer.swift ps1-macos/Sources/PS1App/AppDelegate.swift \
  build.zig .claude/skills/ps1-gpu-metal/SKILL.md
git commit -m "feat(macos): PS1_GPU_BENCH replays fixtures in the Release app and times the GPU"
```

---

### Task 2: Triangle hull instead of the bounding box

**Files:**
- Modify: `ps1-macos/Shaders/Rasterizer.metal` (`ps1_vertex`, new `ps1_hull`)
- Modify: `ps1-macos/Sources/PS1/MetalRasterizer.swift` (`RasterizerReference`, `init(vram:reference:)`, vertex function with constants)
- Modify: `ps1-macos/Sources/PS1/GpuBench.swift` (`Config.reference`, `PS1_GPU_BENCH_AB`)
- Modify: `ps1-macos/Tests/PS1Tests/MetalScaleHarness.swift` (`reference:` parameter on `frame`)
- Create: `ps1-macos/Tests/PS1Tests/RasterizerReferenceTests.swift`

**Interfaces:**
- Consumes: `GpuBench.Config`, `GpuBench.configs(_:)` from Task 1.
- Produces: `RasterizerReference` (exact definition in the File map); `MetalRasterizer.init(vram: MetalVram, reference: RasterizerReference = [])`; `MetalScaleHarness.frame(..., reference: RasterizerReference = [], ...)`; `ReferenceLockstep.compare(_ fixture: String, scale: Int, dither: DitherMode, filter: TextureFilter, spriteFilter: TextureFilter, depthBuffer: Bool, reference: RasterizerReference, every: Int) throws -> String?` (nil = identical, else a message naming the first differing frame and buffer); `GpuBench.Config(name:reference:)`.

The geometry: a triangle's native vertex position is `(ox + qx/16, oy + qy/16)` with `ox = min(x0, x1, x2)`, exactly as `ps1_sample_point` reads it; scaled, it is that times `s`. Coverage samples the subtexel CORNER, which lies up to `s/16` scaled pixels left/up of `px`, while Metal generates a fragment when the pixel CENTRE `px + 0.5` is inside. So a hull must contain the triangle grown by `(0.5 + s/16) * sqrt(2)` scaled pixels: 0.80 at s=1, 1.41 at s=8. Growing every edge by `margin = s` (one native pixel) covers that at every scale with slack for float rounding. The hull is a miter offset; it is used only when its area is smaller than the clipped box's, which also handles needle angles (miter blow-up) and triangles clipped by the drawing area. Coverage and the in-shader clip test still decide every painted pixel, so the hull only changes which fragments are generated.

- [ ] **Step 1: Write the failing tests**

Add the harness parameter first, so the tests compile against it. In `MetalScaleHarness.frame`, add `reference: RasterizerReference = [],` after `wantSidecar: Bool = false,` and change `let r = try MetalRasterizer(vram: vram)` in that function to `let r = try MetalRasterizer(vram: vram, reference: reference)`.

Create `ps1-macos/Tests/PS1Tests/RasterizerReferenceTests.swift`:

```swift
import Testing
import Metal
import Foundation
import CPs1
@testable import PS1

/// Replays a fixture through two rasterizers in lockstep (one with
/// `reference` set, one optimised) and compares the FULL scaled VRAM and
/// sidecar, not `readbackNative()`: the corner-only view is the scaled
/// path's known blind spot, and an optimisation that drops interior
/// subtexels passes it.
enum ReferenceLockstep {
    static func compare(_ fixture: String, scale: Int, dither: DitherMode = .trueColor,
                        filter: TextureFilter = .bilinear, spriteFilter: TextureFilter = .bilinear,
                        depthBuffer: Bool = false, reference: RasterizerReference,
                        every: Int = 1) throws -> String? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let va = MetalVram(device: device, queue: queue, scale: scale, depthBuffer: depthBuffer),
              let vb = MetalVram(device: device, queue: queue, scale: scale, depthBuffer: depthBuffer)
        else { return nil }
        let a = try MetalRasterizer(vram: va, reference: reference)
        let b = try MetalRasterizer(vram: vb)
        for r in [a, b] {
            r.ditherMode = dither
            r.textureFilter = filter
            r.spriteFilter = spriteFilter
        }
        let file = try FixtureFile(contentsOf: FixtureFile.url(named: fixture))
        return withExtendedLifetime(file) {
            let last = file.frames.count - 1
            for i in 0...last {
                for r in [a, b] {
                    r.beginFrame(payload: file.payload(for: i))
                    for cmd in file.records(for: i) { r.apply(cmd) }
                    r.endFrame()
                }
                guard i % every == 0 || i == last else { continue }
                if va.readback() != vb.readback() {
                    return "\(fixture) @\(scale)x frame \(i): VRAM differs"
                }
                if va.readbackSidecar() != vb.readbackSidecar() {
                    return "\(fixture) @\(scale)x frame \(i): sidecar differs"
                }
            }
            return nil
        }
    }

    /// Every fixture present, committed or generated.
    static var corpus: [String] {
        ["synthetic-primitives", "synthetic-movers", "pl-render-polygon", "pl-render-rectangle",
         "pl-render-line", "pl-render-texture-polygon", "croc-legend-of-the-gobbos",
         "silent-hill-usa", "tr1-usa-v1-1", "tr1-usa-v1-1-pgxp", "crash-bandicoot-warped"]
            .filter(generatedFixtureExists)
    }

    /// The scale ladder: 3 and 6 because `/ s` and `% s` are shifts at every
    /// power of two, so a bug there is invisible at 2, 4 and 8.
    static let scales = [1, 2, 3, 4, 6]
}

@Test func theTriangleHullPaintsExactlyWhatTheBoxPainted() throws {
    for fixture in ReferenceLockstep.corpus {
        for scale in ReferenceLockstep.scales {
            let msg = try ReferenceLockstep.compare(fixture, scale: scale,
                                                   reference: .boxGeometry)
            #expect(msg == nil, Comment(rawValue: msg ?? ""))
        }
        // 8x on every 10th frame: 134 MB of sidecar per readback.
        let msg = try ReferenceLockstep.compare(fixture, scale: 8,
                                               reference: .boxGeometry, every: 10)
        #expect(msg == nil, Comment(rawValue: msg ?? ""))
        // Depth buffer on: a depth test decides colour, so a hull that
        // generated a different fragment set would show here too.
        let depth = try ReferenceLockstep.compare(fixture, scale: 4, depthBuffer: true,
                                                 reference: .boxGeometry)
        #expect(depth == nil, Comment(rawValue: "depth on: \(depth ?? "")"))
    }
}

/// Draws one flat triangle through both geometries and requires the full
/// scaled VRAM to match.
private func hullMatchesBox(_ v: [(Int16, Int16)], clip: (x0: UInt32, y0: UInt32, x1: UInt32, y1: UInt32)
                            = (0, 0, 1023, 511)) throws -> [Int] {
    var failing: [Int] = []
    func draw(_ r: MetalRasterizer) {
        var tl = Ps1GpuCommand()
        tl.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        tl.opcode = 0xE3
        tl.value = (clip.y0 << 10) | clip.x0
        r.apply(tl)
        var br = Ps1GpuCommand()
        br.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        br.opcode = 0xE4
        br.value = (clip.y1 << 10) | clip.x1
        r.apply(br)
        var tri = Ps1GpuCommand()
        tri.kind = UInt8(PS1_GPU_DRAW_TRIANGLE.rawValue)
        tri.value = 0x7FFF
        tri.v.0 = Ps1GpuVertex(x: v[0].0, y: v[0].1, u: 0, v: 0, _pad: 0, color: 0)
        tri.v.1 = Ps1GpuVertex(x: v[1].0, y: v[1].1, u: 0, v: 0, _pad: 0, color: 0)
        tri.v.2 = Ps1GpuVertex(x: v[2].0, y: v[2].1, u: 0, v: 0, _pad: 0, color: 0)
        r.apply(tri)
    }
    for scale in [1, 2, 3, 4, 6, 8] {
        guard let box = try MetalScaleHarness.frame(scale: scale, reference: .boxGeometry, draw),
              let hull = try MetalScaleHarness.frame(scale: scale, draw) else { return [] }
        if box.scaled != hull.scaled { failing.append(scale) }
    }
    return failing
}

@Test func aThinDiagonalTriangleMatchesTheBoxAtEveryScale() throws {
    // A 200 px diagonal two pixels thick: the box is ~100x the triangle.
    #expect(try hullMatchesBox([(100, 100), (300, 300), (102, 100)]) == [])
}

@Test func aNeedleTriangleMatchesTheBoxAtEveryScale() throws {
    // An apex angle of about 0.3 degrees: the miter would be ~400 margins long.
    #expect(try hullMatchesBox([(100, 200), (500, 201), (500, 199)]) == [])
}

@Test func aSubPixelSliverMatchesTheBoxAtEveryScale() throws {
    // Native twice-area 1: refused at every native sample point, painted off
    // the lattice. The hull must generate exactly the same subtexels.
    #expect(try hullMatchesBox([(100, 100), (101, 100), (100, 101)]) == [])
}

@Test func aClippedGiantTriangleKeepsTheBox() throws {
    // A triangle ~900 px across clipped to a 64x64 drawing area: the hull is
    // far larger than the clipped box, so the box must be kept. Output equality
    // is the correctness half; the box choice is the cost half, which the
    // benchmark measures.
    #expect(try hullMatchesBox([(0, 0), (900, 20), (20, 500)],
                               clip: (x0: 200, y0: 100, x1: 263, y1: 163)) == [])
}
```

Run: the Step 2 command of Task 1 with `-only-testing:PS1Tests/aThinDiagonalTriangleMatchesTheBoxAtEveryScale()`.
Expected: build error `cannot find type 'RasterizerReference' in scope`.

- [ ] **Step 2: Add `RasterizerReference` and the init parameter**

In `MetalRasterizer.swift`, above `final class MetalRasterizer`, add the `RasterizerReference` definition from the File map, verbatim.

Change the initializer signature to `init(vram: MetalVram, reference: RasterizerReference = []) throws`, store it as `let reference: RasterizerReference` (assign `self.reference = reference` first in `init`), and build the vertex function with the box-only constant. Replace `makePipeline` with:

```swift
    private static func makePipeline(device: MTLDevice, library: MTLLibrary,
                                      fragment: String,
                                      reference: RasterizerReference) throws -> MTLRenderPipelineState {
        let constants = MTLFunctionConstantValues()
        var boxOnly = reference.contains(.boxGeometry)
        constants.setConstantValue(&boxOnly, type: .bool, index: 0)
        let vs = try library.makeFunction(name: "ps1_vertex", constantValues: constants)
        guard let fs = library.makeFunction(name: fragment) else {
            throw Error.missingFunction(fragment)
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vs
        desc.fragmentFunction = fs
        desc.colorAttachments[0].pixelFormat = .r16Uint
        desc.colorAttachments[1].pixelFormat = .rgba8Uint
        desc.colorAttachments[2].pixelFormat = .r32Uint
        return try device.makeRenderPipelineState(descriptor: desc)
    }
```

Keep the existing doc comments above `makePipeline` and the colour-attachment comment block (move it above the `desc.colorAttachments[1]` line unchanged). Pass `reference: reference` at all five `makePipeline` call sites.

- [ ] **Step 3: Write the hull in `Rasterizer.metal`**

Function constants must be declared before use; add at the top of the file, after the `PS1_Q_*` defines:

```metal
/// Function constants. Indices are fixed in the performance plan's table.
constant bool PS1_FC_BOX_ONLY_RAW [[function_constant(0)]];
/// Undefined (no constant values supplied) means the hull is on.
constant bool PS1_FC_BOX_ONLY = is_function_constant_defined(PS1_FC_BOX_ONLY_RAW)
    && PS1_FC_BOX_ONLY_RAW;
```

Above `ps1_vertex`, add:

```metal
/// A triangle's conservative hull, in SCALED pixels: each edge pushed
/// outward by `margin` (one native pixel), as a miter offset. Returns false
/// when the box should be kept instead: a near-degenerate triangle (no
/// stable normals), a needle (the miter blows up), or a hull no smaller than
/// the clipped box (a triangle mostly outside its drawing area).
///
/// The geometry only decides which fragments are GENERATED. Coverage is
/// still `ps1_triangle_coverage` and the clip is still the in-shader test,
/// so a hull that is too generous costs time and never correctness. Why one
/// native pixel is enough: coverage samples the subtexel CORNER, up to s/16
/// scaled pixels up-left of px, and Metal generates a fragment when the
/// pixel CENTRE px + 0.5 is inside, so the hull must contain the triangle
/// grown by (0.5 + s/16) * sqrt(2): 0.80 at s = 1, 1.41 at s = 8, both under
/// `margin = s`.
struct Ps1Hull { float2 v[3]; };

inline bool ps1_hull(const device Ps1PrimInstance& p, float s, thread Ps1Hull& h) {
    float ox = float(min(p.x0, min(p.x1, p.x2)));
    float oy = float(min(p.y0, min(p.y1, p.y2)));
    float2 v[3] = {
        float2(ox + float(p.qx0) / 16.0f, oy + float(p.qy0) / 16.0f) * s,
        float2(ox + float(p.qx1) / 16.0f, oy + float(p.qy1) / 16.0f) * s,
        float2(ox + float(p.qx2) / 16.0f, oy + float(p.qy2) / 16.0f) * s,
    };
    float2 e01 = v[1] - v[0], e02 = v[2] - v[0];
    float area2 = e01.x * e02.y - e01.y * e02.x;
    // Under 1.5 native px^2 (native twice-area 3): the band the degeneracy
    // clause governs, and too small for stable normals. Cheap as a box anyway.
    if (fabs(area2) < 3.0f * s * s) return false;

    // Outward unit normal of each edge i (v[i] -> v[i+1]): perpendicular,
    // flipped to point away from the opposite vertex. Sign-convention free.
    float2 n[3];
    for (int i = 0; i < 3; i++) {
        float2 a = v[i], b = v[(i + 1) % 3], c = v[(i + 2) % 3];
        float2 d = normalize(b - a);
        float2 m = float2(d.y, -d.x);
        n[i] = dot(m, c - a) > 0.0f ? -m : m;
    }
    float margin = s;
    for (int i = 0; i < 3; i++) {
        // Vertex i joins edge i-1 (into it) and edge i (out of it).
        float2 na = n[(i + 2) % 3], nb = n[i];
        float k = 1.0f + dot(na, nb);
        // k -> 0 is a needle: the miter length margin * sqrt(2 / k) blows up.
        // Past 8 margins the box is the cheaper and safer shape.
        if (k < 2.0f / 64.0f) return false;
        h.v[i] = v[i] + margin * (na + nb) / k;
    }

    float2 f01 = h.v[1] - h.v[0], f02 = h.v[2] - h.v[0];
    float hull_area = 0.5f * fabs(f01.x * f02.y - f01.y * f02.x);
    float box_area = float(p.box_x1 + 1 - p.box_x0) * float(p.box_y1 + 1 - p.box_y0) * s * s;
    return hull_area < box_area;
}
```

In `ps1_vertex`, replace the two lines computing `float x` / `float y` with:

```metal
    float s = float(uni.scale);
    float x = (vid & 1u) ? float(p.box_x1 + 1) * s : float(p.box_x0) * s;
    float y = (vid & 2u) ? float(p.box_y1 + 1) * s : float(p.box_y0) * s;
    // Triangle kinds draw their hull when it is the smaller shape: vertices
    // 0, 1, 2 are the hull and vertex 3 repeats 2, so the strip's second
    // triangle (1, 2, 3) is degenerate and generates nothing. Every vertex
    // invocation reaches the same decision from the same instance.
    bool tri = p.kind == PS1_PRIM_FLAT_TRI || p.kind == PS1_PRIM_GOURAUD_TRI
            || p.kind == PS1_PRIM_TEXTURED_TRI;
    Ps1Hull h;
    if (!PS1_FC_BOX_ONLY && tri && ps1_hull(p, s, h)) {
        float2 q = h.v[min(vid, 2u)];
        x = q.x;
        y = q.y;
    }
```

(the existing `float s = float(uni.scale);` line is replaced by the first line above, not duplicated.)

Update the doc comment above `ps1_vertex`: replace "One bounding-box quad per primitive" with "One bounding-box quad per primitive, or for a triangle its hull (see `ps1_hull`)".

- [ ] **Step 4: Run the four hand-built tests**

Run each of `aThinDiagonalTriangleMatchesTheBoxAtEveryScale`, `aNeedleTriangleMatchesTheBoxAtEveryScale`, `aSubPixelSliverMatchesTheBoxAtEveryScale`, `aClippedGiantTriangleKeepsTheBox` with the Task 1 Step 2 command.
Expected: all pass. If one fails, the returned array names the failing scales; the margin or the area test is wrong, do NOT widen the test.

- [ ] **Step 5: Run the corpus lockstep test**

Run `theTriangleHullPaintsExactlyWhatTheBoxPainted` (needs `zig build fixtures -Doptimize=ReleaseFast` to have run). It takes minutes.
Expected: pass, with every fixture in `ReferenceLockstep.corpus` actually present: check `ls zig-out/fixtures/*.p1fx` lists `silent-hill-usa`, `tr1-usa-v1-1`, `crash-bandicoot-warped`.

- [ ] **Step 6: Let the benchmark A/B it**

In `GpuBench.swift`, give `Config` the reference and parse `PS1_GPU_BENCH_AB`:

```swift
    struct Config {
        let name: String
        var reference: RasterizerReference = []
    }
```

```swift
    /// `PS1_GPU_BENCH_AB=box` (or `uber`, `bilinear`, comma-separated) adds
    /// one config per name with that reference switch set, interleaved with
    /// the current renderer.
    static func configs(_ env: [String: String]) -> [Config] {
        var out = [Config(name: "current")]
        for name in (env["PS1_GPU_BENCH_AB"] ?? "").split(separator: ",") {
            switch name {
            case "box": out.append(Config(name: "box", reference: .boxGeometry))
            case "uber": out.append(Config(name: "uber", reference: .uberShader))
            case "bilinear": out.append(Config(name: "ref-bilin", reference: .referenceBilinear))
            default: break
            }
        }
        return out
    }
```

and in `makeRasterizer` use `MetalRasterizer(vram: vram, reference: config.reference)`. (`uber` and `bilinear` select switches that do nothing until Tasks 4 and 5 implement them; parsing them now keeps this function written once.)

Run:

```bash
zig build macos -Doptimize=ReleaseFast && pkill -x Substation
PS1_GPU_BENCH=crash-bandicoot-warped,silent-hill-usa,tr1-usa-v1-1 PS1_GPU_BENCH_AB=box \
  zig-out/Substation.app/Contents/MacOS/Substation 2>/dev/null | grep gpu-bench
```

Expected: `current` rows faster in GPU ms than `box` rows at 4x and above. Paste the table into the skill's performance section under "Task 2: triangle hull". If `current` is not faster, revert Steps 2-3 and record the numbers and the reason instead.

- [ ] **Step 7: Full suite and commit**

Run: `pkill -x Substation; ps1-macos/test.sh 2>&1 | grep -E "✘|Test run with|TEST (SUCC|FAIL)"`. Expected: `** TEST SUCCEEDED **`.

```bash
git add ps1-macos/Shaders/Rasterizer.metal ps1-macos/Sources/PS1/MetalRasterizer.swift \
  ps1-macos/Sources/PS1/GpuBench.swift ps1-macos/Tests/PS1Tests/MetalScaleHarness.swift \
  ps1-macos/Tests/PS1Tests/RasterizerReferenceTests.swift .claude/skills/ps1-gpu-metal/SKILL.md
git commit -m "perf(metal): a triangle draws its hull instead of its bounding box"
```

---

### Task 3: Extract `ps1_prim_shade` (pure refactor)

**Files:**
- Modify: `ps1-macos/Shaders/Rasterizer.metal` (`ps1_prim_fragment`)

**Interfaces:**
- Produces: `inline Ps1FragOut ps1_prim_shade(const device Ps1PrimInstance& p, int kind, bool true_colour, int px, int py, ushort dst, ushort4 dst_side, uint dst_depth, constant Ps1RasterUniforms& uni, texture2d<ushort, access::read> vram)`, the whole body of today's `ps1_prim_fragment`. Task 4's specialised entries call it with constant `kind`/`true_colour`.

No new test: this changes no behaviour, and Gate 1 + Gate 2 + the setting-equality tests already pin every output byte of this function.

- [ ] **Step 1: Move the body**

Cut everything inside `ps1_prim_fragment` after `const device Ps1PrimInstance& p = prims[in.iid];` and the `px`/`py` lines into the new function above it, with these exact substitutions inside the moved body:

- every `p.kind == PS1_PRIM_...` comparison in the `if / else if` chain becomes `kind == PS1_PRIM_...` (seven sites: `FLAT_TRI`, `GOURAUD_TRI`, `TEXTURED_TRI`, `RECT`, `LINE_PIXEL`, `SHADED_LINE_PIXEL`, `TEXTURED_RECT`). `ps1_is_sprite` keeps reading `p.kind`: it is the same value.
- the line `bool true_colour = (uni.dither_mode == PS1_DITHER_TRUE_COLOR);` is deleted (it is now the parameter); its comment block stays above the first use of `true_colour`.
- `int s = int(uni.scale);` stays inside the moved body.

`ps1_prim_fragment` becomes:

```metal
fragment Ps1FragOut ps1_prim_fragment(PrimVertexOut in [[stage_in]],
                                      ushort dst [[color(0)]],
                                      ushort4 dst_side [[color(1)]],
                                      uint dst_depth [[color(2)]],
                                      const device Ps1PrimInstance* prims [[buffer(0)]],
                                      constant Ps1RasterUniforms& uni [[buffer(2)]],
                                      texture2d<ushort, access::read> vram [[texture(0)]]) {
    const device Ps1PrimInstance& p = prims[in.iid];
    // [[position]] in a fragment shader is the pixel CENTRE (px+0.5, py+0.5),
    // so this truncation is exact.
    return ps1_prim_shade(p, p.kind, uni.dither_mode == PS1_DITHER_TRUE_COLOR,
                          int(in.position.x), int(in.position.y),
                          dst, dst_side, dst_depth, uni, vram);
}
```

`discard_fragment()` inside an inline function called from a fragment function is legal MSL; keep every `discard_fragment(); return ps1_discarded();` pair as it is.

- [ ] **Step 2: Build the shaders**

Run: `zig build metallib 2>&1 | grep -E "error|warning: unused"`. Expected: no output.

- [ ] **Step 3: Full suite**

Run: `pkill -x Substation; ps1-macos/test.sh 2>&1 | grep -E "✘|Test run with|TEST (SUCC|FAIL)"`. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add ps1-macos/Shaders/Rasterizer.metal
git commit -m "refactor(metal): the primitive fragment body becomes ps1_prim_shade"
```

---

### Task 4: Specialised pipelines

**Files:**
- Modify: `ps1-macos/Shaders/Rasterizer.metal` (two specialised entries)
- Modify: `ps1-macos/Sources/PS1/MetalRasterizer.swift` (`PrimVariant`, variant pipeline table, `DrawKind.prim(PrimVariant)`, `appendPrim`, encode loop)
- Modify: `ps1-macos/Sources/PS1/PrimEncoders.swift` (only if it constructs `.prim` draws; check with `grep -n "\.prim" ps1-macos/Sources/PS1/*.swift`)
- Modify: `ps1-macos/Tests/PS1Tests/RasterizerReferenceTests.swift`

**Interfaces:**
- Consumes: `ps1_prim_shade` (Task 3), `RasterizerReference.uberShader`, `ReferenceLockstep.compare` (Task 2).
- Produces: `struct PrimVariant: Hashable { let kind: Int32; let readsDst: Bool }`; `MetalRasterizer.variantPipelineCount: Int` (for the test).

Variant axes: primitive class (the seven kinds `ps1_prim_fragment` handles: 0-6), true colour (from `ditherMode`, per frame), and whether the destination is read. A draw reads the destination when it is semi-transparent (`PS1_PRIM_TRANSPARENT`), mask-checked (`PS1_PRIM_CHECK_MASK`), or the depth buffer is on (`vram.depthPersists`: the shader writes `dst_depth` back when it does not write depth). Without any of those, the body's outputs do not depend on `dst`, `dst_side` or `dst_depth`: verify that in Step 3 by reading every use of the three names in `ps1_prim_shade`. 7 x 2 x 2 = 28 pipelines, all built in `init`.

- [ ] **Step 1: Write the failing tests**

Append to `RasterizerReferenceTests.swift`:

```swift
@Test func theSpecialisedVariantsPaintExactlyWhatTheUberShaderPainted() throws {
    let settings: [(DitherMode, TextureFilter, TextureFilter)] = [
        (.trueColor, .bilinear, .bilinear), (.trueColor, .nearest, .nearest),
        (.native, .bilinear, .nearest), (.scaled, .nearest, .bilinear), (.off, .nearest, .nearest),
    ]
    for fixture in ReferenceLockstep.corpus {
        for (dither, filter, sprite) in settings {
            for scale in [1, 3, 4] {
                let msg = try ReferenceLockstep.compare(fixture, scale: scale, dither: dither,
                                                       filter: filter, spriteFilter: sprite,
                                                       reference: .uberShader)
                #expect(msg == nil, Comment(rawValue: "\(dither)/\(filter)/\(sprite): \(msg ?? "")"))
            }
        }
        // The depth plane forces the destination read on every variant.
        let msg = try ReferenceLockstep.compare(fixture, scale: 4, depthBuffer: true,
                                               reference: .uberShader)
        #expect(msg == nil, Comment(rawValue: "depth on: \(msg ?? "")"))
    }
}

@Test func everyVariantIsBuiltAtInit() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue, scale: 1) else { return }
    let t0 = DispatchTime.now().uptimeNanoseconds
    let r = try MetalRasterizer(vram: vram)
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    // 7 classes x true colour on/off x destination read on/off. Built up
    // front so the first use of a variant mid-game is not a compile hitch.
    #expect(r.variantPipelineCount == 28)
    print("[variants] MetalRasterizer.init built \(r.variantPipelineCount) pipelines in \(String(format: "%.0f", ms)) ms")
}
```

Run `everyVariantIsBuiltAtInit` (Task 1 Step 2 command). Expected: build error `value of type 'MetalRasterizer' has no member 'variantPipelineCount'`.

- [ ] **Step 2: Add the specialised entries to `Rasterizer.metal`**

After the `PS1_FC_BOX_ONLY` declarations at the top:

```metal
constant int  PS1_FC_CLASS      [[function_constant(1)]];
constant bool PS1_FC_TRUE_COLOR [[function_constant(2)]];
```

After `ps1_prim_fragment`:

```metal
/// One primitive class and colour mode, folded to constants so the compiler
/// drops every other path and allocates registers for this one alone.
/// Reads the destination through tile memory: for a semi-transparent,
/// mask-checked or depth-buffered draw.
fragment Ps1FragOut ps1_prim_fragment_dst(PrimVertexOut in [[stage_in]],
                                          ushort dst [[color(0)]],
                                          ushort4 dst_side [[color(1)]],
                                          uint dst_depth [[color(2)]],
                                          const device Ps1PrimInstance* prims [[buffer(0)]],
                                          constant Ps1RasterUniforms& uni [[buffer(2)]],
                                          texture2d<ushort, access::read> vram [[texture(0)]]) {
    return ps1_prim_shade(prims[in.iid], PS1_FC_CLASS, PS1_FC_TRUE_COLOR,
                          int(in.position.x), int(in.position.y),
                          dst, dst_side, dst_depth, uni, vram);
}

/// The same, for a draw whose output does not depend on the destination
/// (opaque, unmasked, depth buffer off). Declaring no framebuffer input lets
/// the GPU stop ordering this draw's fragments against earlier ones at the
/// same pixel. The zeros are never read: see `PrimVariant.readsDst`.
fragment Ps1FragOut ps1_prim_fragment_nodst(PrimVertexOut in [[stage_in]],
                                            const device Ps1PrimInstance* prims [[buffer(0)]],
                                            constant Ps1RasterUniforms& uni [[buffer(2)]],
                                            texture2d<ushort, access::read> vram [[texture(0)]]) {
    return ps1_prim_shade(prims[in.iid], PS1_FC_CLASS, PS1_FC_TRUE_COLOR,
                          int(in.position.x), int(in.position.y),
                          0, ushort4(0), 0u, uni, vram);
}
```

Run: `zig build metallib 2>&1 | grep error`. Expected: no output.

- [ ] **Step 3: Verify the no-destination claim**

Run: `grep -n "dst\b\|dst_side\|dst_depth" ps1-macos/Shaders/Rasterizer.metal` and read every hit inside `ps1_prim_shade`. Each must be inside a branch guarded by `transparent` (opcode bit, never true without `PS1_PRIM_TRANSPARENT`), `PS1_PRIM_CHECK_MASK`, `ps1_depth_passes` (only reads `dst_depth` under `PS1_PRIM_DEPTH_TEST`, which is never set while the depth buffer is off), or the final `depth_write ? iz : dst_depth` (writes into the `.memoryless` plane while the depth buffer is off, which nothing reads). If any other use exists, add that condition to `readsDst` in Step 4.

- [ ] **Step 4: Variants in `MetalRasterizer`**

Add above the class:

```swift
/// Which specialised pipeline a primitive draws with. True colour is NOT
/// here: it is one per-frame setting, so it selects the pipeline TABLE.
struct PrimVariant: Hashable {
    let kind: Int32
    /// Whether the draw's output depends on the destination pixel: blended,
    /// mask-checked, or the depth buffer on (the shader writes the stored
    /// depth back where it does not write its own).
    let readsDst: Bool
}
```

Change `enum DrawKind { case prim, fill, upload, copy, depthClear }` to:

```swift
    enum DrawKind: Hashable { case prim(PrimVariant), fill, upload, copy, depthClear }
```

Replace the `.prim:` entry of `pipelines` with nothing (`.prim` no longer has one fixed pipeline), add a stored property

```swift
    /// [trueColour][variant]: every specialised primitive pipeline, built in
    /// `init`. Under `.uberShader` both tables map every variant to the one
    /// branching `ps1_prim_fragment` pipeline.
    private let primPipelines: [Bool: [PrimVariant: MTLRenderPipelineState]]
    var variantPipelineCount: Int { primPipelines.values.reduce(0) { $0 + $1.count } }
```

and build it in `init` after `pipelines`:

```swift
        var tables: [Bool: [PrimVariant: MTLRenderPipelineState]] = [:]
        let uber = reference.contains(.uberShader)
            ? try Self.makePipeline(device: device, library: library,
                                    fragment: "ps1_prim_fragment", reference: reference)
            : nil
        for trueColour in [false, true] {
            var table: [PrimVariant: MTLRenderPipelineState] = [:]
            for kind in Int32(PS1_PRIM_FLAT_TRI)...Int32(PS1_PRIM_SHADED_LINE_PIXEL) {
                for readsDst in [false, true] {
                    let v = PrimVariant(kind: kind, readsDst: readsDst)
                    table[v] = try uber ?? Self.makePipeline(
                        device: device, library: library,
                        fragment: readsDst ? "ps1_prim_fragment_dst" : "ps1_prim_fragment_nodst",
                        reference: reference, primClass: kind, trueColour: trueColour)
                }
            }
            tables[trueColour] = table
        }
        primPipelines = tables
```

Extend `makePipeline` with `primClass: Int32? = nil, trueColour: Bool = false`, and inside, when `primClass` is non-nil, create the FRAGMENT function with constants too:

```swift
        let fs: MTLFunction
        if let primClass {
            let fc = MTLFunctionConstantValues()
            var cls = Int32(primClass)
            var tc = trueColour
            fc.setConstantValue(&cls, type: .int, index: 1)
            fc.setConstantValue(&tc, type: .bool, index: 2)
            fs = try library.makeFunction(name: fragment, constantValues: fc)
        } else {
            guard let f = library.makeFunction(name: fragment) else {
                throw Error.missingFunction(fragment)
            }
            fs = f
        }
```

In `appendPrim`, compute the variant and coalesce only equal variants:

```swift
        let variant = PrimVariant(
            kind: inst.kind,
            readsDst: inst.flags & (PS1_PRIM_TRANSPARENT | PS1_PRIM_CHECK_MASK) != 0
                || vram.depthPersists)
        let i = instances.count
        instances.append(inst)
        if case let .draw(.prim(v), range)? = steps.last, v == variant, range.upperBound == i {
            steps[steps.count - 1] = .draw(kind: .prim(variant), range: range.lowerBound..<(i + 1))
        } else {
            steps.append(.draw(kind: .prim(variant), range: i..<(i + 1)))
        }
```

In `endFrame`'s step loop, resolve the pipeline per draw:

```swift
            case let .draw(kind, range):
                let state: MTLRenderPipelineState?
                if case let .prim(v) = kind {
                    state = primPipelines[ditherMode == .trueColor]?[v]
                } else {
                    state = pipelines[kind]
                }
                guard !range.isEmpty, let e = openPass(), let state else { continue }
```

(the rest of that case is unchanged.) Fix any other `.prim` match the compiler reports (Step 4's grep).

- [ ] **Step 5: Run the new tests**

Run `everyVariantIsBuiltAtInit`, then `theSpecialisedVariantsPaintExactlyWhatTheUberShaderPainted`.
Expected: both pass; note the printed init time. If it exceeds 500 ms, record it in the skill doc and raise it in the task report (a background pre-build is then a follow-up, not part of this task).

- [ ] **Step 6: Benchmark A/B**

```bash
zig build macos -Doptimize=ReleaseFast && pkill -x Substation
PS1_GPU_BENCH=crash-bandicoot-warped,silent-hill-usa,tr1-usa-v1-1 PS1_GPU_BENCH_AB=uber \
  zig-out/Substation.app/Contents/MacOS/Substation 2>/dev/null | grep gpu-bench
```

Expected: `current` faster than `uber` at 4x and above. Record the table under "Task 4: specialised pipelines" in the skill. If not faster, revert Steps 2 and 4 (keep Step 1's tests out too) and record why.

- [ ] **Step 7: Full suite and commit**

Run: `pkill -x Substation; ps1-macos/test.sh 2>&1 | grep -E "✘|Test run with|TEST (SUCC|FAIL)"`. Expected: `** TEST SUCCEEDED **`.

```bash
git add ps1-macos/Shaders/Rasterizer.metal ps1-macos/Sources/PS1/MetalRasterizer.swift \
  ps1-macos/Sources/PS1/PrimEncoders.swift ps1-macos/Tests/PS1Tests/RasterizerReferenceTests.swift \
  .claude/skills/ps1-gpu-metal/SKILL.md
git commit -m "perf(metal): primitives draw through pipelines specialised by class and colour mode"
```

---

### Task 5: Cheaper bilinear

**Files:**
- Modify: `ps1-macos/Shaders/Rasterizer.metal` (`ps1_bilinear`)
- Modify: `ps1-macos/Sources/PS1/MetalRasterizer.swift` (set constant index 3 on fragment functions)
- Modify: `ps1-macos/Tests/PS1Tests/RasterizerReferenceTests.swift`

**Interfaces:**
- Consumes: `RasterizerReference.referenceBilinear`, `ReferenceLockstep.compare`, `makePipeline(... primClass:trueColour:)` (Task 4).
- Produces: nothing new for later tasks.

Two exact savings: a sample whose weight is zero contributes `0` to both `acc` and `wsum` and need not be fetched (every sample at 1x on a 1:1 mapping has `fu == fv == 0`, so three of four go); and samples whose clamped coordinates coincide (an atlas cell's limit, a degenerate range) are fetched once.

- [ ] **Step 1: Write the failing test**

Append to `RasterizerReferenceTests.swift`:

```swift
@Test func theCheaperBilinearFiltersExactlyAsTheReferenceDid() throws {
    for fixture in ReferenceLockstep.corpus {
        for scale in [1, 2, 3, 4, 6] {
            let msg = try ReferenceLockstep.compare(fixture, scale: scale, dither: .trueColor,
                                                   filter: .bilinear, spriteFilter: .bilinear,
                                                   reference: .referenceBilinear)
            #expect(msg == nil, Comment(rawValue: msg ?? ""))
        }
    }
}
```

Run it. Expected: it PASSES before the change (both sides run today's function), which is the point of writing it first: it must still pass after.

- [ ] **Step 2: Rename the old function and add the switch**

In `Rasterizer.metal`, rename today's `ps1_bilinear` to `ps1_bilinear_reference` (body unchanged). Add after the other constants:

```metal
constant bool PS1_FC_REF_BILINEAR_RAW [[function_constant(3)]];
constant bool PS1_FC_REF_BILINEAR = is_function_constant_defined(PS1_FC_REF_BILINEAR_RAW)
    && PS1_FC_REF_BILINEAR_RAW;
```

Add the new function below the reference:

```metal
/// `ps1_bilinear_reference`, with two savings that change no output bit: a
/// zero-weight sample is never fetched (it adds 0 to `acc` and `wsum`
/// either way, hole or not), and a sample whose clamped texel equals an
/// earlier one reuses that fetch. At 1x on a 1:1 mapping fu == fv == 0, so
/// three of the four fetches go.
inline int3 ps1_bilinear(const device Ps1PrimInstance& p,
                         texture2d<ushort, access::read> vram, uint s,
                         int u6, int v6, int2 ul, int2 vl, uint u, uint v) {
    if (PS1_FC_REF_BILINEAR) return ps1_bilinear_reference(p, vram, s, u6, v6, ul, vl, u, v);
    int bu = ps1_floor_div(u6 - 32, 64), bv = ps1_floor_div(v6 - 32, 64);
    int fu = (u6 - 32) - bu * 64, fv = (v6 - 32) - bv * 64;
    uint su[2] = { uint(clamp(bu, ul.x, ul.y)) & 0xFFu, uint(clamp(bu + 1, ul.x, ul.y)) & 0xFFu };
    uint sv[2] = { uint(clamp(bv, vl.x, vl.y)) & 0xFFu, uint(clamp(bv + 1, vl.x, vl.y)) & 0xFFu };
    int wu[2] = { 64 - fu, fu };
    int wv[2] = { 64 - fv, fv };
    int3 acc = int3(0);
    int wsum = 0;
    ushort cache_t = 0;
    uint cache_u = 0xFFFFFFFFu, cache_v = 0xFFFFFFFFu;
    for (int j = 0; j < 2; j++) {
        for (int i = 0; i < 2; i++) {
            int wt = wu[i] * wv[j];
            if (wt == 0) continue;
            ushort t;
            if (su[i] == cache_u && sv[j] == cache_v) {
                t = cache_t;
            } else {
                t = ps1_window_fetch(p, vram, s, su[i], sv[j]);
                cache_t = t; cache_u = su[i]; cache_v = sv[j];
            }
            if (t == 0) continue;
            acc += wt * ps1_texel8(t);
            wsum += wt;
        }
    }
    return wsum != 0 ? acc / wsum : ps1_texel8(ps1_window_fetch(p, vram, s, u, v));
}
```

The one-entry cache catches the coincidences that occur (adjacent samples clamped onto the same column or row arrive consecutively in this loop order); it is exact because a texel is a pure function of its coordinates within one fragment.

- [ ] **Step 3: Set constant 3 on every fragment function built with constants**

In `makePipeline`, inside the `if let primClass` branch, add:

```swift
            var refBilinear = reference.contains(.referenceBilinear)
            fc.setConstantValue(&refBilinear, type: .bool, index: 3)
```

The uber pipeline (`ps1_prim_fragment`, built without constants) leaves it undefined, which means the new function: `.uberShader` and `.referenceBilinear` are separate switches.

- [ ] **Step 4: Run the equality test and the existing filter tests**

Run `theCheaperBilinearFiltersExactlyAsTheReferenceDid`, then the full suite: `pkill -x Substation; ps1-macos/test.sh 2>&1 | grep -E "✘|Test run with|TEST (SUCC|FAIL)"`.
Expected: both pass.

- [ ] **Step 5: Benchmark A/B**

```bash
zig build macos -Doptimize=ReleaseFast && pkill -x Substation
PS1_GPU_BENCH=crash-bandicoot-warped,silent-hill-usa,tr1-usa-v1-1 PS1_GPU_BENCH_AB=bilinear \
  zig-out/Substation.app/Contents/MacOS/Substation 2>/dev/null | grep gpu-bench
```

This is measured at the player's settings; if the player's texture filter is Nearest the rows will not differ, so set it first: `defaults write $(defaults domains | tr ',' '\n' | grep -m1 -i substation | xargs) textureFilter -int 1` only if it is not already 1, and restore it afterwards.
Expected: `current` faster than `ref-bilin`. Record under "Task 5: cheaper bilinear". If not faster at 4x or above, revert Steps 2-3 and record why.

- [ ] **Step 6: Commit**

```bash
git add ps1-macos/Shaders/Rasterizer.metal ps1-macos/Sources/PS1/MetalRasterizer.swift \
  ps1-macos/Tests/PS1Tests/RasterizerReferenceTests.swift .claude/skills/ps1-gpu-metal/SKILL.md
git commit -m "perf(metal): bilinear skips zero-weight and repeated texel fetches"
```

---

### Task 6: Is the CPU the ceiling? (measurement)

**Files:**
- Modify: `.claude/skills/ps1-gpu-metal/SKILL.md`

No code. The spec's unit 4 is conditional on this measurement; any CPU optimisation it calls for becomes its own plan.

- [ ] **Step 1: Run the benchmark with every task landed**

```bash
zig build macos -Doptimize=ReleaseFast && pkill -x Substation
PS1_GPU_BENCH=crash-bandicoot-warped,silent-hill-usa,tr1-usa-v1-1 \
  zig-out/Substation.app/Contents/MacOS/Substation 2>/dev/null | grep gpu-bench
```

- [ ] **Step 2: Record the verdict**

Add "After the spec" with the 12 lines, beside the baseline, and one sentence per fixture: at 4x and 6x, is `cpu ms` >= `gpu ms`? If yes for any row, the CPU encode is the ceiling there and a follow-up plan (profile `PrimBuilder` / `MetalRasterizer.apply` with `xctrace`) is warranted; state that. If no, state that the GPU remains the limit and unit 4 is shown unnecessary. Also state, from the `fps` column, whether 6x reaches 60 fps with headroom for Crash and Silent Hill (the spec's primary goal) and whether 8x does.

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/ps1-gpu-metal/SKILL.md
git commit -m "docs: renderer performance results and the CPU ceiling verdict"
```

---

### Task 7: Delete the reference paths

Only after the full suite has passed twice in a row with Tasks 2-5 landed (spec: "two consecutive full-suite runs").

**Files:**
- Modify: `ps1-macos/Shaders/Rasterizer.metal` (delete `ps1_prim_fragment`, `ps1_bilinear_reference`, `PS1_FC_BOX_ONLY*`, `PS1_FC_REF_BILINEAR*`)
- Modify: `ps1-macos/Sources/PS1/MetalRasterizer.swift` (delete `RasterizerReference`, the `reference` parameter and property, the uber branch)
- Modify: `ps1-macos/Sources/PS1/GpuBench.swift` (`Config.reference`, `PS1_GPU_BENCH_AB` parsing)
- Modify: `ps1-macos/Tests/PS1Tests/MetalScaleHarness.swift` (`reference:` parameter)
- Delete: `ps1-macos/Tests/PS1Tests/RasterizerReferenceTests.swift`
- Modify: `.claude/skills/ps1-gpu-metal/SKILL.md`

**Interfaces:**
- Consumes: everything above. Produces: the final renderer with no switches.

- [ ] **Step 1: Run the suite twice**

Run `pkill -x Substation; ps1-macos/test.sh 2>&1 | grep -E "✘|Test run with|TEST (SUCC|FAIL)"` twice. Expected: `** TEST SUCCEEDED **` both times. If either fails, stop and report.

- [ ] **Step 2: Delete**

Delete the items listed under **Files**. In `ps1_vertex`, the condition becomes `if (tri && ps1_hull(p, s, h))`. In `ps1_bilinear`, delete the `if (PS1_FC_REF_BILINEAR) ...` line. In `makePipeline`, delete the `boxOnly` and `refBilinear` constants and the `reference` parameter; the vertex function goes back to `library.makeFunction(name: "ps1_vertex")` with a `guard ... else { throw Error.missingFunction("ps1_vertex") }`. In `init`, `primPipelines` is built without the `uber` fallback. `GpuBench.configs` returns `[Config(name: "current")]` and `Config` loses `reference`. Keep `aThinDiagonal...`, `aNeedle...`, `aSubPixelSliver...` and `aClippedGiant...` by moving them to `MetalScaleTests.swift` rewritten to assert against the 1x `.native` image instead of a box reference:

```swift
/// The hull must not lose a subtexel the triangle covers: at every scale the
/// top-left subtexel of each block reproduces 1x (Gate 2's property) AND no
/// unpainted subtexel is enclosed by painted ones in the triangle's window.
```

Use the existing `aSmallTriangleIsSolidRatherThanHollowAtEveryScale` body as the template for the enclosed-hole check, with each of the four vertex sets.

- [ ] **Step 3: Full suite and benchmark**

Run the suite; expected `** TEST SUCCEEDED **`. Run the Task 6 Step 1 benchmark; the rows must match the "After the spec" table within run-to-run spread.

- [ ] **Step 4: Update the skill**

In `.claude/skills/ps1-gpu-metal/SKILL.md`: the paragraph that says "every primitive is one instance of a bounding-box quad" now says a triangle draws its conservative hull when smaller, coverage still decided in the fragment shader; add that primitive draws go through 28 specialised pipelines keyed by `PrimVariant` and true colour, and the `readsDst` rule (blended, mask-checked or depth buffer on).

- [ ] **Step 5: Commit**

```bash
git add -A ps1-macos/Shaders ps1-macos/Sources ps1-macos/Tests .claude/skills/ps1-gpu-metal/SKILL.md
git commit -m "refactor(metal): drop the reference paths the performance work was checked against"
```
