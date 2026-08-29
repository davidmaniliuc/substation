# Metal Renderer Phase B — The Backend at 1× Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Metal backend that consumes a recorded GP0 command stream and produces VRAM byte-identical to the software rasterizer at 1×, gated by `.p1fx` fixtures under `ps1-macos/test.sh`.

**Architecture:** Every primitive is submitted as a bounding-box quad, one instance per primitive, with all resolved state in a device-buffer record indexed by `instance_id`; the fragment shader evaluates coverage itself (integer edge functions, top-left rule) and ends in a transcription of `putPixel` (clip → mask check → integer blend → STP). The memory movers (GP0 `02`/`80`/`A0`) run as their own small pipelines against the same `R16Uint` render texture. Nothing is wired into the running app — Phase B is entirely fixture-driven.

**Tech Stack:** Metal Shading Language, Swift 6 + swift-testing under `xcodebuild`, Zig 0.16.0 (`ps1-golden` only), the `CPs1` module map, FNV-1a 64.

**Spec:** `docs/superpowers/specs/2026-08-27-metal-renderer-phase-b-design.md` — read it first, especially § What Phase A2 actually banked and § Architecture. Its parent is `docs/superpowers/specs/2026-08-23-metal-hardware-renderer-design.md`.

---

## Deviations from the spec's task table (decided while writing this plan; do not relitigate)

1. **Eleven tasks, not ten.** The spec assigns Task 5's gate as "`pl-render-polygon` frame 0", but that fixture's frame 0 contains 18 flat triangles **and** 6 Gouraud triangles in one frame, and 16 of its 17 frames are empty repeats of frame 0's hash. Measured, not assumed — see § Fixture census below. There is therefore no flat-only gate anywhere in the corpus. Task 2 adds a committed `synthetic-primitives.p1fx` built the way `synthetic.zig` builds the mover fixture: real GP0 words through a bare `Gpu`, one frame per feature group, hashes produced by the real Zig rasterizer. Tasks 6–10 gate on a growing prefix of its frames; the PL and real-game fixtures become the closing gate at Task 11.

2. **`DrawEnv` (spec Task 4) moves ahead of the movers (spec Task 3).** The mover encoder needs GP0(E6)'s two mask bits, and building a throwaway E6-only path first and replacing it one task later is rework. `DrawEnv` is a pure value type with no Metal in it, so it costs nothing to land early.

3. **`raster_order_group` is not used; an ordering test decides instead.** The spec calls the raster order group "load-bearing, not decoration". `[[raster_order_group(n)]]` in MSL orders accesses to **device memory** (buffers and textures written with `write()`); the ordering of *colour-attachment* reads — which is what programmable blending is — is already guaranteed by Metal's primitive-ordering rules, including between instances of one instanced draw. Task 6 pins this with `overlappingInstancesBlendInSubmissionOrder`, which fails loudly if the guarantee does not hold; only then would a ROG be added.

4. **One `prim` pipeline for every drawing primitive; three more for the movers.** The spec says both "there is no Metal pipeline state that differs between primitives" and "`fill_rect` — its own pipeline". Both hold: the *drawing* primitives share one pipeline (so a run of them is one instanced draw), and the three movers get `fill` / `upload` / `copy` pipelines because each has genuinely different semantics (a fill ignores E6 *and* the drawing area; an upload reads a staging buffer; a copy reads a scratch texture).

---

## Context

Phase A2 is landed. `.p1fx`, `FixtureFile`, `ShadowVram`, `Fnv1a` and seven fixtures exist; `trace-golden -- stream-verify` proves the stream lossless across 23,449 frames of ten workloads. `command.Command` is an `extern struct` pinned at 72 bytes and mirrored in `ps1-capi/include/ps1.h`.

Phase B adds **no emulated behaviour**. Every existing gate is a freeze check: a moved trace golden, a moved fixture hash or a moved PeterLemon floor is a bug in this phase, never a baseline to update.

### Fixture census (measured 2026-08-27, `zig-out/fixtures/`)

| fixture | frames | frame 0 census |
|---|---|---|
| `pl-render-polygon` | 17 | 18 `draw_triangle`, 6 `draw_shaded_triangle`, 10 `set_draw_env`, 1 `reset_draw_env`, 1 `vram_write_abort`, 1 `set_texture_disable_allowed` |
| `pl-render-rectangle` | 17 | 18 `draw_rectangle` + the same 13 env records |
| `pl-render-line` | 17 | 60 `draw_line`, 20 `draw_shaded_line` + the same 13 |
| `pl-render-texture-polygon` | 17 | 48 `draw_textured_triangle`, 34 `latch_texpage`, 4 `vram_write_setup`, 4 `vram_write_data` (2,720 payload words) + the same 13 |
| `croc-legend-of-the-gobbos` | 200 | 1014 `vram_write_setup` + `_data`, 50 `fill_rect`, 306 `set_draw_env`, 0 draw records |
| `synthetic-movers` | 6 | movers only |

Frames 1–16 of every `pl-*` fixture are empty and repeat frame 0's hash. **No fixture anywhere contains `draw_textured_rectangle` or (outside `synthetic-movers`) `copy_rect`.** That is what Task 1 fixes.

---

## Global Constraints

- **Zig 0.16.0 only.** `std.Io.Dir.cwd()`, `std.process.Init`, `std.ArrayList(...).empty` (unmanaged — `append`/`print` take the allocator first), `addRunArtifact`, `b.addOptions`. Run `zig fmt` before every commit.
- **`ps1-core/src` is not modified in this phase, at all.** Not one line. Phase 0 was the only phase permitted to change the software rasterizer's output, and every fixture hash in the corpus is frozen against it. If a task appears to need a core change, stop and ask.
- **These four must be green at every commit:** `zig build test`; `zig build trace-golden -Doptimize=ReleaseFast -- verify`; `zig build trace-golden -Doptimize=ReleaseFast -- stream-verify`; `zig build test-roms-pl -Doptimize=ReleaseFast`.
- **`-D` options go BEFORE `--`.** `zig build trace-golden -Doptimize=ReleaseFast -- stream-capture`. Anything after `--` is an argument to `ps1-golden`.
- **`zig build test-roms-pl` prints a `failed command: …/test … --listen=-` line and still exits 0.** Not a red gate — the suite's `debug.print` confuses the build runner's `--listen` protocol and zig re-runs the binary standalone. Redirect to a file and read `echo $?`.
- **Swift tests need `zig build capi-lib` and `zig build metallib` first**, then `ps1-macos/test.sh`. Both need full Xcode. `test.sh` passes no `-quiet` on purpose.
- **`Sources/` and `Tests/` are `PBXFileSystemSynchronizedRootGroup`s.** Adding a `.swift` file needs **no** `PS1.xcodeproj` edit. Do not add `PBXFileReference`/`PBXBuildFile` entries.
- **Scale is fixed at 1 throughout.** No upscaling anywhere; that is Phase C.
- **No live ABI handoff.** No `ps1_take_frame_stream`, no `gpu_sink = .dual` for `ps1-capi`, no app integration. Phase D.
- **No file in `ps1-core/src` over ~600 lines** (not exercised here). New Swift and Metal files stay under ~350 lines; split rather than exceed.
- **Little-endian is asserted, never assumed**, on both sides.
- **Commit style:** one commit per task, directly on `master`, message ending with:
  ```
  Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
  ```
  **Never `git push`.**

---

## Design decisions taken (do not relitigate mid-execution)

**1. Uniform submission: a bounding-box quad per primitive, one instance each.** The vertex shader expands `vertex_id 0..3` into the box corners; the fragment shader takes `uint2(in.position.xy)` (`[[position]]` is the pixel centre `(px+0.5, py+0.5)`, so truncation is exact) and evaluates coverage itself. **Metal's own rasterizer is never trusted for coverage** — its fill rule and sample positions are not the PS1's.

**2. All per-primitive state is resolved on the CPU into the instance record.** Drawing environment, `clut`, `tpage`, colours, blend mode, mask bits, clip rect. Nothing differs in *pipeline* state between drawing primitives, so a run of them is one instanced draw and ordering is preserved because instances rasterize in submission order.

**3. The instance record is declared once in C** (`ps1-macos/Shaders/PrimInstance.h`), included by the Metal source and imported into Swift through the `CPs1` module map. Same reasoning as `Ps1GpuCommand` in Phase A2: Swift does not guarantee C-compatible layout for its own structs. Plain `int`/`unsigned int` throughout — **never `<stdint.h>`**, which MSL does not ship.

**4. Integer arithmetic only, transcribed from `color.zig`.** Blend is `blend(bg, fg, mode)` on 5-bit channels with truncating division, **not** fixed-function blending. Dither offsets are 8-bit channel units added before the `>> 3`. `interp` is `(w0·a0 + w1·a1 + w2·a2) / area`, and plain `/` is exact here because coverage guarantees `num >= 0` and `area > 0`, where `@divFloor` and `@divTrunc` agree (`renderer.zig:86-89`).

**5. The oversized-primitive drop stays on the CPU**, in the encoder, as a skipped instance — judged per triangle (each quad half separately), exactly as `renderer.zig:123-124` does. It is a refusal to draw, not a clip.

**6. Lines are CPU-expanded to one 1×1 instance per Bresenham step**, at most 1024 of them. No GPU triangle setup reproduces an error accumulator. The per-pixel colour stays in the shader as `c0 + floor((c1-c0)·k / steps)`, evaluated from `k` — which is exactly the form Phase 0 rewrote `drawShadedLine` into (`renderer.zig:342-345`). `floor` here is **not** truncation: `c1 - c0` is routinely negative, so the shader needs a real floor-division helper.

**7. Movers keep `ShadowVram`'s FSM rather than growing a third transcription.** The GP0(A0) transfer FSM is extracted into `VramTransfer.swift` and used by both `ShadowVram` and the Metal encoder. `ShadowVram` is not scaffolding — the parent spec calls these "Phase B's 02/80/A0 passes, written a phase early".

**8. A self-overlapping `copy_rect` is executed as blit-to-scratch then draw-from-scratch**, which makes `vram.zig:154`'s direction reversal disappear rather than requiring it to be reproduced. The destination wraps on both axes, so it is emitted as up to four instances (≤2 x-ranges × ≤2 y-ranges), each with a real rectangular box.

**9. Every mover op ends the render pass, from Task 5 onward.** Conservative and always correct; it is what lets Task 8's textured triangles sample a texture uploaded earlier in the same frame. Task 11 adds the *precise* dirty-rect hazard test for primitive→primitive feedback on top; it never weakens this rule.

**10. Phase B allocates freely on the encoding path.** `makeBuffer(bytes:)` per flush, Swift arrays for instances. The no-allocation rule in the parent spec is about the emulator thread at `.userInteractive` QoS, which Phase B never touches. Phase D owns that.

---

## File Structure

**Zig / build (no `ps1-core/src`):**

- `ps1-golden/src/main.zig` — **modified** (Tasks 1, 3). `--probe` census columns; a `pinned_windows` table; `--dump-frame=<n>`.
- `ps1-golden/src/synthetic_prims.zig` — **new** (Task 2). Builds the committed primitives fixture from real GP0 words.
- `ps1-golden/src/fixture_test.zig` — **modified** (Task 2). The generator-vs-committed byte equality check for the new fixture.
- `ps1-core/tests/goldens/fixtures/synthetic-primitives.p1fx` — **new, committed** (Task 2). `.gitignore` already un-ignores `ps1-core/tests/goldens/fixtures/*.p1fx`; no change needed there.
- `build.zig` — **modified** (Tasks 1, 2, 3). Extra `fixtures` runs; the new anonymous import; the second `.metal` merged into one metallib.

**Metal:**

- `ps1-macos/Shaders/PrimInstance.h` — **new** (Task 3). The instance record and its kind/flag constants. Header of record.
- `ps1-macos/Shaders/Ps1Color.h` — **new** (Tasks 6–10). `blend`, `modulate`, `fetchTexel`, the dither table, `pack`, `floorDiv`, `interp`, `orient2d`, `topLeft`. Metal-only.
- `ps1-macos/Shaders/Rasterizer.metal` — **new** (Tasks 3, 5–10). The vertex function and the four fragment functions.
- `ps1-macos/Shaders/embed.zig` — **modified** (Task 3). Symbol rename.

**Swift:**

- `ps1-macos/Sources/CPs1/include/prim_instance_shim.h` — **new** (Task 3).
- `ps1-macos/Sources/CPs1/include/metallib.h` — **new** (Task 3), replacing `display_metallib.h`.
- `ps1-macos/Sources/CPs1/include/module.modulemap` — **modified** (Task 3).
- `ps1-macos/Sources/PS1/Shaders.swift` — **new** (Task 3), replacing `DisplayShader.swift`.
- `ps1-macos/Sources/PS1/MetalVram.swift` — **new** (Task 3). The render texture, clear, upload, readback, hash.
- `ps1-macos/Sources/PS1/VramDump.swift` — **new** (Task 3). Raw-blob dump and pixel-wise diff report.
- `ps1-macos/Sources/PS1/DrawEnv.swift` — **new** (Task 4).
- `ps1-macos/Sources/PS1/VramTransfer.swift` — **new** (Task 5). The GP0(A0) FSM, extracted.
- `ps1-macos/Sources/PS1/ShadowVram.swift` — **modified** (Task 5). Uses `VramTransfer`.
- `ps1-macos/Sources/PS1/MetalRasterizer.swift` — **new** (Tasks 5–11). The encoder.
- `ps1-macos/Sources/PS1/PrimBuilder.swift` — **new** (Tasks 6–10). Record → instances. Split from the encoder to keep both under ~350 lines.
- `ps1-macos/Sources/PS1/LineExpander.swift` — **new** (Task 10). The Bresenham walk.
- `ps1-macos/Sources/PS1/HazardTracker.swift` — **new** (Task 11).
- `ps1-macos/Sources/PS1/MetalDisplayView.swift` — **modified** (Task 3). `DisplayShader.` → `Shaders.`.

**Swift tests:**

- `ps1-macos/Tests/PS1Tests/MetalVramTests.swift` — **new** (Task 3).
- `ps1-macos/Tests/PS1Tests/MetalFixtureHarness.swift` — **new** (Task 5). The `.p1fx`-through-Metal replay helper, shared by Tasks 5–11.
- `ps1-macos/Tests/PS1Tests/DrawEnvTests.swift` — **new** (Task 4).
- `ps1-macos/Tests/PS1Tests/MetalMoverTests.swift` — **new** (Task 5).
- `ps1-macos/Tests/PS1Tests/MetalRasterizerTests.swift` — **new** (Tasks 6–11). The fixture-replay harness and the per-task gates.
- `ps1-macos/Tests/PS1Tests/LineExpanderTests.swift` — **new** (Task 10).
- `ps1-macos/Tests/PS1Tests/HazardTrackerTests.swift` — **new** (Task 11).
- `ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift` — **modified** (Tasks 1, 2).
- `ps1-macos/Tests/PS1Tests/DisplayShaderTests.swift`, `DisplayRenderTests.swift` — **modified** (Task 3). Rename only.

- `CLAUDE.md` — **modified** (Task 11).

---

---

## Task 1: Geometry fixtures

The corpus has no real-game geometry and no `draw_textured_rectangle` or `copy_rect` anywhere outside the committed synthetic mover fixture. Fix that before any Metal exists to confound the result. `--probe` currently reports *total* records, which is why the Croc window was chosen for A0 payload and turned out to contain zero draw records.

**Files:**
- Modify: `ps1-golden/src/main.zig` (the `--probe` branch at `:587-593`; the croc window constants at `:302-303`; the window selection at `:514-517`)
- Modify: `build.zig` (the `fixtures` step at `:109-116`)
- Modify: `ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `zig-out/fixtures/<key>.p1fx` for two new disc workloads whose frames contain `draw_triangle`/`draw_shaded_triangle`/`draw_textured_triangle`, `draw_textured_rectangle` and `copy_rect`. No Swift or Zig symbol is exported to later tasks.

- [ ] **Step 1: Make `--probe` report draw records, textured rectangles and copies**

In `ps1-golden/src/main.zig`, add a census helper above `runStreamCapture`:

```zig
/// Per-frame census columns for `--probe`. `draws` counts the seven
/// rasterizing kinds; `textured_rects` and `copies` are called out separately
/// because they were absent from the WHOLE Phase A2 corpus, and a window that
/// contains neither is not a real-game gate no matter how many triangles it
/// has.
const Census = struct {
    draws: usize = 0,
    textured_rects: usize = 0,
    copies: usize = 0,

    fn count(records: []const ps1.gpu.command.Command) Census {
        var c = Census{};
        for (records) |cmd| {
            switch (cmd.kind) {
                .draw_triangle,
                .draw_shaded_triangle,
                .draw_textured_triangle,
                .draw_rectangle,
                .draw_textured_rectangle,
                .draw_line,
                .draw_shaded_line,
                => c.draws += 1,
                else => {},
            }
            switch (cmd.kind) {
                .draw_textured_rectangle => c.textured_rects += 1,
                .copy_rect => c.copies += 1,
                else => {},
            }
        }
        return c;
    }
};
```

Replace the `if (opts.probe)` block inside `runStreamCapture`:

```zig
        if (opts.probe) {
            // One line per frame, piped into awk to find the densest window.
            // Columns: instruction, records, payload words, draw records,
            // textured rectangles, VRAM->VRAM copies.
            const c = Census.count(s.records);
            std.debug.print("PROBE {d} {d} {d} {d} {d} {d}\n", .{
                i, s.records.len, s.payload.len, c.draws, c.textured_rects, c.copies,
            });
            continue;
        }
```

Update the `--probe` line in `usage` to name the six columns.

- [ ] **Step 2: Verify the probe still runs and the columns appear**

```bash
zig build trace-golden -Doptimize=ReleaseFast -- stream-capture --probe --filter=pl-render-polygon 2>&1 | grep -c '^PROBE '
zig build trace-golden -Doptimize=ReleaseFast -- stream-capture --probe --filter=pl-render-polygon 2>&1 | grep '^PROBE ' | head -1
```
Expected: 17 lines, and the first reads `PROBE <instr> 37 0 24 0 0` (24 draws = 18 flat + 6 Gouraud, no textured rectangles, no copies).

- [ ] **Step 3: Measure the candidate disc workloads**

Probe three candidates. Each is a 600M-instruction ReleaseFast run; expect a few minutes apiece.

```bash
for KEY in crash-bandicoot-europe-edc silent-hill-usa spyro-the-dragon-usa; do
  zig build trace-golden -Doptimize=ReleaseFast -- stream-capture --probe --filter="$KEY" \
    > "/tmp/probe-$KEY.txt" 2>&1
done
```

Find each workload's densest 100-frame window by draw records:

```bash
for KEY in crash-bandicoot-europe-edc silent-hill-usa spyro-the-dragon-usa; do
  echo -n "$KEY  "
  grep '^PROBE ' "/tmp/probe-$KEY.txt" | awk '
    { ins[NR]=$2; d[NR]=$5; t[NR]=$6; c[NR]=$7 }
    END {
      best=-1
      for (i = 1; i + 99 <= NR; i++) {
        s=0; tt=0; cc=0
        for (j = i; j < i + 100; j++) { s += d[j]; tt += t[j]; cc += c[j] }
        if (s > best) { best=s; bi=i; bt=tt; bc=cc }
      }
      printf "capture_from=%d draws=%d textured_rects=%d copies=%d frames=%d\n", ins[bi], best, bt, bc, NR
    }'
done
```

Pick the **two** workloads whose best window has the most draw records **and** a non-zero `textured_rects`. If neither of the two picked has a non-zero `copies`, probe the remaining disc workloads (`crash-bandicoot-warped`, `crash-bandicoot-2-cortex-strikes-back-europe-australia-en-fr-de-es-it-edc`, `metal-gear-solid-special-missions-europe-enfrdeesit`, `resident-evil-usa`, `tr1-usa-v1-1`) until one is found, and take that as the second workload. Do **not** proceed with a window that has zero textured rectangles across all candidates — that is the exact mistake this task opens by fixing; raise `--instructions=1200000000` for the candidates and re-probe instead.

Record the three numbers per chosen workload (`capture_from`, `draws`, `textured_rects`, `copies`) in the commit message.

- [ ] **Step 4: Pin the windows**

Replace the two croc constants and the croc special case in `ps1-golden/src/main.zig` with a table. Constants block, replacing `croc_capture_from`/`croc_frames`:

```zig
/// A fixture's capture window, pinned by INSTRUCTION rather than by frame
/// ordinal: ps1-golden's button schedule is instruction-indexed, so an
/// instruction is reproducible and a frame number is not.
///
/// Croc's window is the densest 200 frames of A0 PAYLOAD in a 600M-instruction
/// run — i.e. where the FMV is — measured 2026-08-26. It contains zero draw
/// records, which is correct for what it exists to cover (the memory movers at
/// real-game payload sizes) and is why the other two entries exist at all.
///
/// The other two are the densest 100 frames of DRAW records, measured with
/// `stream-capture --probe` on 2026-08-27. 100 rather than 200 because a
/// geometry-dense frame carries up to 3,715 records: 200 frames of that is a
/// ~53 MB build artifact for no extra coverage.
const PinnedWindow = struct {
    key_substring: []const u8,
    capture_from: u64,
    frames: u64,
};

const pinned_windows = [_]PinnedWindow{
    .{ .key_substring = "croc", .capture_from = 166638789, .frames = 200 },
    // TASK 1 STEP 3 writes the two lines below. Each is
    //   .{ .key_substring = "<workload key>", .capture_from = <measured>, .frames = 100 },
};
```

And the selection, replacing the `std.mem.indexOf(u8, wl.key, "croc")` block:

```zig
    // A pinned window applies only when neither flag is given, so an explicit
    // `--capture-from`/`--frames` on the command line still overrides it.
    var capture_from = opts.capture_from;
    var frame_limit = opts.frames;
    if (capture_from == 0 and frame_limit == 0) {
        for (pinned_windows) |p| {
            if (std.mem.indexOf(u8, wl.key, p.key_substring) != null) {
                capture_from = p.capture_from;
                frame_limit = p.frames;
                break;
            }
        }
    }
```

- [ ] **Step 5: Extend the `fixtures` build step**

In `build.zig`, after `fixtures_run_croc`, add one chained run per new workload — chained, not parallel, because every `stream-capture` invocation writes `synthetic-movers.p1fx` unconditionally regardless of filter and two independent steps would race on that path:

```zig
    // The two geometry workloads. Croc's window is FMV — 1,014 transfers, 50
    // fills and zero draw records — so it covers the movers at real payload
    // sizes and nothing else. These two are the real-game half of Phase B's
    // gate: triangles, textured rectangles and VRAM->VRAM copies from actual
    // game software rather than from a synthetic generator.
    const geometry_filters = [_][]const u8{
        // TASK 1 STEP 3 writes the two workload keys here.
    };
    var prev_fixture_run = fixtures_run_croc;
    for (geometry_filters) |f| {
        const run = b.addRunArtifact(golden_exe);
        run.step.dependOn(&prev_fixture_run.step);
        run.addArgs(&.{ "stream-capture", b.fmt("--filter={s}", .{f}) });
        prev_fixture_run = run;
    }
    const fixtures_step = b.step("fixtures", "Write .p1fx command-stream fixtures to zig-out/fixtures");
    fixtures_step.dependOn(&prev_fixture_run.step);
