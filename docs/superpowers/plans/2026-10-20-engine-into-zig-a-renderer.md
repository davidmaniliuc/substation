# Engine into Zig, Plan A: the headless Zig renderer

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Zig module, `ps1-metal/`, that does everything the Swift Metal renderer does below the window (VRAM on the GPU, the rasterizer, the frame queue and its resync rules, runahead replay, the display pass and screenshots), proven by every renderer gate the Swift suite runs today, now running under `zig build test-metal`.

**Architecture:** A typed wrapper over the Objective-C runtime (`objc.zig`, `mtl.zig`) is the only code that sees a selector. On top of it, the Swift renderer files are ported one for one, logic unchanged, except that the three Swift duplicates of core code (`DrawEnv`, `VramTransfer`, `LineExpander`) are replaced by the core's own `DrawingEnv`, a new core `WriteCursor` and a new core `LineWalk`, and the fixture bridge is replaced by `ps1-golden/src/fixture.zig` plus an in-process software replay. Nothing in this plan touches the app. Plan B builds the session and its threads on top of this module, and Plan C switches the app over and deletes the Swift code.

**Tech Stack:** Zig 0.17.0, Metal, QuartzCore, CoreGraphics, ImageIO and libobjc through their C ABIs, and the existing offline-compiled `ps1.metallib`.

**Spec:** `docs/superpowers/specs/2026-10-20-metal-renderer-into-zig-design.md`. This plan implements the spec's "Order of work" steps 1-5 and the renderer half of step 6 (`ps1-bench`). The spec's step 1 asks for the runtime class and a display link too; both belong to the render thread and move to Plan B.

## The three plans

- **Plan A (this one):** `ps1-metal/`, headless, gated by `test-metal`. The app is untouched.
- **Plan B:** `ps1-session/`: the emulator thread, audio, cards, requests, the render thread with its `CAMetalLayer` and display link, and the session C ABI. Written once Plan A has landed, against Plan A's real interfaces.
- **Plan C:** the lockstep against the Swift renderer, the performance comparison, switching the app over, the hand checks, deleting the Swift code, and the docs.

## Global Constraints

