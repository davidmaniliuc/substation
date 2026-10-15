//! PGXP's CPU-mode ALU rules emitted inline where they can be stated
//! exactly: the register move (`ops.move`, in both tiers), `exactValue`
//! (`ops.exact`, `ops.sltReg`), ADDI/ADDIU (`ops.addi`) and ADD/ADDU/SUB/
//! SUBU (`ops.add`, `ops.sub`), and the f64 steps `shadow_shift.zig`
//! shares. Each reads and writes the memory its shim reads and writes, at
//! the same point in the op, so `.jit` stays byte-identical to `.cached`.
//! Every other hook keeps its shim (`shadow.hooked`).
//!
//! The op's result is in w9 on entry. Scratch: w10-w15, x16, d0-d7: the
//! caller-saved registers no op keeps live.

const e = @import("emit.zig");
const t = @import("translate.zig");
const layout = @import("layout.zig");
const shadow = @import("shadow.zig");
const Value = @import("../../pgxp/pgxp.zig").Value;

const x_off = @offsetOf(Value, "x");
const y_off = @offsetOf(Value, "y");
const z_off = @offsetOf(Value, "z");
const word_off = @offsetOf(Value, "word");
const flags_off = @offsetOf(Value, "flags");

/// `ops.source(r)`: a shadow recorded against another word than `r` holds
/// loses its flags, in the table too. Leaves `flags` the validated flags
/// and `value` `r`'s value. $zero's shadow is none, which validates as
/// itself, so it is two zeros.
pub fn source(em: *t.Emitter, r: u5, flags: e.Reg, value: e.Reg) void {
    if (r == 0) {
        em.put(e.movReg(.w, flags, .zr));
        em.put(e.movReg(.w, value, .zr));
        return;
    }
    const s = layout.shadow(r);
    em.put(e.memImm(.ldr_w, flags, t.cpu_reg, s + word_off));
    em.put(e.memImm(.ldr_w, value, t.cpu_reg, layout.reg(r)));
    em.put(e.cmpReg(.w, flags, value));
    em.put(e.memImm(.ldr_w, flags, t.cpu_reg, s + flags_off));
    em.put(e.csel(.w, flags, flags, .zr, .eq));
    em.put(e.memImm(.str_w, flags, t.cpu_reg, s + flags_off));
}

/// The register move: `rs`'s shadow validated, then copied with the value
/// to `rd`. $zero's shadow is always none, which validates as itself. The
/// value is stored first, because the copy takes w9.
pub fn move(ctx: *t.Ctx, rd: u5, rs: u5) void {
    const em = ctx.em;
    if (rs != 0) source(em, rs, .x10, .x11);
    if (rd == 0) return;
    em.put(e.memImm(.str_w, .x9, t.cpu_reg, layout.reg(rd)));
    shadow.copy(em, t.cpu_reg, layout.shadow(rd), t.cpu_reg, layout.shadow(rs));
}

/// `exactValue(result)`: both halves exact, no depth. Reads no source.
pub fn exact(ctx: *t.Ctx, rd: u5) void {
    ctx.em.put(e.memImm(.str_w, .x9, t.cpu_reg, layout.reg(rd)));
    exactShadow(ctx.em, layout.shadow(rd), Value.valid_xy);
}

/// The result's halves, exactly known, as `rd`'s shadow at `d`: no depth,
/// and `flags`.
pub fn exactShadow(em: *t.Emitter, d: u32, flags: u32) void {
    em.put(e.sxth(.x10, .x9));
    em.put(e.scvtf(.s, .v0, .w, .x10));
    em.put(e.fmemImm(.str_s, .v0, t.cpu_reg, d + x_off));
    em.put(e.shiftImm(.asr, .x10, .x9, 16));
    em.put(e.scvtf(.s, .v0, .w, .x10));
    em.put(e.fmemImm(.str_s, .v0, t.cpu_reg, d + y_off));
    em.put(e.memImm(.str_w, .zr, t.cpu_reg, d + z_off));
    em.put(e.memImm(.str_w, .x9, t.cpu_reg, d + word_off));
    em.movImm32(.x10, flags);
    em.put(e.memImm(.str_w, .x10, t.cpu_reg, d + flags_off));
}

