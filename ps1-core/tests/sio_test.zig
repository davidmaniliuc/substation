const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const ps1_core = @import("ps1_core");
const Bus = ps1_core.memory.Bus;
const Cpu = ps1_core.cpu.Cpu;

const JOY_DATA = 0x1F801040;
const JOY_STAT = 0x1F801044;
const JOY_CTRL = 0x1F80104A;

/// Runs the machine for `n` instructions so peripherals get ticked. The BIOS
/// region is zeroed in tests, so the CPU just retires nops.
fn stepCpu(cpu: *Cpu, n: usize) void {
    for (0..n) |_| cpu.step();
}

test "JOY port transfer raises IRQ7 (Controller), not IRQ8 (SIO)" {
    // The controller/memcard port at 0x1F801040 raises IRQ7 per PSX-SPX
    // (Avocado: interrupt::CONTROLLER = 7). IRQ8 belongs to the other serial
    // port (SIO1 at 0x1F801050).
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);

    bus.write8(JOY_DATA, 0x01); // select pad
    stepCpu(&cpu, 600); // let /ACK land

    try expectEqual(@as(u32, 1 << 7), bus.interrupts.stat & (1 << 7)); // Controller
    try expectEqual(@as(u32, 0), bus.interrupts.stat & (1 << 8)); // not SIO
}

test "/ACK interrupt arrives after the pad routine's own acknowledge" {
    // Regression: the port used to raise IRQ7 synchronously from the JOY_DATA
    // write. The BIOS pad routine clocks a byte out, waits ~140 instructions,
    // then clears *both* the port's IRQ (JOY_CTRL bit 4) and I_STAT bit 7
    // before polling for /ACK. A synchronous interrupt is therefore destroyed
    // by the routine's own acknowledge, so it polls ~81 times, times out, and
    // reports "no controller attached" — every button press is dropped.
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);

    bus.write8(JOY_DATA, 0x01);

    // The interrupt must NOT be up yet: the routine has not finished its delay.
    try expectEqual(@as(u32, 0), bus.interrupts.stat & (1 << 7));

    stepCpu(&cpu, 140); // BIOS delay(20)
    bus.write16(JOY_CTRL, 0x1013); // Acknowledge — clears the port's request
    bus.interrupts.writeStat(0xFFFFFF7F); // clear I_STAT bit 7

    // Now /ACK must still be coming, and must land inside the routine's window.
    stepCpu(&cpu, 600);
    try expect((bus.interrupts.stat & (1 << 7)) != 0);
}

test "digital pad reports ID 0x41 and a five-byte packet carrying button state" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    // START is bit 3, active-low.
    bus.sio.setButtons(0xFFFF & ~@as(u16, 1 << 3));

    bus.write8(JOY_DATA, 0x01);
    try expectEqual(@as(u8, 0xFF), bus.read8(JOY_DATA));

    bus.write8(JOY_DATA, 0x42); // read controller
    try expectEqual(@as(u8, 0x41), bus.read8(JOY_DATA)); // digital pad ID

    bus.write8(JOY_DATA, 0x00);
    try expectEqual(@as(u8, 0x5A), bus.read8(JOY_DATA));

    bus.write8(JOY_DATA, 0x00);
    try expectEqual(@as(u8, 0xF7), bus.read8(JOY_DATA)); // START pressed

    bus.write8(JOY_DATA, 0x00);
    try expectEqual(@as(u8, 0xFF), bus.read8(JOY_DATA));

    // A digital packet ends here — the pad stops asserting /ACK.
    try expectEqual(@as(u32, 0), bus.read16Raw(JOY_STAT) & 0x80);
}

test "deselecting the port resets the transfer state" {
    // Dropping /JOYn Output (JOY_CTRL bit 1) deselects the peripheral, which
    // resets its transfer state. Without this a routine that stops early — or
    // that alternates between the two slots, as the BIOS pad scan does —
    // re-enters mid-sequence and stays desynchronised forever.
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    bus.write16(JOY_CTRL, 0x1003); // select
    bus.write8(JOY_DATA, 0x01);
    bus.write8(JOY_DATA, 0x42);
    try expectEqual(@as(u8, 0x41), bus.read8(JOY_DATA)); // mid-sequence

    bus.write16(JOY_CTRL, 0x0000); // deselect, abandoning the transfer

    // The next poll must start cleanly from the address byte.
    bus.write16(JOY_CTRL, 0x1003);
    bus.write8(JOY_DATA, 0x01);
    try expectEqual(@as(u8, 0xFF), bus.read8(JOY_DATA));
    bus.write8(JOY_DATA, 0x42);
    try expectEqual(@as(u8, 0x41), bus.read8(JOY_DATA));
}