- Zig **0.17.0**; `build.zig.zon` gains **no** dependency.
- **No file in `ps1-metal/` over about 600 lines** (CLAUDE.md's `ps1-core/src` rule, extended by the spec).
- **Raw `objc_msgSend` appears in `ps1-metal/src/objc.zig` only**; selectors appear in `objc.zig` and `mtl*.zig` only.
- **No Metal, Objective-C, CoreAudio or threads in `ps1-core/src`.** Tasks 1 and 2 add pure Zig to the core and nothing else.
- **No golden, fixture hash or `.p1fx` is recaptured.** A moved hash is a bug in the port.
- **No gate is weakened.** Every Swift test named in the port table below is ported with the same inputs and the same assertions, or retired with the reason written in the table.
- **The shaders are not edited** and stay compiled offline into `ps1.metallib` (`zig build metallib`). Never `newLibraryWithSource:`.
- **`ps1-metal` finds the metallib through `ps1_metallib_ptr()`/`ps1_metallib_len()`** (`ps1-macos/Shaders/embed.zig`), declared `extern` and resolved at link time, so `capi-lib` stays buildable without the Metal toolchain.
- **`zig build test` keeps passing on a machine with no Metal.** `test-metal` is a separate, macOS-only step.
- **Every `.p1fx` corpus gate runs `-Doptimize=ReleaseFast`.**
- **Every rule in CLAUDE.md's "GPU + Metal" section holds**, and so does the reasoning in the Swift comments being ported: port the comments that carry a rule along with the code, and drop the ones that only explain Swift.
- Commit messages are **a title line only** (CLAUDE.md), one commit per task at least, on master.
- Run `zig fmt` before every commit.

## Review Focus

These are five conditions the spec implies but no ported Swift test covers. Each has a test added to the task that owns it.

1. **A long session leaks GPU memory.** Ported code that forgets a `release`, or creates autoreleased objects outside a pool, grows without bound in the app. Expected: replaying the corpus three times, or building and freeing a scale-8 renderer twenty times, leaves `-[MTLDevice currentAllocatedSize]` where the first pass left it. *Tests: Task 4 and Task 10.*
2. **A frame with more instances than the first instance buffer.** Lines expand to one instance per pixel, so a frame of long lines passes 65,536 instances. Expected: the buffer grows and the frame still matches the software rasterizer. *Test: Task 6.*
3. **Metal API misuse that a release build tolerates in silence**: a wrong enum value, an unbound texture, a bad stride. Expected: one corpus pass under the Metal validation layer runs clean. *Test: Task 3, the `test-metal-validate` step.*
4. **A fixture or a Metal device is missing.** Expected: a skip that names what is missing, never a crash and never a pass. *Test: Task 6.*
5. **A completion block that outlives its caller.** A screenshot's block can fire after the renderer that asked for it is gone. Expected: the block owns what it touches, and a renderer freed with a screenshot in flight neither crashes nor loses the answer. *Test: Task 11.*

---

## File structure

```
ps1-core/src/gpu/line_walk.zig        NEW  the Bresenham walk drawLine/drawShadedLine and ps1-metal share
ps1-core/src/gpu/write_cursor.zig     NEW  the CPU->VRAM cursor plus run planning; Vram's writeData is its reference
ps1-core/src/gpu/renderer.zig         MOD  drawLine/drawShadedLine walk with LineWalk
ps1-core/src/root.zig                 MOD  re-export gpu.LineWalk, gpu.WriteCursor
ps1-core/tests/gpu_walk_test.zig      NEW  LineWalk + WriteCursor tests (joins unit_test_files)

ps1-metal/src/root.zig                NEW  re-exports
ps1-metal/src/objc.zig                NEW  msgSend, selectors, classes, retain/release, pools, blocks, NSString
ps1-metal/src/mtl.zig                 NEW  Device, CommandQueue, Buffer, Texture, descriptors, Library, Function, pipelines
ps1-metal/src/mtl_encode.zig          NEW  CommandBuffer, RenderPassDescriptor, render and blit encoders
ps1-metal/src/mtl_enums.zig           NEW  the Metal enum values used, each pinned to its SDK header line
ps1-metal/src/shaders.zig             NEW  library from ps1_metallib_ptr/len
ps1-metal/src/prim_instance.zig       NEW  PrimInstance (extern), Uniforms, PS1_PRIM_* kinds/flags, VramRect, settings enums
ps1-metal/src/metal_vram.zig          NEW  port of MetalVram.swift
ps1-metal/src/hazard_tracker.zig      NEW  port of HazardTracker.swift
ps1-metal/src/prim_builder.zig        NEW  port of PrimBuilder.swift
ps1-metal/src/rasterizer.zig          NEW  port of MetalRasterizer.swift (pipelines, frame buffers, passes)
ps1-metal/src/prim_encoders.zig       NEW  port of PrimEncoders.swift (lines, fill, depth clear, copy, upload)
ps1-metal/src/stream_queue.zig        NEW  port of StreamQueue.swift minus claimConsumer and StreamBackpressure
ps1-metal/src/speculative_region.zig  NEW  port of SpeculativeRegion.swift
ps1-metal/src/live_renderer.zig       NEW  port of LiveRenderer.swift
ps1-metal/src/display.zig             NEW  DisplayParams, letterboxScale, DrawFade, PauseFade, ToolbarBand.apply, DisplayPass
ps1-metal/src/screenshot.zig          NEW  Screenshot.size/encode/bytes
ps1-metal/src/png.zig                 NEW  BGRA -> PNG through CoreGraphics + ImageIO

ps1-metal/tests/pure_test.zig         NEW  root of the no-Metal binary (joins `zig build test`)
ps1-metal/tests/metal_test.zig        NEW  root of the test-metal binary
ps1-metal/tests/harness.zig           NEW  device/skip helpers, fixture corpus, Gate 1 replay, scale frame, VRAM dumps
ps1-metal/tests/*_test.zig            NEW  one file per ported Swift test file (see the port table)

ps1-bench/src/gpu_main.zig            NEW  ps1-bench-gpu: the renderer benchmark (GpuBench port)
build.zig                             MOD  ps1-metal module, test-metal, test-metal-validate, pure tests, ps1-bench-gpu
```

## The port table

Every renderer-side Swift test file, and what becomes of it. "Port" means the same test name in snake_case-free Zig test syntax (`test "aTexelThatModulatesToBlackIsDrawnRatherThanDiscarded"`), the same inputs and the same assertions. The implementer reads the Swift test and transcribes it.

| Swift file | Fate | Zig file | Task |
|---|---|---|---|
| `LineExpanderTests` (4) | port against `LineWalk` | `ps1-core/tests/gpu_walk_test.zig` | 1 |
| `MetalMoverTests`: the 7 `VramTransfer` cases | port against `WriteCursor`; `planAndConsumeAgreeOnWhereTheCursorEndsUp` becomes `planAgreesWithVramWriteDataOnWhereTheCursorEndsUp`, with `Vram.writeData` as the reference | `ps1-core/tests/gpu_walk_test.zig` | 2 |
| `DrawEnvTests` (6) | **retired**: `DrawEnv` is deleted. The Zig side calls `registers.zig` and `command.applyEnv`, which `gpu_test.zig` covers | — | — |
| `FixtureBridgeTests` (21) | **retired**: `FixtureFile`, `Fnv1a` and `ShadowVram` are deleted. `ps1-golden/src/fixture_test.zig` already covers the format, and Task 6's Gate 1 compares against `command.execute` itself. Two have no Zig twin: `gpuCommandKindOrdinalsAreFrozen` (port to `fixture_test.zig`) and `theCommittedPrimitivesFixtureHasTheDocumentedShape` (port to `harness_test.zig`) | `ps1-golden/src/fixture_test.zig`, `ps1-metal/tests/harness_test.zig` | 6 |
| `DisplayShaderTests` (1), `MetalVramTests`: `theRasterizerVertexFunctionAndFillPipelineBuild` | port | `ps1-metal/tests/smoke_test.zig` | 3 |
| `MetalVramTests` (22) | port; the three `vramDump*`/`report*` and the two PNG-writer cases move with `VramDump`/`VramImage` to the harness | `vram_test.zig`, `harness_test.zig` | 4, 6 |
| `HazardTrackerTests` (9) | port | `hazard_test.zig` (pure) | 5 |
| `MetalMoverTests`: the 7 GPU cases | port | `mover_test.zig` | 6 |
| `MetalRasterizerTests` (22) | port | `rasterizer_test.zig` | 6 |
| `MetalScaleTests` (32, Gates 2-4) | port; the two marker-file gates read `PS1_DUMP_SCALED`/`PS1_SCALE_TIMING` from the environment | `scale_test.zig`, `scale_gate_test.zig` | 7 |
| `TextureFilterTests` (22), `TrueColourTests` (10), `PgxpParityTests` (4), `InterpolationExactnessTests` (1) | port | `filter_test.zig`, `true_colour_test.zig`, `pgxp_parity_test.zig`, `interp_fuzz_test.zig` | 8 |
| `StreamQueueTests` (21) | port 19; **retire** `theProducerWaitsForAFullQueueRatherThanDroppingAFrame` and `aRendererThatStopsDrainingIsGivenUpOnUntilItDrainsAgain`, because `StreamBackpressure` is deleted and Plan B replaces it with a condition-variable wait that gets its own tests | `queue_test.zig` (pure) | 9 |
| `SpeculationTests` (5) | port | `speculation_test.zig` (region cases pure, the replay gate on Metal) | 9, 10 |
| `LiveRendererTests` (16) | port | `live_renderer_test.zig` | 10 |
| `LiveRendererScaleTests` (9) | port 6; **move to Plan B** `buildingTheCoordinatorRaisesAResyncOnTheRunnersQueue`, `aRebuildSupersedesTheCoordinatorItReplaces` and `theCoordinatorBuildsItsRendererAtTheScaleItWasGiven`, because the coordinator becomes a scale message to the render thread | `live_renderer_scale_test.zig` | 10 |
| `DisplayRenderTests` (11), `DisplayScaleTests` (8), `LetterboxTests` (5) | port | `display_test.zig`, `display_scale_test.zig` | 11 |
| `ScreenshotTests` (6) | port 4 (`theHeightIs…`, `aDisabledDisplay…`, `aPngRoundTrips…`, `theOffscreenPass…`); `theFileIsNamedForTheGameAndTheMoment` and `aRequestIsTakenOnce` stay in Swift (naming) or go to Plan B (requests) | `screenshot_test.zig` | 11 |
| `GpuBenchTests` (1) | port | `ps1-bench/src/gpu_bench_test.zig` | 12 |
| `RunaheadTests`, `ResumeThumbnailTests` | Plan B (orchestration and thumbnails are session work) | — | — |

---

### Task 1: `LineWalk` in the core, shared by both line paths

**Files:**
- Create: `ps1-core/src/gpu/line_walk.zig`
- Modify: `ps1-core/src/gpu/renderer.zig:473-560` (`drawLine`, `drawShadedLine`)
- Modify: `ps1-core/src/root.zig` (re-export `gpu.LineWalk`)
- Create: `ps1-core/tests/gpu_walk_test.zig`; Modify: `build.zig` `unit_test_files` (add it)

**Interfaces:**
- Produces:
  ```zig
  pub const LineWalk = struct {
      pub const Step = struct { x: i32, y: i32, k: i32 };
      /// max(|dx|, |dy|): drawShadedLine's denominator.
      steps: i32,
      /// Null for a line hardware refuses: |dx| >= 1024 or |dy| >= 512.
      /// Coordinates arrive with GP0(E5)'s offset ALREADY applied.
      pub fn init(x0: i32, y0: i32, x1: i32, y1: i32) ?LineWalk;
      /// Yields every pixel from (x0, y0) to (x1, y1) inclusive, then null.
      pub fn next(self: *LineWalk) ?Step;
  };
  ```

- [ ] **Step 1: Write the failing tests.** Port `LineExpanderTests.swift`'s four cases to `gpu_walk_test.zig` against `LineWalk` (`aHorizontalLineIsOnePixelPerColumnInclusive`, `aZeroLengthLineIsExactlyOnePixel`, `allEightOctantsEndOnTheirEndpoint`, `anOversizedLineIsDroppedNotClipped`), plus one new case, `theWalkVisitsWhatDrawLinePaints`: for 200 seeded random lines within ±1100 px, draw with `Renderer.drawLine` into a blank `Vram` (drawing area the whole of VRAM, colour 0x7FFF) and require the set of painted pixels to equal the set of in-VRAM `LineWalk` steps.
- [ ] **Step 2:** Run `zig build test -Dtest-filter=LineWalk`. Expected: compile FAIL, `LineWalk` undefined.
- [ ] **Step 3:** Implement `line_walk.zig` with exactly the loop in `renderer.zig:473-500`, in `i32`. Rewrite `drawLine` and `drawShadedLine` to iterate `LineWalk` and call `putPixel` per step, with `drawShadedLine` taking `k` and `steps` from the walk. No other change to either function.
- [ ] **Step 4:** Run `zig build test`. Expected: all pass.
- [ ] **Step 5:** Run `zig build -Doptimize=ReleaseFast trace-golden -- verify` and `zig build -Doptimize=ReleaseFast trace-golden -- stream-verify`. Expected: every workload matches; nothing recaptured.
- [ ] **Step 6:** Commit: `refactor(gpu): one line walk shared by drawLine and drawShadedLine`

### Task 2: `WriteCursor` in the core, pinned to `Vram.writeData`

**Files:**
- Create: `ps1-core/src/gpu/write_cursor.zig`
- Modify: `ps1-core/src/root.zig` (re-export `gpu.WriteCursor`)
- Modify: `ps1-core/tests/gpu_walk_test.zig`

**Interfaces:**
- Produces:
  ```zig
  pub const WriteCursor = struct {
      active: bool = false,
      x: i32 = 0, y: i32 = 0,
      /// After Vram.axisExtent: 0 means the whole axis.
      w: usize = 0, h: usize = 0,
      pub const Run = struct { first: usize, last: usize, consumed: usize };
      pub fn setup(x: i32, y: i32, w: i32, h: i32) WriteCursor;
      pub fn abort(self: *WriteCursor) void;
      pub fn pixelCount(self: WriteCursor) usize;
      /// Advances by up to `words` words and reports the contiguous slice of
      /// transfer PIXEL indices they cover. `first` is always even.
      pub fn plan(self: *WriteCursor, words: usize) ?Run;
  };
  ```
  Ported from `VramTransfer.swift` minus `consume`/`WordPixels`, which only the deleted `ShadowVram` used. The reference is `Vram.writeData`, not a second transcription.

- [ ] **Step 1: Write the failing tests.** Port `MetalMoverTests.swift`'s transfer cases against `WriteCursor` (`aZeroExtentMeansTheWholeAxis`, `eachWordIsTwoPixelsInRowMajorOrder`, `vramTransferDropsTheFinalHalfWordOfAnOddSizedRun`, `wordsAfterTheTransferEndsAreIgnored`, `abortStopsTheTransferMidFlight`, `planReportsTheContiguousPixelRunAWordBatchCovers`). Add `planAgreesWithVramWriteDataOnWhereTheCursorEndsUp`: for every (w, h) in {1..5} x {1..4} plus (0, 1), (1024, 1), (3, 512), and word batches of 1, 2, 3 and 7, feed words through `plan` and the same words through `Vram.setupWrite`/`Vram.writeData`, and require that the pixels `Vram` wrote are exactly `first..last` of the runs, in order, and that `active` agrees with `Vram.write_active` after every batch.
- [ ] **Step 2:** Run `zig build test -Dtest-filter=WriteCursor`. Expected: compile FAIL.
- [ ] **Step 3:** Implement `write_cursor.zig`. `setup` takes `w`/`h` through `Vram.axisExtent` and sets `remaining = Vram.transferWords(w, h)`, so the word arithmetic is the core's own.
- [ ] **Step 4:** Run `zig build test`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(gpu): a write cursor that plans upload runs, pinned to Vram.writeData`

### Task 3: `test-metal`, the Objective-C wrapper and the shader library

**Files:**
- Create: `ps1-metal/src/{root,objc,mtl,mtl_encode,mtl_enums,shaders}.zig`
- Create: `ps1-metal/tests/{metal_test,pure_test,smoke_test}.zig`
- Modify: `build.zig`

**Interfaces:**
- Produces, `objc.zig`:
  ```zig
  pub const Id = *opaque {};          // any Objective-C object
  pub const Class = *opaque {};
  pub const Sel = *opaque {};
  pub fn class(comptime name: [:0]const u8) Class;   // cached; panics naming a missing class
  pub fn sel(comptime name: [:0]const u8) Sel;       // cached per selector
  /// objc_msgSend cast to fn(target, Sel, args...) callconv(.c) R. The fn type
  /// is built with 0.17's type-construction builtins from `args`' tuple type.
  pub fn msg(comptime R: type, target: anytype, comptime selector: [:0]const u8, args: anytype) R;
  pub fn retain(o: Id) Id;
  pub fn release(o: Id) void;
  pub fn nsString(s: [:0]const u8) Id;               // autoreleased
  pub const Pool = struct { token: *anyopaque, pub fn push() Pool, pub fn pop(Pool) void };
  /// A block taking one object, e.g. MTLCommandBuffer's completed handler.
  /// Built as a stack literal (isa = _NSConcreteStackBlock, flags 0,
  /// descriptor { 0, @sizeOf(literal) }) that carries `*Ctx`; the callee's
  /// Block_copy moves it to the heap. Valid only for the call it is passed to.
  pub fn Block(comptime Ctx: type, comptime invoke: fn (*Ctx, Id) void) type; // .init(ctx: *Ctx), .ptr()
  ```
- Produces, `mtl.zig` / `mtl_encode.zig`: `Device` (`createSystemDefault() ?Device`, `newCommandQueue`, `newTexture`, `newBuffer`, `newLibraryWithData`, `newRenderPipelineState`, `currentAllocatedSize`), `CommandQueue`, `Buffer` (`contents`, `length`), `Texture` (`width`, `height`, `pixelFormat`, `replaceRegion`, `getBytes`), `TextureDescriptor`, `Library` (`newFunction`, `newFunctionWithConstants`), `FunctionConstantValues`, `RenderPipelineDescriptor`, `RenderPipelineState`, `CommandBuffer` (`renderCommandEncoder`, `blitCommandEncoder`, `commit`, `waitUntilCompleted`, `addCompletedHandler(block)`, `gpuStartTime`, `gpuEndTime`, `setLabel`), `RenderPassDescriptor` (colour attachment `texture`/`loadAction`/`storeAction`/`clearColor` by index), `RenderCommandEncoder` (`setRenderPipelineState`, `setVertexBuffer`, `setFragmentBuffer`, `setVertexBytes`, `setFragmentBytes`, `setFragmentTexture`, `drawPrimitives`, `drawPrimitivesInstanced`, `endEncoding`), `BlitCommandEncoder` (buffer-to-texture, texture-to-buffer, texture-to-texture with origin and size, `synchronizeResource`, `endEncoding`), and `Origin`/`Size`/`Region`/`ClearColor` as `extern struct`s passed by value. Each wrapper is `struct { id: objc.Id }`; a `new…`/`create…` result is owned by the caller and released with `.release()`.
- Produces, `mtl_enums.zig`: `PixelFormat` (`r16Uint`, `rgba8Uint`, `r32Uint`, `bgra8Unorm`), `StorageMode` (`shared`, `managed`, `private`, `memoryless`), `TextureUsage` bits (`shaderRead`, `shaderWrite`, `renderTarget`), `LoadAction`, `StoreAction`, `PrimitiveType` (`triangle`, `triangleStrip`), `DataType` (`int`, `bool`), and `resourceOptions(StorageMode)`. **Every value is copied from the SDK header** (`$(xcrun --show-sdk-path)/System/Library/Frameworks/Metal.framework/Headers/`), with the header's name in a comment beside it.
- Produces, `shaders.zig`: `pub fn makeLibrary(device: mtl.Device) !mtl.Library`, over `extern fn ps1_metallib_ptr() [*]const u8` and `extern fn ps1_metallib_len() usize`, through `dispatch_data_create` with the default destructor (it copies the blob once).
- Produces, `build.zig`: a `ps1_metal` module (root `ps1-metal/src/root.zig`, imports `ps1_core` = the recording core module and `fixture` = `ps1-golden/src/fixture.zig` for tests); a `test-metal` step (macOS with the Metal toolchain; elsewhere `b.addFail` with the same three-step message `metallib` uses) whose binary links `Metal`, `QuartzCore`, `CoreGraphics`, `ImageIO`, `CoreFoundation`, `objc` and the `shader_obj` object; **`-Dmetal-filter=<substring>`**; and a `test-metal-validate` step that is the same binary run with `MTL_DEBUG_LAYER=1` and `MTL_SHADER_VALIDATION=1` and its filter fixed to `"corpus"`. `pure_test.zig` is added to `zig build test` as its own binary, with no framework linked.

- [ ] **Step 1: Write the failing smoke tests** in `smoke_test.zig`:
  - `aTextureClearedByARenderPassReadsBackThroughACompletionBlock`: a 4x4 `.r16Uint` private texture, cleared to `(0x1234, 0, 0, 0)` by a render pass, blitted to a shared buffer. The completion block stores `true` into its context. After `waitUntilCompleted`, the flag is set and all 16 words read `0x1234`.
  - Port `displayShaderCompilesAndExposesBothFunctions` (`display_vertex` and `display_fragment` exist in the library) and `theRasterizerVertexFunctionAndFillPipelineBuild`.
  - `everyEnumValueMatchesItsHeader`: for each `mtl_enums` value, check it against the value the SDK header gives, read at build time through `b.addTranslateC` over `<Metal/MTLPixelFormat.h>`-style headers if 0.17's translate-c accepts them; if it does not, replace this test with a `// verified against <header>:<line>` comment on each value, and have the reviewer check them.
  - Every Metal test starts with `const env = try harness.metal();`, which returns `error.SkipZigTest` and prints `no Metal device` when `createSystemDefault` is null.
- [ ] **Step 2:** Run `zig build test-metal`. Expected: compile FAIL (modules missing).
- [ ] **Step 3:** Implement `objc.zig`, the parts of `mtl*.zig` the smoke tests need, `mtl_enums.zig`, `shaders.zig`, and the `build.zig` wiring. Grow the wrappers task by task from here: each later task adds the methods it uses, and nothing is added speculatively.
- [ ] **Step 4:** Run `zig build test-metal` and `zig build test`. Expected: both pass. Check that `zig build capi-lib` still builds without the Metal toolchain, by building with `PATH` lacking Xcode (or by reading the build graph): `ps1_metal` must not be a dependency of `capi-lib` yet.
- [ ] **Step 5:** Commit: `feat(metal): a typed Objective-C wrapper, the shader library and a test-metal step`

### Task 4: `PrimInstance` and `MetalVram`

**Files:**
- Create: `ps1-metal/src/prim_instance.zig`, `ps1-metal/src/metal_vram.zig`
- Create: `ps1-metal/tests/vram_test.zig`

**Interfaces:**
- Produces, `prim_instance.zig`:
  ```zig
  pub const PrimInstance = extern struct { /* PrimInstance.h's 54 fields, same order, i32/u32 */ };
  pub const Uniforms = extern struct { scale: u32, dither_mode: u32, texture_filter: u32, sprite_filter: u32 };
  pub const Kind = struct { pub const flat_tri: i32 = 0, … depth_clear = 10 };  // PS1_PRIM_*
  pub const Flag = struct { pub const transparent: u32 = 1 << 0, … depth_write = 1 << 8 };
  pub const DitherMode = enum(u32) { off = 0, native = 1, scaled = 2, true_color = 3 };
  pub const TextureFilter = enum(u32) { nearest = 0, bilinear = 1 };
  pub const default_dither: DitherMode = .true_color;   // DitherSetting.defaultMode
  pub const VramRect = struct { x0: i32, y0: i32, x1: i32, y1: i32,
      pub fn intersects(a: VramRect, b: VramRect) bool, pub fn unionWith(a: VramRect, b: VramRect) VramRect };
  pub const native_width = 1024; pub const native_height = 512; pub const native_pixels = native_width * native_height;
  comptime { assert(@sizeOf(PrimInstance) == 4 * 54); assert(@sizeOf(Uniforms) == 16); }
  ```
  `PrimInstance` is declared by hand only if `b.addTranslateC` over `ps1-macos/Shaders/PrimInstance.h` does not work in 0.17. Prefer translate-c: it removes a second copy. Either way the `comptime` asserts stay, and so does an `@offsetOf` assert for `kind`, `qx0`, `rw0`, `iz2`.
- Produces, `metal_vram.zig`:
  ```zig
  pub const MetalVram = struct {
      scale: u32, device: mtl.Device, queue: mtl.CommandQueue,
      texture: mtl.Texture, sidecar: mtl.Texture, depth: mtl.Texture, depth_persists: bool,
      /// Panics outside 1...8 (the Swift precondition's reason carries over).
      pub fn init(alloc: Allocator, device: mtl.Device, queue: mtl.CommandQueue, scale: u32, depth_buffer: bool) !MetalVram;
      pub fn deinit(self: *MetalVram) void;
      pub fn width(self) usize; pub fn height(self) usize; pub fn pixelCount(self) usize;
      pub fn clear(self) void; pub fn clearSidecar(self) void;
      pub fn attachDepth(self, pass: mtl.RenderPassDescriptor, clearing: bool) void;
      pub fn upload(self, pixels: []const u16) void;                     // pixelCount() entries
      pub fn uploadNative(self, pixels: *const [native_pixels]u16) void;
      pub fn uploadNativeDepth(self, plane: *const [native_pixels]u32) void;
      pub fn readback(self, out: []u16) void;
      pub fn readbackNative(self, out: *[native_pixels]u16) void;
      pub fn readbackSidecar(self, out: []u8) void;
      pub fn readbackSidecarNative(self, out: *[native_pixels * 4]u8) void;
      /// FNV-1a 64 (fixture.fnv1a) straight over the shared staging buffer.
      pub fn hash(self) u64; pub fn nativeHash(self) u64;
      pub fn saveRegion(self, r: VramRect) void; pub fn restoreRegion(self, r: VramRect) void;
  };
  ```

- [ ] **Step 1: Write the failing tests.** Port `MetalVramTests.swift`'s cases except the five that move to the harness (`vramDumpRoundTrips…`, `reportProduces…`, `reportLists…`, `vramImageWritesAPng…`, `theSidecarPngWriterRoundTripsItsBytes`). That includes `theInstanceRecordLayoutIsWhatTheShaderAsserts` (here, `@sizeOf`/`@offsetOf` against the shader's `static_assert`) and `MetalScaleTests`' `theRasterUniformIsSixteenBytesOnBothSides`. Add Review Focus 1's half here: `aScaleEightVramBuiltAndFreedTwentyTimesReturnsTheDevicesAllocation`, which requires that `device.currentAllocatedSize()` after 20 init/deinit cycles at scale 8 (under a `Pool` per cycle) is within 1 MB of the reading before the first.
- [ ] **Step 2:** Run `zig build test-metal -Dmetal-filter=Vram`. Expected: compile FAIL.
- [ ] **Step 3:** Implement both files, porting `MetalVram.swift` line for line. Swift's `preconditionFailure` on a nil encoder becomes `@panic` with the same label. The staging buffers keep their lazy-allocation rules (the sidecar and depth staging buffers are created on first use).
- [ ] **Step 4:** Run `zig build test-metal -Dmetal-filter=Vram`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(metal): MetalVram and the instance layout in Zig`

### Task 5: `HazardTracker` and `PrimBuilder` (pure)

**Files:**
- Create: `ps1-metal/src/hazard_tracker.zig`, `ps1-metal/src/prim_builder.zig`
- Create: `ps1-metal/tests/hazard_test.zig`, `ps1-metal/tests/prim_builder_test.zig` (both imported by `pure_test.zig`)

**Interfaces:**
- Consumes: `PrimInstance`, `VramRect`, `Kind`, `Flag` (Task 4); `ps1_core.gpu.DrawingEnv` and `ps1_core.gpu.command.Command`.
- Produces:
  ```zig
  pub const HazardTracker = struct {
      pub fn init(alloc: Allocator) HazardTracker; pub fn deinit(self: *HazardTracker) void;
      pub fn reset(self: *HazardTracker) void;
      pub fn needsBreakSampling(self: *const HazardTracker, rects: []const VramRect) bool;
      pub fn needsBreakWriting(self: *const HazardTracker, box: VramRect) bool;
      pub fn markWritten(self: *HazardTracker, box: VramRect) void;
      pub fn markRead(self: *HazardTracker, rects: []const VramRect) void; // deduplicated list
  };
  // prim_builder.zig
  pub fn base(env: DrawingEnv) PrimInstance;
  pub fn triangle(cmd: Command, env: DrawingEnv, kind: i32) ?PrimInstance;
  pub fn rectangle(cmd: Command, env: DrawingEnv, kind: i32) ?PrimInstance;
  pub fn applyTexture(cmd: Command, inst: *PrimInstance) void;
  /// Up to four rects (page, CLUT, each possibly split by the row-511 wrap).
  pub fn sampledRects(inst: PrimInstance, out: *[4]VramRect) []const VramRect;
  ```
  `DrawEnv`'s computed properties come from `DrawingEnv` directly: `area()` (clip), `getOffsetX/Y()`, and `(draw_mode >> 9) & 1`, `(draw_mode >> 5) & 3`, `mask_bit & 1`, `mask_bit & 2` written out where they are used.
- [ ] **Step 1: Write the failing tests.** Port `HazardTrackerTests.swift` (9 cases, including the two row-511 wrap cases and `readRectsAreKeptAsAListRatherThanUnionedTogether`). Add `prim_builder_test.zig`: `anOversizedTriangleIsDropped` (span 1024 x 10 → null), `anOversizedRectangleIsDropped` (w 1024 → null), `aDegenerateTriangleIsDropped` (area 0 → null), `theTriangleBoxIsOnePixelWiderAndClipped` (box = clip ∩ [min-1, max+1] ∩ VRAM), `theRecordsFlagsTranslateToInstanceFlags` (each of the four `command.flag_*` bits maps to its `Flag.*`), and `applyTextureDecodesTpageAndClutAsRendererZigDoes` (tpage 0x0B5 → depth 1, page x 320, page y 256; clut 0x7FC1 → clut x 16, clut y 511; opcode 0x24 sets `Flag.modulate`, 0x25 does not).
- [ ] **Step 2:** Run `zig build test -Dtest-filter=Hazard` and `-Dtest-filter=PrimBuilder`. Expected: compile FAIL.
- [ ] **Step 3:** Port `HazardTracker.swift` and `PrimBuilder.swift`, unchanged in logic.
- [ ] **Step 4:** Run `zig build test`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(metal): hazard tracking and primitive building in Zig`

