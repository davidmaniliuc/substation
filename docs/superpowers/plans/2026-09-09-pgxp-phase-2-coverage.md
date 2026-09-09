# PGXP Phase 2 (Coverage) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make PGXP resolve vertices in the games where it currently resolves none — Croc, Metal Gear Solid and Resident Evil, each stuck at exactly 25,854 resolved vertices, which is the BIOS licence logo and identical on every disc.

**Architecture:** Replace the coupled screen-position pair (`pgxp.Precise`) with a per-halfword value carrying a depth term and the integer word it was recorded against (`pgxp.Value`), which is the only representation that can survive a game splitting a packed SXY into two registers. Recompute the projection in float in RTPS/RTPT so a W exists for Phase 3. Then extend the propagation set: the half-word memory hooks we lack entirely, and DuckStation's full CPU-mode instruction set behind its own flag. Finish with the vertex cache, the tolerance knob and culling correction.

**Tech Stack:** Zig 0.16.0, `ps1-core` (the emulator core), `ps1-capi` (C ABI), `ps1-macos` (SwiftUI app), `ps1-golden` (the trace/PGXP harnesses).

**Spec:** `docs/superpowers/specs/2026-09-09-pgxp-phase-2-coverage-design.md`
**Reference audit:** `docs/superpowers/specs/2026-09-09-pgxp-duckstation-parity-audit.md`

## Global Constraints

- **Zig 0.16.0.** `zig version` must report exactly this.
- **`zig fmt` before every commit.** Single-author codebase; match surrounding style — inline field defaults, `init()` on devices.
- **No file in `ps1-core/src` over ~600 lines.** Split by function.
- **`duckstation_ref/` is CC-BY-NC-ND-4.0.** No transcription. Implement from the spec and the audit; the reference is read to establish behaviour, never copied. Do not paste its code, its comments, or its identifier names into this repo.
- **`zig build trace-golden -- verify` must stay green with PGXP off, at every task boundary.** Run it `-Doptimize=ReleaseFast`. Nothing in this phase may move a trace golden. If one moves, that is a bug in the gating, not a behaviour change to recapture.
- **`zig build trace-golden -- pgxp`** is the coverage ratchet, floors in `ps1-core/tests/goldens/pgxp/floors.txt`. Run `-Doptimize=ReleaseFast`. Floors are re-pinned once, in Task 14, not per task.
- **Run all test suites `-Doptimize=ReleaseFast`** — identical results, ~25x faster.
- **Every carve-out test must be verified to FAIL against the naive implementation** before the implementation lands. A guard test that cannot fail is worse than none.
- **`ps1-core/src/pgxp.zig` becomes `ps1-core/src/pgxp/pgxp.zig`.** `root.zig`'s `pub const pgxp = @import("pgxp/pgxp.zig");` keeps `ps1_core.pgxp.*` resolving for every frontend.

## File Structure

**Created:**
- `ps1-core/src/pgxp/pgxp.zig` — the `Value` type, its flags, the 16-bit boundary helpers, `truncateVertexPosition`. Replaces `ps1-core/src/pgxp.zig`.
- `ps1-core/src/pgxp/ops.zig` — CPU-mode instruction implementations (immediates, register arithmetic, logicals).
- `ps1-core/src/pgxp/shift.zig` — the shift ops. Separate because they carry three game-specific carve-outs and the file would otherwise run long.
- `ps1-core/src/pgxp/muldiv.zig` — `mult`/`multu`/`div`/`divu` and the `hi`/`lo` shadows.
- `ps1-core/src/pgxp/cache.zig` — the vertex cache.
- `ps1-core/tests/pgxp_test.zig` — all unit coverage for the above.

**Modified:**
- `ps1-core/src/root.zig:15` — the import path.
- `ps1-core/src/memory.zig:98-111,218-260` — shadow tables and their accessors; the `pgxp_cpu`, `pgxp_vertex_cache`, `pgxp_culling` and `pgxp_tolerance` flags.
- `ps1-core/src/cpu/cpu.zig:36-42,278-283` — the GPR/load-delay shadows, `hi`/`lo` shadows, `writeRegPrecise`.
- `ps1-core/src/cpu/exec.zig` — every propagation site, plus the CPU-mode dispatch.
- `ps1-core/src/cop2/cop2.zig:165,197-268` — the 64-register shadow replacing `precise_sxy[3]`.
- `ps1-core/src/cop2/opcodes.zig:60-91,138-160` — the float projection and float NCLIP.
- `ps1-core/src/gpu/primitive.zig:5,77-85` — `getPointPrecise`.
- `ps1-core/src/gpu/gp0.zig:55,122-148` — the FIFO provenance type and the counters.
- `ps1-capi/src/root.zig:394-396` and `ps1-capi/include/ps1.h` — four new setters.
- `ps1-macos/Sources/PS1/PgxpSetting.swift`, `EmulatorViewModel.swift`, `Ps1Core.swift`, `PS1App/VideoCommands.swift` — the app surface.
- `build.zig:176-187` — `pgxp_test.zig` in `unit_test_files`.
- `CLAUDE.md` — the PGXP section.

---

### Task 1: The value type

**Files:**
- Create: `ps1-core/src/pgxp/pgxp.zig`
- Delete: `ps1-core/src/pgxp.zig`
- Modify: `ps1-core/src/root.zig:15`
- Create: `ps1-core/tests/pgxp_test.zig`
- Modify: `build.zig:176-187`

**Interfaces:**
- Consumes: nothing.
- Produces: `pgxp.Value` (`extern struct { x: f32, y: f32, z: f32, word: u32, flags: u32 }`), `Value.none`, the flag constants `valid_x`/`valid_y`/`valid_z`/`valid_xy`/`valid_xyz`/`low_z`/`high_z`/`tainted_z`, `Value.validate(*Value, u32) void`, `Value.validX(Value, u32) f32`, `Value.validY(Value, u32) f32`, and the free functions `signFold(f64) f64`, `unsign(f64) f64`, `overflow(f64) f64`, `truncateVertexPosition(f32) f32`.

Nothing outside this task uses the new type yet — `Precise` stays in place and compiling until Task 2. This task is the type and its arithmetic laws alone.

- [ ] **Step 1: Write the failing tests**

Create `ps1-core/tests/pgxp_test.zig`:

```zig
const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

const ps1_core = @import("ps1_core");
const pgxp = ps1_core.pgxp;
const Value = pgxp.Value;

test "a value is invalidated when its recorded word no longer matches" {
    var v: Value = .{ .x = 1.5, .y = 2.5, .word = 0xDEAD_BEEF, .flags = Value.valid_xy };
    v.validate(0xDEAD_BEEF);
    try expectEqual(Value.valid_xy, v.flags);
    v.validate(0x0000_0001);
    try expectEqual(@as(u32, 0), v.flags);
}

test "validX and validY fall back to the integer halves when a half is invalid" {
    // Low half -3, high half 7.
    const word: u32 = (@as(u32, 7) << 16) | @as(u32, @as(u16, @bitCast(@as(i16, -3))));
    const v: Value = .{ .x = 1.25, .y = 9.75, .word = word, .flags = Value.valid_x };
    try expectApproxEqAbs(@as(f32, 1.25), v.validX(word), 0.0);
    // y is not valid, so the integer high half is used, sign-extended.
    try expectApproxEqAbs(@as(f32, 7.0), v.validY(word), 0.0);
}

test "signFold rounds onto the 1/65536 grid and reinterprets as signed" {
    // 0.5 survives exactly.
    try expectApproxEqAbs(@as(f64, 0.5), pgxp.signFold(0.5), 0.0);
    // 65535.5 is above the signed 16-bit range and folds negative.
    try expectApproxEqAbs(@as(f64, -0.5), pgxp.signFold(65535.5), 1e-9);
}

test "unsign lifts a negative onto the unsigned 16-bit range" {
    try expectApproxEqAbs(@as(f64, 65535.5), pgxp.unsign(-0.5), 1e-9);
    try expectApproxEqAbs(@as(f64, 3.25), pgxp.unsign(3.25), 0.0);
}

test "overflow extracts the carry out of the low half" {
    try expectApproxEqAbs(@as(f64, 1.0), pgxp.overflow(65536.0 + 12.0), 0.0);
    try expectApproxEqAbs(@as(f64, 0.0), pgxp.overflow(12.0), 0.0);
    try expectApproxEqAbs(@as(f64, -1.0), pgxp.overflow(-12.0), 0.0);
}

test "truncateVertexPosition truncates the integer part to 11 bits and keeps the fraction" {
    // 1500 in 11 bits is 1500 - 2048 = -548.
    try expectApproxEqAbs(@as(f32, -548.25), pgxp.truncateVertexPosition(1500.25), 1e-4);
    // In-range values are untouched.
    try expectApproxEqAbs(@as(f32, 12.75), pgxp.truncateVertexPosition(12.75), 0.0);
    try expectApproxEqAbs(@as(f32, -12.75), pgxp.truncateVertexPosition(-12.75), 0.0);
}

test "a value out of the tracked range folds rather than trapping" {
    // A Debug build must not panic on a garbage value: it is clamped, which
    // is a deliberate divergence from the reference's wrapping conversion.
    // Anything this far out is not a coordinate under any reading.
    _ = pgxp.signFold(1.0e30);
    _ = pgxp.overflow(-1.0e30);
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Add `"ps1-core/tests/pgxp_test.zig",` to the `unit_test_files` array in `build.zig:176-187`, then:

```
zig build test -Doptimize=ReleaseFast
```

Expected: FAIL — `pgxp.Value` does not exist.

- [ ] **Step 3: Create the type**

`git mv ps1-core/src/pgxp.zig ps1-core/src/pgxp/pgxp.zig`, update `root.zig:15` to `@import("pgxp/pgxp.zig")`, and add to the file (leaving `Precise` in place — Task 2 removes it):

```zig
/// One tracked 32-bit word, at the precision the value was actually computed
/// with.
///
/// `x` and `y` are the precise values of the word's LOW and HIGH halfwords —
/// NOT screen x and screen y. For a packed SXY the two readings coincide, and
/// for everything else they are simply two halves. That generalisation is the
/// whole reason arithmetic propagation is possible: a coupled screen position
/// has nothing to say the moment a game splits a word into two registers.
///
/// `word` is the integer this entry was recorded against, and is the staleness
/// check: a projected vertex's word IS its packed integer SXY, so a match
/// means the precise value agrees with that vertex's integers exactly.
pub const Value = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    /// Depth term. For a projected vertex this is the W that Phase 3's
    /// texture correction and depth buffer consume.
    z: f32 = 0,
    word: u32 = 0,
    flags: u32 = 0,

    pub const none: Value = .{};

    pub const valid_x: u32 = 1 << 0;
    pub const valid_y: u32 = 1 << 1;
    pub const valid_z: u32 = 1 << 2;
    pub const valid_xy: u32 = valid_x | valid_y;
    pub const valid_xyz: u32 = valid_xy | valid_z;
    /// Which half a z arrived from, so a half-word write can retire it.
    pub const low_z: u32 = 1 << 16;
    pub const high_z: u32 = 1 << 17;
    /// x or y has been altered since the z was recorded, so the z loses to an
    /// untainted one when two values are combined.
    pub const tainted_z: u32 = 1 << 31;

    pub fn validate(self: *Value, current: u32) void {
        if (self.word != current) self.flags = 0;
    }

    pub fn validX(self: Value, current: u32) f32 {
        if (self.flags & valid_x != 0) return self.x;
        return @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(current)))));
    }

    pub fn validY(self: Value, current: u32) f32 {
        if (self.flags & valid_y != 0) return self.y;
        return @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(current >> 16)))));
    }
};

/// The three helpers that model the 16-bit boundary between the halves.
///
/// Each converts through an integer, and each CLAMPS rather than wrapping on
/// the way. That is a deliberate divergence: the reference truncates to i64
/// and narrows to i32, which wraps, while Zig's `@intFromFloat` is illegal
/// out of range and would panic in a Debug build. A value far enough out of
/// range for the two to differ is not a coordinate under any reading, so
/// clamping costs nothing real and removes a crash.

/// Round onto the 1/65536 grid and reinterpret as a signed 16-bit quantity.
pub fn signFold(val: f64) f64 {
    const scaled = std.math.lossyCast(i64, val * 65536.0);
    const narrowed: i32 = @truncate(scaled);
    return @as(f64, @floatFromInt(narrowed)) / 65536.0;
}

/// Lift a negative half onto the unsigned 16-bit range.
pub fn unsign(val: f64) f64 {
    return if (val >= 0) val else val + 65536.0;
}

/// Extract the carry out of a low half.
pub fn overflow(val: f64) f64 {
    return @floatFromInt(std.math.lossyCast(i64, val) >> 16);
}

/// The GPU drops the upper 5 bits of a vertex coordinate when it parses a
/// command, so a precise position has to lose them too or it describes a
/// different pixel from the one the wire names. The fraction survives.
pub fn truncateVertexPosition(p: f32) f32 {
    const int_part = std.math.lossyCast(i32, p);
    const bits: u32 = @as(u32, @bitCast(int_part)) & 0x7FF;
    const sign_extended: u32 = if (bits & 0x400 != 0) bits | 0xFFFF_F800 else bits;
    const truncated: i32 = @bitCast(sign_extended);
    return @as(f32, @floatFromInt(truncated)) + (p - @as(f32, @floatFromInt(int_part)));
}
```

Add `const std = @import("std");` at the top of the file if it is not already there.

- [ ] **Step 4: Run the tests and verify they pass**

```
zig fmt ps1-core/src/pgxp/pgxp.zig ps1-core/tests/pgxp_test.zig
zig build test -Doptimize=ReleaseFast
```

Expected: PASS, all 16 test binaries.

- [ ] **Step 5: Commit**

```bash
git add ps1-core/src/pgxp/ ps1-core/tests/pgxp_test.zig ps1-core/src/root.zig build.zig
git commit -m "feat(pgxp): the per-halfword value type

