const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

const ps1_core = @import("ps1_core");
const pgxp = ps1_core.pgxp;
const Value = pgxp.Value;
const Primitive = ps1_core.gpu.primitive;
const Cop2 = ps1_core.cpu.Cop2;

/// The shipped default: a negative tolerance disables the check entirely, so
/// every test that is not about tolerance passes this and reads as before.
const tolerance_off: f32 = -1.0;

test "a value is invalidated when its recorded word no longer matches" {
    var v: Value = .{ .x = 1.5, .y = 2.5, .word = 0xDEAD_BEEF, .flags = Value.valid_xy };
    v.validate(0xDEAD_BEEF);
    try expectEqual(Value.valid_xy, v.flags);
    v.validate(0x0000_0001);
    try expectEqual(@as(u32, 0), v.flags);
}

test "validX and validY fall back to the integer halves when a half is invalid" {
    // Low half -3, high half 7.
    const word: u32 = (@as(u32, 7) << 16) | @as(u32, @as(u16, @bitCast(@as(i16, -3))));
    const v: Value = .{ .x = 1.25, .y = 9.75, .word = word, .flags = Value.valid_x };
    try expectApproxEqAbs(@as(f32, 1.25), v.validX(word), 0.0);
    // y is not valid, so the integer high half is used, sign-extended.
    try expectApproxEqAbs(@as(f32, 7.0), v.validY(word), 0.0);
}

test "signFold rounds onto the 1/65536 grid and reinterprets as signed" {
    // 0.5 survives exactly.
    try expectApproxEqAbs(@as(f64, 0.5), pgxp.signFold(0.5), 0.0);
    // 65535.5 is above the signed 16-bit range and folds negative.
    try expectApproxEqAbs(@as(f64, -0.5), pgxp.signFold(65535.5), 1e-9);
}

test "unsign lifts a negative onto the unsigned 16-bit range" {
    try expectApproxEqAbs(@as(f64, 65535.5), pgxp.unsign(-0.5), 1e-9);
    try expectApproxEqAbs(@as(f64, 3.25), pgxp.unsign(3.25), 0.0);
}

test "overflow extracts the carry out of the low half" {
    try expectApproxEqAbs(@as(f64, 1.0), pgxp.overflow(65536.0 + 12.0), 0.0);
    try expectApproxEqAbs(@as(f64, 0.0), pgxp.overflow(12.0), 0.0);
    try expectApproxEqAbs(@as(f64, -1.0), pgxp.overflow(-12.0), 0.0);
}

test "truncateVertexPosition truncates the integer part to 11 bits and keeps the fraction" {
    // 1500 in 11 bits is 1500 - 2048 = -548.
    try expectApproxEqAbs(@as(f32, -547.75), pgxp.truncateVertexPosition(1500.25), 1e-4);
    // In-range values are untouched.
    try expectApproxEqAbs(@as(f32, 12.75), pgxp.truncateVertexPosition(12.75), 0.0);
    try expectApproxEqAbs(@as(f32, -12.75), pgxp.truncateVertexPosition(-12.75), 0.0);
}

test "a value out of the tracked range folds rather than trapping" {
    // A Debug build must not panic on a garbage value: it is clamped, which
    // is a deliberate divergence from the reference's wrapping conversion.
    // Anything this far out is not a coordinate under any reading.
    _ = pgxp.signFold(1.0e30);
    _ = pgxp.overflow(-1.0e30);
}

test "a vertex resolves when the recorded word matches the wire word" {
    // Low half 100, high half 50 — the packed SXY a projection produced.
    const word: u32 = (@as(u32, 50) << 16) | 100;
    const v: Value = .{
        .x = 100.5,
        .y = 50.25,
        .word = word,
        .flags = Value.valid_xy,
    };
    const pt = Primitive.getPointPrecise(word, v, tolerance_off);
    try expectEqual(true, pt.resolved);
    try expectEqual(@as(i32, @intFromFloat(100.5 * 65536.0)), pt.px);
    try expectEqual(@as(i32, @intFromFloat(50.25 * 65536.0)), pt.py);
}

test "a vertex does not resolve when the recorded word is stale" {
    const word: u32 = (@as(u32, 50) << 16) | 100;
    const stale: Value = .{
        .x = 100.5,
        .y = 50.25,
        .word = word ^ 1,
        .flags = Value.valid_xy,
    };
    const pt = Primitive.getPointPrecise(word, stale, tolerance_off);
    try expectEqual(false, pt.resolved);
    try expectEqual(@as(i32, 100) << 16, pt.px);
}

test "a vertex does not resolve when only one half is valid" {
    const word: u32 = (@as(u32, 50) << 16) | 100;
    const half: Value = .{ .x = 100.5, .y = 50.25, .word = word, .flags = Value.valid_x };
    const pt = Primitive.getPointPrecise(word, half, tolerance_off);
    try expectEqual(false, pt.resolved);
}

test "a resolved position is truncated to 11 bits like the wire coordinate is" {
    // Wire low half 1500 truncates to -548; the precise value must follow it
    // rather than describing a pixel 2048 columns away.
    const word: u32 = (@as(u32, 50) << 16) | 1500;
    const v: Value = .{ .x = 1500.5, .y = 50.0, .word = word, .flags = Value.valid_xy };
    const pt = Primitive.getPointPrecise(word, v, tolerance_off);
    try expectEqual(@as(i16, -548), pt.x);
    try expectEqual(true, pt.resolved);
    try expectEqual(@as(i32, @intFromFloat(-547.5 * 65536.0)), pt.px);
}

/// The identity matrix, no translation, and a divide that saturates — the same
/// arrangement `gte_test.zig`'s RTPS coverage uses, so that SX2 = f(VX0) and a
/// projection can be pushed off screen by VX0 alone.
///
/// `divideUNR`'s guard is `2 * SZ3 > H`, and 2*7 is not > 300, so it returns
/// the clamp constant 0x1FFFF outright. That is where both the fraction and
/// the reach to saturate come from.
fn saturatingProjectionCop2() Cop2 {
    var cop2 = Cop2.init();
    cop2.writeCtrl(0, 0x0000_1000); // RT11 = 4096
    cop2.writeCtrl(1, 0x0000_0000);
    cop2.writeCtrl(2, 0x1000_0000); // RT23 = 4096
    cop2.writeCtrl(3, 0x0000_0000);
    cop2.writeCtrl(4, 0x0000_1000); // RT33 = 4096
    cop2.writeCtrl(5, 0);
    cop2.writeCtrl(6, 0);
    cop2.writeCtrl(7, 0);
    cop2.writeCtrl(24, 0); // OFX
    cop2.writeCtrl(25, 0); // OFY
    cop2.writeCtrl(26, 300); // H
    cop2.writeCtrl(27, 0); // DQA
    cop2.writeCtrl(28, 0); // DQB
    cop2.writeData(1, 7); // VZ0 = 7
    return cop2;
}

// A projection that saturates must record NOTHING.
//
// The recorded word is taken from the saturated register, so it matches the
// wire by construction and the staleness check cannot police this case — the
// rejection has to happen where the saturation is visible. Without it the
// vertex below is drawn 1119 columns from where its own command word says it
// is: MAC0 puts x at 4000.09, `truncateVertexPosition` folds that to -96, and
// the register reads 1023.
//
// Hardware's clamp is the only near-plane clip the machine has, and games rely
// on it, so the integer coordinate has to win here.
test "a saturated projection records no precise value" {
    var cop2 = saturatingProjectionCop2();
    cop2.writeData(0, 2000); // VXY0: VX0 = 2000, VY0 = 0

    cop2.executeCommand(0x4A18_0001, .{}); // RTPS, sf=1, lm=0

    // SX2 clamped to the top of the 11-bit range.
    try expectEqual(@as(u32, 1023), cop2.readData(14) & 0xFFFF);
    try expectEqual(@as(u32, 0), cop2.readPreciseData(14).flags);
}

// And the guard is not a blanket disable: the same projection inside the
// saturation range keeps its sub-pixel, recorded against the register word.
//
// This one sits ON `divideUNR`'s 0x1FFFF cap (2*SZ3 = 14 is not > H = 300), so
// it is also what pins the float projection's ratio to that same cap rather
// than to a round 2.0: at 2.0 the precise x would be exactly 10.0 against a
// register that reads 9 -- a whole pixel out, for a vertex the wire has
// already placed.
test "an unsaturated projection records the sub-pixel the float projection computed" {
    var cop2 = saturatingProjectionCop2();
    cop2.writeData(0, 5); // VXY0: VX0 = 5, VY0 = 0

    cop2.executeCommand(0x4A18_0001, .{}); // RTPS, sf=1, lm=0

    const p = cop2.readPreciseData(14);
    try expectEqual(Value.valid_xyz, p.flags);
    try expectEqual(cop2.readData(14), p.word);
    // 5 * 0x1FFFF >> 16 = 9, with a fraction, or the test proves nothing.
    try expectEqual(@as(u32, 9), cop2.readData(14) & 0xFFFF);
    try expectEqual(@as(f32, 9.0), @floor(p.x));
    try std.testing.expect(p.x != @trunc(p.x));
    // H/2 = 150 wins over SZ3 = 7 -- the near clamp, which is the same
    // condition that put the ratio on the cap above.
    try expectApproxEqAbs(@as(f32, 150.0), p.z, 0.0);
}