### Task 6: The rasterizer, the movers and Gate 1

**Files:**
- Create: `ps1-metal/src/rasterizer.zig`, `ps1-metal/src/prim_encoders.zig`
- Create: `ps1-metal/tests/harness.zig`, `harness_test.zig`, `mover_test.zig`, `rasterizer_test.zig`
- Modify: `ps1-golden/src/fixture_test.zig` (port `gpuCommandKindOrdinalsAreFrozen`)

**Interfaces:**
- Consumes: Tasks 1-5; `ps1_core.gpu.command.{Command, Kind, Stream, applyEnv, isEnvKind, execute, replay}`; `fixture.{parse, Parsed, hashVram, fnv1a}`.
- Produces, `rasterizer.zig`:
  ```zig
  pub const PrimVariant = struct { kind: i32, reads_dst: bool };
  pub const Rasterizer = struct {
      vram: *MetalVram,
      env: DrawingEnv = .{}, transfer: WriteCursor = .{},
      dither_mode: DitherMode = default_dither,
      texture_filter: TextureFilter = .nearest, sprite_filter: TextureFilter = .nearest,
      synchronous: bool = true,
      on_commit: ?struct { ctx: *anyopaque, f: *const fn (*anyopaque, mtl.CommandBuffer) void } = null,
      pass_count: usize = 0, saw_unmodelled_kind: bool = false,
      instances: std.ArrayListUnmanaged(PrimInstance),   // read by the scale harness before endFrame
      pub const State = struct { env: DrawingEnv, transfer: WriteCursor };
      pub fn init(alloc: Allocator, vram: *MetalVram, lib: mtl.Library) !Rasterizer;
      pub fn deinit(self: *Rasterizer) void;
      pub fn variantPipelineCount(self) usize;           // 28
      pub fn beginFrame(self, payload: []const u32) void;
      pub fn apply(self, cmd: Command) void;
      pub fn endFrame(self) void;
      pub fn state(self) State; pub fn setState(self, s: State) void;
  };
  ```
  `prim_encoders.zig` holds `encodeLine`, `encodeFill`, `encodeDepthClear`, `encodeCopy`, `encodeUpload` as free functions taking `*Rasterizer`. `encodeLine` iterates `LineWalk` (Task 1); `encodeUpload` drives `WriteCursor.plan` (Task 2). The three-slot `FrameBuffers` cycling, the 65,536-instance initial capacity grown by doubling, the payload buffer at `recorder.max_payload_words` words, and the pass/step rules all carry over unchanged.
