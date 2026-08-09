const std = @import("std");
const Bus = @import("../memory.zig").Bus;
pub const Cop0 = @import("../cop0.zig").Cop0;
pub const Cop2 = @import("../cop2/cop2.zig").Cop2;
const icache = @import("icache.zig");
const exec = @import("exec.zig");

pub const Cpu = struct {
    const Self = @This();

    pub const CacheLine = icache.CacheLine;

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
    // Carry for the CPU->video clock conversion. The GPU/video clock runs at
    // 11/7 the CPU clock (53.2224 MHz vs 33.8688 MHz); gpu.step() is denominated
    // in video cycles, so CPU cycles are scaled before being handed to it.
    gpu_clock_frac: u32 = 0,
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
        const instruction = icache.fetchInstruction(self, self.current_pc);

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
            self.pc = self.next_pc;
            self.next_pc = self.pc +% 4;
            self.is_delay_slot = self.next_is_delay_slot;
            self.next_is_delay_slot = false;

            self.delay_r = self.load_r;
            self.delay_v = self.load_v;

            self.load_r = 0;
            self.load_v = 0;

            exec.execute(self, instruction);

            // Apply the load that lands this cycle. An explicit register write during
            // execute() cancels it (writeReg clears delay_r), matching the R3000A
            // pipeline / Avocado setReg(): a delay-slot instruction's own write to the
            // load's target register wins over the load's delayed writeback.
            if (self.delay_r != 0) {
                self.regs[self.delay_r] = self.delay_v;
            }
            self.regs[0] = 0;
        }

        self.tickPeripherals(delta_cycles);
        self.bus.dma.tickCpuWindow(delta_cycles);
    }

    fn tickPeripherals(self: *Self, delta_cycles: u32) void {
        self.cycles +%= delta_cycles;
        self.bus.sys_clock = self.cycles;

        self.bus.spu.step(delta_cycles);

        // Convert CPU cycles to video-clock cycles (11/7) for the GPU. Without
        // this the vblank period is ~1.57x too long relative to the CPU-cycle
        // root counters, so the BIOS VSync wait times out during KERNEL SETUP
        // and the boot hangs.
        const gpu_scaled = delta_cycles * 11 + self.gpu_clock_frac;
        const gpu_cycles = gpu_scaled / 7;
        self.gpu_clock_frac = gpu_scaled % 7;
        const gpu_result = self.bus.gpu.step(gpu_cycles);

        if (gpu_result.trigger_vblank_irq) {
            self.bus.interrupts.trigger(.Vblank);
        }
        if (gpu_result.trigger_gp0_irq) {
            self.bus.interrupts.trigger(.Gpu);
        }
        if (self.bus.spu.irq_flag) {
            self.bus.interrupts.trigger(.Spu);
        }

        // Controller/memcard port: /ACK arrives a few instructions after a byte
        // is clocked out, so the IRQ is raised here rather than from the write.
        if (self.bus.sio.step()) {
            self.bus.interrupts.trigger(.Controller);
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
        if (i != 0) {
            self.regs[i] = value;
            // An explicit write supersedes a load-delay result landing this same
            // cycle: cancel the pending load to this register (see step()).
            if (i == self.delay_r) self.delay_r = 0;
        }
    }

    inline fn getIdx(self: *const Self, index: anytype) u5 {
        _ = self;
        return switch (@typeInfo(@TypeOf(index))) {
            .int, .comptime_int => @as(u5, @truncate(index)),
            else => @intFromEnum(@as(Reg, index)),
        };
    }

    pub fn isCacheIsolated(self: *const Self, address: u32) bool {
        const sr = self.cop0.readReg(Cop0.Reg.sr);
        const is_isolated = (sr & 0x10000) != 0; // Bit 16 is IsC (Isolate Cache)

        if (!is_isolated) return false;

        return !(address >= 0xA0000000 and address <= 0xBFFFFFFF);
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
            v.env.state = .Off;
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
