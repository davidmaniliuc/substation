const std = @import("std");
const alu = @import("alu.zig");
const Bus = @import("memory.zig").Bus;
pub const Cop0 = @import("cop0.zig").Cop0;
pub const Cop2 = @import("cop2.zig").Cop2;

pub const Cpu = struct {
    const Self = @This();

    pub const RType = struct { rs: u5, rt: u5, rd: u5, shamt: u5 };
    pub const IType = struct { rs: u5, rt: u5, imm: u16 };
    pub const JType = struct { target: u26 };

    regs: [32]u32 = [_]u32{0} ** 32,
    pc: u32 = 0xbfc00000,
    next_pc: u32 = 0xbfc00004,
    current_pc: u32 = 0xbfc00000,
    is_delay_slot: bool = false,
    next_is_delay_slot: bool = false,

    load_r: u5 = 0,
    load_v: u32 = 0,

    delay_r: u5 = 0,
    delay_v: u32 = 0,

    hi: u32 = 0,
    lo: u32 = 0,

    cop0: Cop0 = Cop0.init(),
    cop2: Cop2 = Cop2.init(),
    bus: *Bus,

    pub const Exception = enum(u5) {
        Interrupt = 0x00,
        LoadAddressError = 0x04,
        StoreAddressError = 0x05,
        Syscall = 0x08,
        Breakpoint = 0x09,
        ReservedInstruction = 0x0A,
        CoprocessorUnusable = 0x0B,
        ArithmeticOverflow = 0x0C,
    };

    const LoadType = enum { Byte, Half, Word };
    const UnalignedLoadType = enum { Left, Right };

    const StoreType = enum { Byte, Half, Word };
    const UnalignedStoreType = enum { Left, Right };

    pub fn init(bus: *Bus) Self {
        return Self{
            .bus = bus,
        };
    }

    pub fn step(self: *Self) void {
        self.current_pc = self.pc;
        const instruction = self.bus.read32(self.current_pc);

        self.pc = self.next_pc;
        self.next_pc = self.pc +% 4; // +% : wrapping add
        self.is_delay_slot = self.next_is_delay_slot;
        self.next_is_delay_slot = false;

        const pending_load_r = self.load_r;
        const pending_load_v = self.load_v;

        self.delay_r = self.load_r;
        self.delay_v = self.load_v;

        self.load_r = 0;
        self.load_v = 0;

        self.execute(instruction);

        self.writeReg(pending_load_r, pending_load_v);
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
        return switch (@typeInfo(@TypeOf(index))) {
            .int, .comptime_int => @as(u5, @truncate(index)),
            else => @intFromEnum(@as(Reg, index)),
        };
    }

    pub inline fn decodeR(instr: u32) RType {
        return .{
            .rs = @as(u5, @truncate((instr >> 21) & 0x1F)),
            .rt = @as(u5, @truncate((instr >> 16) & 0x1F)),
            .rd = @as(u5, @truncate((instr >> 11) & 0x1F)),
            .shamt = @as(u5, @truncate((instr >> 6) & 0x1F)),
        };
    }

    pub inline fn decodeI(instr: u32) IType {
        return .{
            .rs = @as(u5, @truncate((instr >> 21) & 0x1F)),
            .rt = @as(u5, @truncate((instr >> 16) & 0x1F)),
            .imm = @as(u16, @truncate(instr & 0xFFFF)),
        };
    }

    pub inline fn decodeJ(instr: u32) JType {
        return .{
            .target = @as(u26, @truncate(instr & 0x03FFFFFF)),
        };
    }

    inline fn rOp(self: *Self, instr: u32, comptime op: fn (u32, u32) u32) void {
        const d = decodeR(instr);
        self.writeReg(d.rd, op(self.readReg(d.rs), self.readReg(d.rt)));
    }

    inline fn rOpChecked(self: *Self, instr: u32, comptime op: fn (u32, u32) ?u32) void {
        const d = decodeR(instr);
        if (op(self.readReg(d.rs), self.readReg(d.rt))) |result| {
            self.writeReg(d.rd, result);
        } else {
            self.exception(.ArithmeticOverflow, 0);
        }
    }

    inline fn hiLoOp(self: *Self, instr: u32, comptime op: fn (u32, u32) alu.HiLo) void {
        const d = decodeR(instr);
        const result = op(self.readReg(d.rs), self.readReg(d.rt));
        self.hi = result.hi;
        self.lo = result.lo;
    }

    fn execute(self: *Self, instruction: u32) void {
        const opcode = @as(u6, @truncate(instruction >> 26));
        switch (opcode) {
            0x00 => self.special(instruction),
            0x02 => self.opJ(instruction),
            0x03 => self.opJal(instruction),

            0x04 => self.opBeq(instruction),
            0x05 => self.opBne(instruction),
            0x06 => self.opBlez(instruction),
            0x07 => self.opBgtz(instruction),

            0x08 => self.iOpChecked(instruction, alu.add),
            0x09 => self.iOpSignExt(instruction, alu.addu),
            0x0A => self.iOpSignExt(instruction, alu.slt),
            0x0B => self.iOpSignExt(instruction, alu.sltu),
            0x0C => self.iOpZeroExt(instruction, alu.and_),
            0x0D => self.iOpZeroExt(instruction, alu.or_),
            0x0E => self.iOpZeroExt(instruction, alu.xor),
            0x0F => self.opLui(instruction),

            0x10 => self.opCop(0, instruction),
            0x11 => self.opCop(1, instruction),
            0x12 => self.opCop(2, instruction),
            0x13 => self.opCop(3, instruction),

            0x20 => self.opLoad(instruction, .Byte, true), // LB  (Sign-extended)
            0x21 => self.opLoad(instruction, .Half, true), // LH  (Sign-extended)
            0x22 => self.opUnalignedLoad(instruction, .Left), // LWL
            0x23 => self.opLoad(instruction, .Word, false), // LW  (Word)
            0x24 => self.opLoad(instruction, .Byte, false), // LBU (Zero-extended)
            0x25 => self.opLoad(instruction, .Half, false), // LHU (Zero-extended)
            0x26 => self.opUnalignedLoad(instruction, .Right), // LWR

            0x28 => self.opStore(instruction, .Byte), // SB
            0x29 => self.opStore(instruction, .Half), // SH
            0x2A => self.opUnalignedStore(instruction, .Left), // SWL
            0x2B => self.opStore(instruction, .Word), // SW
            0x2E => self.opUnalignedStore(instruction, .Right), // SWR

            0x30 => self.opLwc(0, instruction), // LWC0
            0x31 => self.opLwc(1, instruction), // LWC1
            0x32 => self.opLwc(2, instruction), // LWC2
            0x33 => self.opLwc(3, instruction), // LWC3

            0x38 => self.opSwc(0, instruction), // SWC0
            0x39 => self.opSwc(1, instruction), // SWC1
            0x3A => self.opSwc(2, instruction), // SWC2
            0x3B => self.opSwc(3, instruction), // SWC3

            0x14...0x1F, 0x27, 0x2C, 0x2D, 0x2F, 0x34...0x37, 0x3C...0x3F => {
                self.exception(.ReservedInstruction, 0);
            },
            else => std.log.warn("Unimplemented Opcode: 0x{X:0>2}", .{opcode}),
        }
    }

    pub fn special(self: *Self, instruction: u32) void {
        const funct = @as(u6, @truncate(instruction & 0x3F));
        switch (funct) {
            0x00 => self.shift(instruction, alu.sll),
            0x02 => self.shift(instruction, alu.srl),
            0x03 => self.shift(instruction, alu.sra),
            0x04 => self.shiftV(instruction, alu.sll),
            0x06 => self.shiftV(instruction, alu.srl),
            0x07 => self.shiftV(instruction, alu.sra),

            0x08 => self.opJr(instruction),
            0x09 => self.opJalr(instruction),

            0x0C => self.exception(.Syscall, 0),
            0x0D => self.exception(.Breakpoint, 0),

            0x10 => self.writeReg(decodeR(instruction).rd, self.hi),
            0x11 => self.hi = self.readReg(decodeR(instruction).rs),
            0x12 => self.writeReg(decodeR(instruction).rd, self.lo),
            0x13 => self.lo = self.readReg(decodeR(instruction).rs),

            0x18 => self.hiLoOp(instruction, alu.mult),
            0x19 => self.hiLoOp(instruction, alu.multu),
            0x1A => self.hiLoOp(instruction, alu.div),
            0x1B => self.hiLoOp(instruction, alu.divu),

            0x20 => self.rOpChecked(instruction, alu.add),
            0x21 => self.rOp(instruction, alu.addu),
            0x22 => self.rOpChecked(instruction, alu.sub),
            0x23 => self.rOp(instruction, alu.subu),

            0x24 => self.rOp(instruction, alu.and_),
            0x25 => self.rOp(instruction, alu.or_),
            0x26 => self.rOp(instruction, alu.xor),
            0x27 => self.rOp(instruction, alu.nor),

            0x2A => self.rOp(instruction, alu.slt),
            0x2B => self.rOp(instruction, alu.sltu),

            0x01, 0x05, 0x0A...0x0B, 0x0E...0x0F, 0x14...0x17, 0x1C...0x1F, 0x28...0x29, 0x2C...0x3F => {
                self.exception(.ReservedInstruction, 0);
            },
        }
    }

    inline fn shift(self: *Self, instr: u32, comptime op: fn (u32, u5) u32) void {
        const d = decodeR(instr);
        self.writeReg(d.rd, op(self.readReg(d.rt), d.shamt));
    }

    inline fn shiftV(self: *Self, instr: u32, comptime op: fn (u32, u5) u32) void {
        const d = decodeR(instr);
        const shamt = @as(u5, @truncate(self.readReg(d.rs) & 0x1F));
        self.writeReg(d.rd, op(self.readReg(d.rt), shamt));
    }

    inline fn opJ(self: *Self, instruction: u32) void {
        const d = decodeJ(instruction);
        self.next_is_delay_slot = true;
        self.next_pc = (self.pc & 0xF0000000) | (@as(u32, d.target) << 2);
    }

    fn opJal(self: *Self, instruction: u32) void {
        self.writeReg(Reg.ra, self.pc +% 4);
        self.opJ(instruction);
    }

    fn opBeq(self: *Self, instruction: u32) void {
        const i = decodeI(instruction);
        self.doBranch(self.readReg(i.rs) == self.readReg(i.rt), i.imm);
    }

    fn opBne(self: *Self, instruction: u32) void {
        const i = decodeI(instruction);
        self.doBranch(self.readReg(i.rs) != self.readReg(i.rt), i.imm);
    }

    fn opBlez(self: *Self, instruction: u32) void {
        const i = decodeI(instruction);
        const rs_val = @as(i32, @bitCast(self.readReg(i.rs)));
        self.doBranch(rs_val <= 0, i.imm);
    }

    fn opBgtz(self: *Self, instruction: u32) void {
        const i = decodeI(instruction);
        const rs_val = @as(i32, @bitCast(self.readReg(i.rs)));
        self.doBranch(rs_val > 0, i.imm);
    }

    inline fn doBranch(self: *Self, condition: bool, imm: u16) void {
        self.next_is_delay_slot = true;
        if (condition) {
            const offset = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(imm))) << 2));
            self.next_pc = self.pc +% offset;
        }
    }

    fn opJr(self: *Self, instruction: u32) void {
        self.next_is_delay_slot = true;
        self.next_pc = self.readReg(decodeR(instruction).rs);
    }

    fn opJalr(self: *Self, instruction: u32) void {
        const d = decodeR(instruction);
        self.writeReg(d.rd, self.pc +% 4);
        self.next_is_delay_slot = true;
        self.next_pc = self.readReg(d.rs);
    }

    // slti  rt,rs,imm if rs < sign_extended(imm) (signed) then rt=1 else rt=0
    fn opSlti(self: *Self, instruction: u32) void {
        const i = decodeI(instruction);
        const rs_val: i32 = @bitCast(self.readReg(i.rs));
        const imm: i32 = @as(i16, @bitCast(i.imm));
        self.writeReg(i.rt, if (rs_val < imm) 1 else 0);
    }

    // sltiu rt,rs,imm if rs < sign_extended(imm) (unsigned) then rt=1 else rt=0
    fn opSltiu(self: *Self, instruction: u32) void {
        const i = decodeI(instruction);
        const rs_val = self.readReg(i.rs);
        const imm: u32 = @bitCast(@as(i32, @as(i16, @bitCast(i.imm))));
        self.writeReg(i.rt, if (rs_val < imm) 1 else 0);
    }

    inline fn iOpZeroExt(self: *Self, instr: u32, comptime op: fn (u32, u32) u32) void {
        const i = decodeI(instr);
        const imm32 = @as(u32, i.imm);
        self.writeReg(i.rt, op(self.readReg(i.rs), imm32));
    }

    inline fn iOpSignExt(self: *Self, instr: u32, comptime op: fn (u32, u32) u32) void {
        const i = decodeI(instr);
        const imm32 = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(i.imm)))));
        self.writeReg(i.rt, op(self.readReg(i.rs), imm32));
    }

    inline fn iOpChecked(self: *Self, instr: u32, comptime op: fn (u32, u32) ?u32) void {
        const i = decodeI(instr);
        const imm32 = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(i.imm)))));
        if (op(self.readReg(i.rs), imm32)) |result| {
            self.writeReg(i.rt, result);
        } else {
            self.exception(.ArithmeticOverflow, 0);
        }
    }

    fn opLui(self: *Self, instruction: u32) void {
        const i = decodeI(instruction);
        self.writeReg(i.rt, @as(u32, i.imm) << 16);
    }

    fn opCop(self: *Self, comptime cop_num: u2, instruction: u32) void {
        if (cop_num != 0) {
            std.log.warn("Unimplemented COP{} instruction", .{cop_num});
            self.exception(.CoprocessorUnusable, cop_num);
            return;
        }

        const sub_op = @as(u5, @truncate((instruction >> 21) & 0x1F));
        const rt = @as(u5, @truncate((instruction >> 16) & 0x1F));
        const rd = @as(u5, @truncate((instruction >> 11) & 0x1F));

        switch (sub_op) {
            0x00 => {
                const value = self.cop0.readReg(rd);
                self.writeReg(rt, value);
            },
            0x04 => {
                const value = self.readReg(rt);
                self.cop0.writeReg(rd, value);
            },
            0x10...0x1F => {
                self.cop2.executeCommand(instruction);
            },
            else => {
                std.log.warn("Unhandled COP0 sub-op: 0x{X:0>2}", .{sub_op});
                self.exception(.ReservedInstruction, 0);
            },
        }
    }

    inline fn opLoad(self: *Self, instr: u32, comptime ltype: LoadType, comptime signed: bool) void {
        const i = decodeI(instr);
        const base = self.readReg(i.rs);
        const offset = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(i.imm)))));
        const address = base +% offset;

        // Alignment checks -> triggers Exception and populates BadVaddr
        if (ltype == .Word and address & 3 != 0) {
            self.cop0.setReg(.badvaddr, address);
            self.exception(.LoadAddressError, 0);
            return;
        }
        if (ltype == .Half and address & 1 != 0) {
            self.cop0.setReg(.badvaddr, address);
            self.exception(.LoadAddressError, 0);
            return;
        }

        // Read from memory
        const raw_val: u32 = switch (ltype) {
            .Word => self.bus.read32(address),
            .Half => self.bus.read16(address),
            .Byte => self.bus.read8(address),
        };

        // Sign or Zero Extend
        const final_val = if (signed) switch (ltype) {
            .Word => raw_val,
            .Half => @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(raw_val))))))),
            .Byte => @as(u32, @bitCast(@as(i32, @as(i8, @bitCast(@as(u8, @truncate(raw_val))))))),
        } else raw_val;

        // Put the result in the Load Delay queue, NOT directly into the register
        self.load_r = i.rt;
        self.load_v = final_val;
    }

    inline fn opUnalignedLoad(self: *Self, instr: u32, comptime ul_type: UnalignedLoadType) void {
        const i = decodeI(instr);
        const base = self.readReg(i.rs);
        const offset = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(i.imm)))));
        const address = base +% offset;

        // Always read the floor aligned word (masking out the bottom 2 bits)
        const aligned_addr = address & ~@as(u32, 3);
        const mem = self.bus.read32(aligned_addr);

        // Load Delay Bypass: Merge with the incoming load if targeting the same register!
        const current_val = if (self.delay_r == i.rt) self.delay_v else self.readReg(i.rt);
        const shift_idx = address & 3;

        const merged = switch (ul_type) {
            .Left => blk: {
                const shifts = [_]u5{ 24, 16, 8, 0 };
                const masks = [_]u32{ 0x00FFFFFF, 0x0000FFFF, 0x000000FF, 0x00000000 };
                break :blk (current_val & masks[shift_idx]) | (mem << shifts[shift_idx]);
            },
            .Right => blk: {
                const shifts = [_]u5{ 0, 8, 16, 24 };
                const masks = [_]u32{ 0x00000000, 0xFF000000, 0xFFFF0000, 0xFFFFFF00 };
                break :blk (current_val & masks[shift_idx]) | (mem >> shifts[shift_idx]);
            },
        };

        // Enqueue the newly merged value into the load delay slot
        self.load_r = i.rt;
        self.load_v = merged;
    }

    inline fn isCacheIsolated(self: *const Self, address: u32) bool {
        const sr = self.cop0.readReg(Cop0.Reg.sr);
        const is_isolated = (sr & 0x10000) != 0; // Bit 16 is IsC (Isolate Cache)

        if (!is_isolated) return false;

        return !(address >= 0xA0000000 and address <= 0xBFFFFFFF);
    }

    inline fn opStore(self: *Self, instr: u32, comptime stype: StoreType) void {
        const i = decodeI(instr);
        const base = self.readReg(i.rs);
        const offset = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(i.imm)))));
        const address = base +% offset;

        // Alignment checks -> triggers Exception and populates BadVaddr
        if (stype == .Word and address & 3 != 0) {
            self.cop0.setReg(.badvaddr, address);
            self.exception(.StoreAddressError, 0);
            return;
        }
        if (stype == .Half and address & 1 != 0) {
            self.cop0.setReg(.badvaddr, address);
            self.exception(.StoreAddressError, 0);
            return;
        }

        if (self.isCacheIsolated(address)) {
            return; // Drop the write
        }

        const value = self.readReg(i.rt);

        switch (stype) {
            .Word => self.bus.write32(address, value),
            .Half => self.bus.write16(address, @as(u16, @truncate(value))),
            .Byte => self.bus.write8(address, @as(u8, @truncate(value))),
        }
    }

    inline fn opUnalignedStore(self: *Self, instr: u32, comptime us_type: UnalignedStoreType) void {
        const i = decodeI(instr);
        const base = self.readReg(i.rs);
        const offset = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(i.imm)))));
        const address = base +% offset;

        if (self.isCacheIsolated(address)) {
            return; // Drop the write
        }

        const aligned_addr = address & ~@as(u32, 3);
        const mem = self.bus.read32(aligned_addr);
        const val = self.readReg(i.rt);
        const shift_idx = address & 3;

        // Mask out the part of memory we are overwriting, and OR in the shifted register value
        const merged = switch (us_type) {
            .Left => blk: {
                const shifts = [_]u5{ 24, 16, 8, 0 };
                const masks = [_]u32{ 0xFFFFFF00, 0xFFFF0000, 0xFF000000, 0x00000000 };
                break :blk (mem & masks[shift_idx]) | (val >> shifts[shift_idx]);
            },
            .Right => blk: {
                const shifts = [_]u5{ 0, 8, 16, 24 };
                const masks = [_]u32{ 0x00000000, 0x000000FF, 0x0000FFFF, 0x00FFFFFF };
                break :blk (mem & masks[shift_idx]) | (val << shifts[shift_idx]);
            },
        };

        self.bus.write32(aligned_addr, merged);
    }

    inline fn opLwc(self: *Self, comptime cop_num: u2, instr: u32) void {
        if (cop_num != 2) {
            self.exception(.CoprocessorUnusable, cop_num);
            return;
        }

        const i = decodeI(instr);
        const base = self.readReg(i.rs);
        const offset = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(i.imm)))));
        const address = base +% offset;

        if (address & 3 != 0) {
            self.cop0.setReg(.badvaddr, address);
            self.exception(.LoadAddressError, 0);
            return;
        }

        // Read from Bus, Write directly to GTE Data Register
        const raw_val = self.bus.read32(address);
        self.cop2.writeData(i.rt, raw_val);
    }

    inline fn opSwc(self: *Self, comptime cop_num: u2, instr: u32) void {
        if (cop_num != 2) {
            self.exception(.CoprocessorUnusable, cop_num);
            return;
        }

        const i = decodeI(instr);
        const base = self.readReg(i.rs);
        const offset = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(i.imm)))));
        const address = base +% offset;

        if (address & 3 != 0) {
            self.cop0.setReg(.badvaddr, address);
            self.exception(.StoreAddressError, 0);
            return;
        }

        if (self.isCacheIsolated(address)) {
            return;
        }

        // Read from GTE Data Register, Write to Bus
        const cop_val = self.cop2.readData(i.rt);
        self.bus.write32(address, cop_val);
    }

    pub fn exception(self: *Self, code: Exception, cop_error: u2) void {
        var cause = @as(u32, @intFromEnum(code)) << 2;

        if (code == .CoprocessorUnusable) {
            cause |= @as(u32, cop_error) << 28;
        }

        const epc = if (self.is_delay_slot) blk: {
            cause |= 1 << 31;
            break :blk self.current_pc -% 4;
        } else self.current_pc;

        self.cop0.setReg(Cop0.Reg.epc, epc);
        self.cop0.setReg(Cop0.Reg.cause, cause);

        var sr = self.cop0.readReg(Cop0.Reg.sr);
        const mode_bits = sr & 0x3F;
        sr &= ~@as(u32, 0x3F);
        sr |= (mode_bits << 2) & 0x3F;
        self.cop0.setReg(Cop0.Reg.sr, sr);

        self.pc = if (((sr >> 22) & 1) == 1) 0xBFC00180 else 0x80000080;
        self.next_pc = self.pc +% 4;
        self.current_pc = self.pc;
        self.is_delay_slot = false;
        self.next_is_delay_slot = false;
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
