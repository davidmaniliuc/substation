# Multi-disc swap and library grouping — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a multi-disc game be played past its first disc, and show its discs as one library tile.

**Architecture:** The CDROM gains a shell (tray) with the sticky status bit 4 that PSX-SPX describes, so a swap is *observable* by the running game rather than a silent slice replacement. `ps1_swap_disc` exposes it over the C ABI; the macOS app drives it from the emulator thread, offers **Machine ▸ Change Disc**, and folds sibling discs into one tile behind a **Merge Multi-Disc Games** setting.

**Tech Stack:** Zig 0.16.0 (`ps1-core`, `ps1-capi`, `ps1-golden`), Swift 6 + SwiftUI + swift-testing (`ps1-macos`, built with `xcodebuild`).

**Spec:** `docs/superpowers/specs/2026-08-31-multi-disc-swap-and-library-grouping-design.md`

## Global Constraints

- **Zig must be 0.16.0.** `zig version` to confirm. The std API in this tree (`std.Io.Dir.cwd()`, `std.ArrayList(...).empty`) is 0.16-specific.
- **Run every command from the repo root.** Harnesses resolve BIOS, discs and test ROMs relative to the process CWD.
- **`zig fmt` before every commit** that touches a `.zig` file.
- **No file in `ps1-core/src` over ~600 lines.** Split by function if one crosses it.
- **Match the surrounding style.** Inline struct field defaults, devices expose `init()`. No thinking-out-loud comments; write the rule, not the narration. No copy-pasted blocks — extract the helper.
- **Casts: Tier A over Tier B.** Let Zig infer the target from the result location (`const s: i32 = @bitCast(a);`). Do not add helpers to `bits.zig` for this work.
- **Constants:** `constants.zig` holds only cross-module hardware facts. Anything CDROM-specific is a module-private `const` at the top of its own file.
- **Every core test must be verified to FAIL first** against the unmodified code. A guard test that cannot fail is worse than none. Where a test genuinely cannot distinguish the two implementations, the plan says so and does not fake one (Task 3, Step 7).
- **`ps1-golden` goldens must NOT be recaptured** by any task here. `zig build trace-golden -- verify` staying green is a deliverable, not a formality (Task 5).
- **Commit per task**, on `master`, with the message given in the task's final step. **Never `git push`.**
- **Swift tests need `zig build capi-lib` and `zig build metallib` to have run first.** `ps1-macos/test.sh` says so if they haven't.
- **The ABI header `ps1-capi/include/ps1.h` is hand-written and is the reviewable contract.** A change in Zig that is not mirrored there is a silent break.

---

## File structure

| File | Responsibility | Task |
|---|---|---|
| `ps1-core/src/cdrom/cdrom.zig` | `Drive` shell fields; `openShell`/`closeShell`/`swapDisc`; bit 4 in `getDriveStatus`; the close timer in `applyElapsed`/`stepEvents`/`nextDeadline` | 1, 3 |
| `ps1-core/src/cdrom/commands.zig` | Door-open short-circuit; `Getstat` clearing the latch | 1, 2 |
| `ps1-core/tests/cdrom_test.zig` | Shell behaviour tests | 1, 2, 3 |
| `ps1-capi/src/root.zig` | `ps1_swap_disc` + the validation helper it shares with `ps1_load_disc` | 4 |
| `ps1-capi/include/ps1.h` | The hand-written declaration and its contract comment | 4 |
| `ps1-capi/src/capi_test.zig` | `ps1_swap_disc` validation and sidecar-replacement tests | 4 |
| `ps1-golden/src/state_hash.zig` | The three new fields, added by hand | 5 |
| `ps1-macos/Sources/PS1/Ps1Core.swift` | `swapDisc(bin:cue:sbi:)`, retaining the new `Data` | 6 |
| `ps1-macos/Sources/PS1/EmulatorRunner.swift` | The pending-swap slot, drained on the emulator thread | 6 |
| `ps1-macos/Sources/PS1/DiscGrouping.swift` | **New.** `GameGroup` + the pure fold | 7 |
| `ps1-macos/Sources/PS1/MultiDiscSetting.swift` | **New.** The persisted toggle | 8 |
| `ps1-macos/Sources/PS1/LibraryView.swift` | Renders groups | 8 |
| `ps1-macos/Sources/PS1/GameTile.swift` | Shows a disc count on a grouped tile | 8 |
| `ps1-macos/Sources/PS1/EmulatorViewModel.swift` | `groups`, `mergeMultiDisc`, `discsInCurrentGame`, `currentDiscIndex`, `changeDisc(to:)` | 8, 9 |
| `ps1-macos/Sources/PS1App/LibraryCommands.swift` | **New.** The `Library` menu | 8 |
| `ps1-macos/Sources/PS1App/PS1App.swift` | `Machine ▸ Change Disc`; File menu loses the library items | 8, 9 |
| `ps1-macos/Tests/PS1Tests/DiscGroupingTests.swift` | **New.** | 7 |
| `ps1-macos/Tests/PS1Tests/MultiDiscSettingTests.swift` | **New.** | 8 |
| `CLAUDE.md` | Replace the "No disc swap" gap with what now exists | 10 |

---

### Task 1: The shell, and the sticky bit that makes a swap detectable

**Files:**
- Modify: `ps1-core/src/cdrom/cdrom.zig` — `Drive` struct (~line 57), `getDriveStatus` (~line 571), a new `openShell`/`closeShell`/`swapDisc` beside `setDisc` (~line 162)
- Modify: `ps1-core/src/cdrom/commands.zig:57` — the `0x01` Getstat arm
- Test: `ps1-core/tests/cdrom_test.zig`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Drive.shell_open: bool`, `Drive.shell_changed: bool`, `Drive.shell_close_timer: i64`
  - `CdRom.openShell(self: *CdRom) void`
  - `CdRom.closeShell(self: *CdRom) void`
  - `CdRom.swapDisc(self: *CdRom, d: disc.Disc, open_cycles: i64) void`

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/cdrom_test.zig`:

```zig
// The tray. Bit 4 of the drive status is "shell open", and PSX-SPX makes it
// STICKY: it is set when the tray opens and stays set after it closes, until
// software reads the status with Getstat (01h) while the tray is shut. That
// latch is the entire mechanism by which a game learns its disc was exchanged
// -- a game polls Getstat, sees bit 4, and re-reads the TOC instead of
// trusting its cached file table.
//
// Avocado models `shellOpen` but not the latch, and swaps in one instant
// (system_tools.cpp:76-79), which leaves the status byte identical before and
// after. It is not an oracle here.

test "opening the shell raises status bit 4 and stops the motor" {
    var cdrom = CdRom.init();

    try std.testing.expectEqual(@as(u8, 0x02), cdrom.getDriveStatus());

    cdrom.openShell();

    try std.testing.expect(cdrom.drive.shell_open);
    try std.testing.expectEqual(@as(u8, 0x10), cdrom.getDriveStatus());
    try std.testing.expectEqual(ps1_core.cdrom.DriveState.Idle, cdrom.drive.drive_state);
}

test "closing the shell leaves bit 4 set, because a disc may have changed" {
    var cdrom = CdRom.init();

    cdrom.openShell();
    cdrom.closeShell();

    // Motor back on, tray shut -- and bit 4 STILL set. Clearing it here is the
    // bug that makes a swap invisible: the game's next Getstat reads a clean
    // status and goes on using the old disc's file table.
    try std.testing.expect(!cdrom.drive.shell_open);
    try std.testing.expectEqual(@as(u8, 0x12), cdrom.getDriveStatus());
}

test "Getstat consumes the shell-changed latch and reports it in the same breath" {
    var cdrom = CdRom.init();
    var spu = Spu.init();

    cdrom.openShell();
    cdrom.closeShell();

    var response: [1]u8 = undefined;
    const irq = try runCommand(&cdrom, &spu, 0x01, response.len, &response);

    // The response carries the bit. `queueIrq` snapshots the bytes at queue
    // time, so the clear has to happen AFTER the ack -- clearing first delivers
    // a clean status and the news never reaches the game.
    try std.testing.expectEqual(@as(u8, 3), irq);
    try std.testing.expectEqual(@as(u8, 0x12), response[0]);

    // ...and it is consumed: a second Getstat reads clean.
    var again: [1]u8 = undefined;
    _ = try runCommand(&cdrom, &spu, 0x01, again.len, &again);
    try std.testing.expectEqual(@as(u8, 0x02), again[0]);
}

test "Getstat while the tray is still open does not consume the latch" {
    var cdrom = CdRom.init();
    var spu = Spu.init();

    cdrom.openShell();

    var response: [1]u8 = undefined;
    _ = try runCommand(&cdrom, &spu, 0x01, response.len, &response);
    try std.testing.expectEqual(@as(u8, 0x10), response[0]);

    // The game has not been handed a disc yet, so it has learned nothing worth
    // consuming the latch for. Once the tray shuts, the news must still be
    // there to collect.
    cdrom.closeShell();
    var after: [1]u8 = undefined;
    _ = try runCommand(&cdrom, &spu, 0x01, after.len, &after);
    try std.testing.expectEqual(@as(u8, 0x12), after[0]);
}

test "swapDisc opens the tray, installs the new disc and arms the close timer" {
    var first = [_]u8{0} ** 2352;
    var second = [_]u8{0} ** 2352;
    first[0] = 0xAA;
    second[0] = 0xBB;

    var cdrom = CdRom.init();
    cdrom.setDisc(ps1_core.disc.Disc.init(&first));

    cdrom.swapDisc(ps1_core.disc.Disc.init(&second), 1000);

    try std.testing.expect(cdrom.drive.shell_open);
    try std.testing.expectEqual(@as(i64, 1000), cdrom.drive.shell_close_timer);
    // Installed at OPEN, not at close: nothing can read it while the tray is
    // up, so a pending-disc state would be a third state with no observable
    // difference.
    try std.testing.expectEqual(@as(u8, 0xBB), cdrom.disc.?.data[0]);
}
```

