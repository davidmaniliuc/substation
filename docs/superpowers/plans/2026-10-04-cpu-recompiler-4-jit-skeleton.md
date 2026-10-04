# CPU recompiler, Plan 4: the JIT skeleton. Implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `.jit` a working third engine on arm64 macOS. Every block is
emitted as host code that calls the cached interpreter's per-instruction step
once per op, so `.jit` computes exactly what `.cached` computes, and
`trace-golden -- verify --engine=jit` passes against the existing
`trace-block/` goldens with no capture.

**Architecture:** `arm64/emit.zig` is a pure instruction encoder.
`arm64/code_buffer.zig` owns one MAP_JIT mapping and installs finished code
through the per-thread write window. `arm64/translate.zig` turns a `Block`
into a host function. The function's prologue pins `*Cpu` in x19 and keeps
the block's cycle and step accounting in callee-saved registers. Each op is a
call to `cached.runOp` with that op's own `Op`, and a load or store first
commits the elapsed cycles, exactly as `cached.execute` does. The emitted
code owns control flow and timing only. Instruction semantics stay in
`exec.zig`, reached through `cached.zig`, so a block engine bug can only be
a control-flow or accounting bug, and the differential fuzzer looks for
exactly that. A `Block` compiled under `.jit` carries its entry point. The
dispatcher runs whichever form a block has. The cache owns the code buffer,
and a full buffer flushes the cache.

**Tech Stack:** Zig 0.17.0, `ps1-core` (`recompiler/`), arm64 machine code,
macOS `MAP_JIT` + `pthread_jit_write_protect_np` + `sys_icache_invalidate`,
`ps1-golden` (trace-golden), `ps1-bench`, the ROM suites.

**Spec:** `docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md`.
Before starting, read "Architecture", "The arm64 JIT (`.jit`)" (Machinery
especially), "Blocks, the cache and invalidation" (Full flushes), "Testing
and gates", the three "As built" sections (Plan 3's "What Plan 4 inherits"
above all), and Plans → 4.

## Global Constraints

- `zig version` is **0.17.0**. 0.17 has no `**` array repeat (use `@splat`),
  `std.ArrayList` is unmanaged, `zig fmt` rewrites `@intFromEnum` to
  `@backingInt`, and an enum's backing integer is read with `@backingInt`.
- **The JIT exists only on `aarch64-macos`.** Everything that touches MAP_JIT
  or calls the emitted code sits behind `if (comptime jit.available)`, so wasm
  (and any other target) never analyses it. `zig build` builds the wasm
  target, which makes it the check that the gating holds.
- **No interpreter golden moves.** `trace-golden -- verify`, `-- savestate`,
  `-- stream-verify` and `-- pgxp` stay green on the interpreter with **no
  recapture**.
- **No `trace-block/` golden is recaptured.** `.jit` must equal `.cached`
  exactly. A `verify --engine=jit` mismatch is a JIT bug, never a reason to
  capture.
- **`.cached` must not get slower.** Task 3 moves its loop body into three
  inline functions that the JIT shares. Bench it before and after.
- **Instruction semantics live in `exec.zig` only.** The skeleton lowers
  nothing. Every op reaches its `exec.zig` handler through `cached.runOp`.
- **No savestate format change**, no section version bump.
- `ps1-trace`, `ps1-debug`, `ps1-capi` and the Swift app get no changes. The
  app's engine setting is Plan 7.
- No file in `ps1-core/src` over ~600 lines. Every new file here stays well
  under 300.
- Commits go directly on `master`, one per task. The **commit message is the
  title line only**: no body and no trailer. **Never `git push`.**
- Run `zig fmt` on every touched `.zig` file before committing.
- Every `trace-golden` and bench run is `-Doptimize=ReleaseFast`.

### Deliberate departures from the spec (flag these in review, do not "fix" them)

1. **No `Block.segment` and no segment-mismatch recompile.** The spec asked
   for both "once the JIT embeds the fetch cost". The skeleton does not
   embed it: the dispatcher passes the fetch cost to the emitted function as
   its second argument, as it passes it to `cached.execute`. The same block
   entered through KSEG0 and KSEG1 is therefore charged correctly, and a BIOS
   wait-state write applies from the next block. `Block.segment` arrives
   with the first code that bakes the cost in as an immediate, which is
   Plan 5's block-entry `subs x21, x21, #static_cost`.
2. **No `-Djit` build option.** `jit.available` is a comptime check on the
   target (`aarch64` and `macos`). A build option would only let someone
   switch the JIT off on a target that has it, and `setEngine` already
   leaves that choice to the frontend.
3. **The encoder is pinned against `clang -c` + `objdump -d`, not
   `llvm-mc`.** Xcode ships no `llvm-mc`. `clang`'s integrated assembler is
   the same LLVM MC layer, and every expected word in `jit_test.zig` carries
   the assembly line that produced it.
4. **The code-buffer file is `arm64/code_buffer.zig`, not
   `arm64/memory.zig`.** The core already has a `memory.zig` (the `Bus`), and
   files that import both would need two different aliases for one name.
5. **The pinned registers are not x20-x22 yet.** The skeleton uses x19
   (`*Cpu`) and x23-x26 for its own accounting. Plan 5 introduces x20 (RAM
   base), x21 (downcount) and x22 (page bitmap) along with the inline code
   that reads them, and is free to reassign x23-x26 then.
6. **`PS1_JIT_DUMP` and the per-op lower/call mask move to Plan 5.** Both
   are tools for bisecting a lowering. With every op a call there is nothing
   to bisect, and the fuzzer and lockstep localise to one block already.

### Not in this plan

- Any inline lowering, the load-delay resolution, inline RAM fast paths,
  block linking, the x21 downcount check at block entry. Those are Plan 5.
- PGXP-specific JIT code. Every PGXP hook runs today because every handler
  does; Plan 6 adds what inline code will need.
- The lockstep reference straying into a device. Plan 3 noted that under a
  JIT a diverged reference could make an MMIO access the engine never made.
  In this skeleton the reference runs the same words from the same state
  through the same handlers, so it cannot diverge before a mismatch. Plan 5's
  inline code can, and must revisit it. The journal's `max_len + 1` capacity
  still holds: the JIT stores at most once per instruction, and the skeleton
  never links blocks. **Plan 5 must keep linking off while lockstep checks.**

## Review Focus

These five failure modes are the ones most likely to hurt someone running
`.jit`. Each line names the task whose tests pin it.

1. **The code buffer fills during a long session.** Expected: the cache
   flushes, compilation continues, and nothing visibly changes. A 16 KB
   buffer forced to flush mid-run is Task 4's test.
2. **A store rewrites the block that is running** (self-modifying code, or
   a DMA into a code page). Expected: the block stops after the store and
   the rewritten word runs next. The emitted code calls through `&b.ops[i]`,
   so the dropped block must stay allocated until `reap`. That is Task 4's
   "self-modifying" scenario, compared against `.cached`.
3. **Switching engines `.cached` ↔ `.jit` ↔ `.interpreter` at run time.**
   Expected: no leaked cache, no `.cached` block reused without code, and
   re-applying `.jit` is a no-op (frontends re-apply settings every frame).
   Task 4.
4. **The write window left open, or code left un-invalidated, after an
   install fails.** Expected: earlier code still runs after a
   `CodeBufferFull`, and new code runs after a reset. Task 2.
5. **A non-macOS build (the browser) pulling in the arm64 code.** Expected:
   `zig build` still builds `emulator.wasm`, and `.jit` there is
   `EngineUnavailable`. Tasks 1, 3 and 4 each end with `zig build`.

---

## File structure

| File | Responsibility |
| --- | --- |
| `ps1-core/src/recompiler/arm64/emit.zig` (new) | Pure arm64 encoder: one function per instruction form, each returning a `u32`. No state, no I/O, compiles on every target. |
| `ps1-core/src/recompiler/arm64/code_buffer.zig` (new) | `available`; `CodeBuffer`: the MAP_JIT mapping, `install` (write window + icache invalidate), `reset`. |
| `ps1-core/src/recompiler/arm64/translate.zig` (new) | `compile(buf, block) -> JitEntry`: prologue, one call per op, cycle/step accounting, epilogue; the two C-ABI shims the code calls. |
| `ps1-core/src/recompiler/jit.zig` (new) | The backend entry, beside `cached.zig`: re-exports, `buffer_bytes`, `execute`. |
| `ps1-core/src/recompiler/cached.zig` | Loop body split into `begin`, `commit`, `runOp`, shared with the JIT's shims. |
| `ps1-core/src/recompiler/block.zig` | `JitEntry` type; `Block.code`. |
| `ps1-core/src/recompiler/cache.zig` | `BlockCache.code: ?CodeBuffer`; flush resets it, destroy unmaps it. |
| `ps1-core/src/recompiler/run.zig` | `setEngine(.jit)`, `engineOf`, `executeBlock`, compile into the buffer with flush-on-full; `pub` exports. |
| `ps1-core/src/recompiler/lockstep.zig` | Runs the block through `executeBlock`; the reference is bounded by the block's length. |
| `ps1-core/tests/recompiler_helpers.zig` (new) | Shared test helpers moved out of `recompiler_test.zig`: register numbers, `mips`, `poke`, `nops`, `Machine`, `loop_program`, `expectSameMachine`. |
| `ps1-core/tests/recompiler_test.zig` | Imports the helpers; drops the "`.jit` is unavailable" assertion. |
| `ps1-core/tests/jit_test.zig` (new) | Encoder tests, code-buffer tests, `.jit` vs `.cached` scenarios, the fuzzer. |
| `build.zig` | `jit_test.zig` joins `unit_test_files`. |
| `CLAUDE.md`, `.claude/skills/ps1-test-harnesses/SKILL.md`, spec | Counts, layout, as-built notes. |

---

### Task 1: The arm64 encoder

**Files:**
- Create: `ps1-core/src/recompiler/arm64/emit.zig`
- Create: `ps1-core/src/recompiler/jit.zig`
- Create: `ps1-core/tests/jit_test.zig`
- Modify: `ps1-core/src/recompiler/run.zig` (one export line)
- Modify: `build.zig:188-204` (`unit_test_files`)

