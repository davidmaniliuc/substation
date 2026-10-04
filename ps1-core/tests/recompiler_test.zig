//! The block engines: where a block ends, how the cache stays honest when
//! code is rewritten, and the dispatcher's timing and interrupt rules. These
//! are the block engines' own contracts. They are not bit-exact against the
//! interpreter, so nothing here compares cycle counts with it.

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const alloc = std.testing.allocator;

const ps1_core = @import("ps1_core");
const Bus = ps1_core.memory.Bus;
const Cpu = ps1_core.cpu.Cpu;
const recompiler = ps1_core.recompiler;
const block = recompiler.block;

// Register numbers for the hand-written programs.
const zero: u5 = 0;
const a0: u5 = 4;
const t0: u5 = 8;
const t1: u5 = 9;
const t2: u5 = 10;
const t3: u5 = 11;
const t4: u5 = 12;
const t5: u5 = 13;
const t6: u5 = 14;
const t7: u5 = 15;
const k0: u5 = 26;
const k1: u5 = 27;
const ra: u5 = 31;

/// MIPS encoders. Branch offsets count instructions from the delay slot.
const mips = struct {
    const nop: u32 = 0;
    const rfe: u32 = 0x4200_0010;
    const syscall: u32 = 0x0000_000C;
    const brk: u32 = 0x0000_000D;
    /// GTE SQR, sf=0: MAC1..3 = IR1..3 squared.
    const gte_sqr: u32 = 0x4A00_0028;

    fn i(op: u32, rs: u5, rt: u5, imm: u16) u32 {
        return op << 26 | @as(u32, rs) << 21 | @as(u32, rt) << 16 | imm;
    }
    fn r(rs: u5, rt: u5, rd: u5, funct: u32) u32 {
        return @as(u32, rs) << 21 | @as(u32, rt) << 16 | @as(u32, rd) << 11 | funct;
    }
    fn addiu(rt: u5, rs: u5, imm: u16) u32 {
        return i(0x09, rs, rt, imm);
    }
    fn lui(rt: u5, imm: u16) u32 {
        return i(0x0F, 0, rt, imm);
    }
    fn ori(rt: u5, rs: u5, imm: u16) u32 {
        return i(0x0D, rs, rt, imm);
    }
    fn lw(rt: u5, base: u5, off: u16) u32 {
        return i(0x23, base, rt, off);
    }
    fn sw(rt: u5, base: u5, off: u16) u32 {
        return i(0x2B, base, rt, off);
    }
    fn addu(rd: u5, rs: u5, rt: u5) u32 {
        return r(rs, rt, rd, 0x21);
    }
    fn add(rd: u5, rs: u5, rt: u5) u32 {
        return r(rs, rt, rd, 0x20);
    }
    fn beq(rs: u5, rt: u5, off: i16) u32 {
        return i(0x04, rs, rt, @bitCast(off));
    }
    fn bne(rs: u5, rt: u5, off: i16) u32 {
        return i(0x05, rs, rt, @bitCast(off));
    }
    fn j(target: u32) u32 {
        return 0x02 << 26 | ((target >> 2) & 0x03FF_FFFF);
    }
    fn jr(rs: u5) u32 {
        return r(rs, 0, 0, 0x08);
    }
    fn mfc0(rt: u5, rd: u5) u32 {
        return 0x10 << 26 | @as(u32, rt) << 16 | @as(u32, rd) << 11;
    }
    fn mtc0(rt: u5, rd: u5) u32 {
        return 0x10 << 26 | 0x04 << 21 | @as(u32, rt) << 16 | @as(u32, rd) << 11;
    }
};

fn poke(bus: *Bus, addr: u32, words: []const u32) void {
    for (words, 0..) |w, k| bus.write32(addr + @as(u32, @intCast(k)) * 4, w);
}

fn nops(comptime n: usize) [n]u32 {
    return @splat(mips.nop);
}

fn compileAt(bus: *Bus, pc: u32) !*block.Block {
    return block.compile(alloc, bus, pc);
}

test "a block ends after a branch's delay slot" {
    const bus = try Bus.init(alloc);
    defer bus.deinit(alloc);
    poke(bus, 0x1000, &.{ mips.nop, mips.nop, mips.beq(zero, zero, 4), mips.nop, mips.nop });
    const b = try compileAt(bus, 0x8000_1000);
    defer block.destroy(alloc, b);
    try expectEqual(@as(usize, 4), b.ops.len);
    try expectEqual(@as(u32, 0x8000_1000), b.start_pc);
}

test "the length cap ends a block at 64 instructions" {
    const bus = try Bus.init(alloc);
    defer bus.deinit(alloc);
    poke(bus, 0x2000, &nops(100));
    const b = try compileAt(bus, 0x2000);
    defer block.destroy(alloc, b);
    try expectEqual(@as(usize, block.max_len), b.ops.len);
}

