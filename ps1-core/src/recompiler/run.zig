//! The block engines' dispatcher: one block, or one interpreter step, per
//! `run()`. See docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md.

const std = @import("std");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const Bus = @import("../memory.zig").Bus;
const icache = @import("../cpu/icache.zig");
const scheduler = @import("../cpu/scheduler.zig");
pub const block = @import("block.zig");
pub const cache = @import("cache.zig");
pub const lockstep = @import("lockstep.zig");
pub const jit = @import("jit.zig");
pub const cached = @import("cached.zig");
const BlockCache = cache.BlockCache;

pub const Engine = enum { interpreter, cached, jit };

/// Selects the CPU engine. A block engine's cache lives on `Bus` (see
/// `Bus.blocks`), so a frontend that swaps in a fresh `Bus` re-applies its
/// engine the way it re-applies its PGXP settings. Call between `run()`s.
/// Re-applying the current engine does nothing: the I-cache and the compiled
/// blocks are left as they are. `.jit` is unavailable off arm64 macOS, and
/// where MAP_JIT is refused.
pub fn setEngine(cpu: *Cpu, allocator: std.mem.Allocator, engine: Engine) error{ OutOfMemory, EngineUnavailable }!void {
    const bus = cpu.bus;
    if (engineOf(bus) == engine) return;
    const next: ?*BlockCache = switch (engine) {
        .interpreter => null,
        .cached => try BlockCache.create(allocator, bus),
        .jit => if (comptime jit.available) try createJitCache(allocator, bus) else return error.EngineUnavailable,
    };
    if (bus.blocks) |old| old.destroy();
    bus.blocks = next;
    // The block engines leave the I-cache invalidated. Lines the interpreter
    // filled before a switch may describe RAM a block engine since rewrote.
    icache.flush(cpu);
}

fn createJitCache(allocator: std.mem.Allocator, bus: *Bus) error{ OutOfMemory, EngineUnavailable }!*BlockCache {
    const c = try BlockCache.create(allocator, bus);
    errdefer c.destroy();
    c.jit = try jit.Jit.create(allocator, jit.buffer_bytes);
    return c;
}

pub fn engineOf(bus: *const Bus) Engine {
    const c = bus.blocks orelse return .interpreter;
    return if (c.jit != null) .jit else .cached;
}

