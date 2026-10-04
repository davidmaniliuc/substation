# CPU recompiler, Plan 6: PGXP under the JIT. Implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `.jit` lower its op families while PGXP is on, emitting the
shadow bookkeeping the `exec.zig` handlers do, so that `.jit` with PGXP on
stops running at interpreter speed and still equals `.cached` exactly.

**Architecture:** A compile-time PGXP tier (`off`, `base` = master on and CPU
mode off, `cpu` = both on) masks what a block may lower
(`Lowering.under`). Every inline register write clears that register's
shadow. A load's shadow waits in a JIT-owned slot (`Pins.load_shadows`)
beside its integer value, using the same parity as x27/x28, and the model
writes `Cpu.load_shadow`/`delay_shadow` only when it syncs. Inline loads and
stores call small shims that run the handlers' own shadow rules, which move
out of `opLoad`/`opStore` into shared `pub` functions. ALU ops stay calls in
the `cpu` tier.

**Tech Stack:** Zig 0.17.0, `ps1-core` (`recompiler/`, `cpu/exec.zig`,
`memory.zig`), arm64 machine code, `ps1-golden`, `ps1-bench`, `ps1-capi`.

**Spec:** `docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md`.
Before starting, read "The arm64 JIT (`.jit`)" → "PGXP", the whole of
"Plan 6: the PGXP tiers (design, 2026-10-04)", and "As built (Plan 5)"
(its "What Plan 6 inherits" above all). Then read
`ps1-core/src/recompiler/arm64/{translate,model,layout,lower_alu,lower_memory,lower_branch}.zig`,
`ps1-core/src/recompiler/{run,jit,cache}.zig`, and in
`ps1-core/src/cpu/exec.zig` the functions `cpuMode`, `rOpMove`, `opLoad`
and `opStore`. In `ps1-core/src/cpu/cpu.zig` read `beginInstruction`,
`retireLoad`, `writeReg` and `writeRegPrecise`.

## Global Constraints

- `zig version` is **0.17.0**. No `**` array repeat (use `@splat`), decl
  literals (`.zr`, `.none`) are used throughout, and `zig fmt` rewrites
  `@intFromEnum` to `@backingInt`.
- **The JIT exists only on `aarch64-macos`.** Anything that calls emitted
  code sits behind `if (comptime jit.available)`. `zig build` builds the
  wasm target, and that build is the check that the gating holds. Run it
  in every task.
- **With PGXP off, the emitted code must not change.** Every new emission
  is gated on `ctx.opts.pgxp != .off` (or `Model.shadows`). A PGXP-off
  `verify --engine=jit` mismatch is a bug in that gating.
- **No interpreter golden moves and no `trace-block/` golden is
  recaptured.** `.jit` must equal `.cached` exactly, with PGXP on or off.
