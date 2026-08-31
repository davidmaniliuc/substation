# Memory Card Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Quit the app and still have your save — one shared memory card per slot, on disk, written on a debounce.

**Architecture:** Three layers, bottom up. `ps1-core/src/sio.zig` gets the real PSX-SPX card protocol (it has never had it) and per-slot state behind a decoded JOY_CTRL port-select bit. `ps1-capi` gains a copy-in loader and a drain-style taker, plus card retention across `ps1_reset`. `ps1-macos` gains a `MemoryCardStore` (files) and a `MemoryCardFlushPolicy` (when to write), driven from `EmulatorRunner`'s loop, which is the only thread that owns the core.

**Tech Stack:** Zig 0.16.0, C ABI (hand-written `ps1-capi/include/ps1.h`), Swift 6 / SwiftUI / swift-testing under Xcode 26.6.

**Spec:** `docs/superpowers/specs/2026-08-31-memory-card-persistence-design.md`

## Global Constraints

- **Zig must be 0.16.0** (`zig version`). Run `zig fmt` on every `.zig` file touched before committing.
- **Run every command from the repo root.** The harnesses resolve BIOS, discs and test ROMs relative to the process CWD.
- **No file in `ps1-core/src` over ~600 lines.** `sio.zig` is 377 lines today and ends this plan around 470. Do not split it.
- **Casts: Tier A over Tier B.** Let Zig infer the target from the result location (`const x: u8 = @truncate(v);`). Do not add helpers to `bits.zig` for anything here.
- **Every regression test must be verified to FAIL before the fix lands.** A guard test that cannot fail is worse than none. Each task's "run the test" step states the expected failure text.
- **One commit per task**, on `master`, message in the house style (what changed and why, not a changelog). End every commit message with:
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`
- **Never `git push`.** Commit only.
- **Do not recapture `ps1-golden` goldens except in Task 4**, which exists for exactly that. Tasks 2 and 3 may leave `trace-golden -- verify` red; that is expected and is not a bug to chase.
- **`ps1-macos` needs the Zig archives rebuilt before its tests see an ABI change**: `zig build capi-lib` then `zig build metallib`, then `ps1-macos/test.sh`.
- **New `.swift` files need no Xcode project edit.** `Sources/` and `Tests/` are `PBXFileSystemSynchronizedRootGroup`s — the folder is the target membership.
- **Documentation lands in the implementing commit**, not in a trailing docs pass.

---

## File Structure

**Created:**
- `ps1-macos/Sources/PS1/MemoryCardStore.swift` — the two card files on disk. Load, atomic write, one serial queue for all access.
- `ps1-macos/Sources/PS1/MemoryCardFlushPolicy.swift` — a value type holding the debounce rule. No I/O, no clock of its own.
- `ps1-macos/Tests/PS1Tests/MemoryCardStoreTests.swift`
- `ps1-macos/Tests/PS1Tests/MemoryCardFlushPolicyTests.swift`

**Modified:**
- `ps1-core/src/sio.zig` — card protocol (Task 2), per-slot state and port select (Task 3).
- `ps1-core/tests/sio_test.zig` — tests for both.
- `ps1-golden/src/state_hash.zig` — `hashSio` is hand-written and must follow the field changes (Task 3).
- `ps1-capi/include/ps1.h`, `ps1-capi/src/root.zig`, `ps1-capi/src/capi_test.zig` — the ABI (Task 5).
- `ps1-macos/Sources/PS1/Ps1Core.swift` — two wrapper methods, two error cases (Task 6).
- `ps1-macos/Sources/PS1/EmulatorRunner.swift` — take per loop iteration, flush on stop (Task 6).
- `ps1-macos/Sources/PS1/EmulatorViewModel.swift` — install after teardown, flush on quit (Task 7).
- `CLAUDE.md` — the SIO section (Task 3), the CDROM gap list and the card layout (Task 7).

---

## Task 1: Read the ground truth

No code. This task exists because the next one rewrites a protocol, and the reference is three files.

- [ ] **Step 1: Read the reference implementation**

Read `avocado_ref/src/device/controller/peripherals/memory_card.cpp` in full (about 175 lines) and its header. Note in particular:

- `handle()` state 0 accepts **`0x81`** and returns `0xFF`; state 1 takes `'R'` (0x52), `'W'` (0x57) or `'S'` (0x53) and returns the **FLAG byte**, clearing `flag.error` as it goes. Any other command byte resets `state = 0`.
- `handleRead` byte order: `0x5A`, `0x5D`, MSB (returns 0), LSB (returns 0), `0x5C`, `0x5D`, MSB again, LSB again, 128 data bytes, checksum, `'G'`.
- `handleWrite` byte order: `0x5A`, `0x5D`, MSB, LSB, 128 data bytes (each returns 0), checksum byte (returns 0), `0x5C`, `0x5D`, status (`'G'` / `'N'` / `0xFF`).
- `flag` is `fresh | unknown` = `0x18` at power-up; `error` is bit 2 (`0x04`); `fresh` is cleared when a write completes.
- An address above 1023 sets `flag.error`, is masked to 10 bits, and makes the write report `0xFF` (BadSector).

- [ ] **Step 2: Read what we have**

Read `ps1-core/src/sio.zig:140-300`. Confirm for yourself that `.Idle` only leaves for `tx == 0x01`, and that `0x81`/`0x82` are handled one state later as read/write commands. That is the bug: real software opens a card packet with `0x81`, so the whole card path is dead code today.

- [ ] **Step 3: Read the house test style**

Read `ps1-core/tests/sio_test.zig:1-60`. Tests drive the machine through `bus.write8(JOY_DATA, …)` / `bus.read8(JOY_DATA)` and assert on `bus.sio` fields directly. Follow that shape exactly.

Nothing to commit.

---

## Task 2: The real card protocol

**Files:**
- Modify: `ps1-core/src/sio.zig` (the `SioState` enum at :37-67, the memory-card fields at :106-115, the `.Idle` and `.AwaitingCmd` arms at :145-174, and the memory-card arms at :208-295)
- Test: `ps1-core/tests/sio_test.zig` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: a card reachable by the real sequence. `Sio.memcard_dirty: bool` keeps its name and meaning (raised when a written block's checksum verified). Task 3 turns it into an array; nothing outside `sio.zig` reads it until Task 5.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/sio_test.zig`:

```zig
/// Clocks one byte through the JOY port and returns what the addressed
/// peripheral put in RX_DATA. The card protocol is a strict byte sequence, so
/// every card test below is a list of these.
fn xfer(bus: *Bus, tx: u8) u8 {
    bus.write8(JOY_DATA, tx);
    return bus.read8(JOY_DATA);
}

/// Drives the PSX-SPX read sequence for one 128-byte block and returns the
/// data bytes, the checksum byte the card reported, and the end byte.
fn readBlock(bus: *Bus, block: u16) struct { data: [128]u8, checksum: u8, end: u8 } {
    _ = xfer(bus, 0x81); // address the memory card
    _ = xfer(bus, 'R'); // read command; the card answers with FLAG
    _ = xfer(bus, 0x00); // 0x5A
    _ = xfer(bus, 0x00); // 0x5D
    _ = xfer(bus, @truncate(block >> 8)); // address MSB
    _ = xfer(bus, @truncate(block & 0xFF)); // address LSB
    _ = xfer(bus, 0x00); // 0x5C
    _ = xfer(bus, 0x00); // 0x5D
    _ = xfer(bus, 0x00); // MSB, echoed back
    _ = xfer(bus, 0x00); // LSB, echoed back

    var data: [128]u8 = undefined;
    for (&data) |*b| b.* = xfer(bus, 0x00);
    const checksum = xfer(bus, 0x00);
    const end = xfer(bus, 0x00);
    return .{ .data = data, .checksum = checksum, .end = end };
}

/// Drives the PSX-SPX write sequence. `checksum_override` lets a test send a
/// deliberately wrong checksum; pass null to send the correct one.
fn writeBlock(bus: *Bus, block: u16, fill: u8, checksum_override: ?u8) u8 {
    _ = xfer(bus, 0x81);
    _ = xfer(bus, 'W');
    _ = xfer(bus, 0x00); // 0x5A
    _ = xfer(bus, 0x00); // 0x5D
    _ = xfer(bus, @truncate(block >> 8));
    _ = xfer(bus, @truncate(block & 0xFF));

    var checksum: u8 = @truncate(block >> 8);
    checksum ^= @as(u8, @truncate(block & 0xFF));
    for (0..128) |_| {
        _ = xfer(bus, fill);
        checksum ^= fill;
    }
    _ = xfer(bus, checksum_override orelse checksum);
    _ = xfer(bus, 0x00); // 0x5C
    _ = xfer(bus, 0x00); // 0x5D
    return xfer(bus, 0x00); // status: 'G', 'N', or 0xFF
}

test "a card packet opens with 0x81, not the controller's 0x01" {
    // Regression: the state machine used to leave .Idle only for 0x01 — the
    // CONTROLLER address byte — and then treat 0x81 as a read command. Real
    // software addresses the card with 0x81 as the FIRST byte, so the whole
    // card path was unreachable: nothing acked, and the BIOS card driver
    // reported no card in either slot.
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    _ = xfer(bus, 0x81);
    try expect(bus.sio.ctrl_state != .Idle); // the card answered
    try expect(bus.sio.ack); // and is holding /ACK for the next byte
}

test "the command byte returns the FLAG, with fresh set on an untouched card" {
    // FLAG bit 3 ("directory unread") tells the BIOS the card is new or has
    // been swapped, so it re-reads the directory instead of trusting a cache.
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    _ = xfer(bus, 0x81);
    const flag = xfer(bus, 'R');
    try expectEqual(@as(u8, 0x18), flag); // fresh (bit 3) | unknown (bit 4)
}

test "a full read sequence returns the block's bytes, its checksum and 'G'" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    // Block 2, every byte 0xA5.
    const base = 2 * 128;
    for (0..128) |i| bus.sio.memcard_data[base + i] = 0xA5;

    const r = readBlock(bus, 2);
    for (r.data) |b| try expectEqual(@as(u8, 0xA5), b);
    // The card's running checksum covers the two echoed address bytes and
    // every data byte: 0x00 ^ 0x02 ^ (0xA5 * 128 times, which cancels out).
    try expectEqual(@as(u8, 0x02), r.checksum);
    try expectEqual(@as(u8, 'G'), r.end);
}

test "a write with a good checksum commits the block, reports 'G' and dirties the card" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    try expect(!bus.sio.memcard_dirty);
    const status = writeBlock(bus, 5, 0x3C, null);

    try expectEqual(@as(u8, 'G'), status);
    try expect(bus.sio.memcard_dirty);
    for (0..128) |i| try expectEqual(@as(u8, 0x3C), bus.sio.memcard_data[5 * 128 + i]);
}

test "a write with a bad checksum reports 'N' and commits nothing" {
    // The 128 bytes are staged and copied into the card only once the
    // checksum verifies. Avocado writes them straight into the image and
    // reports 'N' afterwards, which was harmless while the image died with
    // the process — with the image persisted, a rejected sector would be
    // written to disk and the save file would carry the corruption forward.
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    const status = writeBlock(bus, 7, 0x11, 0xFF);

    try expectEqual(@as(u8, 'N'), status);
    try expect(!bus.sio.memcard_dirty);
    for (0..128) |i| try expectEqual(@as(u8, 0x00), bus.sio.memcard_data[7 * 128 + i]);
}

test "a completed write clears the fresh flag" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    _ = writeBlock(bus, 0, 0x01, null);

    _ = xfer(bus, 0x81);
    try expectEqual(@as(u8, 0x10), xfer(bus, 'R')); // unknown only; fresh gone
}

test "an unsupported card command ends the packet without acking" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    _ = xfer(bus, 0x81);
    _ = xfer(bus, 'Z');

    try expectEqual(Bus.SioStateForTests.Idle, @as(Bus.SioStateForTests, @enumFromInt(@intFromEnum(bus.sio.ctrl_state))));
    try expect(!bus.sio.ack);
}
```

