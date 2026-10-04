# CPU recompiler, Plan 3: the block engine gates. Implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put `.cached` in front of every gate. Every frame loop calls
`cpu.run()`. `ps1-golden`, `ps1-bench` and the ROM suites take an engine. A
lockstep checker can re-run any block one instruction at a time and say which
block disagrees. Games are smoke-tested under `.cached`, and the block engines
get their own goldens in `ps1-core/tests/goldens/trace-block/`. The browser
build defaults to `.cached`. The interpreter's goldens do not move.

**Architecture:** `Cpu.run()` returns the number of `step()` calls it stands
for: instructions, DMA words and interrupt entries. Every frontend keeps its
instruction budget in that unit. A block engine's counter can step over the
instruction an event names, so events fire at the first count at or past it
(`ticker.zig`). With a counter that advances by one, that is the named
instruction exactly, which is why the interpreter's goldens hold.
`recompiler/lockstep.zig` wraps the block execution in the dispatcher: it
journals RAM stores through the block cache, runs the block on the engine,
puts memory and the CPU back, re-runs the same instructions through
`exec.execute`, and compares the results.

**Tech Stack:** Zig 0.17.0, `ps1-core`, `ps1-golden` (trace-golden),
`ps1-bench`, `ps1-capi`, `ps1-wasm` + `ps1-wasm/www/index.html`, the ROM suites.

**Spec:** `docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md`.
Read "Frontend contract", "Savestates: no format change", "C ABI and wasm",
"Harnesses", "Testing and gates", the "As built (Plan 2)" notes, and Plans → 3
before starting.

## Global Constraints

- `zig version` is **0.17.0**. 0.17 has no `**` array repeat (use `@splat`),
  `std.ArrayList` is unmanaged, `b.args` is gone (use `addPassthruArgs`), and
  `zig fmt` rewrites `@intFromEnum` to `@backingInt`.
- **The interpreter does not move.** `trace-golden -- verify`, `-- savestate`,
  `-- stream-verify` and `-- pgxp` stay green on the interpreter with **no
  recapture**, after every task. A moved interpreter golden is a bug in this
  plan, never a behaviour change to capture. Every gate runs
  `-Doptimize=ReleaseFast`.
- **Every frontend keeps counting `step()` calls.** `Cpu.run()` returns the
  count. Under the interpreter it returns 1, so a loop rewritten as
  `i += cpu.run()` makes the same calls in the same order as the
  `cpu.step(); i += 1` it replaces.
- **No savestate format change.** No section version bump.
- **`ps1-trace` and `ps1-debug` get no changes.** They are debugging tools and
  stay on the interpreter (spec, Non-goals).
- **`ps1-capi` gets no engine setting.** `ps1_run_frame` switches to
  `cpu.run()` and still runs the interpreter. `ps1_set_cpu_engine` is Plan 7.
- **A block engine's cache uses the process allocator, never an arena.**
  Invalidation frees blocks for the whole run, and an arena would keep every
  one of them until the workload ends.
- **Never lower a PGXP floor or re-pin a PeterLemon floor because `.cached`
  misses it.** Record the miss for the owner to rule on.
- No file in `ps1-core/src` over ~600 lines. `memory.zig` (947) is already
  over the limit; this plan adds a few lines to it. `lockstep.zig` stays well
  under the limit.
- Commits go directly on `master`, one per task, and the trace-block capture
  gets its own. The **commit message is the title line only**: no body and no
  trailer. **Never `git push`.**
- Run `zig fmt` on every touched `.zig` file before committing.

### Deliberate departures from the spec (flag these in review, do not "fix" them)

1. **There is no `-Dlockstep` build option.** The RAM-store journal hangs off
   `BlockCache` (`journal`), and only a block engine has a `BlockCache`. The
   RAM write path is restructured so that the interpreter takes exactly one
   `if (self.blocks)` branch, the same one it takes today. The checker is
   switched on at run time (`BlockCache.lockstep`). The result is that nothing
   compiles in or out, no extra core module or test binary is needed, and the
   lockstep tests run in `zig build test`. The interpreter's only new cost is
   one byte store on an MMIO access (`Bus.io_accessed`), a path that already
   syncs the scheduler.
2. **Lockstep snapshots the scratchpad (1 KB) instead of journalling it.** A
   scratchpad store then needs no hook at all.
3. **The lockstep reference runs exactly as many instructions as the engine
   did.** It checks what each instruction computes, not where the block ends.
   `block.zig`'s tests own termination, and a reference that ran on past the
   engine's end would execute an MMIO store the engine never reached.
4. **A trace-block sample is labelled with its boundary, not the count that
   reached it.** A block engine reaches 2,500,000 at, say, 2,500,031. The label
   stays 2,500,000, so `verify`'s alignment check still means "the k-th
   sample". The hashes are taken where the run actually is, and that is
   deterministic.
5. **The FF7 memory-card *save* half of the smoke test moves to Plan 7.** No
   frontend that can write a card runs a block engine before then: the macOS
   app has no engine setting and the browser build has no card. Plan 3 checks
   the read half headlessly: FF7 loads a save from a card under `.cached`
   (Task 6). Card writes use the same per-byte /ACK protocol as reads.

## Review Focus

1. **A savestate taken under a block engine just after an interpreter
   fallback step.** At that moment the I-cache holds lines and
   `icache_dirty` is set. Expected: the machine restored into a fresh `Bus`
   matches the original. This needs `setEngine` to run **before**
   `savestate.load`, which then restores the lines and marks them dirty
   exactly as the original had them. The reverse order flushes the lines on
   one machine only. Pinned in Task 2.
2. **A pad event whose instruction falls inside a block.** Expected: it
   fires once, at the first count past it. It must not be skipped, and it
   must not fire again on the next call. Pinned in Task 2 (`ticker.zig`,
   `script.Pad`).
3. **A sample boundary crossed in the middle of a block.** Expected: one
   sample, labelled with the boundary, and `restore_at` still matches it.
   Pinned in Task 2 (`Ticker.due` returns the boundary).
4. **A block that raises an exception, or rewrites itself, under lockstep.**
   Expected: checked and equal. The journal puts the rewritten word back
   before the reference runs, and the reference stops at the same
   exception. Pinned in Task 4.
5. **`run()`'s count for the dispatcher's one-step paths.** An interrupt
   entry, a DMA word, a delay-slot or IsC fallback, and a refused interrupt's
   single step each count exactly 1. A block that an MMIO store ends early
   counts only the instructions that ran. Pinned in Task 1.

---

### Task 1: `Cpu.run()` returns its step count; the frame loops call it

**Files:**
- Modify: `ps1-core/src/cpu/cpu.zig:97-101` (`run`)
- Modify: `ps1-core/src/recompiler/run.zig` (`run` returns `u32`)
- Modify: `ps1-core/src/recompiler/cached.zig` (`execute` returns `u32`)
- Modify: `ps1-capi/src/root.zig:478-482` (`ps1_run_frame`)
- Modify: `ps1-bench/main.zig:73-74`
- Modify: `ps1-wasm/src/main.zig` (`stepProbed`)
- Test: `ps1-core/tests/recompiler_test.zig`

**Interfaces:**
- Produces: `Cpu.run(self: *Cpu) u32`: the `step()` calls this unit of work
  stands for (instructions + DMA words + interrupt entries). It is 1 under the
  interpreter. `recompiler.run(cpu, c) u32` and
  `cached.execute(cpu, b, fetch_cost) u32` (instructions executed, the
  excepting or exiting one included).

- [ ] **Step 1: Make every existing `run()` call discard its result**

32 call sites in `recompiler_test.zig` read `m.cpu.run();`. Rewrite them
mechanically:

```bash
sed -i '' 's/\([ (]\)m\.cpu\.run();/\1_ = m.cpu.run();/' ps1-core/tests/recompiler_test.zig
grep -c '_ = m.cpu.run();' ps1-core/tests/recompiler_test.zig   # expect 32
grep -n 'm\.cpu\.run();' ps1-core/tests/recompiler_test.zig | grep -v '_ = '   # expect nothing
```

- [ ] **Step 2: Write the failing tests**

Append to `recompiler_test.zig`, after the "a branch in a branch's delay slot
resumes on the interpreter" test:

