# Analog Controller (DualShock) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port 1's pad becomes a DualShock: two sticks, the config-mode protocol games use to switch it to analog, and both rumble motors forwarded to the host controller through Core Haptics.

**Architecture:** The pad leaves `sio.zig` for its own `Pad` struct (`sio/pad.zig`) that owns an 8-byte reply buffer per packet, the way the hardware does; `Sio` keeps the registers, port select, /ACK timing and the memory card, and hands every pad byte to `Pad.transfer`. The savestate `SIO ` section goes to version 2 with a v1 translation. Three new C ABI calls carry sticks in, the Analog button in, and mode plus motors out; the app reads the sticks from `GCExtendedGamepad`, polls the status at 60 Hz, and drives Core Haptics from it.

**Tech Stack:** Zig 0.17.0 (core, C ABI, harnesses), Swift 6 / SwiftUI / GameController / CoreHaptics (macOS app), xcodebuild.

**Spec:** `docs/superpowers/specs/2026-10-07-analog-controller-design.md`

## Global Constraints

- `zig version` is 0.17.0: no `**` array repeat (use `@splat`), `@intFromEnum` is `@backingInt`, an enum's values are `@typeInfo(E).@"enum".field_values`.
- Run everything from the repo root. `trace-golden` modes run `-Doptimize=ReleaseFast`.
- No file in `ps1-core/src` over ~600 lines.
- Commits: one per task, directly on `master`, **title line only** (no body, no trailer). **Never `git push`.**
- Never name DuckStation in code comments or commit titles; "the reference" is fine.
- A new device field is a FORMAT change: section version bump plus a loader for the old version. Sections are hand-written, never reflected; so is `state_hash.zig`.
- `v1-synthetic.state` is never regenerated; v2 gets its own fixture beside it.
- `trace-golden -- capture` only in its own commit, with the moved workloads recorded in `ps1-test-harnesses`.
- The digital `0x42` packet stays byte-identical, IDs and /ACK pattern included. The pad keeps `pad_ack_delay` (500); the card keeps `card_ack_delay` (150). Port 2 still has no pad.
- Stick bytes: `0x00..0xFF`, `0x80` centre, **Y grows DOWN**. Stick order on the wire: RX, RY, LX, LY.
- Settings copy: plain complete sentences, no em or en dashes, British spelling (`SettingsCopyTests`).
- `pkill -x Substation` before `ps1-macos/test.sh`; run `zig build capi-lib metallib` first, and `zig build fixtures -Doptimize=ReleaseFast` if the fixture gates should not skip.
- Non-goals (do not build): port-2 pad, multitap, light guns, NeGcon, stick sensitivity/deadzone settings, keyboard stick emulation, per-game "start in analog", analog in `ps1-wasm`.

## Review Focus

1. **A packet abandoned by a deselect before its last byte**: a `0x43` cut short must leave config mode exactly as it was, because the mode latches on the packet's final byte. Test added to Task 2.
2. **Config commands addressed to port 2**: `0x43`/`0x44` there must get no /ACK and must not touch port 1's pad. Test added to Task 2.
3. **A state saved mid-`0x4D` packet**: the restored machine must finish the remap and stop the unmapped motor on the last byte. Test added to Task 3.
4. **Rumble held while the game is paused, a dialog is up, or the app is in the background**: the motors must go still, and come back when play resumes without the game writing them again (the motor values are machine state, not events). Test added to Task 9.
5. **Reset while the motors run**: `ps1_reset` must power the pad up digital with both motors at 0, so a ⌘R mid-rumble does not vibrate forever. Test added to Task 5.

## Notes on the spec

Three things the code says that the spec does not, settled here so no task re-litigates them:

- The spec says the app's `GCExtendedGamepad` handler "already maps L3/R3". It does not (`EmulatorViewModel.bind(_:)` reads no thumbstick buttons). Task 7 adds them.
- There is no Controls menu. Toggle Analog goes in the **Machine** menu, beside Reset (Task 7).
- `KeyBindings` is keyed on `PadButton`, whose raw values fill all 16 bits, so the Analog binding cannot be a fake button. Task 7 keys the bindings on a new `PadControl` (`.button(PadButton)` or `.analog`), persisted in the same dictionary under the key `"analog"`, so an existing saved map still loads and reads Analog as unbound.

## File map

| File | Change |
| --- | --- |
| `ps1-core/src/sio.zig` → `ps1-core/src/sio/sio.zig` | moved; pad fields and the nine `Ctrl*` states replaced by `pad: Pad` and one `.Pad` state |
| `ps1-core/src/sio/pad.zig` | **new**: `Pad`, the DualShock |
| `ps1-core/src/root.zig`, `memory.zig`, `savestate/io_state.zig` | import path |
| `ps1-core/src/savestate/stream.zig` | `tagValue` split out of `Reader.tag` |
| `ps1-core/src/savestate/savestate.zig` | `SIO ` v2; `sectionVersion` |
| `ps1-core/tests/sio_test.zig`, `savestate_test.zig` | protocol and format tests |
| `ps1-golden/src/state_hash.zig` | `hashSio` over the new fields |
| `ps1-golden/src/savestate_roundtrip_test.zig` | v2 fixture |
| `ps1-core/tests/goldens/savestate/v2-synthetic.state` | **new**, generated then committed |
| `ps1-core/tests/goldens/trace/*.txt`, `trace-block/*.txt` | recaptured (Task 4 only) |
| `ps1-capi/src/root.zig`, `ps1-capi/include/ps1.h`, `ps1-capi/src/capi_test.zig` | three new calls |
| `ps1-macos/Sources/PS1/PadState.swift` | **new**: `Sticks`, `PadStatus` |
| `ps1-macos/Sources/PS1/PadHaptics.swift` | **new**: `MotorDrive`, `PadHaptics` |
| `ps1-macos/Sources/PS1/VibrationSetting.swift` | **new** |
| `ps1-macos/Sources/PS1/Ps1Core.swift`, `EmulatorRunner.swift`, `InputMap.swift`, `KeyBindings.swift`, `EmulatorViewModel.swift`, `GameWindowView.swift`, `GameHUD.swift`, `Settings/ControlsSettingsPane.swift`, `Settings/SettingsCopy.swift`, `Sources/PS1App/MachineCommands.swift` | wiring |
| `ps1-macos/Tests/PS1Tests/PadStateTests.swift`, `PadHapticsTests.swift`, `VibrationSettingTests.swift` | **new** |
| `.claude/skills/ps1-core-subsystems/SKILL.md`, `ps1-test-harnesses/SKILL.md`, `ps1-macos-app/SKILL.md`, `CLAUDE.md` | docs (Task 10) |

---

### Task 1: `Pad` takes over the read packet; `sio/` becomes a directory

The refactor with no behaviour change: `0x42` only, through the new `Pad`. Config commands come in Tasks 2 and 3. The savestate section and the golden hash must change in this same task, because the fields they name stop existing.

**Files:**
- Move: `ps1-core/src/sio.zig` → `ps1-core/src/sio/sio.zig`
- Create: `ps1-core/src/sio/pad.zig`
- Modify: `ps1-core/src/root.zig:10`, `ps1-core/src/memory.zig:6`, `ps1-core/src/savestate/io_state.zig:10,126-196`, `ps1-core/src/savestate/stream.zig:95-101`, `ps1-core/src/savestate/savestate.zig:67`
- Modify: `ps1-golden/src/state_hash.zig:442-474`, `ps1-golden/src/savestate_roundtrip_test.zig`
- Modify: `ps1-capi/src/capi_test.zig:217,220` (`sio.buttons` → `sio.pad.buttons`)
- Test: `ps1-core/tests/sio_test.zig`, `ps1-core/tests/savestate_test.zig`

**Interfaces:**
- Produces (`ps1-core/src/sio/pad.zig`):
  - `pub const Pad = struct { buttons: u16, sticks: [4]u8, analog: bool, config: bool, dualshock: bool, locked: bool, status: u8, rumble_map: [6]u8, motor_small: u8, motor_large: u8, toggle_queued: bool, command: u8, tx: [8]u8, rx: [8]u8, step: u8, len: u8 }` with the defaults below
  - `pub const Reply = struct { out: u8, more: bool }`
  - `pub fn begin(self: *Pad, cmd: u8) bool`
  - `pub fn transfer(self: *Pad, byte_in: u8) Reply`
  - `pub fn idle(self: *Pad) void`
  - `pub fn setSticks(self: *Pad, lx: u8, ly: u8, rx: u8, ry: u8) void`
  - `pub fn id(self: *const Pad) u8`
  - `pub fn isCommand(cmd: u8) bool` (every command byte the pad can ever answer)
- Produces (`Sio`): `pad: Pad` field; `SioState.Pad`; `Sio.setButtons(u16)` kept (four frontends call it) and forwarding to `pad.buttons`. `Sio.setAnalogInputs` is deleted (no callers).
- Produces (`stream.zig`): `pub fn tagValue(comptime E: type, v: u32) Error!E`
- Produces (`savestate.zig`): `pub fn sectionVersion(tag: [4]u8) u32`

- [ ] **Step 1: Move the file**

```bash
mkdir -p ps1-core/src/sio
git mv ps1-core/src/sio.zig ps1-core/src/sio/sio.zig
```

Update the three importers: `root.zig` → `pub const sio = @import("sio/sio.zig");` (the public path `ps1_core.sio.Sio` must not change), `memory.zig` → `@import("sio/sio.zig")`, `savestate/io_state.zig` → `@import("../sio/sio.zig")`.

Run: `zig build test -Dtest-filter=pad`
Expected: builds (nothing matches yet); a build error here means an import was missed.

- [ ] **Step 2: Write the failing tests**

Append to `ps1-core/tests/sio_test.zig`. `xfer` and `selectPort` already exist in that file.

```zig
/// Clocks a whole pad packet on port 1 and returns what came back, byte for
/// byte, with the /ACK level after each one.
fn padPacket(bus: *Bus, bytes: []const u8, out: []u8, acks: []bool) void {
    for (bytes, 0..) |b, i| {
        bus.write8(JOY_DATA, b);
        out[i] = bus.read8(JOY_DATA);
        acks[i] = bus.read16Raw(JOY_STAT) & 0x80 != 0;
    }
}

test "an analog read is nine bytes: ID 0x73, 0x5A, buttons, then RX RY LX LY" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    bus.sio.pad.analog = true;
    bus.sio.pad.setSticks(0x10, 0x20, 0x30, 0x40); // lx, ly, rx, ry
    bus.sio.setButtons(0xFFF7);

    var out: [9]u8 = undefined;
    var acks: [9]bool = undefined;
    padPacket(bus, &.{ 0x01, 0x42, 0, 0, 0, 0, 0, 0, 0 }, &out, &acks);

    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0x73, 0x5A, 0xF7, 0xFF, 0x30, 0x40, 0x10, 0x20 }, &out);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, true, true, true, true, true, false }, &acks);
}

test "the digital packet's /ACK pattern is unchanged: every byte but the last" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    var out: [5]u8 = undefined;
    var acks: [5]bool = undefined;
    padPacket(bus, &.{ 0x01, 0x42, 0, 0, 0 }, &out, &acks);

    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0x41, 0x5A, 0xFF, 0xFF }, &out);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, true, false }, &acks);
}

test "mid-packet the pad still asks for the pad's /ACK delay" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    _ = xfer(bus, 0x01);
    _ = xfer(bus, 0x42); // now in .Pad
    try expectEqual(ps1_core.sio.Sio.SioState.Pad, bus.sio.ctrl_state);
    const n = stepsToIrq(bus);
    try expect(n > 140);
    try expect(n < 730);
}
```

In `ps1-core/tests/savestate_test.zig`, add a version-aware round trip beside `roundTrip` and rewrite the SIO round-trip test over the new fields (replace the whole `test "sio section restores protocol state but never the card images"` body):

```zig
fn roundTripAt(
    src: *Machine,
    dst: *Machine,
    comptime save: fn (*const Cpu, *stream.Writer) stream.Error!void,
    comptime load: fn (*Cpu, *stream.Reader, u32) stream.Error!void,
    version: u32,
) !void {
    var counter = stream.Writer{};
    try save(&src.cpu, &counter);
    const buf = try std.testing.allocator.alloc(u8, counter.len);
    defer std.testing.allocator.free(buf);
    var w = stream.Writer{ .buf = buf };
    try save(&src.cpu, &w);
    var r = stream.Reader{ .buf = buf };
    try load(&dst.cpu, &r, version);
    try r.end();
}
```

Make the existing `roundTrip` a one-line call to `roundTripAt(src, dst, save, load, 1)` so the two do not duplicate.

