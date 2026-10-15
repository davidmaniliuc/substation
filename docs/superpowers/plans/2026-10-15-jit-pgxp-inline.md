# PGXP in Emitted Code Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Under PGXP, the JIT moves word load/store shadows, the register move, `exactValue` and ADDI/ADDIU's rule inline instead of calling Zig shims, byte-identical to `.cached`.

**Architecture:** The inline load/store paths compute the shadow table slot from the physical offset they already hold and copy 20-byte `Value`s with plain `ldr`/`str`. A new `recompiler/arm64/shadow_alu.zig` emits three CPU-mode rules (`ops.move`, `exactValue`, `ops.addi`). Each reads and writes exactly the memory its shim would, at the same point in the op. `ops.addi`'s float work is restated as the same IEEE f64 operations in the same order, on new FP encoders in `emit.zig`.

**Tech Stack:** Zig 0.17.0, arm64 machine code (macOS MAP_JIT), `zig build test`, `ps1-golden` (`trace-golden`), `ps1-bench-dual`.

**Spec:** `docs/superpowers/specs/2026-10-15-jit-pgxp-inline-design.md`

## Global Constraints

- Every shadow the emitted code writes is byte-identical to what the shim writes, floats included (`h.expectSameShadows` compares bytes, NaN payloads included).
- The interpreter and `.cached` do not change. PGXP-off emitted code does not change (`verify --engine=jit` output identical to the parent).
- `lh`/`lhu`/`sh` keep their shims (`shadowLoadHalf` mutates the slot).
- Only `addi`/`addiu` get float rules inline. `add`/`sub`/shifts/`andi`/`bitwise` keep `shadow.hooked`.
- Scratch registers within one op: w9-w13 and x16 (general), d0-d6 (FP). Nothing FP stays live across an op or a call.
- Commit messages are a title line only: no body, no trailer. Commit straight to master. **Never `git push`.**
- `zig fmt` every touched `.zig` file before committing.
- No file in `ps1-core/src` over ~600 lines. No reference-emulator names in code or commits.
- Run unit tests in Debug (`zig build test`). `-Doptimize=ReleaseFast` SEGVs in an unrelated `pgxp_test` case. Run `trace-golden` and the bench in ReleaseFast.

## Review Focus