test "a branch at the length cap stretches the block by its delay slot" {
    const bus = try Bus.init(alloc);
    defer bus.deinit(alloc);
    poke(bus, 0x2000, &nops(63));
    poke(bus, 0x2000 + 63 * 4, &.{ mips.beq(zero, zero, 4), mips.nop, mips.nop });
    const b = try compileAt(bus, 0x2000);
    defer block.destroy(alloc, b);
    try expectEqual(@as(usize, block.max_len + 1), b.ops.len);
}

test "a 4 KB page edge ends a block" {
    const bus = try Bus.init(alloc);
    defer bus.deinit(alloc);
    poke(bus, 0x3FF0, &nops(8));
    const b = try compileAt(bus, 0x3FF0);
    defer block.destroy(alloc, b);
    try expectEqual(@as(usize, 4), b.ops.len);
    try expectEqual(b.first_page, b.last_page);
}

test "a branch in a page's last word takes its delay slot from the next page" {
    const bus = try Bus.init(alloc);
    defer bus.deinit(alloc);
    poke(bus, 0x4FF8, &.{ mips.nop, mips.beq(zero, zero, 4), mips.nop, mips.nop });
    const b = try compileAt(bus, 0x4FF8);
    defer block.destroy(alloc, b);
    try expectEqual(@as(usize, 3), b.ops.len);
    try expectEqual(@as(u16, 4), b.first_page);
    try expectEqual(@as(u16, 5), b.last_page);
}

test "mtc0, rfe, syscall and break each end a block" {
    const bus = try Bus.init(alloc);
    defer bus.deinit(alloc);
    for ([_]u32{ mips.mtc0(t0, 12), mips.rfe, mips.syscall, mips.brk }) |ender| {
        poke(bus, 0x6000, &.{ mips.nop, ender, mips.nop, mips.nop });
        const b = try compileAt(bus, 0x6000);
        defer block.destroy(alloc, b);
        try expectEqual(@as(usize, 2), b.ops.len);
    }
}

test "loads and stores are flagged for the mid-block cycle commit" {
    const bus = try Bus.init(alloc);
    defer bus.deinit(alloc);
    poke(bus, 0x7000, &.{ mips.addiu(t0, zero, 1), mips.lw(t1, t0, 0), mips.sw(t1, t0, 0), mips.jr(ra), mips.nop });
    const b = try compileAt(bus, 0x7000);
    defer block.destroy(alloc, b);
    try expect(!b.ops[0].memory);
    try expect(b.ops[1].memory);
    try expect(b.ops[2].memory);
    try expect(!b.ops[3].memory);
}

test "a BIOS block decodes from the BIOS image" {
    const bus = try Bus.init(alloc);
    defer bus.deinit(alloc);
    std.mem.writeInt(u32, bus.bios[0..4], mips.addiu(t0, zero, 7), .little);
    std.mem.writeInt(u32, bus.bios[4..8], mips.jr(ra), .little);
    const b = try compileAt(bus, 0xBFC0_0000);
    defer block.destroy(alloc, b);
    try expectEqual(@as(usize, 3), b.ops.len);
    try expectEqual(mips.addiu(t0, zero, 7), b.ops[0].instr.raw);
    try expectEqual(@as(?block.Region, .bios), block.regionOf(0x1FC0_0000));
    try expectEqual(@as(?block.Region, null), block.regionOf(0x1F80_0000));
}

const BlockCache = recompiler.cache.BlockCache;

/// A bus carrying a block cache, as `recompiler.setEngine(.cached)` will
/// leave it (Task 5); `Bus.deinit` frees it.
fn busWithCache() !*Bus {
    const bus = try Bus.init(alloc);
    bus.blocks = try BlockCache.create(alloc);
    return bus;
}

fn compileInto(bus: *Bus, pc: u32) !*block.Block {
    const b = try block.compile(alloc, bus, pc);
    try bus.blocks.?.insert(pc & 0x1FFF_FFFF, b);
    return b;
}

/// Starts an OTC DMA (channel 6) that writes `words` words ending at
/// `last`, and runs it to completion the way `Cpu.step()` would.
fn runOtc(bus: *Bus, last: u32, words: u32) void {
    bus.write32(0x1F8010F0, 0x0800_0000); // DPCR: channel 6 enabled
    bus.write32(0x1F8010E0, last); // MADR
    bus.write32(0x1F8010E4, words); // BCR
    bus.write32(0x1F8010E8, 0x1100_0002); // start + trigger, decrementing
    while (bus.dma.isCpuStalled(bus)) _ = bus.dma.step(bus);
}

