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

    /// Reciprocal seed table for the UNR division (Avocado gte.cpp:11).
    const unr_table = blk: {
        @setEvalBranchQuota(10000);
        var table: [0x101]u8 = undefined;
        for (&table, 0..) |*entry, i| {
            const v = @divTrunc(@divTrunc(0x40000, @as(i32, @intCast(i)) + 0x100) + 1, 2) - 0x101;
            entry.* = if (v < 0) 0 else @as(u8, @intCast(v));
        }
        break :blk table;
    };

    fn recip(divisor: u16) i64 {
        const x: i32 = 0x101 + @as(i32, unr_table[((@as(u32, divisor) & 0x7FFF) + 0x40) >> 7]);
        const tmp: i32 = ((@as(i32, divisor) * -x) + 0x80) >> 8;
        return @as(i64, (x * (131072 + tmp)) + 0x80) >> 8;
    }

    /// Newton-Raphson (UNR) division, exactly as the GTE does it
    /// (Avocado opcodes.cpp:291). The result carries 16 fractional bits and may
    /// legally reach 1FFFFh, i.e. a H/SZ3 ratio just under 2.0.
    fn divideUNR(self: *Self, lhs: u32, rhs: u32) u32 {
        if (!(rhs * 2 > lhs)) {
            self.setFlag(17);
            return 0x1FFFF;
        }

        const shift: u5 = @clz(@as(u16, @truncate(rhs)));
        const n = @as(u64, lhs << shift);
        const d = rhs << shift;

        const reciprocal = recip(@as(u16, @truncate(d)) | 0x8000);
        const res = (n * @as(u64, @intCast(reciprocal)) + 0x8000) >> 16;

        return if (res > 0x1FFFF) 0x1FFFF else @as(u32, @truncate(res));
    }

    /// Sign-extend a 44-bit MAC accumulator (Avocado's extend_sign<44>).
    fn extendMac(value: i64) i64 {
        return @as(i64, @as(i44, @truncate(value)));
    }

    /// Accumulate into MAC1..3 with the 44-bit overflow check applied at every
    /// step, matching Avocado's `O()` macro (opcodes.cpp:26-40).
    fn accumulateMac(self: *Self, i: usize, value: i64) i64 {
        if (value >= (1 << 43)) {
            self.setFlag(@as(u5, @intCast(31 - i))); // 30, 29, 28
        } else if (value < -(1 << 43)) {
            self.setFlag(@as(u5, @intCast(28 - i))); // 27, 26, 25
        }
        return extendMac(value);
    }

    /// MAC0 is a plain 32-bit accumulator (Avocado setMac<0>, opcodes.cpp:42).
    fn setMac0(self: *Self, value: i64) i64 {
        if (value >= (1 << 31)) {
            self.setFlag(16);
        } else if (value < -(1 << 31)) {
            self.setFlag(15);
        }
        self.macs[0] = value;
        return value;
    }

    /// IRGB/ORGB are not stored — both read back the three IR registers packed
    /// as 5-bit channels, each saturated rather than wrapped
    /// (Avocado gte.cpp:57-64).
    fn irgbValue(self: *const Self) u32 {
        var packed_rgb: u32 = 0;
        for (0..3) |n| {
            const ir = @as(i32, @bitCast(self.data_regs[9 + n]));
            const channel = std.math.clamp(@divTrunc(ir, 0x80), 0, 0x1F);
            packed_rgb |= @as(u32, @intCast(channel)) << @as(u5, @intCast(n * 5));
        }
        return packed_rgb;
    }

    // Move From/To Data Registers (MFC2 / MTC2)
    pub fn readData(self: *const Self, index: anytype) u32 {
        const i = getDataIdx(index);
        return switch (i) {
            15 => self.data_regs[14], // sxyp mirrors sxy2
            24...27 => @as(u32, @truncate(@as(u64, @bitCast(self.macs[i - 24])))),
            28, 29 => self.irgbValue(),
            31 => self.data_regs[31], // lzcr
            else => self.data_regs[i],
        };
    }

    pub fn writeData(self: *Self, index: anytype, value: u32) void {
        const i = getDataIdx(index);

        switch (i) {
            // otz and the sz fifo are 16-bit *unsigned*: the top half is dropped
            // rather than sign-extended (Avocado stores them as uint16_t).
            7, 16...19 => self.data_regs[i] = value & 0xFFFF,
            // vz0..vz2 and ir0..ir3: sign-extend from 16-bit to 32-bit
            1, 3, 5, 8...11 => {
                self.data_regs[i] = signExtend16(@as(u16, @truncate(value)));
            },
            15 => { // sxyp: write to sxy2 and shift fifo
                self.data_regs[12] = self.data_regs[13]; // sxy0 = sxy1
                self.data_regs[13] = self.data_regs[14]; // sxy1 = sxy2
                self.data_regs[14] = value; // sxy2 = new value
            },
            24...27 => { // mac0...mac3: sign-extend from 32-bit to 44-bit internally
                self.data_regs[i] = value;
                self.macs[i - 24] = @as(i64, @as(i32, @bitCast(value)));
            },
            28 => { // irgb: unpack the 5-bit channels into ir1..ir3
                for (0..3) |n| {
                    const channel = (value >> @as(u5, @intCast(n * 5))) & 0x1F;
                    self.data_regs[9 + n] = channel * 0x80;
                }
            },
            // orgb and lzcr are read-only; writes are discarded.
            29, 31 => {},
            30 => { // lzcs: count leading zeros/ones into lzcr
                self.data_regs[30] = value;
                self.data_regs[31] = if ((value >> 31) == 0) @clz(value) else @clz(~value);
            },
            else => self.data_regs[i] = value,
        }
    }

    /// Control registers backed by a single 16-bit field rather than a packed
    /// pair or a full word: RT33, LL33, LC33, H, DQA, ZSF3, ZSF4 (GTE registers
    /// 36, 44, 52, 58, 59, 61, 62). They are stored truncated and sign-extended
    /// on read. H is included deliberately — the GTE sign-extends it on read
    /// even though the divide consumes it as unsigned, a hardware bug Avocado
    /// reproduces too (gte.cpp:88).
    fn isI16Ctrl(i: usize) bool {
        return switch (i) {
            4, 12, 20, 26, 27, 29, 30 => true,
            else => false,
        };
    }

    // Move From/To Control Registers (CFC2 / CTC2)
    pub fn readCtrl(self: *const Self, index: anytype) u32 {
        const i = getCtrlIdx(index);
        if (isI16Ctrl(i)) return signExtend16(@as(u16, @truncate(self.ctrl_regs[i])));
        return self.ctrl_regs[i];
    }

    pub fn writeCtrl(self: *Self, index: anytype, value: u32) void {
        const i = getCtrlIdx(index);

        switch (i) {
            0...30 => self.ctrl_regs[i] = if (isI16Ctrl(i)) value & 0xFFFF else value,
            31 => {
                // Bits 0-11 are reserved (0). Bit 31 is read-only (calculated).
                // Writing to FLAG directly overwrites bits 12-30.
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
            0x0C => self.opOp(sf, lm),
            0x10 => self.opDpcs(sf, lm),
            0x11 => self.opIntpl(sf, lm),
            0x12 => self.opMvmva(instruction, sf, lm),
            0x13 => self.opNcds(sf, lm),
            0x14 => self.opCdp(sf, lm),
            0x16 => self.opNcdt(sf, lm),
            0x1B => self.opNccs(sf, lm),
            0x1C => self.opCc(sf, lm),
            0x1E => self.opNcs(sf, lm),
            0x20 => self.opNct(sf, lm),
            0x2A => self.opDpct(sf, lm),
            0x28 => self.opSqr(sf, lm),
            0x29 => self.opDcpl(sf, lm),
            0x2D => self.opAvsz(false),
            0x2E => self.opAvsz(true),
            0x30 => self.opRtpt(sf, lm),
            0x3D => self.opGpx(sf, lm, false),
            0x3E => self.opGpx(sf, lm, true),
            0x3F => self.opNcct(sf, lm),
            else => {
                std.log.warn("Unimplemented or Invalid GTE command: 0x{x:0>2} (Full Inst: 0x{x:0>8})", .{ command, instruction });
            },
        }
        self.updateErrorFlag();
    }

    fn doPerspectiveTransform(self: *Self, vx: i64, vy: i64, vz: i64, sf: u6, lm: bool, set_mac0: bool) void {
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

        // The translation enters the accumulator at 20.12 *before* the sf shift
        // (Avocado multiplyMatrixByVectorRTP, opcodes.cpp:116-121).
        var result: [3]i64 = undefined;
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            var acc = self.accumulateMac(i + 1, (@as(i64, tr[i]) << 12) + @as(i64, m[i][0]) * vx);
            acc = self.accumulateMac(i + 1, acc + @as(i64, m[i][1]) * vy);
            acc = self.accumulateMac(i + 1, acc + @as(i64, m[i][2]) * vz);
            result[i] = acc;
        }

        self.macs[1] = result[0] >> sf;
        self.saturateToIr(1, self.macs[1], lm);
        self.macs[2] = result[1] >> sf;
        self.saturateToIr(2, self.macs[2], lm);
        self.macs[3] = result[2] >> sf;

        // RTP derives the IR3 saturation flag from the unshifted Z as if lm were
        // always false, but the value it stores still honours lm
        // (Avocado opcodes.cpp:127-131).
        const z12 = result[2] >> 12;
        if (z12 > 32767 or z12 < -32768) self.setFlag(22);
        var ir3 = self.macs[3];
        const ir3_min: i64 = if (lm) 0 else -32768;
        if (ir3 > 32767) {
            ir3 = 32767;
        } else if (ir3 < ir3_min) {
            ir3 = ir3_min;
        }
        self.data_regs[11] = @as(u32, @bitCast(@as(i32, @as(i16, @intCast(ir3)))));

        // SZ FIFO Shift
        self.data_regs[16] = self.data_regs[17]; // sz0 = sz1
        self.data_regs[17] = self.data_regs[18]; // sz1 = sz2
        self.data_regs[18] = self.data_regs[19]; // sz2 = sz3

        // SZ3 always comes from the *unshifted* MAC3 >> 12, regardless of sf.
        var sz3 = z12;
        if (sz3 < 0) {
            self.setFlag(18);
            sz3 = 0;
        } else if (sz3 > 0xFFFF) {
            self.setFlag(18);
            sz3 = 0xFFFF;
        }
        self.data_regs[19] = @as(u32, @intCast(sz3));

        // Projection. h_s3z carries 16 fractional bits, matching OFX/OFY.
        const h = @as(u32, @as(u16, @truncate(self.ctrl_regs[26])));
        const h_s3z = @as(i64, self.divideUNR(h, @as(u32, @intCast(sz3))));

        const ofx = @as(i64, @as(i32, @bitCast(self.ctrl_regs[24])));
        const ofy = @as(i64, @as(i32, @bitCast(self.ctrl_regs[25])));

        const ir1 = @as(i64, asI16(self.data_regs[9]));
        const ir2 = @as(i64, asI16(self.data_regs[10]));

        const x = self.setMac0(h_s3z * ir1 + ofx) >> 16;
        const y = self.setMac0(h_s3z * ir2 + ofy) >> 16;

        // SXY FIFO Shift
        self.data_regs[12] = self.data_regs[13]; // sxy0 = sxy1
        self.data_regs[13] = self.data_regs[14]; // sxy1 = sxy2

        // Saturate X and Y to -1024..1023
        const sxy2 = Point2D{
            .x = self.saturateSxy(x, 14), // flag bit 14 for X
            .y = self.saturateSxy(y, 13), // flag bit 13 for Y
        };

        self.data_regs[14] = @as(u32, @bitCast(sxy2));

        // Depth cueing: MAC0 = (H/SZ3)*DQA + DQB, IR0 = MAC0 >> 12 clamped to
        // 0..1000h. IR0 is the blend factor every fog/interpolate op reads.
        if (set_mac0) {
            const dqa = @as(i64, asI16(self.ctrl_regs[27]));
            const dqb = @as(i64, @as(i32, @bitCast(self.ctrl_regs[28])));

            var ir0 = self.setMac0(h_s3z * dqa + dqb) >> 12;
            if (ir0 < 0) {
                self.setFlag(12);
                ir0 = 0;
            } else if (ir0 > 0x1000) {
                self.setFlag(12);
                ir0 = 0x1000;
            }
            self.data_regs[8] = @as(u32, @intCast(ir0));
        }
    }

    fn opRtps(self: *Self, sf: u6, lm: bool) void {
        const p = @as(Point2D, @bitCast(self.data_regs[0]));
        const vz = self.data_regs[1];
        const vx0 = @as(i64, p.x);
        const vy0 = @as(i64, p.y);
        const vz0 = @as(i64, asI16(vz));

        self.doPerspectiveTransform(vx0, vy0, vz0, sf, lm, true);
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

            // Only the last vertex updates MAC0/IR0 (Avocado opcodes.cpp:369).
            self.doPerspectiveTransform(vx, vy, vz_val, sf, lm, j == 2);
        }
    }

    /// `val` is already the >>16 screen coordinate (Avocado pushScreenXY).
    fn saturateSxy(self: *Self, val: i64, bit: u5) i16 {
        var res = val;
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
        // COP2 command operand fields (avocado_ref/src/cpu/gte/command.h):
        // bits 13-14 translation vector, 15-16 multiply vector, 17-18 matrix.
        const trans_id = (instr >> 13) & 0x3;
        const vector_id = (instr >> 15) & 0x3;
        const matrix_id = (instr >> 17) & 0x3;

        // Matrix elements: i16
        var m: [3][3]i16 = undefined;
        const matrix_base = switch (matrix_id) {
            0 => @as(u5, 0), // rt
            1 => @as(u5, 8), // l
            2 => @as(u5, 16), // lr
            3 => @as(u5, 0), // Hardware quirk: invalid matrix 3 aliases to RT.
            else => unreachable,
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

    fn saturateColor(self: *Self, val: i64, bit: u5) u8 {
        return self.clampColor(val >> 12, bit);
    }

    /// Clamp an already-scaled colour component to 0..255, flagging saturation.
    /// Callers that hold an un-shifted MAC want `saturateColor` instead.
    fn clampColor(self: *Self, val: i64, bit: u5) u8 {
        if (val < 0) {
            self.setFlag(bit);
            return 0;
        } else if (val > 255) {
            self.setFlag(bit);
            return 255;
        }
        return @as(u8, @intCast(val));
    }

    fn pushRgb(self: *Self, r: u8, g: u8, b: u8) void {
        // Shift RGB FIFO: RGB0 = RGB1, RGB1 = RGB2
        self.data_regs[20] = self.data_regs[21];
        self.data_regs[21] = self.data_regs[22];

        // Read the CODE (command byte) from RGBC (DataReg 6)
        const code = @as(u8, @truncate(self.data_regs[6] >> 24));

        // Pack new color into RGB2 (DataReg 22)
        const rgb2 = ColorCode{ .r = r, .g = g, .b = b, .code = code };
        self.data_regs[22] = @as(u32, @bitCast(rgb2));
    }

    /// Build one of the GTE's 3x3 matrices from five consecutive control regs
    /// (`base` = 8 light source, 16 light colour).
    fn matrixFromCtrl(self: *const Self, comptime base: usize) [3][3]i16 {
        const m0 = @as(DualI16, @bitCast(self.ctrl_regs[base + 0]));
        const m1 = @as(DualI16, @bitCast(self.ctrl_regs[base + 1]));
        const m2 = @as(DualI16, @bitCast(self.ctrl_regs[base + 2]));
        const m3 = @as(DualI16, @bitCast(self.ctrl_regs[base + 3]));
        const m4 = @as(DualI16, @bitCast(self.ctrl_regs[base + 4]));
        return .{
            .{ m0.low, m0.high, m1.low },
            .{ m1.high, m2.low, m2.high },
            .{ m3.low, m3.high, m4.low },
        };
    }

    /// V0/V1/V2 as a vector (DataRegs 0/1, 2/3, 4/5).
    fn vertex(self: *const Self, n: usize) [3]i16 {
        const p = @as(Point2D, @bitCast(self.data_regs[n * 2]));
        return .{ p.x, p.y, asI16(self.data_regs[n * 2 + 1]) };
    }

    fn irVector(self: *const Self) [3]i16 {
        return .{
            asI16(self.data_regs[9]),
            asI16(self.data_regs[10]),
            asI16(self.data_regs[11]),
        };
    }

    /// RGBC as the GTE uses it internally: each component shifted up by 4
    /// (Avocado's R/G/B macros, opcodes.cpp:90).
    fn rgbcScaled(self: *const Self) [3]i16 {
        const c = @as(ColorCode, @bitCast(self.data_regs[6]));
        return .{
            @as(i16, c.r) << 4,
            @as(i16, c.g) << 4,
            @as(i16, c.b) << 4,
        };
    }

    /// Background colour (Ctrl 13..15), the translation vector of the
    /// light-colour matrix multiply.
    fn backgroundColor(self: *const Self) [3]i32 {
        return .{
            @bitCast(self.ctrl_regs[13]),
            @bitCast(self.ctrl_regs[14]),
            @bitCast(self.ctrl_regs[15]),
        };
    }

    /// Far colour (Ctrl 21..23).
    fn farColor(self: *const Self) [3]i64 {
        return .{
            @as(i32, @bitCast(self.ctrl_regs[21])),
            @as(i32, @bitCast(self.ctrl_regs[22])),
            @as(i32, @bitCast(self.ctrl_regs[23])),
        };
    }

    /// Avocado `multiplyMatrixByVector` (opcodes.cpp:104). The `O()` macro
    /// applies the 44-bit overflow check after *every* accumulation step, not
    /// just to the final sum.
    fn multiplyMatrixByVector(self: *Self, m: [3][3]i16, v: [3]i16, tr: [3]i32, sf: u6, lm: bool) void {
        for (0..3) |i| {
            var acc = self.accumulateMac(i + 1, (@as(i64, tr[i]) << 12) + @as(i64, m[i][0]) * @as(i64, v[0]));
            acc = self.accumulateMac(i + 1, acc + @as(i64, m[i][1]) * @as(i64, v[1]));
            acc = self.accumulateMac(i + 1, acc + @as(i64, m[i][2]) * @as(i64, v[2]));
            self.setMacAndIr(i + 1, acc, sf, lm);
        }
    }

    /// Avocado `multiplyVectors` (opcodes.cpp:98).
    fn multiplyVectors(self: *Self, v1: [3]i16, v2: [3]i16, tr: [3]i16, sf: u6, lm: bool) void {
        for (0..3) |i| {
            self.setMacAndIr(i + 1, (@as(i64, tr[i]) << 12) + @as(i64, v1[i]) * @as(i64, v2[i]), sf, lm);
        }
    }

    /// Avocado `pushColor()` (opcodes.cpp:329): MAC1..3 >> 4, clamped to 0..255.
    fn pushColorFromMac(self: *Self) void {
        const r = self.clampColor(self.macs[1] >> 4, 21);
        const g = self.clampColor(self.macs[2] >> 4, 20);
        const b = self.clampColor(self.macs[3] >> 4, 19);
        self.pushRgb(r, g, b);
    }

    /// The lighting half shared by NCS/NCT/NCDS/NCDT/NCCS/NCCT: light matrix
    /// against the vertex normal, then the light-colour matrix against the
    /// resulting IR, translated by the background colour.
    fn applyLighting(self: *Self, n: usize, sf: u6, lm: bool) void {
        self.multiplyMatrixByVector(self.matrixFromCtrl(8), self.vertex(n), .{ 0, 0, 0 }, sf, lm);
        self.multiplyMatrixByVector(self.matrixFromCtrl(16), self.irVector(), self.backgroundColor(), sf, lm);
    }

    /// Depth-cue tail shared by NCDS/NCDT and CDP (Avocado opcodes.cpp:139-147).
    ///
    /// This is deliberately a *two-stage* op: stage 1 interpolates towards the
    /// far colour and saturates into IR with lm forced to 0, stage 2 folds that
    /// saturated IR back in through IR0. Collapsing the two loses the
    /// intermediate +/-0x7FFF clamp. Crucially, both stages weight by the RGBC
    /// vertex colour — dropping it is what rendered the BIOS boot logo grey.
    fn depthCueWithRgbc(self: *Self, sf: u6, lm: bool) void {
        const prev_ir = self.irVector();
        const col = self.rgbcScaled();
        const fc = self.farColor();

        for (0..3) |i| {
            self.setMacAndIr(i + 1, (fc[i] << 12) - @as(i64, col[i]) * @as(i64, prev_ir[i]), sf, false);
        }

        const ir0 = @as(i64, asI16(self.data_regs[8]));
        const ir = self.irVector();
        for (0..3) |i| {
            self.setMacAndIr(i + 1, @as(i64, col[i]) * @as(i64, prev_ir[i]) + ir0 * @as(i64, ir[i]), sf, lm);
        }

        self.pushColorFromMac();
    }

    // NCS / NCT: lighting only (Avocado opcodes.cpp:152).
    fn opNcs(self: *Self, sf: u6, lm: bool) void {
        self.ncsSingle(0, sf, lm);
    }

    fn opNct(self: *Self, sf: u6, lm: bool) void {
        for (0..3) |n| self.ncsSingle(n, sf, lm);
    }

    fn ncsSingle(self: *Self, n: usize, sf: u6, lm: bool) void {
        self.applyLighting(n, sf, lm);
        self.pushColorFromMac();
    }

    // NCDS / NCDT: lighting -> depth cueing (Avocado opcodes.cpp:136).
    fn opNcds(self: *Self, sf: u6, lm: bool) void {
        self.ncdsSingle(0, sf, lm);
    }

    fn opNcdt(self: *Self, sf: u6, lm: bool) void {
        for (0..3) |n| self.ncdsSingle(n, sf, lm);
    }

    fn ncdsSingle(self: *Self, n: usize, sf: u6, lm: bool) void {
        self.applyLighting(n, sf, lm);
        self.depthCueWithRgbc(sf, lm);
    }

    // NCCS / NCCT: lighting -> modulate by RGBC (Avocado opcodes.cpp:164).
    fn opNccs(self: *Self, sf: u6, lm: bool) void {
        self.nccsSingle(0, sf, lm);
    }

    fn opNcct(self: *Self, sf: u6, lm: bool) void {
        for (0..3) |n| self.nccsSingle(n, sf, lm);
    }

    fn nccsSingle(self: *Self, n: usize, sf: u6, lm: bool) void {
        self.applyLighting(n, sf, lm);
        self.multiplyVectors(self.rgbcScaled(), self.irVector(), .{ 0, 0, 0 }, sf, lm);
        self.pushColorFromMac();
    }

    // CDP: colour matrix -> depth cueing (Avocado opcodes.cpp:177).
    fn opCdp(self: *Self, sf: u6, lm: bool) void {
        self.multiplyMatrixByVector(self.matrixFromCtrl(16), self.irVector(), self.backgroundColor(), sf, lm);
        self.depthCueWithRgbc(sf, lm);
    }

    // CC: colour matrix -> modulate by RGBC (Avocado opcodes.cpp:171).
    fn opCc(self: *Self, sf: u6, lm: bool) void {
        self.multiplyMatrixByVector(self.matrixFromCtrl(16), self.irVector(), self.backgroundColor(), sf, lm);
        self.multiplyVectors(self.rgbcScaled(), self.irVector(), .{ 0, 0, 0 }, sf, lm);
        self.pushColorFromMac();
    }

    /// Depth cueing for DPCS / DPCT, ported from Avocado
    /// (`gte/opcodes.cpp:210 dpcs`). Like INTPL this is a *two-stage* op:
    /// stage 1 interpolates towards the far colour and saturates into IR with
    /// lm=0, stage 2 folds that saturated IR back in through IR0. Collapsing the
    /// two loses the intermediate ±0x7FFF clamp.
    fn depthCueColor(self: *Self, r: u8, g: u8, b: u8, sf: u6, lm: bool) void {
        // Colour components enter the accumulator scaled by 16 (Avocado's
        // R/G/B macros are `rgbc.read(n) << 4`).
        const col = [3]i64{
            @as(i64, r) << 4,
            @as(i64, g) << 4,
            @as(i64, b) << 4,
        };
        const fc = [3]i64{
            @as(i64, @as(i32, @bitCast(self.ctrl_regs[21]))),
            @as(i64, @as(i32, @bitCast(self.ctrl_regs[22]))),
            @as(i64, @as(i32, @bitCast(self.ctrl_regs[23]))),
        };

        // Stage 1: MAC = (FC << 12) - (colour << 12), then IR = saturate(MAC).
        for (0..3) |i| {
            self.setMacAndIr(i + 1, (fc[i] << 12) - (col[i] << 12), sf, false);
        }

        // Stage 2: MAC = (colour << 12) + IR0 * IR.
        const ir0 = @as(i64, asI16(self.data_regs[8]));
        for (0..3) |i| {
            const ir_new = @as(i64, asI16(self.data_regs[9 + i]));
            self.setMacAndIr(i + 1, (col[i] << 12) + ir0 * ir_new, sf, lm);
        }

        // The colour FIFO takes MAC >> 4 — MAC is already sf-shifted.
        self.pushRgb(
            self.clampColor(self.macs[1] >> 4, 21),
            self.clampColor(self.macs[2] >> 4, 20),
            self.clampColor(self.macs[3] >> 4, 19),
        );
    }

    fn opDpcs(self: *Self, sf: u6, lm: bool) void {
        // DPCS reads RGBC, *not* the colour FIFO (Avocado `dpcs(useRGB0=false)`).
        const c = @as(ColorCode, @bitCast(self.data_regs[6]));
        self.depthCueColor(c.r, c.g, c.b, sf, lm);
    }

    fn opDpct(self: *Self, sf: u6, lm: bool) void {
        // Three passes, each reading RGB0 — every pass pushes a new colour and
        // shifts the FIFO, so this walks all three entries
        // (Avocado `dpct()` -> `dpcs(true)` x3).
        for (0..3) |_| {
            const c = @as(ColorCode, @bitCast(self.data_regs[20]));
            self.depthCueColor(c.r, c.g, c.b, sf, lm);
        }
    }

    fn opDcpl(self: *Self, sf: u6, lm: bool) void {
        // Matrix LC (Ctrl 16..20) * IR + BK (Ctrl 13..15) -> MAC
        const lc0 = @as(DualI16, @bitCast(self.ctrl_regs[16]));
        const lc1 = @as(DualI16, @bitCast(self.ctrl_regs[17]));
        const lc2 = @as(DualI16, @bitCast(self.ctrl_regs[18]));
        const lc3 = @as(DualI16, @bitCast(self.ctrl_regs[19]));
        const lc4 = @as(DualI16, @bitCast(self.ctrl_regs[20]));

        var LC: [3][3]i16 = undefined;
        LC[0][0] = lc0.low;
        LC[0][1] = lc0.high;
        LC[0][2] = lc1.low;
        LC[1][0] = lc1.high;
        LC[1][1] = lc2.low;
        LC[1][2] = lc2.high;
        LC[2][0] = lc3.low;
        LC[2][1] = lc3.high;
        LC[2][2] = lc4.low;

        const bk = [3]i64{
            @as(i32, @bitCast(self.ctrl_regs[13])),
            @as(i32, @bitCast(self.ctrl_regs[14])),
            @as(i32, @bitCast(self.ctrl_regs[15])),
        };

        const ir1 = @as(i64, asI16(self.data_regs[9]));
        const ir2 = @as(i64, asI16(self.data_regs[10]));
        const ir3 = @as(i64, asI16(self.data_regs[11]));

        var i: usize = 0;
        while (i < 3) : (i += 1) {
            const res = (@as(i64, LC[i][0]) * ir1) + (@as(i64, LC[i][1]) * ir2) + (@as(i64, LC[i][2]) * ir3);
            self.macs[i + 1] = res + (bk[i] << 12);
            self.checkMacOverflow(i + 1);
        }

        // Depth Cueing Interpolation
        const rfc = @as(i64, @as(i32, @bitCast(self.ctrl_regs[21])));
        const gfc = @as(i64, @as(i32, @bitCast(self.ctrl_regs[22])));
        const bfc = @as(i64, @as(i32, @bitCast(self.ctrl_regs[23])));
        const fc = [3]i64{ rfc, gfc, bfc };

        const ir0 = @as(i64, asI16(self.data_regs[8]));

        i = 0;
        while (i < 3) : (i += 1) {
            // Calculate intermediate IR from (FC - MAC)
            const diff = (fc[i] << 12) - self.macs[i + 1];
            var temp_ir = diff >> sf;

            // Saturate as if lm=0 (signed 16-bit range)
            if (temp_ir < -32768) {
                temp_ir = -32768;
            } else if (temp_ir > 32767) {
                temp_ir = 32767;
            }

            // MAC = (temp_ir * IR0) + old MAC
            self.macs[i + 1] = (temp_ir * ir0) + self.macs[i + 1];
            self.checkMacOverflow(i + 1);

            // Final saturation back to IR1, IR2, IR3
            self.saturateToIr(i + 1, self.macs[i + 1] >> sf, lm);
        }

        // Output to RGB
        const r = self.saturateColor(self.macs[1], 21);
        const g = self.saturateColor(self.macs[2], 20);
        const b = self.saturateColor(self.macs[3], 19);

        self.pushRgb(r, g, b);
    }

    // OP: Outer Product (Cross Product of IR and Rotation Matrix Column 3)
    fn opOp(self: *Self, sf: u6, lm: bool) void {
        const d1 = @as(DualI16, @bitCast(self.ctrl_regs[1]));
        const d2 = @as(DualI16, @bitCast(self.ctrl_regs[2]));
        const d4 = @as(DualI16, @bitCast(self.ctrl_regs[4]));

        // Column 3 of the Rotation Matrix
        const rt13 = @as(i64, d1.low);
        const rt23 = @as(i64, d2.high);
        const rt33 = @as(i64, d4.low);

        const ir1 = @as(i64, asI16(self.data_regs[9]));
        const ir2 = @as(i64, asI16(self.data_regs[10]));
        const ir3 = @as(i64, asI16(self.data_regs[11]));

        // Cross Product: IR x RT_Col3
        self.macs[1] = (ir2 * rt33) - (ir3 * rt23);
        self.macs[2] = (ir3 * rt13) - (ir1 * rt33);
        self.macs[3] = (ir1 * rt23) - (ir2 * rt13);

        self.checkMacOverflow(1);
        self.checkMacOverflow(2);
        self.checkMacOverflow(3);

        self.saturateToIr(1, self.macs[1] >> sf, lm);
        self.saturateToIr(2, self.macs[2] >> sf, lm);
        self.saturateToIr(3, self.macs[3] >> sf, lm);
    }

    // INTPL: Color Interpolation
    //
    // Ported from Avocado (`gte/opcodes.cpp:237 intpl`). This is a *two-stage*
    // op, not the single fused expression it looks like: stage 1 interpolates
    // towards the far colour and saturates the result into IR (always lm=0),
    // stage 2 folds that already-saturated IR back in through IR0. Collapsing
    // the two loses the intermediate ±0x7FFF clamp.
    fn opIntpl(self: *Self, sf: u6, lm: bool) void {
        const prev_ir = [3]i64{
            @as(i64, asI16(self.data_regs[9])),
            @as(i64, asI16(self.data_regs[10])),
            @as(i64, asI16(self.data_regs[11])),
        };
        const fc = [3]i64{
            @as(i64, @as(i32, @bitCast(self.ctrl_regs[21]))),
            @as(i64, @as(i32, @bitCast(self.ctrl_regs[22]))),
            @as(i64, @as(i32, @bitCast(self.ctrl_regs[23]))),
        };

        // Stage 1: MAC = (FC << 12) - (IR << 12), then IR = saturate(MAC).
        for (0..3) |i| {
            self.setMacAndIr(i + 1, (fc[i] << 12) - (prev_ir[i] << 12), sf, false);
        }

        // Stage 2: MAC = (IRprev << 12) + IR0 * IR.
        const ir0 = @as(i64, asI16(self.data_regs[8]));
        for (0..3) |i| {
            const ir_new = @as(i64, asI16(self.data_regs[9 + i]));
            self.setMacAndIr(i + 1, (prev_ir[i] << 12) + ir0 * ir_new, sf, lm);
        }

        // The colour FIFO takes MAC >> 4 — MAC is already sf-shifted.
        self.pushRgb(
            self.clampColor(self.macs[1] >> 4, 21),
            self.clampColor(self.macs[2] >> 4, 20),
            self.clampColor(self.macs[3] >> 4, 19),
        );
    }

    /// Avocado `setMacAndIr`: flag-check the full-width value, store MAC with the
    /// `sf` shift applied, then saturate that stored MAC into IR. MAC1..3 are
    /// readable via `mfc2` (data regs 25..27), so the shift must land in `macs`
    /// itself — not only on the way to IR.
    fn setMacAndIr(self: *Self, i: usize, value: i64, sf: u6, lm: bool) void {
        self.macs[i] = value;
        self.checkMacOverflow(i);
        self.macs[i] = value >> sf;
        self.saturateToIr(i, self.macs[i], lm);
    }

    // GPF / GPL: General Purpose Interpolate
    fn opGpx(self: *Self, sf: u6, lm: bool, accumulate: bool) void {
        const ir0 = @as(i64, asI16(self.data_regs[8]));
        const ir1 = @as(i64, asI16(self.data_regs[9]));
        const ir2 = @as(i64, asI16(self.data_regs[10]));
        const ir3 = @as(i64, asI16(self.data_regs[11]));

        const ir = [3]i64{ ir1, ir2, ir3 };

        // GPF starts from zero; GPL accumulates the current MAC, scaled back up
        // by sf so that setMacAndIr's shift leaves it where it already was
        // (Avocado opcodes.cpp:453 gpf / :462 gpl). Capture all three first —
        // setMacAndIr overwrites MAC as it goes.
        var base = [3]i64{ 0, 0, 0 };
        if (accumulate) {
            for (0..3) |i| base[i] = self.macs[i + 1] << sf;
        }

        for (0..3) |i| {
            self.setMacAndIr(i + 1, base[i] + ir0 * ir[i], sf, lm);
        }

        // The colour FIFO takes MAC >> 4 — MAC is already sf-shifted.
        self.pushRgb(
            self.clampColor(self.macs[1] >> 4, 21),
            self.clampColor(self.macs[2] >> 4, 20),
            self.clampColor(self.macs[3] >> 4, 19),
        );
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