- **Non-finite and signed-zero shadow floats** (NaN, ±inf, -0.0 in `x`/`y`) must come out byte-identical. Pinned by Task 5's differential table, which includes them.
- **`rd == rs` aliasing** for the move and for ADDI/ADDIU: every source field is read before any destination is written. Pinned in Tasks 3 and 5.
- **A word store to the scratchpad** must land in `scratch_shadow`, not `ram_shadow`, from the cold path. Pinned in Task 2.
- **`rd == $zero` under the CPU tier** still validates its source (the shim's only effect there). Pinned in Tasks 3 and 5.
- **The base tier** must never run a CPU-mode rule: ADDIU and LUI still just clear. Already pinned by `".jit equals .cached under PGXP: inline ALU clears or hooks shadows..."`. Run it in every task.

---

### Task 1: FP and shifted-add encoders

**Files:**
- Modify: `ps1-core/src/recompiler/arm64/emit.zig` (append after `memReg`)
- Modify: `ps1-core/src/recompiler/arm64/emitter.zig` (add `fconst` after `movImm64`)
- Test: `ps1-core/tests/jit_test.zig` (`"the encoder matches the assembler"` cases)

**Interfaces:**
- Produces (emit.zig):
  - `pub const FReg = enum(u5) { v0, v1, v2, v3, v4, v5, v6, v7 }`
  - `pub const Prec = enum(u1) { s, d }`
  - `addRegLsl(width: Width, rd: Reg, rn: Reg, rm: Reg, amount: u6) u32`
  - `sxth(rd: Reg, rn: Reg) u32`
  - `fmovFromGp(p: Prec, rd: FReg, rn: Reg) u32`
  - `scvtf(p: Prec, rd: FReg, width: Width, rn: Reg) u32`
  - `fcvtzsX(rd: Reg, rn: FReg) u32`
  - `fcvt(to: Prec, rd: FReg, rn: FReg) u32`
  - `pub const FOp = enum(u32) { fmul, fdiv, fadd, fsub }` and `farith(op: FOp, p: Prec, rd: FReg, rn: FReg, rm: FReg) u32`
  - `fcmp(p: Prec, rn: FReg, rm: FReg) u32` and `fcmpZero(p: Prec, rn: FReg) u32`
  - `fcsel(p: Prec, rd: FReg, rn: FReg, rm: FReg, cond: Cond) u32`
  - `pub const FMemImm = enum(u32) { str_s, ldr_s }` and `fmemImm(op: FMemImm, rt: FReg, rn: Reg, offset: u32) u32`
- Produces (emitter.zig): `Emitter.fconst(em, rd: e.FReg, value: f64) void`. It clobbers x16.

- [ ] **Step 1: Write the failing test.** In `jit_test.zig`, append these cases to the `cases` array of `"the encoder matches the assembler"`. The words were assembled with `clang -arch arm64 -c` and read back with `objdump -d`:

```zig
        .{ emit.addRegLsl(.w, .x13, .x13, .x13, 2), 0x0b0d09ad }, // add w13, w13, w13, lsl #2
        .{ emit.addRegLsl(.x, .x12, .x12, .x13, 2), 0x8b0d098c }, // add x12, x12, x13, lsl #2
        .{ emit.sxth(.x10, .x9), 0x13003d2a }, // sxth w10, w9
        .{ emit.csel(.w, .x10, .x10, .zr, .eq), 0x1a9f014a }, // csel w10, w10, wzr, eq
        .{ emit.ubfx(.x13, .x10, 1, 1), 0x5301054d }, // ubfx w13, w10, #1, #1
        .{ emit.shiftImm(.asr, .x13, .x11, 16), 0x13107d6d }, // asr w13, w11, #16
        .{ emit.fmovFromGp(.d, .v0, .x9), 0x9e670120 }, // fmov d0, x9
        .{ emit.fmovFromGp(.s, .v1, .x9), 0x1e270121 }, // fmov s1, w9
        .{ emit.fmovFromGp(.d, .v3, .zr), 0x9e6703e3 }, // fmov d3, xzr
        .{ emit.fmovFromGp(.d, .v2, .x16), 0x9e670202 }, // fmov d2, x16
        .{ emit.scvtf(.s, .v0, .w, .x9), 0x1e220120 }, // scvtf s0, w9
        .{ emit.scvtf(.d, .v0, .w, .x9), 0x1e620120 }, // scvtf d0, w9
        .{ emit.scvtf(.d, .v1, .x, .x9), 0x9e620121 }, // scvtf d1, x9
        .{ emit.scvtf(.d, .v1, .w, .x13), 0x1e6201a1 }, // scvtf d1, w13
        .{ emit.scvtf(.s, .v4, .w, .x13), 0x1e2201a4 }, // scvtf s4, w13
        .{ emit.fcvtzsX(.x9, .v0), 0x9e780009 }, // fcvtzs x9, d0
        .{ emit.fcvtzsX(.x13, .v1), 0x9e78002d }, // fcvtzs x13, d1
        .{ emit.fcvt(.d, .v0, .v0), 0x1e22c000 }, // fcvt d0, s0
        .{ emit.fcvt(.s, .v0, .v0), 0x1e624000 }, // fcvt s0, d0
        .{ emit.fcvt(.s, .v1, .v1), 0x1e624021 }, // fcvt s1, d1
        .{ emit.farith(.fadd, .d, .v0, .v0, .v1), 0x1e612800 }, // fadd d0, d0, d1
        .{ emit.farith(.fsub, .d, .v0, .v0, .v1), 0x1e613800 }, // fsub d0, d0, d1
        .{ emit.farith(.fmul, .d, .v0, .v0, .v1), 0x1e610800 }, // fmul d0, d0, d1
        .{ emit.farith(.fdiv, .d, .v0, .v0, .v1), 0x1e611800 }, // fdiv d0, d0, d1
        .{ emit.farith(.fsub, .d, .v4, .v0, .v2), 0x1e623804 }, // fsub d4, d0, d2
        .{ emit.farith(.fadd, .d, .v5, .v0, .v2), 0x1e622805 }, // fadd d5, d0, d2
        .{ emit.farith(.fmul, .d, .v1, .v0, .v2), 0x1e620801 }, // fmul d1, d0, d2
        .{ emit.farith(.fdiv, .d, .v1, .v1, .v2), 0x1e621821 }, // fdiv d1, d1, d2
        .{ emit.fcmp(.d, .v0, .v1), 0x1e612000 }, // fcmp d0, d1
        .{ emit.fcmpZero(.d, .v0), 0x1e602008 }, // fcmp d0, #0.0
        .{ emit.fcsel(.d, .v0, .v1, .v2, .gt), 0x1e62cc20 }, // fcsel d0, d1, d2, gt
        .{ emit.fcsel(.s, .v0, .v0, .v1, .ne), 0x1e211c00 }, // fcsel s0, s0, s1, ne
        .{ emit.fcsel(.d, .v6, .v5, .v0, .mi), 0x1e604ca6 }, // fcsel d6, d5, d0, mi
        .{ emit.fmemImm(.ldr_s, .v0, .x9, 0), 0xbd400120 }, // ldr s0, [x9]
        .{ emit.fmemImm(.ldr_s, .v1, .x9, 4), 0xbd400521 }, // ldr s1, [x9, #0x4]
        .{ emit.fmemImm(.str_s, .v0, .x9, 0), 0xbd000120 }, // str s0, [x9]
        .{ emit.fmemImm(.str_s, .v1, .x19, 0x40), 0xbd004261 }, // str s1, [x19, #0x40]
        .{ emit.fmemImm(.ldr_s, .v0, .x19, 0x44), 0xbd404660 }, // ldr s0, [x19, #0x44]
```

And a new test after it, for `fconst`:

```zig
test "an f64 constant is built in x16 from its non-zero halfwords" {
    var em: jit.emitter.Emitter = .{};
    em.fconst(.v2, 65536.0); // 0x40F0_0000_0000_0000
    try std.testing.expectEqualSlices(u32, &.{ emit.movz(.x, .x16, 0x40F0, 3), emit.fmovFromGp(.d, .v2, .x16) }, em.hot[0..em.lens[0]]);
    em.reset();
    em.fconst(.v3, 0.0);
    try std.testing.expectEqualSlices(u32, &.{emit.fmovFromGp(.d, .v3, .zr)}, em.hot[0..em.lens[0]]);
    em.reset();
    em.fconst(.v1, -0.0); // the sign bit alone: not the zero register
    try std.testing.expectEqualSlices(u32, &.{ emit.movz(.x, .x16, 0x8000, 3), emit.fmovFromGp(.d, .v1, .x16) }, em.hot[0..em.lens[0]]);
    em.reset();
    em.fconst(.v1, 65535.0); // 0x40EF_FFE0_0000_0000: MOVZ the first non-zero halfword, MOVK the rest
    try std.testing.expectEqualSlices(u32, &.{ emit.movz(.x, .x16, 0xFFE0, 2), emit.movk(.x, .x16, 0x40EF, 3), emit.fmovFromGp(.d, .v1, .x16) }, em.hot[0..em.lens[0]]);
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `zig build test -Dtest-filter="encoder"` and `zig build test -Dtest-filter="f64 constant"`
Expected: compile errors, `no member named 'addRegLsl'` (and the rest).

- [ ] **Step 3: Implement.** Append to `emit.zig`:

```zig
/// ADD (shifted register), LSL by `amount`. Register 31 is the zero
/// register.
pub fn addRegLsl(width: Width, rd: Reg, rn: Reg, rm: Reg, amount: u6) u32 {
    return dpReg(width, 0x0B00_0000, rd, rn, rm) | @as(u32, amount) << 10;
}

/// SXTH on `w` registers: the low half, sign-extended.
pub fn sxth(rd: Reg, rn: Reg) u32 {
    return bitfield(true, rd, rn, 0, 15);
}

/// A SIMD&FP register. Which precision it is read as is the instruction's.
pub const FReg = enum(u5) {
    v0,
    v1,
    v2,
    v3,
    v4,
    v5,
    v6,
    v7,

    fn n(r: FReg) u32 {
        return @backingInt(r);
    }
};

/// Scalar FP precision: `s` (f32) or `d` (f64), the `ftype` field.
pub const Prec = enum(u1) {
    s,
    d,

    fn ftype(p: Prec) u32 {
        return @as(u32, @backingInt(p)) << 22;
    }
};

/// FMOV from a general register, bits unchanged: `s` from a `w`, `d` from
/// an `x`. Register 31 is the zero register.
pub fn fmovFromGp(p: Prec, rd: FReg, rn: Reg) u32 {
    const opcode: u32 = switch (p) {
        .s => 0x1E27_0000,
        .d => 0x9E67_0000,
    };
    return opcode | rn.n() << 5 | rd.n();
}

/// SCVTF: a signed `w` or `x` register, converted to `s` or `d`.
pub fn scvtf(p: Prec, rd: FReg, width: Width, rn: Reg) u32 {
    return width.sf() | 0x1E22_0000 | p.ftype() | rn.n() << 5 | rd.n();
}

/// FCVTZS, `d` to `x`: toward zero, saturating, NaN to 0. That is
/// `std.math.lossyCast(i64, ·)` exactly.
pub fn fcvtzsX(rd: Reg, rn: FReg) u32 {
    return 0x9E78_0000 | rn.n() << 5 | rd.n();
}

/// FCVT to `to` from the other precision. To `s` it rounds to nearest even,
/// as `@floatCast` does.
pub fn fcvt(to: Prec, rd: FReg, rn: FReg) u32 {
    const opcode: u32 = switch (to) {
        .d => 0x1E22_C000,
        .s => 0x1E62_4000,
    };
    return opcode | rn.n() << 5 | rd.n();
}

pub const FOp = enum(u32) {
    fmul = 0x0800,
    fdiv = 0x1800,
    fadd = 0x2800,
    fsub = 0x3800,
};

/// FMUL/FDIV/FADD/FSUB: `rd = rn op rm`.
pub fn farith(op: FOp, p: Prec, rd: FReg, rn: FReg, rm: FReg) u32 {
    return 0x1E20_0000 | p.ftype() | rm.n() << 16 | @backingInt(op) | rn.n() << 5 | rd.n();
}

/// FCMP. Unordered (a NaN) sets C and V: test `mi` for `<`, `gt` for `>`
/// and `ge` for `>=`, which are all false on it, as Zig's operators are.
/// `lt` is true on it.
pub fn fcmp(p: Prec, rn: FReg, rm: FReg) u32 {
    return 0x1E20_2000 | p.ftype() | rm.n() << 16 | rn.n() << 5;
}

/// FCMP against +0.0.
pub fn fcmpZero(p: Prec, rn: FReg) u32 {
    return 0x1E20_2008 | p.ftype() | rn.n() << 5;
}

/// FCSEL: `rd = cond ? rn : rm`.
pub fn fcsel(p: Prec, rd: FReg, rn: FReg, rm: FReg, cond: Cond) u32 {
    return 0x1E20_0C00 | p.ftype() | rm.n() << 16 | @as(u32, @backingInt(cond)) << 12 | rn.n() << 5 | rd.n();
}

/// LDR/STR of an `s` register (unsigned offset).
pub const FMemImm = enum(u32) {
    str_s = 0xBD00_0000,
    ldr_s = 0xBD40_0000,
};

/// `offset` is in bytes: a multiple of 4, below 16 KB.
pub fn fmemImm(op: FMemImm, rt: FReg, rn: Reg, offset: u32) u32 {
    const imm12: u12 = @intCast(@divExact(offset, 4));
    return @backingInt(op) | @as(u32, imm12) << 10 | rn.n() << 5 | rt.n();
}
```

Add to `Emitter` in `emitter.zig`, after `movImm64`:

```zig
    /// An f64 constant into `rd`, through x16: MOVZ and MOVK of its non-zero
    /// halfwords, then FMOV. Zero bits are the zero register; -0.0 is not.
    pub fn fconst(em: *Emitter, rd: e.FReg, value: f64) void {
        const bits: u64 = @bitCast(value);
        if (bits == 0) return em.put(e.fmovFromGp(.d, rd, .zr));
        var first = true;
        for (0..4) |k| {
            const half: u16 = @truncate(bits >> @intCast(16 * k));
            if (half == 0) continue;
            const hw: u2 = @intCast(k);
            em.put(if (first) e.movz(.x, .x16, half, hw) else e.movk(.x, .x16, half, hw));
            first = false;
        }
        em.put(e.fmovFromGp(.d, rd, .x16));
    }
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `zig build test -Dtest-filter="encoder"` then `zig build test -Dtest-filter="f64 constant"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
zig fmt ps1-core/src/recompiler/arm64/emit.zig ps1-core/src/recompiler/arm64/emitter.zig ps1-core/tests/jit_test.zig
git add ps1-core/src/recompiler/arm64/emit.zig ps1-core/src/recompiler/arm64/emitter.zig ps1-core/tests/jit_test.zig
git commit -m "feat(jit): scalar FP, SXTH and shifted-ADD encoders, and an f64 constant builder"
```

---

### Task 2: Word loads, word stores and byte stores move shadows inline

**Files:**
- Modify: `ps1-core/src/recompiler/cache.zig:35-61` (`Pins` fields), `:104` (`Pins` init)
- Modify: `ps1-core/src/recompiler/arm64/layout.zig` (offsets and asserts)
- Modify: `ps1-core/src/recompiler/arm64/shadow.zig` (`copyVia`, `slotAddress`, `afterLoad`, `afterStore`)
- Modify: `ps1-core/src/recompiler/arm64/lower_memory.zig` (`emitLoad`, `emitStore`, and the module comment)
- Test: `ps1-core/tests/jit_test.zig`

**Interfaces:**
- Consumes: `emit.addRegLsl` (Task 1).
- Produces:
  - `Pins.ram_shadow: [*]Value`, `Pins.scratch_shadow: [*]Value`, `Pins.pgxp_pending: *Value`
  - `layout.pins_ram_shadow`, `layout.pins_scratch_shadow`, `layout.pins_pgxp_pending`
  - `shadow.copyVia(em: *Emitter, via: e.Reg, dst: e.Reg, dst_off: u32, src: e.Reg, src_off: u32) void` (`copy` becomes `copyVia(.x9, …)`)
  - Test helpers in `jit_test.zig`: `callsInCode(m: *h.Machine, pc: u32) u32` and `pgxpCalls(program: []const u32, tier: jit.Pgxp) !u32`

- [ ] **Step 1: Write the failing tests.** Add to `jit_test.zig` after `"under PGXP an inline byte load clears its shadow without a call"`:

```zig
/// The calls into Zig (`blr`) in the block compiled at `pc`.
fn callsInCode(m: *h.Machine, pc: u32) u32 {
    const b = m.bus.blocks.?.lookup(pc & 0x1FFF_FFFF).?;
    const code = @as([*]const u32, @ptrCast(b.code.?))[0..b.code_words];
    var n: u32 = 0;
    for (code) |w| {
        if (w & 0xFFFF_FC1F == 0xD63F_0000) n += 1;
    }
    return n;
}

/// The calls into Zig PGXP at `tier` adds to the block `program` compiles
/// to. k1 points at the scratchpad.
fn pgxpCalls(program: []const u32, tier: jit.Pgxp) !u32 {
    var counts: [2]u32 = undefined;
    for ([_]bool{ false, true }, 0..) |on, k| {
        var m = try h.Machine.init(.jit);
        defer m.deinit();
        if (on) h.pgxpOn(&m, tier);
        h.poke(m.bus, 0x1000, program);
        m.cpu.regs[h.k1] = 0x1F80_0000;
        m.start(0x8000_1000);
        _ = m.cpu.run();
        counts[k] = callsInCode(&m, 0x1000);
    }
    return counts[1] - counts[0];
}

test "under PGXP inline word loads, word stores and byte stores make no call" {
    if (!jit.available) return error.SkipZigTest;
    for ([_]jit.Pgxp{ .base, .cpu }) |tier| {
        try expectEqual(@as(u32, 0), try pgxpCalls(&.{
            mips.lw(t0, zero, 0x2000),
            mips.sw(t1, zero, 0x2010),
            mips.i(0x28, zero, t1, 0x2018), // SB
            mips.lw(t3, h.k1, 0),
            mips.sw(t3, h.k1, 0x10),
            mips.i(0x28, h.k1, t3, 0x15), // SB
            mips.beq(zero, zero, -1),
            mips.nop,
        }, tier));
    }
}

test ".jit equals .cached under PGXP: a word store arms GP0 provenance and a byte store drops it, in RAM and the scratchpad" {
    if (!jit.available) return error.SkipZigTest;
    const k1 = h.k1;
    for ([_]jit.Pgxp{ .base, .cpu }) |tier| {
        for ([_]bool{ false, true }) |byte_last| {
            var p = try Pair.init(&.{
                mips.sw(t0, k1, 0x10),
                mips.sw(t1, zero, 0x2010),
                if (byte_last) mips.i(0x28, k1, t1, 0x11) else mips.sw(t1, k1, 0x14),
                mips.beq(zero, zero, -1),
                mips.nop,
            }, 0x8000_1000);
            defer p.deinit();
            for ([_]*h.Machine{ &p.ref, &p.dut }) |m| {
                h.pgxpOn(m, tier);
                m.cpu.regs[k1] = 0x1F80_0000;
                m.cpu.regs[t0] = 0x1234_5678;
                m.cpu.regs[t1] = 0x0009_000A;
                m.cpu.gpr_shadow[t0] = h.shadowOf(0x1234_5678);
                m.cpu.gpr_shadow[t1] = h.shadowOf(0x0009_000A);
                m.bus.scratch_shadow[0x14 / 4] = h.shadowOf(0xDEAD);
                m.start(0x8000_1000);
            }
            try p.expectSameRuns(2);
            // A word store leaves provenance armed; a byte store last drops it.
            try expectEqual(!byte_last, p.dut.bus.pgxp_pending.flags != 0);
            // The scratchpad store landed in the scratchpad's table.
            try expect(p.dut.bus.scratch_shadow[0x10 / 4].flags != 0);
            try expectEqual(@as(u32, 0), p.dut.bus.blocks.?.lookup(0x1000).?.calls);
        }
    }
}
```

Also update the comment in `"under PGXP an inline byte load clears its shadow without a call"` to say: "A byte load's shadow is always `Value.none` (`exec.loadShadow`), so it reads no table, where a word load's copies its slot."

- [ ] **Step 2: Run them to see them fail**

Run: `zig build test -Dtest-filter="make no call"`
Expected: FAIL. `pgxpCalls` returns 4 (two `loadShim`/`storeShim` calls per table, RAM and scratchpad, minus nothing).
Run: `zig build test -Dtest-filter="arms GP0 provenance"`
Expected: PASS (the shims are already exact). This test is the equality net for the change, not the red test.

- [ ] **Step 3: Implement `Pins` and `layout`.** In `cache.zig`, append to `Pins` after `load_shadows`:

```zig
    /// `Bus.ram_shadow`, `Bus.scratch_shadow` and `Bus.pgxp_pending`, which
    /// inline loads and stores move PGXP's shadows through.
    ram_shadow: [*]Value,
    scratch_shadow: [*]Value,
    pgxp_pending: *Value,
```

and extend the initialiser at line 104:

```zig
            .pins = .{
                .ram = &bus.ram,
                .scratchpad = &bus.scratchpad,
                .downcount = &bus.sched.downcount,
                .ram_blocks = ram.ptr,
                .ram_shadow = &bus.ram_shadow,
                .scratch_shadow = &bus.scratch_shadow,
                .pgxp_pending = &bus.pgxp_pending,
            },
```

In `layout.zig`, after `pins_ram_blocks`:

```zig
pub const pins_ram_shadow = @offsetOf(Pins, "ram_shadow");
pub const pins_scratch_shadow = @offsetOf(Pins, "scratch_shadow");
pub const pins_pgxp_pending = @offsetOf(Pins, "pgxp_pending");
```

and add the three to the doubleword assert list:

```zig
    for ([_]u32{ pins_running, pins_downcount, pins_link_site, pins_ram_blocks, block_link_entry, pins_ram_shadow, pins_scratch_shadow, pins_pgxp_pending }) |o| std.debug.assert(o < 32768 and o % 8 == 0);
```

- [ ] **Step 4: Implement the shadow moves in `shadow.zig`.** Replace `copy` with `copyVia`, keeping `copy` as its x9 form:

```zig
/// `[dst + dst_off] = [src + src_off]`, one `Value`, through `via`.
pub fn copyVia(em: *Emitter, via: e.Reg, dst: e.Reg, dst_off: u32, src: e.Reg, src_off: u32) void {
    for (0..words) |k| {
        const o: u32 = @intCast(k * 4);
        em.put(e.memImm(.ldr_w, via, src, src_off + o));
        em.put(e.memImm(.str_w, via, dst, dst_off + o));
    }
}

/// `[dst + dst_off] = [src + src_off]`, one `Value`. Clobbers w9.
pub fn copy(em: *Emitter, dst: e.Reg, dst_off: u32, src: e.Reg, src_off: u32) void {
    copyVia(em, .x9, dst, dst_off, src, src_off);
}

/// x12 the slot, in the table at `table` (a `Pins` offset), of the word
/// holding byte `offset` of that table's memory: `Bus.shadowSlot`'s index
/// for RAM's first 2 MB and the scratchpad. Clobbers w13.
pub fn slotAddress(em: *Emitter, table: u32, offset: e.Reg) void {
    comptime std.debug.assert(@sizeOf(Value) == 20);
    em.put(e.memImm(.ldr_x, .x12, t.pins_reg, table));
    em.put(e.shiftImm(.lsr, .x13, offset, 2));
    em.put(e.addRegLsl(.w, .x13, .x13, .x13, 2)); // the word's index * 5
    em.put(e.addRegLsl(.x, .x12, .x12, .x13, 2)); // * 4: * 20 bytes
}

/// Whether an inline access of `width` bytes moves its shadow through the
/// table itself (`slotAddress`), or leaves it to a shim. A word load copies
/// its slot, and a word or byte store writes it. A byte load reads no
/// table, and a half-word access validates or merges halves in its shim.
pub fn usesSlot(load: bool, width: u3) bool {
    return if (load) width == 4 else width != 2;
}
```

(Add `const std = @import("std");` to the imports.)

Replace `afterLoad` and `afterStore`:

```zig
/// At an inline load's `done`: the shadow it issues, into its value's slot.
/// For a word x12 is the table slot (`slotAddress`). For a half w9 still
/// holds the address and `value` the loaded word, extended as the handler
/// extends it.
pub fn afterLoad(ctx: *t.Ctx, width: u3, signed: bool, value: e.Reg) void {
    const em = ctx.em;
    const slot_off: u32 = @intCast(layout.pinsLoadShadow(model.slot(value)));
    switch (width) {
        // A byte keeps no shadow (`exec.loadShadow`).
        1 => clear(em, t.pins_reg, slot_off),
        // `Bus.shadowLoad`: the word's shadow as the table holds it.
        4 => copy(em, t.pins_reg, slot_off, .x12, 0),
        // `Bus.shadowLoadHalf` validates and rewrites the slot: its shim.
        2 => {
            em.put(e.movReg(.w, .x2, .x9));
            em.put(e.movReg(.x, .x0, t.cpu_reg));
            em.put(e.addImm(.x, .x1, t.pins_reg, @intCast(slot_off)));
            em.put(e.movReg(.w, .x3, value));
            em.put(e.movz(.w, .x4, @backingInt(sized(exec.LoadType, width)), 0));
            em.put(e.movz(.w, .x5, @intFromBool(signed), 0));
            em.call(@intFromPtr(&loadShim));
        },
        else => unreachable,
    }
}

/// At an inline store's `done`, before the op retires: what the store does
/// to the shadows (`exec.storeShadow`). A load landing in `rt` has not
/// landed yet, so the store carries `rt`'s old shadow, as it carries its
/// old value. For a word or a byte x12 is the table slot (`slotAddress`);
/// for a half w9 still holds the address.
pub fn afterStore(ctx: *t.Ctx, width: u3, rt: u5) void {
    const em = ctx.em;
    switch (width) {
        // `rt`'s shadow to the slot and to the GP0 provenance.
        4 => {
            copy(em, .x12, 0, t.cpu_reg, layout.shadow(rt));
            em.put(e.memImm(.ldr_x, .x12, t.pins_reg, layout.pins_pgxp_pending));
            copy(em, .x12, 0, t.cpu_reg, layout.shadow(rt));
        },
        // The word's shadow destroyed, and the provenance dropped.
        1 => {
            clear(em, .x12, 0);
            em.put(e.memImm(.ldr_x, .x12, t.pins_reg, layout.pins_pgxp_pending));
            clear(em, .x12, 0);
        },
        // `Bus.shadowStoreHalf` merges one half: its shim.
        2 => {
            em.put(e.movReg(.w, .x1, .x9));
            em.put(e.movReg(.x, .x0, t.cpu_reg));
            em.put(e.movz(.w, .x2, rt, 0));
            em.put(e.movz(.w, .x3, @backingInt(sized(exec.StoreType, width)), 0));
            em.call(@intFromPtr(&storeShim));
        },
        else => unreachable,
    }
}
```

Update `shadow.zig`'s module comment to say that word and byte accesses move shadows through the tables inline, and half-words call their handler's rule.

- [ ] **Step 5: Compute the slot on both paths in `lower_memory.zig`.** In `emitLoad`, after the RAM path's `addImm(... ram_access_wait)` and before `em.bind(done)`:

```zig
    const pgxp_slot = ctx.opts.pgxp != .off and shadow.usesSlot(true, form.width);
    if (pgxp_slot) shadow.slotAddress(em, layout.pins_ram_shadow, .x10);
```

and in its cold scratchpad path, between the `memReg(... t.scratch_reg ...)` load and `em.branch(.b, done)`:

```zig
    if (pgxp_slot) shadow.slotAddress(em, layout.pins_scratch_shadow, .x11);
```

In `emitStore`, the same: after the RAM path's `addImm(... ram_access_wait)`:

```zig
    const pgxp_slot = ctx.opts.pgxp != .off and shadow.usesSlot(false, form.width);
    if (pgxp_slot) shadow.slotAddress(em, layout.pins_ram_shadow, .x10);
```

and in its cold path before `em.branch(.b, done)`:

```zig
    if (pgxp_slot) shadow.slotAddress(em, layout.pins_scratch_shadow, .x11);
```

Add `const layout = @import("layout.zig");` to the imports. Update the module comment's PGXP paragraph: "Under PGXP a word load copies its table slot, and a word or byte store writes its slot and the GP0 provenance, inline. A half-word runs its handler's rule through a shim. The slow path never reaches either, so the rule runs once."

- [ ] **Step 6: Run the tests to see them pass**

Run: `zig build test -Dtest-filter="PGXP"`
Expected: PASS, `"make no call"` included.
Run: `zig build test -Dtest-filter="fuzz"`
Expected: PASS (the linked fuzzer under both tiers compares every shadow byte).

- [ ] **Step 7: Commit**

```bash
zig fmt ps1-core/src/recompiler ps1-core/tests/jit_test.zig
git add ps1-core/src/recompiler ps1-core/tests/jit_test.zig
git commit -m "perf(jit): word loads, word stores and byte stores move PGXP shadows through the tables inline"
```

---

### Task 3: The move idiom and the exact ops retire inline

**Files:**
- Create: `ps1-core/src/recompiler/arm64/shadow_alu.zig`
- Modify: `ps1-core/src/recompiler/arm64/lower_alu.zig` (`retire`, `move`, module comment)
- Modify: `ps1-core/src/recompiler/arm64/shadow.zig` (delete `move`)
- Test: `ps1-core/tests/jit_test.zig`

**Interfaces:**
- Consumes: `emit.sxth`, `emit.scvtf`, `emit.fmemImm`, `emit.csel` (Task 1), `shadow.copy` (Task 2).
- Produces:
  - `shadow_alu.move(ctx: *t.Ctx, rd: u5, rs: u5) void`
  - `shadow_alu.exact(ctx: *t.Ctx, rd: u5) void`, with `rd != 0`
  - `shadow_alu.validate(em: *t.Emitter, rs: u5) void`, file-private, used again by Task 5: leaves w10 the validated flags and w11 `regs[rs]`
  - `lower_alu.is(comptime hook: anytype, comptime f: anytype) bool`

- [ ] **Step 1: Write the failing tests** in `jit_test.zig`, after Task 2's tests:

```zig
test "under PGXP the move idiom and the exact ops retire without a call" {
    if (!jit.available) return error.SkipZigTest;
    const move = mips.addu(t0, t1, zero);
    try expectEqual(@as(u32, 0), try pgxpCalls(&.{ move, mips.beq(zero, zero, -1), mips.nop }, .base));
    try expectEqual(@as(u32, 0), try pgxpCalls(&.{
        move,
        mips.lui(t2, 0x8000),
        mips.i(0x0A, t1, t3, 0xFFFF), // SLTI
        mips.i(0x0B, t1, t4, 5), // SLTIU
        mips.r(t1, t0, t5, 0x2A), // SLT
        mips.r(t1, t0, t6, 0x2B), // SLTU
        mips.beq(zero, zero, -1),
        mips.nop,
    }, .cpu));
}

test ".jit equals .cached under PGXP: a move validates a stale source, onto itself, into $zero and from $zero" {
    if (!jit.available) return error.SkipZigTest;
    for ([_]jit.Pgxp{ .base, .cpu }) |tier| {
        var p = try Pair.init(&.{
            mips.addu(t1, t0, zero), // stale t0: dropped in the table, copied
            mips.addu(t2, t2, zero), // onto itself
            mips.r(t3, zero, zero, 0x25), // OR $zero, t3, $zero: validates t3 only
            mips.addu(t4, zero, zero), // from $zero: none
            mips.addu(t5, t6, zero), // a live source
            mips.beq(zero, zero, -1),
            mips.nop,
        }, 0x8000_1000);
        defer p.deinit();
        for ([_]*h.Machine{ &p.ref, &p.dut }) |m| {
            h.pgxpOn(m, tier);
            for ([_]u5{ t0, t2, t3 }, [_]u32{ 5, 7, 9 }) |r, v| {
                m.cpu.regs[r] = v;
                m.cpu.gpr_shadow[r] = h.shadowOf(v + 1); // recorded against another word
            }
            m.cpu.gpr_shadow[t4] = h.shadowOf(0);
            m.cpu.regs[t6] = 0x0003_0004;
            m.cpu.gpr_shadow[t6] = h.shadowOf(0x0003_0004);
        }
        try p.expectSameRuns(2);
        for ([_]u5{ t0, t1, t2, t3, t4 }) |r| try expectEqual(@as(u32, 0), p.dut.cpu.gpr_shadow[r].flags);
        try expect(p.dut.cpu.gpr_shadow[t5].flags != 0);
    }
}

test ".jit equals .cached under PGXP's CPU mode: lui and the set ops write an exact shadow" {
    if (!jit.available) return error.SkipZigTest;
    var p = try Pair.init(&.{
        mips.lui(t0, 0x8000), // a negative high half
        mips.i(0x0A, t1, t2, 0xFFFF), // SLTI t2, t1, -1
        mips.i(0x0B, t1, t3, 5), // SLTIU
        mips.r(t1, t0, t4, 0x2A), // SLT t4, t1, t0
        mips.r(t1, t0, t5, 0x2B), // SLTU
        mips.beq(zero, zero, -1),
        mips.nop,
    }, 0x8000_1000);
    defer p.deinit();
    for ([_]*h.Machine{ &p.ref, &p.dut }) |m| {
        h.pgxpOn(m, .cpu);
        m.cpu.regs[t1] = 0xFFFF_FFF0;
        for ([_]u5{ t0, t1, t2, t3, t4, t5 }) |r| m.cpu.gpr_shadow[r] = h.shadowOf(m.cpu.regs[r]);
    }
    try p.expectSameRuns(2);
    try expectEqual(@as(f32, -32768), p.dut.cpu.gpr_shadow[t0].y);
    try expectEqual(Value.valid_xy, p.dut.cpu.gpr_shadow[t0].flags);
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `zig build test -Dtest-filter="retire without a call"`
Expected: FAIL (base 1, CPU 6: one `Hooked` shim per op).
The two equality tests PASS already; they are the net for Step 3.

- [ ] **Step 3: Implement `shadow_alu.zig`:**

```zig
//! PGXP's CPU-mode ALU rules emitted inline where they can be stated
//! exactly: the register move (`ops.move`, in both tiers), `exactValue`
//! (`ops.exact`, `ops.sltReg`), and ADDI/ADDIU (`ops.addi`). Each reads and
//! writes the memory its shim reads and writes, at the same point in the
//! op, so `.jit` stays byte-identical to `.cached`. Every other hook keeps
//! its shim (`shadow.hooked`).
//!
//! The op's result is in w9 on entry. Scratch: w10-w13, x16, d0-d6.

const e = @import("emit.zig");
const t = @import("translate.zig");
const layout = @import("layout.zig");
const shadow = @import("shadow.zig");
const Value = @import("../../pgxp/pgxp.zig").Value;

const x_off = @offsetOf(Value, "x");
const y_off = @offsetOf(Value, "y");
const z_off = @offsetOf(Value, "z");
const word_off = @offsetOf(Value, "word");
const flags_off = @offsetOf(Value, "flags");

/// `ops.source(rs)`: a shadow recorded against another word than `rs`
/// holds loses its flags, in the table too. Leaves w10 the validated flags
/// and w11 `rs`'s value.
fn validate(em: *t.Emitter, rs: u5) void {
    const s = layout.shadow(rs);
    em.put(e.memImm(.ldr_w, .x10, t.cpu_reg, s + word_off));
    em.put(e.memImm(.ldr_w, .x11, t.cpu_reg, layout.reg(rs)));
    em.put(e.cmpReg(.w, .x10, .x11));
    em.put(e.memImm(.ldr_w, .x10, t.cpu_reg, s + flags_off));
    em.put(e.csel(.w, .x10, .x10, .zr, .eq));
    em.put(e.memImm(.str_w, .x10, t.cpu_reg, s + flags_off));
}

/// The register move: `rs`'s shadow validated, then copied with the value
/// to `rd`. $zero's shadow is always none, which validates as itself. The
/// value is stored first, because the copy takes w9.
pub fn move(ctx: *t.Ctx, rd: u5, rs: u5) void {
    const em = ctx.em;
    if (rs != 0) validate(em, rs);
    if (rd == 0) return;
    em.put(e.memImm(.str_w, .x9, t.cpu_reg, layout.reg(rd)));
    shadow.copy(em, t.cpu_reg, layout.shadow(rd), t.cpu_reg, layout.shadow(rs));
}

/// `exactValue(result)`: both halves exact, no depth. Reads no source.
pub fn exact(ctx: *t.Ctx, rd: u5) void {
    const em = ctx.em;
    const d = layout.shadow(rd);
    em.put(e.memImm(.str_w, .x9, t.cpu_reg, layout.reg(rd)));
    em.put(e.sxth(.x10, .x9));
    em.put(e.scvtf(.s, .v0, .w, .x10));
    em.put(e.fmemImm(.str_s, .v0, t.cpu_reg, d + x_off));
    em.put(e.shiftImm(.asr, .x10, .x9, 16));
    em.put(e.scvtf(.s, .v0, .w, .x10));
    em.put(e.fmemImm(.str_s, .v0, t.cpu_reg, d + y_off));
    em.put(e.memImm(.str_w, .zr, t.cpu_reg, d + z_off));
    em.put(e.memImm(.str_w, .x9, t.cpu_reg, d + word_off));
    em.movImm32(.x10, Value.valid_xy);
    em.put(e.memImm(.str_w, .x10, t.cpu_reg, d + flags_off));
}
```

In `lower_alu.zig`, import it (`const shadow_alu = @import("shadow_alu.zig");`), replace `retire`, and add `is`:

```zig
/// The result in w9 to `rd`: under the CPU tier through `hook`, which takes
/// `a` and `b` beside it, inline where `shadow_alu` states the hook and
/// through its shim otherwise; under the base tier as `writeReg` stores it.
fn retire(ctx: *t.Ctx, rd: u5, comptime hook: anytype, a: Arg, b: Arg) void {
    if (ctx.opts.pgxp != .cpu) return ctx.dst(rd, .x9);
    if (comptime is(hook, ops.exact) or is(hook, ops.sltReg)) return shadow_alu.exact(ctx, rd);
    shadow.hooked(ctx, hook, rd, a, b);
}

/// Whether `hook`, a function or a pointer to one, is `f`.
fn is(comptime hook: anytype, comptime f: anytype) bool {
    const T = @TypeOf(hook);
    if (T == @TypeOf(f)) return hook == f;
    if (T == *const @TypeOf(f)) return hook == &f;
    return false;
}
```

Replace the `shadow.hooked(ctx, shadow.move, …)` line in `move` with `shadow_alu.move(ctx, r.rd, r.rs);`. Delete `pub fn move` from `shadow.zig` (its last user is gone). Rewrite `lower_alu.zig`'s module comment's second paragraph: "Under PGXP's base tier `Ctx.dst` clears the destination's shadow, which is all `writeReg` does there. Under the CPU tier every op retires through its CPU-mode hook instead: inline for the rules `shadow_alu.zig` states, through `shadow.hooked`'s shim for the rest. The register-move idiom is inline in both tiers."

- [ ] **Step 4: Run the tests to see them pass**

Run: `zig build test -Dtest-filter="PGXP"` then `zig build test -Dtest-filter="fuzz"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
zig fmt ps1-core/src/recompiler ps1-core/tests/jit_test.zig
git add ps1-core/src/recompiler ps1-core/tests/jit_test.zig
git commit -m "perf(jit): PGXP's register move and exact results retire inline"
```

---

### Task 4: Step 1 gates and measurement

**Files:**
- Modify: `docs/superpowers/specs/2026-10-09-core-performance-roadmap.md` (item 6)

- [ ] **Step 1: Build the parent for A/B** (`$S` is the scratchpad directory, `$BASE` the commit before Task 1, i.e. the plan commit's parent or `git log` the hash):

```bash
S=/private/tmp/claude-501/-Users-david-Documents-develop-substation/917af98a-6344-4c84-a4da-5a1fcbcdb7bd/scratchpad
git worktree add $S/base $BASE
cp ps1-debug/src/BIOS.BIN $S/base/ps1-debug/src/
(cd $S/base && zig build -Doptimize=ReleaseFast) && cp $S/base/zig-out/bin/ps1-bench-dual $S/bench-base
zig build -Doptimize=ReleaseFast && cp zig-out/bin/ps1-bench-dual $S/bench-step1
```

- [ ] **Step 2: Golden gates, against the parent's output.** For each of the commands below, run it in `$S/base` and in the repo, redirect stdout+stderr to `$S/<name>-base.txt` / `$S/<name>-new.txt`, and `diff` the two. Expected: no difference (the floors failure is pre-existing, so compare against the parent, never against the floors).

```bash
zig build trace-golden -Doptimize=ReleaseFast -- pgxp --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- pgxp --snapshot --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- verify --engine=jit
```

Then, in the repo only, expected exit 0:

```bash
zig build trace-golden -Doptimize=ReleaseFast -- lockstep --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build test
```

- [ ] **Step 3: Measure.** Check `uptime` first; wait for a load average under ~3. Interleave, three rounds per game:

```bash
for g in "Spyro the Dragon (USA)/Spyro the Dragon (USA)" "Crash Bandicoot - Warped/Crash Bandicoot - Warped" "Croc - Legend of the Gobbos/Croc - Legend of the Gobbos"; do
  for i in 1 2 3; do for b in base step1; do
    echo -n "$g $b "; $S/bench-$b SCPH-1001_BIOS_1995_US.bin "games/$g.cue" 3000 --engine=jit threaded pgxp 2>&1 | grep -o "fps=[0-9.]*"
  done; done
done
```

Record best-of-three per game per build, and how many pairs the new build won.

- [ ] **Step 4: Record in the roadmap.** Under item 6 in `2026-10-09-core-performance-roadmap.md`, add an "As built, step 1 (date)" bullet list in the style of items 3 and 5: what moved inline, the fps table, the gates run and their result, and the load average. Then commit:

```bash
git add docs/superpowers/specs/2026-10-09-core-performance-roadmap.md
git commit -m "docs(perf): roadmap item 6 step 1 measured"
```

---

### Task 5: ADDI/ADDIU's rule in emitted code

**Files:**
- Modify: `ps1-core/src/recompiler/arm64/shadow_alu.zig` (add `addi`)
- Modify: `ps1-core/src/recompiler/arm64/lower_alu.zig` (`retire`)
- Test: `ps1-core/tests/jit_test.zig` (new differential test; widen `fuzz.live`)

**Interfaces:**
- Consumes: Task 1's FP encoders and `Emitter.fconst`; Task 3's `validate`, `is`, `retire`; `shadow.copyVia` (Task 2).
- Produces: `shadow_alu.addi(ctx: *t.Ctx, rd: u5, rs: u5, imm: u32) void`, where `imm` is the sign-extended immediate the hook takes.

- [ ] **Step 1: Write the failing test** in `jit_test.zig`, after Task 3's tests:

```zig
test ".jit equals .cached under PGXP's CPU mode: ADDI and ADDIU's shadow, case by case" {
    if (!jit.available) return error.SkipZigTest;
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    // x and y each over: an ordinary fraction, both zeros, the edges of a
    // half (so the carry, the borrow and both of foldHigh's arms fire),
    // a fraction within 2^-16 of the grid, a value that wraps signFold's
    // i32, one that saturates fcvtzs, and the non-finite ones.
    const xs = [_]f32{ 12.5, 0.0, -0.0, -3.25, 32767.9999, -32768.0, 65535.5, 0.00001, 70000.25, 3.0e14, -3.0e14, nan, inf };
    const ys = [_]f32{ -3.25, 0.0, -0.0, 32767.5, -32768.25, nan };
    const flag_sets = [_]u32{ Value.valid_xyz, Value.valid_x, Value.valid_y, Value.valid_xy | Value.tainted_z, 0 };
    const values = [_]u32{ 0, 0x0001_0002, 0x7FFF_FFFF, 0xFFFF_FFFF, 0x0000_FFFF, 0x8000_8000, 0x7FFF_7FFF };
    const imms = [_]u16{ 0, 1, 0x7FFF, 0x8000, 0xFFFF, 0x1234 };
    // rt, rs: a plain write, onto the source, to $zero, from $zero.
    const forms = [_]struct { u5, u5 }{ .{ t1, t0 }, .{ t0, t0 }, .{ zero, t0 }, .{ t1, zero } };

    var p = try Pair.init(&.{ mips.beq(zero, zero, -1), mips.nop }, 0x8000_1000);
    defer p.deinit();
    for ([_]*h.Machine{ &p.ref, &p.dut }) |m| h.pgxpOn(m, .cpu);
    var at: u32 = 0x8000; // past `compared_ram`: the programs are not state
    var cases: u32 = 0;
    for ([_]u32{ 0x08, 0x09 }) |opcode| {
        for (forms) |form| {
            for (imms) |imm| {
                for (values) |v| {
                    // One source shadow per x, its y and flags cycling
                    // beside it; every third recorded against another word.
                    for (xs, 0..) |x, xi| {
                        const stale = xi % 3 == 0;
                        const shadow: Value = .{
                            .x = x,
                            .y = ys[xi % ys.len],
                            .z = 400,
                            .word = if (stale) v ^ 1 else v,
                            .flags = flag_sets[xi % flag_sets.len],
                        };
                        const program = [_]u32{ mips.i(opcode, form[1], form[0], imm), mips.beq(zero, zero, -1), mips.nop };
                        for ([_]*h.Machine{ &p.ref, &p.dut }) |m| {
                            h.poke(m.bus, at, &program);
                            m.cpu.regs[t0] = v;
                            m.cpu.regs[t1] = 0;
                            m.cpu.gpr_shadow[t0] = shadow;
                            m.cpu.gpr_shadow[t1] = h.shadowOf(0);
                            m.start(0x8000_0000 | at);
                        }
                        errdefer std.debug.print("addi case: opcode {x} rt {d} rs {d} imm {x} value {x} shadow {any}\n", .{ opcode, form[0], form[1], imm, v, shadow });
                        try expectEqual(p.ref.cpu.run(), p.dut.cpu.run());
                        try h.expectSameMachine(&p.ref, &p.dut);
                        at += 16;
                        cases += 1;
                    }
                }
            }
        }
    }
    try expect(h.jitRan(&p.dut));
    try expectEqual(@as(u32, 2 * forms.len * imms.len * values.len * xs.len), cases);
}
```

Then widen the fuzzer's seeded shadows so `x` reaches the carry boundary: in `fuzz.live`, replace

```zig
            .x = rng.float(f32) * 640 - 320,
```

with

```zig
            // Half the time a screen coordinate, half the time anywhere in
            // a half's range and past it, so a sum reaches the carry.
            .x = if (rng.boolean()) rng.float(f32) * 640 - 320 else rng.float(f32) * 140000 - 70000,
```

- [ ] **Step 2: Run it to see it pass on the shim.** The shim is the reference, so the test must already pass:

Run: `zig build test -Dtest-filter="case by case"`
Expected: PASS (4,368 programs). If it takes over ~60 s in Debug, drop `-3.25` and `0.00001` from `xs` and say so in the roadmap notes.

Add a no-call assertion to `"under PGXP the move idiom and the exact ops retire without a call"`. This one is the red test:

```zig
    try expectEqual(@as(u32, 0), try pgxpCalls(&.{
        mips.addiu(t0, t1, 4),
        mips.i(0x08, t2, t2, 0xFFF0), // ADDI onto its source
        mips.addiu(t3, zero, 7),
        mips.addiu(t4, t4, 0),
        mips.beq(zero, zero, -1),
        mips.nop,
    }, .cpu));
```

Run: `zig build test -Dtest-filter="retire without a call"`
Expected: FAIL (3: one `Hooked(addi)` shim per op with `rs != 0` or `imm != 0`).

- [ ] **Step 3: Implement `addi` in `shadow_alu.zig`.** `bits.sext16` returns a `u32`, so it is no help here. Use these two file-private helpers, which state `ops.zig`'s `lowHalf`/`highHalf` for a constant:

```zig
/// `ops.zig`'s low half: the signed 16-bit quantity, as `Value.x` is read.
fn lowHalf(word: u32) f32 {
    return @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(word)))));
}

