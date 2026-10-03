# CPU recompiler, Plan 1: the scheduler. Implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the per-step fan-out to every device with one machine-wide
countdown, so a `Cpu.step()` with nothing due costs one subtract and one
compare. The interpreter stays bit-exact: zero golden movement.

**Architecture:** A new `cpu/scheduler.zig` keeps `downcount`, the CPU cycles
until the earliest device deadline. That value is the minimum of the countdowns
the GPU, timers and CD-ROM already keep, plus the SPU's 768-cycle sample, SIO's
/ACK timer and the DMA block-gap and chop counters. A step that ends short of
it only adds its cycles to `pending`. Every MMIO access first hands `pending`
to the devices (`sync`), so a register read sees exactly what a per-step tick
would have left. The slow path is today's `tickPeripherals` body, unchanged
and in the same order.

**Tech Stack:** Zig 0.16.0, `ps1-core`, `ps1-golden` (trace-golden), `ps1-bench`, xctrace.

**Spec:** `docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md`
(section "Stage 1: the scheduler", and Plans → 1).

## Global Constraints

- `zig version` is **0.16.0**.
- **Zero golden movement.** `trace-golden -- verify`, `-- savestate`,
  `-- stream-verify` and `-- pgxp` stay green on the interpreter with **no
  recapture**. A moved golden is a bug in this plan, never a behaviour change
  to capture.
- **No savestate format change.** No section version bump. The `CPU ` section
  and `state_hash.zig`'s `hashCpu` write the same bytes in the same order.
- Device order in the fan-out stays **SPU → GPU → SIO → Timer0/1/2 → CD-ROM →
  DMA CPU window**.
- **SIO's term is a step count used as a cycle count. Do not "convert" it.**
- `ps1-trace` and `ps1-debug` get no changes.
- No file in `ps1-core/src` over ~600 lines (`memory.zig` is already over this
  limit and only gains a few lines here).
- Commits go directly on `master`, one per task, and the **commit message is the
  title line only**: no body and no trailer. **Never `git push`.**
- Run `zig fmt` on every touched `.zig` file before committing.

### Deliberate departures from the spec (flag these in review, do not "fix" them)

1. **The scheduler state lives on `Bus` (`bus.sched`), not on `Cpu`.** The spec
   says `Cpu.downcount`. But `Bus`'s MMIO dispatch has to call `sync()`, and
   `Bus` has no pointer to the `Cpu` (`Cpu` is a value type the frontends own).
   `gpu_clock_frac` moves along with it, because `sync()` converts cycles for
   the GPU. The `CPU ` savestate section and `hashCpu` still write it at the
   same position, so no byte moves.
2. **There is no `pending_cpu_window`.** In this plan a DMA-stalled step
   **always** takes the slow path. A DMA word can arm a block gap, start a chop
   CPU turn or finish a transfer, and none of those passes through an MMIO
   access that would force a recompute. As a result, every cycle in `pending`
   was spent by a non-stalled step, and `pending` *is* the CPU-window count. The
   spec's rule that a stalled step adds nothing to the CPU window holds because
   of how the code is built, not because a second counter enforces it.
3. **"Sync before an MMIO access, force one after" is one call.** `sync()`
   hands over `pending` and sets `downcount = 0`. The step that is still
   running then takes the slow path, which recomputes `downcount` *after* the
   access has moved whatever deadline it moved.

## Review Focus

1. **Host-side pokes between steps.** `ps1-golden`'s sample point calls
   `cdrom/gpu/timer.catchUp()` directly. Each of those zeroes a device
   countdown that `downcount` does not know about. Expected: the next step
   takes the slow path and nothing fires late. Pinned in Task 2: the
   equivalence test does the same catch-ups at every checkpoint.
2. **Timer 0 on the dotclock (`gpu.eager`).** The GPU's deadline is 1, so every
   step is a slow step. Expected: still exact. Pinned in Task 2 by a second
   equivalence run.
3. **Two MMIO accesses in one step.** Examples: a CD-ROM word store hits the
   port once per lane, and an SPU word access touches two registers. The
   second `sync()` has nothing pending and must not step any device by 0
   cycles: `gpu.step(0)` with a zeroed countdown fires `stepEvents`. Pinned in
   Task 2.
4. **A savestate taken mid-window, loaded into a different `Bus`.** Expected:
   the restored machine continues bit-identically. Pinned in Task 2, and by the
   `trace-golden -- savestate` gate in Task 3.
5. **A DMA-stalled step after a run of fast steps.** Expected: it hands the
   backlog to the devices before its own cycles and never adds to `pending`.
   Pinned in Task 2: the equivalence loop asserts it on every stalled step.

---

## File structure

| File | Change | Responsibility |
| --- | --- | --- |
| `ps1-core/src/cpu/scheduler.zig` | **Create** | `Scheduler` state, `tick`, `sync`, the fan-out (`advance`) and `deadline` |
| `ps1-core/src/cpu/cpu.zig` | Modify | `step()` calls `scheduler.tick`; `tickPeripherals` shrinks to the clocks; `gpu_clock_frac` removed |
| `ps1-core/src/memory.zig` | Modify | `sched` field; `sync()` at the top of the I/O-port case in `read`/`write` and in `dmaRead32`'s SPU branch |
| `ps1-core/src/sio.zig` | Modify | `advance(steps)`; `step()` becomes `advance(1)` |
| `ps1-core/src/dma.zig` | Modify | `cpuWindowDeadline()` |
| `ps1-core/src/root.zig` | Modify | re-export `scheduler` |
| `ps1-core/src/savestate/savestate.zig` | Modify | `save` syncs first |
| `ps1-core/src/savestate/cpu_state.zig` | Modify | `gpu_clock_frac` via `bus.sched`; load resets the scheduler |
| `ps1-golden/src/state_hash.zig` | Modify | `gpu_clock_frac` via `bus.sched` |
| `ps1-golden/src/main.zig` | Modify | sample point syncs before its catch-ups |
| `ps1-golden/src/savestate_roundtrip_test.zig` | Modify | same |
| `ps1-core/tests/scheduler_test.zig` | **Create** | equivalence against a forced per-step machine, plus targeted cases |
| `ps1-core/tests/sio_test.zig`, `dma_test.zig`, `savestate_test.zig` | Modify | device accessor tests; the `gpu_clock_frac` path |
| `build.zig` | Modify | add `scheduler_test.zig` to `unit_test_files` |
| `CLAUDE.md`, `.claude/skills/ps1-core-subsystems/SKILL.md` | Modify | the new clock model, test counts, measured numbers |

