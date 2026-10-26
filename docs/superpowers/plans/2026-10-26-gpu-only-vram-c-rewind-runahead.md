# GPU-only VRAM, Plan C: rewind and runahead under GPU-only

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `PS1_GPU_VRAM=1` session runs runahead and rewind with the render texture as the machine's only VRAM, and the debug seams that need a software shadow force dual.

**Architecture:** Runahead needs no pixels on the machine side: a mark and a return carry the landing area, a speculative read is never served, and a speculative flush goes to the group. Rewind captures every section but VRAM at the frame, keeps the previous capture's VRAM bytes in `head` (`Diff.keep`), and fills them later from the renderer's asynchronous `CaptureRing` with a second diff appended to the same entry. A step never loads a capture still waiting for its VRAM: it drops every pending capture and lands on the newest complete one. A pushed shadow now carries the machine's drawing environment and write cursor, so a rewind step (or a load) no longer leaves Metal drawing with the previous timeline's environment.

**Tech Stack:** Zig 0.17.0, Metal (via `ps1-metal`), `ps1-golden-metal`.

**Spec:** `docs/superpowers/specs/2026-10-26-gpu-only-vram-design.md`, sections 5 and 8 and their gates in section 7. Plans A and B are done; their deviations are in the spec's Plans section.

## Global Constraints

- Run from the repo root. Unit tests: `zig build test`. Metal and session device tests: `zig build test-metal -Doptimize=ReleaseFast` (narrow with `-Dmetal-filter=<substring>`). Trace gates: `-Doptimize=ReleaseFast`.
- **With `rasterize` at its default the core behaves exactly as today: no golden moves.** `zig build test`, `zig build trace-golden -Doptimize=ReleaseFast -- verify`, `-- snapshot`, `-- savestate`, `verify --threaded=deferred` and `test-metal` stay green after every task. No golden is recaptured.
- **A GPUREAD inside a mark is never served** (it reads the landing area and is counted), and **a flush inside a mark goes to the speculative group, never to the real queue.**
- **A rewind step never restores a VRAM older or newer than the rest of the capture it belongs to.** The rewind memory budget is unchanged: native VRAM only, never a texture per capture.
- Under GPU-only, `pgxp_mark`'s depth PLANE is neither captured nor restored; its `depth_state` is still carried.
- `PS1_LIVE_DIFF` or `PS1_SOFTWARE_DISPLAY` set forces the session into dual and logs that it did.
- The app still ships dual; GPU-only stays behind `PS1_GPU_VRAM=1` (Plan D flips it).
- Debug deadlock bound for any emulator-thread wait on the render thread stays **2 s**; release has no timeout.
- Commit messages are a title line only (`feat:`/`fix:`/`refactor:`/`test:`/`docs:`), one commit per task, on master. Never push.
- Match the surrounding style: doc comments state the rule and its reason, no thinking-aloud comments, no copy-paste. No file in `ps1-core/src` over ~600 lines.

## Decisions the spec left to the builder

- **A mark WRITES the VRAM section from the landing area** rather than skipping it. It is the same 1 MB copy a dual mark makes, a skip would need a second trusted layout, and the transfer cursors beside it must be real either way.
- **An async rewind capture is filled by a SEPARATE diff, not delayed.** The capture is taken at its frame with the VRAM bytes kept (`Diff.keep`); when the renderer's gather lands, the VRAM bytes are diffed over `head` and the runs appended to that capture's entry. Delaying would need a second full copy of the state, the traffic `Diff` exists to avoid.
- **Several captures may wait at once** (at most `CaptureRing.slots`, 3), filled oldest first. The order is what makes the second diff exact: `head`'s VRAM bytes always hold the newest FILLED capture's VRAM, which is exactly what the oldest pending capture's entry must turn back into.
- **A capture whose VRAM cannot come is dropped, with every newer one.** That happens when the ring is full (the newest only) or a seq was discarded by a resync. Entries chain, so a middle one cannot be removed alone.

## Additions to the spec, for the user to confirm

