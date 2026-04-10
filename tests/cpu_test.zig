const std = @import("std");
const expectEqual = std.testing.expectEqual;

const zzssxx = @import("zzssxx");
const Cpu = zzssxx.cpu.Cpu;
const Reg = zzssxx.cpu.Reg;
const Bus = zzssxx.memory.Bus;

test "Cpu Execution: SLL (Shift Left Logical)" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    var cpu = Cpu.init(bus);

    // Move PC to RAM so we can write our test instruction there
    cpu.pc = 0x00000000;
    cpu.next_pc = 0x00000004;

    // Setup CPU state: set $a0 to 15
    cpu.writeReg(Reg.a0, 0x0000000F);

    // Construct instruction: SLL $t0, $a0, 4
    // Opcode(0) | rs(0) | rt(a0=4) | rd(t0=8) | shamt(4) | funct(SLL=0)
    // Binary: 000000 00000 00100 01000 00100 000000
    const instr_sll = 0x00044100;

    // Inject it into memory at the current PC
    bus.write32(cpu.pc, instr_sll);

    // Run the cycle!
    cpu.step();

    // Check the math: 15 << 4 = 240 (0xF0)
    try expectEqual(@as(u32, 0x000000F0), cpu.readReg(Reg.t0));

    // Ensure the Program Counter advanced accurately
    try expectEqual(@as(u32, 0x00000004), cpu.pc);
    try expectEqual(@as(u32, 0x00000008), cpu.next_pc);
}

test "Cpu Execution: ADD" {
    var bus = std.mem.zeroes(Bus);
    var cpu = Cpu.init(&bus);

    cpu.pc = 0x00000000;
    cpu.next_pc = 0x00000004;

    // Setup CPU state: $a1 = 40, $a2 = 2
    cpu.writeReg(Reg.a1, 40);
    cpu.writeReg(Reg.a2, 2);

    // Construct instruction: ADD $t1, $a1, $a2
    // Opcode(0) | rs(a1=5) | rt(a2=6) | rd(t1=9) | shamt(0) | funct(ADD=0x20)
    // Binary: 000000 00101 00110 01001 00000 100000
    const instr_add = 0x00A64820;
    bus.write32(cpu.pc, instr_add);

    // Run the cycle!
    cpu.step();

    // Check the math: 40 + 2 = 42
    try expectEqual(@as(u32, 42), cpu.readReg(Reg.t1));
}
