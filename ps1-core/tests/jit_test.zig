//! The arm64 JIT: the encoder against the assembler, the code buffer, and
//! `.jit` against `.cached`, which it must equal block for block.

const std = @import("std");
const expectEqual = std.testing.expectEqual;

const ps1_core = @import("ps1_core");
const jit = ps1_core.recompiler.jit;
const emit = jit.emit;

// Each expected word is what `clang -arch arm64 -c` assembled from the line
// in the comment, read back with `objdump -d` (Xcode ships no llvm-mc; clang
// is the same MC layer). To pin a new form, assemble it the same way.
test "the encoder matches the assembler" {
    const cases = [_]struct { u32, u32 }{
        .{ emit.stp(.pre_index, .x29, .x30, .sp, -64), 0xa9bc7bfd }, // stp x29, x30, [sp, #-64]!
        .{ emit.stp(.signed_offset, .x19, .x20, .sp, 16), 0xa90153f3 }, // stp x19, x20, [sp, #16]
        .{ emit.stp(.signed_offset, .x23, .x24, .sp, 32), 0xa90263f7 }, // stp x23, x24, [sp, #32]
        .{ emit.stp(.signed_offset, .x25, .x26, .sp, 48), 0xa9036bf9 }, // stp x25, x26, [sp, #48]
        .{ emit.ldp(.signed_offset, .x25, .x26, .sp, 48), 0xa9436bf9 }, // ldp x25, x26, [sp, #48]
        .{ emit.ldp(.signed_offset, .x23, .x24, .sp, 32), 0xa94263f7 }, // ldp x23, x24, [sp, #32]
        .{ emit.ldp(.signed_offset, .x19, .x20, .sp, 16), 0xa94153f3 }, // ldp x19, x20, [sp, #16]
        .{ emit.ldp(.post_index, .x29, .x30, .sp, 64), 0xa8c47bfd }, // ldp x29, x30, [sp], #64
        .{ emit.addImm(.x, .x29, .sp, 0), 0x910003fd }, // add x29, sp, #0
        .{ emit.addImm(.w, .x23, .x1, 1), 0x11000437 }, // add w23, w1, #1
        .{ emit.addImm(.w, .x25, .x25, 1), 0x11000739 }, // add w25, w25, #1
        .{ emit.addReg(.w, .x24, .x24, .x23), 0x0b170318 }, // add w24, w24, w23
        .{ emit.movReg(.x, .x19, .x0), 0xaa0003f3 }, // mov x19, x0
        .{ emit.movReg(.x, .x0, .x19), 0xaa1303e0 }, // mov x0, x19
        .{ emit.movReg(.w, .x1, .x24), 0x2a1803e1 }, // mov w1, w24
        .{ emit.movReg(.w, .x2, .x25), 0x2a1903e2 }, // mov w2, w25
        .{ emit.movReg(.w, .x0, .x26), 0x2a1a03e0 }, // mov w0, w26
        .{ emit.movz(.w, .x24, 0, 0), 0x52800018 }, // movz w24, #0
        .{ emit.movz(.x, .x16, 0x1234, 0), 0xd2824690 }, // movz x16, #0x1234
        .{ emit.movk(.x, .x16, 0x5678, 1), 0xf2aacf10 }, // movk x16, #0x5678, lsl #16
        .{ emit.movk(.x, .x16, 0x9abc, 2), 0xf2d35790 }, // movk x16, #0x9abc, lsl #32
        .{ emit.movk(.x, .x16, 0xdef0, 3), 0xf2fbde10 }, // movk x16, #0xdef0, lsl #48
        .{ emit.movz(.w, .x1, 0xbeef, 1), 0x52b7dde1 }, // movz w1, #0xbeef, lsl #16
        .{ emit.blr(.x16), 0xd63f0200 }, // blr x16
        .{ emit.ret(), 0xd65f03c0 }, // ret
        .{ emit.cbnz(.w, .x0, 8), 0x35000040 }, // cbnz w0, .+8
        .{ emit.cbnz(.w, .x0, -4), 0x35ffffe0 }, // cbnz w0, .-4
        .{ emit.b(12), 0x14000003 }, // b .+12
        .{ emit.b(-8), 0x17fffffe }, // b .-8
    };
    for (cases, 0..) |c, i| {
        if (c[0] != c[1]) {
            std.debug.print("case {d}: got 0x{x:0>8}, assembler 0x{x:0>8}\n", .{ i, c[0], c[1] });
            return error.EncodingDiffers;
        }
    }
}

