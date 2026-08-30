# PGXP geometry correction — vertex precision — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop PS1 polygons wobbling, by keeping the 16 fractional bits the GTE
computes for every projected vertex and getting them to both rasterizers.

**Architecture:** The GTE already computes each screen coordinate as a 16.16
value in MAC0 and immediately shifts it away. A shadow value table over the
GPRs, RAM and scratchpad follows that value through `mfc2` → `sw` → DMA to the
GP0 FIFO, where an identity check (`precise.x >> 16 == vertex.x`) either
accepts it or falls back to the integer vertex. Both rasterizers then reduce it
to 1/16-pixel units taken relative to the primitive's bounding-box origin,
which keeps every edge function inside `i32`/`int` at every internal scale.

**Tech Stack:** Zig 0.16.0 (`ps1-core`, `ps1-capi`, `ps1-golden`), Metal Shading
Language, Swift 6 / SwiftUI (`ps1-macos`), xcodebuild.

**Spec:** `docs/superpowers/specs/2026-08-30-pgxp-geometry-correction-design.md`

## Global Constraints

- **Zig version is exactly 0.16.0.** `std.Io.Dir.cwd()`, `std.process.Init`,
  `std.ArrayList(...).empty`, `addRunArtifact`.
- **Run `zig fmt` on every `.zig` file you touch, before committing.**
- **No file in `ps1-core/src` over ~600 lines.** Check with `wc -l` before
  committing; split by function if you cross it.
- **Casts: Tier A over Tier B.** Let Zig infer the cast target from the result
  location (`const s: i32 = @bitCast(a);`). Do not add helpers to `bits.zig`
  unless an idiom is 3+ operations AND appears at 4+ sites — count with
  `grep -c` first.
- **Constants:** `constants.zig` holds only cross-module hardware facts.
  Everything else is a module-private `const` block at the top of its own file.
- **Commit after every task**, one commit per task, directly on `master`.
  End every commit message with:
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`
- **Do not `git push`.**
- **PGXP is OFF by default** in the core, in the C ABI and in the app.
- **The PGXP-off output must not change.** Tasks 1-3 cannot change it at all
  (they add state nobody reads). From task 4 on, every commit must leave
  `zig build test`, `zig build test-roms-pl`, `zig build test-roms-ja` and
  `zig build trace-golden -- verify` byte-for-byte unchanged. **No golden is
  recaptured by this plan.** If one moves, stop and report — do not recapture.
- **Run the slow suites with `-Doptimize=ReleaseFast`.** The ROM suites are
  ~25× faster and produce identical results; `trace-golden` is unusable
  otherwise.
- **Sub-pixel precision is 1/16 px, box-relative.** Not 16.16 in the edge
  functions — that overflows Metal's `int`. See spec § 5.
- **The identity predicate is the fallback, not an assertion.** A vertex that
  fails it silently uses the integer coordinate. Never `unreachable`, never
  panic, never log per-vertex.

---

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `ps1-core/src/pgxp.zig` | `Precise` — the one shared type, its constructor and the identity predicate. Nothing else; every consumer imports it. |
| `ps1-macos/Sources/PS1/PgxpSetting.swift` | The persisted on/off setting, shaped after `InternalResolution`. |
| `ps1-macos/Tests/PgxpSettingTests.swift` | Round trip, absent key. |

**Modified:**

| File | Change |
|---|---|
| `ps1-core/src/root.zig` | Re-export `pgxp`. |
| `ps1-core/src/cop2/cop2.zig` | `precise_sxy: [3]Precise`; the `sxyp` mirror on read; invalidation on `writeData` to 12..15. |
| `ps1-core/src/cop2/opcodes.zig` | Keep MAC0 before `>> 16`; shift `precise_sxy` with the SXY FIFO. |
| `ps1-core/src/cpu/cpu.zig` | `gpr_shadow`, `load_shadow`, `delay_shadow`; clear in `writeReg`; shift in `step`. |
| `ps1-core/src/cpu/exec.zig` | `mfc2`/`mtc2` hooks; `opLoad`/`opStore` word hooks; the `move` idiom. |
| `ps1-core/src/memory.zig` | `pgxp_enabled`, `ram_shadow`, `scratch_shadow`, `pgxp_pending`; shadow read/write/invalidate helpers; hand `pgxp_pending` to `writeGp0`. |
| `ps1-core/src/dma.zig` | Set `pgxp_pending` from the source address at both GPU-bound sites. |
| `ps1-core/src/gpu/gpu.zig` | `fifo_pgxp: [16]Precise`; `writeGp0` takes provenance; `processFifoWord` forwards it. |
| `ps1-core/src/gpu/gp0.zig` | `cmd_buffer_pgxp`; resolve vertices; the four counters. |
| `ps1-core/src/gpu/primitive.zig` | `Point` gains `px`/`py`; `getPointPrecise`. |
| `ps1-core/src/gpu/sink.zig` | Triangle methods take `Primitive.Point`. |
| `ps1-core/src/gpu/command.zig` | `Vertex.px`/`.py`; size pins 20/96; forward to `Renderer`. |
| `ps1-core/src/gpu/renderer.zig` | `rasterizeTriangle` in box-relative 1/16 px. |
| `ps1-capi/src/root.zig`, `ps1-capi/include/ps1.h` | `ps1_set_pgxp`. |
| `ps1-macos/Shaders/PrimInstance.h` | `sx0..sy2`. |
| `ps1-macos/Shaders/Rasterizer.metal` | `ps1_triangle_coverage` reduces to native 1/16 px. |
| `ps1-macos/Sources/PS1/PrimBuilder.swift` | Fill `sx0..sy2`. |
| `ps1-macos/Sources/PS1/EmulatorViewModel.swift`, `Sources/PS1App/VideoCommands.swift` | `pgxpEnabled` + the menu item. |
| `ps1-golden/src/main.zig` | `--pgxp` mode, the report, the floors. |
| `ps1-core/tests/goldens/pgxp/floors.txt` | Committed per-game hit-rate floors. |
| `CLAUDE.md` | A PGXP section. |

**Test files touched:** `ps1-core/tests/gte_test.zig`, `cpu_test.zig`,
`gpu_test.zig`, `ps1-capi/src/capi_test.zig`,
`ps1-macos/Tests/MetalRasterizerTests.swift`.

---

### Task 1: `Precise` and the GTE's precise SXY FIFO

**Files:**
- Create: `ps1-core/src/pgxp.zig`
- Modify: `ps1-core/src/root.zig`
- Modify: `ps1-core/src/cop2/cop2.zig`
- Modify: `ps1-core/src/cop2/opcodes.zig:57-81`
- Test: `ps1-core/tests/gte_test.zig`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `pgxp.Precise` — `extern struct { x: i32, y: i32, valid: u32, _pad: u32 }`,
    16 bytes.
  - `pgxp.Precise.none: Precise`
  - `pgxp.Precise.make(x: i64, y: i64) Precise`
  - `pgxp.Precise.resolves(self: Precise, ix: i16, iy: i16) bool`
  - `Cop2.precise_sxy: [3]Precise`
  - `Cop2.readPreciseData(index: anytype) Precise`

- [ ] **Step 1: Write the failing test**

Append to `ps1-core/tests/gte_test.zig`. The existing `TestContext` gives you a
`Cpu` with COP2 enabled; drive the GTE by writing registers and calling
`executeCommand` directly, as the file already does elsewhere.

```zig
test "PGXP: RTPS keeps the sub-pixel screen position MAC0 carries" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const cop2 = &ctx.cpu.cop2;

    // Identity rotation at 4096 = 1.0 in 4.12, no translation.
    cop2.writeCtrl(0, 0x0000_1000); // RT11=4096, RT12=0
    cop2.writeCtrl(1, 0x0000_0000);
    cop2.writeCtrl(2, 0x1000_0000); // RT22=4096 in the high half
    cop2.writeCtrl(3, 0x0000_0000);
    cop2.writeCtrl(4, 0x0000_1000); // RT33=4096
    cop2.writeCtrl(5, 0);
    cop2.writeCtrl(6, 0);
    cop2.writeCtrl(7, 0);
    cop2.writeCtrl(24, 0); // OFX
    cop2.writeCtrl(25, 0); // OFY
    cop2.writeCtrl(26, 300); // H
    cop2.writeCtrl(27, 0); // DQA
    cop2.writeCtrl(28, 0); // DQB

    // A vertex whose projection does NOT land on a whole pixel: H/SZ3 * IR1
    // with H=300, VZ=7 gives a non-terminating ratio.
    cop2.writeData(0, 0x0000_0005); // VXY0: VX0 = 5, VY0 = 0
    cop2.writeData(1, 7); // VZ0 = 7

    cop2.executeCommand(0x4A18_0001); // RTPS, sf=1, lm=0

    const p = cop2.readPreciseData(14); // sxy2
    const sx2: i16 = @bitCast(@as(u16, @truncate(cop2.readData(14))));
    const sy2: i16 = @bitCast(@as(u16, @truncate(cop2.readData(14) >> 16)));

    try std.testing.expect(p.valid != 0);
    // The whole-pixel part must reproduce the register exactly...
    try std.testing.expect(p.resolves(sx2, sy2));
    // ...and there must be a fraction, or the test is not exercising anything.
    try std.testing.expect((p.x & 0xFFFF) != 0);
}

test "PGXP: sxyp mirrors sxy2, and mtc2 to the FIFO invalidates" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const cop2 = &ctx.cpu.cop2;

    cop2.precise_sxy[2] = ps1_core.pgxp.Precise.make(0x0010_8000, 0x0020_4000);
    try std.testing.expect(cop2.readPreciseData(15).valid != 0);
    try expectEqual(@as(i32, 0x0010_8000), cop2.readPreciseData(15).x);

    // A game writing its own screen coordinate has no sub-pixel to recover.
    cop2.writeData(14, 0x0002_0003);
    try expectEqual(@as(u32, 0), cop2.readPreciseData(14).valid);
}

test "PGXP: a write to sxyp shifts the precise FIFO with the register FIFO" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const cop2 = &ctx.cpu.cop2;
    const Precise = ps1_core.pgxp.Precise;

    cop2.precise_sxy[1] = Precise.make(0x0011_0000, 0x0022_0000);
    cop2.precise_sxy[2] = Precise.make(0x0033_0000, 0x0044_0000);

    cop2.writeData(15, 0x0005_0006); // sxyp: shifts, then writes sxy2

    try expectEqual(@as(i32, 0x0033_0000), cop2.readPreciseData(13).x); // sxy1
    try expectEqual(@as(u32, 0), cop2.readPreciseData(14).valid); // sxy2 replaced
}
```

Add `const ps1_core = @import("ps1_core");` if the file does not already have
it — it does, at line 4.

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | head -40`
Expected: FAIL — `root source file struct 'root' has no member named 'pgxp'`,
or `no member named 'precise_sxy'`.

- [ ] **Step 3: Create `ps1-core/src/pgxp.zig`**

```zig
//! PGXP's one shared type: a screen position kept at the precision the GTE
//! actually computed it with.
//!
//! Every consumer — `cop2/`, `cpu/`, `memory.zig`, `dma.zig`, `gpu/` — imports
//! this and nothing else of PGXP's, so the representation is decided in one
//! place.

/// A projected screen position in 16.16.
///
/// The value is the raw MAC0 the projection produced, BEFORE the `>> 16` that
/// `cop2/opcodes.zig` applies to derive SX2/SY2. Keeping it unshifted is what
/// makes `resolves` exact: the shift there is literally the same operation,
/// so it reproduces the integer coordinate bit for bit, including for the
/// negative values off-screen geometry produces constantly.
///
/// `extern struct` because it travels in `Bus`'s shadow tables and in the GP0
/// FIFO alongside data the C ABI already sees; 16 bytes rather than a packed
/// 12 plus a side validity bitmap, which would save 4 MB and cost a second
/// dependent load on the hottest lookup in the feature.
pub const Precise = extern struct {
    x: i32 = 0,
    y: i32 = 0,
    valid: u32 = 0,
    _pad: u32 = 0,

    pub const none: Precise = .{};

    /// Takes the wide accumulator values. MAC0 is a 32-bit register but
    /// `setMac0` returns the unnarrowed sum, and a projection that overflows
    /// it has already saturated its SXY beyond anything `resolves` would
    /// accept — so an out-of-range value is recorded as invalid rather than
    /// truncated into a plausible-looking one.
    pub fn make(x: i64, y: i64) Precise {
        const lo = -(1 << 31);
        const hi = (1 << 31) - 1;
        if (x < lo or x > hi or y < lo or y > hi) return none;
        return .{ .x = @intCast(x), .y = @intCast(y), .valid = 1 };
    }

    /// The identity predicate, and the reason invalidation only has to be good
    /// enough for coverage rather than for correctness: a shadow entry that
    /// outlived the value it described either fails this and is discarded, or
    /// passes it and therefore agrees with the integer vertex to within a
    /// pixel.
    pub fn resolves(self: Precise, ix: i16, iy: i16) bool {
        return self.valid != 0 and
            (self.x >> 16) == @as(i32, ix) and
            (self.y >> 16) == @as(i32, iy);
    }
};
```