Replace that last test's awkward enum comparison with the direct form — `ps1_core.sio.Sio.SioState` is public, so write:

```zig
test "an unsupported card command ends the packet without acking" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    _ = xfer(bus, 0x81);
    _ = xfer(bus, 'Z');

    try expectEqual(ps1_core.sio.Sio.SioState.Idle, bus.sio.ctrl_state);
    try expect(!bus.sio.ack);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`

Expected: the new tests fail. `"a card packet opens with 0x81"` fails on `bus.sio.ctrl_state != .Idle` because `0x81` in `.Idle` is ignored; the FLAG, read, and write tests fail on the very first assertion for the same reason. If any of them *passes*, stop — the protocol is not what this task believes it is, and the rest of the plan rests on that reading.

- [ ] **Step 3: Add the new states and fields**

In `ps1-core/src/sio.zig`, replace the `// Memory Card` block of `SioState` (currently `MemcardAck` through `MemcardWriteGood`) with:

```zig
        // Memory Card
        MemcardCmd,
        MemcardAck1,
        MemcardAck2,
        MemcardAddressMsb,
        MemcardAddressLsb,

        MemcardReadAck1,
        MemcardReadAck2,
        MemcardReadConfirmMsb,
        MemcardReadConfirmLsb,
        MemcardReadData,
        MemcardReadChecksum,
        MemcardReadEnd,

        MemcardWriteData,
        MemcardWriteChecksum,
        MemcardWriteAck1,
        MemcardWriteAck2,
        MemcardWriteStatus,
```

Add these consts next to `memcard_address_mask`:

```zig
    /// The whole card: 1024 addressable blocks of 128 bytes.
    pub const memcard_bytes = memcard_sector_bytes * (memcard_address_mask + 1);

    /// FLAG, the byte the card returns on the command byte of every packet.
    /// Bit 3 ("fresh") tells software the directory has not been read since
    /// the card appeared, so it re-reads it rather than trusting a cache; bit
    /// 4 is documented only as always-set. Bit 2 is the error latch, raised by
    /// an out-of-range address or a failed checksum and cleared by the read.
    const memcard_flag_fresh: u8 = 0x08;
    const memcard_flag_unknown: u8 = 0x10;
    const memcard_flag_error: u8 = 0x04;
```

Replace the memory-card field block with:

```zig
    // Memory Card State
    memcard_data: [memcard_bytes]u8 = [_]u8{0} ** memcard_bytes,
    /// The 128 bytes of an in-flight write, held back until its checksum
    /// verifies. A rejected sector must not reach `memcard_data`: the image is
    /// persisted to disk, so a corrupt block written and then reported bad
    /// would outlive the session that produced it.
    memcard_staging: [memcard_sector_bytes]u8 = [_]u8{0} ** memcard_sector_bytes,
    memcard_address: u16 = 0,
    memcard_checksum: u8 = 0,
    memcard_step: u32 = 0,
    memcard_is_write: bool = false,
    memcard_dirty: bool = false,
    memcard_flag: u8 = memcard_flag_fresh | memcard_flag_unknown,
    /// What the write sequence will report in its final byte: 'G' good, 'N'
    /// bad checksum, 0xFF bad sector.
    memcard_status: u8 = 'G',
```

- [ ] **Step 4: Rewrite the packet entry**

Replace the `.Idle` arm and the card branches of `.AwaitingCmd`:

```zig
                    .Idle => {
                        // The first byte of a packet ADDRESSES a peripheral:
                        // 0x01 the controller, 0x81 the memory card. Anything
                        // else leaves the port with nobody listening.
                        if (tx == 0x01) {
                            self.ctrl_state = .AwaitingCmd;
                        } else if (tx == 0x81) {
                            self.ctrl_state = .MemcardCmd;
                        }
                    },
                    .AwaitingCmd => {
                        if (tx == 0x42) { // Read Controller
                            // A pad powers up in digital mode and only reports
                            // the DualShock ID once analog mode has been enabled
                            // (escape command 0x43/0x44, not implemented here).
                            // Claiming 0x73 unconditionally makes pre-DualShock
                            // titles parse a 6-byte analog packet they don't expect.
                            self.rx_data = if (self.analog_enabled) dualshock_pad_id else digital_pad_id;
                            self.ctrl_state = .CtrlAwaitingTap;
                        } else {
                            self.ctrl_state = .Idle;
                        }
                    },
```

- [ ] **Step 5: Rewrite the card arms**

Replace every arm from `.MemcardAck` to `.MemcardWriteGood` with:

