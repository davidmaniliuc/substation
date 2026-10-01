# PGXP Phase 6 — Preserve Projection Precision Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add DuckStation's last missing PGXP setting, `preserve_projection`. Under it, the GTE's float projection reads the exact MAC accumulator instead of the hardware-rounded IR1/IR2/SZ3. It ships OFF.

**Architecture:** The setting rides `pgxp.Config` into the GTE (because `Cop2` cannot reach `Bus`). `doPerspectiveTransform` swaps three inputs to the float projection it already computes, using the exact value only where the register is that value's floor. Then it is plumbed through the C ABI, the macOS Video menu and the `ps1-golden` coverage instruments, exactly as `pgxp_disable_2d` is.

**Tech Stack:** Zig 0.16.0 (core, C ABI, harnesses), Swift/SwiftUI with swift-testing (macOS app), `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-10-01-pgxp-phase-6-preserve-projection-design.md`

## Global Constraints

- `zig version` must be 0.16.0. Run every command from the repo root.
- The setting ships **OFF**. A default-OFF `Bus` flag must **NOT** be assigned in `Bus.init`.
- With the setting off, or with PGXP off, every precise value is bit-identical to today's. No GTE register or FLAG bit moves either way.
- `trace-golden -- verify` and `-- stream-verify` must not move. A moved golden is a gating bug, never a recapture.
- Every `trace-golden` / `fixtures` run is `-Doptimize=ReleaseFast`.
- A re-pin of `ps1-core/tests/goldens/pgxp/floors.txt` is **its own commit**.
- Commit messages are a **title line only**: no body, no trailer. Commit directly on `master`. **Never `git push`.**
- `pkill -x Substation` before running the Swift suite.
- Run `zig fmt` on every touched `.zig` file before committing.
- Match the surrounding style. Comments state the rule and its reason, not a narration of the change.

## Review Focus

1. **A negative coordinate with a fraction.** The hardware truncates with an arithmetic shift (floor), not toward zero. `-451.5` has register `-452`, and must be refined to `-451.5`, not left at `-452` or turned into `-451`. Pinned in Task 1.
2. **A saturated IR under `lm = 1`.** A negative input saturates IR1 to 0. The float must project from 0, not from the exact negative value. Pinned in Task 1.
3. **RTPT.** All three vertices must be refined from their OWN accumulators, not from the last one. Pinned in Task 1.
4. **The master flag off.** The raw field set true with PGXP off must do nothing. Pinned in Task 1 (Bus) and Task 2 (ABI).
5. **`ps1_reset`.** A player's choice must survive a reset. That snapshot already lost `texture_correction` once. Pinned in Task 2.

---

### Task 1: The core — the setting and the projection

**Files:**
- Modify: `ps1-core/src/pgxp/pgxp.zig:30-36` (`Config`)
- Modify: `ps1-core/src/cop2/opcodes.zig:1-176` (`doPerspectiveTransform`, `opRtps`, `opRtpt`)
- Modify: `ps1-core/src/cop2/cop2.zig:368,386` (dispatch)
- Modify: `ps1-core/src/memory.zig:155-158` (field), `:497-503` (`pgxpConfig`)
- Test: `ps1-core/tests/pgxp_test.zig` (new tests appended after the test `"a projection with no depth records nothing rather than a NaN"`, around line 290)

**Interfaces:**
- Produces: `pgxp.Config.preserve_projection: bool = false`; `Bus.pgxp_preserve_projection: bool = false`; `Bus.pgxpConfig()` returns it folded with `pgxp_enabled`; `opcodes.opRtps(cop2: *Cop2, sf: u6, lm: bool, pgxp: PgxpConfig) void` and `opcodes.opRtpt` with the same signature.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/pgxp_test.zig` right after the test `"a projection with no depth records nothing rather than a NaN"`:

```zig
// ---------------------------------------------------------------------------
// Preserve projection precision (Phase 6).

const preserve_on: pgxp.Config = .{ .preserve_projection = true };

/// A GTE with a diagonal rotation and no translation, so each IR is one
/// matrix entry times one input. At 1.5 (0x1800 in 4.12) an odd input leaves
/// exactly .5 in the accumulator below the register's truncation, which is
/// what the setting exists to keep.
fn stageDiagonal(cop2: *Cop2, rt11: i16, rt22: i16, rt33: i16, vx: i16, vy: i16, vz: i16, h: u16) void {
    cop2.writeCtrl(0, @as(u32, @as(u16, @bitCast(rt11))));
    cop2.writeCtrl(1, 0);
    cop2.writeCtrl(2, @as(u32, @as(u16, @bitCast(rt22))));
    cop2.writeCtrl(3, 0);
    cop2.writeCtrl(4, @as(u32, @as(u16, @bitCast(rt33))));
    cop2.writeCtrl(5, 0);
    cop2.writeCtrl(6, 0);
    cop2.writeCtrl(7, 0);
    cop2.writeCtrl(24, 0);
    cop2.writeCtrl(25, 0);
    cop2.writeCtrl(26, h);
    cop2.writeCtrl(27, 0);
    cop2.writeCtrl(28, 0);
    cop2.writeData(0, (@as(u32, @as(u16, @bitCast(vy))) << 16) | @as(u32, @as(u16, @bitCast(vx))));
    cop2.writeData(1, @as(u32, @as(u16, @bitCast(vz))));
}