- Produces, `harness.zig`:
  ```zig
  pub const Metal = struct { device: mtl.Device, queue: mtl.CommandQueue, lib: mtl.Library };
  pub fn metal() !Metal;                                 // error.SkipZigTest + "no Metal device"
  /// Committed fixtures (ps1-core/tests/goldens/fixtures) and every
  /// zig-out/fixtures/*.p1fx; error.SkipZigTest + "fixture <name> not generated".
  pub fn loadFixture(alloc: Allocator, name: []const u8) !fixture.Parsed;
  pub fn corpus(alloc: Allocator) ![]const []const u8;   // every name loadFixture can open
  pub const ReplayOptions = struct { up_to: ?usize = null, dither: DitherMode = .native,
      filter: TextureFilter = .nearest, sprite_filter: TextureFilter = .nearest, depth_buffer: bool = false };
  pub const ReplayResult = struct { frames_checked: usize, first_divergence: ?usize, pass_count: usize, message: []const u8 };
  /// GATE 1. Each frame replayed through command.replay into a software Vram
  /// AND through Metal at 1x; full VRAM compared after EVERY frame, and the
  /// fixture's recorded hash checked as well.
  pub fn replay(alloc: Allocator, m: Metal, name: []const u8, o: ReplayOptions) !ReplayResult;
  pub fn report(alloc, fixture_name, frame: usize, got: []const u16, want: []const u16) ![]const u8; // VramDump.report
  pub fn writeVramPng(path, pixels: []const u16, w, h) !void;  // VramImage
  pub fn writeSidecarPng(path, rgba: []const u8, w, h) !void;
  ```