```zig
                    // --- MEMORY CARD ---
                    .MemcardCmd => {
                        // The command byte is answered with FLAG, and reading
                        // it clears the error latch — the next packet reports
                        // only its own failures.
                        self.rx_data = self.memcard_flag;
                        self.memcard_flag &= ~memcard_flag_error;
                        if (tx == 'R') {
                            self.memcard_is_write = false;
                            self.ctrl_state = .MemcardAck1;
                        } else if (tx == 'W') {
                            self.memcard_is_write = true;
                            self.ctrl_state = .MemcardAck1;
                        } else {
                            // 'S' (get card ID) included: Avocado does not
                            // implement it either, and nothing is known to
                            // send it.
                            self.rx_data = 0xFF;
                            self.ctrl_state = .Idle;
                        }
                    },
                    .MemcardAck1 => {
                        self.rx_data = 0x5A;
                        self.ctrl_state = .MemcardAck2;
                    },
                    .MemcardAck2 => {
                        self.rx_data = 0x5D;
                        self.ctrl_state = .MemcardAddressMsb;
                    },
                    .MemcardAddressMsb => {
                        self.rx_data = 0x00;
                        self.memcard_address = @as(u16, tx) << 8;
                        self.ctrl_state = .MemcardAddressLsb;
                    },
                    .MemcardAddressLsb => {
                        self.rx_data = 0x00;
                        self.memcard_address |= tx;

                        self.memcard_status = 'G';
                        if (self.memcard_address > memcard_address_mask) {
                            self.memcard_flag |= memcard_flag_error;
                            self.memcard_address &= memcard_address_mask;
                            self.memcard_status = 0xFF; // bad sector
                        }

                        self.memcard_step = 0;
                        if (self.memcard_is_write) {
                            self.memcard_checksum = @truncate(self.memcard_address >> 8);
                            self.memcard_checksum ^= @as(u8, @truncate(self.memcard_address & 0xFF));
                            self.ctrl_state = .MemcardWriteData;
                        } else {
                            self.ctrl_state = .MemcardReadAck1;
                        }
                    },
                    .MemcardReadAck1 => {
                        self.rx_data = 0x5C;
                        self.ctrl_state = .MemcardReadAck2;
                    },
                    .MemcardReadAck2 => {
                        self.rx_data = 0x5D;
                        self.ctrl_state = .MemcardReadConfirmMsb;
                    },
                    .MemcardReadConfirmMsb => {
                        // The read checksum starts from the ECHOED address
                        // bytes, not from the ones software sent: an address
                        // masked into range must be checksummed as it will be
                        // reported.
                        const msb: u8 = @truncate(self.memcard_address >> 8);
                        self.rx_data = msb;
                        self.memcard_checksum = msb;
                        self.ctrl_state = .MemcardReadConfirmLsb;
                    },
                    .MemcardReadConfirmLsb => {
                        const lsb: u8 = @truncate(self.memcard_address & 0xFF);
                        self.rx_data = lsb;
                        self.memcard_checksum ^= lsb;
                        self.memcard_step = 0;
                        self.ctrl_state = .MemcardReadData;
                    },
                    .MemcardReadData => {
                        const addr = self.memcard_address * memcard_sector_bytes + self.memcard_step;
                        const data = self.memcard_data[addr];
                        self.rx_data = data;
                        self.memcard_checksum ^= data;
                        self.memcard_step += 1;
                        if (self.memcard_step == memcard_sector_bytes) {
                            self.ctrl_state = .MemcardReadChecksum;
                        }
                    },
                    .MemcardReadChecksum => {
                        self.rx_data = self.memcard_checksum;
                        self.ctrl_state = .MemcardReadEnd;
                    },
                    .MemcardReadEnd => {
                        self.rx_data = 'G';
                        self.ctrl_state = .Idle;
                    },
                    .MemcardWriteData => {
                        self.rx_data = 0x00;
                        self.memcard_staging[self.memcard_step] = tx;
                        self.memcard_checksum ^= tx;
                        self.memcard_step += 1;
                        if (self.memcard_step == memcard_sector_bytes) {
                            self.ctrl_state = .MemcardWriteChecksum;
                        }
                    },
                    .MemcardWriteChecksum => {
                        self.rx_data = 0x00;
                        if (tx != self.memcard_checksum) {
                            self.memcard_flag |= memcard_flag_error;
                            self.memcard_status = 'N';
                        }
                        if (self.memcard_status == 'G') {
                            const base = self.memcard_address * memcard_sector_bytes;
                            @memcpy(self.memcard_data[base..][0..memcard_sector_bytes], &self.memcard_staging);
                            self.memcard_dirty = true;
                            self.memcard_flag &= ~memcard_flag_fresh;
                        }
                        self.ctrl_state = .MemcardWriteAck1;
                    },
                    .MemcardWriteAck1 => {
                        self.rx_data = 0x5C;
                        self.ctrl_state = .MemcardWriteAck2;
                    },
                    .MemcardWriteAck2 => {
                        self.rx_data = 0x5D;
                        self.ctrl_state = .MemcardWriteStatus;
                    },
                    .MemcardWriteStatus => {
                        self.rx_data = self.memcard_status;
                        self.ctrl_state = .Idle;
                    },
```

Note the address no longer needs masking at use — `.MemcardAddressLsb` masks it once, which is also where the error latch is raised.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `zig fmt ps1-core/src/sio.zig ps1-core/tests/sio_test.zig && zig build test`

Expected: all 15 test binaries pass, including the seven new card tests and the existing pad tests (the pad path is untouched — `0x01` then `0x42` still works).

- [ ] **Step 7: Commit**

```bash
git add ps1-core/src/sio.zig ps1-core/tests/sio_test.zig
git commit -m "$(cat <<'MSG'
fix(sio): give the memory card the protocol real software speaks

The state machine left .Idle only for 0x01 — the CONTROLLER address byte —
and then took 0x81/0x82 as read/write. A card packet opens with 0x81 and
carries 'R'/'W' as its command, so the whole card path was unreachable: the
BIOS driver got no ack and reported no card. The 128 KB image has never been
written by anything but a unit test, which is why nothing noticed.

Ported from avocado_ref/src/device/controller/peripherals/memory_card.cpp,
with the FLAG byte (fresh/unknown/error), the out-of-range address latch, and
one deliberate divergence: the 128 bytes of a write are STAGED and copied in
only once the checksum verifies. Avocado writes them straight into the image
and reports 'N' afterwards, which was harmless while the image died with the
process — the next commits persist it, and a rejected sector must not reach
the file.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

## Task 3: Port select and per-slot cards

**Files:**
- Modify: `ps1-core/src/sio.zig`
- Modify: `ps1-golden/src/state_hash.zig:442-469` (`hashSio`)
- Modify: `CLAUDE.md` (§ Memory / interrupts / timers / SIO)
- Test: `ps1-core/tests/sio_test.zig` (append)

**Interfaces:**
- Consumes: Task 2's protocol and state names.
- Produces:
  - `pub const Sio.memcard_slots = 2` and `pub const Sio.memcard_bytes = 131072`.
  - `pub fn getMemoryCardData(self: *Self, slot: usize) []u8`
  - `pub fn setMemoryCardData(self: *Self, slot: usize, bytes: *const [memcard_bytes]u8) void`
  - `pub fn isMemoryCardDirty(self: *Self, slot: usize) bool`
  - `pub fn clearMemoryCardDirty(self: *Self, slot: usize) void`

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/sio_test.zig`. The `xfer`/`readBlock`/`writeBlock` helpers from Task 2 are reused; add one for selecting a slot:

```zig
/// JOY_CTRL bit 13 selects which of the two ports the next packet addresses.
/// Bits 0 and 1 (TX enable, /JOYn output) are what software sets alongside it;
/// bit 1 low would reset the transfer state, so a select always carries it.
fn selectPort(bus: *Bus, port: u1) void {
    bus.write16(JOY_CTRL, 0x0003 | (@as(u16, port) << 13));
}

test "a card write through port 2 leaves port 1's card untouched" {
    // Regression: JOY_CTRL bit 13 was never decoded, so both slots were
    // answered by the same 128 KB image. With the image persisted, that makes
    // the BIOS card manager's COPY function — the flow players use to move a
    // save off a full card — copy a card onto itself.
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    selectPort(bus, 1);
    try expectEqual(@as(u8, 'G'), writeBlock(bus, 3, 0x77, null));

    try expect(bus.sio.isMemoryCardDirty(1));
    try expect(!bus.sio.isMemoryCardDirty(0));
    for (0..128) |i| {
        try expectEqual(@as(u8, 0x77), bus.sio.getMemoryCardData(1)[3 * 128 + i]);
        try expectEqual(@as(u8, 0x00), bus.sio.getMemoryCardData(0)[3 * 128 + i]);
    }
}

test "the port is latched at the start of a packet, not read per byte" {
    // The select line is stable for a whole packet on hardware. Re-reading it
    // per byte would let a JOY_CTRL write mid-transfer splice the rest of one
    // card's block into the other's.
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    selectPort(bus, 1);
    _ = xfer(bus, 0x81);
    _ = xfer(bus, 'W');
    _ = xfer(bus, 0x00);
    _ = xfer(bus, 0x00);
    _ = xfer(bus, 0x00); // MSB
    _ = xfer(bus, 0x04); // LSB — block 4

    // Software flips the select line in the middle of the data phase.
    bus.write16(JOY_CTRL, 0x0003);

    var checksum: u8 = 0x00 ^ 0x04;
    for (0..128) |_| {
        _ = xfer(bus, 0x22);
        checksum ^= 0x22;
    }
    _ = xfer(bus, checksum);
    _ = xfer(bus, 0x00);
    _ = xfer(bus, 0x00);
    try expectEqual(@as(u8, 'G'), xfer(bus, 0x00));

    // The whole block belongs to the slot the packet OPENED on.
    for (0..128) |i| {
        try expectEqual(@as(u8, 0x22), bus.sio.getMemoryCardData(1)[4 * 128 + i]);
        try expectEqual(@as(u8, 0x00), bus.sio.getMemoryCardData(0)[4 * 128 + i]);
    }
}

test "port 2 has no controller in it" {
    // A console with an empty port 2 answers a pad poll with nothing: no
    // /ACK, no IRQ7, and the BIOS routine times out and reports no
    // controller. Aliasing port 1's pad into port 2 invents a second player.
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    selectPort(bus, 1);
    _ = xfer(bus, 0x01);
    _ = xfer(bus, 0x42);

    try expectEqual(ps1_core.sio.Sio.SioState.Idle, bus.sio.ctrl_state);
    try expect(!bus.sio.ack);
}

test "port 1 still has a controller in it" {
    // The control for the test above: decoding the select bit must not cost
    // the pad that is actually there.
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    selectPort(bus, 0);
    bus.sio.setButtons(0xFFEF); // Cross pressed (0 = pressed)
    _ = xfer(bus, 0x01);
    try expectEqual(@as(u8, 0x41), xfer(bus, 0x42)); // digital pad ID
    _ = xfer(bus, 0x00); // 0x5A
    try expectEqual(@as(u8, 0xEF), xfer(bus, 0x00)); // buttons low
    try expectEqual(@as(u8, 0xFF), xfer(bus, 0x00)); // buttons high
}

test "setMemoryCardData installs an image per slot and does not dirty it" {
    // Loading a card from disk is not a write BY the machine: reporting it
    // dirty would make the frontend write straight back what it just read.
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    var image: [ps1_core.sio.Sio.memcard_bytes]u8 = undefined;
    @memset(&image, 0x5E);
    bus.sio.setMemoryCardData(1, &image);

    try expectEqual(@as(u8, 0x5E), bus.sio.getMemoryCardData(1)[0]);
    try expectEqual(@as(u8, 0x00), bus.sio.getMemoryCardData(0)[0]);
    try expect(!bus.sio.isMemoryCardDirty(1));
}

test "the dirty flag clears per slot" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    selectPort(bus, 0);
    _ = writeBlock(bus, 1, 0x01, null);
    selectPort(bus, 1);
    _ = writeBlock(bus, 1, 0x02, null);

    bus.sio.clearMemoryCardDirty(0);
    try expect(!bus.sio.isMemoryCardDirty(0));
    try expect(bus.sio.isMemoryCardDirty(1));
}
```

