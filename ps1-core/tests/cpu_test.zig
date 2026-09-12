const std = @import("std");
const expectEqual = std.testing.expectEqual;

const ps1_core = @import("ps1_core");
const Cpu = ps1_core.cpu.Cpu;
const Reg = ps1_core.cpu.Reg;
const Cop0Reg = ps1_core.cpu.Cop0.Reg;
const Bus = ps1_core.memory.Bus;
const Value = ps1_core.pgxp.Value;
const subPixel = @import("pgxp_value.zig").subPixel;

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
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;

    for (tc.init_regs) |rv| {
        cpu.writeReg(rv.reg, rv.val);
    }

    bus.write32(cpu.pipeline.pc, tc.instr);
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();

    for (tc.expected_regs) |rv| {
        try expectEqual(rv.val, cpu.readReg(rv.reg));
    }

    try expectEqual(tc.expected_pc, cpu.pipeline.pc);
    try expectEqual(tc.expected_next_pc, cpu.pipeline.next_pc);
}

test "LBU masks mirrored IO bus value to one byte" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;
    cpu.writeReg(.a0, 0x1F801800);

    bus.write32(0x00000000, 0x90880000); // LBU $t0, 0($a0)
    bus.write32(0x00000004, 0x00000000); // NOP, resolves load delay
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;

    cpu.step();
    cpu.step();

    try expectEqual(@as(u32, 0x00000018), cpu.readReg(.t0));
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
        .{
            .name = "ADDI (Add Immediate)",
            // Opcode(0x08) | rs(a1=5) | rt(t0=8) | imm(-15 = 0xFFF1)
            // 001000 00101 01000 1111111111110001
            .instr = 0x20A8FFF1,
            .init_regs = &.{.{ .reg = .a1, .val = 20 }},
            .expected_regs = &.{.{ .reg = .t0, .val = 5 }},
        },
        .{
            .name = "ADDIU (Add Immediate Unsigned)",
            // Opcode(0x09) | rs(a1=5) | rt(t1=9) | imm(-15 = 0xFFF1)
            // 001001 00101 01001 1111111111110001
            .instr = 0x24A9FFF1,
            .init_regs = &.{.{ .reg = .a1, .val = 20 }},
            .expected_regs = &.{.{ .reg = .t1, .val = 5 }},
        },
        .{
            .name = "SLTI (Set on Less Than Immediate - True)",
            // Opcode(0x0A) | rs(a1=5) | rt(t2=10) | imm(10 = 0x000A)
            // 001010 00101 01010 0000000000001010
            .instr = 0x28AA000A,
            .init_regs = &.{.{ .reg = .a1, .val = 5 }},
            .expected_regs = &.{.{ .reg = .t2, .val = 1 }},
        },
        .{
            .name = "SLTI (Set on Less Than Immediate - False)",
            // Opcode(0x0A) | rs(a1=5) | rt(t2=10) | imm(10 = 0x000A)
            .instr = 0x28AA000A,
            .init_regs = &.{.{ .reg = .a1, .val = 15 }},
            .expected_regs = &.{.{ .reg = .t2, .val = 0 }},
        },
        .{
            .name = "SLTIU (Set on Less Than Immediate Unsigned - True)",
            // Opcode(0x0B) | rs(a1=5) | rt(t3=11) | imm(-1 = 0xFFFF)
            // Note: Immediate is sign-extended to 0xFFFFFFFF, but compared as unsigned
            // 001011 00101 01011 1111111111111111
            .instr = 0x2CABFFFF,
            .init_regs = &.{.{ .reg = .a1, .val = 10 }}, // 10 < 0xFFFFFFFF is true
            .expected_regs = &.{.{ .reg = .t3, .val = 1 }},
        },
        .{
            .name = "ANDI (Bitwise AND Immediate)",
            // Opcode(0x0C) | rs(a1=5) | rt(t4=12) | imm(0x0F0F)
            // Note: Immediate is Zero-extended
            // 001100 00101 01100 0000111100001111
            .instr = 0x30AC0F0F,
            .init_regs = &.{.{ .reg = .a1, .val = 0xFFFF3333 }},
            .expected_regs = &.{.{ .reg = .t4, .val = 0x00000303 }},
        },
        .{
            .name = "ORI (Bitwise OR Immediate)",
            // Opcode(0x0D) | rs(a1=5) | rt(t5=13) | imm(0x0F0F)
            // Note: Immediate is Zero-extended
            // 001101 00101 01101 0000111100001111
            .instr = 0x34AD0F0F,
            .init_regs = &.{.{ .reg = .a1, .val = 0x33330000 }},
            .expected_regs = &.{.{ .reg = .t5, .val = 0x33330F0F }},
        },
        .{
            .name = "XORI (Bitwise XOR Immediate)",
            // Opcode(0x0E) | rs(a1=5) | rt(t6=14) | imm(0x0F0F)
            // Note: Immediate is Zero-extended
            // 001110 00101 01110 0000111100001111
            .instr = 0x38AE0F0F,
            .init_regs = &.{.{ .reg = .a1, .val = 0x33333333 }},
            .expected_regs = &.{.{ .reg = .t6, .val = 0x33333C3C }},
        },
        .{
            .name = "LUI (Load Upper Immediate)",
            // Opcode(0x0F) | rs(0) | rt(t7=15) | imm(0xDEAD)
            // 001111 00000 01111 1101111010101101
            .instr = 0x3C0FDEAD,
            .expected_regs = &.{.{ .reg = .t7, .val = 0xDEAD0000 }},
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

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;

    // 1. MTHI $a1 (0x00A00011) -> Write $a1 to hi
    cpu.writeReg(.a1, 0xDEADBEEF);
    bus.write32(cpu.pipeline.pc, 0x00A00011);
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    try expectEqual(@as(u32, 0xDEADBEEF), cpu.hi);

    // 2. MTLO $a2 (0x00C00013) -> Write $a2 to lo
    cpu.writeReg(.a2, 0xCAFEBABE);
    bus.write32(cpu.pipeline.pc, 0x00C00013);
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    try expectEqual(@as(u32, 0xCAFEBABE), cpu.lo);

    // 3. MFHI $t0 (0x00004010) -> Read hi into $t0
    bus.write32(cpu.pipeline.pc, 0x00004010);
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    try expectEqual(@as(u32, 0xDEADBEEF), cpu.readReg(.t0));

    // 4. MFLO $t1 (0x00004812) -> Read lo into $t1
    bus.write32(cpu.pipeline.pc, 0x00004812);
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    try expectEqual(@as(u32, 0xCAFEBABE), cpu.readReg(.t1));
}