x and y are the precise values of a word's two halves rather than a screen
position, which is the representation change the whole phase turns on: a
coupled pair has nothing to say once a game splits a packed SXY into two
registers.

The three 16-bit boundary helpers clamp where the reference wraps. Zig's
integer conversion is illegal out of range and would panic in a Debug build,
and a value far enough out for the two to differ is not a coordinate."
```

---

### Task 2: Swap the representation in, behaviour held

**Files:**
- Modify: `ps1-core/src/pgxp/pgxp.zig` (remove `Precise`)
- Modify: `ps1-core/src/memory.zig:98-111,218-260`
- Modify: `ps1-core/src/cpu/cpu.zig:36-42,278-283`
- Modify: `ps1-core/src/cpu/exec.zig` (every `Precise` site)
- Modify: `ps1-core/src/cop2/cop2.zig:165,197-268`
- Modify: `ps1-core/src/cop2/opcodes.zig:80-91`
- Modify: `ps1-core/src/gpu/primitive.zig:5,77-85`
- Modify: `ps1-core/src/gpu/gp0.zig:55,122-148`
- Modify: `ps1-capi/src/capi_test.zig:438-457`
- Test: `ps1-core/tests/pgxp_test.zig`

**Interfaces:**
- Consumes: `pgxp.Value` and its flags from Task 1.
- Produces: `Bus.shadowLoad(*Bus, u32) Value`, `Bus.shadowStore(*Bus, u32, Value) void`, `Bus.shadowInvalidate(*Bus, u32) void` (unchanged names, new type); `Cpu.writeRegPrecise(*Cpu, anytype, u32, Value) void`; `Cop2.readPreciseData(*const Cop2, anytype) Value`; `Cop2.writeDataPrecise(*Cop2, anytype, u32, Value) void`; `Primitive.getPointPrecise(u32, Value) Point`.

This is the risky task and it is deliberately alone: the type and the staleness model change, and **nothing else does**. The precise position still comes from MAC0, so the sweep should barely move. Isolating it is what makes a later movement attributable.

`Precise.resolves(ix, iy)` is replaced by a word match. Where the old code called `p.resolves(pt.x, pt.y)`, the new code asks `p.flags & Value.valid_xy == Value.valid_xy and p.word == word` — the raw command word, not the decoded coordinates, because the recorded word is what the entry was validated against.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/pgxp_test.zig`:

```zig
const Cpu = ps1_core.cpu.Cpu;
const Bus = ps1_core.memory.Bus;
const Primitive = ps1_core.gpu.primitive;

test "a vertex resolves when the recorded word matches the wire word" {
    // Low half 100, high half 50 — the packed SXY a projection produced.
    const word: u32 = (@as(u32, 50) << 16) | 100;
    const v: Value = .{
        .x = 100.5,
        .y = 50.25,
        .word = word,
        .flags = Value.valid_xy,
    };
    const pt = Primitive.getPointPrecise(word, v);
    try expectEqual(true, pt.resolved);
    try expectEqual(@as(i32, @intFromFloat(100.5 * 65536.0)), pt.px);
    try expectEqual(@as(i32, @intFromFloat(50.25 * 65536.0)), pt.py);
}

test "a vertex does not resolve when the recorded word is stale" {
    const word: u32 = (@as(u32, 50) << 16) | 100;
    const stale: Value = .{
        .x = 100.5,
        .y = 50.25,
        .word = word ^ 1,
        .flags = Value.valid_xy,
    };
    const pt = Primitive.getPointPrecise(word, stale);
    try expectEqual(false, pt.resolved);
    try expectEqual(@as(i32, 100) << 16, pt.px);
}

test "a vertex does not resolve when only one half is valid" {
    const word: u32 = (@as(u32, 50) << 16) | 100;
    const half: Value = .{ .x = 100.5, .y = 50.25, .word = word, .flags = Value.valid_x };
    const pt = Primitive.getPointPrecise(word, half);
    try expectEqual(false, pt.resolved);
}

test "a resolved position is truncated to 11 bits like the wire coordinate is" {
    // Wire low half 1500 truncates to -548; the precise value must follow it
    // rather than describing a pixel 2048 columns away.
    const word: u32 = (@as(u32, 50) << 16) | 1500;
    const v: Value = .{ .x = 1500.5, .y = 50.0, .word = word, .flags = Value.valid_xy };
    const pt = Primitive.getPointPrecise(word, v);
    try expectEqual(@as(i16, -548), pt.x);
    try expectEqual(true, pt.resolved);
    try expectEqual(@as(i32, @intFromFloat(-547.5 * 65536.0)), pt.px);
}
```

- [ ] **Step 2: Run the tests and verify they fail**

```
zig build test -Doptimize=ReleaseFast
```

Expected: FAIL — `getPointPrecise` still takes a `Precise`.

- [ ] **Step 3: Do the swap**

Mechanical, in this order so the tree compiles at the end of the step and not before:

1. `ps1-core/src/pgxp/pgxp.zig` — delete `Precise` entirely.
2. `ps1-core/src/memory.zig` — `ram_shadow: [(2 * MB) / 4]Value`, `scratch_shadow: [(1 * KB) / 4]Value`, `pgxp_pending: Value = Value.none`, and `shadowSlot`/`shadowLoad`/`shadowStore`/`shadowInvalidate` retyped. `setPgxp` clears `pgxp_pending` to `Value.none`.
3. `ps1-core/src/cpu/cpu.zig` — `gpr_shadow: [32]Value`, `load_shadow`, `delay_shadow`, `writeReg`'s clear, `writeRegPrecise`'s parameter.
4. `ps1-core/src/cop2/cop2.zig` — `precise_sxy: [3]Value`, `readPreciseData` returning `Value`, `writeDataPrecise` taking one. Its admission test becomes the word match:

```zig
pub fn writeDataPrecise(self: *Self, index: anytype, value: u32, p: Value) void {
    self.writeData(index, value);
    const i = getDataIdx(index);
    const slot: usize = switch (i) {
        12, 13, 14 => i - 12,
        15 => 2,
        else => return,
    };
    if (p.flags & Value.valid_xy == Value.valid_xy and p.word == value) {
        self.precise_sxy[slot] = p;
    }
}
```

5. `ps1-core/src/cop2/opcodes.zig:91` — the production site. Still MAC0-derived in this task; the float projection is Task 3:

```zig
cop2.precise_sxy[2] = .{
    .x = @floatCast(@as(f64, @floatFromInt(x_16_16)) / 65536.0),
    .y = @floatCast(@as(f64, @floatFromInt(y_16_16)) / 65536.0),
    .z = 0,
    .word = @bitCast(sxy2),
    .flags = Value.valid_xy,
};
```

Note this must be written **after** `sxy2` is computed, since it records the saturated register word. Move the assignment below the `data_regs[14]` write. `Precise.make`'s range guard is gone: a projection that overflows MAC0 now records a `word` that the saturated register will not match, so it is rejected at consumption for the same reason and by the same mechanism.

6. `ps1-core/src/gpu/primitive.zig`:

```zig
pub inline fn getPointPrecise(value: u32, p: Value) Point {
    var pt = getPoint(value);
    if (p.flags & Value.valid_xy == Value.valid_xy and p.word == value) {
        pt.px = toFixed(pgxp.truncateVertexPosition(p.x));
        pt.py = toFixed(pgxp.truncateVertexPosition(p.y));
        pt.resolved = true;
    }
    return pt;
}

/// A precise coordinate into the record's 16.16. Saturating, because the
/// record is `i32` and a garbage shadow must not be able to trap here.
inline fn toFixed(v: f32) i32 {
    return std.math.lossyCast(i32, @as(f64, v) * 65536.0);
}
```

7. `ps1-core/src/gpu/gp0.zig` — `cmd_buffer_pgxp: [16]Value`, and `point()`'s counters. `cand.resolves(...)` becomes `pt.resolved`, and the `else if (cand.valid != 0)` arm becomes `else if (cand.flags & Value.valid_xy == Value.valid_xy)`.

8. `ps1-capi/src/capi_test.zig:454` — `h.cpu.bus.pgxp_pending = Precise.make(...)` becomes a `Value` literal, and line 456 asserts on `.flags` rather than `.valid`.

- [ ] **Step 4: Run the tests and both harnesses**

```
zig fmt ps1-core/src ps1-capi/src
zig build test -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- pgxp
```

Expected: unit tests PASS. `verify` OK for all ten workloads — this is the hard gate and a failure here blocks the task. `pgxp` should report hit rates within a point or so of the floors; record the exact numbers in the commit message. A large move here means the swap changed something it should not have.

- [ ] **Step 5: Commit**

```bash
git add -A ps1-core ps1-capi
git commit -m "refactor(pgxp): word-matched staleness on the new value type

Swaps the representation and the staleness model together and changes nothing
else -- the precise position still comes from MAC0, so a movement in the sweep
after this commit is attributable to the float projection rather than to this.

resolves() is gone. Matching the recorded word gives the same guarantee by
another route: a projected vertex's word IS its packed integer SXY, so a match
means the precise value agrees with that vertex's integers exactly. It is
forced besides -- consumption-time identity checking needs an integer to check
against, and an intermediate arithmetic value has none.

Sweep: <paste the per-workload hit rates here>"
```

---

### Task 3: The projection recomputed in float

**Files:**
- Modify: `ps1-core/src/cop2/opcodes.zig:60-91`
- Test: `ps1-core/tests/pgxp_test.zig`

**Interfaces:**
- Consumes: `pgxp.Value` from Task 1, the `precise_sxy` slots from Task 2.
- Produces: `precise_sxy[2]` entries carrying `valid_xyz` and a `z` equal to `max(H/2, SZ3)`. Every later task and all of Phase 3 read that `z`.

This replaces the MAC0-derived position from Task 2. It is forced rather than chosen: there is no depth term on the MAC0 path, and every Phase 3 consumer needs one.

The integer path is not touched. `x_16_16`, `y_16_16`, the saturation and the depth-cueing block all stay exactly as they are — the float values are computed beside them.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/pgxp_test.zig`:

```zig
const Cop2 = ps1_core.cpu.Cop2;

/// A GTE with a projection staged: VXYZ0 = (16, 32, 0), H = 1000, SZ3 comes
/// out of the rotation. Identity rotation, no translation, so IR1/IR2 are the
/// input coordinates and SZ3 is the input z.
fn stageProjection(cop2: *Cop2, vx: i16, vy: i16, vz: i16, h: u16, ofx: i32, ofy: i32) void {
    // RT = identity at 1.0 in 4.12 fixed point.
    cop2.writeCtrl(0, (@as(u32, 0) << 16) | 0x1000);
    cop2.writeCtrl(1, @as(u32, 0x1000) << 16);
    cop2.writeCtrl(2, 0x1000);
    cop2.writeCtrl(3, 0);
    cop2.writeCtrl(4, 0);
    // TR = 0.
    cop2.writeCtrl(5, 0);
    cop2.writeCtrl(6, 0);
    cop2.writeCtrl(7, 0);
    cop2.writeCtrl(24, @bitCast(ofx));
    cop2.writeCtrl(25, @bitCast(ofy));
    cop2.writeCtrl(26, h);
    cop2.writeData(0, (@as(u32, @as(u16, @bitCast(vy))) << 16) | @as(u32, @as(u16, @bitCast(vx))));
    cop2.writeData(1, @as(u32, @as(u16, @bitCast(vz))));
}

test "RTPS records a depth term of max(H/2, SZ3)" {
    var ctx = try GteContext.init();
    defer ctx.deinit();

    // vz = 2000, H = 1000, so SZ3 = 2000 and H/2 = 500: the depth is SZ3.
    stageProjection(&ctx.cpu.cop2, 16, 32, 2000, 1000, 0, 0);
    ctx.cpu.cop2.executeCommand(0x4A080001);

    const p = ctx.cpu.cop2.readPreciseData(14);
    try expectEqual(Value.valid_xyz, p.flags & Value.valid_xyz);
    try expectApproxEqAbs(@as(f32, 2000.0), p.z, 0.5);
}

test "RTPS clamps the depth term up to H/2 for near geometry" {
    var ctx = try GteContext.init();
    defer ctx.deinit();

    // vz = 100, H = 1000: H/2 = 500 wins.
    stageProjection(&ctx.cpu.cop2, 16, 32, 100, 1000, 0, 0);
    ctx.cpu.cop2.executeCommand(0x4A080001);

    const p = ctx.cpu.cop2.readPreciseData(14);
    try expectApproxEqAbs(@as(f32, 500.0), p.z, 0.5);
}