// `f32` cannot hold every 16.16 position: a fraction within half an ulp of 1.0
// rounds UP onto the next integer. At x = 1023 that lands on 1024, whose
// 11-bit fold is -1024, and the vertex is drawn 2047 columns from where its
// own command word says it is. crash-bandicoot-2 reported a full-pixel
// displacement in `trace-golden -- pgxp` before this was bounded.
//
// The bound is NOT a staleness check -- the word match already did that -- it
// is the renderer's documented invariant, `px >> 16 == x`.
test "a precise position that rounds up onto the next integer stays in its pixel" {
    const word: u32 = (@as(u32, 50) << 16) | 1023;
    const v: Value = .{ .x = 1024.0, .y = 50.0, .word = word, .flags = Value.valid_xy };
    const pt = Primitive.getPointPrecise(word, v, tolerance_off);
    try expectEqual(@as(i16, 1023), pt.x);
    try expectEqual(true, pt.resolved);
    // Which end of the pixel it lands on is arbitrary at 1/65536 px; that it
    // stays inside the pixel the wire names is the whole invariant.
    try expectEqual(@as(i32, 1023), pt.px >> 16);
}

/// A GTE with a projection staged: identity rotation at 4.12, no translation,
/// so IR1/IR2 are the input coordinates and SZ3 is the input z. Every RTPS
/// below runs at sf=12, which is what makes that hold.
fn stageProjection(cop2: *Cop2, vx: i16, vy: i16, vz: i16, h: u16, ofx: i32, ofy: i32) void {
    // RT = identity at 1.0 in 4.12. The five control words pack the matrix
    // row-major across halfwords: RT11/RT12, RT13/RT21, RT22/RT23, RT31/RT32,
    // RT33.
    cop2.writeCtrl(0, 0x0000_1000);
    cop2.writeCtrl(1, 0x0000_0000);
    cop2.writeCtrl(2, 0x0000_1000);
    cop2.writeCtrl(3, 0x0000_0000);
    cop2.writeCtrl(4, 0x0000_1000);
    // TR = 0.
    cop2.writeCtrl(5, 0);
    cop2.writeCtrl(6, 0);
    cop2.writeCtrl(7, 0);
    cop2.writeCtrl(24, @bitCast(ofx));
    cop2.writeCtrl(25, @bitCast(ofy));
    cop2.writeCtrl(26, h);
    cop2.writeCtrl(27, 0); // DQA
    cop2.writeCtrl(28, 0); // DQB
    cop2.writeData(0, (@as(u32, @as(u16, @bitCast(vy))) << 16) | @as(u32, @as(u16, @bitCast(vx))));
    cop2.writeData(1, @as(u32, @as(u16, @bitCast(vz))));
}

test "RTPS records a depth term of max(H/2, SZ3)" {
    var cop2 = Cop2.init();
    // vz = 2000, H = 1000, so SZ3 = 2000 and H/2 = 500: the depth is SZ3.
    stageProjection(&cop2, 16, 32, 2000, 1000, 0, 0);
    cop2.executeCommand(0x4A08_0001, .{});

    const p = cop2.readPreciseData(14);
    try expectEqual(Value.valid_xyz, p.flags & Value.valid_xyz);
    try expectApproxEqAbs(@as(f32, 2000.0), p.z, 0.5);
}

test "RTPS clamps the depth term up to H/2 for near geometry" {
    var cop2 = Cop2.init();
    // vz = 100, H = 1000: H/2 = 500 wins.
    stageProjection(&cop2, 16, 32, 100, 1000, 0, 0);
    cop2.executeCommand(0x4A08_0001, .{});

    try expectApproxEqAbs(@as(f32, 500.0), cop2.readPreciseData(14).z, 0.5);
}

test "the precise position is the float projection, not the hardware MAC0" {
    var cop2 = Cop2.init();
    // A depth chosen so the UNR reciprocal is inexact, which is what makes the
    // float projection differ from MAC0 >> 16 at all.
    stageProjection(&cop2, 300, 200, 1234, 1000, 0, 0);
    cop2.executeCommand(0x4A08_0001, .{});

    const p = cop2.readPreciseData(14);
    const expected_x: f32 = 300.0 * (1000.0 / 1234.0);
    const expected_y: f32 = 200.0 * (1000.0 / 1234.0);
    try expectApproxEqAbs(expected_x, p.x, 0.002);
    try expectApproxEqAbs(expected_y, p.y, 0.002);

    // And it is recorded against the integer register, which is what the word
    // match at consumption then requires.
    try expectEqual(cop2.readData(14), p.word);
}

test "the drawing offset reaches the precise position" {
    var cop2 = Cop2.init();
    // OFX/OFY are 16.16: 40.5 and -8.25 pixels.
    stageProjection(&cop2, 0, 0, 1000, 1000, 40 * 65536 + 32768, -(8 * 65536 + 16384));
    cop2.executeCommand(0x4A08_0001, .{});

    const p = cop2.readPreciseData(14);
    try expectApproxEqAbs(@as(f32, 40.5), p.x, 0.001);
    try expectApproxEqAbs(@as(f32, -8.25), p.y, 0.001);
}

test "a projection with no depth records nothing rather than a NaN" {
    var cop2 = Cop2.init();
    // H = 0 and SZ3 = 0 leaves the divisor at zero.
    stageProjection(&cop2, 16, 32, 0, 0, 0, 0);
    cop2.executeCommand(0x4A08_0001, .{});

    try expectEqual(@as(u32, 0), cop2.readPreciseData(14).flags);
}

// The shadow set. Three SXY slots cannot hold a value that moves through a
// GTE scratch register on its way to a projection, so every data register
// carries one — with the FIFO's behaviour confined to 12..15.

test "a GTE register outside the SXY FIFO keeps a precise value" {
    var cop2 = Cop2.init();

    const staged: Value = .{ .x = 3.5, .y = 4.5, .word = 0x0004_0003, .flags = Value.valid_xy };
    cop2.writeDataPrecise(9, 0x0004_0003, staged);

    const back = cop2.readPreciseData(9);
    try expectApproxEqAbs(@as(f32, 3.5), back.x, 0.0);
    // IR1 sign-extends its low half, so the register reads back 3 rather than
    // the word written — and the entry is recorded against what it reads,
    // which is the only word it can ever be validated against.
    try expectEqual(cop2.readData(9), back.word);
}

test "writing SXYP pushes the precise FIFO along with the registers" {
    var cop2 = Cop2.init();

    const a: Value = .{ .x = 1.5, .y = 1.5, .word = 0x0001_0001, .flags = Value.valid_xy };
    const b: Value = .{ .x = 2.5, .y = 2.5, .word = 0x0002_0002, .flags = Value.valid_xy };
    cop2.writeDataPrecise(15, 0x0001_0001, a);
    cop2.writeDataPrecise(15, 0x0002_0002, b);

    // a has been pushed down to sxy1, b sits in sxy2.
    try expectApproxEqAbs(@as(f32, 1.5), cop2.readPreciseData(13).x, 0.0);
    try expectApproxEqAbs(@as(f32, 2.5), cop2.readPreciseData(14).x, 0.0);
    // And 15 still mirrors sxy2 on the way back out.
    try expectApproxEqAbs(@as(f32, 2.5), cop2.readPreciseData(15).x, 0.0);
}

test "the read-only GTE registers refuse a precise write" {
    var cop2 = Cop2.init();

    const staged: Value = .{ .x = 3.5, .y = 4.5, .word = 0x1234, .flags = Value.valid_xy };
    cop2.writeDataPrecise(29, 0x1234, staged);
    try expectEqual(@as(u32, 0), cop2.readPreciseData(29).flags);
    cop2.writeDataPrecise(31, 0x1234, staged);
    try expectEqual(@as(u32, 0), cop2.readPreciseData(31).flags);
}

// The half-word memory hooks. A game that stores its two coordinates with
// separate `sh` instructions never touches the whole-word store hook, which is
// the leading hypothesis for the three discs that resolve only the BIOS logo.

const Bus = ps1_core.memory.Bus;
const Cpu = ps1_core.cpu.Cpu;

/// A heap `Bus` and a `Cpu` pointed at it, so a test can run one real
/// instruction against the real memory map.
const CpuContext = struct {
    bus: *Bus,
    cpu: Cpu,
    allocator: std.mem.Allocator,

    pub fn init() !CpuContext {
        const allocator = std.testing.allocator;
        const bus = try Bus.init(allocator);
        var cpu = Cpu.init(bus);
        cpu.pipeline.pc = 0x0000_0000;
        cpu.pipeline.next_pc = 0x0000_0004;
        return CpuContext{ .bus = bus, .cpu = cpu, .allocator = allocator };
    }

    pub fn deinit(self: *CpuContext) void {
        self.bus.deinit(self.allocator);
    }

    /// Plant `instruction` at the current PC and step once. The I-cache is
    /// flushed first, or the second instruction of a test reads the first.
    pub fn execute(self: *CpuContext, instruction: u32) void {
        self.bus.write32(self.cpu.pipeline.pc, instruction);
        self.cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
        self.cpu.step();
    }
};