- [ ] **Step 4: Re-export it**

In `ps1-core/src/root.zig`, after the `constants` line:

```zig
pub const pgxp = @import("pgxp.zig");
```

- [ ] **Step 5: Add the FIFO to `Cop2`**

In `ps1-core/src/cop2/cop2.zig`, add the import at the top beside `opcodes`:

```zig
const Precise = @import("../pgxp.zig").Precise;
```

Add the field next to `data_regs` (find it with
`grep -n "data_regs: \[" ps1-core/src/cop2/cop2.zig`):

```zig
    /// The sub-pixel half of sxy0/sxy1/sxy2, shifted in lockstep with
    /// `data_regs[12..14]`. Written by the projection in `opcodes.zig`;
    /// invalidated by any write software makes to those registers itself.
    precise_sxy: [3]Precise = .{ .{}, .{}, .{} },
```

Add the reader beside `readData`:

```zig
    /// `readData`'s counterpart. Index 15 mirrors sxy2, exactly as the
    /// register does.
    pub fn readPreciseData(self: *const Self, index: anytype) Precise {
        const i = getDataIdx(index);
        return switch (i) {
            12, 13, 14 => self.precise_sxy[i - 12],
            15 => self.precise_sxy[2],
            else => Precise.none,
        };
    }
```

In `writeData`, extend the existing `15 =>` arm and add a `12, 13, 14` arm.
The current arm is:

```zig
            15 => { // sxyp: write to sxy2 and shift fifo
                self.data_regs[12] = self.data_regs[13]; // sxy0 = sxy1
                self.data_regs[13] = self.data_regs[14]; // sxy1 = sxy2
                self.data_regs[14] = value; // sxy2 = new value
            },
```

Replace it with:

```zig
            15 => { // sxyp: write to sxy2 and shift fifo
                self.data_regs[12] = self.data_regs[13]; // sxy0 = sxy1
                self.data_regs[13] = self.data_regs[14]; // sxy1 = sxy2
                self.data_regs[14] = value; // sxy2 = new value
                self.precise_sxy[0] = self.precise_sxy[1];
                self.precise_sxy[1] = self.precise_sxy[2];
                self.precise_sxy[2] = Precise.none;
            },
            // Software supplying its own screen coordinate has no sub-pixel to
            // recover, and a leftover one from an earlier projection would be
            // attached to an unrelated position.
            12, 13, 14 => {
                self.data_regs[i] = value;
                self.precise_sxy[i - 12] = Precise.none;
            },
```

- [ ] **Step 6: Keep MAC0 in the projection**

In `ps1-core/src/cop2/opcodes.zig`, add the import at the top:

```zig
const Precise = @import("../pgxp.zig").Precise;
```

Replace lines 65-81 (from `const x = math.setMac0` through the `data_regs[14]`
assignment) with:

```zig
    // MAC0 is the projected coordinate in 16.16 — the `>> 16` below is the
    // whole of the precision loss PGXP exists to undo, so the unshifted value
    // is kept before it happens.
    const x_16_16 = math.setMac0(cop2, h_s3z * ir1 + ofx);
    const y_16_16 = math.setMac0(cop2, h_s3z * ir2 + ofy);
    const x = x_16_16 >> 16;
    const y = y_16_16 >> 16;

    // SXY FIFO Shift
    cop2.data_regs[12] = cop2.data_regs[13]; // sxy0 = sxy1
    cop2.data_regs[13] = cop2.data_regs[14]; // sxy1 = sxy2
    cop2.precise_sxy[0] = cop2.precise_sxy[1];
    cop2.precise_sxy[1] = cop2.precise_sxy[2];

    // Saturate X and Y to -1024..1023
    const sxy2 = Cop2.Point2D{
        .x = math.saturateSxy(cop2, x, 14), // flag bit 14 for X
        .y = math.saturateSxy(cop2, y, 13), // flag bit 13 for Y
    };
    // A saturated vertex keeps its true MAC0, so the identity check rejects it
    // and the integer coordinate wins — which is the behaviour hardware has
    // and games rely on for near-plane geometry.
    cop2.precise_sxy[2] = Precise.make(x_16_16, y_16_16);
```

Keep the line that follows (`cop2.data_regs[14] = @as(u32, @bitCast(sxy2));`)
exactly as it is.

- [ ] **Step 7: Run the tests**

Run: `zig fmt ps1-core/src/pgxp.zig ps1-core/src/root.zig ps1-core/src/cop2/cop2.zig ps1-core/src/cop2/opcodes.zig && zig build test 2>&1 | tail -20`
Expected: PASS, all 15 binaries.

- [ ] **Step 8: Prove the GTE is otherwise untouched**

Run: `zig build test-roms-ja -Doptimize=ReleaseFast -Drom-filter="gte" 2>&1 | tail -20`
Expected: `gte/test-all` still passes all 1150 cases. This is the ratchet for
anything in `cop2/`; a regression here means step 6 disturbed the integer path.

- [ ] **Step 9: Commit**

```bash
zig fmt ps1-core/src ps1-core/tests
git add ps1-core/src/pgxp.zig ps1-core/src/root.zig ps1-core/src/cop2 ps1-core/tests/gte_test.zig
git commit -m "$(cat <<'EOF'
feat(pgxp): keep the GTE's sub-pixel screen position

`doPerspectiveTransform` computes each projected coordinate as a 16.16 value
in MAC0 and immediately shifts it away. Keep it: a three-entry precise FIFO
shifted in lockstep with sxy0/1/2, mirrored on sxyp, and invalidated by any
write software makes to those registers itself.

`Precise.resolves` is the identity predicate the rest of the feature rests on.
Its `>> 16` is literally the shift above, which is why it reproduces the
integer coordinate exactly rather than approximately — including for the
negative coordinates off-screen geometry produces constantly, where a float
round would disagree by one on every non-zero fraction.

Nothing reads the FIFO yet. gte/test-all still passes 1150/1150.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: The shadow tables and the propagation set

**Files:**
- Modify: `ps1-core/src/memory.zig` (the `Bus` struct, near `ram`/`scratchpad` at lines 90-94)
- Modify: `ps1-core/src/cpu/cpu.zig` (the struct, `step`, `writeReg`)
- Modify: `ps1-core/src/cpu/exec.zig` (`opLoad`, `opStore`, the COP move arms, `rOp` dispatch)
- Test: `ps1-core/tests/cpu_test.zig`

**Interfaces:**
- Consumes: `pgxp.Precise` and `Cop2.readPreciseData` from Task 1.
- Produces:
  - `Bus.pgxp_enabled: bool` (default `false`)
  - `Bus.shadowLoad(paddr: u32) Precise`
  - `Bus.shadowStore(paddr: u32, p: Precise) void`
  - `Bus.shadowInvalidate(paddr: u32) void`
  - `Cpu.gpr_shadow: [32]Precise`
  - `Cpu.load_shadow: Precise`, `Cpu.delay_shadow: Precise`

- [ ] **Step 1: Write the failing test**

Append to `ps1-core/tests/cpu_test.zig`. These drive real instruction words
through `cpu.step()`, which is what the file's `executeTestCase` already does —
but these need several steps in sequence, so they build the `Cpu` directly.

```zig
const Precise = ps1_core.pgxp.Precise;

/// mfc2 $t0, sxy2 / or $t1, $t0, $zero / sw $t1, 0($t2) / lw $t3, 0($t2)
///
/// This is the dataflow every PS1 game uses, because it is what libgpu
/// prescribes: project, move the packed SXY out of the GTE, park it in an
/// ordering-table node, read it back. Each hop is a separate hook, and a
/// missing one shows up here as a lost sub-pixel rather than as a wrong
/// picture in one game.
test "PGXP: the sub-pixel survives mfc2 -> move -> sw -> lw" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);
    bus.pgxp_enabled = true;

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;
    cpu.cop0.writeReg(Cop0Reg.sr, 1 << 30); // COP2 usable

    const p = Precise.make(0x0005_8000, 0x0007_4000); // (5.5, 7.25)
    cpu.cop2.precise_sxy[2] = p;
    cpu.cop2.writeDataRaw(14, 0x0007_0005); // sxy2 = (5, 7), no invalidation

    cpu.writeReg(10, 0x0000_1000); // $t2 = 0x1000, a RAM address

    // mfc2 $8, $14  -> COP2 rs=0 (MFC), rt=8, rd=14
    bus.write32(0x00, 0x4808_7000);
    // or $9, $8, $0
    bus.write32(0x04, 0x0100_4825);
    // sw $9, 0($10)
    bus.write32(0x08, 0xAD49_0000);
    // nop (let the load-delay of nothing settle)
    bus.write32(0x0C, 0x0000_0000);
    // lw $11, 0($10)
    bus.write32(0x10, 0x8D4B_0000);
    // nop  -- the load lands here
    bus.write32(0x14, 0x0000_0000);

    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    for (0..6) |_| cpu.step();

    try expectEqual(@as(u32, 0x0007_0005), cpu.readReg(11));
    const got = cpu.gpr_shadow[11];
    try expectEqual(@as(u32, 1), got.valid);
    try expectEqual(@as(i32, 0x0005_8000), got.x);
    try expectEqual(@as(i32, 0x0007_4000), got.y);
}

/// The load-delay slot is the trap: a load lands one instruction late, and an
/// explicit write to the same register during that instruction cancels it
/// (`cpu.zig:255`). A shadow that ignores either rule attaches the sub-pixel
/// to whatever the PREVIOUS load targeted.
test "PGXP: a cancelled load cancels its shadow too" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);
    bus.pgxp_enabled = true;

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;

    bus.write32(0x1000, 0x0007_0005);
    bus.shadowStore(0x1000, Precise.make(0x0005_8000, 0x0007_4000));
    cpu.writeReg(10, 0x0000_1000); // $t2

    // lw $9, 0($10)   -- loads into $9, landing one instruction late
    bus.write32(0x00, 0x8D49_0000);
    // ori $9, $0, 42  -- writes $9 in the delay slot, cancelling the load
    bus.write32(0x04, 0x3409_002A);
    bus.write32(0x08, 0x0000_0000); // nop

    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    for (0..3) |_| cpu.step();

    try expectEqual(@as(u32, 42), cpu.readReg(9));
    try expectEqual(@as(u32, 0), cpu.gpr_shadow[9].valid);
}

/// Any other write to a register must clear its shadow, or an unrelated value
/// inherits a screen position. This is the rule that makes the propagation set
/// small: everything not explicitly propagated falls through `writeReg`.
test "PGXP: an ordinary register write clears the shadow" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);
    bus.pgxp_enabled = true;

    cpu.gpr_shadow[9] = Precise.make(0x0005_8000, 0x0007_4000);
    cpu.writeReg(9, 0x1234_5678);
    try expectEqual(@as(u32, 0), cpu.gpr_shadow[9].valid);
}

/// A sub-word store lands inside a tracked word and destroys it.
test "PGXP: sb into a tracked word invalidates it" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    bus.pgxp_enabled = true;

    bus.shadowStore(0x1002, Precise.make(0x0005_8000, 0x0007_4000));
    try expectEqual(@as(u32, 1), bus.shadowLoad(0x1000).valid);
    bus.shadowInvalidate(0x1003);
    try expectEqual(@as(u32, 0), bus.shadowLoad(0x1000).valid);
}

/// Everything above must cost nothing when the feature is off.
test "PGXP: nothing is tracked while disabled" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);
    // bus.pgxp_enabled stays false

    cpu.cop2.precise_sxy[2] = Precise.make(0x0005_8000, 0x0007_4000);
    cpu.cop2.writeDataRaw(14, 0x0007_0005);
    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;
    cpu.cop0.writeReg(Cop0Reg.sr, 1 << 30);
    bus.write32(0x00, 0x4808_7000); // mfc2 $8, r14
    bus.write32(0x04, 0x0000_0000);
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    cpu.step();

    try expectEqual(@as(u32, 0x0007_0005), cpu.readReg(8));
    try expectEqual(@as(u32, 0), cpu.gpr_shadow[8].valid);
}
```

Add `const ps1_core = @import("ps1_core");` — the file has it at line 4 — and
`const Precise = ps1_core.pgxp.Precise;` once, near the other aliases.

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | head -30`
Expected: FAIL — `no member named 'pgxp_enabled' in struct 'memory.Bus'`.

- [ ] **Step 3: Add a test-only raw SXY write to `Cop2`**