- **Instruction semantics, shadow rules included, live in `exec.zig`.**
  Inline code may only reproduce a handler's fast path. The shadow rules
  are called through shims, never re-implemented in emitted code. The one
  exception is the shadow clear (`writeReg`'s `gpr_shadow[i] = .none`),
  which is 20 zero bytes.
- **`Value.none` is all zero bytes**, and `shadow.clear` relies on it
  (Task 2 pins it with a test).
- **No savestate format change.** `Pins.load_shadows` is JIT-owned scratch
  and is never saved; `sync` leaves `Cpu`'s own fields exact before
  anything can read them.
- **A default-ON flag on `Bus` must also be set in `Bus.init`** (CLAUDE.md).
  `pgxp_cpu` already is. `Bus.setPgxpCpu` is a setter, not a new flag.
- `ps1-trace`, `ps1-debug`, `ps1-wasm` and the Swift app get no changes.
  `ps1-capi` changes only to route its two `pgxp_cpu` writes through
  `Bus.setPgxpCpu`.
- No file in `ps1-core/src` over ~600 lines. The new
  `recompiler/arm64/shadow.zig` stays under ~120.
- Commits go directly on `master`, one per task. The **commit message is
  the title line only**: no body, no trailer. **Never `git push`.**
- Run `zig fmt` on every touched `.zig` file before committing.
- Every `trace-golden` and bench run is `-Doptimize=ReleaseFast`.
- `docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md` carries an
  uncommitted table re-alignment by the owner. **Never stage the working
  tree's copy.** Task 5 commits its section through the index without
  touching the working-tree diff (the script is in Task 5).
- Tests run with `zig build test -Dtest-filter="<substring>"`. The JIT
  tests live in `ps1-core/tests/jit_test.zig`, and the shared machine
  helpers in `ps1-core/tests/recompiler_helpers.zig`.

### Deliberate departures from the spec (flag these in review, do not "fix" them)

1. **`--pgxp-no-cpu` already exists** on `ps1-golden` and is the `base`-tier
   sweep. No new flag is added. `ps1-bench` gains a `pgxp-no-cpu` argument
   to time that tier.
2. **The PGXP fuzzers run 250 programs each**, not the 1000 the PGXP-off
   fuzzer runs. Each step under PGXP compares about 100 KB of shadow memory,
   and the test build is Debug.

## Review Focus

These are the inputs most likely to break a player's PGXP-on game that no
gate catches unless a test aims at them. Each one has a test in the task
named.

1. **A half-word load to `$zero`.** `shadowLoadHalf` clears a RAM shadow's
   flag as a side effect, so the shim must run even though nothing lands.
   Expected: the RAM shadow changes exactly as under `.cached`. Test:
   Task 4, "inline loads and stores move shadows".
2. **A store whose source register has a load landing in that same op.**
   Expected: the store carries the register's OLD shadow, as it carries
   the old value. Test: Task 4 (`lw t0` then `sw t0`).
3. **A load that leaves through the slow path (a RAM mirror), read by the
   next inline op.** Expected: its shadow lands from the slot, which the
   slow path refilled from `cpu.load_shadow`. Test: Task 4 (`lw t4, 0(k0)`).
4. **A load issued by a CALL that lands while an inline op retires.**
   Expected: the shadow lands with the value. This is the reason the slots
   must exist before ANY family lowers under PGXP. Test: Task 2.
5. **CPU mode toggled from the app while blocks are compiled.** Expected:
   the cache flushes and later blocks use the new tier. An unchanged value
   flushes nothing, because the macOS runner re-applies every setting every
   frame. Test: Task 1.

---

## File map

| File | Change |
| --- | --- |
| `ps1-core/src/recompiler/jit.zig` | `Pgxp` enum, `Lowering.under` |
| `ps1-core/src/recompiler/run.zig` | `pgxpTier`; `compileBlock` passes the tier and the masked lowering |
| `ps1-core/src/memory.zig` | `Bus.setPgxpCpu` |
| `ps1-capi/src/root.zig` | `ps1_set_pgxp_cpu` and `HostSettings.apply` call `setPgxpCpu` |
| `ps1-golden/src/main.zig` | the `pgxp` sweep calls `setPgxpCpu` |
| `ps1-bench/main.zig` | `pgxp-no-cpu` argument |
| `ps1-core/src/recompiler/cache.zig` | `Pins.load_shadows` |
| `ps1-core/src/recompiler/arm64/layout.zig` | shadow offsets and their checks |
| `ps1-core/src/recompiler/arm64/shadow.zig` (new) | `copy`, `clear`, the load and store shims and their call sequences |
| `ps1-core/src/recompiler/arm64/model.zig` | `shadows`, `slot`, `readBack`; shadow work in `retire`, `sync`, `afterCall` |
| `ps1-core/src/recompiler/arm64/translate.zig` | `Options.pgxp`; `dst` clears; prologue and `slowPath` read back through the model |
| `ps1-core/src/recompiler/arm64/lower_alu.zig` | the move idiom stays a call under PGXP |
| `ps1-core/src/recompiler/arm64/lower_memory.zig` | the shims at `done` |
| `ps1-core/src/cpu/exec.zig` | `pub` `LoadType`/`StoreType`, `loadShadow`, `storeShadow` |
| `ps1-core/tests/recompiler_helpers.zig` | `pgxpOn`, `shadowOf`, shadows in `expectSameMachine` |
| `ps1-core/tests/jit_test.zig` | the tier tests, the PGXP fuzzers, directed tests |
| `CLAUDE.md`, the spec | Task 5 |

---

### Task 1: The PGXP tier, a flushing CPU-mode setter, and the PGXP fuzzers

This task lowers nothing new: under PGXP every block is still all calls.
It builds the tier that later tasks relax, the setter that keeps a compiled
tier honest, and the fuzzers that will gate Tasks 2 to 4. The fuzzers pass
here because nothing is inline under PGXP yet. That is expected.

**Files:**
- Modify: `ps1-core/src/recompiler/jit.zig`, `ps1-core/src/recompiler/run.zig:205-232`,
  `ps1-core/src/recompiler/arm64/translate.zig:58-61`, `ps1-core/src/memory.zig` (after `setPgxp`, ~line 448),
  `ps1-capi/src/root.zig:148` and `:537-539`, `ps1-golden/src/main.zig:687-688`, `ps1-bench/main.zig:29-53`
- Test: `ps1-core/tests/jit_test.zig`, `ps1-core/tests/recompiler_helpers.zig`

**Interfaces:**
- Produces: `jit.Pgxp = enum { off, base, cpu }`;
  `jit.Lowering.under(l: Lowering, tier: Pgxp) Lowering`;
  `translate.Options.pgxp: jit.Pgxp`; `Bus.setPgxpCpu(self: *Bus, enabled: bool) void`;
  in the test helpers, `h.pgxpOn(m: *Machine, tier: jit.Pgxp) void`,
  `h.shadowOf(word: u32) pgxp.Value` and `h.expectSameShadows(ref, dut) !void`,
  which `h.expectSameMachine` calls whenever `ref.bus.pgxp_enabled` is set; in
  `jit_test.zig`, `fn fuzzLinked(tier: jit.Pgxp, programs: usize) !void`.

- [ ] **Step 1: Write the failing tests**

Add to `ps1-core/tests/jit_test.zig`, after "a lowering mask parses from
family names":

```zig
test "PGXP's tiers mask the lowering" {
    const all: jit.Lowering = .{};
    try expectEqual(all, all.under(.off));
    try expectEqual(jit.Lowering.none, all.under(.base));
    try expectEqual(jit.Lowering.none, all.under(.cpu));
    // A family the harness masked off stays off under every tier.
    try expectEqual(jit.Lowering.none, jit.Lowering.none.under(.base));
}
```

And after "with PGXP on nothing is lowered, and turning it on flushes":

```zig
test "a CPU-mode change flushes the block cache, and an unchanged one does not" {
    if (!jit.available) return error.SkipZigTest;
    var m = try h.Machine.init(.jit);
    defer m.deinit();
    const c = m.bus.blocks.?;
    h.poke(m.bus, 0x1000, &.{ mips.beq(zero, zero, -1), mips.nop });
    m.bus.setPgxp(true);
    m.start(0x8000_1000);
    _ = m.cpu.run();
    // The macOS runner re-applies every setting every frame.
    m.bus.setPgxpCpu(true);
    try expect(c.lookup(0x1000) != null);
    m.bus.setPgxpCpu(false);
    try expectEqual(@as(?*block.Block, null), c.lookup(0x1000));
    try expect(!m.bus.pgxp_cpu);
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `zig build test -Dtest-filter="tiers mask"` and
`zig build test -Dtest-filter="CPU-mode change"`
Expected: compile errors: `under` is not a member of `Lowering`, and
`setPgxpCpu` is not a member of `Bus`.

- [ ] **Step 3: Add the tier and the mask to `jit.zig`**

After the `Lowering` struct's `with` function, inside `Lowering`:

```zig
    /// What may be inline under PGXP tier `tier`. A family joins here once
    /// its inline code leaves every shadow its handler would.
    pub fn under(l: Lowering, tier: Pgxp) Lowering {
        return if (tier == .off) l else .none;
    }
```

After the `Lowering` struct:

```zig
/// What a block bakes in of PGXP's two switches (`run.pgxpTier`). `base`
/// is the master switch alone: loads, stores and the register-move idiom
/// propagate shadows and every other write clears one. `cpu` adds CPU
/// mode's hooks at every ALU, shift, mult/div and move.
pub const Pgxp = enum { off, base, cpu };
```

- [ ] **Step 4: Carry the tier into the translator**

In `translate.zig`, `Options`:

```zig
pub const Options = struct {
    lower: jit.Lowering,
    /// Stores take the inline RAM path. Off while lockstep is checking.
    store_fast: bool,
    /// What inline code must do for PGXP's shadows.
    pgxp: jit.Pgxp,
};
```

In `run.zig`, replace the `opts` construction in `compileBlock`:

```zig
            const tier = pgxpTier(bus);
            const opts: jit.translate.Options = .{
                .lower = j.lower.under(tier),
                .store_fast = c.lockstep == null,
                .pgxp = tier,
            };
```

And add, after `clearShadows`:

```zig
/// The JIT's one reading of PGXP's two switches, as `exec.zig`'s `cpuMode`
/// is the handlers'. A block bakes the tier in, so `Bus.setPgxp` and
/// `Bus.setPgxpCpu` flush whenever it changes.
fn pgxpTier(bus: *const Bus) jit.Pgxp {
    if (!bus.pgxp_enabled) return .off;
    return if (bus.pgxp_cpu) .cpu else .base;
}
```

`pgxpTier` is used only inside `if (comptime jit.available)`. If the wasm
build complains about an unused function, move it inside that block's scope
as a nested `const` instead of adding a `_ = pgxpTier;`.

- [ ] **Step 5: Add `Bus.setPgxpCpu`**

In `memory.zig`, directly after `setPgxp`:

```zig
    /// CPU mode, with the same flush as `setPgxp`: a compiled block bakes in
    /// whether its ALU ops run the CPU-mode hooks (`recompiler/run.zig`).
    /// An unchanged value flushes nothing; the macOS runner re-applies every
    /// setting every frame.
    pub fn setPgxpCpu(self: *Self, enabled: bool) void {
        if (enabled != self.pgxp_cpu) {
            if (self.blocks) |c| c.flush();
        }
        self.pgxp_cpu = enabled;
    }
```

`Bus.init`'s `bus.pgxp_cpu = true;` stays a direct write: it runs before any
cache exists.

- [ ] **Step 6: Route every runtime write of `pgxp_cpu` through it**

`ps1-capi/src/root.zig`, in `ps1_set_pgxp_cpu`:

```zig
    h.cpu.bus.setPgxpCpu(enabled != 0);
```

In `HostSettings.apply`, replace `bus.pgxp_cpu = s.cpu;` with:

```zig
        bus.setPgxpCpu(s.cpu);
```

`ps1-golden/src/main.zig` in the `pgxp` sweep, replace
`bus.pgxp_cpu = opts.pgxp_cpu;` with:

```zig
    bus.setPgxpCpu(opts.pgxp_cpu);
```

Then check that nothing else writes the field:
`grep -rn "pgxp_cpu =" ps1-*/ --include=*.zig`. Expected: only
`memory.zig`'s `Bus.init` and `setPgxpCpu`, plus `ps1-golden`'s option
parsing (`opts.pgxp_cpu = false`).

`ps1-bench/main.zig`: add `var pgxp_cpu = true;` beside `var pgxp = false;`,
add `if (std.mem.eql(u8, a, "pgxp-no-cpu")) pgxp_cpu = false;` to the loop,
add `bus.setPgxpCpu(pgxp_cpu);` after `bus.setPgxp(pgxp);`, and add
`pgxp_cpu` to the result line: `pgxp={} cpu={}` with `pgxp, pgxp_cpu`.

- [ ] **Step 7: Run the two tests**

Run: `zig build test -Dtest-filter="tiers mask"` and
`zig build test -Dtest-filter="CPU-mode change"`
Expected: both PASS.

- [ ] **Step 8: Shadow comparison and PGXP setup in the helpers**

In `ps1-core/tests/recompiler_helpers.zig`, add the import beside the
others:

```zig
const Value = ps1_core.pgxp.Value;
```

Add after `jitRan`:

```zig
/// PGXP on at `tier`, as the app sets it. The dispatcher is told it has
/// already seen the edge, or its clear-on-enable (`run.zig`) would wipe the
/// shadows a test seeds before the first run.
pub fn pgxpOn(m: *Machine, tier: recompiler.jit.Pgxp) void {
    std.debug.assert(tier != .off);
    m.bus.setPgxp(true);
    m.bus.setPgxpCpu(tier == .cpu);
    m.bus.blocks.?.pgxp_seen = true;
}

/// A live shadow recorded against `word`.
pub fn shadowOf(word: u32) Value {
    return .{ .x = 12.5, .y = -3.25, .z = 400, .word = word, .flags = Value.valid_xyz };
}
```

At the end of `expectSameMachine`:

```zig
    // Under PGXP the shadows are machine state too.
    if (ref.bus.pgxp_enabled) try expectSameShadows(ref, dut);
```

And after it:

```zig
/// The GPR shadows, the load delay's two, the GP0 provenance a store armed,
/// and the shadow memory under the compared RAM and the scratchpad.
pub fn expectSameShadows(ref: *const Machine, dut: *const Machine) !void {
    for (ref.cpu.gpr_shadow, dut.cpu.gpr_shadow, 0..) |a, b, r| {
        if (!sameBytes(Value, &.{a}, &.{b})) {
            std.debug.print("shadows differ: gpr_shadow[{d}]\n", .{r});
            return error.ShadowsDiffer;
        }
    }
    const singles = [_]struct { []const u8, Value, Value }{
        .{ "load_shadow", ref.cpu.load_shadow, dut.cpu.load_shadow },
        .{ "delay_shadow", ref.cpu.delay_shadow, dut.cpu.delay_shadow },
        .{ "pgxp_pending", ref.bus.pgxp_pending, dut.bus.pgxp_pending },
    };
    for (singles) |s| {
        if (!sameBytes(Value, &.{s[1]}, &.{s[2]})) {
            std.debug.print("shadows differ: {s}\n", .{s[0]});
            return error.ShadowsDiffer;
        }
    }
    const n = compared_ram / 4;
    if (!sameBytes(Value, ref.bus.ram_shadow[0..n], dut.bus.ram_shadow[0..n])) {
        std.debug.print("shadows differ: RAM below 0x{x}\n", .{compared_ram});
        return error.ShadowsDiffer;
    }
    if (!sameBytes(Value, &ref.bus.scratch_shadow, &dut.bus.scratch_shadow)) {
        std.debug.print("shadows differ: scratchpad\n", .{});
        return error.ShadowsDiffer;
    }
}

/// Byte equality: a shadow's floats are compared as stored, NaN included.
fn sameBytes(comptime T: type, a: []const T, b: []const T) bool {
    return std.mem.eql(u8, std.mem.sliceAsBytes(a), std.mem.sliceAsBytes(b));
}
```

- [ ] **Step 9: Run the existing JIT and recompiler tests**

Run: `zig build test -Dtest-filter="jit"` and `zig build test -Dtest-filter="cached"`
Expected: PASS. In particular, ".jit equals .cached: shadows from an
earlier PGXP period do not outlive an off period" turns PGXP back on before
its last `expectSameRuns`. The shadows it then compares are equal, because
the dispatcher's clear runs on both machines.

- [ ] **Step 10: The PGXP fuzzers**

In `jit_test.zig`, add `const Value = ps1_core.pgxp.Value;` beside
`const Cpu = ps1_core.cpu.Cpu;`. Inside the `fuzz` struct, after `restart`/`apply`
(i.e. as members of `fuzz`, beside `landing`), add:

```zig
    /// Live shadows to start a pass from, each recorded against the word it
    /// describes: on about half the registers, every word of the data window
    /// and the whole scratchpad. Its own PRNG, so the programs and states
    /// stay the ones the PGXP-off fuzzer draws. Returns the seeded
    /// registers, one bit each.
    fn seedShadows(m: *h.Machine, seed: u64) u32 {
        var prng = std.Random.DefaultPrng.init(seed ^ 0x5047_5850);
        const rng = prng.random();
        var seeded: u32 = 0;
        for (&m.cpu.gpr_shadow, m.cpu.regs, 0..) |*s, word, r| {
            if (r == 0 or rng.boolean()) continue; // `Cpu.init` left it none
            s.* = live(rng, word);
            seeded |= @as(u32, 1) << @intCast(r);
        }
        const first = data_base / 4;
        for (m.bus.ram_shadow[first..][0 .. data_bytes / 4], first..) |*s, k| {
            s.* = live(rng, std.mem.readInt(u32, m.bus.ram[k * 4 ..][0..4], .little));
        }
        for (&m.bus.scratch_shadow, 0..) |*s, k| {
            s.* = live(rng, std.mem.readInt(u32, m.bus.scratchpad[k * 4 ..][0..4], .little));
        }
        return seeded;
    }

    fn live(rng: std.Random, word: u32) Value {
        return .{
            .x = rng.float(f32) * 640 - 320,
            .y = rng.float(f32) * 480 - 240,
            .z = rng.float(f32) * 65536,
            .word = word,
            .flags = Value.valid_xyz,
        };
    }

    /// A register that started the pass without a shadow holds a live one:
    /// a load, a move or a hook carried it there.
    fn propagated(m: *const h.Machine, seeded: u32) bool {
        for (m.cpu.gpr_shadow, 0..) |s, r| {
            if ((seeded >> @intCast(r)) & 1 == 0 and s.flags != 0) return true;
        }
        return false;
    }
```

Replace the body of "fuzz: linked .jit equals .cached, each program run
three times" with a call, and move the body into `fuzzLinked`. The body is
unchanged except where this listing differs: the PGXP setup, the seeding
after each `restart`, and `propagated`.

```zig
/// The linked fuzzer, with PGXP off or at `tier`. Under PGXP every pass
/// starts from seeded shadows, and `expectSameMachine` compares them after
/// every call.
fn fuzzLinked(tier: jit.Pgxp, programs: usize) !void {
    if (!jit.available) return error.SkipZigTest;
    var p: Pair = .{ .ref = try h.Machine.init(.cached), .dut = undefined };
    defer p.ref.deinit();
    p.dut = try h.Machine.init(.jit);
    defer p.dut.deinit();
    if (tier != .off) {
        h.pgxpOn(&p.ref, tier);
        h.pgxpOn(&p.dut, tier);
    }
    var chained = false;
    var switched = false;
    var propagated = false;
    for (0..programs) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();
        const words = fuzz.program(rng, true);
        const state = fuzz.State.random(rng);
        const first = fuzz.aliases[rng.uintLessThan(usize, fuzz.aliases.len)];
        const second = fuzz.aliases[rng.uintLessThan(usize, fuzz.aliases.len)];
        state.apply(&p.ref, &words);
        state.apply(&p.dut, &words);
        const jumps = for (words) |w| {
            if (w & 0xFFE0_003E == @as(u32, fuzz.jump_reg) << 21 | 0x08) break true; // JR, JALR
        } else false;
        if (jumps and first != second and first < 0xA000_0000 and second < 0xA000_0000) switched = true;
        // The first pass compiles and records the exits; the second, from
        // the same state over the same code, runs them linked, and its
        // indirect jumps find their targets in the RAM table. The third
        // jumps through another alias, so a table slot holds a block
        // compiled for an address the jump is not going to.
        for (0..3) |pass| {
            if (pass > 0) {
                state.restart(&p.ref);
                state.restart(&p.dut);
            }
            var seeded: u32 = 0;
            if (tier != .off) {
                seeded = fuzz.seedShadows(&p.ref, seed);
                _ = fuzz.seedShadows(&p.dut, seed);
            }
            const alias = if (pass == 2) second else first;
            p.ref.cpu.regs[fuzz.alias_reg] = alias;
            p.dut.cpu.regs[fuzz.alias_reg] = alias;
            for (0..fuzz.runs) |run_index| {
                errdefer std.debug.print("linked fuzz ({s}): seed {d}, pass {d}, run {d}\n", .{ @tagName(tier), seed, pass, run_index });
                const k = try expectSameLinked(&p, rng.intRangeAtMost(u32, 1, 256));
                // More steps than one block holds: a chain ran.
                if (k > block.max_len + 1) chained = true;
                if (fuzz.propagated(&p.ref, seeded)) propagated = true;
            }
        }
    }
    try expect(chained);
    // Some program jumped through two different linking aliases.
    try expect(switched);
    // Under PGXP, shadows really moved, so the comparison was not of
    // nothing against nothing.
    if (tier != .off) try expect(propagated);
}