---

### Task 1: Device-side accessors (SIO batch advance, DMA window deadline)

**Files:**
- Modify: `ps1-core/src/sio.zig:519-530` (`step`)
- Modify: `ps1-core/src/dma.zig` (new fn after `tickCpuWindow`, ~line 433)
- Test: `ps1-core/tests/sio_test.zig`, `ps1-core/tests/dma_test.zig`

**Interfaces:**
- Produces: `pub fn advance(self: *Sio, steps: u32) bool` (returns the IRQ7
  level, as `step()` does). `step()` stays and is `advance(1)`.
- Produces: `pub fn cpuWindowDeadline(self: *const Dma) i64`: the CPU-window
  cycles until a block gap or chop CPU turn ends, or `std.math.maxInt(i64)`
  when nothing is counting.

- [ ] **Step 0: Record the baseline commit for Task 4's A/B**

Run: `git rev-parse HEAD > /private/tmp/claude-501/scheduler-base-sha && cat /private/tmp/claude-501/scheduler-base-sha`
Expected: one SHA (the commit before any code change in this plan).

- [ ] **Step 1: Write the failing SIO test**

Append to `ps1-core/tests/sio_test.zig`:

```zig
test "advancing /ACK by a batch of steps lands it on the step single steps would" {
    // The scheduler hands SIO a whole run of steps at once. The /ACK must
    // still land on the same step a one-at-a-time count reaches it.
    const a = try Bus.init(std.testing.allocator);
    defer a.deinit(std.testing.allocator);
    const b = try Bus.init(std.testing.allocator);
    defer b.deinit(std.testing.allocator);
    const c = try Bus.init(std.testing.allocator);
    defer c.deinit(std.testing.allocator);

    a.write8(JOY_DATA, 0x01);
    b.write8(JOY_DATA, 0x01);
    c.write8(JOY_DATA, 0x01);
    const n = stepsToIrq(a);

    try expect(!b.sio.advance(n - 1));
    try expect(b.sio.advance(1));
    try expectEqual(a.sio.irq_timer, b.sio.irq_timer);
    try expectEqual(a.sio.ack, b.sio.ack);

    // A batch that runs past the deadline still raises it.
    try expect(c.sio.advance(n + 100));
    try expectEqual(@as(u32, 0), c.sio.irq_timer);
}
```

- [ ] **Step 2: Write the failing DMA test**

Append to `ps1-core/tests/dma_test.zig`:

```zig
test "cpuWindowDeadline names a mode-1 block gap, and nothing when idle" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const bus = ctx.bus;

    try expectEqual(@as(i64, std.math.maxInt(i64)), bus.dma.cpuWindowDeadline());

    bus.write32(0x1F8010F0, 0x00080000); // DPCR: channel 4 enabled
    bus.write32(0x1F8010C0, 0x1000); // MADR
    bus.write32(0x1F8010C4, 0x00040010); // 4 blocks of 16 words
    bus.write32(0x1F8010C8, 0x01000201); // from RAM, sync mode 1, start

    // Move one block: the SPU channel then hands the bus back for a gap.
    while (bus.dma.isCpuStalled(bus)) _ = bus.dma.step(bus);
    const gap = bus.dma.channels[4].block_gap_counter;
    try std.testing.expect(gap > 0);
    try expectEqual(@as(i64, gap), bus.dma.cpuWindowDeadline());

    bus.dma.tickCpuWindow(gap - 1);
    try expectEqual(@as(i64, 1), bus.dma.cpuWindowDeadline());
}
```

- [ ] **Step 3: Run both and verify they fail to compile**

Run: `zig build test -Dtest-filter="advancing /ACK" 2>&1 | tail -5; zig build test -Dtest-filter="cpuWindowDeadline" 2>&1 | tail -5`
Expected: compile errors `no field or member function named 'advance'` and `... 'cpuWindowDeadline'`.

- [ ] **Step 4: Implement `Sio.advance`**

Replace `step` in `ps1-core/src/sio.zig` (currently lines 519-530, the doc
comment included) with:

```zig
    /// Advances the /ACK deferral by `steps` `Cpu.step()` calls and returns
    /// the IRQ7 level (level, like every other device here: software clears
    /// it via JOY_CTRL bit 4). The scheduler hands over a whole run of steps
    /// at once, and the /ACK lands on the same step either way: the delay
    /// counts steps, not cycles, which is why `pad_ack_delay` and
    /// `card_ack_delay` are step counts.
    pub fn advance(self: *Self, steps: u32) bool {
        if (self.irq_timer > 0) {
            if (steps >= self.irq_timer) {
                self.irq_timer = 0;
                self.irq = true;
                self.ack = false;
            } else {
                self.irq_timer -= steps;
            }
        }
        return self.irq;
    }

    pub fn step(self: *Self) bool {
        return self.advance(1);
    }
```

- [ ] **Step 5: Implement `Dma.cpuWindowDeadline`**