/// `ops.zig`'s high half, as `Value.y` is read.
fn highHalf(word: u32) f32 {
    return @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(word >> 16)))));
}

/// `ops.addi(rs, imm, result)`, with `rs` and the sign-extended `imm` known
/// here. The float work is `ops.addi`'s operation for operation, in f64,
/// with `pgxp.unsign`, `signFold` and `ops.zig`'s `foldHigh` inline: nothing
/// is reassociated, and an add of a constant zero is still emitted, because
/// `-0.0 + 0.0` is `+0.0`. FCMP's `mi`/`gt`/`ge` are false on a NaN, as
/// Zig's `<`/`>`/`>=` are.
pub fn addi(ctx: *t.Ctx, rd: u5, rs: u5, imm: u32) void {
    const em = ctx.em;
    if (rs == 0) {
        // $zero's shadow is none: the result is a constant.
        if (rd != 0) fromZeroRegister(em, rd, imm);
        return;
    }
    validate(em, rs);
    if (rd == 0) return; // the validation was the hook's only effect
    const d = layout.shadow(rd);
    const s = layout.shadow(rs);
    em.put(e.memImm(.str_w, .x9, t.cpu_reg, layout.reg(rd)));
    if (imm == 0) {
        // Adding nothing: the validated source, with the result as its word.
        shadow.copyVia(em, .x12, t.cpu_reg, d, t.cpu_reg, s);
        em.put(e.memImm(.str_w, .x9, t.cpu_reg, d + word_off));
        return;
    }
    // Every source field is read before `rd`'s shadow is written: `rd` may
    // be `rs`.
    em.put(e.memImm(.ldr_w, .x12, t.cpu_reg, s + z_off));
    em.put(e.fmemImm(.ldr_s, .v0, t.cpu_reg, s + x_off));
    em.put(e.fmemImm(.ldr_s, .v1, t.cpu_reg, s + y_off));
    const zero = em.label();
    const done = em.label();
    em.branch(.{ .cbz = .{ .w, .x11 } }, .{ .label = zero });
    sum(em, imm);
    em.put(e.fmemImm(.str_s, .v5, t.cpu_reg, d + x_off));
    em.put(e.fmemImm(.str_s, .v6, t.cpu_reg, d + y_off));
    retireFlags(em, d, Value.tainted_z);
    em.branch(.b, .{ .label = done });

    // Nothing went in: the immediate's halves, exactly known.
    em.bind(zero);
    em.movImm32(.x13, @bitCast(lowHalf(imm)));
    em.put(e.memImm(.str_w, .x13, t.cpu_reg, d + x_off));
    em.movImm32(.x13, @bitCast(highHalf(imm)));
    em.put(e.memImm(.str_w, .x13, t.cpu_reg, d + y_off));
    retireFlags(em, d, Value.valid_xy | Value.tainted_z);
    em.bind(done);
}

