//! Where a block begins and ends. This file alone decides, so every block
//! engine executes the same boundaries.
//!
//! A block ends at: a branch or jump plus its delay slot; the length cap;
//! a 4 KB page edge; or an instruction that changes interrupt or memory
//! state (mtc0, rfe, syscall, break). A branch is never separated from its
//! delay slot: the cap and the page edge both stretch by one instruction to
//! take it. The run-time exits (an MMIO store, a store that invalidates the
//! running block) are `Bus.block_exit`'s, not this file's.

const std = @import("std");
const Bus = @import("../memory.zig").Bus;
const exec = @import("../cpu/exec.zig");
const Cpu = @import("../cpu/cpu.zig").Cpu;

pub const max_len: usize = 64;
pub const page_shift: u5 = 12;
const page_mask: u32 = (1 << page_shift) - 1;

const phys_mask: u32 = 0x1FFF_FFFF;
const ram_mask: u32 = 0x001F_FFFF;
const bios_base: u32 = 0x1FC0_0000;
const bios_mask: u32 = 0x0007_FFFF;

pub const Op = struct {
    handler: exec.Handler,
    instr: exec.Instruction,
    /// A load or store. The block commits its elapsed cycles before it, so
    /// an MMIO access syncs the devices to the right time.
    memory: bool,
};

/// A block as host code (`arm64/translate.zig`): runs the block from its
/// start with the given fetch cost and returns the instructions it ran,
/// exactly as `cached.execute` does.
pub const JitEntry = *const fn (cpu: *Cpu, fetch_cost: u32) callconv(.c) u32;

pub const Block = struct {
    /// The virtual PC it was compiled from.
    start_pc: u32,
    ops: []Op,
    /// The 4 KB RAM pages its words came from. Equal unless a branch in a
    /// page's last word took its delay slot from the next page. Unused for
    /// a BIOS block, which is never invalidated.
    first_page: u16,
    last_page: u16,
    /// Dropped by invalidation and queued for the dispatcher to free
    /// (`cache.zig`): the running block may be the one dropped.
    dead: bool = false,
    next_dead: ?*Block = null,
    /// Set under `.jit`, null under `.cached`. The code lives in the
    /// `Jit`'s code buffer, which is only ever reset by a full flush, so it
    /// outlives the block. It calls through `&ops[i]`, so `ops` must too:
    /// a dropped block stays allocated until `reap`.
    code: ?JitEntry = null,
    /// The length of `code` in words, for a dump.
    code_words: u32 = 0,
    /// Ops emitted as calls to their handler rather than inline. How a test
    /// knows an op was lowered: inline code is not always the shorter.
    calls: u32 = 0,
};

pub const Region = enum { ram, bios };

/// The table a physical PC's block lives in, or null where none can: such
/// a PC runs one interpreter step, which raises the right fetch bus error.
pub fn regionOf(phys: u32) ?Region {
    return switch (phys) {
        0x0000_0000...0x007F_FFFF => .ram, // 2 MB, mirrored 4x
        bios_base...bios_base + bios_mask => .bios,
        else => null,
    };
}

pub fn ramPage(phys: u32) u16 {
    return @intCast((phys & ram_mask) >> page_shift);
}

fn fetch(bus: *const Bus, region: Region, phys: u32) u32 {
    return switch (region) {
        .ram => std.mem.readInt(u32, bus.ram[phys & ram_mask & ~@as(u32, 3) ..][0..4], .little),
        .bios => std.mem.readInt(u32, bus.bios[(phys - bios_base) & bios_mask & ~@as(u32, 3) ..][0..4], .little),
    };
}

/// The word at a physical PC that can hold a block, read without billing
/// wait states. The lockstep reference fetches through it.
pub fn fetchWord(bus: *const Bus, phys: u32) u32 {
    return fetch(bus, regionOf(phys).?, phys);
}

pub fn isBranch(raw: u32) bool {
    const op = raw >> 26;
    if (op >= 0x01 and op <= 0x07) return true; // REGIMM, J, JAL, BEQ, BNE, BLEZ, BGTZ
    const funct = raw & 0x3F;
    return op == 0 and (funct == 0x08 or funct == 0x09); // JR, JALR
}

/// The register a load leaves in the load delay (`load_r`), for an op that
/// is one: LB, LH, LWL, LW, LBU, LHU, LWR.
pub fn issuesLoad(raw: u32) ?u5 {
    const op = raw >> 26;
    return if (op >= 0x20 and op <= 0x26) @truncate(raw >> 16) else null;
}

/// Changes interrupt or memory state, so the dispatcher must look again
/// before the next instruction.
fn endsBlock(raw: u32) bool {
    const op = raw >> 26;
    const funct = raw & 0x3F;
    if (op == 0) return funct == 0x0C or funct == 0x0D; // SYSCALL, BREAK
    if (op == 0x10) {
        const rs = (raw >> 21) & 0x1F;
        return rs == 0x04 or (rs >= 0x10 and funct == 0x10); // MTC0, RFE
    }
    return false;
}

fn isMemory(raw: u32) bool {
    const op = raw >> 26;
    return op >= 0x20 and op <= 0x3B; // loads, stores, LWCn, SWCn
}

pub fn compile(allocator: std.mem.Allocator, bus: *const Bus, pc: u32) !*Block {
    const phys = pc & phys_mask;
    const region = regionOf(phys).?;

    var words: [max_len + 1]u32 = undefined;
    var n: usize = 0;
    var addr = phys;
    while (true) {
        const raw = fetch(bus, region, addr);
        words[n] = raw;
        n += 1;
        addr +%= 4;
        if (n >= 2 and isBranch(words[n - 2])) break; // that was its delay slot
        if (isBranch(raw)) continue;
        if (endsBlock(raw)) break;
        if (n == max_len) break;
        if (addr & page_mask == 0) break;
    }

    const ops = try allocator.alloc(Op, n);
    errdefer allocator.free(ops);
    for (words[0..n], ops) |raw, *op| {
        op.* = .{ .handler = exec.handlerFor(raw), .instr = exec.decode(raw), .memory = isMemory(raw) };
    }

    const b = try allocator.create(Block);
    b.* = .{
        .start_pc = pc,
        .ops = ops,
        .first_page = ramPage(phys),
        .last_page = ramPage(phys +% @as(u32, @intCast(n - 1)) * 4),
    };
    return b;
}

pub fn destroy(allocator: std.mem.Allocator, b: *Block) void {
    allocator.free(b.ops);
    allocator.destroy(b);
}