Insert in `ps1-core/src/dma.zig` directly after `tickCpuWindow`:

```zig
    /// CPU-window cycles until a block gap or a chopping CPU turn runs out:
    /// the instant `isCpuStalled` can next change without a register write.
    /// `tickCpuWindow` ends both on the call that brings them to zero, so the
    /// countdown is the counter itself.
    pub fn cpuWindowDeadline(self: *const Self) i64 {
        var d: i64 = std.math.maxInt(i64);
        if (!self.busy_hint) return d;
        for (&self.channels) |*c| {
            if (c.block_gap_counter > 0) d = @min(d, c.block_gap_counter);
            if (c.chop_dma_window > 0 and c.chop_is_cpu_turn) d = @min(d, c.chop_counter);
        }
        return d;
    }
```

- [ ] **Step 6: Run both tests and verify they pass**

Run: `zig build test -Dtest-filter="advancing /ACK" && zig build test -Dtest-filter="cpuWindowDeadline"`
Expected: exit 0.

- [ ] **Step 7: Format and commit**

```bash
zig fmt ps1-core/src/sio.zig ps1-core/src/dma.zig ps1-core/tests/sio_test.zig ps1-core/tests/dma_test.zig
git add ps1-core/src/sio.zig ps1-core/src/dma.zig ps1-core/tests/sio_test.zig ps1-core/tests/dma_test.zig
git commit -m "feat(core): SIO batch advance and DMA CPU-window deadline"
```

---

### Task 2: The scheduler

This is one task, because no smaller piece is correct on its own. A fast path
without the MMIO `sync` makes register reads stale, and an MMIO `sync` without
the fast path does nothing.

**Files:**
- Create: `ps1-core/src/cpu/scheduler.zig`
- Create: `ps1-core/tests/scheduler_test.zig`
- Modify: `build.zig:190-204` (`unit_test_files`)
- Modify: `ps1-core/src/cpu/cpu.zig:56-61` (field), `:93-99` (stalled branch), `:200-249` (`tickPeripherals`)
- Modify: `ps1-core/src/memory.zig` (import, field near `:190`, `read` `:626`, `write` `:753`, `dmaRead32` `:249`)
- Modify: `ps1-core/src/root.zig`
- Modify: `ps1-core/src/savestate/savestate.zig:68` (`save`)
- Modify: `ps1-core/src/savestate/cpu_state.zig:30,56`
- Modify: `ps1-golden/src/state_hash.zig:182`
- Modify: `ps1-golden/src/main.zig:528-538`
- Modify: `ps1-golden/src/savestate_roundtrip_test.zig:39-42`
- Modify: `ps1-core/tests/savestate_test.zig:140,156`

**Interfaces:**
- Consumes (Task 1): `Sio.advance(steps: u32) bool`, `Dma.cpuWindowDeadline() i64`.
- Produces (Plans 2-7 build on these exact names):
  - `ps1_core.scheduler.Scheduler` with fields `downcount: i64`,
    `pending: u32`, `pending_steps: u32`, `gpu_clock_frac: u32`, all
    defaulting to 0.
  - `Bus.sched: Scheduler`.
  - `pub inline fn tick(bus: *Bus, delta: u32, cpu_window: bool) void`: one
    `Cpu.step()`'s cycles. `cpu_window == false` marks a DMA-stalled step.
  - `pub fn sync(bus: *Bus) void`: hands `pending` to the devices and sets
    `downcount = 0`.

- [ ] **Step 1: Write the failing scheduler tests**

Create `ps1-core/tests/scheduler_test.zig`:

```zig
//! The scheduler must be invisible. Every test here runs a machine that
//! defers device ticks against one forced onto the slow path every step,
//! which is exactly the old per-step `tickPeripherals`, and requires them to
//! agree at every step and in every byte of a savestate.

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const ps1_core = @import("ps1_core");
const Bus = ps1_core.memory.Bus;
const Cpu = ps1_core.cpu.Cpu;
const scheduler = ps1_core.scheduler;
const savestate = ps1_core.savestate;

const Machine = struct {
    bus: *Bus,
    cpu: Cpu,

    fn init() !Machine {
        const bus = try Bus.init(std.testing.allocator);
        return .{ .bus = bus, .cpu = Cpu.init(bus) };
    }

    fn deinit(m: *Machine) void {
        m.bus.deinit(std.testing.allocator);
    }

    /// One step under the old model: every device ticked on every step.
    fn stepPerStep(m: *Machine) void {
        m.bus.sched.downcount = 0;
        m.cpu.step();
    }

    /// What `ps1-golden` does before hashing a sample.
    fn settle(m: *Machine) void {
        scheduler.sync(m.bus);
        m.bus.cdrom.catchUp();
        m.bus.gpu.catchUp();
        for (&m.bus.timers) |*t| t.catchUp();
    }
};

/// Arms every deadline the scheduler takes a term from: timer 0 and timer 2
/// on the system clock (timer 2 prescaled), timer 1 on hblank, a pad
/// transfer waiting on /ACK, and a paced mode-1 SPU DMA whose block gaps
/// hand the bus back to the CPU. The BIOS is zeroed, so the CPU retires nops
/// with I_MASK clear and never takes an interrupt.
fn armSystemClock(bus: *Bus) void {
    bus.write32(0x1F801108, 333); // timer 0 target
    bus.write32(0x1F801104, 0x0058); // sysclk; reset + IRQ on target, repeat
    armCommon(bus);
}

/// The same, but timer 0 counts the dotclock, which keeps the GPU eager:
/// every step is a slow step, and the result must still be exact.
fn armDotclock(bus: *Bus) void {
    bus.write32(0x1F801108, 333);
    bus.write32(0x1F801104, 0x0158); // dotclock
    armCommon(bus);
}

fn armCommon(bus: *Bus) void {
    bus.write32(0x1F801118, 3); // timer 1 target
    bus.write32(0x1F801114, 0x0158); // hblank
    bus.write32(0x1F801128, 100); // timer 2 target
    bus.write32(0x1F801124, 0x0258); // sysclk/8
    bus.write8(0x1F801040, 0x01); // select the pad: arms /ACK
    for (0..64) |i| bus.write32(@intCast(0x1000 + i * 4), @intCast(i));
    bus.write32(0x1F8010F0, 0x00080000); // DPCR: channel 4 enabled
    bus.write32(0x1F8010C0, 0x1000); // MADR
    bus.write32(0x1F8010C4, 0x00040010); // 4 blocks of 16 words
    bus.write32(0x1F8010C8, 0x01000201); // from RAM, sync mode 1, start
}

fn expectSameState(a: *Machine, b: *Machine) !void {
    const alloc = std.testing.allocator;
    const n = try savestate.save(&a.cpu, null);
    try expectEqual(n, try savestate.save(&b.cpu, null));
    const x = try alloc.alloc(u8, n);
    defer alloc.free(x);
    const y = try alloc.alloc(u8, n);
    defer alloc.free(y);
    _ = try savestate.save(&a.cpu, x);
    _ = try savestate.save(&b.cpu, y);
    try std.testing.expectEqualSlices(u8, x, y);
}

fn expectEquivalent(comptime arm: fn (*Bus) void) !void {
    var ref = try Machine.init();
    defer ref.deinit();
    var sch = try Machine.init();
    defer sch.deinit();
    arm(ref.bus);
    arm(sch.bus);

    var i: u32 = 0;
    while (i < 200_000) : (i += 1) {
        ref.stepPerStep();
        const stalled = sch.bus.dma.isCpuStalled(sch.bus);
        sch.cpu.step();

        try expectEqual(ref.bus.interrupts.stat, sch.bus.interrupts.stat);
        try expectEqual(ref.cpu.cycles, sch.cpu.cycles);
        // A DMA-stalled step hands the backlog over and never defers.
        if (stalled) try expectEqual(@as(u32, 0), sch.bus.sched.pending);

        if (i % 20_000 == 0) {
            ref.settle();
            sch.settle();
            try expectSameState(&ref, &sch);
        }
    }
    try expectSameState(&ref, &sch);

    // The run reached every device it armed, so it compared something.
    const stat = sch.bus.interrupts.stat;
    try expect(stat & (1 << 0) != 0); // vblank
    try expect(stat & (1 << 5) != 0); // timer 1
    try expect(stat & (1 << 6) != 0); // timer 2
    try expect(stat & (1 << 7) != 0); // controller
    try expect(!sch.bus.dma.channels[4].transfer_active);
}

test "a deferring machine matches one that ticks every device every step" {
    try expectEquivalent(armSystemClock);
}

test "timer 0 on the dotclock keeps every step slow and still exact" {
    try expectEquivalent(armDotclock);
}

test "an idle machine defers its device ticks" {
    var m = try Machine.init();
    defer m.deinit();
    m.cpu.step(); // power-on downcount is 0: the slow path arms it
    m.cpu.step();
    m.cpu.step();
    try expectEqual(@as(u32, 2), m.bus.sched.pending_steps);
    try expect(m.bus.sched.pending > 0);
}

test "an MMIO read sees the deferred cycles" {
    var ref = try Machine.init();
    defer ref.deinit();
    var sch = try Machine.init();
    defer sch.deinit();
    for (0..50) |_| {
        ref.stepPerStep();
        sch.cpu.step();
    }
    try expect(sch.bus.sched.pending > 0);
    try expectEqual(ref.bus.read32(0x1F801120), sch.bus.read32(0x1F801120)); // timer 2 counter
    try expectEqual(@as(u32, 0), sch.bus.sched.pending);
    try expectEqual(@as(i64, 0), sch.bus.sched.downcount);
}

test "a second sync in the same step steps no device" {
    var m = try Machine.init();
    defer m.deinit();
    for (0..10) |_| m.cpu.step();
    scheduler.sync(m.bus);
    m.bus.gpu.catchUp(); // as the GPU's own register access does
    const gpu_countdown = m.bus.gpu.event_countdown;
    const spu_acc = m.bus.spu.cycle_accumulator;
    scheduler.sync(m.bus);
    try expectEqual(gpu_countdown, m.bus.gpu.event_countdown);
    try expectEqual(spu_acc, m.bus.spu.cycle_accumulator);
}

test "a savestate load resets the scheduler and keeps the GPU clock carry" {
    var m = try Machine.init();
    defer m.deinit();
    for (0..37) |_| m.cpu.step();

    const alloc = std.testing.allocator;
    const buf = try alloc.alloc(u8, try savestate.save(&m.cpu, null));
    defer alloc.free(buf);
    _ = try savestate.save(&m.cpu, buf);
    const frac = m.bus.sched.gpu_clock_frac;

    for (0..13) |_| m.cpu.step();
    try expect(m.bus.sched.pending > 0);

    try savestate.load(&m.cpu, buf);
    try expectEqual(@as(u32, 0), m.bus.sched.pending);
    try expectEqual(@as(u32, 0), m.bus.sched.pending_steps);
    try expectEqual(@as(i64, 0), m.bus.sched.downcount);
    try expectEqual(frac, m.bus.sched.gpu_clock_frac);
}

test "a savestate taken mid-window resumes identically on another bus" {
    var ref = try Machine.init();
    defer ref.deinit();
    var sch = try Machine.init();
    defer sch.deinit();
    armSystemClock(ref.bus);
    armSystemClock(sch.bus);
    for (0..30_001) |_| {
        ref.stepPerStep();
        sch.cpu.step();
    }

    const alloc = std.testing.allocator;
    const buf = try alloc.alloc(u8, try savestate.save(&sch.cpu, null));
    defer alloc.free(buf);
    _ = try savestate.save(&sch.cpu, buf);

    var restored = try Machine.init();
    defer restored.deinit();
    try savestate.load(&restored.cpu, buf);

    for (0..30_000) |_| {
        ref.stepPerStep();
        restored.cpu.step();
        try expectEqual(ref.bus.interrupts.stat, restored.bus.interrupts.stat);
    }
    ref.settle();
    restored.settle();
    try expectSameState(&ref, &restored);
}
```

