# Metal renderer Phase D1 — the live path at 1× — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the Metal rasterizer on the screen — a real game's GP0 command stream leaves `ps1-core` through the C ABI, crosses to the render thread, and becomes the picture the player sees, at internal resolution 1×.

**Architecture:** `ps1-capi` compiles with `gpu_sink = .dual` so every frame is recorded as well as rasterized. `ps1_take_frame_stream` hands the core-owned records and payload out once per frame; the emulator thread copies them into a preallocated 4-slot ring and returns. The `MTKView` draw callback drains every queued stream in order through the existing `MetalRasterizer`, then presents once. The 1× software shadow stays complete and authoritative for 24bpp scanout, for the overflow/reset resync, and as the per-frame divergence oracle.

**Tech Stack:** Zig 0.16.0, Swift 6 / swift-testing, Metal (MSL), Xcode 26.6, `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-08-30-metal-renderer-phase-d1-live-path-design.md`
(parent: `docs/superpowers/specs/2026-08-23-metal-hardware-renderer-design.md`)

## Global Constraints

- **`zig version` must be 0.16.0.** The std API here is 0.16-specific.
- **Run every Zig command from the repo root.** Harnesses read BIOS, discs and ROMs via paths relative to the process CWD.
- **`ps1-macos/test.sh` needs `zig build capi-lib` and `zig build metallib` built first**, and says so. Both need full Xcode.
- **No file in `ps1-core/src` over ~600 lines.** Split by function.
- **Run `zig fmt` before committing** anything under `ps1-core/`, `ps1-capi/`, `ps1-golden/`.
- **Gate 1 is a freeze.** A moved Phase B/C fixture hash is a bug in this phase, never a baseline to update. Phase 0 was the only phase permitted to change output.
- **Nothing may trap across the C ABI.** Every failure is a negative return code; `panic` aborts rather than unwinding into Swift.
- **No allocation on the emulator thread.** It runs at `.userInteractive` QoS (`EmulatorRunner.swift:89`). Allocation on the *render* thread is acceptable; per-frame allocation there is still waste and is removed in Task 4.
- **Recorder capacities are `max_records = 65_536` and `max_payload_words = 524_288`** (`ps1-core/src/gpu/recorder.zig:15,18`). Every mirror of these numbers is checked against the source, never re-typed and hoped for.
- **`Ps1PrimInstance` is 168 bytes** (42 × 4). `Ps1GpuCommand` is 72 bytes. Both are pinned by existing static assertions; do not change either.
- **Swift tests return early without a Metal device** rather than failing — `MTLCreateSystemDefaultDevice()` is nil on a headless runner and a red suite there is noise, not signal.
- **Do not `git push`.** Commit locally, one commit per task, on the current branch.

---

## File Structure

**Zig / C ABI**

- `build.zig` — modify: `capi_core_mod` gets `recording_sink`; `capi_test` gets `record_core_mod`.
- `ps1-capi/src/root.zig` — modify: arm the recorder in `buildMachine`; add `Ps1GpuStream` and `ps1_take_frame_stream`; add the capacity comptime check.
- `ps1-capi/include/ps1.h` — modify: contract rule 4, the two capacity macros, `Ps1GpuStream`, the prototype.
- `ps1-capi/src/capi_test.zig` — modify: tests for arming, stream contents, overflow, take-resets.

**Swift — the queue**

- `ps1-macos/Sources/PS1/StreamQueue.swift` — **create.** `StreamSlot` (one frame's copied records + payload) and `StreamQueue` (SPSC ring, resync flag). One responsibility: cross-thread transport and the resync policy. Nothing Metal, nothing C beyond the record type.
- `ps1-macos/Sources/PS1/Ps1Core.swift` — modify: `takeFrameStream()`.
- `ps1-macos/Sources/PS1/EmulatorRunner.swift` — modify: own the queue, tag frames with a `seq`, publish VRAM then stream, expose `requestResync()`.
- `ps1-macos/Tests/PS1Tests/StreamQueueTests.swift` — **create.**

**Swift — the renderer**

- `ps1-macos/Sources/PS1/MetalRasterizer.swift` — modify: `synchronous` flag, persistent instance and payload buffers.
- `ps1-macos/Sources/PS1/LiveRenderer.swift` — **create.** Owns `MetalVram` + `MetalRasterizer` + the drain/resync decision + the `PS1_LIVE_DIFF` oracle. Exists so the policy is testable without an `MTKView`.
- `ps1-macos/Tests/PS1Tests/LiveRendererTests.swift` — **create.**

**Swift / MSL — display**

- `ps1-macos/Shaders/DisplayShader.metal` — modify: second texture binding, depth routing, `software_display`.
- `ps1-macos/Sources/PS1/MetalDisplayView.swift` — modify: shared device/queue, own a `LiveRenderer`, bind both textures, conditional shadow upload.
- `ps1-macos/Tests/PS1Tests/DisplayRenderTests.swift` — modify: bind both textures; add the routing cases.

**Swift — lifecycle**

- `ps1-macos/Sources/PS1/ContentView.swift` — modify: `.id()` on the display view.
- `ps1-macos/Sources/PS1/EmulatorViewModel.swift` — modify: `reset()` raises resync.

**Docs**

- `CLAUDE.md` — modify (Task 9): the Metal backend paragraph now describes a live path.

---

### Task 1: `ps1-capi` builds `.dual` and arms the recorder

**Files:**
- Modify: `build.zig:225` and `build.zig:278`
- Modify: `ps1-capi/src/root.zig:37-41` (`buildMachine`)
- Test: `ps1-capi/src/capi_test.zig`

**Interfaces:**
- Consumes: `ps1.gpu.Sink.kind` (comptime, `.software` or `.dual`), `ps1.gpu.recorder.Recorder.arm()`.
- Produces: after `ps1_create` or `ps1_reset`, `h.cpu.bus.gpu.sink.rec.enabled == true`. Task 2 depends on this being armed.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-capi/src/capi_test.zig`:

```zig
test "the recorder is armed on create, so a stream exists without a setup call" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    try std.testing.expect(h.cpu.bus.gpu.sink.rec.enabled);
}

test "reset re-arms the recorder" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    // ps1_reset rebuilds Bus, which memsets the whole struct — including the
    // recorder's `enabled` flag. A reset that left it disarmed would produce a
    // permanently empty stream with nothing to say why.
    capi.ps1_reset(h);
    try std.testing.expect(h.cpu.bus.gpu.sink.rec.enabled);
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `zig build test -Dtest-filter="recorder is armed"`

Expected: FAIL. Two possible messages, both correct at this point — a compile error that `struct{}` (the zero-sized `Sink.Storage` in a `.software` build) has no field `enabled`, or, once the module is switched, an assertion failure because nothing calls `arm()`.

- [ ] **Step 3: Point both the shipped library and its tests at the recording core**

In `build.zig`, line 225, change:

```zig
    capi_test.root_module.addImport("ps1_core", core_mod);
```

to:

```zig
    // The RECORDING core, not the shared one: the shipped libps1core.a is
    // built .dual (below), and a test binary compiled against a configuration
    // no frontend links would leave ps1_take_frame_stream untested.
    capi_test.root_module.addImport("ps1_core", record_core_mod);
```

Also update the comment two lines above it, which currently claims the tests run against "the same core module the other frontends get".

In `build.zig`, line 278, change:

```zig
    capi_core_mod.addOptions("gpu_options", software_sink);
```

to:

```zig
    // .dual, per the parent spec's Decision 3: the macOS app needs BOTH the
    // software shadow (24bpp scanout, the resync, the divergence oracle) and
    // the recorded stream. Costs ~6.8 MB of Recorder inside Bus and a `push`
    // per GP0 effect, both accepted there.
    capi_core_mod.addOptions("gpu_options", recording_sink);
```

- [ ] **Step 4: Arm the recorder in `buildMachine`**

In `ps1-capi/src/root.zig`, replace `buildMachine`:

```zig
fn buildMachine(h: *Handle) void {
    h.cpu = Cpu.init(h.bus);
    // Armed HERE rather than in ps1_create: ps1_reset rebuilds Bus through
    // this same function, and Bus.init memsets the struct, so a reset would
    // otherwise leave the recorder disarmed and the stream permanently empty
    // with nothing to say why.
    if (comptime ps1.gpu.Sink.kind == .dual) h.bus.gpu.sink.rec.arm();
    if (h.bios_loaded) @memcpy(h.bus.bios[0..], h.bios[0..]);
    if (h.disc) |d| h.bus.cdrom.setDisc(d);
}
```

- [ ] **Step 5: Run the new tests**

Run: `zig build test -Dtest-filter="recorder"`
Expected: PASS.

- [ ] **Step 6: Run the whole suite and build the library**

Run: `zig build test && zig build capi-lib`
Expected: both succeed. `zig build test` runs fifteen binaries; the `capi_test` one now compiles against the recording core, so a `.software`-only assumption anywhere in `ps1-capi/src/root.zig` surfaces here.

- [ ] **Step 7: Commit**