/// `ops.zig`'s low half: the signed 16-bit quantity, as `Value.x` is read.
fn lowHalf(word: u32) f32 {
    return @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(word)))));
}

/// `ops.zig`'s high half, as `Value.y` is read.
fn highHalf(word: u32) f32 {
    return @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(word >> 16)))));
}

/// `ops.addi(rs, imm, result)`, with `rs` and the sign-extended `imm` known
/// here. The float work is `ops.addi`'s operation for operation, in f64,
/// with `pgxp.unsign`, `signFold` and `ops.zig`'s `foldHigh` inline: nothing
/// is reassociated, and an add of a constant zero is still emitted, because
/// `-0.0 + 0.0` is `+0.0`. FCMP's `mi`/`gt`/`ge` are false on a NaN, as
/// Zig's `<`/`>`/`>=` are.
pub fn addi(ctx: *t.Ctx, rd: u5, rs: u5, imm: u32) void {
    const em = ctx.em;
    if (rs == 0) {
        // $zero's shadow is none: the result is a constant.
        if (rd != 0) fromZeroRegister(em, rd, imm);
        return;
    }
    source(em, rs, .x10, .x11);
    if (rd == 0) return; // the validation was the hook's only effect
    const d = layout.shadow(rd);
    const s = layout.shadow(rs);
    em.put(e.memImm(.str_w, .x9, t.cpu_reg, layout.reg(rd)));
    if (imm == 0) {
        // Adding nothing: the validated source, with the result as its word.
        shadow.copyVia(em, .x12, t.cpu_reg, d, t.cpu_reg, s);
        em.put(e.memImm(.str_w, .x9, t.cpu_reg, d + word_off));
        return;
    }
    // Every source field is read before `rd`'s shadow is written: `rd` may
    // be `rs`.
    em.put(e.memImm(.ldr_w, .x12, t.cpu_reg, s + z_off));
    em.put(e.fmemImm(.ldr_s, .v0, t.cpu_reg, s + x_off));
    em.put(e.fmemImm(.ldr_s, .v1, t.cpu_reg, s + y_off));
    const zero = em.label();
    const done = em.label();
    em.branch(.{ .cbz = .{ .w, .x11 } }, .{ .label = zero });
    sum(em, imm);
    em.put(e.fmemImm(.str_s, .v5, t.cpu_reg, d + x_off));
    em.put(e.fmemImm(.str_s, .v6, t.cpu_reg, d + y_off));
    retireFlags(em, d, Value.tainted_z);
    em.branch(.b, .{ .label = done });

    // Nothing went in: the immediate's halves, exactly known.
    em.bind(zero);
    em.movImm32(.x13, @bitCast(lowHalf(imm)));
    em.put(e.memImm(.str_w, .x13, t.cpu_reg, d + x_off));
    em.movImm32(.x13, @bitCast(highHalf(imm)));
    em.put(e.memImm(.str_w, .x13, t.cpu_reg, d + y_off));
    retireFlags(em, d, Value.valid_xy | Value.tainted_z);
    em.bind(done);
}

/// `rd`'s z, word and flags: the source's z (w12), the result (w9), and
/// the validated flags (w10) with `set` added.
fn retireFlags(em: *t.Emitter, d: u32, set: u32) void {
    em.put(e.memImm(.str_w, .x12, t.cpu_reg, d + z_off));
    em.put(e.memImm(.str_w, .x9, t.cpu_reg, d + word_off));
    em.movImm32(.x13, set);
    em.put(e.orrReg(.w, .x10, .x10, .x13));
    em.put(e.memImm(.str_w, .x10, t.cpu_reg, d + flags_off));
}

