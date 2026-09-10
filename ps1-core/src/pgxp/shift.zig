//! PGXP CPU mode: the shifts.
//!
//! Their own file because a shift by 16 is the pack/unpack idiom — how a game
//! splits a packed SXY into two registers and puts it back — which is the
//! traffic a coupled screen position cannot survive at all, and because two of
//! CPU mode's three carve-outs live here.
//!
//! Same seam as `ops.zig`: each op is a pure function of the register file and
//! RETURNS the destination's value rather than storing it, because
//! `sll $t0, $t0, 16` names its own destination as its source.

const pgxp = @import("pgxp.zig");
const ops = @import("ops.zig");
const Value = pgxp.Value;
const bits = @import("../bits.zig");
const Cpu = @import("../cpu/cpu.zig").Cpu;

/// The shape every shift shares: the source register, the amount shifted by —
/// an immediate `shamt` or the low five bits of Rs, decided by the caller —
/// and the integer result about to be written to Rd.
pub const Hook = *const fn (cpu: *Cpu, rt: u5, sh: u5, result: u32) Value;

/// The low half of a word, read as the signed 16-bit quantity `Value.x` is.
fn lowHalf(word: u32) i16 {
    return @bitCast(@as(u16, @truncate(word)));
}

/// The high half of a word, read as the signed 16-bit quantity `Value.y` is.
fn highHalf(word: u32) i16 {
    return @bitCast(@as(u16, @truncate(word >> 16)));
}

/// The scale a shift of `sh` applies, as the multiplier the halves take.
fn pow2(sh: u5) f64 {
    return @floatFromInt(@as(u32, 1) << sh);
}

/// `sll` and `sllv`: Rd = Rt << sh.
///
/// The reference guards a shift of 32 or more, which clears both halves; a
/// `u5` amount cannot represent one, so that case is absent here rather than
/// unreachable.
pub fn left(cpu: *Cpu, rt: u5, sh: u5, result: u32) Value {
    const src = ops.source(cpu, rt);
    const rt_val = cpu.readReg(rt);
    var out: Value = .{ .z = src.z, .word = result };

    if (sh >= 16) {
        // The low half shifts out entirely: the destination's low half is an
        // exact zero and its high half is the source's low one, scaled.
        out.x = 0;
        out.y = if (sh == 16)
            src.validX(rt_val)
        else
            @floatCast(pgxp.signFold(pgxp.unsign(@as(f64, src.validX(rt_val)) * pow2(sh - 16))));

        // THE SPYRO RULE: the destination's valid_x is derived from the
        // SOURCE's y bit rather than set outright. The zero really is exactly
        // known, but a register whose halves were never tracked would
        // otherwise start claiming a precise low half and spread it.
        out.flags = src.flags | Value.tainted_z | ((src.flags & Value.valid_y) >> 1);
        return out;
    }

    // Both halves survive, and the carry out of the low one lands in the high.
    const x = pgxp.unsign(src.validX(rt_val)) * pow2(sh);
    const y = pgxp.unsign(src.validY(rt_val)) * pow2(sh) + pgxp.overflow(x);
    out.x = @floatCast(pgxp.signFold(x));
    out.y = @floatCast(pgxp.signFold(y));
    out.flags = src.flags | Value.tainted_z;
    return out;
}

/// `srl`/`sra`/`srlv`/`srav`: Rd = Rt >> sh, arithmetic when `signed`.
///
/// Unlike a left shift, a right shift can leave a half holding nothing but
/// sign bits, and the precise value has to follow the integer into that state
/// rather than scale into a fraction that is no longer there. Two integer
/// probes decide it — the low half on its own, and the word with its low half
/// replaced by that half's sign — because shifting each says which components
/// survived.
pub fn right(
    cpu: *Cpu,
    rt: u5,
    sh: u5,
    result: u32,
    comptime signed: bool,
    comptime variable: bool,
) Value {
    const src = ops.source(cpu, rt);
    const rt_val = cpu.readReg(rt);

    // Shifting by nothing is a move.
    if (sh == 0) {
        var out = src;
        out.word = result;
        return out;
    }

    // THE PERSONA 2 RULE: a signed, non-variable shift under 16 of a value
    // that never came from a projection is overwhelmingly not geometry, and
    // treating it as precise produces false positives that spread through the
    // register file. The rounded integer halves are used instead, and the
    // depth — which the value had no valid claim to — is dropped.
    if (signed and !variable and sh < 16 and src.flags & Value.valid_z == 0) {
        return .{
            .x = @floatFromInt(lowHalf(result)),
            .y = @floatFromInt(highHalf(result)),
            .word = result,
            .flags = Value.valid_xy | Value.tainted_z,
        };
    }

    const x_in: f64 = src.validX(rt_val);
    // An unsigned shift reads the high half as the unsigned quantity the
    // integer instruction does, so it slides down into the low half rather
    // than filling it with a sign.
    const y_in: f64 = if (signed) src.validY(rt_val) else pgxp.unsign(src.validY(rt_val));

    const probe_x: i32 = @bitCast(bits.sext16(@truncate(rt_val)));
    const probe_y: i32 = @bitCast((rt_val & 0xFFFF_0000) | (@as(u32, @bitCast(probe_x)) >> 16));
    const shifted_x: u32 = @bitCast(probe_x >> sh);
    const shifted_y: u32 = if (signed) @bitCast(probe_y >> sh) else @as(u32, @bitCast(probe_y)) >> sh;

    // 0 or -1, whichever the low half's sign fills a half with.
    const sign_fill = highHalf(@bitCast(probe_x));

    var x: f64 = if (lowHalf(shifted_x) != sign_fill)
        x_in / pow2(sh)
    else
        // Only sign bits are left of the low half, so that is all it holds.
        @floatFromInt(lowHalf(shifted_x));

    if (lowHalf(shifted_y) != sign_fill) {
        // Part of the high half reached the low one.
        if (sh == 16) {
            x = y_in;
        } else if (sh < 16) {
            x += y_in * pow2(16 - sh);
            if (x_in < 0) x += pow2(16 - sh);
        } else {
            x += y_in / pow2(sh - 16);
        }
    }

    const high = highHalf(shifted_y);
    const y: f64 = if (high == 0 or high == -1) @floatFromInt(high) else y_in / pow2(sh);

    return .{
        .x = @floatCast(pgxp.signFold(x)),
        .y = @floatCast(pgxp.signFold(y)),
        .z = src.z,
        .word = result,
        .flags = src.flags | Value.tainted_z,
    };
}

// The four right-shift forms, as the dispatch names them. `sll` and `sllv`
// share `left` outright: the amount is the caller's business and nothing else
// about a left shift depends on where it came from.

pub fn srl(cpu: *Cpu, rt: u5, sh: u5, result: u32) Value {
    return right(cpu, rt, sh, result, false, false);
}

pub fn sra(cpu: *Cpu, rt: u5, sh: u5, result: u32) Value {
    return right(cpu, rt, sh, result, true, false);
}

pub fn srlv(cpu: *Cpu, rt: u5, sh: u5, result: u32) Value {
    return right(cpu, rt, sh, result, false, true);
}

pub fn srav(cpu: *Cpu, rt: u5, sh: u5, result: u32) Value {
    return right(cpu, rt, sh, result, true, true);
}