**Interfaces:**
- Produces: `recompiler.jit.emit` with `Reg` (`x0`..`x30`, `sp`; `Reg.zr`,
  `Reg.fp`, `Reg.lr`), `Width` (`.w`, `.x`), `PairMode` (`.pre_index`,
  `.signed_offset`, `.post_index`), and `addImm`, `addReg`, `movReg`,
  `movz`, `movk`, `stp`, `ldp`, `blr`, `ret`, `b`, `cbnz`, each returning
  `u32`.

- [ ] **Step 1: Write the failing test**

Create `ps1-core/tests/jit_test.zig`:

```zig
//! The arm64 JIT: the encoder against the assembler, the code buffer, and
//! `.jit` against `.cached`, which it must equal block for block.

const std = @import("std");
const expectEqual = std.testing.expectEqual;

const ps1_core = @import("ps1_core");
const jit = ps1_core.recompiler.jit;
const emit = jit.emit;

// Each expected word is what `clang -arch arm64 -c` assembled from the line
// in the comment, read back with `objdump -d` (Xcode ships no llvm-mc; clang
// is the same MC layer). To pin a new form, assemble it the same way.
test "the encoder matches the assembler" {
    const cases = [_]struct { u32, u32 }{
        .{ emit.stp(.pre_index, .x29, .x30, .sp, -64), 0xa9bc7bfd }, // stp x29, x30, [sp, #-64]!
        .{ emit.stp(.signed_offset, .x19, .x20, .sp, 16), 0xa90153f3 }, // stp x19, x20, [sp, #16]
        .{ emit.stp(.signed_offset, .x23, .x24, .sp, 32), 0xa90263f7 }, // stp x23, x24, [sp, #32]
        .{ emit.stp(.signed_offset, .x25, .x26, .sp, 48), 0xa9036bf9 }, // stp x25, x26, [sp, #48]
        .{ emit.ldp(.signed_offset, .x25, .x26, .sp, 48), 0xa9436bf9 }, // ldp x25, x26, [sp, #48]
        .{ emit.ldp(.signed_offset, .x23, .x24, .sp, 32), 0xa94263f7 }, // ldp x23, x24, [sp, #32]
        .{ emit.ldp(.signed_offset, .x19, .x20, .sp, 16), 0xa94153f3 }, // ldp x19, x20, [sp, #16]
        .{ emit.ldp(.post_index, .x29, .x30, .sp, 64), 0xa8c47bfd }, // ldp x29, x30, [sp], #64
        .{ emit.addImm(.x, .x29, .sp, 0), 0x910003fd }, // add x29, sp, #0
        .{ emit.addImm(.w, .x23, .x1, 1), 0x11000437 }, // add w23, w1, #1
        .{ emit.addImm(.w, .x25, .x25, 1), 0x11000739 }, // add w25, w25, #1
        .{ emit.addReg(.w, .x24, .x24, .x23), 0x0b170318 }, // add w24, w24, w23
        .{ emit.movReg(.x, .x19, .x0), 0xaa0003f3 }, // mov x19, x0
        .{ emit.movReg(.x, .x0, .x19), 0xaa1303e0 }, // mov x0, x19
        .{ emit.movReg(.w, .x1, .x24), 0x2a1803e1 }, // mov w1, w24
        .{ emit.movReg(.w, .x2, .x25), 0x2a1903e2 }, // mov w2, w25
        .{ emit.movReg(.w, .x0, .x26), 0x2a1a03e0 }, // mov w0, w26
        .{ emit.movz(.w, .x24, 0, 0), 0x52800018 }, // movz w24, #0
        .{ emit.movz(.x, .x16, 0x1234, 0), 0xd2824690 }, // movz x16, #0x1234
        .{ emit.movk(.x, .x16, 0x5678, 1), 0xf2aacf10 }, // movk x16, #0x5678, lsl #16
        .{ emit.movk(.x, .x16, 0x9abc, 2), 0xf2d35790 }, // movk x16, #0x9abc, lsl #32
        .{ emit.movk(.x, .x16, 0xdef0, 3), 0xf2fbde10 }, // movk x16, #0xdef0, lsl #48
        .{ emit.movz(.w, .x1, 0xbeef, 1), 0x52b7dde1 }, // movz w1, #0xbeef, lsl #16
        .{ emit.blr(.x16), 0xd63f0200 }, // blr x16
        .{ emit.ret(), 0xd65f03c0 }, // ret
        .{ emit.cbnz(.w, .x0, 8), 0x35000040 }, // cbnz w0, .+8
        .{ emit.cbnz(.w, .x0, -4), 0x35ffffe0 }, // cbnz w0, .-4
        .{ emit.b(12), 0x14000003 }, // b .+12
        .{ emit.b(-8), 0x17fffffe }, // b .-8
    };
    for (cases, 0..) |c, i| {
        if (c[0] != c[1]) {
            std.debug.print("case {d}: got 0x{x:0>8}, assembler 0x{x:0>8}\n", .{ i, c[0], c[1] });
            return error.EncodingDiffers;
        }
    }
}
```

In `build.zig`, add `"ps1-core/tests/jit_test.zig",` after
`"ps1-core/tests/recompiler_test.zig",` in `unit_test_files`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | grep -m3 -E "error|jit"`
Expected: a compile error, `root source file struct 'recompiler.run' has no member named 'jit'`.

- [ ] **Step 3: Write the encoder**

Create `ps1-core/src/recompiler/arm64/emit.zig`:

```zig
//! A pure arm64 instruction encoder: each function returns one instruction
//! word. Only the forms the JIT emits, each pinned in `jit_test.zig` against
//! the assembler's own encoding.

pub const Reg = enum(u5) {
    x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15,
    x16, x17, x18, x19, x20, x21, x22, x23, x24, x25, x26, x27, x28, x29, x30,
    /// Register 31 is the stack pointer as an add-immediate operand or a
    /// load/store base, and the zero register everywhere else.
    sp,

    pub const zr: Reg = .sp;
    pub const fp: Reg = .x29;
    pub const lr: Reg = .x30;

    fn n(r: Reg) u32 {
        return @backingInt(r);
    }
};

/// Operand width: `w` (32-bit) or `x` (64-bit) registers.
pub const Width = enum(u1) {
    w,
    x,

    fn sf(width: Width) u32 {
        return @as(u32, @backingInt(width)) << 31;
    }
};

/// ADD (immediate), unshifted. Register 31 is SP here.
pub fn addImm(width: Width, rd: Reg, rn: Reg, imm12: u12) u32 {
    return width.sf() | 0x1100_0000 | @as(u32, imm12) << 10 | rn.n() << 5 | rd.n();
}

/// ADD (shifted register), LSL #0. Register 31 is the zero register here.
pub fn addReg(width: Width, rd: Reg, rn: Reg, rm: Reg) u32 {
    return width.sf() | 0x0B00_0000 | rm.n() << 16 | rn.n() << 5 | rd.n();
}

/// MOV (register), which is ORR rd, zr, rm. Not for SP: copy SP with
/// `addImm(.x, rd, .sp, 0)`.
pub fn movReg(width: Width, rd: Reg, rm: Reg) u32 {
    return width.sf() | 0x2A00_03E0 | rm.n() << 16 | rd.n();
}

/// MOVZ: `imm16 << (16 * hw)`, every other bit zero. `hw` is 0 or 1 for `w`.
pub fn movz(width: Width, rd: Reg, imm16: u16, hw: u2) u32 {
    return width.sf() | 0x5280_0000 | @as(u32, hw) << 21 | @as(u32, imm16) << 5 | rd.n();
}

/// MOVK: replaces bits `16 * hw` to `16 * hw + 15` and keeps the rest.
pub fn movk(width: Width, rd: Reg, imm16: u16, hw: u2) u32 {
    return width.sf() | 0x7280_0000 | @as(u32, hw) << 21 | @as(u32, imm16) << 5 | rd.n();
}

/// Addressing for STP/LDP. `offset` is in bytes.
pub const PairMode = enum(u32) {
    /// `[base, #offset]!`
    pre_index = 0x2980_0000,
    /// `[base, #offset]`
    signed_offset = 0x2900_0000,
    /// `[base], #offset`
    post_index = 0x2880_0000,
};

/// STP of two `x` registers. `offset` is a multiple of 8 in -512..504.
pub fn stp(mode: PairMode, rt: Reg, rt2: Reg, rn: Reg, offset: i10) u32 {
    return pair(mode, false, rt, rt2, rn, offset);
}

/// LDP of two `x` registers. `offset` is a multiple of 8 in -512..504.
pub fn ldp(mode: PairMode, rt: Reg, rt2: Reg, rn: Reg, offset: i10) u32 {
    return pair(mode, true, rt, rt2, rn, offset);
}

fn pair(mode: PairMode, load: bool, rt: Reg, rt2: Reg, rn: Reg, offset: i10) u32 {
    const imm7: u7 = @bitCast(@as(i7, @intCast(@divExact(offset, 8))));
    return 0x8000_0000 | @backingInt(mode) | @as(u32, @intFromBool(load)) << 22 |
        @as(u32, imm7) << 15 | rt2.n() << 10 | rn.n() << 5 | rt.n();
}

pub fn blr(rn: Reg) u32 {
    return 0xD63F_0000 | rn.n() << 5;
}

pub fn ret() u32 {
    return 0xD65F_03C0;
}

/// B. `offset` is in bytes from this instruction: a multiple of 4 within
/// ±128 MB.
pub fn b(offset: i28) u32 {
    const imm26: u26 = @bitCast(@as(i26, @intCast(@divExact(offset, 4))));
    return 0x1400_0000 | @as(u32, imm26);
}

/// CBNZ. `offset` is in bytes from this instruction: a multiple of 4
/// within ±1 MB.
pub fn cbnz(width: Width, rt: Reg, offset: i21) u32 {
    const imm19: u19 = @bitCast(@as(i19, @intCast(@divExact(offset, 4))));
    return width.sf() | 0x3500_0000 | @as(u32, imm19) << 5 | rt.n();
}
```

`zig fmt` may put the `Reg` fields one per line. Accept whatever it writes.

Create `ps1-core/src/recompiler/jit.zig`:

```zig
//! The arm64 JIT (`.jit`): a block emitted as host code. See
//! docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md.