```

- [ ] **Step 6: Capture, and prove it is reproducible byte-for-byte**

```bash
zig build fixtures -Doptimize=ReleaseFast
mkdir -p /tmp/fixtures-run1 && cp zig-out/fixtures/*.p1fx /tmp/fixtures-run1/
zig build fixtures -Doptimize=ReleaseFast
for f in zig-out/fixtures/*.p1fx; do cmp "$f" "/tmp/fixtures-run1/$(basename "$f")" || echo "NOT REPRODUCIBLE: $f"; done
echo "exit $?"
```
Expected: no `NOT REPRODUCIBLE` line. A capture that is not byte-stable is not a gate.

- [ ] **Step 7: Write the failing Swift census test**

Append to `ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift`:

```swift
// MARK: - The geometry corpus (Phase B Task 1)
//
// Phase A2's real-game fixture contains ZERO draw records: its window was
// chosen as the densest 200 frames of A0 payload, which is where Croc's FMV
// is. These two fixtures are the densest 100 frames of DRAW records, and the
// three kinds asserted below are the ones the whole A2 corpus was missing.

// Internal, not private: Task 11's phase gate in MetalRasterizerTests.swift
// reads this same list, and `private` at file scope would hide it.
let geometryFixtures = [
    // TASK 1 STEP 3 writes the two workload keys here.
]

@Test(.enabled(if: geometryFixtures.contains(where: generatedFixtureExists),
               "geometry fixtures are generated from games/, which is gitignored — run `zig build fixtures -Doptimize=ReleaseFast`"))
func theGeometryFixturesCarryTrianglesTexturedRectanglesAndCopies() throws {
    var checked = 0
    for name in geometryFixtures {
        guard generatedFixtureExists(name) else { continue }
        checked += 1

        let f = try FixtureFile(contentsOf: FixtureFile.url(named: name))
        var census: [UInt32: Int] = [:]
        withExtendedLifetime(f) {
            for i in 0..<f.frames.count {
                for r in f.records(for: i) {
                    census[r.commandKind.rawValue, default: 0] += 1
                }
            }
        }

        let triangles = census[PS1_GPU_DRAW_TRIANGLE.rawValue, default: 0]
            + census[PS1_GPU_DRAW_SHADED_TRIANGLE.rawValue, default: 0]
            + census[PS1_GPU_DRAW_TEXTURED_TRIANGLE.rawValue, default: 0]
        #expect(triangles > 0, "\(name) has no triangles")
        #expect(census[PS1_GPU_DRAW_TEXTURED_RECTANGLE.rawValue, default: 0] > 0,
                "\(name) has no textured rectangles — the sprite path stays uncovered")
    }
    #expect(checked > 0)

    // copy_rect need only appear in ONE of the two: it is rarer than sprites,
    // and Task 3 of the spec covers it from the committed synthetic fixture as
    // well. Zero across BOTH means the window measurement missed it.
    var copiesAnywhere = 0
    for name in geometryFixtures where generatedFixtureExists(name) {
        let f = try FixtureFile(contentsOf: FixtureFile.url(named: name))
        withExtendedLifetime(f) {
            for i in 0..<f.frames.count {
                copiesAnywhere += f.records(for: i).filter { $0.commandKind == PS1_GPU_COPY_RECT }.count
            }
        }
    }
    #expect(copiesAnywhere > 0, "no copy_rect in any geometry fixture")
}
```

- [ ] **Step 8: Run the Swift suite**

```bash
zig build capi-lib && zig build metallib && ps1-macos/test.sh 2>&1 | tail -40
```
Expected: PASS, and the new test not skipped (the fixtures exist locally).

- [ ] **Step 9: Confirm the freeze gates**

```bash
zig build test
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
zig build test-roms-pl -Doptimize=ReleaseFast > /tmp/pl.log 2>&1; echo "exit $?"
```
Expected: all green; ten workloads OK for both `verify` and `stream-verify`; `exit 0`.

- [ ] **Step 10: Commit**

```bash
zig fmt ps1-golden/src/main.zig build.zig
git add ps1-golden/src/main.zig build.zig ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift
git commit -m "$(cat <<'EOF'
feat(fixtures): a real-game geometry corpus for Phase B

--probe reported TOTAL records, which is how Phase A2 came to pin Croc's
densest-A0-payload window and bank a real-game fixture containing zero draw
records. It now reports draw records, textured rectangles and copies as
separate columns, and the window table is measured against draws.

Croc's FMV window is kept as-is: it covers the memory movers at real payload
sizes, which nothing else does.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: The committed synthetic primitives fixture

The gate ladder for Tasks 6–10. `pl-render-polygon`'s only non-empty frame mixes flat and Gouraud triangles, so nothing in the corpus can gate flat triangles alone. This fixture puts one feature group per frame, built from real GP0 words through a bare `Gpu` exactly as `synthetic.zig` does, with hashes produced by the real Zig rasterizer. It is committed, so the ladder works on a fresh clone with no `games/` and no `zig build fixtures`.

**Files:**
- Create: `ps1-golden/src/synthetic_prims.zig`
- Modify: `ps1-golden/src/main.zig` (write it alongside `synthetic-movers.p1fx`)
- Modify: `ps1-golden/src/fixture_test.zig`
- Modify: `build.zig` (a second anonymous import for `fixture_test`)
- Create: `ps1-core/tests/goldens/fixtures/synthetic-primitives.p1fx`

**Interfaces:**
- Consumes: `fixture.Writer`, `fixture.hashVram` (`ps1-golden/src/fixture.zig`), `ps1.gpu.Gpu`.
- Produces: `synthetic_prims.build(a: std.mem.Allocator) ![]u8` — the serialized fixture bytes, caller frees. Same signature as `synthetic.build`. Fixture name `synthetic-primitives`, with **seven** frames in this fixed order, which Tasks 6–10 index by number:

  | frame | contents | first gated by |
  |---|---|---|
  | 0 | flat triangles: both windings, a shared edge, a degenerate, one clipped by GP0(E3)/(E4), one with a non-zero GP0(E5) offset, one oversized (dropped), transparency in all four blend modes, E6 set/check | Task 6 |
  | 1 | Gouraud triangles, dither off then on | Task 7 |
  | 2 | textured triangles: 4bpp, 8bpp, 16bpp, a CLUT, a texture window, modulate on and off, a `texel == 0` hole, an STP-set texel under transparency | Task 8 |
  | 3 | flat rectangles: plain, transparent, clipped, oversized (dropped), 1×1 | Task 9 |
  | 4 | textured rectangles: the `u8` `+%` wrap, a texture window, modulate on and off | Task 9 |
  | 5 | lines: mono in all eight octants, plus shaded lines with rising and falling channels | Task 10 |
  | 6 | a mixed frame that re-reads frames 0–5's own output as texture data, so the feedback loop is exercised before Task 11 measures it | Task 11 |

- [ ] **Step 1: Write the generator**

Create `ps1-golden/src/synthetic_prims.zig`. The `Case` helper is deliberately a copy of `synthetic.zig`'s rather than a shared extraction: it is ten lines, and the two fixtures are frozen artifacts whose generators must not be able to drift together.

```zig
//! The committed rasterization fixture — the gate ladder for Phase B's shader
//! tasks.
//!
//! `pl-render-polygon`'s only non-empty frame carries 18 flat AND 6 Gouraud
//! triangles, so no fixture in the Phase A2 corpus can gate a flat-only
//! rasterizer. This one puts ONE FEATURE GROUP PER FRAME, in a fixed order
//! that the Swift tests index by number — see the table in
//! docs/superpowers/plans/2026-08-27-metal-renderer-phase-b.md. Do not
//! reorder or insert frames; append instead.
//!
//! Driven by real GP0 words through a bare Gpu rather than by hand-built
//! records, so gp0.zig's decode and the recorder path are exercised too, and
//! the records are the ones a real game would produce.
//!
//! Unlike `synthetic.zig` this fixture is NOT reproducible from Swift without
//! a rasterizer — that is the whole point. Its hashes come from the software
//! rasterizer and Phase B's job is to match them.

const std = @import("std");
const ps1 = @import("ps1_core");
const fixture = @import("fixture.zig");

const Gpu = ps1.gpu.Gpu;

const Case = struct {
    gpu: *Gpu,
    w: fixture.Writer = fixture.Writer.empty,
    a: std.mem.Allocator,

    fn gp0(self: *Case, word: u32) void {
        _ = self.gpu.writeGp0(word);
    }

    /// GP0 words queue into a 16-entry FIFO gated on cycle_debt while GP1
    /// executes immediately, so an undrained interleave silently reorders the
    /// stream. Always drain before a gp1() and before ending a frame.
    fn drain(self: *Case) void {
        _ = self.gpu.step(50_000_000);
    }

    fn gp1(self: *Case, word: u32) void {
        self.drain();
        self.gpu.writeGp1(word);
    }

    fn endFrame(self: *Case) !void {
        self.drain();
        const s = self.gpu.sink.rec.takeFrame();
        std.debug.assert(s.complete);
        try self.w.addFrame(self.a, s, fixture.hashVram(&self.gpu.vram));
    }

    /// GP0(E3)/GP0(E4): the inclusive drawing area. Every frame sets it
    /// explicitly — `registers.zig` defaults `area_bot_right` to 0, which is a
    /// degenerate clip rect that draws nothing at all.
    fn clip(self: *Case, x0: u32, y0: u32, x1: u32, y1: u32) void {
        self.gp0(0xE3000000 | (y0 << 10) | x0);
        self.gp0(0xE4000000 | (y1 << 10) | x1);
    }

    /// GP0(E5): the drawing offset, two 11-bit signed fields.
    fn offset(self: *Case, x: i32, y: i32) void {
        const ux: u32 = @as(u32, @bitCast(x)) & 0x7FF;
        const uy: u32 = @as(u32, @bitCast(y)) & 0x7FF;
        self.gp0(0xE5000000 | (uy << 11) | ux);
    }

    /// A vertex word: 16-bit y in the high half, 16-bit x in the low half.
    fn xy(x: i32, y: i32) u32 {
        return (@as(u32, @as(u16, @bitCast(@as(i16, @intCast(y))))) << 16) |
            @as(u32, @as(u16, @bitCast(@as(i16, @intCast(x)))));
    }
};
```

Then the seven frames. Frame 0:

```zig
pub fn build(a: std.mem.Allocator) ![]u8 {
    const gpu = try a.create(Gpu);
    defer a.destroy(gpu);
    gpu.* = Gpu.init();
    gpu.sink.rec.arm();

    var c = Case{ .gpu = gpu, .a = a };
    defer c.w.deinit(a);

    // ---- Frame 0: flat triangles ----------------------------------------
    // GP0(20) is an opaque flat triangle, GP0(22) a semi-transparent one; the
    // semi-transparency MODE is GP0(E1) bits 5-6, so the four transparent
    // triangles below each reprogram E1 first.
    c.gp0(0xE1000000); // dither off, blend mode 0
    c.clip(0, 0, 255, 191);
    c.offset(0, 0);
    c.gp0(0xE6000000); // mask off

    // Clockwise and counter-clockwise windings of the same triangle: the
    // rasterizer normalizes by flipping the sign of every edge function
    // rather than by swapping vertices, and the two must cover identically.
    c.gp0(0x2000FF00); // colour 0x00FF00
    c.gp0(Case.xy(10, 10));
    c.gp0(Case.xy(60, 14));
    c.gp0(Case.xy(20, 50));
    c.gp0(0x200000FF);
    c.gp0(Case.xy(80, 10));
    c.gp0(Case.xy(90, 50));
    c.gp0(Case.xy(130, 14));

    // Two triangles sharing the edge (10,60)-(60,60): the top-left fill rule
    // must paint every pixel on it exactly once. A seam or a double-blend
    // here is the single most likely shader bug and it is invisible in a
    // screenshot.
    c.gp0(0x20FFFFFF);
    c.gp0(Case.xy(10, 60));
    c.gp0(Case.xy(60, 60));
    c.gp0(Case.xy(10, 100));
    c.gp0(0x20FF00FF);
    c.gp0(Case.xy(60, 60));
    c.gp0(Case.xy(60, 100));
    c.gp0(Case.xy(10, 100));

    // Degenerate: zero area, drawn nowhere.
    c.gp0(0x20123456);
    c.gp0(Case.xy(70, 60));
    c.gp0(Case.xy(90, 60));
    c.gp0(Case.xy(110, 60));

    // Clipped by the drawing area on all four sides at once.
    c.clip(100, 100, 140, 130);
    c.gp0(0x2000FFFF);
    c.gp0(Case.xy(90, 90));
    c.gp0(Case.xy(160, 95));
    c.gp0(Case.xy(120, 150));
    c.clip(0, 0, 255, 191);

    // A non-zero drawing offset, including a negative one.
    c.offset(30, -5);
    c.gp0(0x20FFFF00);
    c.gp0(Case.xy(150, 20));
    c.gp0(Case.xy(200, 30));
    c.gp0(Case.xy(160, 70));
    c.offset(0, 0);

    // Oversized: 1024 wide, DROPPED rather than clipped. If Phase B clips it
    // instead, this frame's hash moves and nothing else in the corpus notices.
    c.gp0(0x20FF0000);
    c.gp0(Case.xy(-500, 150));
    c.gp0(Case.xy(524, 150));
    c.gp0(Case.xy(0, 180));

    // The four semi-transparency modes over the white triangle drawn above.
    var mode: u32 = 0;
    while (mode < 4) : (mode += 1) {
        c.gp0(0xE1000000 | (mode << 5));
        c.gp0(0x22808080);
        c.gp0(Case.xy(12 + @as(i32, @intCast(mode)) * 12, 62));
        c.gp0(Case.xy(22 + @as(i32, @intCast(mode)) * 12, 62));
        c.gp0(Case.xy(12 + @as(i32, @intCast(mode)) * 12, 98));
    }
    c.gp0(0xE1000000);

    // E6: set-mask on, then a check-mask draw over the pixels it marked.
    c.gp0(0xE6000001);
    c.gp0(0x2000FF7F);
    c.gp0(Case.xy(170, 100));
    c.gp0(Case.xy(210, 100));
    c.gp0(Case.xy(170, 140));
    c.gp0(0xE6000002);
    c.gp0(0x207F00FF);
    c.gp0(Case.xy(160, 95));
    c.gp0(Case.xy(220, 110));
    c.gp0(Case.xy(180, 150));
    c.gp0(0xE6000000);
    try c.endFrame();
```

Frames 1–6 follow the same shape. Write them as:

```zig
    // ---- Frame 1: Gouraud triangles --------------------------------------
    // GP0(30) opaque, GP0(32) semi-transparent. Colours are BGR888 on the
    // wire; the first colour word carries the opcode in its top byte.
    c.gp0(0xE1000000); // dither OFF
    c.gp0(0x300000FF);
    c.gp0(Case.xy(10, 10));
    c.gp0(0x0000FF00);
    c.gp0(Case.xy(90, 20));
    c.gp0(0x00FF0000);
    c.gp0(Case.xy(20, 90));

    // Dither ON (E1 bit 9). The offsets are 8-bit channel units added BEFORE
    // the >> 3 down to 5 bits, which is the thing 900daa0 fixed; a shader
    // that treats them as 5-bit units differs here and only here.
    c.gp0(0xE1000200);
    c.gp0(0x30102030);
    c.gp0(Case.xy(110, 10));
    c.gp0(0x00405060);
    c.gp0(Case.xy(190, 20));
    c.gp0(0x00708090);
    c.gp0(Case.xy(120, 90));

    // A shaded QUAD (GP0(38)), which decomposes into two triangles — the
    // diagonal seam is a real behaviour and must be reproduced, not smoothed.
    c.gp0(0x38FF0000);
    c.gp0(Case.xy(10, 110));
    c.gp0(0x0000FF00);
    c.gp0(Case.xy(90, 110));
    c.gp0(0x000000FF);
    c.gp0(Case.xy(10, 180));
    c.gp0(0x00FFFFFF);
    c.gp0(Case.xy(90, 180));

    // Transparent Gouraud, blend mode 1 (B+F), dither still on.
    c.gp0(0xE1000220);
    c.gp0(0x32404040);
    c.gp0(Case.xy(20, 120));
    c.gp0(0x00808080);
    c.gp0(Case.xy(80, 130));
    c.gp0(0x00C0C0C0);
    c.gp0(Case.xy(30, 170));
    c.gp0(0xE1000000);
    try c.endFrame();

    // ---- Frame 2: textured triangles -------------------------------------
    // Three texture pages are uploaded first: a 4bpp one, an 8bpp one and a
    // 16bpp one, plus a CLUT row. The CLUT deliberately contains a 0 entry
    // (a HOLE — texel == 0 is not drawn at all) and an entry with bit 15 set
    // (STP, which is what gates per-pixel transparency on a textured draw).
    uploadTexturePages(&c);

    c.clip(0, 0, 255, 191);
    c.offset(0, 0);
    c.gp0(0xE2000000); // texture window: no mask, no offset

    // GP0(24): textured triangle, opaque, MODULATED (opcode bit 0 clear).
    // tpage word 0x0000 selects page (0,0) at 4bpp, blend mode 0.
    c.gp0(0x24808080);
    c.gp0(Case.xy(10, 10));
    c.gp0(0x00000000); // clut (0,0) in the high half, u/v in the low
    c.gp0(Case.xy(70, 14));
    c.gp0(0x00000040); // tpage in the high half, u/v in the low
    c.gp0(Case.xy(20, 70));
    c.gp0(0x00004000);

    // GP0(25): RAW textured — opcode bit 0 set, so no modulation at all.
    c.gp0(0x25000000);
    c.gp0(Case.xy(90, 10));
    c.gp0(0x00000000);
    c.gp0(Case.xy(150, 14));
    c.gp0(0x00000040);
    c.gp0(Case.xy(100, 70));
    c.gp0(0x00004000);

    // 8bpp (tpage bit 7) and 16bpp (tpage bit 8) pages.
    c.gp0(0x24FFFFFF);
    c.gp0(Case.xy(10, 90));
    c.gp0(0x00000000);
    c.gp0(Case.xy(70, 94));
    c.gp0(0x00800040);
    c.gp0(Case.xy(20, 150));
    c.gp0(0x00804000);

    c.gp0(0x25000000);
    c.gp0(Case.xy(90, 90));
    c.gp0(0x00000000);
    c.gp0(Case.xy(150, 94));
    c.gp0(0x01000040);
    c.gp0(Case.xy(100, 150));
    c.gp0(0x01004000);

    // A texture window: mask 8, offset 8 on both axes, so u/v wrap inside a
    // 64x64 tile. This is E2 arithmetic the SPRITE path shares but computes
    // differently, which is why frame 4 repeats it.
    c.gp0(0xE2000000 | (8 << 15) | (8 << 10) | (8 << 5) | 8);
    c.gp0(0x24FFFFFF);
    c.gp0(Case.xy(170, 10));
    c.gp0(0x00000000);
    c.gp0(Case.xy(240, 20));
    c.gp0(0x000000FF);
    c.gp0(Case.xy(180, 90));
    c.gp0(0x0000FF00);
    c.gp0(0xE2000000);

    // Semi-transparent textured (GP0(26)): the STP bit of each TEXEL decides
    // per pixel, not the opcode alone.
    c.gp0(0xE1000020); // blend mode 1
    c.gp0(0x26808080);
    c.gp0(Case.xy(170, 100));
    c.gp0(0x00000000);
    c.gp0(Case.xy(240, 110));
    c.gp0(0x00000040);
    c.gp0(Case.xy(180, 170));
    c.gp0(0x00004000);
    c.gp0(0xE1000000);
    try c.endFrame();

    // ---- Frame 3: flat rectangles ----------------------------------------
    c.clip(0, 0, 255, 191);
    c.offset(0, 0);
    c.gp0(0x6000FF00); // GP0(60): variable-size, opaque
    c.gp0(Case.xy(10, 10));
    c.gp0(0x00200030); // 48 x 32

    c.gp0(0x60FF0000); // 1x1 — the smallest thing the box path can emit
    c.gp0(Case.xy(70, 10));
    c.gp0(0x00010001);

    c.gp0(0x700000FF); // GP0(70): fixed 1x1
    c.gp0(Case.xy(74, 10));

    c.gp0(0x7800FFFF); // GP0(78): fixed 8x8
    c.gp0(Case.xy(80, 10));

    c.gp0(0x60FFFFFF); // clipped on all four sides
    c.clip(100, 40, 140, 70);
    c.gp0(Case.xy(90, 30));
    c.gp0(0x00400040);
    c.clip(0, 0, 255, 191);

    c.gp0(0x60123456); // oversized: 1024 wide, DROPPED
    c.gp0(Case.xy(0, 100));
    c.gp0(0x00100400);

    c.gp0(0xE1000040); // blend mode 2 (B-F)
    c.gp0(0x62808080); // GP0(62): semi-transparent
    c.gp0(Case.xy(14, 14));
    c.gp0(0x00180020);
    c.gp0(0xE1000000);

    c.offset(-8, 6); // a negative offset on the rectangle path
    c.gp0(0x6000FFFF);
    c.gp0(Case.xy(170, 20));
    c.gp0(0x00180018);
    c.offset(0, 0);
    try c.endFrame();

    // ---- Frame 4: textured rectangles ------------------------------------
    // The sprite path. Its u/v arithmetic is `tu +% @truncate(xx)` on u8 —
    // a WRAP, not the triangle path's interpolate-and-clamp — so a sprite
    // wider than the distance from tu to 255 reads back round to 0. That is
    // the behaviour with no coverage anywhere in the Phase A2 corpus.
    c.clip(0, 0, 255, 191);
    c.offset(0, 0);
    c.gp0(0xE1000000);
    c.gp0(0xE2000000);

    // tu = 240 with a 32-wide sprite: u runs 240..255 then wraps to 0..15.
    c.gp0(0x64FFFFFF); // GP0(64): variable-size textured, modulated
    c.gp0(Case.xy(10, 10));
    c.gp0(0x0000F000); // clut (0,0), u=0x00 v=0xF0 -> exercise the v wrap too
    c.gp0(0x00200020);

    c.gp0(0x65000000); // RAW (no modulation)
    c.gp0(Case.xy(50, 10));
    c.gp0(0x0000F0F0);
    c.gp0(0x00200020);

    c.gp0(0x7C808080); // GP0(7C): fixed 16x16, modulated
    c.gp0(Case.xy(90, 10));
    c.gp0(0x00001010);

    c.gp0(0x74FFFFFF); // GP0(74): fixed 8x8
    c.gp0(Case.xy(110, 10));
    c.gp0(0x00002020);

    // A texture window on the sprite path.
    c.gp0(0xE2000000 | (8 << 15) | (8 << 10) | (8 << 5) | 8);
    c.gp0(0x64FFFFFF);
    c.gp0(Case.xy(10, 60));
    c.gp0(0x00000000);
    c.gp0(0x00400040);
    c.gp0(0xE2000000);

    // Semi-transparent sprite, blend mode 3 (B + F/4).
    c.gp0(0xE1000060);
    c.gp0(0x66808080);
    c.gp0(Case.xy(70, 60));
    c.gp0(0x00000000);
    c.gp0(0x00300030);
    c.gp0(0xE1000000);

    // Off the left/top edge, so the sprite's own bounds check runs.
    c.gp0(0x64FFFFFF);
    c.gp0(Case.xy(-10, -6));
    c.gp0(0x00000000);
    c.gp0(0x00200020);
    try c.endFrame();

    // ---- Frame 5: lines ---------------------------------------------------
    // All eight octants, so no swapped dx/dy or sign survives. Bresenham's
    // error accumulator has no closed form, which is why the Swift encoder
    // walks the same loop and emits one instance per step.
    c.clip(0, 0, 255, 191);
    c.offset(0, 0);
    c.gp0(0xE1000000);
    const cx: i32 = 128;
    const cy: i32 = 96;
    const ends = [8][2]i32{
        .{ 90, 20 }, .{ 40, 60 }, .{ -40, 60 }, .{ -90, 20 },
        .{ -90, -20 }, .{ -40, -60 }, .{ 40, -60 }, .{ 90, -20 },
    };
    for (ends, 0..) |e, i| {
        c.gp0(0x4000FF00 | (@as(u32, @intCast(i)) << 16));
        c.gp0(Case.xy(cx, cy));
        c.gp0(Case.xy(cx + e[0], cy + e[1]));
    }

    // A zero-length line: steps == 0, and the shaded path must not divide.
    c.gp0(0x40FFFFFF);
    c.gp0(Case.xy(200, 170));
    c.gp0(Case.xy(200, 170));

    // Shaded lines (GP0(50)), rising and falling channels, dither on. The
    // channel at step k is c0 + floor((c1-c0)*k/steps) and (c1-c0) is
    // NEGATIVE on the falling one, so a shader using truncating division
    // instead of a floor differs here.
    c.gp0(0xE1000200);
    c.gp0(0x50000000);
    c.gp0(Case.xy(10, 180));
    c.gp0(0x00FFFFFF);
    c.gp0(Case.xy(240, 186));
    c.gp0(0x50FFFFFF);
    c.gp0(Case.xy(10, 188));
    c.gp0(0x00000000);
    c.gp0(Case.xy(240, 182));
    c.gp0(0xE1000000);

    // A semi-transparent polyline (GP0(42) + the 0x55555555 terminator).
    c.gp0(0xE1000020);
    c.gp0(0x42808080);
    c.gp0(Case.xy(20, 20));
    c.gp0(Case.xy(60, 40));
    c.gp0(Case.xy(30, 70));
    c.gp0(0x55555555);
    c.gp0(0xE1000000);
    try c.endFrame();

    // ---- Frame 6: the feedback loop ---------------------------------------
    // Reads frames 0-5's OWN OUTPUT back as texture data, in the same frame
    // as further draws that overwrite it. This is the shape Task 11's hazard
    // detection exists for: a textured draw whose tpage intersects what the
    // current render pass has already written must end the pass first.
    c.clip(0, 0, 511, 255);
    c.offset(0, 0);
    c.gp0(0xE2000000);

    // Copy a drawn region up into the second texture-page row, then sample it.
    c.gp0(0x80000000);
    c.gp0(Case.xy(0, 0));
    c.gp0(Case.xy(256, 256));
    c.gp0(0x00400040); // 64 x 64

    c.gp0(0x25000000); // 16bpp page at (256,256) -> tpage 0x0114
    c.gp0(Case.xy(300, 20));
    c.gp0(0x00000000);
    c.gp0(Case.xy(380, 30));
    c.gp0(0x0114003F);
    c.gp0(Case.xy(310, 90));
    c.gp0(0x00003F00);

    // Draw INTO that page, then sample it again in the same frame.
    c.gp0(0x6000FF00);
    c.gp0(Case.xy(256, 256));
    c.gp0(0x00200020);
    c.gp0(0x25000000);
    c.gp0(Case.xy(390, 20));
    c.gp0(Case.xy(470, 30));
    c.gp0(0x0114003F);
    c.gp0(Case.xy(400, 90));
    c.gp0(0x00003F00);
    try c.endFrame();

    return c.w.serialize(a);
}
```

with the texture-page upload helper above `build`:

```zig
/// Three texture pages plus a CLUT row, uploaded with GP0(A0).
///
/// The CLUT deliberately contains index 0 == 0x0000 (a HOLE — `texel == 0` is
/// not drawn at all, which is a discard rather than a black pixel) and an
/// entry with bit 15 set (STP, which is what gates per-pixel transparency on
/// a textured draw).
fn uploadTexturePages(c: *Case) void {
    // CLUT at (0, 240): 256 entries so both the 4bpp and 8bpp pages can share
    // it. Entry 0 is the hole; entry 3 carries STP.
    c.gp0(0xA0000000);
    c.gp0(Case.xy(0, 240));
    c.gp0(0x00010100); // 256 x 1
    var i: u32 = 0;
    while (i < 128) : (i += 1) {
        const lo: u16 = clutEntry(@intCast(i * 2));
        const hi: u16 = clutEntry(@intCast(i * 2 + 1));
        c.gp0(@as(u32, lo) | (@as(u32, hi) << 16));
    }

    // 4bpp page at (0, 0): 64 words wide x 64 rows, four texels per word.
    c.gp0(0xA0000000);
    c.gp0(Case.xy(0, 0));
    c.gp0(0x00400040); // 64 x 64
    i = 0;
    while (i < 64 * 64 / 2) : (i += 1) {
        c.gp0(0x1234_5678 +% (i *% 0x0101_0101));
    }

    // 8bpp page at (128, 0): tpage bit 7. Same 64x64 word footprint.
    c.gp0(0xA0000000);
    c.gp0(Case.xy(128, 0));
    c.gp0(0x00400040);
    i = 0;
    while (i < 64 * 64 / 2) : (i += 1) {
        c.gp0(0x0A1B_2C3D +% (i *% 0x0003_0007));
    }

    // 16bpp page at (256, 0): tpage bit 8, so texels are read straight out.
    c.gp0(0xA0000000);
    c.gp0(Case.xy(256, 0));
    c.gp0(0x00400040);
    i = 0;
    while (i < 64 * 64 / 2) : (i += 1) {
        c.gp0(0x7C1F_03E0 +% (i *% 0x0011_0023));
    }
}

fn clutEntry(idx: u8) u16 {
    if (idx == 0) return 0x0000; // the hole
    if (idx == 3) return 0x8000 | 0x1F; // STP set
    return @as(u16, idx) *% 0x0123;
}
```

> The `tpage` words above are the polygon path's third-word high halves. `tpage & 0xF` is the page X in 64-pixel units, bit 4 is page Y (0 or 256), bits 5-6 the blend mode, bits 7-8 the colour depth. `0x0114` is page X = 4 (→ x 256), page Y = 1 (→ y 256), depth 2 (16bpp). Cross-check any word you change against `renderer.zig:455-459`.

- [ ] **Step 2: Wire it into `stream-capture` and the test binary**

In `ps1-golden/src/main.zig`, next to the existing `synthetic.build` call inside the `opts.mode == .stream_capture` block:

```zig
        const prim_bytes = try synthetic_prims.build(a);
        const prim_path = try std.fmt.allocPrint(a, "{s}/synthetic-primitives.p1fx", .{opts.out_dir});
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = prim_path, .data = prim_bytes });
        std.debug.print("  {s: <22} {d} bytes   WRITTEN\n", .{ "synthetic-primitives", prim_bytes.len });
```

with `const synthetic_prims = @import("synthetic_prims.zig");` at the top.

In `build.zig`, add a second anonymous import to `fixture_test`:

```zig
    fixture_test.root_module.addAnonymousImport("committed_primitives", .{
        .root_source_file = b.path("ps1-core/tests/goldens/fixtures/synthetic-primitives.p1fx"),
    });
```

- [ ] **Step 3: Write the failing generator-equality test**

Append to `ps1-golden/src/fixture_test.zig`, mirroring the existing `committed_synthetic` test:

```zig
test "fixture: the committed primitives fixture still matches its generator" {
    // Same contract as the mover fixture's: the committed bytes ARE the
    // generator's output. Phase B's shader tasks gate on this file's per-frame
    // hashes, so a silent regeneration would move the goalposts under them.
    //
    // If this fails, the committed fixture is stale or the core moved. DO NOT
    // regenerate it to make it pass; that is the bug this test exists to catch.
    const a = std.testing.allocator;
    const bytes = try synthetic_prims.build(a);
    defer a.free(bytes);

    try std.testing.expectEqualSlices(u8, @embedFile("committed_primitives"), bytes);
}

test "fixture: the primitives fixture has seven frames in the documented order" {
    // Tasks 6-10 index these by NUMBER. Appending is fine; reordering silently
    // repoints every gate in the plan at the wrong feature.
    const a = std.testing.allocator;
    const bytes = try synthetic_prims.build(a);
    defer a.free(bytes);
    const parsed = try fixture.parse(a, bytes);
    defer parsed.deinit(a);

    try std.testing.expectEqual(@as(usize, 7), parsed.frames.len);

    // Every frame must actually draw something, or the ladder rung it gates
    // proves nothing. Frame hashes are all distinct for the same reason.
    var seen = std.AutoHashMap(u64, void).init(a);
    defer seen.deinit();
    for (parsed.frames) |f| {
        try std.testing.expect(f.record_count > 0);
        try std.testing.expect(!seen.contains(f.vram_hash));
        try seen.put(f.vram_hash, {});
    }
}
```

Add `const synthetic_prims = @import("synthetic_prims.zig");` to that file's imports.

- [ ] **Step 4: Run it and watch it fail for the right reason**

```bash
zig build test 2>&1 | tail -20
```
Expected: FAIL — the committed file does not exist yet, so `@embedFile` cannot resolve and the build errors with `unable to open '...synthetic-primitives.p1fx'`. That is the correct first failure.

- [ ] **Step 5: Generate and commit the fixture**

```bash
zig build trace-golden -Doptimize=ReleaseFast -- stream-capture --filter=__none__ 2>&1 | grep synthetic
cp zig-out/fixtures/synthetic-primitives.p1fx ps1-core/tests/goldens/fixtures/
ls -l ps1-core/tests/goldens/fixtures/
```
A filter matching nothing still writes both synthetic fixtures — that is deliberate (`main.zig:117-127` writes them before the workload loop, and `stream-capture` treats an empty filter as non-fatal). Expected: `synthetic-primitives.p1fx` present, on the order of 100–300 KB. **If it exceeds 2 MB, a texture upload is too large** — shrink the pages in `uploadTexturePages`, do not commit a multi-megabyte fixture.

- [ ] **Step 6: Run the Zig tests**

```bash
zig build test 2>&1 | tail -20
```
Expected: PASS, including both new tests.

- [ ] **Step 7: Add the Swift-side structural check**

Append to `ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift`:

```swift
// MARK: - The primitives ladder (Phase B Task 2)
//
// Committed, so this runs on a fresh clone with no games/ and no
// `zig build fixtures`. ShadowVram cannot check its hashes — every frame is a
// rasterization — so this is structure only until Task 6 starts matching them.

@Test func theCommittedPrimitivesFixtureHasTheDocumentedShape() throws {
    let f = try FixtureFile(contentsOf: FixtureFile.url(named: "synthetic-primitives"))
    #expect(f.frames.count == 7)

    func census(_ i: Int) -> [UInt32: Int] {
        var c: [UInt32: Int] = [:]
        for r in f.records(for: i) { c[r.commandKind.rawValue, default: 0] += 1 }
        return c
    }

    withExtendedLifetime(f) {
        #expect(census(0)[PS1_GPU_DRAW_TRIANGLE.rawValue, default: 0] > 0)
        #expect(census(0)[PS1_GPU_DRAW_SHADED_TRIANGLE.rawValue, default: 0] == 0)
        #expect(census(1)[PS1_GPU_DRAW_SHADED_TRIANGLE.rawValue, default: 0] > 0)
        #expect(census(2)[PS1_GPU_DRAW_TEXTURED_TRIANGLE.rawValue, default: 0] > 0)
        #expect(census(3)[PS1_GPU_DRAW_RECTANGLE.rawValue, default: 0] > 0)
        #expect(census(4)[PS1_GPU_DRAW_TEXTURED_RECTANGLE.rawValue, default: 0] > 0)
        #expect(census(5)[PS1_GPU_DRAW_LINE.rawValue, default: 0] > 0)
        #expect(census(5)[PS1_GPU_DRAW_SHADED_LINE.rawValue, default: 0] > 0)
        #expect(census(6)[PS1_GPU_COPY_RECT.rawValue, default: 0] > 0)
    }
}
```

Frame 0 must contain **no** `draw_shaded_triangle` — that assertion is what makes frame 0 a flat-only gate, which is the whole reason this fixture exists.

- [ ] **Step 8: Run the Swift suite and the freeze gates**

```bash
zig build capi-lib && zig build metallib && ps1-macos/test.sh 2>&1 | tail -30
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
zig build test-roms-pl -Doptimize=ReleaseFast > /tmp/pl.log 2>&1; echo "exit $?"
```
Expected: all green.

- [ ] **Step 9: Commit**

```bash
zig fmt ps1-golden/src/synthetic_prims.zig ps1-golden/src/main.zig ps1-golden/src/fixture_test.zig build.zig
git add ps1-golden/src/synthetic_prims.zig ps1-golden/src/main.zig ps1-golden/src/fixture_test.zig build.zig \
        ps1-core/tests/goldens/fixtures/synthetic-primitives.p1fx \
        ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift
git commit -m "$(cat <<'EOF'
test(fixture): a committed per-feature rasterization fixture

pl-render-polygon's only non-empty frame carries 18 flat AND 6 Gouraud
triangles, so nothing in the Phase A2 corpus can gate a flat-only rasterizer.
This one puts one feature group per frame — flat, Gouraud, textured, rects,
sprites, lines, feedback — and its hashes come from the software rasterizer,
which is what the Metal backend has to match.

Committed rather than generated: the ladder has to work on a fresh clone.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `MetalVram`, the merged metallib, and `--dump-frame`

The render target and the debugging tool, both before there is anything to debug. A hash says *that* a frame diverged, never *where*; building the pixel-wise diff while staring at a red frame 137 is worthless.

**Files:**
- Create: `ps1-macos/Shaders/PrimInstance.h`
- Create: `ps1-macos/Shaders/Rasterizer.metal`
- Modify: `ps1-macos/Shaders/embed.zig`
- Create: `ps1-macos/Sources/CPs1/include/prim_instance_shim.h`
- Create: `ps1-macos/Sources/CPs1/include/metallib.h` (delete `display_metallib.h`)
- Modify: `ps1-macos/Sources/CPs1/include/module.modulemap`
- Create: `ps1-macos/Sources/PS1/Shaders.swift` (delete `DisplayShader.swift`)
- Create: `ps1-macos/Sources/PS1/MetalVram.swift`
- Create: `ps1-macos/Sources/PS1/VramDump.swift`
- Modify: `ps1-macos/Sources/PS1/MetalDisplayView.swift`, `Tests/PS1Tests/DisplayShaderTests.swift`, `Tests/PS1Tests/DisplayRenderTests.swift` (rename only)
- Create: `ps1-macos/Tests/PS1Tests/MetalVramTests.swift`
- Modify: `build.zig`, `ps1-golden/src/main.zig`

**Interfaces:**
- Consumes: `Fnv1a.hash(vram:)` (Phase A2).
- Produces, for every later task:
  - `enum Shaders { static func makeLibrary(_ device: MTLDevice) throws -> MTLLibrary }`
  - `final class MetalVram` with `init?(device: MTLDevice, queue: MTLCommandQueue)`, `let texture: MTLTexture`, `func clear()`, `func upload(_ pixels: [UInt16])`, `func readback() -> [UInt16]`, `var hash: UInt64`
  - `enum VramDump` with `static func url(fixture: String, frame: Int, side: String) -> URL`, `static func write(_ pixels: [UInt16], to url: URL) throws`, `static func read(_ url: URL) -> [UInt16]?`, `static func report(fixture: String, frame: Int, got: [UInt16]) -> String`
  - C symbols `ps1_metallib_ptr()` / `ps1_metallib_len()`
  - `Ps1PrimInstance` and the `PS1_PRIM_*` constants, imported into Swift via `CPs1`
  - `ps1-golden`'s `--dump-frame=<n>`, writing `<out>/<key>-frame<n>.vram`

- [ ] **Step 1: Write the shared instance record**

Create `ps1-macos/Shaders/PrimInstance.h`:

```c
/* The per-primitive instance record: everything one PS1 primitive needs,
 * resolved on the CPU by the encoder and indexed in the shader by
 * `instance_id`.
 *
 * Declared in C, and included by BOTH the Metal compiler and clang-as-C
 * (through the CPs1 module map), for the same reason Ps1GpuCommand is:
 * Swift does not guarantee C-compatible layout for its own structs.
 *
 * Plain `int` / `unsigned int` throughout — NEVER <stdint.h>, which MSL does
 * not ship. Both compilers agree that int is 32 bits on every target this
 * project builds for. Every field is 4 bytes, so the struct's alignment is 4
 * and its stride is exactly 4 * the field count in both languages.
 *
 * Because there is no Metal pipeline state that differs between drawing
 * primitives, a whole run of them is one instanced draw and ordering is
 * preserved by instance index. That is why this record is wide: everything
 * that would otherwise have been encoder state lives here instead.
 */