```zig
test "sio section restores protocol state but never the card images" {
    var a = try Machine.init();
    defer a.deinit();
    var b = try Machine.init();
    defer b.deinit();

    const io = &a.bus.sio;
    io.stat = 0x123;
    io.mode = 0x4D;
    io.ctrl = 0x1003;
    io.baud = 0x88;
    io.rx_data = 0x41;
    io.ctrl_state = .Pad;
    io.ack = true;
    io.irq = true;
    io.irq_timer = 450;
    io.port = 1;
    const p = &io.pad;
    p.buttons = 0xFFFE;
    p.sticks = .{ 1, 2, 3, 4 };
    p.analog = true;
    p.config = true;
    p.dualshock = true;
    p.locked = true;
    p.status = 0x00;
    p.rumble_map = .{ 0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xFF };
    p.motor_small = 255;
    p.motor_large = 6;
    p.toggle_queued = true;
    p.command = 0x42;
    p.tx = .{ 0xF3, 0x5A, 1, 2, 3, 4, 5, 6 };
    p.rx = .{ 0x42, 0, 9, 8, 7, 0, 0, 0 };
    p.step = 5;
    p.len = 8;
    io.memcard_staging[1][7] = 0x77;
    io.memcard_address[1] = 0x3F;
    io.memcard_checksum[1] = 0x12;
    io.memcard_step[1] = 9;
    io.memcard_is_write[1] = true;
    io.memcard_flag[1] = 0;
    io.memcard_status[1] = 'E';
    io.memcard_data[0][0] = 0xEE; // must NOT travel
    io.memcard_dirty[0] = true; // must NOT travel

    try roundTripAt(&a, &b, io_state.saveSio, io_state.loadSio, savestate.sectionVersion("SIO ".*));

    const got = &b.bus.sio;
    try std.testing.expectEqual(io.stat, got.stat);
    try std.testing.expectEqual(io.mode, got.mode);
    try std.testing.expectEqual(io.ctrl, got.ctrl);
    try std.testing.expectEqual(io.baud, got.baud);
    try std.testing.expectEqual(io.rx_data, got.rx_data);
    try std.testing.expectEqual(io.ctrl_state, got.ctrl_state);
    try std.testing.expectEqual(io.ack, got.ack);
    try std.testing.expectEqual(io.irq, got.irq);
    try std.testing.expectEqual(io.irq_timer, got.irq_timer);
    try std.testing.expectEqual(io.port, got.port);
    try std.testing.expectEqualDeep(io.pad, got.pad);
    try std.testing.expectEqualDeep(io.memcard_staging, got.memcard_staging);
    try std.testing.expectEqualDeep(io.memcard_address, got.memcard_address);
    try std.testing.expectEqualDeep(io.memcard_checksum, got.memcard_checksum);
    try std.testing.expectEqualDeep(io.memcard_step, got.memcard_step);
    try std.testing.expectEqualDeep(io.memcard_is_write, got.memcard_is_write);
    try std.testing.expectEqualDeep(io.memcard_flag, got.memcard_flag);
    try std.testing.expectEqualDeep(io.memcard_status, got.memcard_status);
    try std.testing.expect(got.memcard_data[0][0] != 0xEE);
    try std.testing.expect(!got.memcard_dirty[0]);
}
```

Then the v1 translation tests. v1 has no writer any more, so the section is written by hand in v1's field order (`io_state.zig` before this task: stat, mode, ctrl, baud, rx_data, ctrl_state, ack, irq, irq_timer, buttons, analog_enabled, port, joy_rx, joy_ry, joy_lx, joy_ly, motor_right_small, motor_left_large, then per slot: staging[128], address u16, checksum u8, step u32, is_write, flag u8, status u8):

```zig
/// A version-1 SIO section, written field by field in v1's order. v1's
/// `ctrl_state` tags: 0 Idle, 1 AwaitingCmd, 2 CtrlAwaitingTap, 3
/// CtrlSendingButtonsLow, 4 CtrlSendingButtonsHigh, 5..8 CtrlJoyRightX..LeftY,
/// 9..25 the card states in declaration order.
fn writeV1Sio(w: *stream.Writer, state_tag: u32, buttons: u16, analog: bool) stream.Error!void {
    try w.int(@as(u32, 0x05)); // stat
    try w.int(@as(u32, 0)); // mode
    try w.int(@as(u32, 0x1003)); // ctrl
    try w.int(@as(u32, 0)); // baud
    try w.int(@as(u8, 0x41)); // rx_data
    try w.int(state_tag);
    try w.flag(true); // ack
    try w.flag(false); // irq
    try w.int(@as(u32, 300)); // irq_timer
    try w.int(buttons);
    try w.flag(analog);
    try w.int(@as(u1, 0)); // port
    for ([_]u8{ 0x11, 0x22, 0x33, 0x44 }) |b| try w.int(b); // joy_rx, ry, lx, ly
    try w.int(@as(u8, 0)); // motor_right_small
    try w.int(@as(u8, 0)); // motor_left_large
    for (0..2) |_| {
        try w.array(&@as([128]u8, @splat(0)));
        try w.int(@as(u16, 0));
        try w.int(@as(u8, 0));
        try w.int(@as(u32, 0));
        try w.flag(false);
        try w.int(@as(u8, 0x18));
        try w.int(@as(u8, 'G'));
    }
}

fn loadV1Sio(m: *Machine, state_tag: u32, buttons: u16, analog: bool) !void {
    var counter = stream.Writer{};
    try writeV1Sio(&counter, state_tag, buttons, analog);
    const buf = try std.testing.allocator.alloc(u8, counter.len);
    defer std.testing.allocator.free(buf);
    var w = stream.Writer{ .buf = buf };
    try writeV1Sio(&w, state_tag, buttons, analog);
    var r = stream.Reader{ .buf = buf };
    try io_state.loadSio(&m.cpu, &r, 1);
    try r.end();
}

test "a v1 SIO section loads as a powered-up digital pad with its sticks" {
    var m = try Machine.init();
    defer m.deinit();
    try loadV1Sio(&m, 0, 0xFFF7, false);
    const p = &m.bus.sio.pad;
    try std.testing.expectEqual(ps1.sio.Sio.SioState.Idle, m.bus.sio.ctrl_state);
    try std.testing.expectEqual(@as(u16, 0xFFF7), p.buttons);
    try std.testing.expectEqual([4]u8{ 0x11, 0x22, 0x33, 0x44 }, p.sticks);
    try std.testing.expect(!p.analog and !p.config and !p.dualshock and !p.locked);
    try std.testing.expectEqual(@as(u8, 0x5A), p.status);
    try std.testing.expectEqual(@as([6]u8, @splat(0xFF)), p.rumble_map);
}

test "a v1 mid-packet pad state resumes at the byte it was waiting for" {
    var m = try Machine.init();
    defer m.deinit();
    try loadV1Sio(&m, 3, 0xFFF7, false); // CtrlSendingButtonsLow
    try std.testing.expectEqual(ps1.sio.Sio.SioState.Pad, m.bus.sio.ctrl_state);

    m.bus.sio.write(0, 0x00);
    try std.testing.expectEqual(@as(u32, 0xF7), m.bus.sio.read(0)); // buttons low
    m.bus.sio.write(0, 0x00);
    try std.testing.expectEqual(@as(u32, 0xFF), m.bus.sio.read(0)); // buttons high
    try std.testing.expectEqual(ps1.sio.Sio.SioState.Idle, m.bus.sio.ctrl_state); // digital packet over
}

test "a v1 card state keeps its meaning" {
    var m = try Machine.init();
    defer m.deinit();
    try loadV1Sio(&m, 13, 0xFFFF, false); // MemcardAddressLsb
    try std.testing.expectEqual(ps1.sio.Sio.SioState.MemcardAddressLsb, m.bus.sio.ctrl_state);
}

test "a v1 stick state on a digital pad is StateCorrupt" {
    var m = try Machine.init();
    defer m.deinit();
    try std.testing.expectError(error.StateCorrupt, loadV1Sio(&m, 7, 0xFFFF, false)); // CtrlJoyLeftX
}

test "an impossible pad packet is StateCorrupt" {
    var len = try Machine.init();
    defer len.deinit();
    len.bus.sio.ctrl_state = .Pad;
    len.bus.sio.pad.command = 0x42;
    len.bus.sio.pad.len = 5;
    len.bus.sio.pad.step = 1;
    try expectSavedStateRefused(&len);

    var step = try Machine.init();
    defer step.deinit();
    step.bus.sio.ctrl_state = .Pad;
    step.bus.sio.pad.command = 0x42;
    step.bus.sio.pad.len = 4;
    step.bus.sio.pad.step = 4;
    try expectSavedStateRefused(&step);

    var cmd = try Machine.init();
    defer cmd.deinit();
    cmd.bus.sio.ctrl_state = .Pad;
    cmd.bus.sio.pad.command = 0x99;
    cmd.bus.sio.pad.len = 4;
    cmd.bus.sio.pad.step = 1;
    try expectSavedStateRefused(&cmd);
}
```

Also update `ps1-capi/src/capi_test.zig:217,220`: `h.cpu.bus.sio.buttons` → `h.cpu.bus.sio.pad.buttons`.

- [ ] **Step 3: Run the tests to see them fail**

Run: `zig build test -Dtest-filter=pad`
Expected: compile errors (`no field named 'pad'`, `no member 'sectionVersion'`).

- [ ] **Step 4: Write `ps1-core/src/sio/pad.zig`**

Tasks 2 and 3 fill in the config commands and rumble; this version answers `0x42` only, and `transfer` already has the shape they slot into.

```zig
//! The controller in port 1: a DualShock, which powers up as a plain digital
//! pad.
//!
//! A packet is the command byte and up to seven more. The pad decides its
//! whole reply when the command byte arrives (`begin`) and then clocks it out
//! one byte per exchange (`transfer`), recording what the console sent beside
//! it: a later byte's effect can depend on an earlier one, and a reply byte
//! can be rewritten by the byte that arrives with it.

pub const Pad = struct {
    const Self = @This();

    /// The ID byte is `mode << 4 | halfwords after the 0x5A`.
    pub const id_digital: u8 = 0x41;
    pub const id_analog: u8 = 0x73;
    pub const id_config: u8 = 0xF3;
    /// The byte after the ID on every reply, until an Analog-button toggle
    /// clears it on a pad that has been in config mode.
    pub const status_ok: u8 = 0x5A;

    pub const Reply = struct { out: u8, more: bool };

    buttons: u16 = 0xFFFF, // 0 = pressed, 1 = released
    /// RX, RY, LX, LY: the order they go out on the wire. 0x80 is centre and
    /// Y grows downward.
    sticks: [4]u8 = @splat(0x80),
    analog: bool = false,
    config: bool = false,
    /// Set the first time a game enters config mode: from then on the
    /// rumble map, not the legacy encoding, decides what drives the motors.
    dualshock: bool = false,
    /// The game has locked the mode, so the Analog button does nothing.
    locked: bool = false,
    status: u8 = status_ok,
    /// Which motor each of TX bytes 2..7 of a read drives: 0x00 small,
    /// 0x01 large, anything else nothing.
    rumble_map: [6]u8 = @splat(0xFF),
    /// 0 or 255: the small motor has one speed.
    motor_small: u8 = 0,
    motor_large: u8 = 0,
    toggle_queued: bool = false,

    // The packet in flight. `len` is 0 between packets.
    command: u8 = 0,
    tx: [8]u8 = @splat(0),
    rx: [8]u8 = @splat(0),
    step: u8 = 0,
    len: u8 = 0,

    pub fn id(self: *const Self) u8 {
        if (self.config) return id_config;
        return if (self.analog) id_analog else id_digital;
    }

    /// Every command byte this pad can ever answer. Whether it answers one
    /// NOW also depends on config mode; see `begin`.
    pub fn isCommand(cmd: u8) bool {
        return switch (cmd) {
            0x42 => true,
            else => false,
        };
    }

    /// Called on the command byte. Builds the reply and says whether the pad
    /// answers at all: a pad that does not leaves the port with nobody
    /// listening, which software reads as no /ACK.
    pub fn begin(self: *Self, cmd: u8) bool {
        if (!isCommand(cmd)) return false;
        self.command = cmd;
        self.step = 0;
        self.len = if (self.config or self.analog) 8 else 4;
        self.rx = @splat(0);
        self.tx = .{ self.id(), self.status, 0, 0, 0, 0, 0, 0 };
        self.fillRead();
        return true;
    }

    /// The buttons, and in analog or config mode the four axes after them.
    fn fillRead(self: *Self) void {
        self.tx[2] = @truncate(self.buttons);
        self.tx[3] = @truncate(self.buttons >> 8);
        if (self.analog or self.config) self.tx[4..8].* = self.sticks;
    }

    /// One exchange: record what the console sent, apply its effect, and
    /// return the reply byte for this position. `more` is false on the
    /// packet's last byte, where the pad stops asserting /ACK.
    pub fn transfer(self: *Self, byte_in: u8) Reply {
        const s = self.step;
        self.rx[s] = byte_in;
        const out = self.tx[s];
        self.step += 1;
        return .{ .out = out, .more = self.step < self.len };
    }

    /// The transfer state resets: packet end, deselect, SIO reset. A queued
    /// Analog-button press lands here, so a reply is never re-shaped mid-way.
    pub fn idle(self: *Self) void {
        self.command = 0;
        self.step = 0;
        self.len = 0;
    }

    pub fn setSticks(self: *Self, lx: u8, ly: u8, rx: u8, ry: u8) void {
        self.sticks = .{ rx, ry, lx, ly };
    }
};
```

- [ ] **Step 5: Rewire `Sio` onto it**

In `ps1-core/src/sio/sio.zig`:

1. `const Pad = @import("pad.zig").Pad;` at the top.
2. Delete `digital_pad_id`/`dualshock_pad_id`, the fields `buttons`, `analog_enabled`, `joy_rx/ry/lx/ly`, `motor_right_small`, `motor_left_large`, and `setAnalogInputs`. Add, where `buttons` was:

```zig
    /// Port 1's controller. Port 2 has none.
    pad: Pad = .{},
```

3. Replace `SioState` with explicitly numbered tags. The card states keep their v1 numbers so a state file's tag means the same thing in both versions; 3..8 are the v1 per-byte pad states, which `loadSio` translates.

```zig
    pub const SioState = enum(u8) {
        Idle = 0,
        AwaitingCmd = 1,
        /// A pad packet in flight; `pad.step` is the byte it answers next.
        Pad = 2,
        // 3..8 were the per-byte pad states of savestate v1.

        // Memory Card
        MemcardCmd = 9,
        MemcardAck1 = 10,
        MemcardAck2 = 11,
        MemcardAddressMsb = 12,
        MemcardAddressLsb = 13,

        MemcardReadAck1 = 14,
        MemcardReadAck2 = 15,
        MemcardReadConfirmMsb = 16,
        MemcardReadConfirmLsb = 17,
        MemcardReadData = 18,
        MemcardReadChecksum = 19,
        MemcardReadEnd = 20,

        MemcardWriteData = 21,
        MemcardWriteChecksum = 22,
        MemcardWriteAck1 = 23,
        MemcardWriteAck2 = 24,
        MemcardWriteStatus = 25,
    };
```

4. In `ackDelay`, replace the nine pad states with `.AwaitingCmd, .Pad => pad_ack_delay,`. Keep the switch exhaustive with no `else`.
5. Replace the `.AwaitingCmd` arm and the seven `.Ctrl*` arms of `write`'s TX switch with:

```zig
                    .AwaitingCmd => {
                        // Port 2 has no pad in it. Falling through to .Idle is
                        // the existing "nothing responded" path: no /ACK, no
                        // IRQ7, and the BIOS routine times out and reports no
                        // controller, which is what an empty socket does.
                        if (p == 0 and self.pad.begin(tx)) {
                            self.rx_data = self.pad.transfer(tx).out;
                            self.ctrl_state = .Pad;
                        } else {
                            if (p == 0) self.pad.idle();
                            self.ctrl_state = .Idle;
                        }
                    },
                    .Pad => {
                        const r = self.pad.transfer(tx);
                        self.rx_data = r.out;
                        if (!r.more) {
                            self.pad.idle();
                            self.ctrl_state = .Idle;
                        }
                    },
```

6. In the JOY_CTRL write, call `self.pad.idle();` next to both `self.ctrl_state = .Idle;` assignments (deselect and SIO reset).
7. `setButtons` becomes `self.pad.buttons = buttons;`.

- [ ] **Step 6: `stream.tagValue` and `savestate.sectionVersion`**

`ps1-core/src/savestate/stream.zig`: split the loop out of `Reader.tag` so a loader can decode a tag it has already read.

```zig
    pub fn tag(r: *Reader, comptime E: type) Error!E {
        return tagValue(E, try r.int(u32));
    }
```

and at file scope:

```zig
/// The enum value a raw tag names, or StateCorrupt: the file is CRC-valid
/// and untrusted, so a tag outside the enum is damage, not a new value.
pub fn tagValue(comptime E: type, v: u32) Error!E {
    inline for (@typeInfo(E).@"enum".field_values) |fv| {
        if (v == fv) return @fromBackingInt(@intCast(fv));
    }
    return error.StateCorrupt;
}
```

`ps1-core/src/savestate/savestate.zig`: bump the `SIO ` row to `.version = 2`, and add

```zig
/// The version this build writes for `tag`. For tests that drive one
/// section's save and load directly.
pub fn sectionVersion(tag: [4]u8) u32 {
    return sections[indexOfTag(tag).?].version;
}
```

- [ ] **Step 7: The SIO section, v2 and v1**

In `ps1-core/src/savestate/io_state.zig`, import `const Pad = @import("../sio/pad.zig").Pad;` and replace `saveSio`/`loadSio`:

```zig
pub fn saveSio(cpu: *const Cpu, w: *Writer) Error!void {
    const io = &cpu.bus.sio;
    try w.int(io.stat);
    try w.int(io.mode);
    try w.int(io.ctrl);
    try w.int(io.baud);
    try w.int(io.rx_data);
    try w.tag(io.ctrl_state);
    try w.flag(io.ack);
    try w.flag(io.irq);
    try w.int(io.irq_timer);
    try w.int(io.port);
    try savePad(&io.pad, w);
    for (0..Sio.memcard_slots) |i| {
        try w.array(&io.memcard_staging[i]);
        try w.int(io.memcard_address[i]);
        try w.int(io.memcard_checksum[i]);
        try w.int(io.memcard_step[i]);
        try w.flag(io.memcard_is_write[i]);
        try w.int(io.memcard_flag[i]);
        try w.int(io.memcard_status[i]);
    }
}

fn savePad(p: *const Pad, w: *Writer) Error!void {
    try w.int(p.buttons);
    try w.array(&p.sticks);
    try w.flag(p.analog);
    try w.flag(p.config);
    try w.flag(p.dualshock);
    try w.flag(p.locked);
    try w.int(p.status);
    try w.array(&p.rumble_map);
    try w.int(p.motor_small);
    try w.int(p.motor_large);
    try w.flag(p.toggle_queued);
    try w.int(p.command);
    try w.array(&p.tx);
    try w.array(&p.rx);
    try w.int(p.step);
    try w.int(p.len);
}

fn loadPad(p: *Pad, r: *Reader) Error!void {
    p.buttons = try r.int(u16);
    try r.array(&p.sticks);
    p.analog = try r.flag();
    p.config = try r.flag();
    p.dualshock = try r.flag();
    p.locked = try r.flag();
    p.status = try r.int(u8);
    try r.array(&p.rumble_map);
    p.motor_small = try r.int(u8);
    p.motor_large = try r.int(u8);
    p.toggle_queued = try r.flag();
    p.command = try r.int(u8);
    try r.array(&p.tx);
    try r.array(&p.rx);
    p.step = try r.int(u8);
    p.len = try r.int(u8);
}

/// v1 kept the pad inline in `Sio`: a digital/analog flag, the sticks and a
/// motor pair, with one `SioState` per byte of a read. There was no config
/// mode, so everything else is the pad's power-on value. `step` is the byte
/// a mid-packet state was waiting for; the reply is rebuilt as `0x42` would
/// have built it, which is the only command v1 answered.
fn loadPadV1(io: *Sio, r: *Reader, step: ?u8) Error!void {
    const p = &io.pad;
    p.* = .{};
    p.buttons = try r.int(u16);
    p.analog = try r.flag();
    io.port = try r.int(u1);
    try r.array(&p.sticks); // joy_rx, joy_ry, joy_lx, joy_ly
    p.motor_small = try r.int(u8); // motor_right_small
    p.motor_large = try r.int(u8); // motor_left_large
    if (step) |s| {
        _ = p.begin(0x42);
        p.step = s;
    }
}

/// v1's per-byte pad states, `CtrlAwaitingTap` through `CtrlJoyLeftY`. Each
/// tag is one more than the byte it answered next, counting the command byte
/// as byte 0.
const v1_ctrl_first: u32 = 2;
const v1_ctrl_last: u32 = 8;

pub fn loadSio(cpu: *Cpu, r: *Reader, version: u32) Error!void {
    const io = &cpu.bus.sio;
    io.stat = try r.int(u32);
    io.mode = try r.int(u32);
    io.ctrl = try r.int(u32);
    io.baud = try r.int(u32);
    io.rx_data = try r.int(u8);
    var v1_pad_step: ?u8 = null;
    if (version >= 2) {
        io.ctrl_state = try r.tag(Sio.SioState);
    } else {
        const raw = try r.int(u32);
        if (raw >= v1_ctrl_first and raw <= v1_ctrl_last) {
            io.ctrl_state = .Pad;
            v1_pad_step = @intCast(raw - 1);
        } else {
            io.ctrl_state = try stream.tagValue(Sio.SioState, raw);
        }
    }
    io.ack = try r.flag();
    io.irq = try r.flag();
    io.irq_timer = try r.int(u32);
    if (version >= 2) {
        io.port = try r.int(u1);
        try loadPad(&io.pad, r);
    } else {
        try loadPadV1(io, r, v1_pad_step);
    }
    for (0..Sio.memcard_slots) |i| {
        try r.array(&io.memcard_staging[i]);
        io.memcard_address[i] = try r.int(u16);
        io.memcard_checksum[i] = try r.int(u8);
        io.memcard_step[i] = try r.int(u32);
        io.memcard_is_write[i] = try r.flag();
        io.memcard_flag[i] = try r.int(u8);
        io.memcard_status[i] = try r.int(u8);
        if (io.memcard_step[i] > Sio.memcard_sector_bytes) return error.StateCorrupt;
    }
    // The address holds the unmasked MSB until the LSB byte masks it, and an
    // abandoned packet leaves it that way, so only the states that index the
    // card with it bound it.
    const indexing = switch (io.ctrl_state) {
        .MemcardReadAck1, .MemcardReadAck2, .MemcardReadConfirmMsb, .MemcardReadConfirmLsb, .MemcardReadData, .MemcardWriteData, .MemcardWriteChecksum => true,
        else => false,
    };
    if (indexing and io.memcard_address[io.port] > Sio.memcard_address_mask) return error.StateCorrupt;
    // `step` indexes the 8-byte reply, so a packet in flight is bounded by
    // the only two lengths a reply has.
    if (io.ctrl_state == .Pad) {
        const p = &io.pad;
        if (p.len != 4 and p.len != 8) return error.StateCorrupt;
        if (p.step >= p.len) return error.StateCorrupt;
        if (!Pad.isCommand(p.command)) return error.StateCorrupt;
    }
}
```

- [ ] **Step 8: The golden hash**

In `ps1-golden/src/state_hash.zig`, replace `hashSio`'s pad lines (`buttons` through `motor_left_large`) so the function reads, in this order: stat, mode, ctrl, baud, rx_data, ctrl_state, ack, irq, irq_timer, port, the pad, the cards (unchanged).

```zig
    s.int(io.irq_timer);
    s.int(io.port);
    hashPad(&s, &io.pad);
    for (0..ps1.sio.Sio.memcard_slots) |i| {
```

```zig
fn hashPad(s: *Sink, p: *const ps1.sio.Pad) void {
    s.int(p.buttons);
    s.bytes(&p.sticks);
    s.flag(p.analog);
    s.flag(p.config);
    s.flag(p.dualshock);
    s.flag(p.locked);
    s.int(p.status);
    s.bytes(&p.rumble_map);
    s.int(p.motor_small);
    s.int(p.motor_large);
    s.flag(p.toggle_queued);
    s.int(p.command);
    s.bytes(&p.tx);
    s.bytes(&p.rx);
    s.int(p.step);
    s.int(p.len);
}
```

For `ps1.sio.Pad` to resolve, add `pub const Pad = @import("pad.zig").Pad;` to `sio/sio.zig` (beside the `Pad` import from Step 5; make that import the `pub` one rather than declaring it twice).

- [ ] **Step 9: The v2 fixture**

In `ps1-golden/src/savestate_roundtrip_test.zig`, turn the fixture test into a helper and call it twice. `buildFixtureMachine` stays exactly as it is: the committed v1 file was written from it.

```zig
const v1_fixture_path = "ps1-core/tests/goldens/savestate/v1-synthetic.state";
const v2_fixture_path = "ps1-core/tests/goldens/savestate/v2-synthetic.state";

/// The v1 machine plus a pad that is mid-packet in config mode, so the
/// fixture exercises every field `SIO ` v2 added.
fn buildV2FixtureMachine() !Machine {
    var m = try buildFixtureMachine();
    const p = &m.bus.sio.pad;
    p.config = true;
    p.dualshock = true;
    p.rumble_map[0] = 0x00;
    p.sticks[2] = 0x12;
    p.motor_large = 0x34;
    p.command = 0x42;
    p.len = 8;
    p.step = 3;
    p.tx = .{ 0xF3, 0x5A, 0xFF, 0xFF, 0x80, 0x80, 0x12, 0x80 };
    m.bus.sio.ctrl_state = .Pad;
    return m;
}

/// Loads a committed state into a fresh machine and requires it to hash
/// exactly as the machine `build` describes. The first run writes the file
/// and fails, so a new fixture is noticed and committed.
fn expectFixtureLoads(path: []const u8, comptime build: fn () anyerror!Machine) !void {
    const file = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(64 << 20)) catch |err| switch (err) {
        error.FileNotFound => {
            var m = try build();
            defer m.deinit();
            const state = try m.saveAlloc();
            defer std.testing.allocator.free(state);
            try std.Io.Dir.cwd().createDirPath(std.testing.io, "ps1-core/tests/goldens/savestate");
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = state });
            std.debug.print("wrote {s}; commit it\n", .{path});
            return error.FixtureWritten;
        },
        else => return err,
    };
    defer std.testing.allocator.free(file);

    var want = try build();
    defer want.deinit();
    const zeros: [512 * 1024]u8 = @splat(0);
    var got = try Machine.init(&zeros);
    defer got.deinit();
    try savestate.load(&got.cpu, file);
    try std.testing.expectEqualSlices(u64, &want.hashes(), &got.hashes());
}

test "the committed v1 state still loads, into exactly the machine that wrote it" {
    try expectFixtureLoads(v1_fixture_path, buildFixtureMachine);
}

test "the committed v2 state still loads, into exactly the machine that wrote it" {
    try expectFixtureLoads(v2_fixture_path, buildV2FixtureMachine);
}
```

