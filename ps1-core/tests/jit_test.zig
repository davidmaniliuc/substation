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
        try expect(p.dut.bus.blocks.?.code.?.used > 0);
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
    // One 16 KB page. A 64-nop block is about 3.6 KB of code, so eight of
    // them cannot all fit.
    c.code.?.deinit();
    c.code = try jit.CodeBuffer.init(16 << 10);
    h.poke(m.bus, 0x1000, &(h.nops(64 * 8) ++ .{ mips.beq(zero, zero, -1), mips.nop }));
    m.start(0x1000);
    var flushed = false;
    var high: usize = 0;
    for (0..8) |_| {
        _ = m.cpu.run();
        const used = c.code.?.used;
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
        /// Any alignment, so word and halfword accesses also fault.
        fn dataOffset(g: Gen) u16 {
            return @bitCast(g.rng.intRangeLessThan(i16, -0x200, 0x200));
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
                6 => mips.i(g.pick(u32, &.{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26 }), h.gp, g.dst(), g.dataOffset()),
                7 => mips.i(g.pick(u32, &.{ 0x28, 0x29, 0x2A, 0x2B, 0x2E }), h.gp, g.src(), g.dataOffset()),
                8, 9 => g.branch(at),
                10 => switch (g.rng.uintLessThan(u32, 3)) {
                    0 => 0x4880_0000 | @as(u32, g.src()) << 16 | @as(u32, g.rng.int(u5)) << 11, // MTC2
                    1 => 0x4800_0000 | @as(u32, g.dst()) << 16 | @as(u32, g.rng.int(u5)) << 11, // MFC2
                    else => g.pick(u32, &.{ mips.gte_sqr, gte_nclip, gte_rtps }),
                },
                else => g.pick(u32, &.{ mips.syscall, mips.brk, mips.nop }),
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

    for (0..fuzz.programs) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();
        const words = fuzz.program(rng);
        const state = fuzz.State.random(rng);
        state.apply(&ref, &words);
        state.apply(&dut, &words);

        for (0..fuzz.runs) |run_index| {
            const ran = ref.cpu.run();
            const dut_ran = dut.cpu.run();
            errdefer std.debug.print("fuzz: seed {d}, run {d}\n", .{ seed, run_index });
            try expectEqual(ran, dut_ran);
            try h.expectSameMachine(&ref, &dut);
            if (dut.bus.blocks.?.code.?.used > 0) jit_ran = true;
        }

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
}
