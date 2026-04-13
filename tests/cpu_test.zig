const std = @import("std");
const expectEqual = std.testing.expectEqual;

const zzssxx = @import("zzssxx");
const Cpu = zzssxx.cpu.Cpu;
const Reg = zzssxx.cpu.Reg;
const Bus = zzssxx.memory.Bus;

const RegVal = struct {
    reg: Reg,
    val: u32,
};

const TestCase = struct {
    name: []const u8,
    instr: u32,
    init_regs: []const RegVal = &[_]RegVal{},
    expected_regs: []const RegVal = &[_]RegVal{},

    expected_pc: u32 = 0x00000004,
    expected_next_pc: u32 = 0x00000008,
};

fn executeTestCase(tc: TestCase) !void {
    errdefer std.debug.print("\n=== TEST FAILED: {s} ===\n", .{tc.name});

    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);

    cpu.pc = 0x00000000;
    cpu.next_pc = 0x00000004;

    for (tc.init_regs) |rv| {
        cpu.writeReg(rv.reg, rv.val);
    }

    bus.write32(cpu.pc, tc.instr);
    cpu.step();

    for (tc.expected_regs) |rv| {
        try expectEqual(rv.val, cpu.readReg(rv.reg));
    }

    try expectEqual(tc.expected_pc, cpu.pc);
    try expectEqual(tc.expected_next_pc, cpu.next_pc);
}