```zig
test "run() stands for one step under the interpreter" {
    var m = try Machine.init(.interpreter);
    defer m.deinit();
    poke(m.bus, 0x1000, &.{ mips.nop, mips.nop, mips.beq(zero, zero, -1), mips.nop });
    m.start(0x1000);
    try expectEqual(@as(u32, 1), m.cpu.run());
}

test "run() counts a block's instructions" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x1000, &.{ mips.nop, mips.nop, mips.beq(zero, zero, -1), mips.nop });
    m.start(0x1000);
    try expectEqual(@as(u32, 4), m.cpu.run());
}

test "run() counts only the instructions before an MMIO store's exit" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x1000, &.{
        mips.lui(t1, 0x1F80),
        mips.sw(zero, t1, 0x1074), // I_MASK: MMIO, ends the block
        mips.nop,
        mips.nop,
        mips.beq(zero, zero, -1),
        mips.nop,
    });
    m.start(0x1000);
    try expectEqual(@as(u32, 2), m.cpu.run());
    try expectEqual(@as(u32, 0x1008), m.cpu.pipeline.pc);
}

test "an interrupt entry, a DMA word and a fallback step each count one" {
    // Interrupt entry.
    {
        var m = try Machine.init(.cached);
        defer m.deinit();
        poke(m.bus, 0x1100, &.{ mips.nop, mips.beq(zero, zero, -2), mips.nop });
        raiseVblank(&m, 0);
        m.start(0x1100);
        try expectEqual(@as(u32, 1), m.cpu.run());
        try expectEqual(@as(u32, 0x8000_0080), m.cpu.pipeline.pc);
    }
    // A DMA-stalled run.
    {
        var m = try Machine.init(.cached);
        defer m.deinit();
        m.bus.write32(0x1F8010F0, 0x0800_0000); // DPCR: channel 6
        m.bus.write32(0x1F8010E0, 0x0000_403C);
        m.bus.write32(0x1F8010E4, 16);
        m.bus.write32(0x1F8010E8, 0x1100_0002); // OTC: start + trigger
        ps1_core.scheduler.sync(m.bus);
        try expect(m.bus.dma.isCpuStalled(m.bus));
        try expectEqual(@as(u32, 1), m.cpu.run());
    }
    // A delay slot runs as one interpreter step.
    {
        var m = try Machine.init(.cached);
        defer m.deinit();
        poke(m.bus, 0x1000, &.{ mips.beq(zero, zero, 3), mips.nop, mips.nop, mips.nop, mips.nop });
        m.start(0x1000);
        m.cpu.step(); // the branch: the delay slot is next
        try expect(m.cpu.pipeline.next_is_delay_slot);
        try expectEqual(@as(u32, 1), m.cpu.run());
    }
}

test "a refused interrupt's single step counts one" {
    var m = try gteBlockMachine(true);
    defer m.deinit();
    try expectEqual(@as(u32, 1), m.cpu.run());
    try expectEqual(@as(u32, 0x1104), m.cpu.pipeline.pc);
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `zig build test -Dtest-filter="run() " 2>&1 | tail -20`
Expected: a compile error. `run()` returns `void`, so
`expectEqual(@as(u32, 1), m.cpu.run())` does not type-check.

- [ ] **Step 4: Return the count**

`cached.zig`: count the instructions that ran, next to `steps`, which
`chargeCycles` resets mid-block:

```zig
/// Runs `b` from `cpu.pipeline.pc`, its start. Each instruction costs 1
/// plus `fetch_cost` plus its load/store wait states, as in the interpreter
/// with the I-cache replaced by a static fetch cost. Returns the
/// instructions it ran: an exception or a `block_exit` stops it early.
pub fn execute(cpu: *Cpu, b: *const Block, fetch_cost: u32) u32 {
    const bus = cpu.bus;
    cpu.exception_taken = false;
    bus.block_exit = false;
    // Charged but not yet handed to the scheduler.
    var cycles: u32 = 0;
    var steps: u32 = 0;
    var ran: u32 = 0;
    for (b.ops) |op| {
        // ... unchanged ...
        cpu.retireLoad();
        steps += 1;
        ran += 1;
        if (cpu.exception_taken or bus.block_exit) break;
    }
    cpu.chargeCycles(cycles + bus.wait_cycles, steps);
    bus.wait_cycles = 0;
    return ran;
}
```

`run.zig`: `pub fn run(cpu: *Cpu, c: *BlockCache) u32`. Every early `return;`
after a `cpu.step()` becomes `return 1;`. These are the DMA stall, the
fallback, the out-of-memory compile and the refused interrupt. The taken
interrupt (`chargeCycles(1 + fetch_cost, 1)`) also returns 1. The block's own
run becomes:

```zig
    cpu.biosCallHook(phys);
    c.running = b;
    const ran = cached.execute(cpu, b, fetch_cost);
    c.running = null;
    return ran;
