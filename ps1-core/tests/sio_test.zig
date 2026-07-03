const std = @import("std");
const expectEqual = std.testing.expectEqual;

const ps1_core = @import("ps1_core");
const Bus = ps1_core.memory.Bus;

test "JOY port transfer raises IRQ7 (Controller), not IRQ8 (SIO)" {
    // The controller/memcard port at 0x1F801040 raises IRQ7 per PSX-SPX
    // (Avocado: interrupt::CONTROLLER = 7). IRQ8 belongs to the other serial
    // port (SIO1 at 0x1F801050). Routing pad transfers to IRQ8 causes an
    // unacknowledged level-IRQ storm in games that hook IRQ7 (e.g. Croc's
    // pad driver during the Fox FMV).
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    // Kick a controller transfer: select pad (0x01) on JOY_DATA.
    bus.write8(0x1F801040, 0x01);

    const stat = bus.interrupts.stat;
    try expectEqual(@as(u32, 1 << 7), stat & (1 << 7)); // Controller IRQ set
    try expectEqual(@as(u32, 0), stat & (1 << 8)); // SIO IRQ NOT set
}