fn iType(op: u6, base: u5, rt: u5, imm: u16) u32 {
    return (@as(u32, op) << 26) | (@as(u32, base) << 21) | (@as(u32, rt) << 16) | imm;
}

test "a half-word store writes one half and leaves the other alone" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);

    const addr: u32 = 0x0010_0000;
    // A whole word first, both halves precise.
    ctx.bus.shadowStore(addr, .{ .x = 1.5, .y = 2.5, .word = 0x0002_0001, .flags = Value.valid_xy });
    // Then a half-word store into the HIGH half only.
    ctx.bus.shadowStoreHalf(addr + 2, .{ .x = 9.75, .word = 0x0009, .flags = Value.valid_x });

    const back = ctx.bus.shadowLoad(addr);
    try expectApproxEqAbs(@as(f32, 1.5), back.x, 0.0);
    try expectApproxEqAbs(@as(f32, 9.75), back.y, 0.0);
    try expectEqual(Value.valid_xy, back.flags & Value.valid_xy);
    // And the recorded word follows the half that moved, or the next load
    // validates the surviving half against an integer that is no longer there.
    try expectEqual(@as(u32, 0x0009_0001), back.word);
}

test "a half-word load takes the addressed half into x and sign-extends into y" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);

    const addr: u32 = 0x0010_0000;
    const word: u32 = (@as(u32, @as(u16, @bitCast(@as(i16, -5)))) << 16) | 7;
    ctx.bus.shadowStore(addr, .{ .x = 7.5, .y = -5.25, .word = word, .flags = Value.valid_xy });

    // Load the HIGH half, signed: it becomes the new x, and y is its sign.
    const hi = ctx.bus.shadowLoadHalf(addr + 2, 0xFFFF_FFFB, true);
    try expectApproxEqAbs(@as(f32, -5.25), hi.x, 0.0);
    try expectApproxEqAbs(@as(f32, -1.0), hi.y, 0.0);
    try expectEqual(Value.valid_xy, hi.flags & Value.valid_xy);

    // Load the LOW half, unsigned: y is zero.
    const lo = ctx.bus.shadowLoadHalf(addr, 0x0000_0007, false);
    try expectApproxEqAbs(@as(f32, 7.5), lo.x, 0.0);
    try expectApproxEqAbs(@as(f32, 0.0), lo.y, 0.0);
}

test "a half-word load validates only the half it touches" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);

    const addr: u32 = 0x0010_0000;
    ctx.bus.shadowStore(addr, .{ .x = 7.5, .y = 3.5, .word = 0x0003_0007, .flags = Value.valid_xy });

    // The HIGH half changed under us; a load of the LOW half is still good.
    const lo = ctx.bus.shadowLoadHalf(addr, 0x0000_0007, true);
    try expectEqual(Value.valid_x, lo.flags & Value.valid_x);
    // A load of the HIGH half is not.
    const hi = ctx.bus.shadowLoadHalf(addr + 2, 0x0000_0099, true);
    try expectEqual(@as(u32, 0), hi.flags & Value.valid_x);
}

test "a byte store still destroys the whole word" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);

    const addr: u32 = 0x0010_0000;
    ctx.bus.shadowStore(addr, .{ .x = 1.5, .y = 2.5, .word = 0x0002_0001, .flags = Value.valid_xy });
    ctx.bus.shadowInvalidate(addr + 1);
    try expectEqual(@as(u32, 0), ctx.bus.shadowLoad(addr).flags);
}

// The three tests above pin the `Bus` methods. These pin the CPU wiring, which
// is the half that Croc actually exercises.

test "sh carries the register's shadow into the addressed half" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);

    const addr: u32 = 0x0010_0000;
    ctx.bus.write32(addr, 0x0002_0001);
    ctx.bus.shadowStore(addr, .{ .x = 1.5, .y = 2.5, .word = 0x0002_0001, .flags = Value.valid_xy });

    ctx.cpu.writeReg(1, addr);
    ctx.cpu.writeRegPrecise(2, 0x0000_0009, .{ .x = 9.75, .word = 0x0000_0009, .flags = Value.valid_x });
    ctx.execute(iType(0x29, 1, 2, 2)); // sh $2, 2($1)

    const back = ctx.bus.shadowLoad(addr);
    try expectApproxEqAbs(@as(f32, 1.5), back.x, 0.0);
    try expectApproxEqAbs(@as(f32, 9.75), back.y, 0.0);
    try expectEqual(Value.valid_xy, back.flags & Value.valid_xy);
    try expectEqual(@as(u32, 0x0009_0001), back.word);
}

test "lh carries the addressed half's shadow into the destination register" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);

    const addr: u32 = 0x0010_0000;
    ctx.bus.write32(addr, 0x0003_0007);
    ctx.bus.shadowStore(addr, .{ .x = 7.5, .y = 3.5, .word = 0x0003_0007, .flags = Value.valid_xy });

    ctx.cpu.writeReg(1, addr);
    ctx.execute(iType(0x21, 1, 2, 0)); // lh $2, 0($1)
    ctx.execute(0); // nop, retiring the load delay slot

    const p = ctx.cpu.gpr_shadow[2];
    try expectApproxEqAbs(@as(f32, 7.5), p.x, 0.0);
    try expectEqual(Value.valid_xy, p.flags & Value.valid_xy);
    // Recorded against what the register actually holds, which is the
    // sign-extended half rather than the word it came out of.
    try expectEqual(@as(u32, 7), p.word);
}

test "lb keeps nothing -- a byte cannot carry a coordinate" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);

    const addr: u32 = 0x0010_0000;
    ctx.bus.write32(addr, 0x0003_0007);
    ctx.bus.shadowStore(addr, .{ .x = 7.5, .y = 3.5, .word = 0x0003_0007, .flags = Value.valid_xy });

    ctx.cpu.writeReg(1, addr);
    ctx.execute(iType(0x20, 1, 2, 0)); // lb $2, 0($1)
    ctx.execute(0);

    try expectEqual(@as(u32, 0), ctx.cpu.gpr_shadow[2].flags);
}

test "an unaligned store that overwrites one half leaves the other half's shadow" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);

    const addr: u32 = 0x0010_0000;
    ctx.bus.write32(addr, 0x0002_0001);
    ctx.bus.shadowStore(addr, .{ .x = 1.5, .y = 2.5, .word = 0x0002_0001, .flags = Value.valid_xy });

    ctx.cpu.writeReg(1, addr);
    ctx.execute(iType(0x2A, 1, 2, 0)); // swl $2, 0($1) -- byte 0 only

    const back = ctx.bus.shadowLoad(addr);
    try expectEqual(@as(u32, 0), back.flags & Value.valid_x);
    try expectEqual(Value.valid_y, back.flags & Value.valid_y);
    try expectApproxEqAbs(@as(f32, 2.5), back.y, 0.0);
    // The surviving half must be recorded against the word memory now holds.
    try expectEqual(ctx.bus.read32(addr), back.word);
}

test "an unaligned store that reaches both halves destroys the word" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);

    const addr: u32 = 0x0010_0000;
    ctx.bus.write32(addr, 0x0002_0001);
    ctx.bus.shadowStore(addr, .{ .x = 1.5, .y = 2.5, .word = 0x0002_0001, .flags = Value.valid_xy });

    ctx.cpu.writeReg(1, addr);
    ctx.execute(iType(0x2E, 1, 2, 1)); // swr $2, 1($1) -- bytes 1..3

    try expectEqual(@as(u32, 0), ctx.bus.shadowLoad(addr).flags);
}

// --- Task 6: CPU mode, the dispatch seam and the immediate ops ---------------

test "CPU mode is off by default" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    try expectEqual(false, ctx.bus.pgxp_cpu);
}

test "an immediate add carries between the halves" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    // $t0 low half 0xFFF0, precise at -15.5 read signed; high half 3.
    ctx.cpu.regs[8] = 0x0003_FFF0;
    ctx.cpu.gpr_shadow[8] = .{ .x = -15.5, .y = 3.0, .word = 0x0003_FFF0, .flags = Value.valid_xy };

    // addiu $t1, $t0, 0x20 -- the low half wraps and carries into the high.
    ctx.execute(iType(0x09, 8, 9, 0x0020));

    const p = ctx.cpu.gpr_shadow[9];
    try expectApproxEqAbs(@as(f32, 16.5), p.x, 0.01);
    try expectApproxEqAbs(@as(f32, 4.0), p.y, 0.01);
    try expectEqual(@as(u32, 0x0004_0010), p.word);
}