test "the precise position is the float projection, not the hardware MAC0" {
    var ctx = try GteContext.init();
    defer ctx.deinit();

    // A depth chosen so the UNR reciprocal is inexact, which is what makes the
    // float projection differ from MAC0 >> 16 at all.
    stageProjection(&ctx.cpu.cop2, 300, 200, 1234, 1000, 0, 0);
    ctx.cpu.cop2.executeCommand(0x4A080001);

    const p = ctx.cpu.cop2.readPreciseData(14);
    const expected_x: f32 = 300.0 * (1000.0 / 1234.0);
    const expected_y: f32 = 200.0 * (1000.0 / 1234.0);
    try expectApproxEqAbs(expected_x, p.x, 0.002);
    try expectApproxEqAbs(expected_y, p.y, 0.002);

    // And it still agrees with the integer register to within a pixel, which
    // is what the word match then requires.
    const sxy2 = ctx.cpu.cop2.readData(14);
    try expectEqual(sxy2, p.word);
}

test "the drawing offset reaches the precise position" {
    var ctx = try GteContext.init();
    defer ctx.deinit();

    // OFX/OFY are 16.16: 40.5 and -8.25 pixels.
    stageProjection(&ctx.cpu.cop2, 0, 0, 1000, 1000, 40 * 65536 + 32768, -(8 * 65536 + 16384));
    ctx.cpu.cop2.executeCommand(0x4A080001);

    const p = ctx.cpu.cop2.readPreciseData(14);
    try expectApproxEqAbs(@as(f32, 40.5), p.x, 0.001);
    try expectApproxEqAbs(@as(f32, -8.25), p.y, 0.001);
}

test "a projection with no depth records nothing rather than a NaN" {
    var ctx = try GteContext.init();
    defer ctx.deinit();

    // H = 0 and SZ3 = 0 leaves the divisor at zero.
    stageProjection(&ctx.cpu.cop2, 16, 32, 0, 0, 0, 0);
    ctx.cpu.cop2.executeCommand(0x4A080001);

    const p = ctx.cpu.cop2.readPreciseData(14);
    try expectEqual(@as(u32, 0), p.flags);
}
```

`GteContext` is the same shape as `gte_test.zig`'s `TestContext` — copy it into `pgxp_test.zig` under that name rather than sharing it, since the two files test different subsystems and a shared harness would couple them.

- [ ] **Step 2: Run the tests and verify they fail**

```
zig build test -Doptimize=ReleaseFast --  # then filter
zig build test -Doptimize=ReleaseFast
```

Expected: FAIL — `p.z` is 0 and `p.x` is the MAC0-derived value.

- [ ] **Step 3: Add the float projection**

In `ps1-core/src/cop2/opcodes.zig`, after `sxy2` is computed and written to `data_regs[14]`, replace the Task 2 assignment with:

```zig
// The projection recomputed in float, beside the integer one rather than
// derived from it. Two reasons: it is the ideal projection, so it also
// sheds the UNR reciprocal's quantisation rather than only the `>> 16`;
// and there is no depth term on the MAC0 path at all, which every
// consumer of this value needs.
const hf: f32 = @floatFromInt(h);
const zf = @max(hf / 2.0, @as(f32, @floatFromInt(sz3)));
cop2.precise_sxy[2] = if (zf > 0.0) blk: {
    const h_div_z = hf / zf;
    const fx = std.math.clamp(
        @as(f32, @floatFromInt(ir1)) * h_div_z + @as(f32, @floatFromInt(ofx)) / 65536.0,
        -1024.0,
        1023.0,
    );
    const fy = std.math.clamp(
        @as(f32, @floatFromInt(ir2)) * h_div_z + @as(f32, @floatFromInt(ofy)) / 65536.0,
        -1024.0,
        1023.0,
    );
    break :blk .{
        .x = fx,
        .y = fy,
        .z = zf,
        .word = @bitCast(sxy2),
        .flags = Value.valid_xyz,
    };
    // A divisor of zero means H and SZ3 are both zero, which is the
    // degenerate projection that already collapses the whole scene onto the
    // offset. Recording nothing is right, and it keeps a NaN out of a
    // coordinate.
} else Value.none;
```

`sz3` is already in scope as the saturated depth; `ir1`/`ir2`/`ofx`/`ofy`/`h` are the `i64`/`u32` locals the integer path computed. Add `const std = @import("std");` to the file if absent.

RTPT projects three vertices through the same helper, so it inherits this with no separate change — confirm by reading `opRtpt` and checking it calls into the same body.

- [ ] **Step 4: Run the tests and both harnesses**

```
zig fmt ps1-core/src/cop2/opcodes.zig ps1-core/tests/pgxp_test.zig
zig build test -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- pgxp
```

Expected: unit tests PASS; `verify` OK for all ten (the integer path is untouched, so a failure here means the float block perturbed a shared local). `pgxp` **may move** — this is the change the spec flags as most likely to. Record the numbers. A drop is a finding to explain in the commit message, not a blocker; the retreat, if the numbers demand it, is to keep the float `z` and take `x`/`y` from MAC0 again.

- [ ] **Step 5: Commit**

```bash
git add ps1-core/src/cop2/opcodes.zig ps1-core/tests/pgxp_test.zig
git commit -m "feat(pgxp): recompute the projection in float

Beside the integer path, not derived from it. The ideal projection sheds the
UNR reciprocal's quantisation as well as the >> 16, and it is the only place a
depth term can come from -- MAC0 has none, and every Phase 3 consumer needs
one.

A zero divisor records nothing rather than a NaN: H and SZ3 both zero is the
degenerate projection that already collapses the scene onto the offset.

Sweep: <before -> after, per workload>"
```

---

### Task 4: The shadow set — 64 GTE registers, hi/lo, COP0

**Files:**
- Modify: `ps1-core/src/cop2/cop2.zig:165,197-268`
- Modify: `ps1-core/src/cpu/cpu.zig:36-45`
- Test: `ps1-core/tests/pgxp_test.zig`

**Interfaces:**
- Consumes: `pgxp.Value`.
- Produces: `Cop2.precise: [64]Value` replacing `precise_sxy: [3]Value`; `Cpu.hi_shadow: Value`, `Cpu.lo_shadow: Value`, `Cpu.cop0_shadow: [64]Value`. `Cop2.readPreciseData` and `writeDataPrecise` keep their signatures and gain the other 61 registers.

CPU mode moves values through registers the current three-slot array cannot hold — a game that stages a coordinate in a GTE scratch register, or through `hi`/`lo` from a multiply, loses it today.

The SXY FIFO shift still applies to slots 12/13/14, and register 15 (SXYP) still pushes it. Registers 29 and 31 are read-only and a write is ignored.

- [ ] **Step 1: Write the failing tests**

```zig
test "a GTE register outside the SXY FIFO keeps a precise value" {
    var ctx = try GteContext.init();
    defer ctx.deinit();

    const staged: Value = .{ .x = 3.5, .y = 4.5, .word = 0x0004_0003, .flags = Value.valid_xy };
    ctx.cpu.cop2.writeDataPrecise(9, 0x0004_0003, staged);
    const back = ctx.cpu.cop2.readPreciseData(9);
    try expectApproxEqAbs(@as(f32, 3.5), back.x, 0.0);
}

test "writing SXYP pushes the precise FIFO along with the registers" {
    var ctx = try GteContext.init();
    defer ctx.deinit();

    const a: Value = .{ .x = 1.5, .y = 1.5, .word = 0x0001_0001, .flags = Value.valid_xy };
    const b: Value = .{ .x = 2.5, .y = 2.5, .word = 0x0002_0002, .flags = Value.valid_xy };
    ctx.cpu.cop2.writeDataPrecise(15, 0x0001_0001, a);
    ctx.cpu.cop2.writeDataPrecise(15, 0x0002_0002, b);

    // a has been pushed down to sxy1, b sits in sxy2.
    try expectApproxEqAbs(@as(f32, 1.5), ctx.cpu.cop2.readPreciseData(13).x, 0.0);
    try expectApproxEqAbs(@as(f32, 2.5), ctx.cpu.cop2.readPreciseData(14).x, 0.0);
}

test "the read-only GTE registers refuse a precise write" {
    var ctx = try GteContext.init();
    defer ctx.deinit();

    const staged: Value = .{ .x = 3.5, .y = 4.5, .word = 0x1234, .flags = Value.valid_xy };
    ctx.cpu.cop2.writeDataPrecise(29, 0x1234, staged);
    try expectEqual(@as(u32, 0), ctx.cpu.cop2.readPreciseData(29).flags);
    ctx.cpu.cop2.writeDataPrecise(31, 0x1234, staged);
    try expectEqual(@as(u32, 0), ctx.cpu.cop2.readPreciseData(31).flags);
}
```

- [ ] **Step 2: Run and verify they fail**

```
zig build test -Doptimize=ReleaseFast
```

Expected: FAIL — `readPreciseData(9)` returns `Value.none` by the `else` arm.

- [ ] **Step 3: Widen the shadows**

In `ps1-core/src/cop2/cop2.zig`, replace `precise_sxy: [3]Value` with `precise: [64]Value = [_]Value{.{}} ** 64`, and rewrite the three accessors. `precise[12..15]` are the FIFO slots and keep their behaviour; index 15 aliases slot 14 on read and pushes on write.

```zig
pub fn readPreciseData(self: *const Self, index: anytype) Value {
    const i = getDataIdx(index);
    // 15 mirrors sxy2, exactly as the register does.
    return self.precise[if (i == 15) 14 else i];
}

pub fn writeDataPrecise(self: *Self, index: anytype, value: u32, p: Value) void {
    self.writeData(index, value);
    const i = getDataIdx(index);
    switch (i) {
        // Read-only: the register write was ignored, so the shadow must be too.
        29, 31 => {},
        // sxyp pushes the FIFO, so the value lands in sxy2.
        15 => self.precise[14] = admit(p, value),
        12, 13, 14 => self.precise[i] = admit(p, value),
        // Everything else is a plain slot. No admission test: these are not
        // screen positions and there is no integer vertex to agree with.
        else => {
            self.precise[i] = p;
            self.precise[i].word = value;
        },
    }
}

/// A screen-position slot takes a candidate only when the candidate describes
/// the integer word being written.
fn admit(p: Value, value: u32) Value {
    if (p.flags & Value.valid_xy == Value.valid_xy and p.word == value) return p;
    return Value.none;
}
```

`writeData`'s existing SXY-FIFO arm shifts `precise_sxy` — retarget those three lines to `self.precise[12..15]`, and the `12, 13, 14` arm's clear likewise. Every remaining reference to `precise_sxy` in `opcodes.zig` becomes `precise`.

In `ps1-core/src/cpu/cpu.zig`, beside `hi`/`lo`:

```zig
/// PGXP: `mult`/`div` write these, `mfhi`/`mflo` read them back.
hi_shadow: Value = .{},
lo_shadow: Value = .{},
/// PGXP: COP0's shadow, for `mfc0`/`mtc0` under CPU mode.
cop0_shadow: [64]Value = [_]Value{.{}} ** 64,
```

- [ ] **Step 4: Run the tests and the gate**

```
zig fmt ps1-core/src
zig build test -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify
```

Expected: PASS, `verify` OK for all ten. The sweep cannot move — nothing writes the new slots yet.

- [ ] **Step 5: Commit**

```bash
git add ps1-core/src ps1-core/tests/pgxp_test.zig
git commit -m "feat(pgxp): shadow every GTE register, hi/lo and COP0

Three SXY slots cannot hold a value CPU mode moves through a GTE scratch
register or through hi/lo from a multiply. The FIFO behaviour is unchanged and
the two read-only registers refuse a shadow write for the same reason they
refuse the register write."
```

---

### Task 5: The half-word memory hooks

**Files:**
- Modify: `ps1-core/src/memory.zig:218-260`
- Modify: `ps1-core/src/cpu/exec.zig:425-540`
- Test: `ps1-core/tests/pgxp_test.zig`

**Interfaces:**
- Consumes: `pgxp.Value`, `Bus.shadowLoad`/`shadowStore`.
- Produces: `Bus.shadowLoadHalf(*Bus, u32, u32, bool) Value` (address, the loaded value, signed), `Bus.shadowStoreHalf(*Bus, u32, Value) void`, `Bus.shadowMergeWord(*Bus, u32, Value) void` for the unaligned forms.

This is the leading hypothesis for Croc, whose live RAM shadow count is zero after a 600M-instruction run: a game that stores its two coordinates with separate `sh` instructions never touches the one store hook we have.

Byte loads and stores keep invalidating — a byte cannot carry a coordinate.

- [ ] **Step 1: Write the failing tests**

```zig
test "a half-word store writes one half and leaves the other alone" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);

    const addr: u32 = 0x0010_0000;
    // A whole word first, both halves precise.
    ctx.bus.shadowStore(addr, .{ .x = 1.5, .y = 2.5, .word = 0x0002_0001, .flags = Value.valid_xy });
    // Then a half-word store into the HIGH half only.
    ctx.bus.shadowStoreHalf(addr + 2, .{ .x = 9.75, .word = 0x0009, .flags = Value.valid_x });

    const back = ctx.bus.shadowLoad(addr);
    try expectApproxEqAbs(@as(f32, 1.5), back.x, 0.0);
    try expectApproxEqAbs(@as(f32, 9.75), back.y, 0.0);
    try expectEqual(Value.valid_xy, back.flags & Value.valid_xy);
}