Delete the old `fixture_path` constant and the old test body, and change `buildFixtureMachine`'s return type to `anyerror!Machine` (its body is unchanged): a function with an inferred error set does not coerce to the `fn () anyerror!Machine` parameter.

- [ ] **Step 10: Run everything**

Run: `zig build test`
Expected: one failure, `error.FixtureWritten` from the v2 fixture test, which writes `v2-synthetic.state`. Run `zig build test` again: everything passes, including every pre-existing `sio_test.zig` test unchanged (the digital packet, deselect, port 2, both /ACK windows) and the v1 fixture.

- [ ] **Step 11: Check that nothing but SIO moved**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- verify`
Expected: every workload reports a divergence, and **only in the `sio` region** (the region hash covers renamed fields). Any other region diverging is a refactor bug: stop and find it. Note the output; Task 4 recaptures.

- [ ] **Step 12: Commit**

```bash
zig fmt ps1-core ps1-golden ps1-capi
git add ps1-core ps1-golden ps1-capi
git commit -m "refactor(core): the pad is its own Pad behind a byte-per-step reply, and SIO state goes to v2"
```

---

### Task 2: Config mode and the Analog button

**Files:**
- Modify: `ps1-core/src/sio/pad.zig`
- Test: `ps1-core/tests/sio_test.zig`

**Interfaces:**
- Consumes: `Pad.begin/transfer/idle`, `padPacket` (Task 1's test helper)
- Produces: `pub fn pressAnalogButton(self: *Pad) void`; `isCommand` widened to `0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x4C, 0x4D`; `fn resetRumble(self: *Pad) void` (Task 3 calls it too)

- [ ] **Step 1: Write the failing tests**

```zig
/// One whole packet on port 1, returning the reply bytes after the address
/// byte's 0xFF (so `r[0]` is the ID).
fn padCmd(bus: *Bus, cmd: u8, args: []const u8, reply: []u8) void {
    _ = xfer(bus, 0x01);
    reply[0] = xfer(bus, cmd);
    for (1..reply.len) |i| reply[i] = xfer(bus, if (i - 1 < args.len) args[i - 1] else 0x00);
}

fn enterConfig(bus: *Bus) void {
    var r: [8]u8 = undefined;
    const len: usize = if (bus.sio.pad.analog) 8 else 4;
    padCmd(bus, 0x43, &.{ 0x00, 0x01 }, r[0..len]);
}

fn leaveConfig(bus: *Bus) void {
    var r: [8]u8 = undefined;
    padCmd(bus, 0x43, &.{ 0x00, 0x00 }, &r);
}

test "0x43 enters config: ID 0xF3 inside, and the pad is a DualShock from then on" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var r: [4]u8 = undefined;
    padCmd(bus, 0x43, &.{ 0x00, 0x01 }, &r);
    try std.testing.expectEqualSlices(u8, &.{ 0x41, 0x5A, 0xFF, 0xFF }, &r); // answered as a read
    try expect(bus.sio.pad.config);
    try expect(bus.sio.pad.dualshock);

    var r8: [8]u8 = undefined;
    padCmd(bus, 0x45, &.{}, &r8);
    try std.testing.expectEqualSlices(u8, &.{ 0xF3, 0x5A, 0x01, 0x02, 0x00, 0x02, 0x01, 0x00 }, &r8);

    leaveConfig(bus);
    try expect(!bus.sio.pad.config);
    try expect(bus.sio.pad.dualshock); // sticky
}

test "0x44 sets analog mode and the lock" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    enterConfig(bus);
    var r: [8]u8 = undefined;
    padCmd(bus, 0x44, &.{ 0x00, 0x01, 0x03 }, &r);
    try std.testing.expectEqualSlices(u8, &.{ 0xF3, 0x5A, 0, 0, 0, 0, 0, 0 }, &r);
    try expect(bus.sio.pad.analog);
    try expect(bus.sio.pad.locked);
    leaveConfig(bus);

    var read: [8]u8 = undefined;
    padCmd(bus, 0x42, &.{}, &read);
    try expectEqual(@as(u8, 0x73), read[0]);
}

test "0x45, 0x46, 0x47 and 0x4C answer as the hardware does" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    enterConfig(bus);
    var r: [8]u8 = undefined;

    padCmd(bus, 0x46, &.{ 0x00, 0x00 }, &r);
    try std.testing.expectEqualSlices(u8, &.{ 0xF3, 0x5A, 0x00, 0x00, 0x01, 0x02, 0x00, 0x0A }, &r);
    padCmd(bus, 0x46, &.{ 0x00, 0x01 }, &r);
    try std.testing.expectEqualSlices(u8, &.{ 0xF3, 0x5A, 0x00, 0x00, 0x01, 0x01, 0x01, 0x14 }, &r);

    padCmd(bus, 0x47, &.{ 0x00, 0x00 }, &r);
    try std.testing.expectEqualSlices(u8, &.{ 0xF3, 0x5A, 0x00, 0x00, 0x02, 0x00, 0x01, 0x00 }, &r);
    padCmd(bus, 0x47, &.{ 0x00, 0x01 }, &r);
    try std.testing.expectEqualSlices(u8, &.{ 0xF3, 0x5A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, &r);

    padCmd(bus, 0x4C, &.{ 0x00, 0x00 }, &r);
    try expectEqual(@as(u8, 0x04), r[5]);
    padCmd(bus, 0x4C, &.{ 0x00, 0x01 }, &r);
    try expectEqual(@as(u8, 0x07), r[5]);
}

test "config commands outside config mode get no /ACK" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    for ([_]u8{ 0x44, 0x45, 0x46, 0x47, 0x4C, 0x4D }) |cmd| {
        _ = xfer(bus, 0x01);
        _ = xfer(bus, cmd);
        try expectEqual(@as(u32, 0), bus.read16Raw(JOY_STAT) & 0x80);
        try expectEqual(ps1_core.sio.Sio.SioState.Idle, bus.sio.ctrl_state);
    }
}

test "the Analog button toggles at the next idle, never mid-packet" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    _ = xfer(bus, 0x01);
    try expectEqual(@as(u8, 0x41), xfer(bus, 0x42));
    bus.sio.pad.pressAnalogButton();
    _ = xfer(bus, 0x00);
    _ = xfer(bus, 0x00);
    _ = xfer(bus, 0x00); // a digital packet, finished as one
    try expect(bus.sio.pad.analog); // applied at the packet's end
    try expectEqual(@as(u8, 0x5A), bus.sio.pad.status); // never in config: no status change

    var r: [8]u8 = undefined;
    padCmd(bus, 0x42, &.{}, &r);
    try expectEqual(@as(u8, 0x73), r[0]);
}

test "after config mode, a toggle reports itself through status 0x00" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    enterConfig(bus);
    leaveConfig(bus);
    bus.sio.pad.pressAnalogButton();
    bus.write16(JOY_CTRL, 0x0000); // deselect: idle
    var r: [8]u8 = undefined;
    padCmd(bus, 0x42, &.{}, &r);
    try expectEqual(@as(u8, 0x73), r[0]);
    try expectEqual(@as(u8, 0x00), r[1]);
}

test "a locked pad ignores the Analog button" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    enterConfig(bus);
    var r: [8]u8 = undefined;
    padCmd(bus, 0x44, &.{ 0x00, 0x00, 0x03 }, &r); // digital, locked
    leaveConfig(bus);
    bus.sio.pad.pressAnalogButton();
    bus.write16(JOY_CTRL, 0x0000);
    try expect(!bus.sio.pad.analog);
    try expect(!bus.sio.pad.toggle_queued); // dropped, not held for later
}

test "a 0x43 cut short by a deselect leaves config mode as it was" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    bus.write16(JOY_CTRL, 0x1003);
    _ = xfer(bus, 0x01);
    _ = xfer(bus, 0x43);
    _ = xfer(bus, 0x00);
    _ = xfer(bus, 0x01); // the enter byte, but not the packet's last
    bus.write16(JOY_CTRL, 0x0000);
    try expect(!bus.sio.pad.config);
    try expect(!bus.sio.pad.dualshock);
}

test "config commands to port 2 get no /ACK and leave port 1's pad alone" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    selectPort(bus, 1);
    for ([_]u8{ 0x43, 0x44 }) |cmd| {
        _ = xfer(bus, 0x01);
        _ = xfer(bus, cmd);
        try expectEqual(@as(u32, 0), bus.read16Raw(JOY_STAT) & 0x80);
    }
    try expectEqualDeep(ps1_core.sio.Pad{}, bus.sio.pad);
}
```

Add `const expectEqualDeep = std.testing.expectEqualDeep;` at the top beside the other aliases.

- [ ] **Step 2: Run them to see them fail**

Run: `zig build test -Dtest-filter=config`
Expected: compile error, `no member named 'pressAnalogButton'`; then, once stubbed, FAILs on `0x43`.

- [ ] **Step 3: Implement**

In `pad.zig`:

```zig
    pub fn isCommand(cmd: u8) bool {
        return switch (cmd) {
            0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x4C, 0x4D => true,
            else => false,
        };
    }

    pub fn begin(self: *Self, cmd: u8) bool {
        const answers = switch (cmd) {
            0x42, 0x43 => true,
            0x44, 0x45, 0x46, 0x47, 0x4C, 0x4D => self.config,
            else => false,
        };
        if (!answers) return false;
        self.command = cmd;
        self.step = 0;
        // Config mode reports three halfwords whatever the analog flag says.
        self.len = if (self.config or self.analog) 8 else 4;
        self.rx = @splat(0);
        self.tx = .{ self.id(), self.status, 0, 0, 0, 0, 0, 0 };
        switch (cmd) {
            0x42 => self.fillRead(),
            // Outside config mode, entering it is answered as a read.
            0x43 => if (!self.config) self.fillRead(),
            0x44 => self.resetRumble(),
            0x45 => self.tx[2..8].* = .{ 0x01, 0x02, @intFromBool(self.analog), 0x02, 0x01, 0x00 },
            0x47 => self.tx[2..8].* = .{ 0x00, 0x00, 0x02, 0x00, 0x01, 0x00 },
            else => {},
        }
        return true;
    }

    pub fn transfer(self: *Self, byte_in: u8) Reply {
        const s = self.step;
        self.rx[s] = byte_in;
        switch (self.command) {
            // Config mode changes at the packet's END, so a packet abandoned
            // part-way changes nothing.
            0x43 => if (s == self.len - 1) self.setConfig(self.rx[2] == 0x01),
            0x44 => switch (s) {
                2 => if (byte_in <= 0x01) {
                    self.analog = byte_in == 0x01;
                },
                3 => if (byte_in == 0x02 or byte_in == 0x03) {
                    self.locked = byte_in == 0x03;
                },
                else => {},
            },
            0x46 => if (s == 2) switch (byte_in) {
                0x00 => self.tx[4..8].* = .{ 0x01, 0x02, 0x00, 0x0A },
                0x01 => self.tx[4..8].* = .{ 0x01, 0x01, 0x01, 0x14 },
                else => {},
            },
            0x47 => if (s == 2 and byte_in != 0x00) {
                self.tx[4..8].* = @splat(0);
            },
            0x4C => if (s == 2) switch (byte_in) {
                0x00 => self.tx[5] = 0x04,
                0x01 => self.tx[5] = 0x07,
                else => {},
            },
            else => {},
        }
        // After the effect: a reply byte may be rewritten by the byte that
        // arrives with it.
        const out = self.tx[s];
        self.step += 1;
        return .{ .out = out, .more = self.step < self.len };
    }

    fn setConfig(self: *Self, on: bool) void {
        self.config = on;
        if (on) {
            self.dualshock = true;
            self.status = status_ok;
        }
    }

    pub fn idle(self: *Self) void {
        if (self.toggle_queued) {
            self.toggle_queued = false;
            self.applyToggle();
        }
        self.command = 0;
        self.step = 0;
        self.len = 0;
    }

    /// Queued, not applied: see `idle`.
    pub fn pressAnalogButton(self: *Self) void {
        self.toggle_queued = true;
    }

    fn applyToggle(self: *Self) void {
        if (self.locked) return;
        self.analog = !self.analog;
        self.resetRumble();
        // How a game that has used config mode notices the change.
        if (self.dualshock) self.status = 0x00;
    }

    /// Every mode change unmaps both motors and stops them.
    fn resetRumble(self: *Self) void {
        self.rumble_map = @splat(0xFF);
        self.motor_small = 0;
        self.motor_large = 0;
    }