test "a CPU store into a code page drops the page's blocks" {
    const bus = try busWithCache();
    defer bus.deinit(alloc);
    poke(bus, 0x1000, &.{ mips.jr(ra), mips.nop });
    poke(bus, 0x9000, &.{ mips.jr(ra), mips.nop });
    _ = try compileInto(bus, 0x1000);
    _ = try compileInto(bus, 0x9000);

    bus.write32(0x1F00, 0x1234); // same 4 KB page as 0x1000
    try expectEqual(@as(?*block.Block, null), bus.blocks.?.lookup(0x1000));
    try expect(bus.blocks.?.lookup(0x9000) != null); // another page: untouched
    try expectEqual(@as(u32, 1), bus.blocks.?.invalidations[1]);
    try expect(!bus.block_exit); // nothing was running
    bus.blocks.?.reap();
}

test "a store through a RAM mirror drops the same blocks" {
    const bus = try busWithCache();
    defer bus.deinit(alloc);
    poke(bus, 0x1000, &.{ mips.jr(ra), mips.nop });
    _ = try compileInto(bus, 0x1000);
    bus.write32(0x0060_1004, 0); // 6 MB mirror of 0x1004
    try expectEqual(@as(?*block.Block, null), bus.blocks.?.lookup(0x1000));
    bus.blocks.?.reap();
}

test "a DMA into a code page drops the page's blocks" {
    const bus = try busWithCache();
    defer bus.deinit(alloc);
    poke(bus, 0x2000, &.{ mips.jr(ra), mips.nop });
    _ = try compileInto(bus, 0x2000);
    runOtc(bus, 0x203C, 16); // writes 0x2000..0x203C
    try expectEqual(@as(?*block.Block, null), bus.blocks.?.lookup(0x2000));
    bus.blocks.?.reap();
}

test "a write to either page of a page-crossing block drops it" {
    for ([_]u32{ 0x4000, 0x5004 }) |target| {
        const bus = try busWithCache();
        defer bus.deinit(alloc);
        poke(bus, 0x4FF8, &.{ mips.nop, mips.beq(zero, zero, 4), mips.nop, mips.nop });
        _ = try compileInto(bus, 0x4FF8);
        bus.write32(target, 0);
        try expectEqual(@as(?*block.Block, null), bus.blocks.?.lookup(0x4FF8));
        bus.blocks.?.reap();
        // Neither page still claims code: a second write costs nothing.
        bus.write32(0x4000, 0);
        bus.write32(0x5004, 0);
        try expectEqual(@as(u32, 1), bus.blocks.?.invalidations[4] + bus.blocks.?.invalidations[5]);
    }
}

test "a store that drops the running block raises block_exit and leaves it alive" {
    const bus = try busWithCache();
    defer bus.deinit(alloc);
    poke(bus, 0x1000, &.{ mips.nop, mips.jr(ra), mips.nop });
    const b = try compileInto(bus, 0x1000);
    bus.blocks.?.running = b;
    bus.write32(0x1004, mips.nop);
    try expect(bus.block_exit);
    try expect(b.dead);
    try expectEqual(@as(usize, 3), b.ops.len); // still readable until reaped
    bus.blocks.?.running = null;
    bus.blocks.?.reap();
}

test "an MMIO store raises block_exit; RAM and scratchpad stores do not" {
    const bus = try busWithCache();
    defer bus.deinit(alloc);
    bus.write32(0x0000_8000, 1);
    try expect(!bus.block_exit);
    bus.write32(0x1F80_0000, 1); // scratchpad
    try expect(!bus.block_exit);
    bus.write32(0x1F80_1128, 100); // timer 2 target
    try expect(bus.block_exit);
}

test "BIOS blocks survive RAM writes; flush frees everything" {
    const bus = try busWithCache();
    defer bus.deinit(alloc);
    std.mem.writeInt(u32, bus.bios[0..4], mips.jr(ra), .little);
    poke(bus, 0x1000, &.{ mips.jr(ra), mips.nop });
    _ = try compileInto(bus, 0xBFC0_0000);
    _ = try compileInto(bus, 0x1000);
    bus.write32(0x0, 0);
    bus.write32(0x1000 - 4, 0); // page 0 and page 1
    try expect(bus.blocks.?.lookup(0x1FC0_0000) != null);
    bus.blocks.?.flush();
    try expectEqual(@as(?*block.Block, null), bus.blocks.?.lookup(0x1FC0_0000));
    try expectEqual(@as(?*block.Block, null), bus.blocks.?.lookup(0x1000));
    // The testing allocator fails the test if flush leaked a block.
}

const Engine = recompiler.Engine;

