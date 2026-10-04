//! Shared by the block-engine tests: hand-assembled MIPS, a machine on a
//! chosen engine, and a whole-machine comparison between two of them.

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const alloc = std.testing.allocator;

const ps1_core = @import("ps1_core");
const Bus = ps1_core.memory.Bus;
const Cpu = ps1_core.cpu.Cpu;
const recompiler = ps1_core.recompiler;
const Engine = recompiler.Engine;
const lockstep = recompiler.lockstep;

pub const zero: u5 = 0;
pub const a0: u5 = 4;
pub const t0: u5 = 8;
pub const t1: u5 = 9;
pub const t2: u5 = 10;
pub const t3: u5 = 11;
pub const t4: u5 = 12;
pub const t5: u5 = 13;
pub const t6: u5 = 14;
pub const t7: u5 = 15;
pub const k0: u5 = 26;
pub const k1: u5 = 27;
pub const ra: u5 = 31;

/// MIPS encoders. Branch offsets count instructions from the delay slot.
pub const mips = struct {
    pub const nop: u32 = 0;
    pub const rfe: u32 = 0x4200_0010;
    pub const syscall: u32 = 0x0000_000C;
    pub const brk: u32 = 0x0000_000D;
    /// GTE SQR, sf=0: MAC1..3 = IR1..3 squared.
    pub const gte_sqr: u32 = 0x4A00_0028;

    pub fn i(op: u32, rs: u5, rt: u5, imm: u16) u32 {
        return op << 26 | @as(u32, rs) << 21 | @as(u32, rt) << 16 | imm;
    }
    pub fn r(rs: u5, rt: u5, rd: u5, funct: u32) u32 {
        return @as(u32, rs) << 21 | @as(u32, rt) << 16 | @as(u32, rd) << 11 | funct;
    }
    pub fn addiu(rt: u5, rs: u5, imm: u16) u32 {
        return i(0x09, rs, rt, imm);
    }
    pub fn lui(rt: u5, imm: u16) u32 {
        return i(0x0F, 0, rt, imm);
    }
    pub fn ori(rt: u5, rs: u5, imm: u16) u32 {
        return i(0x0D, rs, rt, imm);
    }
    pub fn lw(rt: u5, base: u5, off: u16) u32 {
        return i(0x23, base, rt, off);
    }
    pub fn sw(rt: u5, base: u5, off: u16) u32 {
        return i(0x2B, base, rt, off);
    }
    pub fn addu(rd: u5, rs: u5, rt: u5) u32 {
        return r(rs, rt, rd, 0x21);
    }
    pub fn add(rd: u5, rs: u5, rt: u5) u32 {
        return r(rs, rt, rd, 0x20);
    }
    pub fn beq(rs: u5, rt: u5, off: i16) u32 {
        return i(0x04, rs, rt, @bitCast(off));
    }
    pub fn bne(rs: u5, rt: u5, off: i16) u32 {
        return i(0x05, rs, rt, @bitCast(off));
    }
    pub fn j(target: u32) u32 {
        return 0x02 << 26 | ((target >> 2) & 0x03FF_FFFF);
    }
    pub fn jr(rs: u5) u32 {
        return r(rs, 0, 0, 0x08);
    }
    pub fn mfc0(rt: u5, rd: u5) u32 {
        return 0x10 << 26 | @as(u32, rt) << 16 | @as(u32, rd) << 11;
    }
    pub fn mtc0(rt: u5, rd: u5) u32 {
        return 0x10 << 26 | 0x04 << 21 | @as(u32, rt) << 16 | @as(u32, rd) << 11;
    }
};

pub fn poke(bus: *Bus, addr: u32, words: []const u32) void {
    for (words, 0..) |w, k| bus.write32(addr + @as(u32, @intCast(k)) * 4, w);
}

pub fn nops(comptime n: usize) [n]u32 {
    return @splat(mips.nop);
}