`runCommand` already exists at `ps1-core/tests/cdrom_test.zig:27` — do not redefine it.

- [ ] **Step 2: Run the tests and confirm they fail**

```bash
zig build test 2>&1 | tail -30
```

Expected: compile errors — `no field named 'shell_open' in struct 'Drive'`, `no member named 'openShell'`. That is a legitimate first failure for a Zig test; the point is that the behaviour is absent, not that the assertion is red.

- [ ] **Step 3: Add the three fields to `Drive`**

In `ps1-core/src/cdrom/cdrom.zig`, inside `pub const Drive = struct`, after `muted: bool = false,`:

```zig
    /// The tray. `shell_open` is the physical state; `shell_changed` is the
    /// STICKY latch PSX-SPX describes -- set when the tray opens, surviving
    /// the close, and cleared only by a Getstat issued once the tray is shut.
    /// A game polls Getstat, sees status bit 4, and re-reads the TOC rather
    /// than trusting its cached file table; without the latch a swap leaves
    /// the status byte identical before and after and the game never learns.
    ///
    /// Boot state is closed with the latch clear, which is what this drive has
    /// always reported. Avocado instead starts `shellOpen` true and relies on
    /// disc load to close it, which would put bit 4 in front of the BIOS's
    /// first Getstat on every workload and move every golden for nothing.
    shell_open: bool = false,
    shell_changed: bool = false,
    /// Cycles until the tray closes again. Ticked with the other timers; see
    /// `nextDeadline`.
    shell_close_timer: i64 = 0,
```

- [ ] **Step 4: Derive bit 4 in `getDriveStatus`**

Replace the body of `getDriveStatus` (`ps1-core/src/cdrom/cdrom.zig:571`):

```zig
    pub fn getDriveStatus(self: *const CdRom) u8 {
        var stat = self.drive.status & 0x1F;
        // Bit 4 is never STORED in `drive.status` -- it is derived here, so the
        // tray has one source of truth. It sits inside the 0x1F mask above, so
        // a stale stored copy would ride out into every response with nothing
        // to catch it.
        if (self.drive.shell_open or self.drive.shell_changed) stat |= 0x10;
        switch (self.drive.drive_state) {
            .Reading => stat |= 0x20,
            .Seeking => stat |= 0x40,
            .Playing => stat |= 0x80,
            .Idle => {},
        }
        return stat;
    }
```

- [ ] **Step 5: Add the three operations beside `setDisc`**

In `ps1-core/src/cdrom/cdrom.zig`, immediately after `setDisc` (~line 164):

```zig
    /// Opens the tray: raises the sticky latch, cuts the motor and stops the
    /// mechanism. `closeShell` deliberately does NOT clear the latch.
    pub fn openShell(self: *CdRom) void {
        self.drive.shell_open = true;
        self.drive.shell_changed = true;
        self.drive.status &= ~@as(u8, 0x02); // motor off
        self.drive.drive_state = .Idle;
        self.drive.read_after_seek = false;
        self.drive.seek_timer = 0;
        self.drive.sector_timer = 0;
    }

    pub fn closeShell(self: *CdRom) void {
        self.drive.shell_open = false;
        self.drive.shell_close_timer = 0;
        self.drive.status |= 0x02; // motor on
    }

    /// Exchanges the disc the way a player does: the tray opens, the disc goes
    /// in, and the tray closes `open_cycles` later. The window is real rather
    /// than instantaneous because a game may watch for the open state itself
    /// rather than for the latch afterwards.
    pub fn swapDisc(self: *CdRom, d: disc.Disc, open_cycles: i64) void {
        self.openShell();
        self.disc = d;
        self.drive.shell_close_timer = open_cycles;
    }
```

- [ ] **Step 6: Clear the latch in Getstat**

In `ps1-core/src/cdrom/commands.zig`, replace the `0x01` arm (line 57):

```zig
        0x01 => { // Getstat
            ackStatus(cdrom);
            // AFTER the ack, and only with the tray shut. `queueIrq` snapshots
            // the response at queue time, so the byte just queued still carries
            // bit 4 -- clearing first would hand the game a clean status and
            // the swap would go unnoticed. And a Getstat answered while the
            // tray is still open has told the game nothing worth consuming:
            // there is no disc in there yet to notice.
            if (!cdrom.drive.shell_open) cdrom.drive.shell_changed = false;
        },
```

- [ ] **Step 7: Export `DriveState` if the test cannot name it**

`ps1_core.cdrom.DriveState` resolves already — it is `pub` at
`ps1-core/src/cdrom/cdrom.zig:20` and `root.zig:10` re-exports the module — so
this step is a confirmation, not a change:

```bash
grep -n "pub const DriveState" ps1-core/src/cdrom/cdrom.zig ps1-core/src/root.zig
```

If it somehow does not, drop that one assertion rather than widening the
module's surface: the other four in that test already pin the behaviour.

- [ ] **Step 8: Run the tests**

```bash
zig fmt ps1-core/src/cdrom/cdrom.zig ps1-core/src/cdrom/commands.zig ps1-core/tests/cdrom_test.zig
zig build test 2>&1 | tail -20
```

Expected: all 15 test binaries pass.

- [ ] **Step 9: Commit**

```bash
git add ps1-core/src/cdrom/cdrom.zig ps1-core/src/cdrom/commands.zig ps1-core/tests/cdrom_test.zig
git commit -m "feat(cdrom): the tray is a state, and bit 4 is sticky

Adds shell_open/shell_changed/shell_close_timer to Drive, derives status
bit 4 from the first two rather than storing it, and has Getstat consume
the latch -- after the ack, and only once the tray is shut.

The latch is the whole mechanism: without it a swap leaves the status
byte identical before and after and the game goes on using the old
disc's file table. Avocado models shellOpen but not the latch, so it is
not an oracle here; PSX-SPX is.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CCw6QYGA7ngwzgp8kpC92w"
```

---

### Task 2: Commands answer INT5 while the tray is open

**Files:**
- Modify: `ps1-core/src/cdrom/commands.zig` — `processCommand` (line 56)
- Test: `ps1-core/tests/cdrom_test.zig`

**Interfaces:**
- Consumes: `Drive.shell_open`, `CdRom.openShell()`, `CdRom.getDriveStatus()` from Task 1.
- Produces: no new symbols. Behaviour only.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/cdrom_test.zig`:

```zig
test "a command issued with the tray open answers INT5 door-open" {
    var cdrom = CdRom.init();
    var spu = Spu.init();

    cdrom.openShell();

    // GetID (1Ah). PSX-SPX gives INT5(stat+1, 80h) for the door-open case, and
    // with the motor off that is {0x11, 0x80} -- byte for byte the constant
    // Avocado hardcodes into cmdGetId alone (commands.cpp:413-417). The
    // general rule gets GetID right and every other command right at once.
    var response: [2]u8 = undefined;
    const irq = try runCommand(&cdrom, &spu, 0x1A, response.len, &response);

    try std.testing.expectEqual(@as(u8, 5), irq);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x80 }, &response);
}

test "a read issued with the tray open does not start the drive" {
    var sectors = [_]u8{0} ** (2 * 2352);
    var cdrom = CdRom.init();
    var spu = Spu.init();
    cdrom.setDisc(ps1_core.disc.Disc.init(&sectors));

    cdrom.openShell();

    var response: [2]u8 = undefined;
    const irq = try runCommand(&cdrom, &spu, 0x06, response.len, &response); // ReadN

    try std.testing.expectEqual(@as(u8, 5), irq);
    try std.testing.expectEqual(ps1_core.cdrom.DriveState.Idle, cdrom.drive.drive_state);

    var guard: usize = 0;
    while (guard < 100) : (guard += 1) cdrom.step(20_000, &spu);
    try std.testing.expectEqual(@as(u64, 0), cdrom.drive.sectors_delivered);
}

