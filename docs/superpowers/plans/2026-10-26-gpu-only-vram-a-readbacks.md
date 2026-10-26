# GPU-only VRAM, Plan A: the renderer can serve readbacks

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove Metal at 1x reproduces the software VRAM on every trace workload, then give `ps1-metal` everything a GPU-only machine will read VRAM through: a native rect readback, a blocking readback request on the render thread, an asynchronous capture ring, a VRAM carry across a scale/depth rebuild, and 24bpp scanned out of the render texture.

**Architecture:** One compute kernel pair gathers each block's top-left subtexel (and depth) into a shared buffer, so every readback costs the rect, not the scaled texture. `LiveRenderer` owns the gather (`readNative`) and the capture ring; `FrameRenderer` owns a request desk served after each drain on the render thread; `RenderThread.readback` is the blocking entry the emulator thread will call in Plan B. Nothing in `ps1-core` or `ps1-session` calls any of it yet: the app still ships dual.

**Tech Stack:** Zig 0.17.0, Metal (compute + blit), the existing `ps1-metal` objc bindings, `ps1-golden`'s workload discovery.

**Spec:** `docs/superpowers/specs/2026-10-26-gpu-only-vram-design.md` (sections 3, 4's rebuild row, 7's Metal-parity and readback-under-stress gates, 9).

## Global Constraints

- Run from the repo root. Every Metal test: `zig build test-metal -Doptimize=ReleaseFast` (narrow with `-Dmetal-filter=<substring>`).
- **VRAM stays `.r16Uint`; readback reads it, never the sidecar.**
- "Native" means **the top-left subtexel of each N x N block**, exactly what `MetalVram.readbackNative` returns. At 1x it is the texture itself.
- Test scales always include **3** (a `>> log2(s)` bug is invisible at 2, 4, 8).
- **No golden moves, and `zig build test`, `trace-golden -- verify`, `stream-verify` and `test-metal` stay green** after every task.
- The parity gate runs at **1x, `.native` dithering, both filters `.nearest`**, and requires **full-VRAM equality**. A divergence is never excluded silently and never by loosening the equality.
- A readback's Debug deadlock bound is **2 s**; release has **no timeout**.
- Commit messages are a title line only (`feat:`/`docs:`/`test:` prefixes as the log uses). Commit after each task on master. Never push.
- Match the surrounding style: doc comments state the rule and its reason, no thinking-aloud comments, no copy-paste (extract the helper).

## Deviation from the spec, for the user to confirm

- **`present` skipping a non-final chunk moves to Plan B.** A non-final slot does not exist until Plan B defines chunks in `StreamQueue` (which the spec leaves to the builder), so in Plan A the rule could only be tested against a flag nothing sets. Plan B adds it with the chunks and the spec's test (`present skips while the newest executed chunk is non-final`).
- **The renderer takes a NON-wrapping rect.** Splitting a rect that crosses the VRAM edge is `Gpu.settleVram`'s job (spec section 1, "split as the builder chooses"), which is Plan B. Plan A asserts the rect is in bounds; the wrap test lands with `settleVram`.
- **A rebuild no longer raises a resync, in either mode.** The carry makes the rebuilt texture exact at native, so the resync's adoption of the shadow would only redo the same picture. This changes dual's behaviour on a scale change (one fewer 1 MB shadow publish + upload, same pixels at native).
- **24bpp reads the render texture in BOTH modes, and the runahead 24-bit exception in `chooseDisplay` goes.** The spec allows the first; the second follows because the exception's stated reason ("a speculative frame publishes no shadow") stops applying once 24bpp no longer reads the shadow.

## Review Focus

1. **A readback posted before the render thread's loop is visible, or after `stop`.** It must still be answered: the first pass serves it, and `stop` answers anything left with the texture's current contents. Test: Task 5's `aReadbackPostedBeforeTheThreadStartsIsServed` and `stopAnswersAPendingReadbackWithTheCurrentTexture`.
2. **A readback while a runahead picture is up** (`pending_restore` set). It must return the REAL timeline. Test: Task 3's `aReadbackWhileASpeculativePictureIsUpReadsTheRealTimeline`.
3. **A rect touching the last column/row** (`x1 = 1023`, `y1 = 511`) at scale 3 and 8: the dispatch must cover it and read no subtexel past the texture. Test: Task 3's `aRectAtTheFarCornerReadsTheLastBlock`.
4. **A depth readback while the plane is memoryless.** A memoryless texture cannot be read; the answer is far (0) everywhere, never a crash. Test: Task 3's `aDepthReadWhileThePlaneIsMemorylessIsFar`.
5. **A scale change arriving with a readback in the same pass.** `perform` applies settings before it executes, so the carry runs first and the readback reads the carried texture. Test: Task 5's `aReadbackAcrossAScaleRebuildReadsTheCarriedPixels`.

