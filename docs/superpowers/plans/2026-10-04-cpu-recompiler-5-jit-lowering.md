# CPU recompiler, Plan 5: JIT lowering. Implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `.jit` faster than `.cached` by emitting real arm64 for the
hot instruction families (ALU and shifts, branches, RAM and scratchpad
loads and stores) and by linking blocks, while `.jit` still equals `.cached`
exactly on every gate and against the shared `trace-block/` goldens.

**Architecture:** The Plan 4 translator is rebuilt around a two-section
emitter (hot path, cold slow paths) and two pieces of compile-time
bookkeeping that replace `cached.execute`'s per-instruction work: the cycle
and step counts (a lagging counter plus closed-form commits) and the
pipeline and load delay (`model.zig`, which writes `Cpu.pipeline` and
`Cpu.load_delay` only when something can read them). Each lowered family is
one file. An inline op's slow path is always the op's own `exec.zig`
handler through `cached.runOp`, so exceptions, MMIO and invalidation keep
one implementation. Linking adds `Cpu.runFor(budget)`: one call may run
blocks back to back, stopping at the first block end at or past the budget
or when a device is due, which is exactly where one block per call would
have stopped.

**Tech Stack:** Zig 0.17.0, `ps1-core` (`recompiler/`), arm64 machine code,
macOS `MAP_JIT`, `ps1-golden` (trace-golden), `ps1-bench`, the ROM suites,
`xctrace`.

**Spec:** `docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md`.
Before starting, read "The arm64 JIT (`.jit`)" (all of it), "Block engines:
timing", "Blocks, the cache and invalidation", "Testing and gates", the
"As built" sections for Plans 3 and 4 (Plan 4's "What Plan 5 inherits"
above all), and Plans → 5. Then read the code this plan rebuilds:
`ps1-core/src/recompiler/{run,cached,block,cache,jit,lockstep}.zig` and
`ps1-core/src/recompiler/arm64/*.zig`.

## Global Constraints

- `zig version` is **0.17.0**. No `**` array repeat (use `@splat`),
  `std.ArrayList` is unmanaged, `zig fmt` rewrites `@intFromEnum` to
  `@backingInt`, decl literals (`.zr`, `.none`, `.entry(pc)`) are used
  throughout.
- **The JIT exists only on `aarch64-macos`.** Everything that touches
  MAP_JIT or calls emitted code sits behind `if (comptime jit.available)`.
  `zig build` builds the wasm target, which is the check that the gating
  holds. Run it in every task.
- **No interpreter golden moves.** `trace-golden -- verify`, `-- savestate`,
  `-- stream-verify` and `-- pgxp` stay green on the interpreter with **no
  recapture**.
- **No `trace-block/` golden is recaptured.** `.jit` must equal `.cached`
  exactly. A `verify --engine=jit` mismatch is a JIT bug, never a reason to
  capture. `.cached` must compute exactly what it computes today.
- **Instruction semantics live in `exec.zig`.** Inline code may only
  reproduce what a handler does on the fast path; every exception,
  misaligned access, MMIO access and invalidation goes through the handler
  (the slow path). Never add a second implementation of an exception.
- **No savestate format change**, no section version bump.
- **The JIT lowers nothing while PGXP is on** (Plan 6 emits the shadow
  code). A compiled block is all calls under PGXP, and `Bus.setPgxp`
  flushes the cache on every toggle.
- `ps1-trace`, `ps1-debug`, `ps1-capi`, `ps1-wasm` and the Swift app get no
  changes. The app's engine setting and `ps1_run_frame`'s switch to
  `runFor` are Plan 7.
- No file in `ps1-core/src` over ~600 lines. Every new file here stays under
  ~300.
- Commits go directly on `master`, one per task. The **commit message is
  the title line only**: no body, no trailer. **Never `git push`.**
- Run `zig fmt` on every touched `.zig` file before committing.
- Every `trace-golden` and bench run is `-Doptimize=ReleaseFast`.
- `docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md` carries an
  uncommitted table re-alignment by the owner. Never stage it: Task 10
  stages only its own section with `git add -p`.

### Deliberate departures from the spec (flag these in review, do not "fix" them)

1. **Guest registers stay in `Cpu.regs`.** The spec's per-block register
   cache (guest registers in x23-x28, written back around calls) is not
   built. Every inline op loads its sources from `cpu.regs` and stores its
   result there, about four host instructions against roughly forty for a
   call. A register cache adds a write-back obligation at every call, slow
   path and exit, the riskiest bookkeeping a JIT has, for a gain Task 10's
   profile must justify first. It is a follow-up, decided by that profile.
2. **x21 is the scratchpad base, not `downcount`.** `downcount` stays in
   `Bus.sched`: every commit (a Zig call) updates it, and the only reader in
   emitted code is a linked block's entry, where one load costs nothing. A
   register copy would need the spec's own "written back before, reloaded
   after every call".
3. **A linked block starts when `downcount > 0`, not after `subs x21,
   #static_cost / b.le`.** The dispatcher starts a block whenever
   `downcount > 0`, whatever the block costs. `.jit` must equal `.cached`
   (they share `trace-block/`), so the link check is the dispatcher's own.
4. **No `Block.segment`; the fetch cost stays a runtime argument (w23).**
   Inline code bakes guest PCs in, so a block entered through another
   segment than it was compiled for (KSEG0 against KSEG1, or a RAM mirror)
   is dropped and compiled again: the spec's segment-mismatch rule, keyed on
   `Block.start_pc`. A BIOS wait-state write still applies from the next
   block, as in Plan 4.
5. **`PS1_JIT_DUMP` and the lower/call mask are harness flags, not
   environment variables:** `ps1-golden --jit-dump=` and `--jit-lower=`
   (and `ps1-bench --jit-lower=`). The core builds freestanding for wasm and
   reads no environment. The mask is per family (alu, branch, load, store,
   link), not per opcode: lockstep names the block, the family mask names
   the family. A per-opcode mask is a follow-up if a bisect ever needs it.
6. **The indirect-jump lookup is inline at each JR/JALR exit**, not a
   shared stub. Same lookup, no extra branch.
7. **`Cpu.runFor(budget)` is new.** The spec argues that skipping the
   dispatcher on a linked jump is unobservable. It is unobservable to the
   machine, but not to a frontend that acts between calls by step count:
   `ps1-golden` samples state and drives the pad at step counts. `run()`
   stays one block per call (`runFor(1)`); `runFor` chains, and stops at the
   first block end at or past the budget.
8. **The flush on a PGXP toggle arrives here, not in Plan 6**, because this
   plan is the first to compile code that differs with PGXP.
9. **Stay calls:** LWL, LWR, SWL, SWR, LWC2, SWC2, MULT/DIV, HI/LO moves,
   every COP0 and COP2 op, SYSCALL, BREAK, reserved opcodes, and a branch in
   another branch's delay slot.
10. **RAM mirrors (2-8 MB) take the slow path.** `Bus.waitCycles` bills 4
    wait states for the first 2 MB and 2 for the mirrors; the inline path
    bills only the first.

## Review Focus

The five conditions most likely to bite a player that no family's own tests
reach. Each has a test in the task named.

1. **A DMA (or any `Bus.write`) into the page of a block other blocks link
   to.** Expected: the next jump to it runs the new code. Test: Task 8,
   "linked: a host write into a linked block's page".
2. **A code-buffer flush while an exit is waiting to be linked.** Expected:
   the pending site is forgotten with the code it named, nothing is patched
   into reset memory. Test: Task 8, "linked: a full code buffer drops a
   pending link site".
3. **PGXP switched on with lowered blocks compiled.** Expected: the cache
   flushes and every later block is all calls. Test: Task 3, "with PGXP on
   nothing is lowered".
4. **The same code entered through KSEG0, KSEG1 and a mirror.** Expected:
   each entry runs code compiled for its own PCs; a jump through a register
   never enters the wrong one. Tests: Task 3, "one RAM block entered through
   KSEG0, then KSEG1"; Task 9, "linked: a jump through a register refuses
   KSEG1, a mirror and a block compiled for another address".
5. **A chain that would run past a frontend's event.** Expected: a
   `runFor` call stops at the first block end at or past its budget, never
   later, and when a device is due. Test: Task 8, `expectSameLinked` checks
   it on every call, and the linked fuzzer.

---

## File structure

| File | Responsibility |
| --- | --- |
| `ps1-core/src/recompiler/arm64/emit.zig` | the pure encoder; grows the data-processing, bitfield, conditional, load/store and branch forms |
| `ps1-core/src/recompiler/arm64/emitter.zig` (new) | hot and cold sections, labels, branch fixups, `finish` |
| `ps1-core/src/recompiler/arm64/layout.zig` (new) | byte offsets into `Cpu`, `Pins` and `Block`, with build-time range checks |
| `ps1-core/src/recompiler/arm64/translate.zig` | prologue, per-op dispatch, calls, slow paths, cycle accounting, the block's end |
| `ps1-core/src/recompiler/arm64/model.zig` (new) | the compile-time pipeline and load-delay model |
| `ps1-core/src/recompiler/arm64/lower_alu.zig` (new) | ALU, shift, logic, LUI, SLT |
| `ps1-core/src/recompiler/arm64/lower_branch.zig` (new) | branches and jumps |
| `ps1-core/src/recompiler/arm64/lower_memory.zig` (new) | RAM and scratchpad loads and stores |
| `ps1-core/src/recompiler/arm64/link.zig` (new) | linked entries, exits, the relink stub, the indirect lookup |
| `ps1-core/src/recompiler/arm64/code_buffer.zig` | `base`/`pin`, `cursor`, `patch` |
| `ps1-core/src/recompiler/jit.zig` | `Jit` (buffer, emitter, stubs, lowering, dump hook), `Lowering`, `execute` |
| `ps1-core/src/recompiler/cache.zig` | `Pins`, the `jit` field, `discard`, unlink on drop |
| `ps1-core/src/recompiler/block.zig` | `code_words`, `link_entry`, `isBranch`/`issuesLoad` made public |
| `ps1-core/src/recompiler/run.zig` | `compileBlock`, `blockAt`, relinking, the budget, `setLowering`, `setJitDump` |
| `ps1-core/src/recompiler/lockstep.zig` | the "io" mismatch and its `stray` seam |
| `ps1-core/src/cpu/cpu.zig` | `runFor` |
| `ps1-core/src/memory.zig` | `ram_access_wait`, the flush on a PGXP toggle |
| `ps1-core/tests/jit_test.zig`, `recompiler_helpers.zig`, `recompiler_test.zig` | the tests |
| `ps1-golden/src/main.zig`, `ps1-golden/src/script.zig` | `--jit-lower`, `--jit-dump`, `runFor` with the next event as budget, `Pad.next` |
| `ps1-bench/main.zig` | `--jit-lower`, `runFor` |

---

### Task 1: Encoder forms and the two-section emitter

**Files:**
- Modify: `ps1-core/src/recompiler/arm64/emit.zig`
- Create: `ps1-core/src/recompiler/arm64/emitter.zig`
- Modify: `ps1-core/src/recompiler/jit.zig` (export `emitter`)
- Test: `ps1-core/tests/jit_test.zig`

**Interfaces:**
- Consumes: Plan 4's `emit.zig` (`Reg`, `Width`, `addImm`, `addReg`,
  `movReg`, `movz`, `movk`, `stp`, `ldp`, `blr`, `ret`, `b`, `cbnz`).
- Produces, in `emit.zig`: `Cond` (`eq ne hs lo mi pl vs vc hi ls ge lt gt
  le`), `Shift` (`lsl lsr asr`), `MemImm` (`strb ldrb str_w ldr_w str_x
  ldr_x`), `MemReg` (`strb ldrb ldrsb strh ldrh ldrsh str_w ldr_w ldr_x`);
  `subImm(width, rd, rn, u12)`, `cmpImm(width, rn, u12)`,
  `subReg/addsReg/subsReg/andReg/orrReg/eorReg/ornReg(width, rd, rn, rm)`,
  `cmpReg(width, rn, rm)`, `neg(width, rd, rm)`, `shiftReg(width, Shift,
  rd, rn, rm)`, `shiftImm(Shift, rd, rn, u5)` (w only), `ubfx(rd, rn, u5
  lsb, u6 width)` (w only), `madd(width, rd, rn, rm, ra)`, `csel(width,
  rd, rn, rm, Cond)`, `cset(width, rd, Cond)`, `bl(i28)`, `br(rn)`,
  `bCond(Cond, i21)`, `cbz(width, rt, i21)`, `tbnz(rt, u5 bit, i16)`,
  `memImm(MemImm, rt, rn, u32 byte_offset)`, `memReg(MemReg, rt, rn, rm,
  scaled: bool)`.
- Produces, in `emitter.zig`: `max_words`, `Section` (`hot`, `cold`),
  `Label` (`u16`), `Target` (`label: Label` / `address: usize`), `Branch`
  (`b`, `bl`, `cond: Cond`, `cbz: {Width, Reg}`, `cbnz: {Width, Reg}`,
  `tbnz: {Reg, u5}`), `Emitter` with `reset`, `put`, `label`, `bind`,
  `branch`, `movImm32`, `movImm64`, `call`, `len`, `finish(at) []const u32`
  and `addressOf(label, at) usize`. `jit.emitter` re-exports it.

- [ ] **Step 1: Write the failing encoder rows**

Append these rows to the `cases` array of `test "the encoder matches the
assembler"` in `ps1-core/tests/jit_test.zig`. Every expected word below was
assembled by `clang -arch arm64 -c` from the line in its comment and read
back with `objdump -d`; to pin another form, do the same.

```zig
        .{ emit.subImm(.w, .x25, .x26, 1), 0x51000759 }, // sub w25, w26, #1
        .{ emit.subImm(.x, .x9, .lr, 4), 0xd10013c9 }, // sub x9, x30, #4
        .{ emit.subImm(.w, .x26, .x26, 3), 0x51000f5a }, // sub w26, w26, #3
        .{ emit.addImm(.w, .x26, .x26, 3), 0x11000f5a }, // add w26, w26, #3
        .{ emit.addImm(.w, .x9, .x9, 4), 0x11001129 }, // add w9, w9, #4
        .{ emit.addImm(.x, .x10, .x10, 0x10), 0x9100414a }, // add x10, x10, #0x10
        .{ emit.subReg(.w, .x9, .x26, .x25), 0x4b190349 }, // sub w9, w26, w25
        .{ emit.madd(.w, .x1, .x9, .x23, .x24), 0x1b176121 }, // madd w1, w9, w23, w24
        .{ emit.neg(.w, .x24, .x23), 0x4b1703f8 }, // neg w24, w23
        .{ emit.addsReg(.w, .x9, .x10, .x11), 0x2b0b0149 }, // adds w9, w10, w11
        .{ emit.subsReg(.w, .x9, .x10, .x11), 0x6b0b0149 }, // subs w9, w10, w11
        .{ emit.cmpReg(.w, .x10, .x11), 0x6b0b015f }, // cmp w10, w11
        .{ emit.cmpReg(.w, .x9, .zr), 0x6b1f013f }, // cmp w9, wzr
        .{ emit.cmpImm(.x, .x9, 0), 0xf100013f }, // cmp x9, #0
        .{ emit.cmpImm(.w, .x10, 0x400), 0x7110015f }, // cmp w10, #0x400
        .{ emit.cmpImm(.w, .x10, 5), 0x7100155f }, // cmp w10, #5
        .{ emit.andReg(.w, .x9, .x10, .x11), 0x0a0b0149 }, // and w9, w10, w11
        .{ emit.orrReg(.w, .x9, .x10, .x11), 0x2a0b0149 }, // orr w9, w10, w11
        .{ emit.eorReg(.w, .x9, .x10, .x11), 0x4a0b0149 }, // eor w9, w10, w11
        .{ emit.ornReg(.w, .x9, .zr, .x9), 0x2a2903e9 }, // mvn w9, w9
        .{ emit.addReg(.w, .x9, .zr, .x11), 0x0b0b03e9 }, // add w9, wzr, w11
        .{ emit.movReg(.w, .x25, .x26), 0x2a1a03f9 }, // mov w25, w26
        .{ emit.shiftReg(.w, .lsl, .x9, .x10, .x11), 0x1acb2149 }, // lsl w9, w10, w11
        .{ emit.shiftReg(.w, .lsr, .x9, .x10, .x11), 0x1acb2549 }, // lsr w9, w10, w11
        .{ emit.shiftReg(.w, .asr, .x9, .x10, .x11), 0x1acb2949 }, // asr w9, w10, w11
        .{ emit.shiftReg(.x, .lsr, .x12, .x12, .x11), 0x9acb258c }, // lsr x12, x12, x11
        .{ emit.shiftImm(.lsl, .x9, .x10, 5), 0x531b6949 }, // lsl w9, w10, #5
        .{ emit.shiftImm(.lsr, .x9, .x10, 5), 0x53057d49 }, // lsr w9, w10, #5
        .{ emit.shiftImm(.asr, .x9, .x10, 5), 0x13057d49 }, // asr w9, w10, #5
        .{ emit.shiftImm(.lsl, .x9, .x10, 31), 0x53010149 }, // lsl w9, w10, #31
        .{ emit.shiftImm(.lsr, .x11, .x10, 21), 0x53157d4b }, // lsr w11, w10, #21
        .{ emit.shiftImm(.lsr, .x10, .x9, 29), 0x531d7d2a }, // lsr w10, w9, #29
        .{ emit.ubfx(.x9, .x10, 0, 29), 0x53007149 }, // ubfx w9, w10, #0, #29
        .{ emit.ubfx(.x10, .x9, 0, 21), 0x5300512a }, // ubfx w10, w9, #0, #21
        .{ emit.ubfx(.x11, .x10, 12, 9), 0x530c514b }, // ubfx w11, w10, #12, #9
        .{ emit.ubfx(.x11, .x10, 2, 19), 0x5302514b }, // ubfx w11, w10, #2, #19
        .{ emit.cset(.w, .x9, .lt), 0x1a9fa7e9 }, // cset w9, lt
        .{ emit.cset(.w, .x9, .lo), 0x1a9f27e9 }, // cset w9, lo
        .{ emit.csel(.w, .x9, .x10, .x9, .eq), 0x1a890149 }, // csel w9, w10, w9, eq
        .{ emit.bCond(.ne, 8), 0x54000041 }, // b.ne .+8
        .{ emit.bCond(.vs, 12), 0x54000066 }, // b.vs .+12
        .{ emit.bCond(.hs, -16), 0x54ffff82 }, // b.hs .-16
        .{ emit.bCond(.le, 20), 0x540000ad }, // b.le .+20
        .{ emit.cbz(.w, .x9, 8), 0x34000049 }, // cbz w9, .+8
        .{ emit.cbz(.x, .x10, 8), 0xb400004a }, // cbz x10, .+8
        .{ emit.tbnz(.x9, 0, 8), 0x37000049 }, // tbnz w9, #0, .+8
        .{ emit.tbnz(.x9, 1, 12), 0x37080069 }, // tbnz w9, #1, .+12
        .{ emit.tbnz(.x12, 0, 8), 0x3700004c }, // tbnz w12, #0, .+8
        .{ emit.bl(8), 0x94000002 }, // bl .+8
        .{ emit.bl(-4096), 0x97fffc00 }, // bl .-4096
        .{ emit.br(.x10), 0xd61f0140 }, // br x10
        .{ emit.movz(.w, .x9, 0x1234, 0), 0x52824689 }, // mov w9, #0x1234
        .{ emit.movk(.w, .x9, 0x8001, 1), 0x72b00029 }, // movk w9, #0x8001, lsl #16
        .{ emit.movz(.w, .x11, 0x1f80, 1), 0x52a3f00b }, // mov w11, #0x1f800000
        .{ emit.memImm(.ldr_w, .x9, .x19, 960), 0xb943c269 }, // ldr w9, [x19, #960]
        .{ emit.memImm(.str_w, .x9, .x19, 964), 0xb903c669 }, // str w9, [x19, #964]
        .{ emit.memImm(.ldr_x, .x9, .x22, 64), 0xf94022c9 }, // ldr x9, [x22, #64]
        .{ emit.memImm(.str_x, .x9, .x22, 72), 0xf90026c9 }, // str x9, [x22, #72]
        .{ emit.memImm(.ldr_x, .x9, .x9, 0), 0xf9400129 }, // ldr x9, [x9]
        .{ emit.memImm(.ldr_w, .x11, .x10, 8), 0xb940094b }, // ldr w11, [x10, #8]
        .{ emit.memImm(.strb, .x9, .x19, 1100), 0x39113269 }, // strb w9, [x19, #1100]
        .{ emit.memImm(.strb, .zr, .x19, 1101), 0x3911367f }, // strb wzr, [x19, #1101]
        .{ emit.memImm(.str_w, .zr, .x19, 1104), 0xb904527f }, // str wzr, [x19, #1104]
        .{ emit.memImm(.str_w, .x27, .x19, 1104), 0xb904527b }, // str w27, [x19, #1104]
        .{ emit.memImm(.ldr_w, .x28, .x19, 1104), 0xb944527c }, // ldr w28, [x19, #1104]
        .{ emit.memReg(.ldr_w, .x9, .x20, .x10, false), 0xb86a4a89 }, // ldr w9, [x20, w10, uxtw]
        .{ emit.memReg(.ldrh, .x9, .x20, .x10, false), 0x786a4a89 }, // ldrh w9, [x20, w10, uxtw]
        .{ emit.memReg(.ldrsh, .x9, .x20, .x10, false), 0x78ea4a89 }, // ldrsh w9, [x20, w10, uxtw]
        .{ emit.memReg(.ldrb, .x9, .x20, .x10, false), 0x386a4a89 }, // ldrb w9, [x20, w10, uxtw]
        .{ emit.memReg(.ldrsb, .x9, .x20, .x10, false), 0x38ea4a89 }, // ldrsb w9, [x20, w10, uxtw]
        .{ emit.memReg(.str_w, .x9, .x20, .x10, false), 0xb82a4a89 }, // str w9, [x20, w10, uxtw]
        .{ emit.memReg(.strh, .x9, .x20, .x10, false), 0x782a4a89 }, // strh w9, [x20, w10, uxtw]
        .{ emit.memReg(.strb, .x9, .x20, .x10, false), 0x382a4a89 }, // strb w9, [x20, w10, uxtw]
        .{ emit.memReg(.ldr_x, .x12, .x22, .x12, true), 0xf86c5acc }, // ldr x12, [x22, w12, uxtw #3]
        .{ emit.memReg(.ldr_x, .x10, .x10, .x11, true), 0xf86b594a }, // ldr x10, [x10, w11, uxtw #3]
        .{ emit.stp(.pre_index, .fp, .lr, .sp, -96), 0xa9ba7bfd }, // stp x29, x30, [sp, #-96]!
        .{ emit.stp(.signed_offset, .x21, .x22, .sp, 32), 0xa9025bf5 }, // stp x21, x22, [sp, #32]
        .{ emit.stp(.signed_offset, .x27, .x28, .sp, 80), 0xa90573fb }, // stp x27, x28, [sp, #80]
        .{ emit.ldp(.signed_offset, .x27, .x28, .sp, 80), 0xa94573fb }, // ldp x27, x28, [sp, #80]
        .{ emit.ldp(.post_index, .fp, .lr, .sp, 96), 0xa8c67bfd }, // ldp x29, x30, [sp], #96
        .{ emit.ldp(.signed_offset, .x20, .x21, .x22, 64), 0xa94456d4 }, // ldp x20, x21, [x22, #64]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `zig build test -Dtest-filter="the encoder matches"`
Expected: compile errors, `emit` has no member `subImm` (and the rest).

- [ ] **Step 3: Add the forms to `emit.zig`**

Replace `addReg` and `movReg` with the shared data-processing helper, and add
the new forms after `cbnz`. Keep the file's comment style: one line per
form saying what it is and which register 31 means.

```zig
/// Condition codes for B.cond, CSEL and CSET.
pub const Cond = enum(u4) {
    eq,
    ne,
    hs,
    lo,
    mi,
    pl,
    vs,
    vc,
    hi,
    ls,
    ge,
    lt,
    gt,
    le,

    fn invert(c: Cond) u32 {
        return @as(u32, @backingInt(c)) ^ 1;
    }
};