```

- [ ] **Step 4: Run the tests**

Run: `zig build test -Dtest-filter=config` then `zig build test -Dtest-filter=Analog` then `zig build test -Dtest-filter=pad`
Expected: PASS, and Task 1's tests still PASS.

- [ ] **Step 5: Commit**

```bash
zig fmt ps1-core
git add ps1-core
git commit -m "feat(core): the pad answers config mode and the Analog button"
```

---

### Task 3: Rumble

**Files:**
- Modify: `ps1-core/src/sio/pad.zig`
- Test: `ps1-core/tests/sio_test.zig`, `ps1-core/tests/savestate_test.zig`

**Interfaces:**
- Consumes: `resetRumble`, `padCmd`, `enterConfig`, `leaveConfig` (Task 2)
- Produces: `motor_small` (0 or 255) and `motor_large` (0..255) kept current, for Task 5's `ps1_get_pad_status`

- [ ] **Step 1: Write the failing tests**

`sio_test.zig`:

```zig
fn mapRumble(bus: *Bus, map: [6]u8, old: *[8]u8) void {
    padCmd(bus, 0x4D, &.{ 0x00, map[0], map[1], map[2], map[3], map[4], map[5] }, old);
}

test "0x4D maps the motors, replies with the old map, and 0x42 then drives them" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    enterConfig(bus);
    var r: [8]u8 = undefined;
    padCmd(bus, 0x44, &.{ 0x00, 0x01, 0x02 }, &r); // analog, unlocked
    mapRumble(bus, .{ 0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xFF }, &r);
    try std.testing.expectEqualSlices(u8, &.{ 0xF3, 0x5A, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, &r);
    leaveConfig(bus);

    padCmd(bus, 0x42, &.{ 0x00, 0x01, 0xC0 }, &r); // TX byte 2 small, byte 3 large
    try expectEqual(@as(u8, 255), bus.sio.pad.motor_small);
    try expectEqual(@as(u8, 0xC0), bus.sio.pad.motor_large);

    padCmd(bus, 0x42, &.{ 0x00, 0x00, 0x40 }, &r);
    try expectEqual(@as(u8, 0), bus.sio.pad.motor_small);
    try expectEqual(@as(u8, 0x40), bus.sio.pad.motor_large);
}

test "unmapping a running motor stops it at the end of the 0x4D" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    enterConfig(bus);
    var r: [8]u8 = undefined;
    mapRumble(bus, .{ 0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xFF }, &r);
    leaveConfig(bus);
    padCmd(bus, 0x42, &.{ 0x00, 0x01, 0xC0 }, &r);
    enterConfig(bus);
    mapRumble(bus, .{ 0xFF, 0x01, 0xFF, 0xFF, 0xFF, 0xFF }, &r); // small unmapped
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xFF }, r[2..8]); // old map
    try expectEqual(@as(u8, 0), bus.sio.pad.motor_small);
    try expectEqual(@as(u8, 0xC0), bus.sio.pad.motor_large);
}

test "before config mode, the legacy encoding drives the small motor" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var r: [4]u8 = undefined;
    padCmd(bus, 0x42, &.{ 0x00, 0x40, 0x01 }, &r);
    try expectEqual(@as(u8, 255), bus.sio.pad.motor_small);
    try std.testing.expectEqualSlices(u8, &.{ 0x41, 0x5A, 0xFF, 0xFF }, &r); // packet unchanged
    padCmd(bus, 0x42, &.{ 0x00, 0x40, 0x00 }, &r);
    try expectEqual(@as(u8, 0), bus.sio.pad.motor_small);
    padCmd(bus, 0x42, &.{ 0x00, 0x00, 0x01 }, &r);
    try expectEqual(@as(u8, 0), bus.sio.pad.motor_small);
}