```bash
zig fmt build.zig ps1-capi/src/root.zig ps1-capi/src/capi_test.zig
git add build.zig ps1-capi/src/root.zig ps1-capi/src/capi_test.zig
git commit -m "feat(capi): build the shipped library .dual and arm the recorder

The macOS app needs both halves: the software shadow serves 24bpp
scanout, the overflow resync and the divergence oracle, while the
recorded stream is what the Metal rasterizer consumes. Arming lives in
buildMachine because ps1_reset rebuilds Bus through it and would
otherwise leave the recorder disarmed.

capi_test moves to the recording core too, so the test binary matches
the library that actually ships.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `ps1_take_frame_stream` and the fourth contract rule

**Files:**
- Modify: `ps1-capi/include/ps1.h`
- Modify: `ps1-capi/src/root.zig`
- Test: `ps1-capi/src/capi_test.zig`

**Interfaces:**
- Consumes: Task 1's armed recorder; `ps1.gpu.recorder.Recorder.takeFrame()` returning `ps1.gpu.command.Stream { records: []const Command, payload: []const u32, complete: bool }`.
- Produces:
  - C: `void ps1_take_frame_stream(Ps1*, Ps1GpuStream* out);` and `typedef struct { const Ps1GpuCommand* records; size_t record_count; const uint32_t* payload; size_t payload_count; uint8_t complete; uint8_t _pad[7]; } Ps1GpuStream;`
  - C: `#define PS1_GPU_MAX_RECORDS 65536` and `#define PS1_GPU_MAX_PAYLOAD_WORDS 524288`.
  - Task 3 (`Ps1Core.takeFrameStream`) and Task 3's `StreamQueue` capacities read all four.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-capi/src/capi_test.zig`:

```zig
test "take_frame_stream hands out the frame's records and payload" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    // GP0(E1) — one `set_draw_env` record, no payload.
    _ = h.cpu.bus.gpu.writeGp0(0xE1000200);

    var s: capi.Ps1GpuStream = undefined;
    capi.ps1_take_frame_stream(h, &s);

    try std.testing.expectEqual(@as(usize, 1), s.record_count);
    try std.testing.expectEqual(@as(usize, 0), s.payload_count);
    try std.testing.expectEqual(@as(u8, 1), s.complete);
    try std.testing.expectEqual(
        ps1_core.gpu.command.Kind.set_draw_env,
        s.records.?[0].kind,
    );
    try std.testing.expectEqual(@as(u32, 0xE1000200), s.records.?[0].value);
}

test "take_frame_stream RESETS the recorder, so a second call in one frame is empty" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    _ = h.cpu.bus.gpu.writeGp0(0xE1000200);

    var first: capi.Ps1GpuStream = undefined;
    capi.ps1_take_frame_stream(h, &first);
    try std.testing.expectEqual(@as(usize, 1), first.record_count);

    // This is the whole reason the header says "once per frame": the call is a
    // DRAIN, not a peek. A caller that takes twice gets nothing the second
    // time; a caller that never takes accumulates until it overruns.
    var second: capi.Ps1GpuStream = undefined;
    capi.ps1_take_frame_stream(h, &second);
    try std.testing.expectEqual(@as(usize, 0), second.record_count);
    try std.testing.expectEqual(@as(u8, 1), second.complete);
}

test "a frame that overruns max_records reports complete == 0" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const cap = ps1_core.gpu.recorder.max_records;
    var i: usize = 0;
    while (i < cap + 10) : (i += 1) {
        _ = h.cpu.bus.gpu.writeGp0(0xE1000200);
    }

    var s: capi.Ps1GpuStream = undefined;
    capi.ps1_take_frame_stream(h, &s);

    // The records present are a PREFIX, not a shorter frame. Applying a prefix
    // to a shadow VRAM leaves it permanently out of step with the rasterizer,
    // which is why the flag exists at all.
    try std.testing.expectEqual(@as(usize, cap), s.record_count);
    try std.testing.expectEqual(@as(u8, 0), s.complete);
}
```

Add the core import at the top of `capi_test.zig`, next to the existing two lines:

```zig
const ps1_core = @import("ps1_core");
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `zig build test -Dtest-filter="take_frame_stream"`
Expected: FAIL — `root.zig` has no `Ps1GpuStream` and no `ps1_take_frame_stream`.

- [ ] **Step 3: Implement the Zig side**

Append to `ps1-capi/src/root.zig`, after `ps1_get_display`:

```zig
comptime {
    // These two are PS1_GPU_MAX_RECORDS and PS1_GPU_MAX_PAYLOAD_WORDS in
    // ps1.h, where the Swift side sizes its queue slots from them. A capacity
    // that drifts between the two silently truncates a frame, so pin it here
    // the same way command.zig pins the 72-byte stride.
    if (ps1.gpu.recorder.max_records != 65_536)
        @compileError("PS1_GPU_MAX_RECORDS in ps1.h is out of step with recorder.zig");
    if (ps1.gpu.recorder.max_payload_words != 524_288)
        @compileError("PS1_GPU_MAX_PAYLOAD_WORDS in ps1.h is out of step with recorder.zig");
}

/// Mirrors `Ps1GpuStream` in ps1.h. `extern struct` pins the C layout.
///
/// Both pointers are CORE-OWNED and alias the recorder's own storage: they are
/// valid only until the next `ps1_run_frame` on this handle.
pub const Ps1GpuStream = extern struct {
    records: ?[*]const ps1.gpu.command.Command,
    record_count: usize,
    payload: ?[*]const u32,
    payload_count: usize,
    /// 0 means the records are a PREFIX of the frame, not a shorter frame.
    complete: u8,
    _pad: [7]u8,
};

/// Drains one frame of recorded GP0 commands. See contract rule 4 in ps1.h.
///
/// This is a DRAIN: `takeFrame` resets the recorder's counters. Call it exactly
/// once per `ps1_run_frame`. Skipping it does not keep the frame — it stacks
/// the next one on top until the capacity overruns and `complete` goes to 0.
pub export fn ps1_take_frame_stream(h: *Handle, out: *Ps1GpuStream) void {
    if (comptime ps1.gpu.Sink.kind != .dual) {
        // A .software build records nothing. An empty COMPLETE stream is the
        // honest answer: there is no frame to discard, and reporting it
        // incomplete would trigger a resync every frame forever.
        out.* = .{
            .records = null,
            .record_count = 0,
            .payload = null,
            .payload_count = 0,
            .complete = 1,
            ._pad = .{0} ** 7,
        };
        return;
    }

    const s = h.cpu.bus.gpu.sink.rec.takeFrame();
    out.* = .{
        .records = s.records.ptr,
        .record_count = s.records.len,
        .payload = s.payload.ptr,
        .payload_count = s.payload.len,
        .complete = @intFromBool(s.complete),
        ._pad = .{0} ** 7,
    };
}
```

- [ ] **Step 4: Run the tests**

Run: `zig build test -Dtest-filter="take_frame_stream"`
Expected: PASS, all three.

If the overflow test reports `record_count == 1` instead of `65536`, `gp0.zig` is coalescing repeated identical E1 writes. Switch that test's loop body to a flat monochrome triangle instead, which cannot coalesce:

```zig
        _ = h.cpu.bus.gpu.writeGp0(0x20FFFFFF); // GP0(20) colour
        _ = h.cpu.bus.gpu.writeGp0(0x00000000); // v0
        _ = h.cpu.bus.gpu.writeGp0(0x00000010); // v1
        _ = h.cpu.bus.gpu.writeGp0(0x00100000); // v2
```

- [ ] **Step 5: Add the C declarations**

In `ps1-capi/include/ps1.h`, extend the header comment block. Change `CONTRACT RULES. These three` to `CONTRACT RULES. These four`, and add after rule 3:

```c
 * 4. ps1_take_frame_stream returns a CORE-OWNED buffer pair (records and
 *    payload). It is valid until the next ps1_run_frame on the same handle.
 *    The caller must not free it and must not retain it across a frame.
 */
```

Then, immediately after the three `_Static_assert` lines that follow `Ps1GpuCommand` (the last is the `PS1_GPU_VRAM_READ_SETUP + 1 == PS1_GPU_KIND_COUNT` one) and before the `ps1_run_frame` comment block, add:

```c
/* Recorder capacities, mirrored from ps1-core/src/gpu/recorder.zig. A comptime
   block in ps1-capi/src/root.zig fails the build if these drift. The Swift
   side sizes its queue slots from them. */
#define PS1_GPU_MAX_RECORDS       65536
#define PS1_GPU_MAX_PAYLOAD_WORDS 524288

/* One frame of recorded GP0 commands.
 *
 * ps1_take_frame_stream is a DRAIN, not a peek: it resets the recorder. Call it
 * exactly once per ps1_run_frame. Skipping it does not keep the frame — the
 * next one stacks on top until the capacity overruns.
 *
 * complete == 0 means the records are a PREFIX of the frame, NOT a shorter
 * frame. Applying a prefix leaves a shadow VRAM permanently out of step with
 * the rasterizer, so an incomplete stream must be DISCARDED and the renderer
 * resynced from the shadow — never replayed. */
typedef struct {
    const Ps1GpuCommand* records;
    size_t               record_count;
    const uint32_t*      payload;
    size_t               payload_count;
    uint8_t              complete;
    uint8_t              _pad[7];
} Ps1GpuStream;

void ps1_take_frame_stream(Ps1*, Ps1GpuStream* out);
```

- [ ] **Step 6: Verify the header compiles and the library still links**

Run: `zig build capi-lib && xcrun clang -fsyntax-only -x c ps1-capi/include/ps1.h`
Expected: both succeed.

- [ ] **Step 7: Commit**

```bash
zig fmt ps1-capi/src/root.zig ps1-capi/src/capi_test.zig
git add ps1-capi/
git commit -m "feat(capi): ps1_take_frame_stream and contract rule 4

Hands one frame of recorded GP0 commands out as a core-owned buffer
pair, valid until the next ps1_run_frame. Two facts go in the header as
prose because both are silent when got wrong: the call is a drain, so it
is once per frame; and complete == 0 means the records are a prefix, so
the stream must be discarded rather than replayed.