The tests need to set sxy2 *without* the invalidation Task 1 added. Add beside
`writeData` in `ps1-core/src/cop2/cop2.zig`:

```zig
    /// `writeData` for sxy0/1/2 that does NOT invalidate the precise entry.
    /// Exists for tests that need to stage a register and its sub-pixel half
    /// independently; nothing in the emulator calls it.
    pub fn writeDataRaw(self: *Self, index: anytype, value: u32) void {
        self.data_regs[getDataIdx(index)] = value;
    }
```

- [ ] **Step 4: Add the shadow tables to `Bus`**

In `ps1-core/src/memory.zig`, add the import near the top:

```zig
const Precise = @import("pgxp.zig").Precise;
```

Add the fields immediately after `scratchpad: [1 * KB]u8,` (line 94):

```zig
    /// PGXP. Off by default: off is the configuration the byte-exact oracle
    /// covers, so the shipped default must not opt out of it.
    pgxp_enabled: bool = false,
    /// One entry per RAM word and per scratchpad word. ~8.4 MB, which sits
    /// beside the recorder's 6.8 MB and MDEC's 768 KB on the already
    /// heap-allocated Bus. `@memset(0)` leaves every entry invalid, which is
    /// the correct initial state — unlike several devices, this needs no
    /// `.init()`.
    ram_shadow: [(2 * MB) / 4]Precise,
    scratch_shadow: [(1 * KB) / 4]Precise,
    /// Provenance for the GP0 word currently being written. Set by the
    /// producer immediately before the store and consumed by the `gpu_data`
    /// arm of `write`, because `write` is generic over T and has too many
    /// callers to thread a parameter through. It does NOT need to survive the
    /// call — the FIFO is what holds provenance over time (see Task 3).
    pgxp_pending: Precise = Precise.none,
```

Add the three helpers as methods on `Bus`, next to `read32`/`write32`:

```zig
    /// RAM and scratchpad are the only tracked regions: everything else is
    /// either a device register or ROM, and neither carries a vertex.
    fn shadowSlot(self: *Self, paddr: u32) ?*Precise {
        return switch (paddr) {
            Addr.ram_base...Addr.ram_mirror_last => &self.ram_shadow[(paddr & Addr.ram_size_mask) >> 2],
            Addr.scratchpad_base...Addr.scratchpad_last => &self.scratch_shadow[(paddr & Addr.scratchpad_mask) >> 2],
            else => null,
        };
    }

    pub fn shadowLoad(self: *Self, virtual_address: u32) Precise {
        if (!self.pgxp_enabled) return Precise.none;
        const slot = self.shadowSlot(virtual_address & Addr.phys_mask) orelse return Precise.none;
        return slot.*;
    }

    pub fn shadowStore(self: *Self, virtual_address: u32, p: Precise) void {
        if (!self.pgxp_enabled) return;
        const slot = self.shadowSlot(virtual_address & Addr.phys_mask) orelse return;
        slot.* = p;
    }

    /// A write through any path that is not a tracked `sw` destroys whatever
    /// the word held. Missing one of those paths is survivable — the identity
    /// check in `gpu/gp0.zig` rejects a stale entry — so only the cheap,
    /// high-yield cases are hooked.
    pub fn shadowInvalidate(self: *Self, virtual_address: u32) void {
        if (!self.pgxp_enabled) return;
        const slot = self.shadowSlot(virtual_address & Addr.phys_mask) orelse return;
        slot.* = Precise.none;
    }
```

`Bus.init` already `@memset(0)`s the whole struct and then re-runs each
device's `.init()`; the shadow tables want zero, so add nothing there.

- [ ] **Step 5: Add the register shadows to `Cpu`**

In `ps1-core/src/cpu/cpu.zig`, add the import:

```zig
const Precise = @import("../pgxp.zig").Precise;
```

Add the fields after the `load_delay` struct:

```zig
    /// PGXP: the sub-pixel half of each GPR, and of the two load-delay slots.
    /// These shift on exactly the lines the register numbers do in `step()`,
    /// because a shadow that ignores the load-delay pipeline attaches a
    /// vertex to whatever the PREVIOUS load targeted.
    gpr_shadow: [32]Precise = [_]Precise{.{}} ** 32,
    load_shadow: Precise = .{},
    delay_shadow: Precise = .{},
```

In `step()`, alongside the existing load-delay shift (lines 164-167):

```zig
            self.load_delay.delay_r = self.load_delay.load_r;
            self.load_delay.delay_v = self.load_delay.load_v;
            self.delay_shadow = self.load_shadow;

            self.load_delay.load_r = 0;
            self.load_delay.load_v = 0;
            self.load_shadow = Precise.none;
```

and at the retire (line 176):

```zig
            if (self.load_delay.delay_r != 0) {
                self.regs[self.load_delay.delay_r] = self.load_delay.delay_v;
                self.gpr_shadow[self.load_delay.delay_r] = self.delay_shadow;
            }
```

In `writeReg`:

```zig
    pub fn writeReg(self: *Self, index: anytype, value: u32) void {
        const i = self.getIdx(index);
        if (i != 0) {
            self.regs[i] = value;
            // Any write that is not an explicit PGXP propagation destroys the
            // register's screen position. This is the rule that keeps the
            // propagation set small — everything not hooked falls through here.
            self.gpr_shadow[i] = Precise.none;
            // An explicit write supersedes a load-delay result landing this same
            // cycle: cancel the pending load to this register (see step()).
            if (i == self.load_delay.delay_r) self.load_delay.delay_r = 0;
        }
    }

    /// `writeReg` plus a screen position. Separate rather than an optional
    /// parameter so the hot path keeps its signature and every propagation
    /// site is greppable.
    pub fn writeRegPrecise(self: *Self, index: anytype, value: u32, p: Precise) void {
        self.writeReg(index, value);
        const i = self.getIdx(index);
        if (i != 0) self.gpr_shadow[i] = p;
    }
```

- [ ] **Step 6: Hook the propagation set in `exec.zig`**

Add the import:

```zig
const Precise = @import("../pgxp.zig").Precise;
```

**`mfc2`** — in the `0x00 => { // MFCn` arm, replace `cpu.writeReg(rt, value);`
with:

```zig
            if (cop_num == 2 and cpu.bus.pgxp_enabled) {
                cpu.writeRegPrecise(rt, value, cpu.cop2.readPreciseData(rd));
            } else {
                cpu.writeReg(rt, value);
            }
```

`cfc2` needs no hook: control registers never hold a projected vertex.

**`opLoad`** — after `cpu.load_delay.load_v = final_val;`:

```zig
    // Word loads only: a packed SXY pair is 32 bits and games move it whole.
    cpu.load_shadow = if (ltype == .Word) cpu.bus.shadowLoad(address) else Precise.none;
```

**`opStore`** — replace the `switch (stype)` block with:

```zig
    switch (stype) {
        .Word => {
            cpu.bus.shadowStore(address, cpu.gpr_shadow[cpu.getIdx(instr.i.rt)]);
            cpu.bus.writeCpuStore(u32, address, value);
        },
        // A sub-word store lands inside a tracked word and destroys it.
        .Half => {
            cpu.bus.shadowInvalidate(address);
            cpu.bus.writeCpuStore(u16, address, value);
        },
        .Byte => {
            cpu.bus.shadowInvalidate(address);
            cpu.bus.writeCpuStore(u8, address, value);
        },
    }
```

`getIdx` is currently private on `Cpu`; make it `pub` (it is a pure index
decode with no invariants to protect).

`opUnalignedStore` writes through `bus.write32` on an aligned address — add
`cpu.bus.shadowInvalidate(aligned_addr);` immediately before that call.

**The `move` idiom** — compilers emit `or rd, rs, $zero` and `addu rd, rs,
$zero` constantly between the `mfc2` and the `sw`, and dropping them costs real
coverage. `rOp` is the shared R-type path; add a specialisation rather than
touching it. Find the two dispatch lines with
`grep -n "0x21 =>\|0x25 =>" ps1-core/src/cpu/exec.zig` and replace each with a
call to:

```zig
/// `or`/`addu` against $zero is the register-move idiom. It is the only
/// arithmetic PGXP follows: everything else falls through `writeReg` and
/// clears the shadow, which is what keeps the propagation set small.
inline fn rOpMove(cpu: *Cpu, instr: Instruction, comptime op: anytype) void {
    const a = cpu.readReg(instr.r.rs);
    const b = cpu.readReg(instr.r.rt);
    const value = op(a, b);
    if (cpu.bus.pgxp_enabled and instr.r.rt == 0) {
        cpu.writeRegPrecise(instr.r.rd, value, cpu.gpr_shadow[@as(u5, instr.r.rs)]);
    } else {
        cpu.writeReg(instr.r.rd, value);
    }
}
```

so `0x21` (ADDU) becomes `rOpMove(cpu, instr, alu.addu)` and `0x25` (OR)
becomes `rOpMove(cpu, instr, alu.orOp)`. Check the exact helper names first
with `grep -n "0x21 =>\|0x25 =>" ps1-core/src/cpu/exec.zig` and reuse whatever
`rOp` was being handed.

- [ ] **Step 7: Run the tests**

Run: `zig fmt ps1-core/src ps1-core/tests && zig build test 2>&1 | tail -20`
Expected: PASS, all 15 binaries.

- [ ] **Step 8: Confirm nothing moved with PGXP off**

Run: `zig build test-roms-ja -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: still 12/17, the same five failures.

Run: `zig build trace-golden -Doptimize=ReleaseFast -- verify 2>&1 | tail -15`
Expected: OK for all ten workloads. **If any workload diverges, stop.** The
shadow tables are not in the state hash and nothing reads them yet, so a
divergence means a propagation hook changed the integer path — most likely
`rOpMove` mis-dispatching, or `writeRegPrecise` reordering the load-delay
cancel.

- [ ] **Step 9: Commit**

```bash
git add ps1-core/src/memory.zig ps1-core/src/cpu ps1-core/src/cop2/cop2.zig ps1-core/tests/cpu_test.zig
git commit -m "$(cat <<'EOF'
feat(pgxp): shadow value tables and the propagation set

A sparse shadow over RAM, scratchpad and the 32 GPRs, following the dataflow
libgpu prescribes and every game therefore uses: mfc2 the packed SXY out of
the GTE, move it between registers, park it in an ordering-table node.

Two rules are load-bearing. The shadow shifts on exactly the lines the
load-delay register numbers do, including the cancel `writeReg` performs, or a
vertex attaches to whatever the previous load targeted. And every other write
to a register clears its shadow — that fall-through is what keeps the
propagation set to six sites instead of the whole instruction set.

`or rd, rs, $zero` is in the set because compilers emit it constantly between
the mfc2 and the sw; leaving it out costs coverage, not correctness.

Off by default, and nothing reads the tables yet. trace-golden verify is
unchanged across all ten workloads.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Provenance reaches GP0, and the counters that prove it

**Files:**
- Modify: `ps1-core/src/cpu/exec.zig` (`opStore`, `.Word` arm)
- Modify: `ps1-core/src/dma.zig:530` and `:578`
- Modify: `ps1-core/src/memory.zig` (the `gpu_data` arm of `write`)
- Modify: `ps1-core/src/gpu/gpu.zig` (`writeGp0`, `processFifoWord`)
- Modify: `ps1-core/src/gpu/gp0.zig` (`cmd_buffer_pgxp`, the resolve helper, the counters, the six triangle parse paths)
- Modify: `ps1-core/src/gpu/primitive.zig` (`Point.px`/`.py`, `getPointPrecise`)
- Test: `ps1-core/tests/gpu_test.zig`

**Interfaces:**
- Consumes: `Bus.pgxp_pending`, `Bus.shadowLoad`, `Cpu.gpr_shadow` from Task 2.
- Produces:
  - `Primitive.Point` = `struct { x: i16, y: i16, px: i32, py: i32 }`
  - `Primitive.getPointPrecise(value: u32, p: Precise) Point`
  - `Gpu.writeGp0(value: u32, p: Precise) u32` — **signature change**
  - `Gp0Engine.write(value, p, sink, vram, draw_env, interrupt_flag) u32` — **signature change**
  - `Gp0Engine.PgxpStats` = `struct { vertices: u64, resolved: u64, identity_fail: u64, disp_sum: u64, disp_max: u32 }`
  - `Gp0Engine.pgxp: PgxpStats`

**Nothing consumes `Point.px`/`.py` yet — Task 4 does.** They are computed and
carried here so this task is testable through the counters alone, with zero
possible effect on rendered output.

- [ ] **Step 1: Write the failing test**

Append to `ps1-core/tests/gpu_test.zig`:

```zig
const Precise = ps1_core.pgxp.Precise;

/// Pack a screen coordinate the way GP0 expects it.
fn packXY(x: i16, y: i16) u32 {
    return (@as(u32, @as(u16, @bitCast(y))) << 16) | @as(u32, @as(u16, @bitCast(x)));
}

test "PGXP: a flat triangle resolves all three vertices" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    bus.pgxp_enabled = true;
    const gpu = &bus.gpu;

    // GP0(0x20): flat triangle, one colour word then three vertex words.
    _ = gpu.writeGp0(0x2000_FFFF, Precise.none);
    _ = gpu.writeGp0(packXY(10, 20), Precise.make(10 << 16 | 0x8000, 20 << 16));
    _ = gpu.writeGp0(packXY(40, 20), Precise.make(40 << 16, 20 << 16 | 0x4000));
    _ = gpu.writeGp0(packXY(10, 60), Precise.make(10 << 16, 60 << 16));

    try expectEqual(@as(u64, 3), gpu.gp0.pgxp.vertices);
    try expectEqual(@as(u64, 3), gpu.gp0.pgxp.resolved);
    try expectEqual(@as(u64, 0), gpu.gp0.pgxp.identity_fail);
}

/// The identity check is the safety net, not an assertion: a stale entry is
/// discarded silently and the integer vertex is used.
test "PGXP: a stale entry is rejected, not applied" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    bus.pgxp_enabled = true;
    const gpu = &bus.gpu;

    _ = gpu.writeGp0(0x2000_FFFF, Precise.none);
    // Says (10, 20); the word says (10, 20) -- accepted.
    _ = gpu.writeGp0(packXY(10, 20), Precise.make(10 << 16, 20 << 16));
    // Says (999, 20); the word says (40, 20) -- a leftover from another vertex.
    _ = gpu.writeGp0(packXY(40, 20), Precise.make(999 << 16, 20 << 16));
    _ = gpu.writeGp0(packXY(10, 60), Precise.none);

    try expectEqual(@as(u64, 3), gpu.gp0.pgxp.vertices);
    try expectEqual(@as(u64, 1), gpu.gp0.pgxp.resolved);
    try expectEqual(@as(u64, 1), gpu.gp0.pgxp.identity_fail); // the stale one
}

/// The FIFO is 16 words deep and is drained against `cycle_debt`, so
/// provenance cannot ride a single pending slot — it has to be stored per
/// word. Fill the FIFO before letting it drain.
test "PGXP: provenance survives a full GP0 FIFO" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    bus.pgxp_enabled = true;
    const gpu = &bus.gpu;

    // Push a large cycle debt so words queue instead of draining immediately.
    gpu.cycle_debt = 10_000;
    _ = gpu.writeGp0(0x2000_FFFF, Precise.none);
    _ = gpu.writeGp0(packXY(10, 20), Precise.make(10 << 16 | 0x8000, 20 << 16));
    _ = gpu.writeGp0(packXY(40, 20), Precise.make(40 << 16, 20 << 16));
    _ = gpu.writeGp0(packXY(10, 60), Precise.make(10 << 16, 60 << 16));
    try expectEqual(@as(u64, 0), gpu.gp0.pgxp.vertices); // still queued

    gpu.cycle_debt = 0;
    _ = gpu.step(1);

    try expectEqual(@as(u64, 3), gpu.gp0.pgxp.vertices);
    try expectEqual(@as(u64, 3), gpu.gp0.pgxp.resolved);
}

/// The CPU store path: `sw $t0, GP0` carries the REGISTER's shadow, because
/// the value's provenance is a register number `memory.zig` never sees.
test "PGXP: a CPU store to GP0 carries the register's shadow" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);
    bus.pgxp_enabled = true;

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;

    // Prime the command word by hand, then store one vertex from a register.
    _ = bus.gpu.writeGp0(0x2000_FFFF, Precise.none);

    cpu.writeReg(10, 0x1F80_1810); // $t2 = GP0
    cpu.writeReg(9, packXY(10, 20)); // $t1 = the vertex
    cpu.gpr_shadow[9] = Precise.make(10 << 16 | 0x8000, 20 << 16);

    bus.write32(0x00, 0xAD49_0000); // sw $9, 0($10)
    bus.write32(0x04, 0x0000_0000);
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();

    try expectEqual(@as(u64, 1), bus.gpu.gp0.pgxp.vertices);
    try expectEqual(@as(u64, 1), bus.gpu.gp0.pgxp.resolved);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | head -30`
Expected: FAIL — `expected 1 argument, found 2` at `writeGp0`.

- [ ] **Step 3: `Primitive.Point` carries the sub-pixel half**

In `ps1-core/src/gpu/primitive.zig`, add the import and widen `Point`:

```zig
const Precise = @import("../pgxp.zig").Precise;

pub const Point = struct {
    x: i16,
    y: i16,
    /// Screen position in 16.16. Equals `x << 16` unless PGXP resolved a
    /// sub-pixel for this vertex.
    px: i32,
    py: i32,
};
```

```zig
pub inline fn getPoint(value: u32) Point {
    const x = getX(value);
    const y = getY(value);
    return .{ .x = x, .y = y, .px = @as(i32, x) << 16, .py = @as(i32, y) << 16 };
}

/// `getPoint` with a candidate sub-pixel position. The candidate is used only
/// if it agrees with the integer coordinate the wire actually carries — see
/// `Precise.resolves`.
pub inline fn getPointPrecise(value: u32, p: Precise) Point {
    var pt = getPoint(value);
    if (p.resolves(pt.x, pt.y)) {
        pt.px = p.x;
        pt.py = p.y;
    }
    return pt;
}
```

`getTexturedPoint` builds a `Point` too — find it and give it the same two
fields, plus a `getTexturedPointPrecise` mirroring the above.

- [ ] **Step 4: The FIFO carries pairs**

In `ps1-core/src/gpu/gpu.zig`, add the import, then the field beside `fifo`:

```zig
const Precise = @import("../pgxp.zig").Precise;
```

```zig
    /// Provenance, indexed by the same head/tail as `fifo`.
    ///
    /// A single pending slot on `Bus` is NOT enough and this is why: the FIFO
    /// is 16 words deep and drains against `cycle_debt`, so a word can sit
    /// here for thousands of cycles while fifteen more are pushed behind it.
    fifo_pgxp: [16]Precise = [_]Precise{.{}} ** 16,
```

```zig
    pub fn writeGp0(self: *Self, value: u32, p: Precise) u32 {
        var stall_cycles: u32 = 0;

        if (self.fifo_count == 16) {
            if (self.cycle_debt > 0) {
                stall_cycles = @intCast(self.cycle_debt);
                self.cycle_debt = 0;
            }
            self.processFifoWord();
        }

        self.fifo[self.fifo_tail] = value;
        self.fifo_pgxp[self.fifo_tail] = p;
        self.fifo_tail = self.fifo_tail +% 1;
        self.fifo_count += 1;

        if (self.cycle_debt <= 0) {
            self.processFifoWord();
        }

        return stall_cycles;
    }
```

In `processFifoWord`, alongside the existing value read:

```zig
        const value = self.fifo[self.fifo_head];
        const p = self.fifo_pgxp[self.fifo_head];
        self.fifo_head = self.fifo_head +% 1;
        self.fifo_count -= 1;

        const debt = self.gp0.write(value, p, &self.sink, &self.vram, &self.draw_env, &self.interrupt_flag);
```

Fix every other caller: `grep -rn "writeGp0" --include=*.zig .` and pass
`Precise.none` at each, except the one in Step 5.

- [ ] **Step 5: The three producers set `pgxp_pending`**

`ps1-core/src/memory.zig`, the `gpu_data` arm of `write` (line 514-517):

```zig
        // GPU
        if (paddr == Addr.gpu_data) {
            const p = self.pgxp_pending;
            self.pgxp_pending = Precise.none;
            self.wait_cycles += self.gpu.writeGp0(@as(u32, value), p);
            return;
        }
```

Consuming it (rather than leaving it set) is what stops one word's provenance
attaching to the next.

`ps1-core/src/cpu/exec.zig`, `opStore`'s `.Word` arm — extend what Task 2 left:

```zig
        .Word => {
            const p = cpu.gpr_shadow[cpu.getIdx(instr.i.rt)];
            cpu.bus.shadowStore(address, p);
            cpu.bus.pgxp_pending = p;
            cpu.bus.writeCpuStore(u32, address, value);
        },
```

`ps1-core/src/dma.zig` — the block-copy site (line 530). Replace the
`channel_idx == 2` branch of that chained `if` so the GPU case sets provenance
first:

```zig
        } else {
            const val = bus.read32(addr);
            if (channel_idx == 0) {
                bus.write32(DmaConst.target_mdec_data, val);
            } else if (channel_idx == 2) {
                bus.pgxp_pending = bus.shadowLoad(addr);
                bus.write32(DmaConst.target_gpu_data, val);
            } else if (channel_idx == 4) {
                bus.write32(DmaConst.target_spu_fifo, val);
            }
        }
```

and the linked-list site (line 576-579):

```zig
            const data = bus.read32(addr);
            // Linked list DMA only goes to GPU (channel 2)
            if (channel_idx == 2) {
                bus.pgxp_pending = bus.shadowLoad(addr);
                bus.write32(DmaConst.target_gpu_data, data);
            }
```

This is the high-yield path by a wide margin: an ordering table is walked by
linked-list DMA, which is how essentially every 3D frame reaches the GPU.

- [ ] **Step 6: `Gp0Engine` resolves and counts**

In `ps1-core/src/gpu/gp0.zig`, add the import and the fields:

```zig
const Precise = @import("../pgxp.zig").Precise;
```

```zig
    /// Provenance for the words in `cmd_buffer`, same indices.
    cmd_buffer_pgxp: [16]Precise = [_]Precise{.{}} ** 16,

    /// Host-side instrumentation, read by `ps1-golden --pgxp`. Not machine
    /// state: excluded from the trace hash for the same reason
    /// `cdrom.pending_cycles` is.
    pub const PgxpStats = struct {
        vertices: u64 = 0,
        resolved: u64 = 0,
        /// A candidate that was present but disagreed with the wire — the
        /// coverage diagnostic. Never an error: the vertex simply falls back.
        identity_fail: u64 = 0,
        /// Displacement in 16.16 units, summed and peak.
        disp_sum: u64 = 0,
        disp_max: u32 = 0,
    };
    pgxp: PgxpStats = .{},
```

Change `write`'s signature and store the provenance beside the word:

```zig
    pub fn write(self: *Gp0Engine, value: u32, p: Precise, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, interrupt_flag: *bool) u32 {
```

and at each of the two places the function assigns into `cmd_buffer`:

```zig
            self.cmd_buffer[0] = value;
            self.cmd_buffer_pgxp[0] = p;
```

```zig
            if (self.words_read < self.cmd_buffer.len) {
                self.cmd_buffer[self.words_read] = value;
                self.cmd_buffer_pgxp[self.words_read] = p;
            }
```

Add the resolve helper. It is the one place the counters move, so the six
triangle parse paths cannot disagree about what "resolved" means:

```zig
    /// Decode a vertex word together with its provenance, counting the outcome.
    fn point(self: *Gp0Engine, idx: usize) Primitive.Point {
        const word = self.cmd_buffer[idx];
        const cand = self.cmd_buffer_pgxp[idx];
        const pt = Primitive.getPointPrecise(word, cand);

        self.pgxp.vertices += 1;
        if (pt.px != @as(i32, pt.x) << 16 or pt.py != @as(i32, pt.y) << 16) {
            self.pgxp.resolved += 1;
            const dx: u32 = @abs(pt.px - (@as(i32, pt.x) << 16));
            const dy: u32 = @abs(pt.py - (@as(i32, pt.y) << 16));
            const d = @max(dx, dy);
            self.pgxp.disp_sum += d;
            if (d > self.pgxp.disp_max) self.pgxp.disp_max = d;
        } else if (cand.valid != 0) {
            // A candidate was present and disagreed with the wire: a stale
            // entry, correctly discarded. Counted, never logged and never
            // fatal — a busy frame carries tens of thousands of vertices.
            self.pgxp.identity_fail += 1;
        }
        return pt;
    }
```

**A resolved vertex whose sub-pixel is exactly zero counts as unresolved.**
That is deliberate: it is indistinguishable from the integer vertex by
construction, so counting it either way is arbitrary and this way the counter
means "vertices this feature actually moved".

Now replace the vertex decode in the six triangle paths.
`drawFlatTriangle` becomes:

```zig
    fn drawFlatTriangle(self: *Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = Primitive.isTransparent(opcode);
        const color = Color.getColor16(self.cmd_buffer[0]);
        const p0 = self.point(1);
        const p1 = self.point(2);
        const p2 = self.point(3);

        sink.drawTriangle(vram, draw_env, p0.x, p0.y, p1.x, p1.y, p2.x, p2.y, color, is_transp);
    }
```