test "a half-word load takes the addressed half into x and sign-extends into y" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);

    const addr: u32 = 0x0010_0000;
    const word: u32 = (@as(u32, @as(u16, @bitCast(@as(i16, -5)))) << 16) | 7;
    ctx.bus.shadowStore(addr, .{ .x = 7.5, .y = -5.25, .word = word, .flags = Value.valid_xy });

    // Load the HIGH half, signed: it becomes the new x, and y is its sign.
    const hi = ctx.bus.shadowLoadHalf(addr + 2, 0xFFFF_FFFB, true);
    try expectApproxEqAbs(@as(f32, -5.25), hi.x, 0.0);
    try expectApproxEqAbs(@as(f32, -1.0), hi.y, 0.0);
    try expectEqual(Value.valid_xy, hi.flags & Value.valid_xy);

    // Load the LOW half, unsigned: y is zero.
    const lo = ctx.bus.shadowLoadHalf(addr, 0x0000_0007, false);
    try expectApproxEqAbs(@as(f32, 7.5), lo.x, 0.0);
    try expectApproxEqAbs(@as(f32, 0.0), lo.y, 0.0);
}

test "a half-word load validates only the half it touches" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);

    const addr: u32 = 0x0010_0000;
    ctx.bus.shadowStore(addr, .{ .x = 7.5, .y = 3.5, .word = 0x0003_0007, .flags = Value.valid_xy });

    // The HIGH half changed under us; a load of the LOW half is still good.
    const lo = ctx.bus.shadowLoadHalf(addr, 0x0000_0007, true);
    try expectEqual(Value.valid_x, lo.flags & Value.valid_x);
    // A load of the HIGH half is not.
    const hi = ctx.bus.shadowLoadHalf(addr + 2, 0x0000_0099, true);
    try expectEqual(@as(u32, 0), hi.flags & Value.valid_x);
}

test "a byte store still destroys the whole word" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);

    const addr: u32 = 0x0010_0000;
    ctx.bus.shadowStore(addr, .{ .x = 1.5, .y = 2.5, .word = 0x0002_0001, .flags = Value.valid_xy });
    ctx.bus.shadowInvalidate(addr + 1);
    try expectEqual(@as(u32, 0), ctx.bus.shadowLoad(addr).flags);
}
```

`CpuContext` is a harness holding a heap `Bus` and a `Cpu`; copy `gte_test.zig`'s `TestContext.init`/`deinit` shape.

- [ ] **Step 2: Run and verify they fail**

```
zig build test -Doptimize=ReleaseFast
```

Expected: FAIL — the three new `Bus` methods do not exist.

- [ ] **Step 3: Add the half-word paths**

In `ps1-core/src/memory.zig`:

```zig
/// A half-word load. `value` is what the CPU actually read, and only the
/// addressed half is validated against it — the other half of the word may
/// legitimately have moved on.
///
/// The addressed half becomes the result's LOW half, because that is where a
/// 16-bit quantity sits in a register. The high half is then the sign
/// extension of it, marked valid only when the low half is: a fabricated
/// high half attached to an unknown low half is a value that looks tracked
/// and is not.
pub fn shadowLoadHalf(self: *Self, virtual_address: u32, value: u32, signed: bool) Value {
    if (!self.pgxp_enabled) return Value.none;
    const slot = self.shadowSlot(virtual_address & Addr.phys_mask) orelse return Value.none;
    const hiword = (virtual_address & 2) != 0;

    const stored: u16 = if (hiword)
        @truncate(slot.word >> 16)
    else
        @truncate(slot.word);
    if (stored != @as(u16, @truncate(value))) {
        slot.flags &= ~(if (hiword) Value.valid_y else Value.valid_x);
    }

    var out = slot.*;
    if (hiword) {
        out.x = out.y;
        out.flags = (out.flags & ~Value.valid_x) | ((out.flags & Value.valid_y) >> 1);
    }
    if (out.flags & Value.valid_x != 0) {
        out.y = if (signed and out.x < 0) -1.0 else 0.0;
        out.flags |= Value.valid_y;
    } else {
        out.y = 0.0;
        out.flags &= ~Value.valid_y;
    }
    out.word = value;
    return out;
}

/// A half-word store. The source's LOW half is written into the addressed
/// half of the destination, and the other half of the destination survives.
pub fn shadowStoreHalf(self: *Self, virtual_address: u32, p: Value) void {
    if (!self.pgxp_enabled) return;
    const slot = self.shadowSlot(virtual_address & Addr.phys_mask) orelse return;
    const hiword = (virtual_address & 2) != 0;

    if (hiword) {
        slot.y = p.x;
        slot.flags = (slot.flags & ~Value.valid_y) | ((p.flags & Value.valid_x) << 1);
        slot.word = (slot.word & 0x0000_FFFF) | (p.word << 16);
    } else {
        slot.x = p.x;
        slot.flags = (slot.flags & ~Value.valid_x) | (p.flags & Value.valid_x);
        slot.word = (slot.word & 0xFFFF_0000) | (p.word & 0x0000_FFFF);
    }

    // The z belongs to whichever half supplied it, so a later write to that
    // half retires it.
    const half_bit = if (hiword) Value.high_z else Value.low_z;
    if (p.flags & Value.valid_z != 0) {
        slot.z = p.z;
        slot.flags |= Value.valid_z | half_bit;
    } else {
        slot.flags &= ~half_bit;
        if (slot.flags & (Value.low_z | Value.high_z) == 0) slot.flags &= ~Value.valid_z;
    }
}

/// A whole-word store from a value that already describes the word, used by
/// the unaligned forms after they have merged. Mirrors `shadowStore` but
/// promotes a whole-word z onto both halves.
pub fn shadowMergeWord(self: *Self, virtual_address: u32, p: Value) void {
    if (!self.pgxp_enabled) return;
    const slot = self.shadowSlot(virtual_address & Addr.phys_mask) orelse return;
    slot.* = p;
    slot.flags = (p.flags & ~(Value.low_z | Value.high_z)) |
        (if (p.flags & Value.valid_z != 0) Value.low_z | Value.high_z else 0);
}
```

In `ps1-core/src/cpu/exec.zig`:

- `opLoad`'s `.Half` arm sets `cpu.load_shadow = cpu.bus.shadowLoadHalf(address, final_val, signed)` instead of `Value.none`. `.Byte` keeps `Value.none`.
- `opStore`'s `.Half` arm calls `cpu.bus.shadowStoreHalf(address, cpu.gpr_shadow[cpu.getIdx(instr.i.rt)])` instead of `shadowInvalidate`, and still clears `pgxp_pending` — a half-word store to GP0 is not a vertex.
- `opUnalignedStore` merges: read the destination's shadow, write the source's surviving bytes as an invalidation of the affected halves, then `shadowMergeWord`. If the merge would touch both halves, invalidate. Keep it simple and conservative — the unaligned forms are rare and a missed one costs coverage, not correctness.

- [ ] **Step 4: Run everything**

```
zig fmt ps1-core/src ps1-core/tests/pgxp_test.zig
zig build test -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- pgxp
```

Expected: unit PASS, `verify` OK. **This is the task where Croc may move off 25,854** — check its number specifically and record it.

- [ ] **Step 5: Commit**

```bash
git add ps1-core
git commit -m "feat(pgxp): track half-word loads and stores

The leading hypothesis for the three games that resolve only the BIOS licence
logo: Croc ends a 600M-instruction run with zero live RAM shadow entries, and a
game that stores its two coordinates with separate sh instructions never
touches the one store hook we had.

A half-word load validates only the half it addresses, and marks its
sign-extended high half valid only when the low half is -- a fabricated high
half attached to an unknown low half looks tracked and is not.

Croc: <before> -> <after>"
```

---

### Task 6: CPU mode — the flag, the seam, and the immediate ops

**Files:**
- Create: `ps1-core/src/pgxp/ops.zig`
- Modify: `ps1-core/src/memory.zig:98` (the flag)
- Modify: `ps1-core/src/cpu/exec.zig:103-125,183-194`
- Test: `ps1-core/tests/pgxp_test.zig`

**Interfaces:**
- Consumes: `pgxp.Value`, `Cpu.gpr_shadow`, `Bus.pgxp_enabled`.
- Produces: `Bus.pgxp_cpu: bool = false`; and in `pgxp/ops.zig`, taking `*Cpu` so each has the whole register file: `move(*Cpu, u5, u5) void`, `addi(*Cpu, u5, u5, u32) void`, `andi(*Cpu, u5, u5, u32) void`, `ori(*Cpu, u5, u5, u32) void`, `xori(*Cpu, u5, u5, u32) void`, `lui(*Cpu, u5, u32) void`, `sltImm(*Cpu, u5, u5) void`. Every one takes destination register, source register, and the raw immediate where relevant; every one reads the current integer register values off `cpu.regs` itself rather than being handed them.

CPU mode ships **off**, matching the reference, where it is a per-game workaround rather than part of the picture. Task 14 revisits that default with the sweep in hand.

The dispatch seam: each hooked arm in `exec.zig` calls its `ops` function **after** the integer result has been written, guarded by `if (cpu.bus.pgxp_enabled and cpu.bus.pgxp_cpu)`. Writing the integer first matters — `writeReg` clears the shadow, so a propagation that ran first would be erased by its own instruction.

- [ ] **Step 1: Write the failing tests**

```zig
test "an immediate add carries between the halves" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    // $t0 low half 0xFFF0 precise at 65520.5 unsigned, high half 3.
    ctx.cpu.regs[8] = 0x0003_FFF0;
    ctx.cpu.gpr_shadow[8] = .{ .x = -15.5, .y = 3.0, .word = 0x0003_FFF0, .flags = Value.valid_xy };

    // addiu $t1, $t0, 0x20 -- the low half wraps and carries into the high.
    ctx.cpu.writeReg(9, 0x0003_FFF0 +% 0x20);
    pgxp.ops.addi(&ctx.cpu, 9, 8, 0x20);

    const p = ctx.cpu.gpr_shadow[9];
    try expectApproxEqAbs(@as(f32, 16.5), p.x, 0.01);
    try expectApproxEqAbs(@as(f32, 4.0), p.y, 0.01);
}

test "an immediate add of zero is a move and keeps the value untouched" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0002_0001;
    ctx.cpu.gpr_shadow[8] = .{ .x = 1.5, .y = 2.5, .z = 9.0, .word = 0x0002_0001, .flags = Value.valid_xyz };
    ctx.cpu.writeReg(9, 0x0002_0001);
    pgxp.ops.addi(&ctx.cpu, 9, 8, 0);

    const p = ctx.cpu.gpr_shadow[9];
    try expectApproxEqAbs(@as(f32, 1.5), p.x, 0.0);
    try expectApproxEqAbs(@as(f32, 9.0), p.z, 0.0);
    try expectEqual(Value.valid_z, p.flags & Value.valid_z);
}

test "andi with 0xFFFF keeps the precise low half and clears the high" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0002_0001;
    ctx.cpu.gpr_shadow[8] = .{ .x = 1.25, .y = 2.5, .word = 0x0002_0001, .flags = Value.valid_xy };
    ctx.cpu.writeReg(9, 0x0000_0001);
    pgxp.ops.andi(&ctx.cpu, 9, 8, 0xFFFF);

    const p = ctx.cpu.gpr_shadow[9];
    try expectApproxEqAbs(@as(f32, 1.25), p.x, 0.0);
    try expectApproxEqAbs(@as(f32, 0.0), p.y, 0.0);
    try expectEqual(Value.valid_xy, p.flags & Value.valid_xy);
}

test "andi with a partial mask falls back to the integer low half" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0002_0009;
    ctx.cpu.gpr_shadow[8] = .{ .x = 9.75, .y = 2.5, .word = 0x0002_0009, .flags = Value.valid_xy };
    ctx.cpu.writeReg(9, 0x0000_0008);
    pgxp.ops.andi(&ctx.cpu, 9, 8, 0xFFF8);

    // The masked value is no longer 9.75 by any reading; the integer wins.
    try expectApproxEqAbs(@as(f32, 8.0), ctx.cpu.gpr_shadow[9].x, 0.0);
}

test "a stale source is validated away before it propagates" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    // The shadow was recorded against a word the register no longer holds.
    ctx.cpu.regs[8] = 0x0000_0005;
    ctx.cpu.gpr_shadow[8] = .{ .x = 1.5, .y = 2.5, .word = 0x0002_0001, .flags = Value.valid_xy };
    ctx.cpu.writeReg(9, 0x0000_0025);
    pgxp.ops.addi(&ctx.cpu, 9, 8, 0x20);

    try expectEqual(@as(u32, 0), ctx.cpu.gpr_shadow[9].flags & Value.valid_xy);
}

test "CPU mode is off by default and propagates nothing when off" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    try expectEqual(false, ctx.bus.pgxp_cpu);
}
```

- [ ] **Step 2: Run and verify they fail**

```
zig build test -Doptimize=ReleaseFast
```

Expected: FAIL — `pgxp.ops` does not exist.

- [ ] **Step 3: Implement**

`ps1-core/src/memory.zig`, beside `pgxp_enabled`:

```zig
/// PGXP propagation through CPU arithmetic. Off by default: it is a
/// per-game workaround in the reference, and it is the part of PGXP most
/// able to make a picture worse.
pgxp_cpu: bool = false,
```

Create `ps1-core/src/pgxp/ops.zig`. The shared shape every op follows:

```zig
const std = @import("std");
const pgxp = @import("pgxp.zig");
const Value = pgxp.Value;
const Cpu = @import("../cpu/cpu.zig").Cpu;

/// Read a source register's shadow, validated against what the register
/// actually holds. Every op starts here: a shadow that outlived its value is
/// dropped before it can propagate into a result.
fn source(cpu: *Cpu, r: u5) Value {
    var v = cpu.gpr_shadow[r];
    v.validate(cpu.regs[r]);
    cpu.gpr_shadow[r] = v;
    return v;
}