/// Data processing (shifted register), LSL #0. Register 31 is the zero
/// register in every operand.
fn dpReg(width: Width, opcode: u32, rd: Reg, rn: Reg, rm: Reg) u32 {
    return width.sf() | opcode | rm.n() << 16 | rn.n() << 5 | rd.n();
}

pub fn addReg(width: Width, rd: Reg, rn: Reg, rm: Reg) u32 {
    return dpReg(width, 0x0B00_0000, rd, rn, rm);
}
pub fn addsReg(width: Width, rd: Reg, rn: Reg, rm: Reg) u32 {
    return dpReg(width, 0x2B00_0000, rd, rn, rm);
}
pub fn subReg(width: Width, rd: Reg, rn: Reg, rm: Reg) u32 {
    return dpReg(width, 0x4B00_0000, rd, rn, rm);
}
pub fn subsReg(width: Width, rd: Reg, rn: Reg, rm: Reg) u32 {
    return dpReg(width, 0x6B00_0000, rd, rn, rm);
}
pub fn andReg(width: Width, rd: Reg, rn: Reg, rm: Reg) u32 {
    return dpReg(width, 0x0A00_0000, rd, rn, rm);
}
pub fn orrReg(width: Width, rd: Reg, rn: Reg, rm: Reg) u32 {
    return dpReg(width, 0x2A00_0000, rd, rn, rm);
}
pub fn eorReg(width: Width, rd: Reg, rn: Reg, rm: Reg) u32 {
    return dpReg(width, 0x4A00_0000, rd, rn, rm);
}
/// ORN: `rn | ~rm`. With `rn` the zero register it is MVN.
pub fn ornReg(width: Width, rd: Reg, rn: Reg, rm: Reg) u32 {
    return dpReg(width, 0x2A20_0000, rd, rn, rm);
}
/// MOV (register), which is ORR rd, zr, rm. Not for SP: copy SP with
/// `addImm(.x, rd, .sp, 0)`.
pub fn movReg(width: Width, rd: Reg, rm: Reg) u32 {
    return orrReg(width, rd, .zr, rm);
}
/// CMP (register): SUBS to the zero register.
pub fn cmpReg(width: Width, rn: Reg, rm: Reg) u32 {
    return subsReg(width, .zr, rn, rm);
}
/// NEG: SUB from the zero register.
pub fn neg(width: Width, rd: Reg, rm: Reg) u32 {
    return subReg(width, rd, .zr, rm);
}

/// SUB (immediate), unshifted. Register 31 is SP here.
pub fn subImm(width: Width, rd: Reg, rn: Reg, imm12: u12) u32 {
    return width.sf() | 0x5100_0000 | @as(u32, imm12) << 10 | rn.n() << 5 | rd.n();
}
/// CMP (immediate): SUBS to the zero register. `rn` 31 is SP here.
pub fn cmpImm(width: Width, rn: Reg, imm12: u12) u32 {
    return width.sf() | 0x7100_001F | @as(u32, imm12) << 10 | rn.n() << 5;
}

/// MADD: `rd = ra + rn * rm`.
pub fn madd(width: Width, rd: Reg, rn: Reg, rm: Reg, ra: Reg) u32 {
    return width.sf() | 0x1B00_0000 | rm.n() << 16 | ra.n() << 10 | rn.n() << 5 | rd.n();
}

/// CSEL: `rd = cond ? rn : rm`.
pub fn csel(width: Width, rd: Reg, rn: Reg, rm: Reg, cond: Cond) u32 {
    return width.sf() | 0x1A80_0000 | rm.n() << 16 | @as(u32, @backingInt(cond)) << 12 | rn.n() << 5 | rd.n();
}
/// CSET: 1 when `cond` holds, else 0. CSINC rd, zr, zr, !cond.
pub fn cset(width: Width, rd: Reg, cond: Cond) u32 {
    return width.sf() | 0x1A9F_07E0 | cond.invert() << 12 | rd.n();
}

pub const Shift = enum(u32) {
    lsl = 0x1AC0_2000,
    lsr = 0x1AC0_2400,
    asr = 0x1AC0_2800,
};

/// LSLV/LSRV/ASRV: shifts `rn` by `rm` modulo the register width.
pub fn shiftReg(width: Width, shift: Shift, rd: Reg, rn: Reg, rm: Reg) u32 {
    return width.sf() | @backingInt(shift) | rm.n() << 16 | rn.n() << 5 | rd.n();
}

/// UBFM/SBFM on `w` registers. Register 31 is the zero register.
fn bitfield(signed: bool, rd: Reg, rn: Reg, immr: u5, imms: u5) u32 {
    const opcode: u32 = if (signed) 0x1300_0000 else 0x5300_0000;
    return opcode | @as(u32, immr) << 16 | @as(u32, imms) << 10 | rn.n() << 5 | rd.n();
}

/// An immediate shift of a `w` register. `amount` 0 is a move.
pub fn shiftImm(shift: Shift, rd: Reg, rn: Reg, amount: u5) u32 {
    return switch (shift) {
        .lsl => bitfield(false, rd, rn, 0 -% amount, 31 - amount),
        .lsr => bitfield(false, rd, rn, amount, 31),
        .asr => bitfield(true, rd, rn, amount, 31),
    };
}

/// UBFX on `w` registers: `width` bits of `rn` from `lsb`, zero-extended.
pub fn ubfx(rd: Reg, rn: Reg, lsb: u5, width: u6) u32 {
    return bitfield(false, rd, rn, lsb, @intCast(@as(u32, lsb) + width - 1));
}

/// BL. `offset` is in bytes from this instruction: a multiple of 4 within
/// ±128 MB.
pub fn bl(offset: i28) u32 {
    const imm26: u26 = @bitCast(@as(i26, @intCast(@divExact(offset, 4))));
    return 0x9400_0000 | @as(u32, imm26);
}

pub fn br(rn: Reg) u32 {
    return 0xD61F_0000 | rn.n() << 5;
}

/// B.cond. `offset` is in bytes from this instruction: within ±1 MB.
pub fn bCond(cond: Cond, offset: i21) u32 {
    const imm19: u19 = @bitCast(@as(i19, @intCast(@divExact(offset, 4))));
    return 0x5400_0000 | @as(u32, imm19) << 5 | @backingInt(cond);
}

/// CBZ. `offset` is in bytes from this instruction: within ±1 MB.
pub fn cbz(width: Width, rt: Reg, offset: i21) u32 {
    const imm19: u19 = @bitCast(@as(i19, @intCast(@divExact(offset, 4))));
    return width.sf() | 0x3400_0000 | @as(u32, imm19) << 5 | rt.n();
}

/// TBNZ on bit `bit` (below 32) of `rt`. `offset` is in bytes from this
/// instruction: within ±32 KB.
pub fn tbnz(rt: Reg, bit: u5, offset: i16) u32 {
    const imm14: u14 = @bitCast(@as(i14, @intCast(@divExact(offset, 4))));
    return 0x3700_0000 | @as(u32, bit) << 19 | @as(u32, imm14) << 5 | rt.n();
}

/// LDR/STR (unsigned offset). The access size is the top two bits.
pub const MemImm = enum(u32) {
    strb = 0x3900_0000,
    ldrb = 0x3940_0000,
    str_w = 0xB900_0000,
    ldr_w = 0xB940_0000,
    str_x = 0xF900_0000,
    ldr_x = 0xF940_0000,
};

/// `offset` is in bytes: a multiple of the access size, below 4096 of
/// them. Register 31 is SP as the base and the zero register as `rt`.
pub fn memImm(op: MemImm, rt: Reg, rn: Reg, offset: u32) u32 {
    const scale: u5 = @intCast(@backingInt(op) >> 30);
    const imm12: u12 = @intCast(@divExact(offset, @as(u32, 1) << scale));
    return @backingInt(op) | @as(u32, imm12) << 10 | rn.n() << 5 | rt.n();
}

/// LDR/STR (register offset), with the size and sign-extension bits.
pub const MemReg = enum(u32) {
    strb = 0x0000_0000,
    ldrb = 0x0040_0000,
    ldrsb = 0x00C0_0000,
    strh = 0x4000_0000,
    ldrh = 0x4040_0000,
    ldrsh = 0x40C0_0000,
    str_w = 0x8000_0000,
    ldr_w = 0x8040_0000,
    ldr_x = 0xC040_0000,
};

/// `[rn, wm, uxtw]`: a `w` index, zero-extended, shifted by the access size
/// when `scaled`. Register 31 as `rt` is the zero register.
pub fn memReg(op: MemReg, rt: Reg, rn: Reg, rm: Reg, scaled: bool) u32 {
    return 0x3820_4800 | @backingInt(op) | rm.n() << 16 |
        @as(u32, @intFromBool(scaled)) << 12 | rn.n() << 5 | rt.n();
}
```

- [ ] **Step 4: Run the encoder test**

Run: `zig build test -Dtest-filter="the encoder matches"`
Expected: PASS. A failing case prints its index and both words; fix the
form, never the expected word.

- [ ] **Step 5: Write the failing emitter tests**

Add to `jit_test.zig`, after the encoder test:

```zig
test "the emitter lays cold after hot and resolves branches across both" {
    const em = try alloc.create(jit.emitter.Emitter);
    defer alloc.destroy(em);
    em.reset();
    const cold = em.label();
    const back = em.label();
    em.branch(.{ .cond = .ne }, .{ .label = cold }); // word 0
    em.bind(back);
    em.put(emit.ret()); // word 1
    em.section = .cold;
    em.bind(cold);
    em.put(emit.movz(.w, .x0, 1, 0)); // word 2
    em.branch(.b, .{ .label = back }); // word 3
    em.branch(.bl, .{ .address = 0x1040 }); // word 4, at 0x1010
    em.section = .hot;
    try std.testing.expectEqual(@as(usize, 0x1008), em.addressOf(cold, 0x1000));
    const code = em.finish(0x1000);
    try std.testing.expectEqualSlices(u32, &.{
        emit.bCond(.ne, 8),
        emit.ret(),
        emit.movz(.w, .x0, 1, 0),
        emit.b(-8),
        emit.bl(0x30),
    }, code);
}

test "a 32-bit immediate takes a second word only for its high half" {
    const em = try alloc.create(jit.emitter.Emitter);
    defer alloc.destroy(em);
    em.reset();
    em.movImm32(.x9, 0x1234);
    try expectEqual(@as(usize, 1), em.len());
    em.movImm32(.x9, 0x8001_1234);
    try expectEqual(@as(usize, 3), em.len());
}
```

`alloc` is declared further down the file today; move its declaration
(`const alloc = std.testing.allocator;`) up beside `expectEqual`.

- [ ] **Step 6: Run them to verify they fail**

Run: `zig build test -Dtest-filter="emitter"`
Expected: compile error, `jit` has no member `emitter`.

- [ ] **Step 7: Write `arm64/emitter.zig`**

```zig
//! A block's code while it is built: a hot section, the straight path
//! through the block, and a cold one (slow paths and the stop tail), laid
//! out hot first so the path that runs is contiguous. A branch names a
//! label or an absolute address; `finish` encodes it once both sections'
//! sizes are known.

const std = @import("std");
const e = @import("emit.zig");

/// Words per section. A block of `block.max_len + 1` ops needs at most
/// about 50 hot and 70 cold words an op, so the worst block's two sections
/// fit together in `hot`, which is where `finish` lays them out.
pub const max_words = 8192;
const max_labels = 1024;
const max_fixups = 1024;

pub const Section = enum(u1) { hot, cold };
pub const Label = u16;
pub const Target = union(enum) { label: Label, address: usize };

/// A branch's form. `finish` encodes it once its offset is known.
pub const Branch = union(enum) {
    b,
    bl,
    cond: e.Cond,
    cbz: struct { e.Width, e.Reg },
    cbnz: struct { e.Width, e.Reg },
    tbnz: struct { e.Reg, u5 },

    fn encode(br: Branch, offset: i64) u32 {
        return switch (br) {
            .b => e.b(@intCast(offset)),
            .bl => e.bl(@intCast(offset)),
            .cond => |c| e.bCond(c, @intCast(offset)),
            .cbz => |r| e.cbz(r[0], r[1], @intCast(offset)),
            .cbnz => |r| e.cbnz(r[0], r[1], @intCast(offset)),
            .tbnz => |t| e.tbnz(t[0], t[1], @intCast(offset)),
        };
    }
};

const Pos = struct { section: Section, at: u32 };
const Fixup = struct { from: Pos, kind: Branch, to: Target };

pub const Emitter = struct {
    hot: [max_words]u32 = undefined,
    cold: [max_words]u32 = undefined,
    lens: [2]u32 = .{ 0, 0 },
    /// Where `put` writes.
    section: Section = .hot,
    labels: [max_labels]?Pos = undefined,
    label_count: u16 = 0,
    fixups: [max_fixups]Fixup = undefined,
    fixup_count: u32 = 0,

    /// Ready for the next block. Leaves the arrays as they are: only the
    /// counts say what is live.
    pub fn reset(em: *Emitter) void {
        em.lens = .{ 0, 0 };
        em.section = .hot;
        em.label_count = 0;
        em.fixup_count = 0;
    }

    pub fn put(em: *Emitter, word: u32) void {
        const s = @backingInt(em.section);
        const words = if (em.section == .hot) &em.hot else &em.cold;
        words[em.lens[s]] = word;
        em.lens[s] += 1;
    }

    fn here(em: *const Emitter) Pos {
        return .{ .section = em.section, .at = em.lens[@backingInt(em.section)] };
    }

    /// A label to bind later. Branches may name it before then.
    pub fn label(em: *Emitter) Label {
        em.labels[em.label_count] = null;
        em.label_count += 1;
        return em.label_count - 1;
    }

    /// Places `l` at the next word `put` writes.
    pub fn bind(em: *Emitter, l: Label) void {
        em.labels[l] = em.here();
    }

    /// A branch to `to`, encoded by `finish`.
    pub fn branch(em: *Emitter, kind: Branch, to: Target) void {
        em.fixups[em.fixup_count] = .{ .from = em.here(), .kind = kind, .to = to };
        em.fixup_count += 1;
        em.put(0);
    }

    /// MOVZ, and MOVK only when the high half is not zero.
    pub fn movImm32(em: *Emitter, rd: e.Reg, value: u32) void {
        em.put(e.movz(.w, rd, @truncate(value), 0));
        if (value >> 16 != 0) em.put(e.movk(.w, rd, @truncate(value >> 16), 1));
    }

    /// Always four words, whatever the value.
    pub fn movImm64(em: *Emitter, rd: e.Reg, value: u64) void {
        em.put(e.movz(.x, rd, @truncate(value), 0));
        em.put(e.movk(.x, rd, @truncate(value >> 16), 1));
        em.put(e.movk(.x, rd, @truncate(value >> 32), 2));
        em.put(e.movk(.x, rd, @truncate(value >> 48), 3));
    }

    /// A call through IP0, the intra-procedure-call scratch register.
    pub fn call(em: *Emitter, target: usize) void {
        em.movImm64(.x16, target);
        em.put(e.blr(.x16));
    }

    /// Words emitted so far, both sections.
    pub fn len(em: *const Emitter) usize {
        return em.lens[0] + em.lens[1];
    }

    /// Lays the code out for `at`, the address it will be installed at: hot,
    /// then cold. Every branch is encoded here. Valid until `reset`.
    pub fn finish(em: *Emitter, at: usize) []const u32 {
        const hot_len = em.lens[0];
        const total = hot_len + em.lens[1];
        std.debug.assert(total <= max_words);
        @memcpy(em.hot[hot_len..total], em.cold[0..em.lens[1]]);
        for (em.fixups[0..em.fixup_count]) |f| {
            const from = wordOf(f.from, hot_len);
            const to: i64 = switch (f.to) {
                .label => |l| @as(i64, wordOf(em.labels[l].?, hot_len)) * 4,
                .address => |a| @as(i64, @intCast(a)) - @as(i64, @intCast(at)),
            };
            em.hot[from] = f.kind.encode(to - @as(i64, from) * 4);
        }
        return em.hot[0..total];
    }

    /// Where `l` lands once the code is installed at `at`.
    pub fn addressOf(em: *const Emitter, l: Label, at: usize) usize {
        return at + @as(usize, wordOf(em.labels[l].?, em.lens[0])) * 4;
    }
};

fn wordOf(p: Pos, hot_len: u32) u32 {
    return p.at + if (p.section == .cold) hot_len else 0;
}
```

In `jit.zig`, beside `pub const emit`, add
`pub const emitter = @import("arm64/emitter.zig");`.

- [ ] **Step 8: Run the tests**

Run: `zig build test -Dtest-filter="emitter"` then
`zig build test -Dtest-filter="immediate takes"`
Expected: PASS.

- [ ] **Step 9: Build everything, format, commit**

```bash
zig build
zig fmt ps1-core/src/recompiler/arm64/emit.zig ps1-core/src/recompiler/arm64/emitter.zig ps1-core/src/recompiler/jit.zig ps1-core/tests/jit_test.zig
git add ps1-core/src/recompiler/arm64/emit.zig ps1-core/src/recompiler/arm64/emitter.zig ps1-core/src/recompiler/jit.zig ps1-core/tests/jit_test.zig
git commit -m "feat(jit): encoder forms for lowering and a two-section emitter"
```

`zig build` builds the wasm target too, and must not analyse any of this.

---

### Task 2: The translator's frame and compile-time accounting

The translator is rebuilt on the emitter, still emitting every op as a
call, so nothing about what a block computes changes. What changes is the
bookkeeping: Plan 4 emitted five accounting instructions per op; here the
counts are resolved at compile time, and a commit is a closed formula.

**Files:**
- Create: `ps1-core/src/recompiler/arm64/layout.zig`
- Modify (rewrite): `ps1-core/src/recompiler/arm64/translate.zig`
- Modify: `ps1-core/src/recompiler/arm64/code_buffer.zig`,
  `ps1-core/src/recompiler/jit.zig`, `ps1-core/src/recompiler/cache.zig`,
  `ps1-core/src/recompiler/run.zig`, `ps1-core/src/recompiler/block.zig`
- Test: `ps1-core/tests/jit_test.zig`, `ps1-core/tests/recompiler_test.zig`,
  `ps1-core/tests/recompiler_helpers.zig`

**Interfaces:**
- Consumes: Task 1's `Emitter` and encoder forms.
- Produces:
  - `cache.Pins` (extern): `has_code: [8]u64` (first field), `ram: [*]u8`,
    `scratchpad: [*]u8` (adjacent, in that order), `running: ?*Block`.
    `BlockCache.pins` replaces `BlockCache.has_code` and `.running`.
  - `BlockCache.create(allocator, bus: *Bus)`; `BlockCache.jit: ?*jit.Jit`
    replaces `BlockCache.code`.
  - `jit.Jit` with `buf: CodeBuffer`, `em: Emitter`, `return_stub: usize`,
    `create(allocator, bytes) error{OutOfMemory, EngineUnavailable}!*Jit`,
    `destroy(allocator)`.
  - `CodeBuffer.base`, `pin()`, `cursor() usize`; `reset()` keeps `base`.
  - `translate.compile(j: *Jit, pins: *Pins, b: *Block) error{CodeBufferFull}!void`,
    which sets `b.code`. `translate.return_stub: [8]u32`. Register
    constants `cpu_reg` (x19), `ram_reg` (x20), `scratch_reg` (x21),
    `pins_reg` (x22), `adjust_reg` (x24), `ran_reg` (x26), all `pub`.
  - `layout.pins_ram`.
  - `run.compileBlock(c, bus, pc) !*Block` (was `compileInto`, now public).
  - Test helpers: `h.jitRan(m) bool`, `h.mips.mflo(rd)`.

- [ ] **Step 1: Point the tests at the new names (they fail to compile)**

In `ps1-core/tests/recompiler_helpers.zig` add, inside `mips`:

```zig
    pub fn mflo(rd: u5) u32 {
        return r(0, 0, rd, 0x12);
    }
```

and after `Machine`:

```zig
/// The JIT emitted code past its stubs: a `.jit` machine really ran it.
pub fn jitRan(m: *const Machine) bool {
    const j = m.bus.blocks.?.jit.?;
    return j.buf.used > j.buf.base;
}
```

In `jit_test.zig`:
- `expectSameBlock` compiles through the cache, so the block's code uses the
  dut's `Pins`:

```zig
fn expectSameBlock(program: []const u32, pc: u32, fetch_cost: u32) !void {
    if (!jit.available) return error.SkipZigTest;
    var ref = try h.Machine.init(.interpreter);
    defer ref.deinit();
    var dut = try h.Machine.init(.jit);
    defer dut.deinit();
    for ([_]*h.Machine{ &ref, &dut }) |m| {
        h.poke(m.bus, pc & 0x1F_FFFF, program);
        m.start(pc);
    }
    const b = try recompiler.compileBlock(dut.bus.blocks.?, dut.bus, pc);
    try expectEqual(recompiler.cached.execute(&ref.cpu, b, fetch_cost), jit.execute(&dut.cpu, b, fetch_cost));
    try h.expectSameMachine(&ref, &dut);
}
```

- `Pair.expectSameRuns` and the fuzzer: `p.dut.bus.blocks.?.code.?.used > 0`
  becomes `h.jitRan(&p.dut)`, and the fuzzer's
  `dut.bus.blocks.?.code.?.used > 0` becomes `h.jitRan(&dut)`.
- `test "a full code buffer flushes every block and compiles on"`: replace
  the buffer and the program. Every block is calls (MFLO is never
  lowered), so the arithmetic holds through every later task:

```zig
    const c = m.bus.blocks.?;
    // One 16 KB page. A block of 64 MFLO calls is about 3 KB of code, so
    // eight of them cannot all fit.
    c.jit.?.destroy(alloc);
    c.jit = try jit.Jit.create(alloc, 16 << 10);
    h.poke(m.bus, 0x1000, &(@as([64 * 8]u32, @splat(mips.mflo(t0))) ++ .{ mips.beq(zero, zero, -1), mips.nop }));