Note the receiver changes from `*const Gp0Engine` to `*Gp0Engine` — the
counters are mutated. Do the same for `drawFlatQuad` (indices 1,2,3,4),
`drawShadedTriangle` (1,3,5), `drawShadedQuad` (1,3,5,7),
`drawTexturedTriangleCommand` (1,3,5), `drawTexturedQuadCommand` (1,3,5,7),
`drawShadedTexturedTriangle` (1,4,7) and `drawShadedTexturedQuad` (1,4,7,10),
using the textured variant of the helper where the path uses
`getTexturedPoint`. `execute` must lose its `*const` too.

**Lines and rectangles are not touched.** A rectangle is an axis-aligned
screen-space blit with no GTE provenance, and PGXP has nothing to offer it.

- [ ] **Step 7: Run the tests**

Run: `zig fmt ps1-core/src ps1-core/tests && zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 8: Confirm nothing moved with PGXP off**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- verify 2>&1 | tail -15`
Expected: OK for all ten workloads.

Run: `zig build test-roms-pl -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: pass.

- [ ] **Step 9: Commit**

```bash
git add ps1-core/src ps1-core/tests/gpu_test.zig
git commit -m "$(cat <<'EOF'
feat(pgxp): carry provenance to GP0, and count what arrives

The GP0 write path is address-blind at all three producers: a CPU store knows
only a register number, and both DMA sites discard the source address by
routing through the generic `bus.write32`. Each now sets `pgxp_pending`, which
the `gpu_data` arm consumes.

A single pending slot is not enough on its own — the FIFO is 16 words deep and
drains against `cycle_debt`, so a word can sit there for thousands of cycles
with fifteen more pushed behind it. Provenance therefore rides the FIFO, and
`cmd_buffer_pgxp` carries it through a multi-word primitive so each vertex
keeps its own.

`Gp0Engine.point` is the single place a vertex is resolved and counted, so the
six triangle paths cannot disagree about what "resolved" means. Nothing
consumes the sub-pixel yet; the counters are the whole observable effect, which
is why trace-golden is unchanged across all ten workloads.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: The software rasterizer draws at 1/16 px

**This is the task that can invalidate the spec.** If the box-relative
1/16-px edge functions are not byte-identical with PGXP off, § 5's argument has
a hole and everything after this waits. It lands before any Metal or app work
for that reason.

**Files:**
- Modify: `ps1-core/src/gpu/command.zig` (`Vertex`, the size pins, `execute`)
- Modify: `ps1-core/src/gpu/sink.zig` (the three triangle methods)
- Modify: `ps1-core/src/gpu/gp0.zig` (pass `Point` through)
- Modify: `ps1-core/src/gpu/renderer.zig:94-197` (`rasterizeTriangle`) and the three `drawXxxTriangle` entry points
- Modify: `ps1-core/tests/goldens/fixtures/synthetic-primitives.p1fx` (regenerate)
- Test: `ps1-core/tests/gpu_test.zig`

**Interfaces:**
- Consumes: `Primitive.Point` from Task 3.
- Produces:
  - `command.Vertex` = `extern struct { x: i16, y: i16, u: u8, v: u8, _pad: u16, color: u32, px: i32, py: i32 }` — 20 bytes
  - `command.Command` — 96 bytes
  - `Sink.drawTriangle(self, vram, env, p0: Primitive.Point, p1, p2, color: u16, is_transparent: bool)`
  - `Sink.drawShadedTriangle(self, vram, env, p0: Primitive.Point, c0: u32, p1, c1, p2, c2, is_transparent: bool)`
  - `Sink.drawTexturedTriangle(self, vram, env, v0: Primitive.TexturedPoint, v1, v2, color: u16, clut: u16, tpage: u16, allow_transparency: bool, opcode: u8)`
  - `renderer.zig` module constants `q_shift` (4), `q_unit` (16), `q_bias_scale` (256) and `toQ(p: i32, base: i16) i32` — file-private, beside the other module consts

- [ ] **Step 1: Write the failing test**

Append to `ps1-core/tests/gpu_test.zig`. Two tests: one that a sub-pixel
vertex actually changes coverage, one that a zero sub-pixel changes nothing.

```zig
/// Draw the same triangle twice — once with integer vertices, once with one
/// vertex nudged half a pixel — and require the covered pixel sets to differ.
/// Without this, every "PGXP works" claim rests on a counter that a no-op
/// would also satisfy.
test "PGXP: a sub-pixel vertex moves coverage" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    bus.pgxp_enabled = true;
    const gpu = &bus.gpu;

    // Full drawing area, no offset.
    _ = gpu.writeGp0(0xE3000000, Precise.none); // area top-left (0,0)
    _ = gpu.writeGp0(0xE4000000 | (511 << 10) | 1023, Precise.none);
    _ = gpu.writeGp0(0xE5000000, Precise.none); // offset (0,0)

    // Integer triangle.
    _ = gpu.writeGp0(0x2000_7FFF, Precise.none);
    _ = gpu.writeGp0(packXY(4, 4), Precise.none);
    _ = gpu.writeGp0(packXY(20, 4), Precise.none);
    _ = gpu.writeGp0(packXY(4, 20), Precise.none);
    const integer_count = countLitPixels(gpu);
    try std.testing.expect(integer_count > 0);

    clearVram(gpu);

    // The same triangle with the apex pushed half a pixel right and down.
    _ = gpu.writeGp0(0x2000_7FFF, Precise.none);
    _ = gpu.writeGp0(packXY(4, 4), Precise.make(4 << 16 | 0x8000, 4 << 16 | 0x8000));
    _ = gpu.writeGp0(packXY(20, 4), Precise.none);
    _ = gpu.writeGp0(packXY(4, 20), Precise.none);
    const nudged_count = countLitPixels(gpu);

    try std.testing.expect(nudged_count != integer_count);
}

/// The equivalence that the whole PGXP-off guarantee rests on, at the unit
/// level: a resolved vertex whose sub-pixel is exactly zero must produce the
/// identical pixel set to an unresolved one.
test "PGXP: a zero sub-pixel is byte-identical to no sub-pixel" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    bus.pgxp_enabled = true;
    const gpu = &bus.gpu;

    _ = gpu.writeGp0(0xE3000000, Precise.none);
    _ = gpu.writeGp0(0xE4000000 | (511 << 10) | 1023, Precise.none);
    _ = gpu.writeGp0(0xE5000000, Precise.none);

    _ = gpu.writeGp0(0x2000_7FFF, Precise.none);
    _ = gpu.writeGp0(packXY(4, 4), Precise.none);
    _ = gpu.writeGp0(packXY(20, 4), Precise.none);
    _ = gpu.writeGp0(packXY(4, 20), Precise.none);
    var plain: [1024 * 512]u16 = undefined;
    @memcpy(&plain, &gpu.vram.data);

    clearVram(gpu);

    _ = gpu.writeGp0(0x2000_7FFF, Precise.none);
    _ = gpu.writeGp0(packXY(4, 4), Precise.make(4 << 16, 4 << 16));
    _ = gpu.writeGp0(packXY(20, 4), Precise.make(20 << 16, 4 << 16));
    _ = gpu.writeGp0(packXY(4, 20), Precise.make(4 << 16, 20 << 16));

    try std.testing.expect(std.mem.eql(u16, &plain, &gpu.vram.data));
}
```

Add the two helpers near the top of the file if it has no equivalent (check
with `grep -n "fn countLitPixels\|fn clearVram" ps1-core/tests/gpu_test.zig`):

```zig
fn countLitPixels(gpu: *ps1_core.gpu.Gpu) usize {
    var n: usize = 0;
    for (gpu.vram.data) |px| {
        if (px != 0) n += 1;
    }
    return n;
}

fn clearVram(gpu: *ps1_core.gpu.Gpu) void {
    @memset(&gpu.vram.data, 0);
}
```

`plain` is 1 MB on the stack — if the test binary trips a stack limit, move it
to `std.testing.allocator.alloc(u16, 1024 * 512)` with a `defer free`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | head -30`
Expected: FAIL — the "moves coverage" test fails with the two counts equal,
because nothing consumes `px`/`py` yet.

- [ ] **Step 3: Widen `command.Vertex`**

In `ps1-core/src/gpu/command.zig`:

```zig
pub const Vertex = extern struct {
    x: i16 = 0,
    y: i16 = 0,
    u: u8 = 0,
    v: u8 = 0,
    _pad: u16 = 0,
    /// 24-bit BGR as it arrives on the wire — the Gouraud paths only.
    color: u32 = 0,
    /// Screen position in 16.16, the exact value the GTE's projection
    /// produced. Equals `x << 16` unless PGXP resolved a sub-pixel.
    ///
    /// Archival, not the rasterizer's working format: the edge functions run
    /// in 1/16 px taken relative to the primitive's bounding box, because
    /// 16.16 cross products reach 2^56 and Metal's `ps1_orient` returns `int`.
    px: i32 = 0,
    py: i32 = 0,
};
```

Update the comptime pins:

```zig
comptime {
    if (@sizeOf(Vertex) != 20) @compileError("Vertex layout changed");
    if (@sizeOf(Command) != 96) @compileError("Command layout changed");
}
```

In `execute`, forward `px`/`py` to the three triangle calls.

- [ ] **Step 4: The sink takes points, not loose coordinates**

`sink.zig` currently spells a textured triangle out in twenty parameters and
would need twenty-six. Take `Primitive.Point`/`Primitive.TexturedPoint`
instead, which *reduces* every signature. Add the import:

```zig
const Primitive = @import("primitive.zig");
```

```zig
    pub fn drawTriangle(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
        p0: Primitive.Point,
        p1: Primitive.Point,
        p2: Primitive.Point,
        color: u16,
        is_transparent: bool,
    ) void {
        self.submit(vram, env, .{
            .kind = .draw_triangle,
            .transparent = @intFromBool(is_transparent),
            .value = color,
            .v = .{
                .{ .x = p0.x, .y = p0.y, .px = p0.px, .py = p0.py },
                .{ .x = p1.x, .y = p1.y, .px = p1.px, .py = p1.py },
                .{ .x = p2.x, .y = p2.y, .px = p2.px, .py = p2.py },
            },
        });
    }
```

Do the same for `drawShadedTriangle` (points plus the three colours) and
`drawTexturedTriangle` (three `TexturedPoint`s plus colour/clut/tpage/opcode).
Update the call sites in `gp0.zig` — they already hold `Point`s from Task 3.

- [ ] **Step 5: `rasterizeTriangle` in box-relative 1/16 px**

In `ps1-core/src/gpu/renderer.zig`, add the module constants above `Renderer`:

```zig
/// Sub-pixel precision: 4 fractional bits, 1/16 of a pixel.
///
/// It is a deliberate ceiling, not an accident. D3D11 mandates 8 sub-pixel
/// bits and OpenGL 4; the artefact PGXP removes is a WHOLE pixel of snapping,
/// so the residual 1/16 px is invisible. What it buys is an `i32` inner loop —
/// see `q_bias_scale` and the bound argument on `rasterizeTriangle`.
const q_shift = 4;
const q_unit: i32 = 1 << q_shift;
/// `orient2d` is bilinear in the coordinates, so scaling both axes by
/// `q_unit` scales it by `q_unit * q_unit`. The fill-rule bias must be scaled
/// by the same factor or it stops being a pure tiebreak: unscaled, a triangle
/// whose doubled area is 3 or less can have all three biased weights land on
/// zero at one scale and not the other, and the PGXP-off equivalence stops
/// being exact.
const q_bias_scale: i32 = q_unit * q_unit;