/// `rd`'s z, word and flags: the source's z (w12), the result (w9), and
/// the validated flags (w10) with `set` added.
fn retireFlags(em: *t.Emitter, d: u32, set: u32) void {
    em.put(e.memImm(.str_w, .x12, t.cpu_reg, d + z_off));
    em.put(e.memImm(.str_w, .x9, t.cpu_reg, d + word_off));
    em.movImm32(.x13, set);
    em.put(e.orrReg(.w, .x10, .x10, .x13));
    em.put(e.memImm(.str_w, .x10, t.cpu_reg, d + flags_off));
}

/// `ops.addi` from $zero, whose shadow is none: none with the result as its
/// word for a zero immediate (all zero bytes: the result is 0), otherwise
/// the immediate's halves, exactly known.
fn fromZeroRegister(em: *t.Emitter, rd: u5, imm: u32) void {
    const d = layout.shadow(rd);
    em.put(e.memImm(.str_w, .x9, t.cpu_reg, layout.reg(rd)));
    if (imm == 0) return shadow.clear(em, t.cpu_reg, d);
    em.movImm32(.x13, @bitCast(lowHalf(imm)));
    em.put(e.memImm(.str_w, .x13, t.cpu_reg, d + x_off));
    em.movImm32(.x13, @bitCast(highHalf(imm)));
    em.put(e.memImm(.str_w, .x13, t.cpu_reg, d + y_off));
    em.put(e.memImm(.str_w, .zr, t.cpu_reg, d + z_off));
    em.put(e.memImm(.str_w, .x9, t.cpu_reg, d + word_off));
    em.movImm32(.x13, Value.valid_xy | Value.tainted_z);
    em.put(e.memImm(.str_w, .x13, t.cpu_reg, d + flags_off));
}