Add it to `build.zig`'s `unit_test_files` after `savestate_test.zig`:

```zig
        "ps1-core/tests/savestate_test.zig",
        "ps1-core/tests/scheduler_test.zig",
```

- [ ] **Step 2: Run it and verify it fails**

Run: `zig build test -Dtest-filter="scheduler" 2>&1 | tail -5`
Expected: compile error: `root source file struct 'root' has no member named 'scheduler'`, or a missing `sched` field.

- [ ] **Step 3: Create `ps1-core/src/cpu/scheduler.zig`**

```zig
//! One countdown for the whole machine.
//!
//! Every device already defers its own work behind a deadline (the GPU, the
//! timers and the CD-ROM keep an `event_countdown`), so handing every step's
//! cycles to every device mostly adds and compares. `downcount` is the
//! minimum of those deadlines in CPU cycles. A step that ends short of it
//! only adds its cycles to `pending`; the step that reaches it takes the slow
//! path, which hands the backlog over and then runs the per-step fan-out
//! exactly as it always ran.
//!
//! Exact, not approximate. The rules that keep it exact:
//!
//!  - Nothing is due inside a deferred window, so handing a device the whole
//!    backlog in one call leaves it holding what a call per step would have.
//!    The slow path hands the backlog over FIRST and only then the step that
//!    reached the deadline, so every device's event body sees the same last
//!    `delta` it always saw.
//!  - Any MMIO access calls `sync` first: the device reads its state current,
//!    and the zeroed `downcount` sends the step in progress down the slow
//!    path, which recomputes the deadline AFTER the access has moved it.
//!  - A DMA-stalled step always takes the slow path. A DMA word can arm a
//!    block gap, start a chop CPU turn or end a transfer without any register
//!    access. Every cycle in `pending` was therefore spent by the CPU, and
//!    `pending` doubles as the DMA CPU-window count.
//!  - `deadline` names EVERY device countdown. One left out is not a slow
//!    event; it is an event that fires late.

const std = @import("std");
const Bus = @import("../memory.zig").Bus;

/// Cycles per SPU output sample: 33.8688 MHz / 44100 Hz.
const spu_sample_cycles: i64 = 768;

pub const Scheduler = struct {
    /// CPU cycles until the earliest device deadline, counted down by every
    /// step. Zero, the power-on value and what `sync` leaves, sends the next
    /// step down the slow path, which recomputes it.
    downcount: i64 = 0,
    /// Cycles and `Cpu.step()` calls not yet handed to the devices. SIO
    /// takes the step count: its /ACK delay counts steps, not cycles.
    pending: u32 = 0,
    pending_steps: u32 = 0,
    /// Carry for the CPU->video clock conversion. The GPU/video clock runs
    /// at 11/7 the CPU clock (53.2224 MHz vs 33.8688 MHz); `gpu.step()` is
    /// denominated in video cycles, so CPU cycles are scaled before being
    /// handed to it. Saved in the `CPU ` section, where it always was.
    gpu_clock_frac: u32 = 0,
};

/// One `Cpu.step()`'s `delta` cycles. `cpu_window` is false for a
/// DMA-stalled step, which neither ticks the DMA CPU window nor defers.
pub inline fn tick(bus: *Bus, delta: u32, cpu_window: bool) void {
    const s = &bus.sched;
    s.downcount -= delta;
    if (s.downcount > 0 and cpu_window) {
        s.pending += delta;
        s.pending_steps += 1;
        return;
    }
    tickSlow(bus, delta, cpu_window);
}

fn tickSlow(bus: *Bus, delta: u32, cpu_window: bool) void {
    flush(bus);
    advance(bus, delta, 1);
    if (cpu_window) bus.dma.tickCpuWindow(delta);
    bus.sched.downcount = deadline(bus);
}

/// Hands everything deferred to the devices and sends the step in progress
/// down the slow path. Called before every MMIO access, before a savestate
/// is written and before `ps1-golden` hashes a sample.
pub fn sync(bus: *Bus) void {
    flush(bus);
    bus.sched.downcount = 0;
}

fn flush(bus: *Bus) void {
    const s = &bus.sched;
    // Also what makes a second sync in one step harmless: stepping a device
    // by 0 cycles with a zeroed countdown would fire its event body.
    if (s.pending == 0) return;
    if (std.debug.runtime_safety) std.debug.assert(s.pending < deadline(bus));
    advance(bus, s.pending, s.pending_steps);
    bus.dma.tickCpuWindow(s.pending);
    s.pending = 0;
    s.pending_steps = 0;
}

/// The device fan-out for `cycles` cycles spanning `steps` `Cpu.step()`
/// calls. The order matters: timer 0 consumes the dotclock ticks and timer 1
/// the hblank tick that the GPU produced earlier in the same call.
fn advance(bus: *Bus, cycles: u32, steps: u32) void {
    bus.spu.step(cycles);

    // Without the 11/7 conversion the vblank period is ~1.57x too long
    // relative to the CPU-cycle root counters, so the BIOS VSync wait times
    // out during KERNEL SETUP and the boot hangs.
    const gpu_scaled = cycles * 11 + bus.sched.gpu_clock_frac;
    bus.sched.gpu_clock_frac = gpu_scaled % 7;
    const gpu_result = bus.gpu.step(gpu_scaled / 7);

    if (gpu_result.trigger_vblank_irq) bus.interrupts.trigger(.Vblank);
    if (gpu_result.trigger_gp0_irq) bus.interrupts.trigger(.Gpu);
    if (bus.spu.irq_flag) bus.interrupts.trigger(.Spu);

    // Controller/memcard port: /ACK arrives a few steps after a byte is
    // clocked out, so the IRQ is raised here rather than from the write.
    if (bus.sio.advance(steps)) bus.interrupts.trigger(.Controller);

    if (bus.timers[0].usesExternalClock()) {
        if (gpu_result.dotclock_ticks > 0 and bus.timers[0].step(gpu_result.dotclock_ticks)) {
            bus.interrupts.trigger(.Timer0);
        }
    } else if (bus.timers[0].step(cycles)) {
        bus.interrupts.trigger(.Timer0);
    }

    if (bus.timers[1].usesExternalClock()) {
        if (gpu_result.tick_hblank_timer and bus.timers[1].step(1)) {
            bus.interrupts.trigger(.Timer1);
        }
    } else if (bus.timers[1].step(cycles)) {
        bus.interrupts.trigger(.Timer1);
    }

    if (bus.timers[2].step(cycles)) bus.interrupts.trigger(.Timer2);

    bus.cdrom.step(cycles, &bus.spu);
    bus.cdrom.updateInterrupts(&bus.interrupts);
}

/// CPU cycles until the earliest device deadline, at least 1.
fn deadline(bus: *const Bus) i64 {
    var d: i64 = spu_sample_cycles - @as(i64, bus.spu.cycle_accumulator);

    // The GPU counts video cycles. It is due once floor((11c + frac) / 7)
    // reaches its countdown, which takes ceil((7 * countdown - frac) / 11)
    // CPU cycles.
    d = @min(d, @divFloor(7 * bus.gpu.event_countdown - @as(i64, bus.sched.gpu_clock_frac) + 10, 11));

    // Timers 0 and 1 on an external clock count GPU ticks and need no term:
    // timer 0 on the dotclock keeps the GPU eager (deadline 1), and timer 1
    // counts the hblank the GPU's scanline deadline already stops on. Timer
    // 2 always counts CPU cycles, whatever its mode.
    for (&bus.timers, 0..) |*t, i| {
        if (i < 2 and t.usesExternalClock()) continue;
        d = @min(d, t.event_countdown);
    }

    d = @min(d, bus.cdrom.event_countdown);

    // SIO counts steps, not cycles. A step costs at least one cycle, so the
    // step count used as a cycle count is a bound that arrives early, never
    // late; an early slow path finds SIO not yet due and re-arms. Do not
    // "convert" it.
    if (bus.sio.irq_timer > 0) d = @min(d, bus.sio.irq_timer);

    d = @min(d, bus.dma.cpuWindowDeadline());
    return @max(d, 1);
}
```

