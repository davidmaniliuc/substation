//! The lockstep checker: each block run by its engine, then re-run from the
//! same state as one `exec.execute` per instruction, and the two compared.
//! Registers, HI/LO, the PC pipeline, the load delay, COP0, the GTE, every
//! RAM word either run stored to and the scratchpad. A mismatch names the
//! block, which is the point: a JIT bug found by a golden's region hash is a
//! frame; found here, it is one block.
//!
//! Devices are frozen for the reference. A block that touched a device
//! (`Bus.io_accessed`) is skipped, since a FIFO pop cannot be replayed. The
//! engine's run is the real one: it charged the scheduler, and its result
//! is what the machine keeps. The reference charges nothing.
//!
//! The reference runs as many instructions as the engine did. It checks what
//! each one computes, not where the block ends; `block.zig` owns that.
//! PGXP must be off: the reference would apply every shadow update twice.

const std = @import("std");
const cpu_mod = @import("../cpu/cpu.zig");
const Cpu = cpu_mod.Cpu;
const exec = @import("../cpu/exec.zig");
const block = @import("block.zig");
const cached = @import("cached.zig");
const Bus = @import("../memory.zig").Bus;

/// The CPU state an instruction can change.
pub const Arch = struct {
    regs: [32]u32,
    hi: u32,
    lo: u32,
    pipeline: @FieldType(Cpu, "pipeline"),
    load_delay: @FieldType(Cpu, "load_delay"),
    cop0: cpu_mod.Cop0,
    cop2: cpu_mod.Cop2,

    pub fn capture(cpu: *const Cpu) Arch {
        return .{
            .regs = cpu.regs,
            .hi = cpu.hi,
            .lo = cpu.lo,
            .pipeline = cpu.pipeline,
            .load_delay = cpu.load_delay,
            .cop0 = cpu.cop0,
            .cop2 = cpu.cop2,
        };
    }

    pub fn restore(a: *const Arch, cpu: *Cpu) void {
        cpu.regs = a.regs;
        cpu.hi = a.hi;
        cpu.lo = a.lo;
        cpu.pipeline = a.pipeline;
        cpu.load_delay = a.load_delay;
        cpu.cop0 = a.cop0;
        cpu.cop2 = a.cop2;
    }
};

pub const Mismatch = struct {
    /// The virtual PC of the block's first instruction.
    block_pc: u32 = 0,
    /// "gpr", "hi", "lo", "pc", "next_pc", "delay slot", "load delay",
    /// "cop0", "cop2 data", "cop2 control", "ram", "scratchpad" or
    /// "length" (the reference stopped at an exception the engine did not).
    what: []const u8,
    /// The register number, or the byte offset into RAM or the scratchpad.
    index: u32 = 0,
    engine: u32 = 0,
    reference: u32 = 0,
};

/// The old word under each RAM store, oldest first. A block holds at most
/// `max_len + 1` instructions and each stores at most once.
pub const Journal = struct {
    len: usize = 0,
    entries: [block.max_len + 1]Entry = undefined,

    pub const Entry = struct { offset: u32, old: u32 };

    pub fn record(j: *Journal, offset: u32, old: u32) void {
        j.entries[j.len] = .{ .offset = offset & ~@as(u32, 3), .old = old };
        j.len += 1;
    }

    fn slice(j: *const Journal) []const Entry {
        return j.entries[0..j.len];
    }
};

pub const Checker = struct {
    checked: u64 = 0,
    skipped_io: u64 = 0,
    /// The first disagreement. Checking stops once it is set.
    mismatch: ?Mismatch = null,
    /// Test seam: run on the machine right after the engine, to make the
    /// engine wrong on purpose. Never set outside a test.
    fault: ?*const fn (cpu: *Cpu) void = null,

    /// Runs `b` on the engine, then checks it. Returns the engine's
    /// instruction count, as `cached.execute` does.
    pub fn execute(self: *Checker, cpu: *Cpu, b: *const block.Block, fetch_cost: u32) u32 {
        const bus = cpu.bus;
        const c = bus.blocks.?;
        std.debug.assert(!bus.pgxp_enabled);

        const pre = Arch.capture(cpu);
        const pre_scratch = bus.scratchpad;
        var engine_journal: Journal = .{};
        bus.io_accessed = false;
        c.journal = &engine_journal;
        const ran = cached.execute(cpu, b, fetch_cost);
        if (self.fault) |f| f(cpu);
        c.journal = null;
        if (self.mismatch != null) return ran;
        if (bus.io_accessed) {
            self.skipped_io += 1;
            return ran;
        }
        self.checked += 1;

        const engine = Arch.capture(cpu);
        const engine_exception = cpu.exception_taken;
        const engine_exit = bus.block_exit;
        const engine_scratch = bus.scratchpad;
        var engine_ram: [block.max_len + 1]u32 = undefined;
        for (engine_journal.slice(), 0..) |e, k| engine_ram[k] = ramWord(bus, e.offset);

        // Memory as the block found it, newest store first.
        var k = engine_journal.len;
        while (k > 0) {
            k -= 1;
            const e = engine_journal.entries[k];
            std.mem.writeInt(u32, bus.ram[e.offset..][0..4], e.old, .little);
        }
        bus.scratchpad = pre_scratch;
        pre.restore(cpu);

        var ref_journal: Journal = .{};
        c.journal = &ref_journal;
        const ref_ran = reference(cpu, ran);
        c.journal = null;
        bus.wait_cycles = 0;

        self.mismatch = if (ref_ran != ran)
            .{ .what = "length", .engine = ran, .reference = ref_ran }
        else
            compareArch(&engine, &Arch.capture(cpu)) orelse
                compareRam(bus, &engine_journal, engine_ram[0..engine_journal.len], &ref_journal) orelse
                compareScratchpad(&engine_scratch, &bus.scratchpad);
        if (self.mismatch) |*mm| mm.block_pc = b.start_pc;

        // Carry on from the engine's result. Memory holds the reference's
        // stores, which equal the engine's unless a mismatch was just set.
        engine.restore(cpu);
        cpu.exception_taken = engine_exception;
        bus.block_exit = engine_exit;
        return ran;
    }
};