test "CPU MULT/DIV Instructions" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;

    // 1. MULT $a1, $a2 (0x00A60018)
    // 0x7FFFFFFF * 2 = 0x00000000_FFFFFFFE (hi=0, lo=0xFFFFFFFE)
    cpu.writeReg(.a1, 0x7FFFFFFF);
    cpu.writeReg(.a2, 2);
    bus.write32(cpu.pipeline.pc, 0x00A60018);
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    try expectEqual(@as(u32, 0), cpu.hi);
    try expectEqual(@as(u32, 0xFFFFFFFE), cpu.lo);

    // 2. MULTU $a1, $a2 (0x00A60019)
    // 0xFFFFFFFF * 2 = 0x00000001_FFFFFFFE (hi=1, lo=0xFFFFFFFE)
    cpu.writeReg(.a1, 0xFFFFFFFF);
    cpu.writeReg(.a2, 2);
    bus.write32(cpu.pipeline.pc, 0x00A60019);
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    try expectEqual(@as(u32, 1), cpu.hi);
    try expectEqual(@as(u32, 0xFFFFFFFE), cpu.lo);

    // 3. DIV $a1, $a2 (0x00A6001A)
    // 10 / 3 = 3 remainder 1 (lo=3, hi=1)
    cpu.writeReg(.a1, 10);
    cpu.writeReg(.a2, 3);
    bus.write32(cpu.pipeline.pc, 0x00A6001A);
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    try expectEqual(@as(u32, 1), cpu.hi); // Remainder in hi
    try expectEqual(@as(u32, 3), cpu.lo); // Quotient in lo

    // 4. DIVU $a1, $a2 (0x00A6001B)
    // 0xFFFFFFFF / 2 = 0x7FFFFFFF remainder 1
    cpu.writeReg(.a1, 0xFFFFFFFF);
    cpu.writeReg(.a2, 2);
    bus.write32(cpu.pipeline.pc, 0x00A6001B);
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    try expectEqual(@as(u32, 1), cpu.hi); // Remainder in hi
    try expectEqual(@as(u32, 0x7FFFFFFF), cpu.lo); // Quotient in lo
}

test "CPU COP0 MTC0/MFC0 loop" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;

    cpu.writeReg(.a1, 0xDEADBEEF);

    // MTC0 $a1, $12 (SR)
    bus.write32(cpu.pipeline.pc, 0x40856000);
    cpu.step();
    try expectEqual(@as(u32, 0xDEADBEEF), cpu.cop0.readReg(Cop0Reg.sr));

    // MFC0 $t0, $12 (SR)
    bus.write32(cpu.pipeline.pc, 0x40086000);
    cpu.step();
    try expectEqual(@as(u32, 0xDEADBEEF), cpu.readReg(.t0));
}

test "explicit register write in load-delay slot supersedes pending load" {
    // Real R3000A / Avocado behavior: when the instruction in a load's delay slot
    // writes the load's target register, that explicit write wins (the load's
    // delayed writeback is cancelled). This is the Silent Hill boot bug: a
    // `lw ra, off(sp)` in a branch-delay slot followed by `jal` must keep the
    // jal's link address in $ra, not the loaded word.
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;
    cpu.writeReg(.a0, 0x00000100);
    bus.write32(0x00000100, 0xDEADBEEF); // the word the buggy path loads into $ra

    bus.write32(0x00000000, 0x8C9F0000); // lw   $ra, 0($a0)
    bus.write32(0x00000004, 0x0C000010); // jal  0x40  -> sets $ra = 0x0C
    bus.write32(0x00000008, 0x00000000); // nop (jal delay slot)
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;

    cpu.step(); // lw   (queues load into $ra)
    cpu.step(); // jal  (writes $ra link; load must NOT clobber it)

    // $ra must hold the jal link address (0x0C), not the loaded 0xDEADBEEF.
    try expectEqual(@as(u32, 0x0000000C), cpu.readReg(.ra));
}

