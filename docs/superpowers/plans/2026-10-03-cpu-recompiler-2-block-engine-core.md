# CPU recompiler, Plan 2: the block engine core. Implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the first block engine, `.cached`, beside the interpreter. It
decodes a run of guest instructions once into an array of `exec.zig` handler
calls, keeps blocks honest under self-modifying code and DMA, and charges the
scheduler once per block. The interpreter stays bit-exact: zero golden
movement.

**Architecture:** `exec.handlerFor` resolves an instruction word to the
function `execute` would have run, so every engine shares one set of
instruction semantics. `recompiler/block.zig` decides where a block ends.
`recompiler/cache.zig` maps a physical PC to its block and drops every block
in a 4 KB RAM page when that page is written. `recompiler/cached.zig` runs a
block. `recompiler/run.zig` is the dispatcher: it services the scheduler,
handles DMA stalls, interpreter fallbacks, the TTY hook and the block-start
interrupt rule, then runs one block. The scheduler learns to take a block's
cycles in one piece and hand an overrun to the devices one deadline at a time.

**Tech Stack:** Zig 0.17.0, `ps1-core`, `ps1-golden` (trace-golden), `ps1-bench`.

**Spec:** `docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md`
(sections "Block engines: timing", "Blocks, the cache and invalidation", "The
cached interpreter", the "As built (Plan 1)" notes, and Plans → 2). Read the
spec and the Plan 1 as-built notes before starting.

## Global Constraints

- `zig version` is **0.17.0**. 0.17 has no `**` array repeat (use `@splat`),
  `std.ArrayList` is unmanaged (`.empty`, `append(gpa, x)`, `pop()` returns
  `?T`, `deinit(gpa)`), and `zig fmt` rewrites `@intFromEnum` to `@backingInt`.
- **The interpreter does not move.** `trace-golden -- verify`, `-- savestate`,
  `-- stream-verify` and `-- pgxp` stay green on the interpreter with **no
  recapture**. A moved golden is a bug in this plan, never a behaviour change
  to capture. Every frontend still calls `cpu.step()`, so none of these
  harnesses runs a block engine yet (that is Plan 3).
- **No savestate format change.** No section version bump. `exception_taken`,
  `bus.blocks` and `bus.block_exit` are not saved.
- **Every handler is an existing `exec.zig` op.** `.cached` adds no instruction
  semantics of its own.
- **The block engines are not bit-exact against the interpreter and are not
  meant to be.** Their tests check architectural results (registers, memory,
  EPC) and the block engines' own timing rules. They do not compare cycle
  counts against the interpreter.
- `ps1-trace`, `ps1-debug`, `ps1-capi`, `ps1-wasm`, `ps1-bench` and `ps1-golden`
  get no changes in this plan.
- No file in `ps1-core/src` over ~600 lines. `memory.zig` (947) and `exec.zig`
  (758) are already over the limit; this plan adds only a few lines to each.
  Each new `recompiler/` file stays well under it.
- Commits go directly on `master`, one per task. The **commit message is the
  title line only**: no body and no trailer. **Never `git push`.**
- Run `zig fmt` on every touched `.zig` file before committing.

### Deliberate departures from the spec (flag these in review, do not "fix" them)

1. **The engine is held on `Bus` as the presence of `bus.blocks`, not as a `Cpu`
   field.** `Bus.write` has to reach the block cache to invalidate it, and
   `Bus` has no `Cpu` pointer. A cache owned anywhere else could outlive the
   RAM it was compiled from: `ps1_load_state` and `ps1_reset` swap in a fresh
   `Bus`. This is the `pgxp_vertex_cache` pattern: allocated on `Bus` by a
   setter that takes an allocator, freed by `Bus.deinit`, and carried across a
   rebuild by the frontend's `HostSettings` (Plan 7). `recompiler.setEngine` /
   `recompiler.engineOf` are the API. `Engine` keeps all three tags; `.jit`
   returns `error.EngineUnavailable` until Plan 4.
2. **A `Block` records no segment, and the fetch cost is read at every block
   start from the actual PC.** `.cached` embeds nothing that depends on the
   segment: branch targets come from `pipeline.pc` at run time. Computing the
   cost per run also keeps a BIOS wait-state write (`0x1F801010`) in effect
   from the next block. Plan 4 adds the segment to `Block`, along with the
   segment-mismatch recompile and its test, when the JIT embeds the cost. The
   test here is "the same block run from KSEG0 and KSEG1 charges each
   segment's cost".
3. **No PGXP mode in `Block`, and no flush when PGXP is toggled.** `.cached`
   calls the same handlers, which read `pgxp_enabled`/`pgxp_cpu` at run time.
   Plan 6 adds both for the JIT, whose emitted code does embed the mode.
4. **`.cached` commits its elapsed cycles before every load and store**, not only
   before a slow-path bus call. The two differ only in when RAM and scratchpad
   accesses commit, and those never sync. At every sync point (an MMIO access)
   both have handed over the same cycles, so `.jit`'s
   commit-before-slow-path produces identical device timing.
5. **The accessing instruction's own step is committed after its access.** The
   spec fixes the cycles ("up to and including the accessing instruction's
   fetch") but not the step count. The interpreter ticks SIO for step *k* after
   step *k*'s store, so a JOY_TX store arms /ACK before its own step counts
   against it. `.cached` keeps that order: with the pad's floor of 500, one
   step early is a real risk.
6. **An interrupt taken at a block start clears `pipeline.is_delay_slot`
   first.** After a block ends on a delay slot, `is_delay_slot` still describes
   that delay slot. `exception()` would then set Cause.BD and EPC = target - 4.
   The interpreter never meets this state because it refuses the interrupt
   there. The spec's block-start rule takes it, so EPC must be the block's
   start PC with BD clear.
7. **The dispatcher keeps the I-cache invalidated with a dirty flag.** An
   interpreter fallback step (IsC, a delay slot, a non-RAM PC) fills I-cache
   lines. The block engines never snoop them, so after a later RAM write those
   lines go stale. The spec says the block engines "leave it invalidated", and
   a savestate taken under a block engine must not capture stale lines. The
   dispatcher flushes the I-cache once before the next block after any fallback
   step (256 tag writes). `setEngine` flushes it too.
8. **The overrun handover lives in the scheduler, and the interpreter never
   reaches it.** `flush` keeps today's single handover when `downcount > 0`. A
   positive downcount proves the backlog is inside the window it was computed
   against, because a deadline only moves at an MMIO access and that syncs
   first. `flushOverrun` runs only when a block engine has pushed `downcount`
   to zero or below. `tickSlow` keeps its single handover and its debug
   assert. That stays true under the block engines because every `run()` ends
   in `serviceDue`, which leaves `downcount > 0`.

## Review Focus

1. **An interrupt taken at the start of a block that follows a delay slot.**
   Expected: EPC is the block's start PC (the branch target) and Cause.BD is
   clear. A wrong answer returns the handler into the middle of the branch.
   Pinned in Task 6.
2. **A DMA stall that begins at the MMIO store ending a block.** That block's
   tail cycles are still in `pending`, and `Cpu.step()`'s stalled path asserts
   `pending == 0`. Expected: the dispatcher syncs before handing the stalled
   step to the interpreter, and the DMA runs to completion. Pinned in Task 6.
3. **A store that rewrites the block it is running in.** Expected: the block
   stops after the store and its op array stays alive until the dispatcher
   reaps it. The next instruction is decoded from the new bytes. Pinned in
   Task 5. Run it in Debug, where the testing allocator catches a
   use-after-free.
4. **A block that overruns more than one device deadline**, for example timer 2
   crossing its target twice inside one charge. Expected: devices end exactly
   where the same cycles handed over one at a time leave them. Pinned in
   Task 2.
5. **RAM rewritten behind the bus**: `Cpu.loadExe` and `savestate.load` both
   `@memcpy` into RAM. Expected: the next `run()` decodes the new bytes. Pinned
   in Task 6.

---

### Task 1: `exec.handlerFor`: one decode table for every engine

**Files:**
- Modify: `ps1-core/src/cpu/exec.zig` (the `execute`/`special` switches, `opCop`/`opLwc`/`opSwc` parameter order, `opJ` inline → fn, new `Handler`, `bind`, `handlerFor`, `specialHandlerFor`, small named ops for the inline arms)
- Modify: `ps1-core/src/cpu/cpu.zig:6` (`const exec` → `pub const exec`)
- Test: `ps1-core/tests/cpu_test.zig`

**Interfaces:**
- Produces: `pub const Handler = *const fn (cpu: *Cpu, instr: Instruction) void;`
  and `pub inline fn handlerFor(raw: u32) Handler` in `exec.zig`, reachable as
  `ps1_core.cpu.exec.handlerFor`. `pub inline fn decode(raw: u32) Instruction`
  and `pub const Instruction` already exist. `execute(cpu, raw)` keeps its
  signature.

- [ ] **Step 1: Record the baseline commit for the bench A/B**

```bash
mkdir -p /private/tmp/claude-501
git rev-parse HEAD > /private/tmp/claude-501/recompiler2-base-sha
```

- [ ] **Step 2: Write the failing test** (append to `ps1-core/tests/cpu_test.zig`)

```zig
test "handlerFor resolves an encoding to one handler, whatever its operands" {
    const exec = ps1_core.cpu.exec;
    // addiu $t0, $t1, 5 and addiu $s0, $s1, -1: same op, different operands.
    try std.testing.expect(exec.handlerFor(0x2528_0005) == exec.handlerFor(0x2630_FFFF));
    // addu and subu share opcode 0 and differ only in funct.
    try std.testing.expect(exec.handlerFor(0x0109_5021) != exec.handlerFor(0x0109_5023));
    // sll (the nop) and srl.
    try std.testing.expect(exec.handlerFor(0x0000_0000) != exec.handlerFor(0x0000_0002));
    // lb and lbu: the same op function bound to different comptime arguments.
    try std.testing.expect(exec.handlerFor(0x8000_0000) != exec.handlerFor(0x9000_0000));
}
```

- [ ] **Step 3: Run it to make sure it fails**

Run: `zig build test -Dtest-filter="handlerFor"`
Expected: compile error, `exec` is not public / `handlerFor` not found.

- [ ] **Step 4: Implement `handlerFor`**

In `cpu.zig` line 6 change `const exec = @import("exec.zig");` to
`pub const exec = @import("exec.zig");`.

In `exec.zig`:

1. Change `inline fn opJ` to `fn opJ` (a function pointer cannot name an inline fn).
2. Reorder the comptime parameter to come last:
   `fn opCop(cpu: *Cpu, instr: Instruction, comptime cop_num: u2) void`,
   `inline fn opLwc(cpu: *Cpu, instr: Instruction, comptime cop_num: u2) void`,
   `inline fn opSwc(cpu: *Cpu, instr: Instruction, comptime cop_num: u2) void`.
   Nothing outside `exec.zig` calls them (`grep -rn "opCop\|opLwc\|opSwc" ps1-core ps1-*/src`).
3. Turn the inline arms of `special` into named ops, with the bodies moved
   verbatim:

```zig
fn opSyscall(cpu: *Cpu, instr: Instruction) void {
    _ = instr;
    cpu.exception(.Syscall, 0);
}

fn opBreak(cpu: *Cpu, instr: Instruction) void {
    _ = instr;
    cpu.exception(.Breakpoint, 0);
}

fn opReserved(cpu: *Cpu, instr: Instruction) void {
    _ = instr;
    cpu.exception(.ReservedInstruction, 0);
}

fn opMfhi(cpu: *Cpu, instr: Instruction) void {
    cpu.writeReg(instr.r.rd, cpu.hi);
    if (cpuMode(cpu)) muldiv.moveFromHi(cpu, instr.r.rd);
}

fn opMthi(cpu: *Cpu, instr: Instruction) void {
    cpu.hi = cpu.readReg(instr.r.rs);
    if (cpuMode(cpu)) muldiv.moveToHi(cpu, instr.r.rs);
}

fn opMflo(cpu: *Cpu, instr: Instruction) void {
    cpu.writeReg(instr.r.rd, cpu.lo);
    if (cpuMode(cpu)) muldiv.moveFromLo(cpu, instr.r.rd);
}

fn opMtlo(cpu: *Cpu, instr: Instruction) void {
    cpu.lo = cpu.readReg(instr.r.rs);
    if (cpuMode(cpu)) muldiv.moveToLo(cpu, instr.r.rs);
}
```

4. Replace `execute` and `special` with the table. `special` is deleted:
   first check that nothing outside `exec.zig` calls it with
   `grep -rn "exec.special\|\.special(" ps1-core ps1-*/src`.

```zig
/// What `execute` runs for one instruction word, resolved once. The block
/// engines decode a block's words into these when they compile it, and the
/// interpreter resolves one per step. There is one table, so a fix to an
/// instruction fixes it in every engine.
pub const Handler = *const fn (cpu: *Cpu, instr: Instruction) void;

/// `f(cpu, instr, args...)` as a `Handler`: binds an op's comptime
/// parameters, so the table can hold a plain function pointer. Comptime
/// memoisation gives one function per distinct `(f, args)`.
fn bind(comptime f: anytype, comptime args: anytype) Handler {
    return &struct {
        fn h(cpu: *Cpu, instr: Instruction) void {
            @call(.always_inline, f, .{ cpu, instr } ++ args);
        }
    }.h;
}

pub fn execute(cpu: *Cpu, raw_instr: u32) void {
    handlerFor(raw_instr)(cpu, decode(raw_instr));
}

pub inline fn handlerFor(raw: u32) Handler {
    const instr = decode(raw);
    return switch (instr.i.opcode) {
        0x00 => specialHandlerFor(instr.r.funct),
        0x01 => &opRegimm, // REGIMM (rt-based branches)
        0x02 => &opJ,
        0x03 => &opJal,

        0x04 => &opBeq,
        0x05 => &opBne,
        0x06 => &opBlez,
        0x07 => &opBgtz,

        0x08 => bind(iOpChecked, .{ alu.add, &ops.addi }),
        0x09 => bind(iOpSignExt, .{ alu.addu, &ops.addi }),
        0x0A => bind(iOpSignExt, .{ alu.slt, &ops.exact }),
        0x0B => bind(iOpSignExt, .{ alu.sltu, &ops.exact }),
        0x0C => bind(iOpZeroExt, .{ alu.and_, &ops.andi }),
        0x0D => bind(iOpZeroExt, .{ alu.or_, &ops.bitwiseImm }),
        0x0E => bind(iOpZeroExt, .{ alu.xor, &ops.bitwiseImm }),
        0x0F => &opLui,

        0x10 => bind(opCop, .{@as(u2, 0)}),
        0x11 => bind(opCop, .{@as(u2, 1)}),
        0x12 => bind(opCop, .{@as(u2, 2)}),
        0x13 => bind(opCop, .{@as(u2, 3)}),

        0x20 => bind(opLoad, .{ LoadType.Byte, true }), // LB  (Sign-extended)
        0x21 => bind(opLoad, .{ LoadType.Half, true }), // LH  (Sign-extended)
        0x22 => bind(opUnalignedLoad, .{UnalignedLoadType.Left}), // LWL
        0x23 => bind(opLoad, .{ LoadType.Word, false }), // LW  (Word)
        0x24 => bind(opLoad, .{ LoadType.Byte, false }), // LBU (Zero-extended)
        0x25 => bind(opLoad, .{ LoadType.Half, false }), // LHU (Zero-extended)
        0x26 => bind(opUnalignedLoad, .{UnalignedLoadType.Right}), // LWR

        0x28 => bind(opStore, .{StoreType.Byte}), // SB
        0x29 => bind(opStore, .{StoreType.Half}), // SH
        0x2A => bind(opUnalignedStore, .{UnalignedStoreType.Left}), // SWL
        0x2B => bind(opStore, .{StoreType.Word}), // SW
        0x2E => bind(opUnalignedStore, .{UnalignedStoreType.Right}), // SWR

        0x30 => bind(opLwc, .{@as(u2, 0)}), // LWC0
        0x31 => bind(opLwc, .{@as(u2, 1)}), // LWC1
        0x32 => bind(opLwc, .{@as(u2, 2)}), // LWC2
        0x33 => bind(opLwc, .{@as(u2, 3)}), // LWC3

        0x38 => bind(opSwc, .{@as(u2, 0)}), // SWC0
        0x39 => bind(opSwc, .{@as(u2, 1)}), // SWC1
        0x3A => bind(opSwc, .{@as(u2, 2)}), // SWC2
        0x3B => bind(opSwc, .{@as(u2, 3)}), // SWC3

        0x14...0x1F, 0x27, 0x2C, 0x2D, 0x2F, 0x34...0x37, 0x3C...0x3F => &opReserved,
    };
}

inline fn specialHandlerFor(funct: u6) Handler {
    return switch (funct) {
        0x00 => bind(shift, .{ alu.sll, &shift_ops.left }),
        0x02 => bind(shift, .{ alu.srl, &shift_ops.srl }),
        0x03 => bind(shift, .{ alu.sra, &shift_ops.sra }),
        0x04 => bind(shiftV, .{ alu.sll, &shift_ops.left }),
        0x06 => bind(shiftV, .{ alu.srl, &shift_ops.srlv }),
        0x07 => bind(shiftV, .{ alu.sra, &shift_ops.srav }),

        0x08 => &opJr,
        0x09 => &opJalr,

        0x0C => &opSyscall,
        0x0D => &opBreak,

        0x10 => &opMfhi,
        0x11 => &opMthi,
        0x12 => &opMflo,
        0x13 => &opMtlo,

        0x18 => bind(hiLoOp, .{ alu.mult, &muldiv.mult, true }),
        0x19 => bind(hiLoOp, .{ alu.multu, &muldiv.mult, false }),
        0x1A => bind(hiLoOp, .{ alu.div, &muldiv.div, true }),
        0x1B => bind(hiLoOp, .{ alu.divu, &muldiv.div, false }),

        0x20 => bind(rOpChecked, .{ alu.add, &ops.add }),
        0x21 => bind(rOpMove, .{ alu.addu, &ops.add }),
        0x22 => bind(rOpChecked, .{ alu.sub, &ops.sub }),
        0x23 => bind(rOp, .{ alu.subu, &ops.sub }),

        0x24 => bind(rOp, .{ alu.and_, &ops.bitwise }),
        0x25 => bind(rOpMove, .{ alu.or_, &ops.bitwise }),
        0x26 => bind(rOp, .{ alu.xor, &ops.bitwise }),
        0x27 => bind(rOp, .{ alu.nor, &ops.bitwise }),

        0x2A => bind(rOp, .{ alu.slt, &ops.sltReg }),
        0x2B => bind(rOp, .{ alu.sltu, &ops.sltReg }),

        // 0x01, 0x05, 0x0A-0x0B, 0x0E-0x0F, 0x14-0x17, 0x1C-0x1F, 0x28-0x29, 0x2C-0x3F
        else => &opReserved,
    };
}
```

If the compiler rejects an optional-pointer coercion inside a `bind` tuple
(the `?ops.RegHook` parameters of `rOp`/`rRetire`), write the argument as
`@as(?ops.RegHook, &ops.add)`. Do not change the op's signature.

- [ ] **Step 5: Run the CPU tests**

Run: `zig build test -Dtest-filter="CPU" && zig build test -Dtest-filter="handlerFor" && zig build test -Dtest-filter="PGXP"`
Expected: PASS. `execute` now routes every existing CPU test through
`handlerFor`, so those suites are the behaviour check for the table.

- [ ] **Step 6: Full unit tests and the interpreter gate**

Run: `zig build test`
Then: `zig build trace-golden -Doptimize=ReleaseFast -- verify`
Expected: all pass; every golden matches with no recapture.

- [ ] **Step 7: Interpreter speed check (it now dispatches through a function pointer)**

```bash
BASE=$(cat /private/tmp/claude-501/recompiler2-base-sha)
git worktree add /private/tmp/claude-501/substation-base2 "$BASE"
(cd /private/tmp/claude-501/substation-base2 && zig build -Doptimize=ReleaseFast)
zig build -Doptimize=ReleaseFast
CUE="games/Croc - Legend of the Gobbos/Croc - Legend of the Gobbos.cue"
for i in 1 2 3 4 5; do
  /private/tmp/claude-501/substation-base2/zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin "$CUE" 3000
  zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin "$CUE" 3000
done
```

Take the best of five for each. Let the machine settle first: a run straight
after `trace-golden` reads about 15% slow. **If the new build is more than 2%
slower, stop and report both numbers to the user.** Do not restructure
`execute` on your own: whether to keep a second switch is their decision. Keep
the worktree; Task 7 reuses it.

- [ ] **Step 8: Commit**

```bash
zig fmt ps1-core/src/cpu/exec.zig ps1-core/src/cpu/cpu.zig ps1-core/tests/cpu_test.zig
git add ps1-core/src/cpu/exec.zig ps1-core/src/cpu/cpu.zig ps1-core/tests/cpu_test.zig
git commit -m "refactor(core): one exec handler table behind execute and handlerFor"
```

---

### Task 2: Block-sized charges in the scheduler, and the step pieces a block engine reuses

**Files:**
- Modify: `ps1-core/src/cpu/scheduler.zig` (`charge`, `serviceDue`, `flush`/`flushOverrun`/`handOver`, `tickSlow`)
- Modify: `ps1-core/src/cpu/cpu.zig` (`exception_taken`, `beginInstruction`, `retireLoad`, `latchIrqLine`, `biosCallHook`, `chargeCycles`; `step()` rewritten in terms of them)
- Test: `ps1-core/tests/scheduler_test.zig`

**Interfaces:**
- Consumes: nothing new.
- Produces (all `pub`):
  - `scheduler.charge(bus: *Bus, cycles: u32, steps: u32) void`: defer only, never the slow path.
  - `scheduler.serviceDue(bus: *Bus) void`: if `downcount <= 0`, hand everything over (one deadline at a time) and recompute `downcount`.
  - `Cpu.exception_taken: bool`, set by every exception entry.
  - `Cpu.beginInstruction(self) void`: rotates the PC pipeline and both load-delay slots (and their shadows).
  - `Cpu.retireLoad(self) void`: lands the load due this instruction, then forces `regs[0] = 0`.
  - `Cpu.latchIrqLine(self) bool`: mirrors the IRQ line into Cause.IP2 and returns pending AND IEc AND IM2.
  - `Cpu.biosCallHook(self, physical_pc: u32) void`: the putchar TTY intercept.
  - `Cpu.chargeCycles(self, cycles: u32, steps: u32) void`: advances `cycles`/`sys_clock` and calls `scheduler.charge`.

- [ ] **Step 1: Write the failing test** (append to `ps1-core/tests/scheduler_test.zig`)

```zig
/// Every CPU-clock deadline the scheduler takes a term from, without the DMA
/// (charging cycles runs no DMA words, so a stalled channel would only sit).
fn armTimersAndPad(bus: *Bus) void {
    bus.write32(0x1F801108, 333); // timer 0 target
    bus.write32(0x1F801104, 0x0058); // sysclk; reset + IRQ on target, repeat
    bus.write32(0x1F801118, 3); // timer 1 target
    bus.write32(0x1F801114, 0x0158); // hblank
    bus.write32(0x1F801128, 100); // timer 2 target
    bus.write32(0x1F801124, 0x0258); // sysclk/8
    bus.write8(0x1F801040, 0x01); // select the pad: arms /ACK
}

test "an overrun handed over in one piece lands where single cycles land" {
    var one = try Machine.init();
    defer one.deinit();
    var many = try Machine.init();
    defer many.deinit();
    armTimersAndPad(one.bus);
    armTimersAndPad(many.bus);

    // 5000 cycles per charge crosses timer 0's target fifteen times, the
    // SPU's 768-cycle sample six times and the pad's /ACK once.
    var total: u32 = 0;
    while (total < 200_000) : (total += 5_000) {
        one.cpu.chargeCycles(5_000, 5_000);
        scheduler.serviceDue(one.bus);
        for (0..5_000) |_| {
            many.cpu.chargeCycles(1, 1);
            scheduler.serviceDue(many.bus);
        }
        try expect(one.bus.sched.downcount > 0);
        one.settle();
        many.settle();
        try expectSameState(&one, &many);
    }

    const stat = one.bus.interrupts.stat;
    try expect(stat & (1 << 0) != 0); // vblank
    try expect(stat & (1 << 4) != 0); // timer 0
    try expect(stat & (1 << 6) != 0); // timer 2
    try expect(stat & (1 << 7) != 0); // controller
}

test "a charge defers without touching any device" {
    var m = try Machine.init();
    defer m.deinit();
    scheduler.serviceDue(m.bus); // power-on downcount 0: arms it
    const spu_acc = m.bus.spu.cycle_accumulator;
    m.cpu.chargeCycles(10, 3);
    try expectEqual(@as(u32, 10), m.bus.sched.pending);
    try expectEqual(@as(u32, 3), m.bus.sched.pending_steps);
    try expectEqual(@as(u64, 10), m.cpu.cycles);
    try expectEqual(m.cpu.cycles, m.bus.sys_clock);
    try expectEqual(spu_acc, m.bus.spu.cycle_accumulator);
}
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `zig build test -Dtest-filter="overrun"` and `zig build test -Dtest-filter="a charge defers"`
Expected: compile error, `chargeCycles` / `serviceDue` not found.

- [ ] **Step 3: Implement the scheduler half**

In `scheduler.zig`, add a paragraph to the top-of-file `//!` rules list:

```zig
//!  - A block engine charges a whole block at once (`charge`) and may run
//!    past the deadline by up to its own length; `serviceDue` at the block
//!    boundary hands the overrun over one deadline at a time. The
//!    interpreter never overruns, and never reaches that path.
```

Replace `tickSlow` and `flush`, and add `charge`, `serviceDue`,
`flushOverrun` and `handOver`:

```zig
fn tickSlow(bus: *Bus, delta: u32, cpu_window: bool) void {
    const s = &bus.sched;
    if (s.pending > 0) {
        // Every step before this one ended short of the deadline, so the
        // backlog lies inside one window. This holds under the block engines
        // too, because each of their `run()`s ends in `serviceDue`.
        if (std.debug.runtime_safety) std.debug.assert(s.pending < deadline(bus));
        handOver(bus, s.pending, s.pending_steps);
        s.pending = 0;
        s.pending_steps = 0;
    }
    advance(bus, delta, 1);
    if (cpu_window) bus.dma.tickCpuWindow(delta);
    s.downcount = deadline(bus);
}

/// A block engine's `cycles` spanning `steps` would-be `Cpu.step()` calls.
/// Defers only, never the slow path: a block may run past the deadline,
/// and `serviceDue` at the block boundary hands the overrun over.
pub inline fn charge(bus: *Bus, cycles: u32, steps: u32) void {
    const s = &bus.sched;
    s.downcount -= cycles;
    s.pending += cycles;
    s.pending_steps += steps;
}

/// The block boundary's half of `tick`'s slow path: anything that came due
/// during the block is handed over and the deadline recomputed.
pub fn serviceDue(bus: *Bus) void {
    if (bus.sched.downcount > 0) return;
    flush(bus);
    bus.sched.downcount = deadline(bus);
}

fn flush(bus: *Bus) void {
    const s = &bus.sched;
    // Also what makes a second sync in one step harmless: stepping a device
    // by 0 cycles with a zeroed countdown would fire its event body.
    if (s.pending == 0) return;
    if (s.downcount > 0) {
        // Short of the deadline it was computed against, and nothing has
        // moved it since (a move means an MMIO access, which syncs first).
        handOver(bus, s.pending, s.pending_steps);
    } else {
        flushOverrun(bus);
    }
    s.pending = 0;
    s.pending_steps = 0;
}

/// Hands a backlog that ran past the deadline over one deadline at a time.
/// A device given more than a deadline's worth in one call misses events:
/// `Timer.stepRaw` sees one target crossing per call, and the CD-ROM's
/// batch assumes nothing is due inside it. Steps go with the earliest
/// cycles. A step costs at least one cycle, so no chunk is handed more
/// steps than cycles, and none more than SIO's own term allows.
fn flushOverrun(bus: *Bus) void {
    const s = &bus.sched;
    while (s.pending > 0) {
        const chunk: u32 = @intCast(@min(@as(i64, s.pending), deadline(bus)));
        const steps = if (chunk == s.pending) s.pending_steps else @min(s.pending_steps, chunk);
        handOver(bus, chunk, steps);
        s.pending -= chunk;
        s.pending_steps -= steps;
    }
}

/// Deferred cycles to the devices. Every deferred cycle was spent by the CPU,
/// so the same count drains the DMA CPU window.
fn handOver(bus: *Bus, cycles: u32, steps: u32) void {
    advance(bus, cycles, steps);
    bus.dma.tickCpuWindow(cycles);
}
```

`sync` is unchanged: it calls `flush`, then sets `downcount = 0`. Under the
interpreter, `flush` always takes the `downcount > 0` branch or returns early.
After a sync zeroes `downcount`, the same step's tick recomputes it before
anything can be added to `pending`.

- [ ] **Step 4: Implement the CPU half**

In `cpu.zig`, add after `icache`:

```zig
    /// Set by every exception entry. The block engines clear it before a
    /// block and stop after the instruction that set it. Transient: not saved.
    exception_taken: bool = false,
```

In `enterException`, add `self.exception_taken = true;` as its first line.

Add these methods, cut verbatim from `step()`:

```zig
    /// The putchar TTY intercept at the A0/B0 kernel vectors. A PC hack,
    /// not a real syscall; shared by `step()` and the block dispatcher.
    pub fn biosCallHook(self: *Self, physical_pc: u32) void {
        if (physical_pc != 0x000000A0 and physical_pc != 0x000000B0) return;
        bios_hit_count += 1;
        const func = self.readReg(.t1);

        // putchar (Table A: 0x3C, Table B: 0x3D)
        if ((physical_pc == 0x000000A0 and func == 0x3C) or
            (physical_pc == 0x000000B0 and func == 0x3D))
        {
            const char: u8 = @truncate(self.readReg(.a0));
            if (self.tty_write_fn) |writer| writer(self.tty_context, char);
        }
    }

    /// Mirrors the hardware interrupt line into Cause.IP2 (bit 10) and
    /// reports whether an interrupt is pending AND enabled (SR IEc and IM2).
    /// Whether it may be taken HERE is the caller's rule.
    pub inline fn latchIrqLine(self: *Self) bool {
        const has_pending_irq = self.bus.interrupts.hasPendingIrq();
        var cause = self.cop0.readReg(.cause);
        if (has_pending_irq) {
            cause |= (1 << 10);
        } else {
            cause &= ~@as(u32, 1 << 10);
        }
        self.cop0.setReg(.cause, cause);

        const sr = self.cop0.readReg(.sr);
        const iec = (sr & 1) == 1; // Current Interrupt Enable
        const im2 = (sr & (1 << 10)) != 0; // Interrupt Mask 2
        return has_pending_irq and iec and im2;
    }

    /// Rotates the PC pipeline and the load-delay pair (with their PGXP
    /// shadows) for the instruction at `pipeline.pc`, just before it runs.
    pub inline fn beginInstruction(self: *Self) void {
        self.pipeline.pc = self.pipeline.next_pc;
        self.pipeline.next_pc = self.pipeline.pc +% 4;
        self.pipeline.is_delay_slot = self.pipeline.next_is_delay_slot;
        self.pipeline.next_is_delay_slot = false;

        self.load_delay.delay_r = self.load_delay.load_r;
        self.load_delay.delay_v = self.load_delay.load_v;
        self.delay_shadow = self.load_shadow;

        self.load_delay.load_r = 0;
        self.load_delay.load_v = 0;
        self.load_shadow = Value.none;
    }

    /// Applies the load that lands this cycle. An explicit register write
    /// during the instruction cancels it (writeReg clears delay_r), matching
    /// the R3000A pipeline: a delay-slot instruction's own write to the
    /// load's target register wins over the load's delayed writeback.
    pub inline fn retireLoad(self: *Self) void {
        if (self.load_delay.delay_r != 0) {
            self.regs[self.load_delay.delay_r] = self.load_delay.delay_v;
            self.gpr_shadow[self.load_delay.delay_r] = self.delay_shadow;
        }
        self.regs[0] = 0;
    }

    /// `cycles` spanning `steps` would-be `step()` calls, run by a block
    /// engine. The clocks advance now, as `tickPeripherals` advances them;
    /// the devices get the cycles at the block boundary (`scheduler.serviceDue`).
    pub inline fn chargeCycles(self: *Self, cycles: u32, steps: u32) void {
        self.cycles +%= cycles;
        self.bus.sys_clock = self.cycles;
        scheduler.charge(self.bus, cycles, steps);
    }
```

Rewrite `step()` to call them. The order of operations must not change:

```zig
    pub fn step(self: *Self) void {
        if (self.bus.dma.isCpuStalled(self.bus)) {
            // (unchanged: the assert, dma.step, tickPeripherals(dma_cycles, false), return)
        }

        const physical_pc = self.pipeline.pc & 0x1FFFFFFF;
        self.biosCallHook(physical_pc);

        if (isInstructionBusErrorAddress(physical_pc)) {
            // (unchanged)
        }

        self.pipeline.current_pc = self.pipeline.pc;
        const instruction = icache.fetchInstruction(self, self.pipeline.current_pc);

        var delta_cycles: u32 = 1;
        delta_cycles += self.bus.wait_cycles;
        self.bus.wait_cycles = 0;

        const irq = self.latchIrqLine();

        // CRITICAL MIPS RULE: ... (keep the whole existing comment block)
        const is_gte_command = (instruction >> 24) & 0xFE == 0x4A;
        const safe_to_interrupt = !self.pipeline.is_delay_slot and
            !self.pipeline.next_is_delay_slot and
            !is_gte_command;

        if (irq and safe_to_interrupt) {
            self.exception(.Interrupt, 0);
            // We spent cycles fetching the instruction, but we don't execute it.
            // We still need to tick hardware!
        } else {
            self.beginInstruction();
            exec.execute(self, instruction);
            self.retireLoad();
        }

        self.tickPeripherals(delta_cycles, true);
    }
```

- [ ] **Step 5: Run the scheduler and CPU tests**

Run: `zig build test -Dtest-filter="overrun" && zig build test -Dtest-filter="a charge defers" && zig build test`
Expected: PASS, including the existing scheduler equivalence tests (the
interpreter path is unchanged).

- [ ] **Step 6: The interpreter gate**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- verify` and
`zig build trace-golden -Doptimize=ReleaseFast -- savestate`
Expected: both green, no recapture.

- [ ] **Step 7: Commit**

```bash
zig fmt ps1-core/src/cpu/scheduler.zig ps1-core/src/cpu/cpu.zig ps1-core/tests/scheduler_test.zig
git add ps1-core/src/cpu/scheduler.zig ps1-core/src/cpu/cpu.zig ps1-core/tests/scheduler_test.zig
git commit -m "feat(core): block-sized scheduler charges and an overrun handed over per deadline"
```

---

### Task 3: `block.zig`: where a block begins and ends

**Files:**
- Create: `ps1-core/src/recompiler/block.zig`
- Create: `ps1-core/src/recompiler/run.zig` (only the module re-exports for now; Task 5 fills it)
- Modify: `ps1-core/src/root.zig` (export `recompiler`)
- Create: `ps1-core/tests/recompiler_test.zig`
- Modify: `build.zig:188-203` (add `"ps1-core/tests/recompiler_test.zig"` to `unit_test_files`)

**Interfaces:**
- Consumes: `exec.Handler`, `exec.handlerFor`, `exec.decode`, `exec.Instruction` (Task 1).
- Produces:
  - `block.max_len: usize = 64`, `block.page_shift: u5 = 12`
  - `block.Region = enum { ram, bios }` and `block.regionOf(phys: u32) ?Region`
  - `block.Op = struct { handler: exec.Handler, instr: exec.Instruction, memory: bool }`
  - `block.Block = struct { start_pc: u32, ops: []Op, first_page: u16, last_page: u16, dead: bool = false, next_dead: ?*Block = null }`
  - `block.compile(allocator: std.mem.Allocator, bus: *const Bus, pc: u32) !*Block` (`pc` must satisfy `regionOf(pc & 0x1FFF_FFFF) != null`)
  - `block.destroy(allocator: std.mem.Allocator, b: *Block) void`
  - `run.zig` re-exports: `pub const block = @import("block.zig");`
  - `root.zig`: `pub const recompiler = @import("recompiler/run.zig");`

- [ ] **Step 1: Write the failing tests** (new file `ps1-core/tests/recompiler_test.zig`)

```zig
//! The block engines: where a block ends, how the cache stays honest when
//! code is rewritten, and the dispatcher's timing and interrupt rules. These
//! are the block engines' own contracts. They are not bit-exact against the
//! interpreter, so nothing here compares cycle counts with it.

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const alloc = std.testing.allocator;

const ps1_core = @import("ps1_core");
const Bus = ps1_core.memory.Bus;
const Cpu = ps1_core.cpu.Cpu;
const recompiler = ps1_core.recompiler;
const block = recompiler.block;

// Register numbers for the hand-written programs.
const zero: u5 = 0;
const a0: u5 = 4;
const t0: u5 = 8;
const t1: u5 = 9;
const t2: u5 = 10;
const t3: u5 = 11;
const t4: u5 = 12;
const t5: u5 = 13;
const t6: u5 = 14;
const t7: u5 = 15;
const ra: u5 = 31;

/// MIPS encoders. Branch offsets count instructions from the delay slot.
const mips = struct {
    const nop: u32 = 0;
    const rfe: u32 = 0x4200_0010;
    const syscall: u32 = 0x0000_000C;
    const brk: u32 = 0x0000_000D;
    /// GTE SQR, sf=0: MAC1..3 = IR1..3 squared.
    const gte_sqr: u32 = 0x4A00_0028;

    fn i(op: u32, rs: u5, rt: u5, imm: u16) u32 {
        return op << 26 | @as(u32, rs) << 21 | @as(u32, rt) << 16 | imm;
    }
    fn r(rs: u5, rt: u5, rd: u5, funct: u32) u32 {
        return @as(u32, rs) << 21 | @as(u32, rt) << 16 | @as(u32, rd) << 11 | funct;
    }
    fn addiu(rt: u5, rs: u5, imm: u16) u32 {
        return i(0x09, rs, rt, imm);
    }
    fn lui(rt: u5, imm: u16) u32 {
        return i(0x0F, 0, rt, imm);
    }
    fn ori(rt: u5, rs: u5, imm: u16) u32 {
        return i(0x0D, rs, rt, imm);
    }
    fn lw(rt: u5, base: u5, off: u16) u32 {
        return i(0x23, base, rt, off);
    }
    fn sw(rt: u5, base: u5, off: u16) u32 {
        return i(0x2B, base, rt, off);
    }
    fn addu(rd: u5, rs: u5, rt: u5) u32 {
        return r(rs, rt, rd, 0x21);
    }
    fn add(rd: u5, rs: u5, rt: u5) u32 {
        return r(rs, rt, rd, 0x20);
    }
    fn beq(rs: u5, rt: u5, off: i16) u32 {
        return i(0x04, rs, rt, @bitCast(off));
    }
    fn bne(rs: u5, rt: u5, off: i16) u32 {
        return i(0x05, rs, rt, @bitCast(off));
    }
    fn j(target: u32) u32 {
        return 0x02 << 26 | (target >> 2) & 0x03FF_FFFF;
    }
    fn jr(rs: u5) u32 {
        return r(rs, 0, 0, 0x08);
    }
    fn mtc0(rt: u5, rd: u5) u32 {
        return 0x10 << 26 | 0x04 << 21 | @as(u32, rt) << 16 | @as(u32, rd) << 11;
    }
};

fn poke(bus: *Bus, addr: u32, words: []const u32) void {
    for (words, 0..) |w, k| bus.write32(addr + @as(u32, @intCast(k)) * 4, w);
}

fn nops(comptime n: usize) [n]u32 {
    return @splat(mips.nop);
}

fn compileAt(bus: *Bus, pc: u32) !*block.Block {
    return block.compile(alloc, bus, pc);
}

test "a block ends after a branch's delay slot" {
    const bus = try Bus.init(alloc);
    defer bus.deinit(alloc);
    poke(bus, 0x1000, &.{ mips.nop, mips.nop, mips.beq(zero, zero, 4), mips.nop, mips.nop });
    const b = try compileAt(bus, 0x8000_1000);
    defer block.destroy(alloc, b);
    try expectEqual(@as(usize, 4), b.ops.len);
    try expectEqual(@as(u32, 0x8000_1000), b.start_pc);
}

test "the length cap ends a block at 64 instructions" {
    const bus = try Bus.init(alloc);
    defer bus.deinit(alloc);
    poke(bus, 0x2000, &nops(100));
    const b = try compileAt(bus, 0x2000);
    defer block.destroy(alloc, b);
    try expectEqual(@as(usize, block.max_len), b.ops.len);
}

test "a branch at the length cap stretches the block by its delay slot" {
    const bus = try Bus.init(alloc);
    defer bus.deinit(alloc);
    poke(bus, 0x2000, &nops(63));
    poke(bus, 0x2000 + 63 * 4, &.{ mips.beq(zero, zero, 4), mips.nop, mips.nop });
    const b = try compileAt(bus, 0x2000);
    defer block.destroy(alloc, b);
    try expectEqual(@as(usize, block.max_len + 1), b.ops.len);
}

test "a 4 KB page edge ends a block" {
    const bus = try Bus.init(alloc);
    defer bus.deinit(alloc);
    poke(bus, 0x3FF0, &nops(8));
    const b = try compileAt(bus, 0x3FF0);
    defer block.destroy(alloc, b);
    try expectEqual(@as(usize, 4), b.ops.len);
    try expectEqual(b.first_page, b.last_page);
}

test "a branch in a page's last word takes its delay slot from the next page" {
    const bus = try Bus.init(alloc);
    defer bus.deinit(alloc);
    poke(bus, 0x4FF8, &.{ mips.nop, mips.beq(zero, zero, 4), mips.nop, mips.nop });
    const b = try compileAt(bus, 0x4FF8);
    defer block.destroy(alloc, b);
    try expectEqual(@as(usize, 3), b.ops.len);
    try expectEqual(@as(u16, 4), b.first_page);
    try expectEqual(@as(u16, 5), b.last_page);
}

test "mtc0, rfe, syscall and break each end a block" {
    const bus = try Bus.init(alloc);
    defer bus.deinit(alloc);
    for ([_]u32{ mips.mtc0(t0, 12), mips.rfe, mips.syscall, mips.brk }) |ender| {
        poke(bus, 0x6000, &.{ mips.nop, ender, mips.nop, mips.nop });
        const b = try compileAt(bus, 0x6000);
        defer block.destroy(alloc, b);
        try expectEqual(@as(usize, 2), b.ops.len);
    }
}

test "loads and stores are flagged for the mid-block cycle commit" {
    const bus = try Bus.init(alloc);
    defer bus.deinit(alloc);
    poke(bus, 0x7000, &.{ mips.addiu(t0, zero, 1), mips.lw(t1, t0, 0), mips.sw(t1, t0, 0), mips.jr(ra), mips.nop });
    const b = try compileAt(bus, 0x7000);
    defer block.destroy(alloc, b);
    try expect(!b.ops[0].memory);
    try expect(b.ops[1].memory);
    try expect(b.ops[2].memory);
    try expect(!b.ops[3].memory);
}

test "a BIOS block decodes from the BIOS image" {
    const bus = try Bus.init(alloc);
    defer bus.deinit(alloc);
    std.mem.writeInt(u32, bus.bios[0..4], mips.addiu(t0, zero, 7), .little);
    std.mem.writeInt(u32, bus.bios[4..8], mips.jr(ra), .little);
    const b = try compileAt(bus, 0xBFC0_0000);
    defer block.destroy(alloc, b);
    try expectEqual(@as(usize, 3), b.ops.len);
    try expectEqual(mips.addiu(t0, zero, 7), b.ops[0].instr.raw);
    try expectEqual(@as(?block.Region, .bios), block.regionOf(0x1FC0_0000));
    try expectEqual(@as(?block.Region, null), block.regionOf(0x1F80_0000));
}
```

Add `"ps1-core/tests/recompiler_test.zig",` to `unit_test_files` in `build.zig`.

- [ ] **Step 2: Run them to make sure they fail**

Run: `zig build test -Dtest-filter="block"`
Expected: compile error, `recompiler` not found in `ps1_core`.

- [ ] **Step 3: Implement `block.zig`**

```zig
//! Where a block begins and ends. This file alone decides, so every block
//! engine executes the same boundaries.
//!
//! A block ends at: a branch or jump plus its delay slot; the length cap;
//! a 4 KB page edge; or an instruction that changes interrupt or memory
//! state (mtc0, rfe, syscall, break). A branch is never separated from its
//! delay slot: the cap and the page edge both stretch by one instruction to
//! take it. The run-time exits (an MMIO store, a store that invalidates the
//! running block) are `Bus.block_exit`'s, not this file's.

const std = @import("std");
const Bus = @import("../memory.zig").Bus;
const exec = @import("../cpu/exec.zig");

pub const max_len: usize = 64;
pub const page_shift: u5 = 12;
const page_mask: u32 = (1 << page_shift) - 1;

const phys_mask: u32 = 0x1FFF_FFFF;
const ram_mask: u32 = 0x001F_FFFF;
const bios_base: u32 = 0x1FC0_0000;
const bios_mask: u32 = 0x0007_FFFF;

pub const Op = struct {
    handler: exec.Handler,
    instr: exec.Instruction,
    /// A load or store. The block commits its elapsed cycles before it, so
    /// an MMIO access syncs the devices to the right time.
    memory: bool,
};

pub const Block = struct {
    /// The virtual PC it was compiled from.
    start_pc: u32,
    ops: []Op,
    /// The 4 KB RAM pages its words came from. Equal unless a branch in a
    /// page's last word took its delay slot from the next page. Unused for
    /// a BIOS block, which is never invalidated.
    first_page: u16,
    last_page: u16,
    /// Dropped by invalidation and queued for the dispatcher to free
    /// (`cache.zig`): the running block may be the one dropped.
    dead: bool = false,
    next_dead: ?*Block = null,
};

pub const Region = enum { ram, bios };

/// The table a physical PC's block lives in, or null where none can: such
/// a PC runs one interpreter step, which raises the right fetch bus error.
pub fn regionOf(phys: u32) ?Region {
    return switch (phys) {
        0x0000_0000...0x007F_FFFF => .ram, // 2 MB, mirrored 4x
        bios_base...bios_base + bios_mask => .bios,
        else => null,
    };
}

pub fn ramPage(phys: u32) u16 {
    return @intCast((phys & ram_mask) >> page_shift);
}

fn fetch(bus: *const Bus, region: Region, phys: u32) u32 {
    return switch (region) {
        .ram => std.mem.readInt(u32, bus.ram[phys & ram_mask & ~@as(u32, 3) ..][0..4], .little),
        .bios => std.mem.readInt(u32, bus.bios[(phys - bios_base) & bios_mask & ~@as(u32, 3) ..][0..4], .little),
    };
}

fn isBranch(raw: u32) bool {
    const op = raw >> 26;
    if (op >= 0x01 and op <= 0x07) return true; // REGIMM, J, JAL, BEQ, BNE, BLEZ, BGTZ
    const funct = raw & 0x3F;
    return op == 0 and (funct == 0x08 or funct == 0x09); // JR, JALR
}

/// Changes interrupt or memory state, so the dispatcher must look again
/// before the next instruction.
fn endsBlock(raw: u32) bool {
    const op = raw >> 26;
    const funct = raw & 0x3F;
    if (op == 0) return funct == 0x0C or funct == 0x0D; // SYSCALL, BREAK
    if (op == 0x10) {
        const rs = (raw >> 21) & 0x1F;
        return rs == 0x04 or (rs >= 0x10 and funct == 0x10); // MTC0, RFE
    }
    return false;
}

fn isMemory(raw: u32) bool {
    const op = raw >> 26;
    return op >= 0x20 and op <= 0x3B; // loads, stores, LWCn, SWCn
}

pub fn compile(allocator: std.mem.Allocator, bus: *const Bus, pc: u32) !*Block {
    const phys = pc & phys_mask;
    const region = regionOf(phys).?;

    var words: [max_len + 1]u32 = undefined;
    var n: usize = 0;
    var addr = phys;
    while (true) {
        const raw = fetch(bus, region, addr);
        words[n] = raw;
        n += 1;
        addr +%= 4;
        if (n >= 2 and isBranch(words[n - 2])) break; // that was its delay slot
        if (isBranch(raw)) continue;
        if (endsBlock(raw)) break;
        if (n == max_len) break;
        if (addr & page_mask == 0) break;
    }

    const ops = try allocator.alloc(Op, n);
    errdefer allocator.free(ops);
    for (words[0..n], ops) |raw, *op| {
        op.* = .{ .handler = exec.handlerFor(raw), .instr = exec.decode(raw), .memory = isMemory(raw) };
    }

    const b = try allocator.create(Block);
    b.* = .{
        .start_pc = pc,
        .ops = ops,
        .first_page = ramPage(phys),
        .last_page = ramPage(phys +% @as(u32, @intCast(n - 1)) * 4),
    };
    return b;
}

pub fn destroy(allocator: std.mem.Allocator, b: *Block) void {
    allocator.free(b.ops);
    allocator.destroy(b);
}
```

Create `ps1-core/src/recompiler/run.zig` with:

```zig
//! The block engines' entry point. See
//! docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md.

pub const block = @import("block.zig");
```

In `root.zig`, after the `scheduler` line, add
`pub const recompiler = @import("recompiler/run.zig");`.

- [ ] **Step 4: Run the tests**

Run: `zig build test -Dtest-filter="block"`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
zig fmt ps1-core/src/recompiler/block.zig ps1-core/src/recompiler/run.zig ps1-core/src/root.zig ps1-core/tests/recompiler_test.zig build.zig
git add ps1-core/src/recompiler ps1-core/src/root.zig ps1-core/tests/recompiler_test.zig build.zig
git commit -m "feat(core): block decoding and termination rules for the block engines"
```

---

### Task 4: `cache.zig` and invalidation in the bus

**Files:**
- Create: `ps1-core/src/recompiler/cache.zig`
- Modify: `ps1-core/src/recompiler/run.zig` (re-export `cache`)
- Modify: `ps1-core/src/memory.zig` (fields `blocks`, `block_exit`; `deinit`; `write()`'s exit flag and RAM-case invalidation; `writeCpuStore`'s exp3 branch)
- Test: `ps1-core/tests/recompiler_test.zig`

**Interfaces:**
- Consumes: `block.Block`, `block.compile`, `block.destroy`, `block.regionOf`, `block.page_shift` (Task 3).
- Produces:
  - `cache.BlockCache` with:
    - `create(allocator) !*BlockCache` and `destroy(self) void`
    - `lookup(self, phys: u32) ?*Block`
    - `insert(self, phys: u32, b: *Block) !void`
    - `onRamWrite(self, offset: u32) bool` (inline: true when the running block was dropped)
    - `flush(self) void` (frees every block) and `reap(self) void` (frees the dead queue)
    - fields `running: ?*Block = null`, `icache_dirty: bool = false`, `invalidations: [ram_pages]u32`
  - `Bus.blocks: ?*cache.BlockCache = null` and `Bus.block_exit: bool = false`
  - `run.zig` re-exports `pub const cache = @import("cache.zig");`

- [ ] **Step 1: Write the failing tests** (append to `recompiler_test.zig`)

```zig
const BlockCache = recompiler.cache.BlockCache;

/// A bus carrying a block cache, as `recompiler.setEngine(.cached)` will
/// leave it (Task 5); `Bus.deinit` frees it.
fn busWithCache() !*Bus {
    const bus = try Bus.init(alloc);
    bus.blocks = try BlockCache.create(alloc);
    return bus;
}

fn compileInto(bus: *Bus, pc: u32) !*block.Block {
    const b = try block.compile(alloc, bus, pc);
    try bus.blocks.?.insert(pc & 0x1FFF_FFFF, b);
    return b;
}

/// Starts an OTC DMA (channel 6) that writes `words` words ending at
/// `last`, and runs it to completion the way `Cpu.step()` would.
fn runOtc(bus: *Bus, last: u32, words: u32) void {
    bus.write32(0x1F8010F0, 0x0800_0000); // DPCR: channel 6 enabled
    bus.write32(0x1F8010E0, last); // MADR
    bus.write32(0x1F8010E4, words); // BCR
    bus.write32(0x1F8010E8, 0x1100_0002); // start + trigger, decrementing
    while (bus.dma.isCpuStalled(bus)) _ = bus.dma.step(bus);
}

test "a CPU store into a code page drops the page's blocks" {
    const bus = try busWithCache();
    defer bus.deinit(alloc);
    poke(bus, 0x1000, &.{ mips.jr(ra), mips.nop });
    poke(bus, 0x9000, &.{ mips.jr(ra), mips.nop });
    _ = try compileInto(bus, 0x1000);
    _ = try compileInto(bus, 0x9000);

    bus.write32(0x1F00, 0x1234); // same 4 KB page as 0x1000
    try expectEqual(@as(?*block.Block, null), bus.blocks.?.lookup(0x1000));
    try expect(bus.blocks.?.lookup(0x9000) != null); // another page: untouched
    try expectEqual(@as(u32, 1), bus.blocks.?.invalidations[1]);
    try expect(!bus.block_exit); // nothing was running
    bus.blocks.?.reap();
}

test "a store through a RAM mirror drops the same blocks" {
    const bus = try busWithCache();
    defer bus.deinit(alloc);
    poke(bus, 0x1000, &.{ mips.jr(ra), mips.nop });
    _ = try compileInto(bus, 0x1000);
    bus.write32(0x0060_1004, 0); // 6 MB mirror of 0x1004
    try expectEqual(@as(?*block.Block, null), bus.blocks.?.lookup(0x1000));
    bus.blocks.?.reap();
}

test "a DMA into a code page drops the page's blocks" {
    const bus = try busWithCache();
    defer bus.deinit(alloc);
    poke(bus, 0x2000, &.{ mips.jr(ra), mips.nop });
    _ = try compileInto(bus, 0x2000);
    runOtc(bus, 0x203C, 16); // writes 0x2000..0x203C
    try expectEqual(@as(?*block.Block, null), bus.blocks.?.lookup(0x2000));
    bus.blocks.?.reap();
}

test "a write to either page of a page-crossing block drops it" {
    for ([_]u32{ 0x4000, 0x5004 }) |target| {
        const bus = try busWithCache();
        defer bus.deinit(alloc);
        poke(bus, 0x4FF8, &.{ mips.nop, mips.beq(zero, zero, 4), mips.nop, mips.nop });
        _ = try compileInto(bus, 0x4FF8);
        bus.write32(target, 0);
        try expectEqual(@as(?*block.Block, null), bus.blocks.?.lookup(0x4FF8));
        bus.blocks.?.reap();
        // Neither page still claims code: a second write costs nothing.
        bus.write32(0x4000, 0);
        bus.write32(0x5004, 0);
        try expectEqual(@as(u32, 1), bus.blocks.?.invalidations[4] + bus.blocks.?.invalidations[5]);
    }
}

test "a store that drops the running block raises block_exit and leaves it alive" {
    const bus = try busWithCache();
    defer bus.deinit(alloc);
    poke(bus, 0x1000, &.{ mips.nop, mips.jr(ra), mips.nop });
    const b = try compileInto(bus, 0x1000);
    bus.blocks.?.running = b;
    bus.write32(0x1004, mips.nop);
    try expect(bus.block_exit);
    try expect(b.dead);
    try expectEqual(@as(usize, 3), b.ops.len); // still readable until reaped
    bus.blocks.?.running = null;
    bus.blocks.?.reap();
}

test "an MMIO store raises block_exit; RAM and scratchpad stores do not" {
    const bus = try busWithCache();
    defer bus.deinit(alloc);
    bus.write32(0x0000_8000, 1);
    try expect(!bus.block_exit);
    bus.write32(0x1F80_0000, 1); // scratchpad
    try expect(!bus.block_exit);
    bus.write32(0x1F80_1128, 100); // timer 2 target
    try expect(bus.block_exit);
}

test "BIOS blocks survive RAM writes; flush frees everything" {
    const bus = try busWithCache();
    defer bus.deinit(alloc);
    std.mem.writeInt(u32, bus.bios[0..4], mips.jr(ra), .little);
    poke(bus, 0x1000, &.{ mips.jr(ra), mips.nop });
    _ = try compileInto(bus, 0xBFC0_0000);
    _ = try compileInto(bus, 0x1000);
    bus.write32(0x0, 0);
    bus.write32(0x1000 - 4, 0); // page 0 and page 1
    try expect(bus.blocks.?.lookup(0x1FC0_0000) != null);
    bus.blocks.?.flush();
    try expectEqual(@as(?*block.Block, null), bus.blocks.?.lookup(0x1FC0_0000));
    try expectEqual(@as(?*block.Block, null), bus.blocks.?.lookup(0x1000));
    // The testing allocator fails the test if flush leaked a block.
}
```

Note that `0x1000 - 4` is `0xFFC`, which is page 0. The block at `0x1000` lives
in page 1, so it survives until `flush`. The test is about `flush`, not about
that write.

- [ ] **Step 2: Run them to make sure they fail**

Run: `zig build test -Dtest-filter="drop"`
Expected: compile error, `recompiler.cache` / `Bus.blocks` not found.

- [ ] **Step 3: Implement `cache.zig`**

```zig
//! Physical PC -> Block, and the bookkeeping that keeps RAM blocks honest.
//!
//! A RAM write that lands in a 4 KB page holding code drops every block in
//! that page. `Bus.write` is the one RAM-write path: CPU stores and every
//! DMA word both pass through it. The only writes that bypass it are
//! `Cpu.loadExe`'s and a savestate load's `@memcpy`, and both flush.
//!
//! A dropped block is freed by the dispatcher (`reap`), never by the store
//! that dropped it: the running block may still be iterating its own ops.

const std = @import("std");
const block = @import("block.zig");
const Block = block.Block;

const ram_words = (2 << 20) / 4;
const bios_words = (512 << 10) / 4;
pub const ram_pages = (2 << 20) >> block.page_shift; // 512
const ram_mask: u32 = 0x001F_FFFF;
const bios_base: u32 = 0x1FC0_0000;

pub const BlockCache = struct {
    allocator: std.mem.Allocator,
    ram: []?*Block,
    bios: []?*Block,
    /// One bit per RAM page holding a live block. While it is clear, this
    /// is the whole cost a RAM write pays.
    has_code: [ram_pages / 64]u64 = @splat(0),
    page_blocks: [ram_pages]std.ArrayList(*Block) = @splat(.empty),
    /// Invalidations per page. A game that keeps hot data beside its code
    /// shows up here; smaller pages only if a measurement asks.
    invalidations: [ram_pages]u32 = @splat(0),
    /// Dropped blocks waiting for `reap`, linked through `next_dead`.
    dead: ?*Block = null,
    /// The block a block engine is executing, so a store into it can end it.
    running: ?*Block = null,
    /// An interpreter fallback step has filled I-cache lines since the last
    /// block; the dispatcher flushes them before the next one (see `run.zig`).
    icache_dirty: bool = false,

    pub fn create(allocator: std.mem.Allocator) !*BlockCache {
        const self = try allocator.create(BlockCache);
        errdefer allocator.destroy(self);
        const ram = try allocator.alloc(?*Block, ram_words);
        errdefer allocator.free(ram);
        const bios = try allocator.alloc(?*Block, bios_words);
        @memset(ram, null);
        @memset(bios, null);
        self.* = .{ .allocator = allocator, .ram = ram, .bios = bios };
        return self;
    }

    pub fn destroy(self: *BlockCache) void {
        self.flush();
        for (&self.page_blocks) |*list| list.deinit(self.allocator);
        self.allocator.free(self.ram);
        self.allocator.free(self.bios);
        self.allocator.destroy(self);
    }

    fn slot(self: *BlockCache, phys: u32) *?*Block {
        return switch (block.regionOf(phys).?) {
            .ram => &self.ram[(phys & ram_mask) >> 2],
            .bios => &self.bios[(phys - bios_base) >> 2],
        };
    }

    pub fn lookup(self: *BlockCache, phys: u32) ?*Block {
        return self.slot(phys).*;
    }

    pub fn insert(self: *BlockCache, phys: u32, b: *Block) !void {
        if (block.regionOf(phys).? == .ram) {
            try self.page_blocks[b.first_page].append(self.allocator, b);
            if (b.last_page != b.first_page) {
                self.page_blocks[b.last_page].append(self.allocator, b) catch |err| {
                    _ = self.page_blocks[b.first_page].pop();
                    return err;
                };
                self.setBit(b.last_page);
            }
            self.setBit(b.first_page);
        }
        self.slot(phys).* = b;
    }

    /// The RAM write hook. True when the running block was among those
    /// dropped, so the block must stop after this store.
    pub inline fn onRamWrite(self: *BlockCache, offset: u32) bool {
        const page: u16 = @intCast(offset >> block.page_shift);
        if (!self.hasBit(page)) return false;
        return self.invalidatePage(page);
    }

    fn invalidatePage(self: *BlockCache, page: u16) bool {
        self.invalidations[page] += 1;
        var hit_running = false;
        while (self.page_blocks[page].pop()) |b| {
            if (b == self.running) hit_running = true;
            self.drop(b, page);
        }
        self.clearBit(page);
        return hit_running;
    }

    /// Unlinks `b` from its table slot and from the other page it straddles,
    /// and queues it for `reap`. `from_page`'s own list is the caller's.
    fn drop(self: *BlockCache, b: *Block, from_page: u16) void {
        const s = self.slot(b.start_pc & 0x1FFF_FFFF);
        if (s.* == b) s.* = null;
        const other = if (b.first_page == from_page) b.last_page else b.first_page;
        if (other != from_page) {
            const list = &self.page_blocks[other];
            for (list.items, 0..) |x, k| {
                if (x == b) {
                    _ = list.swapRemove(k);
                    break;
                }
            }
            if (list.items.len == 0) self.clearBit(other);
        }
        b.dead = true;
        b.next_dead = self.dead;
        self.dead = b;
    }

    /// Frees the dropped blocks. Only between blocks.
    pub fn reap(self: *BlockCache) void {
        while (self.dead) |b| {
            self.dead = b.next_dead;
            block.destroy(self.allocator, b);
        }
    }

    /// Frees every block. Each live block sits in exactly one table slot,
    /// its start, so walking the tables frees each once.
    pub fn flush(self: *BlockCache) void {
        self.reap();
        for (self.ram) |*s| if (s.*) |b| {
            block.destroy(self.allocator, b);
            s.* = null;
        };
        for (self.bios) |*s| if (s.*) |b| {
            block.destroy(self.allocator, b);
            s.* = null;
        };
        for (&self.page_blocks) |*list| list.clearRetainingCapacity();
        self.has_code = @splat(0);
        self.running = null;
    }

    fn hasBit(self: *const BlockCache, page: u16) bool {
        return self.has_code[page >> 6] & (@as(u64, 1) << @intCast(page & 63)) != 0;
    }
    fn setBit(self: *BlockCache, page: u16) void {
        self.has_code[page >> 6] |= @as(u64, 1) << @intCast(page & 63);
    }
    fn clearBit(self: *BlockCache, page: u16) void {
        self.has_code[page >> 6] &= ~(@as(u64, 1) << @intCast(page & 63));
    }
};
```

A table slot can be overwritten while the old block is still live. The
dispatcher never does this, because it compiles only on a lookup miss. The
`s.* == b` check in `drop` exists for that reason, and `flush` reaches every
live block through its slot. If the compiler rejects the `for ... |*s| if
(s.*) |b| { ... };` form, write the loop with a braced body.

Add `pub const cache = @import("cache.zig");` to `run.zig`.

- [ ] **Step 4: Hook the bus** (`memory.zig`)

Import at the top: `const BlockCache = @import("recompiler/cache.zig").BlockCache;`

Fields, after `sched`:

```zig
    /// The block engines' code cache, allocated only while one is selected
    /// (`recompiler.setEngine`). Owned here and freed by `deinit`, so a
    /// fresh `Bus` never carries blocks compiled from another machine's RAM.
    blocks: ?*BlockCache = null,
    /// Set by a store a block must not run past: one to anything but RAM or
    /// scratchpad (it may raise an interrupt, start a DMA or touch I_STAT),
    /// and one that dropped the running block. Cleared at each block start.
    block_exit: bool = false,
```

Both default off and `Bus.init`'s `@memset` leaves them off. Do **not** assign
them in `init`.

In `deinit`, before `allocator.destroy(self)`: `if (self.blocks) |c| c.destroy();`

At the top of `fn write`, right after `const paddr = ...`:

```zig
        const is_memory = paddr <= Addr.ram_mirror_last or
            (paddr >= Addr.scratchpad_base and paddr <= Addr.scratchpad_last);
        if (!is_memory) self.block_exit = true;
```

Replace the RAM arm of `write`'s final switch:

```zig
            // 2 MB RAM, mirrored 4x across the first 8 MB (PSX-SPX memory map).
            Addr.ram_base...Addr.ram_mirror_last => {
                const offset = paddr & Addr.ram_size_mask;
                writeMem(T, &self.ram, offset, value);
                if (self.blocks) |c| {
                    if (c.onRamWrite(offset)) self.block_exit = true;
                }
            },
```

In `writeCpuStore`, the expansion-3 branch returns without reaching `write`.
Add `self.block_exit = true;` before its `self.writeExpansion3(...)` call.

- [ ] **Step 5: Run the tests**

Run: `zig build test -Dtest-filter="drop" && zig build test -Dtest-filter="block_exit" && zig build test -Dtest-filter="flush" && zig build test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
zig fmt ps1-core/src/recompiler/cache.zig ps1-core/src/recompiler/run.zig ps1-core/src/memory.zig ps1-core/tests/recompiler_test.zig
git add ps1-core/src/recompiler ps1-core/src/memory.zig ps1-core/tests/recompiler_test.zig
git commit -m "feat(core): block cache with per-page invalidation on every RAM write"
```

---

### Task 5: The cached interpreter and the dispatcher's core loop

**Files:**
- Create: `ps1-core/src/recompiler/cached.zig`
- Modify: `ps1-core/src/recompiler/run.zig` (`Engine`, `setEngine`, `engineOf`, `fetchCost`, `run`)
- Modify: `ps1-core/src/cpu/cpu.zig` (`Cpu.run`)
- Modify: `ps1-core/src/memory.zig` (`waitCycles` pulled out of `addWaitCycles`)
- Test: `ps1-core/tests/recompiler_test.zig`

**Interfaces:**
- Consumes: `Cpu.beginInstruction`, `retireLoad`, `chargeCycles`, `exception_taken` (Task 2); `scheduler.serviceDue` (Task 2); `block.compile`, `block.regionOf` (Task 3); `BlockCache` (Task 4).
- Produces:
  - `recompiler.Engine = enum { interpreter, cached, jit }`
  - `recompiler.setEngine(cpu: *Cpu, allocator: std.mem.Allocator, engine: Engine) error{ OutOfMemory, EngineUnavailable }!void`
  - `recompiler.engineOf(bus: *const Bus) Engine`
  - `recompiler.run(cpu: *Cpu, cache: *BlockCache) void`
  - `cached.execute(cpu: *Cpu, b: *const Block, fetch_cost: u32) void`
  - `Cpu.run(self) void`: one block under a block engine, one `step()` otherwise
  - `Bus.waitCycles(self: *const Bus, comptime T: type, virtual_address: u32, is_write: bool) u32`

- [ ] **Step 1: Write the failing tests** (append to `recompiler_test.zig`)

```zig
const Engine = recompiler.Engine;

const Machine = struct {
    bus: *Bus,
    cpu: Cpu,

    fn init(engine: Engine) !Machine {
        const bus = try Bus.init(alloc);
        var m: Machine = .{ .bus = bus, .cpu = Cpu.init(bus) };
        try recompiler.setEngine(&m.cpu, alloc, engine);
        return m;
    }

    fn deinit(m: *Machine) void {
        m.bus.deinit(alloc);
    }

    fn start(m: *Machine, pc: u32) void {
        m.cpu.pipeline.pc = pc;
        m.cpu.pipeline.next_pc = pc +% 4;
    }

    fn runUntil(m: *Machine, pc: u32) !void {
        var n: u32 = 0;
        while (m.cpu.pipeline.pc != pc) : (n += 1) {
            if (n == 100_000) return error.NeverReached;
            m.cpu.run();
        }
    }
};

/// A loop with stores, loads read in their delay slot, a branch delay slot
/// and a load in a delay slot whose value lands inside the NEXT block.
const loop_program = [_]u32{
    mips.addiu(t0, zero, 0), // 0x1000
    mips.addiu(t1, zero, 10),
    mips.lui(t2, 0x8000),
    mips.ori(t2, t2, 0x2000),
    mips.sw(t1, t2, 0), // 0x1010 loop:
    mips.lw(t3, t2, 0),
    mips.addu(t0, t0, t3), // reads the previous t3: load delay
    mips.addiu(t2, t2, 4),
    mips.addiu(t1, t1, 0xFFFF),
    mips.bne(t1, zero, -6), // -> 0x1010
    mips.addu(t0, t0, t3), // delay slot
    mips.lw(t4, t2, 0xFFFC),
    mips.beq(zero, zero, 3), // -> 0x1040
    mips.lw(t5, t2, 0xFFF8), // delay slot: lands after done's first instruction
    mips.nop,
    mips.nop,
    mips.addu(t6, t5, zero), // 0x1040 done: the OLD t5
    mips.addu(t7, t5, zero), // the new t5
    mips.beq(zero, zero, -1), // 0x1048 end
    mips.nop,
};

test "the cached interpreter computes what the interpreter computes" {
    var ref = try Machine.init(.interpreter);
    defer ref.deinit();
    var blk = try Machine.init(.cached);
    defer blk.deinit();
    for ([_]*Machine{ &ref, &blk }) |m| {
        poke(m.bus, 0x1000, &loop_program);
        m.start(0x8000_1000);
        try m.runUntil(0x8000_1048);
    }
    try std.testing.expectEqualSlices(u32, &ref.cpu.regs, &blk.cpu.regs);
    try std.testing.expectEqualSlices(u8, ref.bus.ram[0x2000..0x2028], blk.bus.ram[0x2000..0x2028]);
    try expectEqual(@as(u32, 0), blk.cpu.regs[t6]); // load crossed the block boundary
    try expectEqual(@as(u32, 2), blk.cpu.regs[t7]);
}

test "an overflow inside a block is precise" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x1000, &.{
        mips.addiu(t0, zero, 1),
        mips.lui(t1, 0x7FFF),
        mips.ori(t1, t1, 0xFFFF),
        mips.add(t2, t1, t0), // 0x100C: overflows
        mips.addiu(t3, zero, 7), // must not run
        mips.jr(ra),
        mips.nop,
    });
    m.start(0x1000);
    m.cpu.run();
    try expectEqual(@as(u32, 0x8000_0080), m.cpu.pipeline.pc);
    try expectEqual(@as(u32, 0x100C), m.cpu.cop0.readReg(.epc));
    try expectEqual(@as(u32, 0x0C), (m.cpu.cop0.readReg(.cause) >> 2) & 0x1F);
    try expectEqual(@as(u32, 0), m.cpu.regs[t2]);
    try expectEqual(@as(u32, 0), m.cpu.regs[t3]);
    // Four instructions, faulting one included, at RAM's cached fetch cost of 0.
    try expectEqual(@as(u64, 4), m.cpu.cycles);
}

test "an MMIO read mid-block sees the block's elapsed cycles" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x1000, &(.{
        mips.lui(t1, 0x1F80),
        mips.ori(t1, t1, 0x1120), // timer 2 counter, sysclk
        mips.lw(t2, t1, 0),
    } ++ nops(10) ++ .{
        mips.lw(t3, t1, 0),
        mips.nop,
        mips.beq(zero, zero, -1),
        mips.nop,
    }));
    m.start(0x1000);
    m.cpu.run();
    // Between the two commits: 11 instructions at 1 cycle (fetch cost 0)
    // plus the first lw's 2 I/O wait states.
    try expectEqual(@as(u32, 13), m.cpu.regs[t3] - m.cpu.regs[t2]);
}

test "a store into the running block ends it; the rewrite runs next" {
    var m = try Machine.init(.cached);
    defer m.deinit();
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
    m.cpu.run();
    try expectEqual(@as(u32, 0x1010), m.cpu.pipeline.pc);
    try expectEqual(@as(u32, 0), m.cpu.regs[t2]);
    try expectEqual(@as(?*block.Block, null), m.bus.blocks.?.lookup(0x1000));
    m.cpu.run();
    try expectEqual(@as(u32, 0x55), m.cpu.regs[t2]);
}

test "the same block charges each segment's fetch cost" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x3000, &.{ mips.nop, mips.nop, mips.nop, mips.j(0x3000), mips.nop });
    m.start(0x8000_3000);
    var before = m.cpu.cycles;
    m.cpu.run();
    try expectEqual(@as(u64, 5), m.cpu.cycles - before); // KSEG0: a cache hit, free
    m.start(0xA000_3000);
    before = m.cpu.cycles;
    m.cpu.run();
    try expectEqual(@as(u64, 25), m.cpu.cycles - before); // KSEG1: RAM's 4 per word
}

test "a block ticks SIO once per instruction" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x1000, &(nops(10) ++ .{ mips.j(0x1000), mips.nop }));
    m.bus.write8(0x1F801040, 0x01); // select the pad: arms /ACK
    ps1_core.scheduler.serviceDue(m.bus);
    const before = m.bus.sio.irq_timer;
    try expect(before > 12);
    m.start(0x1000);
    m.cpu.run();
    ps1_core.scheduler.sync(m.bus);
    try expectEqual(before - 12, m.bus.sio.irq_timer);
}

test "engine selection allocates, switches and frees the cache" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    try expectEqual(Engine.cached, recompiler.engineOf(m.bus));
    try recompiler.setEngine(&m.cpu, alloc, .interpreter);
    try expectEqual(@as(?*BlockCache, null), m.bus.blocks);
    try expectEqual(Engine.interpreter, recompiler.engineOf(m.bus));
    try std.testing.expectError(error.EngineUnavailable, recompiler.setEngine(&m.cpu, alloc, .jit));
}
```

If `bus.sio.irq_timer`'s type makes `before - 12` ambiguous, cast both sides to
`i64`. If `++` on these tuples does not concatenate into a `[N]u32`, build the
program as a `[_]u32` array literal with the nops written out.

- [ ] **Step 2: Run them to make sure they fail**

Run: `zig build test -Dtest-filter="cached interpreter"`
Expected: compile error, `recompiler.Engine` / `setEngine` not found.

- [ ] **Step 3: Pull `waitCycles` out of `addWaitCycles`** (`memory.zig`)

```zig
    /// The wait states one access of `T` at `virtual_address` costs.
    pub inline fn waitCycles(self: *const Self, comptime T: type, virtual_address: u32, is_write: bool) u32 {
        const paddr = virtual_address & Addr.phys_mask;
        const size = @sizeOf(T);
        return switch (paddr) {
            // (the existing arms, unchanged)
        };
    }

    // Helper method to simulate PS1 memory wait states
    pub inline fn addWaitCycles(self: *Self, comptime T: type, virtual_address: u32, is_write: bool) void {
        self.wait_cycles += self.waitCycles(T, virtual_address, is_write);
    }
```

- [ ] **Step 4: Implement `cached.zig`**

```zig
//! The cached interpreter: a block's words, decoded once into handler
//! calls. It has no instruction semantics of its own; every handler is
//! `exec.zig`'s, so a fix to an instruction fixes it here too.
//!
//! Gone per instruction, compared with `Cpu.step()`: the DMA-stall check,
//! the fetch bus-error check, the I-cache, the Cause.IP2 update and the
//! scheduler tick. The dispatcher does those once per block.

const Cpu = @import("../cpu/cpu.zig").Cpu;
const Block = @import("block.zig").Block;

/// Runs `b` from `cpu.pipeline.pc`, its start. Each instruction costs 1
/// plus `fetch_cost` plus its load/store wait states, as in the interpreter
/// with the I-cache replaced by a static fetch cost.
pub fn execute(cpu: *Cpu, b: *const Block, fetch_cost: u32) void {
    const bus = cpu.bus;
    cpu.exception_taken = false;
    bus.block_exit = false;
    // Charged but not yet handed to the scheduler.
    var cycles: u32 = 0;
    var steps: u32 = 0;
    for (b.ops) |op| {
        cycles += 1 + fetch_cost;
        if (op.memory) {
            // An MMIO access syncs the devices. Hand them this block's
            // cycles so far, up to and including this fetch. This
            // instruction's step counts after its access, as the
            // interpreter counts it: a JOY_TX store arms /ACK before its own
            // step ticks it.
            cpu.chargeCycles(cycles + bus.wait_cycles, steps);
            bus.wait_cycles = 0;
            cycles = 0;
            steps = 0;
        }
        cpu.pipeline.current_pc = cpu.pipeline.pc;
        cpu.beginInstruction();
        op.handler(cpu, op.instr);
        cpu.retireLoad();
        steps += 1;
        if (cpu.exception_taken or bus.block_exit) break;
    }
    cpu.chargeCycles(cycles + bus.wait_cycles, steps);
    bus.wait_cycles = 0;
}
```

- [ ] **Step 5: Implement the dispatcher's core** (`run.zig`, replacing the stub)

```zig
//! The block engines' dispatcher: one block, or one interpreter step, per
//! `run()`. See docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md.

const std = @import("std");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const Bus = @import("../memory.zig").Bus;
const icache = @import("../cpu/icache.zig");
const scheduler = @import("../cpu/scheduler.zig");
pub const block = @import("block.zig");
pub const cache = @import("cache.zig");
const cached = @import("cached.zig");
const BlockCache = cache.BlockCache;

pub const Engine = enum { interpreter, cached, jit };

/// Selects the CPU engine. A block engine's cache lives on `Bus` (see
/// `Bus.blocks`), so a frontend that swaps in a fresh `Bus` re-applies its
/// engine the way it re-applies its PGXP settings. Call between `run()`s.
pub fn setEngine(cpu: *Cpu, allocator: std.mem.Allocator, engine: Engine) error{ OutOfMemory, EngineUnavailable }!void {
    const bus = cpu.bus;
    switch (engine) {
        .interpreter => if (bus.blocks) |c| {
            c.destroy();
            bus.blocks = null;
        },
        .cached => if (bus.blocks) |c| c.flush() else {
            bus.blocks = try BlockCache.create(allocator);
        },
        .jit => return error.EngineUnavailable,
    }
    // The block engines leave the I-cache invalidated. Lines the interpreter
    // filled before a switch may describe RAM a block engine since rewrote.
    icache.flush(cpu);
}

pub fn engineOf(bus: *const Bus) Engine {
    return if (bus.blocks == null) .interpreter else .cached;
}

/// What a block charges per instruction for its fetch, in place of the
/// I-cache model: a cache hit (free) for RAM run through KUSEG/KSEG0, and
/// the uncached per-word cost for KSEG1 and for the BIOS. Read at every
/// block start, so a BIOS wait-state write applies from the next block.
fn fetchCost(bus: *const Bus, pc: u32) u32 {
    const cached_segment = pc < 0xA000_0000 or pc >= 0xC000_0000;
    if (cached_segment and block.regionOf(pc & 0x1FFF_FFFF) == .ram) return 0;
    return bus.waitCycles(u32, pc, false);
}

pub fn run(cpu: *Cpu, c: *BlockCache) void {
    const bus = cpu.bus;
    // The frame loop's vblank check reads what came due during this call.
    defer scheduler.serviceDue(bus);
    c.reap();
    // A block starts only when downcount > 0.
    scheduler.serviceDue(bus);

    const pc = cpu.pipeline.pc;
    const phys = pc & 0x1FFF_FFFF;
    if (block.regionOf(phys) == null) {
        cpu.step();
        c.icache_dirty = true;
        return;
    }

    const b = c.lookup(phys) orelse compileInto(c, bus, pc) catch {
        // Out of memory for a block: the interpreter still runs.
        cpu.step();
        c.icache_dirty = true;
        return;
    };

    c.running = b;
    cached.execute(cpu, b, fetchCost(bus, pc));
    c.running = null;
}

fn compileInto(c: *BlockCache, bus: *const Bus, pc: u32) !*block.Block {
    const b = try block.compile(c.allocator, bus, pc);
    errdefer block.destroy(c.allocator, b);
    try c.insert(pc & 0x1FFF_FFFF, b);
    return b;
}
```

If `orelse compileInto(...) catch { ... }` does not parse as intended, split it:
`const b = c.lookup(phys) orelse blk: { break :blk compileInto(c, bus, pc) catch { ...; return; }; };`

In `cpu.zig`, import `const recompiler = @import("../recompiler/run.zig");`
and add:

```zig
    /// One unit of work for a frame loop: a block under a block engine,
    /// one instruction under the interpreter.
    pub fn run(self: *Self) void {
        if (self.bus.blocks) |c| recompiler.run(self, c) else self.step();
    }
```

- [ ] **Step 6: Run the tests**

Run: `zig build test -Dtest-filter="cached interpreter" && zig build test -Dtest-filter="precise" && zig build test -Dtest-filter="elapsed" && zig build test -Dtest-filter="running block" && zig build test -Dtest-filter="segment" && zig build test -Dtest-filter="SIO" && zig build test -Dtest-filter="engine selection"`
Then: `zig build test`
Expected: PASS. Build and run these in Debug (the default), so the testing
allocator catches a use-after-free in the self-modifying test.

- [ ] **Step 7: Commit**

```bash
zig fmt ps1-core/src/recompiler/*.zig ps1-core/src/cpu/cpu.zig ps1-core/src/memory.zig ps1-core/tests/recompiler_test.zig
git add ps1-core/src/recompiler ps1-core/src/cpu/cpu.zig ps1-core/src/memory.zig ps1-core/tests/recompiler_test.zig
git commit -m "feat(core): the cached interpreter and Cpu.run"
```

---

### Task 6: The dispatcher's rules: DMA stalls, fallbacks, the TTY hook, interrupts and full flushes

**Files:**
- Modify: `ps1-core/src/recompiler/run.zig` (`run`)
- Modify: `ps1-core/src/cpu/cpu.zig` (`loadExe` flushes)
- Modify: `ps1-core/src/savestate/savestate.zig` (`load` flushes)
- Test: `ps1-core/tests/recompiler_test.zig`

**Interfaces:**
- Consumes: `Cpu.latchIrqLine`, `Cpu.biosCallHook`, `Cpu.exception`, `Cpu.chargeCycles` (Task 2); `BlockCache.icache_dirty`, `flush` (Task 4); `run`'s structure (Task 5).
- Produces: the finished `recompiler.run`. Its behaviour is pinned by the tests below.

- [ ] **Step 1: Write the failing tests** (append to `recompiler_test.zig`)

```zig
const Irq = ps1_core.interrupt.Irq;

fn raiseVblank(m: *Machine, sr_extra: u32) void {
    m.cpu.cop0.writeReg(.sr, sr_extra | (1 << 10) | 1); // IM2, IEc
    m.bus.interrupts.writeMask(1 << @backingInt(Irq.Vblank));
    m.bus.interrupts.trigger(.Vblank);
}

test "an interrupt is taken at a branch target, with EPC on the target" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x1000, &.{ mips.beq(zero, zero, 63), mips.nop }); // -> 0x1100
    poke(m.bus, 0x1100, &.{ mips.addiu(t0, zero, 1), mips.beq(zero, zero, -1), mips.nop });
    m.start(0x1000);
    m.cpu.run(); // the branch and its delay slot: is_delay_slot is left set
    try expectEqual(@as(u32, 0x1100), m.cpu.pipeline.pc);
    raiseVblank(&m, 0);
    m.cpu.run();
    try expectEqual(@as(u32, 0x8000_0080), m.cpu.pipeline.pc);
    try expectEqual(@as(u32, 0x1100), m.cpu.cop0.readReg(.epc));
    try expectEqual(@as(u32, 0), m.cpu.cop0.readReg(.cause) >> 31); // BD clear
    try expectEqual(@as(u32, 0), m.cpu.regs[t0]);
}

fn gteBlockMachine(irq: bool) !Machine {
    var m = try Machine.init(.cached);
    poke(m.bus, 0x1100, &.{ mips.gte_sqr, mips.beq(zero, zero, 0x3E), mips.nop }); // -> 0x1200
    poke(m.bus, 0x1200, &.{ mips.nop, mips.beq(zero, zero, -2), mips.nop });
    m.cpu.cop2.writeData(9, 4);
    if (irq) raiseVblank(&m, 1 << 30) else m.cpu.cop0.writeReg(.sr, 1 << 30); // CU2
    m.start(0x1100);
    return m;
}

test "an interrupt is refused before a GTE command and forces an exit" {
    var m = try gteBlockMachine(true);
    defer m.deinit();
    m.cpu.run();
    try expectEqual(@as(u32, 16), m.cpu.cop2.readData(9)); // the command ran
    try expectEqual(@as(u32, 0x1200), m.cpu.pipeline.pc); // not taken
    // The refusal zeroed downcount, so the block's end took the slow path.
    try expectEqual(@as(u32, 0), m.bus.sched.pending);
    m.cpu.run();
    try expectEqual(@as(u32, 0x8000_0080), m.cpu.pipeline.pc);
    try expectEqual(@as(u32, 0x1200), m.cpu.cop0.readReg(.epc));
}

test "without an interrupt the same block defers its cycles" {
    var m = try gteBlockMachine(false);
    defer m.deinit();
    m.cpu.run();
    try expect(m.bus.sched.pending > 0);
}

test "a block engine resumed on a delay slot runs it as one interpreter step" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x1000, &.{ mips.beq(zero, zero, 63), mips.addiu(t0, zero, 5) }); // -> 0x1100
    poke(m.bus, 0x1100, &.{ mips.addiu(t1, zero, 6), mips.beq(zero, zero, -1), mips.nop });
    m.start(0x1000);
    m.cpu.step(); // the interpreter runs the branch: next is its delay slot
    try expect(m.cpu.pipeline.next_is_delay_slot);
    m.cpu.run();
    try expectEqual(@as(u32, 5), m.cpu.regs[t0]);
    try expectEqual(@as(u32, 0x1100), m.cpu.pipeline.pc);
    try expectEqual(@as(u32, 0), m.cpu.regs[t1]);
    m.cpu.run();
    try expectEqual(@as(u32, 6), m.cpu.regs[t1]);
}

test "the interpreter runs while the cache is isolated" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x1000, &.{ mips.sw(t0, t1, 0), mips.beq(zero, zero, -1), mips.nop });
    m.cpu.regs[t0] = 0xDEAD;
    m.cpu.regs[t1] = 0x2000;
    m.cpu.cop0.writeReg(.sr, 1 << 16); // IsC
    m.start(0x1000);
    m.cpu.run();
    try expectEqual(@as(u32, 0x1004), m.cpu.pipeline.pc); // one step, not a block
    try expectEqual(@as(?*block.Block, null), m.bus.blocks.?.lookup(0x1000));
    try expectEqual(@as(u32, 0), m.bus.read32(0x2000)); // the store went to the I-cache
}

var tty_seen: ?u8 = null;
fn ttyCapture(_: ?*anyopaque, c: u8) void {
    tty_seen = c;
}

test "the putchar hook fires before a block at the A0 vector" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0xA0, &.{ mips.jr(ra), mips.nop });
    poke(m.bus, 0x1000, &.{ mips.beq(zero, zero, -1), mips.nop });
    m.cpu.tty_write_fn = ttyCapture;
    m.cpu.regs[t1] = 0x3C;
    m.cpu.regs[a0] = 'Z';
    m.cpu.regs[ra] = 0x1000;
    tty_seen = null;
    m.start(0xA0);
    m.cpu.run();
    try expectEqual(@as(?u8, 'Z'), tty_seen);
    try expectEqual(@as(u32, 0x1000), m.cpu.pipeline.pc);
}

test "a DMA-stalled run is one SIO step" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    m.bus.write8(0x1F801040, 0x01); // select the pad: arms /ACK
    m.bus.write32(0x1F8010F0, 0x0800_0000); // DPCR: channel 6
    m.bus.write32(0x1F8010E0, 0x0000_403C);
    m.bus.write32(0x1F8010E4, 16);
    m.bus.write32(0x1F8010E8, 0x1100_0002); // OTC: start + trigger
    try expect(m.bus.dma.isCpuStalled(m.bus));
    ps1_core.scheduler.sync(m.bus);
    const before = m.bus.sio.irq_timer;
    m.cpu.run();
    ps1_core.scheduler.sync(m.bus);
    try expectEqual(before - 1, m.bus.sio.irq_timer);
}

test "a DMA started by the store that ends a block runs to completion" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    m.bus.write32(0x1F8010F0, 0x0800_0000); // DPCR: channel 6
    m.bus.write32(0x1F8010E0, 0x0000_403C);
    m.bus.write32(0x1F8010E4, 16);
    poke(m.bus, 0x1000, &.{
        mips.lui(t1, 0x1F80),
        mips.ori(t1, t1, 0x10E8), // OTC CHCR
        mips.lui(t0, 0x1100),
        mips.ori(t0, t0, 0x0002), // start + trigger, decrementing
        mips.sw(t0, t1, 0), // ends the block with its tail cycles pending
        mips.nop,
        mips.beq(zero, zero, -1),
        mips.nop,
    });
    m.start(0x1000);
    m.cpu.run();
    try expect(m.bus.dma.isCpuStalled(m.bus));
    var n: u32 = 0;
    while (m.bus.dma.isCpuStalled(m.bus)) : (n += 1) {
        try expect(n < 1000);
        m.cpu.run(); // Debug: Cpu.step()'s pending == 0 assert is live
    }
    try expectEqual(@as(u32, 0x00FF_FFFF), m.bus.read32(0x4000)); // the list's terminator
}

test "loading an EXE drops blocks compiled from the RAM it overwrites" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x1000, &.{ mips.addiu(t0, zero, 0x11), mips.beq(zero, zero, -1), mips.nop });
    m.start(0x8000_1000);
    m.cpu.run();
    try expectEqual(@as(u32, 0x11), m.cpu.regs[t0]);

    var exe: [0x800 + 12]u8 = @splat(0);
    @memcpy(exe[0..8], "PS-X EXE");
    std.mem.writeInt(u32, exe[0x10..0x14], 0x8000_1000, .little); // pc
    std.mem.writeInt(u32, exe[0x18..0x1C], 0x8000_1000, .little); // dest
    std.mem.writeInt(u32, exe[0x1C..0x20], 12, .little); // size
    std.mem.writeInt(u32, exe[0x800..0x804], mips.addiu(t0, zero, 0x77), .little);
    std.mem.writeInt(u32, exe[0x804..0x808], mips.beq(zero, zero, -1), .little);
    try m.cpu.loadExe(&exe);
    m.cpu.run();
    try expectEqual(@as(u32, 0x77), m.cpu.regs[t0]);
}

test "loading a savestate flushes the block cache" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x1000, &.{ mips.beq(zero, zero, -1), mips.nop });
    const savestate = ps1_core.savestate;
    const buf = try alloc.alloc(u8, try savestate.save(&m.cpu, null));
    defer alloc.free(buf);
    _ = try savestate.save(&m.cpu, buf);
    m.start(0x1000);
    m.cpu.run();
    try expect(m.bus.blocks.?.lookup(0x1000) != null);
    try savestate.load(&m.cpu, buf);
    try expectEqual(@as(?*block.Block, null), m.bus.blocks.?.lookup(0x1000));
}
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `zig build test -Dtest-filter="interrupt"` and `zig build test -Dtest-filter="DMA"` and `zig build test -Dtest-filter="loading"`
Expected: FAIL. The interrupt is never taken (no check yet), the delay-slot and
IsC tests run a block, the stalled DMA trips the `pending == 0` assert, and
the stale block runs after `loadExe` and `savestate.load`.

- [ ] **Step 3: Finish `run`**

Replace `run` in `run.zig`:

```zig
const isc_bit: u32 = 1 << 16;

/// The COP2 command encoding the BIOS interrupt handler skips on return.
fn isGteCommand(raw: u32) bool {
    return (raw >> 24) & 0xFE == 0x4A;
}

pub fn run(cpu: *Cpu, c: *BlockCache) void {
    const bus = cpu.bus;
    // The frame loop's vblank check reads what came due during this call.
    defer scheduler.serviceDue(bus);
    c.reap();
    // A block starts only when downcount > 0.
    scheduler.serviceDue(bus);

    if (bus.dma.isCpuStalled(bus)) {
        // One DMA word is one step, exactly as in `step()`, which wants the
        // backlog handed over before it. A block that ended on the store
        // starting this DMA left its tail cycles pending.
        scheduler.sync(bus);
        cpu.step();
        return;
    }

    const pc = cpu.pipeline.pc;
    const phys = pc & 0x1FFF_FFFF;
    // The interpreter takes:
    //  - a delay slot: the instruction after it is `next_pc`, not the next
    //    word, which happens after an interpreter savestate, an engine
    //    switch or a fallback step;
    //  - anything while the cache is isolated: stores go to the I-cache
    //    (the mtc0 that sets IsC already ended the block);
    //  - a PC no block can live at: it raises the right fetch bus error.
    if (block.regionOf(phys) == null or
        cpu.pipeline.next_is_delay_slot or
        cpu.cop0.readReg(.sr) & isc_bit != 0)
    {
        cpu.step();
        c.icache_dirty = true;
        return;
    }
    if (c.icache_dirty) {
        icache.flush(cpu);
        c.icache_dirty = false;
    }

    cpu.biosCallHook(phys);

    const b = c.lookup(phys) orelse compileInto(c, bus, pc) catch {
        // Out of memory for a block: the interpreter still runs.
        cpu.step();
        c.icache_dirty = true;
        return;
    };
    const fetch_cost = fetchCost(bus, pc);

    // Interrupts are seen between blocks only, under the block engines' own
    // rule. The interpreter refuses one on a branch target; most blocks
    // start on one, so that rule would refuse almost every interrupt here.
    if (cpu.latchIrqLine()) {
        if (isGteCommand(b.ops[0].instr.raw)) {
            // Refused: the BIOS handler would skip the command. Force this
            // block back to the dispatcher, so every block engine takes the
            // interrupt one block later, linked or not.
            bus.sched.downcount = 0;
        } else {
            // A block that ended on a delay slot leaves is_delay_slot set,
            // which would put EPC on the branch and set Cause.BD. The
            // interrupted instruction is this block's first.
            cpu.pipeline.current_pc = pc;
            cpu.pipeline.is_delay_slot = false;
            cpu.exception(.Interrupt, 0);
            cpu.chargeCycles(1 + fetch_cost, 1);
            return;
        }
    }

    c.running = b;
    cached.execute(cpu, b, fetch_cost);
    c.running = null;
}
```

- [ ] **Step 4: Flush on the two RAM writes that bypass the bus**

In `Cpu.loadExe`, right after the `@memcpy` into `self.bus.ram`:

```zig
        // Bypasses `Bus.write`, so no block in the overwritten range knows.
        if (self.bus.blocks) |c| c.flush();
```

In `savestate.load`, as the first statement after the identity checks:

```zig
    // Every section below writes the machine directly, RAM included, behind
    // the bus's invalidation hook.
    if (cpu.bus.blocks) |c| c.flush();
```

- [ ] **Step 5: Run the tests**

Run: `zig build test -Dtest-filter="interrupt" && zig build test -Dtest-filter="delay slot" && zig build test -Dtest-filter="isolated" && zig build test -Dtest-filter="putchar" && zig build test -Dtest-filter="DMA" && zig build test -Dtest-filter="loading"`
Then: `zig build test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
zig fmt ps1-core/src/recompiler/run.zig ps1-core/src/cpu/cpu.zig ps1-core/src/savestate/savestate.zig ps1-core/tests/recompiler_test.zig
git add ps1-core/src/recompiler/run.zig ps1-core/src/cpu/cpu.zig ps1-core/src/savestate/savestate.zig ps1-core/tests/recompiler_test.zig
git commit -m "feat(core): block dispatcher interrupt, DMA-stall and fallback rules"
```

---

### Task 7: Gates, measurement and documentation

**Files:**
- Modify: `docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md` (new "As built (Plan 2, 2026-10-03)" section after the Plan 1 one)
- Modify: `CLAUDE.md` (Quick commands `zig build test` row: 20 → 21 binaries and 14 → 15 `unit_test_files`; Repository layout: a `recompiler/` line under `src/` and `recompiler` in the `tests/` list)

- [ ] **Step 1: The interpreter gates, no recapture**

```bash
zig build test
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- savestate
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
zig build trace-golden -Doptimize=ReleaseFast -- pgxp
zig build test-roms-ja -Doptimize=ReleaseFast
```

Expected: all green. `test-roms-ja` stays at 12/17. If a golden moved, find the
bug: no frontend runs a block engine yet, so the only shared changes are
`handlerFor`, `step()`'s extractions, the scheduler's `flush` split and the
bus hooks.

- [ ] **Step 2: Interpreter bench A/B against the pre-plan baseline**

Reuse the Task 1 worktree (`/private/tmp/claude-501/substation-base2`) and run
the interleaved best-of-five from Task 1 Step 7 again, plain and with `pgxp`
appended. Report both numbers. A regression beyond 2% is reported to the user,
not fixed silently. The block engine's speed is measured in Plan 3, once
`ps1-bench` has `--engine`.

- [ ] **Step 3: Remove the worktree**

```bash
git worktree remove /private/tmp/claude-501/substation-base2
```

- [ ] **Step 4: Write the as-built notes** (spec, after "As built (Plan 1, 2026-10-03)")

Write a `### As built (Plan 2, 2026-10-03)` section that records, in the spec's
voice:

- the API names: `recompiler.Engine`, `setEngine(cpu, allocator, engine)`,
  `engineOf(bus)`, `run(cpu, cache)`, `Cpu.run()`, `Bus.blocks`,
  `Bus.block_exit`, `scheduler.charge`/`serviceDue`, `Cpu.chargeCycles`,
  `exec.handlerFor`;
- departures 1-8 from this plan's Global Constraints, one line each with its
  reason;
- what Plan 3 must do: switch the frame loops to `cpu.run()` (`ps1-golden`
  counts instructions in its sample schedule, so its loop needs a block-aware
  counter); carry the engine through `ps1-capi`'s `HostSettings` once Plan 7
  exposes it (a fresh `Bus` comes up on the interpreter);
- what Plan 4 must add: `Block.segment` and the segment-mismatch recompile,
  once the JIT embeds a fetch cost.

- [ ] **Step 5: Update `CLAUDE.md`**

- `zig build test` row: "Runs **21 test binaries**: the 15 `unit_test_files`, …".
- Repository layout, under `src/`, after `cpu/`:
  `recompiler/      block engines: block.zig (termination), cache.zig (lookup +`
  `                 per-page invalidation), cached.zig, run.zig (dispatcher)`
- `tests/` line: add `recompiler` to the list of unit tests, and change "all 14
  in `zig build test`" to "all 15".

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md CLAUDE.md
git commit -m "docs: CPU recompiler spec as-built notes for the block engine core"
```
