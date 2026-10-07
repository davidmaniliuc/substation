# Analog controller (DualShock): sticks, config mode and rumble

Status: design, awaiting review.

## Goal

Port 1's pad becomes a DualShock: two analog sticks, the config-mode protocol
DualShock-aware games use to switch it into analog mode, and both rumble motors
forwarded to the host controller through Core Haptics.

Success is:

1. A DualShock game (Crash Warped, Crash 2) switches the pad to analog on its
   own and reads the sticks, and its vibration reaches a DualShock 4, DualSense
   or Xbox controller.
2. A dual-analog-era game that waits for the player to press ANALOG gets there
   through a bound Analog button.
3. A digital-only game sees exactly the packet it sees today, byte for byte.

Non-goals: a pad on port 2, multitap, light guns, NeGcon, stick sensitivity or
deadzone settings, keyboard stick emulation, a per-game "start in analog"
setting, and analog support in `ps1-wasm` (a known parity gap, recorded here
so it is not mistaken for an oversight).

## What exists today

- `sio.zig` (575 lines, budget ~600) models the pad as nine named states
  (`AwaitingCmd`, `CtrlAwaitingTap`, `CtrlSendingButtonsLow/High`,
  `CtrlJoyRightX..LeftY`) and answers only `0x42`. `analog_enabled` is never
  set, so the stick states are unreachable.
- `joy_rx/ry/lx/ly`, `motor_right_small`, `motor_left_large` exist and are
  saved, but the motor capture is wrong: it latches TX bytes 4 and 5
  unconditionally, ignoring the `0x4D` mapping and the legacy single-motor
  encoding.
- `ps1_set_buttons` is the only input call in the C ABI. The app's
  `GCExtendedGamepad` handler already maps L3/R3 into the mask, sends no
  sticks, and nothing in `ps1-macos/` uses haptics.

## Hardware behaviour

The pad powers up **digital**. The ID byte is `mode << 4 | halfwords`:

| Mode    | ID     | Reply after `0x5A`                              |
| ------- | ------ | ----------------------------------------------- |
| digital | `0x41` | 2 button bytes                                  |
| analog  | `0x73` | 2 button bytes, RX, RY, LX, LY                  |
| config  | `0xF3` | 6 bytes, per command                            |

Every reply is `ID, status, b2..b7` (8 bytes in analog/config, 4 in digital).
`status` is `0x5A`, except `0x00` after an Analog-button toggle on a pad that
has entered config mode (that is how a game notices the change).

Commands (the byte after the `0x01` address):