fn store(cpu: *Cpu, r: u5, v: Value) void {
    if (r != 0) cpu.gpr_shadow[r] = v;
}

/// A register move: the whole value travels, including its depth term.
pub fn move(cpu: *Cpu, rd: u5, rs: u5) void {
    store(cpu, rd, source(cpu, rs));
}

/// Rt = Rs + sign-extended immediate.
pub fn addi(cpu: *Cpu, rt: u5, rs: u5, imm: u32) void {
    const src = source(cpu, rs);
    var out = src;

    if (imm == 0) {
        store(cpu, rt, out);
        return;
    }

    const rs_val = cpu.regs[rs];
    if (rs_val == 0) {
        // Nothing precise went in, so the immediate itself is the value and
        // both halves are exactly known.
        out.x = @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(imm)))));
        out.y = @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(imm >> 16)))));
        out.word = imm;
        out.flags |= Value.valid_xy | Value.tainted_z;
        store(cpu, rt, out);
        return;
    }

    var x = pgxp.unsign(src.validX(rs_val));
    x += @floatFromInt(@as(u16, @truncate(imm)));
    const carry: f32 = if (x > 65535.0) 1.0 else if (x < 0.0) -1.0 else 0.0;
    out.x = @floatCast(pgxp.signFold(x));
    out.y = src.validY(rs_val) +
        @as(f32, @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(imm >> 16)))))) + carry;
    out.y += if (out.y > 32767.0) -65536.0 else if (out.y < -32768.0) 65536.0 else 0.0;
    out.word = rs_val +% imm;
    out.flags |= Value.tainted_z;
    store(cpu, rt, out);
}
```

`andi`, `ori`, `xori`, `lui` and `sltImm` follow the same skeleton with these rules:

- **`andi`** — the high half is masked away entirely, so `y = 0` and valid. The low half is the source's `x` when the mask is `0xFFFF`, zero when the mask is zero, and otherwise the integer low half of the result, since a partial mask makes the precise value meaningless.
- **`ori` and `xori`** — a zero immediate leaves the value alone; otherwise the low half becomes the integer low half of the result and the high half survives.
- **`lui`** — the high half is exactly the immediate, the low half is exactly zero, both valid, no depth.
- **`sltImm`** — the result is 0 or 1, so both halves are exactly known integers, and nothing precise survives.

Hook them in `exec.zig`. The `0x09` (`addiu`) arm, for example, becomes:

```zig
0x09 => {
    iOpSignExt(cpu, instr, alu.addu);
    if (cpu.bus.pgxp_enabled and cpu.bus.pgxp_cpu) {
        pgxp_ops.addi(cpu, instr.i.rt, instr.i.rs, signExtend16(instr.i.imm));
    }
},
```

with the same shape for `0x08` (`addi`, and only when the checked add did not except), `0x0A`/`0x0B` (`slti`/`sltiu` → `sltImm`), `0x0C` (`andi`), `0x0D` (`ori`), `0x0E` (`xori`) and `0x0F` (`lui`). `rOpMove`'s existing `$zero` special case is replaced by a call to `pgxp_ops.move`, so the one idiom that worked before now goes through the same path as the rest.

- [ ] **Step 4: Run everything**

```
zig fmt ps1-core/src ps1-core/tests/pgxp_test.zig
zig build test -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- pgxp
```

Expected: unit PASS, `verify` OK. The sweep must be **unchanged**, because CPU mode is off — that is the check that the flag actually gates.

- [ ] **Step 5: Commit**

```bash
git add ps1-core
git commit -m "feat(pgxp): CPU mode's flag, dispatch seam and immediate ops

Off by default, as in the reference, where it is a per-game workaround rather
than part of the shipped picture.

Each hook runs AFTER the integer result is written: writeReg clears the shadow,
so a propagation that ran first would be erased by its own instruction. Every
op validates its sources before reading them, which is what stops a shadow that
outlived its value propagating into a result.

The old or/addu-against-zero special case now goes through the same move() the
rest of the set uses."
```

---

### Task 7: CPU mode — register arithmetic and logicals

**Files:**
- Modify: `ps1-core/src/pgxp/ops.zig`
- Modify: `ps1-core/src/cpu/exec.zig:183-194`
- Test: `ps1-core/tests/pgxp_test.zig`

**Interfaces:**
- Consumes: `source`/`store` and the helpers from Task 6.
- Produces: `add(*Cpu, u5, u5, u5) void`, `sub(*Cpu, u5, u5, u5) void`, `bitwise(*Cpu, u5, u5, u5) void`, `sltReg(*Cpu, u5, u5, u5) void` — all `(cpu, rd, rs, rt)`. Also `copyZIfMissing(*Value, Value) void` and `selectZ(*Value, Value, Value) void`, which Tasks 8 and 9 reuse.

`selectZ` is the rule that decides which of two operands' depth terms survives: prefer the second when the first has none, or when the first is tainted and the second is both valid and untainted. That is what stops an arithmetic chain carrying a depth that no longer describes the position beside it.

- [ ] **Step 1: Write the failing tests**

```zig
test "adding two tracked registers carries between the halves" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0001_8000;
    ctx.cpu.gpr_shadow[8] = .{ .x = -32768.0, .y = 1.0, .word = 0x0001_8000, .flags = Value.valid_xy };
    ctx.cpu.regs[9] = 0x0001_8000;
    ctx.cpu.gpr_shadow[9] = .{ .x = -32768.0, .y = 1.0, .word = 0x0001_8000, .flags = Value.valid_xy };

    ctx.cpu.writeReg(10, 0x0003_0000);
    pgxp.ops.add(&ctx.cpu, 10, 8, 9);

    const p = ctx.cpu.gpr_shadow[10];
    try expectApproxEqAbs(@as(f32, 0.0), p.x, 0.01);
    try expectApproxEqAbs(@as(f32, 3.0), p.y, 0.01);
}

test "adding zero is a move that adopts the other operand's depth" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0002_0001;
    ctx.cpu.gpr_shadow[8] = .{ .x = 1.5, .y = 2.5, .word = 0x0002_0001, .flags = Value.valid_xy };
    ctx.cpu.regs[9] = 0;
    ctx.cpu.gpr_shadow[9] = .{ .z = 42.0, .word = 0, .flags = Value.valid_z };

    ctx.cpu.writeReg(10, 0x0002_0001);
    pgxp.ops.add(&ctx.cpu, 10, 8, 9);

    const p = ctx.cpu.gpr_shadow[10];
    try expectApproxEqAbs(@as(f32, 1.5), p.x, 0.0);
    try expectApproxEqAbs(@as(f32, 42.0), p.z, 0.0);
}

test "an untainted depth beats a tainted one when two values combine" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0000_0010;
    ctx.cpu.gpr_shadow[8] = .{
        .x = 16.0, .y = 0, .z = 1.0, .word = 0x0000_0010,
        .flags = Value.valid_xyz | Value.tainted_z,
    };
    ctx.cpu.regs[9] = 0x0000_0020;
    ctx.cpu.gpr_shadow[9] = .{ .x = 32.0, .y = 0, .z = 2.0, .word = 0x0000_0020, .flags = Value.valid_xyz };

    ctx.cpu.writeReg(10, 0x0000_0030);
    pgxp.ops.add(&ctx.cpu, 10, 8, 9);

    try expectApproxEqAbs(@as(f32, 2.0), ctx.cpu.gpr_shadow[10].z, 0.0);
}

test "a bitwise op keeps the depth and takes its halves from the integer result" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0003_0005;
    ctx.cpu.gpr_shadow[8] = .{ .x = 5.5, .y = 3.5, .z = 7.0, .word = 0x0003_0005, .flags = Value.valid_xyz };
    ctx.cpu.regs[9] = 0x0000_0003;
    ctx.cpu.gpr_shadow[9] = .{ .word = 0x0000_0003 };

    ctx.cpu.writeReg(10, 0x0000_0001);
    pgxp.ops.bitwise(&ctx.cpu, 10, 8, 9);

    const p = ctx.cpu.gpr_shadow[10];
    try expectApproxEqAbs(@as(f32, 1.0), p.x, 0.0);
    try expectApproxEqAbs(@as(f32, 0.0), p.y, 0.0);
    try expectApproxEqAbs(@as(f32, 7.0), p.z, 0.0);
}
```

- [ ] **Step 2: Run and verify they fail**

```
zig build test -Doptimize=ReleaseFast
```

Expected: FAIL — `pgxp.ops.add` does not exist.

- [ ] **Step 3: Implement**

Append to `ps1-core/src/pgxp/ops.zig`:

```zig
/// A depth term travels only where the destination has none of its own.
pub fn copyZIfMissing(dst: *Value, src: Value) void {
    if (dst.flags & Value.valid_z == 0) dst.z = src.z;
    dst.flags |= src.flags & Value.valid_z;
}

/// Which of two operands' depth terms describes the result.
///
/// The second wins when the first has none, or when the first is tainted and
/// the second is valid and untainted — a depth recorded before its position
/// was altered no longer describes that position, and losing to an untainted
/// one is how an arithmetic chain avoids carrying it forward.
pub fn selectZ(dst: *Value, a: Value, b: Value) void {
    const a_unusable = (a.flags & Value.valid_z == 0) or
        (a.flags & Value.tainted_z != 0 and
            b.flags & (Value.valid_z | Value.tainted_z) == Value.valid_z);
    dst.z = if (a_unusable) b.z else a.z;
    dst.flags |= (a.flags | b.flags) & Value.valid_z;
}

pub fn add(cpu: *Cpu, rd: u5, rs: u5, rt: u5) void {
    const a = source(cpu, rs);
    const b = source(cpu, rt);
    const av = cpu.regs[rs];
    const bv = cpu.regs[rt];

    if (bv == 0) {
        var out = a;
        copyZIfMissing(&out, b);
        store(cpu, rd, out);
        return;
    }
    if (av == 0) {
        var out = b;
        copyZIfMissing(&out, a);
        store(cpu, rd, out);
        return;
    }

    var out: Value = .{};
    const x = pgxp.unsign(a.validX(av)) + pgxp.unsign(b.validX(bv));
    const carry: f32 = if (x > 65535.0) 1.0 else if (x < 0.0) -1.0 else 0.0;
    out.x = @floatCast(pgxp.signFold(x));
    out.y = a.validY(av) + b.validY(bv) + carry;
    out.y += if (out.y > 32767.0) -65536.0 else if (out.y < -32768.0) 65536.0 else 0.0;
    out.word = av +% bv;
    out.flags = a.flags | (b.flags & Value.valid_xy) | Value.tainted_z;
    selectZ(&out, a, b);
    store(cpu, rd, out);
}
```

`sub` is `add` with the second operand negated in both halves and the borrow going the other way. `bitwise` covers `and`/`or`/`xor`/`nor`: the halves come from the integer result — no bit pattern of two precise values is itself precise — while the depth survives through `selectZ`, because a mask does not move a vertex. `sltReg` produces an exact 0 or 1 in the low half, zero in the high, and no depth.

Hook the six arms in `exec.zig` (`0x20`/`0x21` → `add`, `0x22`/`0x23` → `sub`, `0x24`/`0x25`/`0x26`/`0x27` → `bitwise`, `0x2A`/`0x2B` → `sltReg`) with the same `if (cpu.bus.pgxp_enabled and cpu.bus.pgxp_cpu)` guard, after the integer write. `rOpMove`'s `$zero` case still short-circuits to `move`.

- [ ] **Step 4: Run everything**

```
zig fmt ps1-core/src ps1-core/tests/pgxp_test.zig
zig build test -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify
```

Expected: PASS, `verify` OK, sweep unchanged (CPU mode still off).

- [ ] **Step 5: Commit**

```bash
git add ps1-core
git commit -m "feat(pgxp): CPU mode register arithmetic and logicals

selectZ is the load-bearing rule here: a depth recorded before its position was
altered no longer describes that position, so a tainted one loses to an
untainted one and an arithmetic chain stops carrying it forward.

A bitwise op takes its halves from the integer result -- no bit pattern of two
precise values is itself precise -- but keeps the depth, since a mask does not
move a vertex."
```

---

### Task 8: CPU mode — the shifts and their three carve-outs

**Files:**
- Create: `ps1-core/src/pgxp/shift.zig`
- Modify: `ps1-core/src/cpu/exec.zig:160-166`
- Test: `ps1-core/tests/pgxp_test.zig`

**Interfaces:**
- Consumes: `source`/`store` from Task 6 — export them from `ops.zig` so `shift.zig` can call them.
- Produces: `shift.left(*Cpu, u5, u5, u5) void` and `shift.right(*Cpu, u5, u5, u5, bool, bool) void` — `(cpu, rd, rt, amount, signed, variable)`.

**The shifts are the most important ops in CPU mode and the most delicate.** A shift by 16 is the pack/unpack idiom: it is how a game splits a packed SXY into two registers and puts it back together, which is exactly the traffic the old representation could not survive.

Three carve-outs are reproduced from the reference because they are bug fixes, not taste. Each gets a test verified to fail against the naive version.

- [ ] **Step 1: Write the failing tests**

```zig
test "a left shift by 16 moves the low half into the high half" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0000_0007;
    ctx.cpu.gpr_shadow[8] = .{ .x = 7.25, .y = 0.0, .word = 0x0000_0007, .flags = Value.valid_xy };
    ctx.cpu.writeReg(9, 0x0007_0000);
    pgxp.shift.left(&ctx.cpu, 9, 8, 16);

    const p = ctx.cpu.gpr_shadow[9];
    try expectApproxEqAbs(@as(f32, 7.25), p.y, 0.0);
    try expectApproxEqAbs(@as(f32, 0.0), p.x, 0.0);
}