The two capacity macros are pinned against recorder.zig by a comptime
block, the same way command.zig pins the 72-byte stride.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: The stream queue in `EmulatorRunner`

**Files:**
- Create: `ps1-macos/Sources/PS1/StreamQueue.swift`
- Modify: `ps1-macos/Sources/PS1/Ps1Core.swift`
- Modify: `ps1-macos/Sources/PS1/EmulatorRunner.swift`
- Test: `ps1-macos/Tests/PS1Tests/StreamQueueTests.swift`

**Interfaces:**
- Consumes: Task 2's `Ps1GpuStream`, `ps1_take_frame_stream`, `PS1_GPU_MAX_RECORDS`, `PS1_GPU_MAX_PAYLOAD_WORDS`.
- Produces:
  - `final class StreamSlot` with `records: UnsafeMutableBufferPointer<Ps1GpuCommand>`, `payload: UnsafeMutableBufferPointer<UInt32>`, `recordCount: Int`, `payloadCount: Int`, `seq: UInt64`.
  - `final class StreamQueue: @unchecked Sendable` with `static let capacity = 4`, `publish(seq:records:recordCount:payload:payloadCount:complete:)`, `drain(_ body: (StreamSlot) -> Void)`, `discardAll()`, `needsResync: Bool`, `requestResync()`, `clearResync()`, `pendingCount: Int`.
  - `Ps1Core.takeFrameStream() -> Ps1GpuStream`.
  - `EmulatorRunner.streams: StreamQueue`, `EmulatorRunner.requestResync()`, and the widened `withNewestFrame(_ body: (UnsafePointer<UInt16>, Ps1Display, UInt64) -> Void)`.
- Task 5 (`LiveRenderer`) consumes all of the `StreamQueue` surface and the widened `withNewestFrame`.

- [ ] **Step 1: Write the failing tests**

Create `ps1-macos/Tests/PS1Tests/StreamQueueTests.swift`:

```swift
import Testing
import CPs1
@testable import PS1

/// Builds a stream of `n` distinguishable records. `value` carries the index so
/// a drain can assert ORDER, which is the queue's whole job.
private func publish(_ q: StreamQueue, seq: UInt64, records n: Int,
                     payload words: Int = 0, complete: Bool = true) {
    var recs = [Ps1GpuCommand](repeating: Ps1GpuCommand(), count: max(n, 1))
    for i in 0..<n { recs[i].value = UInt32(seq) }
    var pay = [UInt32](repeating: UInt32(seq), count: max(words, 1))
    recs.withUnsafeBufferPointer { r in
        pay.withUnsafeBufferPointer { p in
            q.publish(seq: seq, records: r.baseAddress!, recordCount: n,
                      payload: p.baseAddress!, payloadCount: words,
                      complete: complete)
        }
    }
}

@Test func aQueueStartsAskingForAResync() {
    // The GPU texture's contents are unrelated to the shadow until the first
    // frame lands, so the very first draw callback must adopt the shadow
    // rather than assume a blank match.
    #expect(StreamQueue().needsResync)
}

@Test func drainHandsBackEveryPublishedFrameInOrder() {
    let q = StreamQueue()
    q.clearResync()
    publish(q, seq: 1, records: 3)
    publish(q, seq: 2, records: 5)

    var seen: [(UInt64, Int)] = []
    q.drain { seen.append(($0.seq, $0.recordCount)) }

    #expect(seen.count == 2)
    #expect(seen[0] == (1, 3))
    #expect(seen[1] == (2, 5))
    #expect(q.pendingCount == 0)
}

@Test func drainCopiesRecordsAndPayloadRatherThanAliasingThem() {
    let q = StreamQueue()
    q.clearResync()
    publish(q, seq: 7, records: 2, payload: 4)

    var records: [UInt32] = []
    var payload: [UInt32] = []
    q.drain { slot in
        for i in 0..<slot.recordCount { records.append(slot.records[i].value) }
        for i in 0..<slot.payloadCount { payload.append(slot.payload[i]) }
    }

    // The core reuses its recorder storage the instant emulation resumes, so a
    // slot that aliased it would hand the renderer the NEXT frame's bytes.
    #expect(records == [7, 7])
    #expect(payload == [7, 7, 7, 7])
}

@Test func aFullRingRequestsAResyncAndEnqueuesNothingFurther() {
    let q = StreamQueue()
    q.clearResync()
    for i in 0..<StreamQueue.capacity { publish(q, seq: UInt64(i), records: 1) }
    #expect(!q.needsResync)
    #expect(q.pendingCount == StreamQueue.capacity)

    publish(q, seq: 99, records: 1)
    #expect(q.needsResync)
    #expect(q.pendingCount == StreamQueue.capacity)
}

@Test func anIncompleteStreamIsNeverEnqueued() {
    let q = StreamQueue()
    q.clearResync()
    publish(q, seq: 1, records: 3, complete: false)

    // A prefix applied to VRAM leaves it permanently out of step, so the frame
    // is dropped and the renderer resyncs from the shadow instead.
    #expect(q.needsResync)
    #expect(q.pendingCount == 0)
}

@Test func discardAllDropsTheBacklogWithoutExecutingIt() {
    let q = StreamQueue()
    q.clearResync()
    publish(q, seq: 1, records: 1)
    publish(q, seq: 2, records: 1)

    q.discardAll()

    var drained = 0
    q.drain { _ in drained += 1 }
    #expect(drained == 0)
    #expect(q.pendingCount == 0)
}

@Test func aFrameLargerThanASlotIsRefusedRatherThanTruncated() {
    let q = StreamQueue()
    q.clearResync()
    publish(q, seq: 1, records: Int(PS1_GPU_MAX_RECORDS) + 1)

    // The core cannot produce one — the recorder caps at the same number and
    // reports complete == 0 — but a truncated slot would be a silent prefix,
    // which is the exact failure the complete flag exists to prevent.
    #expect(q.needsResync)
    #expect(q.pendingCount == 0)
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `ps1-macos/test.sh 2>&1 | tail -40`
Expected: FAIL — the build errors with "cannot find 'StreamQueue' in scope".

- [ ] **Step 3: Write `StreamQueue.swift`**

Create `ps1-macos/Sources/PS1/StreamQueue.swift`:

```swift
import Foundation
import Synchronization
import CPs1

/// One frame's recorded GP0 stream, COPIED out of the core.
///
/// The copy is not defensive tidiness: `ps1_take_frame_stream` returns slices
/// into the recorder's own storage, valid only until the next `ps1_run_frame`
/// (contract rule 4). Aliasing them would hand the renderer whichever frame the
/// emulator happened to be building when it looked.
///
/// Sized at the recorder's own capacities so the producer never allocates and
/// never truncates. About 6.8 MB per slot.
final class StreamSlot {
    let records: UnsafeMutableBufferPointer<Ps1GpuCommand>
    let payload: UnsafeMutableBufferPointer<UInt32>
    var recordCount = 0
    var payloadCount = 0
    var seq: UInt64 = 0

    init() {
        records = .allocate(capacity: Int(PS1_GPU_MAX_RECORDS))
        records.initialize(repeating: Ps1GpuCommand())
        payload = .allocate(capacity: Int(PS1_GPU_MAX_PAYLOAD_WORDS))
        payload.initialize(repeating: 0)
    }

    deinit {
        records.deinitialize()
        records.deallocate()
        payload.deinitialize()
        payload.deallocate()
    }
}

/// Single-producer / single-consumer ring carrying frames from the emulator
/// thread to the render thread.
///
/// The producer's whole cost is one bounded memcpy: no allocation, no lock, no
/// wait. That is what keeps the emulator thread — which is audio-paced and runs
/// at .userInteractive QoS — off the renderer's clock entirely.
///
/// `head` and `tail` are monotonic counters rather than wrapped indices, so a
/// full ring is `tail - head == capacity` and no slot is wasted to distinguish
/// full from empty.
final class StreamQueue: @unchecked Sendable {
    /// Four frames is about 66 ms of slack at 60 Hz, and 27 MB of slots. Small
    /// beside Phase C's 67 MB render texture at N=8, and the price of never
    /// touching an allocator on the emulator thread.
    static let capacity = 4

    private let slots: [StreamSlot]
    private let head = Atomic<UInt64>(0)
    private let tail = Atomic<UInt64>(0)
    /// Starts TRUE: the GPU texture's contents bear no relation to the shadow
    /// until the first frame lands, so the first draw callback adopts the
    /// shadow rather than assuming a blank match.
    private let resync = Atomic<Bool>(true)

    init() {
        slots = (0..<Self.capacity).map { _ in StreamSlot() }
    }

    var pendingCount: Int {
        Int(tail.load(ordering: .acquiring) &- head.load(ordering: .acquiring))
    }

    var needsResync: Bool { resync.load(ordering: .acquiring) }
    func requestResync() { resync.store(true, ordering: .releasing) }
    func clearResync() { resync.store(false, ordering: .releasing) }

    // MARK: Producer — emulator thread only

