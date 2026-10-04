//! The arm64 JIT: the encoder against the assembler, the code buffer, and
//! `.jit` against `.cached`, which it must equal block for block.

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const alloc = std.testing.allocator;

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
        .{ emit.subImm(.w, .x25, .x26, 1), 0x51000759 }, // sub w25, w26, #1
        .{ emit.subImm(.x, .x9, .lr, 4), 0xd10013c9 }, // sub x9, x30, #4
        .{ emit.subImm(.w, .x26, .x26, 3), 0x51000f5a }, // sub w26, w26, #3
        .{ emit.addImm(.w, .x26, .x26, 3), 0x11000f5a }, // add w26, w26, #3
        .{ emit.addImm(.w, .x9, .x9, 4), 0x11001129 }, // add w9, w9, #4
        .{ emit.addImm(.x, .x10, .x10, 0x10), 0x9100414a }, // add x10, x10, #0x10
        .{ emit.subReg(.w, .x9, .x26, .x25), 0x4b190349 }, // sub w9, w26, w25
        .{ emit.madd(.w, .x1, .x9, .x23, .x24), 0x1b176121 }, // madd w1, w9, w23, w24
        .{ emit.neg(.w, .x24, .x23), 0x4b1703f8 }, // neg w24, w23
        .{ emit.addsReg(.w, .x9, .x10, .x11), 0x2b0b0149 }, // adds w9, w10, w11
        .{ emit.subsReg(.w, .x9, .x10, .x11), 0x6b0b0149 }, // subs w9, w10, w11
        .{ emit.cmpReg(.w, .x10, .x11), 0x6b0b015f }, // cmp w10, w11
        .{ emit.cmpReg(.w, .x9, .zr), 0x6b1f013f }, // cmp w9, wzr
        .{ emit.cmpImm(.x, .x9, 0), 0xf100013f }, // cmp x9, #0
        .{ emit.cmpImm(.w, .x10, 0x400), 0x7110015f }, // cmp w10, #0x400
        .{ emit.cmpImm(.w, .x10, 5), 0x7100155f }, // cmp w10, #5
        .{ emit.andReg(.w, .x9, .x10, .x11), 0x0a0b0149 }, // and w9, w10, w11
        .{ emit.orrReg(.w, .x9, .x10, .x11), 0x2a0b0149 }, // orr w9, w10, w11
        .{ emit.eorReg(.w, .x9, .x10, .x11), 0x4a0b0149 }, // eor w9, w10, w11
        .{ emit.ornReg(.w, .x9, .zr, .x9), 0x2a2903e9 }, // mvn w9, w9
        .{ emit.addReg(.w, .x9, .zr, .x11), 0x0b0b03e9 }, // add w9, wzr, w11
        .{ emit.movReg(.w, .x25, .x26), 0x2a1a03f9 }, // mov w25, w26
        .{ emit.shiftReg(.w, .lsl, .x9, .x10, .x11), 0x1acb2149 }, // lsl w9, w10, w11
        .{ emit.shiftReg(.w, .lsr, .x9, .x10, .x11), 0x1acb2549 }, // lsr w9, w10, w11
        .{ emit.shiftReg(.w, .asr, .x9, .x10, .x11), 0x1acb2949 }, // asr w9, w10, w11
        .{ emit.shiftReg(.x, .lsr, .x12, .x12, .x11), 0x9acb258c }, // lsr x12, x12, x11
        .{ emit.shiftImm(.lsl, .x9, .x10, 5), 0x531b6949 }, // lsl w9, w10, #5
        .{ emit.shiftImm(.lsr, .x9, .x10, 5), 0x53057d49 }, // lsr w9, w10, #5
        .{ emit.shiftImm(.asr, .x9, .x10, 5), 0x13057d49 }, // asr w9, w10, #5
        .{ emit.shiftImm(.lsl, .x9, .x10, 31), 0x53010149 }, // lsl w9, w10, #31
        .{ emit.shiftImm(.lsr, .x11, .x10, 21), 0x53157d4b }, // lsr w11, w10, #21
        .{ emit.shiftImm(.lsr, .x10, .x9, 29), 0x531d7d2a }, // lsr w10, w9, #29
        .{ emit.ubfx(.x9, .x10, 0, 29), 0x53007149 }, // ubfx w9, w10, #0, #29
        .{ emit.ubfx(.x10, .x9, 0, 21), 0x5300512a }, // ubfx w10, w9, #0, #21
        .{ emit.ubfx(.x11, .x10, 12, 9), 0x530c514b }, // ubfx w11, w10, #12, #9
        .{ emit.ubfx(.x11, .x10, 2, 19), 0x5302514b }, // ubfx w11, w10, #2, #19
        .{ emit.cset(.w, .x9, .lt), 0x1a9fa7e9 }, // cset w9, lt
        .{ emit.cset(.w, .x9, .lo), 0x1a9f27e9 }, // cset w9, lo
        .{ emit.csel(.w, .x9, .x10, .x9, .eq), 0x1a890149 }, // csel w9, w10, w9, eq
        .{ emit.bCond(.ne, 8), 0x54000041 }, // b.ne .+8
        .{ emit.bCond(.vs, 12), 0x54000066 }, // b.vs .+12
        .{ emit.bCond(.hs, -16), 0x54ffff82 }, // b.hs .-16
        .{ emit.bCond(.le, 20), 0x540000ad }, // b.le .+20
        .{ emit.cbz(.w, .x9, 8), 0x34000049 }, // cbz w9, .+8
        .{ emit.cbz(.x, .x10, 8), 0xb400004a }, // cbz x10, .+8
        .{ emit.tbnz(.x9, 0, 8), 0x37000049 }, // tbnz w9, #0, .+8
        .{ emit.tbnz(.x9, 1, 12), 0x37080069 }, // tbnz w9, #1, .+12
        .{ emit.tbnz(.x12, 0, 8), 0x3700004c }, // tbnz w12, #0, .+8
        .{ emit.bl(8), 0x94000002 }, // bl .+8
        .{ emit.bl(-4096), 0x97fffc00 }, // bl .-4096
        .{ emit.br(.x10), 0xd61f0140 }, // br x10
        .{ emit.movz(.w, .x9, 0x1234, 0), 0x52824689 }, // mov w9, #0x1234
        .{ emit.movk(.w, .x9, 0x8001, 1), 0x72b00029 }, // movk w9, #0x8001, lsl #16
        .{ emit.movz(.w, .x11, 0x1f80, 1), 0x52a3f00b }, // mov w11, #0x1f800000
        .{ emit.memImm(.ldr_w, .x9, .x19, 960), 0xb943c269 }, // ldr w9, [x19, #960]
        .{ emit.memImm(.str_w, .x9, .x19, 964), 0xb903c669 }, // str w9, [x19, #964]
        .{ emit.memImm(.ldr_x, .x9, .x22, 64), 0xf94022c9 }, // ldr x9, [x22, #64]
        .{ emit.memImm(.str_x, .x9, .x22, 72), 0xf90026c9 }, // str x9, [x22, #72]
        .{ emit.memImm(.ldr_x, .x9, .x9, 0), 0xf9400129 }, // ldr x9, [x9]
        .{ emit.memImm(.ldr_w, .x11, .x10, 8), 0xb940094b }, // ldr w11, [x10, #8]
        .{ emit.memImm(.strb, .x9, .x19, 1100), 0x39113269 }, // strb w9, [x19, #1100]
        .{ emit.memImm(.strb, .zr, .x19, 1101), 0x3911367f }, // strb wzr, [x19, #1101]
        .{ emit.memImm(.str_w, .zr, .x19, 1104), 0xb904527f }, // str wzr, [x19, #1104]
        .{ emit.memImm(.str_w, .x27, .x19, 1104), 0xb904527b }, // str w27, [x19, #1104]
        .{ emit.memImm(.ldr_w, .x28, .x19, 1104), 0xb944527c }, // ldr w28, [x19, #1104]
        .{ emit.memReg(.ldr_w, .x9, .x20, .x10, false), 0xb86a4a89 }, // ldr w9, [x20, w10, uxtw]
        .{ emit.memReg(.ldrh, .x9, .x20, .x10, false), 0x786a4a89 }, // ldrh w9, [x20, w10, uxtw]
        .{ emit.memReg(.ldrsh, .x9, .x20, .x10, false), 0x78ea4a89 }, // ldrsh w9, [x20, w10, uxtw]
        .{ emit.memReg(.ldrb, .x9, .x20, .x10, false), 0x386a4a89 }, // ldrb w9, [x20, w10, uxtw]
        .{ emit.memReg(.ldrsb, .x9, .x20, .x10, false), 0x38ea4a89 }, // ldrsb w9, [x20, w10, uxtw]
        .{ emit.memReg(.str_w, .x9, .x20, .x10, false), 0xb82a4a89 }, // str w9, [x20, w10, uxtw]
        .{ emit.memReg(.strh, .x9, .x20, .x10, false), 0x782a4a89 }, // strh w9, [x20, w10, uxtw]
        .{ emit.memReg(.strb, .x9, .x20, .x10, false), 0x382a4a89 }, // strb w9, [x20, w10, uxtw]
        .{ emit.memReg(.ldr_x, .x12, .x22, .x12, true), 0xf86c5acc }, // ldr x12, [x22, w12, uxtw #3]
        .{ emit.memReg(.ldr_x, .x10, .x10, .x11, true), 0xf86b594a }, // ldr x10, [x10, w11, uxtw #3]
        .{ emit.stp(.pre_index, .fp, .lr, .sp, -96), 0xa9ba7bfd }, // stp x29, x30, [sp, #-96]!
        .{ emit.stp(.signed_offset, .x21, .x22, .sp, 32), 0xa9025bf5 }, // stp x21, x22, [sp, #32]
        .{ emit.stp(.signed_offset, .x27, .x28, .sp, 80), 0xa90573fb }, // stp x27, x28, [sp, #80]
        .{ emit.ldp(.signed_offset, .x27, .x28, .sp, 80), 0xa94573fb }, // ldp x27, x28, [sp, #80]
        .{ emit.ldp(.post_index, .fp, .lr, .sp, 96), 0xa8c67bfd }, // ldp x29, x30, [sp], #96
        .{ emit.ldp(.signed_offset, .x20, .x21, .x22, 64), 0xa94456d4 }, // ldp x20, x21, [x22, #64]
    };
    for (cases, 0..) |c, i| {
        if (c[0] != c[1]) {
            std.debug.print("case {d}: got 0x{x:0>8}, assembler 0x{x:0>8}\n", .{ i, c[0], c[1] });
            return error.EncodingDiffers;
        }
    }
}