- [ ] **Step 4: Put the scheduler on `Bus` and sync every MMIO access**

In `ps1-core/src/memory.zig`:

Add beside the other imports at the top of the file:

```zig
const scheduler = @import("cpu/scheduler.zig");
```

Add the field directly after `sys_clock: u64 = 0,`. `Bus.init`'s `@memset(0)`
already leaves it valid, because every field defaults to 0. Do NOT add an
assignment in `init`:

```zig
    /// The machine-wide countdown; see `cpu/scheduler.zig`.
    sched: scheduler.Scheduler = .{},
```

In `read`, directly after `const paddr = virtual_address & Addr.phys_mask; // Mask to physical`:

```zig
        // Every device register lives here: hand the devices their deferred
        // cycles first (see `cpu/scheduler.zig`).
        if (paddr >= Addr.io_ports_base and paddr <= Addr.io_ports_last) scheduler.sync(self);
```

In `write`, directly after `const paddr = virtual_address & Addr.phys_mask;`:

```zig
        if (paddr >= Addr.io_ports_base and paddr <= Addr.io_ports_last) scheduler.sync(self);
```

In `dmaRead32`, as the first line inside the `spu_transfer_fifo` `if` (that
branch pops the FIFO without going through `read`):

```zig
            scheduler.sync(self);
```

- [ ] **Step 5: Drive the scheduler from `Cpu.step()`**

In `ps1-core/src/cpu/cpu.zig`:

Add the import beside `icache`/`exec`:

```zig
const scheduler = @import("scheduler.zig");
```

Delete the `gpu_clock_frac` field and its four-line comment (lines 57-61; it
now lives on `Scheduler`).

In `step()`, change the stalled branch's call to:

```zig
            self.tickPeripherals(dma_cycles, false);
```

Replace the two lines at the end of `step()`:

```zig
        self.tickPeripherals(delta_cycles);
        self.bus.dma.tickCpuWindow(delta_cycles);
```

with:

```zig
        self.tickPeripherals(delta_cycles, true);
```

Replace the whole of `fn tickPeripherals` (from `fn tickPeripherals(self: *Self, delta_cycles: u32) void {`
through its closing brace, just before `pub fn readReg`) with:

```zig
    /// The clocks advance every step, so the state hash and a savestate see
    /// them current without a sync; the devices are the scheduler's.
    inline fn tickPeripherals(self: *Self, delta_cycles: u32, cpu_window: bool) void {
        self.cycles +%= delta_cycles;
        self.bus.sys_clock = self.cycles;
        scheduler.tick(self.bus, delta_cycles, cpu_window);
    }
```