    /// Copies one frame into the ring.
    ///
    /// Three conditions raise a resync instead of enqueuing, and all three have
    /// the same remedy — discard the backlog and adopt the shadow — so the
    /// policy lives here rather than being restated at each call site:
    /// an incomplete stream (a prefix), a frame too large for a slot, and a
    /// full ring (the renderer has fallen behind, or the window is
    /// backgrounded).
    func publish(seq: UInt64,
                 records: UnsafePointer<Ps1GpuCommand>, recordCount: Int,
                 payload: UnsafePointer<UInt32>?, payloadCount: Int,
                 complete: Bool) {
        guard complete,
              recordCount <= Int(PS1_GPU_MAX_RECORDS),
              payloadCount <= Int(PS1_GPU_MAX_PAYLOAD_WORDS)
        else { requestResync(); return }

        let t = tail.load(ordering: .relaxed)
        guard t &- head.load(ordering: .acquiring) < UInt64(Self.capacity) else {
            requestResync()
            return
        }

        let slot = slots[Int(t % UInt64(Self.capacity))]
        slot.records.baseAddress!.update(from: records, count: recordCount)
        if let payload, payloadCount > 0 {
            slot.payload.baseAddress!.update(from: payload, count: payloadCount)
        }
        slot.recordCount = recordCount
        slot.payloadCount = payloadCount
        slot.seq = seq

        // Releasing: everything written above must be visible to the consumer
        // before it can observe the new tail.
        tail.store(t &+ 1, ordering: .releasing)
    }

    // MARK: Consumer — render thread only

    /// Hands every queued slot to `body`, oldest first.
    ///
    /// Drain-ALL, not take-newest: a command stream is a set of incremental
    /// mutations, so a skipped frame is lost permanently. Only PRESENTATION is
    /// allowed to skip.
    func drain(_ body: (StreamSlot) -> Void) {
        var h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        while h < t {
            body(slots[Int(h % UInt64(Self.capacity))])
            h &+= 1
            head.store(h, ordering: .releasing)
        }
    }

    /// Drops the whole backlog without executing it. Only ever correct as half
    /// of a resync, where the shadow replaces what the dropped frames would
    /// have produced.
    func discardAll() {
        head.store(tail.load(ordering: .acquiring), ordering: .releasing)
    }
}
```

- [ ] **Step 4: Run the queue tests**

Run: `ps1-macos/test.sh 2>&1 | grep -i "streamqueue\|Test run"`
Expected: all seven pass.

- [ ] **Step 5: Commit the queue**

```bash
git add ps1-macos/Sources/PS1/StreamQueue.swift ps1-macos/Tests/PS1Tests/StreamQueueTests.swift
git commit -m "feat(macos): the SPSC stream queue

Carries recorded GP0 frames from the emulator thread to the render
thread. The producer's whole cost is one bounded memcpy into a
preallocated slot, because the core's buffers are valid only until the
next ps1_run_frame and the emulator thread must not allocate.

Three conditions raise a resync rather than enqueuing -- an incomplete
stream, an oversized frame, a full ring -- because all three have the
same remedy: discard the backlog and adopt the shadow.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

- [ ] **Step 6: Add `takeFrameStream` to `Ps1Core`**

In `ps1-macos/Sources/PS1/Ps1Core.swift`, after `copyVRAM`:

```swift
    /// One frame of recorded GP0 commands.
    ///
    /// The returned pointers are CORE-OWNED and alias the recorder's storage
    /// (ps1.h contract rule 4): valid only until the next `runFrame()`. Copy
    /// what you need before stepping the machine again.
    ///
    /// This is a DRAIN — it resets the recorder — so it must be called exactly
    /// once per `runFrame()`. Skipping it stacks the next frame on top until
    /// the capacity overruns.
    func takeFrameStream() -> Ps1GpuStream {
        var s = Ps1GpuStream()
        ps1_take_frame_stream(handle, &s)
        return s
    }
```

and add the re-export next to the existing `Ps1Display` typealias at the top:

```swift
typealias Ps1GpuStream = CPs1.Ps1GpuStream
```

- [ ] **Step 7: Wire the queue into `EmulatorRunner`**

In `ps1-macos/Sources/PS1/EmulatorRunner.swift`:

Add to the stored properties, next to `displays`:

```swift
    /// The GP0 command stream, frame by frame. Published AFTER the VRAM slot
    /// for the same frame — see `runLoop`.
    let streams = StreamQueue()
    private var seqs = [UInt64](repeating: 0, count: 3)
    private var frameSeq: UInt64 = 0
```

Add, next to `setButtons`:

```swift
    /// Raised on a front-panel reset: `ps1_reset` rebuilds Bus and clears
    /// software VRAM, while the GPU texture still holds the old picture.
    func requestResync() { streams.requestResync() }
```

Widen `withNewestFrame` to carry the sequence number:

```swift
    /// Renderer side. Hands the newest complete frame to `body`, with the
    /// sequence number it was produced under.
    ///
    /// The seq is what lets the divergence oracle compare like with like: it
    /// diffs only when the newest shadow is the very frame whose stream was
    /// last executed, rather than one the emulator has since run past.
    func withNewestFrame(_ body: (UnsafePointer<UInt16>, Ps1Display, UInt64) -> Void) {
        let i = newest.load(ordering: .acquiring)
        displayLock.lock()
        let d = displays[i]
        let s = seqs[i]
        displayLock.unlock()
        body(UnsafePointer(slots[i]), d, s)
    }
```

Replace the publication block at the end of `runLoop`:

```swift
            // VRAM FIRST, then the stream, both under the same seq.
            //
            // That order is load-bearing: it means a stream visible to the
            // consumer ALWAYS has its shadow already published, which is what
            // makes "discard the backlog and adopt the newest shadow" a
            // complete resync needing no per-slot reconciliation.
            frameSeq &+= 1
            let next = (newest.load(ordering: .relaxed) + 1) % 3
            core.copyVRAM(into: slots[next])
            let d = core.display()
            displayLock.lock()
            displays[next] = d
            seqs[next] = frameSeq
            displayLock.unlock()
            newest.store(next, ordering: .releasing)

            // Once per runFrame, unconditionally: this is a drain, and a frame
            // left untaken stacks onto the next until the recorder overruns.
            let s = core.takeFrameStream()
            streams.publish(seq: frameSeq,
                            records: s.records, recordCount: s.record_count,
                            payload: s.payload, payloadCount: s.payload_count,
                            complete: s.complete != 0)
```

Note `s.records` is `UnsafePointer<Ps1GpuCommand>?`; `publish` takes a non-optional, so unwrap:

```swift
            if let recs = s.records {
                streams.publish(seq: frameSeq,
                                records: recs, recordCount: s.record_count,
                                payload: s.payload, payloadCount: s.payload_count,
                                complete: s.complete != 0)
            } else {
                streams.requestResync()
            }
```

- [ ] **Step 8: Fix the one existing `withNewestFrame` call site**

`MetalDisplayView.swift:115` closes over two parameters. Change it to three (the third unused for now — Task 8 uses it):

```swift
            runner.withNewestFrame { vram, display, _ in
```

- [ ] **Step 9: Run the whole Swift suite**

Run: `ps1-macos/test.sh 2>&1 | tail -30`
Expected: PASS, including the 167 pre-existing tests. Nothing visible changes yet — the queue fills and nobody drains it, which is exactly the state the ring's resync path is designed to survive.

- [ ] **Step 10: Commit**

```bash
git add ps1-macos/Sources/PS1/
git commit -m "feat(macos): publish the frame stream alongside the VRAM shadow

EmulatorRunner now drains the recorder once per frame and copies the
result into the ring. VRAM is published before the stream and both carry
the same seq, which is what makes discarding the backlog and adopting
the newest shadow a complete resync with no per-slot reconciliation.

withNewestFrame widens to hand back that seq; Task 8's divergence
oracle uses it to compare like with like.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: `MetalRasterizer` fit for a real-time thread

**Files:**
- Modify: `ps1-macos/Sources/PS1/MetalRasterizer.swift:14, 52-63, 113-198`
- Test: the existing `MetalRasterizerTests.swift`, `MetalMoverTests.swift`, `MetalScaleTests.swift` (unchanged, re-run)

**Interfaces:**
- Consumes: `PS1_GPU_MAX_PAYLOAD_WORDS`.
- Produces: `MetalRasterizer.synchronous: Bool` (default `true`). Task 5 sets it `false`.

- [ ] **Step 1: Add the `synchronous` flag**

In `MetalRasterizer.swift`, next to `ditherDisabled`:

```swift
    /// Whether `endFrame` blocks until the GPU has finished.
    ///
    /// True for every fixture gate, which reads VRAM back the instant
    /// `endFrame` returns. False on the live path, where blocking the draw
    /// callback on the GPU would cost a frame for nothing: `LiveRenderer`
    /// shares one command queue with the display pass, so commit order already
    /// orders the rasterizer's writes before the display's sampling.
    var synchronous = true
```

In `endFrame`, replace the final `cmd.waitUntilCompleted()`:

```swift
        cmd.commit()
        if synchronous { cmd.waitUntilCompleted() }
```

- [ ] **Step 2: Replace the per-frame payload buffer with a persistent one**

The class comment currently says "Allocation on this path is fine: Phase B is fixture-driven and never runs on the emulator thread. Phase D owns the no-allocation requirement." Replace that paragraph with:

```swift
/// Allocation is not on the emulator thread — that one hands over a copied
/// stream and returns — but it is on the render thread once per frame, so the
/// instance and payload buffers are persistent and reused rather than rebuilt.
```

Add a stored property and allocate it in `init`, after `self.scratch = scratch`:

```swift
    /// Sized once at the recorder's own cap (2 MB) and reused. A per-frame
    /// buffer here is up to 2 MB of allocation at 60 Hz for nothing.
    private let payloadBuffer: MTLBuffer
```

```swift
        guard let payloadBuffer = device.makeBuffer(
            length: Int(PS1_GPU_MAX_PAYLOAD_WORDS) * 4,
            options: .storageModeShared) else {
            throw Error.missingFunction("payload buffer")
        }
        self.payloadBuffer = payloadBuffer