test "fuzz: linked .jit equals .cached, each program run three times" {
    try fuzzLinked(.off, fuzz.programs);
}

test "fuzz: linked .jit equals .cached under PGXP, base tier" {
    try fuzzLinked(.base, fuzz.programs / 4);
}

test "fuzz: linked .jit equals .cached under PGXP, CPU tier" {
    try fuzzLinked(.cpu, fuzz.programs / 4);
}
```

The seeded alias register (`fuzz.alias_reg`) is overwritten after seeding,
so its shadow no longer matches its word. That is intended: `validate`
then drops it, the same way on both engines.

- [ ] **Step 11: Run the fuzzers**

Run: `zig build test -Dtest-filter="fuzz"`
Expected: all four PASS. Under PGXP they pass trivially in this task,
because every op is a call. If `propagated` is false, the seeding is not
reaching the registers: check that `seedShadows` runs after `restart`
(which re-inits `Cpu`).

- [ ] **Step 12: The full build and test suite**

Run: `zig fmt ps1-core ps1-capi ps1-golden ps1-bench && zig build && zig build test && zig build capi-lib`
Expected: all PASS, wasm included.

- [ ] **Step 13: Commit**

```bash
git add ps1-core/src/recompiler/jit.zig ps1-core/src/recompiler/run.zig \
  ps1-core/src/recompiler/arm64/translate.zig ps1-core/src/memory.zig \
  ps1-capi/src/root.zig ps1-golden/src/main.zig ps1-bench/main.zig \
  ps1-core/tests/jit_test.zig ps1-core/tests/recompiler_helpers.zig