/// `install`'s result as a function of one `u32`, for code that is one.
fn unary(entry: [*]const u32) *const fn (u32) callconv(.c) u32 {
    return @ptrCast(entry);
}

test "installed code runs" {
    if (!jit.available) return error.SkipZigTest;
    var buf = try jit.CodeBuffer.init(16 << 10);
    defer buf.deinit();
    const f = unary(try buf.install(&.{ emit.addImm(.w, .x0, .x0, 5), emit.ret() }));
    try expectEqual(@as(u32, 12), f(7));
}

test "a full buffer refuses, keeps what it holds, and takes code again after reset" {
    if (!jit.available) return error.SkipZigTest;
    var buf = try jit.CodeBuffer.init(16 << 10); // one 16 KB page: 4096 words
    defer buf.deinit();
    const first = unary(try buf.install(&.{ emit.addImm(.w, .x0, .x0, 1), emit.ret() }));
    const filler: [4094]u32 = @splat(emit.ret());
    _ = try buf.install(&filler);
    try std.testing.expectError(error.CodeBufferFull, buf.install(&.{emit.ret()}));
    // The refusal left the buffer executable and its code intact.
    try expectEqual(@as(u32, 2), first(1));
    buf.reset();
    const again = unary(try buf.install(&.{ emit.addImm(.w, .x0, .x0, 9), emit.ret() }));
    try expectEqual(@as(u32, 10), again(1));
}

const alloc = std.testing.allocator;
const expect = std.testing.expect;
const recompiler = ps1_core.recompiler;
const block = recompiler.block;
const h = @import("recompiler_helpers.zig");
const mips = h.mips;
const zero = h.zero;
const t0 = h.t0;
const t1 = h.t1;
const t2 = h.t2;
const t3 = h.t3;

/// Compiles the block at `pc` once and runs it on two machines from the same
/// state: `.cached`'s handler loop on one, the JIT's code on the other.
fn expectSameBlock(program: []const u32, pc: u32, fetch_cost: u32) !void {
    if (!jit.available) return error.SkipZigTest;
    var buf = try jit.CodeBuffer.init(1 << 20);
    defer buf.deinit();
    var ref = try h.Machine.init(.interpreter);
    defer ref.deinit();
    var dut = try h.Machine.init(.interpreter);
    defer dut.deinit();
    for ([_]*h.Machine{ &ref, &dut }) |m| {
        h.poke(m.bus, pc & 0x1F_FFFF, program);
        m.start(pc);
    }
    const b = try block.compile(alloc, dut.bus, pc);
    defer block.destroy(alloc, b);
    b.code = try jit.translate.compile(&buf, b);
    try expectEqual(recompiler.cached.execute(&ref.cpu, b, fetch_cost), jit.execute(&dut.cpu, b, fetch_cost));
    try h.expectSameMachine(&ref, &dut);
}

test "a translated block computes what the cached interpreter computes" {
    try expectSameBlock(&h.loop_program, 0x8000_1000, 0); // up to the bne and its delay slot
    try expectSameBlock(h.loop_program[4..], 0xA000_1010, 4); // KSEG1: a fetch cost of 4
}

test "a translated block stops at an overflow, precisely" {
    try expectSameBlock(&.{
        mips.addiu(t0, zero, 1),
        mips.lui(t1, 0x7FFF),
        mips.ori(t1, t1, 0xFFFF),
        mips.add(t2, t1, t0), // overflows: the block stops here
        mips.addiu(t3, zero, 7),
        mips.jr(h.ra),
        mips.nop,
    }, 0x1000, 0);
}

test "a translated block commits its cycles before an MMIO read" {
    try expectSameBlock(&(.{
        mips.lui(t1, 0x1F80),
        mips.ori(t1, t1, 0x1120), // timer 2's counter
        mips.lw(t2, t1, 0),
    } ++ h.nops(10) ++ .{
        mips.lw(t3, t1, 0),
        mips.nop,
        mips.beq(zero, zero, -1),
        mips.nop,
    }), 0x1000, 0);
}
