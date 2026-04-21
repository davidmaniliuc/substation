pub const Cop2 = struct {
    const Self = @This();

    // GTE has 32 Data registers and 32 Control registers
    data_regs: [32]u32 = [_]u32{0} ** 32,
    ctrl_regs: [32]u32 = [_]u32{0} ** 32,

    pub fn init() Self {
        return .{};
    }

    // Move From/To Data Registers (MFC2 / MTC2)
    pub fn readData(self: *const Self, index: u5) u32 {
        return self.data_regs[index];
    }

    pub fn writeData(self: *Self, index: u5, value: u32) void {
        self.data_regs[index] = value;
    }

    // Move From/To Control Registers (CFC2 / CTC2)
    pub fn readCtrl(self: *const Self, index: u5) u32 {
        return self.ctrl_regs[index];
    }

    pub fn writeCtrl(self: *Self, index: u5, value: u32) void {
        self.ctrl_regs[index] = value;
    }
};
