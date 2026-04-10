const std = @import("std");
const alu = @import("alu.zig");
const Bus = @import("bus.zig").Bus;

pub const Cpu = struct {
    const Self = @This();

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

    fn execute(self: *Self, instruction: u32) void {
        const opcode = @as(u6, @truncate(instruction >> 26));
        switch (opcode) {
            0x00 => self.special(instruction),
            0x02 => self.j(instruction),
            0x14...0x1F, 0x27, 0x2C, 0x2D, 0x2F, 0x34...0x37, 0x3C...0x3F => {
                // On a real PS1, this triggers a Reserved Instruction Exception
                self.exception(.ReservedInstruction);
            },

            else => {
                std.log.warn("Unimplemented Opcode: 0x{X:0>2}", .{opcode});
            },
        }
    }

    pub fn special(self: *Self, instruction: u32) void {
        const funct = @as(u6, @truncate(instruction & 0x3F));
        switch (funct) {
            0x00 => self.op_sll(instruction),
            0x02 => self.op_srl(instruction),
            0x01, 0x05, 0x0A...0x0B, 0x0E...0x0F, 0x14...0x17, 0x1C...0x1F, 0x28...0x29, 0x2C...0x3F => self.exception(.ReservedInstruction),
        }
    }

    fn op_sll(self: *Self, instr: u32) void {
        const rt_val = self.readReg((instr >> 16) & 0x1F);
        const rd = @as(u5, @truncate((instr >> 11) & 0x1F));
        const shamt = @as(u5, @truncate((instr >> 6) & 0x1F));

        const result = alu.sll(rt_val, shamt);
        self.writeReg(rd, result);
    }

    fn op_srl(self: *Self, instr: u32) void {
        const rt_val = self.readReg((instr >> 16) & 0x1F);
        const rd = @as(u5, @truncate((instr >> 11) & 0x1F));
        const shamt = @as(u5, @truncate((instr >> 6) & 0x1F));

        const result = alu.srl(rt_val, shamt);
        self.writeReg(rd, result);
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
