# Threaded software rasterizer: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the software rasterizer on a second thread in the macOS app,
bit-exact with today's output, so its ~15% of the emulator thread overlaps
with emulation instead of adding to it.

**Architecture:** First, GP0 and GPUREAD stop reading `Vram`'s transfer
fields and read a small mirror the emulator thread owns (`gpu/transfer.zig`),
in both modes, so the existing goldens police the mirror. Then a
`RasterWorker` (`gpu/worker.zig`) takes `command.Command` records and upload
words through two single-producer/single-consumer rings and runs the
unchanged `command.execute` on its own thread against its own `DrawingEnv`.
The emulator thread applies the four env kinds itself as well, and waits
(`Gpu.syncRaster`) only where it reads what the worker owns: GPUREAD, the
per-frame VRAM/depth copies, savestates and the harness's hashes.

**Tech Stack:** Zig 0.17.0 (`std.Thread.spawn`, `std.atomic.Value`,
`std.Io.futexWaitUncancelable`/`futexWake`), `ps1-golden`, `ps1-capi`,
`ps1-bench`.

**Spec:** `docs/superpowers/specs/2026-10-01-threaded-software-rasterizer-design.md`.
Read all of it first. Then read `ps1-core/src/gpu/sink.zig`,
`ps1-core/src/gpu/command.zig` (`execute`), `ps1-core/src/gpu/vram.zig`
(the transfer half), `ps1-core/src/gpu/gpu.zig` (`readData`,
`processFifoWord`, `vramReadPending`), `gp0.zig:189-193`,
`ps1-core/src/savestate/gpu_state.zig`, and `ps1-capi/src/root.zig`
(`Handle`, `buildMachine`, `ps1_reset`, `ps1_save_state`, `ps1_load_state`,
`ps1_copy_vram`, `ps1_copy_depth`). Invoke the `ps1-gpu-metal` skill before
Task 1 and `ps1-test-harnesses` before Task 3.

**Two additions to the spec, made here on purpose:**

1. **A `.deferred` worker mode.** It runs no thread: records queue until a
   sync, or a full ring, drains them on the caller's thread. A missing sync
   point then reads stale VRAM on EVERY run, so `verify --threaded=deferred`
   and the unit tests can fail deterministically. That answers the spec's
   first risk ("a missed reader may pass every gate by luck of timing")
   with a gate rather than a grep.