test "Getstat and Test still answer with the tray open" {
    var cdrom = CdRom.init();
    var spu = Spu.init();

    cdrom.openShell();

    // Getstat is how the game observes the tray at all, and Test 03h is
    // "force motor off, used in swap" in Avocado's own comment. Both have to
    // survive the short-circuit or the open state is unobservable.
    var stat: [1]u8 = undefined;
    try std.testing.expectEqual(@as(u8, 3), try runCommand(&cdrom, &spu, 0x01, stat.len, &stat));
    try std.testing.expectEqual(@as(u8, 0x10), stat[0]);

    cdrom.write(0, 0);
    cdrom.write(2, 0x20); // Test sub-opcode: get version
    cdrom.write(1, 0x19);
    cdrom.step(50_000, &spu);
    cdrom.write(0, 1);
    try std.testing.expectEqual(@as(u8, 3), cdrom.read(3) & 7);
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

```bash
zig build test 2>&1 | tail -30
```

Expected: the first two fail. `GetID` currently answers INT3 with `SCEA`, so `irq` is 3 where 5 is expected; `ReadN` starts seeking, so `drive_state` is `.Seeking` and sectors arrive. The third test passes already — it is the control that proves the short-circuit does not swallow the two commands that matter.

- [ ] **Step 3: Add the short-circuit**

In `ps1-core/src/cdrom/commands.zig`, insert at the top of `processCommand`, before the `switch`:

```zig
/// The door-open refusal: PSX-SPX's `INT5(stat+1, 80h)`.
fn ackDoorOpen(cdrom: *CdRom) void {
    cdrom.queueIrq(5, ack_delay, &[_]u8{ cdrom.getDriveStatus() | 0x01, 0x80 });
}

pub fn processCommand(cdrom: *CdRom, cmd: u8) void {
    // With the tray open the drive can do nothing but report that fact. Getstat
    // is exempt because it is how software observes the tray at all, and Test
    // because 19h/03h is "force motor off", which is part of a swap rather than
    // a request of the mechanism.
    if (cdrom.drive.shell_open and cmd != 0x01 and cmd != 0x19) {
        ackDoorOpen(cdrom);
        return;
    }

    switch (cmd) {
```

- [ ] **Step 4: Run the tests**

```bash
zig fmt ps1-core/src/cdrom/commands.zig ps1-core/tests/cdrom_test.zig
zig build test 2>&1 | tail -20
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add ps1-core/src/cdrom/commands.zig ps1-core/tests/cdrom_test.zig
git commit -m "feat(cdrom): an open tray refuses every command but Getstat and Test

PSX-SPX's INT5(stat+1, 80h). With the motor off that expression is
{0x11, 0x80} -- the constant Avocado hardcodes into cmdGetId alone, so
the general form gets GetID right and every other command with it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CCw6QYGA7ngwzgp8kpC92w"
```

---

### Task 3: The tray closes itself, one second later

**Files:**
- Modify: `ps1-core/src/cdrom/cdrom.zig` — `applyElapsed` (line 339), `nextDeadline` (line 365), `stepEvents` (line 395), and a module-private constant near the top
- Test: `ps1-core/tests/cdrom_test.zig`

**Interfaces:**
- Consumes: `Drive.shell_close_timer`, `CdRom.closeShell()`, `CdRom.swapDisc()` from Task 1.
- Produces: `cdrom.shell_open_cycles: i64` — the default tray-open window, referenced by Task 4's `ps1_swap_disc`.

- [ ] **Step 1: Write the failing test**

Append to `ps1-core/tests/cdrom_test.zig`:

```zig
test "the tray closes itself and the game can then read the new disc" {
    // Two discs whose first sector differs, so "which disc is under the laser"
    // is answerable from the data rather than from a pointer.
    var first = [_]u8{0} ** (2 * 2352);
    var second = [_]u8{0} ** (2 * 2352);
    for (0..2) |n| {
        first[n * 2352 + 15] = 0x02;
        second[n * 2352 + 15] = 0x02;
        for (0..2048) |i| {
            first[n * 2352 + 24 + i] = 0x11;
            second[n * 2352 + 24 + i] = 0x22;
        }
    }

    var cdrom = CdRom.init();
    var spu = Spu.init();
    cdrom.setDisc(ps1_core.disc.Disc.init(&first));

    cdrom.swapDisc(ps1_core.disc.Disc.init(&second), 100_000);

    // Mid-window: still open, still refusing.
    var guard: usize = 0;
    while (guard < 4) : (guard += 1) cdrom.step(20_000, &spu);
    try std.testing.expect(cdrom.drive.shell_open);

    // Past the window: shut, motor back on, and the latch still standing for
    // the game's next Getstat.
    guard = 0;
    while (cdrom.drive.shell_open and guard < 100) : (guard += 1) cdrom.step(20_000, &spu);
    try std.testing.expect(!cdrom.drive.shell_open);
    try std.testing.expect(cdrom.drive.shell_changed);
    try std.testing.expectEqual(@as(u8, 0x12), cdrom.getDriveStatus());

    // And the drive now reads the disc that went in, not the one that came out.
    cdrom.write(0, 0);
    cdrom.write(2, 0x00);
    cdrom.write(2, 0x02);
    cdrom.write(2, 0x00);
    cdrom.write(1, 0x02); // Setloc 00:02:00 == LBA 0
    cdrom.step(1, &spu);
    cdrom.write(0, 0);
    cdrom.write(1, 0x06); // ReadN

    guard = 0;
    while (cdrom.drive.sectors_delivered == 0 and guard < 200) : (guard += 1) {
        cdrom.step(20_000, &spu);
    }
    try std.testing.expectEqual(@as(u64, 1), cdrom.drive.sectors_delivered);

    cdrom.write(0, 0);
    cdrom.write(3, 0x80); // Request: want data
    try std.testing.expectEqual(@as(u8, 0x22), cdrom.read(2));
}
```

- [ ] **Step 2: Run the test and confirm it fails**

```bash
zig build test 2>&1 | tail -30
```

Expected: FAIL. Nothing decrements `shell_close_timer`, so the tray never shuts and `expect(!cdrom.drive.shell_open)` is red.

- [ ] **Step 3: Add the window constant**

In `ps1-core/src/cdrom/cdrom.zig`, in the module-private `const` block near the top of the file (module-private, not `constants.zig` — that file holds only cross-module hardware facts):

`cdrom.zig` does **not** import `constants.zig` today, so add the import
alongside the others at the top of the file:

```zig
const constants = @import("../constants.zig");
```

then, in the module-private `const` block that already holds `mode_byte_offset`
and its neighbours (~line 15):

```zig
/// How long the tray stays open across a swap: one second of emulated time,
/// which is about what a physical tray takes. The window is real rather than
/// instantaneous on purpose -- a game may watch for the open state itself
/// rather than for the sticky latch afterwards, and Avocado's instant swap
/// gives it nothing to see.
pub const shell_open_cycles: i64 = constants.cpu_clock_hz;
```

`cpu_clock_hz` is a genuine cross-module hardware fact and already lives in
`constants.zig:15`; the window derived from it is CDROM-specific and stays
module-private here.

- [ ] **Step 4: Tick it in `applyElapsed`**

In `applyElapsed`, before the final `self.audio.audio_tick_counter += elapsed;`:

```zig
        if (self.drive.shell_close_timer > 0) {
            self.drive.shell_close_timer -= @min(self.drive.shell_close_timer, @as(i64, elapsed));
        }
```

- [ ] **Step 5: Name it in `nextDeadline`**

In `nextDeadline`, before the audio-tick line:

```zig
        if (self.drive.shell_close_timer > 0) d = @min(d, self.drive.shell_close_timer);
```

- [ ] **Step 6: Fire it in `stepEvents`**

In `stepEvents`, after the "Tick the read seek timer" block and before "Tick Drive Mechanism":

```zig
        // Tick the tray. Independent of `irq_queue` for the same reason the
        // seek timer is: every command byte clears that queue, and a game
        // polling Getstat through the swap window would otherwise lose the
        // close.
        if (self.drive.shell_close_timer > 0) {
            self.drive.shell_close_timer -= cycles;
            if (self.drive.shell_close_timer <= 0) self.closeShell();
        }
```

- [ ] **Step 7: Note what the `nextDeadline` entry does and does not buy**

Do **not** write a test for Step 5. CLAUDE.md's rule — a timer the slow path acts on but `nextDeadline` does not name never fires at all — is stated without exceptions and the entry belongs there. But `nextDeadline`'s last term, `768 - audio_tick_counter`, is unconditional, so every deadline is already capped at 768 cycles: omitting this one would make the tray close up to 768 cycles late against a 33,868,800-cycle window, and no test can tell the two apart. It is a conformance edit, not a defect fix. Writing a test that passes either way would be worse than writing none.

- [ ] **Step 8: Run the tests**

```bash
zig fmt ps1-core/src/cdrom/cdrom.zig ps1-core/tests/cdrom_test.zig
zig build test 2>&1 | tail -20
```

Expected: all pass.

- [ ] **Step 9: Commit**

```bash
git add ps1-core/src/cdrom/cdrom.zig ps1-core/tests/cdrom_test.zig
git commit -m "feat(cdrom): the tray shuts itself a second after it opened

swapDisc arms shell_close_timer; applyElapsed ticks it, stepEvents fires
it, nextDeadline names it. The window is a real second of emulated time
because a game may watch for the open state rather than for the latch.

The nextDeadline entry is conformance, not a fix: the unconditional
768-cycle audio tick already caps every deadline, so omitting it would
cost 768 cycles of lateness rather than the event. No test is written
for it, because none could fail against its absence.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CCw6QYGA7ngwzgp8kpC92w"
```

---

### Task 4: `ps1_swap_disc`

**Files:**
- Modify: `ps1-capi/src/root.zig:112-171` — extract the shared validation, add the new export
- Modify: `ps1-capi/include/ps1.h` — after the `ps1_load_disc` declaration
- Test: `ps1-capi/src/capi_test.zig`

**Interfaces:**
- Consumes: `CdRom.swapDisc(d, open_cycles)` and `cdrom.shell_open_cycles` from Tasks 1 and 3.
- Produces: `int32_t ps1_swap_disc(Ps1*, const uint8_t* bin, size_t, const uint8_t* cue, size_t, const uint8_t* sbi, size_t)` — same return codes as `ps1_load_disc`.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-capi/src/capi_test.zig`:

```zig
test "swap_disc validates exactly as load_disc does" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin = [_]u8{0} ** 2352;
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, &bin, bin.len, null, 0, null, 0));

    // A rejection must leave the running machine's disc alone -- this is a
    // LIVE swap, so a half-applied one is a game reading a disc that is not
    // there. Both checks happen before anything is allocated or assigned.
    const swap = [_]u8{0} ** 2352;
    try std.testing.expectEqual(
        @as(i32, -3),
        capi.ps1_swap_disc(h, &swap, swap.len, multi_file_cue.ptr, multi_file_cue.len, null, 0),
    );
    try std.testing.expectEqual(
        @as(i32, -5),
        capi.ps1_swap_disc(h, &swap, swap.len, null, 0, "NOTSBI".ptr, 6),
    );
    try std.testing.expectEqual(@as(i32, -2), capi.ps1_swap_disc(h, &swap, 0, null, 0, null, 0));

    try std.testing.expect(h.disc != null);
    try std.testing.expect(!h.bus.cdrom.drive.shell_open);
}