test "JOY_STAT reports /ACK while the pad expects another byte" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    bus.write8(JOY_DATA, 0x01);
    try expectEqual(@as(u32, 0x80), bus.read16Raw(JOY_STAT) & 0x80);

    // /ACK reads as a one-shot, so a second read sees it low again.
    try expectEqual(@as(u32, 0), bus.read16Raw(JOY_STAT) & 0x80);

    // An unrecognised command means nothing responds — no /ACK at all.
    bus.write8(JOY_DATA, 0x99);
    try expectEqual(@as(u32, 0), bus.read16Raw(JOY_STAT) & 0x80);
}

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
    for (0..128) |i| bus.sio.getMemoryCardData(0)[base + i] = 0xA5;

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

    try expect(!bus.sio.isMemoryCardDirty(0));
    const status = writeBlock(bus, 5, 0x3C, null);

    try expectEqual(@as(u8, 'G'), status);
    try expect(bus.sio.isMemoryCardDirty(0));
    for (0..128) |i| try expectEqual(@as(u8, 0x3C), bus.sio.getMemoryCardData(0)[5 * 128 + i]);
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
    try expect(!bus.sio.isMemoryCardDirty(0));
    for (0..128) |i| try expectEqual(@as(u8, 0x00), bus.sio.getMemoryCardData(0)[7 * 128 + i]);
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
    // Avocado returns FLAG unconditionally at this state, before it looks at
    // whether the byte is a recognized command — 0xFF here was a slip that
    // only an unsupported command's return value could catch.
    const flag = xfer(bus, 'Z');

    try expectEqual(@as(u8, 0x18), flag); // fresh | unknown, on a fresh card
    try expectEqual(ps1_core.sio.Sio.SioState.Idle, bus.sio.ctrl_state);
    try expect(!bus.sio.ack);
}

test "an out-of-range write reports a bad SECTOR, not a bad checksum" {
    // Avocado seeds the write checksum from the address bytes as software
    // sent them, then masks the address. Seeding from the masked value
    // instead makes a correct checksum look wrong, so the drive reports 'N'
    // (retry this block) where hardware reports 0xFF (this block does not
    // exist) — and a retry loop on a request that can never succeed is a
    // hang, not a slow save.
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    const status = writeBlock(bus, 0x0400, 0x5A, null); // one past the last block

    try expectEqual(@as(u8, 0xFF), status);
    try expect(!bus.sio.isMemoryCardDirty(0));
}

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

test "an out-of-range read leaves the error bit clear and still completes with 'G'" {
    // The read counterpart of the out-of-range write test above: Avocado's
    // read path masks a bad address silently and never touches the error
    // latch, so the sequence still ends 'G' and FLAG never reports a fault
    // the read itself never signalled.
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    selectPort(bus, 1);
    const r = readBlock(bus, 0x0400); // one past the last block
    try expectEqual(@as(u8, 'G'), r.end);

    _ = xfer(bus, 0x81);
    try expectEqual(@as(u8, 0x18), xfer(bus, 'R')); // fresh | unknown, no error bit
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

test "a write to a high block lands at the correct byte offset in the image" {
    // Regression: memcard_address is u16 and memcard_sector_bytes coerces to
    // u16, so `memcard_address[p] * memcard_sector_bytes` is u16 arithmetic.
    // 600 * 128 == 76800, which does not fit in a u16 (max 65535) — every
    // test elsewhere in this file uses blocks 0-7, so the multiply never saw
    // an operand this large. Block 600 falls inside save block 8 (blocks
    // 512-1023 are save blocks 8-15), which the BIOS card manager's format
    // routine reaches.
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    const status = writeBlock(bus, 600, 0x99, null);
    try expectEqual(@as(u8, 'G'), status);

    // Land at the correct byte offset — not wrapped, not aliased onto a low
    // block by the overflow.
    for (0..128) |i| try expectEqual(@as(u8, 0x99), bus.sio.getMemoryCardData(0)[600 * 128 + i]);
    // And nothing spilled onto block 0 (600 * 128 mod 65536 == 11264, which
    // is block 88 — still not block 0, so this is a belt-and-braces check
    // that the write went where it was asked, not somewhere the wraparound
    // arithmetic would have landed it).
    for (0..128) |i| try expectEqual(@as(u8, 0x00), bus.sio.getMemoryCardData(0)[i]);

    const r = readBlock(bus, 600);
    for (r.data) |b| try expectEqual(@as(u8, 0x99), b);
    try expectEqual(@as(u8, 'G'), r.end);
}

test "a boundary sweep across 511/512/1023 all land at the right offset" {
    // 511 * 128 == 65408 fits a u16 and never exercised the bug; 512 * 128 ==
    // 65536 is the first block that overflows one; 1023 is the last
    // addressable block on the whole card. Sweeping all three in one test
    // pins the boundary on both sides of the overflow plus the top of the
    // address space.
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    const blocks = [_]u16{ 511, 512, 1023 };
    for (blocks, 0..) |block, i| {
        const fill: u8 = @truncate(0xA0 + i);
        const status = writeBlock(bus, block, fill, null);
        try expectEqual(@as(u8, 'G'), status);

        const base: usize = @as(usize, block) * 128;
        for (0..128) |j| try expectEqual(fill, bus.sio.getMemoryCardData(0)[base + j]);

        const r = readBlock(bus, block);
        for (r.data) |b| try expectEqual(fill, b);
        try expectEqual(@as(u8, 'G'), r.end);
    }
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
