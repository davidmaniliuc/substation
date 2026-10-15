//! PGXP's CPU-mode rules for the immediate shifts (`shift.left`,
//! `shift.right`) emitted inline, with the amount known here. The float
//! work is `pgxp/shift.zig`'s operation for operation, in f64; its integer
//! probes are run on the register's value. The variable shifts keep their
//! shims (`shadow.hooked`).
//!
//! The op's result is in w9 on entry. Scratch: w10-w15, x16, d0-d7.

const e = @import("emit.zig");
const t = @import("translate.zig");
const layout = @import("layout.zig");
const shadow = @import("shadow.zig");
const alu = @import("shadow_alu.zig");
const Value = @import("../../pgxp/pgxp.zig").Value;

const x_off = @offsetOf(Value, "x");
const y_off = @offsetOf(Value, "y");
const z_off = @offsetOf(Value, "z");
const word_off = @offsetOf(Value, "word");
const flags_off = @offsetOf(Value, "flags");

/// `shift.pow2(sh)`.
fn pow2(sh: u5) f64 {
    return @floatFromInt(@as(u32, 1) << sh);
}

/// `shift.left(rt, sh, result)`: SLL.
pub fn left(ctx: *t.Ctx, rd: u5, rt: u5, sh: u5) void {
    const em = ctx.em;
    alu.source(em, rt, .x10, .x11);
    if (rd == 0) return; // the validation was the hook's only effect
    const d = layout.shadow(rd);
    const s = layout.shadow(rt);
    em.put(e.memImm(.str_w, .x9, t.cpu_reg, layout.reg(rd)));
    // Every source field is read before `rd`'s shadow is written: `rd` may
    // be `rt`.
    em.put(e.memImm(.ldr_w, .x12, t.cpu_reg, s + z_off));
    em.put(e.fmemImm(.ldr_s, .v0, t.cpu_reg, s + x_off));
    if (sh >= 16) {
        // The low half shifts out: x is an exact zero, and y the source's
        // low half, scaled.
        alu.validHalfS(em, .v0, .low, .x10, .x11);
        if (sh != 16) {
            em.put(e.fcvt(.d, .v0, .v0));
            em.fconst(.v4, pow2(sh - 16));
            em.put(e.farith(.fmul, .d, .v0, .v0, .v4));
            em.fconst(.v2, 65536.0);
            alu.unsign(em, .v0);
            alu.signFold(em, .v0, .v0);
        }
        em.put(e.memImm(.str_w, .zr, t.cpu_reg, d + x_off));
        em.put(e.fmemImm(.str_s, .v0, t.cpu_reg, d + y_off));
        // flags = src | tainted_z | (src & valid_y) >> 1: the Spyro rule
        em.put(e.ubfx(.x13, .x10, 1, 1));
        em.put(e.orrReg(.w, .x10, .x10, .x13));
    } else {
        // Both halves survive, and the carry out of the low one lands in
        // the high.
        em.fconst(.v2, 65536.0);
        em.fconst(.v4, pow2(sh));
        em.put(e.fmemImm(.ldr_s, .v1, t.cpu_reg, s + y_off));
        alu.validHalf(em, .v0, .low, .x10, .x11);
        alu.unsign(em, .v0);
        em.put(e.farith(.fmul, .d, .v0, .v0, .v4));
        alu.validHalf(em, .v1, .high, .x10, .x11);
        alu.unsign(em, .v1);
        em.put(e.farith(.fmul, .d, .v1, .v1, .v4));
        // + pgxp.overflow(x): `lossyCast(i64, x) >> 16`, back to f64
        em.put(e.fcvtzsX(.x13, .v0));
        em.put(e.movz(.w, .x14, 16, 0));
        em.put(e.shiftReg(.x, .asr, .x13, .x13, .x14));
        em.put(e.scvtf(.d, .v3, .x, .x13));
        em.put(e.farith(.fadd, .d, .v1, .v1, .v3));
        alu.signFold(em, .v5, .v0);
        alu.signFold(em, .v6, .v1);
        em.put(e.fmemImm(.str_s, .v5, t.cpu_reg, d + x_off));
        em.put(e.fmemImm(.str_s, .v6, t.cpu_reg, d + y_off));
    }
    retire(em, d);
}

/// `shift.right(rt, sh, result, signed, false)`: SRL and SRA.
pub fn right(ctx: *t.Ctx, rd: u5, rt: u5, sh: u5, comptime signed: bool) void {
    const em = ctx.em;
    alu.source(em, rt, .x10, .x11);
    if (rd == 0) return; // the validation was the hook's only effect
    const d = layout.shadow(rd);
    const s = layout.shadow(rt);
    em.put(e.memImm(.str_w, .x9, t.cpu_reg, layout.reg(rd)));
    if (sh == 0) {
        // Shifting by nothing: the validated source, with the result as
        // its word.
        shadow.copyVia(em, .x12, t.cpu_reg, d, t.cpu_reg, s);
        em.put(e.memImm(.str_w, .x9, t.cpu_reg, d + word_off));
        return;
    }
    const done = em.label();
    if (signed and sh < 16) {
        // The Persona 2 rule: a value that never came from a projection
        // takes the result's halves, exactly known, and no depth.
        const has_depth = em.label();
        em.branch(.{ .tbnz = .{ .x10, 2 } }, .{ .label = has_depth });
        alu.exactShadow(em, d, Value.valid_xy | Value.tainted_z);
        em.branch(.b, .{ .label = done });
        em.bind(has_depth);
    }
    scaled(em, s, d, sh, signed);
    em.bind(done);
}