2. **`Bus.deinit` detaches the worker itself.** Every path that frees a
   `Bus` (`ps1_destroy`, `ps1_reset`, the old machine in `ps1_load_state`,
   `ps1-golden`'s `saveAndRestore`, every test) is then safe by
   construction rather than by each caller remembering.

## Global Constraints

- Zig **0.17.0**. Thread: `std.Thread.spawn(.{}, f, .{args})`. Futex:
  `io.futexWaitUncancelable(u32, ptr, expected)` and
  `io.futexWake(u32, ptr, n)` on a `std.Io`. Atomics: `std.atomic.Value(u32)`
  (`.raw` is the `u32` a futex takes).
- Output stays **bit-exact**: `zig build trace-golden -- verify` passes with
  goldens untouched, worker off AND on. No golden is recaptured by this plan.
- The worker is opt-in: only `ps1-capi` turns it on by default. `ps1-debug`,
  `ps1-trace`, the ROM suites and plain `ps1-golden` never attach one.
- Compiled out under `builtin.single_threaded` (the wasm build). `zig build`
  must still build `emulator.wasm`.
- No frame pipelining: the app's per-frame `ps1_copy_vram` drains the worker.
- Commit messages are a **title line only**: no body, no trailer.
- No file in `ps1-core/src` over ~600 lines. Run `zig fmt` before each commit.
- Never `git push`.

## Review Focus

1. **An FMV pushing more upload words in a frame than the payload ring
   holds.** Expect identical VRAM; the producer waits for space rather than
   overwriting. Pinned by Task 2's "two whole-VRAM uploads" test.
2. **A game reading VRAM back (GPUREAD by CPU or DMA) right after drawing
   into it.** Expect the freshly drawn pixels. Pinned by Task 2's GPUREAD
   test in `.deferred` mode (DMA's GPUREAD goes through the same
   `Gpu.readData`, `memory.zig:714`).
3. **A player who resets or loads a state mid-frame with a deep queue.**
   Expect no crash, a fresh worker on the new `Bus`, and the old one
   drained before its `Bus` is freed. Pinned by Task 4's reset and load
   tests.
4. **Quitting while the worker is asleep between frames.** Expect
   `ps1_destroy` to return promptly, not hang on a lost wakeup. Pinned by
   Task 2's "detach wakes a sleeping worker" test.
5. **The Metal resync adopting the depth plane with PGXP depth on.** Expect
   `ps1_copy_depth` to reflect queued draws and fills. Pinned by Task 4's
   `copy_depth` test.

---

### Task 1: The transfer mirror, in both modes

GP0's "is this word pixels?" and GPUREAD's "is a readback in flight?" move
off `Vram` onto `Sink.transfer`, an emulator-owned counter pair. Nothing is
threaded yet: this task is the behaviour-preserving half, and the goldens
check it.

**Files:**
- Create: `ps1-core/src/gpu/transfer.zig`
- Modify: `ps1-core/src/gpu/vram.zig` (new `transferWords`, used by `setupWrite`/`setupRead`)
- Modify: `ps1-core/src/gpu/sink.zig` (`transfer` field, the four transfer methods, `checkSettled`)
- Modify: `ps1-core/src/gpu/gp0.zig:190`
- Modify: `ps1-core/src/gpu/gpu.zig` (`vramReadPending`, `readData`, `processFifoWord`)
- Modify: `ps1-core/src/savestate/gpu_state.zig` (`loadGpu` rebuilds the mirror; header comment)
- Test: `ps1-core/tests/gpu_test.zig`, `ps1-core/tests/savestate_test.zig`

**Interfaces:**
- Produces: `Transfer` with fields `write_words: usize`, `read_words: usize`
  and `writeActive() bool`, `readActive() bool`, `writeSetup(w, h)`,
  `wordWritten()`, `writeAbort()`, `readSetup(w, h)`, `wordRead()`,
  `fromVram(*const Vram) Transfer`, `matches(*const Vram) bool`.
  `Vram.transferWords(w: usize, h: usize) usize`. `Sink.transfer: Transfer`.
  `Sink.checkSettled(*const Sink, *const Vram) void` (pub).

- [ ] **Step 1: Re-check the reader list**

Run:
```bash
grep -rn "gpu\.vram\|\.vram\.data\|\.vram\.depth\|read_active\|write_active" ps1-core/src ps1-capi/src ps1-bench ps1-golden/src | grep -v "gpu/vram.zig"
```
Expected: exactly these emulator-side readers and no others.
`gp0.zig:190`, `gpu.zig:103` (`getVramPtr`, wasm only), `gpu.zig:273`,
`gpu.zig:322`, `command.zig:323` (the worker side), `gpu_state.zig`
(savestate, synced in Task 4), `state_hash.zig` (synced in Task 3),
`ps1-capi/src/root.zig:720,725` (synced in Task 4),
`ps1-bench/main.zig:91` (synced in Task 5), and `ps1-golden`'s
stream-capture/stream-verify/synthetic paths (never threaded).
`ps1-trace/src/main.zig:627,746` reads too, but `ps1-trace` never attaches a worker.
If the list differs, stop and add the new reader to the sync points in the
spec before going on.

- [ ] **Step 2: Write the failing tests**

Append to `ps1-core/tests/gpu_test.zig`:

```zig
/// Feeds GP0 words one at a time with the FIFO's debt cleared, so each word
/// is decoded the moment it arrives, then drains whatever queued anyway.
fn feed(gpu: *Gpu, words: []const u32) void {
    for (words) |w| {
        gpu.cycle_debt = 0;
        _ = gpu.writeGp0(w, Value.none);
    }
    drainGp0(gpu);
}

test "the transfer mirror follows an upload, a partial upload and its abort" {
    var gpu = Gpu.init();
    setupGpu(&gpu);
    const t = &gpu.sink.transfer;

    // 3x1 is two words: the odd pixel still costs a whole word.
    feed(&gpu, &.{ 0xA0000000, xy(0, 0), xy(3, 1) });
    try expectEqual(@as(usize, 2), t.write_words);
    try std.testing.expect(t.matches(&gpu.vram));
    feed(&gpu, &.{0x11112222});
    try expectEqual(@as(usize, 1), t.write_words);
    feed(&gpu, &.{0x33334444});
    try std.testing.expect(!t.writeActive());
    try std.testing.expect(t.matches(&gpu.vram));

    // GP1(01) mid-payload. `Vram` keeps `write_remaining` with the flag
    // cleared, so "matches" has to go by the flag.
    feed(&gpu, &.{ 0xA0000000, xy(0, 0), xy(4, 4) });
    feed(&gpu, &.{0x55556666});
    gpu.writeGp1(0x01000000);
    try std.testing.expect(!t.writeActive());
    try std.testing.expect(gpu.vram.write_remaining != 0);
    try std.testing.expect(t.matches(&gpu.vram));
    // The next word is a command again, not payload.
    feed(&gpu, &.{ 0x02FFFFFF, xy(0, 0), xy(16, 1) });
    try expectEqual(@as(u16, 0x7FFF), gpu.vram.data[0]);
}

test "a zero-sized transfer covers the whole axis in the mirror too" {
    var gpu = Gpu.init();
    setupGpu(&gpu);
    // w = 0 is 1024 pixels and h = 0 is 512 rows: 262,144 words.
    feed(&gpu, &.{ 0xA0000000, xy(0, 0), xy(0, 0) });
    try expectEqual(@as(usize, 262_144), gpu.sink.transfer.write_words);
    gpu.writeGp1(0x01000000);
    feed(&gpu, &.{ 0xC0000000, xy(0, 0), xy(0, 1) });
    try expectEqual(@as(usize, 512), gpu.sink.transfer.read_words);
    try std.testing.expect(gpu.sink.transfer.matches(&gpu.vram));
}

test "GPUREAD counts down the mirror word by word" {
    var gpu = Gpu.init();
    setupGpu(&gpu);
    feed(&gpu, &.{ 0xC0000000, xy(0, 0), xy(4, 1) });
    try expectEqual(@as(usize, 2), gpu.sink.transfer.read_words);
    _ = gpu.readData();
    try expectEqual(@as(usize, 1), gpu.sink.transfer.read_words);
    _ = gpu.readData();
    try std.testing.expect(!gpu.sink.transfer.readActive());
    try expectEqual(@as(u32, 0), gpu.readStatus() & (1 << 27));
}
```

Append to `ps1-core/tests/savestate_test.zig`:

```zig
test "a state saved mid-upload resumes the upload, not a command stream" {
    var a = try Machine.init();
    defer a.deinit();
    var b = try Machine.init();
    defer b.deinit();

    const g = &a.bus.gpu;
    // 4x1 at (8, 0): two words; send one, leaving one outstanding.
    for ([_]u32{ 0xA0000000, 8, 0x0001_0004, 0x2222_1111 }) |w| {
        g.cycle_debt = 0;
        _ = g.writeGp0(w, ps1.pgxp.Value.none);
    }
    try std.testing.expectEqual(@as(usize, 1), g.sink.transfer.write_words);

    try roundTrip(&a, &b, gpu_state.saveGpu, gpu_state.loadGpu);

    const h = &b.bus.gpu;
    try std.testing.expectEqual(@as(usize, 1), h.sink.transfer.write_words);
    h.cycle_debt = 0;
    _ = h.writeGp0(0x4444_3333, ps1.pgxp.Value.none);
    try std.testing.expectEqual(@as(u16, 0x3333), h.vram.data[10]);
    try std.testing.expectEqual(@as(u16, 0x4444), h.vram.data[11]);
    try std.testing.expect(!h.sink.transfer.writeActive());
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: `zig build test -Dtest-filter="mirror"` then `zig build test -Dtest-filter="mid-upload"`
Expected: compile error, `no field named 'transfer' in struct 'gpu.sink.Sink'`.

- [ ] **Step 4: Add `Vram.transferWords` and use it**

In `ps1-core/src/gpu/vram.zig`, below `axisExtent`:

```zig
    /// Words a transfer of `w` x `h` moves: two pixels per word, the odd
    /// last pixel still costing a whole one.
    pub fn transferWords(w: usize, h: usize) usize {
        return (axisExtent(w, constants.vram_width) * axisExtent(h, constants.vram_height) + 1) / 2;
    }
```

In `setupWrite`, replace `self.write_remaining = (width * height + 1) / 2;`
with `self.write_remaining = transferWords(w, h);`. Likewise in
`setupRead`: `self.read_remaining = transferWords(w, h);`.

- [ ] **Step 5: Create `ps1-core/src/gpu/transfer.zig`**

```zig
//! The emulator thread's own count of the CPU<->VRAM transfer in flight.
//!
//! GP0 decides every word by it ("pixels, or a command?") and GPUREAD and
//! GPUSTAT bit 27 by its read half, so it is read per word and must never
//! wait on a raster worker. `Vram` keeps its own transfer fields, because
//! placing the pixels needs them; this is the control half alone, updated by
//! `Sink` where the records are made. It is the source of truth with a
//! worker AND without one, which is what lets the goldens police it.

const std = @import("std");
const Vram = @import("vram.zig").Vram;

pub const Transfer = struct {
    /// CPU->VRAM payload words still to come.
    write_words: usize = 0,
    /// VRAM->CPU words still to read through GPUREAD.
    read_words: usize = 0,

    pub fn writeActive(t: Transfer) bool {
        return t.write_words > 0;
    }

    pub fn readActive(t: Transfer) bool {
        return t.read_words > 0;
    }

    pub fn writeSetup(t: *Transfer, w: usize, h: usize) void {
        t.write_words = Vram.transferWords(w, h);
    }

    pub fn wordWritten(t: *Transfer) void {
        if (t.write_words > 0) t.write_words -= 1;
    }

    pub fn writeAbort(t: *Transfer) void {
        t.write_words = 0;
    }

    pub fn readSetup(t: *Transfer, w: usize, h: usize) void {
        t.read_words = Vram.transferWords(w, h);
    }

    pub fn wordRead(t: *Transfer) void {
        if (t.read_words > 0) t.read_words -= 1;
    }

    /// What a settled `Vram` says is in flight. An aborted upload keeps its
    /// `write_remaining` with `write_active` cleared, so the flag decides.
    /// Also how a loaded state rebuilds the mirror: the counters are the
    /// same unit (words), so the savestate format does not change.
    pub fn fromVram(v: *const Vram) Transfer {
        return .{
            .write_words = if (v.write_active) v.write_remaining else 0,
            .read_words = if (v.read_active) v.read_remaining else 0,
        };
    }

    pub fn matches(t: Transfer, v: *const Vram) bool {
        return std.meta.eql(t, fromVram(v));
    }
};
```

- [ ] **Step 6: Wire it into `Sink`**

In `ps1-core/src/gpu/sink.zig`, add the import and the field:

```zig
pub const Transfer = @import("transfer.zig").Transfer;
```

```zig
    rec: Storage = .{},

    /// The control half of the transfer in flight; see `transfer.zig`.
    transfer: Transfer = .{},
```

Add, after `submit`:

```zig
    /// With nothing deferring the rasterizer, `vram` is settled after every
    /// transfer step, so the mirror must agree with it there. Safety builds
    /// only, which is every unit test.
    pub fn checkSettled(self: *const Sink, vram: *const Vram) void {
        if (!std.debug.runtime_safety) return;
        std.debug.assert(self.transfer.matches(vram));
    }
```

Update the four transfer methods (body shown in full):

```zig
    pub fn vramWriteSetup(self: *Sink, vram: *Vram, env: *DrawingEnv, x: usize, y: usize, w: usize, h: usize) void {
        self.transfer.writeSetup(w, h);
        self.submit(vram, env, .{
            .kind = .vram_write_setup,
            .x = @intCast(x),
            .y = @intCast(y),
            .w = @intCast(w),
            .h = @intCast(h),
        });
        self.checkSettled(vram);
    }

    pub fn vramWriteData(self: *Sink, vram: *Vram, env: *DrawingEnv, value: u32) void {
        if (comptime Sink.kind == .dual) self.rec.pushVramWriteData(value);
        self.transfer.wordWritten();
        const words = [_]u32{value};
        command.execute(.{ .kind = .vram_write_data, .x = 0, .y = 1 }, &words, vram, env);
        self.checkSettled(vram);
    }

    pub fn vramWriteAbort(self: *Sink, vram: *Vram, env: *DrawingEnv) void {
        self.transfer.writeAbort();
        self.submit(vram, env, .{ .kind = .vram_write_abort });
        self.checkSettled(vram);
    }

    pub fn vramReadSetup(self: *Sink, vram: *Vram, env: *DrawingEnv, x: usize, y: usize, w: usize, h: usize) void {
        self.transfer.readSetup(w, h);
        self.submit(vram, env, .{
            .kind = .vram_read_setup,
            .x = @intCast(x),
            .y = @intCast(y),
            .w = @intCast(w),
            .h = @intCast(h),
        });
        self.checkSettled(vram);
    }
```

Keep the existing doc comment on `vramWriteData` and the multi-line
parameter layout `zig fmt` leaves on the setup methods.

- [ ] **Step 7: Switch the readers**

`ps1-core/src/gpu/gp0.zig:190`: `if (vram.write_active) {` becomes
`if (sink.transfer.writeActive()) {`.

`ps1-core/src/gpu/gpu.zig`, `vramReadPending`:
```zig
        return self.gpu_read_mode == .Vram and self.sink.transfer.readActive();
```

`readData`:
```zig
    pub fn readData(self: *Self) u32 {
        self.catchUp();
        if (!self.vramReadPending()) {
            return self.gpu_read_data;
        }
        self.sink.transfer.wordRead();
        const word = self.vram.readData();
        self.sink.checkSettled(&self.vram);
        return word;
    }
```

`processFifoWord`'s last line: `if (self.sink.transfer.readActive()) self.gpu_read_mode = .Vram;`
and adjust its comment ("is picked up from the transfer it just armed")
only if it no longer reads true.

- [ ] **Step 8: Rebuild the mirror on load**

In `ps1-core/src/savestate/gpu_state.zig`'s `loadGpu`, directly after
`v.read_remaining = try r.int(usize);`:

```zig
    g.sink.transfer = .fromVram(v);
```

In the file's header comment, extend the "Absent on purpose" sentence:
the transfer mirror on `sink` is not saved either, because it is rebuilt
from the `Vram` fields it mirrors.

- [ ] **Step 9: Run the tests**

Run: `zig build test`
Expected: all 22 binaries pass, including the four new tests. A
`checkSettled` assertion firing anywhere names a sink path where mirror and
`Vram` disagree: fix the mirror, never the assertion.

- [ ] **Step 10: Run the golden gates**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- verify` and
`zig build trace-golden -Doptimize=ReleaseFast -- savestate`
Expected: every workload passes, goldens untouched (`git status` shows no
change under `ps1-core/tests/goldens/`).

- [ ] **Step 11: Commit**

```bash
zig fmt ps1-core
git add ps1-core/src/gpu/transfer.zig ps1-core/src/gpu/vram.zig ps1-core/src/gpu/sink.zig ps1-core/src/gpu/gp0.zig ps1-core/src/gpu/gpu.zig ps1-core/src/savestate/gpu_state.zig ps1-core/tests/gpu_test.zig ps1-core/tests/savestate_test.zig
git commit -m "refactor(gpu): GP0 and GPUREAD read a transfer mirror the emulator thread owns"
```

---

### Task 2: `RasterWorker` and the sink's hand-off

**Files:**
- Create: `ps1-core/src/gpu/worker.zig`
- Modify: `ps1-core/src/gpu/command.zig` (`isEnvKind`, `applyEnv`; `execute` delegates to `applyEnv`)
- Modify: `ps1-core/src/gpu/sink.zig` (`worker` field; `submit`, `vramWriteData`, `checkSettled`)
- Modify: `ps1-core/src/gpu/gpu.zig` (exports; `attachRasterWorker`, `detachRasterWorker`, `syncRaster`; `readData` syncs)
- Modify: `ps1-core/src/memory.zig:253` (`Bus.deinit` detaches)
- Test: `ps1-core/tests/gpu_test.zig`

**Interfaces:**
- Consumes: `Sink.transfer`, `Transfer.matches`, `Sink.checkSettled` (Task 1).
- Produces: `ps1_core.gpu.RasterWorker` with `Mode = enum { thread, deferred }`,
  `create(allocator, io: std.Io, vram: *Vram, env: DrawingEnv, mode: Mode) !*RasterWorker`,
  `destroy()`, `push(command.Command)`, `pushWord(u32)`, `sync()`, pub fields
  `vram: *Vram`, `env: DrawingEnv`, `thread: ?std.Thread`, `work: Signal`.
  `ps1_core.gpu.raster_worker_available: bool`.
  `Gpu.attachRasterWorker(self, allocator, io: std.Io, mode: RasterWorker.Mode) !void`,
  `Gpu.detachRasterWorker(self) void`, `Gpu.syncRaster(self) void`.
  `Sink.worker: ?*RasterWorker`.
  `command.isEnvKind(Kind) bool`, `command.applyEnv(Command, *DrawingEnv) void`.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/gpu_test.zig`:

```zig
const RasterWorker = ps1_core.gpu.RasterWorker;

/// Every record kind the worker executes: env words, a fill, a copy, flat,
/// shaded and textured triangles, a rectangle, a line, an upload aborted
/// mid-payload, a complete upload under a set mask, and a readback setup.
fn feedMixedWorkload(gpu: *Gpu) void {
    setupGpu(gpu);
    feed(gpu, &.{
        0xE1000600, // dither on, draw to the display area allowed
        0x020000FF, xy(16, 16), xy(32, 32), // fill red
        0x80000000, xy(16, 16), xy(64, 16), xy(32, 32), // copy it right
        0x2000FF00, xy(0, 100), xy(64, 100), xy(0, 164), // flat triangle
        0x300000FF, xy(100, 100), 0x0000FF00, xy(164, 100), 0x00FF0000, xy(100, 164), // shaded
        0x24808080, xy(200, 100), 0x0000_0000, xy(264, 100), 0x0008_0020, xy(200, 164), 0x0000_2000, // textured
        0x60FFFF00, xy(300, 300), xy(20, 10), // rectangle
        0x40FFFFFF, xy(0, 0), xy(200, 50), // line
        0xA0000000, xy(400, 0), xy(4, 4), 0x11112222, // upload, then...
    });
    gpu.writeGp1(0x01000000); // ...aborted mid-payload
    feed(gpu, &.{ 0xE6000001, 0xA0000000, xy(500, 0), xy(8, 8) });
    var words: [32]u32 = undefined;
    for (&words, 0..) |*w, i| w.* = @intCast(0x0101_0101 *% (i + 1));
    feed(gpu, &words);
    feed(gpu, &.{ 0xE6000000, 0xC0000000, xy(16, 16), xy(2, 1) });
}

fn expectSameGpu(want: *const Gpu, got: *const Gpu) !void {
    try std.testing.expect(std.mem.eql(u16, &want.vram.data, &got.vram.data));
    try std.testing.expect(std.mem.eql(u32, &want.vram.depth, &got.vram.depth));
    try std.testing.expect(std.meta.eql(want.draw_env, got.draw_env));
    try std.testing.expect(std.meta.eql(want.sink.transfer, got.sink.transfer));
}

fn newGpu() !*Gpu {
    const gpu = try std.testing.allocator.create(Gpu);
    gpu.* = Gpu.init();
    return gpu;
}

fn freeGpu(gpu: *Gpu) void {
    gpu.detachRasterWorker();
    std.testing.allocator.destroy(gpu);
}

test "a threaded GPU ends with the same VRAM, depth and env as an inline one" {
    if (!ps1_core.gpu.raster_worker_available) return error.SkipZigTest;
    for ([_]RasterWorker.Mode{ .thread, .deferred }) |mode| {
        const want = try newGpu();
        defer freeGpu(want);
        const got = try newGpu();
        defer freeGpu(got);
        try got.attachRasterWorker(std.testing.allocator, std.testing.io, mode);

        feedMixedWorkload(want);
        feedMixedWorkload(got);
        got.syncRaster();

        try expectSameGpu(want, got);
        // The worker's env followed the same records as the emulator's.
        try std.testing.expect(std.meta.eql(got.draw_env, got.sink.worker.?.env));
    }
}

test "GPUREAD returns the pixels of draws still queued ahead of it" {
    if (!ps1_core.gpu.raster_worker_available) return error.SkipZigTest;
    const gpu = try newGpu();
    defer freeGpu(gpu);
    // Deferred: without the sync in `readData`, nothing below has executed
    // when the word is read, and this fails every time.
    try gpu.attachRasterWorker(std.testing.allocator, std.testing.io, .deferred);
    setupGpu(gpu);
    feed(gpu, &.{ 0x020000FF, xy(0, 0), xy(16, 1) }); // red fill
    try expectEqual(@as(u16, 0), gpu.vram.data[0]); // still queued
    feed(gpu, &.{ 0xC0000000, xy(0, 0), xy(2, 1) });
    try expectEqual(@as(u32, 0x001F_001F), gpu.readData());
}

test "two whole-VRAM uploads, more than the payload ring holds, land intact" {
    if (!ps1_core.gpu.raster_worker_available) return error.SkipZigTest;
    for ([_]RasterWorker.Mode{ .thread, .deferred }) |mode| {
        const want = try newGpu();
        defer freeGpu(want);
        const got = try newGpu();
        defer freeGpu(got);
        try got.attachRasterWorker(std.testing.allocator, std.testing.io, mode);

        for ([_]*Gpu{ want, got }) |gpu| {
            setupGpu(gpu);
            for (0..2) |pass| {
                feed(gpu, &.{ 0xA0000000, xy(0, 0), xy(0, 0) });
                for (0..262_144) |i| {
                    gpu.cycle_debt = 0;
                    _ = gpu.writeGp0(@truncate(i *% 0x9E37_79B9 +% pass), Value.none);
                }
            }
        }
        got.syncRaster();
        try expectSameGpu(want, got);
    }
}

test "more records than the ring holds wait for space instead of overwriting" {
    if (!ps1_core.gpu.raster_worker_available) return error.SkipZigTest;
    for ([_]RasterWorker.Mode{ .thread, .deferred }) |mode| {
        const want = try newGpu();
        defer freeGpu(want);
        const got = try newGpu();
        defer freeGpu(got);
        try got.attachRasterWorker(std.testing.allocator, std.testing.io, mode);

        for ([_]*Gpu{ want, got }) |gpu| {
            setupGpu(gpu);
            for (0..RasterWorker.ring_records * 3) |i| {
                const x: u16 = @intCast((i * 16) % 1024);
                const y: u16 = @intCast((i / 64) % 512);
                feed(gpu, &.{ 0x02000000 | @as(u32, @truncate(i)), xy(x, y), xy(16, 1) });
            }
        }
        got.syncRaster();
        try expectSameGpu(want, got);
    }
}

test "detach wakes a worker that has gone to sleep" {
    if (!ps1_core.gpu.raster_worker_available) return error.SkipZigTest;
    const gpu = try newGpu();
    defer std.testing.allocator.destroy(gpu);
    try gpu.attachRasterWorker(std.testing.allocator, std.testing.io, .thread);
    const w = gpu.sink.worker.?;
    // Idle from birth: it spins, then announces itself and sleeps.
    while (w.work.waiting.load(.seq_cst) == 0) std.Thread.yield() catch {};
    gpu.detachRasterWorker(); // hangs here if the wakeup is lost
    try std.testing.expect(gpu.sink.worker == null);
}
```

The textured triangle's texel values do not matter: both sides read the
same VRAM. Check the expected red against `Color.getColor16(0x0000FF)`
if `0x001F` is not what `gpu.getColor16(0x0000FF)` returns, and use that.

- [ ] **Step 2: Run them to verify they fail**

Run: `zig build test`
Expected: compile error, `RasterWorker` is not a member of `gpu`.

- [ ] **Step 3: `command.isEnvKind` and `command.applyEnv`**

In `ps1-core/src/gpu/command.zig`, above `execute`:

```zig
/// The four kinds that change the drawing environment and touch no pixel.
/// Under a raster worker the emulator thread applies these itself too:
/// GPUSTAT, GP1(10h) and `gp0`'s own decode read the environment
/// constantly, and none of them can wait for the worker.
pub fn isEnvKind(kind: Kind) bool {
    return switch (kind) {
        .set_draw_env, .latch_texpage, .set_texture_disable_allowed, .reset_draw_env => true,
        else => false,
    };
}

pub fn applyEnv(cmd: Command, env: *DrawingEnv) void {
    switch (cmd.kind) {
        .set_draw_env => env.update(cmd.opcode, cmd.value),
        .latch_texpage => env.latchPolygonTexpage(cmd.tpage),
        .set_texture_disable_allowed => env.texture_disable_allowed = cmd.value != 0,
        .reset_draw_env => env.* = .{},
        else => unreachable,
    }
}
```

In `execute`, replace the four env arms with one:

```zig
        .set_draw_env,
        .latch_texpage,
        .set_texture_disable_allowed,
        .reset_draw_env,
        => applyEnv(cmd, env),
```

- [ ] **Step 4: Create `ps1-core/src/gpu/worker.zig`**

```zig
//! The software rasterizer on a second thread.
//!
//! The emulator thread is the only producer and the worker the only consumer
//! of two single-producer/single-consumer rings: records, and the CPU->VRAM
//! payload words the upload records point into. The worker runs the same
//! `command.execute` the inline path runs, on its own copy of the drawing
//! environment, so threading changes WHEN a pixel lands and never which
//! pixel. `sync` is how the emulator thread waits for "now".
//!
//! `.deferred` runs no thread: nothing executes until a sync, or a full ring,
//! drains the queue on the caller's thread. A sync point missing from the
//! emulator side then reads stale VRAM on every run instead of only when the
//! worker happens to lose a race, which is what lets
//! `verify --threaded=deferred` fail.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const command = @import("command.zig");
const Vram = @import("vram.zig").Vram;
const DrawingEnv = @import("registers.zig").DrawingEnv;

/// There is no second thread on a single-threaded target (the wasm build).
pub const available = !builtin.single_threaded;

/// Records in flight. Covers `stream-verify`'s per-frame peak, so an
/// ordinary frame never waits for space; a frame that outgrows it waits.
pub const ring_records: u32 = 16_384;
/// Upload words in flight: one whole-VRAM upload.
pub const ring_payload: u32 = 262_144;
/// An upload run is published once it reaches this many words. The consumer
/// frees payload only from published runs, so an open run must never be able
/// to fill the ring; publishing early also starts a long upload sooner.
pub const max_run: u32 = 4096;
/// Polls before a waiter sleeps. The waits worth spinning for are a few
/// microseconds; anything longer sleeps rather than heating a fanless
/// machine.
const spin_limit: u32 = 1024;

comptime {
    // The counters are free-running u32s and a slot is the counter modulo
    // the ring, which survives the u32 wrap only for a power of two.
    std.debug.assert(std.math.isPowerOfTwo(ring_records));
    std.debug.assert(std.math.isPowerOfTwo(ring_payload));
    std.debug.assert(max_run < ring_payload);
}

/// An event count. A waiter sleeps on `seq` only after announcing itself in
/// `waiting` and re-testing its condition; a notifier bumps `seq` only when
/// someone has announced. Every access is seq_cst, so either the waiter's
/// re-test sees the new state or the notifier sees the waiter, and a bump
/// that lands between the re-test and the sleep makes the futex return at
/// once because `seq` no longer matches.
const Signal = struct {
    seq: std.atomic.Value(u32) = .init(0),
    waiting: std.atomic.Value(u32) = .init(0),

    fn wait(s: *Signal, io: Io, w: *RasterWorker, comptime ready: fn (*RasterWorker) bool) void {
        var spins: u32 = 0;
        while (!ready(w)) {
            if (spins < spin_limit) {
                spins += 1;
                std.atomic.spinLoopHint();
                continue;
            }
            const seq = s.seq.load(.seq_cst);
            s.waiting.store(1, .seq_cst);
            if (!ready(w)) io.futexWaitUncancelable(u32, &s.seq.raw, seq);
            s.waiting.store(0, .seq_cst);
        }
    }

    fn notify(s: *Signal, io: Io) void {
        if (s.waiting.load(.seq_cst) == 0) return;
        _ = s.seq.fetchAdd(1, .seq_cst);
        io.futexWake(u32, &s.seq.raw, 1);
    }
};

pub const RasterWorker = struct {
    pub const Mode = enum { thread, deferred };

    records: []command.Command,
    payload: []u32,

    /// Records published by the producer and executed by the consumer.
    /// Free-running: the slot is the count modulo `ring_records`.
    head: std.atomic.Value(u32) = .init(0),
    tail: std.atomic.Value(u32) = .init(0),
    /// Payload words written by the producer and consumed by the consumer.
    payload_head: u32 = 0,
    payload_tail: std.atomic.Value(u32) = .init(0),
    /// The upload run being built: its first word's slot and its length.
    /// The consumer cannot see it until `closeRun` publishes it.
    run_start: u32 = 0,
    run_len: u32 = 0,

    /// The consumer sleeps on `work`, the producer on `space`.
    work: Signal = .{},
    space: Signal = .{},
    quit: std.atomic.Value(bool) = .init(false),

    vram: *Vram,
    /// Equal to `Gpu.draw_env` at every record: both start from the same
    /// value and apply the same env records in the same order.
    env: DrawingEnv,
    io: Io,
    allocator: std.mem.Allocator,
    thread: ?std.Thread = null,

    pub fn create(allocator: std.mem.Allocator, io: Io, vram: *Vram, env: DrawingEnv, mode: Mode) !*RasterWorker {
        if (comptime !available) return error.Unsupported;
        const w = try allocator.create(RasterWorker);
        errdefer allocator.destroy(w);
        const records = try allocator.alloc(command.Command, ring_records);
        errdefer allocator.free(records);
        const payload = try allocator.alloc(u32, ring_payload);
        errdefer allocator.free(payload);
        w.* = .{
            .records = records,
            .payload = payload,
            .vram = vram,
            .env = env,
            .io = io,
            .allocator = allocator,
        };
        if (mode == .thread) w.thread = try std.Thread.spawn(.{}, consume, .{w});
        return w;
    }

    /// Drains the queue, stops the thread and frees everything.
    pub fn destroy(w: *RasterWorker) void {
        w.sync();
        if (comptime available) {
            if (w.thread) |t| {
                w.quit.store(true, .seq_cst);
                w.work.notify(w.io);
                t.join();
            }
        }
        const allocator = w.allocator;
        allocator.free(w.records);
        allocator.free(w.payload);
        allocator.destroy(w);
    }

    // The producer side: the emulator thread only.

    pub fn push(w: *RasterWorker, cmd: command.Command) void {
        w.closeRun();
        w.publish(cmd);
    }

    pub fn pushWord(w: *RasterWorker, word: u32) void {
        const slot = w.payload_head % ring_payload;
        // A run is one contiguous slice of the ring: it closes at the wrap.
        if (w.run_len == max_run or (w.run_len > 0 and slot == 0)) w.closeRun();
        w.waitFor(&w.space, payloadFree);
        w.payload[slot] = word;
        if (w.run_len == 0) w.run_start = slot;
        w.run_len += 1;
        w.payload_head +%= 1;
    }

    /// Returns once everything pushed so far has executed. Until its next
    /// push, the emulator thread may then read `vram`: pixels, depth and
    /// the transfer fields.
    pub fn sync(w: *RasterWorker) void {
        w.closeRun();
        w.waitFor(&w.space, idle);
    }

    fn closeRun(w: *RasterWorker) void {
        if (w.run_len == 0) return;
        const len = w.run_len;
        w.run_len = 0;
        w.publish(.{ .kind = .vram_write_data, .x = @intCast(w.run_start), .y = @intCast(len) });
    }

    fn publish(w: *RasterWorker, cmd: command.Command) void {
        w.waitFor(&w.space, recordFree);
        const h = w.head.load(.monotonic);
        w.records[h % ring_records] = cmd;
        w.head.store(h +% 1, .seq_cst);
        w.work.notify(w.io);
    }

    /// A deferred worker has no one to wait for: it does the work itself.
    fn waitFor(w: *RasterWorker, s: *Signal, comptime ready: fn (*RasterWorker) bool) void {
        if (w.thread == null) {
            if (!ready(w)) w.drain();
            return;
        }
        s.wait(w.io, w, ready);
    }

    fn idle(w: *RasterWorker) bool {
        return w.tail.load(.seq_cst) == w.head.load(.monotonic);
    }

    fn recordFree(w: *RasterWorker) bool {
        return w.head.load(.monotonic) -% w.tail.load(.seq_cst) < ring_records;
    }

    fn payloadFree(w: *RasterWorker) bool {
        return w.payload_head -% w.payload_tail.load(.seq_cst) < ring_payload;
    }

    // The consumer side: the worker thread, or the caller under `.deferred`.

    fn consume(w: *RasterWorker) void {
        while (true) {
            w.work.wait(w.io, w, pendingOrQuit);
            // `destroy` syncs before it quits, so quit finds the ring empty.
            if (!w.pending()) return;
            w.executeNext();
        }
    }

    fn drain(w: *RasterWorker) void {
        while (w.pending()) w.executeNext();
    }

    fn pending(w: *RasterWorker) bool {
        return w.head.load(.seq_cst) != w.tail.load(.monotonic);
    }

    fn pendingOrQuit(w: *RasterWorker) bool {
        return w.pending() or w.quit.load(.seq_cst);
    }

    fn executeNext(w: *RasterWorker) void {
        const t = w.tail.load(.monotonic);
        const cmd = w.records[t % ring_records];
        command.execute(cmd, w.payload, w.vram, &w.env);
        if (cmd.kind == .vram_write_data) {
            const len: u32 = @intCast(cmd.y);
            w.payload_tail.store(w.payload_tail.load(.monotonic) +% len, .seq_cst);
        }
        w.tail.store(t +% 1, .seq_cst);
        w.space.notify(w.io);
    }
};
```

- [ ] **Step 5: The sink hands records to the worker**

In `ps1-core/src/gpu/sink.zig`, add the imports:

```zig
const RasterWorker = @import("worker.zig").RasterWorker;
const worker_available = @import("worker.zig").available;
```

Add the field below `transfer`:

```zig
    /// Set while a raster worker owns `vram`. The emulator thread then never
    /// touches `vram` except after `Gpu.syncRaster`.
    worker: ?*RasterWorker = null,
```

Replace `submit`:

```zig
    /// The one place a command becomes an effect. Recording and rasterizing
    /// see the SAME record, so a field the sink forgets to fill is a field the
    /// rasterizer does not get either. Under a worker the env kinds are
    /// applied here as well, to the emulator's environment.
    fn submit(self: *Sink, vram: *Vram, env: *DrawingEnv, cmd: command.Command) void {
        if (comptime Sink.kind == .dual) self.rec.push(cmd);
        if (self.deferTo()) |w| {
            if (command.isEnvKind(cmd.kind)) command.applyEnv(cmd, env);
            w.push(cmd);
            return;
        }
        command.execute(cmd, &.{}, vram, env);
    }

    fn deferTo(self: *const Sink) ?*RasterWorker {
        if (comptime !worker_available) return null;
        return self.worker;
    }
```

In `vramWriteData`, after `self.transfer.wordWritten();`:

```zig
        if (self.deferTo()) |w| return w.pushWord(value);
```

In `checkSettled`, after the `runtime_safety` line:

```zig
        // Under a worker `vram` is settled only after a sync; see `syncRaster`.
        if (self.deferTo() != null) return;
```

- [ ] **Step 6: `Gpu` attaches, detaches and syncs**

In `ps1-core/src/gpu/gpu.zig`, with the other exports:

```zig
pub const RasterWorker = @import("worker.zig").RasterWorker;
pub const raster_worker_available = @import("worker.zig").available;
```

Add to `Gpu`, after `getVramPtr`:

```zig
    /// Moves the software rasterizer onto a worker. Draws, fills, copies and
    /// uploads then land when the worker gets to them, and everything that
    /// reads `vram` on this thread must `syncRaster` first.
    pub fn attachRasterWorker(self: *Self, allocator: std.mem.Allocator, io: std.Io, mode: RasterWorker.Mode) !void {
        std.debug.assert(self.sink.worker == null);
        self.sink.worker = try RasterWorker.create(allocator, io, &self.vram, self.draw_env, mode);
    }

    /// Drains and stops the worker. A no-op without one.
    pub fn detachRasterWorker(self: *Self) void {
        const w = self.sink.worker orelse return;
        w.destroy();
        self.sink.worker = null;
    }

    /// Waits until the worker has executed everything queued. A no-op
    /// without one, so callers need not ask.
    pub fn syncRaster(self: *Self) void {
        const w = self.sink.worker orelse return;
        w.sync();
        if (std.debug.runtime_safety) std.debug.assert(self.sink.transfer.matches(&self.vram));
    }
```

In `readData`, insert `self.syncRaster();` directly before
`self.sink.transfer.wordRead();`.

- [ ] **Step 7: `Bus.deinit` detaches**

`ps1-core/src/memory.zig`, first line of `deinit`:

```zig
        // Before anything is freed: the worker holds a pointer into `gpu`.
        self.gpu.detachRasterWorker();
```

- [ ] **Step 8: Run the tests**

Run: `zig build test`
Expected: all pass. Run it three times: a lost wakeup shows up as a hang
in "detach wakes a worker" or in the `.thread` passes, not as a failure.

- [ ] **Step 9: Prove the deferred tests can fail**

Comment out `self.syncRaster();` in `Gpu.readData`; run
`zig build test`. Expected: "GPUREAD returns the pixels of draws still
queued" FAILS. Restore it. Then comment out
`if (command.isEnvKind(cmd.kind)) command.applyEnv(cmd, env);` in `submit`;
expected: the "same VRAM, depth and env" test FAILS on `draw_env`. Restore.

- [ ] **Step 10: Check the wasm build still compiles**

Run: `zig build`
Expected: success, `zig-out/bin/emulator.wasm` rebuilt.

- [ ] **Step 11: Run the gates (worker off)**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- verify` and
`zig build test-roms-ja -Doptimize=ReleaseFast`
Expected: every workload passes; the JA suite stays at 12/17.

- [ ] **Step 12: Commit**

```bash
zig fmt ps1-core
git add ps1-core/src/gpu/worker.zig ps1-core/src/gpu/command.zig ps1-core/src/gpu/sink.zig ps1-core/src/gpu/gpu.zig ps1-core/src/memory.zig ps1-core/tests/gpu_test.zig
git commit -m "feat(gpu): a raster worker runs the software rasterizer off the emulator thread"
```

---

### Task 3: `ps1-golden --threaded`, and sizing the ring

**Files:**
- Modify: `ps1-golden/src/main.zig` (usage, `Options`, `parseArgs`, `runWorkload`, `saveAndRestore`)
- Modify: `ps1-core/src/gpu/worker.zig` (`ring_records`, only if Step 6 says so)

**Interfaces:**
- Consumes: `Gpu.attachRasterWorker`, `Gpu.syncRaster`, `RasterWorker.Mode` (Task 2).
- Produces: `ps1-golden <verify|savestate> --threaded[=deferred]`.

- [ ] **Step 1: Parse the option**

In `Options`, after `engine`:

```zig
    /// `--threaded[=deferred]`: rasterize on a `RasterWorker`. Verified
    /// against the SAME goldens: threaded output must equal inline output,
    /// hash for hash. `deferred` runs no thread, so a missing sync point is
    /// a stale read on every run rather than a lost race.
    threaded: ?ps1.gpu.RasterWorker.Mode = null,
```

In `parseArgs`' loop, before the final `else`:

```zig
        } else if (std.mem.eql(u8, arg, "--threaded")) {
            opts.threaded = .thread;
        } else if (std.mem.startsWith(u8, arg, "--threaded=")) {
            opts.threaded = std.meta.stringToEnum(ps1.gpu.RasterWorker.Mode, arg["--threaded=".len..]) orelse return error.BadArguments;
```

After the loop, beside the other checks:

```zig
    // Only the hash gates sync where the worker needs them to.
    if (opts.threaded != null and opts.mode != .verify and opts.mode != .savestate) return error.BadArguments;
```

In `usage`, after the `--engine` lines:

```
    \\  --threaded[=deferred]   (verify, savestate) rasterize on a worker
    \\                          thread, against the same goldens. `deferred`
    \\                          queues until a sync, so a missing sync fails
    \\                          every run.
```

- [ ] **Step 2: Attach, and sync before every hash**

In `runWorkload`, after `try selectEngine(&cpu, opts);`:

```zig
    if (opts.threaded) |mode| try bus.gpu.attachRasterWorker(std.heap.smp_allocator, io, mode);
```

In the sample block, after `for (&bus.timers) |*t| t.catchUp();`:

```zig
            // The hash reads VRAM, which a worker owns until it is drained.
            bus.gpu.syncRaster();
```

Change the restore call to pass `io`:
`bus = try saveAndRestore(a, io, &cpu, opts);`

- [ ] **Step 3: `saveAndRestore` syncs, and the restored machine gets a worker**

Signature: `fn saveAndRestore(a: std.mem.Allocator, io: std.Io, cpu: *ps1.cpu.Cpu, opts: Options) !*ps1.memory.Bus`.
First line of the body: `cpu.bus.gpu.syncRaster();` (the save reads VRAM
and its transfer fields). After `try ps1.savestate.load(&restored, buf);`:

```zig
    // After the load, so the worker's env starts from the restored one.
    if (opts.threaded) |mode| try fresh.gpu.attachRasterWorker(std.heap.smp_allocator, io, mode);
```

`old.deinit(a)` already detaches the old worker (Task 2, Step 7).

- [ ] **Step 4: Run the threaded gates**

Run each, `-Doptimize=ReleaseFast`:
```bash
zig build trace-golden -Doptimize=ReleaseFast -- verify --threaded
zig build trace-golden -Doptimize=ReleaseFast -- verify --threaded=deferred
zig build trace-golden -Doptimize=ReleaseFast -- savestate --threaded
zig build trace-golden -Doptimize=ReleaseFast -- savestate --threaded=deferred
```
Expected: every workload passes against the committed goldens. A
divergence here is a bug in the worker or a missing sync, never a golden
to recapture.

- [ ] **Step 5: Prove the gate can fail**

Temporarily delete the `bus.gpu.syncRaster();` before `hashAll`, then run
`verify --threaded=deferred --filter=croc`. Expected: DIVERGED (the VRAM
hash lags the queue). Restore it. Temporarily delete the
`command.applyEnv` line in `Sink.submit`; run the same. Expected: DIVERGED
(GPUSTAT bits 0-10 read a stale env). Restore it, and confirm `git diff`
shows only this task's intended changes.

- [ ] **Step 6: Size the record ring from measured peaks**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- stream-verify`
and read the `peak N rec / M payload` column. If the largest record peak
over every workload except Tekken 3's ringed display list exceeds
`ring_records` (16,384), raise `ring_records` to the next power of two
above it and re-run Step 4's first command. Either way, write the measured
peaks into the `ring_records` doc comment (e.g. "Peak measured
2026-10-xx: 9,812 records (spyro)"), so the size has a source.

- [ ] **Step 7: Commit**

```bash
zig fmt ps1-golden ps1-core
git add ps1-golden/src/main.zig ps1-core/src/gpu/worker.zig
git commit -m "feat(golden): verify --threaded checks the raster worker against the same goldens"
```

---

### Task 4: `ps1-capi` attaches the worker and syncs at its boundaries

**Files:**
- Modify: `ps1-capi/src/root.zig`
- Test: `ps1-capi/src/capi_test.zig`

**Interfaces:**
- Consumes: `Gpu.attachRasterWorker`, `Gpu.detachRasterWorker`,
  `Gpu.syncRaster`, `RasterWorker.Mode`, `raster_worker_available`,
  `RasterWorker.vram`, `RasterWorker.thread`.
- Produces: no ABI change. `ps1.h` is untouched; every existing entry
  point behaves as before, threaded underneath.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-capi/src/capi_test.zig`:

```zig
/// Swaps the handle's worker for a `.deferred` one: a draw then stays
/// queued until something syncs, so a missing sync reads stale pixels on
/// every run.
fn deferWorker(h: *capi.Handle) !void {
    h.cpu.bus.gpu.detachRasterWorker();
    try h.cpu.bus.gpu.attachRasterWorker(std.testing.allocator, std.testing.io, .deferred);
}

fn gp0(h: *capi.Handle, words: []const u32) void {
    for (words) |w| {
        h.cpu.bus.gpu.cycle_debt = 0;
        _ = h.cpu.bus.gpu.writeGp0(w, Value.none);
    }
}

/// Full drawing area, then a red 16x16 fill at the origin.
fn queueRedFill(h: *capi.Handle) void {
    gp0(h, &.{ 0xE3000000, 0xE407FFFF, 0xE5000000, 0x020000FF, 0, 0x0010_0010 });
}

test "a new handle rasterizes on a worker thread" {
    if (!ps1_core.gpu.raster_worker_available) return error.SkipZigTest;
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    const w = h.cpu.bus.gpu.sink.worker orelse return error.NoWorker;
    try std.testing.expect(w.thread != null);
}

test "copy_vram waits for a draw still queued on the worker" {
    if (!ps1_core.gpu.raster_worker_available) return error.SkipZigTest;
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    try deferWorker(h);
    queueRedFill(h);
    try std.testing.expectEqual(@as(u16, 0), h.cpu.bus.gpu.vram.data[0]);

    const dst = try std.testing.allocator.alloc(u16, 1024 * 512);
    defer std.testing.allocator.free(dst);
    capi.ps1_copy_vram(h, dst.ptr);
    try std.testing.expectEqual(@as(u16, 0x001F), dst[0]);
}

test "copy_depth waits for the worker" {
    if (!ps1_core.gpu.raster_worker_available) return error.SkipZigTest;
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    try deferWorker(h);
    h.cpu.bus.gpu.vram.depth[0] = 5; // the worker is idle: nothing queued
    queueRedFill(h); // a fill resets depth where it writes colour

    const dst = try std.testing.allocator.alloc(u32, 1024 * 512);
    defer std.testing.allocator.free(dst);
    capi.ps1_copy_depth(h, dst.ptr);
    try std.testing.expectEqual(@as(u32, 0), dst[0]);
}

test "a state saved with draws queued equals one saved inline" {
    if (!ps1_core.gpu.raster_worker_available) return error.SkipZigTest;
    const threaded = try bootHandle(0x11);
    defer capi.ps1_destroy(threaded);
    const inline_h = try bootHandle(0x11);
    defer capi.ps1_destroy(inline_h);
    try deferWorker(threaded);
    inline_h.cpu.bus.gpu.detachRasterWorker();

    queueRedFill(threaded);
    queueRedFill(inline_h);
    const a = try saveState(threaded);
    defer std.testing.allocator.free(a);
    const b = try saveState(inline_h);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualSlices(u8, b, a);
}

test "a state saved mid-upload resumes the upload on the loading handle's worker" {
    if (!ps1_core.gpu.raster_worker_available) return error.SkipZigTest;
    const src = try bootHandle(0x11);
    defer capi.ps1_destroy(src);
    gp0(src, &.{ 0xA0000000, 8, 0x0001_0004, 0x2222_1111 }); // 2 words, 1 sent
    const state = try saveState(src);
    defer std.testing.allocator.free(state);

    const dst = try bootHandle(0x11);
    defer capi.ps1_destroy(dst);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_state(dst, state.ptr, state.len));
    const w = dst.cpu.bus.gpu.sink.worker orelse return error.NoWorker;
    try std.testing.expect(w.vram == &dst.cpu.bus.gpu.vram);

    gp0(dst, &.{0x4444_3333});
    const vram = try std.testing.allocator.alloc(u16, 1024 * 512);
    defer std.testing.allocator.free(vram);
    capi.ps1_copy_vram(dst, vram.ptr);
    try std.testing.expectEqual(@as(u16, 0x3333), vram[10]);
    try std.testing.expectEqual(@as(u16, 0x4444), vram[11]);
}

test "a refused load keeps the running machine's worker" {
    if (!ps1_core.gpu.raster_worker_available) return error.SkipZigTest;
    const h = try bootHandle(0x11);
    defer capi.ps1_destroy(h);
    const state = try saveState(h);
    defer std.testing.allocator.free(state);
    state[100] ^= 0xFF;

    const before = h.cpu.bus.gpu.sink.worker;
    try std.testing.expectEqual(capi.PS1_ERR_STATE_CORRUPT, capi.ps1_load_state(h, state.ptr, state.len));
    try std.testing.expect(h.cpu.bus.gpu.sink.worker == before);
    queueRedFill(h);
    const vram = try std.testing.allocator.alloc(u16, 1024 * 512);
    defer std.testing.allocator.free(vram);
    capi.ps1_copy_vram(h, vram.ptr);
    try std.testing.expectEqual(@as(u16, 0x001F), vram[0]);
}

test "a reset with draws queued comes back on a fresh worker thread" {
    if (!ps1_core.gpu.raster_worker_available) return error.SkipZigTest;
    const h = try bootHandle(0x11);
    defer capi.ps1_destroy(h);
    try deferWorker(h);
    for (0..100) |_| queueRedFill(h);
    capi.ps1_reset(h);
    const w = h.cpu.bus.gpu.sink.worker orelse return error.NoWorker;
    try std.testing.expect(w.thread != null);
    try std.testing.expect(w.vram == &h.cpu.bus.gpu.vram);
}
```

`ps1_core` must be imported at the top of `capi_test.zig` already (it is:
`const ps1_core = @import("ps1_core");`).

- [ ] **Step 2: Run them to verify they fail**

Run: `zig build test`
Expected: "a new handle rasterizes on a worker thread" fails with
`error.NoWorker`, and the deferred tests fail or report stale pixels.

- [ ] **Step 3: The handle owns an `Io`, and installs a worker on every `Bus`**

In `Handle`, after `engine`:

```zig
    /// The `Io` the raster worker sleeps and wakes through. This is a
    /// library with no `main` to hand one down, so it keeps its own, in the
    /// single-threaded form: that installs no signal handlers in the host
    /// app, and its futex is the OS futex either way.
    io_impl: std.Io.Threaded = .init_single_threaded,
```

After `installEngine`:

```zig
/// The raster worker is a host choice like the engine: every `Bus` comes up
/// without one, so each one this file builds gets it here. A failure leaves
/// the machine rasterizing inline, which draws the same pixels.
fn installWorker(h: *Handle, bus: *Bus) void {
    if (comptime !ps1.gpu.raster_worker_available) return;
    bus.gpu.attachRasterWorker(allocator, h.io_impl.io(), .thread) catch {};
}
```

`buildMachine` gains a last line: `installWorker(h, h.bus);`

- [ ] **Step 4: Sync at every boundary that reads VRAM**

`ps1_save_state_size` and `ps1_save_state`: first line
`h.cpu.bus.gpu.syncRaster();`. (The size pass writes nothing, but it still
reads the `Vram` transfer fields the worker writes.)

`ps1_copy_depth` and `ps1_copy_vram`: first line
`h.cpu.bus.gpu.syncRaster();` (the handle is `*const`, but `bus` is a
`*Bus`, so this compiles unchanged).

`ps1_load_state`: after `h.cpu = cpu;`, add

```zig
    // After the swap, so the worker's env is the restored one. The old
    // machine's worker was drained and stopped by its `deinit` above; a
    // refused state returned before either, leaving it running.
    installWorker(h, h.bus);
```

`ps1_reset` and `ps1_destroy` need no change: `Bus.deinit` detaches, and
`buildMachine` installs.

- [ ] **Step 5: Run the tests**

Run: `zig build test`
Expected: all pass, including every pre-existing `capi_test` (they now
run threaded).

- [ ] **Step 6: Build the library and run the Swift suite**

```bash
pkill -x Substation; zig build capi-lib && zig build metallib && ps1-macos/test.sh
```
Expected: all 539 Swift tests pass (the app now runs threaded; the
fixture gates do not, since they replay records).

- [ ] **Step 7: Commit**

```bash
zig fmt ps1-capi
git add ps1-capi/src/root.zig ps1-capi/src/capi_test.zig
git commit -m "feat(capi): the app rasterizes on a worker thread, synced at every VRAM read"
```

---

### Task 5: Measure it, and write down what was built

**Files:**
- Modify: `ps1-bench/main.zig`
- Modify: `CLAUDE.md` (Quick commands: `trace-golden` and `ps1-bench` rows; the `capi-lib` row)
- Modify: `docs/superpowers/specs/2026-10-01-threaded-software-rasterizer-design.md` (an "As built" section)

- [ ] **Step 1: `ps1-bench ... threaded`**

In `ps1-bench/main.zig`'s argument loop:

```zig
        if (std.mem.eql(u8, a, "threaded")) threaded = true;
```

with `var threaded = false;` beside the other flags. After
`ps1.recompiler.setLowering(...)`:

```zig
    if (threaded) try cpu.bus.gpu.attachRasterWorker(alloc, io, .thread);
```

In the frame loop, before the copy, unconditionally (the app's per-frame
`ps1_copy_vram` always syncs, `nocopy` or not):

```zig
        cpu.bus.gpu.syncRaster();
```

Add `threaded={}` to the result line, after `engine=`. Update the module
comment's last paragraph: "`threaded` attaches a raster worker and drains
it once per frame, as `ps1_copy_vram` does in the app."

- [ ] **Step 2: Interleaved A/B**

```bash
zig build -Doptimize=ReleaseFast
for i in 1 2 3 4 5; do
  zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin games/croc/croc.cue 3000 --engine=jit
  zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin games/croc/croc.cue 3000 --engine=jit threaded
done
```
Repeat for Spyro. Let the machine settle first; take the BEST of five per
side. Check the `games/` paths with `ls games/` and use the real cue names.
Expected: a gain in `fps`. Report the number as measured, including if it
is zero or negative; there is no target.

- [ ] **Step 3: Write the "As built" section**

Append to the spec:

```markdown
## As built (2026-10-xx)

- The two additions the plan made: the `.deferred` mode and `Bus.deinit`
  detaching. Why each exists (see the plan's preamble).
- `ps1_save_state_size` syncs too: its counting pass reads the transfer
  fields, which is a race without the sync even though the size cannot change.
- Ring sizes and the stream-verify peaks they came from.
- The bench table: Croc and Spyro, best of five, inline vs threaded,
  `--engine=jit`, with the date and machine.
```

Fill in every bullet from the actual runs. Do not leave a placeholder in
the committed text.

- [ ] **Step 4: Update `CLAUDE.md`**

In the `trace-golden -- verify` row, after the `--engine=jit` sentence:
"`--threaded` verifies the raster worker against the SAME goldens, and
`--threaded=deferred` queues until a sync, so a missing sync point fails
every run; `savestate` takes both too." In the `ps1-bench` row, add:
"`threaded` attaches the raster worker and syncs it once per frame, as the
app does." In the `capi-lib` row, add: "The handle rasterizes on a worker
thread (`gpu/worker.zig`); every VRAM read across the ABI syncs it first."

In "Rules that must not be broken", under **GPU + Metal**, add:

```markdown
- **Under a raster worker, nothing on the emulator thread reads `vram`
  without `Gpu.syncRaster` first.** GP0 and GPUSTAT read `Sink.transfer`
  and `Gpu.draw_env` instead, which the emulator thread keeps current
  itself. A new reader that skips the sync is a data race, not a wrong
  pixel: `verify --threaded=deferred` is the gate that catches it.
```

- [ ] **Step 5: Commit**

```bash
zig fmt ps1-bench
git add ps1-bench/main.zig CLAUDE.md docs/superpowers/specs/2026-10-01-threaded-software-rasterizer-design.md
git commit -m "docs: as built for the threaded rasterizer, and ps1-bench threaded"
```