/// The sum of a non-zero source and a non-zero immediate, in f64. In: s0
/// the source's x, s1 its y, w10 its validated flags, w11 its value.
/// Out: s5 the result's x, s6 its y.
fn sum(em: *t.Emitter, imm: u32) void {
    em.fconst(.v2, 65536.0);
    // x = unsign(validX) + u16(imm)
    validHalf(em, .v0, 0, false);
    em.put(e.farith(.fadd, .d, .v3, .v0, .v2));
    em.put(e.fcmpZero(.d, .v0));
    em.put(e.fcsel(.d, .v0, .v0, .v3, .ge));
    em.fconst(.v3, @floatFromInt(@as(u16, @truncate(imm))));
    em.put(e.farith(.fadd, .d, .v0, .v0, .v3));
    // carry = x > 65535 ? 1 : x < 0 ? -1 : 0
    em.put(e.fmovFromGp(.d, .v4, .zr));
    em.fconst(.v3, -1.0);
    em.put(e.fcmpZero(.d, .v0));
    em.put(e.fcsel(.d, .v4, .v3, .v4, .mi));
    em.fconst(.v3, 65535.0);
    em.put(e.fcmp(.d, .v0, .v3));
    em.fconst(.v3, 1.0);
    em.put(e.fcsel(.d, .v4, .v3, .v4, .gt));
    // out.x = signFold(x): onto the 1/65536 grid, wrapped to i32
    em.put(e.farith(.fmul, .d, .v3, .v0, .v2));
    em.put(e.fcvtzsX(.x13, .v3));
    em.put(e.scvtf(.d, .v3, .w, .x13));
    em.put(e.farith(.fdiv, .d, .v3, .v3, .v2));
    em.put(e.fcvt(.s, .v5, .v3));
    // y = foldHigh(validY + highHalf(imm) + carry)
    validHalf(em, .v1, 1, true);
    em.fconst(.v3, highHalf(imm));
    em.put(e.farith(.fadd, .d, .v1, .v1, .v3));
    em.put(e.farith(.fadd, .d, .v1, .v1, .v4));
    em.put(e.farith(.fsub, .d, .v3, .v1, .v2)); // y - 65536
    em.put(e.farith(.fadd, .d, .v6, .v1, .v2)); // y + 65536
    em.fconst(.v0, -32768.0);
    em.put(e.fcmp(.d, .v1, .v0));
    em.put(e.fcsel(.d, .v6, .v6, .v1, .mi));
    em.fconst(.v0, 32767.0);
    em.put(e.fcmp(.d, .v1, .v0));
    em.put(e.fcsel(.d, .v6, .v3, .v6, .gt));
    em.put(e.fcvt(.s, .v6, .v6));
}

