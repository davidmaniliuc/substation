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
        return 0x02 << 26 | (target >> 2) & 0x03FF_FFFF;
    }
    fn jr(rs: u5) u32 {
        return r(rs, 0, 0, 0x08);
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
