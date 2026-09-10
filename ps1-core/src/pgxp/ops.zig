//! PGXP CPU mode: propagation through ordinary CPU arithmetic.
//!
//! Gated by `Bus.pgxp_cpu`, which ships off. Base PGXP follows a projected
//! vertex from the GTE to the GP0 FIFO and no further; CPU mode follows it
//! through whatever the game does to it in between, which is what a title
//! doing its own transform after the GTE needs and what a title that does not
//! only pays for.
//!
//! Every op here is a PURE function of the register file: it reads the source
//! register and the integer result the instruction is about to write, and
//! RETURNS the destination's value rather than storing it. That is not a
//! stylistic choice — `Cpu.writeReg` destroys both the destination's shadow
//! and its integer, so an op that ran after the write could not see its own
//! source whenever the destination IS the source (`addiu $t0, $t0, 4`, the
//! commonest shape there is). The caller pairs each op with
//! `Cpu.writeRegPrecise`, which is the same seam `rOpMove` already used.

const pgxp = @import("pgxp.zig");
const Value = pgxp.Value;
const Cpu = @import("../cpu/cpu.zig").Cpu;

/// The shape every immediate-form op shares: the source register (still
/// holding the value the instruction read) and the integer result about to be
/// written. Taking the result rather than recomputing it keeps `word` exactly
/// what the destination will hold, which is the staleness key every consumer
/// matches against.
pub const ImmHook = *const fn (cpu: *Cpu, rs: u5, imm: u32, result: u32) Value;

/// Read a source register's value, validated against what the register
/// actually holds. Every op starts here: a shadow that outlived its value is
/// dropped — in the table as well as in the result — before it can propagate.
pub fn source(cpu: *Cpu, r: u5) Value {
    var v = cpu.gpr_shadow[r];
    v.validate(cpu.readReg(r));
    cpu.gpr_shadow[r] = v;
    return v;
}

/// The low half of a word, read as the signed 16-bit quantity `Value.x` is.
fn lowHalf(word: u32) f32 {
    return @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(word)))));
}

/// The high half of a word, read as the signed 16-bit quantity `Value.y` is.
fn highHalf(word: u32) f32 {
    return @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(word >> 16)))));
}

/// Fold a high half back into the signed 16-bit range it is read as. The two
/// halves are one number to the adder, so a sum that leaves the range has
/// wrapped rather than saturated.
fn foldHigh(y: f64) f64 {
    if (y > 32767.0) return y - 65536.0;
    if (y < -32768.0) return y + 65536.0;
    return y;
}

/// A value that is exactly its own integer: both halves known to the bit,
/// nothing precise and no depth.
fn exactValue(word: u32) Value {
    return .{ .x = lowHalf(word), .y = highHalf(word), .word = word, .flags = Value.valid_xy };
}

/// A register move: the whole value travels, including its depth term.
pub fn move(cpu: *Cpu, rs: u5) Value {
    return source(cpu, rs);
}

/// `lui`, `slti` and `sltiu`. A shift-in immediate and a comparison have
/// nothing precise to carry — the result is exact by construction — so all
/// three reduce to the integer the instruction wrote.
pub fn exact(_: *Cpu, _: u5, _: u32, result: u32) Value {
    return exactValue(result);
}

/// `addi`/`addiu`: Rt = Rs + sign-extended immediate, with the carry out of
/// the low half added into the high one, because the two halves are one
/// number as far as the adder is concerned.
pub fn addi(cpu: *Cpu, rs: u5, imm: u32, result: u32) Value {
    const src = source(cpu, rs);
    var out = src;
    out.word = result;

    // Adding nothing alters nothing, so the depth still describes the
    // position beside it and stays untainted. This is the `addiu rd, rs, 0`
    // move idiom.
    if (imm == 0) return out;

    const rs_val = cpu.readReg(rs);
    if (rs_val == 0) {
        // Nothing went in, so the immediate itself is the value and both
        // halves are exactly known. The depth, if any, belonged to the zero.
        out.x = lowHalf(imm);
        out.y = highHalf(imm);
        out.flags |= Value.valid_xy | Value.tainted_z;
        return out;
    }

    // The low half is added unsigned so a carry out of bit 15 is visible as a
    // value above 65535 rather than as a sign flip.
    const x = pgxp.unsign(src.validX(rs_val)) + @as(f64, @floatFromInt(@as(u16, @truncate(imm))));
    const carry: f64 = if (x > 65535.0) 1.0 else if (x < 0.0) -1.0 else 0.0;
    out.x = @floatCast(pgxp.signFold(x));

    out.y = @floatCast(foldHigh(@as(f64, src.validY(rs_val)) + highHalf(imm) + carry));

    out.flags |= Value.tainted_z;
    return out;
}

/// `andi`. The 16-bit immediate masks the high half away entirely, so it is
/// exactly zero. The low half survives precisely only under a full mask; a
/// partial one clears integer bits the precise value was measured against,
/// which leaves no reading of its fraction that is still true, so the integer
/// result wins instead.
pub fn andi(cpu: *Cpu, rs: u5, imm: u32, result: u32) Value {
    const src = source(cpu, rs);
    var out = src;
    out.word = result;
    out.y = 0;

    const mask: u16 = @truncate(imm);
    out.x = if (mask == 0xFFFF) src.validX(cpu.readReg(rs)) else if (mask == 0) 0 else lowHalf(result);

    out.flags |= Value.valid_xy | Value.tainted_z;
    return out;
}