- [ ] **Step 1: Write the failing tests.**
  - `mover_test.zig`: port the seven GPU cases of `MetalMoverTests.swift` (`aTextureBoundAsAttachmentCanBeReadAtAnotherCoordinate`, the two payload-edge cases, `replaysTheSyntheticMoverFixtureOnTheGpu` through `harness.replay`, `backToBackUploadsShareOneRenderPass`, `anUploadOverWhatThisPassSampledStartsANewPass`, `aSpriteSamplesWhatAnUploadEarlierInTheFrameWrote`).
  - `rasterizer_test.zig`: port all 22 cases of `MetalRasterizerTests.swift`. The ones that replay `synthetic-primitives` frames go through `harness.replay(..., .{ .up_to = N })`. Add Review Focus 2: `aFrameOfLongLinesOutgrowsTheFirstInstanceBufferAndStillMatches`: 80 lines of 1000 px each (80,080 instances) on a blank VRAM, compared against `command.execute` on a software `Vram`.
  - `harness_test.zig`: `theCorpusPassesGateOne` (`harness.replay` over `harness.corpus()`, every fixture, every frame, `first_divergence == null`); Review Focus 1's other half, `replayingTheCorpusThreeTimesDoesNotGrowTheDevicesAllocation` (within 1 MB between the end of pass 1 and the end of pass 3, a `Pool` per frame); Review Focus 4, `aMissingFixtureSkipsAndNamesItself` (`loadFixture("no-such-fixture")` returns `error.SkipZigTest`); the five dump/PNG cases moved from `MetalVramTests`; and `theCommittedPrimitivesFixtureHasTheDocumentedShape`.
  - `fixture_test.zig`: `gpuCommandKindOrdinalsAreFrozen`, asserting every `command.Kind` ordinal 0…17 by name.