#ifndef PS1_PRIM_INSTANCE_H
#define PS1_PRIM_INSTANCE_H

enum {
    PS1_PRIM_FLAT_TRI = 0,
    PS1_PRIM_GOURAUD_TRI = 1,
    PS1_PRIM_TEXTURED_TRI = 2,
    PS1_PRIM_RECT = 3,
    PS1_PRIM_TEXTURED_RECT = 4,
    PS1_PRIM_LINE_PIXEL = 5,
    PS1_PRIM_SHADED_LINE_PIXEL = 6,
    PS1_PRIM_FILL = 7,
    PS1_PRIM_UPLOAD = 8,
    PS1_PRIM_COPY = 9
};

#define PS1_PRIM_TRANSPARENT (1u << 0) /* the primitive's own opcode bit */
#define PS1_PRIM_DITHER      (1u << 1) /* GP0(E1) bit 9 */
#define PS1_PRIM_MODULATE    (1u << 2) /* textured opcode bit 0 CLEAR */
#define PS1_PRIM_SET_MASK    (1u << 3) /* GP0(E6) bit 0 */
#define PS1_PRIM_CHECK_MASK  (1u << 4) /* GP0(E6) bit 1 */

typedef struct {
    int kind;

    /* Inclusive pixel box, ALREADY clamped to VRAM. The vertex shader expands
       vertex_id 0..3 into its corners; the fragment shader decides coverage. */
    int box_x0, box_y0, box_x1, box_y1;

    /* Screen-space vertices with GP0(E5)'s offset ALREADY APPLIED. Triangles
       use all six; rectangles and uploads use (x0, y0) as the origin; a line
       pixel uses (x0, y0) as the pixel itself. */
    int x0, y0, x1, y1, x2, y2;

    /* Texture coordinates. Triangles use all six; a textured rectangle uses
       (u0, v0) as its origin texcoord. */
    int u0, v0, u1, v1, u2, v2;

    /* 24-bit BGR as it arrives on the wire — Gouraud triangles and shaded
       lines only. */
    unsigned int c0, c1, c2;

    /* ABGR1555: the flat colour, the modulation colour, or the fill colour. */
    unsigned int color;

    unsigned int clut_x, clut_y, tpage_x, tpage_y, tex_depth;
    unsigned int tex_window; /* raw GP0(E2) */

    /* The drawing area, INCLUSIVE, from GP0(E3)/(E4). Not a scissor rect: a
       scissor is per-encoder state and would break the single instanced draw. */
    int clip_x0, clip_y0, clip_x1, clip_y1;

    unsigned int blend_mode; /* (draw_mode >> 5) & 3 */
    unsigned int flags;

    int k, steps; /* shaded line: the step index and the span length */
    int w, h;     /* rectangle extents, or a transfer's width/height */

    int src_x, src_y; /* copy_rect source origin */

    /* Upload only. `word_base` is chosen so that payload word index
       (word_base + pixel/2) is the word carrying that pixel; `pixel_first` and
       `pixel_last` bound this run's contiguous slice of transfer pixels. */
    int word_base, pixel_first, pixel_last;
} Ps1PrimInstance;

#endif /* PS1_PRIM_INSTANCE_H */
```

Create the module-map shim `ps1-macos/Sources/CPs1/include/prim_instance_shim.h`:

```c
/* Same shim pattern as ps1_shim.h: the header of record lives next to the
   Metal source that consumes it, while SwiftPM's include directory stays the
   module's header root. */
#include "../../../Shaders/PrimInstance.h"
```

- [ ] **Step 2: Write the Metal source with only the vertex function**

Create `ps1-macos/Shaders/Rasterizer.metal`. Tasks 5–10 add the fragment functions; this task adds the vertex stage and a trivial fragment so the pipeline is buildable and the metallib merge is testable.

```metal
#include <metal_stdlib>
#include "PrimInstance.h"
using namespace metal;

static_assert(sizeof(Ps1PrimInstance) == 4 * 42,
              "Ps1PrimInstance layout changed — update the Swift stride test too");

struct PrimVertexOut {
    float4 position [[position]];
    /// `flat`, not interpolated: it is an index, not a quantity.
    uint   iid [[flat]];
};

/// One bounding-box quad per primitive, expanded from vertex_id 0..3 as a
/// triangle strip. The box is INCLUSIVE, so the far edge is +1.
///
/// The GPU rasterizer's only job here is to generate fragments over a
/// conservative box. It is never trusted for coverage: its fill rule and
/// sample positions are not the PS1's, and the disagreement lands exactly on
/// the degenerate triangles that matter.
vertex PrimVertexOut ps1_vertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                uint base [[base_instance]],
                                const device Ps1PrimInstance* prims [[buffer(0)]]) {
    uint index = base + iid;
    const device Ps1PrimInstance& p = prims[index];

    float x = (vid & 1u) ? float(p.box_x1 + 1) : float(p.box_x0);
    float y = (vid & 2u) ? float(p.box_y1 + 1) : float(p.box_y0);

    PrimVertexOut out;
    // 1024 x 512 target: x/512 - 1 and 1 - y/256. Metal's framebuffer origin
    // is top-left, so y is flipped relative to NDC.
    out.position = float4(x / 512.0f - 1.0f, 1.0f - y / 256.0f, 0.0f, 1.0f);
    out.iid = index;
    return out;
}

/// GP0(02). DELIBERATELY unmasked and NOT clipped to the drawing area:
/// hardware ignores GP0(E6) for fills, and `vram.zig:183-198` clips only to
/// VRAM bounds — which the encoder has already folded into the box.
fragment ushort ps1_fill_fragment(PrimVertexOut in [[stage_in]],
                                  const device Ps1PrimInstance* prims [[buffer(0)]]) {
    return ushort(prims[in.iid].color);
}
```

- [ ] **Step 3: Merge both `.metal` sources into one metallib**

In `build.zig`, replace the `metal_ir` / `metal_lib` block:

```zig
    // Both shader sources go into ONE metallib: `metallib` takes several
    // inputs, so the single embedded blob and the single MTLLibrary on the
    // Swift side keep working as the shader count grows.
    const metal_sources = [_][]const u8{
        "ps1-macos/Shaders/DisplayShader.metal",
        "ps1-macos/Shaders/Rasterizer.metal",
    };

    const metal_lib = b.addSystemCommand(&.{ "xcrun", "-sdk", "macosx", "metallib", "-o" });
    const metal_lib_path = metal_lib.addOutputFileArg("ps1.metallib");
    for (metal_sources) |src| {
        const ir = b.addSystemCommand(&.{ "xcrun", "-sdk", "macosx", "metal", "-Werror", "-o" });
        const ir_path = ir.addOutputFileArg(b.fmt("{s}.ir", .{std.fs.path.stem(src)}));
        ir.addArgs(&.{"-c"});
        ir.addFileArg(b.path(src));
        metal_lib.addFileArg(ir_path);
    }
```

and rename the anonymous import:

```zig
    shader_obj.root_module.addAnonymousImport("metallib", .{
        .root_source_file = metal_lib_path,
    });
```

`Rasterizer.metal` `#include`s `PrimInstance.h` from its own directory, so no `-I` flag is needed; the metal compiler resolves quoted includes relative to the including file.

- [ ] **Step 4: Rename the symbol pair**

`ps1-macos/Shaders/embed.zig`: `@embedFile("display_metallib")` → `@embedFile("metallib")`; `ps1_display_metallib_ptr` → `ps1_metallib_ptr`; `ps1_display_metallib_len` → `ps1_metallib_len`. Update the doc comment's first line to "Exposes the offline-compiled Metal shaders to Swift as a byte blob" — it no longer carries only the display shader.

`git mv ps1-macos/Sources/CPs1/include/display_metallib.h ps1-macos/Sources/CPs1/include/metallib.h`, rename the two declarations and the include guard (`PS1_METALLIB_H`), and update `module.modulemap`:

```
module CPs1 {
    header "ps1_shim.h"
    header "metallib.h"
    header "prim_instance_shim.h"
    export *
}
```

`git mv ps1-macos/Sources/PS1/DisplayShader.swift ps1-macos/Sources/PS1/Shaders.swift`, rename `enum DisplayShader` → `enum Shaders`, and update the two `ps1_display_metallib_*` calls. Update the three call sites: `MetalDisplayView.swift:78`, `DisplayShaderTests.swift:15`, `DisplayRenderTests.swift:31`.

- [ ] **Step 5: Write the failing `MetalVram` tests**

Create `ps1-macos/Tests/PS1Tests/MetalVramTests.swift`:

```swift
import Testing
import Metal
@testable import PS1

/// Every Metal test in this suite returns early without a device rather than
/// failing: `MTLCreateSystemDefaultDevice()` is nil on a headless runner, and
/// a red suite there would be noise, not a signal.
private func makeVram() -> (MTLDevice, MTLCommandQueue, MetalVram)? {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return nil }
    return (device, queue, vram)
}

@Test func theRenderTextureStartsBlank() throws {
    guard let (_, _, vram) = makeVram() else { return }
    // A .private texture's initial contents are NOT specified by Metal, so
    // MetalVram clears at init. Without that, every fixture's frame 0 hash is
    // a coin flip on whatever the allocator handed back.
    #expect(vram.hash == Fnv1a.hash(vram: [UInt16](repeating: 0, count: 1024 * 512)))
}

@Test func aTextureRoundTripsThroughUploadReadbackAndHash() throws {
    guard let (_, _, vram) = makeVram() else { return }

    var pixels = [UInt16](repeating: 0, count: 1024 * 512)
    for i in 0..<pixels.count { pixels[i] = UInt16(truncatingIfNeeded: i &* 2654435761) }
    // The four corners specifically: a bytesPerRow or origin mistake in the
    // blit shows up there and can average out anywhere else.
    pixels[0] = 0x8001
    pixels[1023] = 0x7FFE
    pixels[511 * 1024] = 0x1234
    pixels[511 * 1024 + 1023] = 0xABCD

    vram.upload(pixels)
    let back = vram.readback()

    #expect(back.count == pixels.count)
    #expect(back == pixels)
    #expect(vram.hash == Fnv1a.hash(vram: pixels))
}

@Test func clearReturnsTheTextureToZero() throws {
    guard let (_, _, vram) = makeVram() else { return }
    vram.upload([UInt16](repeating: 0xFFFF, count: 1024 * 512))
    #expect(vram.hash != Fnv1a.hash(vram: [UInt16](repeating: 0, count: 1024 * 512)))
    vram.clear()
    #expect(vram.hash == Fnv1a.hash(vram: [UInt16](repeating: 0, count: 1024 * 512)))
}

@Test func theRasterizerVertexFunctionAndFillPipelineBuild() throws {
    guard let (device, _, vram) = makeVram() else { return }
    _ = vram
    let library = try Shaders.makeLibrary(device)
    #expect(library.makeFunction(name: "ps1_vertex") != nil)
    #expect(library.makeFunction(name: "ps1_fill_fragment") != nil)
    // The display shader must still be in the SAME library after the merge.
    #expect(library.makeFunction(name: "display_vertex") != nil)

    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = library.makeFunction(name: "ps1_vertex")
    desc.fragmentFunction = library.makeFunction(name: "ps1_fill_fragment")
    desc.colorAttachments[0].pixelFormat = .r16Uint
    _ = try device.makeRenderPipelineState(descriptor: desc)
}

@Test func theInstanceRecordLayoutIsWhatTheShaderAsserts() {
    // The Metal side carries `static_assert(sizeof(Ps1PrimInstance) == 4 * 42)`.
    // This is the other half of that pair: a field added on one side only is
    // otherwise a silent shear of every instance in the buffer.
    #expect(MemoryLayout<Ps1PrimInstance>.stride == 4 * 42)
    #expect(MemoryLayout<Ps1PrimInstance>.size == 4 * 42)
}

@Test func vramDumpRoundTripsAndReportsTheFirstDifferences() throws {
    var a = [UInt16](repeating: 0, count: 1024 * 512)
    var b = a
    b[5] = 0x1234
    b[1024 + 7] = 0x8000

    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dump.vram")
    defer { try? FileManager.default.removeItem(at: url) }
    try VramDump.write(b, to: url)
    #expect(VramDump.read(url) == b)

    let diffs = VramDump.firstDifferences(a, b, limit: 4)
    #expect(diffs.count == 2)
    #expect(diffs[0].x == 5 && diffs[0].y == 0 && diffs[0].got == 0x1234)
    #expect(diffs[1].x == 7 && diffs[1].y == 1 && diffs[1].got == 0x8000)
    a[5] = 0x1234
    a[1024 + 7] = 0x8000
    #expect(VramDump.firstDifferences(a, b, limit: 4).isEmpty)
}
```