- **A pushed shadow carries the machine's drawing environment and write cursor** (Task 5). Plan B left this open: after a load, a reset or a rewind step, Metal's `Rasterizer.env` and write cursor are the replaced timeline's. Under dual the software VRAM is the truth and the next resync hides it; under GPU-only it draws wrong pixels into the machine's only VRAM, and a rewind step does it every step.
- **A rewind step's shadow under GPU-only carries no depth plane.** A trusted capture holds no depth, so the renderer keeps its plane, which is what dual's step does too (it publishes the live plane, which is the future's).
- **`HostStats` splits `unserved_reads`** into `unserved_reads` (no host: a bug) and `speculative_reads` (a mark held: expected), so `gpu-verify`'s "unserved 0" stays a meaningful failure under `--snapshot`.
- **A mark taken under GPU-only asserts an empty recorder.** A speculative flush takes the open chunk; anything real left in it would be thrown away with the group.

## Review Focus

1. **A flush inside a speculative frame while the real frame is STAGED.** `publishChunk` would `stage` into the very slot holding the staged real frame and overwrite it. The flush must go to the group and never touch the ring. Test: Task 4's `aFlushWhileSpeculatingGoesToTheGroupAndLeavesTheStagedFrame`.
2. **A speculative GPUREAD that finds the real timeline's stale mark set.** `settleRead` clears `read_stale` before `settle` refuses to serve, so the real read resumes after the return without its re-settle. Test: Task 1's `aSpeculativeReadLeavesTheRealStaleMark`.
3. **A capture requested after its seq already executed** waits forever and pins a ring slot; three of them stop rewind for good. The request must be made after `publishFrame` and before the frame's final stream is published or staged. Test: Task 6's `aCaptureIsRequestedBeforeItsFrameIsPublished`.
4. **A rewind step while captures are pending.** It must land on the newest COMPLETE capture, never on one whose VRAM bytes are still the previous capture's. Test: Task 2's `aStepWithPendingCapturesLandsOnTheNewestCompleteOne`.
5. **A load, a reset, a swap or a budget change with captures in flight.** The core forgets them; the session's ring slots must be released, not leaked. Test: Task 6's `aClearedHistoryReleasesEveryRingSlot`.

---

### Task 1: The core's speculation rules

**Files:**
- Modify: `ps1-core/src/gpu/host.zig` (`Stats`), `ps1-core/src/gpu/sink.zig`, `ps1-core/src/savestate/pgxp_mark.zig`, `ps1-capi/src/root.zig` (`ps1_snapshot_mark`), `ps1-golden/src/gpu_verify.zig` (the stats print)
- Modify: `ps1-core/src/gpu/recorder.zig` (`isEmpty`, if missing)
- Test: `ps1-core/tests/gpu_only_test.zig`, `ps1-capi/src/capi_test.zig`

**Interfaces:**
- Produces:
  - `HostStats.speculative_reads: u64` — reads refused because a mark is held. `unserved_reads` now counts ONLY reads that found no host.
  - `pub fn gpuOnly(self: *const Sink) bool` — `kind == .dual and !rasterize`: `vram` is a landing area.
  - `Recorder.isEmpty() bool` — no records and no payload since the last take.

- [ ] **Step 1: Write the failing tests**

```zig
test "GPU-only: aSpeculativeReadIsCountedApartFromAnUnservedOne" {
    // got: rasterize off, fake host; speculating = true; settle .all
    // stats.speculative_reads == 1, stats.unserved_reads == 0, fake.reads == 0
    // host = null, speculating = false; settle .all
    // stats.unserved_reads == 1
}

test "GPU-only: aSpeculativeReadLeavesTheRealStaleMark" {
    // GP0(C0) read setup; push a fill while the read is active -> read_stale
    // speculating = true; readData() once; read_stale still true
    // speculating = false; readData(); fake.reads grew by one (re-settled),
    // read_stale false
}

test "GPU-only: aMarkUnderGpuOnlyLeavesTheDepthPlaneAlone" {
    // bus with PGXP and the depth buffer on, rasterize off
    // vram.depth filled with 7; Mark.take; vram.depth filled with 9;
    // gp0.depth_state changed; Mark.restore
    // vram.depth is still all 9 (the plane is a landing area),
    // gp0.depth_state is the value at take
}
```

Under dual, `pgxp_mark`'s existing tests already pin that the plane round-trips; they must stay green. The empty-recorder assert has no test of its own: a test runner cannot catch a panic, and `capi: aMarkHeldMeansTheHostIsNeverAsked` already marks a GPU-only handle with an empty recorder.

- [ ] **Step 2:** Run `zig build test` — expected: the new tests fail (`speculative_reads` undefined; the stale mark is cleared; the plane is restored).
- [ ] **Step 3: Implement**
  - `Sink.settle` counts `speculative_reads` while `speculating`; `unserved_reads` only for `host == null`.
  - `Sink.settleRead` returns without touching `read_stale` while `speculating`: the mark belongs to the real timeline's read, which the return resumes.
  - `PgxpShadows.take`: `with_depth = bus.pgxpDepthBuffer() and !bus.gpu.sink.gpuOnly()`. `restore` puts `depth_state` back whenever `held` and `pgxpDepthBuffer()`, and the plane only when `held_depth`. Update the module comment: the plane is a landing area under GPU-only, and Metal's `restoreRegion` already puts depth back.
  - `ps1_snapshot_mark`: under `h.vram_mode == .gpu`, `std.debug.assert(h.cpu.bus.gpu.sink.rec.isEmpty())`, with a doc line saying why (a speculative flush takes the open chunk).
  - `gpu_verify.report` prints `speculative` beside `unserved`.
- [ ] **Step 4:** Run `zig build test` — expected: all pass.
- [ ] **Step 5: Commit** `feat: speculative reads are counted apart and keep the real stale mark`

---

### Task 2: Rewind captures with deferred VRAM

**Files:**
- Modify: `ps1-core/src/savestate/rewind.zig`, `ps1-core/src/savestate/stream.zig`, `ps1-core/src/savestate/savestate.zig`, `ps1-core/src/savestate/gpu_state.zig`, `ps1-core/src/savestate/mark.zig` (call sites), `ps1-capi/src/root.zig`
- Test: `ps1-core/tests/rewind_test.zig`, `ps1-capi/src/capi_test.zig`

If `rewind.zig` passes ~600 lines, move `Diff`, `encode` and `apply` into `ps1-core/src/savestate/delta.zig` and re-export them from `rewind.zig` under the same names.

**Interfaces:**
- Produces (core):
  - `Diff.keep(d: *Diff, pos: usize, len: usize) error{OutOfMemory}!void` — leaves `head[pos..pos+len]` as it is and records nothing, exactly as writing those same bytes would; closes any open run.
  - `savestate.VramBytes = enum { write, keep }`; `saveTrusted(cpu, dst, vram: VramBytes)` and `saveTrustedOver(cpu, diff, vram: VramBytes)`. `.keep` leaves the destination's bytes under `vram.data` untouched (a `buf` is not written there, a `diff` calls `keep`). Every existing caller passes `.write`.
  - `savestate.Layout = struct { len: usize, vram_at: usize }`; `pub fn trustedLayout(cpu: *const Cpu) Layout` — a counting pass that also records where the GPU section's `vram.data` bytes start. `Writer` gains `vram: VramBytes = .write` and `vram_at: ?usize = null`, and `pub fn vram(w, data: *const [native_pixels]u16) Error!void`, which `saveGpu` calls in place of `w.array(&v.data)`.
  - `Rewind.defer_vram: bool = false` — set by the host; captures then keep VRAM.
  - `Rewind.PendingVram = struct { first: u64, last: u64 }` (inclusive capture ids); `pub fn pendingVram(r) ?PendingVram`.
  - `pub fn fillVram(r: *Rewind, id: u64, pixels: *const [native_pixels]u16) error{OutOfMemory}!bool` — fills the OLDEST pending capture; false (nothing changed) when `id` is not the oldest pending.
  - `pub fn dropVramFrom(r: *Rewind, id: u64) void` — drops every pending capture with an id at or above `id`, newest first.
- Produces (`ps1-capi/src/root.zig`, Zig-only like `copyVramAsIs`):
  - `pub fn rewindPendingVram(h: *const Handle) ?ps1.savestate.Rewind.PendingVram`
  - `pub fn rewindFillVram(h: *Handle, id: u64, pixels: *const [native_pixels]u16) bool`
  - `pub fn rewindDropVramFrom(h: *Handle, id: u64) void`
  - `setVramMode` sets `h.rewind.defer_vram = mode == .gpu`.

- [ ] **Step 1: Write the failing tests**

```zig
test "Diff: keepRecordsNothingAndLeavesTheBytes" {
    // head = pattern A; write A[0..5], keep(5, 19), write B over [24, 64)
    // head[5..24] == A[5..24]; apply(delta) restores A everywhere
    // also with keep starting and ending mid-word
}

test "Rewind: aDeferredCaptureFilledLaterStepsBackToTheSameMachine" {
    // two machines, `want` (defer_vram off) and `got` (defer_vram on),
    // driven through the same frames with distinct VRAM each frame
    // after every capture `got` has pendingVram; fillVram(oldest, that
    // frame's VRAM) in order, sometimes two frames late
    // step both until NoHistory: the loaded machines (VRAM included) are
    // byte-identical at every step
}

test "Rewind: aStepWithPendingCapturesLandsOnTheNewestCompleteOne" {
    // defer_vram; captures C1 (filled), C2 (filled), C3 (pending), C4 (pending)
    // step: the machine is C2, VRAM included; pendingVram() == null
    // a second step: C1
}

test "Rewind: dropVramFromDropsThatCaptureAndEveryNewerOne" {
    // C1 filled, C2..C4 pending; dropVramFrom(C3's id)
    // pendingVram() == {C2, C2}; fillVram(C2) then step: the machine is C1
    // frames_covered still counts the frames of the dropped captures
}

test "Rewind: aFillForAnyButTheOldestPendingIsRefused" {
    // C1, C2 pending; fillVram(C2's id) == false and changes nothing
}

test "Rewind: aStepWithOnlyAPendingFirstCaptureIsNoHistory" { }
test "Rewind: clearForgetsPendingCaptures" { }
```

```zig
test "capi: aGpuModeHandleDefersRewindVram" {
    // gpuHandle; ps1_rewind_configure(64 MB); run two frames
    // rewindPendingVram(h) != null; the CountingHost was never asked to read
    // rewindFillVram(first, zeros) == true; pending == null
}
```

- [ ] **Step 2:** Run `zig build test` — expected: compile failures (`keep`, `VramBytes`, `pendingVram` undefined).
- [ ] **Step 3: Implement** as in Interfaces, with these rules:
  - `capture` under `defer_vram` calls `trustedLayout` for `n` and `vram_at`, writes with `.keep`, and appends a pending id. A first capture (no entry) keeps `head`'s bytes there as they are; its fill is a plain copy.
  - `fillVram` diffs the pixels over `head[vram_at..][0..2 * native_pixels]` and appends the runs to the pending capture's entry (re-allocating its delta), then re-runs `evict`. `evict` never drops a pending entry.
  - `dropVramFrom` turns `head` back through each dropped entry's delta (it holds no VRAM runs yet), pops it, and adds its `frames` to `frames_since`, so the next capture's entry covers the gap. A dropped first capture clears `has_head`.
  - `step` with captures pending calls `dropVramFrom(first)` and then loads `head` as it is (no further pop): the same destination a step from the newest capture would have reached at best. With no head left it is `NoHistory`.
  - `clear` forgets pending captures.
- [ ] **Step 4:** Run `zig build test`, then `zig build trace-golden -Doptimize=ReleaseFast -- savestate` and `-- snapshot` — expected: all pass, goldens unchanged.
- [ ] **Step 5: Commit** `feat: rewind captures can take their VRAM later`

---

### Task 3: `gpu-verify --snapshot`

**Files:**
- Modify: `ps1-golden/src/gpu_verify.zig`, `ps1-golden/src/metal_parity.zig` (option parsing, usage)

**Interfaces:**
- Consumes: Task 1's `speculative_reads`.
- Produces: `gpu_verify.Options.snapshot: bool`; `ps1-golden-metal gpu-verify --snapshot`.

- [ ] **Step 1: Implement the detour.** After each sample is hashed, as `ps1-golden`'s `snapshot` mode does: `gate.execute(sink)` (the real open chunk goes to the rig first), `Mark.take`, `sink.speculating = true`, run `interval` instructions, `_ = sink.rec.takeChunk()` (the speculative tail is thrown away), `sink.speculating = false`, `Mark.restore`. While `speculating`, `GateHost.flush` takes and discards the chunk and counts it (`speculative_chunks`, printed with the stats). `GateHost.take` panics if called for a real read while `speculating`.
- [ ] **Step 2:** Run `zig build trace-golden-metal -Doptimize=ReleaseFast -- gpu-verify --snapshot` and again with `--record-limit=256` — expected: 9/9 OK against the unchanged goldens, `unserved 0`, `speculative` and `speculative_chunks` non-zero on at least one workload with `--record-limit=256`. Record both runs' tallies for the spec.
- [ ] **Step 3: Commit** `test: gpu-verify --snapshot runs the runahead detour under GPU-only`

---

### Task 4: A speculative flush goes to the group

**Files:**
- Modify: `ps1-session/src/vram_host.zig`
- Test: `ps1-session/tests/vram_host_test.zig`, `ps1-metal/tests/speculation_test.zig`

**Interfaces:**
- Consumes: `StreamQueue.appendSpeculative(s: Stream)` (unchanged: a stream that does not fit, or one slot too many, spoils the group).

- [ ] **Step 1: Write the failing tests**

```zig
test "VramHost: aFlushWhileSpeculatingGoesToTheGroupAndLeavesTheStagedFrame" {
    // Bench: stage(seq 1, a real frame with one record) — not committed
    // beginSpeculativeGroup(1); sink.speculating = true; push records; flush
    // queue tail unchanged, the staged slot still holds the real record,
    // the open group's count == 1; the render thread was not woken
    // commitSpeculativeGroup; commitStaged: the drain sees the real frame
}

test "VramHost: aSpeculativeFrameThatOverflowsSpoilsOnlyItsGroup" {
    // more chunks than max_speculative_frames inside one group
    // commitSpeculativeGroup hands nothing over; the real frame drains whole
}
```

```zig
test "LiveRenderer: aGroupCutIntoChunksReplaysAndRestoresLikeAWholeOne" {
    // the speculationLeavesTheRealTimelineUntouched shape, with the group's
    // one frame split into two slots at a payload boundary (an upload
    // crossing the cut): the speculative picture equals the whole frame's,
    // and after settleSpeculation the texture hash equals the real timeline's
}
```

- [ ] **Step 2:** Run `zig build test-metal -Doptimize=ReleaseFast -Dmetal-filter=VramHost` and `-Dmetal-filter=aGroupCutIntoChunks` — expected: the VramHost tests fail (the flush publishes to the ring); the LiveRenderer test may already pass, and pins the property.
- [ ] **Step 3: Implement** `VramHost.flush`: while `sink.speculating`, `self.queue.appendSpeculative(sink.rec.takeChunk())` and return: no wait (nothing drains a group mid-build), no `frameArrived`. Doc: a speculative chunk on the real ring would put the future on the real timeline past the region restore's reach.
- [ ] **Step 4:** Run the two filters again — expected: pass.
- [ ] **Step 5: Commit** `feat: a speculative flush goes to the runahead group`

---

### Task 5: A pushed shadow carries the rasterizer's state

**Files:**
- Modify: `ps1-core/src/gpu/write_cursor.zig`, `ps1-capi/src/root.zig`, `ps1-session/src/machine.zig`, `ps1-session/src/frame_path.zig` (`publishShadow`), `ps1-session/tests/fake_machine.zig`, `ps1-metal/src/frame_exchange.zig`, `ps1-metal/src/live_renderer.zig` (`Shadow`, `drain`)
- Test: `ps1-core/tests/gpu_stream_test.zig`, `ps1-metal/tests/live_renderer_test.zig`, `ps1-session/tests/run_loop_frame_test.zig`

**Interfaces:**
- Produces:
  - `pub fn fromVram(v: *const Vram) WriteCursor` — the write cursor `Vram`'s write fields describe.
  - `capi.rasterState(h: *const Handle) RasterState` where `RasterState = struct { env: DrawingEnv, transfer: WriteCursor }` (core types: the core does not import Metal).
  - Machine contract gains `rasterState`; `HandleMachine.rasterState() metal.rasterizer.Rasterizer.State`.
  - `ShadowSlot.state: Rasterizer.State`, filled by every `publishShadow`. `Shadow.state: ?Rasterizer.State = null`: null keeps the rasterizer's own (tests that build a `Shadow` by hand).
  - `LiveRenderer.drain`: adopting a shadow with a state calls `rasterizer.setState` with it.

- [ ] **Step 1: Write the failing tests**

```zig
test "WriteCursor: fromVramMatchesTheCursorTheStreamBuilt" {
    // a Vram set up for a 5x3 upload at (1020, 510) and fed 4 words;
    // WriteCursor.setup + the same 4 words through the rasterizer's advance
    // fromVram(&vram) equals it, field for field; also for an idle Vram
}

test "LiveRenderer: adoptingAShadowAdoptsItsState" {
    // renderer executes a frame setting draw offset A and starting an
    // upload; a resync with a shadow whose state has offset B and no upload
    // rasterizer.state() == the shadow's; the next frame's primitive lands
    // at offset B
}

// run_loop_frame_test.zig (pure)
test "FramePath: everyShadowCarriesTheMachinesRasterState" {
    // FakeMachine.raster_state = { offset B, an upload in flight }
    // machineReplaced under gpu_vram, and a forced publishFrame under dual:
    // each published slot's state equals raster_state
}
```

Test file for the first test: `ps1-core/tests/gpu_stream_test.zig`. The second goes in `ps1-metal/tests/live_renderer_test.zig`, the third in `ps1-session/tests/run_loop_frame_test.zig`.

- [ ] **Step 2:** Run `zig build test` and `zig build test-metal -Doptimize=ReleaseFast -Dmetal-filter=State` — expected: compile failures.
- [ ] **Step 3: Implement** as in Interfaces. Update `Machine`'s contract list and `FakeMachine`. The doc on `ShadowSlot.state` says why: the env and the cursor are built up by records the replaced timeline sent, and a shadow is exactly the moment the texture stops being that timeline.
- [ ] **Step 4:** Run `zig build test` and `zig build test-metal -Doptimize=ReleaseFast` — expected: all pass.
- [ ] **Step 5: Commit** `fix: a shadow carries the drawing environment and write cursor`

---

### Task 6: The session runs runahead and rewind under GPU-only

**Files:**
- Create: `ps1-session/src/rewind_vram.zig`
- Modify: `ps1-session/src/frame_path.zig`, `ps1-session/src/run_loop.zig`, `ps1-session/src/machine.zig`, `ps1-session/src/session.zig`, `ps1-session/tests/fake_machine.zig`
- Test: `ps1-session/tests/rewind_vram_test.zig` (new, under `pure_test.zig`), `ps1-session/tests/run_loop_frame_test.zig`, `ps1-session/tests/session_test.zig`

**Interfaces:**
- Consumes: Task 2's `rewindPendingVram`/`rewindFillVram`/`rewindDropVramFrom`; `CaptureRing.request(seq) ?u32`, `poll(i) Poll`, `release(i)`.
- Produces:
  - Machine contract gains `rewindPendingVram`, `rewindFillVram`, `rewindDropVramFrom` (HandleMachine forwards to `capi`).
  - `pub fn RewindVram(comptime Ring: type) type` with `fifo` of `{ slot: u32, id: u64 }` (at most `CaptureRing.slots`) and:
    - `afterFrame(self, m: anytype, ring: *Ring, seq: u64) void` — a capture newer than any tracked gets a ring slot for `seq`; with none free it is dropped (`rewindDropVramFrom(last)`).
    - `collect(self, m: anytype, ring: *Ring) void` — first releases every slot whose id is outside `rewindPendingVram()`; then, oldest first, fills each `ready` slot and releases it, stops at the first `pending`, and on a `failed` one drops that capture and every newer one and releases their slots.
    - `abandon(self, ring: *Ring) void` — releases every slot.
  - `RunLoop.captures: ?*CaptureRing = null` and `RunLoop.rewind_vram: RewindVram(CaptureRing) = .{}`.
  - `frame_path.ShadowSource` gains `.restored`: `vram.data` as is and NO depth plane (`depth_valid = false`), for a trusted restore.

- [ ] **Step 1: Write the failing tests**

```zig
// rewind_vram_test.zig, with a FakeRing (request/poll/release over three
// slots the test resolves) and a FakeMachine scripting pendingVram
test "RewindVram: aReadyCaptureIsFilledOldestFirst" { }
test "RewindVram: collectStopsAtTheFirstPendingCapture" { }
test "RewindVram: aFullRingDropsOnlyTheNewestCapture" { }
test "RewindVram: aFailedCaptureDropsItAndEveryNewerOneAndReleasesTheirSlots" { }
test "RewindVram: aClearedHistoryReleasesEveryRingSlot" {
    // two slots tracked; the machine's pendingVram becomes null (a load)
    // collect releases both; the ring has three free slots
}
```

```zig
// run_loop_frame_test.zig
test "FramePath: runaheadRunsUnderGpuVram" {
    // gpu_vram, runahead 2: one iterate marks, runs 3 frames, returns
}
test "FramePath: rewindStaysOffUnderGpuVramWithoutACaptureRing" { }
test "FramePath: aGpuRewindStepPublishesTheRestoredVramWithoutDepth" {
    // gpu_vram, depth buffer on, rewinding: copyVramAsIs called,
    // copyVram and copyDepth/copyDepthAsIs not; the shadow's depth_valid false;
    // the resync raised after the shadow, before the picture frames' streams
}
```

```zig
// session_test.zig (device)
test "Session: aCaptureIsRequestedBeforeItsFrameIsPublished" {
    // GPU-only, rewind on; run until 10 captures were taken
    // every one was filled (none dropped, none failed) and no ring slot is held
}
test "Session: aHeldGpuOnlyRewindGoesBackAndLosesNothing" {
    // GPU-only, rewind on; run 60 frames; hold rewind until frames covered
    // has fallen by at least 8; release and run 30 more
    // lost_lossless == 0, vramStats().unserved_reads == 0, and after stop
    // every CaptureRing slot is free
}
```

The pixels a step restores are pinned below the session: Task 2's `aDeferredCaptureFilledLaterStepsBackToTheSameMachine` (the machine's VRAM), Task 5 (the renderer's environment) and Plan B's `aLoadPushesTheLoadedVramBeforeTheResync` (the push itself).

```zig
test "Session: aGpuOnlySessionWithRunaheadLosesNothing" {
    // GPU-only, runahead 2, 120 frames: lost_lossless == 0,
    // vramStats().unserved_reads == 0
}
```

- [ ] **Step 2:** Run `zig build test` and `zig build test-metal -Doptimize=ReleaseFast -Dmetal-filter=Session` — expected: the new tests fail.
- [ ] **Step 3: Implement**
  - `iterate`: drop the `gpu_vram` guard on runahead. Rewind under `gpu_vram` needs `captures != null`; without it the budget stays 0. `rewind_vram.collect` runs after `serviceRequests` every pass, and again before a rewind step, so a capture that has landed is not dropped by the step.
  - The request goes between `publishFrame` and `publishStream`/`stage`, under the seq `publishFrame` just started. Doc why: the renderer serves a capture when its seq executes, and a request registered later fails forever.
  - `rewindStep` publishes its shadow with `.restored` under `gpu_vram`, `.settled` under dual (unchanged), keeping the resync after it and before the streams. `publishFrame(self, force)` becomes `publishFrame(self, force: ?ShadowSource)`.
  - `Session.create` under GPU-only sets `loop.captures = &renderer.live.captures`. `Session.destroy` calls `rewind_vram.abandon` after the emulator thread is joined and before the renderer goes.
  - Update the run loop's doc comments that say GPU-only has no rewind or runahead, and the `runaheadAndRewindAreOffUnderGpuVram` test, which this replaces.
- [ ] **Step 4:** Run `zig build test` and `zig build test-metal -Doptimize=ReleaseFast` — expected: all pass.
- [ ] **Step 5: Commit** `feat: rewind and runahead run under GPU-only VRAM`

---

### Task 7: The debug seams force dual

**Files:**
- Modify: `ps1-session/src/session.zig`, `ps1-session/src/frame_path.zig`
- Test: `ps1-session/tests/run_loop_frame_test.zig` (or a pure test of `chooseVram`)

**Interfaces:**
- Produces: `pub fn chooseVram(configured: capi.VramMode, gpu_env: bool, debug: metal.frame_renderer.Debug) capi.VramMode` in `session.zig`.

- [ ] **Step 1: Write the failing tests**

```zig
test "Session: aDebugSeamForcesDual" {
    // chooseVram(.gpu, true, .{ .live_diff = true }) == .dual
    // chooseVram(.dual, true, .{ .software_display = true }) == .dual
    // chooseVram(.dual, true, .{}) == .gpu; chooseVram(.dual, false, .{ .live_stats = true }) == .dual
}
```

- [ ] **Step 2:** Run `zig build test` — expected: `chooseVram` undefined.
- [ ] **Step 3: Implement.** `Session.create` reads the debug switches before the machine boots and logs `session: PS1_LIVE_DIFF/PS1_SOFTWARE_DISPLAY need dual; GPU-only is off` when it overrides. `publishFrame` drops its `!gpu` guard on `shadow_every_frame` (now unreachable under GPU-only), and `theDebugShadowIsNeverTakenUnderGpuVram` goes with it.
- [ ] **Step 4:** Run `zig build test` — expected: all pass.
- [ ] **Step 5: Commit** `feat: the software-shadow debug seams force dual VRAM`

---

### Task 8: Gates, hand check, spec and memory

- [ ] **Step 1:** Run the whole set, ReleaseFast where noted, and record the tallies: `zig build test`; `zig build test-metal -Doptimize=ReleaseFast`; `zig build trace-golden -Doptimize=ReleaseFast -- verify`, `-- snapshot`, `-- savestate`, `-- verify --threaded=deferred`; `zig build trace-golden-metal -Doptimize=ReleaseFast -- gpu-verify` and `-- gpu-verify --snapshot --record-limit=256`. Expected: all green, no golden moved.
- [ ] **Step 2:** `zig build capi-lib metallib macos`, then ask the user for the in-app hand check: `PS1_GPU_VRAM=1 zig-out/Substation.app/Contents/MacOS/Substation`, Crash in-level with runahead 2 and with rewind held, at 1x and 4x; one run with `PS1_LIVE_DIFF=1 PS1_GPU_VRAM=1` must log the forced dual.
- [ ] **Step 3:** Update the spec's Plans section: Plan C done, with commits, the `gpu-verify --snapshot` tallies, and the deviations above. Commit `docs: GPU-only VRAM Plan C done`.
- [ ] **Step 4:** Write the memory `project-gpu-only-vram-plan-c-done.md` (what landed, the gates, the open hand check, traps hit) and its `MEMORY.md` line; remove the "Open: env+cursor" line from Plan B's memory, which Task 5 closes.
