# Emulator CPU optimization — remaining items — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the emulator's CPU cost by roughly another 15% by deferring the GPU's and the timers' per-instruction ticks to their next deadline, using the pattern the CDROM already proves, and then skip the per-frame VRAM copy on the frames nothing reads it.

**Architecture:** Every device that `Cpu.tickPeripherals` drives is called once per emulated instruction (~11.7M/s) and in the steady state does nothing. Each gets a `pending_cycles` accumulator and an `event_countdown` guard — the number of cycles until the earliest thing it could do — so the body runs once per deadline instead of once per instruction. The device's own timers stay bit-exact wherever anything observes them: `catchUp()` settles them before any MMIO access, and `ps1-golden` settles before each sample, which is what lets the **existing goldens verify the change unchanged** rather than being recaptured around it.

**Tech Stack:** Zig 0.16.0, `ps1-core`; Swift 6 / swift-testing and `xcodebuild` for Task 3 only.

**Spec:** None — this plan is self-contained. Its measurements are in *Measured baseline* below, and the reference implementation it copies is commit `3a0784e` (`perf(cdrom): defer the per-instruction tick to the next deadline`) plus the **`step` is DEFERRED** entry in CLAUDE.md's *CDROM — state of play*. Read both before Task 1.

---

## Global Constraints

- **Zig must be 0.16.0** (`zig version`). The std API here is 0.16-specific.
- **Run everything from the repo root.** The harnesses read the BIOS, discs and test ROMs via paths relative to the process CWD.
- **`-Doptimize=ReleaseFast` for every harness run**, always. A Debug core runs ~0.45x realtime, which turns a boot into a hang.
- **`zig build trace-golden -- verify` must pass on all TEN workloads against the goldens as they are committed. Do not run `capture`.** A recapture would rewrite exactly the evidence these tasks exist to produce. If `verify` goes red, the change is wrong — see *Appendix A: when verify goes red*.
- **`zig build test-roms-ja` must stay at 12/17.** Any other number is a regression.
- **`zig build test-roms-pl` currently FAILS on a clean tree, and did before this work started.** All six of its tests report exactly at their floors; the runner exits non-zero for an unrelated reason. Do not treat it as a gate and do not "fix" it as part of these tasks. Do not update its floors.
- **Measure with `ps1-bench`, best of five, on a settled machine.** A run started straight after `trace-golden` reads about 15% slow. Command in *Measured baseline*.
- **`zig fmt` every file you touch before committing.**
- **One commit per task, on `master`. Do not `git push`.**
- **No file in `ps1-core/src` over ~600 lines.** `gpu.zig` is close — check `wc -l` before adding to it.

---

## Measured baseline

Profiled 2026-08-30, Croc in-game, ReleaseFast, Apple Silicon, `sample` at 1 kHz, self-time aggregated from the call tree. **After** the CDROM work in `3a0784e`:

| Cost | Self time |
|---|---|
| `gpu.step`, inlined at `cpu/cpu.zig:199` | **11.8%** |
| Timers 0/1/2, at `cpu/cpu.zig:218/222/226/227/235` | **6.8%** |
| `spu.step` at `cpu/cpu.zig:190` | 2.4% — already a cheap `while` accumulator, leave it |
| CPU interpreter (`exec.execute` + `Cpu.step` fetch/pipeline) | ~37% |
| Software rasterizer (`command.execute` + `putPixel`) | ~14% |
| Bus MMIO / RAM | ~6% |
| Per-frame VRAM copy to Swift | **~1%** |

Throughput after `3a0784e`: **2.83x realtime** (best of five, 17.69 s for 3000 frames).

Reproduce with:

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin \
  "games/Croc - Legend of the Gobbos/Croc - Legend of the Gobbos.cue" 3000