test "CPU COP0 RFE restores status mode bits" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;
    cpu.cop0.writeReg(Cop0Reg.sr, 0x0000003C);

    // RFE
    bus.write32(cpu.pipeline.pc, 0x42000010);
    cpu.step();

    try expectEqual(@as(u32, 0x0000003F), cpu.cop0.readReg(Cop0Reg.sr));
}

test "CPU exception updates COP0 registers" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;
    cpu.cop0.writeReg(Cop0Reg.sr, 0x0000000F);

    // SYSCALL
    bus.write32(cpu.pipeline.pc, 0x0000000C);
    cpu.step();

    try expectEqual(@as(u32, 0x00000000), cpu.cop0.readReg(Cop0Reg.epc));
    try expectEqual(@as(u32, 0x00000020), cpu.cop0.readReg(Cop0Reg.cause));
    try expectEqual(@as(u32, 0x0000003C), cpu.cop0.readReg(Cop0Reg.sr));
    try expectEqual(@as(u32, 0x80000080), cpu.pipeline.pc);
    try expectEqual(@as(u32, 0x80000084), cpu.pipeline.next_pc);
}

test "CPU exception in branch delay slot sets EPC to branch and BD bit" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;
    cpu.cop0.writeReg(Cop0Reg.sr, 0x0000000F);
    cpu.writeReg(.a0, 1);
    cpu.writeReg(.a1, 2);

    // BEQ $a0, $a1, +3 (not taken)
    bus.write32(0x00000000, 0x10850003);
    // SYSCALL in branch delay slot
    bus.write32(0x00000004, 0x0000000C);

    cpu.step();
    try expectEqual(@as(u32, 0x00000004), cpu.pipeline.pc);
    try expectEqual(@as(u32, 0x00000008), cpu.pipeline.next_pc);

    cpu.step();

    try expectEqual(@as(u32, 0x00000000), cpu.cop0.readReg(Cop0Reg.epc));
    try expectEqual(@as(u32, 0x80000020), cpu.cop0.readReg(Cop0Reg.cause));
    try expectEqual(@as(u32, 0x0000003C), cpu.cop0.readReg(Cop0Reg.sr));
    try expectEqual(@as(u32, 0x80000080), cpu.pipeline.pc);
    try expectEqual(@as(u32, 0x80000084), cpu.pipeline.next_pc);
}

test "COP0 cause register only allows software interrupt writes" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);

    cpu.cop0.regs[@intFromEnum(Cop0Reg.cause)] = 0xAAAAAAAA;
    cpu.cop0.writeReg(Cop0Reg.cause, 0xFFFFFFFF);

    try expectEqual(@as(u32, 0xAAAAABAA), cpu.cop0.readReg(Cop0Reg.cause));
}

test "CPU Load Instructions" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;

    // Set up memory with symmetric byte patterns to make the test endian-independent.
    bus.write32(0x0100, 0xFFFFFFFF);
    bus.write32(0x0104, 0x7F7F7F7F);

    // Set base register $a0 to 0x0100
    cpu.writeReg(.a0, 0x0100);

    // LW $t0, 0($a0) (0x8C880000) -> Load Word
    bus.write32(cpu.pipeline.pc, 0x8C880000);
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step(); // Issues the load
    cpu.step(); // Executes NOP (delay slot), commits the load to the register
    try expectEqual(@as(u32, 0xFFFFFFFF), cpu.readReg(.t0));

    // LB $t1, 0($a0) (0x80890000) -> Load Byte (Sign-Extended: 0xFF -> 0xFFFFFFFF)
    bus.write32(cpu.pipeline.pc, 0x80890000);
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    cpu.step(); // Commit load
    try expectEqual(@as(u32, 0xFFFFFFFF), cpu.readReg(.t1));

    // LBU $t2, 0($a0) (0x908A0000) -> Load Byte Unsigned (Zero-Extended: 0xFF -> 0x000000FF)
    bus.write32(cpu.pipeline.pc, 0x908A0000);
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    cpu.step(); // Commit load
    try expectEqual(@as(u32, 0x000000FF), cpu.readReg(.t2));

    // LH $t3, 0($a0) (0x848B0000) -> Load Halfword (Sign-Extended: 0xFFFF -> 0xFFFFFFFF)
    bus.write32(cpu.pipeline.pc, 0x848B0000);
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    cpu.step(); // Commit load
    try expectEqual(@as(u32, 0xFFFFFFFF), cpu.readReg(.t3));

    // LHU $t4, 0($a0) (0x948C0000) -> Load Halfword Unsigned (Zero-Extended: 0xFFFF -> 0x0000FFFF)
    bus.write32(cpu.pipeline.pc, 0x948C0000);
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    cpu.step(); // Commit load
    try expectEqual(@as(u32, 0x0000FFFF), cpu.readReg(.t4));

    // Test positive values using offset 4 to ensure LB/LH don't falsely sign-extend positive bits
    // Base is still $a0 = 0x0100. Offset = 4. Target = 0x0104.

    // LB $t5, 4($a0) (0x808D0004) -> Load Byte (Sign-Extended: 0x7F -> 0x0000007F)
    bus.write32(cpu.pipeline.pc, 0x808D0004);
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    cpu.step(); // Commit load
    try expectEqual(@as(u32, 0x0000007F), cpu.readReg(.t5));

    // LH $t6, 4($a0) (0x848E0004) -> Load Halfword (Sign-Extended: 0x7F7F -> 0x00007F7F)
    bus.write32(cpu.pipeline.pc, 0x848E0004);
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    cpu.step(); // Commit load
    try expectEqual(@as(u32, 0x00007F7F), cpu.readReg(.t6));
}

