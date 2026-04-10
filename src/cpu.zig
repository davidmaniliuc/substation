const std = @import("std");
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
        _ = self;
        _ = instruction;
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