test "the pack and unpack idiom round-trips a precise half" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    // A packed SXY: x = 100.5 in the low half, y = 50.25 in the high.
    ctx.cpu.regs[8] = (@as(u32, 50) << 16) | 100;
    ctx.cpu.gpr_shadow[8] = .{
        .x = 100.5, .y = 50.25, .word = ctx.cpu.regs[8], .flags = Value.valid_xy,
    };

    // sra $t1, $t0, 16 -- unpack the high half into its own register.
    ctx.cpu.writeReg(9, 50);
    pgxp.shift.right(&ctx.cpu, 9, 8, 16, true, false);
    try expectApproxEqAbs(@as(f32, 50.25), ctx.cpu.gpr_shadow[9].x, 0.001);

    // sll $t2, $t1, 16 -- and put it back.
    ctx.cpu.writeReg(10, 50 << 16);
    pgxp.shift.left(&ctx.cpu, 10, 9, 16);
    try expectApproxEqAbs(@as(f32, 50.25), ctx.cpu.gpr_shadow[10].y, 0.001);
}

test "a left shift by 16 does not mark x valid from an invalid y" {
    // THE SPYRO RULE. The naive form marks the destination's x valid outright,
    // because the shift zeroes it and zero is exactly known. It is not: the
    // valid bits must be derived from the SOURCE's y, or a register whose high
    // half was never tracked starts claiming a precise low half of zero and
    // the value spreads.
    //
    // Verify this test FAILS against the naive version before implementing.
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0000_0007;
    // Only x is tracked; y is not.
    ctx.cpu.gpr_shadow[8] = .{ .x = 7.25, .word = 0x0000_0007, .flags = Value.valid_x };
    ctx.cpu.writeReg(9, 0x0007_0000);
    pgxp.shift.left(&ctx.cpu, 9, 8, 16);

    try expectEqual(@as(u32, 0), ctx.cpu.gpr_shadow[9].flags & Value.valid_x);
}

test "a small signed shift of a non-3D value falls back to the integers" {
    // THE PERSONA 2 RULE. A signed, non-variable shift under 16 of a value
    // carrying no depth is overwhelmingly not geometry, and treating it as
    // precise produces false positives that spread through the register file.
    // The rounded integer halves are used instead.
    //
    // Verify this test FAILS against the unconditional version.
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0000_0009;
    // No valid_z: this value did not come from a projection.
    ctx.cpu.gpr_shadow[8] = .{ .x = 9.75, .y = 0.0, .word = 0x0000_0009, .flags = Value.valid_xy };
    ctx.cpu.writeReg(9, 0x0000_0004);
    pgxp.shift.right(&ctx.cpu, 9, 8, 1, true, false);

    // 9.75 / 2 would be 4.875; the integer result 4 is used instead.
    try expectApproxEqAbs(@as(f32, 4.0), ctx.cpu.gpr_shadow[9].x, 0.0);
}

test "the same shift of a projected value keeps its precision" {
    // The control for the rule above: with a depth term present the value IS
    // geometry, and the precise path runs.
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0000_0009;
    ctx.cpu.gpr_shadow[8] = .{
        .x = 9.75, .y = 0.0, .z = 400.0, .word = 0x0000_0009, .flags = Value.valid_xyz,
    };
    ctx.cpu.writeReg(9, 0x0000_0004);
    pgxp.shift.right(&ctx.cpu, 9, 8, 1, true, false);

    try expectApproxEqAbs(@as(f32, 4.875), ctx.cpu.gpr_shadow[9].x, 0.001);
}

test "a shift by zero passes the value through untouched" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0002_0001;
    ctx.cpu.gpr_shadow[8] = .{ .x = 1.5, .y = 2.5, .z = 3.5, .word = 0x0002_0001, .flags = Value.valid_xyz };
    ctx.cpu.writeReg(9, 0x0002_0001);
    pgxp.shift.right(&ctx.cpu, 9, 8, 0, true, false);

    try expectApproxEqAbs(@as(f32, 1.5), ctx.cpu.gpr_shadow[9].x, 0.0);
    try expectApproxEqAbs(@as(f32, 3.5), ctx.cpu.gpr_shadow[9].z, 0.0);
}
```

- [ ] **Step 2: Run and verify they fail**

```
zig build test -Doptimize=ReleaseFast
```

Expected: FAIL — `pgxp.shift` does not exist.

- [ ] **Step 3: Implement**

Create `ps1-core/src/pgxp/shift.zig`. `left` has four cases on the shift amount:

- **32 or more** — both halves are zero and exactly known.
- **exactly 16** — the source's `x` becomes the destination's `y`, and `x` is zero. **The valid bits come from the source's `y` bit shifted down, not set outright** — the Spyro rule above.
- **17 to 31** — the source's `x` scaled by `1 << (sh - 16)` becomes `y` through the sign fold; `x` is zero; same valid-bit derivation.
- **1 to 15** — both halves scale, with `overflow(x)` carrying into `y`.

`right` (covering `srl`, `sra`, `srlv`, `srav`) follows the reference's structure:

- A shift of zero copies the value and returns.
- Compute two integer probes — the low half sign-extended, and the word with its low half overwritten by the sign of the low half — and shift each. Comparing each probe's low half against the source's sign tells you whether the component survived the shift at all, and that is what decides whether to scale the precise half or to take the sign bits.
- At exactly 16 the high half becomes the new low half; below 16 the high half's contribution is scaled up into the low; above 16 it is scaled down.
- **The Persona 2 carve-out** wraps the result: when the shift is signed, non-variable, under 16, and the source carries no `valid_z`, discard everything computed above and take the rounded integer halves of the actual result, with `valid_xy | tainted_z` and no depth.

Hook `exec.zig`'s special arms after the integer write, under the usual guard: `0x00` → `left` with `instr.r.shamt`, `0x02` → `right(..., false, false)`, `0x03` → `right(..., true, false)`, `0x04` → `left` with `cpu.regs[rs] & 0x1F`, `0x06` → `right(..., false, true)`, `0x07` → `right(..., true, true)`.

- [ ] **Step 4: Verify the two carve-out tests actually fail against the naive versions**

Before running the suite green, temporarily implement each naive form and confirm its test fails:

1. In the `sh == 16` branch of `left`, set `flags = prt.flags | Value.valid_x | Value.tainted_z`. Run: `aLeftShiftBy16DoesNotMarkXValidFromAnInvalidY` must FAIL. Revert.
2. In `right`, drop the Persona 2 branch entirely. Run: `aSmallSignedShiftOfANon3DValueFallsBackToTheIntegers` must FAIL. Revert.

Record both observations in the commit message. A carve-out test that cannot fail is worse than none.

- [ ] **Step 5: Run everything and commit**

```
zig fmt ps1-core/src ps1-core/tests/pgxp_test.zig
zig build test -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify
```

```bash
git add ps1-core
git commit -m "feat(pgxp): CPU mode shifts, with the two carve-outs pinned

A shift by 16 is the pack/unpack idiom -- how a game splits a packed SXY into
two registers and puts it back -- which is the traffic the old coupled
representation could not survive at all.

Two rules are reproduced from the reference because they are bug fixes rather
than taste, and each has a test verified to FAIL against the naive form first:
a left shift by 16 derives its valid bits from the SOURCE's y rather than
marking x valid outright (a register whose high half was never tracked
otherwise starts claiming a precise zero and it spreads), and a signed,
non-variable shift under 16 of a value carrying no depth falls back to the
rounded integers."
```

---

### Task 9: CPU mode — multiply, divide, hi/lo and COP0

**Files:**
- Create: `ps1-core/src/pgxp/muldiv.zig`
- Modify: `ps1-core/src/cpu/exec.zig:167-182,327-340`
- Test: `ps1-core/tests/pgxp_test.zig`

**Interfaces:**
- Consumes: `source`/`store`/`copyZIfMissing` from Tasks 6-7, `Cpu.hi_shadow`/`lo_shadow`/`cop0_shadow` from Task 4.
- Produces: `muldiv.mult(*Cpu, u5, u5, bool) void` (`cpu, rs, rt, signed`), `muldiv.div(*Cpu, u5, u5, bool) void`, `muldiv.moveFromHi(*Cpu, u5) void`, `muldiv.moveToHi(*Cpu, u5) void`, `muldiv.moveFromLo(*Cpu, u5) void`, `muldiv.moveToLo(*Cpu, u5) void`, `muldiv.mfc0(*Cpu, u5, u5) void`, `muldiv.mtc0(*Cpu, u5, u5) void`.

A multiply is where a game scales a projected coordinate, so this is the op that matters most for a title doing its own transform after the GTE.

- [ ] **Step 1: Write the failing tests**

```zig
test "a multiply splits across hi and lo and keeps the depth" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    // 3.5 * 2 = 7, entirely inside the low half.
    ctx.cpu.regs[8] = 3;
    ctx.cpu.gpr_shadow[8] = .{ .x = 3.5, .y = 0.0, .z = 500.0, .word = 3, .flags = Value.valid_xyz };
    ctx.cpu.regs[9] = 2;
    ctx.cpu.gpr_shadow[9] = .{ .x = 2.0, .y = 0.0, .word = 2, .flags = Value.valid_xy };

    ctx.cpu.hi = 0;
    ctx.cpu.lo = 6;
    pgxp.muldiv.mult(&ctx.cpu, 8, 9, true);

    try expectApproxEqAbs(@as(f32, 7.0), ctx.cpu.lo_shadow.x, 0.01);
    try expectApproxEqAbs(@as(f32, 500.0), ctx.cpu.lo_shadow.z, 0.0);
    try expectEqual(Value.tainted_z, ctx.cpu.lo_shadow.flags & Value.tainted_z);
}

test "mflo recovers the multiply's precise result" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.lo = 7;
    ctx.cpu.lo_shadow = .{ .x = 7.5, .y = 0.0, .word = 7, .flags = Value.valid_xy };
    ctx.cpu.writeReg(10, 7);
    pgxp.muldiv.moveFromLo(&ctx.cpu, 10);

    try expectApproxEqAbs(@as(f32, 7.5), ctx.cpu.gpr_shadow[10].x, 0.0);
}

test "a divide produces a precise quotient in lo" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 9;
    ctx.cpu.gpr_shadow[8] = .{ .x = 9.5, .y = 0.0, .word = 9, .flags = Value.valid_xy };
    ctx.cpu.regs[9] = 2;
    ctx.cpu.gpr_shadow[9] = .{ .x = 2.0, .y = 0.0, .word = 2, .flags = Value.valid_xy };

    ctx.cpu.lo = 4;
    ctx.cpu.hi = 1;
    pgxp.muldiv.div(&ctx.cpu, 8, 9, true);

    try expectApproxEqAbs(@as(f32, 4.75), ctx.cpu.lo_shadow.x, 0.01);
}

test "a divide by zero leaves nothing precise behind" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 9;
    ctx.cpu.gpr_shadow[8] = .{ .x = 9.5, .y = 0.0, .word = 9, .flags = Value.valid_xy };
    ctx.cpu.regs[9] = 0;
    ctx.cpu.gpr_shadow[9] = .{ .x = 0.0, .y = 0.0, .word = 0, .flags = Value.valid_xy };

    pgxp.muldiv.div(&ctx.cpu, 8, 9, true);

    try expectEqual(@as(u32, 0), ctx.cpu.lo_shadow.flags & Value.valid_xy);
    try expectEqual(@as(u32, 0), ctx.cpu.hi_shadow.flags & Value.valid_xy);
}

test "a value survives a round trip through a COP0 register" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0002_0001;
    ctx.cpu.gpr_shadow[8] = .{ .x = 1.5, .y = 2.5, .word = 0x0002_0001, .flags = Value.valid_xy };
    pgxp.muldiv.mtc0(&ctx.cpu, 7, 8);
    ctx.cpu.writeReg(10, 0x0002_0001);
    pgxp.muldiv.mfc0(&ctx.cpu, 10, 7);

    try expectApproxEqAbs(@as(f32, 1.5), ctx.cpu.gpr_shadow[10].x, 0.0);
}
```

- [ ] **Step 2: Run and verify they fail**

```
zig build test -Doptimize=ReleaseFast
```

Expected: FAIL — `pgxp.muldiv` does not exist.

- [ ] **Step 3: Implement**

Create `ps1-core/src/pgxp/muldiv.zig`.

`mult` treats each operand as `low + high * 65536` and forms the four half-products, then recombines: the low result's low half is the low-low product, its high half is that product's overflow plus the two cross terms, the high result's low half is that half's overflow plus the high-high product, and the high result's high half is the remainder. Each half goes through the sign fold. Both destinations take the first operand's flags with the second's validity folded in, plus `tainted_z`, and the depth comes from `copyZIfMissing`. The integer `hi`/`lo` are already written by `hiLoOp`, so the shadow's `word` fields are taken from `cpu.hi` and `cpu.lo` after that write.

`div` computes the quotient from the two operands' full precise values and puts it in `lo_shadow`; `hi_shadow` takes the remainder and is marked invalid rather than guessed at, since a precise remainder is not a meaningful quantity. **A zero divisor invalidates both** — the PS1's divide-by-zero quirk produces a fixed integer result that no precise value corresponds to.

`moveFromHi`/`moveFromLo` copy the shadow into the destination GPR after validating it against `cpu.hi`/`cpu.lo`. `moveToHi`/`moveToLo` go the other way. `mfc0`/`mtc0` are the same shape against `cop0_shadow`.

Hook `exec.zig`'s special arms `0x10`/`0x11`/`0x12`/`0x13` and `0x18`/`0x19`/`0x1A`/`0x1B`, plus the `MFC0`/`MTC0` arms in the COP0 dispatch at `exec.zig:327-340`, all after the integer write and under the usual guard.

- [ ] **Step 4: Run everything and commit**

```
zig fmt ps1-core/src ps1-core/tests/pgxp_test.zig
zig build test -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify
```

```bash
git add ps1-core
git commit -m "feat(pgxp): CPU mode multiply, divide, hi/lo and COP0