```

**Two things not on the list, so nobody goes looking:**

- **The software rasterizer's 14% is not free money.** The resync, the 24bpp scanout and the game's own VRAM→CPU readbacks all read the software VRAM, so the software path has to stay correct even though Metal renders the picture. That 14% is the standing price of the `gpu_sink = .dual` architecture, not an oversight.
- **A shared pointer instead of the VRAM copy is not available.** The emulator thread mutates VRAM continuously while the render thread reads it; the triple buffer in `EmulatorRunner` exists for exactly that reason.

---

## The pattern (read this before Task 1)

`ps1-core/src/cdrom/cdrom.zig` is the reference implementation. Five parts:

1. **Two fields.** `pending_cycles: u32` (stepped past, not yet applied) and `event_countdown: i64` (cycles until the earliest thing the body does).
2. **An `inline fn step`** that is three instructions: `pending_cycles += cycles; event_countdown -= cycles; if (event_countdown > 0) return;` then call the cold body. `inline` matters — half the CDROM win was avoiding the call into a large struct, not the work inside it.
3. **`fn nextDeadline`** returning the minimum over the live deadlines, floored at 1. **Every timer the body acts on must appear here.** One left out is not a late event, it is an event that never fires — the guard steps straight past it.
4. **`fn applyElapsed(elapsed)`** — a pure advance of the counters that fires nothing. It exists because the body's blocks are **order-dependent**: a later block consumes what an earlier one just wrote. Skipped cycles go through `applyElapsed`; the **unmodified** body then runs with only *this* step's cycles.
5. **`pub fn catchUp()`** — `event_countdown = 0` **first and unconditionally**, then `applyElapsed(pending_cycles)`, then `pending_cycles = 0`. Called from the MMIO read/write path and from `ps1-golden` before each sample.

The two rules that were shipped broken first, both worth re-reading in CLAUDE.md:

- **The order-dependence in point 4 is real and it bites.** In the CDROM it was the seek block arming `sector_timer` and the read block three lines below charging it that instruction's cycles.
- **The unconditional re-arm in point 5 is load-bearing even though it looks harmless.** `commands.zig` arms a fresh timer on the next line of the register write that called `catchUp`; a deadline derived from the state before that write would stand. It cost four of ten workloads.

---

## File Structure

**Task 1 — the GPU**

- `ps1-core/src/gpu/gpu.zig` — modify. Two fields, `step` split into an inline guard plus `stepEvents`, plus `applyElapsed`, `nextDeadline`, `catchUp` and an `eager` flag. Currently 353 lines; check `wc -l` after — the ceiling is ~600.
- `ps1-core/src/memory.zig` — modify. `catchUp()` on the four GPU MMIO sites, and maintain `gpu.eager` from the timer-mode write path.
- `ps1-golden/src/main.zig` — modify. `bus.gpu.catchUp()` beside the existing `bus.cdrom.catchUp()`.
- `ps1-core/tests/gpu_test.zig` — modify. Two regression tests.

**Task 2 — the timers**

- `ps1-core/src/timer.zig` — modify. Same five parts; `read`/`write` call `catchUp` directly, since `Timer` owns its own MMIO entry points.
- `ps1-golden/src/main.zig` — modify. Settle the three timers before sampling.
- `ps1-core/tests/` — **create `timer_test.zig`.** There is no timer unit test file today; `build.zig`'s `unit_test_files` list must gain it.
- `build.zig` — modify. Add `timer_test.zig` to `unit_test_files`.

**Task 3 — the VRAM copy (optional, ~1%)**

- `ps1-macos/Sources/PS1/StreamQueue.swift` — modify. Replace the boolean `resync` with a monotonic request counter.
- `ps1-macos/Sources/PS1/EmulatorRunner.swift` — modify. Copy VRAM only when something will read it; publish which seq the slot's VRAM belongs to.
- `ps1-macos/Sources/PS1/LiveRenderer.swift` — modify. Consume a resync only when the shadow is fresh.
- `ps1-macos/Sources/PS1/MetalDisplayView.swift` — modify. Pass freshness through the shadow closure.
- `ps1-macos/Tests/PS1Tests/StreamQueueTests.swift` — modify (it exists).

**Task 4 — docs and the final number**

- `CLAUDE.md` — modify.

---

### Task 1: Defer the GPU tick

**Files:**
- Modify: `ps1-core/src/gpu/gpu.zig:44-56` (fields), `:73-125` (`step`)
- Modify: `ps1-core/src/memory.zig:339-340` (GPU reads), `:516,520` (GPU writes), `:505-511` (timer write path)
- Modify: `ps1-golden/src/main.zig:403` (the `catchUp` line added by `3a0784e`)
- Test: `ps1-core/tests/gpu_test.zig`

**Interfaces:**
- Produces: `Gpu.catchUp(self: *Gpu) void`, `Gpu.eager: bool`, `Gpu.pending_cycles: u32`, `Gpu.event_countdown: i64`. Task 2 does not consume any of them; Task 4 documents them.

**Why this one is safe to defer at all.** `is_vblank`, `v_count` and `is_even_field` change **only at a scanline boundary**, and the deadline below settles at every scanline boundary. So they are exact at every instruction for free — which matters, because `ps1_run_frame` (`ps1-capi/src/root.zig:141-142`) and the wasm frame loop (`ps1-wasm/src/main.zig:117-122`) poll `is_vblank` directly and never go through MMIO. The vblank IRQ likewise fires on the exact instruction. **Do not widen the deadline past one scanline** — that property is the whole reason no `catchUp` is needed on those two loops.

**Why `eager` exists.** `step` returns `dotclock_ticks` and `tick_hblank_timer`, which `tickPeripherals` feeds to timers 0 and 1 **when those timers are externally clocked**. Deferring batches those ticks, and a batched tick count is not the same as a stream of small ones once a timer crosses its target. Rather than model that, the GPU runs eagerly whenever either timer is in external-clock mode. That mode is set only by a timer-mode register write, so the flag is maintained at exactly one site.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/gpu_test.zig`:

```zig
test "is_vblank is exact at every instruction, not just at a deadline" {
    // The guard settles at every scanline boundary, which is the ONLY place
    // this field can change — so `ps1_run_frame` and the wasm frame loop,
    // which poll it directly and never touch MMIO, stay exact without a
    // catchUp of their own. Checking one endpoint would not pin that; this
    // walks a whole frame and checks the field against the arithmetic on
    // every single instruction. Widen the deadline past one scanline and this
    // is the test that goes red.
    var gpu = Gpu.init();
    const per_scanline = Gpu.ntsc_cycles_per_scanline;
    const start = Gpu.ntsc_vblank_start_line;
    const lines = Gpu.ntsc_scanlines_per_frame;

    var total: u32 = 0;
    while (total < per_scanline * lines) : (total += 1) {
        _ = gpu.step(1);
        const line = ((total + 1) / per_scanline) % lines;
        try expectEqual(line >= start, gpu.is_vblank);
    }
}

test "a GPU register read sees a settled scanline counter" {
    // `h_count` is stale between settles, and `readStatus` derives GPUSTAT
    // bit 31 from `v_count`. `memory.zig` calls catchUp on the way in, so the
    // fields must be right the moment catchUp returns — not one deadline later.
    var gpu = Gpu.init();
    var i: u32 = 0;
    while (i < 1000) : (i += 1) _ = gpu.step(1);

    gpu.catchUp();
    try expectEqual(@as(u32, 0), gpu.pending_cycles);
    try expectEqual(@as(u32, 1000), gpu.h_count);
}

- [ ] **Step 2: Run them and verify they fail**

Run: `zig build test -Doptimize=ReleaseFast`
Expected: FAIL — `Gpu` has no member `catchUp`, no member `pending_cycles`.

- [ ] **Step 3: Add the fields**

In `ps1-core/src/gpu/gpu.zig`, after `cycle_debt: i32 = 0,`:

```zig
    /// Video cycles stepped past without applying them, and the video cycles
    /// until the earliest thing `stepEvents` does. The same guard `cdrom.zig`
    /// carries, for the same reason — read `pending_cycles` there first, it
    /// carries the rules both of these obey.
    ///
    /// What makes the GPU safe to defer is that `is_vblank`, `v_count` and
    /// `is_even_field` change ONLY at a scanline boundary, and `nextDeadline`
    /// settles at every one of them. `ps1_run_frame` and the wasm frame loop
    /// poll `is_vblank` directly, never through MMIO, so they get no
    /// `catchUp` — they do not need one, and they would have no way to call it.
    pending_cycles: u32 = 0,
    event_countdown: i64 = 0,

    /// Suspends the guard while timer 0 or timer 1 is externally clocked.
    ///
    /// `step` RETURNS the dotclock and hblank ticks those two consume, and a
    /// batched tick count is not interchangeable with a stream of small ones
    /// once a timer crosses its target. Maintained by `memory.zig` from the
    /// timer-mode write, which is the only thing that can change the answer.
    eager: bool = false,