/// `ops.addi` from $zero, whose shadow is none: none with the result as its
/// word for a zero immediate (all zero bytes: the result is 0), otherwise
/// the immediate's halves, exactly known.
fn fromZeroRegister(em: *t.Emitter, rd: u5, imm: u32) void {
    const d = layout.shadow(rd);
    em.put(e.memImm(.str_w, .x9, t.cpu_reg, layout.reg(rd)));
    if (imm == 0) return shadow.clear(em, t.cpu_reg, d);
    em.movImm32(.x13, @bitCast(lowHalf(imm)));
    em.put(e.memImm(.str_w, .x13, t.cpu_reg, d + x_off));
    em.movImm32(.x13, @bitCast(highHalf(imm)));
    em.put(e.memImm(.str_w, .x13, t.cpu_reg, d + y_off));
    em.put(e.memImm(.str_w, .zr, t.cpu_reg, d + z_off));
    em.put(e.memImm(.str_w, .x9, t.cpu_reg, d + word_off));
    em.movImm32(.x13, Value.valid_xy | Value.tainted_z);
    em.put(e.memImm(.str_w, .x13, t.cpu_reg, d + flags_off));
}

/// The sum of a non-zero source and a non-zero immediate, in f64. In: s0
/// the source's x, s1 its y, w10 its validated flags, w11 its value.
/// Out: s5 the result's x, s6 its y.
fn sum(em: *t.Emitter, imm: u32) void {
    em.fconst(.v2, 65536.0);
    // x = unsign(validX) + u16(imm)
    validHalf(em, .v0, .low, .x10, .x11);
    unsign(em, .v0);
    em.fconst(.v3, @floatFromInt(@as(u16, @truncate(imm))));
    em.put(e.farith(.fadd, .d, .v0, .v0, .v3));
    carry(em);
    signFold(em, .v5, .v0);
    // y = foldHigh(validY + highHalf(imm) + carry)
    validHalf(em, .v1, .high, .x10, .x11);
    em.fconst(.v3, highHalf(imm));
    em.put(e.farith(.fadd, .d, .v1, .v1, .v3));
    em.put(e.farith(.fadd, .d, .v1, .v1, .v4));
    foldHigh(em, .v6, .v1);
}

/// `ops.add` (`sub` false) or `ops.sub`. The sources are validated in
/// operand order, then the result branches at run time on their values:
/// a zero `rt` (or, for an add, a zero `rs`) carries the other operand,
/// and otherwise the halves are summed in f64, operation for operation.
pub fn addSub(ctx: *t.Ctx, rd: u5, rs: u5, rt: u5, comptime sub: bool) void {
    const em = ctx.em;
    source(em, rs, .x10, .x11);
    source(em, rt, .x14, .x15);
    if (rd == 0) return; // the validations were the hook's only effect
    const d = layout.shadow(rd);
    const a = layout.shadow(rs);
    const b = layout.shadow(rt);
    em.put(e.memImm(.str_w, .x9, t.cpu_reg, layout.reg(rd)));
    const b_zero = em.label();
    const a_zero = em.label();
    const done = em.label();
    em.branch(.{ .cbz = .{ .w, .x15 } }, .{ .label = b_zero });
    // `0 - rt` is a negation, not a move: only an add takes this path.
    if (!sub) em.branch(.{ .cbz = .{ .w, .x11 } }, .{ .label = a_zero });

    // Every source field is read before `rd`'s shadow is written: `rd` may
    // be either source.
    em.fconst(.v2, 65536.0);
    // x = unsign(validX(a)) +/- unsign(validX(b))
    em.put(e.fmemImm(.ldr_s, .v0, t.cpu_reg, a + x_off));
    validHalf(em, .v0, .low, .x10, .x11);
    unsign(em, .v0);
    em.put(e.fmemImm(.ldr_s, .v1, t.cpu_reg, b + x_off));
    validHalf(em, .v1, .low, .x14, .x15);
    unsign(em, .v1);
    em.put(e.farith(if (sub) .fsub else .fadd, .d, .v0, .v0, .v1));
    if (sub) borrow(em) else carry(em);
    signFold(em, .v5, .v0);
    // y = foldHigh(validY(a) +/- validY(b) +/- carry)
    em.put(e.fmemImm(.ldr_s, .v0, t.cpu_reg, a + y_off));
    validHalf(em, .v0, .high, .x10, .x11);
    em.put(e.fmemImm(.ldr_s, .v1, t.cpu_reg, b + y_off));
    validHalf(em, .v1, .high, .x14, .x15);
    const op: e.FOp = if (sub) .fsub else .fadd;
    em.put(e.farith(op, .d, .v0, .v0, .v1));
    em.put(e.farith(op, .d, .v0, .v0, .v4));
    foldHigh(em, .v6, .v0);
    selectZ(em, a, b);
    // flags = a | (b & valid_xy) | tainted_z, and `selectZ`'s valid_z
    em.movImm32(.x13, Value.valid_xyz);
    em.put(e.andReg(.w, .x13, .x14, .x13));
    em.put(e.orrReg(.w, .x13, .x13, .x10));
    em.movImm32(.x11, Value.tainted_z);
    em.put(e.orrReg(.w, .x13, .x13, .x11));
    em.put(e.fmemImm(.str_s, .v5, t.cpu_reg, d + x_off));
    em.put(e.fmemImm(.str_s, .v6, t.cpu_reg, d + y_off));
    em.put(e.memImm(.str_w, .x12, t.cpu_reg, d + z_off));
    em.put(e.memImm(.str_w, .x9, t.cpu_reg, d + word_off));
    em.put(e.memImm(.str_w, .x13, t.cpu_reg, d + flags_off));
    em.branch(.b, .{ .label = done });

    em.bind(b_zero);
    carryOperand(em, d, a, .x10, b, .x14);
    if (!sub) {
        em.branch(.b, .{ .label = done });
        em.bind(a_zero);
        carryOperand(em, d, b, .x14, a, .x10);
    }
    em.bind(done);
}