A multiply is where a game scales a projected coordinate, so it matters most
for a title doing its own transform after the GTE. The four half-products
recombine into a hi/lo pair through the same sign fold every other op uses.

A zero divisor invalidates both halves rather than guessing: the PS1's
divide-by-zero quirk produces a fixed integer result no precise value
corresponds to. A remainder is invalidated for the same reason."
```

---

### Task 10: The vertex cache

**Files:**
- Create: `ps1-core/src/pgxp/cache.zig`
- Modify: `ps1-core/src/memory.zig:98` (the flag and the pointer)
- Modify: `ps1-core/src/cop2/opcodes.zig` (the write on RTPS)
- Modify: `ps1-core/src/gpu/primitive.zig:77-85` (the fallback lookup)
- Test: `ps1-core/tests/pgxp_test.zig`

**Interfaces:**
- Consumes: `pgxp.Value`.
- Produces: `cache.VertexCache` with `init(std.mem.Allocator) !*VertexCache`, `deinit(*VertexCache, std.mem.Allocator) void`, `put(*VertexCache, u32, Value) void`, `get(*const VertexCache, u32) ?Value`. On `Bus`: `pgxp_vertex_cache: ?*VertexCache = null` and `setPgxpVertexCache(*Bus, std.mem.Allocator, bool) !void`.

A second lookup for a vertex whose memory word cannot be found — keyed on the integer position rather than on where the word lives. Off by default.

The table is 2048×2048 entries covering the ±1024 SXY range, which at 20 bytes is 83 MB. That is the reference's size and we keep it rather than inventing a different one, but it is **heap-allocated on enable and freed on disable**, never a field in `Bus`.

**A cache hit deliberately reports its depth as invalid** even when the stored entry has one. The position is enough to remove jitter; the depth found this way belongs to whichever vertex last occupied that integer position, which is not reliably this one.

- [ ] **Step 1: Write the failing tests**

```zig
test "the vertex cache answers a lookup the address path misses" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    try ctx.bus.setPgxpVertexCache(ctx.allocator, true);

    const word: u32 = (@as(u32, 50) << 16) | 100;
    ctx.bus.pgxp_vertex_cache.?.put(word, .{
        .x = 100.5, .y = 50.25, .z = 400.0, .word = word, .flags = Value.valid_xyz,
    });

    const hit = ctx.bus.pgxp_vertex_cache.?.get(word).?;
    try expectApproxEqAbs(@as(f32, 100.5), hit.x, 0.0);
    // A hit reports no depth: it belongs to whichever vertex last held this
    // integer position, which is not reliably this one.
    try expectEqual(@as(u32, 0), hit.flags & Value.valid_z);
}

test "the vertex cache refuses a position outside the SXY range" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    try ctx.bus.setPgxpVertexCache(ctx.allocator, true);

    // Low half 5000 is outside -1024..1023 and has no slot.
    const word: u32 = (@as(u32, 50) << 16) | 5000;
    ctx.bus.pgxp_vertex_cache.?.put(word, .{ .x = 1.0, .word = word, .flags = Value.valid_xy });
    try expectEqual(@as(?Value, null), ctx.bus.pgxp_vertex_cache.?.get(word));
}

test "the cache is not allocated while the setting is off" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    try expectEqual(@as(?*ps1_core.pgxp.cache.VertexCache, null), ctx.bus.pgxp_vertex_cache);
}

test "disabling the cache frees it" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    try ctx.bus.setPgxpVertexCache(ctx.allocator, true);
    try std.testing.expect(ctx.bus.pgxp_vertex_cache != null);
    try ctx.bus.setPgxpVertexCache(ctx.allocator, false);
    try expectEqual(@as(?*ps1_core.pgxp.cache.VertexCache, null), ctx.bus.pgxp_vertex_cache);
}
```

- [ ] **Step 2: Run and verify they fail**

```
zig build test -Doptimize=ReleaseFast
```

Expected: FAIL — `pgxp.cache` does not exist.

- [ ] **Step 3: Implement**

Create `ps1-core/src/pgxp/cache.zig` with a `[2048 * 2048]Value` behind a pointer, indexed `(sy + 1024) * 2048 + (sx + 1024)` after decoding the word's two signed halves and range-checking both. `get` strips `valid_z` from what it returns.

On `Bus`: the optional pointer, the flag implied by it being non-null, and `setPgxpVertexCache` allocating or freeing. `Bus.deinit` frees it if present — check `deinit`'s existing shape and add the free beside the other owned allocations.

In `opcodes.zig`'s RTPS, after `precise[14]` is written: `if (cop2.vertex_cache) |c| c.put(@bitCast(sxy2), cop2.precise[14]);`. `Cop2` needs a `vertex_cache: ?*VertexCache = null` field that `Bus.setPgxpVertexCache` keeps in step, since `Cop2` has no `*Bus`.

In `primitive.zig`, `getPointPrecise` gains a third parameter — the optional cache — consulted only when the address path did not resolve. `gp0.zig`'s `point()` passes `self.vertex_cache`, mirrored onto `Gp0Engine` the same way.

- [ ] **Step 4: Run everything and commit**

```
zig fmt ps1-core/src ps1-core/tests/pgxp_test.zig
zig build test -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify
```

```bash
git add ps1-core
git commit -m "feat(pgxp): the vertex cache

A second lookup keyed on the integer position, for a vertex whose memory word
cannot be found. Off by default and heap-allocated on enable: 2048x2048 entries
at 20 bytes is 83 MB, which is the reference's size and not one worth inventing
a different number for, but not one to carry unconditionally either.

A hit reports no depth even when the stored entry has one -- the depth belongs
to whichever vertex last held that integer position, which is not reliably this
one."
```

---

### Task 11: Tolerance

**Files:**
- Modify: `ps1-core/src/memory.zig:98`
- Modify: `ps1-core/src/gpu/primitive.zig:77-85`
- Test: `ps1-core/tests/pgxp_test.zig`

**Interfaces:**
- Consumes: `getPointPrecise` from Tasks 2 and 10.
- Produces: `Bus.pgxp_tolerance: f32 = -1.0`; `getPointPrecise` gains it as a parameter.

A resolved vertex whose precise position sits further than the tolerance from the integer one, in either axis, is rejected in favour of the integer. Negative means disabled, which is the default.

This is the mitigation for what the new staleness model gives up: an untracked write that leaves the word unchanged leaves a stale entry admissible, and the tolerance bounds how far wrong that entry can put a vertex.

- [ ] **Step 1: Write the failing tests**

```zig
test "tolerance rejects a vertex further than it from the integer position" {
    const word: u32 = (@as(u32, 50) << 16) | 100;
    const v: Value = .{ .x = 100.9, .y = 50.0, .word = word, .flags = Value.valid_xy };

    const tight = Primitive.getPointPrecise(word, v, null, 0.5);
    try expectEqual(false, tight.resolved);

    const loose = Primitive.getPointPrecise(word, v, null, 1.0);
    try expectEqual(true, loose.resolved);
}

test "a negative tolerance disables the check" {
    const word: u32 = (@as(u32, 50) << 16) | 100;
    const v: Value = .{ .x = 100.9, .y = 50.0, .word = word, .flags = Value.valid_xy };
    try expectEqual(true, Primitive.getPointPrecise(word, v, null, -1.0).resolved);
}

test "tolerance is disabled by default" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    try std.testing.expect(ctx.bus.pgxp_tolerance < 0);
}
```

- [ ] **Step 2: Run and verify they fail**

```
zig build test -Doptimize=ReleaseFast
```

Expected: FAIL — `getPointPrecise` takes three parameters.

- [ ] **Step 3: Implement**

Add the field, thread it from `Bus` through `Gpu` to `Gp0Engine` the way `pgxp_enabled` already is, and add the check to `getPointPrecise` after the word match and after `truncateVertexPosition`, comparing against the decoded integer coordinates.

- [ ] **Step 4: Run everything and commit**

```
zig fmt ps1-core/src ps1-core/tests/pgxp_test.zig
zig build test -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- pgxp
```

The sweep must be unchanged — the default is off.

```bash
git add ps1-core
git commit -m "feat(pgxp): the tolerance setting

Disabled by default, as in the reference. It is the mitigation for what
word-matched staleness gives up: an untracked write that happens to leave the
word unchanged leaves a stale entry admissible, and this bounds how far wrong
such an entry can put a vertex."
```

---

### Task 12: Culling correction

**Files:**
- Modify: `ps1-core/src/cop2/opcodes.zig:138-160`
- Modify: `ps1-core/src/memory.zig:98`
- Modify: `ps1-core/src/cop2/cop2.zig` (a `culling` flag beside `vertex_cache`)
- Test: `ps1-core/tests/pgxp_test.zig`

**Interfaces:**
- Consumes: `Cop2.precise[12..15]` from Tasks 3-4.
- Produces: `Bus.pgxp_culling: bool = true`, mirrored onto `Cop2.pgxp_culling`. No new public function — `opNclip` branches internally.

The one visible feature of this phase. NCLIP's sign decides backface culling, and on a triangle near-degenerate at integer precision that sign flips essentially at random, so facets on a curved surface blink in and out as the camera moves.

Two conditions gate the accurate path, and both matter. **All three precise SXY entries must validate against their registers and carry a depth** — a game-constructed screen position has no depth, and treating one as geometry is how the feature would break 2D. And **a result whose magnitude lands between 0.1 and 1.0 is pushed away from zero** before it is written back, so a thin triangle is not rounded into "degenerate" by the conversion back to an integer MAC0.

Default on, gated on the master flag: there is no state in which culling correction acts while geometry correction does not.

- [ ] **Step 1: Write the failing tests**

```zig
test "float NCLIP is used when all three vertices are precise" {
    var ctx = try GteContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);

    // A triangle that is degenerate at integer precision — all three vertices
    // on one row — but has real area once the sub-pixel positions are used.
    stagePreciseTriangle(&ctx.cpu.cop2, .{
        .{ .ix = 0, .iy = 0, .x = 0.0, .y = 0.0 },
        .{ .ix = 10, .iy = 0, .x = 10.0, .y = 0.0 },
        .{ .ix = 5, .iy = 0, .x = 5.0, .y = 0.6 },
    });
    ctx.cpu.cop2.executeCommand(0x4A000006);

    // The integer cross product is exactly zero; the float one is not.
    try std.testing.expect(@as(i32, @bitCast(ctx.cpu.cop2.readData(24))) != 0);
}

test "a float NCLIP result under 1.0 is pushed away from zero" {
    var ctx = try GteContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);

    // Cross product of about 0.3: without the nudge it truncates to 0 and the
    // triangle is culled as degenerate.
    stagePreciseTriangle(&ctx.cpu.cop2, .{
        .{ .ix = 0, .iy = 0, .x = 0.0, .y = 0.0 },
        .{ .ix = 10, .iy = 0, .x = 10.0, .y = 0.0 },
        .{ .ix = 5, .iy = 0, .x = 5.0, .y = 0.03 },
    });
    ctx.cpu.cop2.executeCommand(0x4A000006);

    const mac0 = @as(i32, @bitCast(ctx.cpu.cop2.readData(24)));
    try std.testing.expect(mac0 != 0);
}

test "NCLIP falls back to integers when a vertex has no depth" {
    var ctx = try GteContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);

    // Same geometry, but the third vertex was constructed by the game rather
    // than projected: no depth, so the accurate path must not run.
    stagePreciseTriangleNoDepth(&ctx.cpu.cop2, .{
        .{ .ix = 0, .iy = 0, .x = 0.0, .y = 0.0 },
        .{ .ix = 10, .iy = 0, .x = 10.0, .y = 0.0 },
        .{ .ix = 5, .iy = 0, .x = 5.0, .y = 0.6 },
    });
    ctx.cpu.cop2.executeCommand(0x4A000006);

    try expectEqual(@as(i32, 0), @as(i32, @bitCast(ctx.cpu.cop2.readData(24))));
}

test "culling correction does nothing while PGXP is off" {
    var ctx = try GteContext.init();
    defer ctx.deinit();
    // Master off: the sub-setting's value is unreachable.
    stagePreciseTriangle(&ctx.cpu.cop2, .{
        .{ .ix = 0, .iy = 0, .x = 0.0, .y = 0.0 },
        .{ .ix = 10, .iy = 0, .x = 10.0, .y = 0.0 },
        .{ .ix = 5, .iy = 0, .x = 5.0, .y = 0.6 },
    });
    ctx.cpu.cop2.executeCommand(0x4A000006);
    try expectEqual(@as(i32, 0), @as(i32, @bitCast(ctx.cpu.cop2.readData(24))));
}
```

`stagePreciseTriangle` writes the three integer SXY registers and their precise entries with a depth; `stagePreciseTriangleNoDepth` writes the same without one. Both are local helpers in the test file.

- [ ] **Step 2: Run and verify they fail**

```
zig build test -Doptimize=ReleaseFast
```

Expected: FAIL — `opNclip` always takes the integer path.

- [ ] **Step 3: Implement**

In `opcodes.zig`:

```zig
pub fn opNclip(cop2: *Cop2) void {
    if (cop2.pgxp_enabled and cop2.pgxp_culling and preciseNclip(cop2)) return;
    // ... the existing integer path, unchanged ...
}

