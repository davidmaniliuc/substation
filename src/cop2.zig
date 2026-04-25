const std = @import("std");

pub const Cop2 = struct {
    const Self = @This();

    pub const Point2D = packed struct(u32) {
        x: i16,
        y: i16,
    };

    pub const DualI16 = packed struct(u32) {
        low: i16,
        high: i16,
    };

    pub const ColorCode = packed struct(u32) {
        r: u8, // Bits 0-7
        g: u8, // Bits 8-15
        b: u8, // Bits 16-23
        code: u8, // Bits 24-31 (usually the GPU command)
    };

    pub const GteFlags = packed struct(u32) {
        _reserved: u12 = 0, // Bits 0-11
        ir0_sat: bool, // Bit 12
        sy2_sat: bool, // Bit 13
        sx2_sat: bool, // Bit 14
        mac0_neg: bool, // Bit 15
        mac0_pos: bool, // Bit 16
        divide_ovf: bool, // Bit 17
        sz3_sat: bool, // Bit 18
        b_sat: bool, // Bit 19
        g_sat: bool, // Bit 20
        r_sat: bool, // Bit 21
        ir3_sat: bool, // Bit 22
        ir2_sat: bool, // Bit 23
        ir1_sat: bool, // Bit 24
        mac3_neg: bool, // Bit 25
        mac2_neg: bool, // Bit 26
        mac1_neg: bool, // Bit 27
        mac3_pos: bool, // Bit 28
        mac2_pos: bool, // Bit 29
        mac1_pos: bool, // Bit 30
        error_flag: bool, // Bit 31
    };

    inline fn signExtend16(val: u16) u32 {
        return @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(val)))));
    }

    inline fn asI16(val: u32) i16 {
        return @bitCast(@as(u16, @truncate(val)));
    }

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

    fn divide(self: *Self, h: u16, sz: u16) u32 {
        if (sz == 0) {
            self.setFlag(17);
            return 0x1FFFF;
        }

        const res = (@as(u64, h) << 12) / sz;

        if (res > 0x1FFFF) {
            self.setFlag(17);
            return 0x1FFFF;
        }
        return @as(u32, @truncate(res));
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
                self.data_regs[i] = signExtend16(@as(u16, @truncate(value)));
            },
            8...11 => { // ir0...ir3: sign-extend from 16-bit to 32-bit
                self.data_regs[i] = signExtend16(@as(u16, @truncate(value)));
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
        var f = @as(GteFlags, @bitCast(self.ctrl_regs[31]));
        // Bit 31 is set if any of bits 30..23 or 18..13 are set.
        const error_bits = (self.ctrl_regs[31] & 0x7F87E000) != 0;
        f.error_flag = error_bits;
        self.ctrl_regs[31] = @as(u32, @bitCast(f));
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

    fn saturateToIr(self: *Self, i: usize, val: i64, lm: bool) void {
        if (i < 1 or i > 3) return;
        var res = val;
        const min: i64 = if (lm) 0 else -32768;
        const max: i64 = 32767;

        if (val > max) {
            self.setFlag(@as(u5, @intCast(25 - i))); // 24, 23, 22
            res = max;
        } else if (val < min) {
            self.setFlag(@as(u5, @intCast(22 - i))); // 21, 20, 19
            res = min;
        }
        self.data_regs[8 + i] = @as(u32, @bitCast(@as(i32, @as(i16, @intCast(res)))));
    }

    pub fn executeCommand(self: *Self, instruction: u32) void {
        const command = instruction & 0x3F;

        // Extract global command parameters
        const sf = @as(u6, @truncate((instruction >> 19) & 1)) * 12;
        const lm = ((instruction >> 10) & 1) != 0;

        // Clear temporary error flags (bits 30..12 are cleared on new command)
        self.ctrl_regs[31] &= 0x80000000;

        switch (command) {
            0x01 => self.opRtps(sf, lm),
            0x06 => self.opNclip(),
            0x12 => self.opMvmva(instruction, sf, lm),
            0x28 => self.opSqr(sf, lm),         // Added SQR
            0x2D => self.opAvsz(false),         // Added AVSZ3
            0x2E => self.opAvsz(true),          // Added AVSZ4
            0x30 => self.opRtpt(sf, lm),
            else => {
                std.log.warn("Unimplemented GTE command: 0x{X:0>2} (Full Inst: 0x{X:0>8})", .{command, instruction});
            },
        }
        self.updateErrorFlag();
    }

    fn doPerspectiveTransform(self: *Self, vx: i64, vy: i64, vz: i64, sf: u6, lm: bool) void {
        const tr = [3]i32{
            @as(i32, @bitCast(self.ctrl_regs[5])),
            @as(i32, @bitCast(self.ctrl_regs[6])),
            @as(i32, @bitCast(self.ctrl_regs[7])),
        };

        // Matrix RT
        var m: [3][3]i16 = undefined;
        const d0 = @as(DualI16, @bitCast(self.ctrl_regs[0]));
        const d1 = @as(DualI16, @bitCast(self.ctrl_regs[1]));
        const d2 = @as(DualI16, @bitCast(self.ctrl_regs[2]));
        const d3 = @as(DualI16, @bitCast(self.ctrl_regs[3]));
        const d4 = @as(DualI16, @bitCast(self.ctrl_regs[4]));
        m[0][0] = d0.low;
        m[0][1] = d0.high;
        m[0][2] = d1.low;
        m[1][0] = d1.high;
        m[1][1] = d2.low;
        m[1][2] = d2.high;
        m[2][0] = d3.low;
        m[2][1] = d3.high;
        m[2][2] = d4.low;

        var i: usize = 0;
        while (i < 3) : (i += 1) {
            const res = (@as(i64, m[i][0]) * vx) + (@as(i64, m[i][1]) * vy) + (@as(i64, m[i][2]) * vz);
            self.macs[i + 1] = (res >> sf) + @as(i64, tr[i]);
            self.checkMacOverflow(i + 1);
            self.saturateToIr(i + 1, self.macs[i + 1], lm);
        }

        // SZ FIFO Shift
        self.data_regs[16] = self.data_regs[17]; // sz0 = sz1
        self.data_regs[17] = self.data_regs[18]; // sz1 = sz2
        self.data_regs[18] = self.data_regs[19]; // sz2 = sz3

        // SZ3 = MAC3 saturated to 0..FFFF
        var sz3 = self.macs[3];
        if (sz3 < 0) {
            self.setFlag(18);
            sz3 = 0;
        } else if (sz3 > 0xFFFF) {
            self.setFlag(18);
            sz3 = 0xFFFF;
        }
        self.data_regs[19] = @as(u32, @intCast(sz3));

        // Projection
        const h = @as(u16, @truncate(self.ctrl_regs[26]));
        const div = self.divide(h, @as(u16, @intCast(sz3)));

        const ofx = @as(i32, @bitCast(self.ctrl_regs[24]));
        const ofy = @as(i32, @bitCast(self.ctrl_regs[25]));

        const ir1 = @as(i64, asI16(self.data_regs[9]));
        const ir2 = @as(i64, asI16(self.data_regs[10]));

        const x = (ir1 * div) + @as(i64, ofx);
        const y = (ir2 * div) + @as(i64, ofy);

        self.macs[1] = x;
        self.macs[2] = y;
        self.checkMacOverflow(1);
        self.checkMacOverflow(2);

        // SXY FIFO Shift
        self.data_regs[12] = self.data_regs[13]; // sxy0 = sxy1
        self.data_regs[13] = self.data_regs[14]; // sxy1 = sxy2

        // Saturate X and Y to -1024..1023
        const sxy2 = Point2D{
            .x = self.saturateSxy(x, 14), // flag bit 14 for X
            .y = self.saturateSxy(y, 13), // flag bit 13 for Y
        };

        self.data_regs[14] = @as(u32, @bitCast(sxy2));
    }

    fn opRtps(self: *Self, sf: u6, lm: bool) void {
        const p = @as(Point2D, @bitCast(self.data_regs[0]));
        const vz = self.data_regs[1];
        const vx0 = @as(i64, p.x);
        const vy0 = @as(i64, p.y);
        const vz0 = @as(i64, asI16(vz));

        self.doPerspectiveTransform(vx0, vy0, vz0, sf, lm);
    }

    fn opRtpt(self: *Self, sf: u6, lm: bool) void {
        var j: usize = 0;
        while (j < 3) : (j += 1) {
            const base = j * 2;
            const p = @as(Point2D, @bitCast(self.data_regs[base]));
            const vz = self.data_regs[base + 1];
            const vx = @as(i64, p.x);
            const vy = @as(i64, p.y);
            const vz_val = @as(i64, asI16(vz));

            self.doPerspectiveTransform(vx, vy, vz_val, sf, lm);
        }
    }

    fn saturateSxy(self: *Self, val: i64, bit: u5) i16 {
        var res = val >> 12;
        if (res < -1024) {
            self.setFlag(bit);
            res = -1024;
        } else if (res > 1023) {
            self.setFlag(bit);
            res = 1023;
        }
        return @as(i16, @intCast(res));
    }

    fn opNclip(self: *Self) void {
        // Cast the raw 32-bit registers directly to our packed struct
        const p0 = @as(Point2D, @bitCast(self.data_regs[12]));
        const p1 = @as(Point2D, @bitCast(self.data_regs[13]));
        const p2 = @as(Point2D, @bitCast(self.data_regs[14]));

        const sx0 = @as(i64, p0.x);
        const sy0 = @as(i64, p0.y);
        const sx1 = @as(i64, p1.x);
        const sy1 = @as(i64, p1.y);
        const sx2 = @as(i64, p2.x);
        const sy2 = @as(i64, p2.y);

        // Perform the cross product: MAC0 = SX0*SY1 + SX1*SY2 + SX2*SY0 - SX0*SY2 - SX1*SY0 - SX2*SY1
        const result = (sx0 * sy1) + (sx1 * sy2) + (sx2 * sy0) -
            (sx0 * sy2) - (sx1 * sy0) - (sx2 * sy1);

        // Store in MAC0 (Data Register 24). NCLIP doesn't saturate MAC0, but we do need to check 31-bit overflow.
        self.macs[0] = result;

        if (result > 0x7FFFFFFF) {
            self.setFlag(16); // MAC0 positive overflow
        } else if (result < -0x80000000) {
            self.setFlag(15); // MAC0 negative overflow
        }
    }

    fn opMvmva(self: *Self, instr: u32, sf: u6, lm: bool) void {
        const matrix_id = (instr >> 13) & 0x3;
        const vector_id = (instr >> 15) & 0x3;
        const trans_id = (instr >> 17) & 0x3;

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

        const d0 = @as(DualI16, @bitCast(self.ctrl_regs[matrix_base + 0]));
        const d1 = @as(DualI16, @bitCast(self.ctrl_regs[matrix_base + 1]));
        const d2 = @as(DualI16, @bitCast(self.ctrl_regs[matrix_base + 2]));
        const d3 = @as(DualI16, @bitCast(self.ctrl_regs[matrix_base + 3]));
        const d4 = @as(DualI16, @bitCast(self.ctrl_regs[matrix_base + 4]));
        m[0][0] = d0.low;
        m[0][1] = d0.high;
        m[0][2] = d1.low;
        m[1][0] = d1.high;
        m[1][1] = d2.low;
        m[1][2] = d2.high;
        m[2][0] = d3.low;
        m[2][1] = d3.high;
        m[2][2] = d4.low;

        // Vector: v0, v1, v2 (Data 0, 2, 4) or ir (Data 8, 9, 10)
        const v: [3]i16 = if (vector_id < 3) blk: {
            const base = vector_id * 2;
            const p = @as(Point2D, @bitCast(self.data_regs[base]));
            const vz = self.data_regs[base + 1];
            break :blk .{
                p.x,
                p.y,
                asI16(vz),
            };
        } else blk: {
            break :blk .{
                asI16(self.data_regs[9]), // ir1
                asI16(self.data_regs[10]), // ir2
                asI16(self.data_regs[11]), // ir3
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
            const res = (@as(i64, m[i][0]) * v[0]) + (@as(i64, m[i][1]) * v[1]) + (@as(i64, m[i][2]) * v[2]);

            self.macs[i + 1] = (res >> sf) + @as(i64, tr[i]);
            self.checkMacOverflow(i + 1);
            self.saturateToIr(i + 1, self.macs[i + 1], lm);
        }
    }

    fn opSqr(self: *Self, sf: u6, lm: bool) void {
        const ir1 = @as(i64, asI16(self.data_regs[9]));
        const ir2 = @as(i64, asI16(self.data_regs[10]));
        const ir3 = @as(i64, asI16(self.data_regs[11]));

        // Square and shift
        self.macs[1] = (ir1 * ir1) >> sf;
        self.macs[2] = (ir2 * ir2) >> sf;
        self.macs[3] = (ir3 * ir3) >> sf;

        // Check overflows and saturate back to IR
        self.checkMacOverflow(1);
        self.checkMacOverflow(2);
        self.checkMacOverflow(3);

        self.saturateToIr(1, self.macs[1], lm);
        self.saturateToIr(2, self.macs[2], lm);
        self.saturateToIr(3, self.macs[3], lm);
    }

    fn opAvsz(self: *Self, is_sz4: bool) void {
        // SZ FIFO uses 16-bit values, but they are unsigned for Z-depth
        const sz1 = @as(u32, @truncate(self.data_regs[17]));
        const sz2 = @as(u32, @truncate(self.data_regs[18]));
        const sz3 = @as(u32, @truncate(self.data_regs[19]));

        // ZSF3 and ZSF4 are 16-bit signed scale factors
        const zsf3 = @as(i64, asI16(self.ctrl_regs[29]));
        const zsf4 = @as(i64, asI16(self.ctrl_regs[30]));

        var sum: u32 = sz1 + sz2 + sz3;
        var zsf: i64 = zsf3;

        if (is_sz4) {
            const sz0 = @as(u32, @truncate(self.data_regs[16]));
            sum += sz0;
            zsf = zsf4;
        }

        // MAC0 = ZSF * Sum
        const mac0 = zsf * @as(i64, sum);
        self.macs[0] = mac0;

        // Overflow checks for MAC0
        if (mac0 > 0x7FFFFFFF) {
            self.setFlag(16); // MAC0 positive overflow
        } else if (mac0 < -0x80000000) {
            self.setFlag(15); // MAC0 negative overflow
        }

        // OTZ = MAC0 >> 12 (Divided by 4096)
        var otz = mac0 >> 12;

        // OTZ is saturated to 0..FFFF 
        if (otz < 0) {
            otz = 0;
            self.setFlag(18); // SZ3 / OTZ saturation flag
        } else if (otz > 0xFFFF) {
            otz = 0xFFFF;
            self.setFlag(18); // SZ3 / OTZ saturation flag
        }

        self.data_regs[7] = @as(u32, @intCast(otz)); // Write to OTZ register
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
