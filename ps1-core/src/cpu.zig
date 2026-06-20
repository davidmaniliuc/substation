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

    pub const CacheLine = struct {
        tag: u32 = 0xFFFFFFFF,
        data: [4]u32 = [_]u32{0} ** 4,
    };

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
    cycles: u64 = 0,
    tty_context: ?*anyopaque = null,
    tty_write_fn: ?*const fn (context: ?*anyopaque, char: u8) void = null,

    icache: [256]CacheLine = [_]CacheLine{.{}} ** 256,

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

    inline fn signExtend16(val: u16) u32 {
        return @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(val)))));
    }

    inline fn signExtend8(val: u8) u32 {
        return @as(u32, @bitCast(@as(i32, @as(i8, @bitCast(val)))));
    }

    fn fetchInstruction(self: *Self, virtual_address: u32) u32 {
        const is_cached = virtual_address < 0xA0000000 or virtual_address >= 0xC0000000;

        if (!is_cached) {
            // Uncached.
            self.bus.addWaitCycles(u32, virtual_address, false);
            return self.bus.fetchInstruction(virtual_address);
        }

        // Cached!
        const line_index = (virtual_address >> 4) & 0xFF; // 256 lines
        const tag = virtual_address & 0xFFFFF000;
        const word_offset = (virtual_address >> 2) & 3;

        var line = &self.icache[line_index];

        if (line.tag == tag) {
            // Cache Hit! 0 wait cycles.
            return line.data[word_offset];
        }

        // Cache Miss!
        // We must fetch 4 words from the bus.
        const line_base = virtual_address & 0xFFFFFFF0;

        // Accurate Burst Read Timing
        const paddr = line_base & 0x1FFFFFFF;
        if (paddr >= 0x00000000 and paddr <= 0x001FFFFF) {
            // RAM Burst: 4 cycles for first word, 1 for each subsequent. Total = 7 cycles.
            self.bus.wait_cycles += 7;
        } else {
            // ROM / BIOS: No burst support, so it's 4 sequential reads.
            self.bus.addWaitCycles(u32, line_base + 0, false);
            self.bus.addWaitCycles(u32, line_base + 4, false);
            self.bus.addWaitCycles(u32, line_base + 8, false);
            self.bus.addWaitCycles(u32, line_base + 12, false);
        }

        const w0 = self.bus.fetchInstruction(line_base + 0);
        const w1 = self.bus.fetchInstruction(line_base + 4);
        const w2 = self.bus.fetchInstruction(line_base + 8);
        const w3 = self.bus.fetchInstruction(line_base + 12);

        // Update cache line
        line.tag = tag;
        line.data[0] = w0;
        line.data[1] = w1;
        line.data[2] = w2;
        line.data[3] = w3;

        return line.data[word_offset];
    }

    pub fn init(bus: *Bus) Self {
        return Self{
            .bus = bus,
        };
    }

    inline fn isInstructionBusErrorAddress(physical_pc: u32) bool {
        return switch (physical_pc) {
            0x1F800000...0x1F8003FF => true, // Scratchpad cannot be used for instruction fetches.
            0x1F801070...0x1F801077 => true, // Interrupt status/mask registers.
            0x1F801820...0x1F801827 => true, // MDEC command/control registers.
            else => false,
        };
    }

    pub var bios_hit_count: u64 = 0;
    pub fn step(self: *Self) void {
        if (self.bus.dma.isCpuStalled(self.bus)) {
            const dma_cycles = self.bus.dma.step(self.bus);
            self.tickPeripherals(dma_cycles);
            return;
        }

        // BIOS TTY INTERCEPT
        const physical_pc = self.pc & 0x1FFFFFFF;
        if (physical_pc == 0x000000A0 or physical_pc == 0x000000B0) {
            bios_hit_count += 1;
            const func = self.readReg(.t1);

            // putchar (Table A: 0x3C, Table B: 0x3D)
            if ((physical_pc == 0x000000A0 and func == 0x3C) or
                (physical_pc == 0x000000B0 and func == 0x3D))
            {
                const char: u8 = @truncate(self.readReg(.a0));
                if (self.tty_write_fn) |writer| writer(self.tty_context, char);
            }
        }

        if (isInstructionBusErrorAddress(physical_pc)) {
            self.current_pc = self.pc;

            var cause = @as(u32, 6) << 2; // Bus Error on Instruction Fetch
            if (self.is_delay_slot) {
                cause |= 1 << 31;
                self.cop0.setReg(.epc, self.current_pc -% 4);
            } else {
                self.cop0.setReg(.epc, self.current_pc);
            }
            self.cop0.setReg(.cause, cause);
            self.enterException();
            return;
        }

        self.current_pc = self.pc;
        const instruction = self.fetchInstruction(self.current_pc);

        var delta_cycles: u32 = 1;
        delta_cycles += self.bus.wait_cycles;
        self.bus.wait_cycles = 0;

        // HARDWARE INTERRUPT CHECK
        const has_pending_irq = self.bus.interrupts.hasPendingIrq();

        // Hardware interrupts map to IP2 (bit 10) in the COP0 Cause register
        var cause = self.cop0.readReg(.cause);
        if (has_pending_irq) {
            cause |= (1 << 10);
        } else {
            cause &= ~@as(u32, 1 << 10);
        }
        self.cop0.setReg(.cause, cause);

        const sr = self.cop0.readReg(.sr);
        const iec = (sr & 1) == 1; // Current Interrupt Enable
        const im2 = (sr & (1 << 10)) != 0; // Interrupt Mask 2

        // CRITICAL MIPS RULE: Never take an interrupt in a branch delay slot!
        const safe_to_interrupt = !self.is_delay_slot and !self.next_is_delay_slot;

        if (iec and im2 and has_pending_irq and safe_to_interrupt) {
            self.exception(.Interrupt, 0);
            // We spent cycles fetching the instruction, but we don't execute it.
            // We still need to tick hardware!
        } else {
            if (self.bus.cdrom.trace_cpu) {
                if (self.bus.cdrom.trace_count < 5000) {
                    std.log.warn("CPU PC={x:0>8}", .{self.pc});
                    self.bus.cdrom.trace_count += 1;
                } else {
                    self.bus.cdrom.trace_cpu = false;
                }
            }
            self.pc = self.next_pc;
            self.next_pc = self.pc +% 4;
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
            self.regs[0] = 0;
        }

        self.tickPeripherals(delta_cycles);
        self.bus.dma.tickCpuWindow(delta_cycles);
    }

    fn tickPeripherals(self: *Self, delta_cycles: u32) void {
        self.cycles +%= delta_cycles;
        self.bus.sys_clock = self.cycles;

        self.bus.spu.step(delta_cycles);
        const gpu_result = self.bus.gpu.step(delta_cycles);

        if (gpu_result.trigger_vblank_irq) {
            self.bus.interrupts.trigger(.Vblank);
        }
        if (gpu_result.trigger_gp0_irq) {
            self.bus.interrupts.trigger(.Gpu);
        }
        if (self.bus.spu.irq_flag) {
            self.bus.interrupts.trigger(.Spu);
        }

        // Tick the Timers (Timer 0, 1, and 2 map to IRQs 4, 5, and 6)
        if (self.bus.timers[0].usesExternalClock()) {
            if (gpu_result.dotclock_ticks > 0 and self.bus.timers[0].step(gpu_result.dotclock_ticks)) {
                self.bus.interrupts.trigger(.Timer0);
            }
        } else if (self.bus.timers[0].step(delta_cycles)) {
            self.bus.interrupts.trigger(.Timer0);
        }

        if (self.bus.timers[1].usesExternalClock()) {
            if (gpu_result.tick_hblank_timer and self.bus.timers[1].step(1)) {
                self.bus.interrupts.trigger(.Timer1);
            }
        } else if (self.bus.timers[1].step(delta_cycles)) {
            self.bus.interrupts.trigger(.Timer1);
        }

        // Calculate if Timer 2 crossed any Divide-By-8 boundaries during this instruction
        if (self.bus.timers[2].step(delta_cycles)) {
            self.bus.interrupts.trigger(.Timer2);
        }

        // Tick CD-ROM
        self.bus.cdrom.step(delta_cycles, &self.bus.spu);
        self.bus.cdrom.updateInterrupts(&self.bus.interrupts);
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

    pub const Instruction = packed union {
        raw: u32,
        r: packed struct(u32) {
            funct: u6, // Bits 0-5
            shamt: u5, // Bits 6-10
            rd: u5, // Bits 11-15
            rt: u5, // Bits 16-20
            rs: u5, // Bits 21-25
            opcode: u6, // Bits 26-31
        },
        i: packed struct(u32) {
            imm: u16, // Bits 0-15
            rt: u5, // Bits 16-20
            rs: u5, // Bits 21-25
            opcode: u6, // Bits 26-31
        },
        j: packed struct(u32) {
            target: u26, // Bits 0-25
            opcode: u6, // Bits 26-31
        },
    };

    pub inline fn decode(instr: u32) Instruction {
        return @as(Instruction, @bitCast(instr));
    }

    inline fn rOp(self: *Self, instr: Instruction, comptime op: fn (u32, u32) u32) void {
        self.writeReg(instr.r.rd, op(self.readReg(instr.r.rs), self.readReg(instr.r.rt)));
    }

    inline fn rOpChecked(self: *Self, instr: Instruction, comptime op: fn (u32, u32) ?u32) void {
        if (op(self.readReg(instr.r.rs), self.readReg(instr.r.rt))) |result| {
            self.writeReg(instr.r.rd, result);
        } else {
            self.exception(.ArithmeticOverflow, 0);
        }
    }

    inline fn hiLoOp(self: *Self, instr: Instruction, comptime op: fn (u32, u32) alu.HiLo) void {
        const result = op(self.readReg(instr.r.rs), self.readReg(instr.r.rt));
        self.hi = result.hi;
        self.lo = result.lo;
    }

    fn execute(self: *Self, raw_instr: u32) void {
        const instr = decode(raw_instr);
        const opcode = instr.i.opcode;
        switch (opcode) {
            0x00 => self.special(instr),
            0x01 => self.opRegimm(instr), // REGIMM (rt-based branches)
            0x02 => self.opJ(instr),
            0x03 => self.opJal(instr),

            0x04 => self.opBeq(instr),
            0x05 => self.opBne(instr),
            0x06 => self.opBlez(instr),
            0x07 => self.opBgtz(instr),

            0x08 => self.iOpChecked(instr, alu.add),
            0x09 => self.iOpSignExt(instr, alu.addu),
            0x0A => self.iOpSignExt(instr, alu.slt),
            0x0B => self.iOpSignExt(instr, alu.sltu),
            0x0C => self.iOpZeroExt(instr, alu.and_),
            0x0D => self.iOpZeroExt(instr, alu.or_),
            0x0E => self.iOpZeroExt(instr, alu.xor),
            0x0F => self.opLui(instr),

            0x10 => self.opCop(0, instr),
            0x11 => self.opCop(1, instr),
            0x12 => self.opCop(2, instr),
            0x13 => self.opCop(3, instr),

            0x20 => self.opLoad(instr, .Byte, true), // LB  (Sign-extended)
            0x21 => self.opLoad(instr, .Half, true), // LH  (Sign-extended)
            0x22 => self.opUnalignedLoad(instr, .Left), // LWL
            0x23 => self.opLoad(instr, .Word, false), // LW  (Word)
            0x24 => self.opLoad(instr, .Byte, false), // LBU (Zero-extended)
            0x25 => self.opLoad(instr, .Half, false), // LHU (Zero-extended)
            0x26 => self.opUnalignedLoad(instr, .Right), // LWR

            0x28 => self.opStore(instr, .Byte), // SB
            0x29 => self.opStore(instr, .Half), // SH
            0x2A => self.opUnalignedStore(instr, .Left), // SWL
            0x2B => self.opStore(instr, .Word), // SW
            0x2E => self.opUnalignedStore(instr, .Right), // SWR

            0x30 => self.opLwc(0, instr), // LWC0
            0x31 => self.opLwc(1, instr), // LWC1
            0x32 => self.opLwc(2, instr), // LWC2
            0x33 => self.opLwc(3, instr), // LWC3

            0x38 => self.opSwc(0, instr), // SWC0
            0x39 => self.opSwc(1, instr), // SWC1
            0x3A => self.opSwc(2, instr), // SWC2
            0x3B => self.opSwc(3, instr), // SWC3

            0x14...0x1F, 0x27, 0x2C, 0x2D, 0x2F, 0x34...0x37, 0x3C...0x3F => {
                self.exception(.ReservedInstruction, 0);
            },
        }
    }

    pub fn special(self: *Self, instr: Instruction) void {
        const funct = instr.r.funct;
        switch (funct) {
            0x00 => self.shift(instr, alu.sll),
            0x02 => self.shift(instr, alu.srl),
            0x03 => self.shift(instr, alu.sra),
            0x04 => self.shiftV(instr, alu.sll),
            0x06 => self.shiftV(instr, alu.srl),
            0x07 => self.shiftV(instr, alu.sra),

            0x08 => self.opJr(instr),
            0x09 => self.opJalr(instr),

            0x0C => self.exception(.Syscall, 0),
            0x0D => self.exception(.Breakpoint, 0),

            0x10 => self.writeReg(instr.r.rd, self.hi),
            0x11 => self.hi = self.readReg(instr.r.rs),
            0x12 => self.writeReg(instr.r.rd, self.lo),
            0x13 => self.lo = self.readReg(instr.r.rs),

            0x18 => self.hiLoOp(instr, alu.mult),
            0x19 => self.hiLoOp(instr, alu.multu),
            0x1A => self.hiLoOp(instr, alu.div),
            0x1B => self.hiLoOp(instr, alu.divu),

            0x20 => self.rOpChecked(instr, alu.add),
            0x21 => self.rOp(instr, alu.addu),
            0x22 => self.rOpChecked(instr, alu.sub),
            0x23 => self.rOp(instr, alu.subu),

            0x24 => self.rOp(instr, alu.and_),
            0x25 => self.rOp(instr, alu.or_),
            0x26 => self.rOp(instr, alu.xor),
            0x27 => self.rOp(instr, alu.nor),

            0x2A => self.rOp(instr, alu.slt),
            0x2B => self.rOp(instr, alu.sltu),

            0x01, 0x05, 0x0A...0x0B, 0x0E...0x0F, 0x14...0x17, 0x1C...0x1F, 0x28...0x29, 0x2C...0x3F => {
                self.exception(.ReservedInstruction, 0);
            },
        }
    }

    inline fn shift(self: *Self, instr: Instruction, comptime op: fn (u32, u5) u32) void {
        self.writeReg(instr.r.rd, op(self.readReg(instr.r.rt), instr.r.shamt));
    }

    inline fn shiftV(self: *Self, instr: Instruction, comptime op: fn (u32, u5) u32) void {
        const shamt = @as(u5, @truncate(self.readReg(instr.r.rs) & 0x1F));
        self.writeReg(instr.r.rd, op(self.readReg(instr.r.rt), shamt));
    }

    inline fn opJ(self: *Self, instr: Instruction) void {
        self.next_is_delay_slot = true;
        self.next_pc = (self.pc & 0xF0000000) | (@as(u32, instr.j.target) << 2);
    }

    fn opJal(self: *Self, instr: Instruction) void {
        self.writeReg(Reg.ra, self.pc +% 4);
        self.opJ(instr);
    }

    fn opBeq(self: *Self, instr: Instruction) void {
        self.doBranch(self.readReg(instr.i.rs) == self.readReg(instr.i.rt), instr.i.imm);
    }

    fn opBne(self: *Self, instr: Instruction) void {
        self.doBranch(self.readReg(instr.i.rs) != self.readReg(instr.i.rt), instr.i.imm);
    }

    fn opBlez(self: *Self, instr: Instruction) void {
        const rs_val = @as(i32, @bitCast(self.readReg(instr.i.rs)));
        self.doBranch(rs_val <= 0, instr.i.imm);
    }

    fn opBgtz(self: *Self, instr: Instruction) void {
        const rs_val = @as(i32, @bitCast(self.readReg(instr.i.rs)));
        self.doBranch(rs_val > 0, instr.i.imm);
    }

    fn opRegimm(self: *Self, instr: Instruction) void {
        const rt = instr.i.rt;
        const rs_val = @as(i32, @bitCast(self.readReg(instr.i.rs)));
        const imm = instr.i.imm;

        switch (rt) {
            0x00 => self.doBranch(rs_val < 0, imm), // BLTZ (Branch Less Than Zero)
            0x01 => self.doBranch(rs_val >= 0, imm), // BGEZ (Branch Greater Than or Equal to Zero)
            0x10 => { // BLTZAL (Branch Less Than Zero And Link)
                self.writeReg(Reg.ra, self.pc +% 4);
                self.doBranch(rs_val < 0, imm);
            },
            0x11 => { // BGEZAL (Branch Greater Than or Equal to Zero And Link)
                self.writeReg(Reg.ra, self.pc +% 4);
                self.doBranch(rs_val >= 0, imm);
            },
            else => {
                self.exception(.ReservedInstruction, 0);
            },
        }
    }

    inline fn doBranch(self: *Self, condition: bool, imm: u16) void {
        self.next_is_delay_slot = true;
        if (condition) {
            const offset = signExtend16(imm) << 2;
            self.next_pc = self.pc +% offset;
        }
    }

    fn opJr(self: *Self, instr: Instruction) void {
        self.next_is_delay_slot = true;
        self.next_pc = self.readReg(instr.r.rs);
    }

    fn opJalr(self: *Self, instr: Instruction) void {
        self.writeReg(instr.r.rd, self.pc +% 4);
        self.next_is_delay_slot = true;
        self.next_pc = self.readReg(instr.r.rs);
    }

    // slti  rt,rs,imm if rs < sign_extended(imm) (signed) then rt=1 else rt=0
    fn opSlti(self: *Self, instr: Instruction) void {
        const rs_val: i32 = @bitCast(self.readReg(instr.i.rs));
        const imm: i32 = @as(i16, @bitCast(instr.i.imm));
        self.writeReg(instr.i.rt, if (rs_val < imm) 1 else 0);
    }

    // sltiu rt,rs,imm if rs < sign_extended(imm) (unsigned) then rt=1 else rt=0
    fn opSltiu(self: *Self, instr: Instruction) void {
        const rs_val = self.readReg(instr.i.rs);
        const imm: u32 = @bitCast(@as(i32, @as(i16, @bitCast(instr.i.imm))));
        self.writeReg(instr.i.rt, if (rs_val < imm) 1 else 0);
    }

    inline fn iOpZeroExt(self: *Self, instr: Instruction, comptime op: fn (u32, u32) u32) void {
        const imm32 = @as(u32, instr.i.imm);
        self.writeReg(instr.i.rt, op(self.readReg(instr.i.rs), imm32));
    }

    inline fn iOpSignExt(self: *Self, instr: Instruction, comptime op: fn (u32, u32) u32) void {
        const imm32 = signExtend16(instr.i.imm);
        self.writeReg(instr.i.rt, op(self.readReg(instr.i.rs), imm32));
    }

    inline fn iOpChecked(self: *Self, instr: Instruction, comptime op: fn (u32, u32) ?u32) void {
        const imm32 = signExtend16(instr.i.imm);
        if (op(self.readReg(instr.i.rs), imm32)) |result| {
            self.writeReg(instr.i.rt, result);
        } else {
            self.exception(.ArithmeticOverflow, 0);
        }
    }

    fn opLui(self: *Self, instr: Instruction) void {
        self.writeReg(instr.i.rt, @as(u32, instr.i.imm) << 16);
    }

    fn opCop(self: *Self, comptime cop_num: u2, instr: Instruction) void {
        const sr = self.cop0.readReg(.sr);
        const cu = (sr >> 28) & 0xF;

        // COP0 is always usable in Kernel Mode (Bits 1-2 of SR are 0)
        const is_kernel = (sr & 0x2) == 0;
        const cop0_usable = (cop_num == 0) and is_kernel;
        const cop_usable = (cu & (@as(u32, 1) << cop_num)) != 0;

        if (!cop0_usable and !cop_usable) {
            self.exception(.CoprocessorUnusable, cop_num);
            return;
        }

        if (cop_num == 1 or cop_num == 3) {
            // Unimplemented but "usable" cops are NOPs
            return;
        }

        const sub_op = instr.r.rs; // rs field is used for sub-op in COP instructions
        const rt = instr.r.rt;
        const rd = instr.r.rd;

        switch (sub_op) {
            0x00 => { // MFCn
                const value = switch (cop_num) {
                    0 => self.cop0.readReg(rd),
                    2 => self.cop2.readData(rd),
                    else => unreachable,
                };
                self.writeReg(rt, value);
            },
            0x02 => { // CFCn
                const value = switch (cop_num) {
                    0 => {
                        std.log.warn("CFC0 is not supported", .{});
                        return self.exception(.ReservedInstruction, 0);
                    },
                    2 => self.cop2.readCtrl(rd),
                    else => unreachable,
                };
                self.writeReg(rt, value);
            },
            0x04 => { // MTCn
                const value = self.readReg(rt);
                switch (cop_num) {
                    0 => {
                        if (rd == 12) { // Status register
                            const old_status = self.cop0.readReg(.sr);
                            const old_isc = (old_status & (1 << 16)) != 0;
                            const new_isc = (value & (1 << 16)) != 0;
                            if (new_isc and !old_isc) {
                                // Isolate Cache enabled: invalidate entire I-cache to mimic BIOS flush
                                for (&self.icache) |*line| {
                                    line.tag = 0xFFFFFFFF;
                                }
                            }
                        }
                        self.cop0.writeReg(rd, value);
                    },
                    2 => self.cop2.writeData(rd, value),
                    else => unreachable,
                }
            },
            0x06 => { // CTCn
                const value = self.readReg(rt);
                switch (cop_num) {
                    0 => {
                        std.log.warn("CTC0 is not supported", .{});
                        return self.exception(.ReservedInstruction, 0);
                    },
                    2 => self.cop2.writeCtrl(rd, value),
                    else => unreachable,
                }
            },
            0x10...0x1F => {
                if (cop_num == 2) {
                    self.cop2.executeCommand(instr.raw);
                } else {
                    // For COP0, 0x10...0x1F are CO functions
                    const funct = instr.r.funct;
                    if (funct == 0x10) {
                        self.cop0.rfe();
                    } else {
                        // Unrecognised COP0 functions are NOPs on real hardware
                    }
                }
            },
            else => {
                std.log.warn("Unhandled COP{} sub-op: 0x{x:0>2}", .{ cop_num, sub_op });
                self.exception(.ReservedInstruction, 0);
            },
        }
    }

    inline fn opLoad(self: *Self, instr: Instruction, comptime ltype: LoadType, comptime signed: bool) void {
        const base = self.readReg(instr.i.rs);
        const offset = signExtend16(instr.i.imm);
        const address = base +% offset;

        // Alignment checks -> triggers Exception and populates BadVaddr
        if (ltype == .Word and address & 3 != 0 and (address & 0x1FFFFFFF) != 0x1F80105A) {
            self.cop0.setReg(.badvaddr, address);
            self.exception(.LoadAddressError, 0);
            return;
        }
        if (ltype == .Half and address & 1 != 0) {
            self.cop0.setReg(.badvaddr, address);
            self.exception(.LoadAddressError, 0);
            return;
        }

        // Read from memory. For IO, this might return unmasked words.
        const raw_val: u32 = switch (ltype) {
            .Word => self.bus.read32(address),
            .Half => self.bus.read16Raw(address),
            .Byte => self.bus.read8Raw(address),
        };

        // Sign or Zero Extend. If raw_val was unmasked, it stays unmasked for zero-extension!
        const final_val = if (signed) switch (ltype) {
            .Word => raw_val,
            .Half => signExtend16(@as(u16, @truncate(raw_val))),
            .Byte => signExtend8(@as(u8, @truncate(raw_val))),
        } else raw_val;

        // Put the result in the Load Delay queue, NOT directly into the register
        self.load_r = instr.i.rt;
        self.load_v = final_val;
    }

    inline fn opUnalignedLoad(self: *Self, instr: Instruction, comptime ul_type: UnalignedLoadType) void {
        const base = self.readReg(instr.i.rs);
        const offset = signExtend16(instr.i.imm);
        const address = base +% offset;

        // Always read the floor aligned word (masking out the bottom 2 bits)
        const aligned_addr = address & ~@as(u32, 3);
        const mem = self.bus.read32(aligned_addr);

        // Load Delay Bypass: Merge with the incoming load if targeting the same register!
        const current_val = if (self.delay_r == instr.i.rt) self.delay_v else self.readReg(instr.i.rt);
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
        self.load_r = instr.i.rt;
        self.load_v = merged;
    }

    inline fn isCacheIsolated(self: *const Self, address: u32) bool {
        const sr = self.cop0.readReg(Cop0.Reg.sr);
        const is_isolated = (sr & 0x10000) != 0; // Bit 16 is IsC (Isolate Cache)

        if (!is_isolated) return false;

        return !(address >= 0xA0000000 and address <= 0xBFFFFFFF);
    }

    inline fn opStore(self: *Self, instr: Instruction, comptime stype: StoreType) void {
        const base = self.readReg(instr.i.rs);
        const offset = signExtend16(instr.i.imm);
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

        const value = self.readReg(instr.i.rt);

        switch (stype) {
            .Word => self.bus.writeCpuStore(u32, address, value),
            .Half => self.bus.writeCpuStore(u16, address, value),
            .Byte => self.bus.writeCpuStore(u8, address, value),
        }
    }

    inline fn opUnalignedStore(self: *Self, instr: Instruction, comptime us_type: UnalignedStoreType) void {
        const base = self.readReg(instr.i.rs);
        const offset = signExtend16(instr.i.imm);
        const address = base +% offset;

        if (self.isCacheIsolated(address)) {
            return; // Drop the write
        }

        const aligned_addr = address & ~@as(u32, 3);
        const mem = self.bus.read32(aligned_addr);
        const val = self.readReg(instr.i.rt);
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

    inline fn opLwc(self: *Self, comptime cop_num: u2, instr: Instruction) void {
        const sr = self.cop0.readReg(.sr);
        const cu = (sr >> 28) & 0xF;
        const cop_usable = (cu & (@as(u32, 1) << cop_num)) != 0;

        if (!cop_usable) {
            self.exception(.CoprocessorUnusable, cop_num);
            return;
        }

        if (cop_num != 2) {
            // LWC0/1/3 are NOPs if usable
            return;
        }

        const base = self.readReg(instr.i.rs);
        const offset = signExtend16(instr.i.imm);
        const address = base +% offset;

        if (address & 3 != 0) {
            self.cop0.setReg(.badvaddr, address);
            self.exception(.LoadAddressError, 0);
            return;
        }

        // Read from Bus, Write directly to GTE Data Register
        const raw_val = self.bus.read32(address);
        self.cop2.writeData(instr.i.rt, raw_val);
    }

    inline fn opSwc(self: *Self, comptime cop_num: u2, instr: Instruction) void {
        const sr = self.cop0.readReg(.sr);
        const cu = (sr >> 28) & 0xF;
        const cop_usable = (cu & (@as(u32, 1) << cop_num)) != 0;

        if (!cop_usable) {
            self.exception(.CoprocessorUnusable, cop_num);
            return;
        }

        if (cop_num != 2) {
            // SWC0/1/3 are NOPs if usable
            return;
        }

        const base = self.readReg(instr.i.rs);
        const offset = signExtend16(instr.i.imm);
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
        const cop_val = self.cop2.readData(instr.i.rt);
        self.bus.write32(address, cop_val);
    }

    pub fn exception(self: *Self, code: Exception, cop_error: u2) void {
        const current_cause = self.cop0.readReg(Cop0.Reg.cause);
        var new_cause = (current_cause & 0x0000FF00) | (@as(u32, @intFromEnum(code)) << 2);

        if (code == .CoprocessorUnusable) {
            new_cause |= @as(u32, cop_error) << 28;
        }

        const epc = if (self.is_delay_slot) blk: {
            new_cause |= 1 << 31;
            break :blk self.current_pc -% 4;
        } else self.current_pc;

        self.cop0.setReg(Cop0.Reg.epc, epc);
        self.cop0.setReg(Cop0.Reg.cause, new_cause);

        self.enterException();
    }

    fn enterException(self: *Self) void {
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

    pub fn loadExe(self: *Self, file_data: []const u8) !void {
        if (file_data.len <= 0x800) return error.InvalidExeSize;
        if (!std.mem.eql(u8, file_data[0..8], "PS-X EXE")) return error.InvalidSignature;

        const init_pc = std.mem.readInt(u32, file_data[0x10..0x14], .little);
        const init_gp = std.mem.readInt(u32, file_data[0x14..0x18], .little);
        const dest_addr = std.mem.readInt(u32, file_data[0x18..0x1C], .little);
        const header_file_size = std.mem.readInt(u32, file_data[0x1C..0x20], .little);
        const init_sp_base = std.mem.readInt(u32, file_data[0x30..0x34], .little);
        const init_sp_offset = std.mem.readInt(u32, file_data[0x34..0x38], .little);
        const init_sp = init_sp_base +% init_sp_offset;

        const available_payload_size: u32 = @intCast(file_data.len - 0x800);
        const actual_file_size = if (header_file_size == 0) available_payload_size else header_file_size;
        const safe_file_size: usize = @intCast(@min(actual_file_size, available_payload_size));
        const ram_offset: usize = @intCast(dest_addr & 0x1FFFFF);
        const payload = file_data[0x800 .. 0x800 + safe_file_size];

        if (ram_offset + payload.len > self.bus.ram.len) return error.ExeTooLargeForRAM;
        @memcpy(self.bus.ram[ram_offset .. ram_offset + payload.len], payload);

        self.pc = init_pc;
        self.next_pc = init_pc +% 4;
        self.current_pc = init_pc;
        self.is_delay_slot = false;
        self.next_is_delay_slot = false;
        self.load_r = 0;
        self.load_v = 0;
        self.delay_r = 0;
        self.delay_v = 0;

        if (init_gp != 0) self.writeReg(.gp, init_gp);
        if (init_sp != 0) self.writeReg(.sp, init_sp);

        // Clear instruction cache to prevent executing stale BIOS instructions
        self.icache = [_]CacheLine{.{}} ** 256;

        // Silence the SPU to prevent trailing BIOS audio from looping
        self.bus.spu.main_vol_l = 0;
        self.bus.spu.main_vol_r = 0;
        for (&self.bus.spu.voices) |*v| {
            v.is_on = false;
            v.adsr_state = .Off;
        }

        std.log.info("PS-EXE loaded: PC=0x{x:0>8} GP=0x{x:0>8} SP=0x{x:0>8}", .{ init_pc, init_gp, init_sp });
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
