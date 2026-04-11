const std = @import("std");
const alu = @import("alu.zig");
const Bus = @import("memory.zig").Bus;

pub const Cpu = struct {
    const Self = @This();

    pub const RType = struct { rs: u5, rt: u5, rd: u5, shamt: u5 };
    pub const IType = struct { rs: u5, rt: u5, imm: u16 };
    pub const JType = struct { target: u26 };

    regs: [32]u32 = [_]u32{0} ** 32,
    pc: u32 = 0xbfc00000,
    next_pc: u32 = 0xbfc00004,
    hi: u32 = 0,
    lo: u32 = 0,
    sr: u32 = 0,
    cause: u32 = 0,
    epc: u32 = 0,
    bus: *Bus,

    pub const Exception = enum(u5) {
        Interrupt = 0x00,
        LoadAddressError = 0x04,
        StoreAddressError = 0x05,
        Syscall = 0x08,
        Breakpoint = 0x09,
        ReservedInstruction = 0x0A,
        ArithmeticOverflow = 0x0C,
    };

    pub fn init(bus: *Bus) Self {
        return Self{ .bus = bus };
    }

    pub fn step(self: *Self) void {
        const instruction = self.bus.read32(self.pc);

        self.pc = self.next_pc;
        self.next_pc = self.pc +% 4; // +% : wrapping add

        self.execute(instruction);
        self.regs[0] = 0; // The "Golden Rule" of MIPS
    }

    pub fn readReg(self: *const Self, index: anytype) u32 {
        const i = self.getIdx(index);
        return if (i == 0) 0 else self.regs[i];
    }

    pub fn writeReg(self: *Self, index: anytype, value: u32) void {
        const i = self.getIdx(index);
        if (i != 0) self.regs[i] = value;
    }

    inline fn getIdx(self: *const Self, index: anytype) u5 {
        _ = self;
        return if (@TypeOf(index) == Reg) @intFromEnum(index) else @as(u5, @truncate(index));
    }

    pub inline fn decodeR(instr: u32) RType {
        return .{
            .rs = @as(u5, @truncate((instr >> 21) & 0x1F)),
            .rt = @as(u5, @truncate((instr >> 16) & 0x1F)),
            .rd = @as(u5, @truncate((instr >> 11) & 0x1F)),
            .shamt = @as(u5, @truncate((instr >> 6) & 0x1F)),
        };
    }

    pub inline fn decodeI(instr: u32) IType {
        return .{
            .rs = @as(u5, @truncate((instr >> 21) & 0x1F)),
            .rt = @as(u5, @truncate((instr >> 16) & 0x1F)),
            .imm = @as(u16, @truncate(instr & 0xFFFF)),
        };
    }

    pub inline fn decodeJ(instr: u32) JType {
        return .{
            .target = @as(u26, @truncate(instr & 0x03FFFFFF)),
        };
    }

    fn execute(self: *Self, instruction: u32) void {
        const opcode = @as(u6, @truncate(instruction >> 26));
        switch (opcode) {
            0x00 => self.special(instruction),
            // 0x02 => self.j(instruction),
            // 0x0F => self.opLui(instruction),
            0x14...0x1F, 0x27, 0x2C, 0x2D, 0x2F, 0x34...0x37, 0x3C...0x3F => {
                // On a real PS1, this triggers a Reserved Instruction Exception
                self.exception(.ReservedInstruction);
            },

            else => std.log.warn("Unimplemented Opcode: 0x{X:0>2}", .{opcode}),
        }
    }

    pub fn special(self: *Self, instruction: u32) void {
        const funct = @as(u6, @truncate(instruction & 0x3F));
        switch (funct) {
            0x00 => self.shift(instruction, alu.sll),
            0x02 => self.shift(instruction, alu.srl),
            0x03 => self.shift(instruction, alu.sra),

            0x04 => self.shiftV(instruction, alu.sll),
            0x06 => self.shiftV(instruction, alu.srl),
            0x07 => self.shiftV(instruction, alu.sra),

            0x08 => self.opJr(instruction),
            0x09 => self.opJalr(instruction),

            0x0C => self.opSyscall(instruction),
            0x0D => self.opBreak(instruction),

            0x10 => self.opMfhi(instruction),
            0x11 => self.opMthi(instruction),
            0x12 => self.opMflo(instruction),
            0x13 => self.opMtlo(instruction),

            0x18 => self.opMult(instruction),
            0x19 => self.opMultu(instruction),

            0x1A => self.opDiv(instruction),
            0x1B => self.opDivu(instruction),

            0x20 => self.opAdd(instruction),
            0x21 => self.opAddu(instruction),

            0x22 => self.opSub(instruction),
            0x23 => self.opSubu(instruction),

            0x24 => self.opAnd(instruction),
            0x25 => self.opOr(instruction),
            0x26 => self.opXor(instruction),
            0x27 => self.opNor(instruction),

            0x2A => self.opSlt(instruction),
            0x2B => self.opSltu(instruction),

            0x01, 0x05, 0x0A...0x0B, 0x0E...0x0F, 0x14...0x17, 0x1C...0x1F, 0x28...0x29, 0x2C...0x3F => self.exception(.ReservedInstruction),

            else => std.log.warn("Unimplemented Special funct: 0x{X:0>2}", .{funct}),
        }
    }

    inline fn shift(self: *Self, instr: u32, comptime op: fn (u32, u5) u32) void {
        const d = decodeR(instr);

        self.writeReg(d.rd, op(self.readReg(d.rt), d.shamt));
    }

    inline fn shiftV(self: *Self, instr: u32, comptime op: fn (u32, u5) u32) void {
        const d = decodeR(instr);
        // Grab the value from register 'rs' and mask it to 5 bits (0-31)
        const shift_amount = @as(u5, @truncate(self.readReg(d.rs) & 0x1F));

        self.writeReg(d.rd, op(self.readReg(d.rt), shift_amount));
    }

    fn opJr(self: *Self, instruction: u32) void {
        const d = decodeR(instruction);
        const target = self.readReg(d.rs);

        self.next_pc = target;
    }

    fn opJalr(self: *Self, instruction: u32) void {
        const d = decodeR(instruction);
        const target = self.readReg(d.rs);
        const return_address = self.pc +% 4;

        self.writeReg(d.rd, return_address);
        self.next_pc = target;
    }

    fn opSyscall(self: *Self, _: u32) void {
        self.exception(.Syscall);
    }

    fn opBreak(self: *Self, _: u32) void {
        self.exception(.Breakpoint);
    }

    fn opAdd(self: *Self, instruction: u32) void {
        const d = decodeR(instruction);

        // Read the values as unsigned 32-bit
        const rs_val = self.readReg(d.rs);
        const rt_val = self.readReg(d.rt);

        // Cast them to signed integers for the math
        const rs_signed: i32 = @bitCast(rs_val);
        const rt_signed: i32 = @bitCast(rt_val);

        const result = @addWithOverflow(rs_signed, rt_signed);

        if (result[1] != 0) {
            self.exception(.ArithmeticOverflow);
        } else {
            self.writeReg(d.rd, @bitCast(result[0]));
        }
    }

    fn opAddu(self: *Self, instruction: u32) void {
        const d = decodeR(instruction);
        const rs_val = self.readReg(d.rs);
        const rt_val = self.readReg(d.rt);

        self.writeReg(d.rd, rs_val +% rt_val);
    }

    fn opSub(self: *Self, instruction: u32) void {
        const d = decodeR(instruction);
        const rs_val = self.readReg(d.rs);
        const rt_val = self.readReg(d.rt);
        const rs_signed: i32 = @bitCast(rs_val);
        const rt_signed: i32 = @bitCast(rt_val);

        const result = @subWithOverflow(rs_signed, rt_signed);

        if (result[1] != 0) {
            self.exception(.ArithmeticOverflow);
        } else {
            self.writeReg(d.rd, @bitCast(result[0]));
        }
    }

    fn opSubu(self: *Self, instruction: u32) void {
        const d = decodeR(instruction);
        const rs_val = self.readReg(d.rs);
        const rt_val = self.readReg(d.rt);

        self.writeReg(d.rd, rs_val -% rt_val);
    }

    // Move from Hi
    fn opMfhi(self: *Self, instruction: u32) void {
        const d = decodeR(instruction);

        self.writeReg(d.rd, self.hi);
    }

    // Move to Hi
    fn opMthi(self: *Self, instruction: u32) void {
        const d = decodeR(instruction);

        self.hi = self.readReg(d.rs);
    }

    fn opMflo(self: *Self, instruction: u32) void {
        const d = decodeR(instruction);

        self.writeReg(d.rd, self.lo);
    }

    fn opMtlo(self: *Self, instruction: u32) void {
        const d = decodeR(instruction);

        self.lo = self.readReg(d.rs);
    }

    fn opMult(self: *Self, instruction: u32) void {
        const d = decodeR(instruction);

        const rs_val = self.readReg(d.rs);
        const rt_val = self.readReg(d.rt);

        const rs_signed: i32 = @bitCast(rs_val);
        const rt_signed: i32 = @bitCast(rt_val);

        const rs_64: i64 = rs_signed;
        const rt_64: i64 = rt_signed;
        const result_64: i64 = rs_64 * rt_64;

        const result_u64: u64 = @bitCast(result_64);

        self.lo = @as(u32, @truncate(result_u64 & 0xFFFFFFFF));
        self.hi = @as(u32, @truncate(result_u64 >> 32));
    }

    fn opMultu(self: *Self, instruction: u32) void {
        const d = decodeR(instruction);

        const rs_val = self.readReg(d.rs);
        const rt_val = self.readReg(d.rt);

        const rs_64: u64 = rs_val;
        const rt_64: u64 = rt_val;
        const result_64: u64 = rs_64 * rt_64;

        self.lo = @as(u32, @truncate(result_64 & 0xFFFFFFFF));
        self.hi = @as(u32, @truncate(result_64 >> 32));
    }

    fn opDiv(self: *Self, instruction: u32) void {
        const d = decodeR(instruction);

        const rs_val = self.readReg(d.rs);
        const rt_val = self.readReg(d.rt);

        const rs_signed: i32 = @bitCast(rs_val);
        const rt_signed: i32 = @bitCast(rt_val);

        if (rt_signed == 0) {
            // PS1 Divide by Zero Hardware Quirk (Signed)
            self.hi = rs_val;
            if (rs_signed >= 0) {
                self.lo = 0xFFFFFFFF;
            } else {
                self.lo = 1;
            }
        } else if (rs_val == 0x80000000 and rt_signed == -1) {
            // PS1 Signed Overflow Quirk (INT_MIN / -1)
            self.hi = 0;
            self.lo = 0x80000000;
        } else {
            // Normal Division
            self.lo = @bitCast(@divTrunc(rs_signed, rt_signed));
            self.hi = @bitCast(@rem(rs_signed, rt_signed));
        }
    }

    fn opDivu(self: *Self, instruction: u32) void {
        const d = decodeR(instruction);

        const rs_val = self.readReg(d.rs);
        const rt_val = self.readReg(d.rt);

        if (rt_val == 0) {
            self.hi = rs_val;
            self.lo = 0xFFFFFFFF;
        } else {
            self.lo = rs_val / rt_val;
            self.hi = rs_val % rt_val;
        }
    }

    fn opAnd(self: *Self, instruction: u32) void {
        const d = decodeR(instruction);
        const rs_val = self.readReg(d.rs);
        const rt_val = self.readReg(d.rt);

        self.writeReg(d.rd, rs_val & rt_val);
    }

    fn opOr(self: *Self, instruction: u32) void {
        const d = decodeR(instruction);
        const rs_val = self.readReg(d.rs);
        const rt_val = self.readReg(d.rt);

        self.writeReg(d.rd, rs_val | rt_val);
    }

    fn opXor(self: *Self, instruction: u32) void {
        const d = decodeR(instruction);
        const rs_val = self.readReg(d.rs);
        const rt_val = self.readReg(d.rt);

        self.writeReg(d.rd, rs_val ^ rt_val);
    }

    fn opNor(self: *Self, instruction: u32) void {
        const d = decodeR(instruction);
        const rs_val = self.readReg(d.rs);
        const rt_val = self.readReg(d.rt);

        self.writeReg(d.rd, ~(rs_val | rt_val));
    }

    // slt   rd,rs,rt  if rs<rt (signed comparison) then rd=1 else rd=0
    fn opSlt(self: *Self, instruction: u32) void {
        const d = decodeR(instruction);
        const rs_val = self.readReg(d.rs);
        const rt_val = self.readReg(d.rt);

        const rs_signed: i32 = @bitCast(rs_val);
        const rt_signed: i32 = @bitCast(rt_val);

        self.writeReg(d.rd, if (rs_signed < rt_signed) 1 else 0);
    }

    // sltu  rd,rs,rt  if rs<rt (unsigned comparison) then rd=1 else rd=0
    fn opSltu(self: *Self, instruction: u32) void {
        const d = decodeR(instruction);
        const rs_val = self.readReg(d.rs);
        const rt_val = self.readReg(d.rt);

        self.writeReg(d.rd, if (rs_val < rt_val) 1 else 0);
    }

    // slti  rt,rs,imm if rs < sign_extended(imm) (signed) then rt=1 else rt=0
    fn opSlti(self: *Self, instruction: u32) void {
        const i = decodeI(instruction);
        const rs_val: i32 = @bitCast(self.readReg(i.rs));
        const imm_signed: i32 = @as(i16, @bitCast(i.imm));

        self.writeReg(i.rt, if (rs_val < imm_signed) 1 else 0);
    }

    // sltiu rt,rs,imm if rs < sign_extended(imm) (unsigned) then rt=1 else rt=0
    fn opSltiu(self: *Self, instruction: u32) void {
        const i = decodeI(instruction);
        const rs_val = self.readReg(i.rs);
        const imm_signed: i32 = @as(i16, @bitCast(i.imm));
        const imm_unsigned: u32 = @bitCast(imm_signed);

        self.writeReg(i.rt, if (rs_val < imm_unsigned) 1 else 0);
    }

    pub fn exception(self: *Self, code: Exception) void {
        self.epc = self.pc -% 4;
        // Bits [6:2] of cause = exception code
        self.cause = (@intFromEnum(code) << 2);

        // Shift SR mode stack (User/Kernel mode bits)
        const mode_bits = self.sr & 0x3F;
        self.sr &= ~@as(u32, 0x3F);
        self.sr |= (mode_bits << 2) & 0x3F;

        // Vector jump
        self.pc = if ((self.sr >> 22) & 1 == 1) 0xBFC00180 else 0x80000080;
        self.next_pc = self.pc +% 4;
    }
};

/// MIPS R3000A Register indices (ABI names)
pub const Reg = enum(u5) {
    zero = 0,
    at = 1,
    v0 = 2,
    v1 = 3,
    a0 = 4,
    a1 = 5,
    a2 = 6,
    a3 = 7,
    t0 = 8,
    t1 = 9,
    t2 = 10,
    t3 = 11,
    t4 = 12,
    t5 = 13,
    t6 = 14,
    t7 = 15,
    s0 = 16,
    s1 = 17,
    s2 = 18,
    s3 = 19,
    s4 = 20,
    s5 = 21,
    s6 = 22,
    s7 = 23,
    t8 = 24,
    t9 = 25,
    k0 = 26,
    k1 = 27,
    gp = 28,
    sp = 29,
    fp = 30,
    ra = 31,
};
