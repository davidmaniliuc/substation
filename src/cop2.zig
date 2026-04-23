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

    const unr_table = [257]u8{
        0xFF, 0xFD, 0xFB, 0xF9, 0xF7, 0xF5, 0xF3, 0xF1, 0xEF, 0xEE, 0xEC, 0xEA, 0xE8, 0xE6, 0xE4, 0xE3,
        0xE1, 0xDF, 0xDD, 0xDC, 0xDA, 0xD8, 0xD6, 0xD5, 0xD3, 0xD1, 0xD0, 0xCE, 0xCD, 0xCB, 0xC9, 0xC8,
        0xC6, 0xC5, 0xC3, 0xC2, 0xC0, 0xBF, 0xBD, 0xBC, 0xBA, 0xB9, 0xB7, 0xB6, 0xB4, 0xB3, 0xB2, 0xB0,
        0xAF, 0xAE, 0xAC, 0xAB, 0xAA, 0xA8, 0xA7, 0xA6, 0xA4, 0xA3, 0xA2, 0xA0, 0x9F, 0x9E, 0x9D, 0x9B,
        0x9A, 0x99, 0x98, 0x96, 0x95, 0x94, 0x93, 0x91, 0x90, 0x8F, 0x8E, 0x8D, 0x8C, 0x8A, 0x89, 0x88,
        0x87, 0x86, 0x85, 0x84, 0x82, 0x81, 0x80, 0x7F, 0x7E, 0x7D, 0x7C, 0x7B, 0x7A, 0x79, 0x78, 0x77,
        0x76, 0x75, 0x74, 0x73, 0x72, 0x71, 0x70, 0x6F, 0x6E, 0x6D, 0x6C, 0x6B, 0x6A, 0x69, 0x68, 0x67,
        0x66, 0x65, 0x64, 0x63, 0x62, 0x61, 0x60, 0x5F, 0x5E, 0x5D, 0x5C, 0x5B, 0x5A, 0x59, 0x58, 0x57,
        0x56, 0x55, 0x55, 0x54, 0x53, 0x52, 0x51, 0x50, 0x4F, 0x4E, 0x4D, 0x4D, 0x4C, 0x4B, 0x4A, 0x49,
        0x48, 0x48, 0x47, 0x46, 0x45, 0x44, 0x43, 0x43, 0x42, 0x41, 0x40, 0x3F, 0x3F, 0x3E, 0x3D, 0x3C,
        0x3C, 0x3B, 0x3A, 0x39, 0x39, 0x38, 0x37, 0x36, 0x36, 0x35, 0x34, 0x33, 0x33, 0x32, 0x31, 0x31,
        0x30, 0x2F, 0x2E, 0x2E, 0x2D, 0x2C, 0x2C, 0x2B, 0x2A, 0x2A, 0x29, 0x28, 0x28, 0x27, 0x26, 0x26,
        0x25, 0x24, 0x24, 0x23, 0x22, 0x22, 0x21, 0x20, 0x20, 0x1F, 0x1E, 0x1E, 0x1D, 0x1D, 0x1C, 0x1B,
        0x1B, 0x1A, 0x19, 0x19, 0x18, 0x18, 0x17, 0x16, 0x16, 0x15, 0x15, 0x14, 0x14, 0x13, 0x12, 0x12,
        0x11, 0x11, 0x10, 0x0F, 0x0F, 0x0E, 0x0E, 0x0D, 0x0D, 0x0C, 0x0C, 0x0B, 0x0A, 0x0A, 0x09, 0x09,
        0x08, 0x08, 0x07, 0x07, 0x06, 0x06, 0x05, 0x05, 0x04, 0x04, 0x03, 0x03, 0x02, 0x02, 0x01, 0x01,
        0x00,
    };

    pub fn init() Self {
        return .{};
    }

    fn divide(self: *Self, h: u16, sz: u16) u32 {
        if (sz == 0) return 0x1FFFF;

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
            0x30 => self.opRtpt(sf, lm),
            else => {
                std.log.warn("Unimplemented GTE command: 0x{X:0>2}", .{command});
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
        const r0 = self.ctrl_regs[0];
        const r1 = self.ctrl_regs[1];
        const r2 = self.ctrl_regs[2];
        const r3 = self.ctrl_regs[3];
        const r4 = self.ctrl_regs[4];
        m[0][0] = @as(i16, @bitCast(@as(u16, @truncate(r0))));
        m[0][1] = @as(i16, @bitCast(@as(u16, @truncate(r0 >> 16))));
        m[0][2] = @as(i16, @bitCast(@as(u16, @truncate(r1))));
        m[1][0] = @as(i16, @bitCast(@as(u16, @truncate(r1 >> 16))));
        m[1][1] = @as(i16, @bitCast(@as(u16, @truncate(r2))));
        m[1][2] = @as(i16, @bitCast(@as(u16, @truncate(r2 >> 16))));
        m[2][0] = @as(i16, @bitCast(@as(u16, @truncate(r3))));
        m[2][1] = @as(i16, @bitCast(@as(u16, @truncate(r3 >> 16))));
        m[2][2] = @as(i16, @bitCast(@as(u16, @truncate(r4))));

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

        const ir1 = @as(i64, @as(i16, @bitCast(@as(u16, @truncate(self.data_regs[9])))));
        const ir2 = @as(i64, @as(i16, @bitCast(@as(u16, @truncate(self.data_regs[10])))));

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
        const sx2 = self.saturateSxy(x, 14); // flag bit 14 for X
        const sy2 = self.saturateSxy(y, 13); // flag bit 13 for Y

        self.data_regs[14] = (@as(u32, sy2) << 16) | @as(u32, sx2);
    }

    fn opRtps(self: *Self, sf: u6, lm: bool) void {
        const vx0 = @as(i64, @as(i16, @bitCast(@as(u16, @truncate(self.data_regs[0])))));
        const vy0 = @as(i64, @as(i16, @bitCast(@as(u16, @truncate(self.data_regs[0] >> 16)))));
        const vz0 = @as(i64, @as(i16, @bitCast(@as(u16, @truncate(self.data_regs[1])))));

        self.doPerspectiveTransform(vx0, vy0, vz0, sf, lm);
    }

    fn opRtpt(self: *Self, sf: u6, lm: bool) void {
        var j: usize = 0;
        while (j < 3) : (j += 1) {
            const base = j * 2;
            const vxy = self.data_regs[base];
            const vz = self.data_regs[base + 1];
            const vx = @as(i64, @as(i16, @bitCast(@as(u16, @truncate(vxy)))));
            const vy = @as(i64, @as(i16, @bitCast(@as(u16, @truncate(vxy >> 16)))));
            const vz_val = @as(i64, @as(i16, @bitCast(@as(u16, @truncate(vz)))));

            self.doPerspectiveTransform(vx, vy, vz_val, sf, lm);
        }
    }

    fn saturateSxy(self: *Self, val: i64, bit: u5) u16 {
        var res = val >> 12;
        if (res < -1024) {
            self.setFlag(bit);
            res = -1024;
        } else if (res > 1023) {
            self.setFlag(bit);
            res = 1023;
        }
        return @as(u16, @bitCast(@as(i16, @intCast(res))));
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
            const res = (@as(i64, m[i][0]) * v[0]) + (@as(i64, m[i][1]) * v[1]) + (@as(i64, m[i][2]) * v[2]);

            self.macs[i + 1] = (res >> sf) + @as(i64, tr[i]);
            self.checkMacOverflow(i + 1);
            self.saturateToIr(i + 1, self.macs[i + 1], lm);
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