- [ ] **Step 6: Run them and watch them fail**

```bash
zig build capi-lib && zig build metallib && ps1-macos/test.sh 2>&1 | tail -40
```
Expected: a compile failure — `cannot find 'MetalVram' in scope`.

- [ ] **Step 7: Implement `MetalVram`**

Create `ps1-macos/Sources/PS1/MetalVram.swift`:

```swift
import Foundation
import Metal

/// The GPU-side PS1 VRAM: 1024x512 R16Uint, private storage, render target
/// and texture source at once.
///
/// R16Uint and NOT RGBA8 is the decision the whole renderer hangs on. PS1 VRAM
/// is simultaneously framebuffer, texture memory and CLUT storage: a game
/// draws into it and then samples the result as 4bpp, 8bpp or 16bpp indexed
/// data. Storing decoded colour destroys the bit patterns texture sampling
/// depends on, and hides bit 15 — the mask/STP bit that `renderer.zig:36-45`
/// and `vram.zig:83-87` implement carefully.
///
/// This is a DIFFERENT texture from `MetalDisplayView`'s: that one is
/// .shaderRead/.managed and cannot be a render target.
final class MetalVram {
    static let width = 1024
    static let height = 512
    static let pixelCount = width * height

    let device: MTLDevice
    let queue: MTLCommandQueue
    let texture: MTLTexture
    /// Staging for both directions. Shared storage, allocated once: readback
    /// runs per fixture frame and a per-frame 1 MB allocation is pure waste.
    private let staging: MTLBuffer

    init?(device: MTLDevice, queue: MTLCommandQueue) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Uint, width: Self.width, height: Self.height, mipmapped: false)
        // .shaderRead as well as .renderTarget: the same texture is `read()`
        // at arbitrary coordinates by the fragment shader that is drawing into
        // it. That aliasing is legal only under the pass-splitting invariant —
        // nothing sampled during a render pass may have been written during
        // that pass — which the encoder's hazard tracking enforces.
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let texture = device.makeTexture(descriptor: desc),
              let staging = device.makeBuffer(length: Self.pixelCount * 2, options: .storageModeShared)
        else { return nil }

        self.device = device
        self.queue = queue
        self.texture = texture
        self.staging = staging
        clear()
    }

    /// A .private texture's initial contents are unspecified. Every fixture
    /// replay starts from a blank VRAM by the format's own rule
    /// (`fixture.zig`'s FrameEntry doc comment), so this is not hygiene.
    func clear() {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    func upload(_ pixels: [UInt16]) {
        precondition(pixels.count == Self.pixelCount)
        pixels.withUnsafeBytes { src in
            staging.contents().copyMemory(from: src.baseAddress!, byteCount: src.count)
        }
        guard let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { return }
        blit.copy(from: staging, sourceOffset: 0,
                  sourceBytesPerRow: Self.width * 2, sourceBytesPerImage: Self.pixelCount * 2,
                  sourceSize: MTLSize(width: Self.width, height: Self.height, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    func readback() -> [UInt16] {
        guard let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else {
            return [UInt16](repeating: 0, count: Self.pixelCount)
        }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: Self.width, height: Self.height, depth: 1),
                  to: staging, destinationOffset: 0,
                  destinationBytesPerRow: Self.width * 2,
                  destinationBytesPerImage: Self.pixelCount * 2)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        var out = [UInt16](repeating: 0, count: Self.pixelCount)
        out.withUnsafeMutableBytes { dst in
            dst.baseAddress!.copyMemory(from: staging.contents(), byteCount: dst.count)
        }
        return out
    }

    /// FNV-1a 64 over the full 1024x512 as little-endian u16 — the same
    /// convention `ShadowVram` and `fixture.hashVram` already use.
    var hash: UInt64 { Fnv1a.hash(vram: readback()) }
}
```

- [ ] **Step 8: Implement `VramDump`**

Create `ps1-macos/Sources/PS1/VramDump.swift`:

```swift
import Foundation

/// Raw 1 MB VRAM blobs, and the pixel-wise diff that turns "frame 137
/// diverged" into an address.
///
/// The reference side is written by `ps1-golden stream-capture --dump-frame=N`;
/// this side writes its own on mismatch. Built BEFORE there is anything to
/// debug, deliberately — it is worthless to write while staring at a red frame.
enum VramDump {
    struct Difference {
        let x: Int, y: Int, want: UInt16, got: UInt16
    }

    /// Sits next to the fixtures, which are already build artifacts.
    static func url(fixture: String, frame: Int, side: String) -> URL {
        FixtureFile.repoURL
            .appendingPathComponent("zig-out/fixtures")
            .appendingPathComponent("\(fixture)-frame\(frame)\(side.isEmpty ? "" : "-" + side).vram")
    }

    static func write(_ pixels: [UInt16], to url: URL) throws {
        try pixels.withUnsafeBytes { Data($0) }.write(to: url)
    }

    static func read(_ url: URL) -> [UInt16]? {
        guard let data = try? Data(contentsOf: url),
              data.count == MetalVram.pixelCount * 2 else { return nil }
        var out = [UInt16](repeating: 0, count: MetalVram.pixelCount)
        out.withUnsafeMutableBytes { dst in data.copyBytes(to: dst) }
        return out
    }

    static func firstDifferences(_ want: [UInt16], _ got: [UInt16], limit: Int) -> [Difference] {
        var out: [Difference] = []
        for i in 0..<min(want.count, got.count) where want[i] != got[i] {
            out.append(Difference(x: i % MetalVram.width, y: i / MetalVram.width,
                                  want: want[i], got: got[i]))
            if out.count == limit { break }
        }
        return out
    }

    /// The failure message. Writes this side's VRAM unconditionally, and if the
    /// Zig reference dump for that frame is present, lists where they part.
    static func report(fixture: String, frame: Int, got: [UInt16]) -> String {
        let mine = url(fixture: fixture, frame: frame, side: "metal")
        try? write(got, to: mine)
        guard let want = read(url(fixture: fixture, frame: frame, side: "")) else {
            return """
            \(fixture) frame \(frame) diverged. Metal VRAM written to \(mine.path).
            No reference dump — produce one with:
              zig build trace-golden -Doptimize=ReleaseFast -- stream-capture \\
                --filter=\(fixture) --dump-frame=\(frame)
            """
        }
        let diffs = firstDifferences(want, got, limit: 10)
        let total = zip(want, got).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        let lines = diffs.map {
            String(format: "  (%4d,%4d) want %04X got %04X", $0.x, $0.y, $0.want, $0.got)
        }
        return "\(fixture) frame \(frame) diverged: \(total) px\n" + lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 9: Add `--dump-frame` to `ps1-golden`**

In `ps1-golden/src/main.zig`: add `dump_frame: ?u64 = null` to `Options`, parse `--dump-frame=<n>`, document it in `usage` ("(stream-capture) also write frame <n>'s reference VRAM as a raw 1 MB blob to `<out>/<key>-frame<n>.vram`"), and in `runStreamCapture` write the blob right after each `w.addFrame` call:

```zig
/// The reference half of the pixel-wise diff. Raw little-endian u16, row-major,
/// full 1024x512 — no header, because the Swift side reads it into a fixed-size
/// array and a header would be one more thing two languages could disagree on.
fn dumpFrame(a: std.mem.Allocator, io: std.Io, opts: Options, key: []const u8, index: usize, vram: *const ps1.gpu.Vram) !void {
    const n = opts.dump_frame orelse return;
    if (index != n) return;
    const path = try std.fmt.allocPrint(a, "{s}/{s}-frame{d}.vram", .{ opts.out_dir, key, n });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = std.mem.sliceAsBytes(vram.data[0..]) });
    std.debug.print("  {s: <22} frame {d} VRAM dumped\n", .{ key, n });
}
```

called as `try dumpFrame(a, io, opts, wl.key, w.frames.items.len - 1, &bus.gpu.vram);` after each of the two `addFrame` calls — the index is the *kept-frame* ordinal, which is what a `FixtureFile` consumer indexes by.

- [ ] **Step 10: Run everything**

```bash
zig build test
zig build capi-lib && zig build metallib && ps1-macos/test.sh 2>&1 | tail -40
zig build trace-golden -Doptimize=ReleaseFast -- stream-capture --filter=pl-render-polygon --dump-frame=0
ls -l zig-out/fixtures/pl-render-polygon-frame0.vram
```
Expected: Swift suite PASS including all six new tests; the dump is exactly 1,048,576 bytes.

- [ ] **Step 11: Commit**

```bash
zig fmt build.zig ps1-golden/src/main.zig ps1-macos/Shaders/embed.zig
git add -A ps1-macos build.zig ps1-golden/src/main.zig
git commit -m "$(cat <<'EOF'
feat(metal): the R16Uint render texture, a merged metallib, and --dump-frame

MetalVram owns the 1024x512 R16Uint private render texture plus a
blit-to-buffer readback hashed with the existing Fnv1a, so it meets the same
convention ShadowVram already passes.

Both .metal sources now go into ONE metallib — metallib takes several inputs —
so the single embedded blob and the single MTLLibrary keep working. The symbol
pair is renamed ps1_display_metallib_* -> ps1_metallib_*, since it no longer
carries only the display shader.

--dump-frame and VramDump exist before there is anything to debug, on purpose:
a hash says THAT a frame diverged, never where.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `DrawEnv` in Swift

The drawing environment, in front of the movers because they need GP0(E6)'s two mask bits and building a throwaway E6-only path first is rework. Pure value type; no Metal.

**Files:**
- Create: `ps1-macos/Sources/PS1/DrawEnv.swift`
- Create: `ps1-macos/Tests/PS1Tests/DrawEnvTests.swift`

**Interfaces:**
- Consumes: `Ps1GpuCommand` (Phase A2).
- Produces: `struct DrawEnv` with `mutating func apply(_ cmd: Ps1GpuCommand)`, `var offsetX: Int`, `var offsetY: Int`, `var clip: (x0: Int, y0: Int, x1: Int, y1: Int)`, `var ditherEnabled: Bool`, `var blendMode: UInt32`, `var maskSet: Bool`, `var maskCheck: Bool`, `var texWindow: UInt32`, and the six raw registers.

- [ ] **Step 1: Write the failing tests**

Create `ps1-macos/Tests/PS1Tests/DrawEnvTests.swift`:

```swift
import Testing
import CPs1
@testable import PS1

private func env(_ cmds: [(UInt8, UInt32)]) -> DrawEnv {
    var e = DrawEnv()
    for (op, v) in cmds {
        var c = Ps1GpuCommand()
        c.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        c.opcode = op
        c.value = v
        e.apply(c)
    }
    return e
}

@Test func theSixRegistersLandWhereRegistersZigPutsThem() {
    let e = env([(0xE1, 0x0000_02A5), (0xE2, 0x1234), (0xE3, 0x0004_0005),
                 (0xE4, 0x0008_0009), (0xE5, 0x00AB), (0xE6, 3)])
    #expect(e.drawMode == 0x0000_02A5)
    #expect(e.texWindow == 0x1234)
    #expect(e.areaTopLeft == 0x0004_0005)
    #expect(e.areaBotRight == 0x0008_0009)
    #expect(e.offset == 0x00AB)
    #expect(e.maskBit == 3)
    #expect(e.maskSet && e.maskCheck)
    #expect(e.ditherEnabled)              // bit 9 of 0x2A5
    #expect(e.blendMode == 1)             // bits 5-6 of 0x2A5
}

@Test func gp1_09GatesTheTextureDisableBit() {
    // Until the BIOS enables it, E1 bit 11 is forced to 0 wherever it would
    // otherwise be written. This is a real boot-order behaviour, not a
    // formality: a fixture's env-sync prologue replays
    // set_texture_disable_allowed FIRST for exactly this reason.
    var e = DrawEnv()
    var e1 = Ps1GpuCommand()
    e1.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
    e1.opcode = 0xE1
    e1.value = 1 << 11
    e.apply(e1)
    #expect(e.drawMode == 0)

    var allow = Ps1GpuCommand()
    allow.kind = UInt8(PS1_GPU_SET_TEXTURE_DISABLE_ALLOWED.rawValue)
    allow.value = 1
    e.apply(allow)
    e.apply(e1)
    #expect(e.drawMode == 1 << 11)
}

@Test func latchPolygonTexpageWritesOnlyTheNineMaskedBits() {
    // A textured POLYGON copies its texpage attribute into E1 so a later
    // GPUSTAT read sees it. Rectangles do NOT — they use the current texpage
    // instead of carrying one. The mask is 0b0000_1001_1111_1111: texpage x/y,
    // the semi-transparency mode, the colour depth, and texture-disable.
    var e = env([(0xE1, 0xFFFF_FFFF)])
    let before = e.drawMode
    var latch = Ps1GpuCommand()
    latch.kind = UInt8(PS1_GPU_LATCH_TEXPAGE.rawValue)
    latch.tpage = 0x0044        // page x 4, blend mode 2
    e.apply(latch)

    #expect(e.drawMode & 0b0000_1001_1111_1111 == 0x0044)
    #expect(e.drawMode & ~UInt32(0b0000_1001_1111_1111) == before & ~UInt32(0b0000_1001_1111_1111))
    // texture_disable_allowed is still false, so bit 11 stays clear even
    // though 0xFFFFFFFF set it a moment ago... it never did: the E1 write
    // above was masked too.
    #expect(e.drawMode & (1 << 11) == 0)
}

@Test func theDrawingOffsetIsTwoElevenBitSignedFields() {
    // 0x7FF is -1, not 2047. Getting this wrong shifts every primitive in
    // every game by up to 2048 pixels, which reads as "nothing is drawn".
    #expect(env([(0xE5, 0x0000_0000)]).offsetX == 0)
    #expect(env([(0xE5, 0x0000_07FF)]).offsetX == -1)
    #expect(env([(0xE5, 0x0000_0400)]).offsetX == -1024)
    #expect(env([(0xE5, 0x0000_03FF)]).offsetX == 1023)
    #expect(env([(0xE5, 0x07FF << 11)]).offsetY == -1)
    #expect(env([(0xE5, 0x03FF << 11)]).offsetY == 1023)
    #expect(env([(0xE5, (0x400 << 11) | 0x400)]) .offsetY == -1024)
}

@Test func theClipRectIsTwoTenBitFieldsAndIsInclusive() {
    let e = env([(0xE3, (7 << 10) | 3), (0xE4, (200 << 10) | 150)])
    #expect(e.clip.x0 == 3)
    #expect(e.clip.y0 == 7)
    #expect(e.clip.x1 == 150)
    #expect(e.clip.y1 == 200)
}

@Test func resetReturnsEveryRegisterToItsDefault() {
    var e = env([(0xE1, 0xFFFF), (0xE3, 0x1234), (0xE6, 3)])
    var allow = Ps1GpuCommand()
    allow.kind = UInt8(PS1_GPU_SET_TEXTURE_DISABLE_ALLOWED.rawValue)
    allow.value = 1
    e.apply(allow)

    var reset = Ps1GpuCommand()
    reset.kind = UInt8(PS1_GPU_RESET_DRAW_ENV.rawValue)
    e.apply(reset)

    #expect(e.drawMode == 0 && e.areaTopLeft == 0 && e.maskBit == 0)
    #expect(e.textureDisableAllowed == false)
    // The default clip rect is DEGENERATE — area_bot_right is 0, so nothing
    // draws until E3/E4 are programmed. That is why a fixture's window has to
    // carry an env-sync prologue.
    #expect(e.clip.x1 == 0 && e.clip.y1 == 0)
}
```

- [ ] **Step 2: Run and watch it fail**

```bash
ps1-macos/test.sh 2>&1 | tail -20
```
Expected: `cannot find 'DrawEnv' in scope`.

- [ ] **Step 3: Implement**

Create `ps1-macos/Sources/PS1/DrawEnv.swift`:

```swift
import Foundation
import CPs1

/// GP0(E1)-(E6) plus GP1(09), mirroring `ps1-core/src/gpu/registers.zig`'s
/// `DrawingEnv`.
///
/// A second transcription, accepted knowingly: the encoder needs the resolved
/// values on the CPU to write them into each instance record, and reaching
/// into the Zig struct across the C ABI would make the layout of an internal
/// type part of the contract. It is 60 lines of pure bit arithmetic with no
/// state machine in it, and the fixture ladder checks it end to end.
struct DrawEnv {
    var drawMode: UInt32 = 0      // E1
    var texWindow: UInt32 = 0     // E2
    var areaTopLeft: UInt32 = 0   // E3
    var areaBotRight: UInt32 = 0  // E4
    var offset: UInt32 = 0        // E5
    var maskBit: UInt32 = 0       // E6

    /// GP1(09): until the BIOS enables it, E1 bit 11 is forced to 0 wherever
    /// it would otherwise be written.
    var textureDisableAllowed = false

    /// E1 bits a textured polygon's texpage word writes through: texpage x/y,
    /// semi-transparency mode, texture colour depth (bits 0-8) and texture
    /// disable (bit 11).
    static let e1TexpageMask: UInt32 = 0b0000_1001_1111_1111

    mutating func apply(_ cmd: Ps1GpuCommand) {
        switch cmd.commandKind {
        case PS1_GPU_SET_DRAW_ENV:
            switch cmd.opcode {
            case 0xE1: drawMode = maskTextureDisable(cmd.value)
            case 0xE2: texWindow = cmd.value
            case 0xE3: areaTopLeft = cmd.value
            case 0xE4: areaBotRight = cmd.value
            case 0xE5: offset = cmd.value
            case 0xE6: maskBit = cmd.value
            default: break
            }
        case PS1_GPU_LATCH_TEXPAGE:
            let new = maskTextureDisable(UInt32(cmd.tpage) & Self.e1TexpageMask)
            drawMode = (drawMode & ~Self.e1TexpageMask) | new
        case PS1_GPU_SET_TEXTURE_DISABLE_ALLOWED:
            textureDisableAllowed = cmd.value != 0
        case PS1_GPU_RESET_DRAW_ENV:
            self = DrawEnv()
        default:
            break
        }
    }

    private func maskTextureDisable(_ v: UInt32) -> UInt32 {
        textureDisableAllowed ? v : v & ~(UInt32(1) << 11)
    }

    /// Two 11-bit SIGNED fields. 0x7FF is -1, not 2047.
    var offsetX: Int { Self.sext11(offset & 0x7FF) }
    var offsetY: Int { Self.sext11((offset >> 11) & 0x7FF) }

    private static func sext11(_ v: UInt32) -> Int {
        let x = Int(v)
        return x >= 0x400 ? x - 0x800 : x
    }

    /// The drawing area, INCLUSIVE on both ends. Two 10-bit fields per
    /// register, x in the low half.
    var clip: (x0: Int, y0: Int, x1: Int, y1: Int) {
        (Int(areaTopLeft & 0x3FF), Int((areaTopLeft >> 10) & 0x3FF),
         Int(areaBotRight & 0x3FF), Int((areaBotRight >> 10) & 0x3FF))
    }

    var ditherEnabled: Bool { (drawMode & (1 << 9)) != 0 }
    var blendMode: UInt32 { (drawMode >> 5) & 3 }
    var maskSet: Bool { (maskBit & 1) != 0 }
    var maskCheck: Bool { (maskBit & 2) != 0 }
}
```

- [ ] **Step 4: Run**

```bash
ps1-macos/test.sh 2>&1 | tail -20
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ps1-macos/Sources/PS1/DrawEnv.swift ps1-macos/Tests/PS1Tests/DrawEnvTests.swift
git commit -m "$(cat <<'EOF'
feat(metal): DrawEnv, the Swift mirror of registers.zig

E1-E6, GP1(09)'s texture-disable gate, latchPolygonTexpage's nine masked bits,
the two 11-bit signed offset fields and the inclusive clip rect. The encoder
resolves all of this on the CPU and writes it into each instance record, which
is what leaves no Metal pipeline state differing between primitives.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: The movers as GPU passes, and the aliasing probe

`fill_rect`, `copy_rect` and the `vram_write_setup`/`_data`/`_abort` FSM must run on the GPU texture too — at 1× the shadow is authoritative for readback, but the GPU texture is what the GPU samples, so it has to be complete.

This task also settles the design's **one foundational risk**: whether a texture bound as `[[color(0)]]` can be `read()` at another coordinate by the same draw. Everything downstream assumes it holds, so it is checked here rather than at the end.

**Files:**
- Create: `ps1-macos/Sources/PS1/VramTransfer.swift`
- Modify: `ps1-macos/Sources/PS1/ShadowVram.swift`
- Create: `ps1-macos/Sources/PS1/MetalRasterizer.swift`
- Modify: `ps1-macos/Shaders/Rasterizer.metal`
- Create: `ps1-macos/Tests/PS1Tests/MetalFixtureHarness.swift` (shared by Tasks 5–11)
- Create: `ps1-macos/Tests/PS1Tests/MetalMoverTests.swift`

**Interfaces:**
- Consumes: `MetalVram`, `VramDump`, `DrawEnv`, `Ps1PrimInstance`, `Shaders.makeLibrary`.
- Produces:
  - `struct VramTransfer` — `static func axisExtent(_ size: Int, _ full: Int) -> Int`, `mutating func setup(x:y:w:h:)`, `mutating func abort()`, `mutating func consume(_ value: UInt32) -> VramTransfer.WordPixels`, `mutating func plan(words: Int) -> (first: Int, last: Int, consumed: Int)?`, and `active`/`x`/`y`/`w`/`h`/`pixelCount`.
  - `final class MetalRasterizer` — `init(vram: MetalVram) throws`, `func beginFrame(payload: UnsafeBufferPointer<UInt32>)`, `func apply(_ cmd: Ps1GpuCommand)`, `func endFrame()`, `private(set) var env: DrawEnv`, `private(set) var passCount: Int`, `private(set) var sawUnmodelledKind: Bool`.
  - `MetalFixtureHarness.replay(_ name: String, upTo: Int?) throws -> ReplayResult` for the test target.
  - Metal: `ps1_upload_fragment`, `ps1_copy_fragment`.

- [ ] **Step 1: Write the failing `VramTransfer` tests**

Create `ps1-macos/Tests/PS1Tests/MetalMoverTests.swift` and start with the FSM, which has no Metal in it:

```swift
import Testing
import Foundation
import Metal
import CPs1
@testable import PS1

// MARK: - The extracted GP0(A0) transfer FSM
//
// ShadowVram and the Metal encoder both need this, and the spec's "no THIRD
// transcription" rule is the whole reason it is extracted rather than copied.
// ShadowVram's own tests in FixtureBridgeTests.swift are the regression net for
// the extraction itself.

@Test func aZeroExtentMeansTheWholeAxis() {
    #expect(VramTransfer.axisExtent(0, 1024) == 1024)
    #expect(VramTransfer.axisExtent(0, 512) == 512)
    #expect(VramTransfer.axisExtent(7, 1024) == 7)
}

@Test func eachWordIsTwoPixelsInRowMajorOrder() {
    var t = VramTransfer()
    t.setup(x: 10, y: 20, w: 3, h: 2)
    #expect(t.active)
    #expect(t.pixelCount == 6)

    let a = t.consume(0x2222_1111)
    #expect(a.count == 2)
    #expect(a[0] == (10, 20, 0x1111))
    #expect(a[1] == (11, 20, 0x2222))

    let b = t.consume(0x4444_3333)
    #expect(b[0] == (12, 20, 0x3333))
    #expect(b[1] == (10, 21, 0x4444))   // wrapped to the next row
}