---

### Task 1: Share the boot helpers out of `ps1-golden/src/main.zig`

`main.zig` is ~1400 lines and the parity harness (Task 2) needs exactly its machine loading and frame stepping. Move them; change nothing.

**Files:**
- Create: `ps1-golden/src/boot.zig`
- Modify: `ps1-golden/src/main.zig` (remove the moved code, import `boot.zig`)

**Interfaces:**
- Produces, in `boot.zig`:
  - `pub fn loadMachine(a: std.mem.Allocator, io: std.Io, wl: golden.Workload, bios_override: ?[]const u8, bus: *ps1.memory.Bus) !void` (moved with `attachSbi`, which stays private to `boot.zig`)
  - `pub const FrameStepper` (moved verbatim, with its `Frame`)
  - `pub fn selectEngine(cpu: *ps1.cpu.Cpu, engine: ps1.recompiler.Engine, jit_lower: <the type Options.jit_lower has>) !void` (takes the two fields rather than `Options`, so `boot.zig` does not depend on `main.zig`)
  - `pub const Diff` and `pub fn firstDiff(want: *const ps1.gpu.Vram, got: *const ps1.gpu.Vram) ?Diff` (moved)

- [ ] **Step 1: Move the code** listed above into `boot.zig`; in `main.zig` replace each use with `boot.X`, and `selectEngine(&cpu, opts)` with `boot.selectEngine(&cpu, opts.engine, opts.jit_lower)`.
- [ ] **Step 2: Build and gate**

Run: `zig build -Doptimize=ReleaseFast && zig build trace-golden -Doptimize=ReleaseFast -- stream-verify --filter=bios && zig build trace-golden -Doptimize=ReleaseFast -- verify --filter=bios`
Expected: both report `OK` for `bios-only`; no other output change.

- [ ] **Step 3: Commit** — `git commit -m "refactor: ps1-golden boot helpers in their own file"`

---

### Task 2: The Metal stream-parity gate, and its result in the spec

The main GPU-only gate (Plan B) assumes Metal at 1x reproduces software VRAM byte for byte on every workload. This task proves or disproves that first.

