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

    try expectEqual(ps1_core.sio.Sio.SioState.Idle, bus.sio.ctrl_state);
    try expect(!bus.sio.ack);
}