/// `Value.validX`/`validY`, widened: `r` (holding the stored half as an
/// f32) keeps it when the flag at `bit` is set, else takes the register's
/// half (`high`: the top one), then becomes an f64.
fn validHalf(em: *t.Emitter, r: e.FReg, bit: u5, high: bool) void {
    em.put(if (high) e.shiftImm(.asr, .x13, .x11, 16) else e.sxth(.x13, .x11));
    em.put(e.scvtf(.s, .v3, .w, .x13));
    em.put(e.ubfx(.x13, .x10, bit, 1));
    em.put(e.cmpImm(.w, .x13, 0));
    em.put(e.fcsel(.s, r, r, .v3, .ne));
    em.put(e.fcvt(.d, r, r));
}
```

Check `sum` against `ops.addi` line by line before running anything. Every `ops.addi` operation has exactly one emitted counterpart, in the same order:
- `validX` → `validHalf(v0)`
- `unsign` → `fadd`/`fcmpZero`/`fcsel ge`
- `+ u16(imm)` → `fadd`
- the carry → the two `fcsel`s
- `signFold` → `fmul`/`fcvtzs`/`scvtf w`/`fdiv`
- `@floatCast` → `fcvt s`
- `validY` widened, then `+ highHalf(imm)` (always emitted), then `+ carry`
- `foldHigh` → `fsub`/`fadd`/two `fcsel`s, then `fcvt s`

In `lower_alu.zig`'s `retire`, before the `exact` line:

```zig
    if (comptime is(hook, ops.addi)) return shadow_alu.addi(ctx, rd, @intCast(a.imm), b.imm);
