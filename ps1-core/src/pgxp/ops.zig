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

    var y: f64 = src.validY(rs_val);
    y += highHalf(imm);
    y += carry;
    if (y > 32767.0) y -= 65536.0 else if (y < -32768.0) y += 65536.0;
    out.y = @floatCast(y);

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