const Machine = struct {
    bus: *Bus,
    cpu: Cpu,

    fn init(engine: Engine) !Machine {
        const bus = try Bus.init(alloc);
        var m: Machine = .{ .bus = bus, .cpu = Cpu.init(bus) };
        try recompiler.setEngine(&m.cpu, alloc, engine);
        return m;
    }

    fn deinit(m: *Machine) void {
        m.bus.deinit(alloc);
    }

    fn start(m: *Machine, pc: u32) void {
        // `poke`'s host writes bill wait states to the next instruction.
        m.bus.wait_cycles = 0;
        m.cpu.pipeline.pc = pc;
        m.cpu.pipeline.next_pc = pc +% 4;
    }

    fn runUntil(m: *Machine, pc: u32) !void {
        var n: u32 = 0;
        while (m.cpu.pipeline.pc != pc) : (n += 1) {
            if (n == 100_000) return error.NeverReached;
            _ = m.cpu.run();
        }
    }
};

/// A loop with stores, loads read in their delay slot, a branch delay slot
/// and a load in a delay slot whose value lands inside the NEXT block.
const loop_program = [_]u32{
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

test "the cached interpreter computes what the interpreter computes" {
    var ref = try Machine.init(.interpreter);
    defer ref.deinit();
    var blk = try Machine.init(.cached);
    defer blk.deinit();
    for ([_]*Machine{ &ref, &blk }) |m| {
        poke(m.bus, 0x1000, &loop_program);
        m.start(0x8000_1000);
        try m.runUntil(0x8000_1048);
    }
    try std.testing.expectEqualSlices(u32, &ref.cpu.regs, &blk.cpu.regs);
    try std.testing.expectEqualSlices(u8, ref.bus.ram[0x2000..0x2028], blk.bus.ram[0x2000..0x2028]);
    try expectEqual(@as(u32, 0), blk.cpu.regs[t6]); // load crossed the block boundary
    try expectEqual(@as(u32, 2), blk.cpu.regs[t7]);
}

test "an overflow inside a block is precise" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x1000, &.{
        mips.addiu(t0, zero, 1),
        mips.lui(t1, 0x7FFF),
        mips.ori(t1, t1, 0xFFFF),
        mips.add(t2, t1, t0), // 0x100C: overflows
        mips.addiu(t3, zero, 7), // must not run
        mips.jr(ra),
        mips.nop,
    });
    m.start(0x1000);
    _ = m.cpu.run();
    try expectEqual(@as(u32, 0x8000_0080), m.cpu.pipeline.pc);
    try expectEqual(@as(u32, 0x100C), m.cpu.cop0.readReg(.epc));
    try expectEqual(@as(u32, 0x0C), (m.cpu.cop0.readReg(.cause) >> 2) & 0x1F);
    try expectEqual(@as(u32, 0), m.cpu.regs[t2]);
    try expectEqual(@as(u32, 0), m.cpu.regs[t3]);
    // Four instructions, faulting one included, at RAM's cached fetch cost of 0.
    try expectEqual(@as(u64, 4), m.cpu.cycles);
}

test "an MMIO read mid-block sees the block's elapsed cycles" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x1000, &(.{
        mips.lui(t1, 0x1F80),
        mips.ori(t1, t1, 0x1120), // timer 2 counter, sysclk
        mips.lw(t2, t1, 0),
    } ++ nops(10) ++ .{
        mips.lw(t3, t1, 0),
        mips.nop,
        mips.beq(zero, zero, -1),
        mips.nop,
    }));
    m.start(0x1000);
    _ = m.cpu.run();
    // Between the two commits: 11 instructions at 1 cycle (fetch cost 0)
    // plus the first lw's 2 I/O wait states.
    try expectEqual(@as(u32, 13), m.cpu.regs[t3] - m.cpu.regs[t2]);
}

test "a store into the running block ends it; the rewrite runs next" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x1000, &.{
        mips.addiu(t1, zero, 0x1010),
        mips.lui(t0, 0x240A),
        mips.ori(t0, t0, 0x0055), // t0 = addiu t2, zero, 0x55
        mips.sw(t0, t1, 0), // rewrites 0x1010
        mips.addiu(t2, zero, 0x11), // 0x1010: the old instruction
        mips.beq(zero, zero, -1),
        mips.nop,
    });
    m.start(0x1000);
    _ = m.cpu.run();
    try expectEqual(@as(u32, 0x1010), m.cpu.pipeline.pc);
    try expectEqual(@as(u32, 0), m.cpu.regs[t2]);
    try expectEqual(@as(?*block.Block, null), m.bus.blocks.?.lookup(0x1000));
    _ = m.cpu.run();
    try expectEqual(@as(u32, 0x55), m.cpu.regs[t2]);
}

test "the same block charges each segment's fetch cost" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x3000, &.{ mips.nop, mips.nop, mips.nop, mips.j(0x3000), mips.nop });
    m.start(0x8000_3000);
    var before = m.cpu.cycles;
    _ = m.cpu.run();
    try expectEqual(@as(u64, 5), m.cpu.cycles - before); // KSEG0: a cache hit, free
    m.start(0xA000_3000);
    before = m.cpu.cycles;
    _ = m.cpu.run();
    try expectEqual(@as(u64, 25), m.cpu.cycles - before); // KSEG1: RAM's 4 per word
}