- [ ] **Step 2:** Run `zig build test-metal -Doptimize=ReleaseFast -Dmetal-filter=Mover`. Expected: compile FAIL.
- [ ] **Step 3:** Implement `rasterizer.zig` and `prim_encoders.zig` by porting (if `rasterizer.zig` passes ~600 lines, move pipeline construction into `pipelines.zig`) `MetalRasterizer.swift` and `PrimEncoders.swift`, then `harness.zig`. `apply`'s environment arm is `command.applyEnv(cmd, &self.env)` behind `command.isEnvKind`. The pipeline table is `[2][7][2]` (true colour, class, reads-dst), built in `init` with function constants 1 (`int`, the class) and 2 (`bool`, true colour). The four mover pipelines carry no constants. Every pipeline declares the three attachment formats `.r16Uint`, `.rgba8Uint`, `.r32Uint`.
- [ ] **Step 4:** Run `zig build test-metal -Doptimize=ReleaseFast`. Expected: PASS on every fixture present. Then run `zig build fixtures -Doptimize=ReleaseFast`, if `games/` is present, and run it again so the generated corpus is exercised as well.
- [ ] **Step 5:** Run `zig build test-metal-validate -Doptimize=ReleaseFast` (Review Focus 3). Expected: PASS with no validation message on stderr.
- [ ] **Step 6:** Commit: `feat(metal): the Zig rasterizer, with Gate 1 against the software rasterizer in-process`

### Task 7: The scaled path (Gates 2, 3 and 4)

**Files:**
- Create: `ps1-metal/tests/scale_test.zig`, `ps1-metal/tests/scale_gate_test.zig`
- Modify: `ps1-metal/tests/harness.zig`

**Interfaces:**
- Consumes: Task 6.
- Produces, `harness.zig`:
  ```zig
  pub const Frame = struct { scaled: []u16, native: []u16, sidecar: ?[]u8, instances: []PrimInstance, width: usize, height: usize, scale: u32 };
  pub const FrameOptions = struct { payload: []const u32 = &.{}, preload: ?*const [native_pixels]u16 = null,
      dither: DitherMode = .off, filter: TextureFilter = .nearest, sprite_filter: ?TextureFilter = null, want_sidecar: bool = false };
  /// MetalScaleHarness.frame: one frame from a blank (or preloaded) VRAM at `scale`.
  pub fn frame(alloc, m: Metal, scale: u32, o: FrameOptions, ctx: anytype, comptime body: fn (@TypeOf(ctx), *Rasterizer) void) !Frame;
  /// The whole fixture at `scale`, native view per frame (Gate 2's currency).
  pub fn replayNative(alloc, m: Metal, name, scale: u32, o: ReplayOptions, each: anytype) !void;
  pub fn gateSwitch(name: []const u8) ?[]const u8;  // std.process env; replaces the marker files
  ```
- [ ] **Step 1: Write the failing tests.** Port all 32 `MetalScaleTests.swift` cases except `theRasterUniformIsSixteenBytesOnBothSides` (done in Task 4). Gate 2 runs at N ∈ {2, 3, 4, 8}, 3 included on purpose. The two opt-in gates go in `scale_gate_test.zig` and return `error.SkipZigTest` unless `gateSwitch("PS1_DUMP_SCALED")` (holding 1…8) or `gateSwitch("PS1_SCALE_TIMING")` is set. Their skip message names the variable.
- [ ] **Step 2:** Run `zig build test-metal -Doptimize=ReleaseFast -Dmetal-filter=Scale`. Expected: FAIL (helpers missing).
- [ ] **Step 3:** Implement the harness additions, porting `MetalScaleHarness.swift`.
- [ ] **Step 4:** Run `zig build test-metal -Doptimize=ReleaseFast`. Expected: PASS. Then `PS1_SCALE_TIMING=1 zig build test-metal -Doptimize=ReleaseFast -Dmetal-filter=Timing`, which prints per-scale replay cost. Record the output in the task's report; there is no threshold here, and Plan C compares it against the Swift numbers.
- [ ] **Step 5:** Commit: `test(metal): the scaled-path gates in Zig`

### Task 8: Filtering, true colour, PGXP parity and the interpolation fuzz

**Files:**
- Create: `ps1-metal/tests/{filter_test,true_colour_test,pgxp_parity_test,interp_fuzz_test}.zig`
- Modify: `ps1-metal/src/mtl.zig`, `mtl_encode.zig` (a compute pipeline and encoder, for the fuzz kernel only)

**Interfaces:**
- Consumes: Tasks 6-7. The fuzz needs `Device.newComputePipelineState(function)`, `CommandBuffer.computeCommandEncoder`, `ComputeCommandEncoder.{setComputePipelineState, setBuffer, setBytes, dispatchThreads, endEncoding}`, added only for it.
- [ ] **Step 1: Write the failing tests.** Port every case of `TextureFilterTests.swift` (22), `TrueColourTests.swift` (10, including `gateOneRunsAtADitheringModeRatherThanThePlayersDefault`, which shows that `harness.replay` at `.true_color` diverges and at its pinned `.native` does not), `PgxpParityTests.swift` (4, skipped when `tr1-usa-v1-1-pgxp.p1fx` is absent) and `InterpolationExactnessTests.swift` (`interpolationMatchesTheSixtyFourBitDivideExactly`: the `ps1_interp_fuzz` kernel over 2^28 cases, half of them on a quotient boundary, both counters zero).
- [ ] **Step 2:** Run `zig build test-metal -Doptimize=ReleaseFast -Dmetal-filter=Filter`. Expected: FAIL to compile, or FAIL, until the compute wrappers exist.
- [ ] **Step 3:** Add the compute wrappers.
- [ ] **Step 4:** Run `zig build test-metal -Doptimize=ReleaseFast`. Expected: PASS.
- [ ] **Step 5:** Commit: `test(metal): filtering, true colour, PGXP parity and the interpolation fuzz in Zig`

### Task 9: `StreamQueue` and `SpeculativeRegion` (pure)

**Files:**
- Create: `ps1-metal/src/stream_queue.zig`, `ps1-metal/src/speculative_region.zig`
- Create: `ps1-metal/tests/queue_test.zig`, `ps1-metal/tests/speculation_region_test.zig` (both in `pure_test.zig`)