git commit -m "feat(jit): PGXP tiers, a flushing CPU-mode setter and the PGXP fuzzers"
```

---

### Task 2: Load shadows beside their values; branches and linking under PGXP

This is the task with the most risk. Branches are the first family inline
under PGXP, and the first inline op means the model must carry shadows. A
load issued by a call can land while an inline branch retires (Review
Focus 4), and `retire` must then land its shadow as well as its value.

How the slots work: a load's integer waits in x27 or x28 by the parity of
the op that issued it (`model.loadReg`). Its shadow waits in
`Pins.load_shadows[slot]`, where slot 0 goes with x27 and slot 1 with x28.
Everywhere the model handles the integer, it handles the shadow at the
same point:

| Integer (today) | Shadow (this task) |
| --- | --- |
| `retire`: `str value → regs[rt]` | `copy slot → gpr_shadow[rt]` |
| `sync`: `load_v = issued.value`, `delay_v = landed.value` | `load_shadow = slot(issued)` or none, `delay_shadow = slot(landed)` or none |
| `readBack` (prologue, `afterCall`, `slowPath`): `ldr value ← load_v` | `copy load_shadow → slot` |

`delay_shadow` takes the landed slot even when the load was cancelled or
targets `$zero`, because `beginInstruction` copies it unconditionally.

**Files:**
- Create: `ps1-core/src/recompiler/arm64/shadow.zig`
- Modify: `ps1-core/src/recompiler/cache.zig:27-49` (`Pins`),
  `ps1-core/src/recompiler/arm64/layout.zig`,
  `ps1-core/src/recompiler/arm64/model.zig`,
  `ps1-core/src/recompiler/arm64/translate.zig` (`Ctx.dst`, `slowPath`, `compile`, `prologue`),
  `ps1-core/src/recompiler/jit.zig` (`Lowering.under`),
  `ps1-core/src/recompiler/arm64/lower_branch.zig` (module comment only)
- Test: `ps1-core/tests/jit_test.zig`

**Interfaces:**
- Consumes: `jit.Pgxp`, `Options.pgxp`, `h.pgxpOn`, `h.shadowOf`, the
  shadow comparison in `h.expectSameMachine` (Task 1).
- Produces: `Pins.load_shadows: [2]pgxp.Value`;
  `layout.shadow(r: u5) u32`, `layout.load_shadow`, `layout.delay_shadow`,
  `layout.pinsLoadShadow(slot: u1) u32`; `shadow.copy(em, dst: e.Reg, dst_off: u32, src: e.Reg, src_off: u32) void`
  and `shadow.clear(em, base: e.Reg, off: u32) void` (both use only w9 and wzr);
  `model.slot(value: e.Reg) u1`; `Model.shadows: bool`;
  `Model.entry(start_pc: u32, shadows: bool) Model`;
  `Model.readBack(m: *const Model, em: *Emitter, l: Load) void`.

- [ ] **Step 1: Write the failing tests**

In `jit_test.zig`, add after "a lowering mask parses from family names":

```zig
test "Value.none is all zero bytes, which the JIT's shadow clear writes" {
    const none = Value.none;
    try expect(std.mem.allEqual(u8, std.mem.asBytes(&none), 0));
    try expectEqual(@as(usize, 0), @sizeOf(Value) % 4);
}
```

Update "PGXP's tiers mask the lowering":

```zig
test "PGXP's tiers mask the lowering" {
    const all: jit.Lowering = .{};
    try expectEqual(all, all.under(.off));
    const branches = try jit.Lowering.parse("branch,link");
    try expectEqual(branches, all.under(.base));
    try expectEqual(branches, all.under(.cpu));
    // A family the harness masked off stays off under every tier.
    try expectEqual(jit.Lowering.none, jit.Lowering.none.under(.base));
}
```

Replace "with PGXP on nothing is lowered, and turning it on flushes" with:

```zig
test "under PGXP a block lowers what its tier allows, and turning PGXP on flushes" {
    if (!jit.available) return error.SkipZigTest;
    // Calls per tier in eight `addu`s, a branch and its delay slot.
    const cases = [_]struct { tier: jit.Pgxp, calls: u32 }{
        .{ .tier = .base, .calls = 9 },
        .{ .tier = .cpu, .calls = 9 },
    };
    for (cases) |case| {
        var m = try h.Machine.init(.jit);
        defer m.deinit();
        const c = m.bus.blocks.?;
        h.poke(m.bus, 0x1000, &(@as([8]u32, @splat(mips.addu(t0, t0, t1))) ++ .{ mips.beq(zero, zero, -1), mips.nop }));
        m.start(0x8000_1000);
        _ = m.cpu.run();
        try expectEqual(@as(u32, 0), c.lookup(0x1000).?.calls); // PGXP off: all inline
        h.pgxpOn(&m, case.tier);
        try expectEqual(@as(?*block.Block, null), c.lookup(0x1000));
        m.start(0x8000_1000);
        _ = m.cpu.run();
        try expectEqual(case.calls, c.lookup(0x1000).?.calls);
    }
}
```

And add after it:

```zig
test ".jit equals .cached under PGXP: a called load's shadow lands as an inline jump retires" {
    if (!jit.available) return error.SkipZigTest;
    for ([_]jit.Pgxp{ .base, .cpu }) |tier| {
        var p = try Pair.init(&.{
            mips.lw(t0, zero, 0x2000), // a call: loads are masked off below
            mips.jal(0x1010), // inline: t0 lands as it retires, $ra's shadow goes
            mips.nop,
            mips.nop,
            mips.beq(zero, zero, -1), // 0x1010
            mips.nop,
        }, 0x8000_1000);
        defer p.deinit();
        for ([_]*h.Machine{ &p.ref, &p.dut }) |m| {
            h.pgxpOn(m, tier);
            h.poke(m.bus, 0x2000, &.{0x1234_5678});
            m.bus.ram_shadow[0x2000 / 4] = h.shadowOf(0x1234_5678);
            m.cpu.gpr_shadow[h.ra] = h.shadowOf(0);
            m.start(0x8000_1000);
        }
        // Only jumps inline, whatever later tasks lower: the load and the
        // nop stay calls, so the load is issued by a call.
        recompiler.setLowering(p.dut.bus, try jit.Lowering.parse("branch,link"));
        try p.expectSameRuns(3);
        try expect(p.dut.cpu.gpr_shadow[t0].flags != 0);
        try expectEqual(@as(u32, 0), p.dut.cpu.gpr_shadow[h.ra].flags);
        // The jump really was inline: two calls in three ops.
        try expectEqual(@as(u32, 2), p.dut.bus.blocks.?.lookup(0x1000).?.calls);
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `zig build test -Dtest-filter="PGXP"`
Expected: "PGXP's tiers mask the lowering" FAILS (`under` still returns
`.none`), "under PGXP a block lowers" FAILS (10 calls, not 9), and "a
called load's shadow lands" FAILS (3 calls, not 2).

- [ ] **Step 3: `Pins.load_shadows`**

In `cache.zig`, import `const Value = @import("../pgxp/pgxp.zig").Value;`
(check the relative path against `cache.zig`'s other imports), and append
to `Pins`, after `link_pc`:

```zig
    /// The PGXP shadows of loads in flight, beside their values in x27
    /// (slot 0) and x28 (slot 1). The JIT's scratch: `Cpu.load_shadow`
    /// and `delay_shadow` are written from here when the model syncs.
    load_shadows: [2]Value = @splat(.none),
```

`Pins` is an `extern struct` and `Value` is an `extern struct`, so this
compiles as is. Check where `Pins` is constructed (`BlockCache.init`):
it takes the field default.

- [ ] **Step 4: The offsets in `layout.zig`**

Add the import `const Value = @import("../../pgxp/pgxp.zig").Value;`, then:

```zig
pub fn shadow(r: u5) u32 {
    return @offsetOf(Cpu, "gpr_shadow") + @as(u32, r) * @sizeOf(Value);
}
pub const load_shadow = @offsetOf(Cpu, "load_shadow");
pub const delay_shadow = @offsetOf(Cpu, "delay_shadow");
pub fn pinsLoadShadow(slot: u1) u32 {
    return @offsetOf(Pins, "load_shadows") + @as(u32, slot) * @sizeOf(Value);
}
```

And in the `comptime` block:

```zig
    // A `Value` moves as whole words (`shadow.zig`): every word of each
    // reachable by `ldr`/`str` of a word. A slot's address is also an
    // `add` immediate (the load shim's argument).
    std.debug.assert(@sizeOf(Value) % 4 == 0);
    for ([_]u32{ shadow(31), load_shadow, delay_shadow, pinsLoadShadow(1) }) |o| std.debug.assert(o + @sizeOf(Value) <= 16384 and o % 4 == 0);
    std.debug.assert(pinsLoadShadow(1) < 4096);
```

- [ ] **Step 5: Create `arm64/shadow.zig` (the copy and the clear)**

```zig
//! PGXP's shadows in emitted code, compiled only under PGXP
//! (`Options.pgxp`). A `Value` moves as whole words through w9. Its rules
//! stay in `exec.zig`; the shims below call them.

const e = @import("emit.zig");
const Emitter = @import("emitter.zig").Emitter;
const Value = @import("../../pgxp/pgxp.zig").Value;

const words = @sizeOf(Value) / 4;

/// `[dst + dst_off] = [src + src_off]`, one `Value`. Clobbers w9.
pub fn copy(em: *Emitter, dst: e.Reg, dst_off: u32, src: e.Reg, src_off: u32) void {
    for (0..words) |k| {
        const o: u32 = @intCast(k * 4);
        em.put(e.memImm(.ldr_w, .x9, src, src_off + o));
        em.put(e.memImm(.str_w, .x9, dst, dst_off + o));
    }
}

/// `[base + off] = Value.none`, which is all zero bytes.
pub fn clear(em: *Emitter, base: e.Reg, off: u32) void {
    for (0..words) |k| em.put(e.memImm(.str_w, .zr, base, off + @as(u32, @intCast(k * 4))));
}
```

- [ ] **Step 6: The model carries shadows**

In `model.zig`, add `const shadow = @import("shadow.zig");` to the imports,
and extend the module comment's load-delay paragraph with:

```zig
//! Under PGXP a load's shadow waits beside its value, in
//! `Pins.load_shadows` by the same parity (`slot`), and lands, syncs and is
//! read back exactly where the value is. `Cpu.load_shadow` and
//! `delay_shadow` cannot be rotated in memory as each op begins: an inline
//! op's slow path runs its handler, which rotates them again.
```

Add after `loadReg`:

```zig
/// The `Pins.load_shadows` slot beside a load's value register.
pub fn slot(value: e.Reg) u1 {
    return if (value == .x27) 0 else 1;
}

fn slotOffset(l: Load) u32 {
    return layout.pinsLoadShadow(slot(l.value));
}
```

In `Model`, add the field after `cancelled`:

```zig
    /// PGXP is on: every load's shadow moves with its value.
    shadows: bool = false,
```

Change `entry`:

```zig
    pub fn entry(start_pc: u32, shadows: bool) Model {
        return .{ .pc = start_pc -% 4, .issued = .{ .rt = 0, .value = loadReg(1) }, .shadows = shadows };
    }
```

Replace `afterCall`:

```zig
    /// After a call to op `i`: memory is exact. A load it issued is read
    /// back into its register, where an inline successor expects it.
    pub fn afterCall(m: *Model, em: *Emitter, i: usize, pc: u32, delay_slot: bool, issues: ?u5) void {
        m.* = .{ .pc = pc, .delay_slot = delay_slot, .shadows = m.shadows };
        if (issues) |rt| {
            m.issued = .{ .rt = rt, .value = loadReg(i) };
            m.readBack(em, m.issued.?);
        }
    }

    /// `l`'s value, and under PGXP its shadow, read back from where a call
    /// or the last block left them. Clobbers w9.
    pub fn readBack(m: *const Model, em: *Emitter, l: Load) void {
        em.put(e.memImm(.ldr_w, l.value, t.cpu_reg, layout.load_v));
        if (m.shadows) shadow.copy(em, t.pins_reg, slotOffset(l), t.cpu_reg, layout.load_shadow);
    }
```

Replace `retire`:

```zig
    /// The landed load's write-back, unless cancelled: `Cpu.retireLoad`.
    /// Clobbers w9 under PGXP.
    pub fn retire(m: *const Model, em: *Emitter) void {
        const l = m.landed orelse return;
        if (m.cancelled or l.rt == 0) return;
        em.put(e.memImm(.str_w, l.value, t.cpu_reg, layout.reg(l.rt)));
        if (m.shadows) shadow.copy(em, t.cpu_reg, layout.shadow(l.rt), t.pins_reg, slotOffset(l));
    }
```

At the end of `sync`, before `m.dirty = false;`:

```zig
        if (m.shadows) {
            // As `beginInstruction` leaves them: `delay_shadow` is the landed
            // load's whatever its target, and even when it was cancelled.
            if (m.issued) |l| shadow.copy(em, cpu, layout.load_shadow, t.pins_reg, slotOffset(l)) else shadow.clear(em, cpu, layout.load_shadow);
            if (m.landed) |l| shadow.copy(em, cpu, layout.delay_shadow, t.pins_reg, slotOffset(l)) else shadow.clear(em, cpu, layout.delay_shadow);
        }
```

`sync` already asserts that a branch target is never x9, and the target
has been stored by this point, so clobbering w9 is safe. `retire` runs
before `sync` in `endBranch`, and the target is in w10 (or the `src`
register, which is never x9 for `JR`: check `lower_branch.register`, which
loads into x10).

- [ ] **Step 7: The translator clears on every inline write and reads back through the model**

In `translate.zig`, add `const shadow = @import("shadow.zig");`. Replace
`Ctx.dst`:

```zig
    /// Stores `from` to guest register `r`. A write to $zero is dropped.
    /// Under PGXP it clears `r`'s shadow, as `writeReg` does.
    pub fn dst(ctx: *Ctx, r: u5, from: e.Reg) void {
        if (r == 0) return;
        ctx.em.put(e.memImm(.str_w, from, cpu_reg, layout.reg(r)));
        if (ctx.opts.pgxp != .off) shadow.clear(ctx.em, cpu_reg, layout.shadow(r));
    }
```

In `slowPath`, replace
`if (ctx.model.issued) |l| em.put(e.memImm(.ldr_w, l.value, cpu_reg, layout.load_v));`
with:

```zig
        if (ctx.model.issued) |l| ctx.model.readBack(em, l);
```

In `compile`, `.model = .entry(b.start_pc),` becomes:

```zig
        .model = .entry(b.start_pc, opts.pgxp != .off),
```

In `prologue`, the last line
`em.put(e.memImm(.ldr_w, model.loadReg(1), cpu_reg, layout.load_v));`
becomes:

```zig
    ctx.model.readBack(em, ctx.model.issued.?);
```

Then `grep -n "\.entry(\|loadReg(1)" ps1-core/src/recompiler` to find any
other `Model.entry` caller or load-value read, and give it the same
treatment. Expected: none.

- [ ] **Step 8: Let branches and linking lower under PGXP**

In `jit.zig`, `Lowering.under`:

```zig
    pub fn under(l: Lowering, tier: Pgxp) Lowering {
        if (tier == .off) return l;
        var out: Lowering = .none;
        out.branch = l.branch;
        out.link = l.link;
        return out;
    }
```

In `lower_branch.zig`'s module comment, add one line: "A link goes
through `Ctx.dst`, which clears its shadow under PGXP." Linking needs no
change: nothing in `link.zig` writes a guest register, and a linked entry
joins `prologue` at `body`, before the `readBack`.

- [ ] **Step 9: Run the tests**

Run: `zig build test -Dtest-filter="PGXP"` then `zig build test -Dtest-filter="jit"`
Expected: PASS. Then `zig build test -Dtest-filter="fuzz"`: all four PASS.
The PGXP fuzzers now exercise inline branches and links against calls
that issue loads.

- [ ] **Step 10: PGXP-off gates**

With PGXP off, the emitted code must not change. Run:

```bash
zig build -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- savestate --engine=jit
```

Expected: OK on all nine for both.

- [ ] **Step 11: PGXP-on parity, end to end**

```bash
S=$TMPDIR/plan6-t2
mkdir -p $S
zig build trace-golden -Doptimize=ReleaseFast -- pgxp --engine=cached > $S/pgxp-cached.txt 2>&1
zig build trace-golden -Doptimize=ReleaseFast -- pgxp --engine=jit > $S/pgxp-jit.txt 2>&1
diff $S/pgxp-cached.txt $S/pgxp-jit.txt
```

Expected: the only differences are lines naming the engine (Plan 5 saw the
same). Both runs exit 1 with the same `BELOW FLOOR` lines. That count is
Plan 3's open item, not this plan's. Any counter difference is a bug in
this task.

- [ ] **Step 12: Full suite and commit**

Run: `zig fmt ps1-core && zig build && zig build test`
Expected: PASS.

```bash
git add ps1-core/src/recompiler ps1-core/tests/jit_test.zig
git commit -m "feat(jit): load shadows beside their values, and branches and linking under PGXP"
```

---

### Task 3: Inline ALU in PGXP's base tier

With CPU mode off, an ALU op's handler only writes its register through
`writeReg`, and `Ctx.dst` already clears the shadow (Task 2). The one
exception is `addu`/`or` with `$zero` as `rt`. That is the register-move
idiom (`exec.zig`'s `rOpMove`), and it carries a shadow, so it stays a
call. With CPU mode on, every ALU op has a hook and stays a call.

**Files:**
- Modify: `ps1-core/src/recompiler/jit.zig` (`Lowering.under`),
  `ps1-core/src/recompiler/arm64/lower_alu.zig`
- Test: `ps1-core/tests/jit_test.zig`

**Interfaces:**
- Consumes: `Options.pgxp`, `Ctx.dst`'s clear (Task 2), `h.pgxpOn`, `h.shadowOf`.
- Produces: nothing new for later tasks.

- [ ] **Step 1: Write the failing tests**

Update "PGXP's tiers mask the lowering":

```zig
test "PGXP's tiers mask the lowering" {
    const all: jit.Lowering = .{};
    try expectEqual(all, all.under(.off));
    try expectEqual(try jit.Lowering.parse("alu,branch,link"), all.under(.base));
    // CPU mode's hooks run at every ALU op: those stay calls.
    try expectEqual(try jit.Lowering.parse("branch,link"), all.under(.cpu));
    try expectEqual(jit.Lowering.none, jit.Lowering.none.under(.base));
}
```

In "under PGXP a block lowers what its tier allows", change the `.base`
case to `.calls = 0`.

Add:

```zig
test ".jit equals .cached under PGXP's base tier: inline ALU clears shadows, and a move carries one" {
    if (!jit.available) return error.SkipZigTest;
    for ([_]jit.Pgxp{ .base, .cpu }) |tier| {
        var p = try Pair.init(&.{
            mips.addu(t0, t1, zero), // the move idiom: a call in both tiers
            mips.addiu(t2, t2, 1),
            mips.r(t4, t5, t3, 0x25), // OR t3, t4, t5
            mips.sll(t6, t6, 2),
            mips.beq(zero, zero, -1),
            mips.nop,
        }, 0x8000_1000);
        defer p.deinit();
        for ([_]*h.Machine{ &p.ref, &p.dut }) |m| {
            h.pgxpOn(m, tier);
            for ([_]u5{ t0, t1, t2, t3, t4, t5, t6 }) |r| m.cpu.gpr_shadow[r] = h.shadowOf(0);
        }
        try p.expectSameRuns(2);
        try expect(p.dut.cpu.gpr_shadow[t0].flags != 0); // carried from t1
        if (tier == .base) {
            for ([_]u5{ t2, t3, t6 }) |r| try expectEqual(@as(u32, 0), p.dut.cpu.gpr_shadow[r].flags);
        }
        // Base: only the move is a call. CPU: every ALU op is, nop included.
        const calls: u32 = if (tier == .base) 1 else 5;
        try expectEqual(calls, p.dut.bus.blocks.?.lookup(0x1000).?.calls);
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `zig build test -Dtest-filter="PGXP"`
Expected: the mask test and "a block lowers what its tier allows" FAIL
(base still has 9 calls), and the new test FAILS on its base-tier call
count (5, not 1).

- [ ] **Step 3: Lower ALU in the base tier, except the move**

`jit.zig`, `Lowering.under`, after `out.link = l.link;`:

```zig
        // CPU mode hooks every ALU op: its handler's work.
        out.alu = l.alu and tier == .base;
```

`lower_alu.zig`: replace the module comment's last paragraph ("Compiled
only while PGXP is off, ...") with:

```zig
//! Under PGXP's base tier `Ctx.dst` clears the destination's shadow, which
//! is all `writeReg` does there, and the register-move idiom stays a call.
//! Under the CPU tier nothing here is compiled (`Lowering.under`).
```

At the top of `special`, before the `switch`:

```zig
    // `addu`/`or` with $zero is PGXP's register move, which carries a
    // shadow (`exec.zig`'s `rOpMove`): its handler's work.
    if ((r.funct == 0x21 or r.funct == 0x25) and r.rt == 0 and ctx.opts.pgxp != .off) return false;
```

It returns before `beginInline`, so nothing has been emitted. That is
`emit`'s contract.

- [ ] **Step 4: Run the tests**

Run: `zig build test -Dtest-filter="PGXP"`, then `zig build test -Dtest-filter="fuzz"`
Expected: PASS. The base-tier fuzzer now runs inline ALU against handler
moves.

- [ ] **Step 5: Gates**

Run Task 2's Step 10 (PGXP-off `verify` and `savestate` under `.jit`) and
Step 11 (the `pgxp` diff). Also run the `base` tier:

```bash
zig build trace-golden -Doptimize=ReleaseFast -- pgxp --pgxp-no-cpu --engine=cached > $S/pgxp-nocpu-cached.txt 2>&1
zig build trace-golden -Doptimize=ReleaseFast -- pgxp --pgxp-no-cpu --engine=jit > $S/pgxp-nocpu-jit.txt 2>&1
diff $S/pgxp-nocpu-cached.txt $S/pgxp-nocpu-jit.txt
```

Expected: identical but for the engine lines, as in Task 2.

- [ ] **Step 6: Full suite and commit**

Run: `zig fmt ps1-core && zig build && zig build test`

```bash
git add ps1-core/src/recompiler/jit.zig ps1-core/src/recompiler/arm64/lower_alu.zig ps1-core/tests/jit_test.zig
git commit -m "feat(jit): inline ALU under PGXP's base tier"
```

---

### Task 4: Inline loads and stores under PGXP

The shadow rules of `opLoad` and `opStore` move into two `pub` functions in
`exec.zig`. The handlers call them as before, and two shims call them from
emitted code at the inline fast path's `done` label. The slow path never
reaches `done`, so each access runs its shadow rule exactly once. That
matters because `shadowLoadHalf` changes a RAM shadow's flags.

**Files:**
- Modify: `ps1-core/src/cpu/exec.zig` (`LoadType`, `StoreType`, `opLoad`, `opStore`),
  `ps1-core/src/recompiler/arm64/shadow.zig`,
  `ps1-core/src/recompiler/arm64/lower_memory.zig`,
  `ps1-core/src/recompiler/jit.zig` (`Lowering.under`)
- Test: `ps1-core/tests/jit_test.zig`

**Interfaces:**
- Consumes: `model.slot`, `layout.pinsLoadShadow` (Task 2), `Ctx`, `t.cpu_reg`, `t.pins_reg`.
- Produces: `pub const LoadType`, `pub const StoreType` in `exec.zig`;
  `exec.loadShadow(cpu: *Cpu, address: u32, ltype: LoadType, value: u32, signed: bool) Value`;
  `exec.storeShadow(cpu: *Cpu, address: u32, rt: u5, stype: StoreType) void`;
  `shadow.afterLoad(ctx: *t.Ctx, width: u3, signed: bool, value: e.Reg) void`;
  `shadow.afterStore(ctx: *t.Ctx, width: u3, rt: u5) void`.

- [ ] **Step 1: Write the failing tests**

Update "PGXP's tiers mask the lowering" to the final form:

```zig
test "PGXP's tiers mask the lowering" {
    const all: jit.Lowering = .{};
    try expectEqual(all, all.under(.off));
    try expectEqual(all, all.under(.base));
    // CPU mode's hooks run at every ALU op: those stay calls.
    try expectEqual(try jit.Lowering.parse("branch,load,store,link"), all.under(.cpu));
    try expectEqual(jit.Lowering.none, jit.Lowering.none.under(.base));
}
```

Add:

```zig
test ".jit equals .cached under PGXP: inline loads and stores move shadows as their handlers do" {
    if (!jit.available) return error.SkipZigTest;
    const k0 = h.k0;
    const k1 = h.k1;
    for ([_]jit.Pgxp{ .base, .cpu }) |tier| {
        var p = try Pair.init(&.{
            mips.lui(k1, 0x1F80), // the scratchpad
            mips.lui(k0, 0x0020), // RAM's first mirror: the slow path
            mips.lw(t0, zero, 0x2000),
            mips.sw(t0, zero, 0x2010), // t0's OLD shadow: its load lands after
            mips.i(0x21, zero, t1, 0x2004), // LH, the matching half
            mips.i(0x21, zero, zero, 0x2006), // LH to $zero: still clears a flag
            mips.i(0x24, zero, t2, 0x2008), // LBU: no shadow
            mips.i(0x29, zero, t1, 0x2014), // SH
            mips.i(0x28, zero, t0, 0x2018), // SB: destroys the word's shadow
            mips.lw(t3, k1, 0),
            mips.sw(t3, k1, 0x10),
            mips.lw(t4, k0, 0x2000), // slow path; lands in the next op
            mips.addu(t5, t4, t1),
            mips.beq(zero, zero, -1),
            mips.nop,
        }, 0x8000_1000);
        defer p.deinit();
        const data = [_]u32{ 0x1111_2222, 0x3333_4444, 0x5555_6666, 0, 0x7777_8888, 0x9999_AAAA, 0xBBBB_CCCC };
        for ([_]*h.Machine{ &p.ref, &p.dut }) |m| {
            h.pgxpOn(m, tier);
            h.poke(m.bus, 0x2000, &data);
            for (data, 0..) |w, k| m.bus.ram_shadow[0x2000 / 4 + k] = h.shadowOf(w);
            // The word at 0x2004 recorded against another high half: the
            // `lh` of 0x2006 finds it stale and clears its valid_y.
            m.bus.ram_shadow[0x2004 / 4] = h.shadowOf(data[1] ^ 0xFFFF_0000);
            m.bus.write32(0x1F80_0000, 0xDDDD_EEEE);
            m.bus.scratch_shadow[0] = h.shadowOf(0xDDDD_EEEE);
            for ([_]u5{ t0, t1, t2, t3, t4, t5 }) |r| m.cpu.gpr_shadow[r] = h.shadowOf(0);
            m.start(0x8000_1000);
        }
        try p.expectSameRuns(2);
        try expect(p.dut.cpu.gpr_shadow[t0].flags != 0);
        try expect(p.dut.cpu.gpr_shadow[t4].flags != 0); // from the slow path's slot
        try expectEqual(@as(u32, 0), p.dut.bus.ram_shadow[0x2004 / 4].flags & ps1_core.pgxp.Value.valid_y);
        // Base: nothing is a call. CPU: the two `lui`s, the `addu` and the nop.
        const calls: u32 = if (tier == .base) 0 else 4;
        try expectEqual(calls, p.dut.bus.blocks.?.lookup(0x1000).?.calls);
    }
}

test ".jit equals .cached under PGXP: a load in a delay slot syncs its shadow for the next block" {
    if (!jit.available) return error.SkipZigTest;
    for ([_]jit.Pgxp{ .base, .cpu }) |tier| {
        var p = try Pair.init(&.{
            mips.beq(zero, zero, 3), // -> 0x1010
            mips.lw(t0, zero, 0x2000), // delay slot: lands in the next block
            mips.nop,
            mips.nop,
            mips.addiu(t1, zero, 1), // 0x1010
            mips.beq(zero, zero, -1),
            mips.nop,
        }, 0x8000_1000);
        defer p.deinit();
        for ([_]*h.Machine{ &p.ref, &p.dut }) |m| {
            h.pgxpOn(m, tier);
            h.poke(m.bus, 0x2000, &.{0x1234_5678});
            m.bus.ram_shadow[0x2000 / 4] = h.shadowOf(0x1234_5678);
            m.start(0x8000_1000);
        }
        try p.expectSameRuns(3);
        try expect(p.dut.cpu.gpr_shadow[t0].flags != 0);
    }
}
```

Check the scratchpad write: `m.bus.write32(0x1F80_0000, ...)` is a host
write through `Bus`. It must not bill a wait state that `start` doesn't
clear (`start` zeroes `wait_cycles`, and it runs after the write). If
`write32` refuses the scratchpad address, write
`m.bus.scratchpad[0..4]` with `std.mem.writeInt(u32, ..., .little)`
instead.

- [ ] **Step 2: Run them to see them fail**

Run: `zig build test -Dtest-filter="PGXP"`
Expected: the mask test FAILS. "inline loads and stores move shadows"
FAILS on its call count (loads and stores are still calls). The
delay-slot test may already pass: it gates `sync`'s `load_shadow` write,
which Task 2 built, and becomes meaningful once the load is inline.

- [ ] **Step 3: Share the shadow rules in `exec.zig`**

Make the two enums public:

```zig
pub const LoadType = enum { Byte, Half, Word };
```

```zig
pub const StoreType = enum { Byte, Half, Word };
```

Add, before `opLoad`:

```zig
/// The shadow a load issues beside its value (`Cpu.load_shadow`). A byte
/// cannot carry a coordinate, so `.Byte` keeps nothing. A half-word can:
/// the addressed half becomes the register's low half, which is the other
/// end of the `sh` idiom in `storeShadow`. The JIT's inline loads call it
/// too (`recompiler/arm64/shadow.zig`).
pub inline fn loadShadow(cpu: *Cpu, address: u32, ltype: LoadType, value: u32, signed: bool) Value {
    return switch (ltype) {
        .Word => cpu.bus.shadowLoad(address),
        .Half => cpu.bus.shadowLoadHalf(address, value, signed),
        .Byte => Value.none,
    };
}
```

In `opLoad`, replace the comment and `cpu.load_shadow = switch ...` block
with:

```zig
    cpu.load_shadow = loadShadow(cpu, address, ltype, final_val, signed);
```

Add, before `opStore`. The comments move here verbatim from `opStore`'s
switch:

```zig
/// What a store does to PGXP's shadows, before the store itself. The JIT's
/// inline stores call it too (`recompiler/arm64/shadow.zig`).
pub inline fn storeShadow(cpu: *Cpu, address: u32, rt: u5, stype: StoreType) void {
    switch (stype) {
        .Word => {
            const p = cpu.gpr_shadow[rt];
            cpu.bus.shadowStore(address, p);
            // Gated: this runs on every word store in the machine, one of the
            // hottest paths there is, and with PGXP off `p` is always
            // `Value.none` anyway (see `writeReg`/`writeRegPrecise`), so the
            // store would be a guaranteed-no-op write, not a guaranteed skip.
            if (cpu.bus.pgxp_enabled) cpu.bus.pgxp_pending = p;
        },
        // A half-word store carries the register's low half into the addressed
        // half of the destination and leaves the other half alone, which is
        // how a game that keeps its two coordinates in separate registers
        // moves them. It still drops any pending GP0 provenance a PRECEDING
        // `sw` armed: a half-word store to GP0 is not a vertex, and without
        // this it would hand an unrelated register's shadow to whichever GP0
        // word arrives next.
        .Half => {
            cpu.bus.shadowStoreHalf(address, cpu.gpr_shadow[rt]);
            if (cpu.bus.pgxp_enabled) cpu.bus.pgxp_pending = Value.none;
        },
        // A byte store lands inside a tracked word and destroys it — a byte
        // cannot carry a coordinate, so there is nothing to keep. Same GP0
        // provenance reasoning as above.
        .Byte => {
            cpu.bus.shadowInvalidate(address);
            if (cpu.bus.pgxp_enabled) cpu.bus.pgxp_pending = Value.none;
        },
    }
}
```

`opStore`'s tail becomes:

```zig
    const value = cpu.readReg(instr.i.rt);
    storeShadow(cpu, address, instr.i.rt, stype);
    switch (stype) {
        .Word => cpu.bus.writeCpuStore(u32, address, value),
        .Half => cpu.bus.writeCpuStore(u16, address, value),
        .Byte => cpu.bus.writeCpuStore(u8, address, value),
    }
```

`instr.i.rt` is a `u5` already. If it isn't, use `cpu.getIdx(instr.i.rt)`
as the old code did. Both functions are `inline`, so the handlers' calls
with comptime-known types fold to exactly the code they ran before.

Run `zig build test -Dtest-filter="cached"` and
`zig build trace-golden -Doptimize=ReleaseFast -- pgxp` (the interpreter
sweep). Expected: green, with output identical to before this step. This
proves the move changed no handler behaviour before any JIT code uses it.

- [ ] **Step 4: The shims in `shadow.zig`**

Add the imports:

```zig
const t = @import("translate.zig");
const layout = @import("layout.zig");
const model = @import("model.zig");
const Cpu = @import("../../cpu/cpu.zig").Cpu;
const exec = @import("../../cpu/exec.zig");
```

And append:

```zig
/// At an inline load's `done`: the shadow it issues, into its value's slot.
/// w9 still holds the address and `value` the loaded word, sign- or
/// zero-extended as the handler extends it.
pub fn afterLoad(ctx: *t.Ctx, width: u3, signed: bool, value: e.Reg) void {
    const em = ctx.em;
    em.put(e.movReg(.w, .x2, .x9));
    em.put(e.movReg(.x, .x0, t.cpu_reg));
    em.put(e.addImm(.x, .x1, t.pins_reg, @intCast(layout.pinsLoadShadow(model.slot(value)))));
    em.put(e.movReg(.w, .x3, value));
    em.put(e.movz(.w, .x4, @intFromEnum(sized(exec.LoadType, width)), 0));
    em.put(e.movz(.w, .x5, @intFromBool(signed), 0));
    em.call(@intFromPtr(&loadShim));
}

/// At an inline store's `done`, before the op retires: what the store does
/// to the shadows. A load landing in `rt` has not landed yet, so the store
/// carries `rt`'s old shadow, as it carries its old value. w9 still holds
/// the address.
pub fn afterStore(ctx: *t.Ctx, width: u3, rt: u5) void {
    const em = ctx.em;
    em.put(e.movReg(.w, .x1, .x9));
    em.put(e.movReg(.x, .x0, t.cpu_reg));
    em.put(e.movz(.w, .x2, rt, 0));
    em.put(e.movz(.w, .x3, @intFromEnum(sized(exec.StoreType, width)), 0));
    em.call(@intFromPtr(&storeShim));
}

fn sized(comptime T: type, width: u3) T {
    return switch (width) {
        1 => .Byte,
        2 => .Half,
        4 => .Word,
        else => unreachable,
    };
}

// What the emitted code calls: the handlers' own rules.

fn loadShim(cpu: *Cpu, slot: *Value, address: u32, value: u32, ltype: u32, signed: u32) callconv(.c) void {
    slot.* = exec.loadShadow(cpu, address, @enumFromInt(ltype), value, signed != 0);
}

fn storeShim(cpu: *Cpu, address: u32, rt: u32, stype: u32) callconv(.c) void {
    exec.storeShadow(cpu, address, @intCast(rt), @enumFromInt(stype));
}
```

A call clobbers x0-x18. Nothing at `done` needs them after the call: the
value is in x27 or x28 (callee-saved), and `endInline`'s `retire` uses
only w9 and the callee-saved registers.

- [ ] **Step 5: Call them from `lower_memory.zig`**

Add `const shadow = @import("shadow.zig");`. In `emitLoad`, after
`em.bind(done);` and before `ctx.endInline();`:

```zig
    if (ctx.opts.pgxp != .off) shadow.afterLoad(ctx, form.width, form.op == .ldrsb or form.op == .ldrsh, value);
```

In `emitStore`, at the same place:

```zig
    if (ctx.opts.pgxp != .off) shadow.afterStore(ctx, form.width, in.i.rt);
```

Before relying on "w9 still holds the address at `done`", check every
emission between `address()` and `done` on both paths. RAM loads use
x10/x11. RAM stores use x11/x12/x13 (`ctx.src(in.i.rt, .x13)`).
`scratchpadOffset` uses x11. None of them writes x9. Then check that
`Bus.writeCpuStore` touches no shadow or `pgxp_pending` for a RAM or
scratchpad address (`grep -n "shadow\|pgxp_pending" ps1-core/src/memory.zig`,
and read the RAM path of `Bus.write`). The handler runs `storeShadow`
before the write and the inline path runs it after, which is equivalent
only while that holds.

Add a line to `lower_memory.zig`'s module comment: "Under PGXP each inline
access then runs its handler's shadow rule through a shim
(`shadow.afterLoad`/`afterStore`); the slow path never reaches it, so the
rule runs once."

- [ ] **Step 6: Let loads and stores lower under PGXP**

`jit.zig`, `Lowering.under`, in its final form:

```zig
    /// What may be inline under PGXP tier `tier`. Every family leaves the
    /// shadows its handler would, except the ALU under CPU mode, whose
    /// hooks are the handlers' work.
    pub fn under(l: Lowering, tier: Pgxp) Lowering {
        var out = l;
        if (tier == .cpu) out.alu = false;
        return out;
    }
```

- [ ] **Step 7: Run the tests**

Run: `zig build test -Dtest-filter="PGXP"`, then `zig build test -Dtest-filter="fuzz"`
Expected: PASS. The PGXP fuzzers now exercise everything Plan 6 lowers:
loads and stores to RAM, mirrors and the scratchpad, misaligned ones that
fault, and cancelled loads.

- [ ] **Step 8: Gates**

Run Task 2's Steps 10 and 11 and Task 3's Step 5 (the `--pgxp-no-cpu`
diff). Expected as there.

- [ ] **Step 9: Full suite and commit**

Run: `zig fmt ps1-core && zig build && zig build test && zig build capi-lib`

```bash
git add ps1-core/src/cpu/exec.zig ps1-core/src/recompiler ps1-core/tests/jit_test.zig
git commit -m "feat(jit): inline loads and stores under PGXP"
```

---

### Task 5: Gates, the bench, and the as-built notes

**Files:**
- Modify: `CLAUDE.md`, `docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md` (through the index only)

- [ ] **Step 1: Every gate**

```bash
zig build -Doptimize=ReleaseFast
zig build test
zig build capi-lib
S=$TMPDIR/plan6-t5; mkdir -p $S
# The interpreter: nothing moved.
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- savestate
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
zig build trace-golden -Doptimize=ReleaseFast -- pgxp > $S/pgxp-interp.txt 2>&1
# The block engines with PGXP off.
zig build trace-golden -Doptimize=ReleaseFast -- verify --engine=cached
for m in verify savestate stream-verify; do zig build trace-golden -Doptimize=ReleaseFast -- $m --engine=jit; done
zig build trace-golden -Doptimize=ReleaseFast -- lockstep --engine=jit
# PGXP on: .jit against .cached, both tiers.
for e in cached jit; do
  zig build trace-golden -Doptimize=ReleaseFast -- pgxp --engine=$e > $S/pgxp-$e.txt 2>&1
  zig build trace-golden -Doptimize=ReleaseFast -- pgxp --pgxp-no-cpu --engine=$e > $S/pgxp-nocpu-$e.txt 2>&1
  zig build trace-golden -Doptimize=ReleaseFast -- stream-capture --pgxp-on --engine=$e --out=$S/fx-$e
done
diff $S/pgxp-cached.txt $S/pgxp-jit.txt
diff $S/pgxp-nocpu-cached.txt $S/pgxp-nocpu-jit.txt
diff -r $S/fx-cached $S/fx-jit
```

Expected:
- The interpreter gates are green, with no recapture. `pgxp-interp.txt`
  exits 1 with the same `BELOW FLOOR` lines as before Plan 6 (Plan 3's
  open item).
- `.jit` is OK on all nine for `verify`, `savestate` and `stream-verify`.
  Lockstep has 0 mismatches; record the checked and skipped counts, which
  should equal Plan 5's because lockstep runs with PGXP off.
- The two `pgxp` diffs show only engine lines.
- `diff -r` of the fixtures prints nothing. Every `<key>-pgxp.p1fx` is
  byte-identical under both engines, so every precise vertex reached GP0
  the same way.

If `stream-capture` doesn't take `--engine`, check `selectEngine`'s callers
in `ps1-golden/src/main.zig`. Every mode calls it, so the flag should be
honoured.

- [ ] **Step 2: Bench**

```bash
CUE="games/Croc - Legend of the Gobbos/Croc - Legend of the Gobbos.cue"
B=./zig-out/bin/ps1-bench-dual
for i in 1 2 3 4 5; do
  $B SCPH-1001_BIOS_1995_US.bin "$CUE" 3000 --engine=interpreter pgxp
  $B SCPH-1001_BIOS_1995_US.bin "$CUE" 3000 --engine=cached pgxp
  $B SCPH-1001_BIOS_1995_US.bin "$CUE" 3000 --engine=jit pgxp
  $B SCPH-1001_BIOS_1995_US.bin "$CUE" 3000 --engine=jit pgxp pgxp-no-cpu
  $B SCPH-1001_BIOS_1995_US.bin "$CUE" 3000 --engine=jit
done
```

Record the best of five for each. The baseline is Plan 5's `.jit` with
PGXP on: 11.347 s. Let the machine settle before the first round (a run
straight after `trace-golden` reads 15% slow).

- [ ] **Step 3: The spec's as-built section**

Write a `### As built (Plan 6, <date>)` section in the same shape as Plan
5's. Put it directly before `## Block engines: timing`, which follows Plan
5's as-built section. Cover:
- what lowers in each tier;
- the names (`jit.Pgxp`, `Lowering.under`, `run.pgxpTier`,
  `Bus.setPgxpCpu`, `Pins.load_shadows`, `model.slot`, `Model.readBack`,
  `shadow.zig`, `exec.loadShadow`/`storeShadow`);
- the departures (`--pgxp-no-cpu` already existed; the PGXP fuzzers run
  250 programs);
- any change made during the build;
- the gate results from Step 1, with real counts;
- the bench table from Step 2 (engine, best, fps, realtime);
- a "What Plan 7 inherits" list. At minimum: whether inlining the ALU
  under the `cpu` tier is now worth it, judged from the `pgxp` against
  `pgxp pgxp-no-cpu` gap. That gap is the most the `cpu` tier's ALU calls
  can be costing.

Commit it without the owner's uncommitted re-alignment, through the
index:

```bash
F=docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md
S=$TMPDIR/plan6-spec; mkdir -p $S
# $S/asbuilt.md holds the new section, ending in a blank line.
git show HEAD:$F > $S/head.md
awk -v sec="$S/asbuilt.md" '/^## Block engines: timing/{while((getline l < sec)>0) print l} {print}' $S/head.md > $S/head-new.md
awk -v sec="$S/asbuilt.md" '/^## Block engines: timing/{while((getline l < sec)>0) print l} {print}' $F > $S/wt-new.md && cp $S/wt-new.md $F
git update-index --cacheinfo 100644,$(git hash-object -w $S/head-new.md),$F
git diff --cached --stat   # one file, only the new section's lines
```

- [ ] **Step 4: CLAUDE.md**

Replace the JIT rule

```
- **The JIT lowers nothing while PGXP is on, and `Bus.setPgxp` flushes the
  block cache on every toggle.** Plan 6 emits the shadow code; until then an
  inline op would skip the hooks `exec.zig` calls.
```

with

```
- **Under PGXP the JIT lowers by tier, and a tier change flushes.**
  `run.pgxpTier` reads the two switches once per compile: with CPU mode off
  every family is inline, with it on the ALU stays calls (its hooks).
  Every inline register write clears its shadow (`Ctx.dst`), and a load's
  shadow waits in `Pins.load_shadows` beside its value: never rotate
  `Cpu.load_shadow` in emitted code, because a slow path's handler rotates
  it again. `Bus.setPgxp` and `Bus.setPgxpCpu` flush on every change.
```

In the PGXP rule that lists one accessor per consumer, after "and
`exec.zig`'s `cpuMode`", add: "; the JIT's is `run.pgxpTier`, read once per
compiled block".

Then `git add CLAUDE.md`.

- [ ] **Step 5: Commit**

```bash
git commit -m "docs: Plan 6 as built, and the JIT's PGXP tiers in CLAUDE.md"
git status --short   # the spec still shows the owner's own modification, nothing else of this plan's
```