test "CPU Unaligned Load Instructions (LWL/LWR)" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;

    // Write a recognizable pattern to memory.
    // Address 0x0100: 0x44332211
    // (In Little Endian, bytes are: 100:11, 101:22, 102:33, 103:44)
    bus.write32(0x0100, 0x44332211);

    // Address 0x0104: 0x88776655
    // (Bytes are: 104:55, 105:66, 106:77, 107:88)
    bus.write32(0x0104, 0x88776655);

    cpu.writeReg(.a0, 0x0100);

    // Helper to run a test and automatically flush the Load Delay slot
    const testInstr = struct {
        fn run(c: *Cpu, b: *Bus, instr: u32, expected: u32) !void {
            c.writeReg(.t0, 0xDEADBEEF); // Set destination to recognizable garbage to test merging
            c.pipeline.pc = 0x00000000;
            c.pipeline.next_pc = 0x00000004;
            b.write32(0x00000000, instr);
            b.write32(0x00000004, 0x00000000); // NOP for delay slot

            c.icache = [_]Cpu.CacheLine{.{}} ** 256;
            c.step(); // Execute target instruction (puts merge in load delay pipeline)
            c.step(); // Execute NOP (commits load delay into register)
            try std.testing.expectEqual(expected, c.readReg(.t0));
        }
    }.run;

    // LWL
    // Opcode 0x22. rs = $a0 (4), rt = $t0 (8). Base instruction: 0x88880000
    try testInstr(&cpu, bus, 0x88880000, 0x11ADBEEF); // offset 0: loads 1 byte (0x11) into MSB
    try testInstr(&cpu, bus, 0x88880001, 0x2211BEEF); // offset 1: loads 2 bytes (0x2211) into top half
    try testInstr(&cpu, bus, 0x88880002, 0x332211EF); // offset 2: loads 3 bytes (0x332211) into top 3 bytes
    try testInstr(&cpu, bus, 0x88880003, 0x44332211); // offset 3: loads all 4 bytes

    // LWR
    // Opcode 0x26. rs = $a0 (4), rt = $t0 (8). Base instruction: 0x98880000
    try testInstr(&cpu, bus, 0x98880000, 0x44332211); // offset 0: loads all 4 bytes
    try testInstr(&cpu, bus, 0x98880001, 0xDE443322); // offset 1: loads 3 bytes (0x443322) into bottom 3 bytes
    try testInstr(&cpu, bus, 0x98880002, 0xDEAD4433); // offset 2: loads 2 bytes (0x4433) into bottom half
    try testInstr(&cpu, bus, 0x98880003, 0xDEADBE44); // offset 3: loads 1 byte (0x44) into LSB

    // Load unaligned word at 0x0101. Bytes are 22, 33, 44, 55.
    // In Little Endian, this results in: 0x55443322
    cpu.writeReg(.a0, 0x0101); // Unaligned base address
    cpu.writeReg(.t0, 0xDEADBEEF);
    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;

    // LWL $t0, 3($a0) -> offset 3. Targets 0x104.
    bus.write32(0x00000000, 0x88880003);
    // NOP (Isolated here so we don't accidentally test complex pipeline forwarding yet)
    bus.write32(0x00000004, 0x00000000);
    // LWR $t0, 0($a0) -> offset 0. Targets 0x101.
    bus.write32(0x00000008, 0x98880000);
    // NOP for LWR delay slot
    bus.write32(0x0000000C, 0x00000000);

    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step(); // Execute LWL
    cpu.step(); // Execute NOP (commits LWL)
    cpu.step(); // Execute LWR
    cpu.step(); // Execute NOP (commits LWR)

    try std.testing.expectEqual(@as(u32, 0x55443322), cpu.readReg(.t0));
}

test "CPU Store Instructions" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;

    // Set base register $a0 to 0x0100
    cpu.writeReg(.a0, 0x0100);
    // Set target register $t0 to a recognizable pattern
    cpu.writeReg(.t0, 0xAABBCCDD);

    // SW $t0, 0($a0) (0xAC880000) -> Store Word
    bus.write32(cpu.pipeline.pc, 0xAC880000);
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    try expectEqual(@as(u32, 0xAABBCCDD), bus.read32(0x0100));

    // SH $t0, 4($a0) (0xA4880004) -> Store Halfword (stores bottom 16 bits: 0xCCDD)
    bus.write32(cpu.pipeline.pc, 0xA4880004);
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    try expectEqual(@as(u16, 0xCCDD), bus.read16(0x0104));

    // SB $t0, 8($a0) (0xA0880008) -> Store Byte (stores bottom 8 bits: 0xDD)
    bus.write32(cpu.pipeline.pc, 0xA0880008);
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    try expectEqual(@as(u8, 0xDD), bus.read8(0x0108));
}

