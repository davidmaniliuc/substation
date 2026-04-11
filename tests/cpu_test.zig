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
    };

    inline for (test_cases) |tc| {
        try executeTestCase(tc);
    }
}