const rtps_sf12: u32 = 0x4A08_0001;
const rtps_sf12_lm: u32 = 0x4A08_0401;
const rtps_sf0: u32 = 0x4A00_0001;

// 1.5 * 301 = 451.5 and 1.5 * 1001 = 1501.5: the registers read 451 and 1501.
test "preserve projection off projects from the rounded registers" {
    var cop2 = Cop2.init();
    stageDiagonal(&cop2, 0x1800, 0x1000, 0x1800, 301, 0, 1001, 1000);
    cop2.executeCommand(rtps_sf12, .{});

    const p = cop2.readPreciseData(14);
    try expectApproxEqAbs(@as(f32, 451.0 * 1000.0 / 1501.0), p.x, 0.0005);
    try expectApproxEqAbs(@as(f32, 1501.0), p.z, 0.0);
}

test "preserve projection on projects from the exact accumulator" {
    var cop2 = Cop2.init();
    stageDiagonal(&cop2, 0x1800, 0x1000, 0x1800, 301, 0, 1001, 1000);
    cop2.executeCommand(rtps_sf12, preserve_on);

    const p = cop2.readPreciseData(14);
    try expectEqual(Value.valid_xyz, p.flags);
    // Still recorded against the register word: the identity check is untouched.
    try expectEqual(cop2.readData(14), p.word);
    try expectApproxEqAbs(@as(f32, 451.5 * 1000.0 / 1501.5), p.x, 0.0005);
    // The depth term gains its fraction too, which is what reaches `w`.
    try expectApproxEqAbs(@as(f32, 1501.5), p.z, 0.0);
}

// The hardware truncates with an arithmetic shift, so -451.5 reads -452. The
// fraction is kept relative to THAT floor, never toward zero.
test "preserve projection refines a negative coordinate from its floor" {
    var cop2 = Cop2.init();
    stageDiagonal(&cop2, 0x1800, 0x1000, 0x1800, -301, 0, 1001, 1000);
    cop2.executeCommand(rtps_sf12, preserve_on);

    try expectEqual(@as(i16, -452), Cop2.asI16(cop2.readData(9)));
    try expectApproxEqAbs(@as(f32, -451.5 * 1000.0 / 1501.5), cop2.readPreciseData(14).x, 0.0005);
}

// With sf = 0 the IRs ARE the accumulator, so only Z can move -- and with a
// depth that is a whole number, nothing does.
test "preserve projection leaves sf=0 X and Y alone" {
    var off = Cop2.init();
    var on = Cop2.init();
    stageDiagonal(&off, 1, 1, 0x1000, 300, 200, 1234, 1000);
    stageDiagonal(&on, 1, 1, 0x1000, 300, 200, 1234, 1000);
    off.executeCommand(rtps_sf0, .{});
    on.executeCommand(rtps_sf0, preserve_on);

    try expectEqual(off.readPreciseData(14), on.readPreciseData(14));
}

// A saturated register is what hardware projected from, so the float takes it
// as-is. The exact value would place the vertex where the wire never did.
test "preserve projection projects a saturated IR from the register" {
    // 7FFFh * 8000 / 4096 = 63998: IR1 saturates high (lm=0).
    var off = Cop2.init();
    var on = Cop2.init();
    stageDiagonal(&off, 0x7FFF, 0x1000, 0x1000, 8000, 0, 32000, 100);
    stageDiagonal(&on, 0x7FFF, 0x1000, 0x1000, 8000, 0, 32000, 100);
    off.executeCommand(rtps_sf12, .{});
    on.executeCommand(rtps_sf12, preserve_on);
    try expectEqual(@as(u32, 1 << 24), on.readCtrl(31) & (1 << 24)); // IR1 saturated
    try expectEqual(off.readPreciseData(14), on.readPreciseData(14));

    // And under lm=1 a negative input saturates to 0, not to -8000h.
    var off_lm = Cop2.init();
    var on_lm = Cop2.init();
    stageDiagonal(&off_lm, 0x1800, 0x1000, 0x1800, -301, 0, 1001, 1000);
    stageDiagonal(&on_lm, 0x1800, 0x1000, 0x1800, -301, 0, 1001, 1000);
    off_lm.executeCommand(rtps_sf12_lm, .{});
    on_lm.executeCommand(rtps_sf12_lm, preserve_on);
    try expectEqual(@as(i16, 0), Cop2.asI16(on_lm.readData(9)));
    try expectEqual(off_lm.readPreciseData(14).x, on_lm.readPreciseData(14).x);
}