```

Replace `beginFrame`:

```swift
    func beginFrame(payload: UnsafeBufferPointer<UInt32>) {
        hazards.reset()
        instances.removeAll(keepingCapacity: true)
        steps.removeAll(keepingCapacity: true)
        payloadCount = payload.count
        if let base = payload.baseAddress, payload.count > 0 {
            precondition(payload.count <= Int(PS1_GPU_MAX_PAYLOAD_WORDS))
            payloadBuffer.contents().copyMemory(
                from: base, byteCount: payload.count * 4)
        }
    }
```

Delete the `private var payloadBuffer: MTLBuffer?` declaration this replaces, and in `endFrame` change the optional bind:

```swift
            e.setFragmentBuffer(payloadBuffer, offset: 0, index: 1)
```

- [ ] **Step 3: Replace the per-frame instance buffer with a growing one**

Add a stored property:

```swift
    /// Grows by doubling and then stays. Instance count is NOT bounded by
    /// record count — `LineExpander` turns one line record into one instance
    /// per pixel — so this cannot be sized from the recorder's cap.
    private var instanceBuffer: MTLBuffer
    private var instanceCapacity: Int
```

In `init`, after the payload buffer:

```swift
        // 65,536 instances is 11 MB at 168 bytes each, and covers every frame
        // in the fixture corpus with room to spare.
        let initialInstances = 65_536
        guard let instanceBuffer = device.makeBuffer(
            length: initialInstances * MemoryLayout<Ps1PrimInstance>.stride,
            options: .storageModeShared) else {
            throw Error.missingFunction("instance buffer")
        }
        self.instanceBuffer = instanceBuffer
        self.instanceCapacity = initialInstances
```

In `endFrame`, replace the buffer construction:

```swift
        if instances.count > instanceCapacity {
            var cap = instanceCapacity
            while cap < instances.count { cap *= 2 }
            guard let grown = device.makeBuffer(
                length: cap * MemoryLayout<Ps1PrimInstance>.stride,
                options: .storageModeShared) else { return }
            instanceBuffer = grown
            instanceCapacity = cap
        }
        instances.withUnsafeBytes { src in
            instanceBuffer.contents().copyMemory(
                from: src.baseAddress!, byteCount: src.count)
        }
```

and replace the two uses of the old local `instanceBuffer` inside `openPass()` — they already name it `instanceBuffer`, so no edit is needed there beyond deleting the `let instanceBuffer = device.makeBuffer(...)` line.

- [ ] **Step 4: Run every Phase B and C gate**

Run: `ps1-macos/test.sh 2>&1 | tail -30`
Expected: PASS, with the same counts as before this task. This is the check: none of these tests knows anything changed, and all eleven fixtures still hash identically at every N. A moved hash here is a bug in the buffer rework, not a baseline.

- [ ] **Step 5: Commit**

```bash
git add ps1-macos/Sources/PS1/MetalRasterizer.swift
git commit -m "perf(macos): persistent instance and payload buffers, optional wait

Phase B allocated both per frame and said so in the class comment,
because it was fixture-driven. On a 60 Hz path that is up to 2 MB of
payload plus a draw-count-sized instance buffer every frame.

endFrame's waitUntilCompleted becomes optional for the same reason: the
live path shares one command queue with the display pass, so commit
order already orders the writes before the sampling. Every fixture gate
keeps the blocking behaviour and hashes identically.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: `LiveRenderer` — drain, resync, present

**Files:**
- Create: `ps1-macos/Sources/PS1/LiveRenderer.swift`
- Test: `ps1-macos/Tests/PS1Tests/LiveRendererTests.swift`

**Interfaces:**
- Consumes: `StreamQueue`, `StreamSlot`, `MetalVram`, `MetalRasterizer`, `MetalVram.uploadNative(_:)`.
- Produces:
  - `final class LiveRenderer` with `init(device:queue:scale:) throws`, `var texture: MTLTexture`, `func drain(from: StreamQueue, shadow: () -> [UInt16])`, `private(set) var lastExecutedSeq: UInt64`.
- Task 6 binds `texture`; Task 8 extends `drain`.

- [ ] **Step 1: Write the failing tests**

Create `ps1-macos/Tests/PS1Tests/LiveRendererTests.swift`:

```swift
import Testing
import Metal
import CPs1
@testable import PS1

private func makeLive() throws -> (MTLDevice, MTLCommandQueue, LiveRenderer)? {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { return nil }
    return (device, queue, try LiveRenderer(device: device, queue: queue))
}

/// A fill of the whole 16x16 box at (x, y) with `color`. One record, no
/// payload — the smallest stream that provably changes VRAM.
private func fillStream(_ q: StreamQueue, seq: UInt64,
                        x: Int32, y: Int32, color: UInt32) {
    var cmd = Ps1GpuCommand()
    cmd.kind = UInt8(PS1_GPU_FILL_RECT.rawValue)
    cmd.x = x
    cmd.y = y
    cmd.w = 16
    cmd.h = 16
    cmd.value = color
    withUnsafePointer(to: &cmd) { p in
        q.publish(seq: seq, records: p, recordCount: 1,
                  payload: nil, payloadCount: 0, complete: true)
    }
}

@Test func drainExecutesEveryQueuedFrameInOrder() throws {
    guard let (_, _, live) = try makeLive() else { return }
    let q = StreamQueue()
    q.clearResync()

    // Two fills at the SAME place with different colours: only the later one
    // survives, so the final pixel proves the ORDER, not merely that both ran.
    fillStream(q, seq: 1, x: 0, y: 0, color: 0x001F)
    fillStream(q, seq: 2, x: 0, y: 0, color: 0x7C00)

    live.drain(from: q) { [] }

    let back = live.vram.readbackNative()
    #expect(back[0] == 0x7C00)
    #expect(live.lastExecutedSeq == 2)
}

@Test func drainSkippedFramesAreExecutedNotDropped() throws {
    guard let (_, _, live) = try makeLive() else { return }
    let q = StreamQueue()
    q.clearResync()

    // Distinct places: if drain took only the newest, the first fill's pixels
    // would never appear. A command stream is incremental, so execution may
    // never skip -- only presentation may.
    fillStream(q, seq: 1, x: 0, y: 0, color: 0x001F)
    fillStream(q, seq: 2, x: 64, y: 0, color: 0x7C00)

    live.drain(from: q) { [] }

    let back = live.vram.readbackNative()
    #expect(back[0] == 0x001F)
    #expect(back[64] == 0x7C00)
}

@Test func aResyncRequestDiscardsTheBacklogAndAdoptsTheShadow() throws {
    guard let (_, _, live) = try makeLive() else { return }
    let q = StreamQueue()
    q.clearResync()

    fillStream(q, seq: 1, x: 0, y: 0, color: 0x001F)
    q.requestResync()

    var shadow = [UInt16](repeating: 0, count: 1024 * 512)
    shadow[0] = 0x03E0
    shadow[1024 * 512 - 1] = 0x7FFF

    live.drain(from: q) { shadow }

    let back = live.vram.readbackNative()
    // The queued fill must NOT have run: the shadow already accounts for it.
    #expect(back[0] == 0x03E0)
    #expect(back[1024 * 512 - 1] == 0x7FFF)
    #expect(q.pendingCount == 0)
    #expect(!q.needsResync)
}

@Test func theShadowClosureIsNotCalledOnTheOrdinaryPath() throws {
    guard let (_, _, live) = try makeLive() else { return }
    let q = StreamQueue()
    q.clearResync()
    fillStream(q, seq: 1, x: 0, y: 0, color: 0x001F)

    // Building the shadow array is a 1 MB copy. It belongs behind a closure so
    // the common path never pays for it.
    var called = false
    live.drain(from: q) { called = true; return [UInt16](repeating: 0, count: 1024 * 512) }
    #expect(!called)
}
```

- [ ] **Step 2: Run and verify failure**

Run: `ps1-macos/test.sh 2>&1 | tail -30`
Expected: FAIL — "cannot find 'LiveRenderer' in scope".

- [ ] **Step 3: Write `LiveRenderer.swift`**

Create `ps1-macos/Sources/PS1/LiveRenderer.swift`:

```swift
import Foundation
import Metal

/// The live command-stream renderer: drains the queue into the GPU's VRAM.
///
/// This is deliberately NOT the MTKView coordinator. A coordinator is not
/// reachable without a view, and the letterbox bug of 2026-08-20 is the
/// standing reminder of what that costs: it survived every compile-and-pipeline
/// test because only the pixels were ever wrong. The policy lives here so it is
/// testable offscreen; the coordinator keeps only MTKView plumbing.
final class LiveRenderer {
    let vram: MetalVram
    private let rasterizer: MetalRasterizer

    /// The seq of the most recently executed stream. Task 8's divergence
    /// oracle compares against the shadow only when this matches the newest
    /// published frame, so it never diffs two different instants.
    private(set) var lastExecutedSeq: UInt64 = 0

    var texture: MTLTexture { vram.texture }

    init(device: MTLDevice, queue: MTLCommandQueue, scale: Int = 1) throws {
        guard let vram = MetalVram(device: device, queue: queue, scale: scale) else {
            throw MetalRasterizer.Error.missingFunction("MetalVram")
        }
        self.vram = vram
        self.rasterizer = try MetalRasterizer(vram: vram)
        // The display pass shares this queue, so commit order orders the
        // rasterizer's writes before its sampling. Blocking the draw callback
        // on the GPU would cost a frame for nothing.
        self.rasterizer.synchronous = false
    }

    /// Executes everything queued, in order, then returns.
    ///
    /// `shadow` is a closure rather than a value because building it is a 1 MB
    /// copy and the ordinary path never needs it.
    func drain(from queue: StreamQueue, shadow: () -> [UInt16]) {
        if queue.needsResync {
            // Discard BEFORE uploading: the shadow already accounts for every
            // frame in the backlog, so replaying any of them would apply the
            // same mutations twice.
            queue.discardAll()
            vram.uploadNative(shadow())
            queue.clearResync()
            return
        }
        queue.drain { slot in self.execute(slot) }
    }

    private func execute(_ slot: StreamSlot) {
        rasterizer.beginFrame(payload: UnsafeBufferPointer(
            start: slot.payload.baseAddress, count: slot.payloadCount))
        for i in 0..<slot.recordCount { rasterizer.apply(slot.records[i]) }
        rasterizer.endFrame()
        lastExecutedSeq = slot.seq
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `ps1-macos/test.sh 2>&1 | tail -30`
Expected: all four `LiveRenderer` tests pass, and the rest of the suite is unchanged.

If `drainExecutesEveryQueuedFrameInOrder` reports a stale pixel, `synchronous = false` is racing the readback — that is the test's own problem, not the renderer's, because `MetalVram.readbackNative` commits a blit on the same queue and waits for it, which orders after the rasterizer's commits. If it does race, the bug is that `MetalVram` was handed a different queue; check both come from the same `makeCommandQueue()`.

- [ ] **Step 5: Commit**

```bash
git add ps1-macos/Sources/PS1/LiveRenderer.swift ps1-macos/Tests/PS1Tests/LiveRendererTests.swift
git commit -m "feat(macos): LiveRenderer -- drain-all, resync from the shadow

Owns the MetalVram, the MetalRasterizer and the resync decision, and is
separate from the MTKView coordinator so the policy is testable
offscreen. Execution never skips a frame -- a command stream is a set of
incremental mutations -- while a resync discards the backlog first,
because the shadow already accounts for it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: The display shader routes by depth

**Files:**
- Modify: `ps1-macos/Shaders/DisplayShader.metal`
- Modify: `ps1-macos/Sources/PS1/MetalDisplayView.swift`
- Test: `ps1-macos/Tests/PS1Tests/DisplayRenderTests.swift`

**Interfaces:**
- Consumes: `LiveRenderer.texture`, `EmulatorRunner.streams`, the widened `withNewestFrame`.
- Produces: `DisplayParams.softwareDisplay: UInt32` (a new trailing field), and the `[[texture(1)]]` shadow binding. Both textures must be bound on every draw — an unbound `texture2d` is a Metal validation failure, not a black pixel.

- [ ] **Step 1: Write the failing tests**

`DisplayRenderTests.swift`'s `render(width:height:)` builds one VRAM texture and binds it at index 0. Generalise it: give it two textures with *different* contents, so a test can tell which one the shader read.

Replace the texture-creation block in `render` with a helper and add a parameter:

```swift
private func makeVramTexture(_ device: MTLDevice, fill: UInt16) -> MTLTexture? {
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .r16Uint, width: 1024, height: 512, mipmapped: false)
    desc.usage = .shaderRead
    desc.storageMode = .managed
    guard let tex = device.makeTexture(descriptor: desc) else { return nil }
    var pixels = [UInt16](repeating: fill, count: 1024 * 512)
    pixels.withUnsafeBytes { buf in
        tex.replace(region: MTLRegionMake2D(0, 0, 1024, 512), mipmapLevel: 0,
                    withBytes: buf.baseAddress!, bytesPerRow: 1024 * 2)
    }
    return tex
}
```

Change `render`'s signature to:

```swift
private func render(width: Int, height: Int,
                    depth24: Bool = false,
                    softwareDisplay: Bool = false) throws -> Rendered? {
```

Replace the inline `vramDesc`/`vram`/`pixels` block with two calls — the render texture keeps today's opaque white so every existing letterbox assertion is unchanged, and the shadow is pure red so a test can tell which one the shader read:

```swift
    guard let vram = makeVramTexture(device, fill: 0x7FFF),
          let shadow = makeVramTexture(device, fill: 0x001F) else { return nil }
```

Add to the `params` block:

```swift
    params.depth24 = depth24 ? 1 : 0
    params.softwareDisplay = softwareDisplay ? 1 : 0
```

And bind both textures where it currently binds one:

```swift
    enc.setFragmentTexture(vram, index: 0)
    enc.setFragmentTexture(shadow, index: 1)
```

Then append these tests:

```swift
@Test func fifteenBppScansOutOfTheRenderTextureNotTheShadow() throws {
    guard let r = try render(width: 320, height: 240) else { return }
    // The render texture is opaque white, the shadow pure red. Anything but
    // white here means the 15bpp branch is reading the wrong texture.
    let (b, g, rr) = r.pixel(160, 120)
    #expect(b > 240 && g > 240 && rr > 240)
}

@Test func twentyFourBppScansOutOfTheShadowPermanently() throws {
    guard let r = try render(width: 320, height: 240, depth24: true) else { return }
    // 24bpp reconstructs pixels by byte-packing across ADJACENT 16-bit words,
    // arithmetic that N x N replication in the scaled texture destroys. FMV is
    // uploaded through A0 and was never upscaled geometry, so it stays on the
    // shadow forever. Croc and Silent Hill both depend on this.
    //
    // The shadow is 0x001F in every word, so the packed bytes are 1F 00 1F 00:
    // r = 0x1F, g = 0x00, b = 0x1F.
    let (b, g, rr) = r.pixel(160, 120)
    #expect(rr == 0x1F)
    #expect(g == 0x00)
    #expect(b == 0x1F)
}

@Test func theSoftwareDisplaySwitchRoutesFifteenBppToTheShadow() throws {
    guard let r = try render(width: 320, height: 240, softwareDisplay: true) else { return }
    // PS1_SOFTWARE_DISPLAY=1: the debug seam for A/B-ing a suspect frame
    // against the software rasterizer without a rebuild. Not a mode, and not
    // a user-facing setting -- D2 owns any of those.
    //
    // The shadow is 0x001F: red 5 bits set, green and blue clear.
    let (b, g, rr) = r.pixel(160, 120)
    #expect(rr > 240)
    #expect(g < 16)
    #expect(b < 16)
}
```

- [ ] **Step 2: Run and verify failure**

Run: `ps1-macos/test.sh 2>&1 | tail -30`
Expected: FAIL — `DisplayParams` has no `softwareDisplay`, and the shader takes one texture.

- [ ] **Step 3: Change the shader**

In `ps1-macos/Shaders/DisplayShader.metal`, extend `Params`:

```metal
struct Params {
    uint  vram_x;
    uint  vram_y;
    uint  width;
    uint  height;
    uint  depth24;
    uint  enabled;
    float scale_x;   // letterboxing: 1.0 on the axis that fills
    float scale_y;
    uint  software_display; // debug seam: read the 1x shadow at 15bpp too
};
```

Change the fragment signature and the two reads:

```metal
fragment float4 display_fragment(VertexOut in [[stage_in]],
                                 texture2d<uint, access::read> vram [[texture(0)]],
                                 texture2d<uint, access::read> shadow [[texture(1)]],
                                 constant Params& p [[buffer(0)]]) {
```

In the 24bpp branch, replace both `vram.read(...)` with `shadow.read(...)`, and add the reason above them:

```metal
    if (p.depth24 != 0) {
        // 24bpp: three bytes per pixel packed across ADJACENT 16-bit VRAM
        // words. That arithmetic is meaningless once uploads are replicated
        // N x N in the scaled texture, and 24bpp content is FMV -- MDEC output
        // uploaded through A0, never upscaled geometry -- so it scans out of
        // the 1x shadow permanently. Croc and Silent Hill both depend on this.
        uint byte_off = px * 3;
        uint w0 = shadow.read(uint2((p.vram_x + (byte_off >> 1)) & 1023, row)).r;
        uint w1 = shadow.read(uint2((p.vram_x + (byte_off >> 1) + 1) & 1023, row)).r;
```

And the 15bpp read:

```metal
    // ABGR1555: bits 0-4 red, 5-9 green, 10-14 blue, bit 15 mask/STP.
    uint2 at = uint2((p.vram_x + px) & 1023, row);
    uint texel = p.software_display != 0 ? shadow.read(at).r : vram.read(at).r;
```

- [ ] **Step 4: Mirror the field in Swift**

In `MetalDisplayView.swift`, add the trailing field to `DisplayParams` (order and types must match the MSL struct exactly):

```swift
    var softwareDisplay: UInt32 = 0
```

- [ ] **Step 5: Wire the coordinator**

Replace `MetalDisplayView.Coordinator`'s `init` and `draw(in:)`. The device and queue are now shared with the `LiveRenderer`; the shadow texture keeps its `.managed` descriptor; the render texture comes from the `LiveRenderer`.

Add to the stored properties:

```swift
        private let live: LiveRenderer
        /// PS1_SOFTWARE_DISPLAY=1 routes 15bpp back to the shadow, so a
        /// suspect frame can be A/B'd against the software rasterizer without
        /// a rebuild. An environment variable is fine HERE — the standing
        /// warning in CLAUDE.md is about the hosted TEST process, which sees
        /// neither an exported variable nor xcodebuild's TEST_RUNNER_ prefix.
        private let softwareDisplay =
            ProcessInfo.processInfo.environment["PS1_SOFTWARE_DISPLAY"] == "1"
```

