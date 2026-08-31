const std = @import("std");
const opcodes = @import("opcodes.zig");
const Precise = @import("../pgxp.zig").Precise;

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

    /// Shared with `math.zig`/`opcodes.zig`, which reach it as `Cop2.asI16`.
    pub inline fn asI16(val: u32) i16 {
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

    /// The sub-pixel half of sxy0/sxy1/sxy2, shifted in lockstep with
    /// `data_regs[12..14]`. Written by the projection in `opcodes.zig`;
    /// invalidated by any write software makes to those registers itself.
    precise_sxy: [3]Precise = .{ .{}, .{}, .{} },

    pub fn init() Self {
        return .{};
    }

    /// IRGB/ORGB are not stored — both read back the three IR registers packed
    /// as 5-bit channels, each saturated rather than wrapped.
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

    /// `readData`'s counterpart. Index 15 mirrors sxy2, exactly as the
    /// register does.
    pub fn readPreciseData(self: *const Self, index: anytype) Precise {
        const i = getDataIdx(index);
        return switch (i) {
            12, 13, 14 => self.precise_sxy[i - 12],
            15 => self.precise_sxy[2],
            else => Precise.none,
        };
    }

    /// `writeData` for sxy0/1/2 that does NOT invalidate the precise entry.
    /// Exists for tests that need to stage a register and its sub-pixel half
    /// independently; nothing in the emulator calls it.
    pub fn writeDataRaw(self: *Self, index: anytype, value: u32) void {
        self.data_regs[getDataIdx(index)] = value;
    }

    /// `writeData` for a value that arrived with a sub-pixel candidate —
    /// `mtc2` and `lwc2`, the two instructions that put a screen position INTO
    /// the GTE. Everything else keeps `writeData`'s blanket clear.
    ///
    /// The clear is right for software that synthesised a screen position out
    /// of nothing, and wrong for a game that CACHES projected vertices and
    /// reloads them to emit a second primitive: the word going in is the same
    /// projection the shadow already describes, and dropping it costs a
    /// sub-pixel on every vertex reached that way. Crash Bandicoot 3 reaches
    /// 100% of its unresolved vertices through here.
    ///
    /// `resolves` decides which of the two it is, exactly as it does at the
    /// GP0 boundary: a candidate that does not reproduce the integer position
    /// being written is dropped, so the worst a surviving one can be is a
    /// sub-pixel inside the right pixel.
    pub fn writeDataPrecise(self: *Self, index: anytype, value: u32, p: Precise) void {
        self.writeData(index, value);
        const i = getDataIdx(index);
        // A write to sxyp pushes the FIFO, so the value lands in sxy2 rather
        // than in the slot the register index names.
        const slot: usize = switch (i) {
            12, 13, 14 => i - 12,
            15 => 2,
            else => return,
        };
        const point = @as(Point2D, @bitCast(value));
        if (p.resolves(point.x, point.y)) self.precise_sxy[slot] = p;
    }

    pub fn writeData(self: *Self, index: anytype, value: u32) void {
        const i = getDataIdx(index);

        switch (i) {
            // otz and the sz fifo are 16-bit *unsigned*: the top half is dropped
            // rather than sign-extended.
            7, 16...19 => self.data_regs[i] = value & 0xFFFF,
            // vz0..vz2 and ir0..ir3: sign-extend from 16-bit to 32-bit
            1, 3, 5, 8...11 => {
                self.data_regs[i] = signExtend16(@as(u16, @truncate(value)));
            },
            15 => { // sxyp: write to sxy2 and shift fifo
                self.data_regs[12] = self.data_regs[13]; // sxy0 = sxy1
                self.data_regs[13] = self.data_regs[14]; // sxy1 = sxy2
                self.data_regs[14] = value; // sxy2 = new value
                self.precise_sxy[0] = self.precise_sxy[1];
                self.precise_sxy[1] = self.precise_sxy[2];
                self.precise_sxy[2] = Precise.none;
            },
            // Software supplying its own screen coordinate has no sub-pixel to
            // recover, and a leftover one from an earlier projection would be
            // attached to an unrelated position.
            12, 13, 14 => {
                self.data_regs[i] = value;
                self.precise_sxy[i - 12] = Precise.none;
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
    /// even though the divide consumes it as unsigned — a hardware bug.
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

    pub fn executeCommand(self: *Self, instruction: u32) void {
        const command = instruction & 0x3F;

        // Extract global command parameters
        const sf = @as(u6, @truncate((instruction >> 19) & 1)) * 12;
        const lm = ((instruction >> 10) & 1) != 0;

        // Clear temporary error flags (bits 30..12 are cleared on new command)
        self.ctrl_regs[31] &= 0x80000000;

        switch (command) {
            0x01 => opcodes.opRtps(self, sf, lm),
            0x06 => opcodes.opNclip(self),
            0x0C => opcodes.opOp(self, sf, lm),
            0x10 => opcodes.opDpcs(self, sf, lm),
            0x11 => opcodes.opIntpl(self, sf, lm),
            0x12 => opcodes.opMvmva(self, instruction, sf, lm),
            0x13 => opcodes.opNcds(self, sf, lm),
            0x14 => opcodes.opCdp(self, sf, lm),
            0x16 => opcodes.opNcdt(self, sf, lm),
            0x1B => opcodes.opNccs(self, sf, lm),
            0x1C => opcodes.opCc(self, sf, lm),
            0x1E => opcodes.opNcs(self, sf, lm),
            0x20 => opcodes.opNct(self, sf, lm),
            0x2A => opcodes.opDpct(self, sf, lm),
            0x28 => opcodes.opSqr(self, sf, lm),
            0x29 => opcodes.opDcpl(self, sf, lm),
            0x2D => opcodes.opAvsz(self, false),
            0x2E => opcodes.opAvsz(self, true),
            0x30 => opcodes.opRtpt(self, sf, lm),
            0x3D => opcodes.opGpx(self, sf, lm, false),
            0x3E => opcodes.opGpx(self, sf, lm, true),
            0x3F => opcodes.opNcct(self, sf, lm),
            else => {
                std.log.warn("Unimplemented or Invalid GTE command: 0x{x:0>2} (Full Inst: 0x{x:0>8})", .{ command, instruction });
            },
        }
        self.updateErrorFlag();
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