test "CPU Unaligned Store Instructions (SWL/SWR)" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);

    cpu.writeReg(.a0, 0x0100);
    cpu.writeReg(.t0, 0x44332211);

    // Helper to run a test, resetting memory to 0xFFFFFFFF each time to easily see the mask
    const testInstr = struct {
        fn run(c: *Cpu, b: *Bus, instr: u32, expected: u32) !void {
            b.write32(0x0100, 0xFFFFFFFF);
            c.pipeline.pc = 0x00000000;
            c.pipeline.next_pc = 0x00000004;
            b.write32(0x00000000, instr);

            c.icache = [_]Cpu.CacheLine{.{}} ** 256;
            c.step();
            try std.testing.expectEqual(expected, b.read32(0x0100));
        }
    }.run;

    // SWL
    // Opcode 0x2A. rs = $a0 (4), rt = $t0 (8). Base instruction: 0xA8880000
    try testInstr(&cpu, bus, 0xA8880000, 0xFFFFFF44); // offset 0: overwrites MSB with 0x44
    try testInstr(&cpu, bus, 0xA8880001, 0xFFFF4433); // offset 1: overwrites top half with 0x4433
    try testInstr(&cpu, bus, 0xA8880002, 0xFF443322); // offset 2: overwrites top 3 bytes with 0x443322
    try testInstr(&cpu, bus, 0xA8880003, 0x44332211); // offset 3: overwrites all 4 bytes

    // SWR
    // Opcode 0x2E. rs = $a0 (4), rt = $t0 (8). Base instruction: 0xB8880000
    try testInstr(&cpu, bus, 0xB8880000, 0x44332211); // offset 0: overwrites all 4 bytes
    try testInstr(&cpu, bus, 0xB8880001, 0x332211FF); // offset 1: overwrites bottom 3 bytes with 0x332211
    try testInstr(&cpu, bus, 0xB8880002, 0x2211FFFF); // offset 2: overwrites bottom half with 0x2211
    try testInstr(&cpu, bus, 0xB8880003, 0x11FFFFFF); // offset 3: overwrites LSB with 0x11
}

test "CPU Cache Isolation prevents RAM writes" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;

    cpu.writeReg(.a0, 0x0100);
    cpu.writeReg(.t0, 0xDEADBEEF);

    // Turn on Cache Isolation (Bit 16 in SR)
    cpu.cop0.writeReg(Cop0Reg.sr, 0x00010000);

    // SW $t0, 0($a0) (0xAC880000)
    bus.write32(cpu.pipeline.pc, 0xAC880000);
    cpu.step();

    // The write to standard RAM should have been dropped entirely
    try expectEqual(@as(u32, 0), bus.read32(0x0100));
}

// An interrupt must not be taken *on* a GTE command instruction.
//
// On hardware the GTE operation is already issued when the exception is
// recognised, so the BIOS handler deliberately returns to EPC+4 -- it reads the
// instruction at EPC and skips it when `(instr >> 24) & 0xFE == 0x4A`, which is
// exactly the COP2-command encoding (kernel handler at 0x00000cc0). An
// emulator that discards the instruction instead loses the operation outright:
// Silent Hill's display-list builder then stores a stale colour-FIFO entry,
// whose CODE byte turns an 8-word POLY_G4 into a 12-word POLY_GT4 and tears
// the rest of the linked-list packet.
test "CPU defers an interrupt pending on a GTE command instruction" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;

    // CU2 usable, IM2 set, interrupts enabled.
    cpu.cop0.writeReg(Cop0Reg.sr, (1 << 30) | (1 << 10) | 1);
    bus.interrupts.writeMask(1 << @intFromEnum(ps1_core.interrupt.Irq.Vblank));
    bus.interrupts.trigger(.Vblank);

    // GTE SQR (opcode 0x28), sf=0: MAC1..3 = IR1..3 squared.
    cpu.cop2.writeData(9, 4);
    bus.write32(0x00000000, 0x4A000028);
    bus.write32(0x00000004, 0x00000000); // nop
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;

    cpu.step();

    // The GTE operation must have run...
    try expectEqual(@as(u32, 16), cpu.cop2.readData(9));
    // ...and the interrupt must still be waiting, not taken at the GTE op.
    try expectEqual(@as(u32, 0x00000004), cpu.pipeline.pc);

    // It is taken on the following instruction instead.
    cpu.step();
    try expectEqual(@as(u32, 0x80000080), cpu.pipeline.pc);
    try expectEqual(@as(u32, 0x00000004), cpu.cop0.readReg(Cop0Reg.epc));
}