In `init`, after the pipeline is built and before `self.device = device`:

```swift
            let live: LiveRenderer
            do {
                live = try LiveRenderer(device: device, queue: queue)
            } catch {
                fatalError("Live renderer failed to build: \(error)")
            }
            self.live = live
```

Rename the existing `texture` property to `shadowTexture` (three sites: the declaration, the `init` assignment, and `draw`).

Replace `draw(in:)`:

```swift
        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let pass = view.currentRenderPassDescriptor,
                  let cmd = queue.makeCommandBuffer() else { return }

            var params = DisplayParams()
            params.softwareDisplay = softwareDisplay ? 1 : 0

            // Drain-all, present-newest. Every queued stream is EXECUTED, in
            // order; only the presentation is allowed to skip, which is what
            // keeps 59.94-against-60 and 120 Hz ProMotion as invisible as they
            // are on the shadow path.
            live.drain(from: runner.streams) {
                var out = [UInt16](repeating: 0, count: EmulatorRunner.vramCount)
                self.runner.withNewestFrame { vram, _, _ in
                    out.withUnsafeMutableBufferPointer { dst in
                        dst.baseAddress!.update(from: vram, count: EmulatorRunner.vramCount)
                    }
                }
                return out
            }

            runner.withNewestFrame { vram, display, _ in
                params.vramX = display.vram_x
                params.vramY = display.vram_y
                params.width = display.width
                params.height = display.height
                params.depth24 = UInt32(display.depth24)
                params.enabled = UInt32(display.enabled)
                // Only the two paths that READ it pay the 1 MB upload.
                if display.depth24 != 0 || self.softwareDisplay {
                    self.shadowTexture.replace(
                        region: MTLRegionMake2D(0, 0, 1024, 512),
                        mipmapLevel: 0,
                        withBytes: vram,
                        bytesPerRow: 1024 * MemoryLayout<UInt16>.size)
                }
            }

            let size = view.drawableSize
            (params.scaleX, params.scaleY) = letterboxScale(
                width: size.width, height: size.height)

            guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
            enc.setRenderPipelineState(pipeline)
            // BOTH bindings, always: an unbound texture2d is a Metal
            // validation failure, not a black pixel.
            enc.setFragmentTexture(live.texture, index: 0)
            enc.setFragmentTexture(shadowTexture, index: 1)
            enc.setVertexBytes(&params, length: MemoryLayout<DisplayParams>.stride, index: 0)
            enc.setFragmentBytes(&params, length: MemoryLayout<DisplayParams>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()

            cmd.present(drawable)
            cmd.commit()
        }
```

- [ ] **Step 6: Run the display tests**

Run: `ps1-macos/test.sh 2>&1 | tail -40`
Expected: PASS, including the three new routing tests and every pre-existing letterbox test.

- [ ] **Step 7: Build the app**

Run: `zig build capi-lib && zig build metallib && zig build macos`
Expected: `zig-out/PS1.app` builds. A shader syntax error fails here rather than at the first frame — that is what the offline compile buys.

- [ ] **Step 8: Commit**

```bash
git add ps1-macos/Shaders/DisplayShader.metal ps1-macos/Sources/PS1/MetalDisplayView.swift ps1-macos/Tests/PS1Tests/DisplayRenderTests.swift
git commit -m "feat(macos): scan out of the Metal render texture

15bpp reads the hardware-rasterized texture; 24bpp reads the 1x shadow
permanently, because it byte-packs across adjacent 16-bit words and that
arithmetic cannot survive N x N replication. Croc and Silent Hill both
depend on the shadow route.

The coordinator now owns a LiveRenderer and drains the queue before
presenting -- every stream executed, only the presentation skipped. The
shadow upload becomes conditional on the two paths that read it.

PS1_SOFTWARE_DISPLAY=1 routes 15bpp back to the shadow: the debug seam
the D1 spec asserts, so a suspect frame can be A/B'd without a rebuild.
Not a mode and not a user-facing setting.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Lifecycle — disc change, reset, eject

**Files:**
- Modify: `ps1-macos/Sources/PS1/ContentView.swift:13`
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift:208`
- Test: `ps1-macos/Tests/PS1Tests/StreamQueueTests.swift`

**Interfaces:**
- Consumes: `EmulatorRunner.requestResync()` from Task 3.
- Produces: nothing new; this closes three correctness holes.

- [ ] **Step 1: Write the failing test**

Append to `StreamQueueTests.swift`:

```swift
@Test func requestResyncSurvivesAnEmptyQueue() {
    let q = StreamQueue()
    q.clearResync()
    #expect(!q.needsResync)

    // A front-panel reset rebuilds Bus and clears software VRAM while the GPU
    // texture still holds the old picture. Nothing is queued at that instant,
    // so the flag is the only thing carrying the news.
    q.requestResync()
    #expect(q.needsResync)
    #expect(q.pendingCount == 0)
}
```

- [ ] **Step 2: Run and verify it passes already**

Run: `ps1-macos/test.sh 2>&1 | grep -i "requestResyncSurvives"`
Expected: PASS. This one documents an invariant Task 3 already provides; it is here because Step 4 depends on it and a reader should not have to infer it.

- [ ] **Step 3: Rebuild the coordinator when the runner changes**

In `ContentView.swift`, change:

```swift
                    MetalDisplayView(runner: runner)
                        .ignoresSafeArea()
```

to:

```swift
                    MetalDisplayView(runner: runner)
                        // A new disc is a new runner and a new queue, but
                        // SwiftUI may keep this view's identity across the
                        // swap and leave the coordinator holding the PREVIOUS
                        // runner. Harmless when it only read frames; wrong now
                        // that it drains a stream. Rebuilding also gives the
                        // new machine a blank render texture.
                        .id(ObjectIdentifier(runner))
                        .ignoresSafeArea()
```

- [ ] **Step 4: Raise a resync on reset**

In `EmulatorViewModel.swift`, change:

```swift
    public func reset() { runner?.isPaused = false; core?.reset() }
```

to:

```swift
    public func reset() {
        runner?.isPaused = false
        core?.reset()
        // ps1_reset rebuilds Bus, clearing software VRAM, while the GPU
        // texture still holds the old picture. Nothing is queued at this
        // instant, so the flag is the only thing that carries the news.
        //
        // NOTE: core.reset() is called from the main actor while the emulator
        // thread may be mid-frame. That race predates this phase and is not
        // widened here; routing the reset itself through the runner is where
        // it gets closed.
        runner?.requestResync()
    }
```

- [ ] **Step 5: Run the suite**

Run: `ps1-macos/test.sh 2>&1 | tail -30`
Expected: PASS, including `EmulatorViewModelStageTests`.

- [ ] **Step 6: Commit**

```bash
git add ps1-macos/Sources/PS1/ContentView.swift ps1-macos/Sources/PS1/EmulatorViewModel.swift ps1-macos/Tests/PS1Tests/StreamQueueTests.swift
git commit -m "fix(macos): rebuild the display coordinator per runner; resync on reset

SwiftUI may keep MetalDisplayView's identity across a disc change,
leaving the coordinator holding the previous runner -- harmless when it
only read frames, wrong now that it drains that runner's stream.

ps1_reset clears software VRAM while the GPU texture keeps the old
picture, and nothing is queued at that instant, so the resync flag is
the only thing carrying the news.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: `PS1_LIVE_DIFF` — the exploratory oracle

**Files:**
- Modify: `ps1-macos/Sources/PS1/LiveRenderer.swift`
- Test: `ps1-macos/Tests/PS1Tests/LiveRendererTests.swift`
- Exploratory: Croc, Silent Hill, Spyro, Crash, TR1

**Interfaces:**
- Consumes: `MetalVram.readbackNative()`, `LiveRenderer.lastExecutedSeq`, the seq from `withNewestFrame`.
- Produces: `LiveRenderer.diff(against:seq:) -> String?` and the `diffEnabled` switch.

- [ ] **Step 1: Write the failing tests**

Append to `LiveRendererTests.swift`:

```swift
@Test func theDiffIsSilentWhenTheTextureMatchesTheShadow() throws {
    guard let (_, _, live) = try makeLive() else { return }
    let q = StreamQueue()
    q.clearResync()
    fillStream(q, seq: 1, x: 0, y: 0, color: 0x001F)
    live.drain(from: q) { [] }

    var shadow = [UInt16](repeating: 0, count: 1024 * 512)
    for y in 0..<16 { for x in 0..<16 { shadow[y * 1024 + x] = 0x001F } }

    #expect(live.diff(against: shadow, seq: 1) == nil)
}

@Test func theDiffNamesTheFrameAndTheFirstDifferingPixel() throws {
    guard let (_, _, live) = try makeLive() else { return }
    let q = StreamQueue()
    q.clearResync()
    fillStream(q, seq: 3, x: 0, y: 0, color: 0x001F)
    live.drain(from: q) { [] }

    // Right shape, wrong colour: 256 pixels differ, the first at (0, 0).
    var shadow = [UInt16](repeating: 0, count: 1024 * 512)
    for y in 0..<16 { for x in 0..<16 { shadow[y * 1024 + x] = 0x7C00 } }

    let report = try #require(live.diff(against: shadow, seq: 3))
    #expect(report.contains("seq 3"))
    #expect(report.contains("256"))
    #expect(report.contains("(0, 0)"))
}

