//! The block engines' dispatcher: one block, or one interpreter step, per
//! `run()`. See docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md.

const std = @import("std");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const Bus = @import("../memory.zig").Bus;
const icache = @import("../cpu/icache.zig");
const scheduler = @import("../cpu/scheduler.zig");
pub const block = @import("block.zig");
pub const cache = @import("cache.zig");
const cached = @import("cached.zig");
const BlockCache = cache.BlockCache;

pub const Engine = enum { interpreter, cached, jit };

/// Selects the CPU engine. A block engine's cache lives on `Bus` (see
/// `Bus.blocks`), so a frontend that swaps in a fresh `Bus` re-applies its
/// engine the way it re-applies its PGXP settings. Call between `run()`s.
/// Re-applying the current engine does nothing: the I-cache and the compiled
/// blocks are left as they are.
pub fn setEngine(cpu: *Cpu, allocator: std.mem.Allocator, engine: Engine) error{ OutOfMemory, EngineUnavailable }!void {
    const bus = cpu.bus;
    if (engineOf(bus) == engine) return;
    switch (engine) {
        .interpreter => {
            bus.blocks.?.destroy();
            bus.blocks = null;
        },
        .cached => bus.blocks = try BlockCache.create(allocator),
        .jit => return error.EngineUnavailable,
    }
    // The block engines leave the I-cache invalidated. Lines the interpreter
    // filled before a switch may describe RAM a block engine since rewrote.
    icache.flush(cpu);
}

pub fn engineOf(bus: *const Bus) Engine {
    return if (bus.blocks == null) .interpreter else .cached;
}

/// What a block charges per instruction for its fetch, in place of the
/// I-cache model: a cache hit (free) for RAM run through KUSEG/KSEG0, and
/// the uncached per-word cost for KSEG1 and for the BIOS. Read at every
/// block start, so a BIOS wait-state write applies from the next block.
fn fetchCost(bus: *const Bus, pc: u32) u32 {
    const cached_segment = pc < 0xA000_0000 or pc >= 0xC000_0000;
    if (cached_segment and block.regionOf(pc & 0x1FFF_FFFF) == .ram) return 0;
    return bus.waitCycles(u32, pc, false);
}

const isc_bit: u32 = 1 << 16;

/// The COP2 command encoding the BIOS interrupt handler skips on return.
fn isGteCommand(raw: u32) bool {
    return (raw >> 24) & 0xFE == 0x4A;
}

pub fn run(cpu: *Cpu, c: *BlockCache) void {
    const bus = cpu.bus;
    // The frame loop's vblank check reads what came due during this call.
    defer scheduler.serviceDue(bus);
    c.reap();
    // A block starts only when downcount > 0.
    scheduler.serviceDue(bus);

    if (bus.dma.isCpuStalled(bus)) {
        // One DMA word is one step, exactly as in `step()`. Nothing is
        // pending here: the store that started the DMA is an MMIO access,
        // which syncs, and every `run()` ends in `serviceDue`, which then
        // hands the block's tail over. `step()` asserts it.
        cpu.step();
        return;
    }

    const pc = cpu.pipeline.pc;
    const phys = pc & 0x1FFF_FFFF;
    // The interpreter takes:
    //  - a delay slot: the instruction after it is `next_pc`, not the next
    //    word, which happens after an interpreter savestate, an engine
    //    switch or a fallback step;
    //  - anything while the cache is isolated: stores go to the I-cache
    //    (the mtc0 that sets IsC already ended the block);
    //  - a PC no block can live at: it raises the right fetch bus error.
    if (block.regionOf(phys) == null or
        cpu.pipeline.next_is_delay_slot or
        cpu.cop0.readReg(.sr) & isc_bit != 0)
    {
        cpu.step();
        c.icache_dirty = true;
        return;
    }
    if (c.icache_dirty) {
        icache.flush(cpu);
        c.icache_dirty = false;
    }

    const b = c.lookup(phys) orelse compileInto(c, bus, pc) catch {
        // Out of memory for a block: the interpreter still runs.
        cpu.step();
        c.icache_dirty = true;
        return;
    };
    // Once the block is in hand, so the hook fires once on every path: the
    // fallback step above runs it itself.
    cpu.biosCallHook(phys);
    const fetch_cost = fetchCost(bus, pc);

    // Interrupts are seen between blocks only, under the block engines' own
    // rule. The interpreter refuses one on a branch target; most blocks
    // start on one, so that rule would refuse almost every interrupt here.
    if (cpu.latchIrqLine()) {
        if (isGteCommand(b.ops[0].instr.raw)) {
            // Refused: the BIOS handler would skip the command. Force this
            // block back to the dispatcher, so every block engine takes the
            // interrupt one block later, linked or not.
            bus.sched.downcount = 0;
        } else {
            // A block that ended on a delay slot leaves is_delay_slot set,
            // which would put EPC on the branch and set Cause.BD. The
            // interrupted instruction is this block's first.
            cpu.pipeline.current_pc = pc;
            cpu.pipeline.is_delay_slot = false;
            cpu.exception(.Interrupt, 0);
            cpu.chargeCycles(1 + fetch_cost, 1);
            return;
        }
    }

    c.running = b;
    cached.execute(cpu, b, fetch_cost);
    c.running = null;
}

fn compileInto(c: *BlockCache, bus: *const Bus, pc: u32) !*block.Block {
    const b = try block.compile(c.allocator, bus, pc);
    errdefer block.destroy(c.allocator, b);
    try c.insert(pc & 0x1FFF_FFFF, b);
    return b;
}