@Test func anOddSizedTransferDropsTheFinalHalfWord() {
    var t = VramTransfer()
    t.setup(x: 0, y: 0, w: 3, h: 1)
    _ = t.consume(0x2222_1111)
    let last = t.consume(0x4444_3333)
    #expect(last.count == 1)            // 0x4444 is dropped
    #expect(last[0] == (2, 0, 0x3333))
    #expect(t.active == false)
}

@Test func wordsAfterTheTransferEndsAreIgnored() {
    var t = VramTransfer()
    t.setup(x: 0, y: 0, w: 2, h: 1)
    _ = t.consume(0x2222_1111)
    #expect(t.active == false)
    #expect(t.consume(0xDEAD_BEEF).count == 0)
}

@Test func abortStopsTheTransferMidFlight() {
    var t = VramTransfer()
    t.setup(x: 0, y: 0, w: 8, h: 8)
    _ = t.consume(0)
    t.abort()
    #expect(t.active == false)
    #expect(t.consume(0xFFFF_FFFF).count == 0)
}

@Test func planReportsTheContiguousPixelRunAWordBatchCovers() {
    // The GPU path never walks pixel by pixel: it turns a whole payload run
    // into ONE instance whose fragment maps each pixel back to its word.
    var t = VramTransfer()
    t.setup(x: 4, y: 8, w: 5, h: 3)     // 15 pixels, 8 words
    let a = t.plan(words: 3)
    #expect(a?.first == 0 && a?.last == 5 && a?.consumed == 3)
    let b = t.plan(words: 100)          // clamped to the 5 words remaining
    #expect(b?.first == 6 && b?.last == 14 && b?.consumed == 5)
    #expect(t.active == false)
    #expect(t.plan(words: 1) == nil)
}

@Test func planAndConsumeAgreeOnWhereTheCursorEndsUp() {
    // The two APIs are the ONE place the shadow and the GPU encoder could
    // silently disagree, so pin them against each other directly.
    for (w, h) in [(3, 2), (5, 3), (1, 1), (7, 1), (2, 4)] {
        var byWord = VramTransfer()
        var byPlan = VramTransfer()
        byWord.setup(x: 0, y: 0, w: w, h: h)
        byPlan.setup(x: 0, y: 0, w: w, h: h)
        var pixels = 0
        while byWord.active { pixels += byWord.consume(0).count }
        var planned = 0
        while let r = byPlan.plan(words: 1) { planned += r.last - r.first + 1 }
        #expect(pixels == planned, "w=\(w) h=\(h)")
        #expect(pixels == w * h)
    }
}
```

- [ ] **Step 2: Run and watch it fail**

```bash
ps1-macos/test.sh 2>&1 | tail -20
```
Expected: `cannot find 'VramTransfer' in scope`.

- [ ] **Step 3: Implement `VramTransfer` and re-point `ShadowVram` at it**

Create `ps1-macos/Sources/PS1/VramTransfer.swift`:

```swift
import Foundation

/// The CPU->VRAM (GP0(A0)) transfer FSM, mirroring `vram.zig:51-115`.
///
/// Extracted so `ShadowVram` and the Metal encoder share ONE transcription.
/// Phase B is a second rasterizer by necessity, and the spec's mitigation is
/// that no THIRD one appears — this is that mitigation, made structural.
///
/// It owns the cursor and nothing else: bounds checking and the E6 mask belong
/// to whoever does the writing, because the shadow clips in Swift and the GPU
/// clips by construction of the instance box.
struct VramTransfer {
    /// The pixels one 32-bit word produces: two, or one when the second would
    /// fall past the end of an odd-sized transfer. Returned by value rather
    /// than through a closure so the caller can mutate its own storage without
    /// an exclusivity conflict against the transfer it is driving.
    struct WordPixels {
        private(set) var count = 0
        private var xs = (0, 0)
        private var ys = (0, 0)
        private var vs: (UInt16, UInt16) = (0, 0)

        subscript(i: Int) -> (x: Int, y: Int, value: UInt16) {
            i == 0 ? (xs.0, ys.0, vs.0) : (xs.1, ys.1, vs.1)
        }

        fileprivate mutating func append(_ x: Int, _ y: Int, _ v: UInt16) {
            if count == 0 { xs.0 = x; ys.0 = y; vs.0 = v } else { xs.1 = x; ys.1 = y; vs.1 = v }
            count += 1
        }
    }

    private(set) var active = false
    private(set) var x = 0, y = 0, w = 0, h = 0
    /// Pixel index within the transfer. `currX`/`currY` are derived from it,
    /// which is exactly `vram.zig`'s wrap-at-write_w behaviour with one
    /// variable instead of two.
    private var cursor = 0
    private var remaining = 0

    /// A transfer's width and height are taken modulo the VRAM axis, so 0
    /// means the WHOLE AXIS rather than an empty rectangle.
    static func axisExtent(_ size: Int, _ full: Int) -> Int { size == 0 ? full : size }

    var currX: Int { w == 0 ? 0 : cursor % w }
    var currY: Int { w == 0 ? 0 : cursor / w }
    var pixelCount: Int { w * h }

    mutating func setup(x: Int, y: Int, w: Int, h: Int) {
        self.w = Self.axisExtent(w, 1024)
        self.h = Self.axisExtent(h, 512)
        self.x = x
        self.y = y
        cursor = 0
        remaining = (self.w * self.h + 1) / 2
        active = remaining > 0
    }

    mutating func abort() { active = false }

    mutating func consume(_ value: UInt32) -> WordPixels {
        var out = WordPixels()
        guard active else { return out }
        out.append(x + currX, y + currY, UInt16(truncatingIfNeeded: value))
        cursor += 1
        if cursor < pixelCount {
            out.append(x + currX, y + currY, UInt16(truncatingIfNeeded: value >> 16))
            cursor += 1
        }
        if remaining > 0 { remaining -= 1 }
        if remaining == 0 { active = false }
        return out
    }

    /// Advances by up to `words` words in one go and reports the contiguous
    /// slice of transfer PIXEL INDICES that run covers. A run always starts on
    /// an even pixel index, because every word writes two, which is what lets
    /// the shader recover the word from the pixel with a single shift.
    mutating func plan(words n: Int) -> (first: Int, last: Int, consumed: Int)? {
        guard active, n > 0 else { return nil }
        let first = cursor
        let consumed = min(n, remaining)
        let after = min(first + 2 * consumed, pixelCount)
        cursor = after
        remaining -= consumed
        if remaining == 0 { active = false }
        guard after > first else { return nil }
        return (first, after - 1, consumed)
    }
}
```

Then in `ShadowVram.swift`, delete the six transfer fields and `setupWrite`/`writePixel`/`writeData`, add `private var transfer = VramTransfer()`, and rewrite the three arms:

```swift
        case PS1_GPU_VRAM_WRITE_SETUP:
            transfer.setup(x: Int(cmd.x), y: Int(cmd.y), w: Int(cmd.w), h: Int(cmd.h))

        case PS1_GPU_VRAM_WRITE_DATA:
            // These two record fields become memory indices, and
            // UnsafeBufferPointer's subscript is _debugPrecondition-checked
            // only: in a Release build a malformed record would read past the
            // buffer silently. FixtureFile validates each FRAME's slice against
            // the file totals but never a RECORD's offsets within its frame,
            // so this is where that check has to live.
            let off = Int(cmd.x), len = Int(cmd.y)
            guard off >= 0, len >= 0, off + len <= payload.count else { return }
            for k in off..<(off + len) {
                let pixels = transfer.consume(payload[k])
                for i in 0..<pixels.count {
                    let p = pixels[i]
                    // The Zig source only checks the upper bound because its
                    // coordinates are usize and can't go negative. Swift's are
                    // Int, so a negative setup needs an explicit lower bound.
                    if p.x >= 0, p.x < Self.width, p.y >= 0, p.y < Self.height {
                        maskedWrite(p.x, p.y, p.value)
                    }
                }
            }

        case PS1_GPU_VRAM_WRITE_ABORT:
            transfer.abort()
```

Keep `ShadowVram.axisExtent` for `copy`, or switch it to `VramTransfer.axisExtent` — do the latter and delete the private copy.

- [ ] **Step 4: Run — the FSM tests and every existing ShadowVram test must pass**

```bash
ps1-macos/test.sh 2>&1 | tail -30
```
Expected: PASS, including `replaysTheSyntheticFixtureAndMatchesEveryHash`, `anOddSizedTransferDropsTheFinalHalfWord`, `vramWriteHonoursTheMaskSetBit` and `replaysTheCrocFixtureAndMatchesEveryHash`. Those four are the regression net for the extraction; if any goes red, the FSM moved rather than being extracted.

- [ ] **Step 5: Add the two mover fragment functions**

Append to `ps1-macos/Shaders/Rasterizer.metal`:

```metal
/// GP0(A0). The payload run is a device buffer; this maps each covered pixel
/// back to the word carrying it. `word_base` is pre-biased by the encoder so
/// that `word_base + pixel/2` is that word, with the parity selecting the half.
///
/// Respects the E6 mask, unlike the fill above — `vram.zig` routes CPU->VRAM
/// through `maskedWrite` and Fill Rectangle around it.
fragment ushort ps1_upload_fragment(PrimVertexOut in [[stage_in]],
                                    ushort dst [[color(0)]],
                                    const device Ps1PrimInstance* prims [[buffer(0)]],
                                    const device uint* words [[buffer(1)]]) {
    const device Ps1PrimInstance& p = prims[in.iid];
    int px = int(in.position.x);
    int py = int(in.position.y);

    // The box spans whole rows, so the first and last rows of a run are
    // partial and are trimmed here rather than by more instances.
    int pix = (py - p.y0) * p.w + (px - p.x0);
    if (pix < p.pixel_first || pix > p.pixel_last) { discard_fragment(); return 0; }
    if ((p.flags & PS1_PRIM_CHECK_MASK) && (dst & 0x8000)) { discard_fragment(); return 0; }

    uint word = words[p.word_base + (pix >> 1)];
    ushort v = ushort((pix & 1) ? (word >> 16) : word);
    if (p.flags & PS1_PRIM_SET_MASK) v |= 0x8000;
    return v;
}

/// GP0(80). Masked, and WRAPS on both axes rather than clipping.
///
/// `scratch` is a snapshot of VRAM taken at the pass boundary just before this
/// draw, which is what makes `vram.zig:154`'s backwards-iteration branch
/// unnecessary: a self-overlapping copy reads a frozen source, so the
/// direction question disappears instead of having to be reproduced.
fragment ushort ps1_copy_fragment(PrimVertexOut in [[stage_in]],
                                  ushort dst [[color(0)]],
                                  const device Ps1PrimInstance* prims [[buffer(0)]],
                                  texture2d<ushort, access::read> scratch [[texture(0)]]) {
    const device Ps1PrimInstance& p = prims[in.iid];
    int px = int(in.position.x);
    int py = int(in.position.y);

    // The destination wraps, so the encoder splits it into up to four boxes
    // and this recovers the in-rect offset by the same modular arithmetic.
    int xx = (px - p.x0) & 0x3FF;
    int yy = (py - p.y0) & 0x1FF;
    if (xx >= p.w || yy >= p.h) { discard_fragment(); return 0; }
    if ((p.flags & PS1_PRIM_CHECK_MASK) && (dst & 0x8000)) { discard_fragment(); return 0; }

    ushort v = scratch.read(uint2(uint((p.src_x + xx) & 0x3FF),
                                  uint((p.src_y + yy) & 0x1FF))).r;
    if (p.flags & PS1_PRIM_SET_MASK) v |= 0x8000;
    return v;
}
```

- [ ] **Step 6: Write the aliasing probe and the fixture gates**

Append to `ps1-macos/Tests/PS1Tests/MetalMoverTests.swift`:

```swift
// MARK: - The foundational risk (spec § The feedback loop)
//
// Everything downstream assumes a texture bound as [[color(0)]] can be read()
// at a DIFFERENT coordinate by the same draw, and that such a read sees the
// PRE-PASS contents. That is what a tile-based GPU gives: the tile being
// rendered lives in tile memory and the rest of the attachment stays in device
// memory until the store action runs. If this test ever fails, the named
// fallback is a second .private texture holding the last committed VRAM,
// refreshed by a blit at each pass boundary and sampled instead of the
// attachment — a substitution behind MetalRasterizer's interface, not a
// redesign.

@Test func aTextureBoundAsAttachmentCanBeReadAtAnotherCoordinate() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }

    var pixels = [UInt16](repeating: 0, count: MetalVram.pixelCount)
    for i in 0..<64 { pixels[500 * 1024 + 100 + i] = UInt16(0x1000 + i) }
    vram.upload(pixels)

    let library = try Shaders.makeLibrary(device)
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = library.makeFunction(name: "ps1_vertex")
    desc.fragmentFunction = library.makeFunction(name: "ps1_copy_fragment")
    desc.colorAttachments[0].pixelFormat = .r16Uint
    let pipeline = try device.makeRenderPipelineState(descriptor: desc)

    // Copy (100,500)-(163,500) to (0,0)-(63,0), reading THE ATTACHMENT ITSELF
    // rather than a scratch snapshot. The source row was written by an earlier
    // command buffer, so the invariant holds and the read must be exact.
    var inst = Ps1PrimInstance()
    inst.kind = PS1_PRIM_COPY
    inst.box_x0 = 0; inst.box_y0 = 0; inst.box_x1 = 63; inst.box_y1 = 0
    inst.x0 = 0; inst.y0 = 0
    inst.src_x = 100; inst.src_y = 500
    inst.w = 64; inst.h = 1

    let buffer = device.makeBuffer(bytes: &inst,
                                   length: MemoryLayout<Ps1PrimInstance>.stride,
                                   options: .storageModeShared)!

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = vram.texture
    pass.colorAttachments[0].loadAction = .load
    pass.colorAttachments[0].storeAction = .store

    guard let cmd = queue.makeCommandBuffer(),
          let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
    enc.setRenderPipelineState(pipeline)
    enc.setVertexBuffer(buffer, offset: 0, index: 0)
    enc.setFragmentBuffer(buffer, offset: 0, index: 0)
    enc.setFragmentTexture(vram.texture, index: 0)
    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                       instanceCount: 1, baseInstance: 0)
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()

    let back = vram.readback()
    for i in 0..<64 {
        #expect(back[i] == UInt16(0x1000 + i), "attachment-as-read-source failed at \(i)")
    }
}

// MARK: - The mover gate
//
// synthetic-movers is committed, so this runs on a fresh clone. Croc is the one
// real-game fixture at real payload sizes — 200 frames, 1,014 transfers, 50
// fills — and it is generated from games/, so it skips when absent.

@Test func replaysTheSyntheticMoverFixtureOnTheGpu() throws {
    guard let r = try MetalFixtureHarness.replay("synthetic-movers") else { return }
    #expect(r.framesChecked == 6)
    #expect(r.firstDivergence == nil, r.message)
}

@Test(.enabled(if: FileManager.default.fileExists(
                    atPath: FixtureFile.url(named: "croc-legend-of-the-gobbos").path),
               "croc-legend-of-the-gobbos.p1fx is generated from games/ — run `zig build fixtures -Doptimize=ReleaseFast`"))
func replaysTheCrocMoverFixtureOnTheGpu() throws {
    guard let r = try MetalFixtureHarness.replay("croc-legend-of-the-gobbos") else { return }
    #expect(r.framesChecked == 200)
    #expect(r.firstDivergence == nil, r.message)
}
```

- [ ] **Step 7: Write the shared harness**

Create `ps1-macos/Tests/PS1Tests/MetalFixtureHarness.swift`:

```swift
import Foundation
import Metal
@testable import PS1

/// Drives a `.p1fx` through `MetalRasterizer` frame by frame and compares the
/// GPU VRAM hash against the fixture's own.
///
/// Returns nil rather than failing when there is no Metal device: a headless
/// runner would otherwise turn the whole suite red for no signal.
enum MetalFixtureHarness {
    struct ReplayResult {
        let framesChecked: Int
        let firstDivergence: Int?
        let passCount: Int
        let message: String
    }

    /// `upTo` bounds the replay to the first N frames — the gate ladder in
    /// Tasks 6-10 walks `synthetic-primitives` one frame at a time, because a
    /// hash is cumulative and a later frame's mismatch would otherwise mask an
    /// earlier feature that already works.
    static func replay(_ name: String, upTo: Int? = nil) throws -> ReplayResult? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let vram = MetalVram(device: device, queue: queue) else { return nil }

        let fixture = try FixtureFile(contentsOf: FixtureFile.url(named: name))
        let renderer = try MetalRasterizer(vram: vram)
        let count = min(upTo ?? fixture.frames.count, fixture.frames.count)

        var result: ReplayResult?
        withExtendedLifetime(fixture) {
            for i in 0..<count {
                let payload = fixture.payload(for: i)
                renderer.beginFrame(payload: payload)
                for cmd in fixture.records(for: i) { renderer.apply(cmd) }
                renderer.endFrame()

                if vram.hash != fixture.frames[i].vramHash {
                    result = ReplayResult(
                        framesChecked: i + 1,
                        firstDivergence: i,
                        passCount: renderer.passCount,
                        message: VramDump.report(fixture: name, frame: i, got: vram.readback()))
                    return
                }
            }
            result = ReplayResult(framesChecked: count, firstDivergence: nil,
                                  passCount: renderer.passCount,
                                  message: "\(name): \(count) frames, \(renderer.passCount) passes")
        }
        return result
    }
}
```

- [ ] **Step 8: Implement `MetalRasterizer`**

Create `ps1-macos/Sources/PS1/MetalRasterizer.swift`. Tasks 6–10 extend `apply` and add `PrimBuilder`; this task lands the encoder, the four pipelines and the three movers.

```swift
import Foundation
import Metal
import CPs1

/// Turns a recorded GP0 command stream into Metal work against a `MetalVram`.
///
/// Every primitive is one INSTANCE of a bounding-box quad, with all its state
/// resolved here on the CPU and written into a `Ps1PrimInstance`. Because no
/// pipeline state differs between drawing primitives, a whole run of them is
/// one instanced draw and ordering is preserved by instance index — the only
/// thing that ends a run is a hazard.
///
/// Allocation on this path is fine: Phase B is fixture-driven and never runs
/// on the emulator thread. Phase D owns the no-allocation requirement.
final class MetalRasterizer {
    enum Error: Swift.Error { case missingFunction(String) }

    private enum Step {
        case draw(kind: DrawKind, range: Range<Int>)
        /// Blit VRAM into `scratch`. Forces a pass boundary: a blit cannot be
        /// encoded inside a render pass.
        case snapshot
        case passBreak
    }

    private enum DrawKind { case prim, fill, upload, copy }

    let vram: MetalVram
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: [DrawKind: MTLRenderPipelineState]
    private let scratch: MTLTexture

    private(set) var env = DrawEnv()
    private(set) var passCount = 0
    /// Set once `apply` meets a record this backend does not model, mirroring
    /// `ShadowVram.sawUnmodelledKind`: without it a fixture carrying an
    /// unhandled kind replays to a wrong hash with nothing to say why.
    private(set) var sawUnmodelledKind = false

    private var transfer = VramTransfer()
    private var instances: [Ps1PrimInstance] = []
    private var steps: [Step] = []
    private var payloadBuffer: MTLBuffer?