Task 2's tests reach `bus.sio.memcard_data[...]` and `bus.sio.memcard_dirty` directly. Update those five tests to the accessors as part of this step — `bus.sio.getMemoryCardData(0)[…]` and `bus.sio.isMemoryCardDirty(0)` — since the fields become arrays.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`

Expected: compile errors on `getMemoryCardData(1)` (the function takes no argument yet). Add the slot parameter first — Step 3 — and then the four behavioural tests fail: the port-2 write lands in slot 0, the mid-packet flip moves the tail of the block, and the port-2 pad answers with `0x41`.

- [ ] **Step 3: Make the card state per-slot**

In `ps1-core/src/sio.zig`:

```zig
    /// Both controller/memory-card ports. JOY_CTRL bit 13 selects between
    /// them; a real console has two of each socket.
    pub const memcard_slots = 2;

    const blank_card = [_]u8{0} ** memcard_bytes;
```

```zig
    /// Which port the packet in flight is addressed to, sampled from JOY_CTRL
    /// bit 13 on the byte that OPENS the packet. Sampled once because the
    /// select line is stable for a whole packet on hardware, and because
    /// re-reading it per byte would let a JOY_CTRL write mid-transfer splice
    /// one card's block into the other's.
    port: u1 = 0,

    memcard_data: [memcard_slots][memcard_bytes]u8 = .{ blank_card, blank_card },
    memcard_staging: [memcard_slots][memcard_sector_bytes]u8 = .{ [_]u8{0} ** memcard_sector_bytes, [_]u8{0} ** memcard_sector_bytes },
    memcard_address: [memcard_slots]u16 = .{ 0, 0 },
    memcard_checksum: [memcard_slots]u8 = .{ 0, 0 },
    memcard_step: [memcard_slots]u32 = .{ 0, 0 },
    memcard_is_write: [memcard_slots]bool = .{ false, false },
    memcard_dirty: [memcard_slots]bool = .{ false, false },
    memcard_flag: [memcard_slots]u8 = .{ memcard_flag_fresh | memcard_flag_unknown, memcard_flag_fresh | memcard_flag_unknown },
    memcard_status: [memcard_slots]u8 = .{ 'G', 'G' },
```

In `write`, open the `0x0` (TX_DATA) case with a slot binding and index every `memcard_*` access through it:

```zig
                const tx: u8 = @truncate(value);
                self.rx_data = 0xFF;
                const p = self.port;
```

Every `self.memcard_x` inside the card arms becomes `self.memcard_x[p]`, and `&self.memcard_staging` becomes `&self.memcard_staging[p]`. Latch the port in `.Idle`:

```zig
                    .Idle => {
                        // Sampled here, on the address byte, for both kinds of
                        // peripheral: `p` above is last packet's value until
                        // this assignment, which is why nothing in this arm
                        // uses it.
                        self.port = @truncate((self.ctrl >> 13) & 1);
                        if (tx == 0x01) {
                            self.ctrl_state = .AwaitingCmd;
                        } else if (tx == 0x81) {
                            self.ctrl_state = .MemcardCmd;
                        }
                    },
```

Gate the pad on port 0 in `.AwaitingCmd`:

```zig
                    .AwaitingCmd => {
                        // Port 2 has no pad in it. Falling through to .Idle is
                        // the existing "nothing responded" path: no /ACK, no
                        // IRQ7, and the BIOS routine times out and reports no
                        // controller — which is what an empty socket does.
                        if (tx == 0x42 and p == 0) {
                            self.rx_data = if (self.analog_enabled) dualshock_pad_id else digital_pad_id;
                            self.ctrl_state = .CtrlAwaitingTap;
                        } else {
                            self.ctrl_state = .Idle;
                        }
                    },
```

Replace the accessors at the bottom of the struct:

```zig
    pub fn getMemoryCardData(self: *Self, slot: usize) []u8 {
        return &self.memcard_data[slot];
    }

    /// Installs an image loaded from the host, WITHOUT dirtying it: this is
    /// not a write by the machine, and reporting it dirty would have the
    /// frontend write straight back what it just read.
    pub fn setMemoryCardData(self: *Self, slot: usize, bytes: *const [memcard_bytes]u8) void {
        @memcpy(&self.memcard_data[slot], bytes);
        self.memcard_dirty[slot] = false;
        // A freshly installed image is a card the software has not read the
        // directory of, whatever it read before.
        self.memcard_flag[slot] |= memcard_flag_fresh;
    }

    pub fn isMemoryCardDirty(self: *Self, slot: usize) bool {
        return self.memcard_dirty[slot];
    }

    pub fn clearMemoryCardDirty(self: *Self, slot: usize) void {
        self.memcard_dirty[slot] = false;
    }
```

- [ ] **Step 4: Follow the change in the golden state hash**

`ps1-golden/src/state_hash.zig` is written by hand on purpose — reflection would make the check follow a refactor instead of policing it. Replace the memory-card lines of `hashSio` (:462-467) with:

```zig
    s.int(io.port);
    for (0..ps1.sio.Sio.memcard_slots) |i| {
        s.bytes(&io.memcard_data[i]);
        s.bytes(&io.memcard_staging[i]);
        s.int(io.memcard_address[i]);
        s.int(io.memcard_checksum[i]);
        s.int(io.memcard_step[i]);
        s.flag(io.memcard_is_write[i]);
        s.flag(io.memcard_dirty[i]);
        s.int(io.memcard_flag[i]);
        s.int(io.memcard_status[i]);
    }
```

Check how the file already refers to the core (`const Bus = ...` at the top) and match it; if `ps1` is not in scope, hardcode `2` with a comment naming `Sio.memcard_slots`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `zig fmt ps1-core/src/sio.zig ps1-core/tests/sio_test.zig ps1-golden/src/state_hash.zig && zig build test`

Expected: all 15 binaries pass. Also run `zig build -Doptimize=ReleaseFast` to confirm `ps1-golden`, `ps1-trace`, `ps1-debug` and the wasm build all still compile against the new accessor signatures.

- [ ] **Step 6: Document both rules in CLAUDE.md**

In § Memory / interrupts / timers / SIO, replace the bullet reading "Memory card **read/write commands (`0x81`) are emulated against an in-memory 128 KB image**…" with:

```markdown
- **The memory card speaks the real protocol as of 2026-08-31, and did not
  before.** A packet ADDRESSES a peripheral with its first byte — `0x01` the
  controller, `0x81` the card — and the card's command byte is `'R'`/`'W'`,
  answered with FLAG (bit 3 "fresh"/directory-unread, bit 4 always set, bit 2
  the error latch cleared by that read). The old code left `.Idle` only for
  `0x01` and then took `0x81`/`0x82` as read/write, so **the card was
  unreachable by real software** and its image had never been written by
  anything but a unit test. One deliberate divergence from Avocado: a write's
  128 bytes are STAGED and copied into the image only once the checksum
  verifies, because the image is now persisted and a sector reported `'N'`
  must not reach the file.
- **JOY_CTRL bit 13 selects the PORT, and it is latched on the byte that opens
  a packet.** Not decoded at all until 2026-08-31, so both slots were answered
  by one card and one pad — which with persistence would make the BIOS card
  manager's copy function copy a card onto itself. Sampling per byte instead
  would let a mid-transfer JOY_CTRL write splice one card's block into the
  other's. **Port 2 has no pad**: `0x42` there falls through to `.Idle`, the
  existing "nothing responded" path, and the BIOS reports no controller, as an
  empty socket does. Cards are per-slot; `getMemoryCardData`/`setMemoryCardData`/
  `isMemoryCardDirty`/`clearMemoryCardDirty` all take a slot index.
```

- [ ] **Step 7: Commit**