// The setting is an enhancement, never a behaviour change: the game reads the
// registers, and they must not know which input the float used.
test "preserve projection moves no GTE register and refines every RTPT vertex" {
    var off = Cop2.init();
    var on = Cop2.init();
    for ([_]*Cop2{ &off, &on }) |c| {
        stageDiagonal(c, 0x1800, 0x1800, 0x1800, 301, 101, 1001, 1000);
        c.writeData(2, (@as(u32, 103) << 16) | 303); // VXY1
        c.writeData(3, 1003); // VZ1
        c.writeData(4, (@as(u32, 105) << 16) | 305); // VXY2
        c.writeData(5, 1005); // VZ2
    }
    off.executeCommand(0x4A28_0030, .{}); // RTPT, sf=1
    on.executeCommand(0x4A28_0030, preserve_on);

    try std.testing.expectEqualSlices(u32, &off.data_regs, &on.data_regs);
    try std.testing.expectEqualSlices(u32, &off.ctrl_regs, &on.ctrl_regs);
    // Each slot from its own accumulator: 1.5 * {1001, 1003, 1005}.
    try expectApproxEqAbs(@as(f32, 1501.5), on.readPreciseData(12).z, 0.0);
    try expectApproxEqAbs(@as(f32, 1504.5), on.readPreciseData(13).z, 0.0);
    try expectApproxEqAbs(@as(f32, 1507.5), on.readPreciseData(14).z, 0.0);
}

test "preserve projection defaults off and is unreachable while PGXP is off" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    try std.testing.expect(!bus.pgxp_preserve_projection);

    bus.pgxp_preserve_projection = true;
    try std.testing.expect(!bus.pgxpConfig().preserve_projection);
    bus.setPgxp(true);
    try std.testing.expect(bus.pgxpConfig().preserve_projection);
}
```

`Bus` is declared further down this file (`const Bus = ps1_core.memory.Bus;`, around line 335). Zig resolves container-level declarations regardless of order, so the last test can use it.

The RTPT opcode word: `0x4A28_0030` is RTPT (0x30) with sf=1 (bit 19) and the COP2 command prefix. Check it against `cop2.zig`'s decode before relying on it: `instruction & 0x3F == 0x30`, `(instruction >> 19) & 1 == 1`, `(instruction >> 10) & 1 == 0`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test -Dtest-filter="preserve projection"`
Expected: compile error, `no field named 'preserve_projection' in struct 'pgxp.Config'`.

- [ ] **Step 3: Add the setting to `pgxp.Config`**

In `ps1-core/src/pgxp/pgxp.zig`, extend `Config`:

```zig
pub const Config = struct {
    /// The position-keyed table, or null when it or PGXP is off.
    vertex_cache: ?*cache.VertexCache = null,
    /// Float NCLIP. Defaults false HERE and true on `Bus` — this is the
    /// value for a caller that named nothing, which must be no correction.
    culling: bool = false,
    /// Project from the exact MAC accumulator rather than the rounded
    /// IR1/IR2/SZ3. Off here and on `Bus` alike.
    preserve_projection: bool = false,
};
```

- [ ] **Step 4: Thread `Config` through the projection**

In `ps1-core/src/cop2/opcodes.zig`, replace the `VertexCache` import with the config's (keep `Value`):

```zig
const Value = @import("../pgxp/pgxp.zig").Value;
const PgxpConfig = @import("../pgxp/pgxp.zig").Config;
```

Check that nothing else in the file still names `VertexCache` before you drop that import (`grep -n VertexCache ps1-core/src/cop2/opcodes.zig`).

Change the signature of `doPerspectiveTransform` from `vertex_cache: ?*VertexCache` to `pgxp: PgxpConfig`, and its cache insert to `if (pgxp.vertex_cache) |c| c.put(@bitCast(sxy2), cop2.precise[14]);`.

Change `opRtps` and `opRtpt` the same way: the last parameter becomes `pgxp: PgxpConfig`, passed straight to `doPerspectiveTransform`.

In `ps1-core/src/cop2/cop2.zig`:

```zig
            0x01 => opcodes.opRtps(self, sf, lm, pgxp),
```
```zig
            0x30 => opcodes.opRtpt(self, sf, lm, pgxp),
```

- [ ] **Step 5: Swap the projection's inputs**

In `opcodes.zig`, add this helper above `doPerspectiveTransform`:

```zig
/// One input to the float projection. The register by default; under
/// `preserve` the exact accumulator it was truncated from — but only where
/// the register IS that truncation. A register that saturated, a MAC that
/// wrapped on its narrowing to 32 bits, or an SZ3 that clamped is what
/// hardware projected from, so the float takes it as-is; that is also what
/// keeps the saturation rejection below meaningful. `>>` is the hardware's own
/// truncation, a floor, so a negative fraction is kept relative to it.
fn projectionInput(register: i64, acc: i64, shift: u6, preserve: bool) f32 {
    if (preserve and acc >> shift == register) {
        const scale: f64 = @floatFromInt(@as(i64, 1) << shift);
        return @floatCast(@as(f64, @floatFromInt(acc)) / scale);
    }
    return @floatFromInt(register);
}
```