pub const Machine = struct {
    bus: *Bus,
    cpu: Cpu,

    pub fn init(engine: Engine) !Machine {
        const bus = try Bus.init(alloc);
        var m: Machine = .{ .bus = bus, .cpu = Cpu.init(bus) };
        try recompiler.setEngine(&m.cpu, alloc, engine);
        return m;
    }

    pub fn deinit(m: *Machine) void {
        m.bus.deinit(alloc);
    }

    pub fn start(m: *Machine, pc: u32) void {
        // `poke`'s host writes bill wait states to the next instruction.
        m.bus.wait_cycles = 0;
        m.cpu.pipeline.pc = pc;
        m.cpu.pipeline.next_pc = pc +% 4;
    }

    pub fn runUntil(m: *Machine, pc: u32) !void {
        var n: u32 = 0;
        while (m.cpu.pipeline.pc != pc) : (n += 1) {
            if (n == 100_000) return error.NeverReached;
            _ = m.cpu.run();
        }
    }
};

/// A loop with stores, loads read in their delay slot, a branch delay slot
/// and a load in a delay slot whose value lands inside the NEXT block.
pub const loop_program = [_]u32{
    mips.addiu(t0, zero, 0), // 0x1000
    mips.addiu(t1, zero, 10),
    mips.lui(t2, 0x8000),
    mips.ori(t2, t2, 0x2000),
    mips.sw(t1, t2, 0), // 0x1010 loop:
    mips.lw(t3, t2, 0),
    mips.addu(t0, t0, t3), // reads the previous t3: load delay
    mips.addiu(t2, t2, 4),
    mips.addiu(t1, t1, 0xFFFF),
    mips.bne(t1, zero, -6), // -> 0x1010
    mips.addu(t0, t0, t3), // delay slot
    mips.lw(t4, t2, 0xFFFC),
    mips.beq(zero, zero, 3), // -> 0x1040
    mips.lw(t5, t2, 0xFFF8), // delay slot: lands after done's first instruction
    mips.nop,
    mips.nop,
    mips.addu(t6, t5, zero), // 0x1040 done: the OLD t5
    mips.addu(t7, t5, zero), // the new t5
    mips.beq(zero, zero, -1), // 0x1048 end
    mips.nop,
};

pub const gp: u5 = 28;

/// The RAM `expectSameMachine` compares: the exception vector, every test
/// program and the fuzzer's data window all lie below it.
pub const compared_ram = 0x5000;

/// Everything a block can change, `dut` against `ref`: the architectural
/// state, the clocks and the scheduler's backlog, the two stop flags, the
/// low RAM and the scratchpad.
pub fn expectSameMachine(ref: *const Machine, dut: *const Machine) !void {
    if (lockstep.compareArch(&lockstep.Arch.capture(&dut.cpu), &lockstep.Arch.capture(&ref.cpu))) |mm| {
        std.debug.print("machines differ: {s} {d}: 0x{x} against 0x{x}\n", .{ mm.what, mm.index, mm.engine, mm.reference });
        return error.MachinesDiffer;
    }
    try expectEqual(ref.cpu.cycles, dut.cpu.cycles);
    try expectEqual(ref.bus.sys_clock, dut.bus.sys_clock);
    try expectEqual(ref.bus.sched.downcount, dut.bus.sched.downcount);
    try expectEqual(ref.bus.sched.pending, dut.bus.sched.pending);
    try expectEqual(ref.bus.sched.pending_steps, dut.bus.sched.pending_steps);
    try expectEqual(ref.cpu.exception_taken, dut.cpu.exception_taken);
    try expectEqual(ref.bus.block_exit, dut.bus.block_exit);
    try std.testing.expectEqualSlices(u8, ref.bus.ram[0..compared_ram], dut.bus.ram[0..compared_ram]);
    try std.testing.expectEqualSlices(u8, &ref.bus.scratchpad, &dut.bus.scratchpad);
}