test "an immediate add into its own source register keeps propagating" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0003_FFF0;
    ctx.cpu.gpr_shadow[8] = .{ .x = -15.5, .y = 3.0, .word = 0x0003_FFF0, .flags = Value.valid_xy };

    // addiu $t0, $t0, 0x20 -- destination IS source. A hook that ran after the
    // integer write would read a shadow writeReg had already cleared, and a
    // register the write had already overwritten.
    ctx.execute(iType(0x09, 8, 8, 0x0020));

    const p = ctx.cpu.gpr_shadow[8];
    try expectEqual(Value.valid_xy, p.flags & Value.valid_xy);
    try expectApproxEqAbs(@as(f32, 16.5), p.x, 0.01);
    try expectApproxEqAbs(@as(f32, 4.0), p.y, 0.01);
    try expectEqual(@as(u32, 0x0004_0010), p.word);
}

test "an immediate add of zero is a move and keeps the value untouched" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0002_0001;
    ctx.cpu.gpr_shadow[8] = .{ .x = 1.5, .y = 2.5, .z = 9.0, .word = 0x0002_0001, .flags = Value.valid_xyz };

    const p = pgxp.ops.addi(&ctx.cpu, 8, 0, 0x0002_0001);
    try expectApproxEqAbs(@as(f32, 1.5), p.x, 0.0);
    try expectApproxEqAbs(@as(f32, 9.0), p.z, 0.0);
    try expectEqual(Value.valid_z, p.flags & Value.valid_z);
    // A move alters nothing, so the depth still describes the position.
    try expectEqual(@as(u32, 0), p.flags & Value.tainted_z);
}

test "an immediate add onto a zero register is exactly the immediate" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    // addiu $t1, $zero, -3 -- the constant-load idiom.
    ctx.execute(iType(0x09, 0, 9, 0xFFFD));

    const p = ctx.cpu.gpr_shadow[9];
    try expectEqual(Value.valid_xy, p.flags & Value.valid_xy);
    try expectApproxEqAbs(@as(f32, -3.0), p.x, 0.0);
    try expectApproxEqAbs(@as(f32, -1.0), p.y, 0.0);
    try expectEqual(@as(u32, 0xFFFF_FFFD), p.word);
}

test "andi with 0xFFFF keeps the precise low half and clears the high" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0002_0001;
    ctx.cpu.gpr_shadow[8] = .{ .x = 1.25, .y = 2.5, .word = 0x0002_0001, .flags = Value.valid_xy };

    ctx.execute(iType(0x0C, 8, 9, 0xFFFF));

    const p = ctx.cpu.gpr_shadow[9];
    try expectApproxEqAbs(@as(f32, 1.25), p.x, 0.0);
    try expectApproxEqAbs(@as(f32, 0.0), p.y, 0.0);
    try expectEqual(Value.valid_xy, p.flags & Value.valid_xy);
    try expectEqual(@as(u32, 0x0000_0001), p.word);
}

test "andi with a partial mask falls back to the integer low half" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0002_0009;
    ctx.cpu.gpr_shadow[8] = .{ .x = 9.75, .y = 2.5, .word = 0x0002_0009, .flags = Value.valid_xy };

    ctx.execute(iType(0x0C, 8, 9, 0xFFF8));

    // The masked value is no longer 9.75 by any reading; the integer wins.
    try expectApproxEqAbs(@as(f32, 8.0), ctx.cpu.gpr_shadow[9].x, 0.0);
}

test "ori with a zero immediate is the register-move idiom" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0002_0001;
    ctx.cpu.gpr_shadow[8] = .{ .x = 1.5, .y = 2.5, .z = 9.0, .word = 0x0002_0001, .flags = Value.valid_xyz };

    ctx.execute(iType(0x0D, 8, 9, 0x0000));

    const p = ctx.cpu.gpr_shadow[9];
    try expectApproxEqAbs(@as(f32, 1.5), p.x, 0.0);
    try expectApproxEqAbs(@as(f32, 2.5), p.y, 0.0);
    try expectApproxEqAbs(@as(f32, 9.0), p.z, 0.0);
    try expectEqual(Value.valid_xyz, p.flags & Value.valid_xyz);
}

test "ori with a real immediate keeps the high half and loses the low" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0002_0000;
    ctx.cpu.gpr_shadow[8] = .{ .x = 0.5, .y = 2.5, .word = 0x0002_0000, .flags = Value.valid_xy };

    ctx.execute(iType(0x0D, 8, 9, 0x0007));

    const p = ctx.cpu.gpr_shadow[9];
    try expectApproxEqAbs(@as(f32, 7.0), p.x, 0.0);
    try expectApproxEqAbs(@as(f32, 2.5), p.y, 0.0);
    try expectEqual(Value.valid_xy, p.flags & Value.valid_xy);
}

test "lui is exactly its immediate in the high half" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.execute(iType(0x0F, 0, 9, 0x8003));

    const p = ctx.cpu.gpr_shadow[9];
    try expectEqual(Value.valid_xy, p.flags & Value.valid_xy);
    try expectApproxEqAbs(@as(f32, 0.0), p.x, 0.0);
    try expectApproxEqAbs(@as(f32, -32765.0), p.y, 0.0);
    try expectEqual(@as(u32, 0x8003_0000), p.word);
}

test "slti records the comparison's exact integer result" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0002_0001;
    ctx.cpu.gpr_shadow[8] = .{ .x = 1.5, .y = 2.5, .z = 9.0, .word = 0x0002_0001, .flags = Value.valid_xyz };

    ctx.execute(iType(0x0A, 8, 9, 0x7FFF)); // slti $t1, $t0, 32767 -> 0

    const p = ctx.cpu.gpr_shadow[9];
    try expectEqual(Value.valid_xy, p.flags & Value.valid_xy);
    // Nothing precise survives a comparison, depth included.
    try expectEqual(@as(u32, 0), p.flags & Value.valid_z);
    try expectApproxEqAbs(@as(f32, 0.0), p.x, 0.0);
}

test "a stale source is validated away before it propagates" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    // The shadow was recorded against a word the register no longer holds.
    ctx.cpu.regs[8] = 0x0000_0005;
    ctx.cpu.gpr_shadow[8] = .{ .x = 1.5, .y = 2.5, .word = 0x0002_0001, .flags = Value.valid_xy };

    ctx.execute(iType(0x09, 8, 9, 0x0020));

    try expectEqual(@as(u32, 0), ctx.cpu.gpr_shadow[9].flags & Value.valid_xy);
    // And the stale entry is dropped where it sat, not just where it was read.
    try expectEqual(@as(u32, 0), ctx.cpu.gpr_shadow[8].flags);
}

test "CPU mode propagates nothing when off" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);

    ctx.cpu.regs[8] = 0x0003_FFF0;
    ctx.cpu.gpr_shadow[8] = .{ .x = -15.5, .y = 3.0, .word = 0x0003_FFF0, .flags = Value.valid_xy };

    ctx.execute(iType(0x09, 8, 9, 0x0020));

    try expectEqual(@as(u32, 0), ctx.cpu.gpr_shadow[9].flags);
}

fn rType(rs: u5, rt: u5, rd: u5, funct: u6) u32 {
    return (@as(u32, rs) << 21) | (@as(u32, rt) << 16) | (@as(u32, rd) << 11) | @as(u32, funct);
}

test "adding two tracked registers carries between the halves" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0001_8000;
    ctx.cpu.gpr_shadow[8] = .{ .x = -32768.0, .y = 1.0, .word = 0x0001_8000, .flags = Value.valid_xy };
    ctx.cpu.regs[9] = 0x0001_8000;
    ctx.cpu.gpr_shadow[9] = .{ .x = -32768.0, .y = 1.0, .word = 0x0001_8000, .flags = Value.valid_xy };

    const p = pgxp.ops.add(&ctx.cpu, 8, 9, 0x0003_0000);
    try expectApproxEqAbs(@as(f32, 0.0), p.x, 0.01);
    try expectApproxEqAbs(@as(f32, 3.0), p.y, 0.01);
}

test "adding zero is a move that adopts the other operand's depth" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0002_0001;
    ctx.cpu.gpr_shadow[8] = .{ .x = 1.5, .y = 2.5, .word = 0x0002_0001, .flags = Value.valid_xy };
    ctx.cpu.regs[9] = 0;
    ctx.cpu.gpr_shadow[9] = .{ .z = 42.0, .word = 0, .flags = Value.valid_z };

    const p = pgxp.ops.add(&ctx.cpu, 8, 9, 0x0002_0001);
    try expectApproxEqAbs(@as(f32, 1.5), p.x, 0.0);
    try expectApproxEqAbs(@as(f32, 42.0), p.z, 0.0);
    try expectEqual(Value.valid_z, p.flags & Value.valid_z);
    // Adding nothing alters nothing, so the depth still describes the
    // position beside it. Without the zero-operand shortcut the general
    // arithmetic path taints it.
    try expectEqual(@as(u32, 0), p.flags & Value.tainted_z);
}