**Interfaces:**
- Consumes: `command.{Command, Stream}`, `recorder.{max_records, max_payload_words}`, `DrawingEnv`, `WriteCursor`, `VramRect`.
- Produces:
  ```zig
  pub const Display = struct { vram_x: u32 = 0, vram_y: u32 = 0, width: u32 = 0, height: u32 = 0, depth24: bool = false, enabled: bool = false };
  pub const StreamSlot = struct {
      records: []Command, payload: []u32,           // capacities: max_records, max_payload_words
      record_count: usize = 0, payload_count: usize = 0, seq: u64 = 0,
      pub fn stream(self: *const StreamSlot) Stream; // complete = true
  };
  pub const SpeculativeGroup = struct { slots: [max_speculative_frames]StreamSlot, count: usize, after_seq: u64, display: Display, spoiled: bool,
      pub fn frames(self: *SpeculativeGroup) []StreamSlot };
  pub const StreamQueue = struct {
      pub const capacity = 5; pub const max_speculative_frames = 3;
      published_count: std.atomic.Value(u64), dropped_count: std.atomic.Value(u64),
      pub fn init(alloc: Allocator) !*StreamQueue; pub fn deinit(self: *StreamQueue) void;
      pub fn pendingCount(self) usize; pub fn isFull(self) bool;
      pub fn needsResync(self) bool; pub fn requestResync(self) void; pub fn clearResync(self) void;
      pub fn hasDroppedFrames(self) bool; pub fn noteDroppedFrame(self) void; pub fn takeDroppedFrames(self) bool;
      pub fn requestShadow(self) void; pub fn wantsShadow(self) bool;
      // producer (emulator thread only)
      pub fn publish(self, seq: u64, s: Stream) void;
      pub fn stage(self, seq: u64, s: Stream) bool; pub fn commitStaged(self) void;
      pub fn beginSpeculativeGroup(self, after: u64) void;
      pub fn appendSpeculative(self, s: Stream) void;
      pub fn commitSpeculativeGroup(self, display: Display) void;
      // consumer (render thread only)
      pub fn drain(self, ctx: anytype, comptime body: fn (@TypeOf(ctx), *const StreamSlot) void) void;
      pub fn discardThrough(self, seq: u64) ?u64; pub fn discardAll(self) ?u64;
      pub fn takeSpeculativeGroup(self, after: u64) ?*SpeculativeGroup; pub fn releaseSpeculativeGroup(self) void;
  };
  // speculative_region.zig
  pub const full: VramRect;
  pub fn of(frames: []const StreamSlot, start_env: DrawingEnv, transfer: WriteCursor) ?VramRect;
  ```
  The atomics are `std.atomic.Value` with the Swift orderings (`acquire` for `acquiring`, `release` for `releasing`, `acq_rel` for `exchange`). The group lock is a `std.Thread.Mutex`. The speculative groups are allocated on the first `beginSpeculativeGroup`, as in Swift. A `Stream` with `complete == false` notes a drop: `publish`/`stage` take the core's own `Stream` rather than a pointer/count pair.
- [ ] **Step 1: Write the failing tests.** Port 19 `StreamQueueTests.swift` cases (the two backpressure cases are retired, see the port table), and `SpeculationTests.swift`'s four region cases (`aGroupThatDrawsNothingHasNoRegion`, `aPrimitiveIsBoundedByTheDrawingAreaItsGroupSet`, `fillsCopiesAndUploadsUseTheirOwnRectangles`, `anUploadTheRealFrameBeganIsPartOfTheRegion`). Add `aProducerAndConsumerOnTwoThreadsLoseNothing`: one thread publishes 10,000 one-record frames with seqs 1…10000, spinning while `isFull`; the other drains. Require that the consumer sees every seq exactly once, in order.
- [ ] **Step 2:** Run `zig build test -Dtest-filter=StreamQueue`. Expected: compile FAIL.
- [ ] **Step 3:** Port `StreamQueue.swift` (minus `claimConsumer`, `isConsumer` and `StreamBackpressure`) and `SpeculativeRegion.swift`.
- [ ] **Step 4:** Run `zig build test`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(metal): the frame queue and speculative region in Zig`

### Task 10: `LiveRenderer`

**Files:**
- Create: `ps1-metal/src/live_renderer.zig`
- Create: `ps1-metal/tests/{live_renderer_test,live_renderer_scale_test,speculation_test}.zig`

**Interfaces:**
- Consumes: Tasks 4, 6 and 9.
- Produces:
  ```zig
  pub const Shadow = struct { pixels: *const [native_pixels]u16, depth: ?*const [native_pixels]u32, seq: u64 };
  pub const Options = struct { diff: bool = false, stats: bool = false };
  pub const DiffReport = struct { seq: u64, differing: usize, first_x: usize, first_y: usize, gpu: u16, shadow: u16,
      pub fn format(...) // "PS1_LIVE_DIFF: seq {d} diverged; {d} pixels, first at ({d}, {d}) gpu=0x{X} shadow=0x{X}"
  };
  pub const LiveRenderer = struct {
      vram: MetalVram, rasterizer: Rasterizer,
      last_executed_seq: u64 = 0, present_display: ?Display = null,
      diff_checked: usize = 0, diff_skipped: usize = 0,
      pub fn init(alloc: Allocator, m: struct { device: mtl.Device, queue: mtl.CommandQueue, lib: mtl.Library },
                  scale: u32, depth_buffer: bool, o: Options) !*LiveRenderer;   // rasterizer.synchronous = false
      pub fn deinit(self: *LiveRenderer) void;   // prints the diff summary when diff ran
      /// `shadow` has `fn sample(self) Shadow`, called only when a resync or
      /// repair needs it, and at most once per drain.
      pub fn drain(self: *LiveRenderer, queue: *StreamQueue, shadow: anytype) void;
      pub fn settleSpeculation(self: *LiveRenderer) void;
      /// `shadow` has `fn pixels(self) *const [native_pixels]u16`, called only after the seq check.
      pub fn diff(self: *LiveRenderer, seq: u64, shadow: anytype) ?DiffReport;
  };
  ```
  `drain` is `LiveRenderer.drain` transcribed: the resync flag cleared before the sample, `discardThrough` (never `discardAll`, except where the Swift code discards a too-old backlog under a hard resync), the hole check that leaves the resync raised, the repair debt that is settled at 1x on the drop and above 1x on the first drain that loses nothing, and speculation after every drain. The `PS1_LIVE_STATS` probe is ported too, behind `Options.stats`, still marked TEMPORARY.
- [ ] **Step 1: Write the failing tests.** Port `LiveRendererTests.swift` (16), the six non-coordinator cases of `LiveRendererScaleTests.swift` (`aLiveDrainAtScaleMatchesTheOneXReplayOfTheSameStream`, `aDroppedFrameKeepsTheScaledPictureRatherThanCollapsingToOneX`, `aDroppedFrameStillAdoptsTheShadowAtOneX`, `aHardResyncStillAdoptsTheShadowAtEveryScale`, `aResyncAdoptsTheDepthPlane`, `aLostFramesMutationIsRepairedOnceTheDropsStop`), and `SpeculationTests.swift`'s `speculationLeavesTheRealTimelineUntouched` (synthetic-primitives, synthetic-movers, croc and Crash Warped at 1x and 2x, two frames speculated after every frame; the settled texture hashes as a plain replay's after every frame, and the sidecars match at the end; skipped per fixture when it is absent). The shadow and diff closures become small test structs that count their calls, which is what `theShadowClosureIsNotCalledOnTheOrdinaryPath` and `theShadowIsNotBuiltForAFrameTheOracleWillSkip` assert.
- [ ] **Step 2:** Run `zig build test-metal -Doptimize=ReleaseFast -Dmetal-filter=Live`. Expected: compile FAIL.
- [ ] **Step 3:** Port `LiveRenderer.swift`.
- [ ] **Step 4:** Run `zig build test-metal -Doptimize=ReleaseFast`. Expected: PASS. Then run the validation step (`test-metal-validate`) again.
- [ ] **Step 5:** Commit: `feat(metal): the live renderer and its resync rules in Zig`

### Task 11: The display pass, screenshots and PNG

**Files:**
- Create: `ps1-metal/src/display.zig`, `ps1-metal/src/screenshot.zig`, `ps1-metal/src/png.zig`
- Create: `ps1-metal/tests/{display_test,display_scale_test,screenshot_test}.zig`

**Interfaces:**
- Consumes: Tasks 4, 9 and 10.
- Produces, `display.zig`:
  ```zig
  pub const Params = extern struct { vram_x: u32, vram_y: u32, width: u32, height: u32, depth24: u32, enabled: u32,
      scale_x: f32 = 1, scale_y: f32 = 1, software_display: u32 = 0, scale: u32 = 1, saturation: f32 = 1,
      band_px: f32 = 0, band_edge_px: f32 = 0, band_sigma_px: f32 = 0, band_mix: f32 = 0, uv_per_px_x: f32 = 0, uv_per_px_y: f32 = 0 };
  comptime { assert(@sizeOf(Params) == 68); }
  pub fn letterboxScale(width: f64, height: f64) struct { x: f32, y: f32 };
  pub const DrawFade = struct { duration: f64, progress: f64 = 0, last: ?f64 = null, pub fn eased(self: *DrawFade, on: bool, now: f64) f32 };
  pub const PauseFade = struct { pub const paused_saturation: f32 = 0.6; pub const duration = 0.25; pub fn saturation(self: *PauseFade, paused: bool, now: f64) f32 };
  /// ToolbarBand's geometry stays a Swift constant (spec); it arrives here as points.
  pub const Band = struct { height: f64, edge: f64, sigma: f64 };
  pub fn applyBand(p: *Params, band: Band, mix: f32, size_px: [2]f64, points: [2]f64) void;
  pub const DisplayPass = struct {
      pipeline: mtl.RenderPipelineState, shadow: mtl.Texture,   // r16Uint 1024x512 managed
      pub fn init(m: …, lib: mtl.Library) !DisplayPass; pub fn deinit(self: *DisplayPass) void;
      pub fn uploadShadow(self: *DisplayPass, pixels: *const [native_pixels]u16) void;
      /// Binds all three textures always, then draws one triangle into `target`.
      pub fn encode(self: *DisplayPass, cmd: mtl.CommandBuffer, target: mtl.Texture, vram: mtl.Texture, sidecar: mtl.Texture, p: Params) void;
  };
  ```
- Produces, `screenshot.zig`: `pub const Size = struct { width: u32, height: u32 }`; `pub fn size(display_height: u32, scale: u32, enabled: bool) Size`; `pub fn encode(cmd, pass: *DisplayPass, vram, sidecar, p: Params, s: Size) ?mtl.Texture` (scale_x = scale_y = 1, saturation 1, band_mix 0, then a `synchronizeResource` blit); `pub fn bytes(t: mtl.Texture, out: []u8) void`.
- Produces, `png.zig`: `pub fn encode(alloc: Allocator, bgra: []const u8, width: u32, height: u32, bytes_per_row: u32) ![]u8`, through `CGColorSpaceCreateWithName(kCGColorSpaceSRGB)`, `CGDataProviderCreateWithData`, `CGImageCreate` (byte order 32 little, alpha none-skip-first), `CFDataCreateMutable`, `CGImageDestinationCreateWithData(…, CFSTR("public.png"), 1, NULL)`, `AddImage` and `Finalize`, releasing each object. These are plain C `extern fn` declarations in `png.zig`; none of them goes through `objc`.
- [ ] **Step 1: Write the failing tests.** Port `DisplayRenderTests.swift` (11), `DisplayScaleTests.swift` (8, including `theDisplayParamsStrideMatchesTheShaderStruct` and `aPauseGreysThePictureOutOverAQuarterSecondAndBack`), `LetterboxTests.swift` (5), and four `ScreenshotTests.swift` cases (`theHeightIsTheDisplayedLinesAtTheScale`, `aDisabledDisplayIsAPlainBlackFrame`, `aPngRoundTripsItsPixels` (decode with `CGImageSourceCreateWithData` and compare pixels), `theOffscreenPassDrawsThePicture`). Add Review Focus 5: `aScreenshotBlockOutlivesTheRendererThatAskedForIt`: encode a screenshot with a completion block whose heap context owns the target texture and an answer slot, free the `LiveRenderer` and `DisplayPass` before the block runs, then wait on the command buffer. The block must run once, the answer must be a valid PNG, and the run must not crash.
- [ ] **Step 2:** Run `zig build test-metal -Dmetal-filter=Display`. Expected: compile FAIL.
- [ ] **Step 3:** Implement the three files, porting `MetalDisplayView.swift`'s free functions and types, `Screenshot.swift`'s render half and the display harness.
- [ ] **Step 4:** Run `zig build test-metal -Doptimize=ReleaseFast`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(metal): the display pass, screenshots and PNG encoding in Zig`