```

(Both callers pass `rs` as `a.imm` and the sign-extended immediate as `b.imm`: `immediate` for ADDIU, `checked` for ADDI.)

- [ ] **Step 4: Run the tests to see them pass**

Run: `zig build test -Dtest-filter="case by case"`, then `-Dtest-filter="retire without a call"`, then `-Dtest-filter="PGXP"`, then `-Dtest-filter="fuzz"`
Expected: PASS for all.

- [ ] **Step 5: Prove the differential test can fail.** Make each mutation below, run `zig build test -Dtest-filter="case by case"`, confirm FAIL, revert, and confirm PASS again. Record which case each one failed on.
  1. In the carry, `.mi` → `.lt` (the NaN `x` case).
  2. In `signFold`, `e.scvtf(.d, .v3, .w, .x13)` → `.x` (the 70000.25 wrap case).
  3. In `foldHigh`, swap the two `fcsel` conditions `.mi`/`.gt` (32767.5 / -32768.25).
  4. In `validate`, drop the `str_w` of the flags (the stale cases: the table keeps its flags).
  5. In the zero branch, `Value.valid_xy | Value.tainted_z` → `Value.valid_xy`.

If any mutation PASSES, the table is missing that case. Add it and repeat before going on.

- [ ] **Step 6: Commit**

```bash
zig fmt ps1-core/src/recompiler ps1-core/tests/jit_test.zig
git add ps1-core/src/recompiler ps1-core/tests/jit_test.zig
git commit -m "perf(jit): ADDI and ADDIU's PGXP rule in emitted code"
```

---

### Task 6: Step 2 gates, measurement, profile and docs

**Files:**
- Modify: `docs/superpowers/specs/2026-10-09-core-performance-roadmap.md` (item 6, the state line at the top)
- Modify: `CLAUDE.md` (the JIT rule about `shadow.hooked`)

- [ ] **Step 1: Gates.** Rebuild (`zig build -Doptimize=ReleaseFast && cp zig-out/bin/ps1-bench-dual $S/bench-step2`). Repeat Task 4 Step 2 exactly: the three diffs against `$S/base`, then `lockstep --engine=jit`, `verify` and `zig build test`. Same expectations.

- [ ] **Step 2: Measure.** Task 4 Step 3's loop with `for b in base step1 step2`. Record best of three per build per game.

- [ ] **Step 3: Profile.** Take a fresh Spyro profile and partition it by outermost shim:

```bash
rm -rf $S/spyro2.trace
xctrace record --template 'Time Profiler' --output $S/spyro2.trace --launch -- zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin "games/Spyro the Dragon (USA)/Spyro the Dragon (USA).cue" 4000 --engine=jit threaded pgxp
xctrace export --input $S/spyro2.trace --xpath '/trace-toc/run/data/table[@schema="time-profile"]' > $S/spyro2.xml
python3 $S/part.py $S/spyro2.xml
```

(`$S/part.py` is in the scratchpad from the design session. If it is gone, it counts each emulator-thread sample under the outermost frame whose name contains `Shim` or `Hooked`, and puts anonymous leaf frames under "JIT code".)

- [ ] **Step 4: Docs.**
  - **Roadmap item 6:** add an "As built, step 2" block: fps for base / step 1 / step 2, the post-change shim table, the gates and the five mutations. End with a one-line verdict on option C (`add`/`sub`/shifts), read off what the profile leaves: worth it only if those shims still total more than ~8% of the thread. Update the state line at the top of the roadmap.
  - **CLAUDE.md**, JIT rules, first bullet: replace "An ALU op with a hook retires through that hook's shim (`shadow.hooked`), which writes the register AND its shadow, because the hook reads its sources before the destination is written" with "An ALU op with a hook retires through that hook's shim (`shadow.hooked`), which writes the register AND its shadow, because the hook reads its sources before the destination is written. The move idiom, `exact` and ADDI/ADDIU are emitted inline instead (`shadow_alu.zig`), reading and writing exactly the memory the shim would; `addi`'s float work is `ops.addi`'s operation for operation, so a change to one is a change to both". Also add the inline word load/store shadow copy beside "a load's shadow waits in `Pins.load_shadows`".

```bash
git add docs/superpowers/specs/2026-10-09-core-performance-roadmap.md CLAUDE.md
git commit -m "docs(perf): roadmap item 6 done, PGXP's word moves and ADDI inline"
```

- [ ] **Step 5: Clean up** the parent worktree: `git worktree remove $S/base`.
