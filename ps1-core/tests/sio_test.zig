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