/// `shift.right` past its two early returns. In: w10 the validated
/// flags, w11 the source's value.
fn scaled(em: *t.Emitter, s: u32, d: u32, sh: u5, signed: bool) void {
    em.fconst(.v2, 65536.0);
    // x_in, and y_in: unsigned for a logical shift
    em.put(e.fmemImm(.ldr_s, .v0, t.cpu_reg, s + x_off));
    alu.validHalf(em, .v0, .low, .x10, .x11);
    em.put(e.fmemImm(.ldr_s, .v1, t.cpu_reg, s + y_off));
    alu.validHalf(em, .v1, .high, .x10, .x11);
    if (!signed) alu.unsign(em, .v1);

    // The probes: w12 probe_x, w14 sign_fill (0 or -1), and the low half
    // of probe_x >> sh in w13, which decides x.
    em.put(e.sxth(.x12, .x11));
    em.put(e.shiftImm(.asr, .x14, .x12, 31));
    em.put(e.shiftImm(.asr, .x13, .x12, sh));
    em.put(e.sxth(.x13, .x13));
    em.put(e.scvtf(.d, .v3, .w, .x13));
    em.fconst(.v4, pow2(sh));
    em.put(e.farith(.fdiv, .d, .v5, .v0, .v4));
    em.put(e.cmpReg(.w, .x13, .x14));
    em.put(e.fcsel(.d, .v5, .v5, .v3, .ne));

    // probe_y = rt's high half over the low half's sign, shifted, in w13;
    // its low half in w15 decides whether the high half reached x.
    em.put(e.shiftImm(.lsr, .x13, .x11, 16));
    em.put(e.shiftImm(.lsl, .x13, .x13, 16));
    em.put(e.shiftImm(.lsr, .x15, .x12, 16));
    em.put(e.orrReg(.w, .x13, .x13, .x15));
    em.put(e.shiftImm(if (signed) .asr else .lsr, .x13, .x13, sh));
    em.put(e.sxth(.x15, .x13));
    // x's candidate with the high half folded in: y_in itself at 16, else
    // in d6. Its float compare comes before the integer one the select
    // reads.
    if (sh < 16) {
        em.fconst(.v4, pow2(16 - sh));
        em.put(e.farith(.fmul, .d, .v6, .v1, .v4));
        em.put(e.farith(.fadd, .d, .v6, .v5, .v6));
        em.put(e.farith(.fadd, .d, .v3, .v6, .v4));
        em.put(e.fcmpZero(.d, .v0));
        em.put(e.fcsel(.d, .v6, .v3, .v6, .mi));
    } else if (sh > 16) {
        em.fconst(.v4, pow2(sh - 16));
        em.put(e.farith(.fdiv, .d, .v6, .v1, .v4));
        em.put(e.farith(.fadd, .d, .v6, .v5, .v6));
    }
    em.put(e.cmpReg(.w, .x15, .x14));
    em.put(e.fcsel(.d, .v5, if (sh == 16) .v1 else .v6, .v5, .ne));

    // y: the high half of probe_y >> sh when that is 0 or -1, else
    // y_in / 2^sh.
    em.put(e.shiftImm(.asr, .x15, .x13, 16));
    em.put(e.scvtf(.d, .v3, .w, .x15));
    em.fconst(.v4, pow2(sh));
    em.put(e.farith(.fdiv, .d, .v6, .v1, .v4));
    em.put(e.addImm(.w, .x15, .x15, 1));
    em.put(e.cmpImm(.w, .x15, 1));
    em.put(e.fcsel(.d, .v6, .v3, .v6, .ls));

    alu.signFold(em, .v5, .v5);
    alu.signFold(em, .v6, .v6);
    em.put(e.memImm(.ldr_w, .x12, t.cpu_reg, s + z_off));
    em.put(e.fmemImm(.str_s, .v5, t.cpu_reg, d + x_off));
    em.put(e.fmemImm(.str_s, .v6, t.cpu_reg, d + y_off));
    retire(em, d);
}

/// `rd`'s z (w12), word (the result, w9) and flags: the validated flags
/// (w10) with tainted_z added.
fn retire(em: *t.Emitter, d: u32) void {
    em.put(e.memImm(.str_w, .x12, t.cpu_reg, d + z_off));
    em.put(e.memImm(.str_w, .x9, t.cpu_reg, d + word_off));
    em.movImm32(.x13, Value.tainted_z);
    em.put(e.orrReg(.w, .x10, .x10, .x13));
    em.put(e.memImm(.str_w, .x10, t.cpu_reg, d + flags_off));
}