/// Adding nothing: `keep`'s shadow (flags validated, in `keep_flags`)
/// with the result as its word, and `ops.copyZIfMissing` from `other`.
/// Clobbers w11-w13 and w15.
fn carryOperand(em: *t.Emitter, d: u32, keep: u32, keep_flags: e.Reg, other: u32, other_flags: e.Reg) void {
    // z = keep has valid_z ? keep.z : other.z
    em.put(e.ubfx(.x13, keep_flags, 2, 1));
    em.put(e.cmpImm(.w, .x13, 0));
    em.put(e.memImm(.ldr_w, .x12, t.cpu_reg, keep + z_off));
    em.put(e.memImm(.ldr_w, .x13, t.cpu_reg, other + z_off));
    em.put(e.csel(.w, .x12, .x12, .x13, .ne));
    // flags = keep | (other & valid_z)
    em.movImm32(.x13, Value.valid_z);
    em.put(e.andReg(.w, .x13, other_flags, .x13));
    em.put(e.orrReg(.w, .x13, .x13, keep_flags));
    em.put(e.memImm(.ldr_w, .x11, t.cpu_reg, keep + x_off));
    em.put(e.memImm(.ldr_w, .x15, t.cpu_reg, keep + y_off));
    em.put(e.memImm(.str_w, .x11, t.cpu_reg, d + x_off));
    em.put(e.memImm(.str_w, .x15, t.cpu_reg, d + y_off));
    em.put(e.memImm(.str_w, .x12, t.cpu_reg, d + z_off));
    em.put(e.memImm(.str_w, .x9, t.cpu_reg, d + word_off));
    em.put(e.memImm(.str_w, .x13, t.cpu_reg, d + flags_off));
}

/// `ops.selectZ`'s z, into w12: `b`'s when `a` has none, or when `a`'s is
/// tainted and `b`'s is valid and untainted; `a`'s otherwise. In: w10 and
/// w14 the two validated flags. Clobbers w11 and w13.
fn selectZ(em: *t.Emitter, a: u32, b: u32) void {
    // b clean = b & (valid_z | tainted_z) == valid_z
    em.movImm32(.x13, Value.valid_z | Value.tainted_z);
    em.put(e.andReg(.w, .x13, .x14, .x13));
    em.put(e.cmpImm(.w, .x13, Value.valid_z));
    em.put(e.cset(.w, .x13, .eq));
    // lose = a tainted and b clean; keep a's z iff it is valid and not lost
    em.put(e.shiftImm(.lsr, .x11, .x10, 31));
    em.put(e.andReg(.w, .x13, .x13, .x11));
    em.put(e.ubfx(.x12, .x10, 2, 1));
    em.put(e.cmpReg(.w, .x12, .x13));
    em.put(e.memImm(.ldr_w, .x12, t.cpu_reg, a + z_off));
    em.put(e.memImm(.ldr_w, .x13, t.cpu_reg, b + z_off));
    em.put(e.csel(.w, .x12, .x12, .x13, .hi));
}