test "the emitter lays cold after hot and resolves branches across both" {
    const em = try alloc.create(jit.emitter.Emitter);
    defer alloc.destroy(em);
    em.reset();
    const cold = em.label();
    const back = em.label();
    em.branch(.{ .cond = .ne }, .{ .label = cold }); // word 0
    em.bind(back);
    em.put(emit.ret()); // word 1
    em.section = .cold;
    em.bind(cold);
    em.put(emit.movz(.w, .x0, 1, 0)); // word 2
    em.branch(.b, .{ .label = back }); // word 3
    em.branch(.bl, .{ .address = 0x1040 }); // word 4, at 0x1010
    em.section = .hot;
    try std.testing.expectEqual(@as(usize, 0x1008), em.addressOf(cold, 0x1000));
    const code = em.finish(0x1000);
    try std.testing.expectEqualSlices(u32, &.{
        emit.bCond(.ne, 8),
        emit.ret(),
        emit.movz(.w, .x0, 1, 0),
        emit.b(-8),
        emit.bl(0x30),
    }, code);
}

test "a 32-bit immediate takes a second word only for its high half" {
    const em = try alloc.create(jit.emitter.Emitter);
    defer alloc.destroy(em);
    em.reset();
    em.movImm32(.x9, 0x1234);
    try expectEqual(@as(usize, 1), em.len());
    em.movImm32(.x9, 0x8001_1234);
    try expectEqual(@as(usize, 3), em.len());
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
const t4 = h.t4;
const t5 = h.t5;
const t6 = h.t6;
const t7 = h.t7;

/// Compiles the block at `pc` once and runs it on two machines from the same
/// state: `.cached`'s handler loop on one, the JIT's code on the other.
fn expectSameBlock(program: []const u32, pc: u32, fetch_cost: u32) !void {
    if (!jit.available) return error.SkipZigTest;
    var ref = try h.Machine.init(.interpreter);
    defer ref.deinit();
    var dut = try h.Machine.init(.jit);
    defer dut.deinit();
    for ([_]*h.Machine{ &ref, &dut }) |m| {
        h.poke(m.bus, pc & 0x1F_FFFF, program);
        m.start(pc);
    }
    const b = try recompiler.compileBlock(dut.bus.blocks.?, dut.bus, pc);
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

const Engine = recompiler.Engine;
const BlockCache = recompiler.cache.BlockCache;

/// Both machines run the same program, `ref` under `.cached` and `dut`
/// under `.jit`, with a spin loop at the exception vector so a fault parks
/// both. Returns them started at `pc`; the caller deinits.
const Pair = struct {
    ref: h.Machine,
    dut: h.Machine,

    fn init(program: []const u32, pc: u32) !Pair {
        var p: Pair = .{ .ref = try h.Machine.init(.cached), .dut = undefined };
        errdefer p.ref.deinit();
        p.dut = try h.Machine.init(.jit);
        for ([_]*h.Machine{ &p.ref, &p.dut }) |m| {
            h.poke(m.bus, 0x80, &.{ mips.beq(zero, zero, -1), mips.nop });
            h.poke(m.bus, pc & 0x1F_FFFF, program);
            m.start(pc);
        }
        return p;
    }

    fn deinit(p: *Pair) void {
        p.ref.deinit();
        p.dut.deinit();
    }

    /// `runs` dispatcher calls on each, compared after every one.
    fn expectSameRuns(p: *Pair, runs: u32) !void {
        for (0..runs) |_| {
            try expectEqual(p.ref.cpu.run(), p.dut.cpu.run());
            try h.expectSameMachine(&p.ref, &p.dut);
        }
        // The JIT really ran: code was emitted.
        try expect(h.jitRan(&p.dut));
    }
};

fn expectSameRuns(program: []const u32, pc: u32, runs: u32) !void {
    if (!jit.available) return error.SkipZigTest;
    var p = try Pair.init(program, pc);
    defer p.deinit();
    try p.expectSameRuns(runs);
}

test ".jit equals .cached: a loop with loads, stores and delay slots" {
    try expectSameRuns(&h.loop_program, 0x8000_1000, 40);
}

test ".jit equals .cached: the same loop through KSEG1" {
    try expectSameRuns(&h.loop_program, 0xA000_1000, 40);
}

test ".jit equals .cached: an overflow and a misaligned load fault precisely" {
    try expectSameRuns(&.{
        mips.lui(t1, 0x7FFF),
        mips.ori(t1, t1, 0xFFFF),
        mips.add(t2, t1, t1), // overflow
        mips.nop,
    }, 0x1000, 4);
    try expectSameRuns(&.{
        mips.addiu(t1, zero, 0x2001),
        mips.lw(t2, t1, 0), // misaligned: address error
        mips.nop,
    }, 0x1000, 4);
}

test ".jit equals .cached: an MMIO store ends the block and ticks SIO" {
    try expectSameRuns(&(.{
        mips.lui(t1, 0x1F80),
        mips.addiu(t0, zero, 1),
        mips.i(0x28, t1, t0, 0x1040), // sb t0, 0x1040(t1): JOY_TX, a pad byte arms /ACK
        mips.lw(t2, t1, 0x1120), // timer 2: the cycles so far
    } ++ h.nops(20) ++ .{
        mips.lw(t3, t1, 0x1120),
        mips.beq(zero, zero, -1),
        mips.nop,
    }), 0x1000, 12);
}

test ".jit equals .cached: a store into the running block" {
    try expectSameRuns(&.{
        mips.addiu(t1, zero, 0x1010),
        mips.lui(t0, 0x240A),
        mips.ori(t0, t0, 0x0055), // t0 = addiu t2, zero, 0x55
        mips.sw(t0, t1, 0), // rewrites 0x1010, the next word
        mips.addiu(t2, zero, 0x11), // 0x1010: never runs in its old form
        mips.beq(zero, zero, -1),
        mips.nop,
    }, 0x1000, 6);
}

test ".jit equals .cached: a branch in a branch's delay slot" {
    try expectSameRuns(&.{
        mips.beq(zero, zero, 3), // -> 0x1010
        mips.j(0x1018), // its delay slot: runs, and its own delay slot is 0x1010
        mips.addiu(t0, zero, 1),
        mips.addiu(t1, zero, 2),
        mips.addiu(t2, zero, 3), // 0x1010
        mips.addiu(t3, zero, 4),
        mips.beq(zero, zero, -1), // 0x1018
        mips.nop,
    }, 0x1000, 8);
}

test ".jit equals .cached: every inline ALU form" {
    try expectSameRuns(&.{
        mips.lui(t0, 0x8000), // t0 = 0x80000000
        mips.ori(t1, zero, 0xFFFF), // t1 = 0xFFFF
        mips.addiu(t2, zero, 0xFFFF), // t2 = -1
        mips.sll(t3, t2, 4),
        mips.r(0, t0, t4, 0x02) | 31 << 6, // SRL
        mips.r(0, t0, t5, 0x03) | 31 << 6, // SRA
        mips.r(t1, t2, t6, 0x04), // SLLV by 0xFFFF: only the low five bits count
        mips.r(t1, t0, t7, 0x06), // SRLV
        mips.r(t1, t0, t3, 0x07), // SRAV
        mips.addu(t4, t0, t2),
        mips.r(t0, t1, t5, 0x23), // SUBU
        mips.r(t0, t1, t6, 0x24), // AND
        mips.r(t0, t1, t7, 0x25), // OR
        mips.r(t0, t1, t3, 0x26), // XOR
        mips.r(t0, t1, t4, 0x27), // NOR
        mips.r(t0, t1, t5, 0x2A), // SLT: signed, 0x80000000 is the smaller
        mips.r(t0, t1, t6, 0x2B), // SLTU
        mips.add(t7, t1, t1), // ADD, no overflow
        mips.r(t1, t2, t3, 0x22), // SUB, no overflow
        mips.i(0x08, t1, t4, 0x7FFF), // ADDI
        mips.i(0x0A, t0, t5, 0x0001), // SLTI
        mips.i(0x0B, t2, t6, 0xFFFF), // SLTIU against 0xFFFFFFFF
        mips.i(0x0C, t2, t7, 0x8001), // ANDI: zero-extended
        mips.i(0x0D, t0, t3, 0x8001), // ORI
        mips.i(0x0E, t2, t4, 0x8001), // XORI
        mips.addu(zero, t0, t1), // a write to $zero is dropped
        mips.sll(zero, t0, 1), // and so is a shift into it
        mips.beq(zero, zero, -1),
        mips.nop,
    }, 0x8000_1000, 4);
}

test ".jit equals .cached: a load lands around inline ops, unless one writes its target" {
    try expectSameRuns(&.{
        mips.lui(t2, 0x8000),
        mips.ori(t2, t2, 0x2000),
        mips.addiu(t0, zero, 5),
        mips.sw(t0, t2, 0),
        mips.addiu(t0, zero, 1),
        mips.lw(t0, t2, 0),
        mips.addu(t1, t0, zero), // the old t0, 1
        mips.addu(t3, t0, zero), // the loaded t0, 5
        mips.lw(t0, t2, 0),
        mips.addiu(t0, zero, 9), // cancels the load: t0 stays 9
        mips.addu(t4, t0, zero),
        mips.lw(zero, t2, 0), // a load to $zero still passes through load_v
        mips.addu(t5, t4, t4),
        mips.lw(t6, t2, 0),
        mips.lw(t6, t2, 4), // back to back into one register
        mips.addu(t7, t6, zero),
        mips.beq(zero, zero, -1),
        mips.nop,
    }, 0x8000_1000, 4);
}

test "the inline RAM path bills the bus's own wait states" {
    const bus = try ps1_core.memory.Bus.init(alloc);
    defer bus.deinit(alloc);
    const Bus = ps1_core.memory.Bus;
    for ([_]u32{ 0x0000_0000, 0x8000_1000, 0xA01F_FFFC }) |a| {
        try expectEqual(Bus.ram_access_wait, bus.waitCycles(u32, a, false));
        try expectEqual(Bus.ram_access_wait, bus.waitCycles(u16, a, true));
        try expectEqual(Bus.ram_access_wait, bus.waitCycles(u8, a, false));
    }
    try expectEqual(@as(u32, 0), bus.waitCycles(u32, 0x1F80_0000, false)); // the scratchpad is free
}

test ".jit equals .cached: inline loads from RAM, a mirror, the scratchpad and I/O" {
    // Each load has its own target, so every value survives to the compare.
    const s0: u5 = 16;
    const s1: u5 = 17;
    const s2: u5 = 18;
    const s3: u5 = 19;
    const s4: u5 = 20;
    const s5: u5 = 21;
    const s6: u5 = 22;
    const s7: u5 = 23;
    const t8: u5 = 24;
    try expectSameRuns(&.{
        mips.lui(t0, 0x8000),
        mips.ori(t0, t0, 0x2000), // KSEG0 RAM
        mips.lui(t1, 0xA000),
        mips.ori(t1, t1, 0x2000), // the same word through KSEG1
        mips.lui(t2, 0x0020),
        mips.ori(t2, t2, 0x2000), // its mirror at 2 MB: other wait states, so the slow path
        mips.lui(t3, 0x1F80), // the scratchpad
        mips.addiu(t4, zero, 0x8081), // 0xFFFF8081: a sign bit in every width
        mips.sw(t4, t0, 0),
        mips.sw(t4, t3, 4),
        mips.lw(s0, t0, 0),
        mips.i(0x20, t1, s1, 0), // LB: 0x81 sign-extends
        mips.i(0x24, t1, s2, 0), // LBU
        mips.i(0x21, t0, s3, 2), // LH: 0xFFFF
        mips.i(0x25, t0, s4, 0), // LHU: 0x8081
        mips.lw(s5, t2, 0), // the mirror
        mips.lw(s6, t3, 4), // the scratchpad
        mips.i(0x20, t3, s7, 5), // LB from the scratchpad: 0x80 sign-extends
        mips.lw(t8, t1, 0xFFFC), // a negative offset, through KSEG1
        mips.lui(t4, 0x1F80),
        mips.ori(t4, t4, 0x1120), // timer 2's counter: I/O, committed first
        mips.lw(t5, t4, 0),
        mips.addu(t6, t5, zero),
        mips.beq(zero, zero, -1),
        mips.nop,
    }, 0x8000_1000, 4);
}

test ".jit equals .cached: misaligned loads fault from the inline path" {
    for ([_]u32{ mips.lw(t1, t0, 2), mips.i(0x21, t0, t1, 1), mips.i(0x25, t0, t1, 3) }) |load| {
        try expectSameRuns(&.{
            mips.lui(t0, 0x8000),
            mips.addiu(t2, zero, 5),
            load,
            mips.addu(t3, t1, zero),
            mips.beq(zero, zero, -1),
            mips.nop,
        }, 0x8000_1000, 3);
    }
}

test ".jit equals .cached: a slow-path load in a delay slot returns to the hot path" {
    for ([_]u16{ 0x0020, 0x1F80 }) |high| { // a RAM mirror; I/O (timer 0's counter)
        try expectSameRuns(&.{
            mips.lui(t2, high),
            mips.ori(t2, t2, if (high == 0x0020) 0x2000 else 0x1100),
            mips.beq(zero, zero, 2),
            mips.lw(t5, t2, 0), // the delay slot
            mips.addiu(t6, zero, 1), // skipped
            mips.addu(t7, t5, zero),
            mips.beq(zero, zero, -1),
            mips.nop,
        }, 0x8000_1000, 3);
    }
}

test "lockstep reports a reference that strays into I/O the engine never touched" {
    if (!jit.available) return error.SkipZigTest;
    var m = try h.Machine.init(.jit);
    defer m.deinit();
    var checker: recompiler.lockstep.Checker = .{
        .stray = struct {
            // As if the engine had computed a RAM address the reference did not.
            fn f(cpu: *Cpu) void {
                cpu.regs[t0] = 0x1F80_1120; // timer 2: a device
            }
        }.f,
    };
    m.bus.blocks.?.lockstep = &checker;
    h.poke(m.bus, 0x1000, &.{ mips.lw(t1, t0, 0), mips.nop, mips.beq(zero, zero, -1), mips.nop });
    m.cpu.regs[t0] = 0x8000_2000;
    m.start(0x8000_1000);
    _ = m.cpu.run();
    try std.testing.expectEqualStrings("io", checker.mismatch.?.what);
}

test ".jit equals .cached: blocks entered with a load in flight" {
    try expectSameRuns(&.{
        mips.lui(t2, 0x8000),
        mips.ori(t2, t2, 0x2000),
        mips.addiu(t0, zero, 7),
        mips.sw(t0, t2, 0),
        mips.addiu(t1, zero, 3),
        mips.addiu(t1, t1, 0xFFFF), // 0x1014 loop
        mips.bne(t1, zero, -2), // -> loop
        mips.lw(t3, t2, 0), // delay slot: in flight as the next block starts
        mips.addu(t4, t3, zero),
        mips.beq(zero, zero, 1),
        mips.lw(zero, t2, 0), // delay slot: load_r clear, load_v set at the next start
        mips.addu(t5, t4, zero),
        mips.beq(zero, zero, -1),
        mips.nop,
    }, 0x8000_1000, 16);
}

test ".jit equals .cached: an overflow in a delay slot after inline ops" {
    try expectSameRuns(&.{
        mips.lui(t1, 0x7FFF),
        mips.ori(t1, t1, 0xFFFF),
        mips.addiu(t0, zero, 1),
        mips.beq(zero, zero, 2),
        mips.add(t2, t1, t0), // delay slot: overflows, EPC the branch, BD set
        mips.nop,
        mips.nop,
        mips.beq(zero, zero, -1),
        mips.nop,
    }, 0x8000_1000, 4);
}

test ".jit equals .cached: one RAM block entered through KSEG0, then KSEG1" {
    if (!jit.available) return error.SkipZigTest;
    var p = try Pair.init(&.{ mips.addiu(t0, t0, 1), mips.beq(zero, zero, -2), mips.nop }, 0x8000_1000);
    defer p.deinit();
    try p.expectSameRuns(3);
    for ([_]*h.Machine{ &p.ref, &p.dut }) |m| m.start(0xA000_1000);
    try p.expectSameRuns(3);
    // Inline code bakes its PCs in, so the KSEG1 entry compiled again.
    try expectEqual(@as(u32, 1), p.dut.bus.blocks.?.segment_recompiles);
}

test ".jit equals .cached: every inline branch, taken and not" {
    const at = 0x8000_1000;
    try expectSameRuns(&.{
        mips.addiu(t0, zero, 1), // 0
        mips.addiu(t1, zero, 0xFFFF), // 1: -1
        mips.beq(t0, t1, 2), // 2: not taken
        mips.addiu(t2, t2, 1), // 3: delay slot
        mips.bne(t0, t1, 2), // 4: taken, to 7
        mips.addiu(t2, t2, 1), // 5: delay slot
        mips.addiu(t2, t2, 0x100), // 6: skipped
        mips.i(0x06, t1, 0, 2), // 7: BLEZ -1, taken, to 10
        mips.nop,
        mips.addiu(t2, t2, 0x100),
        mips.i(0x07, t1, 0, 2), // 10: BGTZ -1, not taken
        mips.nop,
        mips.i(0x01, t1, 0x00, 2), // 12: BLTZ, taken, to 15
        mips.nop,
        mips.addiu(t2, t2, 0x100),
        mips.i(0x01, t1, 0x01, 2), // 15: BGEZ, not taken
        mips.nop,
        mips.i(0x01, h.ra, 0x10, 2), // 17: BLTZAL on $ra: compares the old $ra, then links
        mips.nop,
        mips.i(0x01, t0, 0x11, 2), // 19: BGEZAL, taken, to 22
        mips.nop,
        mips.addiu(t2, t2, 0x100),
        mips.jal(at + 26 * 4), // 22: to 26
        mips.addiu(t3, zero, 3),
        mips.addiu(t2, t2, 0x100), // 24, 25: skipped
        mips.addiu(t2, t2, 0x100),
        mips.lui(t5, 0x8000), // 26
        mips.ori(t5, t5, 0x1000 + 32 * 4),
        mips.jalr(t5, t5), // 28: links into t5 first, so jumps to 30, not 32
        mips.nop,
        mips.beq(zero, zero, -1), // 30: the end
        mips.nop,
        mips.addiu(t2, t2, 0x100), // 32: only a wrong JALR lands here
        mips.beq(zero, zero, -1),
        mips.nop,
    }, at, 24);
}

test ".jit equals .cached: a call and its return through $ra" {
    const at = 0x8000_1000;
    try expectSameRuns(&.{
        mips.jal(at + 6 * 4), // 0: to f
        mips.addiu(t0, zero, 1),
        mips.addiu(t1, t0, 1), // 2: f returns here
        mips.beq(zero, zero, -1),
        mips.nop,
        mips.nop,
        mips.jr(h.ra), // 6: f
        mips.addiu(t2, zero, 2),
    }, at, 8);
}

test "a block's branch is inline, and a call with branches masked off" {
    if (!jit.available) return error.SkipZigTest;
    var m = try h.Machine.init(.jit);
    defer m.deinit();
    h.poke(m.bus, 0x1000, &.{ mips.beq(zero, zero, -1), mips.nop });
    m.start(0x8000_1000);
    _ = m.cpu.run();
    try expectEqual(@as(u32, 0), m.bus.blocks.?.lookup(0x1000).?.calls);
    var no_branch: jit.Lowering = .{};
    no_branch.branch = false;
    recompiler.setLowering(m.bus, no_branch);
    m.start(0x8000_1000);
    _ = m.cpu.run();
    try expectEqual(@as(u32, 1), m.bus.blocks.?.lookup(0x1000).?.calls);
}

test "with PGXP on nothing is lowered, and turning it on flushes" {
    if (!jit.available) return error.SkipZigTest;
    var m = try h.Machine.init(.jit);
    defer m.deinit();
    const c = m.bus.blocks.?;
    h.poke(m.bus, 0x1000, &(@as([8]u32, @splat(mips.addu(t0, t0, t1))) ++ .{ mips.beq(zero, zero, -1), mips.nop }));
    m.start(0x8000_1000);
    _ = m.cpu.run();
    const lowered = c.lookup(0x1000).?.calls;
    m.bus.setPgxp(true);
    try expectEqual(@as(?*block.Block, null), c.lookup(0x1000));
    m.start(0x8000_1000);
    _ = m.cpu.run();
    const b = c.lookup(0x1000).?;
    try expectEqual(@as(u32, @intCast(b.ops.len)), b.calls); // all calls
    try expect(lowered < b.calls);
}

test ".jit equals .cached: shadows from an earlier PGXP period do not outlive an off period" {
    if (!jit.available) return error.SkipZigTest;
    var p = try Pair.init(&.{
        mips.addiu(t0, zero, 5), // rewrites t0 while PGXP is off: inline under .jit
        mips.beq(zero, zero, -1),
        mips.nop,
    }, 0x8000_1000);
    defer p.deinit();
    const machines = [_]*h.Machine{ &p.ref, &p.dut };
    // What a PGXP-on period leaves behind: t0 and t1 carry shadows.
    const stale: ps1_core.pgxp.Value = .{ .x = 5, .word = 5, .flags = 1 };
    for (machines) |m| {
        m.bus.setPgxp(true);
        m.cpu.gpr_shadow[t0] = stale;
        m.cpu.gpr_shadow[t1] = stale;
        m.bus.setPgxp(false);
    }
    try p.expectSameRuns(2);
    for (machines) |m| m.bus.setPgxp(true);
    try p.expectSameRuns(1);
    for ([_]u5{ t0, t1 }) |r| try expectEqual(p.ref.cpu.gpr_shadow[r], p.dut.cpu.gpr_shadow[r]);
}

test "engine selection creates, switches and frees the JIT's cache" {
    var m = try h.Machine.init(.cached);
    defer m.deinit();
    if (!jit.available) {
        try std.testing.expectError(error.EngineUnavailable, recompiler.setEngine(&m.cpu, alloc, .jit));
        return;
    }
    h.poke(m.bus, 0x1000, &.{ mips.beq(zero, zero, -1), mips.nop });
    m.start(0x1000);
    _ = m.cpu.run();
    try expect(m.bus.blocks.?.lookup(0x1000).?.code == null); // .cached emits nothing

    try recompiler.setEngine(&m.cpu, alloc, .jit);
    try expectEqual(Engine.jit, recompiler.engineOf(m.bus));
    const c = m.bus.blocks.?;
    try expectEqual(@as(?*block.Block, null), c.lookup(0x1000)); // a fresh cache
    _ = m.cpu.run();
    try expect(c.lookup(0x1000).?.code != null);
    try recompiler.setEngine(&m.cpu, alloc, .jit); // re-applied: kept as it is
    try expect(m.bus.blocks.? == c);
    try expect(c.lookup(0x1000) != null);

    try recompiler.setEngine(&m.cpu, alloc, .cached);
    try expectEqual(Engine.cached, recompiler.engineOf(m.bus));
    try expectEqual(@as(?*block.Block, null), m.bus.blocks.?.lookup(0x1000));
    try recompiler.setEngine(&m.cpu, alloc, .interpreter);
    try expectEqual(@as(?*BlockCache, null), m.bus.blocks);
    // The testing allocator fails the test if a switch leaked a cache.
}

test "a full code buffer flushes every block and compiles on" {
    if (!jit.available) return error.SkipZigTest;
    var m = try h.Machine.init(.jit);
    defer m.deinit();
    const c = m.bus.blocks.?;
    // One 16 KB page. A block of 64 MFLO calls is about 3 KB of code, so
    // eight of them cannot all fit.
    c.jit.?.destroy(alloc);
    c.jit = try jit.Jit.create(alloc, 16 << 10);
    h.poke(m.bus, 0x1000, &(@as([64 * 8]u32, @splat(mips.mflo(t0))) ++ .{ mips.beq(zero, zero, -1), mips.nop }));
    m.start(0x1000);
    var flushed = false;
    var high: usize = 0;
    for (0..8) |_| {
        _ = m.cpu.run();
        const used = c.jit.?.buf.used;
        if (used < high) flushed = true;
        high = used;
    }
    try expect(flushed);
    try expectEqual(@as(?*block.Block, null), c.lookup(0x1000)); // went with the flush
    try expectEqual(@as(u32, 0x1000 + 64 * 8 * 4), m.cpu.pipeline.pc); // and every block ran
}

test "lockstep checks JIT blocks" {
    if (!jit.available) return error.SkipZigTest;
    var m = try h.Machine.init(.jit);
    defer m.deinit();
    var checker: recompiler.lockstep.Checker = .{};
    m.bus.blocks.?.lockstep = &checker;
    h.poke(m.bus, 0x1000, &h.loop_program);
    m.start(0x8000_1000);
    try m.runUntil(0x8000_1048);
    try expectEqual(@as(?recompiler.lockstep.Mismatch, null), checker.mismatch);
    try expect(checker.checked >= 10);
    try expect(m.bus.blocks.?.lookup(0x1000).?.code != null);
}

const fuzz = struct {
    const programs = 1000;
    const len = 48;
    /// Forward branches and jumps skip at most this many words past their
    /// delay slot, into a tail of nops that ends in a spin loop.
    const max_skip = 8;
    const tail = max_skip + 2;
    const runs = 24;
    const base: u32 = 0x1000;
    /// Loads and stores address [$gp - 0x200, $gp + 0x200), inside this.
    const data_base: u32 = 0x3C00;
    const data_bytes = 0x800;
    const gp_value: u32 = 0x8000_4000;

    /// Values the sources start with, chosen to reach the edges: overflow,
    /// a divide by zero and INT_MIN / -1.
    const interesting = [_]u32{ 0, 1, 0xFFFF_FFFF, 0x7FFF_FFFF, 0x8000_0000, 0x8000_0001, 0xFFFF_8000 };

    const gte_nclip: u32 = 0x4B40_0006;
    const gte_rtps: u32 = 0x4A18_0001;

    const Gen = struct {
        rng: std.Random,

        fn pick(g: Gen, comptime T: type, items: []const T) T {
            return items[g.rng.uintLessThan(usize, items.len)];
        }
        fn src(g: Gen) u5 {
            return g.rng.int(u5);
        }
        /// Any register but $gp, which holds the data window's base. $zero
        /// stays in: a write to it must be dropped.
        fn dst(g: Gen) u5 {
            const r = g.rng.int(u5);
            return if (r == h.gp) zero else r;
        }
        /// An offset into the data window, aligned to `width` seven times
        /// in eight: a misaligned access faults and ends the program, and
        /// the fuzzer needs programs that run deep, with a few that fault.
        fn dataOffset(g: Gen, width: u16) u16 {
            const off: u16 = @bitCast(g.rng.intRangeLessThan(i16, -0x200, 0x200));
            return if (g.rng.uintLessThan(u32, 8) == 0) off else off & ~(width - 1);
        }

        fn instr(g: Gen, at: usize) u32 {
            return switch (g.rng.uintLessThan(u32, 12)) {
                0 => mips.r(g.src(), g.src(), g.dst(), g.pick(u32, &.{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B })),
                1 => mips.r(0, g.src(), g.dst(), g.pick(u32, &.{ 0x00, 0x02, 0x03 })) | @as(u32, g.rng.int(u5)) << 6,
                2 => mips.r(g.src(), g.src(), g.dst(), g.pick(u32, &.{ 0x04, 0x06, 0x07 })),
                3 => mips.i(g.pick(u32, &.{ 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F }), g.src(), g.dst(), g.rng.int(u16)),
                4 => mips.r(g.src(), g.src(), zero, g.pick(u32, &.{ 0x18, 0x19, 0x1A, 0x1B })), // MULT, MULTU, DIV, DIVU
                5 => switch (g.rng.uintLessThan(u32, 4)) {
                    0 => mips.r(0, 0, g.dst(), 0x10), // MFHI
                    1 => mips.r(g.src(), 0, 0, 0x11), // MTHI
                    2 => mips.r(0, 0, g.dst(), 0x12), // MFLO
                    else => mips.r(g.src(), 0, 0, 0x13), // MTLO
                },
                6 => blk: {
                    const op = g.pick(u32, &.{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26 });
                    break :blk mips.i(op, h.gp, g.dst(), g.dataOffset(accessWidth(op)));
                },
                7 => blk: {
                    const op = g.pick(u32, &.{ 0x28, 0x29, 0x2A, 0x2B, 0x2E });
                    break :blk mips.i(op, h.gp, g.src(), g.dataOffset(accessWidth(op)));
                },
                8, 9 => g.branch(at),
                10 => switch (g.rng.uintLessThan(u32, 3)) {
                    0 => 0x4880_0000 | @as(u32, g.src()) << 16 | @as(u32, g.rng.int(u5)) << 11, // MTC2
                    1 => 0x4800_0000 | @as(u32, g.dst()) << 16 | @as(u32, g.rng.int(u5)) << 11, // MFC2
                    else => g.pick(u32, &.{ mips.gte_sqr, gte_nclip, gte_rtps }),
                },
                else => if (g.rng.uintLessThan(u32, 16) == 0) g.pick(u32, &.{ mips.syscall, mips.brk }) else mips.nop,
            };
        }

        /// Forward only, so every program ends.
        fn branch(g: Gen, at: usize) u32 {
            const skip = g.rng.uintAtMost(u16, max_skip);
            return switch (g.rng.uintLessThan(u32, 4)) {
                0 => mips.i(g.pick(u32, &.{ 0x04, 0x05 }), g.src(), g.src(), skip), // BEQ, BNE
                1 => mips.i(g.pick(u32, &.{ 0x06, 0x07 }), g.src(), 0, skip), // BLEZ, BGTZ
                2 => mips.i(0x01, g.src(), g.pick(u5, &.{ 0x00, 0x01, 0x10, 0x11 }), skip), // BLTZ, BGEZ, BLTZAL, BGEZAL
                else => g.pick(u32, &.{ 0x02, 0x03 }) << 26 | // J, JAL
                    (((base + 4 * (@as(u32, @intCast(at)) + 1 + skip)) >> 2) & 0x03FF_FFFF),
            };
        }
    };

    fn program(rng: std.Random) [len + tail]u32 {
        var words: [len + tail]u32 = undefined;
        const g: Gen = .{ .rng = rng };
        for (words[0..len], 0..) |*w, at| w.* = g.instr(at);
        for (words[len..][0..max_skip]) |*w| w.* = mips.nop;
        words[len + max_skip] = mips.beq(zero, zero, -1);
        words[len + max_skip + 1] = mips.nop;
        return words;
    }

    const State = struct {
        regs: [32]u32,
        hi: u32,
        lo: u32,
        data: [data_bytes]u8,
        pc: u32,

        fn random(rng: std.Random) State {
            var s: State = undefined;
            for (&s.regs) |*r| r.* = if (rng.boolean()) interesting[rng.uintLessThan(usize, interesting.len)] else rng.int(u32);
            s.regs[0] = 0;
            s.regs[h.gp] = gp_value;
            s.hi = rng.int(u32);
            s.lo = rng.int(u32);
            rng.bytes(&s.data);
            s.pc = if (rng.boolean()) 0x8000_0000 | base else 0xA000_0000 | base; // both fetch costs
            return s;
        }

        fn apply(s: *const State, m: *h.Machine, words: []const u32) void {
            m.cpu = Cpu.init(m.bus);
            m.cpu.regs = s.regs;
            m.cpu.hi = s.hi;
            m.cpu.lo = s.lo;
            m.cpu.cop0.writeReg(.sr, 1 << 30); // CU2: the GTE ops run instead of faulting
            // On no code page, so a host copy needs no invalidation.
            @memcpy(m.bus.ram[data_base..][0..data_bytes], &s.data);
            h.poke(m.bus, 0x80, &.{ mips.beq(zero, zero, -1), mips.nop });
            h.poke(m.bus, base, words); // through Bus.write: drops the last program's blocks
            m.start(s.pc);
        }
    };

    fn isBranch(w: u32) bool {
        const op = w >> 26;
        return (op >= 0x01 and op <= 0x07) or (op == 0 and ((w & 0x3F) == 0x08 or (w & 0x3F) == 0x09));
    }

    /// The register `w` writes through `writeReg`, if any: what cancels a
    /// load still in its delay slot.
    fn writes(w: u32) ?u5 {
        const op = w >> 26;
        const rt: u5 = @truncate(w >> 16);
        const rd: u5 = @truncate(w >> 11);
        if (op == 0) return switch (w & 0x3F) {
            0x00, 0x02, 0x03, 0x04, 0x06, 0x07, 0x10, 0x12, 0x20...0x27, 0x2A, 0x2B => rd,
            else => null,
        };
        return if (op >= 0x08 and op <= 0x0F) rt else null;
    }

    fn isLoad(w: u32) bool {
        return (w >> 26) >= 0x20 and (w >> 26) <= 0x26;
    }

    fn accessWidth(op: u32) u16 {
        return switch (op) {
            0x21, 0x25, 0x29 => 2,
            0x23, 0x2B => 4,
            else => 1,
        };
    }
};

const Cpu = ps1_core.cpu.Cpu;

test "fuzz: .jit equals .cached on random programs" {
    if (!jit.available) return error.SkipZigTest;
    var ref = try h.Machine.init(.cached);
    defer ref.deinit();
    var dut = try h.Machine.init(.jit);
    defer dut.deinit();

    var overflowed = false;
    var load_fault = false;
    var store_fault = false;
    var branch_in_delay_slot = false;
    var load_cancelled = false;
    var jit_ran = false;
    var reached_total: u64 = 0;

    for (0..fuzz.programs) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();
        const words = fuzz.program(rng);
        const state = fuzz.State.random(rng);
        state.apply(&ref, &words);
        state.apply(&dut, &words);
        var reached: u64 = 0;

        for (0..fuzz.runs) |run_index| {
            const ran = ref.cpu.run();
            const dut_ran = dut.cpu.run();
            errdefer std.debug.print("fuzz: seed {d}, run {d}\n", .{ seed, run_index });
            try expectEqual(ran, dut_ran);
            try h.expectSameMachine(&ref, &dut);
            if (h.jitRan(&dut)) jit_ran = true;
            const phys = ref.cpu.pipeline.pc & 0x1FFF_FFFF;
            if (phys >= fuzz.base and phys < fuzz.base + 4 * (fuzz.len + fuzz.tail))
                reached = @max(reached, @min((phys - fuzz.base) / 4, fuzz.len));
        }
        reached_total += reached;

        switch (ref.cpu.cop0.readReg(.cause) >> 2 & 0x1F) {
            0x0C => overflowed = true,
            0x04 => load_fault = true,
            0x05 => store_fault = true,
            else => {},
        }
        for (words[0 .. fuzz.len - 1], words[1..fuzz.len]) |w, next| {
            if (fuzz.isBranch(w) and fuzz.isBranch(next)) branch_in_delay_slot = true;
            if (fuzz.isLoad(w) and fuzz.writes(next) == @as(u5, @truncate(w >> 16))) load_cancelled = true;
        }
    }
    // The generator really reached the cases it exists for.
    try expect(overflowed);
    try expect(load_fault);
    try expect(store_fault);
    try expect(branch_in_delay_slot);
    try expect(load_cancelled);
    // And the dut really ran emitted code, so this is not cached against cached.
    try expect(jit_ran);
    // Programs run deep: on average past their midpoint before a fault or
    // the end. Plan 4's generator stopped most of them in the first few
    // blocks.
    try expect(reached_total / fuzz.programs >= fuzz.len / 2);
}

test "a lowering mask parses from family names" {
    const Lowering = jit.Lowering;
    try expectEqual(Lowering{}, try Lowering.parse("all"));
    try expectEqual(Lowering.none, try Lowering.parse("none"));
    // Every family but the named ones off, however many later tasks add.
    var only_alu = Lowering.none;
    only_alu.alu = true;
    try expectEqual(only_alu, try Lowering.parse("alu"));
    try std.testing.expectError(error.UnknownFamily, Lowering.parse("alu,float"));
}