/// A 16.16 coordinate to 1/16 px, relative to `base`.
///
/// `base` is the pre-offset minimum of the primitive's three vertices, so the
/// difference is bounded by the span — which the oversized-primitive rule caps
/// at 1023 px. Forming the absolute value instead would overflow: `x` is an
/// i16, so `x << 16` already reaches 2^31, and adding the drawing offset
/// carries it past.
inline fn toQ(p: i32, base: i16) i32 {
    return (p - (@as(i32, base) << @as(u5, 16)) + (1 << (16 - q_shift - 1))) >> (16 - q_shift);
}
```

Change `rasterizeTriangle`'s signature to take the 16.16 coordinates alongside
the integer ones:

```zig
    fn rasterizeTriangle(
        vram: *Vram,
        env: *const DrawingEnv,
        x0: i16, y0: i16, px0: i32, py0: i32,
        x1: i16, y1: i16, px1: i32, py1: i32,
        x2: i16, y2: i16, px2: i32, py2: i32,
        allow_transparency: bool,
        comptime Shader: type,
        shader_ctx: anytype,
    ) void {
```

Keep everything from `const ox` down to the `if (min_x > max_x or min_y > max_y) return;`
**exactly as it is** — the oversized-primitive drop and the bounding box stay
on the integer coordinates. Add one line to the box, because a sub-pixel vertex
can push coverage one pixel further:

```zig
        const min_x = @max(draw_x0, @max(0, @min(vx0, @min(vx1, vx2)) - 1));
        const max_x = @min(draw_x1, @min(constants.vram_width - 1, @max(vx0, @max(vx1, vx2)) + 1));
        const min_y = @max(draw_y0, @max(0, @min(vy0, @min(vy1, vy2)) - 1));
        const max_y = @min(draw_y1, @min(constants.vram_height - 1, @max(vy0, @max(vy1, vy2)) + 1));
```

Widening the box costs at most one ring of pixels that fail the coverage test;
it cannot change which pixels are drawn with PGXP off.

Then replace everything from `const area_signed = ...` down to the loop's
`row0/row1/row2` initialisation with the q-space form:

```zig
        // Everything below runs in 1/16 px taken relative to the primitive's
        // own bounding box. That is what keeps `orient2d` inside i32: the
        // oversized rule caps the span at 1023 px, so a relative coordinate is
        // at most 1023 * 16 < 2^14 and the cross product at most 2^29.
        // Absolute coordinates are not bounded that way -- `vx` can sit ~3000
        // px out while the box is still on screen.
        const bx = @min(x0, @min(x1, x2));
        const by = @min(y0, @min(y1, y2));
        const org_x: i32 = @as(i32, bx) + ox;
        const org_y: i32 = @as(i32, by) + oy;

        const qx0 = toQ(px0, bx);
        const qy0 = toQ(py0, by);
        const qx1 = toQ(px1, bx);
        const qy1 = toQ(py1, by);
        const qx2 = toQ(px2, bx);
        const qy2 = toQ(py2, by);

        const area_signed = orient2d(qx0, qy0, qx1, qy1, qx2, qy2);
        if (area_signed == 0) return;

        const s: i32 = if (area_signed < 0) -1 else 1;
        const area: i32 = area_signed * s;

        const dw0dx = s * (qy1 - qy2) * q_unit;
        const dw0dy = s * (qx2 - qx1) * q_unit;
        const dw1dx = s * (qy2 - qy0) * q_unit;
        const dw1dy = s * (qx0 - qx2) * q_unit;
        const dw2dx = s * (qy0 - qy1) * q_unit;
        const dw2dy = s * (qx1 - qx0) * q_unit;

        const bias0: i32 = if (isTopLeft(s * (qx2 - qx1), s * (qy2 - qy1))) -q_bias_scale else 0;
        const bias1: i32 = if (isTopLeft(s * (qx0 - qx2), s * (qy0 - qy2))) -q_bias_scale else 0;
        const bias2: i32 = if (isTopLeft(s * (qx1 - qx0), s * (qy1 - qy0))) -q_bias_scale else 0;

        const sq_x = (min_x - org_x) * q_unit;
        const sq_y = (min_y - org_y) * q_unit;

        var row0 = s * orient2d(qx1, qy1, qx2, qy2, sq_x, sq_y) + bias0;
        var row1 = s * orient2d(qx2, qy2, qx0, qy0, sq_x, sq_y) + bias1;
        var row2 = s * orient2d(qx0, qy0, qx1, qy1, sq_x, sq_y) + bias2;
```

The pixel loop below is unchanged: `dw0dx` is now the step for one whole pixel
(`q_unit` q-units), and `Shader.shade` still receives `w_i - bias_i` and
`area`, both scaled by `q_bias_scale`. `interp` is `@divFloor(num, area)` and
`@divFloor(k*a, k*b) == @divFloor(a, b)` for `k > 0`, so every interpolated
attribute is bit-identical.

Update the three `drawXxxTriangle` entry points to take and forward `px`/`py`,
and `command.execute` to pass `cmd.v[i].px` / `.py`.

- [ ] **Step 6: Run the tests**

Run: `zig fmt ps1-core/src && zig build test 2>&1 | tail -20`
Expected: PASS, including both new tests.

- [ ] **Step 7: Prove PGXP-off is unchanged — the gate for this task**

Run each, and treat any movement as a stop:

```bash
zig build test-roms-pl -Doptimize=ReleaseFast 2>&1 | tail -5
zig build test-roms-ja -Doptimize=ReleaseFast 2>&1 | tail -5
zig build trace-golden -Doptimize=ReleaseFast -- verify 2>&1 | tail -15
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify 2>&1 | tail -15
```

Expected: PL passes, JA still 12/17 with the same five, `verify` OK on all ten
workloads, `stream-verify` OK. **If `verify` moves, do not recapture.** The
likely causes, in order: the bias was not scaled by `q_bias_scale`; `toQ` used
the post-offset base and overflowed; the bounding box was widened by more than
one pixel and a clip boundary moved.

- [ ] **Step 8: Regenerate the committed fixture**

`Vertex` went from 12 to 20 bytes and `Command` from 72 to 96, so every `.p1fx`
file's `record_stride` is stale. That check firing is the pin doing its job.

```bash
zig build fixtures -Doptimize=ReleaseFast
cp zig-out/fixtures/synthetic-primitives.p1fx ps1-core/tests/goldens/fixtures/
zig build test 2>&1 | tail -5
```

Expected: `fixture_test` passes against the regenerated file. **The fixture's
VRAM hashes must not change** — the records are wider but describe the same
primitives, and with PGXP off `px == x << 16`. If a hash moves, step 5 is
wrong; stop.

- [ ] **Step 9: Commit**

```bash
git add ps1-core/src ps1-core/tests
git commit -m "$(cat <<'EOF'
feat(pgxp): the software rasterizer draws at 1/16 px

`command.Vertex` carries the exact 16.16 position the GTE produced, and
`rasterizeTriangle` reduces it at draw time to 1/16 px taken relative to the
primitive's bounding box.

Box-relative is what keeps the edge functions in i32: the oversized-primitive
rule caps the span at 1023 px, so a relative coordinate is under 2^14 and the
cross product under 2^29. Absolute 16.16 reaches 2^56, which is also why
neither this nor the Metal backend computes in 16.16.

The fill-rule bias is scaled by q_unit^2 along with everything else. Left at
-1 it stops being a pure tiebreak — a triangle whose doubled area is 3 or less
can have all three biased weights land on zero at one scale and not the other,
and the PGXP-off equivalence stops being exact rather than merely rare.

Vertex is now 20 bytes and Command 96, so the committed .p1fx is regenerated.
Its VRAM hashes are unchanged, as are test-roms-pl, test-roms-ja and both
trace-golden gates.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: The Metal backend draws at 1/16 px

**Files:**
- Modify: `ps1-capi/include/ps1.h` (`Ps1GpuVertex`, its `_Static_assert`s, `PS1_GPU_COMMAND_STRIDE`)
- Modify: `ps1-macos/Shaders/PrimInstance.h` (`qx0..qy2`)
- Modify: `ps1-macos/Shaders/Rasterizer.metal` (`ps1_triangle_coverage`)
- Modify: `ps1-macos/Sources/PS1/PrimBuilder.swift` (`triangle`)
- Modify: `ps1-macos/Sources/PS1/FixtureFile.swift` (only if it hardcodes 72)
- Test: `ps1-macos/Tests/MetalRasterizerTests.swift`

**Interfaces:**
- Consumes: `command.Vertex.px`/`.py` from Task 4.
- Produces:
  - `Ps1GpuVertex` gains `int32_t px, py` — 20 bytes; `PS1_GPU_COMMAND_STRIDE` becomes 96.
  - `Ps1PrimInstance` gains `int qx0, qy0, qx1, qy1, qx2, qy2` — box-relative 1/16 px.

- [ ] **Step 1: Write the failing test**

Append to `ps1-macos/Tests/MetalRasterizerTests.swift`, following the file's
existing `@Test` shape (find one with
`grep -n "@Test" ps1-macos/Tests/MetalRasterizerTests.swift | head -3` and copy
its setup verbatim — it builds a `MetalRasterizer`, replays a fixture and
compares `readbackNative()` against `ShadowVram`).

```swift
/// A hand-built triangle with one vertex nudged half a pixel must cover a
/// different pixel set than the same triangle with integer vertices — and the
/// Metal backend must agree with the software rasterizer about which.
///
/// The fixture corpus cannot pin this: every fixture was captured with PGXP
/// off, so every `px` in it is exactly `x << 16`.
@Test func aSubPixelVertexMovesCoverageIdenticallyToSoftware() throws {
    let r = try MetalRasterizer()

    // A C array imports into Swift as a tuple, so the three vertices are
    // written out rather than looped.
    func vertex(_ x: Int16, _ y: Int16) -> Ps1GpuVertex {
        var v = Ps1GpuVertex()
        v.x = x
        v.y = y
        v.px = Int32(x) << 16
        v.py = Int32(y) << 16
        return v
    }

    var integerCmd = Ps1GpuCommand()
    integerCmd.kind = UInt8(PS1_GPU_DRAW_TRIANGLE)
    integerCmd.value = 0x7FFF
    integerCmd.v = (vertex(4, 4), vertex(20, 4), vertex(4, 20))

    var nudgedCmd = integerCmd
    nudgedCmd.v.0.px = (4 << 16) | 0x8000
    nudgedCmd.v.0.py = (4 << 16) | 0x8000

    let integerVram = try r.replay([integerCmd])
    let nudgedVram = try r.replay([nudgedCmd])
    #expect(integerVram != nudgedVram)
}
```

**Read `MetalRasterizerTests.swift` first and match its API — do not invent
one.** The file already has a way to replay a hand-built command list and read
the result back (that is how
`aTexelThatModulatesToBlackIsDrawnRatherThanDiscarded` works); reuse exactly
that helper and its comparison, whatever they are called. `replay([...])` above
is a stand-in for it.

This test deliberately does NOT compare against `ShadowVram`: `ShadowVram`
models the memory movers only, never the rasterizer, so it has no opinion about
triangle coverage. The software-vs-Metal comparison for sub-pixel triangles has
no fixture behind it either — every fixture was captured with PGXP off, so
every `px` in the corpus is exactly `x << 16`. Cross-checking the two
rasterizers on sub-pixel content is `PS1_LIVE_DIFF`'s job on a real game, and
it is exploratory, not a gate.

- [ ] **Step 2: Run the test to verify it fails**

Run: `ps1-macos/test.sh 2>&1 | tail -30`
Expected: FAIL — `value of type 'Ps1GpuVertex' has no member 'px'`.

Note `test.sh` needs `zig build capi-lib` and `zig build metallib` first; it
says so if they are missing.

- [ ] **Step 3: Widen the C ABI**

In `ps1-capi/include/ps1.h`, add the two fields to `Ps1GpuVertex` (before the
closing brace at line 113):

```c
    /* Screen position in 16.16 — the exact value the GTE's projection
       produced, `x << 16` unless PGXP resolved a sub-pixel for this vertex.
       Archival: the rasterizers work in 1/16 px relative to the primitive's
       bounding box, because 16.16 cross products reach 2^56. */
    int32_t px, py;
```

and update the pins:

```c
_Static_assert(sizeof(Ps1GpuVertex) == 20, "Ps1GpuVertex layout changed");
```

`PS1_GPU_COMMAND_STRIDE` becomes `96`; find its `#define` and the comment that
says "command.zig pins 72" and update both.

Run `zig build capi-lib` — the comptime block in `ps1-capi/src/root.zig` that
mirrors these constants will fail loudly if you missed one.

- [ ] **Step 4: Add the box-relative coordinates to the instance record**

In `ps1-macos/Shaders/PrimInstance.h`, after the `x0..y2` block:

```c
    /* Screen-space vertices in 1/16 px, taken RELATIVE to
       min(x0, x1, x2) / min(y0, y1, y2) — with GP0(E5)'s offset already
       applied, exactly as x0..y2 are. Triangles only.

       Relative because absolute values overflow: the oversized-primitive rule
       caps the span at 1023 px, so a relative coordinate is at most
       1023 * 16 < 2^14 and `ps1_orient` at most 2^29, comfortably inside int
       at every internal scale. An absolute 1/16-px coordinate can sit ~3000 px
       out while the box is still on screen, and its cross product does not
       fit.

       Computed on the CPU for the same reason everything else in this record
       is: it leaves no state differing between primitives in a batch. */
    int qx0, qy0, qx1, qy1, qx2, qy2;
```

- [ ] **Step 5: Fill them in `PrimBuilder.triangle`**

In `ps1-macos/Sources/PS1/PrimBuilder.swift`, after the existing
`(inst.x2, inst.y2) = ...` line:

```swift
        // 1/16 px, relative to the box origin. `toQ` rounds to nearest; the
        // subtraction is bounded by the span, which the guard above caps at
        // 1023 px.
        let bx = vx.min()!, by = vy.min()!
        func toQ(_ p: Int32, _ base: Int) -> Int32 {
            Int32((Int(p) - (base << 16) + 2048) >> 12)
        }
        (inst.qx0, inst.qy0) = (toQ(verts[0].px, bx - ox) , toQ(verts[0].py, by - oy))
        (inst.qx1, inst.qy1) = (toQ(verts[1].px, bx - ox), toQ(verts[1].py, by - oy))
        (inst.qx2, inst.qy2) = (toQ(verts[2].px, bx - ox), toQ(verts[2].py, by - oy))
```

`verts[i].px` is pre-offset (it comes straight off the wire record), while
`vx`/`vy` are post-offset, so `bx - ox` is the pre-offset minimum — the same
`base` `Renderer.toQ` uses in Zig. Keeping both sides pre-offset is what avoids
forming an absolute 16.16 value that overflows.

- [ ] **Step 6: The shader reduces the scaled sample point to native 1/16 px**

In `ps1-macos/Shaders/Rasterizer.metal`, replace the body of
`ps1_triangle_coverage` down to the `b0`/`b1`/`b2` computation:

```metal
    // Phase C scaled the VERTICES up by s. That inverts here: the vertices
    // arrive in native 1/16-px units and the SAMPLE POINT is reduced to them.
    // Scaling 1/16-px vertices up by s would put ps1_orient at 2^35 and force
    // `long` into the per-fragment inner loop of every triangle in every game.
    //
    // At a top-left subtexel px == nx * s, so (px * 16) / s is exactly nx * 16
    // for every s including 3 — downsample-invariance holds by construction
    // rather than by argument. px * 16 peaks at 1024 * 8 * 16 = 2^17.
    int ox = min(p.x0, min(p.x1, p.x2));
    int oy = min(p.y0, min(p.y1, p.y2));
    int qpx = (px * PS1_Q_UNIT) / s - ox * PS1_Q_UNIT;
    int qpy = (py * PS1_Q_UNIT) / s - oy * PS1_Q_UNIT;

    int ax = p.qx0, ay = p.qy0;
    int bx = p.qx1, by = p.qy1;
    int cx = p.qx2, cy = p.qy2;

    int area_signed = ps1_orient(ax, ay, bx, by, cx, cy);
    // Normalize to a positive area by flipping the sign of every edge function
    // rather than by swapping two vertices: a swap would permute the
    // attributes the shader indexes by vertex number.
    int sgn = area_signed < 0 ? -1 : 1;
    area = area_signed * sgn;

    // The fill rule reads only the SIGN of each edge delta, so the q-space
    // deltas classify identically to the native ones.
    //
    // The bias is scaled by PS1_Q_BIAS_SCALE, not left at -1. Unscaled it stops
    // being a pure tiebreak: a triangle whose doubled area is 3 or less can
    // have all three biased weights land on zero at one scale and not the
    // other. `renderer.zig` scales it for the same reason and they must agree.
    int bias0 = ps1_top_left(sgn * (cx - bx), sgn * (cy - by)) ? -PS1_Q_BIAS_SCALE : 0;
    int bias1 = ps1_top_left(sgn * (ax - cx), sgn * (ay - cy)) ? -PS1_Q_BIAS_SCALE : 0;
    int bias2 = ps1_top_left(sgn * (bx - ax), sgn * (by - ay)) ? -PS1_Q_BIAS_SCALE : 0;

    int b0 = sgn * ps1_orient(bx, by, cx, cy, qpx, qpy) + bias0;
    int b1 = sgn * ps1_orient(cx, cy, ax, ay, qpx, qpy) + bias1;
    int b2 = sgn * ps1_orient(ax, ay, bx, by, qpx, qpy) + bias2;
```

Leave the coverage test and the unbiased write-back below it untouched. Add the
constants near the top of the file, beside the other `PS1_` defines:

```metal
#define PS1_Q_UNIT       16   /* 1/16 px; renderer.zig's q_unit */
#define PS1_Q_BIAS_SCALE 256  /* PS1_Q_UNIT * PS1_Q_UNIT */
```

`ps1_interp` is unchanged: both the weights and the area pick up the same
factor, and integer division of a ratio is invariant under it.

- [ ] **Step 7: Regenerate the fixtures and run the suite**

```bash
zig build fixtures -Doptimize=ReleaseFast
zig build capi-lib && zig build metallib
ps1-macos/test.sh 2>&1 | tail -40
```

Expected: all 245 existing tests plus the new one pass. The Phase B 1× gate and
the Phase C downsample-invariance gate at N ∈ {2,3,4,8} are the ones that
matter here; **3 is in that list on purpose**, because `/ s` and `% s` are
shifts and masks at every power of two and the new `(px * 16) / s` is not.

**Expect an accepted behaviour change above 1×:** which *subtexels* a triangle
covers at non-power-of-two scales shifts slightly, because a subtexel offset of
1/3 px is not representable in 1/16 px. Nothing gates on it — the 1× hashes are
exact and invariance is defined at top-left subtexels, where the reduction is
exact for every s. For s ≤ 8 distinct subtexels stay distinct, since 16/s ≥ 2.

- [ ] **Step 8: Commit**

```bash
git add ps1-capi/include/ps1.h ps1-macos/Shaders ps1-macos/Sources/PS1/PrimBuilder.swift ps1-macos/Tests ps1-core/tests/goldens/fixtures
git commit -m "$(cat <<'EOF'
feat(pgxp): the Metal backend draws at 1/16 px

`Ps1PrimInstance` carries the three vertices in 1/16 px relative to the
primitive's bounding box, computed on the CPU like everything else in that
record so nothing differs between primitives in a batch.

The shader inverts Phase C's move: rather than scaling the vertices up by s, it
reduces the scaled sample point to native 1/16-px units. Scaling 1/16-px
vertices would put ps1_orient at 2^35 and force `long` into the per-fragment
inner loop of every triangle in every game. At a top-left subtexel px == nx * s,
so (px * 16) / s is exactly nx * 16 for every s including 3, and
downsample-invariance holds by construction.

The fill-rule bias is scaled by 256 to match renderer.zig; unscaled it stops
being a pure tiebreak on near-degenerate triangles.

Ps1GpuVertex is 20 bytes and the command stride 96.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: The setting — core flag, C ABI, app

**Files:**
- Modify: `ps1-capi/src/root.zig`, `ps1-capi/include/ps1.h`
- Modify: `ps1-capi/src/capi_test.zig`
- Create: `ps1-macos/Sources/PS1/PgxpSetting.swift`
- Create: `ps1-macos/Tests/PgxpSettingTests.swift`
- Modify: `ps1-macos/Sources/PS1/Ps1Core.swift`, `EmulatorViewModel.swift`, `EmulatorRunner.swift`
- Modify: `ps1-macos/Sources/PS1App/VideoCommands.swift`

**Interfaces:**
- Consumes: `Bus.pgxp_enabled` from Task 2.
- Produces:
  - `void ps1_set_pgxp(Ps1*, int enabled);`
  - `struct PgxpSetting { static let defaultsKey: String; var enabled: Bool; init(key:defaults:); mutating func set(_:) }`
  - `EmulatorViewModel.pgxpEnabled: Bool`

- [ ] **Step 1: Write the failing tests**

`ps1-capi/src/capi_test.zig` — follow the file's existing shape (it creates a
handle, runs frames, and frees):

```zig
test "ps1_set_pgxp toggles the core flag" {
    const h = ps1_new() orelse return error.OutOfMemory;
    defer ps1_free(h);

    try std.testing.expect(!coreOf(h).bus.pgxp_enabled);
    ps1_set_pgxp(h, 1);
    try std.testing.expect(coreOf(h).bus.pgxp_enabled);
    ps1_set_pgxp(h, 0);
    try std.testing.expect(!coreOf(h).bus.pgxp_enabled);
}
```

Use whatever the file already uses to reach the core behind the opaque handle
(`grep -n "fn coreOf\|@ptrCast" ps1-capi/src/capi_test.zig`); if there is no
such helper, assert through a second `ps1_set_pgxp` round trip plus a getter
you add alongside it — do not invent a cast.

`ps1-macos/Tests/PgxpSettingTests.swift`:

```swift
import Testing
@testable import PS1

/// The same shape as `InternalResolution`, and the same reason it is a type:
/// the rule is reachable from a test without a window.
///
/// Unlike `VolumeSetting`, an absent key is NOT ambiguous here —
/// `bool(forKey:)` returns false for a missing key and false is the intended
/// default — so no `object(forKey:)` probe is needed.
struct PgxpSettingTests {
    private func scratchDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func defaultsToOff() {
        let d = scratchDefaults("pgxp.default")
        #expect(PgxpSetting(key: "pgxp", defaults: d).enabled == false)
    }

    @Test func persistsAndReloads() {
        let d = scratchDefaults("pgxp.persist")
        var s = PgxpSetting(key: "pgxp", defaults: d)
        s.set(true)
        #expect(PgxpSetting(key: "pgxp", defaults: d).enabled == true)
        s.set(false)
        #expect(PgxpSetting(key: "pgxp", defaults: d).enabled == false)
    }
}
```

- [ ] **Step 2: Run both to verify they fail**

Run: `zig build test 2>&1 | head -20` — expected FAIL, `ps1_set_pgxp` undefined.
Run: `ps1-macos/test.sh 2>&1 | tail -20` — expected FAIL, no `PgxpSetting`.

- [ ] **Step 3: Add the C ABI entry point**

`ps1-capi/include/ps1.h`, beside `ps1_set_buttons`:

```c
/* PGXP geometry correction: keep the sub-pixel screen position the GTE
   computes instead of snapping every vertex to a whole pixel.
   0 = off (the default), non-zero = on. Safe to call at any time. */
void    ps1_set_pgxp(Ps1*, int enabled);
```

`ps1-capi/src/root.zig`, beside the `ps1_set_buttons` export:

```zig
export fn ps1_set_pgxp(handle: ?*Ps1, enabled: c_int) void {
    const core = coreFrom(handle) orelse return;
    core.bus.pgxp_enabled = enabled != 0;
}
```

Match the file's existing null-handle guard exactly — copy it from
`ps1_set_buttons` rather than writing a new one.

- [ ] **Step 4: Create `PgxpSetting.swift`**

```swift
import Foundation

/// Whether PGXP geometry correction is on.
///
/// Shaped after `InternalResolution` — `init` resolves from `UserDefaults`,
/// `set` persists, and the rule lives in the type so it is reachable from a
/// test without a window.
///
/// Default OFF, and for the same reason internal resolution defaults to 1×:
/// off is the configuration the byte-exact oracle covers. Selecting PGXP opts
/// out of that knowingly; the shipped configuration must not opt out for the
/// player.
///
/// There is no clamp and no `object(forKey:)` probe, unlike its two
/// neighbours. `bool(forKey:)` returns false for a missing key and false is
/// the intended default, so absence is not ambiguous the way it is for
/// `VolumeSetting`'s level.
struct PgxpSetting {
    static let defaultsKey = "pgxpEnabled"

    private let defaults: UserDefaults
    private let key: String
    private(set) var enabled: Bool

    init(key: String = PgxpSetting.defaultsKey,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = key
        self.enabled = defaults.bool(forKey: key)
    }

    mutating func set(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: key)
    }
}
```

- [ ] **Step 5: Wire it through the app**

`Ps1Core.swift` — add the thin wrapper beside the existing `setButtons`:

```swift
    func setPgxp(_ enabled: Bool) {
        ps1_set_pgxp(handle, enabled ? 1 : 0)
    }