test "a block ticks SIO once per instruction" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x1000, &(nops(10) ++ .{ mips.j(0x1000), mips.nop }));
    m.bus.write8(0x1F801040, 0x01); // select the pad: arms /ACK
    ps1_core.scheduler.serviceDue(m.bus);
    const before = m.bus.sio.irq_timer;
    try expect(before > 12);
    m.start(0x1000);
    _ = m.cpu.run();
    ps1_core.scheduler.sync(m.bus);
    try expectEqual(before - 12, m.bus.sio.irq_timer);
}

test "engine selection allocates, switches and frees the cache" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    try expectEqual(Engine.cached, recompiler.engineOf(m.bus));
    try recompiler.setEngine(&m.cpu, alloc, .interpreter);
    try expectEqual(@as(?*BlockCache, null), m.bus.blocks);
    try expectEqual(Engine.interpreter, recompiler.engineOf(m.bus));
    try std.testing.expectError(error.EngineUnavailable, recompiler.setEngine(&m.cpu, alloc, .jit));
}

test "re-applying the current engine changes nothing" {
    var m = try Machine.init(.interpreter);
    defer m.deinit();
    poke(m.bus, 0x1000, &nops(4));
    m.start(0x8000_1000);
    _ = m.cpu.run();
    _ = m.cpu.run();
    const lines = m.cpu.icache;
    try recompiler.setEngine(&m.cpu, alloc, .interpreter);
    try std.testing.expectEqualSlices(Cpu.CacheLine, &lines, &m.cpu.icache);

    try recompiler.setEngine(&m.cpu, alloc, .cached);
    const c = m.bus.blocks.?;
    m.start(0x1000);
    _ = m.cpu.run();
    try expect(c.lookup(0x1000) != null);
    try recompiler.setEngine(&m.cpu, alloc, .cached);
    try expect(m.bus.blocks.? == c);
    try expect(c.lookup(0x1000) != null);
}

const Irq = ps1_core.interrupt.Irq;

fn raiseVblank(m: *Machine, sr_extra: u32) void {
    m.cpu.cop0.writeReg(.sr, sr_extra | (1 << 10) | 1); // IM2, IEc
    m.bus.interrupts.writeMask(1 << @backingInt(Irq.Vblank));
    m.bus.interrupts.trigger(.Vblank);
}

test "an interrupt is taken at a branch target, with EPC on the target" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x1000, &.{ mips.beq(zero, zero, 63), mips.nop }); // -> 0x1100
    poke(m.bus, 0x1100, &.{ mips.addiu(t0, zero, 1), mips.beq(zero, zero, -1), mips.nop });
    m.start(0x1000);
    _ = m.cpu.run(); // the branch and its delay slot: is_delay_slot is left set
    try expectEqual(@as(u32, 0x1100), m.cpu.pipeline.pc);
    raiseVblank(&m, 0);
    _ = m.cpu.run();
    try expectEqual(@as(u32, 0x8000_0080), m.cpu.pipeline.pc);
    try expectEqual(@as(u32, 0x1100), m.cpu.cop0.readReg(.epc));
    try expectEqual(@as(u32, 0), m.cpu.cop0.readReg(.cause) >> 31); // BD clear
    try expectEqual(@as(u32, 0), m.cpu.regs[t0]);
}

fn gteBlockMachine(irq: bool) !Machine {
    var m = try Machine.init(.cached);
    poke(m.bus, 0x1100, &.{ mips.gte_sqr, mips.beq(zero, zero, 0x3E), mips.nop }); // -> 0x1200
    poke(m.bus, 0x1200, &.{ mips.nop, mips.beq(zero, zero, -2), mips.nop });
    m.cpu.cop2.writeData(9, 4);
    // At power-on the devices' countdowns are unarmed, so the deadline is 1
    // cycle and every block overruns it. Advance them once to arm a real one.
    m.cpu.chargeCycles(1, 1);
    ps1_core.scheduler.sync(m.bus);
    if (irq) raiseVblank(&m, 1 << 30) else m.cpu.cop0.writeReg(.sr, 1 << 30); // CU2
    m.start(0x1100);
    return m;
}

test "an interrupt is refused before a GTE command and taken one instruction later" {
    var m = try gteBlockMachine(true);
    defer m.deinit();
    _ = m.cpu.run();
    try expectEqual(@as(u32, 16), m.cpu.cop2.readData(9)); // the command ran
    try expectEqual(@as(u32, 0x1104), m.cpu.pipeline.pc); // alone, not taken
    // The refusal zeroed downcount, so the closing serviceDue flushed.
    try expectEqual(@as(u32, 0), m.bus.sched.pending);
    _ = m.cpu.run();
    try expectEqual(@as(u32, 0x8000_0080), m.cpu.pipeline.pc);
    try expectEqual(@as(u32, 0x1104), m.cpu.cop0.readReg(.epc));
}