test "an untainted depth beats a tainted one when two values combine" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0000_0010;
    ctx.cpu.gpr_shadow[8] = .{
        .x = 16.0,
        .y = 0,
        .z = 1.0,
        .word = 0x0000_0010,
        .flags = Value.valid_xyz | Value.tainted_z,
    };
    ctx.cpu.regs[9] = 0x0000_0020;
    ctx.cpu.gpr_shadow[9] = .{ .x = 32.0, .y = 0, .z = 2.0, .word = 0x0000_0020, .flags = Value.valid_xyz };

    const p = pgxp.ops.add(&ctx.cpu, 8, 9, 0x0000_0030);
    try expectApproxEqAbs(@as(f32, 2.0), p.z, 0.0);
}

test "a subtraction borrows out of the high half" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0003_0000;
    ctx.cpu.gpr_shadow[8] = .{ .x = 0.0, .y = 3.0, .word = 0x0003_0000, .flags = Value.valid_xy };
    ctx.cpu.regs[9] = 0x0000_8000;
    ctx.cpu.gpr_shadow[9] = .{ .x = -32768.0, .y = 0.0, .word = 0x0000_8000, .flags = Value.valid_xy };

    const p = pgxp.ops.sub(&ctx.cpu, 8, 9, 0x0002_8000);
    try expectApproxEqAbs(@as(f32, -32768.0), p.x, 0.01);
    try expectApproxEqAbs(@as(f32, 2.0), p.y, 0.01);
}

test "a bitwise op keeps the depth and takes its halves from the integer result" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0003_0005;
    ctx.cpu.gpr_shadow[8] = .{ .x = 5.5, .y = 3.5, .z = 7.0, .word = 0x0003_0005, .flags = Value.valid_xyz };
    ctx.cpu.regs[9] = 0x0000_0003;
    ctx.cpu.gpr_shadow[9] = .{ .word = 0x0000_0003 };

    const p = pgxp.ops.bitwise(&ctx.cpu, 8, 9, 0x0000_0001);
    try expectApproxEqAbs(@as(f32, 1.0), p.x, 0.0);
    try expectApproxEqAbs(@as(f32, 0.0), p.y, 0.0);
    try expectApproxEqAbs(@as(f32, 7.0), p.z, 0.0);
}

test "a comparison is exact and carries no depth" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0000_0005;
    ctx.cpu.gpr_shadow[8] = .{ .x = 5.5, .y = 0.0, .z = 7.0, .word = 0x0000_0005, .flags = Value.valid_xyz };
    ctx.cpu.regs[9] = 0x0000_0009;

    const p = pgxp.ops.sltReg(&ctx.cpu, 8, 9, 1);
    try expectApproxEqAbs(@as(f32, 1.0), p.x, 0.0);
    try expectApproxEqAbs(@as(f32, 0.0), p.y, 0.0);
    try expectEqual(Value.valid_xy, p.flags & Value.valid_xyz);
}

test "a register add reaches its hook through the real dispatch" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0003_FFF0;
    ctx.cpu.gpr_shadow[8] = .{ .x = -15.5, .y = 3.0, .word = 0x0003_FFF0, .flags = Value.valid_xy };
    ctx.cpu.regs[9] = 0x0000_0020;

    // addu $t2, $t0, $t1 -- the low half wraps and carries into the high.
    ctx.execute(rType(8, 9, 10, 0x21));

    const p = ctx.cpu.gpr_shadow[10];
    try expectApproxEqAbs(@as(f32, 16.5), p.x, 0.01);
    try expectApproxEqAbs(@as(f32, 4.0), p.y, 0.01);
    try expectEqual(@as(u32, 0x0004_0010), p.word);
}

test "a register bitwise op propagates nothing when CPU mode is off" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);

    ctx.cpu.regs[8] = 0x0003_0005;
    ctx.cpu.gpr_shadow[8] = .{ .x = 5.5, .y = 3.5, .z = 7.0, .word = 0x0003_0005, .flags = Value.valid_xyz };
    ctx.cpu.regs[9] = 0x0000_0003;

    // and $t2, $t0, $t1
    ctx.execute(rType(8, 9, 10, 0x24));

    try expectEqual(@as(u32, 0), ctx.cpu.gpr_shadow[10].flags);
}

fn rShift(rt: u5, rd: u5, shamt: u5, funct: u6) u32 {
    return (@as(u32, rt) << 16) | (@as(u32, rd) << 11) | (@as(u32, shamt) << 6) | @as(u32, funct);
}

test "a left shift by 16 moves the low half into the high half" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0000_0007;
    ctx.cpu.gpr_shadow[8] = .{ .x = 7.25, .y = 0.0, .word = 0x0000_0007, .flags = Value.valid_xy };

    const p = pgxp.shift.left(&ctx.cpu, 8, 16, 0x0007_0000);
    try expectApproxEqAbs(@as(f32, 7.25), p.y, 0.0);
    try expectApproxEqAbs(@as(f32, 0.0), p.x, 0.0);
    // The source's high half was tracked, so the destination's low half — an
    // exact zero — is allowed to say so.
    try expectEqual(Value.valid_xy, p.flags & Value.valid_xy);
}

test "the pack and unpack idiom round-trips a precise half" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    // A packed SXY: x = 100.5 in the low half, y = 50.25 in the high.
    ctx.cpu.regs[8] = (@as(u32, 50) << 16) | 100;
    ctx.cpu.gpr_shadow[8] = .{
        .x = 100.5,
        .y = 50.25,
        .word = ctx.cpu.regs[8],
        .flags = Value.valid_xy,
    };

    // sra $t1, $t0, 16 -- unpack the high half into its own register.
    const unpacked = pgxp.shift.sra(&ctx.cpu, 8, 16, 50);
    ctx.cpu.writeRegPrecise(9, 50, unpacked);
    try expectApproxEqAbs(@as(f32, 50.25), ctx.cpu.gpr_shadow[9].x, 0.001);

    // sll $t2, $t1, 16 -- and put it back.
    const packed_again = pgxp.shift.left(&ctx.cpu, 9, 16, 50 << 16);
    try expectApproxEqAbs(@as(f32, 50.25), packed_again.y, 0.001);
}

test "a left shift by 16 does not mark x valid from an untracked source" {
    // THE SPYRO RULE. The naive form marks the destination's x valid outright,
    // because the shift zeroes the low half and zero is exactly known. The
    // valid bit is derived from the SOURCE's y bit instead, so a register
    // whose halves were never tracked cannot start claiming a precise low
    // half of zero and spread it.
    //
    // Verify this test FAILS against the naive version before implementing.
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0000_0007;
    // A value sitting in the table with neither half established.
    ctx.cpu.gpr_shadow[8] = .{ .x = 7.25, .word = 0x0000_0007, .flags = 0 };

    const p = pgxp.shift.left(&ctx.cpu, 8, 16, 0x0007_0000);
    try expectEqual(@as(u32, 0), p.flags & Value.valid_x);
}

test "a small signed shift of a non-3D value falls back to the integers" {
    // THE PERSONA 2 RULE. A signed, non-variable shift under 16 of a value
    // carrying no depth is overwhelmingly not geometry, and treating it as
    // precise produces false positives that spread through the register file.
    // The rounded integer halves are used instead.
    //
    // Verify this test FAILS against the unconditional version.
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0000_0009;
    // No valid_z: this value did not come from a projection.
    ctx.cpu.gpr_shadow[8] = .{ .x = 9.75, .y = 0.0, .word = 0x0000_0009, .flags = Value.valid_xy };

    const p = pgxp.shift.sra(&ctx.cpu, 8, 1, 0x0000_0004);
    // 9.75 / 2 would be 4.875; the integer result 4 is used instead.
    try expectApproxEqAbs(@as(f32, 4.0), p.x, 0.0);
    try expectEqual(Value.valid_xy | Value.tainted_z, p.flags);
}

test "the same shift of a projected value keeps its precision" {
    // The control for the rule above: with a depth term present the value IS
    // geometry, and the precise path runs.
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0000_0009;
    ctx.cpu.gpr_shadow[8] = .{
        .x = 9.75,
        .y = 0.0,
        .z = 400.0,
        .word = 0x0000_0009,
        .flags = Value.valid_xyz,
    };

    const p = pgxp.shift.sra(&ctx.cpu, 8, 1, 0x0000_0004);
    try expectApproxEqAbs(@as(f32, 4.875), p.x, 0.001);
    try expectApproxEqAbs(@as(f32, 400.0), p.z, 0.0);
}

test "a shift by zero passes the value through untouched" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0002_0001;
    ctx.cpu.gpr_shadow[8] = .{
        .x = 1.5,
        .y = 2.5,
        .z = 3.5,
        .word = 0x0002_0001,
        .flags = Value.valid_xyz,
    };

    const p = pgxp.shift.sra(&ctx.cpu, 8, 0, 0x0002_0001);
    try expectApproxEqAbs(@as(f32, 1.5), p.x, 0.0);
    try expectApproxEqAbs(@as(f32, 3.5), p.z, 0.0);
    try expectEqual(Value.valid_xyz, p.flags & Value.valid_xyz);
}