```

`EmulatorViewModel.swift` — a stored `PgxpSetting` and a published property,
following `internalScale` exactly:

```swift
    private var pgxpSetting = PgxpSetting()

    public var pgxpEnabled: Bool {
        get { pgxpSetting.enabled }
        set {
            pgxpSetting.set(newValue)
            runner?.setPgxp(newValue)
        }
    }
```

`EmulatorRunner` needs `setPgxp` to reach the core on the emulator thread the
same way `setButtons` does — copy that path, do not call into `Ps1Core`
directly from the main actor. It must also **apply the current setting when a
disc is loaded**, because the runner is rebuilt per game while the setting
outlives every disc — the same trap `AudioOutput.setGain` has, and the same
fix: re-apply in `play()`.

Unlike a scale change, this needs **no `.id()` rebuild** of the coordinator:
PGXP changes the contents of the command stream, not the size or format of any
texture, so the existing renderer consumes it from the next frame onward.

`VideoCommands.swift` — add below the resolution picker, inside the same
`CommandMenu("Video")`:

```swift
            Divider()
            Toggle("PGXP Geometry Correction", isOn: $model.pgxpEnabled)
```

- [ ] **Step 6: Run both suites**

Run: `zig build test 2>&1 | tail -10` — expected PASS.
Run: `zig build capi-lib && ps1-macos/test.sh 2>&1 | tail -20` — expected PASS.

- [ ] **Step 7: Confirm the default really is off, end to end**

Run: `zig build macos && open zig-out/PS1.app`

Load a game, open **Video**, and confirm the toggle is unchecked. Tick it and
confirm the picture does not break. Quit and relaunch, and confirm the tick
persisted. This is the only step in the plan that needs a human eye, and it is
checking one thing: that a fresh install does not ship the feature on.

- [ ] **Step 8: Commit**

```bash
git add ps1-capi ps1-macos
git commit -m "$(cat <<'EOF'
feat(pgxp): a setting, off by default