test "a loop whose head is a GTE command still takes an interrupt" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x1100, &.{ mips.gte_sqr, mips.beq(zero, zero, -2), mips.nop }); // -> 0x1100
    raiseVblank(&m, 1 << 30); // CU2
    m.start(0x1100);
    var n: u32 = 0;
    while (m.cpu.pipeline.pc != 0x8000_0080) : (n += 1) {
        try expect(n < 4);
        _ = m.cpu.run();
    }
    try expectEqual(@as(u32, 0x1104), m.cpu.cop0.readReg(.epc));
}

test "without an interrupt the same block defers its cycles" {
    var m = try gteBlockMachine(false);
    defer m.deinit();
    _ = m.cpu.run();
    try expect(m.bus.sched.pending > 0);
}

test "a block engine resumed on a delay slot runs it as one interpreter step" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x1000, &.{ mips.beq(zero, zero, 63), mips.addiu(t0, zero, 5) }); // -> 0x1100
    poke(m.bus, 0x1100, &.{ mips.addiu(t1, zero, 6), mips.beq(zero, zero, -1), mips.nop });
    m.start(0x1000);
    m.cpu.step(); // the interpreter runs the branch: next is its delay slot
    try expect(m.cpu.pipeline.next_is_delay_slot);
    _ = m.cpu.run();
    try expectEqual(@as(u32, 5), m.cpu.regs[t0]);
    try expectEqual(@as(u32, 0x1100), m.cpu.pipeline.pc);
    try expectEqual(@as(u32, 0), m.cpu.regs[t1]);
    _ = m.cpu.run();
    try expectEqual(@as(u32, 6), m.cpu.regs[t1]);
}

test "the interpreter runs while the cache is isolated" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x1000, &.{ mips.sw(t0, t1, 0), mips.beq(zero, zero, -1), mips.nop });
    m.cpu.regs[t0] = 0xDEAD;
    m.cpu.regs[t1] = 0x2000;
    m.cpu.cop0.writeReg(.sr, 1 << 16); // IsC
    m.start(0x1000);
    _ = m.cpu.run();
    try expectEqual(@as(u32, 0x1004), m.cpu.pipeline.pc); // one step, not a block
    try expectEqual(@as(?*block.Block, null), m.bus.blocks.?.lookup(0x1000));
    try expectEqual(@as(u32, 0), m.bus.read32(0x2000)); // the store went to the I-cache
}

var tty_seen: ?u8 = null;
var tty_calls: u32 = 0;
fn ttyCapture(_: ?*anyopaque, c: u8) void {
    tty_seen = c;
    tty_calls += 1;
}

test "the putchar hook fires before a block at the A0 vector" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0xA0, &.{ mips.jr(ra), mips.nop });
    poke(m.bus, 0x1000, &.{ mips.beq(zero, zero, -1), mips.nop });
    m.cpu.tty_write_fn = ttyCapture;
    m.cpu.regs[t1] = 0x3C;
    m.cpu.regs[a0] = 'Z';
    m.cpu.regs[ra] = 0x1000;
    tty_seen = null;
    tty_calls = 0;
    m.start(0xA0);
    _ = m.cpu.run();
    try expectEqual(@as(?u8, 'Z'), tty_seen);
    try expectEqual(@as(u32, 1), tty_calls);
    try expectEqual(@as(u32, 0x1000), m.cpu.pipeline.pc);
}

test "an interrupt taken at the A0 vector fires the putchar hook once" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x80, &.{ // the handler: ack I_STAT, return to EPC
        mips.lui(k1, 0x1F80),
        mips.sw(zero, k1, 0x1070),
        mips.mfc0(k0, 14),
        mips.jr(k0),
        mips.rfe,
    });
    poke(m.bus, 0xA0, &.{ mips.jr(ra), mips.nop });
    poke(m.bus, 0x1000, &.{ mips.beq(zero, zero, -1), mips.nop });
    m.cpu.tty_write_fn = ttyCapture;
    m.cpu.regs[t1] = 0x3C;
    m.cpu.regs[a0] = 'Z';
    m.cpu.regs[ra] = 0x1000;
    tty_seen = null;
    tty_calls = 0;
    raiseVblank(&m, 0);
    m.start(0xA0);
    _ = m.cpu.run();
    try expectEqual(@as(u32, 0x8000_0080), m.cpu.pipeline.pc);
    try expectEqual(@as(u32, 0xA0), m.cpu.cop0.readReg(.epc));
    try m.runUntil(0x1000);
    try expectEqual(@as(?u8, 'Z'), tty_seen);
    try expectEqual(@as(u32, 1), tty_calls);
}