    init(vram: MetalVram) throws {
        self.vram = vram
        self.device = vram.device
        self.queue = vram.queue

        let library = try Shaders.makeLibrary(device)
        func pipeline(_ fragment: String) throws -> MTLRenderPipelineState {
            guard let vs = library.makeFunction(name: "ps1_vertex") else {
                throw Error.missingFunction("ps1_vertex")
            }
            guard let fs = library.makeFunction(name: fragment) else {
                throw Error.missingFunction(fragment)
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vs
            desc.fragmentFunction = fs
            desc.colorAttachments[0].pixelFormat = .r16Uint
            return try device.makeRenderPipelineState(descriptor: desc)
        }
        pipelines = [
            .prim: try pipeline("ps1_prim_fragment"),
            .fill: try pipeline("ps1_fill_fragment"),
            .upload: try pipeline("ps1_upload_fragment"),
            .copy: try pipeline("ps1_copy_fragment"),
        ]

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Uint, width: MetalVram.width, height: MetalVram.height,
            mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .private
        guard let scratch = device.makeTexture(descriptor: desc) else {
            throw Error.missingFunction("scratch texture")
        }
        self.scratch = scratch
    }

    // MARK: - Frame lifecycle

    func beginFrame(payload: UnsafeBufferPointer<UInt32>) {
        instances.removeAll(keepingCapacity: true)
        steps.removeAll(keepingCapacity: true)
        // Metal rejects a zero-length buffer, and an empty payload is the
        // common case (only A0 frames have one).
        let bytes = max(payload.count * 4, 4)
        payloadBuffer = device.makeBuffer(length: bytes, options: .storageModeShared)
        if let base = payload.baseAddress, payload.count > 0 {
            payloadBuffer?.contents().copyMemory(from: base, byteCount: payload.count * 4)
        }
    }

    func endFrame() {
        defer {
            instances.removeAll(keepingCapacity: true)
            steps.removeAll(keepingCapacity: true)
        }
        guard !steps.isEmpty, !instances.isEmpty else { return }
        guard let cmd = queue.makeCommandBuffer() else { return }
        let instanceBuffer = device.makeBuffer(
            bytes: instances,
            length: instances.count * MemoryLayout<Ps1PrimInstance>.stride,
            options: .storageModeShared)

        var encoder: MTLRenderCommandEncoder?
        func closePass() {
            encoder?.endEncoding()
            encoder = nil
        }
        func openPass() -> MTLRenderCommandEncoder? {
            if let e = encoder { return e }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = vram.texture
            // .load, never .clear: VRAM persists across frames, and every
            // pass after the first in a frame must see the previous one's work.
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
            guard let e = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            e.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
            e.setFragmentBuffer(instanceBuffer, offset: 0, index: 0)
            if let p = payloadBuffer { e.setFragmentBuffer(p, offset: 0, index: 1) }
            encoder = e
            passCount += 1
            return e
        }

        for step in steps {
            switch step {
            case .passBreak:
                closePass()
            case .snapshot:
                closePass()
                if let blit = cmd.makeBlitCommandEncoder() {
                    blit.copy(from: vram.texture, sourceSlice: 0, sourceLevel: 0,
                              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                              sourceSize: MTLSize(width: MetalVram.width,
                                                  height: MetalVram.height, depth: 1),
                              to: scratch, destinationSlice: 0, destinationLevel: 0,
                              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                    blit.endEncoding()
                }
            case let .draw(kind, range):
                guard !range.isEmpty, let e = openPass(), let state = pipelines[kind] else { continue }
                e.setRenderPipelineState(state)
                // The prim path samples the ATTACHMENT ITSELF; only copy reads
                // the snapshot. Nothing else binds a texture at all.
                e.setFragmentTexture(kind == .copy ? scratch : vram.texture, index: 0)
                e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                 instanceCount: range.count, baseInstance: range.lowerBound)
            }
        }
        closePass()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    // MARK: - Records

    func apply(_ cmd: Ps1GpuCommand) {
        switch cmd.commandKind {
        case PS1_GPU_SET_DRAW_ENV, PS1_GPU_LATCH_TEXPAGE,
             PS1_GPU_SET_TEXTURE_DISABLE_ALLOWED, PS1_GPU_RESET_DRAW_ENV:
            env.apply(cmd)

        case PS1_GPU_FILL_RECT:
            encodeFill(cmd)
        case PS1_GPU_COPY_RECT:
            encodeCopy(cmd)
        case PS1_GPU_VRAM_WRITE_SETUP:
            transfer.setup(x: Int(cmd.x), y: Int(cmd.y), w: Int(cmd.w), h: Int(cmd.h))
        case PS1_GPU_VRAM_WRITE_DATA:
            encodeUpload(cmd)
        case PS1_GPU_VRAM_WRITE_ABORT:
            transfer.abort()

        case PS1_GPU_VRAM_READ_SETUP:
            // Moves no pixel. GPUREAD is served from the shadow (parent spec,
            // § Ownership and sync), so there is nothing to do here — and
            // that is "irrelevant", not "unmodelled".
            break

        default:
            sawUnmodelledKind = true
        }
    }

    // MARK: - Movers

    /// A mover both starts and ends a render pass. Conservative and always
    /// correct: it is what lets a textured primitive sample a texture uploaded
    /// earlier in the SAME frame. Task 11's dirty-rect hazard test is added on
    /// top of this rule, never in place of it.
    private func breakPass() {
        if case .passBreak? = steps.last { return }
        steps.append(.passBreak)
    }

    private func maskFlags() -> UInt32 {
        (env.maskSet ? PS1_PRIM_SET_MASK : 0) | (env.maskCheck ? PS1_PRIM_CHECK_MASK : 0)
    }

    /// Clamps an inclusive box to VRAM. Returns nil when nothing is left, which
    /// is the encoder's equivalent of the software path's `continue`.
    private func clampBox(x0: Int, y0: Int, x1: Int, y1: Int) -> (Int, Int, Int, Int)? {
        let cx0 = max(x0, 0), cy0 = max(y0, 0)
        let cx1 = min(x1, MetalVram.width - 1), cy1 = min(y1, MetalVram.height - 1)
        guard cx0 <= cx1, cy0 <= cy1 else { return nil }
        return (cx0, cy0, cx1, cy1)
    }

    /// A wrapping run on one axis, as at most two non-wrapping ranges.
    private func wrapRanges(origin: Int, extent: Int, axis: Int) -> [(Int, Int)] {
        if extent >= axis { return [(0, axis - 1)] }
        let o = ((origin % axis) + axis) % axis
        if o + extent <= axis { return [(o, o + extent - 1)] }
        return [(o, axis - 1), (0, o + extent - axis - 1)]
    }

    private func encodeFill(_ cmd: Ps1GpuCommand) {
        let x = Int(cmd.x), y = Int(cmd.y), w = Int(cmd.w), h = Int(cmd.h)
        guard w > 0, h > 0,
              let box = clampBox(x0: x, y0: y, x1: x + w - 1, y1: y + h - 1) else { return }
        var inst = Ps1PrimInstance()
        inst.kind = PS1_PRIM_FILL
        (inst.box_x0, inst.box_y0, inst.box_x1, inst.box_y1) =
            (Int32(box.0), Int32(box.1), Int32(box.2), Int32(box.3))
        inst.color = cmd.value & 0xFFFF
        let first = instances.count
        instances.append(inst)
        breakPass()
        steps.append(.draw(kind: .fill, range: first..<instances.count))
        breakPass()
    }

    private func encodeCopy(_ cmd: Ps1GpuCommand) {
        let w = VramTransfer.axisExtent(Int(cmd.w), MetalVram.width)
        let h = VramTransfer.axisExtent(Int(cmd.h), MetalVram.height)
        guard w > 0, h > 0 else { return }

        var base = Ps1PrimInstance()
        base.kind = PS1_PRIM_COPY
        base.x0 = Int32(Int(cmd.x2) & 0x3FF)
        base.y0 = Int32(Int(cmd.y2) & 0x1FF)
        base.src_x = Int32(Int(cmd.x) & 0x3FF)
        base.src_y = Int32(Int(cmd.y) & 0x1FF)
        base.w = Int32(w)
        base.h = Int32(h)
        base.flags = maskFlags()

        let first = instances.count
        for (bx0, bx1) in wrapRanges(origin: Int(base.x0), extent: w, axis: MetalVram.width) {
            for (by0, by1) in wrapRanges(origin: Int(base.y0), extent: h, axis: MetalVram.height) {
                var inst = base
                (inst.box_x0, inst.box_x1) = (Int32(bx0), Int32(bx1))
                (inst.box_y0, inst.box_y1) = (Int32(by0), Int32(by1))
                instances.append(inst)
            }
        }
        breakPass()
        steps.append(.snapshot)
        steps.append(.draw(kind: .copy, range: first..<instances.count))
        breakPass()
    }

    private func encodeUpload(_ cmd: Ps1GpuCommand) {
        let off = Int(cmd.x), len = Int(cmd.y)
        guard off >= 0, len >= 0 else { return }
        var wordCursor = off
        var remaining = len
        let first = instances.count
        while remaining > 0, transfer.active, let run = transfer.plan(words: remaining) {
            appendUploadInstance(bufferWordOffset: wordCursor, run: run)
            wordCursor += run.consumed
            remaining -= run.consumed
        }
        guard instances.count > first else { return }
        breakPass()
        steps.append(.draw(kind: .upload, range: first..<instances.count))
        breakPass()
    }

    private func appendUploadInstance(bufferWordOffset: Int,
                                      run: (first: Int, last: Int, consumed: Int)) {
        let w = transfer.w
        let rowFirst = run.first / w, rowLast = run.last / w
        guard let box = clampBox(x0: transfer.x, y0: transfer.y + rowFirst,
                                 x1: transfer.x + w - 1, y1: transfer.y + rowLast) else { return }
        var inst = Ps1PrimInstance()
        inst.kind = PS1_PRIM_UPLOAD
        (inst.box_x0, inst.box_y0, inst.box_x1, inst.box_y1) =
            (Int32(box.0), Int32(box.1), Int32(box.2), Int32(box.3))
        inst.x0 = Int32(transfer.x)
        inst.y0 = Int32(transfer.y)
        inst.w = Int32(w)
        inst.h = Int32(transfer.h)
        // A run always starts on an EVEN pixel index, so this bias is exact.
        inst.word_base = Int32(bufferWordOffset - run.first / 2)
        inst.pixel_first = Int32(run.first)
        inst.pixel_last = Int32(run.last)
        inst.flags = maskFlags()
        instances.append(inst)
    }
}
```

> `ps1_prim_fragment` does not exist until Task 6. Until then, add a stub to `Rasterizer.metal` so `init` does not throw:
> ```metal
> /// Placeholder until Task 6 lands the real one. It discards everything, so a
> /// mover-only fixture is unaffected and a drawing record is a visible hole
> /// rather than a wrong pixel.
> fragment ushort ps1_prim_fragment(PrimVertexOut in [[stage_in]]) {
>     discard_fragment();
>     return 0;
> }
> ```

- [ ] **Step 9: Run**

```bash
zig build capi-lib && zig build metallib && ps1-macos/test.sh 2>&1 | tail -40
```
Expected: PASS. `replaysTheSyntheticMoverFixtureOnTheGpu` checks all 6 frames; `replaysTheCrocMoverFixtureOnTheGpu` checks all 200; `aTextureBoundAsAttachmentCanBeReadAtAnotherCoordinate` passes.

If the aliasing probe fails, **stop and report it** before going further: implement the named fallback (a second `.private` texture refreshed by a blit at each pass boundary, bound in place of `vram.texture` for the `.prim` draw) rather than working around it downstream.

- [ ] **Step 10: Commit**

```bash
git add ps1-macos
git commit -m "$(cat <<'EOF'
feat(metal): the 02/80/A0 movers as GPU passes

The GP0(A0) FSM is extracted into VramTransfer and shared by ShadowVram and the
Metal encoder — the spec's "no third transcription" rule, made structural.

A self-overlapping copy is a read/write hazard on one resource, so it runs as a
blit to a scratch texture and back; vram.zig's backwards-iteration branch then
has nothing to reproduce. Fill stays deliberately unmasked and unclipped.

Also settles the design's one foundational risk: a texture bound as [[color(0)]]
IS readable at another coordinate by the same draw, and the read sees pre-pass
contents. Pinned by aTextureBoundAsAttachmentCanBeReadAtAnotherCoordinate.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Flat triangles and the whole of `putPixel`

The core of the rasterizer: integer edge functions, the top-left fill rule, the drawing-area clip, the mask check, integer blending and STP. Everything from Task 7 on plugs a different shading function into this same tail.

**Files:**
- Create: `ps1-macos/Shaders/Ps1Color.h`
- Modify: `ps1-macos/Shaders/Rasterizer.metal`
- Create: `ps1-macos/Sources/PS1/PrimBuilder.swift`
- Modify: `ps1-macos/Sources/PS1/MetalRasterizer.swift`
- Create: `ps1-macos/Tests/PS1Tests/MetalRasterizerTests.swift`

**Interfaces:**
- Consumes: `MetalRasterizer`, `DrawEnv`, `MetalFixtureHarness`.
- Produces: `enum PrimBuilder` with `static func triangle(_ cmd: Ps1GpuCommand, env: DrawEnv, kind: Int32) -> Ps1PrimInstance?` and the shared `static func base(_ env: DrawEnv) -> Ps1PrimInstance`; Metal helpers in `Ps1Color.h`; the real `ps1_prim_fragment`.

- [ ] **Step 1: Write the failing gate and the ordering test**

Create `ps1-macos/Tests/PS1Tests/MetalRasterizerTests.swift`:

```swift
import Testing
import Foundation
import Metal
import CPs1
@testable import PS1

// The gate ladder. `synthetic-primitives` puts one feature group per frame, in
// the order documented in the Phase B plan; each task below extends the prefix
// this replays. A hash is CUMULATIVE, so bounding the replay is what keeps a
// later frame's mismatch from masking an earlier feature that already works.

@Test func flatTrianglesMatchTheSoftwareRasterizer() throws {
    guard let r = try MetalFixtureHarness.replay("synthetic-primitives", upTo: 1) else { return }
    #expect(r.firstDivergence == nil, r.message)
}

// The one assumption underneath every blend in the corpus. Metal orders
// framebuffer reads by primitive submission order, instances included; a
// raster order group orders accesses to DEVICE memory, which this backend
// never does. If this ever fails, add [[raster_order_group(0)]] to the
// [[color(0)]] input — do NOT reorder the encoder to work around it.
@Test func overlappingInstancesBlendInSubmissionOrder() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let renderer = try MetalRasterizer(vram: vram)

    var env = Ps1GpuCommand()
    env.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
    env.opcode = 0xE4
    env.value = (511 << 10) | 1023

    // Blend mode 1 is B + F. Three identical opaque-then-additive triangles
    // over the same pixel must land at 3x, not 1x, and not in some other order.
    var mode = Ps1GpuCommand()
    mode.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
    mode.opcode = 0xE1
    mode.value = 1 << 5

    func tri(_ transparent: Bool, _ colour: UInt32) -> Ps1GpuCommand {
        var c = Ps1GpuCommand()
        c.kind = UInt8(PS1_GPU_DRAW_TRIANGLE.rawValue)
        c.transparent = transparent ? 1 : 0
        c.value = colour
        c.v.0 = Ps1GpuVertex(x: 0, y: 0, u: 0, v: 0, _pad: 0, color: 0)
        c.v.1 = Ps1GpuVertex(x: 40, y: 0, u: 0, v: 0, _pad: 0, color: 0)
        c.v.2 = Ps1GpuVertex(x: 0, y: 40, u: 0, v: 0, _pad: 0, color: 0)
        return c
    }

    renderer.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
    renderer.apply(env)
    renderer.apply(mode)
    renderer.apply(tri(false, 0x0005))          // opaque red = 5
    renderer.apply(tri(true, 0x0005))           // +5
    renderer.apply(tri(true, 0x0005))           // +5
    renderer.endFrame()

    #expect(vram.readback()[5 * 1024 + 5] == 0x000F)
}
```

- [ ] **Step 2: Run and watch it fail**

```bash
ps1-macos/test.sh 2>&1 | tail -20
```
Expected: both fail — the prim fragment is still the discard-everything stub, so frame 0's hash is the blank one and the blend test reads 0.

- [ ] **Step 3: Write the shared shader helpers**

Create `ps1-macos/Shaders/Ps1Color.h`. This is a transcription of `gpu/color.zig` and the geometry helpers in `gpu/renderer.zig`; every divergence from those files is a bug, and the frozen Phase 0 goldens are what makes that testable.

```c
/* Integer colour and geometry helpers, transcribed from
   ps1-core/src/gpu/color.zig and the top of gpu/renderer.zig.

   Metal-only: it uses MSL types. Included by Rasterizer.metal after
   <metal_stdlib>.

   INTEGER ARITHMETIC THROUGHOUT, never fixed-function blending and never
   floats: fixed-function blending normalizes to float and rounds differently,
   so it cannot be bit-exact at 1x. */
#ifndef PS1_COLOR_H
#define PS1_COLOR_H

constant int ps1_dither_table[4][4] = {
    { -4,  0, -3,  1 },
    {  2, -2,  3, -1 },
    { -3,  1, -4,  0 },
    {  3, -1,  2, -2 },
};

/// Floor division. `c1 - c0` on a shaded line is routinely negative, and
/// MSL's `/` truncates toward zero — which is a DIFFERENT answer from
/// `@divFloor` for exactly those spans.
inline int ps1_floor_div(int a, int b) {
    int q = a / b;
    if ((a % b != 0) && ((a < 0) != (b < 0))) q -= 1;
    return q;
}

/// Three 8-bit-scale channels down to ABGR1555. The dither offsets are 8-bit
/// channel units, so they are added BEFORE this and the clamp is at 8-bit
/// range — reading them as 5-bit units is the bug 900daa0 fixed.
inline ushort ps1_pack(int r, int g, int b) {
    int r5 = clamp(r, 0, 255) >> 3;
    int g5 = clamp(g, 0, 255) >> 3;
    int b5 = clamp(b, 0, 255) >> 3;
    return ushort(r5 | (g5 << 5) | (b5 << 10));
}

inline int ps1_dither(int px, int py) {
    return ps1_dither_table[py & 3][px & 3];
}

/// color.zig's `blend`. Truncating integer division on 5-bit channels.
/// Blending never touches bit 15 — the drawn pixel keeps the mask bit of the
/// SOURCE colour, carried through every mode.
inline ushort ps1_blend(ushort bg, ushort fg, uint mode) {
    int fr = fg & 0x1F, fg_g = (fg >> 5) & 0x1F, fb = (fg >> 10) & 0x1F;
    int br = bg & 0x1F, bg_g = (bg >> 5) & 0x1F, bb = (bg >> 10) & 0x1F;
    int rr, gg, bo;
    switch (mode) {
        case 0u: rr = (br + fr) / 2; gg = (bg_g + fg_g) / 2; bo = (bb + fb) / 2; break;
        case 1u: rr = br + fr;       gg = bg_g + fg_g;       bo = bb + fb;       break;
        case 2u: rr = br > fr ? br - fr : 0;
                 gg = bg_g > fg_g ? bg_g - fg_g : 0;
                 bo = bb > fb ? bb - fb : 0; break;
        default: rr = br + (fr / 4);  gg = bg_g + (fg_g / 4); bo = bb + (fb / 4); break;
    }
    rr = min(rr, 31); gg = min(gg, 31); bo = min(bo, 31);
    return ushort(rr | (gg << 5) | (bo << 10) | (fg & 0x8000));
}

/// `Vram.index(x, y)` is `y * 1024 + x` with NO masking, so a CLUT whose
/// `clut_x + index` runs past 1023 reads into the NEXT ROW. That is the
/// software rasterizer's behaviour and it has to be reproduced, not corrected:
/// this converts the flat index back to 2D exactly as Zig's array does.
inline ushort ps1_vram_read(texture2d<ushort, access::read> vram, uint x, uint y) {
    uint lin = (y * 1024u + x) & 0x7FFFFu;
    return vram.read(uint2(lin & 1023u, lin >> 10)).r;
}

/// color.zig's `fetchTexel`, at all three depths.
inline ushort ps1_fetch_texel(texture2d<ushort, access::read> vram, uint depth,
                              uint tpage_x, uint tpage_y,
                              uint clut_x, uint clut_y, uint u, uint v) {
    uint py = tpage_y + v;
    if (depth == 0u) {
        ushort word = ps1_vram_read(vram, tpage_x + (u >> 2), py);
        uint idx = (uint(word) >> ((u & 3u) * 4u)) & 0xFu;
        return ps1_vram_read(vram, clut_x + idx, clut_y);
    }
    if (depth == 1u) {
        ushort word = ps1_vram_read(vram, tpage_x + (u >> 1), py);
        uint idx = (uint(word) >> ((u & 1u) * 8u)) & 0xFFu;
        return ps1_vram_read(vram, clut_x + idx, clut_y);
    }
    return ps1_vram_read(vram, tpage_x + u, py);
}

/// color.zig's `modulate`: texel * vertex-colour at 8-bit scale, i.e.
/// `(t << 3) * (c << 3) >> 7` == `(t * c) >> 1`. Working at 8-bit scale is
/// what makes the dither offsets mean what they say. Keeps `texel & 0x8000` —
/// a textured primitive's semi-transparency bit lives there.
inline ushort ps1_modulate(ushort texel, ushort color, int px, int py, bool dither) {
    int tr = texel & 0x1F, tg = (texel >> 5) & 0x1F, tb = (texel >> 10) & 0x1F;
    int cr = color & 0x1F, cg = (color >> 5) & 0x1F, cb = (color >> 10) & 0x1F;
    int r = (tr * cr) >> 1, g = (tg * cg) >> 1, b = (tb * cb) >> 1;
    if (dither) {
        int o = ps1_dither(px, py);
        r += o; g += o; b += o;
    }
    return ps1_pack(r, g, b) | (texel & 0x8000);
}

/// Twice the signed area of (a, b, c).
inline int ps1_orient(int ax, int ay, int bx, int by, int cx, int cy) {
    return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
}

/// The top-left fill rule. An edge that fails it drops the pixels landing
/// exactly on it, so two triangles sharing an edge paint each pixel once.
inline bool ps1_top_left(int dx, int dy) {
    return dy > 0 || (dy == 0 && dx < 0);
}

/// Exact barycentric interpolation of one integer attribute.
///
/// `renderer.zig:82-90` does this in i64 because the EXPANDED plane equation's
/// constant term exceeds i32. Nothing is expanded here — the weights are
/// evaluated at the pixel — and coverage guarantees every w_i is in [0, area]
/// with area <= 1024*512, so the numerator is bounded by 3 * 524288 * 255,
/// about 4.0e8, comfortably inside int32.
///
/// Plain `/` rather than a floor: on a covered pixel num >= 0 and area > 0, so
/// @divFloor and @divTrunc agree, exactly as that function's own comment says.
inline int ps1_interp(int w0, int w1, int w2, int area, int a0, int a1, int a2) {
    return (w0 * a0 + w1 * a1 + w2 * a2) / area;
}

#endif /* PS1_COLOR_H */
```

- [ ] **Step 4: Replace the stub fragment**

In `ps1-macos/Shaders/Rasterizer.metal`, add `#include "Ps1Color.h"` after `<metal_stdlib>` and replace `ps1_prim_fragment`:

```metal
/// Coverage for a triangle instance, recomputed per pixel from the three
/// vertices with no incremental state — which is precisely what Phase 0's
/// `interp` doc comment was written to guarantee.
///
/// Returns false when the pixel is outside. `w0`/`w1`/`w2` come back UNBIASED:
/// the fill-rule bias is a coverage device only, and attributes must be
/// interpolated from the true barycentric numerators.
inline bool ps1_triangle_coverage(const device Ps1PrimInstance& p, int px, int py,
                                  thread int& w0, thread int& w1, thread int& w2,
                                  thread int& area) {
    int area_signed = ps1_orient(p.x0, p.y0, p.x1, p.y1, p.x2, p.y2);
    // Normalize to a positive area by flipping the sign of every edge function
    // rather than by swapping two vertices: a swap would permute the
    // attributes the shader indexes by vertex number.
    int s = area_signed < 0 ? -1 : 1;
    area = area_signed * s;

    int bias0 = ps1_top_left(s * (p.x2 - p.x1), s * (p.y2 - p.y1)) ? -1 : 0;
    int bias1 = ps1_top_left(s * (p.x0 - p.x2), s * (p.y0 - p.y2)) ? -1 : 0;
    int bias2 = ps1_top_left(s * (p.x1 - p.x0), s * (p.y1 - p.y0)) ? -1 : 0;

    int b0 = s * ps1_orient(p.x1, p.y1, p.x2, p.y2, px, py) + bias0;
    int b1 = s * ps1_orient(p.x2, p.y2, p.x0, p.y0, px, py) + bias1;
    int b2 = s * ps1_orient(p.x0, p.y0, p.x1, p.y1, px, py) + bias2;

    // Avocado's coverage test verbatim: a negative term sets the sign bit of
    // the OR, so this means "all three non-negative, and not all three zero".
    if ((b0 | b1 | b2) <= 0) return false;

    w0 = b0 - bias0;
    w1 = b1 - bias1;
    w2 = b2 - bias2;
    return true;
}

/// Every drawing primitive. `dst` is the destination pixel through
/// programmable blending — the same pixel via tile memory, which is a
/// different mechanism from sampling an arbitrary VRAM address and is not
/// affected by the pass-splitting invariant.
fragment ushort ps1_prim_fragment(PrimVertexOut in [[stage_in]],
                                  ushort dst [[color(0)]],
                                  const device Ps1PrimInstance* prims [[buffer(0)]],
                                  texture2d<ushort, access::read> vram [[texture(0)]]) {
    const device Ps1PrimInstance& p = prims[in.iid];
    // [[position]] in a fragment shader is the pixel CENTRE (px+0.5, py+0.5),
    // so this truncation is exact.
    int px = int(in.position.x);
    int py = int(in.position.y);

    bool transparent = (p.flags & PS1_PRIM_TRANSPARENT) != 0;
    ushort src;

    if (p.kind == PS1_PRIM_FLAT_TRI) {
        int w0, w1, w2, area;
        if (!ps1_triangle_coverage(p, px, py, w0, w1, w2, area)) { discard_fragment(); return 0; }
        src = ushort(p.color);
    } else {
        discard_fragment();
        return 0;
    }

    // ---- putPixel's tail (renderer.zig:8-46) ----------------------------
    // The drawing-area clip could be a scissor rect — it is exactly a
    // rectangle — but a scissor is per-encoder state and would break the
    // single instanced draw. In-shader keeps the batch.
    if (px < p.clip_x0 || px > p.clip_x1 || py < p.clip_y0 || py > p.clip_y1) {
        discard_fragment();
        return 0;
    }
    if ((p.flags & PS1_PRIM_CHECK_MASK) && (dst & 0x8000)) { discard_fragment(); return 0; }

    ushort out = transparent ? ps1_blend(dst, src, p.blend_mode) : src;

    // Bit 15 of the written pixel is the SOURCE pixel's own bit 15 — for a
    // textured primitive the texel's STP bit, for an untextured one 0 — OR'd
    // with GP0(E6).bit0. It must NOT be cleared: games mask off already-drawn
    // areas by leaving STP-set texels in VRAM and drawing with check-mask.
    if (p.flags & PS1_PRIM_SET_MASK) out |= 0x8000;
    return out;
}
```

- [ ] **Step 5: Implement `PrimBuilder` and hook it up**

Create `ps1-macos/Sources/PS1/PrimBuilder.swift`:

```swift
import Foundation
import CPs1

/// Turns one recorded drawing command into instance records.
///
/// Split from `MetalRasterizer` so neither file grows past readable size: the
/// encoder owns passes and resources, this owns the per-primitive geometry
/// that mirrors `gpu/renderer.zig`'s CPU-side setup — the offset, the
/// oversized-primitive refusal, and the bounding box.
enum PrimBuilder {
    /// Everything a primitive inherits from the drawing environment.
    static func base(_ env: DrawEnv) -> Ps1PrimInstance {
        var inst = Ps1PrimInstance()
        let clip = env.clip
        (inst.clip_x0, inst.clip_y0, inst.clip_x1, inst.clip_y1) =
            (Int32(clip.x0), Int32(clip.y0), Int32(clip.x1), Int32(clip.y1))
        inst.blend_mode = env.blendMode
        inst.tex_window = env.texWindow
        inst.flags = (env.maskSet ? PS1_PRIM_SET_MASK : 0)
            | (env.maskCheck ? PS1_PRIM_CHECK_MASK : 0)
            | (env.ditherEnabled ? PS1_PRIM_DITHER : 0)
        return inst
    }

    /// One triangle. A record always carries exactly one — `gp0.zig` already
    /// decomposes quads into two `draw_triangle`/`draw_shaded_triangle`
    /// records — so the oversized refusal is judged per triangle, each half of
    /// a quad separately, exactly as `renderer.zig:123-124` does, without this
    /// function having to know about quads at all.
    ///
    /// Returns nil for every case the software rasterizer refuses outright: an
    /// oversized span, a degenerate area, or an empty box after clipping.
    static func triangle(_ cmd: Ps1GpuCommand, env: DrawEnv, kind: Int32) -> Ps1PrimInstance? {
        let verts = withUnsafeBytes(of: cmd.v) { raw -> [Ps1GpuVertex] in
            let p = raw.bindMemory(to: Ps1GpuVertex.self)
            return [p[0], p[1], p[2]]
        }
        let ox = env.offsetX, oy = env.offsetY
        let vx = verts.map { Int($0.x) + ox }
        let vy = verts.map { Int($0.y) + oy }

        // Hardware refuses any primitive whose vertices span 1024 or more
        // horizontally, or 512 or more vertically — it is not clipped, it is
        // DROPPED. Games lean on that: geometry crossing the near plane
        // projects to saturated screen coordinates, and the drop is what keeps
        // it off the screen.
        guard vx.max()! - vx.min()! < 1024, vy.max()! - vy.min()! < 512 else { return nil }

        // Twice the signed area; zero means degenerate and nothing is drawn.
        let area = (vx[1] - vx[0]) * (vy[2] - vy[0]) - (vy[1] - vy[0]) * (vx[2] - vx[0])
        guard area != 0 else { return nil }

        let clip = env.clip
        let x0 = max(clip.x0, max(0, vx.min()!))
        let x1 = min(clip.x1, min(MetalVram.width - 1, vx.max()!))
        let y0 = max(clip.y0, max(0, vy.min()!))
        let y1 = min(clip.y1, min(MetalVram.height - 1, vy.max()!))
        guard x0 <= x1, y0 <= y1 else { return nil }

        var inst = base(env)
        inst.kind = kind
        (inst.box_x0, inst.box_y0, inst.box_x1, inst.box_y1) =
            (Int32(x0), Int32(y0), Int32(x1), Int32(y1))
        (inst.x0, inst.y0) = (Int32(vx[0]), Int32(vy[0]))
        (inst.x1, inst.y1) = (Int32(vx[1]), Int32(vy[1]))
        (inst.x2, inst.y2) = (Int32(vx[2]), Int32(vy[2]))
        (inst.u0, inst.v0) = (Int32(verts[0].u), Int32(verts[0].v))
        (inst.u1, inst.v1) = (Int32(verts[1].u), Int32(verts[1].v))
        (inst.u2, inst.v2) = (Int32(verts[2].u), Int32(verts[2].v))
        (inst.c0, inst.c1, inst.c2) = (verts[0].color, verts[1].color, verts[2].color)
        inst.color = cmd.value & 0xFFFF
        if cmd.transparent != 0 { inst.flags |= PS1_PRIM_TRANSPARENT }
        return inst
    }
}
```

In `MetalRasterizer`, add the `.prim` accumulation and the `draw_triangle` arm:

```swift
    /// Drawing primitives accumulate into ONE instanced draw. The only thing
    /// that ends a run is a mover (Decision 9) or, from Task 11, a hazard.
    private func appendPrim(_ inst: Ps1PrimInstance) {
        let i = instances.count
        instances.append(inst)
        if case let .draw(kind, range)? = steps.last, kind == .prim, range.upperBound == i {
            steps[steps.count - 1] = .draw(kind: .prim, range: range.lowerBound..<(i + 1))
        } else {
            steps.append(.draw(kind: .prim, range: i..<(i + 1)))
        }
    }
```

and in `apply`:

```swift
        case PS1_GPU_DRAW_TRIANGLE:
            if let inst = PrimBuilder.triangle(cmd, env: env, kind: PS1_PRIM_FLAT_TRI) {
                appendPrim(inst)
            }
```

- [ ] **Step 6: Run**

```bash
zig build capi-lib && zig build metallib && ps1-macos/test.sh 2>&1 | tail -40
```
Expected: PASS, including `flatTrianglesMatchTheSoftwareRasterizer` and `overlappingInstancesBlendInSubmissionOrder`, and every mover test from Task 5 still green.

If frame 0 diverges, the message carries the first ten differing pixels. Get the reference dump first:
```bash
zig build trace-golden -Doptimize=ReleaseFast -- stream-capture --filter=__none__ --dump-frame=0
```
— it writes `zig-out/fixtures/synthetic-primitives-frame0.vram` alongside the fixture, and the next test run diffs against it.

- [ ] **Step 7: Commit**

```bash
git add ps1-macos
git commit -m "$(cat <<'EOF'
feat(metal): flat triangles and the whole of putPixel

Coverage is evaluated in the FRAGMENT shader from the integer edge functions
and the top-left rule, per pixel, with no incremental state. Metal's own
rasterizer is never trusted for it — its fill rule and sample positions are not
the PS1's, and the disagreement lands exactly on the degenerate triangles that
matter.

The putPixel tail is transcribed in order: drawing-area clip, mask check,
integer blend on 5-bit channels, then bit 15 as the source pixel's own OR'd
with GP0(E6).bit0.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Gouraud shading and dither

**Files:**
- Modify: `ps1-macos/Shaders/Rasterizer.metal`
- Modify: `ps1-macos/Sources/PS1/MetalRasterizer.swift`
- Modify: `ps1-macos/Tests/PS1Tests/MetalRasterizerTests.swift`

**Interfaces:**
- Consumes: `PrimBuilder.triangle`, `ps1_triangle_coverage`, `ps1_interp`, `ps1_dither`, `ps1_pack`.
- Produces: nothing new; `PS1_PRIM_GOURAUD_TRI` becomes live.

- [ ] **Step 1: Extend the gate**

In `MetalRasterizerTests.swift`:

```swift
@Test func gouraudTrianglesAndDitherMatchTheSoftwareRasterizer() throws {
    guard let r = try MetalFixtureHarness.replay("synthetic-primitives", upTo: 2) else { return }
    #expect(r.firstDivergence == nil, r.message)
}

@Test func theDitherOffsetIsAnEightBitChannelUnit() throws {
    // The offsets are added at 8-BIT scale and clamped to [0,255] BEFORE the
    // >> 3 down to 5 bits. Reading them as 5-bit units is the bug 900daa0
    // fixed, and it survives every hash in the A2 corpus because no PL ROM
    // dithers. Channel 0x80 with dither cell (0,0) = -4 gives 0x7C >> 3 = 15;
    // at 5-bit scale it would give (0x80>>3) - 4 = 12.
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let renderer = try MetalRasterizer(vram: vram)

    func env(_ op: UInt8, _ v: UInt32) -> Ps1GpuCommand {
        var c = Ps1GpuCommand()
        c.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        c.opcode = op
        c.value = v
        return c
    }

    var tri = Ps1GpuCommand()
    tri.kind = UInt8(PS1_GPU_DRAW_SHADED_TRIANGLE.rawValue)
    // A flat-coloured Gouraud triangle: all three vertices 0x808080, so the
    // interpolation is exact everywhere and only the dither varies.
    tri.v.0 = Ps1GpuVertex(x: 0, y: 0, u: 0, v: 0, _pad: 0, color: 0x0080_8080)
    tri.v.1 = Ps1GpuVertex(x: 60, y: 0, u: 0, v: 0, _pad: 0, color: 0x0080_8080)
    tri.v.2 = Ps1GpuVertex(x: 0, y: 60, u: 0, v: 0, _pad: 0, color: 0x0080_8080)

    renderer.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
    renderer.apply(env(0xE4, (511 << 10) | 1023))
    renderer.apply(env(0xE1, 1 << 9))              // dither ON
    renderer.apply(tri)
    renderer.endFrame()

    let back = vram.readback()
    #expect(back[0] == (15 | (15 << 5) | (15 << 10)))          // cell (0,0) = -4
    #expect(back[1] == (16 | (16 << 5) | (16 << 10)))          // cell (1,0) =  0
}
```

- [ ] **Step 2: Run and watch it fail**

```bash
ps1-macos/test.sh 2>&1 | tail -20
```
Expected: both fail; the Gouraud kind is not handled, so nothing is drawn.

- [ ] **Step 3: Add the Gouraud arm to the shader**

In `ps1_prim_fragment`, replace the `if (p.kind == PS1_PRIM_FLAT_TRI) { ... } else { discard }` block's `else` with:

```metal
    } else if (p.kind == PS1_PRIM_GOURAUD_TRI) {
        int w0, w1, w2, area;
        if (!ps1_triangle_coverage(p, px, py, w0, w1, w2, area)) { discard_fragment(); return 0; }
        // Wire colours are 24-bit BGR: red in the low byte.
        int r = ps1_interp(w0, w1, w2, area,
                           int(p.c0 & 0xFFu), int(p.c1 & 0xFFu), int(p.c2 & 0xFFu));
        int g = ps1_interp(w0, w1, w2, area,
                           int((p.c0 >> 8) & 0xFFu), int((p.c1 >> 8) & 0xFFu), int((p.c2 >> 8) & 0xFFu));
        int b = ps1_interp(w0, w1, w2, area,
                           int((p.c0 >> 16) & 0xFFu), int((p.c1 >> 16) & 0xFFu), int((p.c2 >> 16) & 0xFFu));
        if (p.flags & PS1_PRIM_DITHER) {
            int o = ps1_dither(px, py);
            r += o; g += o; b += o;
        }
        src = ps1_pack(r, g, b);
    } else {
```

- [ ] **Step 4: Add the encoder arm**

In `MetalRasterizer.apply`:

```swift
        case PS1_GPU_DRAW_SHADED_TRIANGLE:
            if let inst = PrimBuilder.triangle(cmd, env: env, kind: PS1_PRIM_GOURAUD_TRI) {
                appendPrim(inst)
            }
```

- [ ] **Step 5: Run**

```bash
zig build capi-lib && zig build metallib && ps1-macos/test.sh 2>&1 | tail -40
```
Expected: PASS, all previous gates still green.

- [ ] **Step 6: Commit**

```bash
git add ps1-macos
git commit -m "$(cat <<'EOF'
feat(metal): Gouraud shading and dither

interp is the exact integer barycentric form Phase 0 rewrote renderer.zig into
precisely so a fragment shader could evaluate it from (px, py) with no
incremental state. Dither offsets are 8-bit channel units added before the
>> 3 down to 5 bits, which no fixture in the Phase A2 corpus exercises.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Textured triangles

4/8/16bpp, CLUT, the texture window, `modulate`, the `texel == 0` hole, and STP-gated transparency. This is also the first task where a primitive **samples VRAM** — `latch_texpage` must be applied to the env, and the frame's uploads must have landed in an earlier pass, which Decision 9's mover rule already guarantees.

**Files:**
- Modify: `ps1-macos/Shaders/Rasterizer.metal`
- Modify: `ps1-macos/Sources/PS1/MetalRasterizer.swift`
- Modify: `ps1-macos/Tests/PS1Tests/MetalRasterizerTests.swift`

**Interfaces:**
- Consumes: `ps1_fetch_texel`, `ps1_modulate`, `ps1_interp`, `PrimBuilder.triangle`.
- Produces: `PS1_PRIM_TEXTURED_TRI` live, and `PrimBuilder.applyTexture(_:to:)` which decodes `clut`/`tpage` into the instance.

- [ ] **Step 1: Extend the gate**

```swift
@Test func texturedTrianglesMatchTheSoftwareRasterizer() throws {
    guard let r = try MetalFixtureHarness.replay("synthetic-primitives", upTo: 3) else { return }
    #expect(r.firstDivergence == nil, r.message)
}

@Test(.enabled(if: FileManager.default.fileExists(
                    atPath: FixtureFile.url(named: "pl-render-texture-polygon").path),
               "pl-*.p1fx are build artifacts — run `zig build fixtures -Doptimize=ReleaseFast`"))
func replaysThePeterLemonTexturePolygonRom() throws {
    // 48 textured triangles, 34 latch_texpage records and four uploads, all in
    // frame 0 — and the uploads are in the SAME frame as the draws that sample
    // them, which is what makes the mover-ends-the-pass rule load-bearing here
    // rather than merely conservative.
    guard let r = try MetalFixtureHarness.replay("pl-render-texture-polygon") else { return }
    #expect(r.framesChecked == 17)
    #expect(r.firstDivergence == nil, r.message)
}
```

- [ ] **Step 2: Run and watch it fail**

Expected: both fail — textured triangles are not handled, so those pixels stay blank.

- [ ] **Step 3: Add the textured arm to the shader**

```metal
    } else if (p.kind == PS1_PRIM_TEXTURED_TRI) {
        int w0, w1, w2, area;
        if (!ps1_triangle_coverage(p, px, py, w0, w1, w2, area)) { discard_fragment(); return 0; }

        // u/v are 8-bit fields on the wire, and coverage guarantees every
        // unbiased w_i >= 0 with w0+w1+w2 == area exactly, so the interpolant
        // is a convex combination of three in-range values on every covered
        // pixel. The clamp cannot actually trigger; it is the same defensive
        // guard renderer.zig:425-426 keeps, for the same reason.
        uint u = uint(clamp(ps1_interp(w0, w1, w2, area, p.u0, p.u1, p.u2), 0, 255));
        uint v = uint(clamp(ps1_interp(w0, w1, w2, area, p.v0, p.v1, p.v2), 0, 255));

        src = ps1_sample(p, vram, u, v, px, py);
        if (src == 0u) { discard_fragment(); return 0; }
        // A textured primitive's transparency is decided PER TEXEL by the
        // STP bit, not by the opcode alone.
        transparent = transparent && (src & 0x8000) != 0;
    } else {
```

with a helper above `ps1_prim_fragment` shared with the sprite path in Task 9:

```metal
/// Texture-window masking, the texel fetch and optional modulation — the
/// tail both textured paths share.
///
/// Returns 0 for a texel-zero HOLE, which the caller must treat as a discard
/// rather than as a black pixel: `renderer.zig:439` returns `.draw = false`.
/// 0 is unambiguous here because a real texel of 0 is that same hole.
inline ushort ps1_sample(const device Ps1PrimInstance& p,
                         texture2d<ushort, access::read> vram,
                         uint u, uint v, int px, int py) {
    uint mask_x   = (p.tex_window & 0x1Fu) * 8u;
    uint mask_y   = ((p.tex_window >> 5) & 0x1Fu) * 8u;
    uint offset_x = ((p.tex_window >> 10) & 0x1Fu) * 8u;
    uint offset_y = ((p.tex_window >> 15) & 0x1Fu) * 8u;

    uint final_u = (u & ~mask_x) | (offset_x & mask_x);
    uint final_v = (v & ~mask_y) | (offset_y & mask_y);

    ushort texel = ps1_fetch_texel(vram, p.tex_depth, p.tpage_x, p.tpage_y,
                                   p.clut_x, p.clut_y, final_u, final_v);
    if (texel == 0) return 0;
    if (p.flags & PS1_PRIM_MODULATE) {
        return ps1_modulate(texel, ushort(p.color), px, py,
                            (p.flags & PS1_PRIM_DITHER) != 0);
    }
    return texel;
}
```

- [ ] **Step 4: Add the texture decode and the encoder arm**

In `PrimBuilder`:

```swift
    /// `clut` and `tpage` decoded exactly as `renderer.zig:455-459` does.
    /// `tpage & 0xF` is the page X in 64-pixel units; bit 4 is page Y (0 or
    /// 256); bits 7-8 the colour depth. The clut row is 9 bits — it can reach
    /// row 511 — and `clut_x` is in 16-pixel units.
    static func applyTexture(_ cmd: Ps1GpuCommand, to inst: inout Ps1PrimInstance) {
        inst.tex_depth = UInt32((cmd.tpage >> 7) & 3)
        inst.tpage_x = UInt32(cmd.tpage & 0xF) * 64
        inst.tpage_y = (cmd.tpage & 0x10) != 0 ? 256 : 0
        inst.clut_x = UInt32(cmd.clut & 0x3F) * 16
        inst.clut_y = UInt32((cmd.clut >> 6) & 0x1FF)
        // Opcode bit 0 CLEAR means modulate; set means raw.
        if (cmd.opcode & 1) == 0 { inst.flags |= PS1_PRIM_MODULATE }
    }
```

In `MetalRasterizer.apply`:

```swift
        case PS1_GPU_DRAW_TEXTURED_TRIANGLE:
            if var inst = PrimBuilder.triangle(cmd, env: env, kind: PS1_PRIM_TEXTURED_TRI) {
                PrimBuilder.applyTexture(cmd, to: &inst)
                appendPrim(inst)
            }
```

Note the blend mode: a textured polygon's own `latch_texpage` record precedes it in the stream and has already written GP0(E1) bits 5-6 through `DrawEnv`, so `PrimBuilder.base` picks up the right `blendMode` with no special case here. That is why `e1_texpage_mask` covers bits 5-6 in the first place.

- [ ] **Step 5: Run**

```bash
zig build capi-lib && zig build metallib && ps1-macos/test.sh 2>&1 | tail -40
```
Expected: PASS, all previous gates green.

- [ ] **Step 6: Commit**

```bash
git add ps1-macos
git commit -m "$(cat <<'EOF'
feat(metal): textured triangles

4/8/16bpp with CLUT indirection, the texture window, modulation at 8-bit scale,
the texel == 0 hole as a discard rather than a black pixel, and STP-gated
per-texel transparency.

The CLUT read reproduces Vram.index's lack of masking: clut_x + index running
past 1023 reads into the next row, which is the software rasterizer's
behaviour and has to be matched rather than corrected.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Rectangles, plain and textured

Coverage is by construction — the box *is* the primitive. The sprite path's `u8` `+%` wrap is the behaviour with no coverage anywhere in the Phase A2 corpus.

**Files:**
- Modify: `ps1-macos/Shaders/Rasterizer.metal`
- Modify: `ps1-macos/Sources/PS1/PrimBuilder.swift`, `MetalRasterizer.swift`
- Modify: `ps1-macos/Tests/PS1Tests/MetalRasterizerTests.swift`

**Interfaces:**
- Consumes: `ps1_sample`, `PrimBuilder.base`, `PrimBuilder.applyTexture`.
- Produces: `PrimBuilder.rectangle(_ cmd: Ps1GpuCommand, env: DrawEnv, kind: Int32) -> Ps1PrimInstance?`.

- [ ] **Step 1: Extend the gate**

```swift
@Test func rectanglesAndSpritesMatchTheSoftwareRasterizer() throws {
    guard let r = try MetalFixtureHarness.replay("synthetic-primitives", upTo: 5) else { return }
    #expect(r.firstDivergence == nil, r.message)
}

@Test(.enabled(if: FileManager.default.fileExists(
                    atPath: FixtureFile.url(named: "pl-render-rectangle").path),
               "pl-*.p1fx are build artifacts — run `zig build fixtures -Doptimize=ReleaseFast`"))
func replaysThePeterLemonRectangleRom() throws {
    guard let r = try MetalFixtureHarness.replay("pl-render-rectangle") else { return }
    #expect(r.framesChecked == 17)
    #expect(r.firstDivergence == nil, r.message)
}

@Test func aSpriteWrapsItsTexcoordsInEightBits() throws {
    // `tu +% @truncate(xx)` on u8 — a WRAP. The triangle path interpolates and
    // clamps instead, so this is a genuinely separate shader path, and the
    // A2 corpus contains not one draw_textured_rectangle to catch it.
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }

    // A 16bpp texture page at (256, 0) whose row 0 is a ramp: texel at u is
    // 0x0100 + u, so a wrapped read is visibly different from a clamped one.
    var pixels = [UInt16](repeating: 0, count: MetalVram.pixelCount)
    for u in 0..<256 { pixels[256 + u] = UInt16(0x0100 + u) }
    vram.upload(pixels)

    let renderer = try MetalRasterizer(vram: vram)
    func env(_ op: UInt8, _ v: UInt32) -> Ps1GpuCommand {
        var c = Ps1GpuCommand(); c.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        c.opcode = op; c.value = v; return c
    }

    var spr = Ps1GpuCommand()
    spr.kind = UInt8(PS1_GPU_DRAW_TEXTURED_RECTANGLE.rawValue)
    spr.opcode = 0x65                 // RAW: no modulation
    spr.tpage = 0x0104                // page x 4 (-> 256), 16bpp
    spr.x = 0; spr.y = 300; spr.w = 8; spr.h = 1
    spr.v.0 = Ps1GpuVertex(x: 0, y: 0, u: 252, v: 0, _pad: 0, color: 0)

    renderer.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
    renderer.apply(env(0xE4, (511 << 10) | 1023))
    renderer.apply(spr)
    renderer.endFrame()

    let back = vram.readback()
    let row = 300 * 1024
    #expect(back[row + 0] == 0x01FC)   // u = 252
    #expect(back[row + 3] == 0x01FF)   // u = 255
    #expect(back[row + 4] == 0x0100)   // u wrapped to 0 — a clamp would repeat 0x01FF
    #expect(back[row + 7] == 0x0103)
}
```

- [ ] **Step 2: Run and watch it fail**

Expected: all three fail; nothing draws rectangles yet.

- [ ] **Step 3: Add the two rectangle arms to the shader**

```metal
    } else if (p.kind == PS1_PRIM_RECT) {
        // Covered by construction: the box IS the primitive.
        src = ushort(p.color);
    } else if (p.kind == PS1_PRIM_TEXTURED_RECT) {
        // `tu +% @truncate(xx)` on u8 — a WRAP, not the triangle path's
        // interpolate-and-clamp. This is why the sprite path is a separate
        // shader path rather than a special case of the triangle one.
        uint u = uint((px - p.x0) + p.u0) & 0xFFu;
        uint v = uint((py - p.y0) + p.v0) & 0xFFu;
        src = ps1_sample(p, vram, u, v, px, py);
        if (src == 0u) { discard_fragment(); return 0; }
        transparent = transparent && (src & 0x8000) != 0;
    } else {
```

- [ ] **Step 4: Add `PrimBuilder.rectangle` and the encoder arms**

```swift
    /// A rectangle's box is clamped to VRAM ONLY — the drawing-area clip stays
    /// in the shader, because `renderer.zig:280-281` does the VRAM bounds
    /// check itself and then lets `putPixel` apply the clip.
    static func rectangle(_ cmd: Ps1GpuCommand, env: DrawEnv, kind: Int32) -> Ps1PrimInstance? {
        let w = Int(cmd.w), h = Int(cmd.h)
        // The same refusal the polygon and line paths apply: 1024 or more
        // wide, or 512 or more tall, is DROPPED rather than clipped. The GP0
        // size field is 16 bits, so nothing else bounds it.
        guard w > 0, h > 0, w < 1024, h < 512 else { return nil }

        let ox = Int(cmd.x) + env.offsetX
        let oy = Int(cmd.y) + env.offsetY
        let x0 = max(ox, 0), y0 = max(oy, 0)
        let x1 = min(ox + w - 1, MetalVram.width - 1)
        let y1 = min(oy + h - 1, MetalVram.height - 1)
        guard x0 <= x1, y0 <= y1 else { return nil }

        var inst = base(env)
        inst.kind = kind
        (inst.box_x0, inst.box_y0, inst.box_x1, inst.box_y1) =
            (Int32(x0), Int32(y0), Int32(x1), Int32(y1))
        (inst.x0, inst.y0) = (Int32(ox), Int32(oy))
        (inst.w, inst.h) = (Int32(w), Int32(h))
        inst.color = cmd.value & 0xFFFF
        let v0 = withUnsafeBytes(of: cmd.v) { $0.bindMemory(to: Ps1GpuVertex.self)[0] }
        (inst.u0, inst.v0) = (Int32(v0.u), Int32(v0.v))
        if cmd.transparent != 0 { inst.flags |= PS1_PRIM_TRANSPARENT }
        return inst
    }
```

```swift
        case PS1_GPU_DRAW_RECTANGLE:
            if let inst = PrimBuilder.rectangle(cmd, env: env, kind: PS1_PRIM_RECT) {
                appendPrim(inst)
            }
        case PS1_GPU_DRAW_TEXTURED_RECTANGLE:
            if var inst = PrimBuilder.rectangle(cmd, env: env, kind: PS1_PRIM_TEXTURED_RECT) {
                PrimBuilder.applyTexture(cmd, to: &inst)
                appendPrim(inst)
            }
```

A textured rectangle does **not** latch its texpage — it reads the current one, which `gp0.zig:341` takes from `draw_env.draw_mode & 0x1FF` and puts in the record's `tpage` field. `applyTexture` therefore needs no special case, but do not add a `latch_texpage` here.

- [ ] **Step 5: Run**

```bash
zig build capi-lib && zig build metallib && ps1-macos/test.sh 2>&1 | tail -40
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add ps1-macos
git commit -m "$(cat <<'EOF'
feat(metal): rectangles, plain and textured

Coverage by construction — the box IS the primitive — plus the sprite path's
u8 +% texcoord wrap, which differs from the triangle path's interpolate-and-
clamp and had no coverage anywhere in the Phase A2 corpus.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Lines

Bresenham with an error accumulator has no closed form worth deriving and proving. The encoder walks the same twenty-line loop and emits one 1×1 instance per step, at most 1024 of them; the per-pixel colour stays in the shader, evaluated from `k`.

**Files:**
- Create: `ps1-macos/Sources/PS1/LineExpander.swift`
- Create: `ps1-macos/Tests/PS1Tests/LineExpanderTests.swift`
- Modify: `ps1-macos/Shaders/Rasterizer.metal`, `MetalRasterizer.swift`, `MetalRasterizerTests.swift`

**Interfaces:**
- Consumes: `PrimBuilder.base`, `ps1_floor_div`, `ps1_dither`, `ps1_pack`.
- Produces: `enum LineExpander` with `struct Step { let x: Int; let y: Int; let k: Int }` and `static func walk(x0: Int, y0: Int, x1: Int, y1: Int) -> (steps: [Step], total: Int)?` — nil for an oversized line.

- [ ] **Step 1: Write the failing expander tests**

Create `ps1-macos/Tests/PS1Tests/LineExpanderTests.swift`:

```swift
import Testing
@testable import PS1

@Test func aHorizontalLineIsOnePixelPerColumnInclusive() {
    let r = LineExpander.walk(x0: 10, y0: 5, x1: 14, y1: 5)!
    #expect(r.total == 4)
    #expect(r.steps.map { ($0.x, $0.y, $0.k) }.map { "\($0.0),\($0.1),\($0.2)" }
            == ["10,5,0", "11,5,1", "12,5,2", "13,5,3", "14,5,4"])
}

@Test func aZeroLengthLineIsExactlyOnePixel() {
    // `steps == 0`, and the shaded path must not divide by it.
    let r = LineExpander.walk(x0: 3, y0: 3, x1: 3, y1: 3)!
    #expect(r.total == 0)
    #expect(r.steps.count == 1)
    #expect(r.steps[0].x == 3 && r.steps[0].y == 3 && r.steps[0].k == 0)
}

@Test func allEightOctantsEndOnTheirEndpoint() {
    // A swapped dx/dy or a dropped sign shows up as a line that stops short or
    // walks the wrong way; nothing else in the suite would notice.
    for (dx, dy) in [(9, 2), (2, 9), (-2, 9), (-9, 2), (-9, -2), (-2, -9), (2, -9), (9, -2)] {
        let r = LineExpander.walk(x0: 50, y0: 50, x1: 50 + dx, y1: 50 + dy)!
        #expect(r.steps.last!.x == 50 + dx, "octant \(dx),\(dy)")
        #expect(r.steps.last!.y == 50 + dy, "octant \(dx),\(dy)")
        #expect(r.total == max(abs(dx), abs(dy)))
        #expect(r.steps.count == r.total + 1)
        #expect(r.steps.last!.k == r.total)
    }
}

@Test func anOversizedLineIsDroppedNotClipped() {
    // The same 1023x511 refusal the triangle path applies.
    #expect(LineExpander.walk(x0: 0, y0: 0, x1: 1024, y1: 0) == nil)
    #expect(LineExpander.walk(x0: 0, y0: 0, x1: 0, y1: 512) == nil)
    #expect(LineExpander.walk(x0: 0, y0: 0, x1: 1023, y1: 511) != nil)
}
```

- [ ] **Step 2: Run and watch it fail**

Expected: `cannot find 'LineExpander' in scope`.

- [ ] **Step 3: Implement the expander**

Create `ps1-macos/Sources/PS1/LineExpander.swift`:

```swift
import Foundation

/// The Bresenham walk from `renderer.zig:286-313`, transcribed.
///
/// No GPU triangle setup reproduces an error accumulator, and no closed form
/// for the step->coordinate mapping is worth deriving and proving. So the CPU
/// walks the same loop and the GPU gets one 1x1 instance per step — at most
/// 1024 of them, since an oversized line is dropped outright.
///
/// Coordinates arriving here must ALREADY have GP0(E5)'s offset applied: the
/// oversized check in the Zig source is on the offset-applied deltas.
enum LineExpander {
    struct Step {
        let x: Int
        let y: Int
        /// The step index. `drawShadedLine`'s channel at step k is
        /// `c0 + floor((c1 - c0) * k / steps)` — evaluable from k alone rather
        /// than from an accumulator, which is exactly what Phase 0 rewrote
        /// that function into so a shader could do it.
        let k: Int
    }

    /// Returns nil for a line the hardware refuses to draw at all.
    static func walk(x0: Int, y0: Int, x1: Int, y1: Int) -> (steps: [Step], total: Int)? {
        let dx = abs(x1 - x0), dy = abs(y1 - y0)
        guard dx < 1024, dy < 512 else { return nil }

        let sx = x0 < x1 ? 1 : -1
        let sy = y0 < y1 ? 1 : -1
        var err = dx - dy
        var cx = x0, cy = y0
        var k = 0
        var out: [Step] = []
        out.reserveCapacity(max(dx, dy) + 1)

        while true {
            out.append(Step(x: cx, y: cy, k: k))
            if cx == x1 && cy == y1 { break }
            let e2 = 2 * err
            if e2 > -dy { err -= dy; cx += sx }
            if e2 < dx { err += dx; cy += sy }
            k += 1
        }
        return (out, max(dx, dy))
    }
}
```

- [ ] **Step 4: Extend the gate**

In `MetalRasterizerTests.swift`:

```swift
@Test func linesMatchTheSoftwareRasterizer() throws {
    guard let r = try MetalFixtureHarness.replay("synthetic-primitives", upTo: 6) else { return }
    #expect(r.firstDivergence == nil, r.message)
}

@Test(.enabled(if: FileManager.default.fileExists(
                    atPath: FixtureFile.url(named: "pl-render-line").path),
               "pl-*.p1fx are build artifacts — run `zig build fixtures -Doptimize=ReleaseFast`"))
func replaysThePeterLemonLineRom() throws {
    // 60 mono lines and 20 shaded ones.
    guard let r = try MetalFixtureHarness.replay("pl-render-line") else { return }
    #expect(r.framesChecked == 17)
    #expect(r.firstDivergence == nil, r.message)
}
```

- [ ] **Step 5: Add the two line arms to the shader**

```metal
    } else if (p.kind == PS1_PRIM_LINE_PIXEL) {
        // A mono line does NOT dither — `drawLine` has no dither branch at all,
        // unlike `drawShadedLine`.
        src = ushort(p.color);
    } else if (p.kind == PS1_PRIM_SHADED_LINE_PIXEL) {
        int r = int(p.c0 & 0xFFu);
        int g = int((p.c0 >> 8) & 0xFFu);
        int b = int((p.c0 >> 16) & 0xFFu);
        if (p.steps != 0) {
            // floor, NOT truncation: (c1 - c0) is negative on a falling span.
            r += ps1_floor_div((int(p.c1 & 0xFFu) - r) * p.k, p.steps);
            g += ps1_floor_div((int((p.c1 >> 8) & 0xFFu) - g) * p.k, p.steps);
            b += ps1_floor_div((int((p.c1 >> 16) & 0xFFu) - b) * p.k, p.steps);
        }
        if (p.flags & PS1_PRIM_DITHER) {
            int o = ps1_dither(px, py);
            r += o; g += o; b += o;
        }
        src = ps1_pack(r, g, b);
    } else {
```

- [ ] **Step 6: Add the encoder arms**

In `MetalRasterizer`:

```swift
        case PS1_GPU_DRAW_LINE, PS1_GPU_DRAW_SHADED_LINE:
            encodeLine(cmd)
```

```swift
    /// One 1x1 instance per Bresenham step. The pixel itself is the box, so
    /// coverage is trivially true; the drawing-area clip and the mask still run
    /// in the shader's putPixel tail, exactly as `drawLine` calls `putPixel`.
    private func encodeLine(_ cmd: Ps1GpuCommand) {
        let shaded = cmd.commandKind == PS1_GPU_DRAW_SHADED_LINE
        let v = withUnsafeBytes(of: cmd.v) { raw -> [Ps1GpuVertex] in
            let p = raw.bindMemory(to: Ps1GpuVertex.self)
            return [p[0], p[1]]
        }
        let ox = env.offsetX, oy = env.offsetY
        guard let walk = LineExpander.walk(x0: Int(v[0].x) + ox, y0: Int(v[0].y) + oy,
                                           x1: Int(v[1].x) + ox, y1: Int(v[1].y) + oy)
        else { return }

        var proto = PrimBuilder.base(env)
        proto.kind = shaded ? PS1_PRIM_SHADED_LINE_PIXEL : PS1_PRIM_LINE_PIXEL
        proto.color = cmd.value & 0xFFFF
        proto.c0 = v[0].color
        proto.c1 = v[1].color
        proto.steps = Int32(walk.total)
        if cmd.transparent != 0 { proto.flags |= PS1_PRIM_TRANSPARENT }
        // A mono line never dithers; drawLine has no dither branch.
        if !shaded { proto.flags &= ~PS1_PRIM_DITHER }

        for step in walk.steps {
            // Outside VRAM the software path's putPixel returns immediately, so
            // skipping the instance is equivalent and saves the box clamp.
            guard step.x >= 0, step.x < MetalVram.width,
                  step.y >= 0, step.y < MetalVram.height else { continue }
            var inst = proto
            (inst.box_x0, inst.box_x1) = (Int32(step.x), Int32(step.x))
            (inst.box_y0, inst.box_y1) = (Int32(step.y), Int32(step.y))
            (inst.x0, inst.y0) = (Int32(step.x), Int32(step.y))
            inst.k = Int32(step.k)
            appendPrim(inst)
        }
    }
```

- [ ] **Step 7: Run**

```bash
zig build capi-lib && zig build metallib && ps1-macos/test.sh 2>&1 | tail -40
```
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add ps1-macos
git commit -m "$(cat <<'EOF'
feat(metal): lines, CPU-expanded to per-pixel instances

Bresenham's error accumulator has no closed form worth deriving, so the encoder
walks the same loop renderer.zig does and emits one 1x1 instance per step. The
colour stays in the shader as c0 + floor((c1-c0)*k/steps) — the form Phase 0
rewrote drawShadedLine into for exactly this — with a real floor division,
because (c1-c0) is negative on a falling span and MSL's / truncates.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Hazard detection, pass splitting, and the closing gate

Until now every mover ends the pass, which covers upload→sample and copy→sample. What it does not cover is **primitive→primitive**: a textured draw that samples a region an earlier draw in the *same pass* wrote. `synthetic-primitives` frame 6 is built to contain exactly that shape.

**Files:**
- Create: `ps1-macos/Sources/PS1/HazardTracker.swift`
- Create: `ps1-macos/Tests/PS1Tests/HazardTrackerTests.swift`
- Modify: `ps1-macos/Sources/PS1/MetalRasterizer.swift`, `PrimBuilder.swift`
- Modify: `ps1-macos/Tests/PS1Tests/MetalRasterizerTests.swift`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: everything above.
- Produces: `struct VramRect` (`x0`/`y0`/`x1`/`y1`, inclusive) with `func intersects(_ other: VramRect) -> Bool` and `mutating func union(_ other: VramRect)`; `struct HazardTracker` with `mutating func reset()`, `mutating func needsBreak(sampling rects: [VramRect]) -> Bool`, `mutating func markWritten(_ rect: VramRect)`; `PrimBuilder.sampledRects(of: Ps1PrimInstance) -> [VramRect]`.

- [ ] **Step 1: Write the failing tracker tests**

Create `ps1-macos/Tests/PS1Tests/HazardTrackerTests.swift`:

```swift
import Testing
import CPs1
@testable import PS1

@Test func aDrawThatSamplesNothingNeverBreaksThePass() {
    var h = HazardTracker()
    h.markWritten(VramRect(x0: 0, y0: 0, x1: 100, y1: 100))
    #expect(h.needsBreak(sampling: []) == false)
}

@Test func samplingOutsideTheDirtyRectDoesNotBreakThePass() {
    var h = HazardTracker()
    h.markWritten(VramRect(x0: 0, y0: 0, x1: 63, y1: 63))
    #expect(h.needsBreak(sampling: [VramRect(x0: 256, y0: 0, x1: 319, y1: 63)]) == false)
}

@Test func samplingWhatThisPassWroteBreaksIt() {
    var h = HazardTracker()
    h.markWritten(VramRect(x0: 0, y0: 0, x1: 63, y1: 63))
    #expect(h.needsBreak(sampling: [VramRect(x0: 60, y0: 60, x1: 200, y1: 200)]))
    // Breaking RESETS the dirty rect: the new pass has written nothing yet,
    // so the very next draw must not break again for the same reason.
    #expect(h.needsBreak(sampling: [VramRect(x0: 60, y0: 60, x1: 200, y1: 200)]) == false)
}

@Test func theClutRowIsCheckedSeparatelyFromTheTexturePage() {
    // A CLUT is one row, usually far from the page. Folding the two into one
    // bounding rect would span everything between them and split passes that
    // do not need splitting — which is a performance bug, not a correctness
    // one, and therefore invisible to every hash gate.
    var h = HazardTracker()
    h.markWritten(VramRect(x0: 0, y0: 480, x1: 255, y1: 480))   // a CLUT row
    let page = VramRect(x0: 512, y0: 0, x1: 575, y1: 255)
    let clut = VramRect(x0: 0, y0: 480, x1: 255, y1: 480)
    #expect(h.needsBreak(sampling: [page]) == false)
    h.markWritten(VramRect(x0: 0, y0: 480, x1: 255, y1: 480))
    #expect(h.needsBreak(sampling: [page, clut]))
}

@Test func aTexturedTriangleReportsItsPageAndClutAtTheRightDepth() {
    var inst = Ps1PrimInstance()
    inst.kind = PS1_PRIM_TEXTURED_TRI
    inst.tex_depth = 0          // 4bpp: u/4, so 64 words wide
    inst.tpage_x = 320
    inst.tpage_y = 256
    inst.clut_x = 640
    inst.clut_y = 300
    let rects = PrimBuilder.sampledRects(of: inst)
    #expect(rects.count == 2)
    #expect(rects[0] == VramRect(x0: 320, y0: 256, x1: 383, y1: 511))
    #expect(rects[1] == VramRect(x0: 640, y0: 300, x1: 655, y1: 300))

    inst.tex_depth = 1          // 8bpp: 128 words
    #expect(PrimBuilder.sampledRects(of: inst)[0].x1 == 447)
    inst.tex_depth = 2          // 16bpp: 256 words, and no CLUT read at all
    #expect(PrimBuilder.sampledRects(of: inst)[0].x1 == 575)
    #expect(PrimBuilder.sampledRects(of: inst).count == 1)
}
```

- [ ] **Step 2: Run and watch it fail**

Expected: `cannot find 'HazardTracker' in scope`.

- [ ] **Step 3: Implement**

Create `ps1-macos/Sources/PS1/HazardTracker.swift`:

```swift
import Foundation

/// An inclusive VRAM rectangle.
struct VramRect: Equatable {
    var x0: Int, y0: Int, x1: Int, y1: Int

    func intersects(_ o: VramRect) -> Bool {
        x0 <= o.x1 && o.x0 <= x1 && y0 <= o.y1 && o.y0 <= y1
    }

    mutating func formUnion(_ o: VramRect) {
        x0 = min(x0, o.x0); y0 = min(y0, o.y0)
        x1 = max(x1, o.x1); y1 = max(y1, o.y1)
    }
}

/// Per-draw hazard detection with render-pass splitting.
///
/// PS1 VRAM is the render target and the texture source at once. The invariant
/// that makes that legal on a tile-based GPU is: NOTHING SAMPLED DURING A
/// RENDER PASS MAY HAVE BEEN WRITTEN DURING THAT PASS. The tile being rendered
/// lives in tile memory and the rest of the attachment stays in device memory
/// until the store action runs, so a read() sees the pre-pass contents — right
/// for a region an earlier PASS wrote, stale for one an earlier DRAW in this
/// pass wrote. This forbids the second case.
///
/// Programmable blending is unaffected: it reads the same pixel through tile
/// memory, which is a different mechanism from sampling an arbitrary address.
///
/// Ordering is preserved by construction and pathological content degrades
/// into many small passes rather than into wrong pixels. Do NOT weaken this to
/// buy speed — the pass count is reported, so the cost is visible.
struct HazardTracker {
    private var dirty: VramRect?

    mutating func reset() { dirty = nil }

    /// True when this draw must begin a new render pass. Resets the dirty rect
    /// when it returns true, because the new pass has written nothing yet.
    mutating func needsBreak(sampling rects: [VramRect]) -> Bool {
        guard let d = dirty, rects.contains(where: { $0.intersects(d) }) else { return false }
        dirty = nil
        return true
    }

    mutating func markWritten(_ rect: VramRect) {
        if dirty == nil { dirty = rect } else { dirty!.formUnion(rect) }
    }
}
```

In `PrimBuilder`:

```swift
    /// What a primitive reads, as up to two rectangles: its texture page and,
    /// at 4bpp/8bpp, its CLUT row.
    ///
    /// Two rectangles rather than one bounding box on purpose. A CLUT usually
    /// sits far from the page it serves, and a box spanning both would cover
    /// most of VRAM — splitting passes that need no split. That costs
    /// throughput without moving a single pixel, so no hash gate would ever
    /// notice.
    ///
    /// Conservative on the page: v is an 8-bit field, so a page is 256 rows
    /// tall, and its width in VRAM words is 64 / 128 / 256 by depth.
    static func sampledRects(of inst: Ps1PrimInstance) -> [VramRect] {
        guard inst.kind == PS1_PRIM_TEXTURED_TRI || inst.kind == PS1_PRIM_TEXTURED_RECT else {
            return []
        }
        let words = [64, 128, 256][min(Int(inst.tex_depth), 2)]
        let px = Int(inst.tpage_x), py = Int(inst.tpage_y)
        var out = [VramRect(x0: px, y0: py,
                            x1: min(px + words - 1, MetalVram.width - 1),
                            y1: min(py + 255, MetalVram.height - 1))]
        if inst.tex_depth < 2 {
            let cx = Int(inst.clut_x), cy = Int(inst.clut_y)
            let entries = inst.tex_depth == 0 ? 16 : 256
            out.append(VramRect(x0: cx, y0: cy,
                                x1: min(cx + entries - 1, MetalVram.width - 1), y1: cy))
        }
        return out
    }
```

In `MetalRasterizer.appendPrim`, consult the tracker before extending the run:

```swift
    private var hazards = HazardTracker()

    private func appendPrim(_ inst: Ps1PrimInstance) {
        if hazards.needsBreak(sampling: PrimBuilder.sampledRects(of: inst)) {
            breakPass()
        }
        hazards.markWritten(VramRect(x0: Int(inst.box_x0), y0: Int(inst.box_y0),
                                     x1: Int(inst.box_x1), y1: Int(inst.box_y1)))
        let i = instances.count
        instances.append(inst)
        if case let .draw(kind, range)? = steps.last, kind == .prim, range.upperBound == i {
            steps[steps.count - 1] = .draw(kind: .prim, range: range.lowerBound..<(i + 1))
        } else {
            steps.append(.draw(kind: .prim, range: i..<(i + 1)))
        }
    }
```

and reset it wherever a pass ends. In `breakPass()`:

```swift
    private func breakPass() {
        hazards.reset()
        if case .passBreak? = steps.last { return }
        steps.append(.passBreak)
    }
```

and as the first statement of `beginFrame(payload:)` — a frame boundary is a pass boundary, because `endFrame` committed and stored, so nothing the new frame samples can be stale from the last one:

```swift
        hazards.reset()
```

- [ ] **Step 4: Extend the gate to every frame and every fixture**

In `MetalRasterizerTests.swift`:

```swift
@Test func theFeedbackFrameMatchesTheSoftwareRasterizer() throws {
    // Frame 6 samples a page this very frame drew into. Without pass splitting
    // the read is stale and the hash moves.
    guard let r = try MetalFixtureHarness.replay("synthetic-primitives") else { return }
    #expect(r.framesChecked == 7)
    #expect(r.firstDivergence == nil, r.message)
}

// MARK: - The phase gate
//
// Byte-identical full 1024x512 VRAM on every frame of every fixture. This is a
// strictly stronger check than test-roms-pl, which compares a 320x224 display
// window reduced to 5-bit against a per-test floor and is a ratchet.

private let allGeneratedFixtures = [
    "pl-hello-world", "pl-cpu-add", "pl-render-polygon", "pl-render-line",
    "pl-render-rectangle", "pl-render-texture-polygon",
    "croc-legend-of-the-gobbos",
] + geometryFixtures

@Test(.enabled(if: allGeneratedFixtures.contains(where: {
                    FileManager.default.fileExists(atPath: FixtureFile.url(named: $0).path) }),
               "generated fixtures are absent — run `zig build fixtures -Doptimize=ReleaseFast`"))
func everyFixtureIsByteIdenticalOnEveryFrame() throws {
    var checked = 0
    for name in allGeneratedFixtures {
        guard FileManager.default.fileExists(atPath: FixtureFile.url(named: name).path) else { continue }
        guard let r = try MetalFixtureHarness.replay(name) else { return }
        checked += 1
        #expect(r.firstDivergence == nil, r.message)
        // The pass count and the frame count, printed on SUCCESS as well as
        // failure: pass-splitting cost was unknown until the geometry fixtures
        // existed to measure it on, and this is the measurement.
        print("[phase-b] \(name): \(r.framesChecked) frames, \(r.passCount) passes")
    }
    #expect(checked > 0)
}
```

`geometryFixtures` lives in `FixtureBridgeTests.swift` and is `internal`, so it is visible here without redeclaring it.

- [ ] **Step 5: Run the whole ladder**

```bash
zig build capi-lib && zig build metallib && zig build fixtures -Doptimize=ReleaseFast
ps1-macos/test.sh 2>&1 | tee /tmp/phaseb.log | tail -60
grep '\[phase-b\]' /tmp/phaseb.log
```
Expected: PASS. Record the per-fixture pass counts and the wall-clock of `everyFixtureIsByteIdenticalOnEveryFrame` (xcodebuild prints a per-test duration) in the commit message — that is the "pass-count and frame-time reported on the geometry fixtures" half of the spec's Task 10 gate.

If a geometry fixture's pass count is pathological (more passes than draw records), the hazard rects are too conservative, not the design — check `sampledRects` before touching `HazardTracker`.

- [ ] **Step 6: Confirm the freeze gates one last time**

```bash
zig build test
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
zig build test-roms-pl -Doptimize=ReleaseFast > /tmp/pl.log 2>&1; echo "exit $?"
```
Expected: all green. Phase B changed no emulated behaviour, so any movement here is a bug in this phase.

- [ ] **Step 7: Update `CLAUDE.md`**

Three edits:

1. In the **Quick commands** table, after the `fixtures` row, note that `zig build metallib` now compiles **both** `.metal` sources into one library.

2. In **The macOS app** § the display-shader bullet, change "The display shader is compiled OFFLINE" to cover both shaders, and rename `ps1_display_metallib_ptr/len` → `ps1_metallib_ptr/len` and `Sources/CPs1/include/display_metallib.h` → `metallib.h`.

3. Add a new paragraph after the fixture-bridge paragraph in the **Per-subsystem cheat-sheet**:

```markdown
**The Metal backend runs at 1x and is fixture-driven only.** Nothing in
`ps1-macos/Sources/PS1/Metal*.swift` is wired into the running app — that is
Phase D. `MetalRasterizer` consumes a `.p1fx` stream and produces VRAM
byte-identical to the software rasterizer, checked per frame by
`MetalRasterizerTests`. Four things about it are load-bearing and easy to
"fix" wrongly: **coverage is decided in the FRAGMENT shader**, never by Metal's
rasterizer, whose fill rule and sample positions are not the PS1's; **blending
is integer arithmetic on 5-bit channels**, never fixed-function blending, which
normalizes to float and rounds differently; **every primitive is one instance
of a bounding-box quad** with all its state resolved on the CPU into a
`Ps1PrimInstance`, which is what leaves no pipeline state differing between
primitives and therefore nothing to break a batch on; and **a draw that samples
what the current render pass has already written must end that pass first**
(`HazardTracker`) — on a tile-based GPU such a read returns pre-pass contents,
so without the split it is silently stale. `synthetic-primitives.p1fx` is the
per-feature gate ladder, committed, one feature group per frame in a fixed
order that the Swift tests index by number; append to it, never reorder it.
```

- [ ] **Step 8: Commit**

```bash
git add ps1-macos CLAUDE.md
git commit -m "$(cat <<'EOF'
feat(metal): hazard detection, pass splitting, and the Phase B gate

A draw whose sampled region — texture page plus CLUT — intersects what the
current render pass has already written now ends the pass and starts a new one.
On a tile-based GPU a read() of the attachment returns PRE-PASS contents, which
is correct for a region an earlier pass stored and stale for one an earlier
draw in the same pass wrote; this forbids the second case. Ordering is
preserved by construction.

The page and the CLUT are tracked as two rectangles, not one bounding box: a
CLUT sits far from its page and a box spanning both would split passes that
need no split — a throughput bug no hash gate could see.

Phase B gate met: full 1024x512 VRAM byte-identical to the software rasterizer
on every frame of every fixture.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Appendix: what Phase B does NOT do

Stated here because each is a plausible-looking next step that belongs to a later phase:

- **No live ABI handoff.** No `ps1_take_frame_stream`, no `gpu_sink = .dual` for `ps1-capi`, no queue, no frame pacing, no app integration. Adding an ABI entry point a phase before it has a consumer ships untested surface; Phase D adds it with a live consumer on day one.
- **No upscaling.** Scale is fixed at 1 throughout. Phase C.
- **No 24bpp scanout** — it stays on the shadow permanently — and no display path at all. Phase B never presents anything.
- **No change to the software rasterizer's output.** Phase 0 was the only phase permitted that, and every fixture hash in the corpus is frozen against it.
- **No performance work.** Bounding-box overdraw and per-flush buffer allocation are both known and both deliberate: PS1 triangles are small, the oversized-primitive rule caps any primitive at 1023×511, and the discard is a handful of integer ops. Measure before optimising — Task 11 prints the measurement.