/// `ori` and `xori`, which share a rule because the integer result already
/// carries whichever operation ran: a zero immediate leaves the value alone,
/// and otherwise the low half loses its fraction while the high half — which
/// a 16-bit immediate cannot reach — survives.
pub fn bitwiseImm(cpu: *Cpu, rs: u5, imm: u32, result: u32) Value {
    const src = source(cpu, rs);
    var out = src;
    out.word = result;

    if (imm == 0) return out;

    out.x = lowHalf(result);
    out.flags |= Value.valid_x | Value.tainted_z;
    return out;
}

/// The shape every register-form op shares: the two source registers (still
/// holding the values the instruction read) and the integer result about to
/// be written to Rd.
pub const RegHook = *const fn (cpu: *Cpu, rs: u5, rt: u5, result: u32) Value;

/// A depth term travels only where the destination has none of its own.
pub fn copyZIfMissing(dst: *Value, src: Value) void {
    if (dst.flags & Value.valid_z == 0) dst.z = src.z;
    dst.flags |= src.flags & Value.valid_z;
}

/// Which of two operands' depth terms describes the result.
///
/// The second wins when the first has none, or when the first is tainted and
/// the second is valid and untainted — a depth recorded before its position
/// was altered no longer describes that position, and losing to an untainted
/// one is how an arithmetic chain avoids carrying it forward.
pub fn selectZ(dst: *Value, a: Value, b: Value) void {
    const a_unusable = (a.flags & Value.valid_z == 0) or
        (a.flags & Value.tainted_z != 0 and
            b.flags & (Value.valid_z | Value.tainted_z) == Value.valid_z);
    dst.z = if (a_unusable) b.z else a.z;
    dst.flags |= (a.flags | b.flags) & Value.valid_z;
}

/// `add`/`addu`: Rd = Rs + Rt, with the carry out of the low half added into
/// the high one.
pub fn add(cpu: *Cpu, rs: u5, rt: u5, result: u32) Value {
    const a = source(cpu, rs);
    const b = source(cpu, rt);
    const av = cpu.readReg(rs);
    const bv = cpu.readReg(rt);

    // Adding nothing alters nothing, so the surviving value keeps its halves
    // and its depth stays untainted. This is the register-move idiom, and it
    // is the same rule `addi` applies to a zero immediate.
    if (bv == 0) {
        var out = a;
        out.word = result;
        copyZIfMissing(&out, b);
        return out;
    }
    if (av == 0) {
        var out = b;
        out.word = result;
        copyZIfMissing(&out, a);
        return out;
    }

    var out: Value = .{ .word = result };

    // The low halves are added unsigned so a carry out of bit 15 is visible
    // as a value above 65535 rather than as a sign flip.
    const x = pgxp.unsign(a.validX(av)) + pgxp.unsign(b.validX(bv));
    const carry: f64 = if (x > 65535.0) 1.0 else if (x < 0.0) -1.0 else 0.0;
    out.x = @floatCast(pgxp.signFold(x));
    out.y = @floatCast(foldHigh(@as(f64, a.validY(av)) + b.validY(bv) + carry));

    out.flags = a.flags | (b.flags & Value.valid_xy) | Value.tainted_z;
    selectZ(&out, a, b);
    return out;
}

/// `sub`/`subu`: Rd = Rs - Rt. The borrow out of the low half is subtracted
/// from the high one. There is no zero-source shortcut on the left, because
/// `0 - Rt` is a negation and not a move.
pub fn sub(cpu: *Cpu, rs: u5, rt: u5, result: u32) Value {
    const a = source(cpu, rs);
    const b = source(cpu, rt);
    const av = cpu.readReg(rs);
    const bv = cpu.readReg(rt);

    if (bv == 0) {
        var out = a;
        out.word = result;
        copyZIfMissing(&out, b);
        return out;
    }

    var out: Value = .{ .word = result };

    const x = pgxp.unsign(a.validX(av)) - pgxp.unsign(b.validX(bv));
    const borrow: f64 = if (x < 0.0) 1.0 else 0.0;
    out.x = @floatCast(pgxp.signFold(x));
    out.y = @floatCast(foldHigh(@as(f64, a.validY(av)) - b.validY(bv) - borrow));

    out.flags = a.flags | (b.flags & Value.valid_xy) | Value.tainted_z;
    selectZ(&out, a, b);
    return out;
}

/// `and`/`or`/`xor`/`nor`. The halves come from the integer result — no bit
/// pattern of two precise values is itself precise — while the depth survives
/// through `selectZ`, because a mask does not move a vertex.
pub fn bitwise(cpu: *Cpu, rs: u5, rt: u5, result: u32) Value {
    const a = source(cpu, rs);
    const b = source(cpu, rt);

    var out = exactValue(result);
    out.flags |= Value.tainted_z;
    selectZ(&out, a, b);
    return out;
}

/// `slt`/`sltu`. A comparison writes an exact 0 or 1 and describes no
/// position, so there is nothing for a depth term to be attached to.
pub fn sltReg(_: *Cpu, _: u5, _: u5, result: u32) Value {
    return exactValue(result);
}