### Task 12: `ps1-bench-gpu`, the renderer benchmark

**Files:**
- Create: `ps1-bench/src/gpu_main.zig`, `ps1-bench/src/gpu_bench.zig`, `ps1-bench/src/gpu_bench_test.zig`
- Modify: `build.zig` (install `ps1-bench-gpu` on macOS with the Metal toolchain, beside `ps1-bench-dual`/`-sw`; add `gpu_bench_test` to `test-metal`)

**Interfaces:**
- Consumes: `Rasterizer`, `MetalVram`, `harness`-style fixture loading (factor the loader into `ps1-metal/src/` if the bench needs it outside tests: `fixture_corpus.zig`, with `harness.zig` re-using it).
- Produces: `ps1-bench-gpu <fixture>[,<fixture>…] [--scales=1,4,6,8] [--repeats=5] [--dither=true-color|native|scaled|off] [--filter=nearest|bilinear] [--sprite-filter=nearest|bilinear]`. It prints one line per (fixture, scale, config) in exactly `GpuBench.Result.line`'s format: `[gpu-bench] <fixture padded 24> <s>x <config padded 10> gpu %6.2f ms  cpu %6.2f ms  %6.1f fps  (%d frames)`. It takes the best of `repeats` by GPU ms, and interleaves configs inside each repeat. The defaults are the shipped settings (true colour, bilinear texture filter, nearest sprite filter), because the bench has no `UserDefaults` to read.
- [ ] **Step 1: Write the failing test.** Port `theBenchmarkReplaysEveryFrameAndTimesTheGpu` against `gpu_bench.run` on `synthetic-primitives` at 1x with one repeat: every frame is replayed, `gpu_ms > 0` and `fps > 0`.
- [ ] **Step 2:** Run `zig build test-metal -Dmetal-filter=Bench`. Expected: compile FAIL.
- [ ] **Step 3:** Port `GpuBench.swift`: a synchronous pass that sums `GPUEndTime - GPUStartTime` over the committed buffers after each wait, and a pipelined pass (`synchronous = false`) timed wall-clock, with `on_commit` collecting the buffers.
- [ ] **Step 4:** Run `zig build -Doptimize=ReleaseFast` and then `zig-out/bin/ps1-bench-gpu crash-bandicoot-warped,silent-hill-usa,tr1-usa-v1-1 --scales=1,4,6,8`. Expected: twelve lines in the format above. Record them in the task report for Plan C's comparison; this task sets no threshold.
- [ ] **Step 5:** Commit: `feat(bench): ps1-bench-gpu replays fixtures through the Zig renderer`

---

## After Plan A

- `zig build test`, `zig build test-metal -Doptimize=ReleaseFast`, `zig build test-metal-validate -Doptimize=ReleaseFast` and `trace-golden -- verify` are green, and `ps1-macos/test.sh` is unchanged and green: the app has not been touched.
- Plan B is written against the interfaces above: `StreamQueue`'s producer half, `LiveRenderer`, `DisplayPass` and `screenshot` are what the session and the render thread drive.