test "an unsigned shift lifts the high half rather than sign-extending it" {
    // srl, so the high half is read unsigned: -1 in the high half is 65535
    // sliding down into the low one, not a sign that fills it.
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0xFFFF_0000;
    ctx.cpu.gpr_shadow[8] = .{ .x = 0.0, .y = -1.0, .word = 0xFFFF_0000, .flags = Value.valid_xy };

    const p = pgxp.shift.srl(&ctx.cpu, 8, 16, 0x0000_FFFF);
    try expectApproxEqAbs(@as(f32, -1.0), p.x, 0.0);
    try expectApproxEqAbs(@as(f32, 0.0), p.y, 0.0);
}

test "a shift reaches its hook through the real dispatch" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0000_0007;
    ctx.cpu.gpr_shadow[8] = .{ .x = 7.25, .y = 0.0, .word = 0x0000_0007, .flags = Value.valid_xy };

    // sll $t1, $t0, 16
    ctx.execute(rShift(8, 9, 16, 0x00));

    const p = ctx.cpu.gpr_shadow[9];
    try expectApproxEqAbs(@as(f32, 7.25), p.y, 0.0);
    try expectEqual(@as(u32, 0x0007_0000), p.word);
}

test "a shift whose destination is its own source still propagates" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0000_0007;
    ctx.cpu.gpr_shadow[8] = .{ .x = 7.25, .y = 0.0, .word = 0x0000_0007, .flags = Value.valid_xy };

    // sll $t0, $t0, 16 -- the hook runs before the integer write, or it finds
    // neither its source shadow nor the integer that shadow was recorded
    // against.
    ctx.execute(rShift(8, 8, 16, 0x00));

    try expectApproxEqAbs(@as(f32, 7.25), ctx.cpu.gpr_shadow[8].y, 0.0);
}

test "a shift propagates nothing when CPU mode is off" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);

    ctx.cpu.regs[8] = 0x0000_0007;
    ctx.cpu.gpr_shadow[8] = .{ .x = 7.25, .y = 0.0, .word = 0x0000_0007, .flags = Value.valid_xy };

    ctx.execute(rShift(8, 9, 16, 0x00));

    try expectEqual(@as(u32, 0), ctx.cpu.gpr_shadow[9].flags);
}

// --- Task 9: CPU mode, multiply, divide, hi/lo and COP0 ---------------------
//
// A multiply is where a game scales a projected coordinate, so it is the op
// that matters most for a title doing its own transform after the GTE.

test "a multiply splits across hi and lo and keeps the depth" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    // 3.5 * 2 = 7, entirely inside the low half.
    ctx.cpu.regs[8] = 3;
    ctx.cpu.gpr_shadow[8] = .{ .x = 3.5, .y = 0.0, .z = 500.0, .word = 3, .flags = Value.valid_xyz };
    ctx.cpu.regs[9] = 2;
    ctx.cpu.gpr_shadow[9] = .{ .x = 2.0, .y = 0.0, .word = 2, .flags = Value.valid_xy };

    ctx.cpu.hi = 0;
    ctx.cpu.lo = 6;
    pgxp.muldiv.mult(&ctx.cpu, 8, 9, true);

    try expectApproxEqAbs(@as(f32, 7.0), ctx.cpu.lo_shadow.x, 0.01);
    try expectApproxEqAbs(@as(f32, 500.0), ctx.cpu.lo_shadow.z, 0.0);
    try expectEqual(Value.tainted_z, ctx.cpu.lo_shadow.flags & Value.tainted_z);
}

test "mflo recovers the multiply's precise result" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.lo = 7;
    ctx.cpu.lo_shadow = .{ .x = 7.5, .y = 0.0, .word = 7, .flags = Value.valid_xy };
    ctx.cpu.writeReg(10, 7);
    pgxp.muldiv.moveFromLo(&ctx.cpu, 10);

    try expectApproxEqAbs(@as(f32, 7.5), ctx.cpu.gpr_shadow[10].x, 0.0);
}

test "a multiply and its mflo reach their hooks through the real dispatch" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 3;
    ctx.cpu.gpr_shadow[8] = .{ .x = 3.5, .y = 0.0, .word = 3, .flags = Value.valid_xy };
    ctx.cpu.regs[9] = 2;
    ctx.cpu.gpr_shadow[9] = .{ .x = 2.0, .y = 0.0, .word = 2, .flags = Value.valid_xy };

    ctx.execute(rType(8, 9, 0, 0x18)); // mult $t0, $t1
    ctx.execute(rType(0, 0, 10, 0x12)); // mflo $t2

    // The integer result is 6; the precise one carries the half the integers
    // could not hold.
    try expectEqual(@as(u32, 6), ctx.cpu.regs[10]);
    try expectApproxEqAbs(@as(f32, 7.0), ctx.cpu.gpr_shadow[10].x, 0.01);
    try expectEqual(Value.valid_x, ctx.cpu.gpr_shadow[10].flags & Value.valid_x);
}

test "a multiply propagates nothing when CPU mode is off" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);

    ctx.cpu.regs[8] = 3;
    ctx.cpu.gpr_shadow[8] = .{ .x = 3.5, .y = 0.0, .word = 3, .flags = Value.valid_xy };
    ctx.cpu.regs[9] = 2;
    ctx.cpu.gpr_shadow[9] = .{ .x = 2.0, .y = 0.0, .word = 2, .flags = Value.valid_xy };

    ctx.execute(rType(8, 9, 0, 0x18));

    try expectEqual(@as(u32, 0), ctx.cpu.lo_shadow.flags);
}

test "a divide produces a precise quotient in lo" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 9;
    ctx.cpu.gpr_shadow[8] = .{ .x = 9.5, .y = 0.0, .word = 9, .flags = Value.valid_xy };
    ctx.cpu.regs[9] = 2;
    ctx.cpu.gpr_shadow[9] = .{ .x = 2.0, .y = 0.0, .word = 2, .flags = Value.valid_xy };

    ctx.cpu.lo = 4;
    ctx.cpu.hi = 1;
    pgxp.muldiv.div(&ctx.cpu, 8, 9, true);

    try expectApproxEqAbs(@as(f32, 4.75), ctx.cpu.lo_shadow.x, 0.01);
}

test "a divide's remainder is not offered as a precise value" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 9;
    ctx.cpu.gpr_shadow[8] = .{ .x = 9.5, .y = 0.0, .word = 9, .flags = Value.valid_xy };
    ctx.cpu.regs[9] = 2;
    ctx.cpu.gpr_shadow[9] = .{ .x = 2.0, .y = 0.0, .word = 2, .flags = Value.valid_xy };

    ctx.cpu.lo = 4;
    ctx.cpu.hi = 1;
    pgxp.muldiv.div(&ctx.cpu, 8, 9, true);

    // A remainder is not a position: the number is there, but nothing may
    // read it as a coordinate.
    try expectEqual(@as(u32, 0), ctx.cpu.hi_shadow.flags & Value.valid_xy);
}

test "a divide by zero leaves nothing precise behind" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 9;
    ctx.cpu.gpr_shadow[8] = .{ .x = 9.5, .y = 0.0, .word = 9, .flags = Value.valid_xy };
    ctx.cpu.regs[9] = 0;
    ctx.cpu.gpr_shadow[9] = .{ .x = 0.0, .y = 0.0, .word = 0, .flags = Value.valid_xy };

    pgxp.muldiv.div(&ctx.cpu, 8, 9, true);

    try expectEqual(@as(u32, 0), ctx.cpu.lo_shadow.flags & Value.valid_xy);
    try expectEqual(@as(u32, 0), ctx.cpu.hi_shadow.flags & Value.valid_xy);
}

test "a value survives a round trip through a COP0 register" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    ctx.bus.pgxp_cpu = true;

    ctx.cpu.regs[8] = 0x0002_0001;
    ctx.cpu.gpr_shadow[8] = .{ .x = 1.5, .y = 2.5, .word = 0x0002_0001, .flags = Value.valid_xy };
    pgxp.muldiv.mtc0(&ctx.cpu, 7, 8);
    ctx.cpu.writeReg(10, 0x0002_0001);
    pgxp.muldiv.mfc0(&ctx.cpu, 10, 7);

    try expectApproxEqAbs(@as(f32, 1.5), ctx.cpu.gpr_shadow[10].x, 0.0);
}

// --- Task 10: the vertex cache ---------------------------------------------
//
// A second lookup for a vertex whose memory word cannot be found, keyed on the
// integer position rather than on where the word lives. Off by default: the
// table is 2048x2048 entries covering the SXY range, which at 20 bytes is
// 83 MB.

const VertexCache = ps1_core.pgxp.cache.VertexCache;