// mfc2 $t0, sxy2 / or $t1, $t0, $zero / sw $t1, 0($t2) / lw $t3, 0($t2)
//
// This is the dataflow every PS1 game uses, because it is what libgpu
// prescribes: project, move the packed SXY out of the GTE, park it in an
// ordering-table node, read it back. Each hop is a separate hook, and a
// missing one shows up here as a lost sub-pixel rather than as a wrong
// picture in one game.
test "PGXP: the sub-pixel survives mfc2 -> move -> sw -> lw" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);
    bus.setPgxp(true);

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;
    cpu.cop0.writeReg(Cop0Reg.sr, 1 << 30); // COP2 usable

    const p = subPixel(0x0007_0005, 0.5, 0.25); // (5.5, 7.25)
    cpu.cop2.precise[14] = p;
    cpu.cop2.writeDataRaw(14, 0x0007_0005); // sxy2 = (5, 7), no invalidation

    cpu.writeReg(10, 0x0000_1000); // $t2 = 0x1000, a RAM address

    // mfc2 $8, $14  -> COP2 rs=0 (MFC), rt=8, rd=14
    bus.write32(0x00, 0x4808_7000);
    // or $9, $8, $0
    bus.write32(0x04, 0x0100_4825);
    // sw $9, 0($10)
    bus.write32(0x08, 0xAD49_0000);
    // nop (let the load-delay of nothing settle)
    bus.write32(0x0C, 0x0000_0000);
    // lw $11, 0($10)
    bus.write32(0x10, 0x8D4B_0000);
    // nop  -- the load lands here
    bus.write32(0x14, 0x0000_0000);

    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    for (0..6) |_| cpu.step();

    try expectEqual(@as(u32, 0x0007_0005), cpu.readReg(11));
    const got = cpu.gpr_shadow[11];
    try expectEqual(Value.valid_xy, got.flags);
    try expectEqual(@as(f32, 5.5), got.x);
    try expectEqual(@as(f32, 7.25), got.y);
}

// A cancelled load must not leave a stale shadow behind: `ori` overwrites $9
// in the same instruction slot a pending `lw` would otherwise land in one
// instruction later, and `writeReg`'s unconditional `gpr_shadow[i] =
// Value.none` must apply here exactly as it does to any other explicit
// write (`cpu.zig:255` is the load-delay half of that same cancel). This does
// NOT by itself prove the shadow lands on the correct register when nothing
// cancels it -- see "two in-flight loads land on the correct target
// register" below for that.
test "PGXP: a cancelled load cancels its shadow too" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);
    bus.setPgxp(true);

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;

    // CPU mode off: it ships on, and with it the cancelling `ori` below
    // propagates a shadow of its OWN into $9. That is CPU mode working, but it
    // would leave this test unable to tell a cancelled load's shadow from the
    // canceller's, which is the only thing it is here to check.
    bus.pgxp_cpu = false;

    bus.write32(0x1000, 0x0007_0005);
    bus.shadowStore(0x1000, subPixel(0x0007_0005, 0.5, 0.25));
    cpu.writeReg(10, 0x0000_1000); // $t2

    // lw $9, 0($10)   -- loads into $9, landing one instruction late
    bus.write32(0x00, 0x8D49_0000);
    // ori $9, $0, 42  -- writes $9 in the delay slot, cancelling the load
    bus.write32(0x04, 0x3409_002A);
    bus.write32(0x08, 0x0000_0000); // nop

    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    for (0..3) |_| cpu.step();

    try expectEqual(@as(u32, 42), cpu.readReg(9));
    try expectEqual(@as(u32, 0), cpu.gpr_shadow[9].flags);
}