```bash
git add ps1-core/src/sio.zig ps1-core/tests/sio_test.zig ps1-golden/src/state_hash.zig CLAUDE.md
git commit -m "$(cat <<'MSG'
feat(sio): decode the port select and give each slot its own card

JOY_CTRL bit 13 was never read, so both slots were answered by the same 128 KB
image and the same pad. Persisting the image makes that destructive rather than
merely unused: the BIOS card manager shows one card in both panes, and its copy
function copies a card onto itself.

The port is latched on the byte that opens a packet, because the select line is
stable for a whole packet on hardware and a per-byte read would let a mid-
transfer JOY_CTRL write splice one card's block into the other's. Port 2 now
has no pad in it, which is a behaviour change the next commit recaptures.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

## Task 4: Recapture the trace goldens

**Files:**
- Modify: `ps1-core/tests/goldens/trace/*.txt`

This is the one circumstance under which the goldens are rewritten: an intentional behaviour change has landed. It gets its own commit so the diff is reviewable as exactly that.

- [ ] **Step 1: See the damage**

Run: `zig build trace-golden -- verify -Doptimize=ReleaseFast`

Expected: FAIL on some or all of the ten workloads. The regions that legitimately move are `sio` (the card fields changed shape and port 2 lost its pad) and anything downstream of the BIOS pad routine's timing — plausibly `cpu`, `ram`, `interrupt`, `timer`. Write down which workloads and regions moved.

Regions that must NOT move: `vram`, `gpu`, `mdec`, `spu`, `cdrom`, `dma`. If one of those moved, stop and investigate — nothing in Tasks 2 and 3 touches them, and a moved `gpu` or `cdrom` hash means something unintended happened.

- [ ] **Step 2: Recapture**

Run: `zig build trace-golden -- capture -Doptimize=ReleaseFast`

- [ ] **Step 3: Verify the recapture is clean**

Run: `zig build trace-golden -- verify -Doptimize=ReleaseFast`

Expected: OK for all ten workloads.

- [ ] **Step 4: Commit**

```bash
git add ps1-core/tests/goldens/trace
git commit -m "$(cat <<'MSG'
test(golden): recapture for the SIO port select

Port 2 no longer reports a phantom controller, so what the BIOS sees during
KERNEL SETUP changed, and the card fields changed shape. Moved: <fill in the
regions and workloads recorded in Step 1>. Nothing in gpu, vram, mdec, spu,
cdrom or dma moved, which is the check that this is the intended change and
only the intended change.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

Replace the `<fill in…>` with the real list before committing. A recapture commit whose message does not say what moved is the one thing this repo's golden policy forbids.

---

## Task 5: The C ABI

**Files:**
- Modify: `ps1-capi/include/ps1.h` (error-code block at :29-36, declarations near :214)
- Modify: `ps1-capi/src/root.zig` (error codes at :19-24, `Handle` at :32-46, `buildMachine` at :48-57, `ps1_reset` at :81-89)
- Test: `ps1-capi/src/capi_test.zig` (append)

**Interfaces:**
- Consumes: `Sio.memcard_slots`, `Sio.memcard_bytes`, and the four slot-taking accessors from Task 3.
- Produces:
  - `int32_t ps1_load_memcard(Ps1*, int32_t slot, const uint8_t* bytes, size_t len)`
  - `int32_t ps1_take_memcard(Ps1*, int32_t slot, uint8_t* dst)` — returns 1 if it copied, 0 if clean, negative on a bad slot.
  - `PS1_ERR_BAD_MEMCARD_SIZE == -6`, `PS1_ERR_BAD_SLOT == -7`, `PS1_MEMCARD_BYTES == 131072`, `PS1_MEMCARD_SLOTS == 2`.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-capi/src/capi_test.zig`:

```zig
const memcard_bytes = ps1_core.sio.Sio.memcard_bytes;

test "load_memcard rejects a wrong length and an out-of-range slot" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const short = [_]u8{0} ** 16;
    try std.testing.expectEqual(@as(i32, -6), capi.ps1_load_memcard(h, 0, &short, short.len));

    const image = try std.testing.allocator.alloc(u8, memcard_bytes);
    defer std.testing.allocator.free(image);
    @memset(image, 0x42);

    try std.testing.expectEqual(@as(i32, -7), capi.ps1_load_memcard(h, 2, image.ptr, image.len));
    try std.testing.expectEqual(@as(i32, -7), capi.ps1_load_memcard(h, -1, image.ptr, image.len));
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_memcard(h, 1, image.ptr, image.len));
    try std.testing.expectEqual(@as(u8, 0x42), h.cpu.bus.sio.getMemoryCardData(1)[0]);
    try std.testing.expectEqual(@as(u8, 0x00), h.cpu.bus.sio.getMemoryCardData(0)[0]);
}

test "take_memcard is a drain: 1 once, 0 after" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const dst = try std.testing.allocator.alloc(u8, memcard_bytes);
    defer std.testing.allocator.free(dst);
    @memset(dst, 0xEE);

    // A card nobody has written is clean, and a clean take must not touch dst.
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_take_memcard(h, 0, dst.ptr));
    try std.testing.expectEqual(@as(u8, 0xEE), dst[0]);

    // Dirty it the way the machine does.
    h.cpu.bus.sio.getMemoryCardData(0)[0] = 0x99;
    h.cpu.bus.sio.memcard_dirty[0] = true;

    try std.testing.expectEqual(@as(i32, 1), capi.ps1_take_memcard(h, 0, dst.ptr));
    try std.testing.expectEqual(@as(u8, 0x99), dst[0]);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_take_memcard(h, 0, dst.ptr));
    try std.testing.expectEqual(@as(i32, -7), capi.ps1_take_memcard(h, 5, dst.ptr));
}

test "reset keeps the card, including writes the frontend never took" {
    // A front-panel reset does not wipe a memory card. Bus.init memsets the
    // struct, so the images have to be snapshotted and reinstalled — and
    // snapshotted at reset rather than at the last take, or a save made
    // between the two would be lost.
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const image = try std.testing.allocator.alloc(u8, memcard_bytes);
    defer std.testing.allocator.free(image);
    @memset(image, 0x11);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_memcard(h, 0, image.ptr, image.len));

    h.cpu.bus.sio.getMemoryCardData(0)[64] = 0x77; // an untaken write

    capi.ps1_reset(h);

    try std.testing.expectEqual(@as(u8, 0x11), h.cpu.bus.sio.getMemoryCardData(0)[0]);
    try std.testing.expectEqual(@as(u8, 0x77), h.cpu.bus.sio.getMemoryCardData(0)[64]);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`

Expected: compile failure — `ps1_load_memcard` and `ps1_take_memcard` do not exist.

- [ ] **Step 3: Implement the exports**

In `ps1-capi/src/root.zig`, add near the other error codes:

```zig
pub const PS1_ERR_BAD_MEMCARD_SIZE: i32 = -6;
pub const PS1_ERR_BAD_SLOT: i32 = -7;

const Sio = ps1.sio.Sio;
```

Add to `Handle`:

```zig
    /// Retained for the same reason `bios` is: `Bus.init` memsets the struct,
    /// and a front-panel reset does not wipe a memory card.
    memcard: [Sio.memcard_slots][Sio.memcard_bytes]u8 =
        .{[_]u8{0} ** Sio.memcard_bytes} ** Sio.memcard_slots,
```

If that repeated-array initializer does not compile, spell it out as
`.{ [_]u8{0} ** Sio.memcard_bytes, [_]u8{0} ** Sio.memcard_bytes }`.

In `buildMachine`, after the BIOS copy:

```zig
    for (0..Sio.memcard_slots) |i| h.bus.sio.setMemoryCardData(i, &h.memcard[i]);
```

Unconditional, with no `loaded` flag: a handle that has never been given a card holds zeros, which is exactly what `Bus.init` produces anyway.

In `ps1_reset`, before `h.bus.deinit`:

```zig
    // Snapshot the LIVE images, not the ones last loaded: a save the frontend
    // has not taken yet is still the player's save.
    for (0..Sio.memcard_slots) |i| {
        @memcpy(h.memcard[i][0..], h.bus.sio.getMemoryCardData(i));
    }
```

Then the two exports, next to `ps1_set_buttons`:

```zig
/// Installs a memory card image. The bytes are COPIED — 128 KB is small enough
/// that a second lifetime obligation on the caller buys nothing, and the copy
/// is what lets `ps1_reset` put the card back afterwards.
pub export fn ps1_load_memcard(h: *Handle, slot: i32, bytes: [*]const u8, len: usize) i32 {
    if (slot < 0 or slot >= Sio.memcard_slots) return PS1_ERR_BAD_SLOT;
    if (len != Sio.memcard_bytes) return PS1_ERR_BAD_MEMCARD_SIZE;
    const i: usize = @intCast(slot);
    @memcpy(h.memcard[i][0..], bytes[0..Sio.memcard_bytes]);
    h.bus.sio.setMemoryCardData(i, &h.memcard[i]);
    return PS1_OK;
}

/// Takes the card image if the game has written it since the last call.
///
/// Returns 1 having copied PS1_MEMCARD_BYTES into `dst` and cleared the dirty
/// flag, or 0 having touched nothing. This is a DRAIN, and it is one call
/// rather than a dirty query followed by a copy so that a block committed
/// between the two cannot be reported and then dropped.
pub export fn ps1_take_memcard(h: *Handle, slot: i32, dst: [*]u8) i32 {
    if (slot < 0 or slot >= Sio.memcard_slots) return PS1_ERR_BAD_SLOT;
    const i: usize = @intCast(slot);
    if (!h.bus.sio.isMemoryCardDirty(i)) return 0;
    @memcpy(dst[0..Sio.memcard_bytes], h.bus.sio.getMemoryCardData(i));
    h.bus.sio.clearMemoryCardDirty(i);
    return 1;
}
```

- [ ] **Step 4: Declare them in the header**

In `ps1-capi/include/ps1.h`, extend the error block:

```c
#define PS1_ERR_BAD_SBI        (-5)
#define PS1_ERR_BAD_MEMCARD_SIZE (-6)
#define PS1_ERR_BAD_SLOT       (-7)
```

And add, after `ps1_set_pgxp`:

```c
/* Memory cards. Two slots, as a console has, selected by JOY_CTRL bit 13 from
 * the game's side. One shared pair of images for the whole library is the
 * intended frontend policy: a multi-disc game then finds its own save on disc
 * 2 because it is the same card.
 *
 * ps1_load_memcard COPIES the bytes, unlike the disc .bin and like the .sbi
 * sidecar. len must be exactly PS1_MEMCARD_BYTES.
 *
 * ps1_take_memcard is a DRAIN: it returns 1 having written PS1_MEMCARD_BYTES
 * to dst and cleared the dirty flag, or 0 having left dst untouched. Poll it
 * per frame; the copy is paid only on a frame where the game committed a
 * block, which is rare. Both return PS1_ERR_BAD_SLOT for a slot outside
 * 0..PS1_MEMCARD_SLOTS-1.
 *
 * A card survives ps1_reset, as it does on hardware. */