In `ps1-core/src/root.zig`, after `pub const cpu = @import("cpu/cpu.zig");`:

```zig
pub const scheduler = @import("cpu/scheduler.zig");
```

- [ ] **Step 6: Savestates: sync on save, reset on load**

In `ps1-core/src/savestate/savestate.zig`, make the first line of `save`:

```zig
    // Every device must hold what a per-step tick would have left it; the
    // scheduler's backlog is not part of a state.
    scheduler.sync(cpu.bus);
```

and add beside the file's other imports:

```zig
const scheduler = @import("../cpu/scheduler.zig");
```

In `ps1-core/src/savestate/cpu_state.zig`, replace `try w.int(cpu.gpu_clock_frac);` with:

```zig
    try w.int(cpu.bus.sched.gpu_clock_frac);
```

and replace `cpu.gpu_clock_frac = try r.int(u32);` with:

```zig
    // A whole Scheduler, not just the carry: the backlog belonged to the
    // device state this load replaces, and a zero `downcount` re-derives the
    // deadline on the first step.
    cpu.bus.sched = .{ .gpu_clock_frac = try r.int(u32) };
```

In `ps1-core/tests/savestate_test.zig`, line 140 becomes
`a.cpu.bus.sched.gpu_clock_frac = 5;`, and line 156 becomes
`try std.testing.expectEqual(a.cpu.bus.sched.gpu_clock_frac, b.cpu.bus.sched.gpu_clock_frac);`.

- [ ] **Step 7: `ps1-golden`: hash the carry from its new home, sync before sampling**

`ps1-golden/src/state_hash.zig:182`: `s.int(cpu.gpu_clock_frac);` becomes:

```zig
    s.int(cpu.bus.sched.gpu_clock_frac);
```

`ps1-golden/src/main.zig`: in the sample block (around line 528), put this
line before `bus.cdrom.catchUp();`, and extend the comment above it:

```zig
            // The scheduler defers every device the same way, one level up,
            // and for the same reason settling it cannot fire anything.
            ps1.scheduler.sync(bus);
```

`ps1-golden/src/savestate_roundtrip_test.zig`, in `hashes()`, put this line
before `m.bus.cdrom.catchUp();`. Match the name the file imports the core
under; check its top lines:

```zig
        ps1.scheduler.sync(m.bus);
```

- [ ] **Step 8: Run the scheduler tests and verify they pass**

Run: `zig build test -Dtest-filter="scheduler" 2>&1 | tail -20`
Then: `zig build test -Dtest-filter="savestate" 2>&1 | tail -20`
Expected: both exit 0. If the equivalence test fails, the first mismatching
step's `interrupts.stat` or `cycles` names the device. Use
superpowers:systematic-debugging. Do NOT weaken the test. If an `expect(stat & ...)` coverage
assertion fails and the equivalence assertions pass, the run was too short
to reach that device. Raise 200_000 and say so in the commit.

- [ ] **Step 9: Run the whole unit suite**

Run: `zig build test 2>&1 | tail -20`
Expected: exit 0, with all 20 binaries (14 unit files plus golden_test,
capi_test, gpu_stream_test, fixture_test and the two self-skipping ROM suites).

- [ ] **Step 10: Format and commit**

```bash
zig fmt ps1-core/src/cpu/scheduler.zig ps1-core/src/cpu/cpu.zig ps1-core/src/memory.zig ps1-core/src/root.zig ps1-core/src/savestate/savestate.zig ps1-core/src/savestate/cpu_state.zig ps1-core/tests/scheduler_test.zig ps1-core/tests/savestate_test.zig ps1-golden/src/state_hash.zig ps1-golden/src/main.zig ps1-golden/src/savestate_roundtrip_test.zig build.zig
git add -A ps1-core ps1-golden build.zig
git commit -m "feat(core): one machine-wide countdown for device ticks"
```

---

### Task 3: The zero-movement gates

Code changes in this task happen only if a gate fails. A failure here is a
bug in Task 2, **never** a golden to recapture (Global Constraints).

**Files:** none expected.

- [ ] **Step 1: verify**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- verify 2>&1 | tail -30`
Expected: every workload passes, exit 0.

- [ ] **Step 2: savestate**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- savestate 2>&1 | tail -30`
Expected: every workload passes, exit 0.

- [ ] **Step 3: stream-verify**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- stream-verify 2>&1 | tail -30`
Expected: every workload passes, exit 0.

- [ ] **Step 4: pgxp**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- pgxp 2>&1 | tail -30`
Expected: the identity invariant holds and no counter falls below
`ps1-core/tests/goldens/pgxp/floors.txt`, exit 0.

- [ ] **Step 5: JaCzekanski suite**

Run: `zig build test-roms-ja -Doptimize=ReleaseFast 2>&1 | tail -30`
Expected: 12/17, the same five failures as before (`ps1-test-harnesses`
lists them).

- [ ] **Step 6: Swift suite**

Run: `pkill -x Substation; zig build capi-lib metallib -Doptimize=ReleaseFast && ps1-macos/test.sh 2>&1 | tail -15`
Expected: all tests pass (484, or 480 with four fixture gates skipping if
`zig build fixtures` has not run).

- [ ] **Step 7: On any failure**

Invoke superpowers:systematic-debugging. Diff the first diverging sample's
region hashes. The region (`cpu`, `spu`, `sio`, `dma`, …) names the device
whose term or hand-over is wrong. Fix it in Task 2's files, rerun Task 2
Step 9 and every gate in this task, and commit the fix with a title-only
message (`fix(core): …`).

---

### Task 4: Measure, then document