test "CPU Instruction Execution Suite" {
    const test_cases = [_]TestCase{
        .{
            .name = "SLL (Shift Left Logical)",
            .instr = 0x00044100, // SLL $t0, $a0, 4
            .init_regs = &.{.{ .reg = .a0, .val = 0x0000000F }},
            .expected_regs = &.{.{ .reg = .t0, .val = 0x000000F0 }},
        },
        .{
            .name = "SRL (Shift Right Logical)",
            // SRL $t1, $a1, 4
            // Opcode(0) | rs(0) | rt(a1=5) | rd(t1=9) | shamt(4) | funct(0x02)
            // 000000 00000 00101 01001 00100 000010
            .instr = 0x00054902,
            // 0xF0000000 logically shifted right by 4 should not sign-extend (0s fill from left)
            .init_regs = &.{.{ .reg = .a1, .val = 0xF0000000 }},
            .expected_regs = &.{.{ .reg = .t1, .val = 0x0F000000 }},
        },
        .{
            .name = "SRA (Shift Right Arithmetic)",
            // SRA $t2, $a1, 4
            // Opcode(0) | rs(0) | rt(a1=5) | rd(t2=10) | shamt(4) | funct(0x03)
            // 000000 00000 00101 01010 00100 000011
            .instr = 0x00055103,
            // 0xF0000000 arithmetically shifted right by 4 MUST sign-extend (1s fill from left)
            .init_regs = &.{.{ .reg = .a1, .val = 0xF0000000 }},
            .expected_regs = &.{.{ .reg = .t2, .val = 0xFF000000 }},
        },
        .{
            .name = "SLLV (Shift Left Logical Variable)",
            // SLLV $t3, $a1, $a2
            // Opcode(0) | rs(a2=6) | rt(a1=5) | rd(t3=11) | shamt(0) | funct(0x04)
            // 000000 00110 00101 01011 00000 000100
            .instr = 0x00C55804,
            // 0x0000FFFF shifted left by 8
            .init_regs = &.{ .{ .reg = .a1, .val = 0x0000FFFF }, .{ .reg = .a2, .val = 8 } },
            .expected_regs = &.{.{ .reg = .t3, .val = 0x00FFFF00 }},
        },
        .{
            .name = "SRLV (Shift Right Logical Variable)",
            // SRLV $t4, $a1, $a2
            // Opcode(0) | rs(a2=6) | rt(a1=5) | rd(t4=12) | shamt(0) | funct(0x06)
            // 000000 00110 00101 01100 00000 000110
            .instr = 0x00C56006,
            // 0xFFFF0000 shifted right by 8 (Zero-extended)
            .init_regs = &.{ .{ .reg = .a1, .val = 0xFFFF0000 }, .{ .reg = .a2, .val = 8 } },
            .expected_regs = &.{.{ .reg = .t4, .val = 0x00FFFF00 }},
        },
        .{
            .name = "SRAV (Shift Right Arithmetic Variable)",
            // SRAV $t5, $a1, $a2
            // Opcode(0) | rs(a2=6) | rt(a1=5) | rd(t5=13) | shamt(0) | funct(0x07)
            // 000000 00110 00101 01101 00000 000111
            .instr = 0x00C56807,
            // 0xFFFF0000 shifted right by 8 (Sign-extended)
            .init_regs = &.{ .{ .reg = .a1, .val = 0xFFFF0000 }, .{ .reg = .a2, .val = 8 } },
            .expected_regs = &.{.{ .reg = .t5, .val = 0xFFFFFF00 }},
        },
        .{
            .name = "ADD",
            .instr = 0x00A64820, // ADD $t1, $a1, $a2
            .init_regs = &.{ .{ .reg = .a1, .val = 40 }, .{ .reg = .a2, .val = 2 } },
            .expected_regs = &.{.{ .reg = .t1, .val = 42 }},
        },
        .{
            .name = "ADDU (Add Unsigned)",
            .instr = 0x00A65021, // ADDU $t2, $a1, $a2
            .init_regs = &.{ .{ .reg = .a1, .val = 0xFFFFFFFF }, .{ .reg = .a2, .val = 5 } },
            .expected_regs = &.{.{ .reg = .t2, .val = 4 }}, // Wrapped
        },
        .{
            .name = "SUB (Subtract)",
            .instr = 0x00A65822, // SUB $t3, $a1, $a2
            .init_regs = &.{ .{ .reg = .a1, .val = 50 }, .{ .reg = .a2, .val = 15 } },
            .expected_regs = &.{.{ .reg = .t3, .val = 35 }},
        },
        .{
            .name = "SUBU (Subtract Unsigned)",
            .instr = 0x00A66023, // SUBU $t4, $a1, $a2
            .init_regs = &.{ .{ .reg = .a1, .val = 10 }, .{ .reg = .a2, .val = 15 } },
            .expected_regs = &.{.{ .reg = .t4, .val = 0xFFFFFFFB }}, // Underflow
        },
        .{
            .name = "JR (Jump Register)",
            .instr = 0x03200008, // JR $t9
            .init_regs = &.{.{ .reg = .t9, .val = 0x80001234 }},
            .expected_pc = 0x00000004, // Current PC hits delay slot
            .expected_next_pc = 0x80001234, // Next PC jumps
        },
        .{
            .name = "JALR (Jump And Link Register)",
            .instr = 0x0320F809, // JALR $ra, $t9
            .init_regs = &.{.{ .reg = .t9, .val = 0x80005678 }},
            .expected_regs = &.{.{ .reg = .ra, .val = 0x00000008 }}, // Stores return addr
            .expected_pc = 0x00000004,
            .expected_next_pc = 0x80005678,
        },
        .{
            .name = "Zero Register Hardwiring",
            .instr = 0x00A60020, // ADD $zero, $a1, $a2
            .init_regs = &.{ .{ .reg = .a1, .val = 10 }, .{ .reg = .a2, .val = 20 } },
            .expected_regs = &.{.{ .reg = .zero, .val = 0 }}, // Must remain 0
        },
        .{
            .name = "AND",
            .instr = 0x00A66824, // AND $t5, $a1, $a2
            .init_regs = &.{ .{ .reg = .a1, .val = 0x0F0F0F0F }, .{ .reg = .a2, .val = 0x33333333 } },
            .expected_regs = &.{.{ .reg = .t5, .val = 0x03030303 }},
        },
        .{
            .name = "OR",
            .instr = 0x00A67025, // OR $t6, $a1, $a2
            .init_regs = &.{ .{ .reg = .a1, .val = 0x0F0F0F0F }, .{ .reg = .a2, .val = 0x33333333 } },
            .expected_regs = &.{.{ .reg = .t6, .val = 0x3F3F3F3F }},
        },
        .{
            .name = "XOR",
            .instr = 0x00A67826, // XOR $t7, $a1, $a2
            .init_regs = &.{ .{ .reg = .a1, .val = 0x0F0F0F0F }, .{ .reg = .a2, .val = 0x33333333 } },
            .expected_regs = &.{.{ .reg = .t7, .val = 0x3C3C3C3C }},
        },
        .{
            .name = "NOR",
            .instr = 0x00A6C027, // NOR $t8, $a1, $a2
            .init_regs = &.{ .{ .reg = .a1, .val = 0x00000000 }, .{ .reg = .a2, .val = 0x00000000 } },
            .expected_regs = &.{.{ .reg = .t8, .val = 0xFFFFFFFF }},
        },
        .{
            .name = "SLT (Set on Less Than - True)",
            .instr = 0x00A6402A, // SLT $t0, $a1, $a2
            // a1 = -5, a2 = 10 -> t0 = 1
            .init_regs = &.{ .{ .reg = .a1, .val = @as(u32, @bitCast(@as(i32, -5))) }, .{ .reg = .a2, .val = 10 } },
            .expected_regs = &.{.{ .reg = .t0, .val = 1 }},
        },
        .{
            .name = "SLT (Set on Less Than - False)",
            .instr = 0x00A6402A, // SLT $t0, $a1, $a2
            // a1 = 10, a2 = -5 -> t0 = 0
            .init_regs = &.{ .{ .reg = .a1, .val = 10 }, .{ .reg = .a2, .val = @as(u32, @bitCast(@as(i32, -5))) } },
            .expected_regs = &.{.{ .reg = .t0, .val = 0 }},
        },
        .{
            .name = "SLTU (Set on Less Than Unsigned - False)",
            .instr = 0x00A6482B, // SLTU $t1, $a1, $a2
            // -5 as unsigned is 0xFFFFFFFB. 0xFFFFFFFB > 10, so t1 = 0
            .init_regs = &.{ .{ .reg = .a1, .val = @as(u32, @bitCast(@as(i32, -5))) }, .{ .reg = .a2, .val = 10 } },
            .expected_regs = &.{.{ .reg = .t1, .val = 0 }},
        },
        .{
            .name = "SLTU (Set on Less Than Unsigned - True)",
            .instr = 0x00A6482B, // SLTU $t1, $a1, $a2
            // a1 = 5, a2 = 10 -> t1 = 1
            .init_regs = &.{ .{ .reg = .a1, .val = 5 }, .{ .reg = .a2, .val = 10 } },
            .expected_regs = &.{.{ .reg = .t1, .val = 1 }},
        },
        .{
            .name = "J (Jump)",
            // Opcode(0x02) | target(0x00048D) -> 0x00001234 >> 2
            // 000010 00000000000000010010001101
            .instr = 0x0800048D,
            .expected_pc = 0x00000004, // Advances to delay slot
            .expected_next_pc = 0x00001234, // PC jumps to target
        },
        .{
            .name = "JAL (Jump And Link)",
            // Opcode(0x03) | target(0x00048D) -> 0x00001234 >> 2
            // 000011 00000000000000010010001101
            .instr = 0x0C00048D,
            .expected_regs = &.{.{ .reg = .ra, .val = 0x00000008 }}, // Link address (PC + 8)
            .expected_pc = 0x00000004,
            .expected_next_pc = 0x00001234,
        },
        .{
            .name = "BEQ (Branch on Equal - True)",
            // Opcode(0x04) | rs(a0=4) | rt(a1=5) | offset(3)
            // 000100 00100 00101 0000000000000011
            .instr = 0x10850003,
            .init_regs = &.{ .{ .reg = .a0, .val = 42 }, .{ .reg = .a1, .val = 42 } },
            .expected_pc = 0x00000004,
            // Next PC = delay slot PC (0x4) + (offset << 2) (0xC) = 0x10
            .expected_next_pc = 0x00000010,
        },
        .{
            .name = "BEQ (Branch on Equal - False)",
            .instr = 0x10850003,
            .init_regs = &.{ .{ .reg = .a0, .val = 42 }, .{ .reg = .a1, .val = 43 } },
            .expected_pc = 0x00000004,
            .expected_next_pc = 0x00000008, // Branch not taken, normal execution
        },
        .{
            .name = "BNE (Branch on Not Equal - True)",
            // Opcode(0x05) | rs(a0=4) | rt(a1=5) | offset(3)
            // 000101 00100 00101 0000000000000011
            .instr = 0x14850003,
            .init_regs = &.{ .{ .reg = .a0, .val = 42 }, .{ .reg = .a1, .val = 99 } },
            .expected_pc = 0x00000004,
            .expected_next_pc = 0x00000010, // Branch taken
        },
        .{
            .name = "BNE (Branch on Not Equal - False)",
            .instr = 0x14850003,
            .init_regs = &.{ .{ .reg = .a0, .val = 42 }, .{ .reg = .a1, .val = 42 } },
            .expected_pc = 0x00000004,
            .expected_next_pc = 0x00000008, // Branch not taken
        },
        .{
            .name = "BLEZ (Branch on Less Than or Equal to Zero - Less)",
            // Opcode(0x06) | rs(a0=4) | rt(0) | offset(5)
            // 000110 00100 00000 0000000000000101
            .instr = 0x18800005,
            .init_regs = &.{.{ .reg = .a0, .val = @as(u32, @bitCast(@as(i32, -1))) }},
            .expected_pc = 0x00000004,
            // Next PC = delay slot PC (0x4) + (offset << 2) (0x14) = 0x18
            .expected_next_pc = 0x00000018,
        },
        .{
            .name = "BLEZ (Branch on Less Than or Equal to Zero - Equal)",
            .instr = 0x18800005,
            .init_regs = &.{.{ .reg = .a0, .val = 0 }},
            .expected_pc = 0x00000004,
            .expected_next_pc = 0x00000018, // Branch taken
        },
        .{
            .name = "BLEZ (Branch on Less Than or Equal to Zero - False)",
            .instr = 0x18800005,
            .init_regs = &.{.{ .reg = .a0, .val = 1 }},
            .expected_pc = 0x00000004,
            .expected_next_pc = 0x00000008, // Branch not taken
        },
        .{
            .name = "BGTZ (Branch on Greater Than Zero - True)",
            // Opcode(0x07) | rs(a0=4) | rt(0) | offset(5)
            // 000111 00100 00000 0000000000000101
            .instr = 0x1C800005,
            .init_regs = &.{.{ .reg = .a0, .val = 1 }},
            .expected_pc = 0x00000004,
            .expected_next_pc = 0x00000018, // Branch taken
        },
        .{
            .name = "BGTZ (Branch on Greater Than Zero - Equal/False)",
            .instr = 0x1C800005,
            .init_regs = &.{.{ .reg = .a0, .val = 0 }},
            .expected_pc = 0x00000004,
            .expected_next_pc = 0x00000008, // Branch not taken
        },
        .{
            .name = "BGTZ (Branch on Greater Than Zero - Less/False)",
            .instr = 0x1C800005,
            .init_regs = &.{.{ .reg = .a0, .val = @as(u32, @bitCast(@as(i32, -1))) }},
            .expected_pc = 0x00000004,
            .expected_next_pc = 0x00000008, // Branch not taken
        },
    };

    inline for (test_cases) |tc| {
        try executeTestCase(tc);
    }
}