pub const emit = @import("arm64/emit.zig");
```

In `ps1-core/src/recompiler/run.zig`, below `pub const lockstep = @import("lockstep.zig");`, add:

```zig
pub const jit = @import("jit.zig");
```

- [ ] **Step 4: Run the tests to verify they pass, and that wasm still builds**

Run: `zig build test 2>&1 | tail -5 && zig build`
Expected: the test step passes, and `zig build` exits 0. `zig build` builds
`emulator.wasm` too, and `emit.zig` is target-independent.

- [ ] **Step 5: Commit**

```bash
zig fmt ps1-core/src/recompiler/arm64/emit.zig ps1-core/src/recompiler/jit.zig ps1-core/src/recompiler/run.zig ps1-core/tests/jit_test.zig build.zig
git add ps1-core/src/recompiler/arm64/emit.zig ps1-core/src/recompiler/jit.zig ps1-core/src/recompiler/run.zig ps1-core/tests/jit_test.zig build.zig
git commit -m "feat(jit): arm64 instruction encoder pinned against the assembler"
```

---

### Task 2: The code buffer

**Files:**
- Create: `ps1-core/src/recompiler/arm64/code_buffer.zig`
- Modify: `ps1-core/src/recompiler/jit.zig`
- Test: `ps1-core/tests/jit_test.zig`

**Interfaces:**
- Consumes: `jit.emit` (Task 1).
- Produces: `jit.available: bool` (comptime); `jit.CodeBuffer` with
  `init(bytes: usize) std.posix.MMapError!CodeBuffer`, `deinit(*CodeBuffer)`,
  `install(*CodeBuffer, code: []const u32) error{CodeBufferFull}![*]const u32`,
  `reset(*CodeBuffer)`, and the fields `words: []u32` and `used: usize`.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/jit_test.zig`:

```zig
/// `install`'s result as a function of one `u32`, for code that is one.
fn unary(entry: [*]const u32) *const fn (u32) callconv(.c) u32 {
    return @ptrCast(entry);
}

test "installed code runs" {
    if (!jit.available) return error.SkipZigTest;
    var buf = try jit.CodeBuffer.init(16 << 10);
    defer buf.deinit();
    const f = unary(try buf.install(&.{ emit.addImm(.w, .x0, .x0, 5), emit.ret() }));
    try expectEqual(@as(u32, 12), f(7));
}

test "a full buffer refuses, keeps what it holds, and takes code again after reset" {
    if (!jit.available) return error.SkipZigTest;
    var buf = try jit.CodeBuffer.init(16 << 10); // one 16 KB page: 4096 words
    defer buf.deinit();
    const first = unary(try buf.install(&.{ emit.addImm(.w, .x0, .x0, 1), emit.ret() }));
    const filler: [4094]u32 = @splat(emit.ret());
    _ = try buf.install(&filler);
    try std.testing.expectError(error.CodeBufferFull, buf.install(&.{emit.ret()}));
    // The refusal left the buffer executable and its code intact.
    try expectEqual(@as(u32, 2), first(1));
    buf.reset();
    const again = unary(try buf.install(&.{ emit.addImm(.w, .x0, .x0, 9), emit.ret() }));
    try expectEqual(@as(u32, 10), again(1));
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test 2>&1 | grep -m3 error`
Expected: `struct 'jit' has no member named 'available'`.

- [ ] **Step 3: Write the code buffer**

Create `ps1-core/src/recompiler/arm64/code_buffer.zig`:

```zig
//! The JIT's code memory: one MAP_JIT mapping, filled from the bottom and
//! never freed piecemeal. When it fills, the block cache flushes every block
//! and it starts again from the bottom (spec: Full flushes).
//!
//! MAP_JIT memory is writable or executable per thread, never both. The
//! write window opens and closes inside `install` around one copy that
//! cannot fail, so no path leaves it open.

const std = @import("std");
const builtin = @import("builtin");

/// MAP_JIT and the per-thread write toggle exist only here. Every other
/// target, wasm included, must never analyse the code below; callers guard
/// with `if (comptime available)`.
pub const available = builtin.cpu.arch == .aarch64 and builtin.os.tag == .macos;

extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;
extern "c" fn sys_icache_invalidate(start: *anyopaque, len: usize) void;

pub const CodeBuffer = struct {
    words: []u32,
    used: usize = 0,

    /// Fails when MAP_JIT is refused: a hardened runtime without the
    /// `allow-jit` entitlement (spec: Findings).
    pub fn init(bytes: usize) std.posix.MMapError!CodeBuffer {
        const mem = try std.posix.mmap(
            null,
            bytes,
            .{ .READ = true, .WRITE = true, .EXEC = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = true },
            -1,
            0,
        );
        return .{ .words = @as([*]u32, @ptrCast(mem.ptr))[0 .. mem.len / 4] };
    }

    pub fn deinit(self: *CodeBuffer) void {
        const bytes: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(self.words.ptr));
        std.posix.munmap(bytes[0 .. self.words.len * 4]);
        self.* = undefined;
    }

    /// Copies `code` in and returns its first word, ready to call.
    pub fn install(self: *CodeBuffer, code: []const u32) error{CodeBufferFull}![*]const u32 {
        if (code.len > self.words.len - self.used) return error.CodeBufferFull;
        const dest = self.words[self.used..][0..code.len];
        pthread_jit_write_protect_np(0);
        @memcpy(dest, code);
        pthread_jit_write_protect_np(1);
        sys_icache_invalidate(dest.ptr, code.len * 4);
        self.used += code.len;
        return dest.ptr;
    }

    /// Forgets every installed function. Only once nothing can call one.
    pub fn reset(self: *CodeBuffer) void {
        self.used = 0;
    }
};
```

In `ps1-core/src/recompiler/jit.zig`, add below the `emit` line:

```zig
const code_buffer = @import("arm64/code_buffer.zig");
pub const CodeBuffer = code_buffer.CodeBuffer;
pub const available = code_buffer.available;
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test 2>&1 | tail -5 && zig build`
Expected: PASS. `zig build` exits 0, because nothing outside the tests
calls `CodeBuffer` yet.

- [ ] **Step 5: Commit**

```bash
zig fmt ps1-core/src/recompiler/arm64/code_buffer.zig ps1-core/src/recompiler/jit.zig ps1-core/tests/jit_test.zig
git add ps1-core/src/recompiler/arm64/code_buffer.zig ps1-core/src/recompiler/jit.zig ps1-core/tests/jit_test.zig
git commit -m "feat(jit): MAP_JIT code buffer with a per-thread write window"
```

---

### Task 3: Translate a block into host code

The emitted function for a block of `n` ops is, in order:

```
prologue:   stp x29,x30,[sp,#-64]!; add x29,sp,#0; stp x19,x20,[sp,#16];
            stp x23,x24,[sp,#32]; stp x25,x26,[sp,#48];
            mov x19,x0                 // *Cpu
            add w23,w1,#1              // per-instruction cost: 1 + fetch cost
            movz w24,#0; movz w25,#0; movz w26,#0   // cycles, steps, ran
op i:       add w24,w24,w23
            [load/store only: commitShim(cpu, w24, w25); movz w24,#0; movz w25,#0]
            x0 = x19; x1 = &b.ops[i]; blr opShim     // w0 = stop?
            add w25,w25,#1; add w26,w26,#1
            cbnz w0, epilogue
epilogue:   commitShim(cpu, w24, w25); mov w0,w26
            ldp x25,x26,[sp,#48]; ldp x23,x24,[sp,#32]; ldp x19,x20,[sp,#16];
            ldp x29,x30,[sp],#64; ret
```

That is `cached.execute` op for op. Every 64-bit address is a fixed four-word
`movz`/`movk` sequence, because a MAP_JIT region can lie more than ±128 MB
from the binary, beyond `bl`'s range. Fixed sizes make the scratch buffer's
bound exact.

**Files:**
- Modify: `ps1-core/src/recompiler/cached.zig`
- Modify: `ps1-core/src/recompiler/block.zig`
- Create: `ps1-core/src/recompiler/arm64/translate.zig`
- Modify: `ps1-core/src/recompiler/jit.zig`
- Modify: `ps1-core/src/recompiler/run.zig` (make `cached` `pub`)
- Create: `ps1-core/tests/recompiler_helpers.zig`
- Modify: `ps1-core/tests/recompiler_test.zig`
- Test: `ps1-core/tests/jit_test.zig`

**Interfaces:**
- Consumes: `jit.emit`, `jit.CodeBuffer` (Tasks 1-2).
- Produces:
  - `cached.begin(cpu: *Cpu) void`, `cached.commit(cpu: *Cpu, cycles: u32, steps: u32) void`,
    `cached.runOp(cpu: *Cpu, op: *const block.Op) bool` (all `pub inline`).
  - `block.JitEntry = *const fn (cpu: *Cpu, fetch_cost: u32) callconv(.c) u32`;
    `Block.code: ?JitEntry = null`.
  - `jit.translate.compile(buf: *CodeBuffer, b: *const block.Block) error{CodeBufferFull}!block.JitEntry`.
  - `jit.execute(cpu: *Cpu, b: *const block.Block, fetch_cost: u32) u32`
    (same contract as `cached.execute`; `b.code` must be set).
  - `jit.buffer_bytes: usize = 32 << 20`.
  - `recompiler.cached` is now `pub`.
  - `recompiler_helpers.zig`: `pub` register constants, `mips`, `poke`,
    `nops`, `Machine`, `loop_program`, `expectSameMachine`, `compared_ram`.

- [ ] **Step 1: Move the shared test helpers**

Create `ps1-core/tests/recompiler_helpers.zig`. Move these out of
`recompiler_test.zig` verbatim and mark each `pub` (for `mips`, every
function and constant inside it too): the register constants (`zero` ..
`ra`), `mips`, `poke`, `nops`, `Machine` (with `init`, `deinit`, `start`,
`runUntil`), and `loop_program` with its doc comment. Then add
`expectSameMachine` and add `gp`:

```zig
//! Shared by the block-engine tests: hand-assembled MIPS, a machine on a
//! chosen engine, and a whole-machine comparison between two of them.

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const alloc = std.testing.allocator;

const ps1_core = @import("ps1_core");
const Bus = ps1_core.memory.Bus;
const Cpu = ps1_core.cpu.Cpu;
const recompiler = ps1_core.recompiler;
const lockstep = recompiler.lockstep;

// (register constants, mips, poke, nops, Machine, loop_program: moved here)

pub const gp: u5 = 28;

/// The RAM `expectSameMachine` compares: the exception vector, every test
/// program and the fuzzer's data window all lie below it.
pub const compared_ram = 0x5000;

/// Everything a block can change, `dut` against `ref`: the architectural
/// state, the clocks and the scheduler's backlog, the two stop flags, the
/// low RAM and the scratchpad.
pub fn expectSameMachine(ref: *const Machine, dut: *const Machine) !void {
    if (lockstep.compareArch(&lockstep.Arch.capture(&dut.cpu), &lockstep.Arch.capture(&ref.cpu))) |mm| {
        std.debug.print("machines differ: {s} {d}: 0x{x} against 0x{x}\n", .{ mm.what, mm.index, mm.engine, mm.reference });
        return error.MachinesDiffer;
    }
    try expectEqual(ref.cpu.cycles, dut.cpu.cycles);
    try expectEqual(ref.bus.sys_clock, dut.bus.sys_clock);
    try expectEqual(ref.bus.sched.downcount, dut.bus.sched.downcount);
    try expectEqual(ref.bus.sched.pending, dut.bus.sched.pending);
    try expectEqual(ref.bus.sched.pending_steps, dut.bus.sched.pending_steps);
    try expectEqual(ref.cpu.exception_taken, dut.cpu.exception_taken);
    try expectEqual(ref.bus.block_exit, dut.bus.block_exit);
    try std.testing.expectEqualSlices(u8, ref.bus.ram[0..compared_ram], dut.bus.ram[0..compared_ram]);
    try std.testing.expectEqualSlices(u8, &ref.bus.scratchpad, &dut.bus.scratchpad);
}
```

In `recompiler_test.zig`, delete the moved definitions and import them under
their old names so no test body changes:

```zig
const h = @import("recompiler_helpers.zig");
const zero = h.zero;
// ... one line per register constant the file uses (a0, t0..t7, k0, k1, ra)
const mips = h.mips;
const poke = h.poke;
const nops = h.nops;
const Machine = h.Machine;
const loop_program = h.loop_program;
```

Keep `alloc`, `Bus`, `Cpu`, `recompiler` and `block` in
`recompiler_test.zig`: its own tests use them. If `zig build test` reports an
unused constant, delete that line.

- [ ] **Step 2: Confirm that the move changed nothing**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS, with the same tests as before the move.

- [ ] **Step 3: Write the failing tests**

Append to `ps1-core/tests/jit_test.zig`:

```zig
const alloc = std.testing.allocator;
const expect = std.testing.expect;
const recompiler = ps1_core.recompiler;
const block = recompiler.block;
const h = @import("recompiler_helpers.zig");
const mips = h.mips;
const zero = h.zero;
const t0 = h.t0;
const t1 = h.t1;
const t2 = h.t2;
const t3 = h.t3;

/// Compiles the block at `pc` once and runs it on two machines from the same
/// state: `.cached`'s handler loop on one, the JIT's code on the other.
fn expectSameBlock(program: []const u32, pc: u32, fetch_cost: u32) !void {
    if (!jit.available) return error.SkipZigTest;
    var buf = try jit.CodeBuffer.init(1 << 20);
    defer buf.deinit();
    var ref = try h.Machine.init(.interpreter);
    defer ref.deinit();
    var dut = try h.Machine.init(.interpreter);
    defer dut.deinit();
    for ([_]*h.Machine{ &ref, &dut }) |m| {
        h.poke(m.bus, pc & 0x1F_FFFF, program);
        m.start(pc);
    }
    const b = try block.compile(alloc, dut.bus, pc);
    defer block.destroy(alloc, b);
    b.code = try jit.translate.compile(&buf, b);
    try expectEqual(recompiler.cached.execute(&ref.cpu, b, fetch_cost), jit.execute(&dut.cpu, b, fetch_cost));
    try h.expectSameMachine(&ref, &dut);
}

test "a translated block computes what the cached interpreter computes" {
    try expectSameBlock(&h.loop_program, 0x8000_1000, 0); // up to the bne and its delay slot
    try expectSameBlock(h.loop_program[4..], 0xA000_1010, 4); // KSEG1: a fetch cost of 4
}

test "a translated block stops at an overflow, precisely" {
    try expectSameBlock(&.{
        mips.addiu(t0, zero, 1),
        mips.lui(t1, 0x7FFF),
        mips.ori(t1, t1, 0xFFFF),
        mips.add(t2, t1, t0), // overflows: the block stops here
        mips.addiu(t3, zero, 7),
        mips.jr(h.ra),
        mips.nop,
    }, 0x1000, 0);
}

test "a translated block commits its cycles before an MMIO read" {
    try expectSameBlock(&(.{
        mips.lui(t1, 0x1F80),
        mips.ori(t1, t1, 0x1120), // timer 2's counter
        mips.lw(t2, t1, 0),
    } ++ h.nops(10) ++ .{
        mips.lw(t3, t1, 0),
        mips.nop,
        mips.beq(zero, zero, -1),
        mips.nop,
    }), 0x1000, 0);
}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `zig build test 2>&1 | grep -m3 error`
Expected: `struct 'jit' has no member named 'translate'` (or `cached` is
not `pub`).

- [ ] **Step 5: Split the cached interpreter's loop body**

Replace the body of `ps1-core/src/recompiler/cached.zig` below its imports
(keep the module doc comment and add the last paragraph shown):

```zig
//! The cached interpreter: a block's words, decoded once into handler
//! calls. It has no instruction semantics of its own; every handler is
//! `exec.zig`'s, so a fix to an instruction fixes it here too.
//!
//! Gone per instruction, compared with `Cpu.step()`: the DMA-stall check,
//! the fetch bus-error check, the I-cache, the Cause.IP2 update and the
//! scheduler tick. The dispatcher does those once per block.
//!
//! `begin`, `commit` and `runOp` are the JIT's too: its emitted code calls
//! them where this loop does, which is what makes `.jit` equal `.cached`.

const Cpu = @import("../cpu/cpu.zig").Cpu;
const block = @import("block.zig");
const Block = block.Block;

/// Runs `b` from `cpu.pipeline.pc`, its start. Each instruction costs 1
/// plus `fetch_cost` plus its load/store wait states, as in the interpreter
/// with the I-cache replaced by a static fetch cost. Returns the
/// instructions it ran: an exception or a `block_exit` stops it early.
pub fn execute(cpu: *Cpu, b: *const Block, fetch_cost: u32) u32 {
    begin(cpu);
    // Charged but not yet handed to the scheduler.
    var cycles: u32 = 0;
    var steps: u32 = 0;
    var ran: u32 = 0;
    for (b.ops) |*op| {
        cycles += 1 + fetch_cost;
        if (op.memory) {
            // An MMIO access syncs the devices. Hand them this block's
            // cycles so far, up to and including this fetch. This
            // instruction's step counts after its access, as the
            // interpreter counts it: a JOY_TX store arms /ACK before its own
            // step ticks it.
            commit(cpu, cycles, steps);
            cycles = 0;
            steps = 0;
        }
        const stop = runOp(cpu, op);
        steps += 1;
        ran += 1;
        if (stop) break;
    }
    commit(cpu, cycles, steps);
    return ran;
}

/// Clears the two flags a block stops on. Before every block.
pub inline fn begin(cpu: *Cpu) void {
    cpu.exception_taken = false;
    cpu.bus.block_exit = false;
}

/// Hands the scheduler `cycles` spanning `steps` instructions, plus the
/// wait states their loads and stores billed.
pub inline fn commit(cpu: *Cpu, cycles: u32, steps: u32) void {
    cpu.chargeCycles(cycles + cpu.bus.wait_cycles, steps);
    cpu.bus.wait_cycles = 0;
}