**Files:**
- Create: `ps1-golden/src/metal_parity.zig` (the executable's root)
- Modify: `build.zig` (new exe `ps1-golden-metal`, step `trace-golden-metal`, inside the existing `if (metal_available)` block, arm64 macOS only like `ps1-bench-gpu`)
- Modify: `docs/superpowers/specs/2026-10-26-gpu-only-vram-design.md` (a new subsection under section 7, "Metal stream parity: result (2026-10-26)")

**Interfaces:**
- Consumes: Task 1's `boot.loadMachine`, `boot.FrameStepper`, `boot.selectEngine`; `golden.discover`; `ps1_metal.metal_context.Metal` and `.Rig`.
- Produces: `zig build trace-golden-metal -Doptimize=ReleaseFast -- parity [--filter=<s>] [--instructions=<n>]`. Plan B adds its GPU-only mode to this same executable.

- [ ] **Step 1: Wire the build.** Executable `ps1-golden-metal`, root `ps1-golden/src/metal_parity.zig`, `.optimize = optimize`, imports `ps1_core` = `record_core_mod`, `ps1_metal` = `metal_mod`, `cue_files` = `cue_files_mod`, `linkMetal(...)`. Step `trace-golden-metal` runs it with `run.addPassthruArgs()` and the repo root as CWD (as `trace-golden` does). Where Metal is unavailable the step depends on `missing_metal`.

- [ ] **Step 2: Implement `metal_parity.zig`.** Per workload (skip `.exe` sources, as `stream-verify` does; default 600M instructions, the same constant as `main.zig`):
  - boot exactly as `runStreamVerify` does, `bus.gpu.sink.rec.arm()`;
  - one `Rig` at `.{ .scale = 1, .depth_buffer = false }`, `r.dither_mode = .native`, `r.texture_filter = .nearest`, `r.sprite_filter = .nearest`, `r.synchronous = true`;
  - each frame from `FrameStepper`: an incomplete stream is reported `OVERFLOW` and ends the workload (as `stream-verify`); else `rig.frame(s.payload, s.records)`, `rig.vram.readback(buf)` and compare with `bus.gpu.vram.data`;
  - on a mismatch, record the first diverging frame (frame index, instruction count, pixel count, first x/y, both values), count it, then `rig.vram.upload(&bus.gpu.vram.data)` and go on, so the run reports how MANY frames diverge, not just the first;
  - a `known_divergences` table, `[_]struct { key: []const u8, class: []const u8 }`, starts EMPTY. A workload in it is reported `EXCLUDED (<class>)` with its first diverging frame on every run and does not fail the run;
  - output per workload: `  <key> <frames> frames  OK` or `  <key> DIVERGED in <n> of <frames> frames, first @ frame <f> (instr <i>): <px> px, first (<x>,<y>) metal=<hex> software=<hex>`; exit non-zero if any non-excluded workload diverged or overflowed, or if no workload matched.

- [ ] **Step 3: Run it over every workload**

Run: `zig build trace-golden-metal -Doptimize=ReleaseFast -- parity`
Expected: one line per workload in `ps1-core/tests/goldens/trace/` (nine today). Record the output.

- [ ] **Step 4: Triage each divergence.** For each diverging workload, capture its first diverging frame as a fixture (`ps1-golden stream-capture --cue=... --key=<key>-parity --capture-from=<instr of the frame before> --frames=3`) and decide: a Metal bug, or the documented class "a primitive samples its own destination" (`ps1-gpu-metal`). The class claim needs evidence: the diverging pixels lie inside a primitive whose texture read covers its own draw box. A Metal bug is NOT fixed in this plan: it is written down and Plan B waits on it (spec: "fixed before Plan B starts"). A proven class member goes into `known_divergences` with its class.

- [ ] **Step 5: Write the result into the spec** under section 7: the command, the date, a table of workload / frames / result / first diverging frame / class or bug, and which workloads the Plan B gate will exclude. Do not change any other part of the spec.

- [ ] **Step 6: Commit** — `git commit -m "test: Metal stream parity over every trace workload"` (code + spec together).

**If any workload diverges as a Metal bug, stop after this task and report it to the user before Task 3**: the rest of Plan A does not depend on it, but the user decides whether the bug is fixed first.

---

### Task 3: Native gather and `LiveRenderer.readNative`

**Files:**
- Create: `ps1-metal/shaders/Readback.metal` (two compute kernels)
- Modify: `build.zig:463` (the metallib source list) and the metallib cache-input list beside it, so the new file is compiled and its edits rebuild the library
- Modify: `ps1-metal/src/pipelines.zig` (`Set` gains the two compute pipelines)
- Modify: `ps1-metal/src/metal_vram.zig:142` (depth usage gains `.shaderRead` while it persists)
- Modify: `ps1-metal/src/live_renderer.zig` (`readNative`)
- Test: `ps1-metal/tests/readback_test.zig` (new), registered in `ps1-metal/metal_test.zig`

**Interfaces:**
- Produces:
  - kernels `ps1_gather_colour` and `ps1_gather_depth`: `texture2d<uint, access::read> src [[texture(0)]]`, `device ushort*` / `device uint* out [[buffer(0)]]`, `constant Ps1GatherParams& p [[buffer(1)]]` with `{ uint x0, y0, width, height, scale; }`, one thread per native pixel of the rect, reading `src.read(uint2((p.x0 + gid.x) * p.scale, (p.y0 + gid.y) * p.scale))` into `out[gid.y * p.width + gid.x]`, returning early for `gid` outside `width x height`.
  - `pipelines.Set.gather_colour: mtl.ComputePipelineState`, `gather_depth: mtl.ComputePipelineState`, built in `Set.init`, released in `deinit`.
  - `LiveRenderer.readNative(self: *LiveRenderer, r: pi.VramRect, colour: []u16, depth: ?[]u32) void`: `colour.len` (and `depth.len`) `== w * h` of the inclusive rect, row-major. Synchronous: its own command buffer after everything this renderer has committed, `waitUntilCompleted`. Panics on an out-of-bounds rect or a wrong length (programming errors, like `MetalVram.upload`).

- [ ] **Step 1: Write the failing tests** in `readback_test.zig`, each over a `LiveRenderer` with the pipeline set from `live_harness`:
  - `aRectReadsTheNativeViewAtEveryScale`: for s in {1, 3, 8}: `vram.uploadNative(lcgImage)`; then a fill frame drained through a queue so the texture also holds drawn pixels; `readNative(.{ .x0 = 100, .y0 = 50, .x1 = 419, .y1 = 289 }, ...)` equals the same rect cut from `vram.readbackNative`.
  - `aRectAtTheFarCornerReadsTheLastBlock`: s in {3, 8}, rect `.{ .x0 = 1000, .y0 = 500, .x1 = 1023, .y1 = 511 }`, equals the cut from `readbackNative`.
  - `aDepthReadReturnsThePlane`: s = 3, depth buffer on, `vram.uploadNativeDepth(plane)` with a non-uniform plane; `readNative(full, colour, depth)`'s depth equals `plane`.
  - `aDepthReadWhileThePlaneIsMemorylessIsFar`: depth off, `depth` slice pre-filled with `0xFFFF_FFFF`; after `readNative` every entry is `0`.
  - `aReadbackWhileASpeculativePictureIsUpReadsTheRealTimeline`: real frame 1 fills red; a speculative group after it fills the same rect green (the `speculation_test` helpers); drain; `pending_restore != null`; `readNative` over the rect reads red.

- [ ] **Step 2: Run them to see them fail**

Run: `zig build test-metal -Doptimize=ReleaseFast -Dmetal-filter=readNative` (and the test names)
Expected: compile error, `readNative` not a member.

- [ ] **Step 3: Implement.** The kernels; the two pipelines (`device.newComputePipelineState`, built where `Set.init` builds the movers, inside its `Built` cleanup); depth `.shaderRead` only when `depth_buffer` (a memoryless texture may not be shader-readable). `readNative`: call `settleSpeculation()` first (the real timeline is what a readback reads; the speculative picture comes back with the next group); a lazily-allocated shared buffer of `native_pixels * 6` bytes kept on the renderer (colour then depth); dispatch `width x height` threads; for depth while `!vram.depth_persists`, `@memset(depth, 0)` and skip the kernel.

- [ ] **Step 4: Run them to see them pass**, then the full suite: `zig build test-metal -Doptimize=ReleaseFast`. Expected: all pass.

- [ ] **Step 5: Commit** — `git commit -m "feat: native rect readback through a gather kernel"`

---

### Task 4: Carry VRAM across a rebuild instead of resyncing

**Files:**
- Modify: `ps1-metal/src/live_renderer.zig` (`rebuildVram`)
- Modify: `ps1-metal/src/frame_renderer.zig` (`applySettings` drops `requestResync`)
- Modify: `ps1-metal/tests/frame_renderer_test.zig`, `ps1-metal/tests/live_renderer_scale_test.zig`
- Modify: `.claude/skills/ps1-gpu-metal/SKILL.md` (the paragraph "**`FrameRenderer` calls `requestResync()` on every VRAM rebuild**" and the `resync` cause list that names "a scale change")

**Interfaces:**
- Consumes: Task 3's `readNative`.
- Produces: `rebuildVram(scale, depth_buffer)` keeps its signature; after it the new texture's native view equals the old one's, and the depth plane is carried when the old AND the new plane persist (else the new plane is far).

- [ ] **Step 1: Change the tests first**
  - `aScaleChangeRaisesAResyncFromTheRenderThread` becomes `aScaleChangeCarriesTheVramWithoutAResync`: publish and execute a fill at 1x, post `.scale = 3`; `!needsResync()`; the 3x texture's `readbackNative` equals the 1x readback taken before the post.
  - `aDepthToggleRebuildsTheVramAndResyncs` becomes `aDepthToggleRebuildsTheVramWithoutAResync`: same assertions on `depth_persists` and the re-post, with `!needsResync()` after the toggle.
  - `aScaleChangeLeavesExactlyOneConsumer`: drop its comment and expectation about the resync adopting frame 1's shadow; frame 1 now executes normally.
  - The `live_renderer_scale_test` case that rebuilds 1x -> 3x then calls `drainAfterAResync` becomes `aRebuildCarriesUploadsAndFillsExactly`: frames 1 and 2 (an upload of a texture page and a fill), rebuild to 3x, frame 3 draws a textured triangle sampling that page; the rebuilt texture equals a fresh 3x renderer that replayed frames 1-3 (uploads and fills replicate N x N at any scale, so the carry is exact for them). This is the Crash 1 "level vanishes after a depth toggle" regression in its new shape.
  - New `aDepthPlaneIsCarriedWhileItPersists`: depth on at 1x, `uploadNativeDepth(plane)`, rebuild to 3x depth on; `readNative`'s depth equals `plane`. Rebuild to depth off and back on: plane is far.

- [ ] **Step 2: Run them to see the new ones fail**: `-Dmetal-filter=Carr` and `-Dmetal-filter=WithoutAResync`. Expected: FAIL (resync raised / texture blank).

- [ ] **Step 3: Implement.** In `rebuildVram`, after both new halves are built and before the old ones go: `readNative` of the whole VRAM (and depth when both persist) from the old renderer into a scratch, then `vram.uploadNative` / `uploadNativeDepth` into the new one. The doc comment says the carry replaces the resync and that the picture drops to native until the game repaints, as an adoption did. In `applySettings`, remove `self.x.queue.requestResync()` and rewrite its doc comment to name the carry.

- [ ] **Step 4: Run** `zig build test-metal -Doptimize=ReleaseFast`. Expected: all pass. Then `zig build test` (session pure tests). Expected: pass.

- [ ] **Step 5: Update the skill paragraph** to: a rebuild carries the native VRAM (and the depth plane while it persists both sides) into the new texture, so it raises no resync; the old rule's bug (a blank texture under an incremental stream) is what the carry prevents.

- [ ] **Step 6: Commit** — `git commit -m "feat: carry VRAM across a scale or depth rebuild"`

---

### Task 5: The blocking readback request on the render thread

**Files:**
- Create: `ps1-metal/src/readback_desk.zig`
- Modify: `ps1-metal/src/frame_renderer.zig` (owns a desk, serves it at the end of `executeArrived`)
- Modify: `ps1-metal/src/render_thread.zig` (`readback`, and `stop`'s backstop)
- Modify: `ps1-metal/src/root.zig` (or whatever re-exports the modules; export `readback_desk`)
- Test: `ps1-metal/tests/render_thread_test.zig`

**Interfaces:**
- Consumes: Task 3's `LiveRenderer.readNative`; `LiveRenderer.consumed_seq`.
- Produces:
  - `pub const Readback = struct { rect: pi.VramRect, colour: []u16, depth: ?[]u32, through_seq: u64, served_by_backstop: bool = false, done: std.Thread.ResetEvent = .{} }`. The caller owns it and its slices until `done` is set.
  - `pub const ReadbackDesk = struct { pub fn post(*ReadbackDesk, *Readback) void; pub fn serve(*ReadbackDesk, live: *LiveRenderer) void; pub fn answerAll(*ReadbackDesk, live: *LiveRenderer) void }`: a `Lock`-guarded intrusive list (or a fixed array of 4: one emulator thread posts one at a time; more is a programming error and panics). `serve` answers every posted request whose `through_seq <= live.consumed_seq` and leaves the rest posted; `answerAll` answers every one regardless, setting `served_by_backstop`.
  - `FrameRenderer.desk: ReadbackDesk`; `executeArrived` calls `self.desk.serve(self.live)` after the drain, occluded or not.
  - `RenderThread.readback(self: *RenderThread, req: *Readback) void`: posts, `frameArrived()`, waits on `req.done`. Debug builds use `timedWait(2 s)` and `@panic("readback: the render thread did not answer in 2 s")`; release waits without a bound.
  - `RenderThread.stop` calls `self.r.desk.answerAll(self.r.live)` after the join (the thread is gone, so the caller may encode).

- [ ] **Step 1: Write the failing tests** (all with a running `RenderThread`, the `Bench` in `render_thread_test.zig`):
  - `aReadbackSeesEveryFrameQueuedBeforeIt`: publish frames 1-3 (fills at different rects) without waiting, then `readback(.{ full rect, through_seq = 3 })`; colour equals a `Rig` replay of the three frames.
  - `aReadbackCompletesWhileOccluded`: post `.occluded = true` settings, publish a frame, readback through it: returns, pixels match.
  - `aReadbackAcrossAScaleRebuildReadsTheCarriedPixels`: execute a fill at 1x, post `.scale = 3` and immediately `readback` through the same seq: equals the 1x picture.
  - `aReadbackPostedBeforeTheThreadStartsIsServed`: post on the desk and publish before `rt.start`, then start, then wait on `done`: served, `!served_by_backstop`.
  - `stopAnswersAPendingReadbackWithTheCurrentTexture`: from a helper thread, `readback(through_seq = 99)` (never reached); after it has posted, `rt.stop()`; the helper returns with `served_by_backstop` and the current texture's pixels.

- [ ] **Step 2: Run them to see them fail**: `-Dmetal-filter=Readback` / `-Dmetal-filter=readback`. Expected: compile error.

- [ ] **Step 3: Implement** to the interfaces above. `serve` is called from `perform` and `fire` alike through `executeArrived`; `perform` already applies settings first, which is what puts the carry before the readback.

- [ ] **Step 4: Run** the filter, then the full `test-metal`. Expected: all pass, and run the new tests 20 times in a loop (`for i in $(seq 20); do zig build test-metal -Doptimize=ReleaseFast -Dmetal-filter=eadback || break; done`) to shake out ordering races. Expected: 20 passes.

- [ ] **Step 5: Commit** — `git commit -m "feat: render-thread readback request with a stop backstop"`

---

### Task 6: The asynchronous capture ring

What rewind (Plan C) fills its VRAM section from without a GPU round trip on the emulator thread.

**Files:**
- Create: `ps1-metal/src/capture_ring.zig`
- Modify: `ps1-metal/src/live_renderer.zig` (owns a ring; `execute` serves it after replaying a real slot, never from `speculate`)
- Test: `ps1-metal/tests/capture_ring_test.zig` (new), registered in `metal_test.zig`

**Interfaces:**
- Consumes: Task 3's gather pipeline (`Set.gather_colour`).
- Produces:
  - `pub const CaptureRing = struct { pub const slots = 3; ... }` with one shared `mtl.Buffer` of `native_pixels * 2` bytes per slot, allocated in `init(device)`.
  - Emulator thread: `pub fn request(self: *CaptureRing, seq: u64) ?u32` (a free slot's index, or null when all three are busy); `pub fn poll(self: *CaptureRing, i: u32) Poll` where `Poll = union(enum) { pending, ready: *const [native_pixels]u16, failed }`; `pub fn release(self: *CaptureRing, i: u32) void`.
  - Render thread: `pub fn serve(self: *CaptureRing, executed_seq: u64, encode: anytype) void`: a requested slot with `seq == executed_seq` is encoded (gather of the whole native VRAM into its buffer, on its own command buffer, a completion block flips it to ready); a requested slot with `seq < executed_seq` is marked failed (its frame was discarded by a resync). Slot state is one atomic enum `free, requested, encoded, ready, failed`.
  - `LiveRenderer.captures: CaptureRing`; `deinit` waits for any encoded slot to complete before freeing.

- [ ] **Step 1: Write the failing tests**:
  - `aCaptureLandsAfterItsFrameExecutes`: `request(2)`; publish and drain frames 1, 2, 3 (frame 3 overwrites frame 2's fill); poll until ready (bounded loop, 2 s); the buffer equals the native VRAM after frame 2, not 3 (compare with a `Rig` replay of 1-2), at scales 1 and 3.
  - `aCaptureForADiscardedSeqFails`: `request(2)`; raise a resync whose adopted shadow is seq 3 so frame 2 is discarded; drain; `poll` is `.failed`.
  - `aFullRingRefusesARequest`: three requests succeed, the fourth returns null; `release` one, the next succeeds.
  - `aSpeculativeFrameNeverServesACapture`: `request(5)`; drain real frame 4 with a speculative group after it; `poll` stays `.pending`.

- [ ] **Step 2: Run them to see them fail**: `-Dmetal-filter=Capture`. Expected: compile error.

- [ ] **Step 3: Implement** to the interfaces. The completion block follows `FrameRenderer`'s `Shot` pattern (`objc.Block`, the block's last touch is an atomic store).

- [ ] **Step 4: Run** the filter, then full `test-metal`. Expected: pass.

- [ ] **Step 5: Commit** — `git commit -m "feat: asynchronous native capture ring"`

---

### Task 7: 24bpp from the render texture

**Files:**
- Modify: `ps1-metal/shaders/DisplayShader.metal:108-130` (the 24bpp branch reads `vram` at the native subtexel)
- Modify: `ps1-metal/src/frame_renderer.zig` (`pictureParams` uploads the shadow only for `software_display`; `chooseDisplay` loses its 24-bit exception)
- Modify: `ps1-metal/src/display.zig` (doc comments naming the shadow's readers)
- Modify: `ps1-metal/tests/display_scale_test.zig`, `ps1-metal/tests/display_test.zig`, `ps1-metal/tests/frame_renderer_test.zig:175-190`
- Modify: `.claude/skills/ps1-gpu-metal/SKILL.md` (every sentence saying 24bpp scans out of the 1x shadow: "24bpp scans out of the 1x shadow permanently", the scaled display path's "24bpp and the `PS1_SOFTWARE_DISPLAY` seam read the 1024x512 shadow", the runahead bullet's 24-bit exception) and `CLAUDE.md` if it repeats it

**Interfaces:**
- Produces: the 24bpp words are `vram.read(uint2(((p.vram_x + (byte_off >> 1)) & 1023) * p.scale, row * p.scale))` and the `+ 1` word likewise: the native subtexel, the same rule as readback. `chooseDisplay(real, ahead)` returns `ahead orelse real`.

- [ ] **Step 1: Change the tests first**
  - `twentyFourBppDisplaysIdenticallyAtEveryScale`: the RENDER texture holds the 24bpp image (`uploadNative(lcgImage(default_seed))`) and the shadow holds a DIFFERENT image, so a path still reading the shadow fails; the picture is identical at every scale in {1, 2, 3, 4, 8}.
  - New `twentyFourBppIgnoresEveryNonTopLeftSubtexel`: s = 3, a scaled upload whose top-left subtexels are the lcg image and every other subtexel is `0xFFFF`; the picture equals the 1x one.
  - `display_test.zig`'s 24bpp cases put their bytes in the render texture rather than the shadow.
  - The `chooseDisplay` test: a 24-bit real or ahead display now yields `ahead` too.

- [ ] **Step 2: Run them to see them fail**: `-Dmetal-filter=TwentyFour` and `-Dmetal-filter=twentyFour`. Expected: FAIL.

- [ ] **Step 3: Implement.** The shader branch's comment states the new rule: 24bpp reads the render texture at each word's top-left subtexel, where a native upload (which is all FMV is) is exact at every scale. `pictureParams` uploads the shadow only when `debug.software_display`.

- [ ] **Step 4: Run** full `test-metal`. Expected: pass. Then `zig build metallib && zig build capi-lib && zig build macos`, launch the app, and ask the user to hand-check a Croc and a Silent Hill FMV at 4x (the spec's hand check; record their answer in the commit-free notes of Task 8).

- [ ] **Step 5: Update the skill and CLAUDE.md sentences** listed above to the new rule.

- [ ] **Step 6: Commit** — `git commit -m "feat: 24bpp scans out of the render texture"`

---

### Task 8: Close Plan A

**Files:**
- Modify: `docs/superpowers/specs/2026-10-26-gpu-only-vram-design.md` (one line under "Plans": Plan A done, with the commit range and the deviations above)
- Create: a memory file `project-gpu-only-vram-plan-a-done.md` and its index line

- [ ] **Step 1: Full gates**

Run: `zig build test && zig build test-metal -Doptimize=ReleaseFast && zig build trace-golden -Doptimize=ReleaseFast -- verify && zig build trace-golden -Doptimize=ReleaseFast -- stream-verify && zig build trace-golden-metal -Doptimize=ReleaseFast -- parity`
Expected: all green, parity as recorded in Task 2 (or better).

- [ ] **Step 2: Write the spec line and the memory note** (what landed, the parity result, the deviations, the FMV hand check's outcome).

- [ ] **Step 3: Commit** — `git commit -m "docs: GPU-only VRAM Plan A done"`
