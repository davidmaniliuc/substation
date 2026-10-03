pub const std = @import("std");

pub const Cop0 = struct {
    const Self = @This();

    pub const Reg = enum(u5) {
        badvaddr = 8,
        sr = 12,
        cause = 13,
        epc = 14,
        prid = 15,
    };

    // COP0 has 32 data registers (though not all are used on the PSX)
    regs: [32]u32 = @splat(0),

    pub fn init() Self {
        return .{};
    }

    pub fn readReg(self: *const Self, index: anytype) u32 {
        const i = getIdx(index);
        return self.regs[i];
    }

    pub fn writeReg(self: *Self, index: anytype, value: u32) void {
        const i = getIdx(index);
        switch (i) {
            @backingInt(Reg.sr) => self.regs[@backingInt(Reg.sr)] = value,
            @backingInt(Reg.cause) => {
                const mask: u32 = 0x00000300;
                self.regs[@backingInt(Reg.cause)] =
                    (self.regs[@backingInt(Reg.cause)] & ~mask) | (value & mask);
            },
            @backingInt(Reg.prid) => {},
            else => self.regs[i] = value,
        }
    }

    pub fn setReg(self: *Self, index: anytype, value: u32) void {
        const i = getIdx(index);
        self.regs[i] = value;
    }

    pub fn rfe(self: *Self) void {
        const sr = self.regs[@backingInt(Reg.sr)];
        self.regs[@backingInt(Reg.sr)] = (sr & ~@as(u32, 0x0F)) | ((sr >> 2) & 0x0F);
    }

    inline fn getIdx(index: anytype) u5 {
        return switch (@typeInfo(@TypeOf(index))) {
            .int, .comptime_int => @as(u5, @truncate(index)),
            else => @backingInt(@as(Reg, index)),
        };
    }
};