// The f64 steps every rule here shares, each one `pgxp/`'s operation for
// operation. v2 holds 65536.0 wherever one of them reads it; v3 and x13
// are scratch in all of them.

/// `pgxp.unsign`: a negative half lifted by 65536. `>=` is false on a
/// NaN, as Zig's is, so a NaN is lifted (and stays a NaN).
pub fn unsign(em: *t.Emitter, r: e.FReg) void {
    em.put(e.farith(.fadd, .d, .v3, r, .v2));
    em.put(e.fcmpZero(.d, r));
    em.put(e.fcsel(.d, r, r, .v3, .ge));
}

/// The carry out of a low-half sum in d0, into d4: 1 above 65535, -1
/// below 0, else 0.
fn carry(em: *t.Emitter) void {
    em.put(e.fmovFromGp(.d, .v4, .zr));
    em.fconst(.v3, -1.0);
    em.put(e.fcmpZero(.d, .v0));
    em.put(e.fcsel(.d, .v4, .v3, .v4, .mi));
    em.fconst(.v3, 65535.0);
    em.put(e.fcmp(.d, .v0, .v3));
    em.fconst(.v3, 1.0);
    em.put(e.fcsel(.d, .v4, .v3, .v4, .gt));
}

/// The borrow out of a low-half difference in d0, into d4: 1 below 0,
/// else 0.
fn borrow(em: *t.Emitter) void {
    em.put(e.fmovFromGp(.d, .v4, .zr));
    em.fconst(.v3, 1.0);
    em.put(e.fcmpZero(.d, .v0));
    em.put(e.fcsel(.d, .v4, .v3, .v4, .mi));
}

/// `@floatCast(pgxp.signFold(in))` into `out`'s `s`: onto the 1/65536
/// grid, wrapped to i32 (`fcvtzs` is `lossyCast(i64, ·)`; the `w` read
/// is the truncation), back to f64, then rounded to f32.
pub fn signFold(em: *t.Emitter, out: e.FReg, in: e.FReg) void {
    em.put(e.farith(.fmul, .d, .v3, in, .v2));
    em.put(e.fcvtzsX(.x13, .v3));
    em.put(e.scvtf(.d, .v3, .w, .x13));
    em.put(e.farith(.fdiv, .d, .v3, .v3, .v2));
    em.put(e.fcvt(.s, out, .v3));
}

/// `@floatCast(ops.zig's foldHigh(in))` into `out`'s `s`. Clobbers d7.
fn foldHigh(em: *t.Emitter, out: e.FReg, in: e.FReg) void {
    em.put(e.farith(.fsub, .d, .v3, in, .v2)); // y - 65536
    em.put(e.farith(.fadd, .d, out, in, .v2)); // y + 65536
    em.fconst(.v7, -32768.0);
    em.put(e.fcmp(.d, in, .v7));
    em.put(e.fcsel(.d, out, out, in, .mi));
    em.fconst(.v7, 32767.0);
    em.put(e.fcmp(.d, in, .v7));
    em.put(e.fcsel(.d, out, .v3, out, .gt));
    em.put(e.fcvt(.s, out, out));
}

pub const Half = enum { low, high };

/// `Value.validX`/`validY` as an f32: `r` (holding the stored half) keeps
/// it when the half's valid flag is set in `flags`, else takes `value`'s
/// half, sign-extended.
pub fn validHalfS(em: *t.Emitter, r: e.FReg, half: Half, flags: e.Reg, value: e.Reg) void {
    em.put(if (half == .high) e.shiftImm(.asr, .x13, value, 16) else e.sxth(.x13, value));
    em.put(e.scvtf(.s, .v3, .w, .x13));
    em.put(e.ubfx(.x13, flags, if (half == .high) 1 else 0, 1));
    em.put(e.cmpImm(.w, .x13, 0));
    em.put(e.fcsel(.s, r, r, .v3, .ne));
}

/// `validHalfS`, widened to f64.
pub fn validHalf(em: *t.Emitter, r: e.FReg, half: Half, flags: e.Reg, value: e.Reg) void {
    validHalfS(em, r, half, flags, value);
    em.put(e.fcvt(.d, r, r));
}