#define PS1_MEMCARD_BYTES 131072
#define PS1_MEMCARD_SLOTS 2

int32_t ps1_load_memcard(Ps1*, int32_t slot, const uint8_t* bytes, size_t len);
int32_t ps1_take_memcard(Ps1*, int32_t slot, uint8_t* dst);
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `zig fmt ps1-capi/src/root.zig ps1-capi/src/capi_test.zig && zig build test`

Expected: all 15 binaries pass, including the three new `capi_test` cases.

- [ ] **Step 6: Commit**

```bash
git add ps1-capi
git commit -m "$(cat <<'MSG'
feat(capi): expose the memory cards

ps1_load_memcard copies an image in; ps1_take_memcard drains one out, returning
1 only when the game has written it, so the 128 KB copy is paid on the rare
frame a save actually lands. One call rather than a dirty query plus a copy: a
block committed between the two would otherwise be reported and then dropped.

ps1_reset now snapshots the live images before rebuilding Bus. A front-panel
reset does not wipe a card on hardware, and snapshotting at reset rather than
at the last take means a save the frontend has not collected yet survives too.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

## Task 6: `MemoryCardStore`

**Files:**
- Create: `ps1-macos/Sources/PS1/MemoryCardStore.swift`
- Test: `ps1-macos/Tests/PS1Tests/MemoryCardStoreTests.swift`

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces: `final class MemoryCardStore` with `static let bytes = 131072`, `static let slots = 2`, `init(directory: URL? = nil)`, `func load(slot: Int) -> Data?`, `func write(_ data: Data, slot: Int)`.

- [ ] **Step 1: Write the failing tests**

Create `ps1-macos/Tests/PS1Tests/MemoryCardStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import PS1

private func makeStoreDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("memcards-\(UUID().uuidString)")
}

private func makeImage(_ fill: UInt8) -> Data {
    Data(repeating: fill, count: MemoryCardStore.bytes)
}

@Test func aCardThatWasNeverWrittenLoadsAsNil() {
    let store = MemoryCardStore(directory: makeStoreDirectory())
    #expect(store.load(slot: 0) == nil)
    #expect(store.load(slot: 1) == nil)
}

@Test func aCardReadsBackByteForByte() {
    let store = MemoryCardStore(directory: makeStoreDirectory())
    store.write(makeImage(0x5A), slot: 0)

    let loaded = store.load(slot: 0)
    #expect(loaded == makeImage(0x5A))
}

@Test func theTwoSlotsAreSeparateFiles() {
    let store = MemoryCardStore(directory: makeStoreDirectory())
    store.write(makeImage(0x11), slot: 0)
    store.write(makeImage(0x22), slot: 1)

    #expect(store.load(slot: 0) == makeImage(0x11))
    #expect(store.load(slot: 1) == makeImage(0x22))
}

@Test func aFileOfTheWrongSizeIsRefusedRatherThanPadded() throws {
    // A short file is far more likely a botched copy than a card worth
    // salvaging, and refusing it presents as "unformatted" — which the BIOS
    // offers to fix — instead of as corrupt save data.
    let directory = makeStoreDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(repeating: 0xFF, count: 4096)
        .write(to: directory.appendingPathComponent("card1.mcd"))

    let store = MemoryCardStore(directory: directory)
    #expect(store.load(slot: 0) == nil)
}

@Test func writingRefusesAnImageOfTheWrongSize() {
    let store = MemoryCardStore(directory: makeStoreDirectory())
    store.write(Data(repeating: 0x01, count: 100), slot: 0)
    #expect(store.load(slot: 0) == nil)
}

@Test func aSecondWriteReplacesTheFirst() {
    let store = MemoryCardStore(directory: makeStoreDirectory())
    store.write(makeImage(0x01), slot: 0)
    store.write(makeImage(0x02), slot: 0)
    #expect(store.load(slot: 0) == makeImage(0x02))
}

