const std = @import("std");
const expectEqual = std.testing.expectEqual;

const zzssxx = @import("zzssxx");
const Cpu = zzssxx.cpu.Cpu;
const Bus = zzssxx.memory.Bus;

test "GTE MTC2/MFC2 and register quirks" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);

    cpu.pc = 0x00000000;
    cpu.next_pc = 0x00000004;

    // 1. MTC2 $a0, DataReg 1 (vz0)
    cpu.writeReg(.a0, 0x0000ABCD);
    bus.write32(cpu.pc, 0x48840800);
    cpu.step();
    try expectEqual(@as(u32, 0xFFFFABCD), cpu.cop2.readData(@as(u5, 1)));

    // 2. MFC2 $t0, DataReg 1 (vz0)
    bus.write32(cpu.pc, 0x48080800);
    cpu.step();
    try expectEqual(@as(u32, 0xFFFFABCD), cpu.readReg(.t0));

    // 3. MTC2 $a0, DataReg 30 (lzcs)
    cpu.writeReg(.a0, 0x000000FF);
    bus.write32(cpu.pc, 0x4884F000);
    cpu.step();
    try expectEqual(@as(u32, 24), cpu.cop2.readData(@as(u5, 31)));

    cpu.writeReg(.a0, 0xFFFFFF00);
    bus.write32(cpu.pc, 0x4884F000);
    cpu.step();
    try expectEqual(@as(u32, 24), cpu.cop2.readData(@as(u5, 31)));
}

test "GTE MVMVA execution" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);

    cpu.pc = 0x00000000;
    cpu.next_pc = 0x00000004;

    cpu.cop2.writeCtrl(@as(u5, 0), 0x00000001);
    cpu.cop2.writeCtrl(@as(u5, 1), 0x00000000);
    cpu.cop2.writeCtrl(@as(u5, 2), 0x00000001);
    cpu.cop2.writeCtrl(@as(u5, 3), 0x00000000);
    cpu.cop2.writeCtrl(@as(u5, 4), 0x00000001);
    cpu.cop2.writeCtrl(@as(u5, 5), 0);
    cpu.cop2.writeCtrl(@as(u5, 6), 0);
    cpu.cop2.writeCtrl(@as(u5, 7), 0);

    cpu.cop2.writeData(@as(u5, 0), 0x0014000A);
    cpu.cop2.writeData(@as(u5, 1), 30);

    bus.write32(cpu.pc, 0x4A000012);
    cpu.step();

    try expectEqual(@as(u32, 10), cpu.cop2.readData(@as(u5, 9)));
    try expectEqual(@as(u32, 20), cpu.cop2.readData(@as(u5, 10)));
    try expectEqual(@as(u32, 30), cpu.cop2.readData(@as(u5, 11)));
}

test "GTE SXYP FIFO Shift and NCLIP execution" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);

    cpu.pc = 0x00000000;
    cpu.next_pc = 0x00000004;

    // Load up the FIFO via SXYP (Reg 15). Note: Y is high word, X is low word.
    // Point 0: (10, 10)
    cpu.cop2.writeData(@as(u5, 15), (10 << 16) | 10);
    // Point 1: (20, 10)
    cpu.cop2.writeData(@as(u5, 15), (10 << 16) | 20);
    // Point 2: (10, 20)
    cpu.cop2.writeData(@as(u5, 15), (20 << 16) | 10);

    // Verify the FIFO shifted correctly
    try expectEqual(@as(u32, (10 << 16) | 10), cpu.cop2.readData(@as(u5, 12))); // SXY0
    try expectEqual(@as(u32, (10 << 16) | 20), cpu.cop2.readData(@as(u5, 13))); // SXY1
    try expectEqual(@as(u32, (20 << 16) | 10), cpu.cop2.readData(@as(u5, 14))); // SXY2

    // Execute NCLIP (Opcode 0x14000006 in standard form, real command is 0x06)
    bus.write32(cpu.pc, 0x4A000006);
    cpu.step();

    // The cross product of these coordinates forms a clockwise triangle.
    // Result should be 100. Check MAC0 (Reg 24).
    try expectEqual(@as(u32, 100), cpu.cop2.readData(@as(u5, 24)));
}