test "a DMA-stalled run is one SIO step" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    m.bus.write8(0x1F801040, 0x01); // select the pad: arms /ACK
    m.bus.write32(0x1F8010F0, 0x0800_0000); // DPCR: channel 6
    m.bus.write32(0x1F8010E0, 0x0000_403C);
    m.bus.write32(0x1F8010E4, 16);
    m.bus.write32(0x1F8010E8, 0x1100_0002); // OTC: start + trigger
    try expect(m.bus.dma.isCpuStalled(m.bus));
    ps1_core.scheduler.sync(m.bus);
    const before = m.bus.sio.irq_timer;
    _ = m.cpu.run();
    ps1_core.scheduler.sync(m.bus);
    try expectEqual(before - 1, m.bus.sio.irq_timer);
}

test "a DMA started by the store that ends a block runs to completion" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    m.bus.write32(0x1F8010F0, 0x0800_0000); // DPCR: channel 6
    m.bus.write32(0x1F8010E0, 0x0000_403C);
    m.bus.write32(0x1F8010E4, 16);
    poke(m.bus, 0x1000, &.{
        mips.lui(t1, 0x1F80),
        mips.ori(t1, t1, 0x10E8), // OTC CHCR
        mips.lui(t0, 0x1100),
        mips.ori(t0, t0, 0x0002), // start + trigger, decrementing
        mips.sw(t0, t1, 0), // MMIO: syncs, and ends the block
        mips.nop,
        mips.beq(zero, zero, -1),
        mips.nop,
    });
    m.start(0x1000);
    _ = m.cpu.run();
    try expect(m.bus.dma.isCpuStalled(m.bus));
    var n: u32 = 0;
    while (m.bus.dma.isCpuStalled(m.bus)) : (n += 1) {
        try expect(n < 1000);
        _ = m.cpu.run(); // Debug: Cpu.step() asserts nothing is pending
    }
    try expectEqual(@as(u32, 0x00FF_FFFF), m.bus.read32(0x4000)); // the list's terminator
}

test "loading an EXE drops blocks compiled from the RAM it overwrites" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x1000, &.{ mips.addiu(t0, zero, 0x11), mips.beq(zero, zero, -1), mips.nop });
    m.start(0x8000_1000);
    _ = m.cpu.run();
    try expectEqual(@as(u32, 0x11), m.cpu.regs[t0]);

    var exe: [0x800 + 12]u8 = @splat(0);
    @memcpy(exe[0..8], "PS-X EXE");
    std.mem.writeInt(u32, exe[0x10..0x14], 0x8000_1000, .little); // pc
    std.mem.writeInt(u32, exe[0x18..0x1C], 0x8000_1000, .little); // dest
    std.mem.writeInt(u32, exe[0x1C..0x20], 12, .little); // size
    std.mem.writeInt(u32, exe[0x800..0x804], mips.addiu(t0, zero, 0x77), .little);
    std.mem.writeInt(u32, exe[0x804..0x808], mips.beq(zero, zero, -1), .little);
    try m.cpu.loadExe(&exe);
    _ = m.cpu.run();
    try expectEqual(@as(u32, 0x77), m.cpu.regs[t0]);
}

test "loading a savestate drops stale blocks and invalidates the I-cache" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x1000, &.{ mips.addiu(t0, zero, 0x11), mips.beq(zero, zero, -1), mips.nop });
    const savestate = ps1_core.savestate;
    const buf = try alloc.alloc(u8, try savestate.save(&m.cpu, null));
    defer alloc.free(buf);
    _ = try savestate.save(&m.cpu, buf);

    poke(m.bus, 0x1000, &.{mips.addiu(t0, zero, 0x22)});
    m.start(0x1000);
    _ = m.cpu.run();
    try expectEqual(@as(u32, 0x22), m.cpu.regs[t0]);
    const c = m.bus.blocks.?;
    c.icache_dirty = false;

    try savestate.load(&m.cpu, buf);
    try expect(c.icache_dirty);
    m.start(0x1000);
    _ = m.cpu.run();
    try expectEqual(@as(u32, 0x11), m.cpu.regs[t0]); // the state's code
}

test "a fallback step leaves the I-cache flushed before the next block" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x1000, &.{ mips.beq(zero, zero, 63), mips.nop }); // -> 0x1100
    poke(m.bus, 0x1100, &.{ mips.beq(zero, zero, -1), mips.nop });
    m.start(0x1000);
    m.cpu.step(); // the branch: next is its delay slot
    _ = m.cpu.run(); // the delay slot, as an interpreter step
    try expect(m.bus.blocks.?.icache_dirty);
    try expectEqual(@as(u32, 0x1000), m.cpu.icache[0].tag); // the line it filled
    _ = m.cpu.run(); // a block
    for (m.cpu.icache) |line| try expectEqual(@as(u32, 0xFFFF_FFFF), line.tag);
    try expect(!m.bus.blocks.?.icache_dirty);
}

