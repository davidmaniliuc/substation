const std = @import("std");

pub const Cop0 = struct {
    const Self = @This();

    // COP0 has 32 data registers (though not all are used on the PSX)
    regs: [32]u32 = [_]u32{0} ** 32,

    pub fn init() Self {
        return .{};
    }

    pub fn readReg(self: *const Self, index: u5) u32 {
        return self.regs[index];
    }

    pub fn writeReg(self: *Self, index: u5, value: u32) void {
        self.regs[index] = value;
    }
};