@Test func theFileNamesAreTheOnesOtherEmulatorsRead() {
    // Raw 131072-byte .mcd, one file per slot, so a save can be carried in
    // from or out to DuckStation and the PCSX line.
    let directory = makeStoreDirectory()
    let store = MemoryCardStore(directory: directory)
    store.write(makeImage(0x33), slot: 1)

    let url = directory.appendingPathComponent("card2.mcd")
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(try! Data(contentsOf: url).count == MemoryCardStore.bytes)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build capi-lib && zig build metallib && ps1-macos/test.sh`

Expected: the build fails — `cannot find 'MemoryCardStore' in scope`.

- [ ] **Step 3: Implement the store**

Create `ps1-macos/Sources/PS1/MemoryCardStore.swift`:

```swift
import Foundation

/// The two memory cards, on disk.
///
/// ONE shared pair for the whole library, like a console with two cards in it,
/// rather than a card per game. A multi-disc game then finds its own save on
/// disc 2 because it is the same card — which is also what happens on
/// hardware — and a sequel finds its predecessor's for the same reason. The
/// cost is that 15 blocks is a hard cap, managed through the BIOS card
/// manager, which is why the second slot exists. DuckStation defaults to
/// per-game cards instead: unlimited capacity, neither of those behaviours.
///
/// The format is a raw 131072-byte image per slot, the `.mcd` layout
/// DuckStation and the PCSX line read, so a save can be carried in or out.
final class MemoryCardStore {
    static let bytes = 128 * 1024
    static let slots = 2

    private let directory: URL

    /// Every access, read and write, goes through one queue. The write is
    /// debounced onto the emulator thread while the read happens on the main
    /// actor as a game is installed, and a card is the one piece of state
    /// those two share.
    private let queue = DispatchQueue(label: "PS1.MemoryCardStore")

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PS1/MemoryCards", isDirectory: true)
    }

    /// `nil` for a card that has never been written, and for a file that is
    /// not exactly one card long — see the test for why it is not padded.
    func load(slot: Int) -> Data? {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL(slot: slot)),
                  data.count == Self.bytes
            else { return nil }
            return data
        }
    }

    /// Synchronous on purpose. Both callers want it that way: the debounce
    /// runs on the emulator thread between frames, where a 128 KB write is
    /// nothing beside the frame it sits next to, and the flush on eject and
    /// quit must not outlive the process that started it.
    func write(_ data: Data, slot: Int) {
        guard data.count == Self.bytes else { return }
        queue.sync {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try? data.write(to: fileURL(slot: slot), options: .atomic)
        }
    }

    private func fileURL(slot: Int) -> URL {
        directory.appendingPathComponent("card\(slot + 1).mcd")
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ps1-macos/test.sh`

Expected: the suite passes, now 288 tests.

- [ ] **Step 5: Commit**

```bash
git add ps1-macos/Sources/PS1/MemoryCardStore.swift ps1-macos/Tests/PS1Tests/MemoryCardStoreTests.swift
git commit -m "$(cat <<'MSG'
feat(macos): the two memory cards on disk

One shared pair for the whole library, raw .mcd, in Application Support. A
file that is not exactly one card long is refused rather than padded: a short
file is a botched copy, and refusing it reads as "unformatted" — which the
BIOS offers to fix — rather than as corrupt save data. All access is on one
serial queue, because the debounced write runs on the emulator thread while
the read happens on the main actor as a game is installed.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

## Task 7: `MemoryCardFlushPolicy`

**Files:**
- Create: `ps1-macos/Sources/PS1/MemoryCardFlushPolicy.swift`
- Test: `ps1-macos/Tests/PS1Tests/MemoryCardFlushPolicyTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct MemoryCardFlushPolicy` with `static let settleDelay = 1.0`, `mutating func shouldWrite(dirty: Bool, now: Double) -> Bool`, `var hasPendingWrite: Bool`.

- [ ] **Step 1: Write the failing tests**

Create `ps1-macos/Tests/PS1Tests/MemoryCardFlushPolicyTests.swift`:

```swift
import Testing
@testable import PS1

@Test func aCleanCardIsNeverWritten() {
    var policy = MemoryCardFlushPolicy()
    #expect(policy.shouldWrite(dirty: false, now: 0) == false)
    #expect(policy.shouldWrite(dirty: false, now: 100) == false)
    #expect(policy.hasPendingWrite == false)
}

@Test func aDirtyCardIsNotWrittenImmediately() {
    // A game committing a save writes ten or so blocks in a burst. Writing on
    // the first would put ten 128 KB files through the disk for one save.
    var policy = MemoryCardFlushPolicy()
    #expect(policy.shouldWrite(dirty: true, now: 0) == false)
    #expect(policy.hasPendingWrite)
}

@Test func aDirtyCardIsWrittenOnceItSettles() {
    var policy = MemoryCardFlushPolicy()
    _ = policy.shouldWrite(dirty: true, now: 0)
    #expect(policy.shouldWrite(dirty: false, now: 0.5) == false)
    #expect(policy.shouldWrite(dirty: false, now: 1.0) == true)
}

@Test func theSettleWindowRestartsOnEachNewWrite() {
    // The burst is the thing being waited out, so the clock restarts on every
    // block: one write at the end of the burst, not one part-way through it.
    var policy = MemoryCardFlushPolicy()
    _ = policy.shouldWrite(dirty: true, now: 0)
    #expect(policy.shouldWrite(dirty: true, now: 0.9) == false)
    #expect(policy.shouldWrite(dirty: false, now: 1.5) == false)
    #expect(policy.shouldWrite(dirty: false, now: 1.9) == true)
}

@Test func aWriteIsNotRepeatedWhileTheCardStaysClean() {
    var policy = MemoryCardFlushPolicy()
    _ = policy.shouldWrite(dirty: true, now: 0)
    #expect(policy.shouldWrite(dirty: false, now: 1.0) == true)
    #expect(policy.shouldWrite(dirty: false, now: 2.0) == false)
    #expect(policy.shouldWrite(dirty: false, now: 60.0) == false)
    #expect(policy.hasPendingWrite == false)
}

@Test func aNewWriteAfterAFlushStartsAFreshWindow() {
    var policy = MemoryCardFlushPolicy()
    _ = policy.shouldWrite(dirty: true, now: 0)
    #expect(policy.shouldWrite(dirty: false, now: 1.0) == true)
    #expect(policy.shouldWrite(dirty: true, now: 5.0) == false)
    #expect(policy.shouldWrite(dirty: false, now: 6.0) == true)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ps1-macos/test.sh`

Expected: build failure — `cannot find 'MemoryCardFlushPolicy' in scope`.

- [ ] **Step 3: Implement the policy**

Create `ps1-macos/Sources/PS1/MemoryCardFlushPolicy.swift`:

```swift
import Foundation

/// When a dirtied memory card should be written to disk.
///
/// A value type with no clock and no I/O of its own, like `FpsCounter` and
/// `InternalResolution`: the rule is then reachable from a test with synthetic
/// timestamps, which is the only way to check a one-second debounce without
/// spending a second per case.
///
/// The window restarts on every new write rather than counting from the first,
/// because what is being waited out is a BURST — a game committing a save
/// writes ten or so 128-byte blocks back to back, and each one raises the
/// dirty flag.
struct MemoryCardFlushPolicy {
    /// Long enough to swallow a save's burst of blocks, short enough that a
    /// force-quit a moment later still finds the save on disk.
    static let settleDelay = 1.0

    private var pendingSince: Double?

    var hasPendingWrite: Bool { pendingSince != nil }

    /// `dirty` is whether the core reported new bytes on this tick.
    mutating func shouldWrite(dirty: Bool, now: Double) -> Bool {
        if dirty { pendingSince = now }
        guard let since = pendingSince, now - since >= Self.settleDelay else { return false }
        pendingSince = nil
        return true
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ps1-macos/test.sh`

Expected: pass, now 294 tests.

- [ ] **Step 5: Commit**

```bash
git add ps1-macos/Sources/PS1/MemoryCardFlushPolicy.swift ps1-macos/Tests/PS1Tests/MemoryCardFlushPolicyTests.swift
git commit -m "$(cat <<'MSG'
feat(macos): the memory-card write debounce, as a value

A save is a burst of ten or so blocks, so the settle window restarts on each
one and the card is written once at the end. A value type with no clock of its
own, for the same reason FpsCounter is one: a one-second rule is only testable
with synthetic timestamps.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

## Task 8: Wire the runner

**Files:**
- Modify: `ps1-macos/Sources/PS1/Ps1Core.swift` (`Ps1Error` at :11-30, methods near :135)
- Modify: `ps1-macos/Sources/PS1/EmulatorRunner.swift` (`init` at :79-92, `stop()` at :162-175, `runLoop()` at :198-215)

**Interfaces:**
- Consumes: `ps1_load_memcard`, `ps1_take_memcard`, `PS1_MEMCARD_BYTES` (Task 5); `MemoryCardStore` (Task 6); `MemoryCardFlushPolicy` (Task 7).
- Produces:
  - `Ps1Core.loadMemcard(_ data: Data, slot: Int) throws`
  - `Ps1Core.takeMemcard(slot: Int, into scratch: inout [UInt8]) -> Data?`
  - `EmulatorRunner.init(core:ring:cards:)` — `cards` defaults to `nil`, so existing test call sites keep compiling.

- [ ] **Step 1: Extend the error mapping and add the wrapper methods**

`Ps1Core.swift` is the only file in the app that touches the C ABI; keep it that way. Add to `Ps1Error`:

```swift
    case badMemcardSize
    case badSlot
```

and to `from(_:)`, before `default`:

```swift
        case -6: return .badMemcardSize
        case -7: return .badSlot
```

Add the two methods next to `setPgxp`:

```swift
    /// Installs a card image. The core COPIES the bytes, so nothing is
    /// retained here — unlike the disc `.bin`, which it borrows.
    func loadMemcard(_ data: Data, slot: Int) throws {
        let code = data.withUnsafeBytes { raw in
            ps1_load_memcard(handle, Int32(slot),
                             raw.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
        if let e = Ps1Error.from(code) { throw e }
    }

    /// `nil` when the game has not written the card since the last call.
    ///
    /// `scratch` is the caller's buffer, reused across calls: this is polled
    /// once per loop iteration, and a fresh 128 KB allocation per frame to
    /// hold nothing would be absurd.
    func takeMemcard(slot: Int, into scratch: inout [UInt8]) -> Data? {
        let took = scratch.withUnsafeMutableBufferPointer { buf in
            ps1_take_memcard(handle, Int32(slot), buf.baseAddress)
        }
        return took == 1 ? Data(scratch) : nil
    }
```

- [ ] **Step 2: Hold the store and the pending images on the runner**

In `EmulatorRunner`, add next to `pendingSwap`:

```swift
    /// The cards, and the newest image taken from each. `nil` in tests that
    /// build a runner without a store — there is then nothing to write to and
    /// the card is simply never persisted.
    private let cards: MemoryCardStore?
    private var pendingCards: [Int: Data] = [:]
    private var cardFlush = MemoryCardFlushPolicy()
    private var cardScratch = [UInt8](repeating: 0, count: MemoryCardStore.bytes)
```

Change `init` to take the store:

```swift
    init(core: Ps1Core, ring: AudioRing, cards: MemoryCardStore? = nil) {
        self.core = core
        self.ring = ring
        self.cards = cards
```

- [ ] **Step 3: Service the cards at the top of the loop**

Add the call as the first statement inside `while running.load(...)` in `runLoop`, above the paused check:

```swift
        while running.load(ordering: .acquiring) {
            // Above the paused and ring-full early-outs on purpose: a player
            // who saves and immediately hits Pause would otherwise leave the
            // pending write parked until they resumed.
            serviceMemoryCards()

            if paused.load(ordering: .acquiring) {
```

and the methods themselves, below `takePendingSwap()`:

```swift
    /// Takes whatever the game has written and writes it out once the burst
    /// settles. Called from `runLoop` only — this thread owns the core.
    ///
    /// Taking BEFORE the frame rather than after is deliberate and costs
    /// nothing: a block committed in frame N is collected at the top of frame
    /// N+1, and this way the one call site also runs while the emulator is
    /// paused or waiting on the audio ring.
    private func serviceMemoryCards() {
        guard let cards else { return }

        var dirty = false
        for slot in 0..<MemoryCardStore.slots {
            if let image = core.takeMemcard(slot: slot, into: &cardScratch) {
                pendingCards[slot] = image
                dirty = true
            }
        }

        guard cardFlush.shouldWrite(dirty: dirty,
                                    now: Date().timeIntervalSinceReferenceDate)
        else { return }

        for (slot, image) in pendingCards { cards.write(image, slot: slot) }
        pendingCards.removeAll()
    }

    /// The unconditional flush, on eject and on quit. Called from `stop()`
    /// AFTER the emulator thread has been joined, so this is the only thread
    /// touching the core.
    private func flushMemoryCards() {
        guard let cards else { return }

        for slot in 0..<MemoryCardStore.slots {
            if let image = core.takeMemcard(slot: slot, into: &cardScratch) {
                pendingCards[slot] = image
            }
        }
        for (slot, image) in pendingCards { cards.write(image, slot: slot) }
        pendingCards.removeAll()
    }
```

- [ ] **Step 4: Flush on stop**

At the end of `stop()`, after `thread = nil`:

```swift
        thread = nil

        // After the join, never before: the emulator thread owns the core, and
        // a take from here while it is mid-frame would race the state machine
        // that raises the dirty flag.
        flushMemoryCards()
```

- [ ] **Step 5: Build and run the whole suite**

Run: `zig build capi-lib && zig build metallib && ps1-macos/test.sh`

Expected: all 294 tests pass. `stop()` is called by `deinit` in several existing tests; with `cards == nil` the flush is a no-op, so nothing there changes.

There is deliberately no unit test for `serviceMemoryCards` itself: dirtying a card over the ABI means driving the SIO state machine, which the C surface cannot do — that path is covered by `capi_test.zig` in Zig and by the seven protocol tests in `sio_test.zig`. The two pieces of logic that *are* testable in Swift, the store and the debounce, have their own suites.

- [ ] **Step 6: Commit**

```bash
git add ps1-macos/Sources/PS1/Ps1Core.swift ps1-macos/Sources/PS1/EmulatorRunner.swift
git commit -m "$(cat <<'MSG'
feat(macos): persist the memory cards from the emulator thread

The runner polls ps1_take_memcard once per loop iteration and writes the image
out once the debounce settles. The poll sits ABOVE the paused and ring-full
early-outs, so a save followed straight by Pause is not parked until the player
resumes, and the final flush runs in stop() AFTER the thread is joined, so
nothing takes from the core while it is mid-frame.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

## Task 9: Wire the app, and correct the docs

**Files:**
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift` (properties at :44-49, `init` at :66-70, `load(disc:)` at :299-350)
- Modify: `CLAUDE.md` (§ The macOS app, § CDROM — state of play)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing further.

- [ ] **Step 1: Hold the store**

Next to `let covers = CoverStore()`:

```swift
    /// One shared pair of cards for the whole library. Outlives every disc,
    /// like `covers` and unlike `runner`.
    let cards = MemoryCardStore()
```

- [ ] **Step 2: Pass it to the runner and install the images after teardown**

In `load(disc:)`, change the runner construction:

```swift
            let runner = EmulatorRunner(core: core, ring: ring, cards: cards)
```

and add the install immediately after `installedReplacement = true`, before `audio.setGain(...)`:

```swift
            // AFTER teardownRunningMachine(), never before. Everything else
            // here is built ahead of the teardown so that a disc which fails
            // to load leaves the running game alone — but the card cannot
            // follow that order: teardown is what FLUSHES the outgoing game's
            // card, and reading the file before it would load stale bytes and
            // then write them back over the save it was about to make.
            //
            // A failure is non-fatal: a missing or unreadable card file is a
            // blank card, which the BIOS reports as unformatted and offers to
            // format, exactly as a new card does on hardware.
            for slot in 0..<MemoryCardStore.slots {
                guard let image = cards.load(slot: slot) else { continue }
                try? core.loadMemcard(image, slot: slot)
            }
```

- [ ] **Step 3: Flush on quit**

In `init()`, after `observeKeyboard()`:

```swift
        // ⌘Q does not go through eject(), so the pending write would be lost
        // with the process. Tearing the machine down is what flushes it, and
        // it is synchronous — a Task here would not be scheduled before exit.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.teardownRunningMachine() }
        }
```

`teardownRunningMachine` is `private`; the closure is inside the class, so that is fine. `NSApplication` needs `import AppKit` — check the top of the file; `import SwiftUI` re-exports it on macOS, so no new import should be necessary. If the compiler disagrees, add `import AppKit`.

- [ ] **Step 4: Build and run the suite**

Run: `ps1-macos/test.sh`

Expected: 294 tests pass. `EmulatorViewModelStageTests` constructs the model, so the observer registration runs there — it must not crash on a model with no runner (`self?.runner` is nil, `teardownRunningMachine` handles that throughout).

- [ ] **Step 5: Correct CLAUDE.md**

In § CDROM — state of play, under "Known remaining gaps", **delete** the whole "Multi-disc saves still do not persist" bullet.

In § The macOS app, after the `.sbi` sidecar bullet, add:

```markdown
- **The memory cards are ONE shared pair for the whole library, and the load
  must happen AFTER the teardown.** `MemoryCardStore` keeps
  `~/Library/Application Support/PS1/MemoryCards/card{1,2}.mcd` — raw 131072-byte
  images, the `.mcd` layout DuckStation and the PCSX line read. Shared rather
  than per-game so that a multi-disc game finds its own save on disc 2 and a
  sequel finds its predecessor's, both of which are what hardware does; the
  cost is the 15-block cap, managed through the BIOS card manager, which is
  what the second slot is for. `load(disc:)` builds every other part of the new
  machine BEFORE tearing the old one down, so that a disc which fails to load
  leaves the running game alone — the card is the one exception, because the
  teardown is what flushes the outgoing card and a read before it would load
  stale bytes and then write them back over the save. `EmulatorRunner` polls
  `ps1_take_memcard` at the TOP of its loop, above the paused and ring-full
  early-outs, so a save followed immediately by ⌘P is not parked; the write
  itself is debounced a second by `MemoryCardFlushPolicy` because a save is a
  burst of ten or so blocks. The unconditional flush is in `stop()`, after the
  emulator thread is joined, and ⌘Q reaches it through a
  `willTerminateNotification` observer — `eject()` is not on that path.
```

- [ ] **Step 6: Commit**

```bash
git add ps1-macos/Sources/PS1/EmulatorViewModel.swift CLAUDE.md
git commit -m "$(cat <<'MSG'
feat(macos): load and flush the memory cards around a game

The card install is the one part of load(disc:) that happens AFTER the
teardown: the teardown is what flushes the outgoing card, and reading the file
before it would load stale bytes and then write them back over the save. ⌘Q
reaches the flush through willTerminateNotification, since it does not go
through eject().

Closes the "multi-disc saves still do not persist" gap.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

## Task 10: Verify it against a real game

The whole point, and nothing above proves it. Every test so far drives the state machine synthetically; none of them boots a BIOS and asks it to format a card.

- [ ] **Step 1: Build and launch**

Run: `zig build macos && open zig-out/PS1.app`

- [ ] **Step 2: Reach the BIOS card manager**

Launch with no disc (or eject to the library and use `File ▸ Open Disc…` on nothing). The BIOS shell offers **MEMORY CARD**. Open it.

Expected: slot 1 reports an **unformatted** card rather than "no card". That single screen is what proves Task 2 — before it, the BIOS reported no card in either slot.

- [ ] **Step 3: Format the card, and confirm the file appears**

Format slot 1 through the BIOS. Then:

Run: `ls -l ~/Library/Application\ Support/PS1/MemoryCards/`

Expected: `card1.mcd`, exactly 131072 bytes, mtime within the last few seconds.

- [ ] **Step 4: Confirm the two slots are independent**

Back in the card manager, look at slot 2. Expected: also unformatted, and it stays unformatted after slot 1 is formatted. Before Task 3 both panes showed the same card.

- [ ] **Step 5: Save from a real game, quit, and come back**

Open a game from the library that saves early — Croc saves after the first level, Silent Hill at the first save point. Save. Then ⌘Q, relaunch, load the same disc, and load the save.

Expected: the save is there. Also confirm `card1.mcd`'s mtime moved at the moment of the in-game save (the debounce), not only at quit.

- [ ] **Step 6: Confirm a reset does not wipe it**

With the game running, `Machine ▸ Reset` (⌘R), then re-enter the load menu.

Expected: the save is still listed. That is `ps1_reset`'s snapshot doing its job.

- [ ] **Step 7: Record the result**

Nothing to commit unless something failed. If a step fails, that is a real bug found by the only test that could find it — debug it before declaring the feature done, and add a unit test at the layer that was wrong.

---

## Self-Review

**Spec coverage.** § 1 port latch → Task 3 Steps 1/3. § 2 per-slot state and padless port 1 → Task 3. § 3 shared card → Task 6 (the store's shape and doc comment). § 4 ABI, copy-in, drain, reset retention → Task 5. § 5 store, policy, runner wiring, top-of-loop placement, flush after join → Tasks 6-8. § 6 install after teardown, quit observer → Task 9. § Testing → the test steps of Tasks 2, 3, 5, 6, 7. § Golden recapture → Task 4. § Documentation → Tasks 3 and 9.

**Added beyond the spec:** Task 2, the protocol rewrite, and Task 10, the manual verification. The spec assumed a working card because CLAUDE.md said the commands "are emulated"; they are not reachable. Persistence without Task 2 would faithfully persist zeros forever, so it is a prerequisite rather than a scope increase to negotiate — but the spec's § Scope should be read as amended by it.

**Type consistency.** `memcard_bytes`/`memcard_slots` are `pub const`s on `Sio`, used by `state_hash.zig`, `root.zig` and `capi_test.zig`. `MemoryCardStore.bytes`/`.slots` are the Swift mirror and are used by `EmulatorRunner` and `EmulatorViewModel`. `slot` is `usize` in Zig, `i32` across the ABI, `Int` in Swift, converted at each boundary. `getMemoryCardData(slot:)` returns `[]u8` in Zig throughout; `takeMemcard(slot:into:)` returns `Data?` in Swift throughout.