/// A compiled block, on whichever engine compiled it: its host code when it
/// has some, its handler array otherwise.
pub fn executeBlock(cpu: *Cpu, b: *const block.Block, fetch_cost: u32) u32 {
    if (comptime jit.available) {
        if (b.code != null) return jit.execute(cpu, b, fetch_cost);
    }
    return cached.execute(cpu, b, fetch_cost);
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

/// One block, or one interpreter step. Returns the `Cpu.step()` calls it
/// stands for: a block's instructions, or 1 for a DMA word, an interrupt
/// entry or a fallback step.
pub fn run(cpu: *Cpu, c: *BlockCache) u32 {
    const bus = cpu.bus;
    // The frame loop's vblank check reads what came due during this call.
    defer scheduler.serviceDue(bus);
    c.reap();
    if (bus.pgxp_enabled != c.pgxp_seen) {
        if (bus.pgxp_enabled) clearShadows(cpu);
        c.pgxp_seen = bus.pgxp_enabled;
    }
    // A block starts only when downcount > 0.
    scheduler.serviceDue(bus);

    if (bus.dma.isCpuStalled(bus)) {
        // One DMA word is one step, exactly as in `step()`. Nothing is
        // pending here: the store that started the DMA is an MMIO access,
        // whose sync zeroed `downcount`, so the closing `serviceDue` of the
        // `run()` that made it could not return early and handed the
        // block's tail over. `step()` asserts it.
        cpu.step();
        return 1;
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
        return 1;
    }
    if (c.icache_dirty) {
        icache.flush(cpu);
        c.icache_dirty = false;
    }

    const b = blockAt(c, bus, pc) orelse {
        // No memory for a block, or no code space even after a flush: the
        // interpreter still runs.
        cpu.step();
        c.icache_dirty = true;
        return 1;
    };
    const fetch_cost = fetchCost(bus, pc);

    // Interrupts are seen between blocks only, under the block engines' own
    // rule. The interpreter refuses one on a branch target; most blocks
    // start on one, so that rule would refuse almost every interrupt here.
    if (cpu.latchIrqLine()) {
        if (isGteCommand(b.ops[0].instr.raw)) {
            // Refused: the BIOS handler would skip the command. Run the
            // command alone, so the interrupt is taken one instruction
            // later: a loop whose head is a GTE command would otherwise
            // refuse it at every start. `step()` refuses it on the command
            // too, and runs the TTY hook itself.
            cpu.step();
            c.icache_dirty = true;
            // Kept for the JIT, whose linked blocks only return to the
            // dispatcher on a zero downcount; here it makes the closing
            // `serviceDue` hand the step over.
            bus.sched.downcount = 0;
            return 1;
        }
        // A block that ended on a delay slot leaves is_delay_slot set, which
        // would put EPC on the branch and set Cause.BD. The interrupted
        // instruction is this block's first.
        cpu.pipeline.current_pc = pc;
        cpu.pipeline.is_delay_slot = false;
        cpu.exception(.Interrupt, 0);
        cpu.chargeCycles(1 + fetch_cost, 1);
        return 1;
    }

    // The putchar hook fires only when the block actually runs: an interrupt
    // taken here returns to the vector and fires it then, and every fallback
    // `step()` above runs it itself. A block that falls through into
    // 0xA0/0xB0 misses it, which the kernel's layout makes unreachable.
    cpu.biosCallHook(phys);
    c.pins.running = b;
    const ran = if (c.lockstep) |l| l.execute(cpu, b, fetch_cost) else executeBlock(cpu, b, fetch_cost);
    c.pins.running = null;
    return ran;
}

/// While PGXP is off, inline code keeps no GPR shadows and `.cached`
/// keeps only some, so whatever an earlier PGXP period left is stale on
/// both engines. Both start the new period from nothing.
fn clearShadows(cpu: *Cpu) void {
    cpu.gpr_shadow = @splat(.none);
    cpu.load_shadow = .none;
    cpu.delay_shadow = .none;
}

/// The block at `pc`, compiled if need be. Inline code bakes its PCs in, so
/// a block entered through another segment than it was compiled for (KSEG0
/// against KSEG1, or a RAM mirror) is compiled again for this one.
fn blockAt(c: *BlockCache, bus: *const Bus, pc: u32) ?*block.Block {
    if (c.lookup(pc & 0x1FFF_FFFF)) |b| {
        if (b.code == null or b.start_pc == pc) return b;
        c.discard(b);
        c.segment_recompiles += 1;
    }
    return compileBlock(c, bus, pc) catch null;
}

/// Compiles the block at `pc` into `c`, as host code under `.jit`. A full
/// code buffer flushes every block first: between blocks nothing is
/// running, and there is no eviction policy (spec: Full flushes).
pub fn compileBlock(c: *BlockCache, bus: *const Bus, pc: u32) !*block.Block {
    const b = try block.compile(c.allocator, bus, pc);
    errdefer block.destroy(c.allocator, b);
    if (comptime jit.available) {
        if (c.jit) |j| {
            const opts: jit.translate.Options = .{
                // Inline code skips the PGXP hooks `exec.zig` calls. Plan 6
                // emits them; until then a block compiled under PGXP is all
                // calls, and `Bus.setPgxp` flushes on every toggle.
                .lower = if (bus.pgxp_enabled) .none else j.lower,
            };
            jit.translate.compile(j, &c.pins, b, opts) catch {
                c.flush();
                try jit.translate.compile(j, &c.pins, b, opts);
            };
        }
    }
    try c.insert(pc & 0x1FFF_FFFF, b);
    return b;
}