test "a mode change stops both motors and unmaps them" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    enterConfig(bus);
    var r: [8]u8 = undefined;
    mapRumble(bus, .{ 0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xFF }, &r);
    leaveConfig(bus);
    padCmd(bus, 0x42, &.{ 0x00, 0x01, 0xC0 }, &r);
    bus.sio.pad.pressAnalogButton();
    bus.write16(JOY_CTRL, 0x0000);
    try expectEqual(@as(u8, 0), bus.sio.pad.motor_small);
    try expectEqual(@as(u8, 0), bus.sio.pad.motor_large);
    try expectEqual(@as([6]u8, @splat(0xFF)), bus.sio.pad.rumble_map);
}
```

`savestate_test.zig` (Review Focus 3):

```zig
test "a state saved mid-0x4D finishes the remap after a restore" {
    var a = try Machine.init();
    defer a.deinit();
    const sio = &a.bus.sio;
    // Config mode, small motor mapped and running.
    sio.pad.config = true;
    sio.pad.dualshock = true;
    sio.pad.rumble_map = .{ 0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xFF };
    sio.pad.motor_small = 255;
    for ([_]u8{ 0x01, 0x4D, 0x00, 0xFF, 0x01 }) |b| sio.write(0, b); // three bytes into the remap

    const buf = try saveAlloc(&a);
    defer std.testing.allocator.free(buf);
    var b = try Machine.init();
    defer b.deinit();
    try savestate.load(&b.cpu, buf);

    for ([_]u8{ 0xFF, 0xFF, 0xFF, 0xFF }) |x| b.bus.sio.write(0, x);
    try std.testing.expectEqual(ps1.sio.Sio.SioState.Idle, b.bus.sio.ctrl_state);
    try std.testing.expectEqual(@as(u8, 0), b.bus.sio.pad.motor_small); // unmapped, stopped
    try std.testing.expectEqual([6]u8{ 0xFF, 0x01, 0xFF, 0xFF, 0xFF, 0xFF }, b.bus.sio.pad.rumble_map);
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `zig build test -Dtest-filter=motor` and `zig build test -Dtest-filter=0x4D`
Expected: FAIL (motors stay 0; the old map reply is zeros).

- [ ] **Step 3: Implement**

Add two arms to `transfer`'s switch, and the helpers:

```zig
            0x42 => self.driveRumble(s, byte_in),
            0x4D => self.remapRumble(s, byte_in),
```

```zig
    /// What a read's TX bytes do to the motors.
    fn driveRumble(self: *Self, s: u8, byte_in: u8) void {
        if (self.dualshock) {
            if (s < 2) return;
            switch (self.rumble_map[s - 2]) {
                0x00 => self.motor_small = if (byte_in != 0) 255 else 0,
                0x01 => self.motor_large = byte_in,
                else => {},
            }
        } else if (s == 3) {
            // The single-motor encoding of pads from before the DualShock.
            const on = (self.rx[2] & 0xC0) == 0x40 and (self.rx[3] & 0x01) != 0;
            self.motor_small = if (on) 255 else 0;
        }
    }

    /// Replies with the old map while taking the new one, then stops any
    /// motor the new map no longer reaches.
    fn remapRumble(self: *Self, s: u8, byte_in: u8) void {
        if (s >= 2) {
            self.tx[s] = self.rumble_map[s - 2];
            self.rumble_map[s - 2] = byte_in;
        }
        if (s == self.len - 1) {
            if (std.mem.indexOfScalar(u8, &self.rumble_map, 0x00) == null) self.motor_small = 0;
            if (std.mem.indexOfScalar(u8, &self.rumble_map, 0x01) == null) self.motor_large = 0;
        }
    }
```

Add `const std = @import("std");` at the top of `pad.zig`.

- [ ] **Step 4: Run the tests**

Run: `zig build test`
Expected: PASS, all 23 binaries. Check `wc -l ps1-core/src/sio/*.zig`: both under ~600.

- [ ] **Step 5: Commit**

```bash
zig fmt ps1-core
git add ps1-core
git commit -m "feat(core): DualShock rumble, mapped by 0x4D, with the legacy single-motor encoding before it"
```

---

### Task 4: Recapture the goldens

Read `ps1-test-harnesses` before starting. This task's commit holds the goldens and nothing else.

**Files:**
- Modify: `ps1-core/tests/goldens/trace/*.txt`, `ps1-core/tests/goldens/trace-block/*.txt`, possibly `ps1-core/tests/goldens/pgxp/floors.txt`
- Modify: `.claude/skills/ps1-test-harnesses/SKILL.md`

- [ ] **Step 1: Find which workloads moved for more than the hash**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- verify 2>&1 | tee /tmp/verify.txt` (use the scratchpad, not `/tmp`, if the session lists one)
Expected: every workload diverges in `sio`. Any workload whose first divergence is in ANOTHER region (cpu, ram, ...) is a game that now talks to a DualShock.

- [ ] **Step 2: Prove each such divergence follows a `0x43`**

Invoke the `ps1-debugging-real-games` skill for `ps1-trace`'s invocation. For each workload from Step 1 with a non-SIO divergence, run it under `ps1-trace` with a temporary probe that logs every `Pad.begin` command byte with the instruction count (a `std.log.warn` in `begin`, gated on nothing; it is reverted before the commit), and confirm the first `0x43` comes before the instruction count of the first non-SIO divergence. A non-SIO divergence with no `0x43` before it is a Task 1 bug: stop and fix it there. Record per workload: name, instruction count of the first `0x43`, and which commands it sent.

Remove the probe: `git diff --stat` must show only goldens and the skill afterwards.

- [ ] **Step 3: Recapture both sets**

```bash
zig build trace-golden -Doptimize=ReleaseFast -- capture
zig build trace-golden -Doptimize=ReleaseFast -- capture --engine=cached
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- verify --engine=cached
zig build trace-golden -Doptimize=ReleaseFast -- savestate
```

Expected: the three verifying runs all green.

- [ ] **Step 4: The PGXP floors**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- pgxp`
Expected: green. If a floor now fails on a workload from Step 2 (the game is on a different code path), re-pin it as `ps1-test-harnesses` describes and record why. A floor failing on a workload that sent no `0x43` is a bug, not a re-pin.

- [ ] **Step 5: Record it**

In `.claude/skills/ps1-test-harnesses/SKILL.md`, near the existing recapture history, add a dated paragraph: 2026-10-07 recapture for the DualShock; every workload's `sio` region moved because `hashSio` now hashes `Pad`; the workloads that additionally moved in CPU/RAM, each with the instruction count of its first `0x43` and the commands it sent; and any PGXP floor re-pinned. Note that `v2-synthetic.state` joined `v1-synthetic.state` and neither is ever regenerated.

- [ ] **Step 6: Commit**

```bash
git add ps1-core/tests/goldens .claude/skills/ps1-test-harnesses/SKILL.md
git commit -m "test(golden): recapture for the DualShock pad"
```

---

### Task 5: The C ABI

**Files:**
- Modify: `ps1-capi/src/root.zig` (after `ps1_set_buttons`, ~line 656), `ps1-capi/include/ps1.h` (after `ps1_set_buttons`, ~line 365)
- Test: `ps1-capi/src/capi_test.zig`

**Interfaces:**
- Consumes: `Pad.setSticks`, `Pad.pressAnalogButton`, `Pad.analog/motor_small/motor_large`
- Produces: `ps1_set_analog(Ps1*, uint8_t lx, uint8_t ly, uint8_t rx, uint8_t ry)`, `ps1_press_analog_button(Ps1*)`, `Ps1PadStatus { uint8_t analog, small, large; }`, `ps1_get_pad_status(Ps1*, Ps1PadStatus*)`

- [ ] **Step 1: Write the failing tests**

```zig
test "set_analog reaches the pad in wire order" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    capi.ps1_set_analog(h, 0x10, 0x20, 0x30, 0x40); // lx, ly, rx, ry
    try std.testing.expectEqual([4]u8{ 0x30, 0x40, 0x10, 0x20 }, h.cpu.bus.sio.pad.sticks);
}

test "press_analog_button queues a toggle on the pad" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    capi.ps1_press_analog_button(h);
    try std.testing.expect(h.cpu.bus.sio.pad.toggle_queued);
}

test "get_pad_status reports the mode and both motors" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    var s: capi.Ps1PadStatus = undefined;
    capi.ps1_get_pad_status(h, &s);
    try std.testing.expectEqual(capi.Ps1PadStatus{ .analog = 0, .small = 0, .large = 0 }, s);

    h.cpu.bus.sio.pad.analog = true;
    h.cpu.bus.sio.pad.motor_small = 255;
    h.cpu.bus.sio.pad.motor_large = 0x80;
    capi.ps1_get_pad_status(h, &s);
    try std.testing.expectEqual(capi.Ps1PadStatus{ .analog = 1, .small = 255, .large = 0x80 }, s);
}

test "reset powers the pad up digital with both motors stopped" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    h.cpu.bus.sio.pad.analog = true;
    h.cpu.bus.sio.pad.motor_small = 255;
    h.cpu.bus.sio.pad.motor_large = 0xFF;
    capi.ps1_reset(h);
    var s: capi.Ps1PadStatus = undefined;
    capi.ps1_get_pad_status(h, &s);
    try std.testing.expectEqual(capi.Ps1PadStatus{ .analog = 0, .small = 0, .large = 0 }, s);
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `zig build test -Dtest-filter=pad_status` (and `-Dtest-filter=analog`)
Expected: compile errors, the symbols do not exist.

- [ ] **Step 3: Implement**

`ps1-capi/src/root.zig`, after `ps1_set_buttons`:

```zig
/// The sticks, as the pad reports them: 0x80 centre, Y grows DOWN. Applied
/// to the next packet the game reads.
pub export fn ps1_set_analog(h: *Handle, lx: u8, ly: u8, rx: u8, ry: u8) void {
    h.cpu.bus.sio.pad.setSticks(lx, ly, rx, ry);
}

/// The pad's ANALOG button. Queued until the pad is next idle between
/// packets; the pad ignores it while the game holds the mode lock.
pub export fn ps1_press_analog_button(h: *Handle) void {
    h.cpu.bus.sio.pad.pressAnalogButton();
}

pub const Ps1PadStatus = extern struct {
    analog: u8,
    small: u8,
    large: u8,
};

/// The mode LED and both motors, for the host to show and to rumble with.
/// A reset rebuilds the pad, so it reads digital and still after one.
pub export fn ps1_get_pad_status(h: *Handle, out: *Ps1PadStatus) void {
    const p = &h.cpu.bus.sio.pad;
    out.* = .{ .analog = @intFromBool(p.analog), .small = p.motor_small, .large = p.motor_large };
}
```

`ps1-capi/include/ps1.h`, after `ps1_set_buttons`:

```c
/* Sticks: 0x00..0xFF, 0x80 centre; Y grows DOWN (0xFF = full down). */
void    ps1_set_analog(Ps1*, uint8_t lx, uint8_t ly, uint8_t rx, uint8_t ry);

/* The pad's ANALOG button. Queued; ignored while the game locks the mode. */
void    ps1_press_analog_button(Ps1*);

typedef struct {
    uint8_t analog;  /* 1 = analog mode (the LED) */
    uint8_t small;   /* small motor: 0 or 255 */
    uint8_t large;   /* large motor: 0..255 */
} Ps1PadStatus;
/* Read once after each ps1_run_frame. ps1_reset powers the pad up digital
 * with both motors stopped; a state load restores the motors, so the next
 * poll resumes rumble with no special case. */
void    ps1_get_pad_status(Ps1*, Ps1PadStatus* out);
```

- [ ] **Step 4: Run the tests**

Run: `zig build test` then `zig build capi-lib`
Expected: PASS; the library builds.

- [ ] **Step 5: Commit**

```bash
zig fmt ps1-capi
git add ps1-capi
git commit -m "feat(capi): sticks, the Analog button and the pad's mode and motors"
```

---

### Task 6: Swift bridge and the runner

**Files:**
- Create: `ps1-macos/Sources/PS1/PadState.swift`
- Modify: `ps1-macos/Sources/PS1/Ps1Core.swift:158`, `ps1-macos/Sources/PS1/EmulatorRunner.swift` (fields ~line 81, setters ~line 227, `runLoop` ~line 590)
- Test: `ps1-macos/Tests/PS1Tests/PadStateTests.swift`

**Interfaces:**
- Consumes: Task 5's three C calls
- Produces:
  - `struct Sticks: Equatable, Sendable { var lx, ly, rx, ry: UInt8; static let centred; static func byte(_ v: Float) -> UInt8; init(leftX:leftY:rightX:rightY:) (Float, GameController's Y-up); init(packed: UInt32); var packed: UInt32 }`
  - `struct PadStatus: Equatable, Sendable { var analog: Bool; var small: UInt8; var large: UInt8; static let idle; init(packed: UInt32); var packed: UInt32 }`
  - `Ps1Core.setAnalog(_ s: Sticks)`, `Ps1Core.pressAnalogButton()`, `Ps1Core.padStatus() -> PadStatus`
  - `EmulatorRunner.setSticks(_:)`, `EmulatorRunner.pressAnalogButton()`, `EmulatorRunner.padStatus: PadStatus` (read from any thread), `EmulatorRunner.takeAnalogPress() -> Bool` (internal, the drain `runLoop` uses)

- [ ] **Step 1: Write the failing tests**

`ps1-macos/Tests/PS1Tests/PadStateTests.swift`:

```swift
import Foundation
import Testing
@testable import PS1

struct PadStateTests {
    @Test func stickExtremesAndCentreMapToTheWireBytes() {
        #expect(Sticks.byte(-1) == 0x00)
        #expect(Sticks.byte(0) == 0x80)
        #expect(Sticks.byte(1) == 0xFF)
    }

    @Test func outOfRangeValuesClamp() {
        #expect(Sticks.byte(-1.5) == 0x00)
        #expect(Sticks.byte(2) == 0xFF)
    }

    /// GameController's Y grows UP; the pad's grows DOWN.
    @Test func pushingUpIsZeroOnTheWire() {
        let s = Sticks(leftX: 0, leftY: 1, rightX: 0, rightY: -1)
        #expect(s.ly == 0x00)
        #expect(s.ry == 0xFF)
        #expect(s.lx == 0x80)
    }

    @Test func sticksAndStatusSurviveTheirPacking() {
        let s = Sticks(lx: 1, ly: 2, rx: 3, ry: 4)
        #expect(Sticks(packed: s.packed) == s)
        let p = PadStatus(analog: true, small: 255, large: 0x40)
        #expect(PadStatus(packed: p.packed) == p)
        #expect(PadStatus(packed: PadStatus.idle.packed) == .idle)
    }

    @Test func aPressIsDrainedOnce() throws {
        let core = try Ps1Core()
        let runner = EmulatorRunner(core: core, ring: AudioRing(capacity: EmulatorRunner.ringCapacity), cards: nil)
        #expect(!runner.takeAnalogPress())
        runner.pressAnalogButton()
        runner.pressAnalogButton()
        #expect(runner.takeAnalogPress())
        #expect(!runner.takeAnalogPress())
    }

    @Test func aFreshCoreReportsADigitalPadAtRest() throws {
        let core = try Ps1Core()
        #expect(core.padStatus() == .idle)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `zig build capi-lib metallib && pkill -x Substation; ps1-macos/test.sh`
Expected: build failure, `cannot find 'Sticks' in scope`.

- [ ] **Step 3: Implement**

`ps1-macos/Sources/PS1/PadState.swift`:

```swift
import Foundation

/// The two sticks as the pad reports them: one byte per axis, 0x80 centred,
/// Y growing DOWN, the convention `ps1_set_analog` takes.
struct Sticks: Equatable, Sendable {
    var lx: UInt8 = 0x80
    var ly: UInt8 = 0x80
    var rx: UInt8 = 0x80
    var ry: UInt8 = 0x80

    static let centred = Sticks()

    init(lx: UInt8 = 0x80, ly: UInt8 = 0x80, rx: UInt8 = 0x80, ry: UInt8 = 0x80) {
        self.lx = lx; self.ly = ly; self.rx = rx; self.ry = ry
    }

    /// From GameController's -1...1, whose Y grows UP.
    init(leftX: Float, leftY: Float, rightX: Float, rightY: Float) {
        self.init(lx: Self.byte(leftX), ly: Self.byte(-leftY),
                  rx: Self.byte(rightX), ry: Self.byte(-rightY))
    }

    /// No deadzone here: GameController applies one, and games their own.
    static func byte(_ v: Float) -> UInt8 {
        UInt8(((min(max(v, -1), 1) + 1) * 127.5).rounded())
    }

    /// One word, so it crosses to the emulator thread through an `Atomic`.
    var packed: UInt32 {
        UInt32(lx) | UInt32(ly) << 8 | UInt32(rx) << 16 | UInt32(ry) << 24
    }

    init(packed v: UInt32) {
        self.init(lx: UInt8(truncatingIfNeeded: v), ly: UInt8(truncatingIfNeeded: v >> 8),
                  rx: UInt8(truncatingIfNeeded: v >> 16), ry: UInt8(truncatingIfNeeded: v >> 24))
    }
}

/// What the pad tells the host after a frame: its mode LED and both motors.
struct PadStatus: Equatable, Sendable {
    var analog: Bool
    /// 0 or 255: the small motor has one speed.
    var small: UInt8
    var large: UInt8

    static let idle = PadStatus(analog: false, small: 0, large: 0)

    init(analog: Bool, small: UInt8, large: UInt8) {
        self.analog = analog; self.small = small; self.large = large
    }

    var packed: UInt32 {
        (analog ? 1 : 0) | UInt32(small) << 8 | UInt32(large) << 16
    }

    init(packed v: UInt32) {
        self.init(analog: v & 1 != 0, small: UInt8(truncatingIfNeeded: v >> 8),
                  large: UInt8(truncatingIfNeeded: v >> 16))
    }
}
```

`Ps1Core.swift`, after `setButtons`:

```swift
    func setAnalog(_ s: Sticks) { ps1_set_analog(handle, s.lx, s.ly, s.rx, s.ry) }
    func pressAnalogButton() { ps1_press_analog_button(handle) }

    func padStatus() -> PadStatus {
        var s = Ps1PadStatus()
        ps1_get_pad_status(handle, &s)
        return PadStatus(analog: s.analog != 0, small: s.small, large: s.large)
    }
```

`EmulatorRunner.swift`, beside `buttons`:

```swift
    private let sticks = Atomic<UInt32>(Sticks.centred.packed)
    /// Presses waiting for the emulator thread. A count rather than a flag
    /// only so a press is never lost to a race; the pad itself collapses
    /// several presses before one idle into one toggle.
    private let analogPresses = Atomic<Int>(0)
    /// Published after every frame, for the main actor's 60 Hz poll.
    private let padStatusWord = Atomic<UInt32>(PadStatus.idle.packed)
```

beside `setButtons`:

```swift
    func setSticks(_ s: Sticks) {
        sticks.store(s.packed, ordering: .releasing)
    }

    func pressAnalogButton() {
        analogPresses.wrappingAdd(1, ordering: .acquiringAndReleasing)
    }

    /// `internal` for the test that pins the drain.
    func takeAnalogPress() -> Bool {
        analogPresses.exchange(0, ordering: .acquiringAndReleasing) > 0
    }

    var padStatus: PadStatus {
        PadStatus(packed: padStatusWord.load(ordering: .acquiring))
    }
```

In `runLoop`, after `core.setButtons(...)`:

```swift
            core.setAnalog(Sticks(packed: sticks.load(ordering: .acquiring)))
            if takeAnalogPress() { core.pressAnalogButton() }
```

and right after `core.runFrame()`:

```swift
            padStatusWord.store(core.padStatus().packed, ordering: .releasing)
```

- [ ] **Step 4: Run the tests**

Run: `pkill -x Substation; ps1-macos/test.sh`
Expected: PASS, including the six new tests.

- [ ] **Step 5: Commit**

```bash
git add ps1-macos
git commit -m "feat(macos): the runner carries sticks and the Analog button in and the pad's status out"
```

---

### Task 7: Controller input, the Analog binding and the menu item

**Files:**
- Modify: `ps1-macos/Sources/PS1/InputMap.swift`, `KeyBindings.swift`, `EmulatorViewModel.swift` (`bind(_:)` ~1476, `applyPadInput` ~1515, key capture ~1318-1400), `Settings/ControlsSettingsPane.swift`, `Settings/SettingsCopy.swift`, `Sources/PS1App/MachineCommands.swift`
- Test: `ps1-macos/Tests/PS1Tests/KeyBindingsTests.swift`, `InputMapTests.swift`, `EmulatorViewModelStageTests.swift`

**Interfaces:**
- Consumes: `Sticks`, `EmulatorRunner.setSticks/pressAnalogButton` (Task 6)
- Produces:
  - `InputMap.sticks: Sticks` (centred by default and by `reset()`)
  - `enum PadControl: Hashable { case button(PadButton); case analog }` with `var title: String`
  - `KeyBindings.keys: [PadControl: UInt16]`, `key(for: PadControl) -> UInt16?`, `control(forKey:) -> PadControl?`, `assign(_:to: PadControl) -> Bool`, `static let controls: [PadControl]`, `static let defaults: [PadControl: UInt16]`
  - `EmulatorViewModel.capturing: PadControl?`, `beginCapture(_: PadControl)`, `toggleAnalog()`, `var sticksForTesting: Sticks` (DEBUG)

- [ ] **Step 1: Write the failing tests**

Rewrite `KeyBindingsTests.swift` against `PadControl` (every `.cross` etc. becomes `.button(.cross)`, `button(forKey:)` becomes `control(forKey:)`, `KeyBindings.buttons` becomes `KeyBindings.controls`), and add:

```swift
    @Test func analogIsUnboundByDefault() {
        let b = KeyBindings(defaults: freshDefaults())
        #expect(b.key(for: .analog) == nil)
        #expect(b.isDefault)
    }

    /// A key moves to Analog like it moves between buttons.
    @Test func analogTakesAKeyFromAButton() {
        var b = KeyBindings(defaults: freshDefaults())
        b.assign(6, to: .analog)          // Z, Cross by default
        #expect(b.control(forKey: 6) == .analog)
        #expect(b.key(for: .button(.cross)) == nil)
    }

    /// A map saved before Analog existed has no "analog" entry; it must load,
    /// with Analog unbound and every button where the player left it.
    @Test func aMapSavedBeforeAnalogStillLoads() {
        let d = freshDefaults()
        d.set([String(PadButton.cross.rawValue): 14], forKey: KeyBindings.storageKey)
        let b = KeyBindings(defaults: d)
        #expect(b.key(for: .button(.cross)) == 14)
        #expect(b.key(for: .analog) == nil)
        #expect(b.key(for: .button(.up)) == nil)   // a present map is the whole map
    }

    @Test func analogPersists() {
        let d = freshDefaults()
        var b = KeyBindings(defaults: d)
        b.assign(0, to: .analog)          // A, L2 by default
        #expect(KeyBindings(defaults: d) == b)
    }
```

The defaults test becomes:

```swift
    @Test func everyListedButtonHasADefaultAndNoTwoShareAKey() {
        let buttons = KeyBindings.controls.filter { $0 != .analog }
        let codes = buttons.compactMap { KeyBindings.defaults[$0] }
        #expect(codes.count == buttons.count)
        #expect(Set(codes).count == codes.count)
        #expect(Set(KeyBindings.defaults.keys) == Set(buttons))
    }
```

`InputMapTests.swift`:

```swift
@Test func resetCentresTheSticks() {
    var map = InputMap()
    map.sticks = Sticks(lx: 0, ly: 0, rx: 0xFF, ry: 0xFF)
    map.reset()
    #expect(map.sticks == .centred)
}
```

`EmulatorViewModelStageTests.swift`:

```swift
/// A stick held across an eject is the same trap as a button held across
/// one: the next game must start centred.
@MainActor
@Test func ejectCentresAStickHeldAcrossIt() {
    let model = EmulatorViewModel()
    var held = InputMap()
    held.sticks = Sticks(lx: 0, ly: 0x80, rx: 0x80, ry: 0x80)

    model.simulatePlayingForTesting()
    model.simulatePadInputForTesting(held)
    #expect(model.sticksForTesting.lx == 0)

    model.eject()
    model.simulatePadInputForTesting(held)
    #expect(model.sticksForTesting == .centred)
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `pkill -x Substation; ps1-macos/test.sh`
Expected: build failure, `cannot find 'PadControl' in scope`.

- [ ] **Step 3: `InputMap` and `PadControl`**

`InputMap.swift`:

```swift
struct InputMap {
    private var pressed: UInt16 = 0
    /// Centred for the keyboard, which has no sticks.
    var sticks = Sticks.centred

    var mask: UInt16 { ~pressed }

    mutating func press(_ b: PadButton) { pressed |= b.rawValue }
    mutating func release(_ b: PadButton) { pressed &= ~b.rawValue }
    mutating func reset() {
        pressed = 0
        sticks = .centred
    }
}
```

and below `PadButton.title`:

```swift
/// Anything a key can be bound to: a pad button, or the Analog button, which
/// is not in the button mask (the pad handles it itself).
enum PadControl: Hashable {
    case button(PadButton)
    case analog

    var title: String {
        switch self {
        case .button(let b): return b.title
        case .analog: return "Analog"
        }
    }
}
```

- [ ] **Step 4: `KeyBindings` over `PadControl`**

Replace the body's button-keyed parts:

```swift
    /// WASD is deliberately absent: the D-pad is on the arrows and the face
    /// buttons are on the right hand. Analog is unbound: the keyboard has no
    /// sticks for analog mode to read.
    static let buttonDefaults: [PadButton: UInt16] = [
        .up: 126, .down: 125, .left: 123, .right: 124,
        .cross: 6, .square: 7, .circle: 8, .triangle: 9,   // Z X C V
        .l1: 12, .r1: 13, .l2: 0, .r2: 1,                  // Q W A S
        .start: 36, .select: 49,                           // Return, Space
    ]

    static let defaults: [PadControl: UInt16] =
        Dictionary(uniqueKeysWithValues: buttonDefaults.map { (PadControl.button($0.key), $0.value) })

    /// The order a player reads a pad: D-pad, face buttons, shoulders,
    /// Start/Select, then Analog. L3/R3 are absent: they need a stick to press.
    static let controls: [PadControl] = ([
        .up, .down, .left, .right,
        .cross, .square, .circle, .triangle,
        .l1, .r1, .l2, .r2,
        .start, .select,
    ] as [PadButton]).map(PadControl.button) + [.analog]

    /// The stored name of Analog. Buttons are stored as their raw value, so a
    /// map saved before Analog existed simply has no entry for it.
    private static let analogName = "analog"

    private(set) var keys: [PadControl: UInt16]
```

`init` parses each stored name with:

```swift
    private static func control(named name: String) -> PadControl? {
        if name == analogName { return .analog }
        guard let raw = UInt16(name), let b = PadButton(rawValue: raw) else { return nil }
        return .button(b)
    }

    private static func name(of c: PadControl) -> String {
        switch c {
        case .button(let b): return String(b.rawValue)
        case .analog: return analogName
        }
    }
```

and `key(for:)`, `control(forKey:)`, `assign(_:to:)`, `save()` keep their current bodies with `PadButton` replaced by `PadControl` and the name conversion going through those two helpers.

- [ ] **Step 5: The view model**

1. `capturingButton: PadButton?` → `capturing: PadControl?`; `beginCapture(_ c: PadControl)`; in `captureKey`, `keyBindings.assign(keyCode, to: c)`.
2. `keyDown`:

```swift
        guard stage == .playing, let c = keyBindings.control(forKey: keyCode) else { return false }
        switch c {
        case .button(let b):
            input.press(b)
            runner?.setButtons(input.mask)
        case .analog:
            toggleAnalog()
        }
        return true
```

`keyUp`: the same, with `case .analog: break` (the press is the event).

3. Add:

```swift
    /// The pad's Analog button: from the Home button, a bound key or
    /// Machine ▸ Toggle Analog. The pad decides whether it takes effect.
    func toggleAnalog() {
        guard stage == .playing else { return }
        runner?.pressAnalogButton()
    }
```

4. `bind(_:)`: after the existing presses, before `let snapshot = m`:

```swift
            if pad.leftThumbstickButton?.isPressed == true  { m.press(.l3) }
            if pad.rightThumbstickButton?.isPressed == true { m.press(.r3) }
            m.sticks = Sticks(leftX: pad.leftThumbstick.xAxis.value,
                              leftY: pad.leftThumbstick.yAxis.value,
                              rightX: pad.rightThumbstick.xAxis.value,
                              rightY: pad.rightThumbstick.yAxis.value)
```

and after setting `valueChangedHandler`:

```swift
        // Home is the Analog button. The system takes it for its own
        // overlay unless told not to.
        if let home = pad.buttonHome {
            home.preferredSystemGestureState = .disabled
            home.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                MainActor.assumeIsolated { self?.toggleAnalog() }
            }
        }
```

5. `applyPadInput`: add `runner?.setSticks(snapshot.sticks)` after `setButtons`. In `releaseAllKeys`, add `runner?.setSticks(input.sticks)`. `teardownRunningMachine` already calls `input.reset()`, which now centres.
6. In the DEBUG testing seams: `var sticksForTesting: Sticks { input.sticks }`.

- [ ] **Step 6: Settings and the menu**

`ControlsSettingsPane.swift`: `ForEach(KeyBindings.controls, id: \.self) { control in LabeledContent(control.title) { KeyBindingField(key: model.keyBindings.key(for: control), isCapturing: model.capturing == control, begin: { model.beginCapture(control) }) } }`.

`SettingsCopy.swift`: replace `controllers`' summary and add `analogButton`; add `analogButton` to `allInfo`.

```swift
    static let controllers = SettingInfo(
        title: "Game Controllers",
        summary: "PlayStation, Xbox and other controllers supported by macOS work as soon as they connect, over Bluetooth or USB, with no setup.",
        details: "The controller's sticks are the analog sticks of a DualShock. Most games that use them switch the pad to analog mode themselves. Older games wait for the Analog button, which is the controller's Home button."
    )

    static let analogButton = SettingInfo(
        title: "Analog Button",
        summary: "Switches the pad between digital and analog mode, as the button in the middle of a DualShock does.",
        details: "On a controller it is the Home button. It is also in the Machine menu. A game can lock the mode, and while it does the button does nothing."
    )
```

Add a row for `analogButton` in the "Shortcuts While Playing" section: `SettingRow(SettingsCopy.analogButton) { KeyCap("Home") }`.

`MachineCommands.swift`, after Reset:

```swift
            Button("Toggle Analog") { model.toggleAnalog() }
                .disabled(model.stage != .playing)
```

- [ ] **Step 7: Run the tests**

Run: `pkill -x Substation; ps1-macos/test.sh`
Expected: PASS, including `SettingsCopyTests` (the new copy has no dashes and ends in full stops).

- [ ] **Step 8: Commit**

```bash
git add ps1-macos
git commit -m "feat(macos): controller sticks and L3/R3 reach the pad, and the Analog button is bindable"
```

---

### Task 8: The pad poll and the Analog notice

**Files:**
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift` (beside `startSamplingFps` ~1228, teardown ~1193), `GameWindowView.swift:52`, `GameHUD.swift` (new `PadNotice` view beside `SpeedBadge`)
- Test: `ps1-macos/Tests/PS1Tests/EmulatorViewModelStageTests.swift`

**Interfaces:**
- Consumes: `EmulatorRunner.padStatus` (Task 6)
- Produces: `EmulatorViewModel.padNotice: String?`; `func padStatusChanged(_ s: PadStatus)` (private; Task 9 adds the haptics call inside it); `simulatePadStatusForTesting(_:)` (DEBUG)

- [ ] **Step 1: Write the failing test**

```swift
/// The notice follows the pad's own mode bit, so it also reports a game
/// switching the mode itself, and says nothing while the mode holds.
@MainActor
@Test func theAnalogNoticeFollowsTheModeBit() {
    let model = EmulatorViewModel()
    model.simulatePlayingForTesting()
    model.simulatePadStatusForTesting(.idle)
    #expect(model.padNotice == nil)

    model.simulatePadStatusForTesting(PadStatus(analog: true, small: 0, large: 0))
    #expect(model.padNotice == "Analog on")

    model.simulatePadStatusForTesting(PadStatus(analog: false, small: 0, large: 0))
    #expect(model.padNotice == "Analog off")
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `pkill -x Substation; ps1-macos/test.sh`
Expected: build failure, no `simulatePadStatusForTesting`.

- [ ] **Step 3: Implement**

In `EmulatorViewModel`:

```swift
    /// "Analog on"/"Analog off", for a moment after the pad's mode changes.
    private(set) var padNotice: String?
    private var padNoticeTask: Task<Void, Never>?
    private var padTask: Task<Void, Never>?
    /// The mode last seen, so only a CHANGE shows the notice. Each new
    /// runner starts from a digital pad.
    private var lastPadAnalog = false

    /// Polls the pad's mode and motors at the display's rate. The status is
    /// an atomic on the runner, so a poll costs a load; the rumble it feeds
    /// must start within a frame of the game asking for it.
    private func startWatchingPad() {
        padTask?.cancel()
        lastPadAnalog = false
        padTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let runner = self.runner else { return }
                self.padStatusChanged(runner.padStatus)
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func padStatusChanged(_ s: PadStatus) {
        if s.analog != lastPadAnalog {
            lastPadAnalog = s.analog
            showPadNotice(s.analog ? "Analog on" : "Analog off")
        }
    }

    private func showPadNotice(_ text: String) {
        padNotice = text
        padNoticeTask?.cancel()
        padNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.padNotice = nil
        }
    }
```

Call `startWatchingPad()` wherever `startSamplingFps()` is called. In `teardownRunningMachine`, beside `fpsTask?.cancel()`: `padTask?.cancel(); padTask = nil; padNoticeTask?.cancel(); padNotice = nil`. DEBUG seam: `func simulatePadStatusForTesting(_ s: PadStatus) { padStatusChanged(s) }`.

`GameHUD.swift`, beside `SpeedBadge`:

```swift
/// The pad's mode, for a moment after it changes. Shown with the OSD hidden,
/// like `SpeedBadge`: the press that caused it came from a controller, not
/// the pointer.
struct PadNotice: View {
    let text: String?

    var body: some View {
        Label(text ?? "", systemImage: "gamecontroller.fill")
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .opacity(text == nil ? 0 : 1)
            .animation(.easeInOut(duration: 0.15), value: text)
            .allowsHitTesting(false)
            .accessibilityHidden(text == nil)
    }
}
```

`GameWindowView.swift`, after the `SpeedBadge` block:

```swift
                PadNotice(text: model.padNotice)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 36)
```

- [ ] **Step 4: Run the tests**

Run: `pkill -x Substation; ps1-macos/test.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ps1-macos
git commit -m "feat(macos): a notice when the pad switches between analog and digital"
```

---

### Task 9: Rumble through Core Haptics

**Files:**
- Create: `ps1-macos/Sources/PS1/PadHaptics.swift`, `ps1-macos/Sources/PS1/VibrationSetting.swift`
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift` (`bind(_:)`, `padStatusChanged`, teardown, `observeControllers`, resign-active observer ~line 166), `Settings/ControlsSettingsPane.swift`, `Settings/SettingsCopy.swift`
- Test: `ps1-macos/Tests/PS1Tests/PadHapticsTests.swift`, `VibrationSettingTests.swift`

**Interfaces:**
- Consumes: `PadStatus` (Task 6), `padStatusChanged` (Task 8)
- Produces: `struct MotorDrive: Equatable { var large: Float; var small: Bool; static let stopped; init(status: PadStatus, allowed: Bool); var combined: Float }`; `@MainActor final class PadHaptics { func noteInput(from: ObjectIdentifier); func drive(_: MotorDrive); func stop(); func controllerDisconnected() }`; `struct VibrationSetting { static let defaultsKey = "vibration"; var enabled: Bool; mutating func set(_:) }`; `EmulatorViewModel.vibration: Bool`

- [ ] **Step 1: Write the failing tests**

`PadHapticsTests.swift`:

```swift
import Testing
@testable import PS1

struct MotorDriveTests {
    @Test func theLargeMotorScalesAndTheSmallOneSwitches() {
        let d = MotorDrive(status: PadStatus(analog: true, small: 255, large: 0x80), allowed: true)
        #expect(d.large == Float(0x80) / 255)
        #expect(d.small)
    }

    @Test func aStillPadDrivesNothing() {
        #expect(MotorDrive(status: .idle, allowed: true) == .stopped)
    }

    /// Paused, a dialog up, the app in the background or Vibration off: the
    /// motors stop, and the same status drives them again once allowed,
    /// because the motor values are machine state, not events.
    @Test func disallowedStopsAndReallowedResumes() {
        let s = PadStatus(analog: true, small: 255, large: 0xFF)
        #expect(MotorDrive(status: s, allowed: false) == .stopped)
        let resumed = MotorDrive(status: s, allowed: true)
        #expect(resumed.large == 1)
        #expect(resumed.small)
    }

    /// A controller with one actuator group plays whichever motor is stronger.
    @Test func oneEngineTakesTheStrongerMotor() {
        #expect(MotorDrive(large: 0.25, small: false).combined == 0.25)
        #expect(MotorDrive(large: 0.25, small: true).combined == 1)
        #expect(MotorDrive.stopped.combined == 0)
    }
}
```

`VibrationSettingTests.swift`:

```swift
import Foundation
import Testing
@testable import PS1

private func freshDefaults() -> UserDefaults {
    let name = "VibrationSettingTests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

struct VibrationSettingTests {
    /// Default ON, so absence must not read as false.
    @Test func absentMeansOn() {
        #expect(VibrationSetting(defaults: freshDefaults()).enabled)
    }

    @Test func offPersists() {
        let d = freshDefaults()
        var s = VibrationSetting(defaults: d)
        s.set(false)
        #expect(!VibrationSetting(defaults: d).enabled)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `pkill -x Substation; ps1-macos/test.sh`
Expected: build failure, no `MotorDrive`.

- [ ] **Step 3: `VibrationSetting`**

```swift
import Foundation

/// Whether the game's rumble reaches the controller. Defaults to ON, so the
/// key's absence is probed with `object(forKey:)`: `bool(forKey:)` would read
/// it as off.
struct VibrationSetting {
    static let defaultsKey = "vibration"

    private let defaults: UserDefaults
    private let key: String
    private(set) var enabled: Bool

    init(key: String = VibrationSetting.defaultsKey, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = key
        self.enabled = defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    mutating func set(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: key)
    }
}
```

- [ ] **Step 4: `PadHaptics`**

```swift
import CoreHaptics
import GameController

/// What the two motors should be doing, in Core Haptics' terms.
struct MotorDrive: Equatable {
    /// The large (left) motor, 0...1.
    var large: Float
    /// The small (right) motor: one speed, on or off.
    var small: Bool

    static let stopped = MotorDrive(large: 0, small: false)

    init(large: Float, small: Bool) {
        self.large = large
        self.small = small
    }

    /// `allowed` folds in every reason to keep still: Vibration off, the game
    /// paused, a dialog up, the app in the background. A motor left on with
    /// the emulator stopped would vibrate forever.
    init(status: PadStatus, allowed: Bool) {
        guard allowed else { self = .stopped; return }
        self.init(large: Float(status.large) / 255, small: status.small != 0)
    }

    /// For a controller with one actuator group: whichever motor is stronger.
    var combined: Float { max(large, small ? 1 : 0) }
}

/// The game's rumble on the controller that last sent input.
///
/// Two engines, one per handle, laid out as the original DualShock is: the
/// large motor in the left grip, the small one in the right. Each plays one
/// looping continuous event, and a motor's level reaches it as the dynamic
/// intensity, sent only when it changes. A controller without both handles
/// gets one engine over `.handles`; one without haptics, nothing.
@MainActor
final class PadHaptics {
    private enum Role { case large, small, combined }

    private struct Channel {
        let role: Role
        let engine: CHHapticEngine
        let player: CHHapticAdvancedPatternPlayer
        var level: Float = 0
    }

    private var target: ObjectIdentifier?
    private var channels: [Channel] = []
    private var built = false
    private var applied = MotorDrive.stopped

    /// Switching controllers stops the old one before the new one is used.
    func noteInput(from id: ObjectIdentifier) {
        guard id != target else { return }
        tearDown()
        target = id
    }

    func drive(_ d: MotorDrive) {
        guard d != applied else { return }
        if !built { build() }
        for i in channels.indices {
            set(&channels[i], to: level(of: channels[i].role, in: d))
        }
        applied = d
    }

    func stop() { drive(.stopped) }

    func controllerDisconnected() {
        tearDown()
        target = nil
    }

    private func level(of role: Role, in d: MotorDrive) -> Float {
        switch role {
        case .large: return d.large
        case .small: return d.small ? 1 : 0
        case .combined: return d.combined
        }
    }

    /// A stopped player, not a silent one, at zero: a running continuous
    /// event at zero intensity still keeps the actuator powered.
    private func set(_ c: inout Channel, to level: Float) {
        guard level != c.level else { return }
        if level == 0 {
            try? c.player.stop(atTime: CHHapticTimeImmediate)
        } else {
            if c.level == 0 { try? c.player.start(atTime: CHHapticTimeImmediate) }
            try? c.player.sendParameters(
                [CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: level, relativeTime: 0)],
                atTime: CHHapticTimeImmediate)
        }
        c.level = level
    }

    private func build() {
        built = true
        guard let id = target,
              let controller = GCController.controllers().first(where: { ObjectIdentifier($0) == id }),
              let haptics = controller.haptics else { return }
        let localities = haptics.supportedLocalities
        if localities.contains(.leftHandle), localities.contains(.rightHandle),
           let large = channel(.large, haptics, .leftHandle, sharpness: 0.2),
           let small = channel(.small, haptics, .rightHandle, sharpness: 0.9) {
            channels = [large, small]
        } else if let one = channel(.combined, haptics, .handles, sharpness: 0.5) {
            channels = [one]
        }
    }

    private func channel(_ role: Role, _ haptics: GCDeviceHaptics,
                         _ locality: GCHapticsLocality, sharpness: Float) -> Channel? {
        guard let engine = haptics.createEngine(withLocality: locality) else { return nil }
        do {
            // A continuous event lasts at most 30 s; the player loops it.
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: 0, duration: 30)
            let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
            player.loopEnabled = true
            // The server reset the engine: rebuild and replay what was asked.
            engine.resetHandler = { [weak self] in
                Task { @MainActor in self?.rebuild() }
            }
            // Stopped from outside (the controller slept, the system took
            // it): forget it, so the next change builds afresh.
            engine.stoppedHandler = { [weak self] _ in
                Task { @MainActor in self?.tearDown() }
            }
            try engine.start()
            return Channel(role: role, engine: engine, player: player)
        } catch {
            return nil
        }
    }

    private func rebuild() {
        let wanted = applied
        tearDown()
        drive(wanted)
    }

    private func tearDown() {
        for c in channels {
            // Detached first: a handler queued by this very stop would
            // otherwise land after a rebuild and tear the new engines down.
            c.engine.resetHandler = {}
            c.engine.stoppedHandler = { _ in }
            try? c.player.stop(atTime: CHHapticTimeImmediate)
            c.engine.stop()
        }
        channels = []
        built = false
        applied = .stopped
    }
}
```

- [ ] **Step 5: Wire it into the view model**

```swift
    private var vibrationSetting = VibrationSetting()
    var vibration: Bool {
        get { vibrationSetting.enabled }
        set { vibrationSetting.set(newValue) }
    }
    private let haptics = PadHaptics()

    private var rumbleAllowed: Bool {
        vibration && stage == .playing && !isPaused && !isDialogShown && (NSApp?.isActive ?? true)
    }
```

`padStatusChanged` gains, after the notice: `haptics.drive(MotorDrive(status: s, allowed: rumbleAllowed))`.

In `bind(_:)`: before the snapshot crosses, `let source = pad.controller.map(ObjectIdentifier.init)`, and inside the `MainActor.assumeIsolated` block, after `applyPadInput`: `if let source { self?.haptics.noteInput(from: source) }`.

`observeControllers`: add a `.GCControllerDidDisconnect` observer, same shape as the connect one, whose body is `self?.haptics.controllerDisconnected()`.

Explicit stops, so the motors go still immediately rather than at the next poll: in `teardownRunningMachine` after `padTask?.cancel()`: `haptics.stop()`; in the `didResignActiveNotification` handler: `self?.haptics.stop()`. Pause and dialogs are covered by `rumbleAllowed` on the next 16 ms poll, which keeps running while paused.

- [ ] **Step 6: The setting**

`SettingsCopy.swift`, add and list in `allInfo`:

```swift
    static let vibration = SettingInfo(
        title: "Vibration",
        summary: "Sends the game's rumble to your controller.",
        details: "Works with DualShock 4, DualSense and Xbox controllers. The large motor plays in the left grip and the small one in the right. Vibration stops whenever the game is paused or Substation is in the background."
    )
```

`ControlsSettingsPane.swift`, a new section above the Controllers one: `Section("Controller") { SettingToggle(SettingsCopy.vibration, isOn: $model.vibration) }`.

- [ ] **Step 7: Run the tests**

Run: `pkill -x Substation; ps1-macos/test.sh`
Expected: PASS.

- [ ] **Step 8: Manual check**

`zig build macos`, open `zig-out/Substation.app`, and with Crash Bandicoot: Warped on a DualShock 4 or DualSense (and a Pro Controller if one is to hand):

1. Crash runs with the left stick; the notice reads "Analog on" when the game switches.
2. Vibration on a box break or a hit.
3. ⌘P while rumbling: still at once. Resume: rumble returns on the next game event.
4. ⌘Tab away while rumbling: still.
5. Eject while rumbling: still.
6. Pick up a second controller and press a button: the first goes still.
7. Turn Vibration off in Settings ▸ Controls: no rumble.
8. Home toggles Analog in a game that waits for it (the notice shows), and does not open the system overlay.

Record each result. Whatever the Pro Controller does goes into `ps1-macos-app` in Task 10.

- [ ] **Step 9: Commit**

```bash
git add ps1-macos
git commit -m "feat(macos): the game's rumble on the controller through Core Haptics"
```

---

### Task 10: Documentation

**Files:**
- Modify: `.claude/skills/ps1-core-subsystems/SKILL.md`, `.claude/skills/ps1-macos-app/SKILL.md`, `CLAUDE.md`

- [ ] **Step 1: `ps1-core-subsystems`**

Replace the bullet that begins "The pad reports as a **digital** controller (ID `0x41`, 5-byte packet)..." with the pad as it now is: a DualShock in `sio/pad.zig` that powers up digital; the reply decided at the command byte and clocked out by step; config mode latched at a packet's END (so a deselect mid-`0x43` changes nothing); the Analog button queued until `idle()`; `status` `0x00` after a toggle on a pad that has seen config mode; rumble by `0x4D` map once `dualshock` is set and the legacy single-motor encoding before; every mode change stops and unmaps both motors. Add to the savestate table's note: `SIO ` is v2; v1's per-byte pad tags 2..8 load as `.Pad` at step `tag - 1`, and the card tags keep their numbers because `SioState` is explicitly numbered.

- [ ] **Step 2: `ps1-macos-app`**

Add a section: sticks cross as four bytes beside the mask, Y negated, no app deadzone; L3/R3 from the thumbstick buttons; the Analog button is Home (`preferredSystemGestureState = .disabled`), a bindable `PadControl.analog` stored under `"analog"` in the same dictionary, and Machine ▸ Toggle Analog; the 16 ms pad poll feeds the notice and `PadHaptics`; rumble follows the controller that last sent input, two handle engines or one `.handles` engine, stopped by `rumbleAllowed` and explicitly on teardown, deactivation and disconnect; `VibrationSetting` defaults on and is probed with `object(forKey:)`. Add the Task 9 manual results, the Pro Controller's included.

- [ ] **Step 3: `CLAUDE.md`**

In the repository layout, `sio.zig` under `ps1-core/src/` becomes `sio/  sio.zig (registers, /ACK, memory card) + pad.zig (the DualShock)`. In "Rules that must not be broken" under Core subsystems, add: **The pad's config mode changes at a packet's LAST byte, and the Analog button only at idle.** A deselect mid-packet must leave the mode as it was, and a reply is never re-shaped mid-way.

- [ ] **Step 4: Commit**

```bash
git add .claude/skills CLAUDE.md
git commit -m "docs: the DualShock pad, its savestate translation and the app's rumble"
```