```

  and `c.code.?.used` becomes `c.jit.?.buf.used`.

In `recompiler_test.zig`: `BlockCache.create(alloc)` becomes
`BlockCache.create(alloc, bus)`, and `bus.blocks.?.running` becomes
`bus.blocks.?.pins.running` (both lines).

- [ ] **Step 2: Run them to verify they fail**

Run: `zig build test -Dtest-filter="jit"`
Expected: compile errors naming `jitRan`'s `.jit`, `compileBlock`,
`Jit.create`, `pins`.

- [ ] **Step 3: `code_buffer.zig`: a pinned base and a cursor**

Add the field and three functions, and make `reset` keep the base:

```zig
    words: []u32,
    used: usize = 0,
    /// Words below this survive `reset`: the stubs every block leaves
    /// through.
    base: usize = 0,
```

```zig
    /// The address the next `install` copies to.
    pub fn cursor(self: *const CodeBuffer) usize {
        return @intFromPtr(self.words.ptr + self.used);
    }

    /// Keeps everything installed so far across `reset`.
    pub fn pin(self: *CodeBuffer) void {
        self.base = self.used;
    }

    /// Forgets every function installed since `pin`. Only once nothing can
    /// call one.
    pub fn reset(self: *CodeBuffer) void {
        self.used = self.base;
    }
```

- [ ] **Step 4: `layout.zig`**

```zig
//! Byte offsets the emitted code addresses: `Cpu` through x19, `Pins`
//! through x22. The checks below fail the build when one outgrows the
//! unsigned-offset form that reaches it.

const std = @import("std");
const Pins = @import("../cache.zig").Pins;

/// `ram` and `scratchpad`: the prologue loads both with one `ldp`.
pub const pins_ram = @offsetOf(Pins, "ram");

comptime {
    std.debug.assert(@offsetOf(Pins, "scratchpad") == pins_ram + 8);
    std.debug.assert(pins_ram % 8 == 0 and pins_ram <= 504);
}
```

- [ ] **Step 5: `cache.zig`: `Pins` and the `jit` field**

Add the imports and the struct, and replace `has_code`, `running` and
`code` on `BlockCache`:

```zig
const Bus = @import("../memory.zig").Bus;
const jit = @import("jit.zig");
```

```zig
/// What emitted code reads through one pinned register (x22). Extern, so
/// `arm64/layout.zig` can rely on its offsets. `.cached` uses `has_code`
/// and `running` too.
pub const Pins = extern struct {
    /// One bit per RAM page holding a live block. While it is clear, this
    /// is the whole cost a RAM write pays. First: a store's inline page test
    /// indexes it from x22 itself.
    has_code: [ram_pages / 64]u64 = @splat(0),
    /// `Bus.ram` and `Bus.scratchpad`, adjacent and in this order.
    ram: [*]u8,
    scratchpad: [*]u8,
    /// The block a block engine is executing, so a store into it can end it.
    running: ?*Block = null,
};
```

On `BlockCache`: delete `has_code` and `running`, delete `code`, and add

```zig
    pins: Pins,
    /// The JIT's code memory and compiler, owned here. Its presence is what
    /// makes the engine `.jit` (`run.engineOf`); null under `.cached`.
    jit: ?*jit.Jit = null,
```

`create` takes the bus the cache serves:

```zig
    pub fn create(allocator: std.mem.Allocator, bus: *Bus) !*BlockCache {
        ...
        self.* = .{
            .allocator = allocator,
            .ram = ram,
            .bios = bios,
            .pins = .{ .ram = &bus.ram, .scratchpad = &bus.scratchpad },
        };
        return self;
    }
```

`destroy` frees the JIT:

```zig
        if (comptime jit.available) {
            if (self.jit) |j| j.destroy(self.allocator);
        }
```

`invalidatePage` compares against `self.pins.running`; `flush` ends with

```zig
        self.pins.has_code = @splat(0);
        self.pins.running = null;
        // Every block that could call into the buffer is gone.
        if (self.jit) |j| j.buf.reset();
```

and `hasBit`/`setBit`/`clearBit` read `self.pins.has_code`. Drop the
`code_buffer` import.

- [ ] **Step 6: `jit.zig`: the `Jit` struct**

```zig
/// What the JIT keeps beside the block cache: its code memory, the emitter a
/// compile builds in, and the stub every block returns through. Heap-only:
/// the emitter alone is about 100 KB.
pub const Jit = struct {
    buf: CodeBuffer,
    em: emitter.Emitter = .{},
    return_stub: usize = 0,

    /// Fails with `EngineUnavailable` when MAP_JIT is refused.
    pub fn create(allocator: std.mem.Allocator, bytes: usize) error{ OutOfMemory, EngineUnavailable }!*Jit {
        const j = try allocator.create(Jit);
        errdefer allocator.destroy(j);
        j.* = .{ .buf = CodeBuffer.init(bytes) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.EngineUnavailable,
        } };
        // A fresh buffer has room for the stubs.
        j.return_stub = @intFromPtr(j.buf.install(&translate.return_stub) catch unreachable);
        j.buf.pin();
        return j;
    }

    pub fn destroy(j: *Jit, allocator: std.mem.Allocator) void {
        j.buf.deinit();
        allocator.destroy(j);
    }
};
```

Add `const std = @import("std");` and update the file comment's first
sentence to "a block emitted as host code; it computes exactly what
`.cached` computes and shares its goldens (`trace-block/`)."

- [ ] **Step 7: Rewrite `translate.zig`**

```zig
//! A block as arm64 code: each op a call to `cached.runOp` with the block's
//! own `Op`, so `.jit` executes exactly what `.cached` executes. The cycle
//! and step accounting `cached.execute` does per instruction is resolved at
//! compile time: `pending` counts ops w26 does not include yet, and a
//! commit is a closed formula over w23-w26 (`commitMid`).
//!
//! Registers for the whole block, callee-saved so a call keeps them:
//!   x19 `*Cpu`; x20 RAM; x21 the scratchpad; x22 the cache's `Pins`;
//!   w23 one instruction's cycles, 1 + the fetch cost;
//!   w24, w25 the cycle adjustment and the commit base (`commitMid`);
//!   w26 the instructions this call has run, less `Ctx.pending`;
//!   x27, x28 the values of loads in flight.
//! Scratch within one op: w9-w13, and x16 for a call's target.

const std = @import("std");
const block = @import("../block.zig");
const cached = @import("../cached.zig");
const Pins = @import("../cache.zig").Pins;
const jit = @import("../jit.zig");
const Cpu = @import("../../cpu/cpu.zig").Cpu;
const e = @import("emit.zig");
const emitter = @import("emitter.zig");
const Emitter = emitter.Emitter;
const layout = @import("layout.zig");

pub const cpu_reg: e.Reg = .x19;
pub const ram_reg: e.Reg = .x20;
pub const scratch_reg: e.Reg = .x21;
pub const pins_reg: e.Reg = .x22;
const cost_reg: e.Reg = .x23;
pub const adjust_reg: e.Reg = .x24;
const base_reg: e.Reg = .x25;
pub const ran_reg: e.Reg = .x26;
const frame_bytes = 96;

/// Every block leaves through here: returns the instructions the call ran
/// and unwinds the frame `prologue` built.
pub const return_stub = [_]u32{
    e.movReg(.w, .x0, ran_reg),
    e.ldp(.signed_offset, .x27, .x28, .sp, 80),
    e.ldp(.signed_offset, .x25, .x26, .sp, 64),
    e.ldp(.signed_offset, .x23, .x24, .sp, 48),
    e.ldp(.signed_offset, .x21, .x22, .sp, 32),
    e.ldp(.signed_offset, .x19, .x20, .sp, 16),
    e.ldp(.post_index, .fp, .lr, .sp, frame_bytes),
    e.ret(),
};

pub const Ctx = struct {
    em: *Emitter,
    b: *const block.Block,
    return_stub: usize,
    /// The op being emitted.
    i: usize = 0,
    /// Ops emitted inline whose count w26 does not include yet.
    pending: u32 = 0,
    /// The stop tail: a call's op raised an exception or set `block_exit`.
    stop: emitter.Label,

    pub fn op(ctx: *const Ctx) *const block.Op {
        return &ctx.b.ops[ctx.i];
    }
};

/// Emits `b`, installs it in `j`'s buffer and sets `b.code`.
pub fn compile(j: *jit.Jit, pins: *Pins, b: *block.Block) error{CodeBufferFull}!void {
    std.debug.assert(b.ops.len <= block.max_len + 1);
    const em = &j.em;
    em.reset();
    var ctx: Ctx = .{ .em = em, .b = b, .return_stub = j.return_stub, .stop = em.label() };
    prologue(&ctx, pins);
    while (ctx.i < b.ops.len) : (ctx.i += 1) emitCall(&ctx);
    end(&ctx);
    const entry: block.JitEntry = @ptrCast(try j.buf.install(em.finish(j.buf.cursor())));
    b.code = entry;
}

fn prologue(ctx: *Ctx, pins: *Pins) void {
    const em = ctx.em;
    em.put(e.stp(.pre_index, .fp, .lr, .sp, -frame_bytes));
    em.put(e.addImm(.x, .fp, .sp, 0));
    em.put(e.stp(.signed_offset, .x19, .x20, .sp, 16));
    em.put(e.stp(.signed_offset, .x21, .x22, .sp, 32));
    em.put(e.stp(.signed_offset, .x23, .x24, .sp, 48));
    em.put(e.stp(.signed_offset, .x25, .x26, .sp, 64));
    em.put(e.stp(.signed_offset, .x27, .x28, .sp, 80));
    em.put(e.movReg(.x, cpu_reg, .x0));
    em.put(e.addImm(.w, cost_reg, .x1, 1));
    em.movImm64(pins_reg, @intFromPtr(pins));
    em.put(e.ldp(.signed_offset, ram_reg, scratch_reg, pins_reg, layout.pins_ram));
    em.put(e.movz(.w, ran_reg, 0, 0));
    // Everything above holds for the whole call, everything below for this
    // block.
    em.put(e.movz(.w, adjust_reg, 0, 0));
    em.put(e.movReg(.w, base_reg, ran_reg));
}

/// The op as a call to `cached.runOp`, as `cached.execute` runs it.
fn emitCall(ctx: *Ctx) void {
    countThrough(ctx);
    if (ctx.op().memory) commitMid(ctx.em);
    callRunOp(ctx);
}

fn callRunOp(ctx: *Ctx) void {
    const em = ctx.em;
    em.put(e.movReg(.x, .x0, cpu_reg));
    em.movImm64(.x1, @intFromPtr(ctx.op()));
    em.call(@intFromPtr(&opShim));
    em.branch(.{ .cbnz = .{ .w, .x0 } }, .{ .label = ctx.stop });
}

/// Brings w26 up to date and counts the op about to run: a stop after it
/// returns it as run, as `cached.execute` counts it.
fn countThrough(ctx: *Ctx) void {
    ctx.em.put(e.addImm(.w, ran_reg, ran_reg, @intCast(ctx.pending + 1)));
    ctx.pending = 0;
}

/// Before a load or store's call, which may sync the devices: hands the
/// scheduler what `cached.execute`'s commit hands it, the cycles of every op
/// since the last commit with this one's fetch included, and the steps of
/// those before it. w26 already counts this op, so with `n = w26 - w25`:
///   cycles = n * w23 + w24, steps = n - 1.
/// The base then moves to just before this op and w24 to -w23: the next
/// commit counts from the op after this one, whose fetch was not paid here.
fn commitMid(em: *Emitter) void {
    em.put(e.subReg(.w, .x9, ran_reg, base_reg));
    em.put(e.madd(.w, .x1, .x9, cost_reg, adjust_reg));
    em.put(e.subImm(.w, .x2, .x9, 1));
    em.put(e.subImm(.w, base_reg, ran_reg, 1));
    em.put(e.neg(.w, adjust_reg, cost_reg));
    em.put(e.movReg(.x, .x0, cpu_reg));
    em.call(@intFromPtr(&commitShim));
}

/// At the block's end: `n * w23 + w24` cycles over `n` steps, every op
/// since the last commit.
fn commitFinal(em: *Emitter) void {
    em.put(e.subReg(.w, .x2, ran_reg, base_reg));
    em.put(e.madd(.w, .x1, .x2, cost_reg, adjust_reg));
    em.put(e.movReg(.x, .x0, cpu_reg));
    em.call(@intFromPtr(&commitShim));
}

fn end(ctx: *Ctx) void {
    const em = ctx.em;
    if (ctx.pending > 0) em.put(e.addImm(.w, ran_reg, ran_reg, @intCast(ctx.pending)));
    commitFinal(em);
    em.branch(.b, .{ .address = ctx.return_stub });
    // The stop tail: memory is exactly as the stopping op's call left it.
    em.section = .cold;
    em.bind(ctx.stop);
    commitFinal(em);
    em.branch(.b, .{ .address = ctx.return_stub });
    em.section = .hot;
}

// What the emitted code calls. Thin on purpose: the semantics are
// `cached.zig`'s. `u32` rather than `bool`, so `cbnz w0` reads a defined
// register whatever the ABI leaves above the low byte.

fn opShim(cpu: *Cpu, op: *const block.Op) callconv(.c) u32 {
    return @intFromBool(cached.runOp(cpu, op));
}

fn commitShim(cpu: *Cpu, cycles: u32, steps: u32) callconv(.c) void {
    cached.commit(cpu, cycles, steps);
}
```

Check the formulas against `cached.execute` by hand before going on: a
block of three plain ops, a memory op at index 1, and a stop at index 2.
`commitMid` at op 1 hands `2 * c` cycles and 1 step; the final commit hands
`(3 - 1) * c - c = c` cycles and 2 steps. `cached.execute` hands `2c, 1`
then `c, 2`.

- [ ] **Step 8: `run.zig` and `block.zig`**

`run.zig`:

```zig
        .cached => try BlockCache.create(allocator, bus),
        .jit => if (comptime jit.available) try createJitCache(allocator, bus) else return error.EngineUnavailable,
```

```zig
fn createJitCache(allocator: std.mem.Allocator, bus: *Bus) error{ OutOfMemory, EngineUnavailable }!*BlockCache {
    const c = try BlockCache.create(allocator, bus);
    errdefer c.destroy();
    c.jit = try jit.Jit.create(allocator, jit.buffer_bytes);
    return c;
}

pub fn engineOf(bus: *const Bus) Engine {
    const c = bus.blocks orelse return .interpreter;
    return if (c.jit != null) .jit else .cached;
}
```

`c.running = b` / `c.running = null` become `c.pins.running`. Rename
`compileInto` to a public `compileBlock`, update its caller, and compile
through the `Jit`:

```zig
/// Compiles the block at `pc` into `c`, as host code under `.jit`. A full
/// code buffer flushes every block first: between blocks nothing is
/// running, and there is no eviction policy (spec: Full flushes).
pub fn compileBlock(c: *BlockCache, bus: *const Bus, pc: u32) !*block.Block {
    const b = try block.compile(c.allocator, bus, pc);
    errdefer block.destroy(c.allocator, b);
    if (comptime jit.available) {
        if (c.jit) |j| jit.translate.compile(j, &c.pins, b) catch {
            c.flush();
            try jit.translate.compile(j, &c.pins, b);
        };
    }
    try c.insert(pc & 0x1FFF_FFFF, b);
    return b;
}
```

`block.zig`: `Block.code`'s comment says "the cache's code buffer"; change
it to "the `Jit`'s code buffer".

- [ ] **Step 9: Retune the fuzzer for depth**

The Plan 4 generator ends programs early: one instruction in twelve is
SYSCALL, BREAK or NOP with SYSCALL/BREAK two in three, and every load and
store offset has a random alignment. Make faults rare enough that programs
run deep, and measure the depth so a later change cannot quietly undo it.
In `fuzz.Gen`:

```zig
        /// An offset into the data window, aligned to `width` seven times
        /// in eight: a misaligned access faults and ends the program, and
        /// the fuzzer needs programs that run deep, with a few that fault.
        fn dataOffset(g: Gen, width: u16) u16 {
            const off: u16 = @bitCast(g.rng.intRangeLessThan(i16, -0x200, 0x200));
            return if (g.rng.uintLessThan(u32, 8) == 0) off else off & ~(width - 1);
        }
```

```zig
fn accessWidth(op: u32) u16 {
    return switch (op) {
        0x21, 0x25, 0x29 => 2,
        0x23, 0x2B => 4,
        else => 1,
    };
}
```

(`accessWidth` sits inside `fuzz`, beside `isLoad`.) In `instr`, cases 6, 7
and `else` become:

```zig
                6 => blk: {
                    const op = g.pick(u32, &.{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26 });
                    break :blk mips.i(op, h.gp, g.dst(), g.dataOffset(accessWidth(op)));
                },
                7 => blk: {
                    const op = g.pick(u32, &.{ 0x28, 0x29, 0x2A, 0x2B, 0x2E });
                    break :blk mips.i(op, h.gp, g.src(), g.dataOffset(accessWidth(op)));
                },
                else => if (g.rng.uintLessThan(u32, 16) == 0) g.pick(u32, &.{ mips.syscall, mips.brk }) else mips.nop,
```

In the fuzz test, measure how far each program gets: declare
`var reached_total: u64 = 0;` beside the other flags, `var reached: u64 =
0;` at the top of each program's loop, and after each run's comparison:

```zig
            const phys = ref.cpu.pipeline.pc & 0x1FFF_FFFF;
            if (phys >= fuzz.base and phys < fuzz.base + 4 * (fuzz.len + fuzz.tail))
                reached = @max(reached, @min((phys - fuzz.base) / 4, fuzz.len));
```

then `reached_total += reached;` after the runs, and after the loop:

```zig
    // Programs run deep: on average past their midpoint before a fault or
    // the end. Plan 4's generator stopped most of them in the first few
    // blocks.
    try expect(reached_total / fuzz.programs >= fuzz.len / 2);
```

If the mean is below 24, lower the fault rates further; do not lower the
bar. Print the mean once while tuning, then remove the print.

- [ ] **Step 10: Run the tests**

Run: `zig build test -Dtest-filter="jit"` then
`zig build test -Dtest-filter="recompiler"` then `zig build test`.
Expected: all PASS (49/49 steps). The sabotage check from Plan 4 still
applies: temporarily change `countThrough`'s `+ 1` to `+ 2` and confirm the
fuzzer fails on a cycles or step mismatch, then revert it.

- [ ] **Step 11: The gates**

```bash
zig build
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- verify --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- savestate --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- lockstep --engine=jit
```

Expected: the interpreter `verify` OK on all nine (the cache's fields
moved; nothing the interpreter runs did). `.jit` `verify`, `savestate` OK
on all nine against `trace-block/`; lockstep 0 mismatches.

- [ ] **Step 12: Bench**

```bash
zig build -Doptimize=ReleaseFast
CUE="games/Croc - Legend of the Gobbos/Croc - Legend of the Gobbos.cue"
for i in 1 2 3 4 5; do
  ./zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin "$CUE" 3000 --engine=cached
  ./zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin "$CUE" 3000 --engine=jit
done
```

Let the machine settle first (not straight after `trace-golden`). Record
the best of five for each engine in the task report; Task 10 collects every
task's numbers. Plan 4 measured `.jit` 11.4% slower than `.cached`. No
target here.

- [ ] **Step 13: Format and commit**

```bash
zig fmt ps1-core/src/recompiler ps1-core/tests/jit_test.zig ps1-core/tests/recompiler_test.zig ps1-core/tests/recompiler_helpers.zig
git add ps1-core/src/recompiler ps1-core/tests/jit_test.zig ps1-core/tests/recompiler_test.zig ps1-core/tests/recompiler_helpers.zig
git commit -m "refactor(jit): rebuild the translator on the emitter with compile-time accounting"
```

---

### Task 3: The load-delay model and inline ALU ops

The first lowering. ALU ops are the most common family, and they need the
whole model at once: an inline op must leave the pipeline and the load delay
as `runOp` would, including around a load issued by a call just before it.

**Files:**
- Modify: `ps1-core/src/recompiler/arm64/layout.zig`
- Create: `ps1-core/src/recompiler/arm64/model.zig`,
  `ps1-core/src/recompiler/arm64/lower_alu.zig`
- Modify (rewrite): `ps1-core/src/recompiler/arm64/translate.zig`
- Modify: `ps1-core/src/recompiler/jit.zig`, `ps1-core/src/recompiler/block.zig`,
  `ps1-core/src/recompiler/cache.zig`, `ps1-core/src/recompiler/run.zig`,
  `ps1-core/src/memory.zig`
- Test: `ps1-core/tests/jit_test.zig`, `ps1-core/tests/recompiler_helpers.zig`

**Interfaces:**
- Consumes: Task 2's `translate`, `Jit`, `Pins`, `compileBlock`.
- Produces:
  - `layout.reg(r)`, `layout.pc`, `next_pc`, `current_pc`,
    `is_delay_slot`, `next_is_delay_slot`, `load_r`, `load_v`, `delay_r`,
    `delay_v`.
  - `model.Load`, `model.loadReg(i)`, `model.Model` with `entry`,
    `advance`, `afterCall`, `retire`, `sync(em, branch_target: ?e.Reg)`.
  - `translate.Options{ lower: jit.Lowering }`; `translate.compile(j, pins,
    b, opts)`, which also sets `b.code_words` and `b.calls`;
    `translate.Slow{ entry, back }`; `Ctx` methods `pc()`, `isDelaySlot()`,
    `src(r, into) e.Reg`, `dst(r, from)`, `beginInline(issues, writes)
    Model`, `endInline()`, `slowPath(before) Slow`. `Ctx.opts`,
    `Ctx.model`, `Ctx.calls`.
  - `jit.Lowering{ alu: bool = true }` with `none`; `Jit.lower`.
  - `block.isBranch` and `block.issuesLoad(raw) ?u5` public;
    `Block.code_words: u32`, `Block.calls: u32` (the ops emitted as calls:
    what a test checks to know an op was lowered, since inline code is not
    always shorter than a call).
  - `BlockCache.discard(b)`, `BlockCache.segment_recompiles`.
  - Test helpers `mips.sll`, `mips.jal`, `mips.jalr`.

- [ ] **Step 1: Write the failing tests**

In `recompiler_helpers.zig`, inside `mips`:

```zig
    pub fn sll(rd: u5, rt: u5, sa: u5) u32 {
        return r(0, rt, rd, 0x00) | @as(u32, sa) << 6;
    }
    pub fn jal(target: u32) u32 {
        return 0x03 << 26 | ((target >> 2) & 0x03FF_FFFF);
    }
    pub fn jalr(rd: u5, rs: u5) u32 {
        return r(rs, 0, rd, 0x09);
    }