**Files:**
- Modify: `CLAUDE.md` (Quick commands `zig build test` row; Architecture section; Repository layout `tests/` line)
- Modify: `.claude/skills/ps1-core-subsystems/SKILL.md` (new "Scheduler" paragraph under CPU)
- Memory: update `project-emulator-cpu-profile.md`

- [ ] **Step 1: Build the baseline and the new bench**

```bash
BASE=$(cat /private/tmp/claude-501/scheduler-base-sha)
git worktree add /private/tmp/claude-501/substation-base "$BASE"
(cd /private/tmp/claude-501/substation-base && zig build -Doptimize=ReleaseFast)
zig build -Doptimize=ReleaseFast
```

Expected: `/private/tmp/claude-501/substation-base/zig-out/bin/ps1-bench-dual`
and `zig-out/bin/ps1-bench-dual` both exist.

- [ ] **Step 2: Interleaved A/B, best of five, Croc 3000 frames**

Let the machine settle first: no `trace-golden` in the last few minutes.
Run from the repo root:

```bash
CUE="games/Croc - Legend of the Gobbos/Croc - Legend of the Gobbos.cue"
for i in 1 2 3 4 5; do
  /private/tmp/claude-501/substation-base/zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin "$CUE" 3000
  zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin "$CUE" 3000
done
```

Then do the same with `pgxp` appended to both commands. Record the best of
five for each binary in each mode. The same instructions run on both sides
(zero golden movement), so this is a fair A/B.

- [ ] **Step 3: xctrace: the interpreter's share of the emulator thread**

```bash
zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin "$CUE" 100000 &
PID=$!; sleep 20
xctrace record --template 'Time Profiler' --attach $PID --time-limit 8s --output /private/tmp/claude-501/sched.trace
kill $PID
xctrace export --input /private/tmp/claude-501/sched.trace --xpath '/trace-toc/run/data/table[@schema="time-profile"]' > /private/tmp/claude-501/sched.xml
```

Aggregate the first `<frame>` of each `<tagged-backtrace>` by function
(resolve `ref=` ids to their defining `<frame>`). Report the shares of:
`Cpu.step` plus `exec.*` plus `icache.*` (the interpreter); `scheduler.*`;
the rasterizer (`gpu/renderer`, `gpu/shaders`); SPU; CD-ROM. The interpreter
share is the ceiling Plans 2-5 can speed up. Stage 1's spec requires this
number before any speed-up is promised.

- [ ] **Step 4: Remove the worktree**

Run: `git worktree remove /private/tmp/claude-501/substation-base`

- [ ] **Step 5: Update `CLAUDE.md`**

- Quick commands, `zig build test` row: "**19 test binaries**: the 13
  `unit_test_files`" becomes "**20 test binaries**: the 14 `unit_test_files`".
- Repository layout, `tests/`: add `scheduler` to the unit-test list and
  change "all 13" to "all 14".
- Architecture: replace step 7 of the `Cpu.step()` list and the paragraph
  after it with:

```markdown
7. `tickPeripherals(delta_cycles, cpu_window)` advances `cpu.cycles` and
   `bus.sys_clock`, then `scheduler.tick` (`cpu/scheduler.zig`). While the step
   ends short of `bus.sched.downcount`, the earliest device deadline, it only
   adds the cycles to `pending`. The step that reaches the deadline hands the
   backlog over and then fans `delta_cycles` out **in this order, and the order
   matters**: `SPU → GPU → SIO → Timer0/1/2 → CDROM → DMA CPU window`.
   Timer0 consumes GPU dotclock ticks and Timer1 consumes GPU hblank ticks
   produced earlier _in the same call_, so reordering breaks timer timing.
   **Every MMIO access calls `scheduler.sync` first**, so a device register
   reads exactly what a per-step tick would have left. A DMA-stalled step
   always takes the slow path. SIO's /ACK counts steps, not cycles.
```

  Also change the "GPU runs on a scaled clock" paragraph's `gpu_clock_frac`
  reference to `bus.sched.gpu_clock_frac`.
- Rules, Core subsystems: add one line:

```markdown
- **`scheduler.deadline` must name EVERY device countdown**, and every MMIO
  access must `sync` first. A term left out is an event that fires late; the
  scheduler is exact only because nothing is ever due inside a deferred window.
```

- [ ] **Step 6: Update the `ps1-core-subsystems` skill**

Add under the CPU / COP0 / ALU bullets in
`.claude/skills/ps1-core-subsystems/SKILL.md`:

```markdown
- **The scheduler** (`cpu/scheduler.zig`, state on `bus.sched`) is exact, and
  `scheduler_test.zig` proves it against a machine forced onto the slow path
  every step, byte for byte through a savestate. Three things keep it exact:
  `deadline` names every device countdown; every MMIO access (and `dmaRead32`'s
  SPU branch) calls `sync` first, so `downcount = 0` makes the step in progress
  re-derive the deadline after the access; and a DMA-stalled step is always
  slow, because a DMA word can arm a block gap or chop turn without touching a
  register. A host-side poke that zeroes a device countdown (`catchUp`) must
  `sync` first, as `ps1-golden`'s sample point does. Measured on <date>:
  Croc <A>x -> <B>x, PGXP-on <C>x -> <D>x; interpreter share <E>% (xctrace).
```

Fill `<date>` and `<A>`–`<E>` from Steps 2-3.

- [ ] **Step 7: Update the profile memory**

Edit `/Users/david/.claude/projects/-Users-david-Documents-develop-substation/memory/project-emulator-cpu-profile.md`:
add a dated paragraph with the Step 2 numbers and the Step 3 breakdown,
noting that the "one global next-event countdown" step it named is done.

- [ ] **Step 8: Commit**

```bash
git add CLAUDE.md .claude/skills/ps1-core-subsystems/SKILL.md
git commit -m "docs: the machine-wide scheduler and its measured speed-up"
```
