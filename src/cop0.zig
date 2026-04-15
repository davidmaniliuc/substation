pub const Cop0 = struct {
    const Self = @This();

    pub const Reg = enum(u5) {
        sr = 12,
        cause = 13,
        epc = 14,
        prid = 15,
    };

    // COP0 has 32 data registers (though not all are used on the PSX)
    regs: [32]u32 = [_]u32{0} ** 32,

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
            @intFromEnum(Reg.sr) => self.regs[@intFromEnum(Reg.sr)] = value,
            @intFromEnum(Reg.cause) => {
                const mask: u32 = 0x00000300;
                self.regs[@intFromEnum(Reg.cause)] =
                    (self.regs[@intFromEnum(Reg.cause)] & ~mask) | (value & mask);
            },
            @intFromEnum(Reg.prid) => {},
            else => self.regs[i] = value,
        }
    }

    pub fn setReg(self: *Self, index: anytype, value: u32) void {
        const i = getIdx(index);
        self.regs[i] = value;
    }

    pub fn rfe(self: *Self) void {
        const sr = self.regs[@intFromEnum(Reg.sr)];
        self.regs[@intFromEnum(Reg.sr)] = (sr & ~@as(u32, 0x0F)) | ((sr >> 2) & 0x0F);
    }

    inline fn getIdx(index: anytype) u5 {
        return switch (@typeInfo(@TypeOf(index))) {
            .int, .comptime_int => @as(u5, @truncate(index)),
            else => @intFromEnum(@as(Reg, index)),
        };
    }
};