```

In `jit_test.zig`, after the existing `.jit equals .cached` tests:

```zig
test ".jit equals .cached: every inline ALU form" {
    try expectSameRuns(&.{
        mips.lui(t0, 0x8000), // t0 = 0x80000000
        mips.ori(t1, zero, 0xFFFF), // t1 = 0xFFFF
        mips.addiu(t2, zero, 0xFFFF), // t2 = -1
        mips.sll(t3, t2, 4),
        mips.r(0, t0, t4, 0x02) | 31 << 6, // SRL
        mips.r(0, t0, t5, 0x03) | 31 << 6, // SRA
        mips.r(t1, t2, t6, 0x04), // SLLV by 0xFFFF: only the low five bits count
        mips.r(t1, t0, t7, 0x06), // SRLV
        mips.r(t1, t0, t3, 0x07), // SRAV
        mips.addu(t4, t0, t2),
        mips.r(t0, t1, t5, 0x23), // SUBU
        mips.r(t0, t1, t6, 0x24), // AND
        mips.r(t0, t1, t7, 0x25), // OR
        mips.r(t0, t1, t3, 0x26), // XOR
        mips.r(t0, t1, t4, 0x27), // NOR
        mips.r(t0, t1, t5, 0x2A), // SLT: signed, 0x80000000 is the smaller
        mips.r(t0, t1, t6, 0x2B), // SLTU
        mips.add(t7, t1, t1), // ADD, no overflow
        mips.r(t1, t2, t3, 0x22), // SUB, no overflow
        mips.i(0x08, t1, t4, 0x7FFF), // ADDI
        mips.i(0x0A, t0, t5, 0x0001), // SLTI
        mips.i(0x0B, t2, t6, 0xFFFF), // SLTIU against 0xFFFFFFFF
        mips.i(0x0C, t2, t7, 0x8001), // ANDI: zero-extended
        mips.i(0x0D, t0, t3, 0x8001), // ORI
        mips.i(0x0E, t2, t4, 0x8001), // XORI
        mips.addu(zero, t0, t1), // a write to $zero is dropped
        mips.sll(zero, t0, 1), // and so is a shift into it
        mips.beq(zero, zero, -1),
        mips.nop,
    }, 0x8000_1000, 4);
}

test ".jit equals .cached: a load lands around inline ops, unless one writes its target" {
    try expectSameRuns(&.{
        mips.lui(t2, 0x8000),
        mips.ori(t2, t2, 0x2000),
        mips.addiu(t0, zero, 5),
        mips.sw(t0, t2, 0),
        mips.addiu(t0, zero, 1),
        mips.lw(t0, t2, 0),
        mips.addu(t1, t0, zero), // the old t0, 1
        mips.addu(t3, t0, zero), // the loaded t0, 5
        mips.lw(t0, t2, 0),
        mips.addiu(t0, zero, 9), // cancels the load: t0 stays 9
        mips.addu(t4, t0, zero),
        mips.lw(zero, t2, 0), // a load to $zero still passes through load_v
        mips.addu(t5, t4, t4),
        mips.lw(t6, t2, 0),
        mips.lw(t6, t2, 4), // back to back into one register
        mips.addu(t7, t6, zero),
        mips.beq(zero, zero, -1),
        mips.nop,
    }, 0x8000_1000, 4);
}

test ".jit equals .cached: blocks entered with a load in flight" {
    try expectSameRuns(&.{
        mips.lui(t2, 0x8000),
        mips.ori(t2, t2, 0x2000),
        mips.addiu(t0, zero, 7),
        mips.sw(t0, t2, 0),
        mips.addiu(t1, zero, 3),
        mips.addiu(t1, t1, 0xFFFF), // 0x1014 loop
        mips.bne(t1, zero, -2), // -> loop
        mips.lw(t3, t2, 0), // delay slot: in flight as the next block starts
        mips.addu(t4, t3, zero),
        mips.beq(zero, zero, 1),
        mips.lw(zero, t2, 0), // delay slot: load_r clear, load_v set at the next start
        mips.addu(t5, t4, zero),
        mips.beq(zero, zero, -1),
        mips.nop,
    }, 0x8000_1000, 16);
}

test ".jit equals .cached: an overflow in a delay slot after inline ops" {
    try expectSameRuns(&.{
        mips.lui(t1, 0x7FFF),
        mips.ori(t1, t1, 0xFFFF),
        mips.addiu(t0, zero, 1),
        mips.beq(zero, zero, 2),
        mips.add(t2, t1, t0), // delay slot: overflows, EPC the branch, BD set
        mips.nop,
        mips.nop,
        mips.beq(zero, zero, -1),
        mips.nop,
    }, 0x8000_1000, 4);
}

test ".jit equals .cached: one RAM block entered through KSEG0, then KSEG1" {
    if (!jit.available) return error.SkipZigTest;
    var p = try Pair.init(&.{ mips.addiu(t0, t0, 1), mips.beq(zero, zero, -2), mips.nop }, 0x8000_1000);
    defer p.deinit();
    try p.expectSameRuns(3);
    for ([_]*h.Machine{ &p.ref, &p.dut }) |m| m.start(0xA000_1000);
    try p.expectSameRuns(3);
    // Inline code bakes its PCs in, so the KSEG1 entry compiled again.
    try expectEqual(@as(u32, 1), p.dut.bus.blocks.?.segment_recompiles);
}

test "with PGXP on nothing is lowered, and turning it on flushes" {
    if (!jit.available) return error.SkipZigTest;
    var m = try h.Machine.init(.jit);
    defer m.deinit();
    const c = m.bus.blocks.?;
    h.poke(m.bus, 0x1000, &(@as([8]u32, @splat(mips.addu(t0, t0, t1))) ++ .{ mips.beq(zero, zero, -1), mips.nop }));
    m.start(0x8000_1000);
    _ = m.cpu.run();
    const lowered = c.lookup(0x1000).?.calls;
    m.bus.setPgxp(true);
    try expectEqual(@as(?*block.Block, null), c.lookup(0x1000));
    m.start(0x8000_1000);
    _ = m.cpu.run();
    const b = c.lookup(0x1000).?;
    try expectEqual(@as(u32, @intCast(b.ops.len)), b.calls); // all calls
    try expect(lowered < b.calls);
}
```

`Pair.init`, `Pair.expectSameRuns` and `expectSameRuns` are the Plan 4
helpers in this file.

- [ ] **Step 2: Run them to verify they fail**

Run: `zig build test -Dtest-filter="jit"`
Expected: compile errors (`segment_recompiles`, `calls`), and once those
exist the PGXP test fails: nothing is lowered yet, so both blocks are all
calls.

- [ ] **Step 3: `layout.zig`: the `Cpu` offsets**

```zig
const Cpu = @import("../../cpu/cpu.zig").Cpu;
const Pipeline = @FieldType(Cpu, "pipeline");
const LoadDelay = @FieldType(Cpu, "load_delay");

pub fn reg(r: u5) u32 {
    return @offsetOf(Cpu, "regs") + @as(u32, r) * 4;
}
pub const pc = @offsetOf(Cpu, "pipeline") + @offsetOf(Pipeline, "pc");
pub const next_pc = @offsetOf(Cpu, "pipeline") + @offsetOf(Pipeline, "next_pc");
pub const current_pc = @offsetOf(Cpu, "pipeline") + @offsetOf(Pipeline, "current_pc");
pub const is_delay_slot = @offsetOf(Cpu, "pipeline") + @offsetOf(Pipeline, "is_delay_slot");
pub const next_is_delay_slot = @offsetOf(Cpu, "pipeline") + @offsetOf(Pipeline, "next_is_delay_slot");
pub const load_r = @offsetOf(Cpu, "load_delay") + @offsetOf(LoadDelay, "load_r");
pub const load_v = @offsetOf(Cpu, "load_delay") + @offsetOf(LoadDelay, "load_v");
pub const delay_r = @offsetOf(Cpu, "load_delay") + @offsetOf(LoadDelay, "delay_r");
pub const delay_v = @offsetOf(Cpu, "load_delay") + @offsetOf(LoadDelay, "delay_v");
```

and in the `comptime` block:

```zig
    // `ldr`/`str` of a word: below 16 KB. `strb`: below 4 KB.
    for ([_]u32{ reg(31), pc, next_pc, current_pc, load_v, delay_v }) |o| std.debug.assert(o < 16384 and o % 4 == 0);
    for ([_]u32{ is_delay_slot, next_is_delay_slot, load_r, delay_r }) |o| std.debug.assert(o < 4096);
    // One byte each: `strb` writes them whole.
    std.debug.assert(@sizeOf(@FieldType(LoadDelay, "load_r")) == 1 and @sizeOf(@FieldType(Pipeline, "is_delay_slot")) == 1);
```

- [ ] **Step 4: `block.zig`**

Make `isBranch` public, add `issuesLoad`, and add `code_words` to `Block`
after `code`:

```zig
/// The register a load leaves in the load delay (`load_r`), for an op that
/// is one: LB, LH, LWL, LW, LBU, LHU, LWR.
pub fn issuesLoad(raw: u32) ?u5 {
    const op = raw >> 26;
    return if (op >= 0x20 and op <= 0x26) @truncate(raw >> 16) else null;
}
```

```zig
    /// The length of `code` in words, for a dump.
    code_words: u32 = 0,
    /// Ops emitted as calls to their handler rather than inline. How a test
    /// knows an op was lowered: inline code is not always the shorter.
    calls: u32 = 0,
```

- [ ] **Step 5: `model.zig`**

```zig
//! What the emitted code knows at compile time that memory does not hold
//! yet. `cached.runOp` leaves `Cpu.pipeline` and `Cpu.load_delay` current
//! after every instruction. An op emitted inline writes neither: it moves
//! this model on instead, and `sync` writes what `runOp` would have left
//! before anything reads them, which is a call, a slow path or the block's
//! end.
//!
//! The load delay is resolved here too. A load's value waits in x27 or x28,
//! by the parity of the op that issued it, and lands as the next op retires
//! unless that op writes the same register (`Cpu.writeReg` cancels it). The
//! block's entry counts as op -1: whatever `load_v` holds is a load to
//! $zero in flight, read into x28 by the prologue. A block entered with a
//! load to any other register runs through `.cached` (`jit.execute`).

const std = @import("std");
const e = @import("emit.zig");
const Emitter = @import("emitter.zig").Emitter;
const layout = @import("layout.zig");
const t = @import("translate.zig");

/// A load in flight: its target, and the register holding its value.
pub const Load = struct { rt: u5, value: e.Reg };

/// The register a load issued by op `i` keeps its value in. Entry is op -1,
/// so its value sits in x28.
pub fn loadReg(i: usize) e.Reg {
    return if (i % 2 == 0) .x27 else .x28;
}

pub const Model = struct {
    /// Memory lags the inline ops: `sync` must run before anything reads it.
    dirty: bool = false,
    /// The last op's PC, and whether it ran in a branch's delay slot. Its
    /// successor is then the branch target, which memory's `next_pc` holds:
    /// the branch wrote it, inline or as a call.
    pc: u32,
    delay_slot: bool = false,
    /// The load the last op issued: `load_r`/`load_v` after it.
    issued: ?Load = null,
    /// The load that landed as the last op retired: `delay_v` after it, and
    /// `delay_r` unless the last op's own write cancelled it.
    landed: ?Load = null,
    cancelled: bool = false,

    pub fn entry(start_pc: u32) Model {
        return .{ .pc = start_pc -% 4, .issued = .{ .rt = 0, .value = loadReg(1) } };
    }

    /// Op `i`, at `pc`, runs inline next. The load the last op issued lands
    /// as it retires. `issues` is its own load's target, if it is a load;
    /// `writes` the register it writes through `writeReg`.
    pub fn advance(m: *Model, i: usize, pc: u32, delay_slot: bool, issues: ?u5, writes: ?u5) void {
        m.landed = m.issued;
        m.cancelled = false;
        if (m.landed) |l| {
            if (writes) |w| m.cancelled = l.rt != 0 and w == l.rt;
        }
        m.issued = if (issues) |rt| .{ .rt = rt, .value = loadReg(i) } else null;
        m.pc = pc;
        m.delay_slot = delay_slot;
        m.dirty = true;
    }

    /// After a call to op `i`: memory is exact. A load it issued is read
    /// back into its register, where an inline successor expects it.
    pub fn afterCall(m: *Model, em: *Emitter, i: usize, pc: u32, delay_slot: bool, issues: ?u5) void {
        m.* = .{ .pc = pc, .delay_slot = delay_slot };
        if (issues) |rt| {
            m.issued = .{ .rt = rt, .value = loadReg(i) };
            em.put(e.memImm(.ldr_w, loadReg(i), t.cpu_reg, layout.load_v));
        }
    }

    /// The landed load's write-back, unless cancelled: `Cpu.retireLoad`.
    pub fn retire(m: *const Model, em: *Emitter) void {
        const l = m.landed orelse return;
        if (m.cancelled or l.rt == 0) return;
        em.put(e.memImm(.str_w, l.value, t.cpu_reg, layout.reg(l.rt)));
    }

    /// Writes the pipeline and the load delay as `runOp` would have left
    /// them after the last op, and marks memory exact. `branch_target`: the
    /// last op is a branch whose target is in that register (never x9).
    pub fn sync(m: *Model, em: *Emitter, branch_target: ?e.Reg) void {
        std.debug.assert(m.dirty);
        if (branch_target) |r| std.debug.assert(r != .x9);
        const cpu = t.cpu_reg;
        em.movImm32(.x9, m.pc);
        em.put(e.memImm(.str_w, .x9, cpu, layout.current_pc));
        if (branch_target) |target| {
            em.put(e.addImm(.w, .x9, .x9, 4));
            em.put(e.memImm(.str_w, .x9, cpu, layout.pc));
            em.put(e.memImm(.str_w, target, cpu, layout.next_pc));
        } else if (m.delay_slot) {
            em.put(e.memImm(.ldr_w, .x9, cpu, layout.next_pc));
            em.put(e.memImm(.str_w, .x9, cpu, layout.pc));
            em.put(e.addImm(.w, .x9, .x9, 4));
            em.put(e.memImm(.str_w, .x9, cpu, layout.next_pc));
        } else {
            em.put(e.addImm(.w, .x9, .x9, 4));
            em.put(e.memImm(.str_w, .x9, cpu, layout.pc));
            em.put(e.addImm(.w, .x9, .x9, 4));
            em.put(e.memImm(.str_w, .x9, cpu, layout.next_pc));
        }
        storeByte(em, @intFromBool(m.delay_slot), layout.is_delay_slot);
        storeByte(em, @intFromBool(branch_target != null), layout.next_is_delay_slot);
        storeByte(em, if (m.issued) |l| l.rt else 0, layout.load_r);
        em.put(e.memImm(.str_w, if (m.issued) |l| l.value else .zr, cpu, layout.load_v));
        const delay_r: u5 = if (m.landed) |l| (if (m.cancelled) 0 else l.rt) else 0;
        storeByte(em, delay_r, layout.delay_r);
        em.put(e.memImm(.str_w, if (m.landed) |l| l.value else .zr, cpu, layout.delay_v));
        m.dirty = false;
    }
};

fn storeByte(em: *Emitter, value: u8, offset: u32) void {
    if (value == 0) return em.put(e.memImm(.strb, .zr, t.cpu_reg, offset));
    em.put(e.movz(.w, .x9, value, 0));
    em.put(e.memImm(.strb, .x9, t.cpu_reg, offset));
}
```

Why each field is what `runOp` leaves, so a reviewer can check it against
`Cpu.beginInstruction`/`retireLoad`: `beginInstruction` copies
`load_*` into `delay_*` (that is `landed` taking `issued`) and clears
`load_*`; a load handler sets `load_*` (`issued`); `writeReg` to `delay_r`
zeroes `delay_r` and leaves `delay_v` (`cancelled`); `retireLoad` writes
`delay_v` to `delay_r` (`retire`).

- [ ] **Step 6: `lower_alu.zig`**

```zig
//! ALU, shift, logic, LUI and SLT ops, inline. Each reads its sources from
//! `Cpu.regs` and stores its result there; `model.zig` resolves the load
//! delay around it. ADD, ADDI and SUB leave for their `exec.zig` handler on
//! overflow, which raises the exception.
//!
//! Compiled only while PGXP is off (`run.zig`), so a result is a plain
//! store: `writeReg`'s shadow clear has nothing to clear.

const e = @import("emit.zig");
const t = @import("translate.zig");
const Instruction = @import("../../cpu/exec.zig").Instruction;
const sext16 = @import("../../bits.zig").sext16;

const R = @FieldType(Instruction, "r");
const Op = enum { add, sub, and_, orr, eor };
const Operand = union(enum) { reg: u5, imm: u32 };

fn encode(op: Op, rd: e.Reg, rn: e.Reg, rm: e.Reg) u32 {
    return switch (op) {
        .add => e.addReg(.w, rd, rn, rm),
        .sub => e.subReg(.w, rd, rn, rm),
        .and_ => e.andReg(.w, rd, rn, rm),
        .orr => e.orrReg(.w, rd, rn, rm),
        .eor => e.eorReg(.w, rd, rn, rm),
    };
}

/// False, having emitted nothing, for an op this file does not lower.
pub fn emit(ctx: *t.Ctx) bool {
    const in = ctx.op().instr;
    const i = in.i;
    switch (i.opcode) {
        0x00 => return special(ctx, in.r),
        0x08 => checked(ctx, .add, i.rt, i.rs, .{ .imm = sext16(i.imm) }), // ADDI
        0x09 => immediate(ctx, .add, i.rt, i.rs, sext16(i.imm)), // ADDIU
        0x0A => setImm(ctx, .lt, i.rt, i.rs, sext16(i.imm)), // SLTI
        0x0B => setImm(ctx, .lo, i.rt, i.rs, sext16(i.imm)), // SLTIU
        0x0C => immediate(ctx, .and_, i.rt, i.rs, i.imm),
        0x0D => immediate(ctx, .orr, i.rt, i.rs, i.imm),
        0x0E => immediate(ctx, .eor, i.rt, i.rs, i.imm),
        0x0F => lui(ctx, i.rt, i.imm),
        else => return false,
    }
    return true;
}

fn special(ctx: *t.Ctx, r: R) bool {
    switch (r.funct) {
        0x00 => shiftImm(ctx, r, .lsl),
        0x02 => shiftImm(ctx, r, .lsr),
        0x03 => shiftImm(ctx, r, .asr),
        0x04 => shiftVar(ctx, r, .lsl),
        0x06 => shiftVar(ctx, r, .lsr),
        0x07 => shiftVar(ctx, r, .asr),
        0x20 => checked(ctx, .add, r.rd, r.rs, .{ .reg = r.rt }),
        0x21 => register(ctx, .add, r),
        0x22 => checked(ctx, .sub, r.rd, r.rs, .{ .reg = r.rt }),
        0x23 => register(ctx, .sub, r),
        0x24 => register(ctx, .and_, r),
        0x25 => register(ctx, .orr, r),
        0x26 => register(ctx, .eor, r),
        0x27 => nor(ctx, r),
        0x2A => setReg(ctx, .lt, r),
        0x2B => setReg(ctx, .lo, r),
        else => return false,
    }
    return true;
}

// Every op below but `checked` has its destination as its only effect, so
// one that writes $zero is emitted as nothing but the landing load.

fn register(ctx: *t.Ctx, op: Op, r: R) void {
    _ = ctx.beginInline(null, r.rd);
    if (r.rd != 0) {
        const a = ctx.src(r.rs, .x10);
        const b = ctx.src(r.rt, .x11);
        ctx.em.put(encode(op, .x9, a, b));
        ctx.dst(r.rd, .x9);
    }
    ctx.endInline();
}

fn nor(ctx: *t.Ctx, r: R) void {
    _ = ctx.beginInline(null, r.rd);
    if (r.rd != 0) {
        const a = ctx.src(r.rs, .x10);
        const b = ctx.src(r.rt, .x11);
        ctx.em.put(e.orrReg(.w, .x9, a, b));
        ctx.em.put(e.ornReg(.w, .x9, .zr, .x9));
        ctx.dst(r.rd, .x9);
    }
    ctx.endInline();
}

fn setReg(ctx: *t.Ctx, cond: e.Cond, r: R) void {
    _ = ctx.beginInline(null, r.rd);
    if (r.rd != 0) {
        const a = ctx.src(r.rs, .x10);
        const b = ctx.src(r.rt, .x11);
        ctx.em.put(e.cmpReg(.w, a, b));
        ctx.em.put(e.cset(.w, .x9, cond));
        ctx.dst(r.rd, .x9);
    }
    ctx.endInline();
}

fn shiftImm(ctx: *t.Ctx, r: R, shift: e.Shift) void {
    _ = ctx.beginInline(null, r.rd);
    if (r.rd != 0) {
        const v = ctx.src(r.rt, .x10);
        ctx.em.put(e.shiftImm(shift, .x9, v, r.shamt));
        ctx.dst(r.rd, .x9);
    }
    ctx.endInline();
}

/// SLLV/SRLV/SRAV shift by `rs` modulo 32, which is what the host does too.
fn shiftVar(ctx: *t.Ctx, r: R, shift: e.Shift) void {
    _ = ctx.beginInline(null, r.rd);
    if (r.rd != 0) {
        const v = ctx.src(r.rt, .x10);
        const n = ctx.src(r.rs, .x11);
        ctx.em.put(e.shiftReg(.w, shift, .x9, v, n));
        ctx.dst(r.rd, .x9);
    }
    ctx.endInline();
}

fn immediate(ctx: *t.Ctx, op: Op, rt: u5, rs: u5, imm: u32) void {
    _ = ctx.beginInline(null, rt);
    if (rt != 0) {
        const a = ctx.src(rs, .x10);
        ctx.em.movImm32(.x11, imm);
        ctx.em.put(encode(op, .x9, a, .x11));
        ctx.dst(rt, .x9);
    }
    ctx.endInline();
}

fn setImm(ctx: *t.Ctx, cond: e.Cond, rt: u5, rs: u5, imm: u32) void {
    _ = ctx.beginInline(null, rt);
    if (rt != 0) {
        const a = ctx.src(rs, .x10);
        ctx.em.movImm32(.x11, imm);
        ctx.em.put(e.cmpReg(.w, a, .x11));
        ctx.em.put(e.cset(.w, .x9, cond));
        ctx.dst(rt, .x9);
    }
    ctx.endInline();
}

fn lui(ctx: *t.Ctx, rt: u5, imm: u16) void {
    _ = ctx.beginInline(null, rt);
    if (rt != 0) {
        ctx.em.put(e.movz(.w, .x9, imm, 1));
        ctx.dst(rt, .x9);
    }
    ctx.endInline();
}

/// ADD, ADDI, SUB. On overflow nothing has been written and the slow path
/// runs the op's handler, which raises the exception and stops the block;
/// even a write to $zero can overflow, so these are always emitted.
fn checked(ctx: *t.Ctx, op: enum { add, sub }, rd: u5, rs: u5, b: Operand) void {
    const before = ctx.beginInline(null, rd);
    const slow = ctx.slowPath(before);
    const a = ctx.src(rs, .x10);
    const rm: e.Reg = switch (b) {
        .reg => |r| ctx.src(r, .x11),
        .imm => |imm| blk: {
            ctx.em.movImm32(.x11, imm);
            break :blk .x11;
        },
    };
    ctx.em.put(switch (op) {
        .add => e.addsReg(.w, .x9, a, rm),
        .sub => e.subsReg(.w, .x9, a, rm),
    });
    ctx.em.branch(.{ .cond = .vs }, .{ .label = slow.entry });
    ctx.dst(rd, .x9);
    ctx.endInline();
    ctx.em.bind(slow.back);
}
```

- [ ] **Step 7: Rewrite `translate.zig` around the model**

Keep Task 2's register constants, `return_stub`, `callRunOp`, `commitMid`,
`commitFinal`, `countThrough` and the shims exactly as they are. Change the
file comment's second paragraph to name both resolutions ("the cycle and
step counts (`pending` and the commit formulas below) and the pipeline and
load delay (`model.zig`)"), import `model.zig` and `lower_alu.zig`, and
replace `Ctx`, `compile`, `prologue`, `emitCall` and `end` with:

```zig
const model = @import("model.zig");
const Model = model.Model;
const lower_alu = @import("lower_alu.zig");