Then in `doPerspectiveTransform`, replace the float-projection block (from `const hf: f32 = @floatFromInt(h);` to the end of the `cop2.precise[14] = ... else Value.none;` expression) so it reads its three inputs through the helper. The surrounding comments stay as they are.

```zig
    const hf: f32 = @floatFromInt(h);
    const ir1f = projectionInput(ir1, result[0], sf, pgxp.preserve_projection);
    const ir2f = projectionInput(ir2, result[1], sf, pgxp.preserve_projection);
    const sz3f = projectionInput(sz3, result[2], 12, pgxp.preserve_projection);
    const zf = @max(hf / 2.0, sz3f);
    cop2.precise[14] = if (x == sxy2.x and y == sxy2.y and zf > 0.0) blk: {
        const h_div_z = @min(hf / zf, 131071.0 / 65536.0);
        break :blk .{
            .x = std.math.clamp(ir1f * h_div_z + @as(f32, @floatFromInt(ofx)) / 65536.0, -1024.0, 1023.0),
            .y = std.math.clamp(ir2f * h_div_z + @as(f32, @floatFromInt(ofy)) / 65536.0, -1024.0, 1023.0),
            .z = zf,
            .word = @bitCast(sxy2),
            .flags = Value.valid_xyz,
        };
    } else Value.none;
```

Keep the two existing comment blocks: the long one above `const hf` and the "A divisor of zero" one inside the `else` arm. Only the expressions change. `sz3` at this point is the clamped `i64` that was written to `data_regs[19]`, and `ir1`/`ir2` are the `i64` register reads already in scope.

- [ ] **Step 6: Add the `Bus` field and fold it into `pgxpConfig`**

In `ps1-core/src/memory.zig`, after `pgxp_disable_2d: bool = false,`:

```zig
    /// Project from the exact MAC accumulator instead of the rounded
    /// IR1/IR2/SZ3, gated by `pgxp_enabled` above. OFF by default, the
    /// reference's own default. Default-OFF, so NOT assigned in `init`.
    pgxp_preserve_projection: bool = false,
```

And in `pgxpConfig`:

```zig
    pub inline fn pgxpConfig(self: *const Self) pgxp.Config {
        if (!self.pgxp_enabled) return .{};
        return .{
            .vertex_cache = self.pgxp_vertex_cache,
            .culling = self.pgxp_culling,
            .preserve_projection = self.pgxp_preserve_projection,
        };
    }
```

Do **not** add anything to `Bus.init`.

- [ ] **Step 7: Run the new tests to verify they pass**

Run: `zig build test -Dtest-filter="preserve projection"`
Expected: all 7 tests PASS.

If `"preserve projection off projects from the rounded registers"` fails, the off path is no longer identical to before. Fix that before anything else.

- [ ] **Step 8: Run the full unit suite once**

Run: `zig build test`
Expected: PASS. In particular every existing RTPS test in `pgxp_test.zig` and `gte_test.zig` is unchanged.

- [ ] **Step 9: Run the behaviour-freeze gates**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- verify && zig build trace-golden -Doptimize=ReleaseFast -- stream-verify`
Expected: both green, with no golden moved. With PGXP off nothing reads the setting. A failure here is a gating bug in Steps 4-6. Never recapture.

- [ ] **Step 10: Format and commit**

```bash
zig fmt ps1-core/src/pgxp/pgxp.zig ps1-core/src/cop2/opcodes.zig ps1-core/src/cop2/cop2.zig ps1-core/src/memory.zig ps1-core/tests/pgxp_test.zig
git add ps1-core/src/pgxp/pgxp.zig ps1-core/src/cop2/opcodes.zig ps1-core/src/cop2/cop2.zig ps1-core/src/memory.zig ps1-core/tests/pgxp_test.zig
git commit -m "feat(pgxp): preserve projection precision projects from the exact accumulator"
```

---

### Task 2: The C ABI

**Files:**
- Modify: `ps1-capi/include/ps1.h:359-361` (after `ps1_set_pgxp_disable_2d`)
- Modify: `ps1-capi/src/root.zig:122-160` (reset snapshot), `:489-493` (setter, after `ps1_set_pgxp_disable_2d`)
- Test: `ps1-capi/src/capi_test.zig` (append after `"Phase5: ps1_reset keeps the three depth settings"`, around line 953)

**Interfaces:**
- Consumes: `Bus.pgxp_preserve_projection`, `Bus.pgxpConfig().preserve_projection` (Task 1).
- Produces: `void ps1_set_pgxp_preserve_projection(Ps1*, int enabled);` (Zig: `pub export fn ps1_set_pgxp_preserve_projection(h: *Handle, enabled: c_int) void`).

- [ ] **Step 1: Write the failing tests**

Append to `ps1-capi/src/capi_test.zig`:

```zig
test "Phase6: preserve projection crosses the ABI, defaults off and folds in the master flag" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    try std.testing.expect(!h.cpu.bus.pgxp_preserve_projection);
    capi.ps1_set_pgxp_preserve_projection(h, 1);
    try std.testing.expect(h.cpu.bus.pgxp_preserve_projection);
    try std.testing.expect(!h.cpu.bus.pgxpConfig().preserve_projection); // PGXP itself is off

    capi.ps1_set_pgxp(h, 1);
    try std.testing.expect(h.cpu.bus.pgxpConfig().preserve_projection);
}