// Test 2 only proves a CANCELLED load's shadow clears -- an implementation
// that wrote `gpr_shadow[rt]` directly inside `opLoad`, skipping
// `load_shadow`/`delay_shadow` entirely, would pass every test above this
// one, because nothing else in those tests ever touches the shadow slot a
// stray early write landed in. Two loads back to back is what exposes it,
// and checking only the fully-settled end state is not enough on its own --
// hand-traced below, an eager write happens to reach the same final answer
// once both loads have retired, because nothing else writes gpr_shadow[9] in
// between. The INTERMEDIATE assertion after exactly two `step()`s is what
// actually falls out differently: at that point $8's load has retired (it
// was issued one instruction before $9's) but $9's load is still sitting in
// the load-delay slot -- `readReg(9)` is still its pre-load value and
// `gpr_shadow[9]` must still read invalid. A `gpr_shadow[rt]` write made
// eagerly inside `opLoad`, rather than shifted through
// `load_shadow`/`delay_shadow` in lockstep with the word, would already show
// valid=1 there, one instruction ahead of the register value it claims to
// describe. The final assertions separately catch the other shape of bug --
// a retire that reads THIS step's freshly-set `load_shadow` instead of the
// SAVED `delay_shadow` -- which attaches $9's sub-pixel to $8's register
// instead (both would then read wrong, not just early).
test "PGXP: two in-flight loads land on the correct target register" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);
    bus.setPgxp(true);

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;

    bus.write32(0x1000, 0x0002_0001);
    bus.write32(0x1004, 0x0004_0003);
    bus.shadowStore(0x1000, subPixel(0x0002_0001, 0, 0)); // (1, 2)
    bus.shadowStore(0x1004, subPixel(0x0004_0003, 0, 0)); // (3, 4)
    cpu.writeReg(10, 0x0000_1000); // $t2 = base

    // lw $8, 0($10)
    bus.write32(0x00, 0x8D48_0000);
    // lw $9, 4($10)
    bus.write32(0x04, 0x8D49_0004);
    bus.write32(0x08, 0x0000_0000); // nop -- retires $9's load
    bus.write32(0x0C, 0x0000_0000); // nop -- settling margin

    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;

    cpu.step(); // executes lw $8
    cpu.step(); // executes lw $9; retires $8's load

    try expectEqual(@as(u32, 0x0002_0001), cpu.readReg(8));
    try expectEqual(Value.valid_xy, cpu.gpr_shadow[8].flags);
    // $9's load has executed but not yet retired: the register still reads
    // its pre-load value, and the shadow must not have arrived early either.
    try expectEqual(@as(u32, 0), cpu.readReg(9));
    try expectEqual(@as(u32, 0), cpu.gpr_shadow[9].flags);

    cpu.step(); // nop; retires $9's load
    cpu.step(); // nop; settling margin

    try expectEqual(@as(u32, 0x0002_0001), cpu.readReg(8));
    try expectEqual(@as(u32, 0x0004_0003), cpu.readReg(9));

    const shadow_a = cpu.gpr_shadow[8];
    try expectEqual(Value.valid_xy, shadow_a.flags);
    try expectEqual(@as(f32, 1), shadow_a.x);
    try expectEqual(@as(f32, 2), shadow_a.y);

    const shadow_b = cpu.gpr_shadow[9];
    try expectEqual(Value.valid_xy, shadow_b.flags);
    try expectEqual(@as(f32, 3), shadow_b.x);
    try expectEqual(@as(f32, 4), shadow_b.y);
}

// Any other write to a register must clear its shadow, or an unrelated value
// inherits a screen position. This is the rule that makes the propagation set
// small: everything not explicitly propagated falls through `writeReg`.
test "PGXP: an ordinary register write clears the shadow" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);
    bus.setPgxp(true);

    cpu.gpr_shadow[9] = subPixel(0x0007_0005, 0.5, 0.25);
    cpu.writeReg(9, 0x1234_5678);
    try expectEqual(@as(u32, 0), cpu.gpr_shadow[9].flags);
}

// A sub-word store lands inside a tracked word and destroys it.
test "PGXP: sb into a tracked word invalidates it" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    bus.setPgxp(true);

    bus.shadowStore(0x1002, subPixel(0x0007_0005, 0.5, 0.25));
    try expectEqual(Value.valid_xy, bus.shadowLoad(0x1000).flags);
    bus.shadowInvalidate(0x1003);
    try expectEqual(@as(u32, 0), bus.shadowLoad(0x1000).flags);
}

// Everything above must cost nothing when the feature is off.
test "PGXP: nothing is tracked while disabled" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);
    // bus.pgxp_enabled stays false

    cpu.cop2.precise[14] = subPixel(0x0007_0005, 0.5, 0.25);
    cpu.cop2.writeDataRaw(14, 0x0007_0005);
    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;
    cpu.cop0.writeReg(Cop0Reg.sr, 1 << 30);
    bus.write32(0x00, 0x4808_7000); // mfc2 $8, r14
    bus.write32(0x04, 0x0000_0000);
    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    cpu.step();

    try expectEqual(@as(u32, 0x0007_0005), cpu.readReg(8));
    try expectEqual(@as(u32, 0), cpu.gpr_shadow[8].flags);
}

// mtc2 / lwc2 into SXY0..2 is the path that carried 100% of Crash Bandicoot 3's
// unresolved vertices, measured 2026-08-31 by counting why each empty
// `precise` slot was empty: every one of them had been cleared by
// `writeData(12/13/14)`.
//
// The idiom is a game that CACHES projected vertices instead of re-projecting
// them: it loads a packed SXY back into the GTE and emits it with
// `swc2 sxy0`. `writeData`'s blanket clear is right for software that
// synthesised a screen position out of nothing, and wrong here, where the word
// being written is the same projection PGXP already recorded. Which one it is
// does not have to be guessed: the word the entry was recorded against
// decides, exactly as it does at the GP0 boundary.
test "PGXP: mtc2 into sxy0 carries the register's sub-pixel" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);
    bus.setPgxp(true);

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;
    cpu.cop0.writeReg(Cop0Reg.sr, 1 << 30); // COP2 usable

    cpu.writeRegPrecise(8, 0x0007_0005, subPixel(0x0007_0005, 0.5, 0.25));

    // mtc2 $8, $12  -> COP2 rs=4 (MTC), rt=8, rd=12
    bus.write32(0x00, 0x4888_6000);
    bus.write32(0x04, 0x0000_0000); // nop

    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    cpu.step();

    try expectEqual(@as(u32, 0x0007_0005), cpu.cop2.readData(12));
    const got = cpu.cop2.readPreciseData(12);
    try expectEqual(Value.valid_xy, got.flags);
    try expectEqual(@as(f32, 5.5), got.x);
    try expectEqual(@as(f32, 7.25), got.y);
}