pub const Options = struct {
    lower: jit.Lowering,
};

/// An inline op's way out: `entry` is where its hot code branches, and the
/// cold code comes back to `back`, which the op binds after `endInline`.
pub const Slow = struct { entry: emitter.Label, back: emitter.Label };

pub const Ctx = struct {
    em: *Emitter,
    b: *const block.Block,
    opts: Options,
    return_stub: usize,
    /// The op being emitted.
    i: usize = 0,
    /// Ops emitted inline whose count w26 does not include yet.
    pending: u32 = 0,
    /// Ops emitted as calls (`Block.calls`).
    calls: u32 = 0,
    model: Model,
    /// The stop tail: a call's op raised an exception or set `block_exit`.
    stop: emitter.Label,

    pub fn op(ctx: *const Ctx) *const block.Op {
        return &ctx.b.ops[ctx.i];
    }

    pub fn pc(ctx: *const Ctx) u32 {
        return ctx.b.start_pc +% @as(u32, @intCast(ctx.i)) * 4;
    }

    pub fn isDelaySlot(ctx: *const Ctx) bool {
        return ctx.i > 0 and block.isBranch(ctx.b.ops[ctx.i - 1].instr.raw);
    }

    /// Guest register `r`, loaded into `into`. $zero reads as the zero
    /// register, which only the register forms of an instruction accept.
    pub fn src(ctx: *Ctx, r: u5, into: e.Reg) e.Reg {
        if (r == 0) return .zr;
        ctx.em.put(e.memImm(.ldr_w, into, cpu_reg, layout.reg(r)));
        return into;
    }

    /// Stores `from` to guest register `r`. A write to $zero is dropped.
    pub fn dst(ctx: *Ctx, r: u5, from: e.Reg) void {
        if (r == 0) return;
        ctx.em.put(e.memImm(.str_w, from, cpu_reg, layout.reg(r)));
    }

    /// Starts the op inline. Returns the model as it stood before it, which
    /// a slow path syncs from. `issues`: the load target it issues;
    /// `writes`: the register it writes through `writeReg`.
    pub fn beginInline(ctx: *Ctx, issues: ?u5, writes: ?u5) Model {
        const before = ctx.model;
        ctx.model.advance(ctx.i, ctx.pc(), ctx.isDelaySlot(), issues, writes);
        return before;
    }

    /// Ends the op inline: the landed load retires, and the op counts.
    pub fn endInline(ctx: *Ctx) void {
        ctx.model.retire(ctx.em);
        ctx.pending += 1;
    }

    /// The op's slow path, in the cold section: memory brought to the state
    /// before the op, then the op as a call, exactly as `emitCall` runs it.
    /// Call it after `beginInline`.
    pub fn slowPath(ctx: *Ctx, before: Model) Slow {
        const em = ctx.em;
        const s: Slow = .{ .entry = em.label(), .back = em.label() };
        em.section = .cold;
        em.bind(s.entry);
        var m = before;
        if (m.dirty) m.sync(em, null);
        const counted: u12 = @intCast(ctx.pending + 1);
        em.put(e.addImm(.w, ran_reg, ran_reg, counted));
        if (ctx.op().memory) commitMid(em);
        callRunOp(ctx);
        // Back on the hot path, which counts this op among `pending`.
        em.put(e.subImm(.w, ran_reg, ran_reg, counted));
        if (ctx.model.issued) |l| em.put(e.memImm(.ldr_w, l.value, cpu_reg, layout.load_v));
        em.branch(.b, .{ .label = s.back });
        em.section = .hot;
        return s;
    }
};

/// Emits `b`, installs it in `j`'s buffer and sets `b.code`,
/// `b.code_words` and `b.calls`.
pub fn compile(j: *jit.Jit, pins: *Pins, b: *block.Block, opts: Options) error{CodeBufferFull}!void {
    std.debug.assert(b.ops.len <= block.max_len + 1);
    const em = &j.em;
    em.reset();
    var ctx: Ctx = .{
        .em = em,
        .b = b,
        .opts = opts,
        .return_stub = j.return_stub,
        .model = .entry(b.start_pc),
        .stop = em.label(),
    };
    prologue(&ctx, pins);
    while (ctx.i < b.ops.len) : (ctx.i += 1) emitOp(&ctx);
    end(&ctx);
    const code = em.finish(j.buf.cursor());
    const entry: block.JitEntry = @ptrCast(try j.buf.install(code));
    b.code = entry;
    b.code_words = @intCast(code.len);
    b.calls = ctx.calls;
}

const Family = enum { alu, other };

fn family(raw: u32) Family {
    return switch (raw >> 26) {
        0x00 => switch (raw & 0x3F) {
            0x00, 0x02, 0x03, 0x04, 0x06, 0x07, 0x20...0x27, 0x2A, 0x2B => .alu,
            else => .other,
        },
        0x08...0x0F => .alu,
        else => .other,
    };
}

fn emitOp(ctx: *Ctx) void {
    const lower = ctx.opts.lower;
    const lowered = switch (family(ctx.op().instr.raw)) {
        .alu => lower.alu and lower_alu.emit(ctx),
        .other => false,
    };
    if (!lowered) emitCall(ctx);
}

/// The op as a call to `cached.runOp`, as `cached.execute` runs it.
fn emitCall(ctx: *Ctx) void {
    const em = ctx.em;
    ctx.calls += 1;
    if (ctx.model.dirty) ctx.model.sync(em, null);
    countThrough(ctx);
    if (ctx.op().memory) commitMid(em);
    callRunOp(ctx);
    ctx.model.afterCall(em, ctx.i, ctx.pc(), ctx.isDelaySlot(), block.issuesLoad(ctx.op().instr.raw));
}
```

`prologue` gains one line at its end (op -1's load, after the per-block
`movReg`):

```zig
    em.put(e.memImm(.ldr_w, model.loadReg(1), cpu_reg, layout.load_v));
```

`end` syncs before the final commit:

```zig
fn end(ctx: *Ctx) void {
    const em = ctx.em;
    if (ctx.pending > 0) em.put(e.addImm(.w, ran_reg, ran_reg, @intCast(ctx.pending)));
    if (ctx.model.dirty) ctx.model.sync(em, null);
    commitFinal(em);
    em.branch(.b, .{ .address = ctx.return_stub });
    // The stop tail: memory is exactly as the stopping op's call left it.
    em.section = .cold;
    em.bind(ctx.stop);
    commitFinal(em);
    em.branch(.b, .{ .address = ctx.return_stub });
    em.section = .hot;
}
```

- [ ] **Step 8: `jit.zig`: `Lowering`, `Jit.lower`, the entry rule**

```zig
/// Which op families the JIT emits inline; every other op is a call to its
/// `exec.zig` handler. All on is the shipped engine. Turning one off
/// bisects a JIT bug to that family (`ps1-golden --jit-lower=`).
pub const Lowering = struct {
    alu: bool = true,

    pub const none: Lowering = .{ .alu = false };
};
```

`Jit` gets `lower: Lowering = .{},` after `em`. `execute` sends a block
entered with a load in flight to `.cached`:

```zig
/// Runs `b`'s host code from `cpu.pipeline.pc`, its start. Same contract
/// as `cached.execute`.
pub fn execute(cpu: *Cpu, b: *const block.Block, fetch_cost: u32) u32 {
    // Inline code resolves the load delay at compile time, and cannot know
    // which register a load issued before the block targets.
    if (cpu.load_delay.load_r != 0) return cached.execute(cpu, b, fetch_cost);
    cached.begin(cpu);
    return b.code.?(cpu, fetch_cost);
}
```

- [ ] **Step 9: `cache.zig`: `discard`**

```zig
    /// Blocks compiled again because they were entered through a segment
    /// their inline code was not compiled for (`run.blockAt`).
    segment_recompiles: u32 = 0,
```

```zig
    /// Drops one block as invalidation would. `run.zig` uses it for a block
    /// entered through another segment than it was compiled for.
    pub fn discard(self: *BlockCache, b: *Block) void {
        if (block.regionOf(b.start_pc & 0x1FFF_FFFF).? == .ram) {
            removeFrom(&self.page_blocks[b.first_page], b);
            if (self.page_blocks[b.first_page].items.len == 0) self.clearBit(b.first_page);
        }
        self.drop(b, b.first_page);
    }
```

Extract the loop `drop` already uses to remove a block from the other
page's list into

```zig
fn removeFrom(list: *std.ArrayList(*Block), b: *Block) void {
    for (list.items, 0..) |x, k| {
        if (x == b) {
            _ = list.swapRemove(k);
            return;
        }
    }
}
```

and call it from `drop` too. A BIOS block has no page list: `drop` with
`first_page == last_page` touches none.

- [ ] **Step 10: `run.zig`: the options and the segment rule**

In `compileBlock`, build the options from the bus:

```zig
        if (c.jit) |j| {
            const opts: jit.translate.Options = .{
                // Inline code skips the PGXP hooks `exec.zig` calls. Plan 6
                // emits them; until then a block compiled under PGXP is all
                // calls, and `Bus.setPgxp` flushes on every toggle.
                .lower = if (bus.pgxp_enabled) .none else j.lower,
            };
            jit.translate.compile(j, &c.pins, b, opts) catch {
                c.flush();
                try jit.translate.compile(j, &c.pins, b, opts);
            };
        }
```

Replace the lookup in `run` with

```zig
    const b = blockAt(c, bus, pc) orelse {
        // No memory for a block, or no code space even after a flush: the
        // interpreter still runs.
        cpu.step();
        c.icache_dirty = true;
        return 1;
    };
```

```zig
/// The block at `pc`, compiled if need be. Inline code bakes its PCs in, so
/// a block entered through another segment than it was compiled for (KSEG0
/// against KSEG1, or a RAM mirror) is compiled again for this one.
fn blockAt(c: *BlockCache, bus: *const Bus, pc: u32) ?*block.Block {
    if (c.lookup(pc & 0x1FFF_FFFF)) |b| {
        if (b.code == null or b.start_pc == pc) return b;
        c.discard(b);
        c.segment_recompiles += 1;
    }
    return compileBlock(c, bus, pc) catch null;
}
```

- [ ] **Step 11: `memory.zig`: flush on a PGXP toggle**

At the top of `Bus.setPgxp`:

```zig
        // A compiled block bakes in whether PGXP was on (`recompiler/run.zig`).
        if (enabled != self.pgxp_enabled) {
            if (self.blocks) |c| c.flush();
        }
```

- [ ] **Step 12: Run the tests**

Run: `zig build test -Dtest-filter="jit"`, then
`zig build test -Dtest-filter="recompiler"`, then `zig build test`.
Expected: PASS, the fuzzer included. If an equality test fails, run the
same program under `lockstep` in a scratch test (attach a
`recompiler.lockstep.Checker` as `test "lockstep checks JIT blocks"` does)
to name the block, and compare the model's sync against `runOp`'s fields
one by one.

- [ ] **Step 13: The gates**

```bash
zig build
zig build trace-golden -Doptimize=ReleaseFast -- verify --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- savestate --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- lockstep --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- pgxp --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- pgxp --engine=cached
```

Expected: OK on all nine for `verify` and `savestate`; lockstep 0
mismatches. The two `pgxp` outputs differ only in the line naming the
engine (PGXP on lowers nothing, so `.jit` is still all calls there).

- [ ] **Step 14: Bench** as in Task 2, Step 12. Record both engines' best
of five.

- [ ] **Step 15: Format and commit**

```bash
zig fmt ps1-core/src ps1-core/tests/jit_test.zig ps1-core/tests/recompiler_helpers.zig
git add ps1-core/src/recompiler ps1-core/src/memory.zig ps1-core/tests/jit_test.zig ps1-core/tests/recompiler_helpers.zig
git commit -m "feat(jit): inline ALU ops over a compile-time load-delay model"
```

---

### Task 4: The bisecting tools: `--jit-lower` and `--jit-dump`

**Files:**
- Modify: `ps1-core/src/recompiler/jit.zig`, `ps1-core/src/recompiler/run.zig`
- Modify: `ps1-golden/src/main.zig`, `ps1-bench/main.zig`
- Test: `ps1-core/tests/jit_test.zig`

**Interfaces:**
- Consumes: Task 3's `Lowering`, `Jit.lower`, `Block.code_words`.
- Produces: `Lowering.parse(text) error{UnknownFamily}!Lowering` (names
  `all`, `none`, or a comma list of `families`); `jit.Hook{ context, f }`;
  `Jit.dump: ?Hook`; `run.setLowering(bus, Lowering)` (flushes);
  `run.setJitDump(bus, ?Hook)`; `ps1-golden --jit-lower=`, `--jit-dump=`;
  `ps1-bench --jit-lower=`. Later tasks add their family to `Lowering`,
  `none` and `families`.

- [ ] **Step 1: Write the failing test**

```zig
test "a lowering mask parses from family names" {
    const Lowering = jit.Lowering;
    try expectEqual(Lowering{}, try Lowering.parse("all"));
    try expectEqual(Lowering.none, try Lowering.parse("none"));
    // Every family but the named ones off, however many later tasks add.
    var only_alu = Lowering.none;
    only_alu.alu = true;
    try expectEqual(only_alu, try Lowering.parse("alu"));
    try std.testing.expectError(error.UnknownFamily, Lowering.parse("alu,float"));
}
```

Run: `zig build test -Dtest-filter="lowering mask"`. Expected: compile
error, no `parse`.

- [ ] **Step 2: `Lowering.parse` and the dump hook**

```zig
pub const Lowering = struct {
    alu: bool = true,

    pub const none: Lowering = .{ .alu = false };
    /// The names `parse` takes, one per field.
    const families = .{"alu"};

    /// "all", "none", or a comma-separated list of the families to lower.
    pub fn parse(text: []const u8) error{UnknownFamily}!Lowering {
        if (std.mem.eql(u8, text, "all")) return .{};
        var l: Lowering = none;
        if (std.mem.eql(u8, text, "none")) return l;
        var it = std.mem.splitScalar(u8, text, ',');
        while (it.next()) |name| l = try with(l, name);
        return l;
    }

    fn with(l: Lowering, name: []const u8) error{UnknownFamily}!Lowering {
        var out = l;
        inline for (families) |f| {
            if (std.mem.eql(u8, name, f)) {
                @field(out, f) = true;
                return out;
            }
        }
        return error.UnknownFamily;
    }
};

/// Called with each block's code once it is installed: `ps1-golden
/// --jit-dump` writes it out for `objdump`.
pub const Hook = struct {
    context: *anyopaque,
    f: *const fn (context: *anyopaque, b: *const block.Block, code: []const u32) void,
};
```

`Jit` gets `dump: ?Hook = null,`. In `run.zig`'s `compileBlock`, after the
compile succeeds:

```zig
            if (j.dump) |d| d.f(d.context, b, @as([*]const u32, @ptrCast(b.code.?))[0..b.code_words]);
```

and two setters:

```zig
/// The JIT's lowering mask, from a harness. Flushes: a compiled block bakes
/// its lowering in. Does nothing off `.jit`.
pub fn setLowering(bus: *Bus, lower: jit.Lowering) void {
    const c = bus.blocks orelse return;
    const j = c.jit orelse return;
    j.lower = lower;
    c.flush();
}

/// Calls `hook` with every block the JIT compiles from now on.
pub fn setJitDump(bus: *Bus, hook: ?jit.Hook) void {
    const c = bus.blocks orelse return;
    const j = c.jit orelse return;
    j.dump = hook;
}
```

Run the test: PASS.

- [ ] **Step 3: `ps1-golden`**

`Options` gains

```zig
    /// `--jit-lower=`: the JIT's lowering mask (`jit.Lowering.parse`).
    /// Turning one family off bisects a `.jit` mismatch to it.
    jit_lower: ps1.recompiler.jit.Lowering = .{},
    /// `--jit-dump=<prefix>`: every block the JIT compiles, as assembler
    /// source in `<prefix>-<workload>.s`, for
    /// `clang -arch arm64 -c x.s -o x.o && objdump -d x.o`.
    jit_dump: ?[]const u8 = null,
```

parsed in `parseArgs` beside `--engine=`:

```zig
        } else if (std.mem.startsWith(u8, arg, "--jit-lower=")) {
            opts.jit_lower = try ps1.recompiler.jit.Lowering.parse(arg["--jit-lower=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--jit-dump=")) {
            opts.jit_dump = arg["--jit-dump=".len..];
```

Add both to the usage text after `--engine`. `selectEngine` applies the
mask:

```zig
fn selectEngine(cpu: *ps1.cpu.Cpu, opts: Options) !void {
    try ps1.recompiler.setEngine(cpu, std.heap.smp_allocator, opts.engine);
    ps1.recompiler.setLowering(cpu.bus, opts.jit_lower);
}
```

Every call site passes `opts`; `saveAndRestore` takes `opts: Options` in
place of `engine: Engine` and its caller passes `opts`.

The dump writer, beside `FrameStepper`:

```zig
/// `--jit-dump`: every compiled block's code as assembler source.
const JitDump = struct {
    a: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    blocks: usize = 0,

    fn hook(d: *JitDump) ps1.recompiler.jit.Hook {
        return .{ .context = d, .f = record };
    }

    fn record(context: *anyopaque, b: *const ps1.recompiler.block.Block, code: []const u32) void {
        const d: *JitDump = @ptrCast(@alignCast(context));
        d.append(b, code) catch @panic("--jit-dump: out of memory");
    }

    fn append(d: *JitDump, b: *const ps1.recompiler.block.Block, code: []const u32) !void {
        try d.text.appendSlice(d.a, try std.fmt.allocPrint(d.a, "// guest 0x{x:0>8}, {d} ops\nblock_{d}:\n", .{ b.start_pc, b.ops.len, d.blocks }));
        for (code) |w| try d.text.appendSlice(d.a, try std.fmt.allocPrint(d.a, "  .inst 0x{x:0>8}\n", .{w}));
        d.blocks += 1;
    }
};
```

In `runWorkload` and `runLockstep`, after `selectEngine`:

```zig
    var dump: JitDump = .{ .a = a };
    if (opts.jit_dump != null) ps1.recompiler.setJitDump(bus, dump.hook());
```

and after the run loop:

```zig
    if (opts.jit_dump) |prefix| {
        const path = try std.fmt.allocPrint(a, "{s}-{s}.s", .{ prefix, wl.key });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = dump.text.items });
    }
```

(`a` is the arena both runners already take; use the names the runner
already has for the allocator, the `Io` and the workload key.) In
`runWorkload`, a `savestate` restore installs a fresh `Bus`: re-apply
`setJitDump` on it right after `saveAndRestore` returns.

- [ ] **Step 4: `ps1-bench`**

Parse `--jit-lower=` beside `--engine=` into a `jit_lower` variable
(default `.{}`) and apply it after `setEngine`:

```zig
    try ps1.recompiler.setEngine(&cpu, alloc, engine);
    ps1.recompiler.setLowering(cpu.bus, jit_lower);