```

Change the top comment to say what is returned:

```zig
/// One block, or one interpreter step. Returns the `Cpu.step()` calls it
/// stands for: a block's instructions, or 1 for a DMA word, an interrupt
/// entry or a fallback step.
pub fn run(cpu: *Cpu, c: *BlockCache) u32 {
```

`cpu.zig`:

```zig
    /// One unit of work for a frame loop: a block under a block engine,
    /// one instruction under the interpreter. Returns the `step()` calls it
    /// stands for (instructions, DMA words and interrupt entries), the unit
    /// every frontend keeps its instruction budget and schedules in.
    pub fn run(self: *Self) u32 {
        if (self.bus.blocks) |c| return recompiler.run(self, c);
        self.step();
        return 1;
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `zig build test -Dtest-filter="run() " && zig build test -Dtest-filter="count one" 2>&1 | tail -5`
Expected: PASS. Step 7 runs the full suite once; do not run it here as well.

- [ ] **Step 6: Switch the three frame loops**

`ps1-capi/src/root.zig`:

```zig
pub export fn ps1_run_frame(h: *Handle) void {
    if (!h.bios_loaded) return;
    while (h.cpu.bus.gpu.is_vblank) _ = h.cpu.run();
    while (!h.cpu.bus.gpu.is_vblank) _ = h.cpu.run();
}
```

`ps1-bench/main.zig` lines 73-74: the same, with `cpu`.

`ps1-wasm/src/main.zig` `stepProbed`: both `cpu.step();` calls become
`_ = cpu.run();`. Change the ring's comment so it no longer claims one entry
per instruction:

```zig
var pc_ring: [256]u32 = @splat(0); // one entry per run(): per block under a block engine
```

No engine is selected anywhere yet, so all three still run the interpreter.

- [ ] **Step 7: Build everything and check the interpreter did not move**

```bash
zig build && zig build capi-lib
zig build test 2>&1 | tail -3
zig build -Doptimize=ReleaseFast trace-golden -- verify
```

Expected: build clean, tests pass, verify all `OK`. `ps1-golden` still calls
`step()`, so verify only proves the core change. The capi and bench loops are
proved by Task 7's bench and by `capi_test`.

- [ ] **Step 8: Commit**

```bash
zig fmt ps1-core/src/cpu/cpu.zig ps1-core/src/recompiler/run.zig ps1-core/src/recompiler/cached.zig ps1-capi/src/root.zig ps1-bench/main.zig ps1-wasm/src/main.zig ps1-core/tests/recompiler_test.zig
git add -A ps1-core ps1-capi ps1-bench ps1-wasm
git commit -m "feat(core): run() returns its step count; frame loops call it"
```

---

### Task 2: `ps1-golden` runs on `cpu.run()` under any engine

**Files:**
- Create: `ps1-golden/src/ticker.zig`
- Modify: `ps1-golden/src/script.zig` (the rotation moves here; `Pad` replaces `maskAt`)
- Modify: `ps1-golden/src/main.zig` (`--engine`, the loops, `trace-block/`, `saveAndRestore`)
- Modify: `ps1-golden/src/golden_test.zig` (pull in `ticker.zig`'s tests)
- Modify: `ps1-golden/src/savestate_roundtrip_test.zig:34` (`run`)
- Test: `ps1-golden/src/ticker.zig`, `ps1-golden/src/script.zig`, `ps1-core/tests/recompiler_test.zig`

**Interfaces:**
- Consumes: `Cpu.run() u32` (Task 1); `recompiler.setEngine(cpu, allocator, engine)`, `recompiler.Engine`.
- Produces: `Ticker.init(period, phase)`, `Ticker.due(*Ticker, i) ?u64`;
  `script.Pad` with `maskAt(*Pad, i) ?u16`; `script.rotation_period`,
  `script.hold`; `Options.engine`; `goldensDir(engine) []const u8`;
  `selectEngine(cpu, engine) !void`. Task 4 reuses `selectEngine` and `Pad`.

- [ ] **Step 1: Write `ticker.zig` with its failing tests**

```zig
//! A schedule over a counter that can advance by more than one at a time.
//! A block engine's `run()` stands for up to a block's worth of steps, so a
//! frontend's counter can step over the instruction an event names. An event
//! fires at the first count at or past it. With a counter that advances by
//! one, that is exactly the named instruction, which is why the
//! interpreter's goldens do not move.

const std = @import("std");

pub const Ticker = struct {
    next: u64,
    period: u64,

    /// Every `period`, first at `phase`.
    pub fn init(period: u64, phase: u64) Ticker {
        return .{ .next = phase, .period = period };
    }

    /// The event's own count once `i` has reached it, else null. One event
    /// per call, so a period shorter than one `run()` would fall behind;
    /// `ps1-golden` refuses such a period.
    pub fn due(t: *Ticker, i: u64) ?u64 {
        if (i < t.next) return null;
        const at = t.next;
        t.next += t.period;
        return at;
    }
};

test "a ticker fires on its exact count when the counter steps by one" {
    var t = Ticker.init(10, 0);
    var fired: [3]u64 = undefined;
    var n: usize = 0;
    for (0..25) |i| {
        if (t.due(i)) |at| {
            try std.testing.expectEqual(@as(u64, i), at);
            fired[n] = at;
            n += 1;
        }
    }
    try std.testing.expectEqualSlices(u64, &.{ 0, 10, 20 }, fired[0..n]);
}

test "an event the counter steps over fires once, at the first count past it" {
    var t = Ticker.init(10, 3);
    try std.testing.expectEqual(@as(?u64, null), t.due(0));
    try std.testing.expectEqual(@as(?u64, 3), t.due(7));
    try std.testing.expectEqual(@as(?u64, null), t.due(9));
    try std.testing.expectEqual(@as(?u64, 13), t.due(15));
    try std.testing.expectEqual(@as(?u64, null), t.due(16));
}
```

Add `_ = @import("ticker.zig");` to the `test {}` block in `golden_test.zig`,
and give `ticker.zig` a line in that block's comment ("leaf modules with no
ps1_core dependency").

- [ ] **Step 2: Replace `script.maskAt` with `Pad`, test first**

Replace the test "maskAt presses on the tick and releases after the hold"
with:

```zig
test "a schedule presses on its count and releases after the hold" {
    const items = try parse(std.testing.allocator, "1:cross");
    defer std.testing.allocator.free(items);
    var p = Pad{ .script = items };
    const cross = released & ~(@as(u16, 1) << 14);
    try std.testing.expectEqual(@as(?u16, null), p.maskAt(0));
    try std.testing.expectEqual(@as(?u16, cross), p.maskAt(1_000_000));
    try std.testing.expectEqual(@as(?u16, null), p.maskAt(1_000_000 + hold - 1));
    try std.testing.expectEqual(@as(?u16, released), p.maskAt(1_000_000 + hold));
    try std.testing.expectEqual(@as(?u16, null), p.maskAt(1_000_000 + hold + 1));
}

test "a scheduled press inside a block fires once, at the first count past it" {
    const items = try parse(std.testing.allocator, "1:cross");
    defer std.testing.allocator.free(items);
    var p = Pad{ .script = items };
    const cross = released & ~(@as(u16, 1) << 14);
    try std.testing.expectEqual(@as(?u16, null), p.maskAt(999_990));
    try std.testing.expectEqual(@as(?u16, cross), p.maskAt(1_000_031));
    try std.testing.expectEqual(@as(?u16, null), p.maskAt(1_000_090));
    try std.testing.expectEqual(@as(?u16, released), p.maskAt(1_000_000 + hold + 40));
    try std.testing.expectEqual(@as(?u16, null), p.maskAt(1_000_000 + hold + 90));
}

test "with no schedule the pad rotates Start, Cross, Circle" {
    var p = Pad{};
    try std.testing.expectEqual(@as(?u16, rotation[0]), p.maskAt(0));
    try std.testing.expectEqual(@as(?u16, null), p.maskAt(1));
    try std.testing.expectEqual(@as(?u16, released), p.maskAt(hold));
    try std.testing.expectEqual(@as(?u16, rotation[1]), p.maskAt(rotation_period));
    try std.testing.expectEqual(@as(?u16, released), p.maskAt(rotation_period + hold + 17));
    try std.testing.expectEqual(@as(?u16, rotation[2]), p.maskAt(2 * rotation_period + 5));
}
```

Run: `zig build test -Dtest-filter="schedule" 2>&1 | tail -5`
Expected: compile error (`Pad`, `hold`, `rotation` undefined).

Then replace `maskAt` in `script.zig` with:

```zig
const Ticker = @import("ticker.zig").Ticker;

/// The rotation that walks intros, FMVs and title menus when no schedule is
/// given: Start, Cross, Circle, one press every `rotation_period`
/// instructions, each held for `hold`.
pub const rotation_period: u64 = 4_000_000;
pub const hold: u64 = 1_000_000;
const rotation = [_]u16{
    released & ~@as(u16, 1 << 3), // Start
    released & ~@as(u16, 1 << 14), // Cross
    released & ~@as(u16, 1 << 13), // Circle
};

/// What the pad holds over a run, as a function of the step count. A
/// schedule, when given, owns the pad and the rotation is off. Every event
/// fires at the first count at or past its instruction (see `ticker.zig`).
pub const Pad = struct {
    script: []const Press = &.{},
    idx: usize = 0,
    /// When the last scheduled press is released.
    release: ?u64 = null,
    press_at: Ticker = .init(rotation_period, 0),
    release_at: Ticker = .init(rotation_period, hold),
    rotation_idx: usize = 0,

    /// The mask to install at count `i`, or null when nothing changes.
    pub fn maskAt(p: *Pad, i: u64) ?u16 {
        if (p.script.len > 0) return p.scheduled(i);
        var mask: ?u16 = null;
        if (p.press_at.due(i) != null) {
            mask = rotation[p.rotation_idx];
            p.rotation_idx = (p.rotation_idx + 1) % rotation.len;
        }
        if (p.release_at.due(i) != null) mask = released;
        return mask;
    }

    /// Events sharing a count collapse to the last; a later press moves the
    /// release, so a press is never cut short by an earlier one's hold.
    fn scheduled(p: *Pad, i: u64) ?u16 {
        var mask: ?u16 = null;
        while (p.idx < p.script.len and p.script[p.idx].at <= i) : (p.idx += 1) {
            mask = p.script[p.idx].mask;
            p.release = p.script[p.idx].at + hold;
        }
        if (mask) |m| return m;
        const r = p.release orelse return null;
        if (i < r) return null;
        p.release = null;
        return released;
    }
};
```

With a counter that steps by one, this behaves exactly like the old `maskAt`
and the old `i % press_period` rotation. Check the four cases against the old
code by reading it: a press, its release, a second press inside the first's
hold (the release moves to the second), and two events on one count. Keep
the module's opening doc comment, and add one sentence: the rotation lives
here so the three loops in `main.zig` share one copy of it.

Run: `zig build test -Dtest-filter="schedule" && zig build test -Dtest-filter="ticker" && zig build test -Dtest-filter="rotates"`
Expected: PASS.

- [ ] **Step 3: Pin the restore order with a failing core test**

Append to `recompiler_test.zig`:

```zig
test "a state saved after a fallback step restores under a block engine with the same I-cache" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    // A branch run by the interpreter leaves its delay slot to a fallback
    // step, which fills I-cache lines and marks them dirty.
    poke(m.bus, 0x1000, &.{ mips.beq(zero, zero, 3), mips.addiu(t0, zero, 7), mips.nop, mips.nop, mips.addiu(t1, zero, 9), mips.beq(zero, zero, -1), mips.nop });
    m.start(0x1000);
    m.cpu.step();
    _ = m.cpu.run(); // the delay slot: a fallback step
    try expect(m.bus.blocks.?.icache_dirty);

    const n = try ps1_core.savestate.save(&m.cpu, null);
    const buf = try alloc.alloc(u8, n);
    defer alloc.free(buf);
    _ = try ps1_core.savestate.save(&m.cpu, buf);

    const fresh = try Bus.init(alloc);
    defer fresh.deinit(alloc);
    var restored = Cpu.init(fresh);
    // The engine first: load then restores the lines and marks them dirty,
    // exactly as the original holds them.
    try recompiler.setEngine(&restored, alloc, .cached);
    try ps1_core.savestate.load(&restored, buf);
    try expect(fresh.blocks.?.icache_dirty);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&m.cpu.icache), std.mem.sliceAsBytes(&restored.icache));

    var r: Machine = .{ .bus = fresh, .cpu = restored };
    try m.runUntil(0x1014);
    try r.runUntil(0x1014);
    try std.testing.expectEqualSlices(u32, &m.cpu.regs, &r.cpu.regs);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&m.cpu.icache), std.mem.sliceAsBytes(&r.cpu.icache));
}
```

`r` borrows `fresh`, which the `defer` frees, so do not call `r.deinit()`.
Both machines carry the zeroed BIOS a fresh `Bus` has, so `load`'s
BIOS-identity check passes, as in `savestate_test.zig`'s round-trip test.

Run: `zig build test -Dtest-filter="restores under a block engine"`
Expected: PASS. The core already behaves this way, so the test pins the
order `saveAndRestore` must follow (Step 6). To see it fail, swap the two
lines and watch `icache_dirty` come back false; then put them back.

- [ ] **Step 4: Add `--engine` to `Options` and `parseArgs`**

```zig
const Engine = ps1.recompiler.Engine;
const goldens_block_dir = "ps1-core/tests/goldens/trace-block";
```

In `Options`:

```zig
    /// The CPU engine every workload runs under. The block engines compare
    /// against their own goldens (`trace-block/`): they are not bit-exact
    /// against the interpreter, and are not meant to be.
    engine: Engine = .interpreter,
```

In `parseArgs`' loop:

```zig
        } else if (std.mem.startsWith(u8, arg, "--engine=")) {
            opts.engine = std.meta.stringToEnum(Engine, arg["--engine=".len..]) orelse return error.UnknownEngine;
```

After the loop, next to the `interval == 0` check:

```zig
    // A sample or a press is taken once per run(), so under a block engine
    // a period shorter than one block would fall behind its own schedule.
    if (opts.engine != .interpreter and opts.interval <= ps1.recompiler.block.max_len + 1) return error.BadArguments;
```

Add to `usage`, after `--bios=`:

```
    \\  --engine=<name>         interpreter (default), cached or jit. A block
    \\                          engine verifies against goldens/trace-block/.
```

- [ ] **Step 5: Add `selectEngine` and `goldensDir`, and use them**

```zig
/// The block cache frees a block on every invalidation for the whole run,
/// so it takes the process allocator: a workload arena would keep every
/// block it ever freed.
fn selectEngine(cpu: *ps1.cpu.Cpu, engine: Engine) !void {
    try ps1.recompiler.setEngine(cpu, std.heap.smp_allocator, engine);
}

fn goldensDir(engine: Engine) []const u8 {
    return if (engine == .interpreter) goldens_dir else goldens_block_dir;
}
```

`goldenPath(a, key)` becomes `goldenPath(a, key, engine)` and formats with
`goldensDir(engine)`. Update its two callers (`writeGolden`, `verifyGolden`)
to pass `opts.engine`.

Call `try selectEngine(&cpu, opts.engine);` right after
`try loadMachine(...)` in `runWorkload`, `runPgxp`, `runStreamVerify` and
`runStreamCapture`. `bus.deinit` frees the cache.

- [ ] **Step 6: Rewrite the loops on `cpu.run()`**

Delete `press_period`, `press_hold`, `released` and `press_seq` from
`main.zig`; they now live in `script.zig`.

`FrameStepper`:

```zig
const FrameStepper = struct {
    pad: script.Pad = .{},
    prev_vblank: bool = false,
    /// `step()` calls run so far: instructions, DMA words, interrupt entries.
    i: u64 = 0,

    const Frame = struct {
        stream: ps1.gpu.command.Stream,
        /// The count when the run that reached the boundary began. Under the
        /// interpreter that is the old per-instruction index, so probe logs
        /// and `--capture-from` keep their meaning.
        at: u64,
    };

    /// Drives the pad and one `cpu.run()`. Returns the drained stream when
    /// the run lands on a vblank rising edge (a frame boundary).
    fn step(self: *FrameStepper, cpu: *ps1.cpu.Cpu, bus: *ps1.memory.Bus) ?Frame {
        if (self.pad.maskAt(self.i)) |m| bus.sio.setButtons(m);
        const at = self.i;
        self.i += cpu.run();

        const vblank = bus.gpu.is_vblank;
        defer self.prev_vblank = vblank;
        if (!vblank or self.prev_vblank) return null;

        // The stream aliases the recorder's storage and is valid only until
        // emulation resumes, so callers must consume it before stepping again.
        return .{ .stream = bus.gpu.sink.rec.takeFrame(), .at = at };
    }
};
```

Keep the doc comment above the struct (one owner of the schedule). Point
"button schedule" at `script.Pad`.

`runStreamVerify`'s loop:

```zig
    var stepper = FrameStepper{};
    while (stepper.i < opts.instructions) {
        const f = stepper.step(&cpu, bus) orelse continue;
        const s = f.stream;
        const i = f.at;
        // ... body unchanged ...
    }
```

`runStreamCapture`: the same shape, with
`.pad = .{ .script = if (opts.input) |text| try script.parse(a, text) else &.{} }`
and `stepper.pad.script.len` in the "scripted presses" print. The PL boot:

```zig
        var b: u64 = 0;
        while (b < pl_boot_instructions) b += cpu.run();
```

`runPgxp`:

```zig
    var pad = script.Pad{};
    var i: u64 = 0;
    while (i < opts.instructions) {
        if (pad.maskAt(i)) |m| bus.sio.setButtons(m);
        i += cpu.run();
    }
```

`runWorkload`:

```zig
    var samples = std.ArrayList(golden.Sample).empty;
    var pad = script.Pad{};
    var sample_at = Ticker.init(opts.interval, opts.interval);
    var i: u64 = 0;
    while (i < opts.instructions) {
        if (pad.maskAt(i)) |m| bus.sio.setButtons(m);
        i += cpu.run();

        if (sample_at.due(i)) |at| {
            // ... the sync/catchUp comment and calls, unchanged ...
            var s = golden.Sample{ .instr = at, .hashes = undefined };
            state_hash.hashAll(&cpu, &s.hashes);
            try samples.append(a, s);
            if (opts.mode == .savestate and at == restore_at) bus = try saveAndRestore(a, &cpu, opts.engine);
        }
    }
```

Add `const Ticker = @import("ticker.zig").Ticker;` at the top. Under the
interpreter `i` arrives at each multiple exactly, and the label is the old
`i + 1`.

`saveAndRestore(a, cpu)` becomes `saveAndRestore(a, cpu, engine)`. Select the
engine on the fresh machine **before** the load:

```zig
    var restored = ps1.cpu.Cpu.init(fresh);
    // The engine before the load: a fresh Bus comes up on the interpreter,
    // and `savestate.load` then restores the I-cache lines and marks them
    // dirty for the dispatcher, exactly as the saving machine holds them.
    // The other order flushes them on this machine only.
    try selectEngine(&restored, engine);
    try ps1.savestate.load(&restored, buf);
```

`savestate_roundtrip_test.zig:34`:

```zig
    fn run(m: *Machine, n: u64) void {
        var i: u64 = 0;
        while (i < n) i += m.cpu.run();
    }
```

- [ ] **Step 7: Build, run the unit tests, and prove the interpreter did not move**

```bash
zig build && zig build test 2>&1 | tail -3
zig build -Doptimize=ReleaseFast trace-golden -- verify
zig build -Doptimize=ReleaseFast trace-golden -- savestate
zig build -Doptimize=ReleaseFast trace-golden -- stream-verify
zig build -Doptimize=ReleaseFast trace-golden -- pgxp
```

Expected: every workload `OK` and no floor moved. Then a quick block-engine
smoke on the BIOS alone, which needs no disc:

```bash
zig build -Doptimize=ReleaseFast trace-golden -- stream-verify --engine=cached --filter=bios-only --instructions=100000000
```

Expected: `OK` with a frame count near the interpreter's for the same budget.
Any `ERROR` or `DIVERGED` here is a Plan 2 bug: stop and use
`ps1-debugging-real-games` before going further.

- [ ] **Step 8: Commit**

```bash
zig fmt ps1-golden/src/*.zig ps1-core/tests/recompiler_test.zig
git add ps1-golden ps1-core/tests/recompiler_test.zig
git commit -m "feat(golden): run on cpu.run() under any engine, with trace-block goldens for the block engines"
```

---

### Task 3: `ps1-bench --engine` and the browser's `.cached` default

**Files:**
- Modify: `ps1-bench/main.zig`
- Modify: `ps1-wasm/src/main.zig` (new export `setCpuEngine`)
- Modify: `ps1-wasm/www/index.html:132` (select `.cached` after `init()`)

**Interfaces:**
- Consumes: `recompiler.setEngine`, `recompiler.Engine`, `Cpu.run()` (Task 1).
- Produces: wasm export `setCpuEngine(engine: u32) bool`, where 0 is the
  interpreter, 1 `.cached` and 2 `.jit`. It returns false, and keeps the
  current engine, when the engine is unavailable or out of memory.

- [ ] **Step 1: `ps1-bench --engine=`**

In the argument loop:

```zig
    var engine: ps1.recompiler.Engine = .interpreter;
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "nocopy")) no_copy = true;
        if (std.mem.eql(u8, a, "pgxp")) pgxp = true;
        if (std.mem.startsWith(u8, a, "--engine=")) {
            engine = std.meta.stringToEnum(ps1.recompiler.Engine, a["--engine=".len..]) orelse return error.UnknownEngine;
        }
    }
```

After `var cpu = ps1.cpu.Cpu.init(bus);`:

```zig
    try ps1.recompiler.setEngine(&cpu, alloc, engine);
```

Add `engine={s}` to the result line (`@tagName(engine)`), straight after
`sink=`. In the opening doc comment, add one sentence: `--engine=cached`
times a block engine through the same loop, so an engine A/B is one binary
with a flag.

- [ ] **Step 2: Run the bench under both engines**

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin "games/Croc - Legend of the Gobbos/<cue>" 600
./zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin "games/Croc - Legend of the Gobbos/<cue>" 600 --engine=cached
```

Use `ls "games/Croc - Legend of the Gobbos"` to find the cue. Expected: both
finish. Note the two `realtime=` figures; Task 7 takes the real numbers.

- [ ] **Step 3: The wasm export**

Below `setControllerButtons`:

```zig
/// 0 the interpreter, 1 the cached interpreter (the page's default), 2 the
/// JIT, which no wasm build has. False when the engine is unavailable or
/// its cache could not be allocated; the current engine stays selected.
/// `init()` builds a fresh Bus on the interpreter, so call this after it.
export fn setCpuEngine(engine: u32) bool {
    const e: ps1_core.recompiler.Engine = switch (engine) {
        0 => .interpreter,
        1 => .cached,
        2 => .jit,
        else => return false,
    };
    ps1_core.recompiler.setEngine(&cpu, std.heap.wasm_allocator, e) catch return false;
    return true;
}
```

`index.html`, straight after `wasmExports.init();`:

```js
        // The cached interpreter: the web build has no JIT.
        wasmExports.setCpuEngine(1);
```

Check that `init()` is the only place the page calls `wasmExports.init()`
(`grep -n "init()" ps1-wasm/www/index.html`). If any other path re-creates
the machine, select the engine there too.

- [ ] **Step 4: Smoke the browser build**

```bash
zig build
python3 -m http.server 8000   # from the repo root; the page fetches /zig-out/bin/emulator.wasm
```

Open `http://localhost:8000/ps1-wasm/www/index.html`, load the BIOS and the
Croc cue/bin, and play to the first level. Expected: it boots, plays and has
sound. **This step needs the owner's eyes**: ask them to do it, and record
what they report. Rebuild before reporting a browser-only symptom. A stale
`emulator.wasm` has caused that before.

- [ ] **Step 5: Commit**

```bash
zig fmt ps1-bench/main.zig ps1-wasm/src/main.zig
git add ps1-bench ps1-wasm
git commit -m "feat(wasm): setCpuEngine, with the cached interpreter as the page default; ps1-bench --engine"
```

---

### Task 4: The lockstep checker

**Files:**
- Create: `ps1-core/src/recompiler/lockstep.zig`
- Modify: `ps1-core/src/recompiler/cache.zig` (`journal`, `lockstep` fields)
- Modify: `ps1-core/src/recompiler/block.zig` (`fetchWord` made public)
- Modify: `ps1-core/src/recompiler/run.zig` (route the block through the checker)
- Modify: `ps1-core/src/memory.zig` (`io_accessed`, the journalled RAM store)
- Modify: `ps1-golden/src/main.zig` (the `lockstep` mode)
- Test: `ps1-core/tests/recompiler_test.zig`

**Interfaces:**
- Consumes: `cached.execute(cpu, b, fetch_cost) u32` (Task 1); `selectEngine`, `script.Pad` (Task 2).
- Produces: `recompiler.lockstep.Checker` (`checked: u64`, `skipped_io: u64`,
  `mismatch: ?Mismatch`), `Checker.execute(*Checker, cpu, b, fetch_cost) u32`,
  `lockstep.Arch` (`capture`, `restore`),
  `lockstep.compareArch(engine: *const Arch, reference: *const Arch) ?Mismatch`,
  `lockstep.Mismatch` (`block_pc`, `what: []const u8`, `index`, `engine`,
  `reference`), `BlockCache.lockstep: ?*Checker`,
  `BlockCache.journal: ?*Journal`, `Bus.io_accessed: bool`,
  `block.fetchWord(bus, phys) u32`. Plan 4 points `Checker.execute` at the
  JIT's block entry.

- [ ] **Step 1: Write the failing tests**

Append to `recompiler_test.zig`:

```zig
const lockstep = recompiler.lockstep;

fn lockstepMachine(checker: *lockstep.Checker) !Machine {
    const m = try Machine.init(.cached);
    m.bus.blocks.?.lockstep = checker;
    return m;
}

test "lockstep checks blocks that compute, store, load and branch" {
    var checker: lockstep.Checker = .{};
    var m = try lockstepMachine(&checker);
    defer m.deinit();
    poke(m.bus, 0x1000, &loop_program);
    m.start(0x8000_1000);
    try m.runUntil(0x8000_1048);
    try expectEqual(@as(?lockstep.Mismatch, null), checker.mismatch);
    try expect(checker.checked >= 10);
    // The engine's result is the one the machine kept.
    try expectEqual(@as(u32, 0), m.cpu.regs[t6]);
    try expectEqual(@as(u32, 2), m.cpu.regs[t7]);
    try expectEqual(@as(u32, 1), m.bus.read32(0x2024)); // the loop's last store
}

test "lockstep skips a block that touches MMIO" {
    var checker: lockstep.Checker = .{};
    var m = try lockstepMachine(&checker);
    defer m.deinit();
    poke(m.bus, 0x1000, &.{
        mips.lui(t1, 0x1F80),
        mips.lw(t0, t1, 0x1070), // I_STAT: a device read cannot be replayed
        mips.beq(zero, zero, -1),
        mips.nop,
    });
    m.start(0x1000);
    _ = m.cpu.run();
    try expectEqual(@as(u64, 0), checker.checked);
    try expectEqual(@as(u64, 1), checker.skipped_io);
}

test "lockstep checks a block that raises an exception" {
    var checker: lockstep.Checker = .{};
    var m = try lockstepMachine(&checker);
    defer m.deinit();
    poke(m.bus, 0x1000, &.{
        mips.lui(t0, 0x7FFF),
        mips.ori(t0, t0, 0xFFFF),
        mips.add(t1, t0, t0), // overflow
        mips.addiu(t2, zero, 1), // never runs
        mips.beq(zero, zero, -1),
        mips.nop,
    });
    m.start(0x1000);
    try expectEqual(@as(u32, 3), m.cpu.run());
    try expectEqual(@as(?lockstep.Mismatch, null), checker.mismatch);
    try expectEqual(@as(u64, 1), checker.checked);
    try expectEqual(@as(u32, 0x8000_0080), m.cpu.pipeline.pc);
    try expectEqual(@as(u32, 0x1008), m.cpu.cop0.readReg(.epc));
}

test "lockstep checks a store that rewrites the running block" {
    var checker: lockstep.Checker = .{};
    var m = try lockstepMachine(&checker);
    defer m.deinit();
    // The program of "a store into the running block ends it; the rewrite
    // runs next". The journal must put 0x1010 back before the reference runs.
    poke(m.bus, 0x1000, &.{
        mips.addiu(t1, zero, 0x1010),
        mips.lui(t0, 0x240A),
        mips.ori(t0, t0, 0x0055), // t0 = addiu t2, zero, 0x55
        mips.sw(t0, t1, 0), // rewrites 0x1010
        mips.addiu(t2, zero, 0x11), // 0x1010: the old instruction
        mips.beq(zero, zero, -1),
        mips.nop,
    });
    m.start(0x1000);
    try expectEqual(@as(u32, 4), m.cpu.run());
    try expectEqual(@as(u32, 0x1010), m.cpu.pipeline.pc);
    _ = m.cpu.run();
    try expectEqual(@as(u32, 0x55), m.cpu.regs[t2]);
    try expectEqual(@as(?lockstep.Mismatch, null), checker.mismatch);
    try expectEqual(@as(u64, 2), checker.checked);
}

test "compareArch names the first thing that differs" {
    var m = try Machine.init(.interpreter);
    defer m.deinit();
    const a = lockstep.Arch.capture(&m.cpu);
    var b = a;
    try expectEqual(@as(?lockstep.Mismatch, null), lockstep.compareArch(&a, &b));
    b.regs[9] = 0xDEAD;
    const mm = lockstep.compareArch(&a, &b).?;
    try std.testing.expectEqualStrings("gpr", mm.what);
    try expectEqual(@as(u32, 9), mm.index);
    try expectEqual(@as(u32, 0xDEAD), mm.reference);

    b = a;
    b.cop2.writeData(9, 4);
    try std.testing.expectEqualStrings("cop2 data", lockstep.compareArch(&a, &b).?.what);
    b = a;
    b.pipeline.next_pc +%= 4;
    try std.testing.expectEqualStrings("next_pc", lockstep.compareArch(&a, &b).?.what);
}

test "a lockstep RAM mismatch names the word" {
    var checker: lockstep.Checker = .{};
    var m = try lockstepMachine(&checker);
    defer m.deinit();
    poke(m.bus, 0x1000, &.{
        mips.lui(t0, 0x8000),
        mips.addiu(t1, zero, 5),
        mips.sw(t1, t0, 0x2000),
        mips.beq(zero, zero, -1),
        mips.nop,
    });
    m.start(0x1000);
    checker.fault = struct {
        // What a miscompiled store looks like: the engine wrote the wrong word.
        fn f(cpu: *Cpu) void {
            cpu.bus.write32(0x2000, 6);
        }
    }.f;
    _ = m.cpu.run();
    const mm = checker.mismatch.?;
    try std.testing.expectEqualStrings("ram", mm.what);
    try expectEqual(@as(u32, 0x2000), mm.index);
    try expectEqual(@as(u32, 6), mm.engine);
    try expectEqual(@as(u32, 5), mm.reference);
    try expectEqual(@as(u32, 0x1000), mm.block_pc);
}
```

The last test needs a seam: `Checker.fault`, an optional function run on the
machine right after the engine, so a test can make the engine wrong. It is
the only way to prove the checker can fail before Plan 4 has a JIT that
might. Document it as a test seam on the field.

Copy the program for the "rewrites the running block" test from the existing
test "a store into the running block ends it; the rewrite runs next"
(`recompiler_test.zig`, around line 422). Use its `start` and `runUntil`
target too.

- [ ] **Step 2: Run them to verify they fail**

Run: `zig build test -Dtest-filter="lockstep" 2>&1 | tail -5`
Expected: compile error, `recompiler.lockstep` not found.

- [ ] **Step 3: The hooks in `block.zig`, `cache.zig` and `memory.zig`**

`block.zig`, below `fetch`:

```zig
/// The word at a physical PC that can hold a block, read without billing
/// wait states. The lockstep reference fetches through it.
pub fn fetchWord(bus: *const Bus, phys: u32) u32 {
    return fetch(bus, regionOf(phys).?, phys);
}
```

`cache.zig`: add `const lockstep = @import("lockstep.zig");` and two fields
after `icache_dirty`:

```zig
    /// Records the old word under every RAM store while lockstep is
    /// checking a block (`lockstep.zig`). Null otherwise.
    journal: ?*lockstep.Journal = null,
    /// Re-runs every block one instruction at a time and compares. Set by a
    /// harness, never by a frontend.
    lockstep: ?*lockstep.Checker = null,
```

`memory.zig`: a field after `block_exit`:

```zig
    /// Set by every device access (an MMIO read or write). The lockstep
    /// checker clears it before a block and skips a block that set it: a
    /// FIFO pop cannot be replayed.
    io_accessed: bool = false,
```

In `read`:

```zig
        if (paddr >= Addr.io_ports_base and paddr <= Addr.io_ports_last) {
            scheduler.sync(self);
            self.io_accessed = true;
        }
```

In `write`, beside `if (!is_memory) self.block_exit = true;`:

```zig
        if (!is_memory) {
            self.block_exit = true;
            self.io_accessed = true;
        }
```

In `writeCpuStore`'s expansion-3 branch, beside its `self.block_exit = true;`,
add `self.io_accessed = true;`.

The RAM case in `write`. The interpreter takes the one branch it takes today:

```zig
            Addr.ram_base...Addr.ram_mirror_last => {
                const offset = paddr & Addr.ram_size_mask;
                if (self.blocks) |c| {
                    if (c.journal) |j| j.record(offset, readMem(u32, &self.ram, offset));
                    writeMem(T, &self.ram, offset, value);
                    if (c.onRamWrite(offset)) self.block_exit = true;
                } else writeMem(T, &self.ram, offset, value);
            },
```

`Bus.init` uses `@memset(0)`, so `io_accessed` starts false, which is its
default. No `init` line is needed.

- [ ] **Step 4: `lockstep.zig`**

```zig
//! The lockstep checker: each block run by its engine, then re-run from the
//! same state as one `exec.execute` per instruction, and the two compared.
//! Registers, HI/LO, the PC pipeline, the load delay, COP0, the GTE, every
//! RAM word either run stored to and the scratchpad. A mismatch names the
//! block, which is the point: a JIT bug found by a golden's region hash is a
//! frame; found here, it is one block.
//!
//! Devices are frozen for the reference. A block that touched a device
//! (`Bus.io_accessed`) is skipped, since a FIFO pop cannot be replayed. The
//! engine's run is the real one: it charged the scheduler, and its result
//! is what the machine keeps. The reference charges nothing.
//!
//! The reference runs as many instructions as the engine did. It checks what
//! each one computes, not where the block ends; `block.zig` owns that.
//! PGXP must be off: the reference would apply every shadow update twice.

const std = @import("std");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const exec = @import("../cpu/exec.zig");
const block = @import("block.zig");
const cached = @import("cached.zig");

/// The CPU state an instruction can change.
pub const Arch = struct {
    regs: [32]u32,
    hi: u32,
    lo: u32,
    pipeline: @FieldType(Cpu, "pipeline"),
    load_delay: @FieldType(Cpu, "load_delay"),
    cop0: Cpu.Cop0,
    cop2: Cpu.Cop2,

    pub fn capture(cpu: *const Cpu) Arch {
        return .{
            .regs = cpu.regs,
            .hi = cpu.hi,
            .lo = cpu.lo,
            .pipeline = cpu.pipeline,
            .load_delay = cpu.load_delay,
            .cop0 = cpu.cop0,
            .cop2 = cpu.cop2,
        };
    }

    pub fn restore(a: *const Arch, cpu: *Cpu) void {
        cpu.regs = a.regs;
        cpu.hi = a.hi;
        cpu.lo = a.lo;
        cpu.pipeline = a.pipeline;
        cpu.load_delay = a.load_delay;
        cpu.cop0 = a.cop0;
        cpu.cop2 = a.cop2;
    }
};

pub const Mismatch = struct {
    /// The virtual PC of the block's first instruction.
    block_pc: u32 = 0,
    /// "gpr", "hi", "lo", "pc", "next_pc", "delay slot", "load delay",
    /// "cop0", "cop2 data", "cop2 control", "ram", "scratchpad" or
    /// "length" (the reference stopped at an exception the engine did not).
    what: []const u8,
    /// The register number, or the byte offset into RAM or the scratchpad.
    index: u32 = 0,
    engine: u32 = 0,
    reference: u32 = 0,
};

/// The old word under each RAM store, oldest first. A block holds at most
/// `max_len + 1` instructions and each stores at most once.
pub const Journal = struct {
    len: usize = 0,
    entries: [block.max_len + 1]Entry = undefined,

    pub const Entry = struct { offset: u32, old: u32 };

    pub fn record(j: *Journal, offset: u32, old: u32) void {
        j.entries[j.len] = .{ .offset = offset & ~@as(u32, 3), .old = old };
        j.len += 1;
    }

    fn slice(j: *const Journal) []const Entry {
        return j.entries[0..j.len];
    }
};

pub const Checker = struct {
    checked: u64 = 0,
    skipped_io: u64 = 0,
    /// The first disagreement. Checking stops once it is set.
    mismatch: ?Mismatch = null,
    /// Test seam: run on the machine right after the engine, to make the
    /// engine wrong on purpose. Never set outside a test.
    fault: ?*const fn (cpu: *Cpu) void = null,

    /// Runs `b` on the engine, then checks it. Returns the engine's
    /// instruction count, as `cached.execute` does.
    pub fn execute(self: *Checker, cpu: *Cpu, b: *const block.Block, fetch_cost: u32) u32 {
        const bus = cpu.bus;
        const c = bus.blocks.?;
        std.debug.assert(!bus.pgxp_enabled);

        const pre = Arch.capture(cpu);
        const pre_scratch = bus.scratchpad;
        var engine_journal: Journal = .{};
        bus.io_accessed = false;
        c.journal = &engine_journal;
        const ran = cached.execute(cpu, b, fetch_cost);
        if (self.fault) |f| f(cpu);
        c.journal = null;
        if (self.mismatch != null) return ran;
        if (bus.io_accessed) {
            self.skipped_io += 1;
            return ran;
        }
        self.checked += 1;

        const engine = Arch.capture(cpu);
        const engine_exception = cpu.exception_taken;
        const engine_exit = bus.block_exit;
        const engine_scratch = bus.scratchpad;
        var engine_ram: [block.max_len + 1]u32 = undefined;
        for (engine_journal.slice(), 0..) |e, k| engine_ram[k] = ramWord(bus, e.offset);

        // Memory as the block found it, newest store first.
        var k = engine_journal.len;
        while (k > 0) {
            k -= 1;
            const e = engine_journal.entries[k];
            std.mem.writeInt(u32, bus.ram[e.offset..][0..4], e.old, .little);
        }
        bus.scratchpad = pre_scratch;
        pre.restore(cpu);

        var ref_journal: Journal = .{};
        c.journal = &ref_journal;
        const ref_ran = reference(cpu, ran);
        c.journal = null;
        bus.wait_cycles = 0;

        self.mismatch = if (ref_ran != ran)
            .{ .what = "length", .engine = ran, .reference = ref_ran }
        else
            compareArch(&engine, &Arch.capture(cpu)) orelse
                compareRam(bus, &engine_journal, engine_ram[0..engine_journal.len], &ref_journal) orelse
                compareScratchpad(&engine_scratch, &bus.scratchpad);
        if (self.mismatch) |*mm| mm.block_pc = b.start_pc;

        // Carry on from the engine's result. Memory holds the reference's
        // stores, which equal the engine's unless a mismatch was just set.
        engine.restore(cpu);
        cpu.exception_taken = engine_exception;
        bus.block_exit = engine_exit;
        return ran;
    }
};

fn ramWord(bus: anytype, offset: u32) u32 {
    return std.mem.readInt(u32, bus.ram[offset..][0..4], .little);
}

/// `n` instructions through `exec.execute`, fetched from memory as it is
/// now, with no scheduler charge. Stops at an exception, as a block does.
fn reference(cpu: *Cpu, n: u32) u32 {
    cpu.exception_taken = false;
    var ran: u32 = 0;
    while (ran < n) {
        cpu.pipeline.current_pc = cpu.pipeline.pc;
        const raw = block.fetchWord(cpu.bus, cpu.pipeline.current_pc & 0x1FFF_FFFF);
        cpu.beginInstruction();
        exec.execute(cpu, raw);
        cpu.retireLoad();
        ran += 1;
        if (cpu.exception_taken) break;
    }
    return ran;
}

pub fn compareArch(engine: *const Arch, ref: *const Arch) ?Mismatch {
    for (engine.regs, ref.regs, 0..) |e, r, i| {
        if (e != r) return .{ .what = "gpr", .index = @intCast(i), .engine = e, .reference = r };
    }
    if (engine.hi != ref.hi) return .{ .what = "hi", .engine = engine.hi, .reference = ref.hi };
    if (engine.lo != ref.lo) return .{ .what = "lo", .engine = engine.lo, .reference = ref.lo };
    const ep = engine.pipeline;
    const rp = ref.pipeline;
    if (ep.pc != rp.pc) return .{ .what = "pc", .engine = ep.pc, .reference = rp.pc };
    if (ep.next_pc != rp.next_pc) return .{ .what = "next_pc", .engine = ep.next_pc, .reference = rp.next_pc };
    if (ep.is_delay_slot != rp.is_delay_slot or ep.next_is_delay_slot != rp.next_is_delay_slot)
        return .{ .what = "delay slot" };
    if (!std.meta.eql(engine.load_delay, ref.load_delay)) return .{
        .what = "load delay",
        .index = engine.load_delay.load_r,
        .engine = engine.load_delay.load_v,
        .reference = ref.load_delay.load_v,
    };
    for (engine.cop0.regs, ref.cop0.regs, 0..) |e, r, i| {
        if (e != r) return .{ .what = "cop0", .index = @intCast(i), .engine = e, .reference = r };
    }
    for (0..32) |i| {
        const e = engine.cop2.readData(i);
        const r = ref.cop2.readData(i);
        if (e != r) return .{ .what = "cop2 data", .index = @intCast(i), .engine = e, .reference = r };
    }
    for (0..32) |i| {
        const e = engine.cop2.readCtrl(i);
        const r = ref.cop2.readCtrl(i);
        if (e != r) return .{ .what = "cop2 control", .index = @intCast(i), .engine = e, .reference = r };
    }
    return null;
}

/// Every word either run stored to. Where only one run stored, the other's
/// final value is the word as the block found it: the reference journal's
/// first old value for that offset.
fn compareRam(bus: anytype, engine_j: *const Journal, engine_final: []const u32, ref_j: *const Journal) ?Mismatch {
    for (engine_j.slice(), engine_final) |e, final| {
        const ref = ramWord(bus, e.offset);
        if (final != ref) return .{ .what = "ram", .index = e.offset, .engine = final, .reference = ref };
    }
    for (ref_j.slice()) |r| {
        if (find(engine_j, r.offset) != null) continue;
        const pre = ref_j.entries[find(ref_j, r.offset).?].old;
        const ref = ramWord(bus, r.offset);
        if (pre != ref) return .{ .what = "ram", .index = r.offset, .engine = pre, .reference = ref };
    }
    return null;
}

fn find(j: *const Journal, offset: u32) ?usize {
    for (j.slice(), 0..) |e, k| if (e.offset == offset) return k;
    return null;
}

fn compareScratchpad(engine: []const u8, ref: []const u8) ?Mismatch {
    var i: usize = 0;
    while (i < engine.len) : (i += 4) {
        const e = std.mem.readInt(u32, engine[i..][0..4], .little);
        const r = std.mem.readInt(u32, ref[i..][0..4], .little);
        if (e != r) return .{ .what = "scratchpad", .index = @intCast(i), .engine = e, .reference = r };
    }
    return null;
}
```

Import `const Bus = @import("../memory.zig").Bus;` and write `ramWord` and
`compareRam` with `bus: *const Bus`, not `anytype`. `bus.scratchpad` is `[1 KB]u8`, so
`compareScratchpad(&engine_scratch, &bus.scratchpad)` coerces to slices. The
test's fault store goes through `bus.write32` while the journal is still
attached, so it is journalled like an engine store. That is why `fault` runs
before `c.journal = null`.

If `readData(i)` or `readCtrl(i)` refuses a `usize` index (`anytype` that
casts to `u5`), pass `@as(u5, @intCast(i))`.

Export it: in `run.zig`, `pub const lockstep = @import("lockstep.zig");`
beside `block` and `cache`.

- [ ] **Step 5: Route the block through the checker**

`run.zig`, the block's run:

```zig
    cpu.biosCallHook(phys);
    c.running = b;
    const ran = if (c.lockstep) |l| l.execute(cpu, b, fetch_cost) else cached.execute(cpu, b, fetch_cost);
    c.running = null;
    return ran;
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `zig build test -Dtest-filter="lockstep" && zig build test -Dtest-filter="compareArch"`
Expected: PASS. Then run the rest of `recompiler_test.zig` once
(`zig build test 2>&1 | tail -3`), because `memory.zig`'s RAM path changed.

- [ ] **Step 7: The `lockstep` mode in `ps1-golden`**

Add `lockstep` to `Mode` and to `parseArgs`' mode chain
(`"lockstep" => .lockstep`). After the loop:

```zig
    // Lockstep re-runs blocks: the interpreter has none to re-run.
    if (opts.mode == .lockstep and opts.engine == .interpreter) {
        std.debug.print("lockstep: needs --engine=cached or --engine=jit\n", .{});
        return error.BadArguments;
    }
```

`usage`:

```
    \\  lockstep        run each workload under --engine, re-running every
    \\                  block one instruction at a time and comparing; names
    \\                  the first block that disagrees. PGXP stays off.
```

The runner, next to `runPgxp`:

```zig
const LockstepResult = struct {
    checker: ps1.recompiler.lockstep.Checker,
    instructions: u64,
};

/// `runPgxp`'s loop with the checker attached and PGXP off. Stops at the
/// first mismatch: everything after it runs on a machine already wrong.
fn runLockstep(
    a: std.mem.Allocator,
    io: std.Io,
    wl: golden.Workload,
    bios_override: ?[]const u8,
    opts: Options,
) !LockstepResult {
    const bus = try ps1.memory.Bus.init(a);
    defer bus.deinit(a);
    var cpu = ps1.cpu.Cpu.init(bus);
    try loadMachine(a, io, wl, bios_override, bus);
    try selectEngine(&cpu, opts.engine);
    var checker: ps1.recompiler.lockstep.Checker = .{};
    bus.blocks.?.lockstep = &checker;

    var pad = script.Pad{};
    var i: u64 = 0;
    while (i < opts.instructions and checker.mismatch == null) {
        if (pad.maskAt(i)) |m| bus.sio.setButtons(m);
        i += cpu.run();
    }
    return .{ .checker = checker, .instructions = i };
}

/// Returns true when the workload failed.
fn reportLockstep(key: []const u8, r: LockstepResult) bool {
    const c = r.checker;
    if (c.mismatch) |m| {
        std.debug.print(
            "  {s: <22} LOCKSTEP @ instr {d}: block {x:0>8}, {s}[{d}] engine={x:0>8} reference={x:0>8}\n",
            .{ key, r.instructions, m.block_pc, m.what, m.index, m.engine, m.reference },
        );
        return true;
    }
    std.debug.print("  {s: <22} {d} blocks checked, {d} skipped (MMIO)   OK\n", .{ key, c.checked, c.skipped_io });
    return false;
}
```

In `main`'s workload loop, before the `runWorkload` call:

```zig
        if (opts.mode == .lockstep) {
            const lr = runLockstep(wa, init.io, wl, opts.bios_override, opts) catch |err| {
                std.debug.print("  {s: <22} ERROR {s}\n", .{ wl.key, @errorName(err) });
                failures += 1;
                continue;
            };
            if (reportLockstep(wl.key, lr)) failures += 1;
            continue;
        }
```

Add `.lockstep` to the `unreachable` arm of the final `switch (opts.mode)`.

- [ ] **Step 8: Run lockstep on every workload**

```bash
zig build -Doptimize=ReleaseFast trace-golden -- lockstep --engine=cached
```

Expected: every workload `OK` with millions of blocks checked. `.cached` and
the reference share every handler, so a mismatch here is a checker bug (the
journal, the undo, `Arch`) or a real Plan 2 bug in the pipeline handling.
Either way, read the named block before going on. Record the per-workload
checked/skipped counts for Task 7.

Also re-run the interpreter gate once, because `memory.zig`'s RAM path
changed:
`zig build -Doptimize=ReleaseFast trace-golden -- verify`. Expected: all `OK`.

- [ ] **Step 9: Commit**

```bash
zig fmt ps1-core/src/recompiler/*.zig ps1-core/src/memory.zig ps1-golden/src/main.zig ps1-core/tests/recompiler_test.zig
git add ps1-core ps1-golden
git commit -m "feat(core): lockstep checker for the block engines, and trace-golden lockstep"
```

---

### Task 5: The ROM suites under `-Dengine`

**Files:**
- Modify: `build.zig:449-507` (the `engine` option, into `rom_test_options`)
- Modify: `ps1-core/tests/rom_test_helpers.zig` (`engine()`)
- Modify: `ps1-core/tests/jaczekanski_test.zig:165-200`
- Modify: `ps1-core/tests/peterlemon_test.zig` (`stepWithStreamCheck`, `runPlTest`)

**Interfaces:**
- Consumes: `Cpu.run() u32` (Task 1), `recompiler.setEngine`.
- Produces: `zig build test-roms-ja -Dengine=cached` and
  `zig build test-roms-pl -Dengine=cached`; `rom_test_options.engine: []const u8`.

- [ ] **Step 1: The build option**

Before `const rom_suites`:

```zig
    // `-Dengine=cached` runs the ROM suites under a block engine. They were
    // written against the interpreter: a timing-sensitive test may differ,
    // and the difference is recorded, not fixed by re-pinning a floor.
    const RomEngine = enum { interpreter, cached, jit };
    const rom_engine = b.option(RomEngine, "engine", "CPU engine for the ROM suites (default interpreter)") orelse .interpreter;
```

Add `opts.addOption([]const u8, "engine", @tagName(rom_engine));` to the
enabled suite's options. Add `skip_opts.addOption([]const u8, "engine", "interpreter");`
to the skip options, so the compile-check under `zig build test` sees the same
declarations.

- [ ] **Step 2: `engine()` in the helpers**

```zig
const ps1_core = @import("ps1_core");
const options = @import("rom_test_options");

/// The engine `-Dengine` chose. The build validates the name.
pub fn engine() ps1_core.recompiler.Engine {
    return std.meta.stringToEnum(ps1_core.recompiler.Engine, options.engine).?;
}
```

- [ ] **Step 3: The JA loop**

After `var cpu = Cpu.init(bus);` in the runner:

```zig
    try ps1_core.recompiler.setEngine(&cpu, allocator, rom_helpers.engine());
```

Import it as `const rom_helpers = @import("rom_test_helpers.zig");` and keep
the existing `readTestFile` import working, either through `rom_helpers` or as
it is. The boot loop:

```zig
    var boot_cycles: u64 = 0;
    while (boot_cycles < 25_000_000) boot_cycles += cpu.run();
```

The run loop:

```zig
    // Run the test
    var cycles: u64 = 0;
    var next_check: u64 = 0;
    while (cycles < max_cycles) {
        cycles += cpu.run();

        // Early exit optimization
        if (cycles > next_check) {
            next_check += 100_000;
            if (hasCompletionMarker(tty_capture.output.items)) break;
        }
    }
```

Under the interpreter the old check ran after step `cycles` when
`cycles % 100_000 == 0`, that is, when the new `cycles` (one higher) was
1, 100,001, 200,001 and so on. `cycles > next_check` with `next_check`
starting at 0 fires at exactly those counts. Work through the first two by
hand before committing.

`std.testing.allocator` checks for leaks: the cache is freed by
`bus.deinit`, which the test already defers.

- [ ] **Step 4: The PL loops**

`stepWithStreamCheck`:

```zig
    var i: u64 = 0;
    while (i < count) {
        i += cpu.run();
        // ... the vblank edge body, unchanged ...
    }
```

In `runPlTest`, after its `Cpu.init`, add the same `setEngine` line as in
JA. Read the rest of `runPlTest` for any other `cpu.step()` loop
(`grep -n "step()" ps1-core/tests/peterlemon_test.zig`) and convert it the
same way.

- [ ] **Step 5: Run both suites under both engines**

```bash
zig build test 2>&1 | tail -3
zig build -Doptimize=ReleaseFast test-roms-ja 2>&1 | tail -15
zig build -Doptimize=ReleaseFast test-roms-pl 2>&1 | tail -15
zig build -Doptimize=ReleaseFast test-roms-ja -Dengine=cached 2>&1 | tail -25
zig build -Doptimize=ReleaseFast test-roms-pl -Dengine=cached 2>&1 | tail -25
```

Expected: under the interpreter, JA stays 12/17 (the same five fail) and PL
passes. Under `.cached`, record which tests pass and fail, and the PL match
counts against their floors. For any test that fails under `.cached` and
passes under the interpreter, run it once with `-Drom-filter=<name>` and
read the diff. Then classify it:
- **timing**, when the test measures cycles or races a device, as the
  timer and DMA tests do; this is expected by the spec and gets recorded;
- **functional**, when the output differs for any other reason; this is a
  block engine bug, so stop and report it to the owner before going on.

- [ ] **Step 6: Commit**

```bash
zig fmt build.zig ps1-core/tests/rom_test_helpers.zig ps1-core/tests/jaczekanski_test.zig ps1-core/tests/peterlemon_test.zig
git add build.zig ps1-core/tests
git commit -m "test(roms): run the ROM suites under -Dengine"
```

---

### Task 6: Smoke-test games under `.cached`, then capture `trace-block/`

**Files:**
- Create: `ps1-core/tests/goldens/trace-block/*.txt` (captured)
- Modify: `.claude/skills/ps1-test-harnesses/SKILL.md` (the trace-block section)

**Interfaces:**
- Consumes: `trace-golden --engine` (Task 2), `lockstep` (Task 4), the browser default (Task 3).
- Produces: `ps1-core/tests/goldens/trace-block/`, one golden per workload
  that `verify` discovers. Plan 4's `verify --engine=jit` compares against
  them unchanged.

- [ ] **Step 1: The headless gates that need no golden**

```bash
zig build -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseFast trace-golden -- stream-verify --engine=cached
zig build -Doptimize=ReleaseFast trace-golden -- pgxp --engine=cached
```

Expected: `stream-verify` `OK` on every workload. `pgxp` meets every floor in
`floors.txt`. A floor that `.cached` misses is reported to the owner with the
two numbers. It is not lowered (Global Constraints).

- [ ] **Step 2: Headless boot check, game by game**

For each of Croc, Crash (`crash-bandicoot-europe-edc`), Spyro, Silent Hill
and Tekken 3, compare where each engine ends up after the standard 600M budget:

```bash
for e in interpreter cached; do
  ./zig-out/bin/ps1-golden stream-capture --engine=$e --filter=<key> --probe \
    --instructions=600000000 > /tmp/claude-probe-<key>-$e.txt 2>&1
done
```

Use the scratchpad directory for the outputs. Tekken 3 is not a discovered
workload (`ls ps1-core/tests/goldens/trace/`). If it is missing, use
`--cue=<path to its cue> --key=tekken3` instead of `--filter`. Expected: in
the last 100 `PROBE` lines, both engines draw (non-zero draw records) at a
similar density. The two runs are not frame-identical and are not meant to
be. A block engine run that draws nothing over its last 100 frames, while the
interpreter does, is a hang: stop and use `ps1-debugging-real-games`.

- [ ] **Step 3: FF7 loads a save from a memory card under `.cached`**

Use the recipe in the `project-ff7-fixture-capture` memory, with
`--engine=cached` and `--probe` in place of a fixture:

```bash
./zig-out/bin/ps1-golden stream-capture --engine=cached \
  --cue="games/Final Fantasy VII (USA)/<disc 1 folder>/<disc 1>.cue" --key=ff7-cached \
  --memcard="$HOME/Library/Application Support/PS1/MemoryCards/card1.mcd" \
  --input="$(for m in $(seq 700 30 1300); do printf '%d:circle;' $m; done)" \
  --instructions=2200000000 --probe > <scratchpad>/ff7-cached.txt 2>&1
```

Run the same command with `--engine=interpreter` too. Expected: near 2,186M
instructions both runs show field frames (about 745 records and a non-zero
payload). That proves the save was read off the card. A block engine run
stuck in dialogue-sized frames (66-175 records), or on the title screen, is
the SIO step-count failure the spec warns about ("every game reports the card
unformatted"). If the card is not at that path, ask the owner where it is.
Do not substitute a blank card: it has no save on it.

- [ ] **Step 4: The owner plays**

Ask the owner to play Crash, Spyro, Silent Hill and Tekken 3 in the browser
build (Task 3, Step 4 has the recipe) for a few minutes each, past the first
load, and to report anything that differs from the interpreter. Record what
they say, game by game. Do not capture until they have answered. If they
report a fault, run `trace-golden -- lockstep --engine=cached --filter=<key>`
on that workload first: it names the block if the fault is functional.

- [ ] **Step 5: Capture `trace-block/`**

```bash
mkdir -p ps1-core/tests/goldens/trace-block
zig build -Doptimize=ReleaseFast trace-golden -- capture --engine=cached
ls ps1-core/tests/goldens/trace-block/ | wc -l   # one per file in goldens/trace/
```

- [ ] **Step 6: Prove the capture is deterministic and survives a savestate**

```bash
zig build -Doptimize=ReleaseFast trace-golden -- verify --engine=cached
zig build -Doptimize=ReleaseFast trace-golden -- savestate --engine=cached
```

Expected: both all `OK`. A `verify` failure straight after a capture means
the block engine is not deterministic. A `savestate` failure means a state
taken under `.cached` does not capture the whole machine. Look at the
failing region first. `cpu` is most likely the I-cache order from Review
Focus 1: check that `saveAndRestore` selects the engine before the load. If
the cause is the scheduler backlog, the spec's fallback is to save
`pending` with a `CPU ` section bump. That is a format change: **ask the
owner first**.

- [ ] **Step 7: Document the trace-block goldens**

Add a section to `.claude/skills/ps1-test-harnesses/SKILL.md`, after "The
trace-equivalence harness", titled "`trace-block/`: the block engines'
goldens". It covers:
- what they are: captured from `.cached`, `verify --engine=cached|jit`,
  reused unchanged by the JIT (Plan 4);
- why they exist separately: block-granular interrupts, so they are not
  bit-exact against the interpreter, by design;
- the sample label is the boundary, not the count that reached it;
- when to recapture: a deliberate change to block-engine behaviour, as its own
  commit, never to make a JIT run pass;
- the smoke evidence this capture was taken on: the per-game headless
  results, the FF7 card load, what the owner reported, and the `lockstep`
  counts from Task 4.

- [ ] **Step 8: Commit the capture on its own**

```bash
git add ps1-core/tests/goldens/trace-block .claude/skills/ps1-test-harnesses/SKILL.md
git commit -m "test(golden): capture trace-block goldens from the cached interpreter"
```

---

### Task 7: Measurements, the full gate sweep and the as-built notes

**Files:**
- Modify: `docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md` (add "As built (Plan 3, ...)")
- Modify: `CLAUDE.md` (quick commands)

- [ ] **Step 1: Bench the interpreter against the pre-plan commit**

The frame loops now call `run()`, which adds a branch per instruction. Build
`ps1-bench-dual` at `a1ae280` (the commit before this plan) and at `HEAD`.
Use a worktree so the tree you are working in stays put:

```bash
git worktree add <scratchpad>/pre-plan3 a1ae280
(cd <scratchpad>/pre-plan3 && zig build -Doptimize=ReleaseFast)
zig build -Doptimize=ReleaseFast
```

Then, from the repo root, interleave five runs of each (Croc, 3000 frames)
and take the best of five for each binary:

```bash
for k in 1 2 3 4 5; do
  <scratchpad>/pre-plan3/zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin "<croc cue>" 3000
  ./zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin "<croc cue>" 3000
done
```

The 2% line applies. Over it, record the number and leave it for the owner to
rule on, exactly as Plan 2 did. Then remove the worktree
(`git worktree remove <scratchpad>/pre-plan3`).

- [ ] **Step 2: Bench `.cached` against the interpreter**

The same interleaved best of five at `HEAD`, without and with
`--engine=cached`, plus one pair with `pgxp`. This is the first measured
speed of the cached interpreter. Record it as measured. Do not round it into a
claim.

- [ ] **Step 3: The full gate sweep**

```bash
zig build test 2>&1 | tail -3
zig build -Doptimize=ReleaseFast trace-golden -- verify
zig build -Doptimize=ReleaseFast trace-golden -- savestate
zig build -Doptimize=ReleaseFast trace-golden -- stream-verify
zig build -Doptimize=ReleaseFast trace-golden -- pgxp
zig build -Doptimize=ReleaseFast trace-golden -- verify --engine=cached
zig build -Doptimize=ReleaseFast trace-golden -- savestate --engine=cached
zig build capi-lib && zig build metallib && pkill -x Substation; ps1-macos/test.sh 2>&1 | tail -5
```

Expected: all green, Swift suite included (its count unchanged). If an
earlier task already ran a step and nothing since touched what it covers,
reuse that result rather than re-running. Say so in the notes.

- [ ] **Step 4: The as-built notes**

Add "### As built (Plan 3, <date>)" to the spec, after the Plan 2 notes,
in their style. Cover:
- the names: `Cpu.run() u32`, `ticker.zig`, `script.Pad`,
  `--engine=` on `ps1-golden` and `ps1-bench`, `-Dengine` on the ROM suites,
  `setCpuEngine`, `recompiler.lockstep` (`Checker`, `Arch`, `Journal`,
  `compareArch`), `BlockCache.lockstep`/`journal`, `Bus.io_accessed`,
  `goldens/trace-block/`;
- the five departures from this plan's header, as built;
- the restore order (engine before `savestate.load`), which Plan 7's
  `ps1-capi` must follow when it carries the engine through `HostSettings`;
- the measurements: the Step 1 and 2 numbers, the ROM suites under `.cached`
  (which tests differ, timing or functional), the `lockstep` counts, the
  per-game smoke results and what the owner reported;
- what Plan 4 inherits: `Checker.execute` calls `cached.execute` directly,
  so Plan 4 dispatches on the engine there; `verify --engine=jit` compares
  against `trace-block/` unchanged; the FF7 save check moves to Plan 7.

- [ ] **Step 5: CLAUDE.md**

In the quick-commands table:
- `zig build trace-golden -- verify`: add that `--engine=cached` verifies a
  block engine against `ps1-core/tests/goldens/trace-block/` (and that every
  mode takes `--engine`);
- a new row, `zig build trace-golden -- lockstep --engine=cached`: re-runs
  every block one instruction at a time and names the first that disagrees;
  needs a block engine; PGXP stays off;
- `zig build test-roms-pl` / `-ja`: `-Dengine=cached` runs them under the
  cached interpreter, and timing tests may differ;
- `zig build ps1-bench-dual`/`-sw`: `--engine=cached`.

Under "Rules that must not be broken" → Harnesses, add:
- **A savestate restored under a block engine selects the engine BEFORE
  `savestate.load`.** Load then restores the I-cache lines and marks them
  dirty, as the saving machine holds them; the other order flushes them on one
  machine only.

Keep the "21 test binaries" count: this plan adds no test binary.

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md CLAUDE.md
git commit -m "docs: CPU recompiler spec as-built notes for the block engine gates"
```