/// Pack a screen coordinate the way GP0 and the SXY registers both do.
fn packXY(x: i16, y: i16) u32 {
    return (@as(u32, @as(u16, @bitCast(y))) << 16) | @as(u32, @as(u16, @bitCast(x)));
}

test "the vertex cache answers a lookup the address path misses" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    try ctx.bus.setPgxpVertexCache(ctx.allocator, true);

    const word: u32 = (@as(u32, 50) << 16) | 100;
    ctx.bus.pgxp_vertex_cache.?.put(word, .{
        .x = 100.5,
        .y = 50.25,
        .z = 400.0,
        .word = word,
        .flags = Value.valid_xyz,
    });

    const hit = ctx.bus.pgxp_vertex_cache.?.get(word).?;
    try expectApproxEqAbs(@as(f32, 100.5), hit.x, 0.0);
    // A hit reports no depth: it belongs to whichever vertex last held this
    // integer position, which is not reliably this one.
    try expectEqual(@as(u32, 0), hit.flags & Value.valid_z);
}

test "the vertex cache refuses a position outside the SXY range" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    try ctx.bus.setPgxpVertexCache(ctx.allocator, true);

    // Low half 5000 is outside -1024..1023 and has no slot.
    const word: u32 = (@as(u32, 50) << 16) | 5000;
    ctx.bus.pgxp_vertex_cache.?.put(word, .{ .x = 1.0, .word = word, .flags = Value.valid_xy });
    try expectEqual(@as(?Value, null), ctx.bus.pgxp_vertex_cache.?.get(word));
}

test "an empty slot is a miss rather than an invalid value" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    try ctx.bus.setPgxpVertexCache(ctx.allocator, true);

    try expectEqual(@as(?Value, null), ctx.bus.pgxp_vertex_cache.?.get(packXY(10, 20)));
}

test "the cache is not allocated while the setting is off" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    try expectEqual(@as(?*VertexCache, null), ctx.bus.pgxp_vertex_cache);
}

test "disabling the cache frees it" {
    var ctx = try CpuContext.init();
    defer ctx.deinit();
    ctx.bus.setPgxp(true);
    try ctx.bus.setPgxpVertexCache(ctx.allocator, true);
    try std.testing.expect(ctx.bus.pgxp_vertex_cache != null);
    try ctx.bus.setPgxpVertexCache(ctx.allocator, false);
    try expectEqual(@as(?*VertexCache, null), ctx.bus.pgxp_vertex_cache);
}

test "a projection records its vertex in the cache" {
    const cache = try VertexCache.init(std.testing.allocator);
    defer cache.deinit(std.testing.allocator);

    var cop2 = saturatingProjectionCop2();
    cop2.writeData(0, 5); // VXY0: VX0 = 5, VY0 = 0
    cop2.executeCommand(0x4A18_0001, .{ .vertex_cache = cache }); // RTPS, sf=1, lm=0

    const word = cop2.readData(14);
    const hit = cache.get(word).?;
    try expectApproxEqAbs(cop2.readPreciseData(14).x, hit.x, 0.0);
}

test "a saturated projection does not evict the cached vertex at its position" {
    const cache = try VertexCache.init(std.testing.allocator);
    defer cache.deinit(std.testing.allocator);

    // VX0 = 2000 saturates SX2 to 1023 and records no precise value. Learn
    // the register word the saturation produces, then seed the cache at that
    // position: the position is still being drawn, so the entry already there
    // is the best answer anyone has for it.
    var cop2 = saturatingProjectionCop2();
    cop2.writeData(0, 2000);
    cop2.executeCommand(0x4A18_0001, .{});

    const word = cop2.readData(14);
    try expectEqual(@as(u32, 1023), word & 0xFFFF);
    try expectEqual(@as(u32, 0), cop2.readPreciseData(14).flags);
    cache.put(word, .{ .x = 1023.5, .y = 0.0, .word = word, .flags = Value.valid_xy });

    cop2.writeData(0, 2000);
    cop2.executeCommand(0x4A18_0001, .{ .vertex_cache = cache });

    try expectApproxEqAbs(@as(f32, 1023.5), cache.get(word).?.x, 0.0);
}

test "a cached vertex resolves one the memory path knows nothing about" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    bus.setPgxp(true);
    try bus.setPgxpVertexCache(std.testing.allocator, true);
    const cache = bus.pgxp_vertex_cache.?;

    inline for (.{ .{ 10, 20 }, .{ 40, 20 }, .{ 10, 60 } }) |xy| {
        const word = packXY(xy[0], xy[1]);
        cache.put(word, .{
            .x = @as(f32, @floatFromInt(xy[0])) + 0.5,
            .y = @floatFromInt(xy[1]),
            .word = word,
            .flags = Value.valid_xy,
        });
    }

    // GP0(0x20): a flat triangle whose vertices carry NO provenance at all.
    _ = bus.gpu.writeGp0(0x2000_FFFF, Value.none);
    _ = bus.gpu.writeGp0(packXY(10, 20), Value.none);
    _ = bus.gpu.writeGp0(packXY(40, 20), Value.none);
    _ = bus.gpu.writeGp0(packXY(10, 60), Value.none);

    try expectEqual(@as(u64, 3), bus.gpu.gp0.pgxp.vertices);
    try expectEqual(@as(u64, 3), bus.gpu.gp0.pgxp.resolved);
}

test "the same triangle resolves nothing with the cache off" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    bus.setPgxp(true);

    _ = bus.gpu.writeGp0(0x2000_FFFF, Value.none);
    _ = bus.gpu.writeGp0(packXY(10, 20), Value.none);
    _ = bus.gpu.writeGp0(packXY(40, 20), Value.none);
    _ = bus.gpu.writeGp0(packXY(10, 60), Value.none);

    try expectEqual(@as(u64, 3), bus.gpu.gp0.pgxp.vertices);
    try expectEqual(@as(u64, 0), bus.gpu.gp0.pgxp.resolved);
}

test "turning PGXP off stops the cache resolving vertices" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    bus.setPgxp(true);
    try bus.setPgxpVertexCache(std.testing.allocator, true);
    const word = packXY(10, 20);
    bus.pgxp_vertex_cache.?.put(word, .{ .x = 10.5, .y = 20.0, .word = word, .flags = Value.valid_xy });

    // The cache is the one thing that could still move a vertex with the
    // feature off, because it needs no provenance to hit.
    bus.setPgxp(false);

    _ = bus.gpu.writeGp0(0x2000_FFFF, Value.none);
    _ = bus.gpu.writeGp0(word, Value.none);
    _ = bus.gpu.writeGp0(packXY(40, 20), Value.none);
    _ = bus.gpu.writeGp0(packXY(10, 60), Value.none);

    try expectEqual(@as(u64, 0), bus.gpu.gp0.pgxp.resolved);
}

// ---------------------------------------------------------------------------
// Tolerance.
//
// The mitigation for what word-matched staleness gives up. It bounds how far a
// candidate is allowed to sit from the integer vertex it claims to describe,
// and it is checked BEFORE `toFixed`'s clamp, which is the whole point: the
// clamp pins a disagreeing candidate inside the wire's pixel and so makes the
// disagreement invisible rather than absent. A shadow that drifted five pixels
// under CPU-mode arithmetic is clamped to a plausible-looking position today.

test "tolerance rejects a vertex further than it from the integer position" {
    const word: u32 = (@as(u32, 50) << 16) | 100;
    const v: Value = .{ .x = 100.9, .y = 50.0, .word = word, .flags = Value.valid_xy };

    const tight = Primitive.getPointPrecise(word, v, 0.5);
    try expectEqual(false, tight.resolved);
    // Rejected means the integer position, not a clamped precise one.
    try expectEqual(@as(i32, 100) << 16, tight.px);

    const loose = Primitive.getPointPrecise(word, v, 1.0);
    try expectEqual(true, loose.resolved);
}

test "tolerance measures the disagreement the clamp would otherwise hide" {
    // A candidate five pixels from the vertex it claims to be. The word match
    // admits it -- the word is what it was recorded against -- and `toFixed`
    // then clamps it into pixel 100, where nothing downstream can tell it was
    // ever wrong. Only a pre-clamp check can refuse it.
    const word: u32 = (@as(u32, 50) << 16) | 100;
    const drifted: Value = .{ .x = 105.0, .y = 50.0, .word = word, .flags = Value.valid_xy };

    const off = Primitive.getPointPrecise(word, drifted, tolerance_off);
    try expectEqual(true, off.resolved);
    try expectEqual(@as(i32, 100), off.px >> 16);

    try expectEqual(false, Primitive.getPointPrecise(word, drifted, 2.0).resolved);
}

test "tolerance is measured per axis, not on the pair" {
    // x agrees exactly, y is off by 0.9: the vertex must still be refused.
    const word: u32 = (@as(u32, 50) << 16) | 100;
    const v: Value = .{ .x = 100.0, .y = 50.9, .word = word, .flags = Value.valid_xy };
    try expectEqual(false, Primitive.getPointPrecise(word, v, 0.5).resolved);
}