```

- [ ] **Step 5: Check the tools by hand**

```bash
zig build -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify --engine=jit --jit-lower=none --filter=croc
zig build trace-golden -Doptimize=ReleaseFast -- lockstep --engine=jit --jit-dump="$TMPDIR/jit" --filter=croc --instructions=5000000
clang -arch arm64 -c "$TMPDIR"/jit-croc*.s -o "$TMPDIR/jit.o" && objdump -d "$TMPDIR/jit.o" | head -40
```

Expected: `verify` OK with every family masked off; lockstep 0 mismatches
over the short run (it needs no golden, which is why the dump check uses
it); the disassembly shows the prologue (`stp x29, x30, [sp, #-0x60]!`)
and inline ALU code.

- [ ] **Step 6: Gates, format, commit**

```bash
zig build
zig build test
zig fmt ps1-core/src/recompiler ps1-golden/src ps1-bench ps1-core/tests/jit_test.zig
git add ps1-core/src/recompiler ps1-golden/src ps1-bench ps1-core/tests/jit_test.zig
git commit -m "feat(jit): --jit-lower and --jit-dump for bisecting the lowering"
```

---

### Task 5: Inline branches and jumps

**Files:**
- Create: `ps1-core/src/recompiler/arm64/lower_branch.zig`
- Modify: `ps1-core/src/recompiler/arm64/translate.zig`, `ps1-core/src/recompiler/jit.zig`
- Test: `ps1-core/tests/jit_test.zig`

**Interfaces:**
- Consumes: Task 3's `Ctx`, `Model.sync(em, target)`.
- Produces: `lower_branch.emit(ctx) bool`; `Ctx.endBranch(target: e.Reg)`;
  `Lowering.branch` (in `none` and `families`). The `branch` family in
  `translate.family`: REGIMM, J, JAL, BEQ, BNE, BLEZ, BGTZ, JR, JALR.

- [ ] **Step 1: Write the failing tests**

```zig
test ".jit equals .cached: every inline branch, taken and not" {
    const at = 0x8000_1000;
    try expectSameRuns(&.{
        mips.addiu(t0, zero, 1), // 0
        mips.addiu(t1, zero, 0xFFFF), // 1: -1
        mips.beq(t0, t1, 2), // 2: not taken
        mips.addiu(t2, t2, 1), // 3: delay slot
        mips.bne(t0, t1, 2), // 4: taken, to 7
        mips.addiu(t2, t2, 1), // 5: delay slot
        mips.addiu(t2, t2, 0x100), // 6: skipped
        mips.i(0x06, t1, 0, 2), // 7: BLEZ -1, taken, to 10
        mips.nop,
        mips.addiu(t2, t2, 0x100),
        mips.i(0x07, t1, 0, 2), // 10: BGTZ -1, not taken
        mips.nop,
        mips.i(0x01, t1, 0x00, 2), // 12: BLTZ, taken, to 15
        mips.nop,
        mips.addiu(t2, t2, 0x100),
        mips.i(0x01, t1, 0x01, 2), // 15: BGEZ, not taken
        mips.nop,
        mips.i(0x01, h.ra, 0x10, 2), // 17: BLTZAL on $ra: compares the old $ra, then links
        mips.nop,
        mips.i(0x01, t0, 0x11, 2), // 19: BGEZAL, taken, to 22
        mips.nop,
        mips.addiu(t2, t2, 0x100),
        mips.jal(at + 26 * 4), // 22: to 26
        mips.addiu(t3, zero, 3),
        mips.addiu(t2, t2, 0x100), // 24, 25: skipped
        mips.addiu(t2, t2, 0x100),
        mips.lui(t5, 0x8000), // 26
        mips.ori(t5, t5, 0x1000 + 32 * 4),
        mips.jalr(t5, t5), // 28: links into t5 first, so jumps to 30, not 32
        mips.nop,
        mips.beq(zero, zero, -1), // 30: the end
        mips.nop,
        mips.addiu(t2, t2, 0x100), // 32: only a wrong JALR lands here
        mips.beq(zero, zero, -1),
        mips.nop,
    }, at, 24);
}

test ".jit equals .cached: a call and its return through $ra" {
    const at = 0x8000_1000;
    try expectSameRuns(&.{
        mips.jal(at + 6 * 4), // 0: to f
        mips.addiu(t0, zero, 1),
        mips.addiu(t1, t0, 1), // 2: f returns here
        mips.beq(zero, zero, -1),
        mips.nop,
        mips.nop,
        mips.jr(h.ra), // 6: f
        mips.addiu(t2, zero, 2),
    }, at, 8);
}
```

These pass today (branches are calls). What fails first is the check that
the branches really are inline:

```zig
test "a block's branch is inline, and a call with branches masked off" {
    if (!jit.available) return error.SkipZigTest;
    var m = try h.Machine.init(.jit);
    defer m.deinit();
    h.poke(m.bus, 0x1000, &.{ mips.beq(zero, zero, -1), mips.nop });
    m.start(0x8000_1000);
    _ = m.cpu.run();
    try expectEqual(@as(u32, 0), m.bus.blocks.?.lookup(0x1000).?.calls);
    var no_branch: jit.Lowering = .{};
    no_branch.branch = false;
    recompiler.setLowering(m.bus, no_branch);
    m.start(0x8000_1000);
    _ = m.cpu.run();
    try expectEqual(@as(u32, 1), m.bus.blocks.?.lookup(0x1000).?.calls);
}
```

Run: `zig build test -Dtest-filter="jit"`. Expected: compile error, no
`branch` in `Lowering`.

- [ ] **Step 2: `Lowering.branch`**

Add `branch: bool = true,` to `Lowering`, `.branch = false` to `none`,
and `"branch"` to `families`.

- [ ] **Step 3: `lower_branch.zig`**

```zig
//! Branches and jumps, inline. A branch computes its target into w10,
//! links where it links, and then writes the pipeline as `exec.zig`'s
//! handler leaves it (`next_pc` the target, `next_is_delay_slot` set) along
//! with everything else the model holds: its delay slot is the next op,
//! inline or a call, and a call would clobber w10.
//!
//! A branch in another branch's delay slot stays a call: its own delay slot
//! is not in the block. So does a reserved REGIMM, which raises.

const e = @import("emit.zig");
const t = @import("translate.zig");
const sext16 = @import("../../bits.zig").sext16;

/// False, having emitted nothing, for an op this file does not lower.
pub fn emit(ctx: *t.Ctx) bool {
    if (ctx.isDelaySlot()) return false;
    const in = ctx.op().instr;
    const pc = ctx.pc();
    const relative = pc +% 4 +% (sext16(in.i.imm) << 2);
    const absolute = ((pc +% 4) & 0xF000_0000) | @as(u32, in.j.target) << 2;
    switch (in.i.opcode) {
        0x00 => switch (in.r.funct) {
            0x08 => register(ctx, in.r.rs, null), // JR
            0x09 => register(ctx, in.r.rs, in.r.rd), // JALR
            else => return false,
        },
        0x01 => switch (in.i.rt) {
            0x00 => conditional(ctx, in.i.rs, null, .lt, relative, null), // BLTZ
            0x01 => conditional(ctx, in.i.rs, null, .ge, relative, null), // BGEZ
            0x10 => conditional(ctx, in.i.rs, null, .lt, relative, 31), // BLTZAL
            0x11 => conditional(ctx, in.i.rs, null, .ge, relative, 31), // BGEZAL
            else => return false,
        },
        0x02 => jump(ctx, absolute, null), // J
        0x03 => jump(ctx, absolute, 31), // JAL
        0x04 => conditional(ctx, in.i.rs, in.i.rt, .eq, relative, null), // BEQ
        0x05 => conditional(ctx, in.i.rs, in.i.rt, .ne, relative, null), // BNE
        0x06 => conditional(ctx, in.i.rs, null, .le, relative, null), // BLEZ
        0x07 => conditional(ctx, in.i.rs, null, .gt, relative, null), // BGTZ
        else => return false,
    }
    return true;
}

/// `rs` against `rt`, or against zero when `rt` is null. The link is
/// written after `rs` is read, as `opRegimm` reads it first.
fn conditional(ctx: *t.Ctx, rs: u5, rt: ?u5, cond: e.Cond, taken: u32, link: ?u5) void {
    const em = ctx.em;
    _ = ctx.beginInline(null, link);
    const a = ctx.src(rs, .x10);
    const b: e.Reg = if (rt) |r| ctx.src(r, .x11) else .zr;
    em.put(e.cmpReg(.w, a, b));
    const not_taken = ctx.pc() +% 8;
    // Neither MOVZ, MOVK nor STR touches the flags.
    if (link) |r| {
        em.movImm32(.x11, not_taken);
        ctx.dst(r, .x11);
    }
    em.movImm32(.x10, taken);
    em.movImm32(.x11, not_taken);
    em.put(e.csel(.w, .x10, .x10, .x11, cond));
    ctx.endBranch(.x10);
}

fn jump(ctx: *t.Ctx, target: u32, link: ?u5) void {
    _ = ctx.beginInline(null, link);
    if (link) |r| {
        ctx.em.movImm32(.x11, ctx.pc() +% 8);
        ctx.dst(r, .x11);
    }
    ctx.em.movImm32(.x10, target);
    ctx.endBranch(.x10);
}

/// JR, JALR. The link is written before the target is read, as `opJalr`
/// does, so with rd == rs the jump goes to the link.
fn register(ctx: *t.Ctx, rs: u5, link: ?u5) void {
    _ = ctx.beginInline(null, link);
    if (link) |r| {
        ctx.em.movImm32(.x11, ctx.pc() +% 8);
        ctx.dst(r, .x11);
    }
    ctx.endBranch(ctx.src(rs, .x10));
}
```

- [ ] **Step 4: `translate.zig`: dispatch and `endBranch`**

`Family` gains `branch`, and `family`:

```zig
const Family = enum { alu, branch, other };

fn family(raw: u32) Family {
    return switch (raw >> 26) {
        0x00 => switch (raw & 0x3F) {
            0x00, 0x02, 0x03, 0x04, 0x06, 0x07, 0x20...0x27, 0x2A, 0x2B => .alu,
            0x08, 0x09 => .branch,
            else => .other,
        },
        0x01...0x07 => .branch,
        0x08...0x0F => .alu,
        else => .other,
    };
}
```

`emitOp` gains `.branch => lower.branch and lower_branch.emit(ctx),`
(import `lower_branch.zig`). On `Ctx`:

```zig
    /// Ends a branch inline: the landed load retires, then memory takes the
    /// branch's whole state, with its target in `target`.
    pub fn endBranch(ctx: *Ctx, target: e.Reg) void {
        ctx.model.retire(ctx.em);
        ctx.model.sync(ctx.em, target);
        ctx.pending += 1;
    }
```

`target` may be `.zr` (JR $zero): `sync` stores `wzr` then.

- [ ] **Step 5: Run the tests**

Run: `zig build test -Dtest-filter="jit"`, then `zig build test`.
Expected: PASS, fuzzer included (its branches, branches in delay slots and
delay-slot loads are the family's real test).

- [ ] **Step 6: Gates and bench**

```bash
zig build
zig build trace-golden -Doptimize=ReleaseFast -- verify --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- savestate --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- lockstep --engine=jit
```

Expected as before. A mismatch here is bisected with `--jit-lower=alu`
(branches off) before anything else. Bench as in Task 2, Step 12.

- [ ] **Step 7: Format and commit**

```bash
zig fmt ps1-core/src/recompiler ps1-core/tests/jit_test.zig
git add ps1-core/src/recompiler ps1-core/tests/jit_test.zig
git commit -m "feat(jit): inline branches and jumps"
```

---

### Task 6: Inline loads from RAM and the scratchpad

**Files:**
- Create: `ps1-core/src/recompiler/arm64/lower_memory.zig`
- Modify: `ps1-core/src/recompiler/arm64/translate.zig`, `ps1-core/src/recompiler/jit.zig`,
  `ps1-core/src/memory.zig`, `ps1-core/src/recompiler/lockstep.zig`
- Test: `ps1-core/tests/jit_test.zig`

**Interfaces:**
- Consumes: Task 3's `Ctx`, `slowPath`, `model.issued`.
- Produces: `Bus.ram_access_wait`; `lower_memory.emitLoad(ctx) bool` and
  the shared `address(ctx, in, width, slow)` and `scratchpadOffset(em,
  slow)`; `Lowering.load`; `lockstep.Checker.stray` and the `"io"`
  mismatch.

- [ ] **Step 1: Write the failing tests**

```zig
test "the inline RAM path bills the bus's own wait states" {
    const bus = try ps1_core.memory.Bus.init(alloc);
    defer bus.deinit(alloc);
    const Bus = ps1_core.memory.Bus;
    for ([_]u32{ 0x0000_0000, 0x8000_1000, 0xA01F_FFFC }) |a| {
        try expectEqual(Bus.ram_access_wait, bus.waitCycles(u32, a, false));
        try expectEqual(Bus.ram_access_wait, bus.waitCycles(u16, a, true));
        try expectEqual(Bus.ram_access_wait, bus.waitCycles(u8, a, false));
    }
    try expectEqual(@as(u32, 0), bus.waitCycles(u32, 0x1F80_0000, false)); // the scratchpad is free
}

test ".jit equals .cached: inline loads from RAM, a mirror, the scratchpad and I/O" {
    try expectSameRuns(&.{
        mips.lui(t0, 0x8000),
        mips.ori(t0, t0, 0x2000), // KSEG0 RAM
        mips.lui(t1, 0xA000),
        mips.ori(t1, t1, 0x2000), // the same word through KSEG1
        mips.lui(t2, 0x0020),
        mips.ori(t2, t2, 0x2000), // its mirror at 2 MB: other wait states, so the slow path
        mips.lui(t3, 0x1F80), // the scratchpad
        mips.addiu(t4, zero, 0x8081), // 0xFFFF8081: a sign bit in every width
        mips.sw(t4, t0, 0),
        mips.sw(t4, t3, 4),
        mips.lw(t5, t0, 0),
        mips.i(0x20, t1, t6, 0), // LB: 0x81 sign-extends
        mips.i(0x24, t1, t7, 0), // LBU
        mips.i(0x21, t0, t5, 2), // LH: 0xFFFF
        mips.i(0x25, t0, t6, 0), // LHU: 0x8081
        mips.lw(t7, t2, 0), // the mirror
        mips.lw(t5, t3, 4), // the scratchpad
        mips.i(0x20, t3, t6, 5), // LB from the scratchpad
        mips.lw(t7, t1, 0xFFFC), // a negative offset, through KSEG1
        mips.lui(t4, 0x1F80),
        mips.ori(t4, t4, 0x1120), // timer 2's counter: I/O, committed first
        mips.lw(t5, t4, 0),
        mips.addu(t6, t5, zero),
        mips.beq(zero, zero, -1),
        mips.nop,
    }, 0x8000_1000, 4);
}

test ".jit equals .cached: misaligned loads fault from the inline path" {
    for ([_]u32{ mips.lw(t1, t0, 2), mips.i(0x21, t0, t1, 1), mips.i(0x25, t0, t1, 3) }) |load| {
        try expectSameRuns(&.{
            mips.lui(t0, 0x8000),
            mips.addiu(t2, zero, 5),
            load,
            mips.addu(t3, t1, zero),
            mips.beq(zero, zero, -1),
            mips.nop,
        }, 0x8000_1000, 3);
    }
}

test "lockstep reports a reference that strays into I/O the engine never touched" {
    if (!jit.available) return error.SkipZigTest;
    var m = try h.Machine.init(.jit);
    defer m.deinit();
    var checker: recompiler.lockstep.Checker = .{ .stray = struct {
        // As if the engine had computed a RAM address the reference did not.
        fn f(cpu: *Cpu) void {
            cpu.regs[t0] = 0x1F80_1120; // timer 2: a device
        }
    }.f };
    m.bus.blocks.?.lockstep = &checker;
    h.poke(m.bus, 0x1000, &.{ mips.lw(t1, t0, 0), mips.nop, mips.beq(zero, zero, -1), mips.nop });
    m.cpu.regs[t0] = 0x8000_2000;
    m.start(0x8000_1000);
    _ = m.cpu.run();
    try std.testing.expectEqualStrings("io", checker.mismatch.?.what);
}
```

Run: `zig build test -Dtest-filter="jit"`. Expected: compile errors
(`ram_access_wait`, `stray`).

- [ ] **Step 2: `memory.zig`**

On `Bus`:

```zig
    /// The wait states every access to the first 2 MB of RAM costs, whatever
    /// its width or direction. The JIT's inline RAM path bills it too.
    pub const ram_access_wait: u32 = 4;
```

and in `waitCycles`, `Addr.ram_base...Addr.ram_last => 4,` becomes
`=> ram_access_wait,` (keep its comment).

- [ ] **Step 3: `lockstep.zig`: the "io" mismatch**

On `Checker`, after `fault`:

```zig
    /// Test seam: run on the restored machine right before the reference,
    /// to send it where the engine did not go. Never set outside a test.
    stray: ?*const fn (cpu: *Cpu) void = null,
```

In `execute`, after `pre.restore(cpu);`:

```zig
        if (self.stray) |s| s(cpu);
```

and the mismatch chain starts with the reference's own device access (the
engine's was already ruled out: such a block is skipped):

```zig
        // The engine touched no device, or the block was skipped above. A
        // reference that did went somewhere the engine did not, and has
        // already moved a device the machine keeps.
        self.mismatch = if (bus.io_accessed)
            .{ .what = "io" }
        else if (ref_ran != ran)
            ...
```

Add `"io"` to `Mismatch.what`'s doc list, with "(the reference touched a
device the engine did not)". In `run.zig`'s doc for lockstep nothing
changes.

- [ ] **Step 4: `lower_memory.zig` (loads)**

```zig
//! Loads and stores, inline for the first 2 MB of RAM and for the
//! scratchpad. Anything else (I/O, the BIOS, the RAM mirrors, which cost
//! other wait states) and any misaligned address takes the slow path: the
//! op's own `exec.zig` handler through `Bus`, after a commit, exactly as a
//! call would run it. An inline access bills what `Bus.waitCycles` would.
//!
//! No access here can meet an isolated cache: a block never runs while
//! SR.IsC is set (`run.zig`), and the MTC0 that sets it ends one.

const e = @import("emit.zig");
const t = @import("translate.zig");
const Bus = @import("../../memory.zig").Bus;
const Instruction = @import("../../cpu/exec.zig").Instruction;
const sext16 = @import("../../bits.zig").sext16;

/// Physical addresses below this are RAM's first 2 MB.
const ram_bits = 21;
const scratchpad_base: u32 = 0x1F80_0000;
const scratchpad_bytes = 0x400;

const Form = struct { op: e.MemReg, width: u3 };

/// False, having emitted nothing, for an op this file does not lower.
pub fn emitLoad(ctx: *t.Ctx) bool {
    const in = ctx.op().instr;
    const form: Form = switch (in.i.opcode) {
        0x20 => .{ .op = .ldrsb, .width = 1 },
        0x21 => .{ .op = .ldrsh, .width = 2 },
        0x23 => .{ .op = .ldr_w, .width = 4 },
        0x24 => .{ .op = .ldrb, .width = 1 },
        0x25 => .{ .op = .ldrh, .width = 2 },
        else => return false, // LWL, LWR
    };
    const em = ctx.em;
    const before = ctx.beginInline(in.i.rt, null);
    const slow = ctx.slowPath(before);
    const value = ctx.model.issued.?.value;
    const done = em.label();
    const not_ram = em.label();
    address(ctx, in, form.width, slow);
    em.branch(.{ .cbnz = .{ .w, .x11 } }, .{ .label = not_ram });
    em.put(e.memReg(form.op, value, t.ram_reg, .x10, false));
    em.put(e.addImm(.w, t.adjust_reg, t.adjust_reg, Bus.ram_access_wait));
    em.bind(done);
    ctx.endInline();
    em.bind(slow.back);

    em.section = .cold;
    em.bind(not_ram);
    scratchpadOffset(em, slow);
    em.put(e.memReg(form.op, value, t.scratch_reg, .x11, false));
    em.branch(.b, .{ .label = done });
    em.section = .hot;
    return true;
}

/// w9 the effective address, w10 its physical address, w11 the bits above
/// RAM's first 2 MB (zero for RAM). A misaligned address goes to `slow`.
pub fn address(ctx: *t.Ctx, in: Instruction, width: u3, slow: t.Slow) void {
    const em = ctx.em;
    const offset = sext16(in.i.imm);
    if (in.i.rs == 0) {
        em.movImm32(.x9, offset);
    } else {
        _ = ctx.src(in.i.rs, .x9);
        const signed: i32 = @bitCast(offset);
        if (signed > 0 and signed < 4096) {
            em.put(e.addImm(.w, .x9, .x9, @intCast(signed)));
        } else if (signed < 0 and signed > -4096) {
            em.put(e.subImm(.w, .x9, .x9, @intCast(-signed)));
        } else if (signed != 0) {
            em.movImm32(.x11, offset);
            em.put(e.addReg(.w, .x9, .x9, .x11));
        }
    }
    if (width >= 2) em.branch(.{ .tbnz = .{ .x9, 0 } }, .{ .label = slow.entry });
    if (width == 4) em.branch(.{ .tbnz = .{ .x9, 1 } }, .{ .label = slow.entry });
    em.put(e.ubfx(.x10, .x9, 0, 29));
    em.put(e.shiftImm(.lsr, .x11, .x10, ram_bits));
}

/// For a physical address in w10 outside RAM: w11 its scratchpad offset, or
/// a branch to `slow` when it is outside the scratchpad too.
pub fn scratchpadOffset(em: *t.Emitter, slow: t.Slow) void {
    em.put(e.movz(.w, .x11, scratchpad_base >> 16, 1));
    em.put(e.subReg(.w, .x11, .x10, .x11));
    em.put(e.cmpImm(.w, .x11, scratchpad_bytes));
    em.branch(.{ .cond = .hs }, .{ .label = slow.entry });
}
```

`translate.zig` must re-export the emitter type for this signature:
`pub const Emitter = emitter.Emitter;` (replace the private alias).

Why the slow path is right for every case the fast path refuses: the hot
code has written nothing when it branches there (the address is computed
into scratch registers, the value lands only on the RAM or scratchpad
path, the landed load retires after both), so `slowPath`'s call runs the
op from the state before it.

- [ ] **Step 5: Dispatch and the mask**

`Lowering` gains `load: bool = true` (also in `none` and `families`).
`translate.Family` gains `load`, `family` maps `0x20...0x26 => .load`, and
`emitOp` gains `.load => lower.load and lower_memory.emitLoad(ctx),`.

- [ ] **Step 6: Run the tests**

Run: `zig build test -Dtest-filter="jit"`, then `zig build test`.
Expected: PASS. The Task 3 test "a load lands around inline ops" now runs
inline loads and is this family's load-delay test.

- [ ] **Step 7: Gates and bench**

```bash
zig build
zig build trace-golden -Doptimize=ReleaseFast -- verify --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- savestate --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- lockstep --engine=jit
```

Expected as before; lockstep's skipped-for-MMIO counts should be close to
Plan 4's (a block that reads I/O through the slow path is still skipped).
Bench as in Task 2, Step 12.

- [ ] **Step 8: Format and commit**

```bash
zig fmt ps1-core/src ps1-core/tests/jit_test.zig
git add ps1-core/src ps1-core/tests/jit_test.zig
git commit -m "feat(jit): inline RAM and scratchpad loads; lockstep reports a reference that strays into I/O"
```

---

### Task 7: Inline stores, with the page's code bit

**Files:**
- Modify: `ps1-core/src/recompiler/arm64/lower_memory.zig`,
  `ps1-core/src/recompiler/arm64/translate.zig`, `ps1-core/src/recompiler/arm64/layout.zig`,
  `ps1-core/src/recompiler/jit.zig`, `ps1-core/src/recompiler/run.zig`
- Test: `ps1-core/tests/jit_test.zig`

**Interfaces:**
- Consumes: Task 6's `address`, `scratchpadOffset`.
- Produces: `lower_memory.emitStore(ctx) bool`; `translate.Options.store_fast`;
  `Lowering.store`.

- [ ] **Step 1: Write the failing tests**

```zig
test ".jit equals .cached: inline stores to RAM, a mirror and the scratchpad" {
    try expectSameRuns(&.{
        mips.lui(t0, 0x8000),
        mips.ori(t0, t0, 0x2000),
        mips.lui(t1, 0xA000),
        mips.ori(t1, t1, 0x2000),
        mips.lui(t2, 0x0020),
        mips.ori(t2, t2, 0x2000),
        mips.lui(t3, 0x1F80),
        mips.lui(t4, 0x1234),
        mips.ori(t4, t4, 0x5678),
        mips.sw(t4, t0, 0),
        mips.i(0x29, t1, t4, 6), // SH through KSEG1: the high half of the next word
        mips.i(0x28, t0, t4, 9), // SB: one byte lane
        mips.sw(t4, t2, 12), // the mirror: the slow path
        mips.sw(t4, t3, 8), // the scratchpad
        mips.i(0x28, t3, t4, 3),
        mips.sw(zero, t0, 16), // $zero stores zero
        mips.lw(t5, t0, 4),
        mips.lw(t6, t3, 8),
        mips.beq(zero, zero, -1),
        mips.nop,
    }, 0x8000_1000, 4);
}

test ".jit equals .cached: a store rewrites a block that already ran" {
    if (!jit.available) return error.SkipZigTest;
    const f = 0x8000_3000;
    const new = mips.addiu(t2, zero, 9);
    var p = try Pair.init(&.{
        mips.jal(f), // compile and run f
        mips.nop,
        mips.lui(t0, 0x8000),
        mips.ori(t0, t0, 0x3000),
        mips.lui(t1, @truncate(new >> 16)),
        mips.ori(t1, t1, @truncate(new)),
        mips.sw(t1, t0, 0), // f's page holds a block: the slow path drops it
        mips.jal(f),
        mips.nop,
        mips.beq(zero, zero, -1),
        mips.nop,
    }, 0x8000_1000);
    defer p.deinit();
    for ([_]*h.Machine{ &p.ref, &p.dut }) |m| h.poke(m.bus, 0x3000, &.{ mips.addiu(t2, zero, 1), mips.jr(h.ra), mips.nop });
    try p.expectSameRuns(12);
    try expectEqual(@as(u32, 9), p.dut.cpu.regs[t2]);
}

test ".jit equals .cached: misaligned stores fault from the inline path" {
    for ([_]u32{ mips.sw(t1, t0, 2), mips.i(0x29, t0, t1, 1) }) |store| {
        try expectSameRuns(&.{
            mips.lui(t0, 0x8000),
            mips.addiu(t1, zero, 5),
            store,
            mips.addu(t3, t1, zero),
            mips.beq(zero, zero, -1),
            mips.nop,
        }, 0x8000_1000, 3);
    }
}
```

Plus the structural check, as in Task 5:

```zig
test "a store is inline unless lockstep is checking" {
    if (!jit.available) return error.SkipZigTest;
    var m = try h.Machine.init(.jit);
    defer m.deinit();
    h.poke(m.bus, 0x1000, &.{ mips.sw(zero, zero, 0x2000), mips.beq(zero, zero, -2), mips.nop });
    m.start(0x8000_1000);
    _ = m.cpu.run();
    try expectEqual(@as(u32, 0), m.bus.blocks.?.lookup(0x1000).?.calls);
    var checker: recompiler.lockstep.Checker = .{};
    m.bus.blocks.?.lockstep = &checker;
    m.bus.blocks.?.flush();
    m.start(0x8000_1000);
    _ = m.cpu.run();
    // Lockstep's journal sees only stores through `Bus.write`.
    try expectEqual(@as(u32, 1), m.bus.blocks.?.lookup(0x1000).?.calls);
}
```

Run: `zig build test -Dtest-filter="jit"`. Expected: the structural test
fails (the store is a call both ways) and the others pass.

- [ ] **Step 2: `layout.zig`**

In the `comptime` block:

```zig
    // A store's page test indexes `has_code` from x22 itself.
    std.debug.assert(@offsetOf(Pins, "has_code") == 0);
```

- [ ] **Step 3: `emitStore`**

```zig
/// False, having emitted nothing, for an op this file does not lower.
pub fn emitStore(ctx: *t.Ctx) bool {
    // Lockstep's journal records the old word under every RAM store, and
    // sees only stores through `Bus.write`.
    if (!ctx.opts.store_fast) return false;
    const in = ctx.op().instr;
    const form: Form = switch (in.i.opcode) {
        0x28 => .{ .op = .strb, .width = 1 },
        0x29 => .{ .op = .strh, .width = 2 },
        0x2B => .{ .op = .str_w, .width = 4 },
        else => return false, // SWL, SWR
    };
    const em = ctx.em;
    const before = ctx.beginInline(null, null);
    const slow = ctx.slowPath(before);
    const done = em.label();
    const not_ram = em.label();
    address(ctx, in, form.width, slow);
    em.branch(.{ .cbnz = .{ .w, .x11 } }, .{ .label = not_ram });
    // A page holding a block: the slow path's `Bus.write` drops its blocks,
    // and ends this one if it was among them.
    em.put(e.shiftImm(.lsr, .x11, .x10, block.page_shift));
    em.put(e.shiftImm(.lsr, .x12, .x11, 6));
    em.put(e.memReg(.ldr_x, .x12, t.pins_reg, .x12, true));
    em.put(e.shiftReg(.x, .lsr, .x12, .x12, .x11));
    em.branch(.{ .tbnz = .{ .x12, 0 } }, .{ .label = slow.entry });
    em.put(e.memReg(form.op, ctx.src(in.i.rt, .x13), t.ram_reg, .x10, false));
    em.put(e.addImm(.w, t.adjust_reg, t.adjust_reg, Bus.ram_access_wait));
    em.bind(done);
    ctx.endInline();
    em.bind(slow.back);

    em.section = .cold;
    em.bind(not_ram);
    scratchpadOffset(em, slow);
    em.put(e.memReg(form.op, ctx.src(in.i.rt, .x13), t.scratch_reg, .x11, false));
    em.branch(.b, .{ .label = done });
    em.section = .hot;
    return true;
}
```

Import `block` (`const block = @import("../block.zig");`). A store's
value is read after the address, from `cpu.regs`: the landed load (if any)
retires only at `endInline`, so a store of the register a load is landing
in stores the old value, as the interpreter does.

- [ ] **Step 4: Options, dispatch, mask**

`translate.Options` gains

```zig
    /// Stores take the inline RAM path. Off while lockstep is checking.
    store_fast: bool,
```

and `run.compileBlock` sets `.store_fast = c.lockstep == null`. `Lowering`
gains `store: bool = true` (in `none` and `families`), `Family` gains
`store`, `family` maps `0x28...0x2B, 0x2E => .store`, and `emitOp` gains
`.store => lower.store and lower_memory.emitStore(ctx),`. The
`lockstep checks JIT blocks` test attaches the checker before the first
compile, which is the rule: a harness attaches lockstep before running.

- [ ] **Step 5: Run the tests**

Run: `zig build test -Dtest-filter="jit"`, then `zig build test`.
Expected: PASS. Plan 4's `a store into the running block` and `an MMIO
store ends the block and ticks SIO` are now this family's invalidation and
`block_exit` tests.

- [ ] **Step 6: Gates and bench**

```bash
zig build
zig build trace-golden -Doptimize=ReleaseFast -- verify --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- savestate --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- lockstep --engine=jit
```

Bench as in Task 2, Step 12.

- [ ] **Step 7: Format and commit**

```bash
zig fmt ps1-core/src/recompiler ps1-core/tests/jit_test.zig
git add ps1-core/src/recompiler ps1-core/tests/jit_test.zig
git commit -m "feat(jit): inline RAM and scratchpad stores behind the page's code bit"
```

---

### Task 8: Direct block linking and `Cpu.runFor`

A block that ends in a direct branch leaves through one `bl` per outcome.
Unlinked, the `bl` reaches the relink stub, which records the site and
returns to the dispatcher; the dispatcher's next lookup rewrites the site to
`bl` the target's linked entry. From then on the two run back to back
inside one `runFor` call, while the budget and the deadline allow.

**Files:**
- Create: `ps1-core/src/recompiler/arm64/link.zig`
- Modify: `ps1-core/src/recompiler/arm64/translate.zig`,
  `ps1-core/src/recompiler/arm64/lower_branch.zig`,
  `ps1-core/src/recompiler/arm64/layout.zig`,
  `ps1-core/src/recompiler/arm64/code_buffer.zig`,
  `ps1-core/src/recompiler/jit.zig`, `ps1-core/src/recompiler/cache.zig`,
  `ps1-core/src/recompiler/block.zig`, `ps1-core/src/recompiler/run.zig`,
  `ps1-core/src/cpu/cpu.zig`
- Modify: `ps1-golden/src/main.zig`, `ps1-golden/src/script.zig`, `ps1-bench/main.zig`
- Test: `ps1-core/tests/jit_test.zig`

**Interfaces:**
- Consumes: Tasks 5-7.
- Produces:
  - `Cpu.runFor(budget: u32) u32`; `run()` is `runFor(1)`.
    `recompiler.run(cpu, c, budget)`.
  - `Pins.downcount: *const i64`, `Pins.link_site: ?[*]u32`,
    `Pins.budget: u32`, `Pins.link_pc: u32`; their `layout.pins_*` offsets.
  - `Block.link_entry: ?[*]u32`.
  - `Jit.relink_stub`, `Jit.links` (patches made), `Jit.link(site,
    entry)`, `Jit.unlink(b)`; `CodeBuffer.patch(at, word)`.
  - `translate.Exit` (`none`, `direct: {taken, not_taken: ?u32}`,
    `indirect`), `Ctx.exit`, `Ctx.relink_stub`, `Ctx.body`.
  - `link.relink_stub: [4]u32`, `link.isLinkPc(pc)`, `link.entry(ctx)`,
    `link.exits(ctx)`.
  - `Lowering.link`.
  - `script.Pad.next() u64`.

- [ ] **Step 1: Write the failing tests**

In `jit_test.zig`, after `Pair`:

```zig
/// `dut` runs one `runFor(budget)`; `ref` calls `run()` until it has run as
/// many steps. It must land exactly there, and must not pass `budget` on
/// the way: a chain stops at the first block end at or past its budget.
/// Returns the steps the call ran.
fn expectSameLinked(p: *Pair, budget: u32) !u32 {
    const k = p.dut.cpu.runFor(budget);
    var n: u32 = 0;
    while (n < k) {
        if (n >= budget) return error.ChainOverran;
        n += p.ref.cpu.run();
    }
    try expectEqual(k, n);
    try h.expectSameMachine(&p.ref, &p.dut);
    return k;
}
```

Tests:

```zig
test "linked: blocks run back to back inside one runFor, as one block per run would" {
    if (!jit.available) return error.SkipZigTest;
    var p = try Pair.init(&h.loop_program, 0x8000_1000);
    defer p.deinit();
    var most: u32 = 0;
    for ([_]u32{ 1, 1, 1, 7, 100, 3, 100_000, 50, 100_000, 100_000 }) |budget| most = @max(most, try expectSameLinked(&p, budget));
    try expect(most > h.loop_program.len); // a chain ran more than one block
    // The spin loop at the end is linked to itself: with no budget to stop
    // it, the chain ends when a device is due.
    try expect(try expectSameLinked(&p, 1_000_000) < 1_000_000);
}

test "linked: a store that rewrites a linked block runs the new code" {
    if (!jit.available) return error.SkipZigTest;
    const b_pc = 0x8000_2000;
    const base = mips.addiu(t1, t1, 0);
    var p = try Pair.init(&.{
        mips.lui(t0, 0x8000),
        mips.ori(t0, t0, 0x2000), // B
        mips.lui(t3, @truncate(base >> 16)),
        mips.ori(t3, t3, @truncate(base)),
        mips.addiu(t4, zero, 20),
        mips.nop,
        mips.addiu(t3, t3, 1), // 0x1018 loop: B's next immediate
        mips.sw(t3, t0, 0), // rewrites B, which the jump below links to
        mips.j(b_pc),
        mips.nop,
    }, 0x8000_1000);
    defer p.deinit();
    for ([_]*h.Machine{ &p.ref, &p.dut }) |m| h.poke(m.bus, 0x2000, &.{
        base, // rewritten every iteration
        mips.addiu(t4, t4, 0xFFFF),
        mips.bne(t4, zero, -1021), // -> loop
        mips.nop,
        mips.beq(zero, zero, -1),
        mips.nop,
    });
    for (0..80) |_| _ = try expectSameLinked(&p, 1000);
    try expectEqual(@as(u32, 210), p.dut.cpu.regs[h.t1]); // 1 + 2 + ... + 20
    try expect(p.dut.bus.blocks.?.jit.?.links > 20); // relinked after each rewrite
}

test "linked: a host write into a linked block's page" {
    if (!jit.available) return error.SkipZigTest;
    var p = try Pair.init(&h.loop_program, 0x8000_1000);
    defer p.deinit();
    for (0..12) |_| _ = try expectSameLinked(&p, 100_000);
    // Through `Bus.write`, the path every DMA word takes: the spin loop,
    // linked to itself, becomes a jump back to the start.
    for ([_]*h.Machine{ &p.ref, &p.dut }) |m| h.poke(m.bus, 0x1048, &.{mips.j(0x8000_1000)});
    for (0..24) |_| _ = try expectSameLinked(&p, 100_000);
}

test "linked: a full code buffer drops a pending link site" {
    if (!jit.available) return error.SkipZigTest;
    // Eight blocks of 62 MFLO calls in a ring, about 3 KB of code each,
    // through a 16 KB buffer: it fills and flushes while exits wait to be
    // linked.
    const ring = comptime blk: {
        var words: [8 * 64]u32 = undefined;
        for (0..8) |k| {
            for (0..62) |w| words[k * 64 + w] = mips.mflo(t0);
            words[k * 64 + 62] = mips.j(0x8000_1000 + @as(u32, @intCast((k + 1) % 8)) * 256);
            words[k * 64 + 63] = mips.nop;
        }
        break :blk words;
    };
    var p = try Pair.init(&ring, 0x8000_1000);
    defer p.deinit();
    const c = p.dut.bus.blocks.?;
    c.jit.?.destroy(alloc);
    c.jit = try jit.Jit.create(alloc, 16 << 10);
    var flushed = false;
    var high: usize = 0;
    for (0..40) |k| {
        _ = try expectSameLinked(&p, if (k % 3 == 0) 1 else 1000);
        if (c.jit.?.buf.used < high) flushed = true;
        high = c.jit.?.buf.used;
    }
    try expect(flushed);
}

fn countChar(context: ?*anyopaque, char: u8) void {
    _ = char;
    const n: *u32 = @ptrCast(@alignCast(context.?));
    n.* += 1;
}

test "linked: the TTY hook still fires on every call through 0xB0" {
    if (!jit.available) return error.SkipZigTest;
    var p = try Pair.init(&.{
        mips.addiu(t1, zero, 0x3D), // B0 putchar
        mips.addiu(h.a0, zero, 'x'),
        mips.jal(0x8000_00B0), // 2: loop
        mips.nop,
        mips.beq(zero, zero, -3), // -> 2
        mips.nop,
    }, 0x8000_1000);
    defer p.deinit();
    var counts: [2]u32 = .{ 0, 0 };
    for ([_]*h.Machine{ &p.ref, &p.dut }, &counts) |m, *n| {
        h.poke(m.bus, 0xB0, &.{ mips.jr(h.ra), mips.nop });
        m.cpu.tty_context = n;
        m.cpu.tty_write_fn = countChar;
    }
    for (0..30) |_| _ = try expectSameLinked(&p, 1000);
    try expectEqual(counts[0], counts[1]);
    try expect(counts[0] > 5);
}
```

And the linked fuzzer, after the existing one:

```zig
test "fuzz: linked .jit equals .cached, each program run twice" {
    if (!jit.available) return error.SkipZigTest;
    var p: Pair = .{ .ref = try h.Machine.init(.cached), .dut = undefined };
    defer p.ref.deinit();
    p.dut = try h.Machine.init(.jit);
    defer p.dut.deinit();
    var chained = false;
    for (0..fuzz.programs) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();
        const words = fuzz.program(rng);
        const state = fuzz.State.random(rng);
        state.apply(&p.ref, &words);
        state.apply(&p.dut, &words);
        // The first pass compiles and records the exits; the second, from
        // the same state over the same code, runs them linked.
        for (0..2) |pass| {
            if (pass == 1) {
                state.restart(&p.ref);
                state.restart(&p.dut);
            }
            for (0..fuzz.runs) |run_index| {
                errdefer std.debug.print("linked fuzz: seed {d}, pass {d}, run {d}\n", .{ seed, pass, run_index });
                const k = try expectSameLinked(&p, rng.intRangeAtMost(u32, 1, 256));
                // More steps than one block holds: a chain ran.
                if (k > block.max_len + 1) chained = true;
            }
        }
    }
    try expect(chained);
}
```

with, in `fuzz.State`, `apply` split so the second pass skips the code:

```zig
        /// The CPU and the data window as `apply` sets them, over code
        /// already in place: its blocks, and their links, survive.
        fn restart(s: *const State, m: *h.Machine) void {
            m.cpu = Cpu.init(m.bus);
            m.cpu.regs = s.regs;
            m.cpu.hi = s.hi;
            m.cpu.lo = s.lo;
            m.cpu.cop0.writeReg(.sr, 1 << 30); // CU2: the GTE ops run instead of faulting
            // On no code page, so a host copy needs no invalidation.
            @memcpy(m.bus.ram[data_base..][0..data_bytes], &s.data);
            m.start(s.pc);
        }

        fn apply(s: *const State, m: *h.Machine, words: []const u32) void {
            h.poke(m.bus, 0x80, &.{ mips.beq(zero, zero, -1), mips.nop });
            h.poke(m.bus, base, words); // through Bus.write: drops the last program's blocks
            s.restart(m);
        }