test "Phase6: ps1_reset keeps preserve projection" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    capi.ps1_set_pgxp_preserve_projection(h, 1);
    capi.ps1_reset(h);
    try std.testing.expect(h.cpu.bus.pgxp_preserve_projection);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test -Dtest-filter="Phase6"`
Expected: compile error, `root struct of file 'root' has no member named 'ps1_set_pgxp_preserve_projection'` (or equivalent).

- [ ] **Step 3: Add the header declaration**

In `ps1-capi/include/ps1.h`, after `ps1_set_pgxp_disable_2d`:

```c
/* Project from the GTE's exact accumulator instead of its rounded IR1/IR2/SZ3.
 * OFF by default, gated on ps1_set_pgxp. Changes no GTE register. */
void    ps1_set_pgxp_preserve_projection(Ps1*, int enabled);
```

- [ ] **Step 4: Add the setter**

In `ps1-capi/src/root.zig`, after `ps1_set_pgxp_disable_2d`:

```zig
/// Project from the GTE's exact accumulator instead of its rounded
/// IR1/IR2/SZ3. OFF by default, gated on `ps1_set_pgxp`.
pub export fn ps1_set_pgxp_preserve_projection(h: *Handle, enabled: c_int) void {
    h.cpu.bus.pgxp_preserve_projection = enabled != 0;
}
```

- [ ] **Step 5: Carry it across `ps1_reset`**

In `root.zig`'s reset, add `preserve_projection: bool` to the end of the `pgxp_was` struct type, `.preserve_projection = h.bus.pgxp_preserve_projection,` to its initializer after `.disable_2d`, and after `h.bus.pgxp_disable_2d = pgxp_was.disable_2d;`:

```zig
    h.bus.pgxp_preserve_projection = pgxp_was.preserve_projection;
```

It must be assigned before `h.bus.setPgxp(pgxp_was.on);`, which the existing comment says comes last.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `zig build test -Dtest-filter="Phase6"`
Expected: both PASS.

- [ ] **Step 7: Build the library the app links**

Run: `zig build capi-lib`
Expected: builds `zig-out/lib/libps1core.a` with no error.

- [ ] **Step 8: Format and commit**

```bash
zig fmt ps1-capi/src/root.zig ps1-capi/src/capi_test.zig
git add ps1-capi/include/ps1.h ps1-capi/src/root.zig ps1-capi/src/capi_test.zig
git commit -m "feat(capi): ps1_set_pgxp_preserve_projection"
```

---

### Task 3: The macOS app

**Files:**
- Modify: `ps1-macos/Sources/PS1/PgxpSetting.swift` (property after `disable2d` ~line 69; key ~line 79; init ~line 99; setter at the end)
- Modify: `ps1-macos/Sources/PS1/Ps1Core.swift:168` (after `setPgxpDisable2d`)
- Modify: `ps1-macos/Sources/PS1/EmulatorRunner.swift:88` (atomic), `:224-226` (setter), `:458` (per-frame apply)
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift:233-238` (property), `:587-596` (re-apply on start)
- Modify: `ps1-macos/Sources/PS1App/VideoCommands.swift:57-60` (toggle)
- Test: `ps1-macos/Tests/PS1Tests/PgxpSettingTests.swift`

**Interfaces:**
- Consumes: `ps1_set_pgxp_preserve_projection(Ps1*, int)` (Task 2).
- Produces: `PgxpSetting.preserveProjection: Bool`, `PgxpSetting.setPreserveProjection(_:)`, `Ps1Core.setPgxpPreserveProjection(_:)`, `EmulatorRunner.setPgxpPreserveProjection(_:)`, `EmulatorViewModel.pgxpPreserveProjection: Bool`.

- [ ] **Step 1: Write the failing tests**

In `ps1-macos/Tests/PS1Tests/PgxpSettingTests.swift`, find the round-trip test that calls `s.setDisable2d(true)` and then `#expect(reloaded.disable2d == true)` (~lines 95-117). Add `s.setPreserveProjection(true)` after `s.setDisable2d(true)` and `#expect(reloaded.preserveProjection == true)` after `#expect(reloaded.disable2d == true)`. Each setting is set away from its own default there, so a key collision shows up.