test "CPU HI/LO Move Instructions" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);

    cpu.pc = 0x00000000;
    cpu.next_pc = 0x00000004;

    // 1. MTHI $a1 (0x00A00011) -> Write $a1 to hi
    cpu.writeReg(.a1, 0xDEADBEEF);
    bus.write32(cpu.pc, 0x00A00011);
    cpu.step();
    try expectEqual(@as(u32, 0xDEADBEEF), cpu.hi);

    // 2. MTLO $a2 (0x00C00013) -> Write $a2 to lo
    cpu.writeReg(.a2, 0xCAFEBABE);
    bus.write32(cpu.pc, 0x00C00013);
    cpu.step();
    try expectEqual(@as(u32, 0xCAFEBABE), cpu.lo);

    // 3. MFHI $t0 (0x00004010) -> Read hi into $t0
    bus.write32(cpu.pc, 0x00004010);
    cpu.step();
    try expectEqual(@as(u32, 0xDEADBEEF), cpu.readReg(.t0));

    // 4. MFLO $t1 (0x00004812) -> Read lo into $t1
    bus.write32(cpu.pc, 0x00004812);
    cpu.step();
    try expectEqual(@as(u32, 0xCAFEBABE), cpu.readReg(.t1));
}

test "CPU MULT/DIV Instructions" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);

    cpu.pc = 0x00000000;
    cpu.next_pc = 0x00000004;

    // 1. MULT $a1, $a2 (0x00A60018)
    // 0x7FFFFFFF * 2 = 0x00000000_FFFFFFFE (hi=0, lo=0xFFFFFFFE)
    cpu.writeReg(.a1, 0x7FFFFFFF);
    cpu.writeReg(.a2, 2);
    bus.write32(cpu.pc, 0x00A60018);
    cpu.step();
    try expectEqual(@as(u32, 0), cpu.hi);
    try expectEqual(@as(u32, 0xFFFFFFFE), cpu.lo);

    // 2. MULTU $a1, $a2 (0x00A60019)
    // 0xFFFFFFFF * 2 = 0x00000001_FFFFFFFE (hi=1, lo=0xFFFFFFFE)
    cpu.writeReg(.a1, 0xFFFFFFFF);
    cpu.writeReg(.a2, 2);
    bus.write32(cpu.pc, 0x00A60019);
    cpu.step();
    try expectEqual(@as(u32, 1), cpu.hi);
    try expectEqual(@as(u32, 0xFFFFFFFE), cpu.lo);

    // 3. DIV $a1, $a2 (0x00A6001A)
    // 10 / 3 = 3 remainder 1 (lo=3, hi=1)
    cpu.writeReg(.a1, 10);
    cpu.writeReg(.a2, 3);
    bus.write32(cpu.pc, 0x00A6001A);
    cpu.step();
    try expectEqual(@as(u32, 1), cpu.hi); // Remainder in hi
    try expectEqual(@as(u32, 3), cpu.lo); // Quotient in lo

    // 4. DIVU $a1, $a2 (0x00A6001B)
    // 0xFFFFFFFF / 2 = 0x7FFFFFFF remainder 1
    cpu.writeReg(.a1, 0xFFFFFFFF);
    cpu.writeReg(.a2, 2);
    bus.write32(cpu.pc, 0x00A6001B);
    cpu.step();
    try expectEqual(@as(u32, 1), cpu.hi); // Remainder in hi
    try expectEqual(@as(u32, 0x7FFFFFFF), cpu.lo); // Quotient in lo
}