| Cmd    | When          | Effect                                                               | Reply b2..b7                    |
| ------ | ------------- | -------------------------------------------------------------------- | ------------------------------- |
| `0x42` | always        | read pad; TX b2..b7 drive mapped motors                              | buttons (+ sticks)              |
| `0x43` | always        | rx[2]==1 enters config, else leaves; first entry sets `dualshock`    | as `0x42` outside config, else zeros |
| `0x44` | config only   | rx[2] 0/1 sets digital/analog; rx[3] 2/3 unlocks/locks; resets rumble map | zeros                      |
| `0x45` | config only   | report mode                                                          | `01 02 <analog> 02 01 00`       |
| `0x46` | config only   | rx[2]=0 → `01 02 00 0A`; rx[2]=1 → `01 01 01 14` (in b4..b7)        | zeros otherwise                 |
| `0x47` | config only   | rx[2] != 0 zeroes b4..b7                                             | `00 00 02 00 01 00`             |
| `0x4C` | config only   | b5 = `0x04` for rx[2]=0, `0x07` for rx[2]=1                          | zeros otherwise                 |
| `0x4D` | config only   | b2..b7 replies the OLD map, rx[2..7] is the NEW map                  | old map                         |
| other  | —             | no /ACK; the pad falls back to idle (today's unknown-command path)   | —                               |

`0x44`..`0x4D` outside config mode are "other".

**Rumble.** `rumble_map[6]` starts all `0xFF`. Once `dualshock` is set, during
a `0x42` read the TX byte at position `i` (2..7) drives `rumble_map[i-2]`:
`0x00` the small motor (on iff the byte is non-zero, reported as 0 or 255),
`0x01` the large motor (0..255), anything else nothing. Ending a `0x4D` stops
any motor no longer mapped. Before `dualshock` is set, the legacy encoding
applies: small motor 255 iff `(rx[2] & 0xC0) == 0x40 && (rx[3] & 1)`, else 0.
Any mode change (by `0x44` or the button) resets the map to `0xFF` and stops
both motors.

**The Analog button** queues a toggle, applied when the pad is next idle
between packets, so a packet in flight is never re-shaped mid-reply. It does
nothing while the game holds the lock. Applying it flips analog mode, resets
rumble, and sets `status = 0x00` if `dualshock` is set. The reference also
carries a per-game workaround here (resetting config mode for titles not
flagged as DualShock-capable); we have no such flag and take the hardware
behaviour.

## Design

### Core: `sio/` becomes a directory

Following the repo's split convention:

- `ps1-core/src/sio/sio.zig`: the `Sio` struct as today, minus the pad:
  registers, port select, /ACK and IRQ deferral, `ackDelay`, the memory card.
- `ps1-core/src/sio/pad.zig`: `Pad`, the DualShock.
- `root.zig` keeps re-exporting `ps1_core.sio.Sio` under the old path.

`Pad` owns:

```
buttons: u16, sticks: [4]u8 (RX, RY, LX, LY; 0x80 centre),
analog: bool, config: bool, dualshock: bool, locked: bool,
status: u8, rumble_map: [6]u8, motor_small: u8, motor_large: u8,
toggle_queued: bool,
command: u8, tx: [8]u8, rx: [8]u8, step: u8, len: u8
```

Interface:

- `begin(cmd) bool`: called on the command byte. Builds `tx` for that command
  and returns whether the pad answers it. Returns false for unknown commands
  and `0x44`..`0x4D` outside config.
- `transfer(byte_in) struct { out: u8, more: bool }`: records `rx[step]`, runs
  the command's per-step effect, returns `tx[step]`, advances; `more` is false
  on the last byte.
- `idle()`: called whenever the transfer state resets (packet end, deselect,
  SIO reset); applies a queued toggle.
- `pressAnalogButton()`, `setSticks(...)`, `setButtons(...)`, and the status
  getter.

`SioState`'s nine pad states collapse into one `.Pad`. `ackDelay(.Pad)` is
`pad_ack_delay`; the switch stays exhaustive. The opening exchange (ID, then
`0x5A`) becomes `tx[0]`/`tx[1]` of the pad's reply, so the bytes on the wire
are unchanged for `0x42`. Port 2 still answers nothing.

### Savestates

`SIO ` goes from version 1 to 2. v2 writes `Pad`'s fields by hand in place of
`buttons`/`analog_enabled`/`joy_*`/`motor_*`.

Loading v1:

- `analog_enabled` → `analog`; `config`, `dualshock`, `locked` false;
  `status 0x5A`; `rumble_map` all `0xFF`; motors as saved.
- A v1 `ctrl_state` tag is translated: `Idle`/memcard states keep their
  meaning; `AwaitingCmd` stays; each `Ctrl*` state becomes `.Pad` at the step
  it represents (`CtrlAwaitingTap` = step 1 ... `CtrlJoyLeftY` = step 7), with
  `command = 0x42` and `tx` rebuilt from the saved buttons and sticks. The v1
  tag VALUES are listed explicitly in the loader, since the enum no longer has
  them.

New range checks (`StateCorrupt`): `len` not in {4, 8}, `step >= len`,
`command` not one the pad answers.

A `v2-synthetic.state` fixture joins `v1-synthetic.state`; v1 must keep
loading.

### Goldens

`state_hash.zig`'s `hashSio` is rewritten by hand over the new fields, so the
SIO region hash moves on every workload even where behaviour does not. Order:

1. Land the refactor and run `trace-golden -- verify`: every region other than
   SIO must match on every workload that never sends `0x43`. A non-SIO
   divergence there is a bug in the refactor.
2. Workloads whose game probes for a DualShock will additionally diverge in
   CPU/RAM. Confirm from a command log that the first divergence follows a
   `0x43`; that is the feature working.
3. Recapture as its own commit, and record in `ps1-test-harnesses` which
   workloads moved for reason 2.

`trace-golden -- savestate` must pass after the recapture.

### C ABI

```c
/* Sticks: 0x00..0xFF, 0x80 centre; Y grows DOWN (0xFF = full down). */
void ps1_set_analog(Ps1*, uint8_t lx, uint8_t ly, uint8_t rx, uint8_t ry);

/* The pad's ANALOG button. Queued; ignored while the game locks the mode. */
void ps1_press_analog_button(Ps1*);

typedef struct {
    uint8_t analog;  /* 1 = analog mode (the LED) */
    uint8_t small;   /* small motor: 0 or 255 */
    uint8_t large;   /* large motor: 0..255 */
} Ps1PadStatus;
/* Read once after each ps1_run_frame. */
void ps1_get_pad_status(Ps1*, Ps1PadStatus* out);
```

`ps1_reset` powers the pad up digital with both motors stopped. A state load
restores the motors, so the next poll resumes rumble with no special case.

### App

**Input.** `bind(_:)` reads `leftThumbstick`/`rightThumbstick` beside the
buttons: `byte = round((v + 1) * 127.5)`, Y negated first. The snapshot that
crosses to the main actor grows from a `UInt16` mask to the mask plus four
bytes, and `EmulatorRunner` forwards sticks the way it forwards buttons. No
app-side deadzone: GameController applies one, and games apply their own.

**Analog button.** Defaults to the controller's Home/Guide button
(`buttonHome`), bindable in `KeyBindings` for the keyboard, and a Controls ▸
Toggle Analog menu item. A HUD notice ("Analog on" / "Analog off") follows the
status `analog` bit, so it also reports a game switching the mode itself.

**Rumble** (`PadHaptics.swift`).

- Target: the controller that delivered the most recent input; switching
  controllers stops the old one.
- `controller.haptics?.createEngine(withLocality: .leftHandle)` for the
  large motor and `.rightHandle` for the small one (the original DualShock's
  layout). If either is unavailable, one `.handles` engine plays
  `max(large, small)`. `haptics == nil` means no rumble, silently.
- Each engine runs one looping continuous event through a
  `CHHapticAdvancedPatternPlayer`. Large motor: intensity `large / 255`, low
  sharpness. Small motor: intensity 1.0, high sharpness, while on. Parameters
  are sent only when a value changes.
- Stop on: pause, a dialog shown, eject/teardown, app deactivation,
  controller disconnect, Vibration turned off. A motor left on with the
  emulator stopped would vibrate forever.
- `resetHandler` restarts the engines; `stoppedHandler` clears them so the
  next change rebuilds.
- Settings: "Vibration", default on.

**Controller support.** DualShock 4, DualSense and Xbox controllers are
documented haptics targets. The Switch Pro Controller is plausible but
unverified: macOS 27's `GameController.framework` ships
`ProControllerHapticCapabilityGraph.json` with `Left Handle`/`Right Handle`
actuators of type 1 (DualShock's graph uses type 0), but no runtime test has
been run. Whatever the manual test finds goes into `ps1-macos-app`.

## Testing

**Core, `sio_test.zig`:**

- digital `0x42` packet byte-identical to today's, IDs and /ACK pattern
  included
- `0x43` enter/leave; `0xF3` ID inside config; `dualshock` set on first entry
- `0x44` analog on/off and lock; lock blocks `pressAnalogButton`
- `0x45`, `0x46`, `0x47`, `0x4C` replies
- `0x4D` map, then `0x42` driving small and large; unmapping stops a motor
- legacy single-motor rumble before `dualshock`
- toggle pressed mid-packet applies only at idle; `status` becomes `0x00`
- `0x44`..`0x4D` outside config get no /ACK
- the pad still uses `pad_ack_delay`; port 2 still silent

**Savestates:** v1 fixture loads (including a mid-packet `Ctrl*` state
resuming at the right byte); v2 round-trip; each new range check refuses.

**`capi_test`:** `ps1_set_analog` reaches the pad; `ps1_get_pad_status`
reports mode and motors; `ps1_reset` clears them.

**Harnesses:** `zig build test`, `trace-golden -- verify` and `-- savestate`
per the golden order above (both `-Doptimize=ReleaseFast`).

**Swift:** unit tests for stick-to-byte conversion (−1, 0, +1, Y inversion)
and for status-to-haptic-parameters mapping. Manual: Crash Warped on a
DualShock 4, a DualSense and a Pro Controller; vibration on in-game events,
stops on pause and eject, Analog toggle HUD.