/// NCLIP's sign decides backface culling, and on a triangle near-degenerate at
/// integer precision it flips essentially at random — which reads as facets on
/// a curved surface blinking in and out as the camera moves.
///
/// Requires a DEPTH on all three, not merely a position: a game-constructed
/// screen coordinate has none, and running the accurate path over 2D geometry
/// is how this feature would break a HUD.
fn preciseNclip(cop2: *Cop2) bool {
    var p: [3]Value = undefined;
    for (0..3) |i| {
        p[i] = cop2.precise[12 + i];
        p[i].validate(cop2.data_regs[12 + i]);
        cop2.precise[12 + i] = p[i];
        if (p[i].flags & Value.valid_xyz != Value.valid_xyz) return false;
    }

    var nclip = (p[0].x * p[1].y) + (p[1].x * p[2].y) + (p[2].x * p[0].y) -
        (p[0].x * p[2].y) - (p[1].x * p[0].y) - (p[2].x * p[1].y);

    // A real but sub-unit area must not truncate to "degenerate" on the way
    // back to an integer MAC0.
    const mag = @abs(nclip);
    if (mag > 0.1 and mag < 1.0) nclip += if (nclip < 0.0) -1.0 else 1.0;

    _ = math.setMac0(cop2, std.math.lossyCast(i64, nclip));
    return true;
}
```

Add `pgxp_culling: bool = true` to `Bus` and mirror it onto `Cop2` alongside `pgxp_enabled` in `Bus.setPgxp` — `Cop2` has no `*Bus`, exactly as `Gp0Engine` does not.

- [ ] **Step 4: Run everything and commit**

```
zig fmt ps1-core/src ps1-core/tests/pgxp_test.zig
zig build test -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- pgxp
```

`verify` must be OK: with PGXP off, `preciseNclip` cannot run.

```bash
git add ps1-core
git commit -m "feat(pgxp): culling correction

NCLIP in float from the three precise vertices. Its sign decides backface
culling, and on a triangle near-degenerate at integer precision that sign flips
essentially at random -- facets on a curved surface blinking in and out as the
camera moves.

A depth is required on all three, not merely a position: a game-constructed
screen coordinate has none, and running the accurate path over 2D geometry is
how this would break a HUD. A real but sub-unit area is pushed away from zero
so it does not truncate into 'degenerate' on the way back to an integer MAC0."
```

---

### Task 13: The settings surface

**Files:**
- Modify: `ps1-capi/src/root.zig:394-396`, `ps1-capi/include/ps1.h:276`
- Modify: `ps1-capi/src/capi_test.zig`
- Modify: `ps1-macos/Sources/PS1/PgxpSetting.swift`, `Ps1Core.swift`, `EmulatorViewModel.swift`
- Modify: `ps1-macos/Sources/PS1App/VideoCommands.swift`
- Test: `ps1-macos/Tests/PS1Tests/PgxpSettingTests.swift` (extend, or create if absent)

**Interfaces:**
- Consumes: the four core flags from Tasks 6, 10, 11 and 12.
- Produces: `void ps1_set_pgxp_cpu(Ps1*, int)`, `void ps1_set_pgxp_vertex_cache(Ps1*, int)`, `void ps1_set_pgxp_culling(Ps1*, int)`, `void ps1_set_pgxp_tolerance(Ps1*, float)`; Swift `PgxpSetting` growing `cpu`, `vertexCache`, `culling` and `tolerance`.

**The four are sub-settings, and the menu must say so.** Each is `&&`-gated on the master flag in the core, so a tick while geometry correction is off does nothing. Disable them in the menu rather than leaving a control that silently no-ops.

`culling` and the master toggle differ in default, and `PgxpSetting`'s current comment explains why it needs no `object(forKey:)` probe — `bool(forKey:)` returns false for a missing key and false is the intended default. **`culling` defaults true, so that reasoning does not transfer and it must probe with `object(forKey:)`**, exactly as `MultiDiscSetting` and `VolumeSetting` do. Same for `tolerance`, where -1 is the default and 0 is a legitimate value.

- [ ] **Step 1: Write the failing tests**

In `ps1-capi/src/capi_test.zig`:

```zig
test "the PGXP sub-settings cross the ABI with their defaults" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    // Defaults, pinned on the core side of the ABI.
    try std.testing.expect(!h.cpu.bus.pgxp_cpu);
    try std.testing.expect(h.cpu.bus.pgxp_culling);
    try std.testing.expect(h.cpu.bus.pgxp_vertex_cache == null);
    try std.testing.expect(h.cpu.bus.pgxp_tolerance < 0);

    capi.ps1_set_pgxp_cpu(h, 1);
    try std.testing.expect(h.cpu.bus.pgxp_cpu);
    capi.ps1_set_pgxp_culling(h, 0);
    try std.testing.expect(!h.cpu.bus.pgxp_culling);
    capi.ps1_set_pgxp_tolerance(h, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), h.cpu.bus.pgxp_tolerance, 0.0);
    capi.ps1_set_pgxp_vertex_cache(h, 1);
    try std.testing.expect(h.cpu.bus.pgxp_vertex_cache != null);
}
```

In `ps1-macos/Tests/PS1Tests/PgxpSettingTests.swift`:

```swift
@Test func cullingDefaultsOnWhenTheKeyIsAbsent() {
    let defaults = UserDefaults(suiteName: "pgxp-culling-absent")!
    defaults.removePersistentDomain(forName: "pgxp-culling-absent")
    let setting = PgxpSetting(defaults: defaults)
    // bool(forKey:) would report false here, which is why this one probes.
    #expect(setting.culling == true)
}

@Test func cullingSurvivesBeingTurnedOff() {
    let defaults = UserDefaults(suiteName: "pgxp-culling-off")!
    defaults.removePersistentDomain(forName: "pgxp-culling-off")
    var setting = PgxpSetting(defaults: defaults)
    setting.setCulling(false)
    #expect(PgxpSetting(defaults: defaults).culling == false)
}

@Test func toleranceDefaultsToDisabled() {
    let defaults = UserDefaults(suiteName: "pgxp-tolerance-absent")!
    defaults.removePersistentDomain(forName: "pgxp-tolerance-absent")
    #expect(PgxpSetting(defaults: defaults).tolerance < 0)
}
```

- [ ] **Step 2: Run and verify they fail**

```
zig build test -Doptimize=ReleaseFast
zig build capi-lib && zig build metallib && ps1-macos/test.sh
```

Expected: both FAIL — the setters and the properties do not exist. (`pkill -x Substation` first: a running app shares the test host's bundle id and makes the suite fail with `Failing tests:` and no `✘` lines.)

- [ ] **Step 3: Implement**

Four exports in `ps1-capi/src/root.zig` beside `ps1_set_pgxp`, four declarations in `ps1-capi/include/ps1.h` beside line 276 — the header is hand-written and is the reviewable contract, so it gets real comments, not just signatures. `ps1_set_pgxp_vertex_cache` needs the handle's allocator, which `Handle` already owns.

In Swift: `PgxpSetting` grows the three properties with their own defaults keys, probing with `object(forKey:)` for `culling` and `tolerance`; `Ps1Core` grows four `setX` methods; `EmulatorViewModel` grows four published properties that push through to the runner, and re-applies all four in the same place it re-applies `pgxpEnabled` when a runner is installed.

In `VideoCommands.swift`, after the existing toggle:

```swift
Toggle("PGXP Geometry Correction", isOn: $model.pgxpEnabled)

// Sub-settings of the master, not peers of it: each is &&-gated on
// pgxpEnabled in the core, so a tick while geometry correction is off does
// nothing at all. Disabled rather than silently ineffective.
Group {
    Toggle("PGXP Culling Correction", isOn: $model.pgxpCulling)
    Toggle("PGXP CPU Mode", isOn: $model.pgxpCpu)
    Toggle("PGXP Vertex Cache", isOn: $model.pgxpVertexCache)
    Picker("PGXP Tolerance", selection: $model.pgxpTolerance) {
        Text("Off").tag(Float(-1))
        Text("0.5 px").tag(Float(0.5))
        Text("1 px").tag(Float(1))
        Text("2 px").tag(Float(2))
    }
    .pickerStyle(.menu)
}
.disabled(!model.pgxpEnabled)
```

Note this contradicts the file's current header comment, which says both entries are always enabled. Update that comment — it will otherwise read as a rule these four are breaking.

- [ ] **Step 4: Run everything and commit**

```
zig fmt ps1-capi/src
zig build test -Doptimize=ReleaseFast
pkill -x Substation; zig build capi-lib && zig build metallib && ps1-macos/test.sh
```

```bash
git add ps1-capi ps1-macos
git commit -m "feat(pgxp): the four sub-settings across the ABI and the menu

Greyed while Geometry Correction is off rather than merely ineffective: each is
&&-gated on the master flag in the core, so a tick there does nothing, and a
control that silently no-ops is worse than one that says it cannot act.

culling and tolerance probe with object(forKey:) where the master toggle does
not need to. bool(forKey:) returns false for a missing key and false is the
master's intended default, which makes absence unambiguous there and ambiguous
for a setting defaulting on."
```

---

### Task 14: The sweep, the floors, and the docs

**Files:**
- Modify: `ps1-core/tests/goldens/pgxp/floors.txt`
- Modify: `CLAUDE.md`

**Interfaces:** none — this task produces measurements and prose.

- [ ] **Step 1: Take the full sweep, both ways**

```
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- pgxp
```

Then again with CPU mode forced on. There is no runtime flag for it in `ps1-golden`, so add `--pgxp-cpu` beside the existing `--pgxp-on` argument — a few lines in `ps1-golden/src/main.zig`, and worth having permanently, because the ratchet cannot cover CPU mode otherwise.

Record both columns per workload. **The number that decides the phase is Croc, Metal Gear Solid and Resident Evil against 25,854.**

- [ ] **Step 2: Re-pin the floors**

Rewrite `floors.txt` from the measured sweep, rounded down to the whole percent, and rewrite its header comment. The current header carries three notes that this phase settles or invalidates — the three lines that were above what HEAD measured, the "next thing to chase" paragraph about Croc, and the description of the identity check. Replace them; do not leave a stale explanation attached to a new number.

- [ ] **Step 3: Decide CPU mode's default**

If CPU mode is what moves the three games, off means shipping a fix nobody turns on, and the reference's reasoning — that it is a per-game workaround — does not transfer to us. Change the default and say why in the commit. If it is not what moves them, leave it off and record what did.

- [ ] **Step 4: Update CLAUDE.md**

The PGXP section describes the old representation, `resolves` as the safety net, and a six-idiom propagation set. Rewrite it around: the per-halfword value, word-matched staleness and what it gives up, the float projection, the full hook set, the four new settings and their gating, and culling correction. Keep `unify`, `thinIntegerTriangle` and `weldPoint` exactly as they are — they are unchanged and their rationale is still correct.

- [ ] **Step 5: Commit**

```bash
git add ps1-core/tests/goldens/pgxp/floors.txt CLAUDE.md ps1-golden
git commit -m "chore(pgxp): re-pin the floors and document Phase 2

<the sweep, per workload, before and after, both CPU-mode columns>

<what moved the three games that resolved only the licence logo>"
```

---

## Self-Review

Run before handing this plan to an executor.

**Spec coverage.** Every section of the Phase 2 spec maps to a task: the value → 1; staleness → 2; production → 3; storage and the shadow set → 4; memory mode → 5; CPU mode → 6, 7, 8, 9; vertex cache → 10; tolerance → 11; culling correction → 12; consumption → 2 and 11; file layout → 1, 6, 8, 9, 10; settings surface → 13; testing and the floors → every task plus 14. `unify`/`thinIntegerTriangle`/`weldPoint` are untouched by design and Task 14 says so in the docs.

**Deliberate omissions.** The spec's `disable_2d`, `transparent_depth`, texture correction, colour correction, the depth buffer and preserve-projection-precision are Phase 3 and 4, and are listed out of scope in the spec's own Scope section.

**Type consistency.** `pgxp.Value` throughout; `Value.none`; flags `valid_x`/`valid_y`/`valid_z`/`valid_xy`/`valid_xyz`/`low_z`/`high_z`/`tainted_z`; `validate`/`validX`/`validY`; free functions `signFold`/`unsign`/`overflow`/`truncateVertexPosition`. `source`/`store` are defined in Task 6 and exported for Tasks 8 and 9. `copyZIfMissing`/`selectZ` are defined in Task 7 and reused in Task 9. `getPointPrecise` gains parameters in Tasks 10 and 11 and every later reference uses the four-parameter form. `Cop2.precise` (Task 4) replaces `precise_sxy` and Tasks 10 and 12 use the new name.

**Known open question, deliberately not resolved here.** Task 3 may move the games currently at 99%. The plan does not pre-commit to a response because the right one depends on the direction and size of the move; the retreat path is named in the task, and Task 14 is where the floors are settled either way.