```

In `ps1-golden/src/script.zig`:

```zig
test "next names the first count at which the pad can change" {
    var p = Pad{};
    try std.testing.expectEqual(@as(u64, 0), p.next());
    _ = p.maskAt(0);
    try std.testing.expectEqual(hold, p.next());
    _ = p.maskAt(hold);
    try std.testing.expectEqual(rotation_period, p.next());

    const items = try parse(std.testing.allocator, "1:cross");
    defer std.testing.allocator.free(items);
    var s = Pad{ .script = items };
    try std.testing.expectEqual(@as(u64, 1_000_000), s.next());
    _ = s.maskAt(1_000_000);
    try std.testing.expectEqual(1_000_000 + hold, s.next());
}
```

Run: `zig build test -Dtest-filter="linked"` and
`zig build test -Dtest-filter="next names"`. Expected: compile errors
(`runFor`, `links`, `restart`, `next`).

- [ ] **Step 2: `cpu.zig`: `runFor`**

Replace `run` with:

```zig
    /// One unit of work for a frame loop: a block under a block engine,
    /// one instruction under the interpreter. Returns the `step()` calls it
    /// stands for (instructions, DMA words and interrupt entries), the unit
    /// every frontend keeps its instruction budget and schedules in.
    pub fn run(self: *Self) u32 {
        return self.runFor(1);
    }

    /// `run()`, but `.jit` may run linked blocks back to back inside one
    /// call. It stops at the first block end at or past `budget` steps, or
    /// when a device is due: exactly where calling `run()` until that many
    /// steps had run would have stopped. So a frontend that acts between
    /// calls by step count (ps1-golden's samples and pad) passes its next
    /// event as the budget and sees the same machine either way.
    pub fn runFor(self: *Self, budget: u32) u32 {
        // Never inlined: the dispatcher's frame and register saves would
        // otherwise be paid before this test, on the interpreter path too.
        if (self.bus.blocks) |c| return @call(.never_inline, recompiler.run, .{ self, c, budget });
        self.step();
        return 1;
    }
```

- [ ] **Step 3: `Pins`, `Block.link_entry`, `layout`, `CodeBuffer.patch`**

`Pins` gains, after `running`:

```zig
    /// `Bus.sched.downcount`: a linked block starts only while it is positive.
    downcount: *const i64,
    /// Where `link.relink_stub` left the exit that reached it. The
    /// dispatcher's next lookup rewrites that exit to jump straight to the
    /// block at `link_pc` (`run.relink`).
    link_site: ?[*]u32 = null,
    /// This call's step budget (`Cpu.runFor`): a linked block starts only
    /// while fewer steps than this have run.
    budget: u32 = 1,
    link_pc: u32 = 0,
```

and `create` sets `.downcount = &bus.sched.downcount`. `flush` adds
`self.pins.link_site = null;` beside `running`.

`Block` gains, after `code_words`:

```zig
    /// Where another block's exit may jump straight in (`arm64/link.zig`),
    /// null for a block no exit may link to. Dropping the block rewrites
    /// its first word to send such a jump back to the dispatcher.
    link_entry: ?[*]u32 = null,
```

`layout.zig`:

```zig
pub const pins_running = @offsetOf(Pins, "running");
pub const pins_downcount = @offsetOf(Pins, "downcount");
pub const pins_link_site = @offsetOf(Pins, "link_site");
pub const pins_budget = @offsetOf(Pins, "budget");
pub const pins_link_pc = @offsetOf(Pins, "link_pc");
```

`code_buffer.zig`:

```zig
    /// Rewrites one installed word: a link, or an unlink.
    pub fn patch(self: *CodeBuffer, at: [*]u32, word: u32) void {
        _ = self;
        pthread_jit_write_protect_np(0);
        at[0] = word;
        pthread_jit_write_protect_np(1);
        sys_icache_invalidate(at, 4);
    }
```

A patch can run while emitted code is on the stack (a store's slow path
drops a block): the write window is per thread and this thread is in Zig
at that moment, so the toggle is safe.

- [ ] **Step 4: `link.zig`**

```zig
//! Block linking. A block that ends in a direct branch leaves through one
//! `bl` per outcome. Unlinked, the `bl` reaches `relink_stub`, which
//! records it and returns to the dispatcher; the dispatcher's next lookup
//! rewrites it to `bl` the target block's linked entry (`run.relink`), and
//! from then on the two blocks run back to back inside one `Cpu.runFor`.
//!
//! Skipping the dispatcher changes nothing it would have seen. A linked
//! block starts only while `downcount > 0` and fewer steps than the
//! budget have run, which is when the dispatcher would have started it
//! next. In between, interrupt state changes only at a device sync (an
//! MMIO access, which zeroes `downcount`) or at an MTC0 or RFE, and a block
//! holding either never links out. A DMA stall starts only at an MMIO
//! store or a deadline; SR.IsC only at an MTC0; and a block at 0xA0 or
//! 0xB0, whose TTY hook only the dispatcher runs, is never linked to.

const block = @import("../block.zig");
const e = @import("emit.zig");
const t = @import("translate.zig");
const layout = @import("layout.zig");

/// Installed once, right before `translate.return_stub`, which it falls
/// into: records the `bl` that came here and the PC it was leaving for.
pub const relink_stub = [_]u32{
    e.subImm(.x, .x9, .lr, 4),
    e.memImm(.str_x, .x9, t.pins_reg, layout.pins_link_site),
    e.memImm(.ldr_w, .x9, t.cpu_reg, layout.pc),
    e.memImm(.str_w, .x9, t.pins_reg, layout.pins_link_pc),
};

/// A PC a block may link to: RAM entered through KUSEG or KSEG0, whose
/// fetch cost is the cached-hit 0, the same for every block that links;
/// and never 0xA0 or 0xB0.
pub fn isLinkPc(pc: u32) bool {
    const phys = pc & 0x1FFF_FFFF;
    return pc < 0xA000_0000 and block.regionOf(phys) == .ram and phys != 0xA0 and phys != 0xB0;
}

/// The block's linked entry, in the cold section, ending in a branch to
/// `ctx.body`. Its first word is the one `Jit.unlink` rewrites.
pub fn entry(ctx: *t.Ctx) t.Label {
    const em = ctx.em;
    const l = em.label();
    em.section = .cold;
    em.bind(l);
    em.put(e.memImm(.ldr_w, .x9, t.pins_reg, layout.pins_budget));
    em.put(e.cmpReg(.w, t.ran_reg, .x9));
    em.branch(.{ .cond = .hs }, .{ .address = ctx.return_stub });
    em.put(e.memImm(.ldr_x, .x9, t.pins_reg, layout.pins_downcount));
    em.put(e.memImm(.ldr_x, .x9, .x9, 0));
    em.put(e.cmpImm(.x, .x9, 0));
    em.branch(.{ .cond = .le }, .{ .address = ctx.return_stub });
    em.movImm64(.x9, @intFromPtr(ctx.b));
    em.put(e.memImm(.str_x, .x9, t.pins_reg, layout.pins_running));
    em.branch(.b, .{ .label = ctx.body });
    em.section = .hot;
    return l;
}

/// Whether this block's exits may link: the lowering allows it, the block
/// links at all, its delay slot leaves no load in flight (inline code
/// cannot take one over; `jit.execute`), and it holds no COP0 op.
fn exitsLink(ctx: *const t.Ctx) bool {
    if (!ctx.opts.lower.link or !isLinkPc(ctx.b.start_pc)) return false;
    if (block.issuesLoad(ctx.b.ops[ctx.b.ops.len - 1].instr.raw) != null) return false;
    for (ctx.b.ops) |op| if (op.instr.i.opcode == 0x10) return false;
    return true;
}