test "tolerance is measured against the truncated coordinate, not the raw one" {
    // Wire low half 1500 folds to -548 and the candidate follows it. Measured
    // against the raw 1500.25 the disagreement would read as 2048 px and every
    // wrapped vertex in the frame would be refused.
    const word: u32 = (@as(u32, 50) << 16) | 1500;
    const v: Value = .{ .x = 1500.25, .y = 50.0, .word = word, .flags = Value.valid_xy };
    const pt = Primitive.getPointPrecise(word, v, 0.5);
    try expectEqual(@as(i16, -548), pt.x);
    try expectEqual(true, pt.resolved);
}

test "a negative tolerance disables the check" {
    const word: u32 = (@as(u32, 50) << 16) | 100;
    const v: Value = .{ .x = 100.9, .y = 50.0, .word = word, .flags = Value.valid_xy };
    try expectEqual(true, Primitive.getPointPrecise(word, v, -1.0).resolved);
}

test "tolerance is disabled by default" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    try std.testing.expect(bus.pgxp_tolerance < 0);
}

test "the tolerance setting reaches the vertex decode" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    bus.setPgxp(true);
    bus.setPgxpTolerance(0.25);

    // A flat-shaded triangle whose three vertices each carry a candidate 0.5 px
    // from the integer position: outside the tolerance, so none resolves.
    const a = packXY(10, 20);
    const b = packXY(40, 20);
    const c = packXY(10, 60);
    _ = bus.gpu.writeGp0(0x2000_FFFF, Value.none);
    _ = bus.gpu.writeGp0(a, .{ .x = 10.5, .y = 20.0, .word = a, .flags = Value.valid_xy });
    _ = bus.gpu.writeGp0(b, .{ .x = 40.5, .y = 20.0, .word = b, .flags = Value.valid_xy });
    _ = bus.gpu.writeGp0(c, .{ .x = 10.5, .y = 60.0, .word = c, .flags = Value.valid_xy });

    try expectEqual(@as(u64, 3), bus.gpu.gp0.pgxp.vertices);
    try expectEqual(@as(u64, 0), bus.gpu.gp0.pgxp.resolved);
}

test "the tolerance setting reaches a vertex cache hit" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    bus.setPgxp(true);
    try bus.setPgxpVertexCache(std.testing.allocator, true);
    bus.setPgxpTolerance(0.25);

    const a = packXY(10, 20);
    bus.pgxp_vertex_cache.?.put(a, .{ .x = 10.5, .y = 20.0, .word = a, .flags = Value.valid_xy });

    _ = bus.gpu.writeGp0(0x2000_FFFF, Value.none);
    _ = bus.gpu.writeGp0(a, Value.none);
    _ = bus.gpu.writeGp0(packXY(40, 20), Value.none);
    _ = bus.gpu.writeGp0(packXY(10, 60), Value.none);

    // The cache is the lookup that needs no provenance to hit, so it is the
    // one most in need of the bound, not least.
    try expectEqual(@as(u64, 0), bus.gpu.gp0.pgxp.resolved);
}

// ---------------------------------------------------------------------------
// Culling correction — float NCLIP.

/// One vertex as the integer register holds it plus the sub-pixel position
/// PGXP recorded for it.
const PreciseVertex = struct { ix: i16, iy: i16, x: f32, y: f32 };

fn packSxy(x: i16, y: i16) u32 {
    return (@as(u32, @as(u16, @bitCast(y))) << 16) | @as(u32, @as(u16, @bitCast(x)));
}

/// Fill sxy0/1/2 and their precise entries. `with_depth` is the difference
/// between a projected vertex and one the game built itself.
fn stagePreciseTriangle(cop2: *Cop2, v: [3]PreciseVertex, with_depth: bool) void {
    for (v, 0..) |pv, i| {
        const word = packSxy(pv.ix, pv.iy);
        cop2.writeDataPrecise(12 + i, word, .{
            .x = pv.x,
            .y = pv.y,
            .z = if (with_depth) 100.0 else 0,
            .word = word,
            .flags = if (with_depth) Value.valid_xyz else Value.valid_xy,
        });
    }
}

/// All three on one row: the integer cross product is exactly zero, so any
/// non-zero MAC0 can only have come from the float path.
const flat_triangle = [3]PreciseVertex{
    .{ .ix = 0, .iy = 0, .x = 0.0, .y = 0.0 },
    .{ .ix = 10, .iy = 0, .x = 10.0, .y = 0.0 },
    .{ .ix = 5, .iy = 0, .x = 5.0, .y = 0.6 },
};

const nclip_on: pgxp.Config = .{ .culling = true };
const nclip_off: pgxp.Config = .{};

fn mac0(cop2: *Cop2) i32 {
    return @bitCast(cop2.readData(24));
}

test "float NCLIP is used when all three vertices are precise" {
    var cop2 = Cop2.init();
    stagePreciseTriangle(&cop2, flat_triangle, true);
    cop2.executeCommand(0x4A00_0006, nclip_on);

    // Cross product 10 * 0.6 = 6, against an integer zero.
    try expectEqual(@as(i32, 6), mac0(&cop2));
}

test "a float NCLIP result under 1.0 is pushed away from zero" {
    var cop2 = Cop2.init();
    // Cross product 0.3: without the nudge it truncates to 0 on the way back
    // to an integer MAC0 and the triangle is culled as degenerate.
    stagePreciseTriangle(&cop2, .{
        .{ .ix = 0, .iy = 0, .x = 0.0, .y = 0.0 },
        .{ .ix = 10, .iy = 0, .x = 10.0, .y = 0.0 },
        .{ .ix = 5, .iy = 0, .x = 5.0, .y = 0.03 },
    }, true);
    cop2.executeCommand(0x4A00_0006, nclip_on);

    try expectEqual(@as(i32, 1), mac0(&cop2));
}

test "a float NCLIP result keeps its sign when it is pushed away from zero" {
    var cop2 = Cop2.init();
    // The same triangle wound the other way: a nudge that ignored the sign
    // would flip the facing of every near-degenerate back face.
    stagePreciseTriangle(&cop2, .{
        .{ .ix = 0, .iy = 0, .x = 0.0, .y = 0.0 },
        .{ .ix = 5, .iy = 0, .x = 5.0, .y = 0.03 },
        .{ .ix = 10, .iy = 0, .x = 10.0, .y = 0.0 },
    }, true);
    cop2.executeCommand(0x4A00_0006, nclip_on);

    try expectEqual(@as(i32, -1), mac0(&cop2));
}

test "a float NCLIP result below the nudge floor stays zero" {
    var cop2 = Cop2.init();
    // Cross product 0.05, under the 0.1 floor: genuinely degenerate, and
    // inventing area for it would un-cull a triangle hardware discards.
    stagePreciseTriangle(&cop2, .{
        .{ .ix = 0, .iy = 0, .x = 0.0, .y = 0.0 },
        .{ .ix = 10, .iy = 0, .x = 10.0, .y = 0.0 },
        .{ .ix = 5, .iy = 0, .x = 5.0, .y = 0.005 },
    }, true);
    cop2.executeCommand(0x4A00_0006, nclip_on);

    try expectEqual(@as(i32, 0), mac0(&cop2));
}

test "NCLIP falls back to integers when a vertex has no depth" {
    var cop2 = Cop2.init();
    // Same geometry, but built by the game rather than projected. Running the
    // accurate path over 2D geometry is how this feature would break a HUD.
    stagePreciseTriangle(&cop2, flat_triangle, false);
    cop2.executeCommand(0x4A00_0006, nclip_on);

    try expectEqual(@as(i32, 0), mac0(&cop2));
}

test "NCLIP falls back to integers when a precise entry is stale" {
    var cop2 = Cop2.init();
    stagePreciseTriangle(&cop2, flat_triangle, true);

    // Desynced directly, because no path inside `Cop2` produces this state
    // today: `writeData` clears the entry of any register it overwrites, so
    // going through it would test that clear and never reach the word match.
    // The match is a guard against a future producer that forgets to, and the
    // only way to exercise a guard like that is to stage what it guards
    // against.
    cop2.precise[13].word ^= 1;
    cop2.executeCommand(0x4A00_0006, nclip_on);

    try expectEqual(@as(i32, 0), mac0(&cop2));
}

test "culling correction does nothing while it is off" {
    var cop2 = Cop2.init();
    stagePreciseTriangle(&cop2, flat_triangle, true);
    cop2.executeCommand(0x4A00_0006, nclip_off);

    try expectEqual(@as(i32, 0), mac0(&cop2));
}

test "culling correction is unreachable while PGXP itself is off" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    // Default-on, but the master flag is off: there is no state in which
    // culling correction acts while geometry correction does not.
    try std.testing.expect(bus.pgxp_culling);
    try std.testing.expect(!bus.pgxpConfig().culling);

    bus.setPgxp(true);
    try std.testing.expect(bus.pgxpConfig().culling);
}

test "culling correction defaults on" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    try std.testing.expect(bus.pgxp_culling);
}
