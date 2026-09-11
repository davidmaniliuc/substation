//! PGXP CPU mode: multiply, divide, the `hi`/`lo` pair and the COP0 moves.
//!
//! A multiply is where a game scales a projected coordinate, so of everything
//! CPU mode adds this is the op that matters most for a title doing its own
//! transform after the GTE. It is also the only op whose result does not fit
//! one word: the four half-products recombine into a `hi`/`lo` pair, and both
//! halves of that pair carry a value.
//!
//! Unlike `ops.zig` and `shift.zig`, these run AFTER the integer write and
//! store rather than return. `hi`, `lo` and the COP0 registers are never a
//! source of their own instruction, so the aliasing that forces the other two
//! files' ordering cannot arise here — and the shadows need the written words
//! as their staleness keys.

const pgxp = @import("pgxp.zig");
const ops = @import("ops.zig");
const Value = pgxp.Value;
const Cpu = @import("../cpu/cpu.zig").Cpu;

/// The shape `mult` and `div` share, as the dispatch holds them: the two
/// source registers and whether the instruction read them signed.
pub const Hook = *const fn (cpu: *Cpu, rs: u5, rt: u5, signed: bool) void;

/// A source operand's two halves as one f64 pair. The low half is always
/// lifted onto the unsigned range — it is the bottom of a wider number, not a
/// signed quantity of its own — while the high half keeps the signedness the
/// instruction read it with.
fn halves(v: Value, current: u32, signed: bool) struct { x: f64, y: f64 } {
    return .{
        .x = pgxp.unsign(v.validX(current)),
        .y = if (signed) v.validY(current) else pgxp.unsign(v.validY(current)),
    };
}

/// The flags a hi/lo result carries: the first operand's, the second's
/// validity folded in, and the taint every arithmetic op leaves behind.
fn resultFlags(a: Value, b: Value) u32 {
    return a.flags | (b.flags & Value.valid_xy) | Value.tainted_z;
}

/// `mult`/`multu`: hi:lo = Rs * Rt.
///
/// Each operand is `low + high * 65536`, so the product is the four
/// half-products recombined: the low result's low half is the low-low
/// product, its high half is that product's overflow plus the two cross
/// terms, the high result's low half is that half's overflow plus the
/// high-high product, and the high result's high half is what is left.
pub fn mult(cpu: *Cpu, rs: u5, rt: u5, signed: bool) void {
    const a = ops.source(cpu, rs);
    const b = ops.source(cpu, rt);
    const av = halves(a, cpu.readReg(rs), signed);
    const bv = halves(b, cpu.readReg(rt), signed);

    const xx = av.x * bv.x;
    const ly = pgxp.overflow(xx) + (av.x * bv.y + av.y * bv.x);
    const hx = pgxp.overflow(ly) + av.y * bv.y;

    // The depth travels once and both halves of the pair describe the same
    // position, so `hi` starts as the same value `lo` does.
    var lo = a;
    ops.copyZIfMissing(&lo, b);
    var hi = lo;

    lo.x = @floatCast(pgxp.signFold(xx));
    lo.y = @floatCast(pgxp.signFold(ly));
    lo.word = cpu.lo;
    lo.flags = resultFlags(lo, b);

    hi.x = @floatCast(pgxp.signFold(hx));
    hi.y = @floatCast(pgxp.signFold(pgxp.overflow(hx)));
    hi.word = cpu.hi;
    hi.flags = resultFlags(hi, b);

    cpu.lo_shadow = lo;
    cpu.hi_shadow = hi;
}

/// `div`/`divu`: lo = Rs / Rt, hi = Rs % Rt.
///
/// The quotient is computed from the two operands' full precise values, which
/// is the whole point — an integer divide is where a game loses the fraction
/// PGXP exists to keep.
///
/// Two results are refused rather than guessed at, which is a deliberate
/// divergence from the reference:
///   - **A zero divisor invalidates both halves.** The PS1's divide-by-zero
///     quirk writes a fixed integer pair that no precise value corresponds to.
///   - **A remainder is never precise.** The number is computed and kept, but
///     nothing may read it as a coordinate: a remainder is not a position.
pub fn div(cpu: *Cpu, rs: u5, rt: u5, signed: bool) void {
    const a = ops.source(cpu, rs);
    const b = ops.source(cpu, rt);
    if (cpu.readReg(rt) == 0) {
        cpu.lo_shadow = Value.none;
        cpu.hi_shadow = Value.none;
        return;
    }
    const av = halves(a, cpu.readReg(rs), signed);
    const bv = halves(b, cpu.readReg(rt), signed);

    const dividend = av.x + av.y * 65536.0;
    const divisor = bv.x + bv.y * 65536.0;
    const quotient = dividend / divisor;
    const remainder = @rem(dividend, divisor);

    var lo = a;
    ops.copyZIfMissing(&lo, b);
    var hi = lo;

    lo.x = @floatCast(pgxp.signFold(quotient));
    lo.y = @floatCast(pgxp.signFold(pgxp.overflow(quotient)));
    lo.word = cpu.lo;
    lo.flags = resultFlags(lo, b);

    hi.x = @floatCast(pgxp.signFold(remainder));
    hi.y = @floatCast(pgxp.signFold(pgxp.overflow(remainder)));
    hi.word = cpu.hi;
    hi.flags = resultFlags(hi, b) & ~@as(u32, Value.valid_xy);

    cpu.lo_shadow = lo;
    cpu.hi_shadow = hi;
}

/// Copy a shadow into a destination, validating it against the integer the
/// source register actually holds. Every one of the six moves below is this,
/// which is what a move is: the value travels whole, or not at all.
fn moveShadow(dst: *Value, src: *Value, current: u32) void {
    src.validate(current);
    dst.* = src.*;
}

pub fn moveFromHi(cpu: *Cpu, rd: u5) void {
    if (rd == 0) return;
    moveShadow(&cpu.gpr_shadow[rd], &cpu.hi_shadow, cpu.hi);
}

pub fn moveToHi(cpu: *Cpu, rs: u5) void {
    cpu.hi_shadow = ops.source(cpu, rs);
}

pub fn moveFromLo(cpu: *Cpu, rd: u5) void {
    if (rd == 0) return;
    moveShadow(&cpu.gpr_shadow[rd], &cpu.lo_shadow, cpu.lo);
}

pub fn moveToLo(cpu: *Cpu, rs: u5) void {
    cpu.lo_shadow = ops.source(cpu, rs);
}

/// `mfc0`: Rt = COP0[Rd]. The destination's word is the COP0 register's own
/// value rather than the shadow's, because that is what the GPR received.
pub fn mfc0(cpu: *Cpu, rt: u5, rd: u5) void {
    if (rt == 0) return;
    const current = cpu.cop0.readReg(rd);
    moveShadow(&cpu.gpr_shadow[rt], &cpu.cop0_shadow[rd], current);
    cpu.gpr_shadow[rt].word = current;
}

/// `mtc0`: COP0[Rd] = Rt. The word is read back out of COP0 rather than taken
/// from the register, because several COP0 registers mask what they accept
/// and the shadow has to match what the register kept.
pub fn mtc0(cpu: *Cpu, rd: u5, rt: u5) void {
    cpu.cop0_shadow[rd] = ops.source(cpu, rt);
    cpu.cop0_shadow[rd].word = cpu.cop0.readReg(rd);
}
