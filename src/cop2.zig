const std = @import("std");

pub const Cop2 = struct {
    const Self = @This();

    pub const DataReg = enum(u5) {
        // Vector 0, 1, 2
        vxy0 = 0,
        vz0 = 1,
        vxy1 = 2,
        vz1 = 3,
        vxy2 = 4,
        vz2 = 5,

        rgbc = 6, // Color/code value
        otz = 7, // Average Z value (for Ordering Table)

        ir0 = 8, // 16bit Accumulator (Interpolate)
        ir1 = 9,
        ir2 = 10,
        ir3 = 11, // 16bit Accumulator (Vector)

        // Screen XY-coordinate FIFO
        sxy0 = 12,
        sxy1 = 13,
        sxy2 = 14,
        sxyp = 15,

        // Screen Z-coordinate FIFO
        sz0 = 16,
        sz1 = 17,
        sz2 = 18,
        sz3 = 19,

        // Color CRGB-code/color FIFO
        rgb0 = 20,
        rgb1 = 21,
        rgb2 = 22,

        res1 = 23, // Prohibited / Reserved

        // 32bit Maths Accumulators
        mac0 = 24,
        mac1 = 25,
        mac2 = 26,
        mac3 = 27,

        // Convert RGB Color
        irgb = 28,
        orgb = 29,

        // Count Leading-Zeroes/Ones
        lzcs = 30,
        lzcr = 31,
    };

    pub const CtrlReg = enum(u5) {
        // Rotation matrix (3x3)
        rt11_rt12 = 0,
        rt13_rt21 = 1,
        rt22_rt23 = 2,
        rt31_rt32 = 3,
        rt33 = 4,

        // Translation vector (X,Y,Z)
        trx = 5,
        try_ = 6,
        trz = 7, // Note: 'try' is a reserved keyword in Zig!

        // Light source matrix (3x3)
        l11_l12 = 8,
        l13_l21 = 9,
        l22_l23 = 10,
        l31_l32 = 11,
        l33 = 12,

        // Background color (R,G,B)
        rbk = 13,
        gbk = 14,
        bbk = 15,

        // Light color matrix source (3x3)
        lr1_lr2 = 16,
        lr3_lg1 = 17,
        lg2_lg3 = 18,
        lb1_lb2 = 19,
        lb3 = 20,

        // Far color (R,G,B)
        rfc = 21,
        gfc = 22,
        bfc = 23,

        // Screen offset (X,Y)
        ofx = 24,
        ofy = 25,

        h = 26, // Projection plane distance
        dqa = 27, // Depth queuing parameter A (coeff)
        dqb = 28, // Depth queuing parameter B (offset)
        zsf3 = 29,
        zsf4 = 30, // Average Z scale factors
        flag = 31, // Returns any calculation errors
    };

    data_regs: [32]u32 = [_]u32{0} ** 32,
    ctrl_regs: [32]u32 = [_]u32{0} ** 32,
    macs: [4]i64 = [_]i64{0} ** 4,

    pub fn init() Self {
        return .{};
    }

    // Move From/To Data Registers (MFC2 / MTC2)
    pub fn readData(self: *const Self, index: anytype) u32 {
        const i = getDataIdx(index);
        return switch (i) {
            24...27 => @as(u32, @truncate(@as(u64, @bitCast(self.macs[i - 24])))),
            31 => self.data_regs[31], // lzcr
            else => self.data_regs[i],
        };
    }

    pub fn writeData(self: *Self, index: anytype, value: u32) void {
        const i = getDataIdx(index);
        self.data_regs[i] = value;

        switch (i) {
            1, 3, 5 => { // vz0, vz1, vz2: sign-extend from 16-bit to 32-bit
                self.data_regs[i] = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(value)))))));
            },
            8...11 => { // ir0...ir3: sign-extend from 16-bit to 32-bit
                self.data_regs[i] = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(value)))))));
            },
            15 => { // sxyp: write to sxy2 and shift fifo
                self.data_regs[12] = self.data_regs[13]; // sxy0 = sxy1
                self.data_regs[13] = self.data_regs[14]; // sxy1 = sxy2
                self.data_regs[14] = value; // sxy2 = new value
                self.data_regs[15] = value; // sxyp mirrors sxy2
            },
            24...27 => { // mac0...mac3: sign-extend from 32-bit to 44-bit internally
                self.macs[i - 24] = @as(i64, @as(i32, @bitCast(value)));
            },
            30 => { // lzcs: count leading zeros/ones
                const val = value;
                const result: u32 = if ((val >> 31) == 0)
                    @clz(val)
                else
                    @clz(~val);
                self.data_regs[31] = result;
            },
            else => {},
        }
    }

    // Move From/To Control Registers (CFC2 / CTC2)
    pub fn readCtrl(self: *const Self, index: anytype) u32 {
        return self.ctrl_regs[getCtrlIdx(index)];
    }

    pub fn writeCtrl(self: *Self, index: anytype, value: u32) void {
        const i = getCtrlIdx(index);

        switch (i) {
            0...30 => self.ctrl_regs[i] = value,
            31 => {
                // Writing to FLAG register clears bits 30..12 that are 1 in 'value'
                // But GTE spec also says some bits are just set.
                // Let's implement the "clear on write" behavior for bits 30..12.
                // Wait, actually many implementations just store it and update the error flag.
                self.ctrl_regs[31] = value & 0x7FFFF000;
                self.updateErrorFlag();
            },
        }
    }

    fn updateErrorFlag(self: *Self) void {
        const f = self.ctrl_regs[31];
        // Bit 31 is set if any of bits 30..23 or 18..13 are set.
        const error_bits = (f & 0x7F87E000) != 0;
        if (error_bits) {
            self.ctrl_regs[31] |= (1 << 31);
        } else {
            self.ctrl_regs[31] &= ~@as(u32, 1 << 31);
        }
    }

    pub fn setFlag(self: *Self, bit: u5) void {
        self.ctrl_regs[31] |= (@as(u32, 1) << bit);
        self.updateErrorFlag();
    }

    fn checkMacOverflow(self: *Self, i: usize) void {
        if (i < 1 or i > 3) return;
        const val = self.macs[i];
        if (val > 0x7FFFFFFF) {
            self.setFlag(@as(u5, @intCast(31 - i))); // 30, 29, 28
        } else if (val < -0x80000000) {
            self.setFlag(@as(u5, @intCast(28 - i))); // 27, 26, 25
        }
    }

    fn saturateToIr(self: *Self, i: usize, val: i64) void {
        if (i < 1 or i > 3) return;
        var res = val;
        if (val > 32767) {
            self.setFlag(@as(u5, @intCast(25 - i))); // 24, 23, 22
            res = 32767;
        } else if (val < -32768) {
            self.setFlag(@as(u5, @intCast(22 - i))); // 21, 20, 19
            res = -32768;
        }
        self.data_regs[8 + i] = @as(u32, @bitCast(@as(i32, @as(i16, @intCast(res)))));
    }

    pub fn executeCommand(self: *Self, instruction: u32) void {
        const command = instruction & 0x3F;

        // Extract global command parameters
        const sf = @as(u5, @truncate((instruction >> 19) & 1));
        const lm = @as(u5, @truncate((instruction >> 10) & 1));
        _ = sf;
        _ = lm;

        // Clear temporary error flags (bits 30..12 are cleared on new command)
        self.ctrl_regs[31] &= 0x80000000;

        switch (command) {
            0x06 => self.opNclip(),
            0x12 => self.opMvmva(instruction),
            else => {
                std.log.warn("Unimplemented GTE command: 0x{X:0>2}", .{command});
            },
        }
        self.updateErrorFlag();
    }

    fn opNclip(self: *Self) void {
        // Retrieve the 3 coordinates from the SXY FIFO
        const sxy0 = self.data_regs[12];
        const sxy1 = self.data_regs[13];
        const sxy2 = self.data_regs[14];

        // Extract X (bottom 16 bits) and Y (top 16 bits) as signed 16-bit integers
        const sx0 = @as(i64, @as(i16, @bitCast(@as(u16, @truncate(sxy0)))));
        const sy0 = @as(i64, @as(i16, @bitCast(@as(u16, @truncate(sxy0 >> 16)))));

        const sx1 = @as(i64, @as(i16, @bitCast(@as(u16, @truncate(sxy1)))));
        const sy1 = @as(i64, @as(i16, @bitCast(@as(u16, @truncate(sxy1 >> 16)))));

        const sx2 = @as(i64, @as(i16, @bitCast(@as(u16, @truncate(sxy2)))));
        const sy2 = @as(i64, @as(i16, @bitCast(@as(u16, @truncate(sxy2 >> 16)))));

        // Perform the cross product: MAC0 = SX0*SY1 + SX1*SY2 + SX2*SY0 - SX0*SY2 - SX1*SY0 - SX2*SY1
        const term1 = sx0 * sy1;
        const term2 = sx1 * sy2;
        const term3 = sx2 * sy0;
        const term4 = sx0 * sy2;
        const term5 = sx1 * sy0;
        const term6 = sx2 * sy1;

        const result = term1 + term2 + term3 - term4 - term5 - term6;

        // Store in MAC0 (Data Register 24). NCLIP doesn't saturate MAC0, but we do need to check 31-bit overflow.
        self.macs[0] = result;

        if (result > 0x7FFFFFFF) {
            self.setFlag(16); // MAC0 positive overflow
        } else if (result < -0x80000000) {
            self.setFlag(15); // MAC0 negative overflow
        }
    }

    fn opMvmva(self: *Self, instr: u32) void {
        const matrix_id = (instr >> 13) & 0x3;
        const vector_id = (instr >> 15) & 0x3;
        const trans_id = (instr >> 17) & 0x3;
        const shift = if (((instr >> 19) & 1) == 1) @as(u6, 12) else @as(u6, 0);

        // Matrix elements: i16
        var m: [3][3]i16 = undefined;
        const matrix_base = switch (matrix_id) {
            0 => @as(u5, 0), // rt
            1 => @as(u5, 8), // l
            2 => @as(u5, 16), // lr
            else => {
                std.log.warn("MVMVA with invalid matrix {}", .{matrix_id});
                return;
            },
        };

        // Row 0
        const r0 = self.ctrl_regs[matrix_base + 0];
        const r1 = self.ctrl_regs[matrix_base + 1];
        m[0][0] = @as(i16, @bitCast(@as(u16, @truncate(r0))));
        m[0][1] = @as(i16, @bitCast(@as(u16, @truncate(r0 >> 16))));
        m[0][2] = @as(i16, @bitCast(@as(u16, @truncate(r1))));

        // Row 1
        const r2 = self.ctrl_regs[matrix_base + 2];
        m[1][0] = @as(i16, @bitCast(@as(u16, @truncate(r1 >> 16))));
        m[1][1] = @as(i16, @bitCast(@as(u16, @truncate(r2))));
        m[1][2] = @as(i16, @bitCast(@as(u16, @truncate(r2 >> 16))));

        // Row 2
        const r3 = self.ctrl_regs[matrix_base + 3];
        const r4 = self.ctrl_regs[matrix_base + 4];
        m[2][0] = @as(i16, @bitCast(@as(u16, @truncate(r3))));
        m[2][1] = @as(i16, @bitCast(@as(u16, @truncate(r3 >> 16))));
        m[2][2] = @as(i16, @bitCast(@as(u16, @truncate(r4))));

        // Vector: v0, v1, v2 (Data 0, 2, 4) or ir (Data 8, 9, 10)
        // Wait, IR registers are DataReg 8, 9, 10, 11 (ir0, ir1, ir2, ir3)
        // Vector ir is usually ir1, ir2, ir3.
        const v: [3]i16 = if (vector_id < 3) blk: {
            const base = vector_id * 2;
            const vxy = self.data_regs[base];
            const vz = self.data_regs[base + 1];
            break :blk .{
                @as(i16, @bitCast(@as(u16, @truncate(vxy)))),
                @as(i16, @bitCast(@as(u16, @truncate(vxy >> 16)))),
                @as(i16, @bitCast(@as(u16, @truncate(vz)))),
            };
        } else blk: {
            break :blk .{
                @as(i16, @bitCast(@as(u16, @truncate(self.data_regs[9])))), // ir1
                @as(i16, @bitCast(@as(u16, @truncate(self.data_regs[10])))), // ir2
                @as(i16, @bitCast(@as(u16, @truncate(self.data_regs[11])))), // ir3
            };
        };

        // Translation: TR, BK, FC or None (Ctrl 5, 13, 21)
        const tr: [3]i32 = if (trans_id < 3) blk: {
            const base = 5 + (trans_id * 8);
            break :blk .{
                @as(i32, @bitCast(self.ctrl_regs[base])),
                @as(i32, @bitCast(self.ctrl_regs[base + 1])),
                @as(i32, @bitCast(self.ctrl_regs[base + 2])),
            };
        } else .{ 0, 0, 0 };

        // Perform Multiplication
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            // mac = (matrix_row * vector) + (trans << 12)
            // Intermediate results are 44-bit
            const res = (@as(i64, m[i][0]) * v[0]) + (@as(i64, m[i][1]) * v[1]) + (@as(i64, m[i][2]) * v[2]);

            self.macs[i + 1] = (res >> shift) + @as(i64, tr[i]);
            self.checkMacOverflow(i + 1);
            self.saturateToIr(i + 1, self.macs[i + 1]);
        }
    }

    inline fn getDataIdx(index: anytype) u5 {
        return switch (@typeInfo(@TypeOf(index))) {
            .int, .comptime_int => @as(u5, @truncate(index)),
            else => @intFromEnum(@as(DataReg, index)),
        };
    }

    inline fn getCtrlIdx(index: anytype) u5 {
        return switch (@typeInfo(@TypeOf(index))) {
            .int, .comptime_int => @as(u5, @truncate(index)),
            else => @intFromEnum(@as(CtrlReg, index)),
        };
    }
};