ps1_set_pgxp on the C ABI, PgxpSetting shaped after InternalResolution, and a
Video menu toggle.

Off by default for the same reason internal resolution defaults to 1x: off is
the configuration the byte-exact oracle covers, and the shipped configuration
must not opt out of it for the player.

No .id() rebuild, unlike a scale change — PGXP changes the contents of the
command stream, not the size or format of any texture. The runner does
re-apply the setting on play(), because it is rebuilt per game while the
setting outlives every disc.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: The `pgxp` sweep, the floors, the numbers, the docs

**Files:**
- Modify: `ps1-golden/src/main.zig` (the mode dispatch, a `runPgxp`, the report)
- Create: `ps1-core/tests/goldens/pgxp/floors.txt`
- Modify: `docs/superpowers/specs/2026-08-30-pgxp-geometry-correction-design.md` (the one CLI line)
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: `Gp0Engine.PgxpStats` from Task 3, `Bus.pgxp_enabled` from Task 2.
- Produces: `zig build trace-golden -- pgxp [--filter=…] [--instructions=…]`

- [ ] **Step 1: Add the mode**

In `ps1-golden/src/main.zig`, add `pgxp` to the usage text beside
`verify`/`capture`/`stream-verify`/`stream-capture`:

```
\\  pgxp                    boot each workload with PGXP ON and report the
\\                          identity invariant and the shadow hit-rate
```

Add a `runPgxp` alongside `runWorkload`. It is `runWorkload` with three
differences: it sets `bus.pgxp_enabled = true` before the run, it takes **no
state-hash samples at all** (PGXP-on state has no golden and never will), and
it reads the counters at the end:

```zig
const PgxpReport = struct {
    vertices: u64,
    resolved: u64,
    identity_fail: u64,
    disp_sum: u64,
    disp_max: u32,

    fn hitRate(self: PgxpReport) f64 {
        if (self.vertices == 0) return 0;
        return @as(f64, @floatFromInt(self.resolved)) * 100.0 /
            @as(f64, @floatFromInt(self.vertices));
    }

    /// Displacement in pixels. The counters accumulate 16.16 units.
    fn maxPx(self: PgxpReport) f64 {
        return @as(f64, @floatFromInt(self.disp_max)) / 65536.0;
    }

    fn meanPx(self: PgxpReport) f64 {
        if (self.resolved == 0) return 0;
        return @as(f64, @floatFromInt(self.disp_sum)) /
            @as(f64, @floatFromInt(self.resolved)) / 65536.0;
    }
};
```

- [ ] **Step 2: Print the report and enforce the invariants**

Per workload, in the shape the spec fixes:

```
croc-legend-of-the-gobbos
  GP0 vertices      1,284,551
  shadow resolved   1,197,832   (93.2%)  floor 90.0%  OK
  displacement      max 0.996 px, mean 0.263 px
  identity          0 violations                      OK
```

Two hard checks, both non-zero exit on failure:

- **`maxPx() < 1.0`.** This follows from the identity predicate, so it is
  really a check that the predicate is wired up at all — if it ever fires,
  `Gp0Engine.point` is measuring displacement against the wrong baseline.
- **The hit-rate is at or above the workload's floor.**

`identity_fail` is **reported, not enforced**. It counts vertices the predicate
correctly rejected — a leak in invalidation, which costs coverage rather than
correctness, and which the hit-rate floor already prices in. Printing it is how
you find the missing propagation idiom if the rate comes back low.

- [ ] **Step 3: The floors file**

`ps1-core/tests/goldens/pgxp/floors.txt`, one workload per line:

```
# Per-game shadow hit-rate floors for `trace-golden -- pgxp`, in percent.
#
# A ratchet, exactly like test-roms-pl's floor.txt: set from the first measured
# sweep rounded DOWN to the nearest whole percent, so a propagation regression
# shows up as a drop rather than as a subtly worse picture nobody notices.
# Re-pin deliberately, in its own commit, when propagation improves.
#
# A workload with no line here is a WARNING, not an error — unlike a missing
# trace golden, which stays fatal. A new rip should not fail the gate before
# anyone has measured it.
```

Leave it with only the comment block for now; step 4 fills it.

- [ ] **Step 4: Measure, then pin**

```bash
zig build trace-golden -Doptimize=ReleaseFast -- pgxp 2>&1 | tee /tmp/pgxp-sweep.txt
```

Append one `<workload> <floor>` line per workload, each the measured rate
rounded down to a whole percent.

**If a rate comes back far below the others** — say 40% where its neighbours
are 90% — do not pin it and move on. Read `identity_fail` for that workload
first: a high count means invalidation is leaking, and a low count alongside a
low hit-rate means a propagation idiom is missing. Instrument the unresolved
vertices to find which, add the idiom to Task 2's set, and re-measure. A 2D
title or one that transforms geometry on the CPU legitimately scores low —
CPU mode is out of scope — and those get an honest low floor.

- [ ] **Step 5: The performance numbers**

Let the machine settle, then take the best of five for each:

```bash
zig build ps1-bench-dual -Doptimize=ReleaseFast
for i in 1 2 3 4 5; do
  ./zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin \
    games/croc-legend-of-the-gobbos/croc-legend-of-the-gobbos.cue 3000
done
```

- **PGXP off must be within noise of the pre-task-1 number.** Get that baseline
  by benching `git stash`-ed or `git worktree`-d HEAD~7 the same way — a
  remembered figure is not a measurement, and a run straight after
  `trace-golden` reads 15% slow.
- **If off is NOT within noise**, the cost is `cpu.writeReg`'s shadow clear —
  one store in the hottest function in the emulator. The fallback is to move
  the propagation behind a comptime-specialised core module, the same shape
  `gpu_sink` already uses: a `pgxp` build option, `.off` for `ps1-wasm`,
  `ps1-debug` and the ROM suites, `.on` for `ps1-capi` and `ps1-golden`. Do not
  attempt this speculatively — only if the number demands it.
- **PGXP on is measured and reported, not gated.** Put both figures in the
  commit message.

- [ ] **Step 6: Documentation**

Fix the one place the spec names the CLI. In
`docs/superpowers/specs/2026-08-30-pgxp-geometry-correction-design.md`, change
`zig build trace-golden -- --pgxp` to `zig build trace-golden -- pgxp` — it is
a mode, like `verify`, not a flag.

Add to `CLAUDE.md`'s quick-commands table:

```
| `zig build trace-golden -- pgxp` | Boots every workload with PGXP ON and reports the identity invariant plus a ratcheted per-game shadow hit-rate. There is no golden for PGXP-on output and never will be; this is the whole automated gate for the feature. |
```

Add a **PGXP** section after **GPU**, carrying the four things that will
otherwise be re-derived painfully:

- **The identity check is the safety net, not just the gate.** A stale shadow
  entry either fails `precise.x >> 16 == vertex.x` and is discarded, or passes
  and therefore agrees to within a pixel. That is why there is no invalidation
  hook on OTC, MDEC or CD DMA, and why adding one is not a bug fix.
- **The GP0 write path is address-blind at all three producers**, and the FIFO
  is 16 words deep, so provenance rides the FIFO. A single pending slot on
  `Bus` is only the device that carries it across `write`'s generic signature.
- **Neither rasterizer computes in 16.16.** Absolute 16.16 cross products reach
  2^56 and Metal's `ps1_orient` returns `int`. Both reduce to 1/16 px relative
  to the primitive's bounding box, which the oversized-primitive rule caps at
  1023 px — hence 2^29, hence `i32`. **The fill-rule bias is scaled by 256 with
  everything else**; left at -1 it stops being a pure tiebreak on triangles
  whose doubled area is 3 or less, and the PGXP-off equivalence stops being
  exact.
- **Off by default**, and 1/16 px is a ceiling: raising it means putting
  `long` in Metal's fragment shader. The shadow table and the records carry the
  full 16.16, so nothing upstream would change if that trade is ever reopened.

Also correct the `command.zig` line in the **GPU** section if it names the
72-byte stride, and the `Vertex`/`Command` sizes wherever CLAUDE.md pins them.

- [ ] **Step 7: Commit**

```bash
git add ps1-golden ps1-core/tests/goldens/pgxp CLAUDE.md docs/superpowers/specs
git commit -m "$(cat <<'EOF'
feat(pgxp): the sweep, the floors, and the docs

`trace-golden -- pgxp` boots every workload with PGXP on and reports the two
things that are machine-checkable without a golden: that every resolved vertex
moved less than a pixel, and what fraction of GP0 vertices the shadow resolved
at all. The hit-rate carries a per-game floor, ratcheted like test-roms-pl's.

identity_fail is reported rather than enforced: it counts vertices the
predicate correctly rejected, which is a coverage diagnostic the hit-rate floor
already prices in.

PGXP-on output has no golden and never will — the identity invariant bounds the
error but does not confirm the value, and Avocado does not implement PGXP, so
it is not an oracle here either. That is the reason the default is off.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

Run all of these from the repo root, in order, after Task 7:

```bash
zig fmt --check ps1-core/src ps1-golden/src ps1-capi/src
zig build test
zig build test-roms-pl -Doptimize=ReleaseFast
zig build test-roms-ja -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
zig build trace-golden -Doptimize=ReleaseFast -- pgxp
zig build capi-lib && zig build metallib && ps1-macos/test.sh
```

Expected:

| Command | Expected |
|---|---|
| `zig fmt --check` | clean |
| `zig build test` | 15 binaries pass |
| `test-roms-pl` | pass — **unchanged floors**, do not re-pin |
| `test-roms-ja` | 12/17, the same five failures |
| `trace-golden verify` | OK on all ten workloads — **no recapture** |
| `trace-golden stream-verify` | OK |
| `trace-golden pgxp` | every workload at or above its floor, 0 displacement violations |
| `ps1-macos/test.sh` | 245 + 2 new tests pass |

**The single most important line in this table is `trace-golden verify`.** It
is the evidence that a feature which deliberately changes rendered output costs
nothing when it is off. If it moves at any point, the answer is never to
recapture — it is that one of Tasks 2-4 changed the integer path.

## Notes for the executor

- **Do NOT add any of the new fields to `ps1-golden/src/state_hash.zig`.**
  Its dumps are written by hand precisely so the check polices a refactor
  instead of following it, and CLAUDE.md's standing rule is that a field which
  moves gets its dump updated in the same commit — so the instinct here is to
  add `gpr_shadow`, `ram_shadow`, `precise_sxy` and `Gp0Engine.pgxp`. Don't.
  They are host-side derived state, excluded on the same grounds as
  `cdrom.pending_cycles` and `cdrom.debug_enable`: with PGXP off they are
  always zero and hashing 8.4 MB per sample would cost the sweep dearly, and with
  PGXP on there is no golden to compare against anyway. Their coverage is
  `trace-golden -- pgxp`.
- **Tasks 1-3 cannot change rendered output**, by construction: they add state
  nobody reads. If a gate moves during them, a hook disturbed the integer path
  — most likely `rOpMove` mis-dispatching an opcode, or `writeRegPrecise`
  reordering the load-delay cancel in `writeReg`.
- **Never make the identity predicate an assertion.** It is the fallback. A
  vertex that fails it uses the integer coordinate silently — no
  `unreachable`, no panic, and no per-vertex logging (a busy frame carries tens
  of thousands of vertices).
- **Do not add invalidation hooks beyond the three in Task 2** without a
  measurement showing the hit-rate needs them. The predicate makes missed
  invalidation a coverage cost, not a correctness one, and every hook is on a
  hot path.
- **`ps1-trace` is how you look at a real game**, with `explore` past 600M
  instructions. If you want to see PGXP working rather than counted, that is
  the tool — but nothing in this plan gates on it.
- **`PS1_LIVE_DIFF=1` will be loud with PGXP on above 1×** and that is expected
  for two independent reasons already documented in CLAUDE.md: the software
  shadow always dithers while the Metal shader gates dithering on `s == 1`, and
  now the shadow's sub-pixel coverage differs from a scaled subtexel's. Read
  its `checked/skipped` tally before reading anything into it.