/// One instruction of a block. True when the block must stop after it: it
/// raised an exception, or a store set `block_exit`.
pub inline fn runOp(cpu: *Cpu, op: *const block.Op) bool {
    cpu.pipeline.current_pc = cpu.pipeline.pc;
    cpu.beginInstruction();
    op.handler(cpu, op.instr);
    cpu.retireLoad();
    return cpu.exception_taken or cpu.bus.block_exit;
}
```

In `run.zig`, change `const cached = @import("cached.zig");` to
`pub const cached = @import("cached.zig");`.

- [ ] **Step 6: Give `Block` an entry point**

In `ps1-core/src/recompiler/block.zig`, add an import below the `exec`
import:

```zig
const Cpu = @import("../cpu/cpu.zig").Cpu;
```

Add above `pub const Block = struct {`:

```zig
/// A block as host code (`arm64/translate.zig`): runs the block from its
/// start with the given fetch cost and returns the instructions it ran,
/// exactly as `cached.execute` does.
pub const JitEntry = *const fn (cpu: *Cpu, fetch_cost: u32) callconv(.c) u32;
```

Add as the last field of `Block` (after `next_dead`):

```zig
    /// Set under `.jit`, null under `.cached`. The code lives in the
    /// cache's code buffer, which is only ever reset by a full flush, so it
    /// outlives the block. It calls through `&ops[i]`, so `ops` must too:
    /// a dropped block stays allocated until `reap`.
    code: ?JitEntry = null,
```

- [ ] **Step 7: Write the translator**

Create `ps1-core/src/recompiler/arm64/translate.zig`:

```zig
//! A block as arm64 code. In this skeleton every instruction is a call to
//! `cached.runOp` with the block's own `Op`, so `.jit` executes exactly what
//! `.cached` executes. The emitted code owns the control flow and the cycle
//! accounting, and does both as `cached.execute` does, op for op.
//!
//! Registers, for the whole block, all callee-saved so the calls keep them:
//! x19 `*Cpu`; w23 one instruction's cost (1 + the fetch cost); w24 the
//! cycles and w25 the steps not yet committed; w26 the instructions run.

const block = @import("../block.zig");
const cached = @import("../cached.zig");
const Cpu = @import("../../cpu/cpu.zig").Cpu;
const CodeBuffer = @import("code_buffer.zig").CodeBuffer;
const e = @import("emit.zig");

const cpu_reg: e.Reg = .x19;
const cost_reg: e.Reg = .x23;
const cycles_reg: e.Reg = .x24;
const steps_reg: e.Reg = .x25;
const ran_reg: e.Reg = .x26;
/// IP0, the intra-procedure-call scratch register: holds a call's target.
const call_reg: e.Reg = .x16;

// Every piece has a fixed size, so the scratch buffer's bound is exact.
const prologue_words = 10;
const call_words = 5; // a 64-bit address, blr
const commit_words = 3 + call_words; // three argument moves
const op_words = 1 + 1 + 4 + call_words + 3; // cost, cpu, op address, call, counts + cbnz
const memory_words = commit_words + 2; // and zero the two counters
const epilogue_words = commit_words + 6; // result, four ldp, ret
pub const max_words = prologue_words + (block.max_len + 1) * (op_words + memory_words) + epilogue_words;

const Emitter = struct {
    words: [max_words]u32 = undefined,
    len: usize = 0,

    fn put(self: *Emitter, word: u32) void {
        self.words[self.len] = word;
        self.len += 1;
    }

    /// Always four words, whatever the value.
    fn movImm64(self: *Emitter, rd: e.Reg, value: u64) void {
        self.put(e.movz(.x, rd, @truncate(value), 0));
        self.put(e.movk(.x, rd, @truncate(value >> 16), 1));
        self.put(e.movk(.x, rd, @truncate(value >> 32), 2));
        self.put(e.movk(.x, rd, @truncate(value >> 48), 3));
    }

    fn call(self: *Emitter, target: usize) void {
        self.movImm64(call_reg, target);
        self.put(e.blr(call_reg));
    }

    /// `commitShim(cpu, cycles, steps)`.
    fn commit(self: *Emitter) void {
        self.put(e.movReg(.x, .x0, cpu_reg));
        self.put(e.movReg(.w, .x1, cycles_reg));
        self.put(e.movReg(.w, .x2, steps_reg));
        self.call(@intFromPtr(&commitShim));
    }
};

/// Emits `b` and installs it in `buf`.
pub fn compile(buf: *CodeBuffer, b: *const block.Block) error{CodeBufferFull}!block.JitEntry {
    var em: Emitter = .{};

    em.put(e.stp(.pre_index, .fp, .lr, .sp, -64));
    em.put(e.addImm(.x, .fp, .sp, 0));
    em.put(e.stp(.signed_offset, .x19, .x20, .sp, 16));
    em.put(e.stp(.signed_offset, .x23, .x24, .sp, 32));
    em.put(e.stp(.signed_offset, .x25, .x26, .sp, 48));
    em.put(e.movReg(.x, cpu_reg, .x0));
    em.put(e.addImm(.w, cost_reg, .x1, 1));
    em.put(e.movz(.w, cycles_reg, 0, 0));
    em.put(e.movz(.w, steps_reg, 0, 0));
    em.put(e.movz(.w, ran_reg, 0, 0));

    // Each op's stop branch, patched once the epilogue's position is known.
    var stops: [block.max_len + 1]usize = undefined;
    for (b.ops, 0..) |*op, i| {
        em.put(e.addReg(.w, cycles_reg, cycles_reg, cost_reg));
        if (op.memory) {
            em.commit();
            em.put(e.movz(.w, cycles_reg, 0, 0));
            em.put(e.movz(.w, steps_reg, 0, 0));
        }
        em.put(e.movReg(.x, .x0, cpu_reg));
        em.movImm64(.x1, @intFromPtr(op));
        em.call(@intFromPtr(&opShim));
        em.put(e.addImm(.w, steps_reg, steps_reg, 1));
        em.put(e.addImm(.w, ran_reg, ran_reg, 1));
        stops[i] = em.len;
        em.put(0); // cbnz w0, epilogue
    }

    const epilogue = em.len;
    for (stops[0..b.ops.len]) |at| em.words[at] = e.cbnz(.w, .x0, @intCast((epilogue - at) * 4));
    em.commit();
    em.put(e.movReg(.w, .x0, ran_reg));
    em.put(e.ldp(.signed_offset, .x25, .x26, .sp, 48));
    em.put(e.ldp(.signed_offset, .x23, .x24, .sp, 32));
    em.put(e.ldp(.signed_offset, .x19, .x20, .sp, 16));
    em.put(e.ldp(.post_index, .fp, .lr, .sp, 64));
    em.put(e.ret());

    return @ptrCast(try buf.install(em.words[0..em.len]));
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

In `ps1-core/src/recompiler/jit.zig`, replace the module doc comment and
add the rest, so the file reads:

```zig
//! The arm64 JIT (`.jit`): a block emitted as host code. In this skeleton
//! every op calls `cached.zig`'s per-instruction step, so it computes
//! exactly what `.cached` computes and shares its goldens (`trace-block/`).
//! See docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md.

const Cpu = @import("../cpu/cpu.zig").Cpu;
const block = @import("block.zig");
const cached = @import("cached.zig");

pub const emit = @import("arm64/emit.zig");
const code_buffer = @import("arm64/code_buffer.zig");
pub const CodeBuffer = code_buffer.CodeBuffer;
pub const available = code_buffer.available;
pub const translate = @import("arm64/translate.zig");

/// One MAP_JIT region (spec: Machinery). It is flushed whole when full.
pub const buffer_bytes: usize = 32 << 20;

/// Runs `b`'s host code from `cpu.pipeline.pc`, its start. Same contract
/// as `cached.execute`.
pub fn execute(cpu: *Cpu, b: *const block.Block, fetch_cost: u32) u32 {
    cached.begin(cpu);
    return b.code.?(cpu, fetch_cost);
}
```

- [ ] **Step 8: Run the tests to verify they pass, and that wasm still builds**

Run: `zig build test 2>&1 | tail -5 && zig build`
Expected: PASS, and `zig build` exits 0. No core code calls `translate`
yet, so wasm never analyses it.

- [ ] **Step 9: Bench `.cached` against the commit before Step 5**

Build the "before" binary from the Task 2 commit in a throwaway worktree.
Run both from the repo root, interleaved, and take the best of five for
each:

```bash
git worktree add "$TMPDIR/pre-task3" HEAD
(cd "$TMPDIR/pre-task3" && zig build -Doptimize=ReleaseFast)
zig build -Doptimize=ReleaseFast
CUE="games/Croc - Legend of the Gobbos/Croc - Legend of the Gobbos.cue"
for i in 1 2 3 4 5; do
  "$TMPDIR/pre-task3/zig-out/bin/ps1-bench-dual" SCPH-1001_BIOS_1995_US.bin "$CUE" 3000 --engine=cached
  ./zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin "$CUE" 3000 --engine=cached
done
git worktree remove "$TMPDIR/pre-task3"
```

(`HEAD` is still the Task 2 commit, since this task has not committed.)
Expected: the two bests within 2%. If the new one is slower by more than
that, check in the disassembly that `runOp` and `commit` inlined into
`execute`. `xcrun objdump -d --no-show-raw-insn zig-out/bin/ps1-bench-dual
| grep -A60 'cached.execute'` should show no `bl` to `runOp` or `commit`.
Fix it and re-measure. Record both numbers for Task 6.

- [ ] **Step 10: Commit**

```bash
zig fmt ps1-core/src/recompiler ps1-core/tests/recompiler_helpers.zig ps1-core/tests/recompiler_test.zig ps1-core/tests/jit_test.zig
git add ps1-core/src/recompiler ps1-core/tests/recompiler_helpers.zig ps1-core/tests/recompiler_test.zig ps1-core/tests/jit_test.zig
git commit -m "feat(jit): translate a block into calls to the cached interpreter's step"
```

---

### Task 4: `.jit` as an engine

**Files:**
- Modify: `ps1-core/src/recompiler/cache.zig`
- Modify: `ps1-core/src/recompiler/run.zig`
- Modify: `ps1-core/src/recompiler/lockstep.zig`
- Modify: `ps1-core/tests/recompiler_test.zig:478` (one line)
- Test: `ps1-core/tests/jit_test.zig`

**Interfaces:**
- Consumes: `jit.CodeBuffer`, `jit.translate.compile`, `jit.execute`,
  `jit.buffer_bytes`, `Block.code` (Tasks 2-3).
- Produces:
  - `BlockCache.code: ?jit.CodeBuffer`. Present means the engine is `.jit`.
  - `recompiler.setEngine(cpu, allocator, .jit)` succeeds where
    `jit.available` and MAP_JIT is granted, and returns
    `error.EngineUnavailable` otherwise.
  - `recompiler.engineOf` returns `.jit`.
  - `recompiler.executeBlock(cpu: *Cpu, b: *const block.Block, fetch_cost: u32) u32`.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/jit_test.zig`:

```zig
const Engine = recompiler.Engine;
const BlockCache = recompiler.cache.BlockCache;

/// Both machines run the same program, `ref` under `.cached` and `dut`
/// under `.jit`, with a spin loop at the exception vector so a fault parks
/// both. Returns them started at `pc`; the caller deinits.
const Pair = struct {
    ref: h.Machine,
    dut: h.Machine,

    fn init(program: []const u32, pc: u32) !Pair {
        var p: Pair = .{ .ref = try h.Machine.init(.cached), .dut = undefined };
        errdefer p.ref.deinit();
        p.dut = try h.Machine.init(.jit);
        for ([_]*h.Machine{ &p.ref, &p.dut }) |m| {
            h.poke(m.bus, 0x80, &.{ mips.beq(zero, zero, -1), mips.nop });
            h.poke(m.bus, pc & 0x1F_FFFF, program);
            m.start(pc);
        }
        return p;
    }

    fn deinit(p: *Pair) void {
        p.ref.deinit();
        p.dut.deinit();
    }

    /// `runs` dispatcher calls on each, compared after every one.
    fn expectSameRuns(p: *Pair, runs: u32) !void {
        for (0..runs) |_| {
            try expectEqual(p.ref.cpu.run(), p.dut.cpu.run());
            try h.expectSameMachine(&p.ref, &p.dut);
        }
        // The JIT really ran: code was emitted.
        try expect(p.dut.bus.blocks.?.code.?.used > 0);
    }
};

fn expectSameRuns(program: []const u32, pc: u32, runs: u32) !void {
    if (!jit.available) return error.SkipZigTest;
    var p = try Pair.init(program, pc);
    defer p.deinit();
    try p.expectSameRuns(runs);
}

test ".jit equals .cached: a loop with loads, stores and delay slots" {
    try expectSameRuns(&h.loop_program, 0x8000_1000, 40);
}

test ".jit equals .cached: the same loop through KSEG1" {
    try expectSameRuns(&h.loop_program, 0xA000_1000, 40);
}

test ".jit equals .cached: an overflow and a misaligned load fault precisely" {
    try expectSameRuns(&.{
        mips.lui(t1, 0x7FFF),
        mips.ori(t1, t1, 0xFFFF),
        mips.add(t2, t1, t1), // overflow
        mips.nop,
    }, 0x1000, 4);
    try expectSameRuns(&.{
        mips.addiu(t1, zero, 0x2001),
        mips.lw(t2, t1, 0), // misaligned: address error
        mips.nop,
    }, 0x1000, 4);
}

test ".jit equals .cached: an MMIO store ends the block and ticks SIO" {
    try expectSameRuns(&(.{
        mips.lui(t1, 0x1F80),
        mips.addiu(t0, zero, 1),
        mips.i(0x28, t1, t0, 0x1040), // sb t0, 0x1040(t1): JOY_TX, a pad byte arms /ACK
        mips.lw(t2, t1, 0x1120), // timer 2: the cycles so far
    } ++ h.nops(20) ++ .{
        mips.lw(t3, t1, 0x1120),
        mips.beq(zero, zero, -1),
        mips.nop,
    }), 0x1000, 12);
}

test ".jit equals .cached: a store into the running block" {
    try expectSameRuns(&.{
        mips.addiu(t1, zero, 0x1010),
        mips.lui(t0, 0x240A),
        mips.ori(t0, t0, 0x0055), // t0 = addiu t2, zero, 0x55
        mips.sw(t0, t1, 0), // rewrites 0x1010, the next word
        mips.addiu(t2, zero, 0x11), // 0x1010: never runs in its old form
        mips.beq(zero, zero, -1),
        mips.nop,
    }, 0x1000, 6);
}

test ".jit equals .cached: a branch in a branch's delay slot" {
    try expectSameRuns(&.{
        mips.beq(zero, zero, 3), // -> 0x1010
        mips.j(0x1018), // its delay slot: runs, and its own delay slot is 0x1010
        mips.addiu(t0, zero, 1),
        mips.addiu(t1, zero, 2),
        mips.addiu(t2, zero, 3), // 0x1010
        mips.addiu(t3, zero, 4),
        mips.beq(zero, zero, -1), // 0x1018
        mips.nop,
    }, 0x1000, 8);
}

test "engine selection creates, switches and frees the JIT's cache" {
    var m = try h.Machine.init(.cached);
    defer m.deinit();
    if (!jit.available) {
        try std.testing.expectError(error.EngineUnavailable, recompiler.setEngine(&m.cpu, alloc, .jit));
        return;
    }
    h.poke(m.bus, 0x1000, &.{ mips.beq(zero, zero, -1), mips.nop });
    m.start(0x1000);
    _ = m.cpu.run();
    try expect(m.bus.blocks.?.lookup(0x1000).?.code == null); // .cached emits nothing

    try recompiler.setEngine(&m.cpu, alloc, .jit);
    try expectEqual(Engine.jit, recompiler.engineOf(m.bus));
    const c = m.bus.blocks.?;
    try expectEqual(@as(?*block.Block, null), c.lookup(0x1000)); // a fresh cache
    _ = m.cpu.run();
    try expect(c.lookup(0x1000).?.code != null);
    try recompiler.setEngine(&m.cpu, alloc, .jit); // re-applied: kept as it is
    try expect(m.bus.blocks.? == c);
    try expect(c.lookup(0x1000) != null);

    try recompiler.setEngine(&m.cpu, alloc, .cached);
    try expectEqual(Engine.cached, recompiler.engineOf(m.bus));
    try expectEqual(@as(?*block.Block, null), m.bus.blocks.?.lookup(0x1000));
    try recompiler.setEngine(&m.cpu, alloc, .interpreter);
    try expectEqual(@as(?*BlockCache, null), m.bus.blocks);
    // The testing allocator fails the test if a switch leaked a cache.
}

test "a full code buffer flushes every block and compiles on" {
    if (!jit.available) return error.SkipZigTest;
    var m = try h.Machine.init(.jit);
    defer m.deinit();
    const c = m.bus.blocks.?;
    // One 16 KB page. A 64-nop block is about 3.6 KB of code, so eight of
    // them cannot all fit.
    c.code.?.deinit();
    c.code = try jit.CodeBuffer.init(16 << 10);
    h.poke(m.bus, 0x1000, &(h.nops(64 * 8) ++ .{ mips.beq(zero, zero, -1), mips.nop }));
    m.start(0x1000);
    var flushed = false;
    var high: usize = 0;
    for (0..8) |_| {
        _ = m.cpu.run();
        const used = c.code.?.used;
        if (used < high) flushed = true;
        high = used;
    }
    try expect(flushed);
    try expectEqual(@as(?*block.Block, null), c.lookup(0x1000)); // went with the flush
    try expectEqual(@as(u32, 0x1000 + 64 * 8 * 4), m.cpu.pipeline.pc); // and every block ran
}

test "lockstep checks JIT blocks" {
    if (!jit.available) return error.SkipZigTest;
    var m = try h.Machine.init(.jit);
    defer m.deinit();
    var checker: recompiler.lockstep.Checker = .{};
    m.bus.blocks.?.lockstep = &checker;
    h.poke(m.bus, 0x1000, &h.loop_program);
    m.start(0x8000_1000);
    try m.runUntil(0x8000_1048);
    try expectEqual(@as(?recompiler.lockstep.Mismatch, null), checker.mismatch);
    try expect(checker.checked >= 10);
    try expect(m.bus.blocks.?.lookup(0x1000).?.code != null);
}
```

If `mips.i` is not `pub` after Task 3's move, make it `pub`: the JOY_TX
store uses it as a raw `sb`.

In `ps1-core/tests/recompiler_test.zig`, delete this line from the test
"engine selection allocates, switches and frees the cache". The new jit
test owns that case, per target:

```zig
    try std.testing.expectError(error.EngineUnavailable, recompiler.setEngine(&m.cpu, alloc, .jit));
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test 2>&1 | grep -m5 -E "error|fail"`
Expected: a compile error, because `BlockCache` has no field `code`.

- [ ] **Step 3: Give the cache its code buffer**

In `ps1-core/src/recompiler/cache.zig`, add an import below
`const lockstep = @import("lockstep.zig");`:

```zig
const code_buffer = @import("arm64/code_buffer.zig");
```

Add a field after `lockstep`:

```zig
    /// The JIT's code memory, owned here. Its presence is what makes the
    /// engine `.jit` (`run.engineOf`); null under `.cached`.
    code: ?code_buffer.CodeBuffer = null,
```

At the end of `destroy`, before `self.allocator.destroy(self);`, add:

```zig
        if (comptime code_buffer.available) {
            if (self.code) |*buf| buf.deinit();
        }
```

At the end of `flush`, after `self.running = null;`, add:

```zig
        // Every block that could call into the buffer is gone.
        if (self.code) |*buf| buf.reset();
```

- [ ] **Step 4: Select, compile and run `.jit` in the dispatcher**

In `ps1-core/src/recompiler/run.zig`, replace `setEngine` and `engineOf`:

```zig
/// Selects the CPU engine. A block engine's cache lives on `Bus` (see
/// `Bus.blocks`), so a frontend that swaps in a fresh `Bus` re-applies its
/// engine the way it re-applies its PGXP settings. Call between `run()`s.
/// Re-applying the current engine does nothing: the I-cache and the compiled
/// blocks are left as they are. `.jit` is unavailable off arm64 macOS, and
/// where MAP_JIT is refused.
pub fn setEngine(cpu: *Cpu, allocator: std.mem.Allocator, engine: Engine) error{ OutOfMemory, EngineUnavailable }!void {
    const bus = cpu.bus;
    if (engineOf(bus) == engine) return;
    const next: ?*BlockCache = switch (engine) {
        .interpreter => null,
        .cached => try BlockCache.create(allocator),
        .jit => if (comptime jit.available) try createJitCache(allocator) else return error.EngineUnavailable,
    };
    if (bus.blocks) |old| old.destroy();
    bus.blocks = next;
    // The block engines leave the I-cache invalidated. Lines the interpreter
    // filled before a switch may describe RAM a block engine since rewrote.
    icache.flush(cpu);
}

fn createJitCache(allocator: std.mem.Allocator) error{ OutOfMemory, EngineUnavailable }!*BlockCache {
    const c = try BlockCache.create(allocator);
    errdefer c.destroy();
    c.code = jit.CodeBuffer.init(jit.buffer_bytes) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.EngineUnavailable,
    };
    return c;
}

pub fn engineOf(bus: *const Bus) Engine {
    const c = bus.blocks orelse return .interpreter;
    return if (c.code != null) .jit else .cached;
}
```

Add below `engineOf`:

```zig
/// A compiled block, on whichever engine compiled it: its host code when it
/// has some, its handler array otherwise.
pub fn executeBlock(cpu: *Cpu, b: *const block.Block, fetch_cost: u32) u32 {
    if (comptime jit.available) {
        if (b.code != null) return jit.execute(cpu, b, fetch_cost);
    }
    return cached.execute(cpu, b, fetch_cost);
}
```

In `run()`, replace

```zig
    const ran = if (c.lockstep) |l| l.execute(cpu, b, fetch_cost) else cached.execute(cpu, b, fetch_cost);
```

with

```zig
    const ran = if (c.lockstep) |l| l.execute(cpu, b, fetch_cost) else executeBlock(cpu, b, fetch_cost);
```

and change the comment on the compile fallback from
`// Out of memory for a block: the interpreter still runs.` to
`// No memory for a block, or no code space even after a flush: the interpreter still runs.`

Replace `compileInto`:

```zig
fn compileInto(c: *BlockCache, bus: *const Bus, pc: u32) !*block.Block {
    const b = try block.compile(c.allocator, bus, pc);
    errdefer block.destroy(c.allocator, b);
    if (comptime jit.available) {
        if (c.code) |*buf| b.code = jit.translate.compile(buf, b) catch retry: {
            // Full. There is no eviction policy (spec: Full flushes), and
            // between blocks nothing is running, so every block can go.
            c.flush();
            break :retry try jit.translate.compile(buf, b);
        };
    }
    try c.insert(pc & 0x1FFF_FFFF, b);
    return b;
}
```

- [ ] **Step 5: Run lockstep's engine through the same dispatch**

In `ps1-core/src/recompiler/lockstep.zig`, replace
`const cached = @import("cached.zig");` with
`const run = @import("run.zig");`. In `Checker.execute`, replace
`const ran = cached.execute(cpu, b, fetch_cost);` with:

```zig
        const ran = run.executeBlock(cpu, b, fetch_cost);
```

and replace `const ref_ran = reference(cpu, ran);` with:

```zig
        // Never past the block's own words: an engine that claims more
        // would send the reference fetching beyond them. The length check
        // below reports it instead.
        const ref_ran = reference(cpu, @min(ran, @as(u32, @intCast(b.ops.len))));
```

Change the doc comment of `Checker.execute` from "as `cached.execute`
does" to "as `run.executeBlock` does".

- [ ] **Step 6: Run the tests to verify they pass, and that wasm still builds**

Run: `zig build test 2>&1 | tail -5 && zig build`
Expected: PASS, and `zig build` exits 0. `setEngine`, `executeBlock` and
`compileInto` all reach the arm64 code only through
`if (comptime jit.available)`. A wasm compile error that names
`code_buffer.zig` or `translate.zig` means a guard is missing.

- [ ] **Step 7: Commit**

```bash
zig fmt ps1-core/src/recompiler ps1-core/tests/jit_test.zig ps1-core/tests/recompiler_test.zig
git add ps1-core/src/recompiler ps1-core/tests/jit_test.zig ps1-core/tests/recompiler_test.zig
git commit -m "feat(jit): select, compile and dispatch .jit blocks; flush on a full buffer"
```

---

### Task 5: The differential fuzzer

Random short MIPS programs run from the same random state under `.cached`
and `.jit`, and are compared after every `run()`. The seeds are fixed, so a
failure names the seed and the run that reproduce it. A fuzzer that never
reaches its edge cases proves nothing, so the test also asserts that the
programs it generated really overflowed, really faulted on alignment for a
load and for a store, really put a branch in a branch's delay slot, and
really cancelled a pending load.

**Files:**
- Test: `ps1-core/tests/jit_test.zig`

**Interfaces:**
- Consumes: `Pair`'s layout (vector spin at 0x80), `h.Machine`,
  `h.expectSameMachine`, `h.mips`, `h.gp` (Tasks 3-4).

- [ ] **Step 1: Write the fuzzer**

Append to `ps1-core/tests/jit_test.zig`:

```zig
const fuzz = struct {
    const programs = 1000;
    const len = 48;
    /// Forward branches and jumps skip at most this many words past their
    /// delay slot, into a tail of nops that ends in a spin loop.
    const max_skip = 8;
    const tail = max_skip + 2;
    const runs = 24;
    const base: u32 = 0x1000;
    /// Loads and stores address [$gp - 0x200, $gp + 0x200), inside this.
    const data_base: u32 = 0x3C00;
    const data_bytes = 0x800;
    const gp_value: u32 = 0x8000_4000;

    /// Values the sources start with, chosen to reach the edges: overflow,
    /// a divide by zero and INT_MIN / -1.
    const interesting = [_]u32{ 0, 1, 0xFFFF_FFFF, 0x7FFF_FFFF, 0x8000_0000, 0x8000_0001, 0xFFFF_8000 };

    const gte_nclip: u32 = 0x4B40_0006;
    const gte_rtps: u32 = 0x4A18_0001;

    const Gen = struct {
        rng: std.Random,

        fn pick(g: Gen, comptime T: type, items: []const T) T {
            return items[g.rng.uintLessThan(usize, items.len)];
        }
        fn src(g: Gen) u5 {
            return g.rng.int(u5);
        }
        /// Any register but $gp, which holds the data window's base. $zero
        /// stays in: a write to it must be dropped.
        fn dst(g: Gen) u5 {
            const r = g.rng.int(u5);
            return if (r == h.gp) zero else r;
        }
        /// Any alignment, so word and halfword accesses also fault.
        fn dataOffset(g: Gen) u16 {
            return @bitCast(g.rng.intRangeLessThan(i16, -0x200, 0x200));
        }

        fn instr(g: Gen, at: usize) u32 {
            return switch (g.rng.uintLessThan(u32, 12)) {
                0 => mips.r(g.src(), g.src(), g.dst(), g.pick(u32, &.{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B })),
                1 => mips.r(0, g.src(), g.dst(), g.pick(u32, &.{ 0x00, 0x02, 0x03 })) | @as(u32, g.rng.int(u5)) << 6,
                2 => mips.r(g.src(), g.src(), g.dst(), g.pick(u32, &.{ 0x04, 0x06, 0x07 })),
                3 => mips.i(g.pick(u32, &.{ 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F }), g.src(), g.dst(), g.rng.int(u16)),
                4 => mips.r(g.src(), g.src(), zero, g.pick(u32, &.{ 0x18, 0x19, 0x1A, 0x1B })), // MULT, MULTU, DIV, DIVU
                5 => switch (g.rng.uintLessThan(u32, 4)) {
                    0 => mips.r(0, 0, g.dst(), 0x10), // MFHI
                    1 => mips.r(g.src(), 0, 0, 0x11), // MTHI
                    2 => mips.r(0, 0, g.dst(), 0x12), // MFLO
                    else => mips.r(g.src(), 0, 0, 0x13), // MTLO
                },
                6 => mips.i(g.pick(u32, &.{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26 }), h.gp, g.dst(), g.dataOffset()),
                7 => mips.i(g.pick(u32, &.{ 0x28, 0x29, 0x2A, 0x2B, 0x2E }), h.gp, g.src(), g.dataOffset()),
                8, 9 => g.branch(at),
                10 => switch (g.rng.uintLessThan(u32, 3)) {
                    0 => 0x4880_0000 | @as(u32, g.src()) << 16 | @as(u32, g.rng.int(u5)) << 11, // MTC2
                    1 => 0x4800_0000 | @as(u32, g.dst()) << 16 | @as(u32, g.rng.int(u5)) << 11, // MFC2
                    else => g.pick(u32, &.{ mips.gte_sqr, gte_nclip, gte_rtps }),
                },
                else => g.pick(u32, &.{ mips.syscall, mips.brk, mips.nop }),
            };
        }

        /// Forward only, so every program ends.
        fn branch(g: Gen, at: usize) u32 {
            const skip = g.rng.uintAtMost(u16, max_skip);
            return switch (g.rng.uintLessThan(u32, 4)) {
                0 => mips.i(g.pick(u32, &.{ 0x04, 0x05 }), g.src(), g.src(), skip), // BEQ, BNE
                1 => mips.i(g.pick(u32, &.{ 0x06, 0x07 }), g.src(), 0, skip), // BLEZ, BGTZ
                2 => mips.i(0x01, g.src(), g.pick(u5, &.{ 0x00, 0x01, 0x10, 0x11 }), skip), // BLTZ, BGEZ, BLTZAL, BGEZAL
                else => g.pick(u32, &.{ 0x02, 0x03 }) << 26 | // J, JAL
                    (((base + 4 * (@as(u32, @intCast(at)) + 1 + skip)) >> 2) & 0x03FF_FFFF),
            };
        }
    };

    fn program(rng: std.Random) [len + tail]u32 {
        var words: [len + tail]u32 = undefined;
        const g: Gen = .{ .rng = rng };
        for (words[0..len], 0..) |*w, at| w.* = g.instr(at);
        for (words[len..][0..max_skip]) |*w| w.* = mips.nop;
        words[len + max_skip] = mips.beq(zero, zero, -1);
        words[len + max_skip + 1] = mips.nop;
        return words;
    }

    const State = struct {
        regs: [32]u32,
        hi: u32,
        lo: u32,
        data: [data_bytes]u8,
        pc: u32,

        fn random(rng: std.Random) State {
            var s: State = undefined;
            for (&s.regs) |*r| r.* = if (rng.boolean()) interesting[rng.uintLessThan(usize, interesting.len)] else rng.int(u32);
            s.regs[0] = 0;
            s.regs[h.gp] = gp_value;
            s.hi = rng.int(u32);
            s.lo = rng.int(u32);
            rng.bytes(&s.data);
            s.pc = if (rng.boolean()) 0x8000_0000 | base else 0xA000_0000 | base; // both fetch costs
            return s;
        }

        fn apply(s: *const State, m: *h.Machine, words: []const u32) void {
            m.cpu = Cpu.init(m.bus);
            m.cpu.regs = s.regs;
            m.cpu.hi = s.hi;
            m.cpu.lo = s.lo;
            m.cpu.cop0.writeReg(.sr, 1 << 30); // CU2: the GTE ops run instead of faulting
            // Below any code page, so a host copy needs no invalidation.
            @memcpy(m.bus.ram[data_base..][0..data_bytes], &s.data);
            h.poke(m.bus, 0x80, &.{ mips.beq(zero, zero, -1), mips.nop });
            h.poke(m.bus, base, words); // through Bus.write: drops the last program's blocks
            m.start(s.pc);
        }
    };

    fn isBranch(w: u32) bool {
        const op = w >> 26;
        return (op >= 0x01 and op <= 0x07) or (op == 0 and ((w & 0x3F) == 0x08 or (w & 0x3F) == 0x09));
    }

    /// The register `w` writes through `writeReg`, if any: what cancels a
    /// load still in its delay slot.
    fn writes(w: u32) ?u5 {
        const op = w >> 26;
        const rt: u5 = @truncate(w >> 16);
        const rd: u5 = @truncate(w >> 11);
        if (op == 0) return switch (w & 0x3F) {
            0x00, 0x02, 0x03, 0x04, 0x06, 0x07, 0x10, 0x12, 0x20...0x27, 0x2A, 0x2B => rd,
            else => null,
        };
        return if (op >= 0x08 and op <= 0x0F) rt else null;
    }

    fn isLoad(w: u32) bool {
        return (w >> 26) >= 0x20 and (w >> 26) <= 0x26;
    }
};

const Cpu = ps1_core.cpu.Cpu;

test "fuzz: .jit equals .cached on random programs" {
    if (!jit.available) return error.SkipZigTest;
    var ref = try h.Machine.init(.cached);
    defer ref.deinit();
    var dut = try h.Machine.init(.jit);
    defer dut.deinit();

    var overflowed = false;
    var load_fault = false;
    var store_fault = false;
    var branch_in_delay_slot = false;
    var load_cancelled = false;

    for (0..fuzz.programs) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();
        const words = fuzz.program(rng);
        const state = fuzz.State.random(rng);
        state.apply(&ref, &words);
        state.apply(&dut, &words);

        for (0..fuzz.runs) |run_index| {
            const ran = ref.cpu.run();
            const dut_ran = dut.cpu.run();
            errdefer std.debug.print("fuzz: seed {d}, run {d}\n", .{ seed, run_index });
            try expectEqual(ran, dut_ran);
            try h.expectSameMachine(&ref, &dut);
        }

        switch (ref.cpu.cop0.readReg(.cause) >> 2 & 0x1F) {
            0x0C => overflowed = true,
            0x04 => load_fault = true,
            0x05 => store_fault = true,
            else => {},
        }
        for (words[0 .. fuzz.len - 1], words[1..fuzz.len]) |w, next| {
            if (fuzz.isBranch(w) and fuzz.isBranch(next)) branch_in_delay_slot = true;
            if (fuzz.isLoad(w) and fuzz.writes(next) == @as(u5, @truncate(w >> 16))) load_cancelled = true;
        }
    }
    // The generator really reached the cases it exists for.
    try expect(overflowed and load_fault and store_fault and branch_in_delay_slot and load_cancelled);
}
```

The coverage flags look at the program text, and at the last exception each
program took (`Cpu.init` zeroes Cause per program). A program that faults
early and never reaches the pair it contains still counts as covered by the
text check. With 1000 programs of 48 words that is deliberate: the
assertion catches a generator that cannot emit a case at all, not a seed
that happens to miss one.

- [ ] **Step 2: Run the fuzzer**

Run: `time zig build test -Dtest-filter="fuzz" 2>&1 | tail -5`
Expected: PASS. Note how long it takes, and if it exceeds ~20 s in Debug,
lower `fuzz.programs` until it does not. Record the count you keep.

A FAIL here prints the seed and the run. Reproduce it with
`fuzz.programs` set to `seed + 1`, then bisect which op diverged by
printing `ref.cpu.pipeline` and `dut.cpu.pipeline` before the failing run.
Do not weaken the comparison.

- [ ] **Step 3: Prove the fuzzer can fail**

Temporarily break the translator. In `translate.zig`, change
`em.put(e.addImm(.w, cost_reg, .x1, 1));` to
`em.put(e.addImm(.w, cost_reg, .x1, 2));`. Run Step 2's command.
Expected: FAIL, with a `fuzz: seed …` line and a `cycles` mismatch.
Revert the change and re-run. Expected: PASS.

- [ ] **Step 4: Commit**

```bash
zig fmt ps1-core/tests/jit_test.zig
git add ps1-core/tests/jit_test.zig
git commit -m "test(jit): differential fuzzer against the cached interpreter"
```

---

### Task 6: The gates, the measurements and the as-built notes

Nothing in this task changes core code. If a gate fails, stop and fix the
cause in the task that owns it. Never recapture to make a gate pass.

**Files:**
- Modify: `CLAUDE.md`
- Modify: `.claude/skills/ps1-test-harnesses/SKILL.md:110-113`
- Modify: `docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md` (new "As built (Plan 4)" section after Plan 3's)

- [ ] **Step 1: Unit tests and both builds**

Run: `zig build test 2>&1 | tail -3 && zig build && zig build capi-lib`
Expected: every test step passes, and `zig build` (wasm included) and
`capi-lib` build.

- [ ] **Step 2: The interpreter does not move**

Run each, `-Doptimize=ReleaseFast`:

```bash
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- savestate
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
zig build trace-golden -Doptimize=ReleaseFast -- pgxp
```

Expected: all OK, exactly as before this plan.

- [ ] **Step 3: `.jit` equals `.cached` on every workload**

```bash
zig build trace-golden -Doptimize=ReleaseFast -- verify --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- savestate --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- lockstep --engine=jit
```

Expected: `verify` OK on all nine against `trace-block/` with no capture,
`savestate` OK on all nine, `stream-verify` OK on all nine, and `lockstep`
0 mismatches. Record the checked and skipped counts per workload: they
should equal Plan 3's `.cached` numbers, since the two engines compile the
same blocks.

- [ ] **Step 4: The PGXP sweep reads what `.cached` reads**

```bash
zig build trace-golden -Doptimize=ReleaseFast -- pgxp --engine=cached > "$TMPDIR/pgxp-cached.txt" 2>&1
zig build trace-golden -Doptimize=ReleaseFast -- pgxp --engine=jit > "$TMPDIR/pgxp-jit.txt" 2>&1
diff "$TMPDIR/pgxp-cached.txt" "$TMPDIR/pgxp-jit.txt"
```

Expected: the diff is empty, or differs only in lines that name the engine
or a wall time. Plan 3's open item stands: `.cached` misses floors the
interpreter meets, and `.jit` will miss the same ones by the same amounts.
That is not this plan's to rule on. Do not lower a floor.

- [ ] **Step 5: The ROM suites**

```bash
zig build test-roms-ja -Doptimize=ReleaseFast -Dengine=jit
zig build test-roms-pl -Doptimize=ReleaseFast -Dengine=jit
```

Expected: JA 12/17 with the same five failing as under `.cached`
(Getloc, Timing, MDEC 4bit, MDEC 8bit, MDEC Step By Step Log), and PL
passing at its floors.

- [ ] **Step 6: Bench `.jit` against `.cached`**

```bash
zig build -Doptimize=ReleaseFast
CUE="games/Croc - Legend of the Gobbos/Croc - Legend of the Gobbos.cue"
for i in 1 2 3 4 5; do
  ./zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin "$CUE" 3000 --engine=cached
  ./zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin "$CUE" 3000 --engine=jit
done
```

Let the machine settle first (not straight after `trace-golden`). Record
the best of five for each. There is no target. The skeleton trades a
handler-array loop for straight-line code with two indirect calls per op,
and either result is information for Plan 5. Report it as measured.

- [ ] **Step 7: Update the docs**

`CLAUDE.md`:
- The `zig build test` row: "Runs **21 test binaries**: the 15
  `unit_test_files`" becomes "Runs **22 test binaries**: the 16
  `unit_test_files`".
- The `trace-golden -- verify` row: after "`--engine=cached` verifies a
  block engine against `ps1-core/tests/goldens/trace-block/` instead", add
  "; `--engine=jit` verifies against the same set".
- Repository layout, the `recompiler/` entry: add `jit.zig (backend 2:
  host code)` and a line `arm64/: emit.zig (encoder), code_buffer.zig
  (MAP_JIT), translate.zig (block -> host code)`.
- Repository layout, `tests/`: add `jit` to the unit list and change "all
  15" to "all 16". Add `recompiler_helpers` beside `rom_test_helpers`.

`.claude/skills/ps1-test-harnesses/SKILL.md`, the `trace-block/` paragraph:
"and the JIT (Plan 4) reuses them unchanged with `verify --engine=jit`"
becomes "and the JIT reuses them unchanged with `verify --engine=jit`
(OK on all nine since Plan 4)".

The spec gets an `### As built (Plan 4, <date>)` section after Plan 3's,
in the same style as that section:
- Names: `jit.available`, `jit.CodeBuffer` (`init`, `install`, `reset`),
  `jit.translate.compile`, `jit.execute`, `block.JitEntry`, `Block.code`,
  `BlockCache.code`, `run.executeBlock`, `cached.begin`/`commit`/`runOp`.
- The six deliberate departures from this plan's header, as built.
- What changed from this plan during the build, if anything.
- Measurements: Task 3's `.cached` before and after, Step 6's `.jit`
  against `.cached`.
- Gates: Steps 1-5's results, including the lockstep counts and the fuzzer's
  program count (and whether Task 5 lowered it).
- What Plan 5 inherits: `Block.segment` arrives with the static-cost
  immediate; lockstep must run with linking off, and must revisit the
  reference straying into MMIO once inline code can diverge; the x20-x22
  pinning starts there; `PS1_JIT_DUMP` and the lower/call mask arrive with
  the first lowering; the fuzzer is the per-family gate.

- [ ] **Step 8: Commit**

```bash
git add CLAUDE.md .claude/skills/ps1-test-harnesses/SKILL.md docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md
git commit -m "docs: Plan 4 as-built notes, the JIT skeleton's gates and bench"
```

If the spec file carries unrelated uncommitted edits from before this plan
(the owner's table re-alignment), stage only the new section with
`git add -p` and leave the rest for the owner.