Then append inside `struct PgxpSettingTests`, after `theDepthSettingsDefaultOffAndPersist`:

```swift
    /// Preserve projection ships OFF, the reference's own default, and
    /// persists on its own key.
    @Test func preserveProjectionDefaultsOffAndPersists() {
        let d = scratchDefaults("pgxp.preserveProjection")
        var s = PgxpSetting(key: "pgxpEnabled", defaults: d)
        #expect(!s.preserveProjection)
        s.setPreserveProjection(true)
        #expect(PgxpSetting(key: "pgxpEnabled", defaults: d).preserveProjection)
    }
```

`scratchDefaults` is the helper `theDepthSettingsDefaultOffAndPersist` already uses. Check its signature in the same file.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pkill -x Substation; zig build capi-lib && zig build metallib && ps1-macos/test.sh`
Expected: build failure, `value of type 'PgxpSetting' has no member 'setPreserveProjection'`.

- [ ] **Step 3: Add the setting to `PgxpSetting`**

After `private(set) var disable2d: Bool`:

```swift
    /// Project from the GTE's exact accumulator instead of its rounded
    /// registers. OFF by default, the reference's own.
    private(set) var preserveProjection: Bool
```

After `private var disable2dKey`:

```swift
    private var preserveProjectionKey: String { key + ".preserveProjection" }
```

At the end of `init`, after `self.disable2d = ...`:

```swift
        self.preserveProjection =
            (defaults.object(forKey: key + ".preserveProjection") as? NSNumber)?.boolValue ?? false
```

After `setDisable2d`:

```swift
    mutating func setPreserveProjection(_ value: Bool) {
        preserveProjection = value
        defaults.set(value, forKey: preserveProjectionKey)
    }
```

- [ ] **Step 4: Bridge it in `Ps1Core`**

After `func setPgxpDisable2d`:

```swift
    func setPgxpPreserveProjection(_ enabled: Bool) {
        ps1_set_pgxp_preserve_projection(handle, enabled ? 1 : 0)
    }
```

- [ ] **Step 5: Carry it on the emulation thread in `EmulatorRunner`**

After `private let pgxpDisable2d = Atomic<Bool>(false)`:

```swift
    private let pgxpPreserveProjection = Atomic<Bool>(false)
```

After `func setPgxpDisable2d(_:)`:

```swift
    func setPgxpPreserveProjection(_ enabled: Bool) {
        pgxpPreserveProjection.store(enabled, ordering: .releasing)
    }
```

In the run loop, after `core.setPgxpDisable2d(pgxpDisable2d.load(ordering: .acquiring))`:

```swift
            core.setPgxpPreserveProjection(pgxpPreserveProjection.load(ordering: .acquiring))
```

Then update the comment just below it, `// Not re-applied blindly like the eight above:`, to say `nine`.

- [ ] **Step 6: Expose it on the view model**

In `EmulatorViewModel.swift`, after the `pgxpDisable2d` property:

```swift
    public var pgxpPreserveProjection: Bool {
        get { pgxpSetting.preserveProjection }
        set {
            pgxpSetting.setPreserveProjection(newValue)
            runner?.setPgxpPreserveProjection(newValue)
        }
    }
```

In the start path, after `runner.setPgxpDisable2d(pgxpSetting.disable2d)`:

```swift
            runner.setPgxpPreserveProjection(pgxpSetting.preserveProjection)
```

Update the comment above that block, `// All ten, for the same reason:`, to say `All eleven`. Without this line a player's choice is dropped on the second disc. No test reaches that path, so check it by reading.

- [ ] **Step 7: Add the menu entry**

In `VideoCommands.swift`, inside the `Group` greyed by `.disabled(!model.pgxpEnabled)`, after the `PGXP Culling Correction` toggle:

```swift
                Toggle("PGXP Preserve Projection Precision", isOn: $model.pgxpPreserveProjection)
```

- [ ] **Step 8: Run the Swift suite**

Run: `pkill -x Substation; ps1-macos/test.sh`
Expected: `** TEST SUCCEEDED **`, including `preserveProjectionDefaultsOffAndPersists` and the extended round-trip test. If generated fixtures are missing, four fixture gates skip; Task 4 runs them.

- [ ] **Step 9: See it in the real app**

Run: `zig build macos && open zig-out/Substation.app`
Expected: Video ▸ "PGXP Preserve Projection Precision" sits greyed while "PGXP Geometry Correction" is off, and becomes clickable once it is on. Quit the app afterwards (`pkill -x Substation`).

- [ ] **Step 10: Commit**