test "swap_disc opens the tray and installs the new disc" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    var first = [_]u8{0} ** 2352;
    var second = [_]u8{0} ** 2352;
    first[0] = 0xAA;
    second[0] = 0xBB;

    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, &first, first.len, null, 0, null, 0));
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_swap_disc(h, &second, second.len, null, 0, null, 0));

    try std.testing.expect(h.bus.cdrom.drive.shell_open);
    try std.testing.expect(h.bus.cdrom.drive.shell_changed);
    try std.testing.expectEqual(@as(u8, 0xBB), h.bus.cdrom.disc.?.data[0]);
}

test "swap_disc replaces the handle's sidecar rather than keeping the old one" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin = [_]u8{0} ** 2352;
    const sbi_a = "SBI\x00" ++ [_]u8{0} ** 14;
    const sbi_b = "SBI\x00" ++ [_]u8{0} ** 28;

    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, &bin, bin.len, null, 0, sbi_a.ptr, sbi_a.len));
    try std.testing.expectEqual(@as(usize, sbi_a.len), h.sbi.len);

    // Each disc of a multi-disc set carries its own sidecar, naming sectors of
    // its OWN image. Carrying the previous disc's over is worth exactly as
    // much as carrying none.
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_swap_disc(h, &bin, bin.len, null, 0, sbi_b.ptr, sbi_b.len));
    try std.testing.expectEqual(@as(usize, sbi_b.len), h.sbi.len);
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

```bash
zig build test 2>&1 | tail -20
```

Expected: compile error, `no member named 'ps1_swap_disc'`.

- [ ] **Step 3: Extract the shared preparation**

Replace `ps1_load_disc`'s body (`ps1-capi/src/root.zig:112-171`) with a helper plus two thin exports. The helper carries the whole contract, including the ordering rule that the sidecar copy happens after every rejection — this function family returns codes rather than errors, so `errdefer` never fires and each early return would otherwise have to free by hand.

```zig
/// Validates the three buffers and, on success, returns a `Disc` with the
/// handle's sidecar already replaced by a copy of `sbi`.
///
/// Every rejection happens while nothing has been allocated and nothing on the
/// handle has been touched, so a caller that gets a negative code still has the
/// machine it had before. That matters more for `ps1_swap_disc` than for
/// `ps1_load_disc`: the swap is applied to a RUNNING machine.
fn prepareDisc(
    h: *Handle,
    bin: [*]const u8,
    bin_len: usize,
    cue: ?[*]const u8,
    cue_len: usize,
    sbi: ?[*]const u8,
    sbi_len: usize,
) union(enum) { ok: Disc, err: i32 } {
    if (bin_len < ps1.constants.sector_bytes) return .{ .err = PS1_ERR_BAD_CUE };

    if (sbi_len > 0) {
        const bytes = (sbi orelse return .{ .err = PS1_ERR_BAD_SBI })[0..sbi_len];
        if (!std.mem.startsWith(u8, bytes, sbi_magic)) return .{ .err = PS1_ERR_BAD_SBI };
    }

    const data = bin[0..bin_len];
    var d: Disc = undefined;

    if (cue_len > 0) {
        const cue_ptr = cue orelse return .{ .err = PS1_ERR_BAD_CUE };
        const cue_text = cue_ptr[0..cue_len];

        const files = ps1.disc.countCueFiles(cue_text);
        if (files == 0) return .{ .err = PS1_ERR_BAD_CUE };
        // A multi-FILE cue is fine as long as the caller has concatenated the
        // images and said where the seams are; without the `REM FILESIZE`
        // lines that carry them, `initFromCue` stacks every FILE at the same
        // base LBA rather than failing, so it has to be caught here.
        if (files > 1 and !ps1.disc.cueFilesAreLaidOut(cue_text)) return .{ .err = PS1_ERR_MULTI_FILE_CUE };

        // `initFromCue` silently falls back to a single data track on a cue it
        // cannot parse, so a cue with no TRACK line has to be caught here.
        if (std.mem.indexOf(u8, cue_text, "TRACK ") == null) return .{ .err = PS1_ERR_BAD_CUE };

        d = Disc.initFromCue(cue_text, data);
    } else {
        d = Disc.init(data);
    }

    // Past this point nothing can fail but the copy itself, so the handle's
    // old sidecar is safe to drop.
    const new_sbi: []u8 = if (sbi_len > 0)
        allocator.dupe(u8, sbi.?[0..sbi_len]) catch return .{ .err = PS1_ERR_OOM }
    else
        &.{};
    allocator.free(h.sbi);
    h.sbi = new_sbi;
    // `setDisc`/`swapDisc` copy the Disc by value, so the sidecar has to be
    // attached to `d` before it is handed over rather than to `h.disc` after.
    d.setSbi(new_sbi);
    return .{ .ok = d };
}

pub export fn ps1_load_disc(
    h: *Handle,
    bin: [*]const u8,
    bin_len: usize,
    cue: ?[*]const u8,
    cue_len: usize,
    sbi: ?[*]const u8,
    sbi_len: usize,
) i32 {
    const d = switch (prepareDisc(h, bin, bin_len, cue, cue_len, sbi, sbi_len)) {
        .err => |code| return code,
        .ok => |disc| disc,
    };
    h.disc = d;
    h.cpu.bus.cdrom.setDisc(d);
    return PS1_OK;
}

pub export fn ps1_swap_disc(
    h: *Handle,
    bin: [*]const u8,
    bin_len: usize,
    cue: ?[*]const u8,
    cue_len: usize,
    sbi: ?[*]const u8,
    sbi_len: usize,
) i32 {
    const d = switch (prepareDisc(h, bin, bin_len, cue, cue_len, sbi, sbi_len)) {
        .err => |code| return code,
        .ok => |disc| disc,
    };
    h.disc = d;
    h.cpu.bus.cdrom.swapDisc(d, ps1.cdrom.shell_open_cycles);
    return PS1_OK;
}
```

Confirm the path to the constant resolves — `root.zig` re-exports the cdrom module, so `ps1.cdrom.shell_open_cycles` should. Check with:

```bash
grep -n "pub const cdrom" ps1-core/src/root.zig
```

- [ ] **Step 4: Declare it in the header**

In `ps1-capi/include/ps1.h`, immediately after the `ps1_load_disc` declaration:

```c
/* Exchanges the disc on a RUNNING machine, the way a player swaps one.
 *
 * Same arguments, same validation and same return codes as ps1_load_disc,
 * including the borrow contract: `bin` is BORROWED and must outlive the handle
 * or the next call here, and `sbi` is copied. Pass the sidecar that shipped
 * with the disc going IN — the outgoing disc's is discarded, and each disc of
 * a multi-disc set names sectors of its own image.
 *
 * The difference is the tray. This raises the drive's shell-open state, puts
 * the new disc in, and closes the tray one emulated second later; status bit 4
 * then stays set until the game reads it with Getstat, which is how it learns
 * to re-read the TOC rather than trust the file table it cached from the disc
 * that just came out. Replacing the disc without that sequence — which is what
 * calling ps1_load_disc on a running machine does — is invisible to the game.
 *
 * Commands issued during that one-second window are refused with the
 * door-open error, exactly as on hardware. A rejection here changes nothing:
 * the machine keeps the disc it had.
 */
int32_t ps1_swap_disc(Ps1*, const uint8_t* bin, size_t bin_len,
                            const uint8_t* cue, size_t cue_len,
                            const uint8_t* sbi, size_t sbi_len);
```

- [ ] **Step 5: Run the tests**

```bash
zig fmt ps1-capi/src/root.zig ps1-capi/src/capi_test.zig
zig build test 2>&1 | tail -20
```

Expected: all pass. `capi_test` builds against the recording core module (`gpu_sink = .dual`) — that is deliberate and needs no change here.

- [ ] **Step 6: Commit**

```bash
git add ps1-capi/src/root.zig ps1-capi/include/ps1.h ps1-capi/src/capi_test.zig
git commit -m "feat(capi): ps1_swap_disc, the tray version of ps1_load_disc

Same validation, same borrow contract, differing only in driving the
shell sequence instead of setDisc. The two share prepareDisc rather than
duplicating the block -- including its ordering rule, that the sidecar
copy happens after every rejection because this family returns codes and
errdefer would never fire.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CCw6QYGA7ngwzgp8kpC92w"
```

---

### Task 5: Hash the new fields, and prove the goldens do not move

**Files:**
- Modify: `ps1-golden/src/state_hash.zig` — `hashCdrom` (line 198)

**Interfaces:**
- Consumes: the three `Drive` fields from Task 1.
- Produces: nothing.

- [ ] **Step 1: Add the three fields by hand**

In `hashCdrom`, after `s.flag(cd.drive.muted);`:

```zig
    s.flag(cd.drive.shell_open);
    s.flag(cd.drive.shell_changed);
    s.int(cd.drive.shell_close_timer);
```

That file is written by hand on purpose — reflection would make the check follow a refactor instead of policing it. `drive.status` is already hashed and bit 4 lives inside its `& 0x1F` mask, so the status side needs nothing.

- [ ] **Step 2: Build and verify**