test "a branch in a branch's delay slot resumes on the interpreter" {
    const program = struct {
        fn load(bus: *Bus) void {
            poke(bus, 0x1000, &.{
                mips.beq(zero, zero, 63), // -> 0x1100
                // In its delay slot. Its offset counts from the first
                // branch's target, the PC it runs under: -> 0x1200.
                mips.beq(zero, zero, 64),
            });
            poke(bus, 0x1100, &.{ mips.addiu(t0, zero, 7), mips.addiu(t1, zero, 9) });
            poke(bus, 0x1200, &.{ mips.addiu(t2, zero, 3), mips.beq(zero, zero, -1), mips.nop });
        }
    };
    var ref = try Machine.init(.interpreter);
    defer ref.deinit();
    var blk = try Machine.init(.cached);
    defer blk.deinit();
    for ([_]*Machine{ &ref, &blk }) |m| {
        program.load(m.bus);
        m.start(0x1000);
    }
    _ = blk.cpu.run(); // the block ends on the slot holding the second branch
    try expectEqual(@as(u32, 0x1100), blk.cpu.pipeline.pc);
    try expect(blk.cpu.pipeline.next_is_delay_slot);
    try blk.runUntil(0x1204);
    try ref.runUntil(0x1204);
    try std.testing.expectEqualSlices(u32, &ref.cpu.regs, &blk.cpu.regs);
    try expectEqual(@as(u32, 7), blk.cpu.regs[t0]);
}

test "run() stands for one step under the interpreter" {
    var m = try Machine.init(.interpreter);
    defer m.deinit();
    poke(m.bus, 0x1000, &.{ mips.nop, mips.nop, mips.beq(zero, zero, -1), mips.nop });
    m.start(0x1000);
    try expectEqual(@as(u32, 1), m.cpu.run());
}

test "run() counts a block's instructions" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x1000, &.{ mips.nop, mips.nop, mips.beq(zero, zero, -1), mips.nop });
    m.start(0x1000);
    try expectEqual(@as(u32, 4), m.cpu.run());
}

test "run() counts only the instructions before an MMIO store's exit" {
    var m = try Machine.init(.cached);
    defer m.deinit();
    poke(m.bus, 0x1000, &.{
        mips.lui(t1, 0x1F80),
        mips.sw(zero, t1, 0x1074), // I_MASK: MMIO, ends the block
        mips.nop,
        mips.nop,
        mips.beq(zero, zero, -1),
        mips.nop,
    });
    m.start(0x1000);
    try expectEqual(@as(u32, 2), m.cpu.run());
    try expectEqual(@as(u32, 0x1008), m.cpu.pipeline.pc);
}

test "an interrupt entry, a DMA word and a fallback step each count one" {
    // Interrupt entry.
    {
        var m = try Machine.init(.cached);
        defer m.deinit();
        poke(m.bus, 0x1100, &.{ mips.nop, mips.beq(zero, zero, -2), mips.nop });
        raiseVblank(&m, 0);
        m.start(0x1100);
        try expectEqual(@as(u32, 1), m.cpu.run());
        try expectEqual(@as(u32, 0x8000_0080), m.cpu.pipeline.pc);
    }
    // A DMA-stalled run.
    {
        var m = try Machine.init(.cached);
        defer m.deinit();
        m.bus.write32(0x1F8010F0, 0x0800_0000); // DPCR: channel 6
        m.bus.write32(0x1F8010E0, 0x0000_403C);
        m.bus.write32(0x1F8010E4, 16);
        m.bus.write32(0x1F8010E8, 0x1100_0002); // OTC: start + trigger
        ps1_core.scheduler.sync(m.bus);
        try expect(m.bus.dma.isCpuStalled(m.bus));
        try expectEqual(@as(u32, 1), m.cpu.run());
    }
    // A delay slot runs as one interpreter step.
    {
        var m = try Machine.init(.cached);
        defer m.deinit();
        poke(m.bus, 0x1000, &.{ mips.beq(zero, zero, 3), mips.nop, mips.nop, mips.nop, mips.nop });
        m.start(0x1000);
        m.cpu.step(); // the branch: the delay slot is next
        try expect(m.cpu.pipeline.next_is_delay_slot);
        try expectEqual(@as(u32, 1), m.cpu.run());
    }
}

test "a refused interrupt's single step counts one" {
    var m = try gteBlockMachine(true);
    defer m.deinit();
    try expectEqual(@as(u32, 1), m.cpu.run());
    try expectEqual(@as(u32, 0x1104), m.cpu.pipeline.pc);
}