// The word match is what makes the hook above safe rather than a guess: a
// shadow recorded against a DIFFERENT word than the one being written is
// dropped, so the register keeps no sub-pixel at all instead of an unrelated
// one. Verified to FAIL against a hook that propagates unconditionally.
test "PGXP: mtc2 into sxy0 drops a shadow that disagrees with the value" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);
    bus.setPgxp(true);

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;
    cpu.cop0.writeReg(Cop0Reg.sr, 1 << 30);

    // Shadow says (5.5, 7.25); the word written says (9, 11).
    cpu.writeRegPrecise(8, 0x000B_0009, subPixel(0x0007_0005, 0.5, 0.25));

    bus.write32(0x00, 0x4888_6000); // mtc2 $8, $12
    bus.write32(0x04, 0x0000_0000);

    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    cpu.step();

    try expectEqual(@as(u32, 0x000B_0009), cpu.cop2.readData(12));
    try expectEqual(@as(u32, 0), cpu.cop2.readPreciseData(12).flags);
}

// The regression the blanket clear was protecting against, kept: software
// supplying its own screen coordinate must not inherit the sub-pixel of a
// projection two vertices ago.
test "PGXP: mtc2 into sxy0 from an untracked register clears the slot" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);
    bus.setPgxp(true);

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;
    cpu.cop0.writeReg(Cop0Reg.sr, 1 << 30);

    // A leftover projection in the slot, and a plain value on its way in.
    cpu.cop2.precise[12] = subPixel(0x0007_0005, 0.5, 0.25);
    cpu.cop2.writeDataRaw(12, 0x0007_0005);
    cpu.writeReg(8, 0x0007_0005); // same integer coords, no shadow

    bus.write32(0x00, 0x4888_6000); // mtc2 $8, $12
    bus.write32(0x04, 0x0000_0000);

    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    cpu.step();

    try expectEqual(@as(u32, 0), cpu.cop2.readPreciseData(12).flags);
}

// `lwc2` is the same hop with the value coming from RAM instead of a register,
// which is what libgte's `gte_ldsxy*` macros compile to.
test "PGXP: lwc2 into sxy1 carries the word's sub-pixel" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);
    bus.setPgxp(true);

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;
    cpu.cop0.writeReg(Cop0Reg.sr, 1 << 30);

    bus.write32(0x1000, 0x0007_0005);
    bus.shadowStore(0x1000, subPixel(0x0007_0005, 0.5, 0.25));
    cpu.writeReg(10, 0x0000_1000); // $t2 = 0x1000

    // lwc2 $13, 0($10)  -> opcode 0x32, base=10, rt=13
    bus.write32(0x00, 0xC94D_0000);
    bus.write32(0x04, 0x0000_0000);

    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    cpu.step();

    try expectEqual(@as(u32, 0x0007_0005), cpu.cop2.readData(13));
    const got = cpu.cop2.readPreciseData(13);
    try expectEqual(Value.valid_xy, got.flags);
    try expectEqual(@as(f32, 5.5), got.x);
    try expectEqual(@as(f32, 7.25), got.y);
}

// A write to sxyp (reg 15) pushes the FIFO and lands the new value in sxy2, so
// the sub-pixel has to follow it there and not into the slot the register
// index names.
test "PGXP: mtc2 into sxyp lands the sub-pixel on sxy2" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);
    bus.setPgxp(true);

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;
    cpu.cop0.writeReg(Cop0Reg.sr, 1 << 30);

    cpu.writeRegPrecise(8, 0x0007_0005, subPixel(0x0007_0005, 0.5, 0.25));

    bus.write32(0x00, 0x4888_7800); // mtc2 $8, $15
    bus.write32(0x04, 0x0000_0000);

    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    cpu.step();

    try expectEqual(@as(u32, 0x0007_0005), cpu.cop2.readData(14));
    const got = cpu.cop2.readPreciseData(14);
    try expectEqual(Value.valid_xy, got.flags);
    try expectEqual(@as(f32, 5.5), got.x);
    try expectEqual(@as(f32, 7.25), got.y);
}

// And none of it may happen with the feature off.
test "PGXP: mtc2 into sxy0 tracks nothing while disabled" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init(bus);
    // bus.pgxp_enabled stays false

    cpu.pipeline.pc = 0x00000000;
    cpu.pipeline.next_pc = 0x00000004;
    cpu.cop0.writeReg(Cop0Reg.sr, 1 << 30);

    cpu.gpr_shadow[8] = subPixel(0x0007_0005, 0.5, 0.25);
    cpu.writeReg(8, 0x0007_0005);

    bus.write32(0x00, 0x4888_6000); // mtc2 $8, $12
    bus.write32(0x04, 0x0000_0000);

    cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
    cpu.step();
    cpu.step();

    try expectEqual(@as(u32, 0x0007_0005), cpu.cop2.readData(12));
    try expectEqual(@as(u32, 0), cpu.cop2.readPreciseData(12).flags);
}