```bash
git add ps1-macos/Sources/PS1/PgxpSetting.swift ps1-macos/Sources/PS1/Ps1Core.swift ps1-macos/Sources/PS1/EmulatorRunner.swift ps1-macos/Sources/PS1/EmulatorViewModel.swift ps1-macos/Sources/PS1App/VideoCommands.swift ps1-macos/Tests/PS1Tests/PgxpSettingTests.swift
git commit -m "feat(macos): PGXP Preserve Projection Precision in the Video menu"
```

---

### Task 4: The coverage instruments — force it on, measure, re-pin

**Files:**
- Modify: `ps1-golden/src/main.zig:549-554` (the `pgxp` sweep's forced settings), `:830-837` (`--pgxp-on`)
- Modify (only if the sweep fails a floor): `ps1-core/tests/goldens/pgxp/floors.txt`
- Output (gitignored): `zig-out/phase6-sweep-before.txt`, `zig-out/phase6-sweep-after.txt`

**Interfaces:**
- Consumes: `Bus.pgxp_preserve_projection` (Task 1).
- Produces: the two sweep transcripts Task 5 quotes.

- [ ] **Step 1: Record the baseline sweep**

The setting is not forced yet, so this is today's numbers.

Run: `zig build trace-golden -Doptimize=ReleaseFast -- pgxp 2>&1 | tee zig-out/phase6-sweep-before.txt`
Expected: green, as on `master`.

- [ ] **Step 2: Force the setting in both instruments**

In `ps1-golden/src/main.zig`, in the `pgxp` sweep after `bus.setPgxpDisable2d(true);`:

```zig
    bus.pgxp_preserve_projection = true;
```

In the `--pgxp-on` block after `bus.setPgxpDisable2d(opts.pgxp_on);`:

```zig
    bus.pgxp_preserve_projection = opts.pgxp_on;
```

This is a plain field assignment, like `bus.pgxp_cpu`, because there is no `gp0` mirror to keep in step. The comments above both blocks already say every correction sub-setting is forced on; leave them as they are.

- [ ] **Step 3: Run the sweep with it forced**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- pgxp 2>&1 | tee zig-out/phase6-sweep-after.txt`

Expected: the identity invariant holds on every workload. Per-game counters may move, because the setting is not lockstep: float NCLIP reads the precise X/Y and writes MAC0, which the game reads.

- If it is green: go to Step 5, no re-pin.
- If the identity invariant fails anywhere: STOP. That is a bug in Task 1, not a floor to move.
- If only floors fail: Step 4.

- [ ] **Step 4 (only if floors failed): Re-pin `floors.txt` in its own commit**

For each failing line, read the comment block above that group in `floors.txt` to learn which way it ratchets (a hit-rate floor, a `perspective`/`color`/`depth` FLOOR, a `clamped` bound). Re-pin to the measured value from `zig-out/phase6-sweep-after.txt` using that block's stated rounding rule. Add a dated comment line above the group: `# Re-pinned 2026-10-01 for Phase 6: the sweep forces preserve_projection on.` Then rerun Step 3's command and confirm green.

First commit only the instrument change:

```bash
zig fmt ps1-golden/src/main.zig
git add ps1-golden/src/main.zig
git commit -m "test(pgxp): the sweep and --pgxp-on force preserve projection on"
```

Then the re-pin on its own:

```bash
git add ps1-core/tests/goldens/pgxp/floors.txt
git commit -m "test(pgxp): re-pin floors for preserve projection forced on"
```

Then skip Step 5's commit.

- [ ] **Step 5 (only if no re-pin was needed): Commit**

```bash
zig fmt ps1-golden/src/main.zig
git add ps1-golden/src/main.zig
git commit -m "test(pgxp): the sweep and --pgxp-on force preserve projection on"
```

- [ ] **Step 6: Recapture the fixtures and run the parity gate**

`tr1-usa-v1-1-pgxp.p1fx` is captured with `--pgxp-on`, so it now carries the setting.

Run: `zig build fixtures -Doptimize=ReleaseFast && zig build capi-lib && zig build metallib && pkill -x Substation; ps1-macos/test.sh`
Expected: `** TEST SUCCEEDED **`, with no fixture gate skipped. The Metal-vs-software parity gate on `tr1-usa-v1-1-pgxp.p1fx` stays a strict equality. Fixtures live in `zig-out/` and are not committed.

---

### Task 5: The docs

**Files:**
- Modify: `CLAUDE.md` (the PGXP rules, ~line 333)
- Modify: `.claude/skills/ps1-pgxp/SKILL.md` (line 14's sub-settings paragraph; a new section at the end)
- Modify: `docs/superpowers/specs/2026-09-09-pgxp-duckstation-parity-audit.md` (the "Projection source" row, ~line 128; "Fork 1", ~line 147)

**Interfaces:**
- Consumes: `zig-out/phase6-sweep-before.txt` and `zig-out/phase6-sweep-after.txt` (Task 4); whether Task 4 re-pinned.

- [ ] **Step 1: CLAUDE.md**

In the PGXP rule beginning `**Each of the nine sub-settings folds in the master flag in exactly ONE`, change `nine` to `ten`. Change `` `Bus.pgxpConfig` (culling and the vertex cache, on their way to the GTE) `` to `` `Bus.pgxpConfig` (culling, the vertex cache and preserve projection, on their way to the GTE) ``.

In the rule beginning `` **`pgxp_color_correction`, `pgxp_depth_buffer`, `pgxp_transparent_depth` and `pgxp_disable_2d` all ship OFF ``, add `` `pgxp_preserve_projection` `` to the list (making it "…`pgxp_disable_2d` and `pgxp_preserve_projection` all ship OFF").

Add one new rule bullet to the PGXP list, after the tolerance rule (`**The tolerance check runs BEFORE `toFixed`'s clamp.**`):

```markdown
- **Preserve projection refines an input only where the register is its
  floor** (`acc >> shift == register`). A saturated IR, a wrapped MAC or a
  clamped SZ3 is what hardware projected from, so the float takes the register
  as-is; a second set of saturation bounds would disagree with the saturation
  rejection beside it. It changes no GTE register, and it is NOT lockstep:
  float NCLIP feeds the precise X/Y back to the game through MAC0.
```

- [ ] **Step 2: The `ps1-pgxp` skill**

Line 14's paragraph says `**Six sub-settings hang off it**` and lists six. That is already stale. Rewrite its opening so it names all ten: `pgxp_cpu`, `pgxp_culling`, `pgxp_vertex_cache`, `pgxp_tolerance`, `pgxp_texture_correction` (Phase 3), `pgxp_color_correction` (Phase 4), `pgxp_depth_buffer`, `pgxp_transparent_depth`, `pgxp_disable_2d` (Phase 5) and `pgxp_preserve_projection` (Phase 6). Add that `Bus.pgxpConfig` carries preserve projection to the GTE alongside culling and the vertex cache. Leave the rest of the paragraph's reasoning intact.

Append a new section at the end of the file:

```markdown
## Phase 6: preserve projection precision (2026-10-01)

**The last DuckStation setting, and a smaller change than the audit
predicted.** `pgxp_preserve_projection`, default OFF, folded into
`Bus.pgxpConfig` with culling and the vertex cache. The audit's Fork 1
assumed we projected from MAC0 and DuckStation in float; by Phase 6 we
already did DuckStation's float projection, so the setting swaps three inputs
and nothing else.

**The rule: the exact accumulator, only where the register is its floor.**
`projectionInput` (`cop2/opcodes.zig`) uses `acc / 2^shift` when
`acc >> shift == register`, and the register otherwise. That covers
saturation under either `lm`, a MAC that wrapped narrowing to 32 bits, and
SZ3's clamp, with no second set of bounds. DuckStation clamps its float
instead, and its `lm` bounds are inverted from the hardware's. With `sf = 0`
the IRs already are the accumulator, so only Z gains a fraction.

**What it can and cannot change.** No GTE register or FLAG bit (pinned by
`"preserve projection moves no GTE register and refines every RTPT vertex"`).
The position is still pinned inside the wire's pixel by `toFixed`, so the
visible effect is sub-pixel placement and the depth term `w`, which is never
clamped. **Not lockstep**: float NCLIP reads the precise X/Y and writes MAC0.

**MEASURED 2026-10-01** (`trace-golden -- pgxp`, the setting forced on vs the
same sweep without it):

<a table per workload: resolved, clamped, drift_far, drift_max (peak px),
perspective, color — before and after — copied from
zig-out/phase6-sweep-before.txt and zig-out/phase6-sweep-after.txt>

<one paragraph: which floors were re-pinned (or "none"), and which way
drift_far/drift_max moved and on which workloads, stated as measured>
```

Replace the two `<...>` lines with the actual table and paragraph built from the two transcripts. Build the table from the numbers and don't characterise them beyond what they show. If a column didn't move, say so.

- [ ] **Step 3: Correct the parity audit**

In `docs/superpowers/specs/2026-09-09-pgxp-duckstation-parity-audit.md`:

Change the "Projection source" row's right-hand cell to: `**Same since Phase 2**: a float projection beside the hardware one, from the integer IR1/IR2/SZ3. Phase 6 added preserve projection.`

Change the "Preserve projection precision" row's cell to: `Yes, since Phase 6 (2026-10-01-pgxp-phase-6-preserve-projection-design.md).`

Under `**Fork 1 — staleness.**`, add this paragraph after the existing text:

```markdown
*Superseded:* the premise that we keep the hardware `MAC0` no longer holds.
The projection became a float recompute beside the hardware one, and the
identity check judges a value by the word it was recorded against rather than
its position, so DuckStation's numbers pass it. See the Phase 6 spec.
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md .claude/skills/ps1-pgxp/SKILL.md docs/superpowers/specs/2026-09-09-pgxp-duckstation-parity-audit.md
git commit -m "docs(pgxp): Phase 6, preserve projection precision"
```