```bash
zig fmt ps1-golden/src/state_hash.zig
zig build trace-golden -Doptimize=ReleaseFast -- verify 2>&1 | tail -20
```

Expected: **OK for all ten workloads, and no recapture.** No workload calls `swapDisc`, so the two flags stay false, the timer stays zero, and `getDriveStatus` returns exactly what it returned before.

- [ ] **Step 3: If verify goes red, stop**

A red verify means Task 1 changed behaviour on a path that runs without a swap — the likely culprits are `getDriveStatus` (a mask or an ordering slip) or `openShell` clearing state it should not. **Do not run `capture`.** Find the behaviour change; the goldens are right and the code is wrong.

- [ ] **Step 4: Commit**

```bash
git add ps1-golden/src/state_hash.zig
git commit -m "test(golden): hash the tray state

Added by hand, like the rest of state_hash.zig. verify stays green for
all ten workloads with no recapture, which is the claim: no workload
opens the shell, so this is inert for everything that existed before it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CCw6QYGA7ngwzgp8kpC92w"
```

---

### Task 6: Route the swap through the emulator thread

**Files:**
- Modify: `ps1-macos/Sources/PS1/Ps1Core.swift` — after `loadDisc` (line 68)
- Modify: `ps1-macos/Sources/PS1/EmulatorRunner.swift` — a pending-swap slot; `runLoop` (line 167)
- Test: `ps1-macos/Tests/PS1Tests/Ps1CoreTests.swift`

**Interfaces:**
- Consumes: `ps1_swap_disc` from Task 4.
- Produces:
  - `Ps1Core.swapDisc(bin: Data, cue: Data?, sbi: Data?) throws`
  - `EmulatorRunner.requestDiscSwap(bin: Data, cue: Data?, sbi: Data?)`

- [ ] **Step 1: Write the failing test**

Append to `ps1-macos/Tests/PS1Tests/Ps1CoreTests.swift`:

```swift
@Test func swappingADiscOpensTheTrayAndKeepsTheNewBytesAlive() throws {
    let core = try Ps1Core()
    var first = Data(count: 2352)
    var second = Data(count: 2352)
    first[0] = 0xAA
    second[0] = 0xBB

    try core.loadDisc(bin: first, cue: nil, sbi: nil)
    try core.swapDisc(bin: second, cue: nil, sbi: nil)

    // `Disc` BORROWS its bytes, so the retained Data is what keeps the core's
    // slice valid. Dropping the local here must change nothing.
    second = Data()
    #expect(core.hasDisc)
}

@Test func aRejectedSwapLeavesTheRunningDiscAlone() throws {
    let core = try Ps1Core()
    try core.loadDisc(bin: Data(count: 2352), cue: nil, sbi: nil)

    #expect(throws: Ps1Error.badSBI) {
        try core.swapDisc(bin: Data(count: 2352), cue: nil,
                          sbi: Data("NOTSBI".utf8))
    }
    #expect(core.hasDisc)
}
```

If `Ps1Core` has no `hasDisc`, add one — a computed `var hasDisc: Bool { discData != nil }`. Check first:

```bash
grep -n "hasDisc" ps1-macos/Sources/PS1/Ps1Core.swift
```

- [ ] **Step 2: Run the tests and confirm they fail**

```bash
zig build capi-lib && zig build metallib && ps1-macos/test.sh 2>&1 | tail -30
```

Expected: build failure — `value of type 'Ps1Core' has no member 'swapDisc'`.

- [ ] **Step 3: Add `Ps1Core.swapDisc`**

In `ps1-macos/Sources/PS1/Ps1Core.swift`, after `loadDisc`:

```swift
    /// Exchanges the disc on a running machine: the tray opens, the disc goes
    /// in, and it closes an emulated second later, leaving the sticky status
    /// bit that tells the game to re-read the TOC.
    ///
    /// Called from the emulator thread, never the main actor — `EmulatorRunner`
    /// owns the core while it is running.
    ///
    /// The retain happens BEFORE the call and is rolled back on failure, the
    /// same shape `loadDisc` uses: the core starts reading these bytes the
    /// moment the disc is attached, and a rejected swap must leave the machine
    /// holding exactly what it held before — including the Data keeping the
    /// OUTGOING disc's slice alive.
    func swapDisc(bin: Data, cue: Data?, sbi: Data?) throws {
        let previous = discData
        self.discData = bin

        let code: Int32 = bin.withUnsafeBytes { binRaw -> Int32 in
            let binPtr = binRaw.bindMemory(to: UInt8.self).baseAddress
            return Self.withOptionalBytes(cue) { cuePtr, cueLen in
                Self.withOptionalBytes(sbi) { sbiPtr, sbiLen in
                    ps1_swap_disc(handle, binPtr, bin.count, cuePtr, cueLen, sbiPtr, sbiLen)
                }
            }
        }

        if let e = Ps1Error.from(code) {
            self.discData = previous
            throw e
        }
    }

    var hasDisc: Bool { discData != nil }
```

Note the mapping is `Ps1Error.from(code)` — a static factory returning an
optional, not an initializer (`Ps1Core.swift:20`).

- [ ] **Step 4: Add the pending-swap slot to `EmulatorRunner`**

In `ps1-macos/Sources/PS1/EmulatorRunner.swift`, beside the `pgxp` atomic (line 63):

```swift
    /// A disc waiting to go in, applied by `runLoop` between frames.
    ///
    /// Not an `Atomic`: the payload is three `Data` values, and `Synchronization`
    /// has no conformance for those. It rides the `NSCondition` this class
    /// already holds for pacing rather than a second lock.
    ///
    /// This exists because `runLoop` owns the core. Calling `ps1_swap_disc`
    /// from a menu handler on the main actor would widen exactly the race
    /// `EmulatorViewModel.reset()` documents, and against a longer critical
    /// section than `ps1_reset`.
    private struct PendingSwap { let bin: Data; let cue: Data?; let sbi: Data? }
    private var pendingSwap: PendingSwap?

    func requestDiscSwap(bin: Data, cue: Data?, sbi: Data?) {
        pacing.lock()
        pendingSwap = PendingSwap(bin: bin, cue: cue, sbi: sbi)
        // The loop may be parked waiting on the audio high-water mark; wake it
        // so the swap lands now rather than at the next drain.
        pacing.signal()
        pacing.unlock()
    }

    private func takePendingSwap() -> PendingSwap? {
        pacing.lock()
        defer { pacing.unlock() }
        let swap = pendingSwap
        pendingSwap = nil
        return swap
    }
```

- [ ] **Step 5: Drain it in `runLoop`**

In `runLoop`, immediately before `core.setButtons(...)`:

```swift
            if let swap = takePendingSwap() {
                // A failure here is not actionable from this thread and must
                // not take the emulator down: the core rolled the swap back and
                // the game is still running on the disc it had.
                try? core.swapDisc(bin: swap.bin, cue: swap.cue, sbi: swap.sbi)
            }
```

No `requestResync()` — a swap mutates no VRAM and the command stream is unbroken across it.

- [ ] **Step 6: Run the tests**

```bash
ps1-macos/test.sh 2>&1 | tail -30
```

Expected: 247 tests pass (245 existing plus the two new).

- [ ] **Step 7: Commit**

```bash
git add ps1-macos/Sources/PS1/Ps1Core.swift ps1-macos/Sources/PS1/EmulatorRunner.swift ps1-macos/Tests/PS1Tests/Ps1CoreTests.swift
git commit -m "feat(macos): swap the disc on the thread that owns the core

runLoop owns the core, so the swap is queued and drained between frames
rather than called from a menu handler -- which would widen the main-actor
race reset() documents, against a longer critical section.

Ps1Core rolls its retained Data back on a rejected swap: Disc borrows
its bytes, and a failed swap has to leave the OUTGOING disc's slice alive.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CCw6QYGA7ngwzgp8kpC92w"
```

---

### Task 7: `DiscGrouping`

**Files:**
- Create: `ps1-macos/Sources/PS1/DiscGrouping.swift`
- Test: `ps1-macos/Tests/PS1Tests/DiscGroupingTests.swift` (create)

**Interfaces:**
- Consumes: `GameEntry` (existing: `url`, `title`, `isCue`, `id`).
- Produces:
  - `struct GameGroup: Identifiable, Hashable, Sendable { let title: String; let discs: [GameEntry]; var id: String { first.id }; var first: GameEntry }`
  - `enum DiscGrouping { static func group(_ entries: [GameEntry], merging: Bool) -> [GameGroup]; static func discNumber(in title: String) -> Int?; static func baseTitle(_ title: String) -> String }`

`Sources/` is a `PBXFileSystemSynchronizedRootGroup`, so a new `.swift` file needs **no project edit** — do not add `PBXFileReference` entries.

- [ ] **Step 1: Write the failing tests**

Create `ps1-macos/Tests/PS1Tests/DiscGroupingTests.swift`:

```swift
import Testing
import Foundation
@testable import PS1

/// The rule is a pure fold over what `GameScanner` already found, so it is
/// reachable from a test with no filesystem at all.
struct DiscGroupingTests {
    private func entry(_ path: String) -> GameEntry {
        GameEntry(url: URL(fileURLWithPath: path), isCue: true)
    }

    @Test func foldsTheFourFF9DiscsIntoOneGroup() {
        let discs = (1...4).map {
            entry("/games/FF9/Final Fantasy IX (France) (Disc \($0)).cue")
        }
        let groups = DiscGrouping.group(discs.shuffled(), merging: true)

        #expect(groups.count == 1)
        #expect(groups[0].title == "Final Fantasy IX (France)")
        #expect(groups[0].discs.count == 4)
        // Ordered by disc number, not by whatever order the scan produced.
        #expect(groups[0].discs.map(\.title).first?.hasSuffix("(Disc 1)") == true)
        #expect(groups[0].discs.map(\.title).last?.hasSuffix("(Disc 4)") == true)
    }

    @Test func mergingOffYieldsOneGroupPerEntry() {
        let discs = (1...4).map { entry("/games/FF9/FF9 (Disc \($0)).cue") }
        let groups = DiscGrouping.group(discs, merging: false)

        #expect(groups.count == 4)
        #expect(groups.allSatisfy { $0.discs.count == 1 })
        // The title is the file's own, untouched -- turning merging off must
        // not leave the base title on a tile that is only one disc.
        #expect(groups[0].title == "FF9 (Disc 1)")
    }

    @Test func acceptsTheOtherTokenSpellings() {
        #expect(DiscGrouping.discNumber(in: "Game (Disc 2)") == 2)
        #expect(DiscGrouping.discNumber(in: "Game (Disk 2)") == 2)
        #expect(DiscGrouping.discNumber(in: "Game (CD 2)") == 2)
        #expect(DiscGrouping.discNumber(in: "Game [Disc 2]") == 2)
        #expect(DiscGrouping.discNumber(in: "Game (disc 2)") == 2)
        #expect(DiscGrouping.discNumber(in: "Game (Disc 12)") == 12)
        #expect(DiscGrouping.discNumber(in: "Game") == nil)
        // "Discovery" is not a disc token, and neither is a bare number.
        #expect(DiscGrouping.discNumber(in: "Discovery Channel") == nil)
        #expect(DiscGrouping.discNumber(in: "Game (2)") == nil)
    }

    @Test func stripsTheTokenFromTheMiddleOfATitle() {
        #expect(DiscGrouping.baseTitle("Game (Disc 1) (USA)") == "Game (USA)")
        #expect(DiscGrouping.baseTitle("Game (USA) (Disc 1)") == "Game (USA)")
    }

    @Test func doesNotGroupAcrossDirectories() {
        let groups = DiscGrouping.group([
            entry("/games/a/Game (Disc 1).cue"),
            entry("/games/b/Game (Disc 2).cue"),
        ], merging: true)

        // Two rips of the same game in different folders are two games. This
        // is the same per-directory rule GameScanner already applies.
        #expect(groups.count == 2)
    }

    @Test func anEntryWithNoTokenNeverJoinsAGroup() {
        let groups = DiscGrouping.group([
            entry("/games/x/Game (Disc 1).cue"),
            entry("/games/x/Game (Disc 2).cue"),
            entry("/games/x/Game.cue"),
        ], merging: true)

        #expect(groups.count == 2)
        #expect(groups.contains { $0.discs.count == 2 })
        #expect(groups.contains { $0.title == "Game" && $0.discs.count == 1 })
    }

    @Test func groupsAreSortedByTitle() {
        let groups = DiscGrouping.group([
            entry("/games/z/Spyro.cue"),
            entry("/games/a/Croc.cue"),
        ], merging: true)

        #expect(groups.map(\.title) == ["Croc", "Spyro"])
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

```bash
ps1-macos/test.sh 2>&1 | tail -20
```

Expected: build failure — `cannot find 'DiscGrouping' in scope`.

- [ ] **Step 3: Write `DiscGrouping`**

Create `ps1-macos/Sources/PS1/DiscGrouping.swift`:

```swift
import Foundation

/// One tile in the library: a single game, or the discs of a multi-disc one.
struct GameGroup: Identifiable, Hashable, Sendable {
    let title: String
    let discs: [GameEntry]

    /// The first disc IS the group's identity — for `Identifiable`, and for
    /// the cover, which `CoverStore` keys on a hash of the disc path. Writing
    /// the same image once per disc instead would multiply the stored files
    /// and still have to pick one to read back from.
    var id: String { first.id }
    var first: GameEntry { discs[0] }
}

/// Folds `GameScanner`'s per-file entries into per-game groups.
///
/// A pure function over what the scan already found, so the whole rule is
/// reachable from a test with no filesystem. With `merging` false every group
/// holds exactly one disc, which is what lets `LibraryView` render groups
/// unconditionally instead of carrying two rendering paths.
enum DiscGrouping {
    /// `(Disc 2)`, `(Disk 2)`, `(CD 2)`, `[Disc 2]`, any case. Anchored on the
    /// bracket so "Discovery Channel" is not a disc and neither is "(2)".
    private static let token = try! NSRegularExpression(
        pattern: #"[\(\[]\s*(?:disc|disk|cd)\s*(\d+)\s*[\)\]]"#,
        options: [.caseInsensitive])

    static func discNumber(in title: String) -> Int? {
        let range = NSRange(title.startIndex..., in: title)
        guard let m = token.firstMatch(in: title, range: range),
              let numberRange = Range(m.range(at: 1), in: title) else { return nil }
        return Int(title[numberRange])
    }

