const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

const ps1_core = @import("ps1_core");
const pgxp = ps1_core.pgxp;
const Value = pgxp.Value;
const Primitive = ps1_core.gpu.primitive;
const Cop2 = ps1_core.cpu.Cop2;

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
    const pt = Primitive.getPointPrecise(word, v);
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
    const pt = Primitive.getPointPrecise(word, stale);
    try expectEqual(false, pt.resolved);
    try expectEqual(@as(i32, 100) << 16, pt.px);
}

test "a vertex does not resolve when only one half is valid" {
    const word: u32 = (@as(u32, 50) << 16) | 100;
    const half: Value = .{ .x = 100.5, .y = 50.25, .word = word, .flags = Value.valid_x };
    const pt = Primitive.getPointPrecise(word, half);
    try expectEqual(false, pt.resolved);
}

test "a resolved position is truncated to 11 bits like the wire coordinate is" {
    // Wire low half 1500 truncates to -548; the precise value must follow it
    // rather than describing a pixel 2048 columns away.
    const word: u32 = (@as(u32, 50) << 16) | 1500;
    const v: Value = .{ .x = 1500.5, .y = 50.0, .word = word, .flags = Value.valid_xy };
    const pt = Primitive.getPointPrecise(word, v);
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

    cop2.executeCommand(0x4A18_0001); // RTPS, sf=1, lm=0

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

    cop2.executeCommand(0x4A18_0001); // RTPS, sf=1, lm=0

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
    const pt = Primitive.getPointPrecise(word, v);
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
    cop2.executeCommand(0x4A08_0001);

    const p = cop2.readPreciseData(14);
    try expectEqual(Value.valid_xyz, p.flags & Value.valid_xyz);
    try expectApproxEqAbs(@as(f32, 2000.0), p.z, 0.5);
}

test "RTPS clamps the depth term up to H/2 for near geometry" {
    var cop2 = Cop2.init();
    // vz = 100, H = 1000: H/2 = 500 wins.
    stageProjection(&cop2, 16, 32, 100, 1000, 0, 0);
    cop2.executeCommand(0x4A08_0001);

    try expectApproxEqAbs(@as(f32, 500.0), cop2.readPreciseData(14).z, 0.5);
}

test "the precise position is the float projection, not the hardware MAC0" {
    var cop2 = Cop2.init();
    // A depth chosen so the UNR reciprocal is inexact, which is what makes the
    // float projection differ from MAC0 >> 16 at all.
    stageProjection(&cop2, 300, 200, 1234, 1000, 0, 0);
    cop2.executeCommand(0x4A08_0001);

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
    cop2.executeCommand(0x4A08_0001);

    const p = cop2.readPreciseData(14);
    try expectApproxEqAbs(@as(f32, 40.5), p.x, 0.001);
    try expectApproxEqAbs(@as(f32, -8.25), p.y, 0.001);
}

test "a projection with no depth records nothing rather than a NaN" {
    var cop2 = Cop2.init();
    // H = 0 and SZ3 = 0 leaves the divisor at zero.
    stageProjection(&cop2, 16, 32, 0, 0, 0, 0);
    cop2.executeCommand(0x4A08_0001);

    try expectEqual(@as(u32, 0), cop2.readPreciseData(14).flags);
}