/// The block's normal end, after the final commit: where it goes next.
pub fn exits(ctx: *t.Ctx) void {
    const em = ctx.em;
    switch (ctx.exit) {
        .direct => |d| if (exitsLink(ctx)) {
            const nt = d.not_taken orelse return site(ctx, d.taken);
            const not_taken = em.label();
            em.put(e.memImm(.ldr_w, .x9, t.cpu_reg, layout.pc));
            em.movImm32(.x10, d.taken);
            em.put(e.cmpReg(.w, .x9, .x10));
            em.branch(.{ .cond = .ne }, .{ .label = not_taken });
            site(ctx, d.taken);
            em.bind(not_taken);
            site(ctx, nt);
            return;
        },
        .indirect, .none => {},
    }
    em.branch(.b, .{ .address = ctx.return_stub });
}

/// One exit to a known PC: a `bl` the dispatcher rewrites to reach the
/// target's linked entry, or a plain return when it can never link.
fn site(ctx: *t.Ctx, target: u32) void {
    if (isLinkPc(target)) {
        ctx.em.branch(.bl, .{ .address = ctx.relink_stub });
    } else {
        ctx.em.branch(.b, .{ .address = ctx.return_stub });
    }
}
```

- [ ] **Step 5: `translate.zig`: exits, the body label, the entry**

Re-export the label type (`pub const Label = emitter.Label;`) and add:

```zig
/// How a block's normal end leaves it, for linking (`link.zig`).
pub const Exit = union(enum) {
    none,
    direct: struct { taken: u32, not_taken: ?u32 },
    indirect,
};
```

`Ctx` gains `relink_stub: usize`, `exit: Exit = .none`, and
`body: emitter.Label` (where a linked entry joins the prologue). In
`compile`: initialise `.relink_stub = j.relink_stub, .body = em.label()`,
and after `end(&ctx)`:

```zig
    const link_entry = if (opts.lower.link and link.isLinkPc(b.start_pc)) link.entry(&ctx) else null;
    const at = j.buf.cursor();
    const code = em.finish(at);
    const entry: block.JitEntry = @ptrCast(try j.buf.install(code));
    b.code = entry;
    b.code_words = @intCast(code.len);
    b.calls = ctx.calls;
    b.link_entry = if (link_entry) |l| @ptrFromInt(em.addressOf(l, at)) else null;
```

In `prologue`, bind the body between the per-call and per-block parts:

```zig
    em.put(e.movz(.w, ran_reg, 0, 0));
    // Everything above holds for the whole call, everything below for this
    // block; a linked entry joins here.
    em.bind(ctx.body);
```

In `end`, the normal path's `em.branch(.b, .{ .address = ctx.return_stub });`
becomes `link.exits(ctx);` (the stop tail keeps its plain return).

- [ ] **Step 6: `lower_branch.zig` records the exit**

In `conditional`, before `ctx.endBranch(.x10)`:

```zig
    ctx.exit = .{ .direct = .{ .taken = taken, .not_taken = not_taken } };
```

in `jump`: `ctx.exit = .{ .direct = .{ .taken = target, .not_taken = null } };`
and in `register`: `ctx.exit = .indirect;`.

- [ ] **Step 7: `jit.zig`: stubs, link, unlink, the mask**

`Lowering` gains `link: bool = true` (in `none` and `families`). `Jit`:

```zig
    /// Where an unlinked exit goes: records itself for `run.relink`, then
    /// falls into `return_stub`.
    relink_stub: usize = 0,
    /// Exits rewritten to jump straight to a block. For tests and the bench.
    links: u32 = 0,
```

`create` installs both stubs as one run of words:

```zig
        // A fresh buffer has room for the stubs. The relink stub falls
        // through into the return stub, so they go in together.
        const stubs = translate.link.relink_stub ++ translate.return_stub;
        j.relink_stub = @intFromPtr(j.buf.install(&stubs) catch unreachable);
        j.return_stub = j.relink_stub + translate.link.relink_stub.len * 4;
        j.buf.pin();
```

(`translate.zig` exposes `pub const link = @import("link.zig");`.)

```zig
    /// Rewrites the exit at `site` to jump straight to `entry`.
    pub fn link(j: *Jit, site: [*]u32, entry: [*]u32) void {
        j.buf.patch(site, emit.bl(@intCast(@as(i64, @intCast(@intFromPtr(entry))) - @as(i64, @intCast(@intFromPtr(site))))));
        j.links += 1;
    }

    /// Sends every jump into a dropped block's linked entry to the relink
    /// stub: the exit that made it records itself, and the dispatcher links
    /// it to whatever block is compiled there next.
    pub fn unlink(j: *Jit, b: *const block.Block) void {
        const entry = b.link_entry orelse return;
        j.buf.patch(entry, emit.b(@intCast(@as(i64, @intCast(j.relink_stub)) - @as(i64, @intCast(@intFromPtr(entry))))));
    }
```

`unlink` uses `b`, not `bl`: the exit's own `bl` already left its address
in x30, which the relink stub reads.

- [ ] **Step 8: `cache.zig`: unlink on drop**

At the top of `drop`:

```zig
        if (comptime jit.available) {
            if (self.jit) |j| j.unlink(b);
        }
```

`flush` must not unlink (the buffer resets anyway): it frees blocks
directly, which it already does.

- [ ] **Step 9: `run.zig`: the budget and relinking**

`run` takes the budget and passes it through `Pins`:

```zig
pub fn run(cpu: *Cpu, c: *BlockCache, budget: u32) u32 {
```

after `blockAt`:

```zig
    if (comptime jit.available) relink(c, b, pc);
```

and before executing the block:

```zig
    // Lockstep checks one block at a time; a budget of 1 refuses every link.
    c.pins.budget = if (c.lockstep != null) 1 else budget;
    c.pins.running = b;
```

```zig
/// Links the exit that last reached the relink stub, if it was leaving for
/// `pc`, to `b`. An exit recorded before a flush was forgotten with it.
fn relink(c: *BlockCache, b: *const block.Block, pc: u32) void {
    const site = c.pins.link_site orelse return;
    c.pins.link_site = null;
    const entry = b.link_entry orelse return;
    if (c.pins.link_pc != pc) return;
    c.jit.?.link(site, entry);
}
```

`run`'s doc comment gains: "Under `.jit`, linked blocks may follow it
inside the same call, up to `budget` steps (`Cpu.runFor`)."

- [ ] **Step 10: The frontends**

`ps1-bench/main.zig`: both frame-loop lines call
`cpu.runFor(std.math.maxInt(u32))`.

`ps1-golden/src/script.zig`, on `Pad`:

```zig
    /// The first count at which `maskAt` can return a mask. A linked chain
    /// stops there (`Cpu.runFor`), as one block per call would.
    pub fn next(p: *const Pad) u64 {
        if (p.script.len > 0) {
            const press = if (p.idx < p.script.len) p.script[p.idx].at else std.math.maxInt(u64);
            return @min(press, p.release orelse std.math.maxInt(u64));
        }
        return @min(p.press_at.next, p.release_at.next);
    }
```

`ps1-golden/src/main.zig`, in `runWorkload`'s loop (verify, capture and
savestate run through it):

```zig
    while (i < opts.instructions) {
        if (pad.maskAt(i)) |m| bus.sio.setButtons(m);
        // Every event this loop acts on is a step count. A linked chain stops
        // at the first block end at or past the next one, where one block
        // per call would have stopped too.
        const next = @min(opts.instructions, @min(sample_at.next, pad.next()));
        i += cpu.runFor(@intCast(@min(next - i, std.math.maxInt(u32))));
```

The other runners keep `run()`.

- [ ] **Step 11: Run the tests**

Run: `zig build test -Dtest-filter="linked"`, then
`zig build test -Dtest-filter="fuzz"`, then `zig build test`.
Expected: PASS. Sabotage once: make `link.entry` skip its `downcount`
check (delete the four words) and confirm the first linked test fails with
`ChainOverran` or a machine difference; revert.

- [ ] **Step 12: Gates and bench**

```bash
zig build
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- verify --engine=cached
zig build trace-golden -Doptimize=ReleaseFast -- verify --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- savestate --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- lockstep --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- verify --engine=jit --jit-lower=alu,branch,load,store
```

Expected: OK on all nine everywhere (the last run is linking off, as a
control); lockstep 0 mismatches. `verify --engine=jit` now runs linked
chains between samples: if it fails and the control passes, linking is
the cause. Bench as in Task 2, Step 12.

- [ ] **Step 13: Format and commit**

```bash
zig fmt ps1-core/src ps1-core/tests/jit_test.zig ps1-golden/src ps1-bench
git add ps1-core/src ps1-core/tests/jit_test.zig ps1-golden/src ps1-bench
git commit -m "feat(jit): link blocks through direct branches; Cpu.runFor chains them"
```

---

### Task 9: Jumps through a register look their target up inline

**Files:**
- Modify: `ps1-core/src/recompiler/arm64/link.zig`, `ps1-core/src/recompiler/arm64/layout.zig`,
  `ps1-core/src/recompiler/cache.zig`
- Test: `ps1-core/tests/jit_test.zig`

**Interfaces:**
- Consumes: Task 8's `exits`, `exitsLink`, `link_entry`.
- Produces: `Pins.ram_blocks: [*]?*Block`; `layout.pins_ram_blocks`,
  `layout.block_start_pc`, `layout.block_link_entry`.

- [ ] **Step 1: Write the failing tests**

```zig
test "linked: a return through $ra jumps straight to the caller's block" {
    if (!jit.available) return error.SkipZigTest;
    const at = 0x8000_1000;
    var p = try Pair.init(&.{
        mips.addiu(t4, zero, 50),
        mips.jal(at + 8 * 4), // 1: loop, call f
        mips.nop,
        mips.addiu(t4, t4, 0xFFFF), // 3: f returns here
        mips.bne(t4, zero, -4), // -> 1
        mips.nop,
        mips.beq(zero, zero, -1),
        mips.nop,
        mips.addiu(t5, t5, 1), // 8: f
        mips.jr(h.ra),
        mips.nop,
    }, at);
    defer p.deinit();
    var most: u32 = 0;
    for (0..20) |_| most = @max(most, try expectSameLinked(&p, 1000));
    // A chain crossed the return: more than call, body and return alone.
    try expect(most > 12);
}

test "linked: a jump through a register refuses KSEG1, a mirror and a block compiled for another address" {
    if (!jit.available) return error.SkipZigTest;
    // f is word 18, 0x1048. The same RAM is called three ways each time
    // round, so its one table slot holds a block compiled for another of
    // them at every call.
    var p = try Pair.init(&.{
        mips.lui(t5, 0xA000),
        mips.ori(t5, t5, 0x1048), // f through KSEG1: never linked
        mips.lui(t6, 0x8000),
        mips.ori(t6, t6, 0x1048), // f through KSEG0
        mips.lui(h.k0, 0x8020),
        mips.ori(h.k0, h.k0, 0x1048), // f through the mirror at 2 MB
        mips.addiu(t4, zero, 3),
        mips.jalr(h.ra, t5), // 7: loop
        mips.nop,
        mips.jalr(h.ra, t6),
        mips.nop,
        mips.jalr(h.ra, h.k0),
        mips.nop,
        mips.addiu(t4, t4, 0xFFFF),
        mips.bne(t4, zero, -8), // 14: -> 7, counted from the delay slot at 15
        mips.nop,
        mips.beq(zero, zero, -1),
        mips.nop,
        mips.addiu(t7, t7, 1), // 18: f
        mips.jr(h.ra),
        mips.nop,
    }, 0x8000_1000);
    defer p.deinit();
    for (0..60) |_| _ = try expectSameLinked(&p, 1000);
    try expectEqual(@as(u32, 9), p.dut.cpu.regs[t7]); // three calls, three times
}
```

Run: `zig build test -Dtest-filter="linked"`. Expected: the first test
fails its `most > 12` (returns go through the dispatcher); the second
passes (it is the refusal test).

- [ ] **Step 2: `Pins.ram_blocks` and the offsets**

`Pins` gains, after `downcount`:

```zig
    /// The RAM table, which a jump through a register looks its target up in.
    ram_blocks: [*]?*Block,
```

set in `create` after the table is allocated (`.ram_blocks = ram.ptr`).
`layout.zig`:

```zig
const Block = @import("../block.zig").Block;
pub const pins_ram_blocks = @offsetOf(Pins, "ram_blocks");
pub const block_start_pc = @offsetOf(Block, "start_pc");
pub const block_link_entry = @offsetOf(Block, "link_entry");
```

- [ ] **Step 3: The lookup in `link.exits`**

The `.indirect` arm:

```zig
        .indirect => if (exitsLink(ctx)) return lookup(ctx),
```

```zig
/// JR, JALR: the target block from the RAM table, entered at its linked
/// entry if it has one and was compiled for exactly this PC; otherwise the
/// dispatcher. A dropped block is never found: dropping clears its slot.
fn lookup(ctx: *t.Ctx) void {
    const em = ctx.em;
    const out: t.Target = .{ .address = ctx.return_stub };
    em.put(e.memImm(.ldr_w, .x9, t.cpu_reg, layout.pc));
    em.put(e.shiftImm(.lsr, .x10, .x9, 29));
    em.put(e.cmpImm(.w, .x10, 5)); // KSEG1 and above
    em.branch(.{ .cond = .hs }, out);
    em.put(e.ubfx(.x10, .x9, 0, 29));
    em.put(e.shiftImm(.lsr, .x11, .x10, 23)); // past RAM and its mirrors
    em.branch(.{ .cbnz = .{ .w, .x11 } }, out);
    em.put(e.ubfx(.x11, .x10, 2, 19)); // the word within 2 MB
    em.put(e.memImm(.ldr_x, .x10, t.pins_reg, layout.pins_ram_blocks));
    em.put(e.memReg(.ldr_x, .x10, .x10, .x11, true));
    em.branch(.{ .cbz = .{ .x, .x10 } }, out);
    em.put(e.memImm(.ldr_w, .x11, .x10, layout.block_start_pc));
    em.put(e.cmpReg(.w, .x11, .x9));
    em.branch(.{ .cond = .ne }, out);
    em.put(e.memImm(.ldr_x, .x10, .x10, layout.block_link_entry));
    em.branch(.{ .cbz = .{ .x, .x10 } }, out);
    em.put(e.br(.x10));
}
```

(`translate.zig` re-exports `pub const Target = emitter.Target;`.) A block
at 0xA0 or 0xB0, or outside the cached segment, has no linked entry, so
`cbz` on it sends the jump to the dispatcher, which runs the TTY hook.

- [ ] **Step 4: Run the tests**

Run: `zig build test -Dtest-filter="linked"`, then `zig build test`.
Expected: PASS.

- [ ] **Step 5: Gates and bench**

```bash
zig build
zig build trace-golden -Doptimize=ReleaseFast -- verify --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- savestate --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- lockstep --engine=jit
```

Bench as in Task 2, Step 12, and once more with `--jit-lower=alu,branch,load,store`
on the `.jit` side, to separate linking's share.

- [ ] **Step 6: Format and commit**

```bash
zig fmt ps1-core/src/recompiler ps1-core/tests/jit_test.zig
git add ps1-core/src/recompiler ps1-core/tests/jit_test.zig
git commit -m "feat(jit): jumps through a register look their target block up inline"
```

---

### Task 10: The full gates, a profile, and the as-built notes

**Files:**
- Modify: `docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md`
  (a new section only), `CLAUDE.md`, `.claude/skills/ps1-test-harnesses/SKILL.md`

- [ ] **Step 1: Every gate**

```bash
zig build
zig build test
zig build capi-lib
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- savestate
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
zig build trace-golden -Doptimize=ReleaseFast -- pgxp
zig build trace-golden -Doptimize=ReleaseFast -- verify --engine=cached
zig build trace-golden -Doptimize=ReleaseFast -- verify --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- savestate --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- lockstep --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- pgxp --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- pgxp --engine=cached
zig build test-roms-ja -Doptimize=ReleaseFast -Dengine=jit
zig build test-roms-pl -Doptimize=ReleaseFast -Dengine=jit
```

Expected: interpreter gates green with no recapture; `.jit` OK on all nine
for `verify`, `savestate` and `stream-verify`; lockstep 0 mismatches
(record checked and skipped counts per workload); the two `pgxp` outputs
equal but for the engine line; JA 12/17 with the same five failing as
under `.cached` (Getloc, Timing, MDEC 4bit, MDEC 8bit, MDEC Step By Step
Log); PL at its floors.

- [ ] **Step 2: Bench, every engine and every family**

```bash
zig build -Doptimize=ReleaseFast
CUE="games/Croc - Legend of the Gobbos/Croc - Legend of the Gobbos.cue"
B=./zig-out/bin/ps1-bench-dual
for i in 1 2 3 4 5; do
  $B SCPH-1001_BIOS_1995_US.bin "$CUE" 3000 --engine=interpreter
  $B SCPH-1001_BIOS_1995_US.bin "$CUE" 3000 --engine=cached
  $B SCPH-1001_BIOS_1995_US.bin "$CUE" 3000 --engine=jit
  $B SCPH-1001_BIOS_1995_US.bin "$CUE" 3000 --engine=jit --jit-lower=none
  $B SCPH-1001_BIOS_1995_US.bin "$CUE" 3000 --engine=jit pgxp
done
```

Best of five for each. `--jit-lower=none` is the Task 2 frame without any
lowering; `pgxp` is `.jit` with PGXP on, which lowers nothing until Plan
6. Also print, once, `segment_recompiles` and `links` for Croc (a
temporary `std.debug.print` in the bench, not committed): a large
`segment_recompiles` would mean a game alternates segments for the same
code.

- [ ] **Step 3: Profile `.jit` against `.cached`**

```bash
for engine in cached jit; do
  xcrun xctrace record --template 'Time Profiler' --output "$TMPDIR/croc-$engine.trace" \
    --launch -- $B SCPH-1001_BIOS_1995_US.bin "$CUE" 3000 --engine=$engine
  xcrun xctrace export --input "$TMPDIR/croc-$engine.trace" \
    --xpath '/trace-toc/run/data/table[@schema="time-profile"]' > "$TMPDIR/croc-$engine.xml"
done
```

Aggregate the first frame of each sample's backtrace (frames are given once
with an `id` and reused by `ref`). Save this as
`$TMPDIR/leaf.py` and run it on each export:

```python
import collections, sys, xml.etree.ElementTree as ET

frames, leaves = {}, collections.Counter()
for row in ET.parse(sys.argv[1]).getroot().iter('row'):
    bt = next((c for c in row if c.tag in ('backtrace', 'tagged-backtrace')), None)
    if bt is None:
        continue
    if bt.get('ref'):
        bt = frames.get('bt' + bt.get('ref'), bt)
    else:
        frames['bt' + bt.get('id', '')] = bt
    f = bt.find('.//frame')
    if f is None:
        continue
    if f.get('ref'):
        name = frames.get(f.get('ref'), '?')
    else:
        name = f.get('name') or ('0x' + f.get('addr', '?') if f.find('binary') is None else '?')
        frames[f.get('id')] = name
    leaves[name] += 1
total = sum(leaves.values())
for name, n in leaves.most_common(40):
    print(f'{100 * n / total:5.1f}%  {name}')
```

Bucket the leaves: emitted code (frames with no symbol and no binary),
`recompiler.*` and `cached.*`, `cpu.exec.*` handlers, `memory.Bus.*`,
`scheduler.*`, `gpu.*` (rasterizer and stepping), `spu.*`, `cdrom.*`,
`dma.*`, the rest. Report the table for both engines: the CPU-side share
(emitted code, handlers, recompiler, Bus) is the ceiling any further JIT
work can win; the rest is what it cannot. Name the top three remaining
CPU-side leaves under `.jit`; they decide whether the register cache
(departure 1) or another family is the next step.

- [ ] **Step 4: The docs**

`CLAUDE.md`:
- The `trace-golden -- lockstep` row: append "`--jit-lower=<families>`
  (`alu,branch,load,store,link`, `all`, `none`) bisects a `.jit` mismatch
  by family; `--jit-dump=<prefix>` writes each workload's compiled blocks
  as assembler for `clang -c` + `objdump -d`."
- The `ps1-bench` row: after `--engine=jit likewise`, add "; `--jit-lower=`
  as for trace-golden. The bench calls `Cpu.runFor`, so `.jit` links
  blocks."
- Repository layout, the `arm64/` line: list `emit.zig (encoder),
  emitter.zig (hot/cold sections), code_buffer.zig (MAP_JIT),
  translate.zig (block -> host code), model.zig (pipeline and load delay
  at compile time), lower_alu/lower_branch/lower_memory.zig, link.zig,
  layout.zig`.
- Rules, Harnesses, add: "**`Cpu.run()` is one block; `Cpu.runFor(budget)`
  chains `.jit`'s linked blocks.** A frontend that acts between calls by
  step count must pass its next event as the budget, as `ps1-golden`'s
  `runWorkload` does, or its samples land on other instructions."
- Rules, Core subsystems or a new JIT group, add: "**The JIT lowers
  nothing while PGXP is on, and `Bus.setPgxp` flushes the block cache on
  every toggle.** Plan 6 emits the shadow code; until then an inline op
  would skip the hooks `exec.zig` calls."

`.claude/skills/ps1-test-harnesses/SKILL.md`, the `trace-block/`
paragraph: add that `.jit` with every family lowered and linking on
still verifies against `trace-block/` unchanged (Plan 5), and that
`runWorkload` passes its next sample or pad event to `Cpu.runFor`.

The spec gets `### As built (Plan 5, <date>)` after Plan 4's, in the same
style:
- Names: `emitter.Emitter`, `layout`, `model.Model`, `lower_alu`,
  `lower_branch`, `lower_memory`, `link`, `jit.Jit`, `jit.Lowering`,
  `jit.Hook`, `cache.Pins`, `BlockCache.discard`/`segment_recompiles`,
  `Block.code_words`/`link_entry`, `run.compileBlock`/`setLowering`/
  `setJitDump`, `Cpu.runFor`, `Bus.ram_access_wait`, `lockstep`'s `"io"`
  and `stray`, `script.Pad.next`.
- The ten deliberate departures from this plan's header, as built.
- What changed from this plan during the build, if anything.
- Measurements: every task's bench pair, Step 2's table, Step 3's profile
  table and its top three leaves.
- Gates: Step 1's results, lockstep counts, the fuzzers' program counts
  and the depth the retuned generator reached.
- What Plan 6 inherits: inline loads and stores must call
  `shadowLoad`/`shadowStore` (and the half-word and byte variants) where
  the handlers do, and clear `gpr_shadow` for every register written
  inline; CPU-mode hooks at every ALU, shift and move; until then
  `run.compileBlock` lowers nothing under PGXP, which Plan 6 relaxes.
  Whether the register cache is worth building, from Step 3.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md .claude/skills/ps1-test-harnesses/SKILL.md
git add -p docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md
git commit -m "docs: Plan 5 as-built notes, the JIT lowering's gates, bench and profile"
```

Stage only the new section of the spec: the owner's table re-alignment in
that file stays unstaged.