    /// The title with its disc token removed and the leftover whitespace
    /// collapsed, so "Game (Disc 1) (USA)" and "Game (Disc 2) (USA)" meet at
    /// "Game (USA)".
    static func baseTitle(_ title: String) -> String {
        let range = NSRange(title.startIndex..., in: title)
        let stripped = token.stringByReplacingMatches(
            in: title, range: range, withTemplate: "")
        return stripped
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func group(_ entries: [GameEntry], merging: Bool) -> [GameGroup] {
        guard merging else {
            return entries
                .map { GameGroup(title: $0.title, discs: [$0]) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }

        // Keyed on the directory as well as the base title: two rips of one
        // game in different folders are two games, which is the same
        // per-directory rule GameScanner applies to cues and bins.
        struct Key: Hashable { let directory: String; let title: String }

        var grouped: [Key: [(disc: Int, entry: GameEntry)]] = [:]
        var ungrouped: [GameGroup] = []

        for entry in entries {
            guard let n = discNumber(in: entry.title) else {
                ungrouped.append(GameGroup(title: entry.title, discs: [entry]))
                continue
            }
            let key = Key(
                directory: entry.url.deletingLastPathComponent().standardizedFileURL.path,
                title: baseTitle(entry.title))
            grouped[key, default: []].append((n, entry))
        }

        let merged = grouped.map { key, discs in
            GameGroup(title: key.title,
                      discs: discs.sorted { $0.disc < $1.disc }.map(\.entry))
        }

        return (merged + ungrouped)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
ps1-macos/test.sh 2>&1 | tail -20
```

Expected: the seven new tests pass, nothing else moves.

- [ ] **Step 5: Commit**

```bash
git add ps1-macos/Sources/PS1/DiscGrouping.swift ps1-macos/Tests/PS1Tests/DiscGroupingTests.swift
git commit -m "feat(macos): fold sibling discs into one group

A pure fold over what GameScanner already found, keyed on directory as
well as base title so two rips of one game in different folders stay two
games. With merging off every group holds one disc, so the view renders
groups unconditionally rather than carrying two paths.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CCw6QYGA7ngwzgp8kpC92w"
```

---

### Task 8: The setting, the Library menu, and a grouped grid

**Files:**
- Create: `ps1-macos/Sources/PS1/MultiDiscSetting.swift`
- Create: `ps1-macos/Sources/PS1App/LibraryCommands.swift`
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift` — beside `pgxpSetting` (line ~86)
- Modify: `ps1-macos/Sources/PS1/LibraryView.swift`
- Modify: `ps1-macos/Sources/PS1/GameTile.swift`
- Modify: `ps1-macos/Sources/PS1/ContentView.swift:41-47`
- Modify: `ps1-macos/Sources/PS1App/PS1App.swift:23-33`
- Test: `ps1-macos/Tests/PS1Tests/MultiDiscSettingTests.swift` (create)

**Interfaces:**
- Consumes: `GameGroup`, `DiscGrouping.group(_:merging:)` from Task 7.
- Produces:
  - `struct MultiDiscSetting { static let defaultsKey = "mergeMultiDisc"; init(key:defaults:); private(set) var merging: Bool; mutating func set(_:) }`
  - `EmulatorViewModel.mergeMultiDisc: Bool` (public, settable)
  - `EmulatorViewModel.groups: [GameGroup]`

- [ ] **Step 1: Write the failing test**

Create `ps1-macos/Tests/PS1Tests/MultiDiscSettingTests.swift`:

```swift
import Testing
import Foundation
@testable import PS1

/// Shaped after `PgxpSetting`, with the one difference that matters: this
/// setting defaults to TRUE, so `bool(forKey:)`'s false-for-absent is
/// ambiguous and absence has to be probed the way `VolumeSetting` probes its
/// level. Getting that wrong ships the feature off on every first launch.
struct MultiDiscSettingTests {
    private func scratchDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func aMissingKeyMeansOn() {
        let d = scratchDefaults("merge.default")
        #expect(MultiDiscSetting(key: "merge", defaults: d).merging == true)
    }

    @Test func persistsBothWays() {
        let d = scratchDefaults("merge.persist")
        var s = MultiDiscSetting(key: "merge", defaults: d)

        s.set(false)
        #expect(MultiDiscSetting(key: "merge", defaults: d).merging == false)
        s.set(true)
        #expect(MultiDiscSetting(key: "merge", defaults: d).merging == true)
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

```bash
ps1-macos/test.sh 2>&1 | tail -20
```

Expected: `cannot find 'MultiDiscSetting' in scope`.

- [ ] **Step 3: Write `MultiDiscSetting`**

Create `ps1-macos/Sources/PS1/MultiDiscSetting.swift`:

```swift
import Foundation

/// Whether a multi-disc game shows as one library tile.
///
/// Shaped after `PgxpSetting` — `init` resolves from `UserDefaults`, `set`
/// persists, and the rule lives in the type so it is reachable from a test
/// without a window — with one difference that is a trap rather than a style
/// note. `PgxpSetting` can read its key with `bool(forKey:)` precisely because
/// it defaults to false and false is what a missing key returns. This defaults
/// to TRUE, so that reasoning inverts: absence has to be probed with
/// `object(forKey:)`, the way `VolumeSetting` probes its level, or the feature
/// ships off on every first launch.
///
/// On by default because four Final Fantasy IX tiles is the noise this exists
/// to remove. It is not one of the byte-exactness defaults (1x, PGXP off) —
/// it changes no emulated behaviour at all.
struct MultiDiscSetting {
    static let defaultsKey = "mergeMultiDisc"

    private let defaults: UserDefaults
    private let key: String
    private(set) var merging: Bool

    init(key: String = MultiDiscSetting.defaultsKey,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = key
        self.merging = (defaults.object(forKey: key) as? NSNumber)?.boolValue ?? true
    }

    mutating func set(_ value: Bool) {
        merging = value
        defaults.set(value, forKey: key)
    }
}
```

- [ ] **Step 4: Expose it and the grouped list on the view model**

In `ps1-macos/Sources/PS1/EmulatorViewModel.swift`, after the `pgxpEnabled` computed property:

```swift
    /// Whether a multi-disc game shows as one tile — the same computed seam
    /// over a stored struct as `internalScale` above, so `@Observable`
    /// instruments it and the grid re-folds on a change.
    private var multiDiscSetting = MultiDiscSetting()

    public var mergeMultiDisc: Bool {
        get { multiDiscSetting.merging }
        set { multiDiscSetting.set(newValue) }
    }

    /// What the grid renders. Folded on demand rather than stored: the inputs
    /// are `library.entries` and the setting, both observable, so a stored copy
    /// would be a third thing to keep in step with them.
    var groups: [GameGroup] {
        DiscGrouping.group(library.entries, merging: mergeMultiDisc)
    }
```

- [ ] **Step 5: Render groups**

In `ps1-macos/Sources/PS1/LibraryView.swift`, change the stored properties and the grid. The empty/scanning branches still read `library`, so keep that property:

```swift
struct LibraryView: View {
    @Bindable var library: GameLibrary
    let groups: [GameGroup]
    let coverURL: (GameEntry) -> URL?
    let play: (GameEntry) -> Void
    let chooseCover: (GameEntry) -> Void
    let removeCover: (GameEntry) -> Void
    let chooseFolder: () -> Void
```

and in `body`, replace `library.entries.isEmpty` with `groups.isEmpty` in both branches, then the grid:

```swift
    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 22) {
                ForEach(groups) { group in
                    // The group's first disc carries its cover and is what
                    // Play opens; a multi-disc game always starts on disc 1,
                    // and Machine > Change Disc moves between them.
                    let url = coverURL(group.first)
                    GameTile(
                        entry: group.first,
                        title: group.title,
                        discCount: group.discs.count,
                        coverURL: url,
                        play: { play(group.first) },
                        chooseCover: { chooseCover(group.first) },
                        removeCover: url == nil
                            ? nil : { removeCover(group.first) })
                }
            }
            .padding(24)
            // The title bar is hidden but the window still reserves its height,
            // and the grid scrolls under it.
            .padding(.top, 24)
        }
    }
```

- [ ] **Step 6: Show the disc count on the tile**

In `ps1-macos/Sources/PS1/GameTile.swift`, add the two properties and use them:

```swift
struct GameTile: View {
    let entry: GameEntry
    /// The GROUP's title, which for a multi-disc game is the shared one with
    /// the disc token stripped — not `entry.title`, which is disc 1's filename.
    let title: String
    let discCount: Int
    let coverURL: URL?
```

and replace the label:

```swift
            Text(title)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if discCount > 1 {
                Text("\(discCount) discs")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
```

- [ ] **Step 7: Pass the groups in**

In `ps1-macos/Sources/PS1/ContentView.swift`, the `.library` case:

```swift
            case .library:
                LibraryView(
                    library: model.library,
                    groups: model.groups,
                    coverURL: { model.coverURL(for: $0) },
                    play: { model.play($0) },
                    chooseCover: { model.chooseCover(for: $0) },
                    removeCover: { model.removeCover(for: $0) },
                    chooseFolder: { model.chooseGamesFolder() })
```

- [ ] **Step 8: Add the Library menu**

Create `ps1-macos/Sources/PS1App/LibraryCommands.swift`:

```swift
import SwiftUI

/// The Library menu.
///
/// A `Commands` type rather than an inline `CommandMenu`, for the reason
/// `VideoCommands` gives: `@Bindable` produces the toggle's binding directly,
/// where `Binding(get:set:)` would capture the `@MainActor` model in two
/// escaping closures.
///
/// These three items were in File, which had become the folder-and-refresh
/// menu by default rather than by design. `Open Disc…` stays there.
struct LibraryCommands: Commands {
    @Bindable var model: EmulatorViewModel

    var body: some Commands {
        CommandMenu("Library") {
            Toggle("Merge Multi-Disc Games", isOn: $model.mergeMultiDisc)

            Divider()

            // ⇧⌘R, not ⌘R: that is Reset, in the Machine menu.
            Button("Refresh Library") { model.rescanLibrary() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Choose Games Folder…") { model.chooseGamesFolder() }
            Button("Choose BIOS Folder…") { model.chooseBIOSFolder() }
        }
    }
}
```

Then in `ps1-macos/Sources/PS1App/PS1App.swift`, cut those three buttons out of the `.newItem` group and add the menu:

```swift
            CommandGroup(replacing: .newItem) {
                Button("Open Disc…") { model.openDisc() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Machine") {
                Button(model.isPaused ? "Resume" : "Pause") { model.isPaused.toggle() }
                    .keyboardShortcut("p")
                Button("Reset") { model.reset() }
                    .keyboardShortcut("r")
                Button("Eject") { model.eject() }
                    .keyboardShortcut("e")
            }
            LibraryCommands(model: model)
            VideoCommands(model: model)
```

- [ ] **Step 9: Run the tests**

```bash
ps1-macos/test.sh 2>&1 | tail -30
```

Expected: pass. If `GameScannerTests` or `GameLibraryTests` construct a `GameTile` or `LibraryView` directly they will need the two new arguments — update them rather than adding defaults, so a future call site has to state what it means.

- [ ] **Step 10: Commit**

```bash
git add ps1-macos/Sources/PS1/MultiDiscSetting.swift ps1-macos/Sources/PS1App/LibraryCommands.swift ps1-macos/Sources/PS1/EmulatorViewModel.swift ps1-macos/Sources/PS1/LibraryView.swift ps1-macos/Sources/PS1/GameTile.swift ps1-macos/Sources/PS1/ContentView.swift ps1-macos/Sources/PS1App/PS1App.swift ps1-macos/Tests/PS1Tests/MultiDiscSettingTests.swift
git commit -m "feat(macos): one tile per game, not one per disc

Merge Multi-Disc Games, on by default, in a new Library menu that also
takes the folder and refresh items File had collected by default rather
than by design.

The setting defaults to TRUE, so unlike PgxpSetting it cannot read its
key with bool(forKey:) -- absence is probed with object(forKey:) the way
VolumeSetting probes its level, or the feature ships off on first launch.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CCw6QYGA7ngwzgp8kpC92w"
```

---

### Task 9: Machine ▸ Change Disc

**Files:**
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift` — `load(disc:)` (line 216) and new members
- Modify: `ps1-macos/Sources/PS1App/PS1App.swift` — the Machine menu
- Test: `ps1-macos/Tests/PS1Tests/EmulatorViewModelStageTests.swift`

**Interfaces:**
- Consumes: `EmulatorRunner.requestDiscSwap(bin:cue:sbi:)` (Task 6), `DiscGrouping` (Task 7), the existing `Self.discImage(forCue:)` and `Self.sidecar(forDisc:)`.
- Produces:
  - `EmulatorViewModel.siblingDiscs(of: URL) -> [GameEntry]` (static)
  - `EmulatorViewModel.currentDiscs: [GameEntry]`
  - `EmulatorViewModel.currentDiscIndex: Int?`
  - `EmulatorViewModel.changeDisc(to entry: GameEntry)`

- [ ] **Step 1: Write the failing test**

Append to `ps1-macos/Tests/PS1Tests/EmulatorViewModelStageTests.swift`:

```swift
@Test @MainActor func siblingDiscsAreFoundFromTheDiscsOwnDirectory() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("changedisc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    for n in 1...3 {
        try Data().write(to: dir.appendingPathComponent("Game (Disc \(n)).cue"))
    }
    // A different game in the same folder must not join the list.
    try Data().write(to: dir.appendingPathComponent("Other.cue"))

    let siblings = EmulatorViewModel.siblingDiscs(
        of: dir.appendingPathComponent("Game (Disc 2).cue"))

    #expect(siblings.count == 3)
    #expect(siblings.map(\.title) == [
        "Game (Disc 1)", "Game (Disc 2)", "Game (Disc 3)",
    ])
}

@Test @MainActor func aSingleDiscGameHasNoSiblingsToSwapTo() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("changedisc-solo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let cue = dir.appendingPathComponent("Croc.cue")
    try Data().write(to: cue)

    // One entry, not zero: the menu is disabled on a count of 1, and an empty
    // list would make "which disc am I on" unanswerable.
    #expect(EmulatorViewModel.siblingDiscs(of: cue).map(\.title) == ["Croc"])
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

```bash
ps1-macos/test.sh 2>&1 | tail -20
```

Expected: `type 'EmulatorViewModel' has no member 'siblingDiscs'`.

- [ ] **Step 3: Add the sibling lookup and the swap**

In `ps1-macos/Sources/PS1/EmulatorViewModel.swift`, add the stored state beside `discTitle`:

```swift
    /// The discs of the game that is running, and which one is in the drive.
    /// Derived from the launched disc's own DIRECTORY rather than from the
    /// tile that was clicked, so Change Disc also works for a game opened
    /// through File ▸ Open Disc… that was never in the library folder.
    ///
    /// Deliberately independent of `mergeMultiDisc`: that setting decides how
    /// the grid looks, and a player who prefers separate tiles has not asked
    /// to lose disc swapping. DuckStation's Change Disc is independent of its
    /// game-list setting for the same reason.
    private(set) var currentDiscs: [GameEntry] = []
    private(set) var currentDiscIndex: Int?
```

and these methods, next to `load(disc:)`:

```swift
    /// Every disc of the game `url` belongs to, in disc order — `[url]` alone
    /// when its name carries no disc token, or when it is the only one.
    static func siblingDiscs(of url: URL) -> [GameEntry] {
        let directory = url.deletingLastPathComponent()
        let entries = GameScanner.scan(root: directory)
        let self_ = GameEntry(url: url, isCue: url.pathExtension.lowercased() == "cue")

        let group = DiscGrouping.group(entries, merging: true)
            .first { $0.discs.contains { $0.id == self_.id } }
        return group?.discs ?? [self_]
    }

    /// Puts a different disc of the running game in the drive.
    ///
    /// Everything that can fail is done BEFORE the request is queued, so a
    /// bad rip leaves the running game alone rather than opening the tray on
    /// a machine that has nothing to close it on.
    func changeDisc(to entry: GameEntry) {
        guard let runner else { return }
        do {
            let isCue = entry.url.pathExtension.lowercased() == "cue"
            let binData: Data
            let cueData: Data?
            if isCue {
                let image = try Self.discImage(forCue: entry.url)
                binData = image.bin
                cueData = image.cue
            } else {
                binData = try Data(contentsOf: entry.url)
                cueData = nil
            }
            runner.requestDiscSwap(bin: binData, cue: cueData,
                                   sbi: Self.sidecar(forDisc: entry.url))
            currentDiscIndex = currentDiscs.firstIndex { $0.id == entry.id }
            discTitle = entry.title
        } catch {
            errorMessage = Self.describe(error)
        }
    }
```

and in `load(disc:)`, beside the existing `discTitle = …` assignment:

```swift
            discTitle = url.deletingPathExtension().lastPathComponent
            currentDiscs = Self.siblingDiscs(of: url)
            currentDiscIndex = currentDiscs.firstIndex { $0.url == url }
```

and in `eject()`, before `stage = .library`:

```swift
        currentDiscs = []
        currentDiscIndex = nil
```

- [ ] **Step 4: Add the menu**

In `ps1-macos/Sources/PS1App/PS1App.swift`, inside `CommandMenu("Machine")`, after the Eject button:

```swift
                Divider()

                Menu("Change Disc") {
                    ForEach(Array(model.currentDiscs.enumerated()), id: \.element.id) { index, disc in
                        Button {
                            model.changeDisc(to: disc)
                        } label: {
                            // The checkmark is drawn rather than set through
                            // a Picker: the list is not a preference, it is an
                            // action per item, and a Picker would re-select on
                            // a swap that has not been applied yet.
                            Text(index == model.currentDiscIndex
                                 ? "✓ \(disc.title)" : "   \(disc.title)")
                        }
                    }
                }
                .disabled(model.currentDiscs.count < 2)
```

- [ ] **Step 5: Run the tests**

```bash
ps1-macos/test.sh 2>&1 | tail -30
```

Expected: pass.

- [ ] **Step 6: Verify it by hand against Final Fantasy IX**

```bash
zig build capi-lib && zig build metallib && zig build macos
open zig-out/PS1.app
```

Play *Final Fantasy IX (Disc 1)*, let it boot to the title screen, then **Machine ▸ Change Disc ▸ Disc 2**. What to look for, in order:

1. The menu lists four discs with the checkmark on disc 1.
2. The game does not crash or freeze — for about a second it is being refused every CD command, which is the tray travelling.
3. It survives past that second and keeps running.

A game sitting on a static screen is not necessarily hung; if it looks stuck, give it real time before concluding anything. If the swap wedges it, the first thing to vary is `shell_open_cycles` — it is the one number here with no hardware measurement behind it, only the observation that physical trays take about a second.

- [ ] **Step 7: Commit**

```bash
git add ps1-macos/Sources/PS1/EmulatorViewModel.swift ps1-macos/Sources/PS1App/PS1App.swift ps1-macos/Tests/PS1Tests/EmulatorViewModelStageTests.swift
git commit -m "feat(macos): Machine > Change Disc

The disc list comes from the running disc's own directory, not from the
tile that was clicked, so it works for a game opened through Open Disc...
too. Independent of Merge Multi-Disc Games: that decides how the grid
looks, and a player who prefers separate tiles has not asked to lose disc
swapping.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CCw6QYGA7ngwzgp8kpC92w"
```

---

### Task 10: Replace the "No disc swap" gap in CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` — the "Known remaining gaps" bullet under § CDROM — state of play, and the macOS app section

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Replace the gap bullet**

Find it:

```bash
grep -n "No disc swap" CLAUDE.md
```

Replace that bullet with a rule entry in the CDROM section proper (it is no longer a gap), keeping what is still true — the memory card half:

```markdown
- **A disc swap is a TRAY, not a slice replacement.** `swapDisc` opens the
  shell, installs the disc and closes the tray one emulated second later
  (`shell_open_cycles`); status **bit 4 is derived, never stored**, from
  `shell_open or shell_changed`, and `shell_changed` is STICKY — it survives
  the close and is consumed only by a `Getstat` issued once the tray is shut.
  That latch is the entire mechanism by which a game learns its disc changed
  and re-reads the TOC instead of trusting the file table it cached from the
  previous one; `setDisc` alone is invisible to it. Commands during the window
  are refused with PSX-SPX's `INT5(stat+1, 80h)`, which with the motor off is
  the `{0x11, 0x80}` Avocado hardcodes into GetID alone. **Avocado is not an
  oracle here**: it models `shellOpen` but neither the latch nor its clear, and
  swaps in one instant, so on its own model a polling game has nothing to
  observe. Reached over the ABI as `ps1_swap_disc`, and in the app through
  `EmulatorRunner.requestDiscSwap` — which queues it for the emulator thread,
  because `runLoop` owns the core and a main-actor call would widen the race
  `reset()` documents. `shell_open_cycles` is the one number here with no
  hardware measurement behind it and is the first thing to vary if a title
  will not cross a disc boundary.
- **Multi-disc saves still do not persist.** The 128 KB memory card image is
  in-memory only (`memcard_dirty` is set and never consumed), so quitting
  between discs still loses the save. A real swap does not go through that
  path — the game hands its state over in RAM — so this no longer blocks
  multi-disc play; it blocks resuming one.
```

- [ ] **Step 2: Note the library rules in the macOS section**

After the `GameScanner` paragraph, add:

```markdown
`DiscGrouping` folds the scanner's per-file entries into per-game tiles behind
**Library ▸ Merge Multi-Disc Games** (`MultiDiscSetting`, default ON). The rule
is keyed on the directory as well as the disc-token-stripped title, so two rips
of one game in different folders stay two games; an entry whose name carries no
`(Disc N)` token never groups. With merging off every group holds exactly one
disc, which is why `LibraryView` renders groups unconditionally rather than
carrying two paths. The group's cover is its FIRST disc's, since `CoverStore`
keys on a hash of the disc path. **`MultiDiscSetting` cannot read its key with
`bool(forKey:)`** the way `PgxpSetting` does — it defaults to true, so absence
is ambiguous and is probed with `object(forKey:)`, as `VolumeSetting` does for
its level. **Machine ▸ Change Disc is deliberately independent of the toggle**
and derives its list from the running disc's own directory, so it also works
for a game opened through `File ▸ Open Disc…`.
```

- [ ] **Step 3: Full verification**

```bash
zig build test 2>&1 | tail -5
zig build trace-golden -Doptimize=ReleaseFast -- verify 2>&1 | tail -12
ps1-macos/test.sh 2>&1 | tail -5
```

Expected: 15 test binaries pass; ten workloads OK with no recapture; the Swift suite passes.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: disc swap is no longer a gap

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CCw6QYGA7ngwzgp8kpC92w"
```

---

## Self-review notes

**Spec coverage.** § 1 → Task 1. § 2 → Task 1 (Steps 6, 1). § 3 → Task 2. § 4 → Task 3, with the `nextDeadline` qualification carried into Step 7 rather than dropped. § 5 → Task 4. § 6 → Task 6. § 7 → Task 5. § 8 → Tasks 7 and 8. § 9 → Task 8. § 10 → Task 9. Spec § Testing → each task's test step, plus Task 10 Step 3 as the full sweep.

**Known follow-ups, deliberately not in this plan.** `ps1-trace`, `ps1-debug` and `ps1-wasm` get no swap entry point — the spec's Out list covers the browser, and the two native harnesses take a single disc on argv with no UI to drive a swap from. `ps1-golden`'s multi-`.cue` skip means Final Fantasy IX is still not a golden workload, so the swap path has no trace coverage; Task 9 Step 6's hand check is the only end-to-end verification, and it is a real one.