fn ramWord(bus: *const Bus, offset: u32) u32 {
    return std.mem.readInt(u32, bus.ram[offset..][0..4], .little);
}

/// `n` instructions through `exec.execute`, fetched from memory as it is
/// now, with no scheduler charge. Stops at an exception, as a block does.
fn reference(cpu: *Cpu, n: u32) u32 {
    cpu.exception_taken = false;
    var ran: u32 = 0;
    while (ran < n) {
        cpu.pipeline.current_pc = cpu.pipeline.pc;
        const raw = block.fetchWord(cpu.bus, cpu.pipeline.current_pc & 0x1FFF_FFFF);
        cpu.beginInstruction();
        exec.execute(cpu, raw);
        cpu.retireLoad();
        ran += 1;
        if (cpu.exception_taken) break;
    }
    return ran;
}

pub fn compareArch(engine: *const Arch, ref: *const Arch) ?Mismatch {
    for (engine.regs, ref.regs, 0..) |e, r, i| {
        if (e != r) return .{ .what = "gpr", .index = @intCast(i), .engine = e, .reference = r };
    }
    if (engine.hi != ref.hi) return .{ .what = "hi", .engine = engine.hi, .reference = ref.hi };
    if (engine.lo != ref.lo) return .{ .what = "lo", .engine = engine.lo, .reference = ref.lo };
    const ep = engine.pipeline;
    const rp = ref.pipeline;
    if (ep.pc != rp.pc) return .{ .what = "pc", .engine = ep.pc, .reference = rp.pc };
    if (ep.next_pc != rp.next_pc) return .{ .what = "next_pc", .engine = ep.next_pc, .reference = rp.next_pc };
    if (ep.is_delay_slot != rp.is_delay_slot or ep.next_is_delay_slot != rp.next_is_delay_slot)
        return .{ .what = "delay slot" };
    if (!std.meta.eql(engine.load_delay, ref.load_delay)) return .{
        .what = "load delay",
        .index = engine.load_delay.load_r,
        .engine = engine.load_delay.load_v,
        .reference = ref.load_delay.load_v,
    };
    for (engine.cop0.regs, ref.cop0.regs, 0..) |e, r, i| {
        if (e != r) return .{ .what = "cop0", .index = @intCast(i), .engine = e, .reference = r };
    }
    for (0..32) |i| {
        const e = engine.cop2.readData(i);
        const r = ref.cop2.readData(i);
        if (e != r) return .{ .what = "cop2 data", .index = @intCast(i), .engine = e, .reference = r };
    }
    for (0..32) |i| {
        const e = engine.cop2.readCtrl(i);
        const r = ref.cop2.readCtrl(i);
        if (e != r) return .{ .what = "cop2 control", .index = @intCast(i), .engine = e, .reference = r };
    }
    return null;
}

/// Every word either run stored to. Where only one run stored, the other's
/// final value is the word as the block found it: the reference journal's
/// first old value for that offset.
fn compareRam(bus: *const Bus, engine_j: *const Journal, engine_final: []const u32, ref_j: *const Journal) ?Mismatch {
    for (engine_j.slice(), engine_final) |e, final| {
        const ref = ramWord(bus, e.offset);
        if (final != ref) return .{ .what = "ram", .index = e.offset, .engine = final, .reference = ref };
    }
    for (ref_j.slice()) |r| {
        if (find(engine_j, r.offset) != null) continue;
        const pre = ref_j.entries[find(ref_j, r.offset).?].old;
        const ref = ramWord(bus, r.offset);
        if (pre != ref) return .{ .what = "ram", .index = r.offset, .engine = pre, .reference = ref };
    }
    return null;
}

fn find(j: *const Journal, offset: u32) ?usize {
    for (j.slice(), 0..) |e, k| if (e.offset == offset) return k;
    return null;
}

fn compareScratchpad(engine: []const u8, ref: []const u8) ?Mismatch {
    var i: usize = 0;
    while (i < engine.len) : (i += 4) {
        const e = std.mem.readInt(u32, engine[i..][0..4], .little);
        const r = std.mem.readInt(u32, ref[i..][0..4], .little);
        if (e != r) return .{ .what = "scratchpad", .index = @intCast(i), .engine = e, .reference = r };
    }
    return null;
}
