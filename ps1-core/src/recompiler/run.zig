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
pub fn setEngine(cpu: *Cpu, allocator: std.mem.Allocator, engine: Engine) error{ OutOfMemory, EngineUnavailable }!void {
    const bus = cpu.bus;
    switch (engine) {
        .interpreter => if (bus.blocks) |c| {
            c.destroy();
            bus.blocks = null;
        },
        .cached => if (bus.blocks) |c| c.flush() else {
            bus.blocks = try BlockCache.create(allocator);
        },
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

pub fn run(cpu: *Cpu, c: *BlockCache) void {
    const bus = cpu.bus;
    // The frame loop's vblank check reads what came due during this call.
    defer scheduler.serviceDue(bus);
    c.reap();
    // A block starts only when downcount > 0.
    scheduler.serviceDue(bus);

    const pc = cpu.pipeline.pc;
    const phys = pc & 0x1FFF_FFFF;
    if (block.regionOf(phys) == null) {
        cpu.step();
        c.icache_dirty = true;
        return;
    }

    const b = c.lookup(phys) orelse compileInto(c, bus, pc) catch {
        // Out of memory for a block: the interpreter still runs.
        cpu.step();
        c.icache_dirty = true;
        return;
    };

    c.running = b;
    cached.execute(cpu, b, fetchCost(bus, pc));
    c.running = null;
}

fn compileInto(c: *BlockCache, bus: *const Bus, pc: u32) !*block.Block {
    const b = try block.compile(c.allocator, bus, pc);
    errdefer block.destroy(c.allocator, b);
    try c.insert(pc & 0x1FFF_FFFF, b);
    return b;
}