```

- [ ] **Step 4: Split `step`**

Replace the `pub fn step(self: *Self, delta_cycles: u32) GpuStepResult {` line and its opening `var result = ...` with:

```zig
    /// The per-instruction entry point: three instructions, inlined into
    /// `tickPeripherals`, and in the steady state it returns without touching
    /// anything else.
    pub inline fn step(self: *Self, delta_cycles: u32) GpuStepResult {
        self.pending_cycles += delta_cycles;
        self.event_countdown -= delta_cycles;
        if (self.event_countdown > 0) return .{};
        return self.stepEvents(delta_cycles);
    }

    /// Advances the free-running counters by `elapsed` and does NOTHING else.
    ///
    /// Sound only because `nextDeadline` guarantees no scanline boundary falls
    /// inside the skipped window, and refuses to defer at all while the GP0
    /// FIFO has a word in it. `cycle_debt` is deliberately untouched: with an
    /// empty FIFO the body drives it to 0 on every step anyway.
    fn applyElapsed(self: *Self, elapsed: u32) void {
        if (elapsed == 0) return;
        self.dotclock_count +%= elapsed;
        self.h_count +%= elapsed;
    }

    /// Video cycles until the earliest thing `stepEvents` does.
    ///
    /// Returns 1 — i.e. no deferral — in the two cases the guard cannot
    /// describe: a queued GP0 word, which drains on `cycle_debt` rather than
    /// on a wall-clock deadline, and an externally clocked timer 0/1, which
    /// consumes this call's return value and cannot take it in batches.
    fn nextDeadline(self: *const Self) i64 {
        if (self.eager or self.fifo_count > 0) return 1;
        const per_scanline: i64 = self.cyclesPerScanline();
        return @max(per_scanline - @as(i64, self.h_count), 1);
    }

    /// Applies everything `step` deferred, without firing anything.
    ///
    /// Re-arms from zero FIRST and unconditionally: the caller is about to
    /// read or write a register, and a deadline derived from the state before
    /// that write would otherwise stand. `cdrom.zig` shipped that bug and it
    /// moved four of ps1-golden's ten workloads.
    pub fn catchUp(self: *Self) void {
        self.event_countdown = 0;
        self.applyElapsed(self.pending_cycles);
        self.pending_cycles = 0;
    }

    /// The original per-instruction body, run once a deadline comes due.
    /// `delta_cycles` is THIS step's cycles, not the batch.
    fn stepEvents(self: *Self, delta_cycles: u32) GpuStepResult {
        @branchHint(.cold);
        self.applyElapsed(self.pending_cycles - delta_cycles);
        self.pending_cycles = 0;

        var result = GpuStepResult{
            .trigger_vblank_irq = false,
```

Then, at the end of the original body, immediately before `return result;`, insert:

```zig
        self.event_countdown = self.nextDeadline();
```

Everything between is unchanged. Do not touch a line of it.

- [ ] **Step 5: Settle the GPU on MMIO**

In `ps1-core/src/memory.zig`, at the two read sites (currently `:339-340`):

```zig
        if (paddr == Addr.gpu_data) {
            self.gpu.catchUp();
            return self.gpu.readData();
        }
        if (paddr == Addr.gpu_stat) {
            self.gpu.catchUp();
            return self.gpu.readStatus();
        }
```

At the two write sites (currently `:516,520`), add `self.gpu.catchUp();` as the first statement of each branch.

In the timer write path (currently `:510`), after `self.timers[timer_idx].write(offset, @truncate(value));`, add:

```zig
                // The GPU's guard batches the dotclock and hblank ticks it
                // returns; timers 0 and 1 consume those per call when they are
                // externally clocked. This write is the only thing that can
                // change that, so it is the only place the flag is maintained.
                self.gpu.catchUp();
                self.gpu.eager = self.timers[0].usesExternalClock() or
                    self.timers[1].usesExternalClock();
```

- [ ] **Step 6: Settle the GPU before each golden sample**

In `ps1-golden/src/main.zig`, extend the `catchUp` line added by `3a0784e`:

```zig
            bus.cdrom.catchUp();
            bus.gpu.catchUp();
```

- [ ] **Step 7: Run the unit tests**

Run: `zig build test -Doptimize=ReleaseFast`
Expected: PASS, including both new tests.

- [ ] **Step 8: Verify against the goldens — the real gate**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- verify`
Expected: exit 0, **all ten workloads OK**, goldens untouched (`git status` shows no change under `ps1-core/tests/goldens/`).

If it fails, **do not recapture.** Go to *Appendix A*.

- [ ] **Step 9: Prove the tests can fail**

A guard test that cannot fail pins nothing — this is not optional, and it is where the CDROM work found its second bug.

Temporarily widen the deadline to two scanlines (`per_scanline * 2 - h_count`), run `zig build test -Doptimize=ReleaseFast`, and confirm the vblank test FAILS. Then temporarily move `event_countdown = 0` in `catchUp` to after an `if (self.pending_cycles == 0) return;`, run `zig build trace-golden -Doptimize=ReleaseFast -- verify`, and confirm workloads diverge. Restore both.

- [ ] **Step 10: Measure**

Run, best of five, on a settled machine:

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin \
  "games/Croc - Legend of the Gobbos/Croc - Legend of the Gobbos.cue" 3000
```

Expected: better than 17.69 s / 2.83x. Record the number — Task 4 needs it. If it has barely moved, see *Appendix B*.

- [ ] **Step 11: Check the ROM suite has not regressed**

Run: `zig build test-roms-ja -Doptimize=ReleaseFast`
Expected: 12/17. (`test-roms-pl` is already red — see Global Constraints.)

- [ ] **Step 12: Commit**

```bash
zig fmt ps1-core/src/gpu/gpu.zig ps1-core/src/memory.zig ps1-golden/src/main.zig ps1-core/tests/gpu_test.zig
git add ps1-core/src/gpu/gpu.zig ps1-core/src/memory.zig ps1-golden/src/main.zig ps1-core/tests/gpu_test.zig
git commit -m "perf(gpu): defer the per-instruction tick to the next scanline"
```

---

### Task 2: Defer the timer tick

**Files:**
- Modify: `ps1-core/src/timer.zig:21-95`
- Modify: `ps1-golden/src/main.zig` (the `catchUp` block from Task 1)
- Modify: `build.zig` (`unit_test_files`)
- Test: **create** `ps1-core/tests/timer_test.zig`

**Interfaces:**
- Consumes: nothing from Task 1. The `Gpu.eager` flag Task 1 added already keeps the GPU out of the way whenever a timer is externally clocked, so these two are independent.
- Produces: `Timer.catchUp(self: *Timer) void`.

**Why the timers need no `applyElapsed` split, unlike the CDROM and the GPU.** `Timer.step`'s body has no block that consumes what an earlier block wrote — the target check and the overflow check both read the same `self.counter` written once at the top. So a batch is interchangeable with a stream of small steps **provided the batch crosses at most one boundary**, which is exactly what `nextDeadline` guarantees by taking the minimum of "ticks to target" and "ticks to overflow". Step 9 makes that claim testable rather than assumed.

**Why `read` and `write` must settle.** Unlike the CDROM's timers, `counter` is software-readable at any instruction (`Timer.read(0x0)`). It is also in `ps1-golden`'s state hash (`hashTimers`, all four fields).

- [ ] **Step 1: Write the failing tests**

Create `ps1-core/tests/timer_test.zig`:

```zig
const std = @import("std");
const ps1_core = @import("ps1_core");

const Timer = ps1_core.timer.Timer;

/// Sysclk source, IRQ on target, reset on target.
fn targetTimer(target: u32) Timer {
    var t = Timer{};
    t.write(0x4, (1 << 3) | (1 << 4)); // reset on target, IRQ on target
    t.write(0x8, target);
    return t;
}

test "a deferred counter reads back exactly what a per-cycle tick would leave" {
    var fine = targetTimer(10_000);
    var coarse = targetTimer(10_000);

    var i: u32 = 0;
    while (i < 5_000) : (i += 1) _ = fine.step(1);

    var j: u32 = 0;
    while (j < 1_000) : (j += 1) _ = coarse.step(5);

    // The read is what settles it; comparing the raw field would only be
    // comparing two accumulators.
    try std.testing.expectEqual(fine.read(0x0), coarse.read(0x0));
    try std.testing.expectEqual(@as(u32, 5_000), coarse.read(0x0));
}

test "the target IRQ fires on the exact tick, not at the end of a batch" {
    var t = targetTimer(1_000);

    var fired_at: u32 = 0;
    var i: u32 = 1;
    while (i <= 2_000) : (i += 1) {
        if (t.step(1) and fired_at == 0) fired_at = i;
    }
    try std.testing.expectEqual(@as(u32, 1_000), fired_at);
}

test "a batch never skips a boundary: target and overflow are not merged" {
    // No reset-on-target, so the counter runs on to overflow. A guard whose
    // deadline took only "ticks to overflow" would swallow the target
    // crossing inside one batch and report a single IRQ.
    var t = Timer{};
    t.write(0x4, (1 << 4) | (1 << 5)); // IRQ on target AND on overflow
    t.write(0x8, 0x100);

    var irqs: u32 = 0;
    var i: u32 = 0;
    while (i < 0x20000) : (i += 1) {
        if (t.step(1)) irqs += 1;
    }

    var batched = Timer{};
    batched.write(0x4, (1 << 4) | (1 << 5));
    batched.write(0x8, 0x100);

    var batched_irqs: u32 = 0;
    var j: u32 = 0;
    while (j < 0x20000 / 7) : (j += 1) {
        if (batched.step(7)) batched_irqs += 1;
    }

    try std.testing.expectEqual(irqs, batched_irqs);
    try std.testing.expect(irqs >= 2);
}

test "a mode write is applied to a settled counter" {
    // `write(0x4, ...)` resets the counter. Applied to a stale one, the reset
    // is right by luck and the prescaler is not.
    var t = Timer{};
    t.write(0x4, mode_sysclk_div8);
    var i: u32 = 0;
    while (i < 100) : (i += 1) _ = t.step(1);

    t.write(0x8, 50);
    try std.testing.expectEqual(@as(u32, 0), t.pending_ticks);
}

const mode_sysclk_div8: u32 = 0x0200;
```

- [ ] **Step 2: Wire the new test file into the build**

In `build.zig`, add the new file to the `unit_test_files` array at `:176-186`. The entries are full repo-relative paths, not bare names:

```zig
        "ps1-core/tests/mdec_test.zig",
        "ps1-core/tests/timer_test.zig",
    };
```

That array is what CLAUDE.md's *Quick commands* row calls "the 9 `unit_test_files`" — it becomes 10, so update that row in Task 4 as well.

- [ ] **Step 3: Run them and verify they fail**

Run: `zig build test -Doptimize=ReleaseFast`
Expected: FAIL — `Timer` has no member `pending_ticks`.

- [ ] **Step 4: Add the fields and the guard**

In `ps1-core/src/timer.zig`, add to the `Timer` struct after `prescale_counter: u32 = 0,`:

```zig
    /// Input ticks stepped past without applying them, and the input ticks
    /// until this counter next reaches its target or overflows.
    ///
    /// The same guard `cdrom.zig` and `gpu.zig` carry — read `pending_cycles`
    /// in the first of those, it holds the rules all three obey. What is
    /// different here, and worth knowing before touching `nextDeadline`: the
    /// body below has NO order-dependence between its blocks, so a batch is
    /// interchangeable with a stream of small steps and no `applyElapsed`
    /// split is needed. That holds only while the batch crosses at most one
    /// boundary, which is precisely what the deadline buys — take the minimum
    /// of the target and the overflow or `step` merges two IRQs into one.
    ///
    /// `counter` is software-readable at any instruction, so `read` and
    /// `write` settle first. `ps1-golden` hashes all four fields and settles
    /// before each sample for the same reason.
    pending_ticks: u32 = 0,
    event_countdown: i64 = 0,
```

Rename the existing `pub fn step` to `fn stepRaw`, leaving its body untouched, and add above it:

```zig
    pub inline fn step(self: *Timer, ticks: u32) bool {
        self.pending_ticks += ticks;
        self.event_countdown -= ticks;
        if (self.event_countdown > 0) return false;
        return self.stepEvents();
    }

    fn stepEvents(self: *Timer) bool {
        @branchHint(.cold);
        const ticks = self.pending_ticks;
        self.pending_ticks = 0;
        const irq = self.stepRaw(ticks);
        self.event_countdown = self.nextDeadline();
        return irq;
    }

    /// Input ticks until the counter next reaches its target or overflows,
    /// whichever comes first.
    ///
    /// BOTH must be in the minimum. Taking only the overflow lets a batch
    /// cross the target on its way there, and `stepRaw` detects one crossing
    /// per call — the second IRQ is then never raised at all.
    fn nextDeadline(self: *const Timer) i64 {
        const div: i64 = if ((self.mode & mode_clock_source_mask) == mode_clock_source_sysclk_div8)
            sysclk_div8_divisor
        else
            1;

        var counter_ticks: i64 = @as(i64, counter_overflow) - @as(i64, self.counter);
        if (self.target > 0 and self.counter < self.target) {
            counter_ticks = @min(counter_ticks, @as(i64, self.target) - @as(i64, self.counter));
        }

        return @max(counter_ticks * div - @as(i64, self.prescale_counter), 1);
    }

    /// Applies everything `step` deferred. Cannot raise an IRQ: the deadline
    /// guarantees no crossing falls inside the skipped window, so `stepRaw`
    /// here only moves the counter.
    ///
    /// Re-arms from zero FIRST and unconditionally, for the reason spelled out
    /// on `cdrom.zig`'s `catchUp`.
    pub fn catchUp(self: *Timer) void {
        self.event_countdown = 0;
        if (self.pending_ticks == 0) return;
        const ticks = self.pending_ticks;
        self.pending_ticks = 0;
        _ = self.stepRaw(ticks);
    }
```

- [ ] **Step 5: Settle on MMIO**

Make `catchUp()` the first statement of both `Timer.read` and `Timer.write`. `read` already takes `*Timer` (it mutates `mode`), so no signature change is needed.

- [ ] **Step 6: Settle before each golden sample**

In `ps1-golden/src/main.zig`, extend the block from Task 1:

```zig
            bus.cdrom.catchUp();
            bus.gpu.catchUp();
            for (&bus.timers) |*t| t.catchUp();
```

- [ ] **Step 7: Run the unit tests**

Run: `zig build test -Doptimize=ReleaseFast`
Expected: PASS, including all four new tests.

- [ ] **Step 8: Verify against the goldens**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- verify`
Expected: exit 0, all ten workloads OK, goldens untouched. If red, *Appendix A*.

- [ ] **Step 9: Prove the tests can fail**

Temporarily drop the target term from `nextDeadline` (leave only `counter_overflow - counter`), run `zig build test -Doptimize=ReleaseFast`, and confirm *"a batch never skips a boundary"* FAILS. Restore it.

- [ ] **Step 10: Measure and check the ROM suite**

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin \
  "games/Croc - Legend of the Gobbos/Croc - Legend of the Gobbos.cue" 3000
zig build test-roms-ja -Doptimize=ReleaseFast
```

Expected: better than Task 1's number; JA still 12/17. Record it.

- [ ] **Step 11: Commit**

```bash
zig fmt ps1-core/src/timer.zig ps1-core/tests/timer_test.zig ps1-golden/src/main.zig build.zig
git add ps1-core/src/timer.zig ps1-core/tests/timer_test.zig ps1-golden/src/main.zig build.zig
git commit -m "perf(timer): defer the per-instruction tick to the next crossing"
```

---

### Task 3: Copy VRAM only on the frames something reads it

**Files:**
- Modify: `ps1-macos/Sources/PS1/StreamQueue.swift:60-85` (the `resync` flag)
- Modify: `ps1-macos/Sources/PS1/EmulatorRunner.swift:186-210` (the publish block in `runLoop`)
- Modify: `ps1-macos/Sources/PS1/LiveRenderer.swift:46-80` (`drain`)
- Modify: `ps1-macos/Sources/PS1/MetalDisplayView.swift` (the `live.drain` closure in `draw`)
- Test: `ps1-macos/Tests/PS1Tests/StreamQueueTests.swift`

**Interfaces:**
- Consumes: nothing from Tasks 1-2. Swift only; **no Zig change at all**, and a diff touching `ps1-core`, `ps1-capi`, `ps1-golden` or `build.zig` is a defect in this task.
- Produces: `StreamQueue.resyncRequests: UInt64` (monotonic), `StreamQueue.serviceResync(upTo:)`, `EmulatorRunner.withNewestFrame` gaining a `vramFresh: Bool`.

**Read this before starting — it is ~1% and the blast radius is the delicate part of the app.** The measured cost of the copy is 3 GB/s of memcpy, about 1% of emulator-thread time; `nocopy` on `ps1-bench` reproduces it. What it touches is the resync protocol, whose race was only closed on 2026-08-30 and whose rules are written out at length in CLAUDE.md's *Metal backend* section. **If Tasks 1 and 2 landed and you are looking for the best next thing to do, this is not it** — it is here because it is on the list, and the honest recommendation is to do it only if the emulator thread specifically is the measured bottleneck. Skipping it and stopping after Task 2 is a legitimate outcome; say so in Task 4.

**The hazard, precisely.** If the producer skips the copy, the newest slot's VRAM belongs to an older frame. A resync then adopts a stale shadow and calls `discardThrough(seq:)` with an old seq; the queue holds four frames, so nothing matches `seq + 1`, the hole check raises resync again, and the renderer loops forever on a stale texture. So the producer must copy whenever a resync is outstanding, and the consumer must not consume a shadow that is not fresh.

**Why a counter and not the boolean.** Today's `clearResync()` is a store, not a compare-and-clear, and `LiveRenderer.drain` clears it *before* sampling precisely so a request raised in between is not swallowed. The new rule needs the consumer to clear only *after* it knows the shadow was fresh, which reintroduces exactly that swallow. A monotonic request counter plus a serviced watermark removes the race in both directions: a request raised after the read yields a higher value and is seen on the next frame.

- [ ] **Step 1: Write the failing test**

Append to `ps1-macos/Tests/PS1Tests/StreamQueueTests.swift`:

```swift
@Test func aRequestRaisedWhileServicingIsNotSwallowed() {
    let q = StreamQueue()
    // Fresh queues start needing a resync.
    #expect(q.needsResync)

    let seen = q.resyncRequests
    // The producer raises one while the consumer is mid-service.
    q.requestResync()
    q.serviceResync(upTo: seen)

    // Servicing the value read BEFORE the new request must not clear it.
    #expect(q.needsResync)

    q.serviceResync(upTo: q.resyncRequests)
    #expect(!q.needsResync)
}
```

- [ ] **Step 2: Run it and verify it fails**

Run: `ps1-macos/test.sh` (needs `zig build capi-lib` and `zig build metallib` built first — run those once, not per step).
Expected: FAIL to compile — no `resyncRequests`, no `serviceResync`.

- [ ] **Step 3: Replace the flag with a counter**

In `StreamQueue.swift`, replace the `resync` atomic and its three accessors:

```swift
    /// Resync requests, monotonic, raised by BOTH sides — the producer when a
    /// frame cannot be enqueued, the consumer when its texture has no valid
    /// base. Paired with a serviced watermark rather than cleared, because a
    /// clear is a store and would swallow a request raised between the
    /// consumer's read and its write. Starts at 1: a fresh queue faces a blank
    /// texture that bears no relation to any shadow.
    private let requests = Atomic<UInt64>(1)
    private let serviced = Atomic<UInt64>(0)

    var resyncRequests: UInt64 { requests.load(ordering: .acquiring) }
    var needsResync: Bool { resyncRequests > serviced.load(ordering: .acquiring) }

    func requestResync() {
        // `wrappingAdd`, not a load-modify-store: BOTH threads raise requests,
        // so this has to be a real atomic read-modify-write.
        _ = requests.wrappingAdd(1, ordering: .releasing)
    }

    /// Marks every request up to `upTo` served. Pass the value read BEFORE the
    /// shadow was sampled, never `resyncRequests` re-read afterwards.
    func serviceResync(upTo: UInt64) {
        serviced.store(upTo, ordering: .releasing)
    }
```

Delete `clearResync()`. Update the one call in `LiveRenderer.drain` in Step 5.

- [ ] **Step 4: Copy VRAM only when something will read it**

In `EmulatorRunner.swift`, add beside the `seqs` array:

```swift
    /// The seq each slot's VRAM actually belongs to. Not the same as `seqs`:
    /// `displays`/`seqs` are published every frame because the display pass
    /// needs them, while the 1 MB VRAM copy is skipped on the frames nothing
    /// reads it.
    private var vramSeqs = [UInt64](repeating: 0, count: 3)
```

Replace the `core.copyVRAM(into: slots[next])` line and the block around it:

```swift
            let next = (newest.load(ordering: .relaxed) + 1) % 3
            let d = core.display()

            // Three readers, and only these three: a pending resync, a 24bpp
            // frame (the display pass scans those out of the shadow), and the
            // debug oracle. Everything else has been reading the GPU's own
            // texture since Phase D1.
            let wantVram = streams.needsResync || d.depth24 != 0 || diagnosticsEnabled
            if wantVram {
                core.copyVRAM(into: slots[next])
                vramSeqs[next] = frameSeq
            } else {
                vramSeqs[next] = vramSeqs[newest.load(ordering: .relaxed)]
            }

            displayLock.lock()
            displays[next] = d
            seqs[next] = frameSeq
            displayLock.unlock()
            newest.store(next, ordering: .releasing)
```

Add the diagnostics flag near the other stored properties:

```swift
    /// Both debug seams read the shadow every frame, so neither can run
    /// against a conditionally-copied one. Read once: `ProcessInfo` on the
    /// emulator thread's hot path is not free.
    private let diagnosticsEnabled =
        ProcessInfo.processInfo.environment["PS1_LIVE_DIFF"] == "1"
            || ProcessInfo.processInfo.environment["PS1_SOFTWARE_DISPLAY"] == "1"
```

Note `vramSeqs[next]` copies the previous slot's value on a skip, so a slot never claims VRAM it does not hold.

- [ ] **Step 5: Consume a resync only when the shadow is fresh**

Widen `withNewestFrame`'s closure to carry freshness:

```swift
    func withNewestFrame(_ body: (UnsafePointer<UInt16>, Ps1Display, UInt64, Bool) -> Void) {
        let i = newest.load(ordering: .acquiring)
        displayLock.lock()
        let d = displays[i]
        let s = seqs[i]
        let vs = vramSeqs[i]
        displayLock.unlock()
        body(UnsafePointer(slots[i]), d, s, vs == s)
    }
```

In `LiveRenderer.drain`, replace the resync branch:

```swift
    func drain(from queue: StreamQueue, shadow: () -> ([UInt16], UInt64, Bool)) {
        guard queue.needsResync else {
            queue.drain { slot in self.execute(slot) }
            return
        }

        // Read the request count BEFORE sampling. Servicing a count re-read
        // afterwards would clear a request the producer raised in between.
        let servicing = queue.resyncRequests

        let (pixels, seq, fresh) = shadow()
        // The producer skips the VRAM copy on frames nothing reads it, and it
        // only learns of this request at its next frame boundary. Present what
        // the texture already holds for one more frame rather than adopting a
        // stale shadow — `discardThrough` would find no frame at `seq + 1`,
        // raise the resync again, and loop there forever.
        guard fresh else { return }

        vram.uploadNative(pixels)
        lastExecutedSeq = seq
        queue.serviceResync(upTo: servicing)

        let next = queue.discardThrough(seq: seq)
        if let next, next != seq &+ 1 { queue.requestResync() }

        queue.drain { slot in self.execute(slot) }
    }
```

- [ ] **Step 6: Pass freshness through the call site**

In `MetalDisplayView.swift`'s `draw`, update the `live.drain` closure and the two other `withNewestFrame` calls to the four-argument closure:

```swift
            live.drain(from: runner.streams) {
                var out = [UInt16](repeating: 0, count: EmulatorRunner.vramCount)
                var seq: UInt64 = 0
                var fresh = false
                self.runner.withNewestFrame { vram, _, s, f in
                    seq = s
                    fresh = f
                    guard f else { return }
                    out.withUnsafeMutableBufferPointer { dst in
                        dst.baseAddress!.update(from: vram, count: EmulatorRunner.vramCount)
                    }
                }
                return (out, seq, fresh)
            }
```

The other two call sites take `{ vram, display, _, _ in ... }` and `{ vram, _, seq, _ in ... }` respectively — the 24bpp upload and the `PS1_LIVE_DIFF` oracle both run only when `diagnosticsEnabled` or `depth24` forced a copy, so their VRAM is fresh by construction.

- [ ] **Step 7: Run the Swift suite**

Run: `ps1-macos/test.sh`
Expected: **TEST SUCCEEDED**, 245+ tests. Nothing else may go red — in particular the resync tests in `StreamQueueTests` and `LiveRendererScaleTests`.

- [ ] **Step 8: Confirm no Zig changed**

Run: `git status --short`
Expected: only files under `ps1-macos/`.

- [ ] **Step 9: Exercise it in the real app**

Run: `zig build macos && open zig-out/PS1.app`

Boot a game, let an FMV play (Croc's intro is 24bpp — the conditional copy must not break it), then eject back to the library and open a game again (that path rebuilds the runner and forces a resync). Then change `Video ▸` to 4x while playing: that rebuilds `MetalVram` with a blank texture and requests a resync against a **live** producer, which is the exact case Step 5 guards. A picture that stays blank or freezes there is this task's bug.

- [ ] **Step 10: Commit**

```bash
git add ps1-macos
git commit -m "perf(macos): copy VRAM only on the frames something reads it"
```

---

### Task 4: Document the result

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: the three measured numbers recorded in Tasks 1, 2 and (if done) 3.

- [ ] **Step 1: Record the deferral pattern as a cross-cutting rule**

CLAUDE.md's *Architecture: the CPU is the master clock* section says `tickPeripherals` fans cycles out to every device in a fixed order. That is now only half true — most calls return from a guard. Add to that section, after the list of the fan-out order:

```markdown
**Most of that fan-out no longer happens.** `spu`, `gpu`, the three timers and
`cdrom` are each called once per emulated instruction, and in the steady state
each has nothing to do. `cdrom`, `gpu` and `timer` therefore carry a
`pending_cycles`/`event_countdown` guard: `step` is an inline three-instruction
compare and the body runs once per deadline. The order above still holds for
the calls that get through, and it is still load-bearing.

The rules are written out on `cdrom/cdrom.zig`'s `pending_cycles` — read that
before touching any of the three. The two that were shipped broken, once each:
a body whose blocks are ORDER-DEPENDENT must not be handed a whole batch (hence
the `applyElapsed`/`stepEvents` split), and `catchUp` must re-arm from zero
FIRST and unconditionally, before any early return.

`ps1-golden` settles all three with `catchUp()` before each sample, and their
guard fields are deliberately absent from the state hash. That is what let
every one of these changes verify against goldens captured before it, rather
than being recaptured around it — the only evidence available that a
pure-performance change is pure.
```

- [ ] **Step 2: Update the per-subsystem entries**

In the **GPU** paragraph of *Per-subsystem cheat-sheet*, append:

```markdown
**`Gpu.step`'s deadline is ONE SCANLINE and must not be widened.** `is_vblank`,
`v_count` and `is_even_field` change only at a scanline boundary, so settling at
every boundary keeps all three exact at every instruction — which is what lets
`ps1_run_frame` and the wasm frame loop poll `is_vblank` directly, with no
`catchUp` they have no way to call. The guard also refuses to defer at all while
the GP0 FIFO holds a word (that drains on `cycle_debt`, not on a deadline) or
while `eager` is set, which `memory.zig` maintains from the timer-mode write:
`step` RETURNS the dotclock and hblank ticks an externally clocked timer 0/1
consumes, and those cannot be handed over in batches.
```

In the **Memory / interrupts / timers / SIO** bullet list, add:

```markdown
- **A timer's deadline is the MINIMUM of "ticks to target" and "ticks to
  overflow", and dropping either merges two IRQs into one.** `Timer.step`
  detects one target crossing per call, so a batch that runs from below the
  target all the way past 0xFFFF reports a single interrupt where hardware
  raises two. Unlike `cdrom`/`gpu` the body needs no `applyElapsed` split —
  nothing in it consumes what an earlier block wrote — but that equivalence
  holds only while the batch crosses at most one boundary. `counter` is
  software-readable at any instruction, so `read` and `write` settle first.
```

- [ ] **Step 3: Correct the test counts**

Task 2 added a tenth unit-test file. CLAUDE.md's *Quick commands* row for `zig build test` says "**15 test binaries** — the 9 `unit_test_files`". Make it 16 and 10.

- [ ] **Step 4: Update the measured throughput**

Replace the figures in this plan's *Measured baseline* section with the final ones, and note in CLAUDE.md's `ps1-bench` row what the current number is, so the next person has a baseline to regress against.

If Task 3 was skipped, say so explicitly in this plan — an unticked box reads as unfinished work, and "measured at ~1%, deliberately not taken" is a decision worth recording.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs/superpowers/plans/2026-08-30-emulator-cpu-optimization.md
git commit -m "docs: record the deferred-tick pattern and the new baseline"
```

---

## Appendix A: when `verify` goes red

This will happen. It happened twice on the CDROM task, and both times the harness was right. The method that worked:

1. **Read which REGIONS moved**, not just which workloads. `verify` prints `want`/`got` per region. `cdrom` alone moving means a representation change; `ram` and `cpu` moving too means real divergence that has already propagated into the game.
2. **Read the instruction number.** All ten workloads failing at the same early sample is a boot-phase divergence and is usually one clear bug. A failure at 140M+ in a subset is subtler — often something whose error is masked most of the time.
3. **Compare the want/got pairs across workloads.** Identical pairs in several games mean they were all still in the same state — i.e. the divergence is in shared BIOS-driven behaviour, not game-specific.
4. **Narrow with `--filter=croc --instructions=<n>`** once you have a hypothesis. `--interval` tightens sampling but note the committed goldens are at 2.5M, so a different interval has nothing to compare against — use it only with `capture` into a scratch `--out=` directory, never over the committed goldens.
5. **Suspect the two known shapes first**: a deadline missing from `nextDeadline` (the event never fires), and a body block consuming what an earlier block wrote (the batch is charged to a freshly-armed timer).

**Never respond to a red `verify` by running `capture`.** The goldens are the only thing distinguishing a working optimization from a subtly broken one.

## Appendix B: when the measurement disappoints

If a guard lands and `ps1-bench` barely moves, check in this order:

1. **Is `step` actually inlined?** `pub inline fn` is a request the optimizer can still decline for a large body. Re-profile with `sample` and look for the function by name — if `gpu.gpu.Gpu.step` appears in the self-time list at all, it is not inlined and the call overhead is still being paid. Half the CDROM win was the call, not the work.
2. **Is the guard actually deferring?** Add a temporary counter of `stepEvents` entries per frame and print it. The GPU should settle roughly once per scanline (263 per frame NTSC), the timers far less. If it is settling every instruction, `nextDeadline` is returning 1 — check the `eager` bail and the FIFO condition.
3. **Did you measure on a settled machine?** A run started right after `trace-golden` reads about 15% slow. Take the best of five.
4. **Is the bench workload reaching the code you changed?** 3000 frames of Croc from cold boot is roughly half BIOS boot. A GPU change shows up throughout; a change that only matters in-game may need a longer run.

**If the combined guard is what is left:** the three guards are independent compares in `tickPeripherals`, one per device. Hoisting them into a single `peripheral_countdown` on `Cpu` — the minimum across all of them — would replace three compares with one. That is a further, larger refactor and is deliberately not in this plan; measure whether the three compares are actually costing anything before attempting it.