@Test func theDiffRefusesToCompareTwoDifferentInstants() throws {
    guard let (_, _, live) = try makeLive() else { return }
    let q = StreamQueue()
    q.clearResync()
    fillStream(q, seq: 1, x: 0, y: 0, color: 0x001F)
    live.drain(from: q) { [] }

    // The shadow is from frame 9; the texture holds frame 1. Comparing them
    // would report a divergence on every frame the emulator runs ahead, which
    // is exactly the noise that would make the oracle useless.
    #expect(live.diff(against: [UInt16](repeating: 0, count: 1024 * 512), seq: 9) == nil)
}
```

- [ ] **Step 2: Run and verify failure**

Run: `ps1-macos/test.sh 2>&1 | tail -30`
Expected: FAIL — `LiveRenderer` has no `diff`.

- [ ] **Step 3: Implement the oracle**

Append to `LiveRenderer`:

```swift
    /// The exploratory oracle: the render texture against the software shadow,
    /// per frame, on whatever is actually being played.
    ///
    /// The fixture corpus is eleven streams; five games booting and playing is
    /// coverage it does not have. This is how a divergence gets LOCALISED once
    /// it exists — the response is then to bank that window as a fixture with
    /// `zig build fixtures`, never to weaken a gate.
    ///
    /// An environment variable is fine here: the standing warning in CLAUDE.md
    /// is about the hosted TEST process, which sees neither an exported
    /// variable nor xcodebuild's TEST_RUNNER_ prefix. This switch is never read
    /// from a test.
    let diffEnabled = ProcessInfo.processInfo.environment["PS1_LIVE_DIFF"] == "1"

    /// Returns nil when the texture matches, or when `seq` is not the frame
    /// the texture currently holds.
    ///
    /// The seq check is what keeps this usable: without it, every frame the
    /// emulator runs ahead of the renderer reports a divergence, and the real
    /// ones drown.
    func diff(against shadow: [UInt16], seq: UInt64) -> String? {
        guard seq == lastExecutedSeq else { return nil }
        let got = vram.readbackNative()
        guard got.count == shadow.count else { return nil }

        var differing = 0
        var first = -1
        for i in 0..<got.count where got[i] != shadow[i] {
            differing += 1
            if first < 0 { first = i }
        }
        guard differing > 0 else { return nil }

        let x = first % MetalVram.nativeWidth
        let y = first / MetalVram.nativeWidth
        return """
        PS1_LIVE_DIFF: seq \(seq) diverged — \(differing) pixels, \
        first at (\(x), \(y)) gpu=0x\(String(got[first], radix: 16, uppercase: true)) \
        shadow=0x\(String(shadow[first], radix: 16, uppercase: true))
        """
    }
```

- [ ] **Step 4: Run the diff tests**

Run: `ps1-macos/test.sh 2>&1 | tail -30`
Expected: all three pass.

- [ ] **Step 5: Call it from the coordinator**

In `MetalDisplayView.Coordinator.draw(in:)`, after the `runner.withNewestFrame` block that fills `params`:

```swift
            if live.diffEnabled {
                runner.withNewestFrame { vram, _, seq in
                    let shadow = [UInt16](UnsafeBufferPointer(
                        start: vram, count: EmulatorRunner.vramCount))
                    if let report = self.live.diff(against: shadow, seq: seq) {
                        print(report)
                    }
                }
            }
```

- [ ] **Step 6: Commit**

```bash
git add ps1-macos/Sources/PS1/LiveRenderer.swift ps1-macos/Sources/PS1/MetalDisplayView.swift ps1-macos/Tests/PS1Tests/LiveRendererTests.swift
git commit -m "feat(macos): PS1_LIVE_DIFF, the per-frame divergence oracle

Reads the render texture back and compares it against the software
shadow, on whatever is actually being played. The seq check is what
makes it usable: without it every frame the emulator runs ahead reports
a divergence and the real ones drown.

Eleven fixtures is not the coverage of five games booting and playing.
When this fires, bank the window as a fixture -- never weaken a gate.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

- [ ] **Step 7: Run the five games**

```bash
zig build capi-lib && zig build metallib && zig build macos
PS1_LIVE_DIFF=1 ./zig-out/PS1.app/Contents/MacOS/PS1
```

Play each of Croc, Silent Hill, Spyro, Crash Bandicoot and Tomb Raider past the boot logo and into gameplay, watching stdout.

Expected: **no `PS1_LIVE_DIFF` lines.** For each game that does diverge, record in the commit message: the game, the seq, the pixel count and the first coordinate. Then capture that window as a fixture and add it to `MetalRasterizerTests`'s corpus — the divergence is reproducible from there, and the fix belongs in a follow-up commit with the fixture as its gate.

One expected class of divergence is **not** a bug and must be recognised rather than chased: a primitive that samples its own destination. The software rasterizer scans row by row and sees its own new values deterministically; nothing orders fragments within one primitive on a GPU. `HazardTracker` orders one draw against the next and does not help. A handful of unexplained pixels on a self-sampling primitive is a divergence class, not a defect.

- [ ] **Step 8: Also confirm 24bpp and the debug seam by eye**

```bash
./zig-out/PS1.app/Contents/MacOS/PS1                      # Croc's FMV must play
PS1_SOFTWARE_DISPLAY=1 ./zig-out/PS1.app/Contents/MacOS/PS1  # identical picture
```

Expected: Croc's opening FMV renders correctly (that is the 24bpp shadow route), and the software-display run is visually indistinguishable from the default one at 15bpp.

---

### Task 9: Documentation

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the Metal backend paragraph**

In `CLAUDE.md`, the paragraph beginning "**The Metal backend renders at an internal resolution of 1-8x and is fixture-driven only.**" is now wrong in its first sentence. Replace that opening and the sentence about `MetalRasterizer` being unreachable:

```markdown
**The Metal backend renders at an internal resolution of 1-8x and is now the
LIVE display path at 1x.** `MetalRasterizer` (with `MetalVram`, `PrimBuilder`,
`PrimEncoders`, `HazardTracker`) consumes both `.p1fx` fixtures and, since Phase
D1, the live command stream: `ps1-capi` builds `gpu_sink = .dual`,
`ps1_take_frame_stream` drains one frame per `ps1_run_frame`, `EmulatorRunner`
copies it into a 4-slot ring, and `LiveRenderer` drains that ring from the
`MTKView` draw callback. **Scale above 1x is not wired to the app** — the picker,
the scale-aware scanout wraps and the aspect interaction are Phase D2.
```

- [ ] **Step 2: Add the D1 traps to the same section**

Append to that paragraph:

```markdown
Five things about the live path are load-bearing. **`ps1_take_frame_stream` is a
DRAIN, not a peek** — it resets the recorder, so it must be called exactly once
per `ps1_run_frame`, and a frame left untaken stacks onto the next until the
capacity overruns. **`complete == 0` means the records are a PREFIX**, so the
stream is discarded and the renderer resyncs from the shadow rather than
replaying it. **VRAM is published before the stream, under the same seq**, which
is what makes "discard the backlog and adopt the newest shadow" a complete
resync with no per-slot reconciliation. **Execution never skips a frame, only
presentation does** — a command stream is a set of incremental mutations, unlike
the idempotent VRAM snapshot the shadow path publishes. And **24bpp scans out of
the 1x shadow permanently**, because it byte-packs across adjacent 16-bit words
and that arithmetic cannot survive N x N replication; Croc and Silent Hill both
depend on it.

Two environment switches, both debug-only and both read by the APP rather than
the test host (the marker-file scheme exists because the hosted test process sees
no environment; the app launched from a shell has an ordinary one):
`PS1_LIVE_DIFF=1` reads the render texture back each frame and logs the first
divergence against the shadow, and `PS1_SOFTWARE_DISPLAY=1` routes 15bpp back to
the shadow so a suspect frame can be A/B'd without a rebuild. Neither is a mode
and neither is a user-facing setting.
```

- [ ] **Step 3: Update the quick-commands table**

The `zig build capi-lib` row currently reads "Builds `zig-out/lib/libps1core.a`, the C ABI the macOS app links." Extend it:

```markdown
| `zig build capi-lib` | Builds `zig-out/lib/libps1core.a`, the C ABI the macOS app links. Built with `gpu_sink = .dual` since Phase D1 — it records the GP0 stream as well as rasterizing, which costs ~6.8 MB of `Recorder` inside `Bus`. |
```

And the test row's binary count is unchanged at 15, but `capi_test` now compiles against the recording core — note that in the `enable_rom_tests` bullet list below the table:

```markdown
- **`capi_test` compiles against the RECORDING core module**, not the shared
  one, because the shipped `libps1core.a` is built `.dual`. A test binary built
  against a configuration no frontend links would leave `ps1_take_frame_stream`
  untested.
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: the Metal backend is the live display path at 1x

Records the five load-bearing D1 rules -- take-is-a-drain, prefix means
discard, VRAM-before-stream under one seq, execution never skips, 24bpp
stays on the shadow -- and the two debug environment switches.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Final verification

- [ ] `zig build test` — 15 binaries green.
- [ ] `zig build trace-golden -- verify -Doptimize=ReleaseFast` — 10 workloads OK. **Nothing in D1 touches `ps1-core/src`**, so a moved hash here means an unintended core change.
- [ ] `zig build test-roms-pl -Doptimize=ReleaseFast` and `zig build test-roms-ja -Doptimize=ReleaseFast` — the PL ratchet green, JA still 12/17.
- [ ] `zig build capi-lib && zig build metallib && zig build macos` — the app builds.
- [ ] `ps1-macos/test.sh` — every pre-existing test plus the new ones, with all eleven Phase B/C fixture hashes unmoved.
- [ ] The five-game `PS1_LIVE_DIFF` run reported in Task 8's commit message.
