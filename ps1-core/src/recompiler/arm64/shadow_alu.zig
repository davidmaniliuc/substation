//! PGXP's CPU-mode ALU rules emitted inline where they can be stated
//! exactly: the register move (`ops.move`, in both tiers), `exactValue`
//! (`ops.exact`, `ops.sltReg`), and ADDI/ADDIU (`ops.addi`). Each reads and
//! writes the memory its shim reads and writes, at the same point in the
//! op, so `.jit` stays byte-identical to `.cached`. Every other hook keeps
//! its shim (`shadow.hooked`).
//!
//! The op's result is in w9 on entry. Scratch: w10-w13, x16, d0-d6.

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

/// `ops.source(rs)`: a shadow recorded against another word than `rs`
/// holds loses its flags, in the table too. Leaves w10 the validated flags
/// and w11 `rs`'s value.
fn validate(em: *t.Emitter, rs: u5) void {
    const s = layout.shadow(rs);
    em.put(e.memImm(.ldr_w, .x10, t.cpu_reg, s + word_off));
    em.put(e.memImm(.ldr_w, .x11, t.cpu_reg, layout.reg(rs)));
    em.put(e.cmpReg(.w, .x10, .x11));
    em.put(e.memImm(.ldr_w, .x10, t.cpu_reg, s + flags_off));
    em.put(e.csel(.w, .x10, .x10, .zr, .eq));
    em.put(e.memImm(.str_w, .x10, t.cpu_reg, s + flags_off));
}

/// The register move: `rs`'s shadow validated, then copied with the value
/// to `rd`. $zero's shadow is always none, which validates as itself. The
/// value is stored first, because the copy takes w9.
pub fn move(ctx: *t.Ctx, rd: u5, rs: u5) void {
    const em = ctx.em;
    if (rs != 0) validate(em, rs);
    if (rd == 0) return;
    em.put(e.memImm(.str_w, .x9, t.cpu_reg, layout.reg(rd)));
    shadow.copy(em, t.cpu_reg, layout.shadow(rd), t.cpu_reg, layout.shadow(rs));
}

/// `exactValue(result)`: both halves exact, no depth. Reads no source.
pub fn exact(ctx: *t.Ctx, rd: u5) void {
    const em = ctx.em;
    const d = layout.shadow(rd);
    em.put(e.memImm(.str_w, .x9, t.cpu_reg, layout.reg(rd)));
    em.put(e.sxth(.x10, .x9));
    em.put(e.scvtf(.s, .v0, .w, .x10));
    em.put(e.fmemImm(.str_s, .v0, t.cpu_reg, d + x_off));
    em.put(e.shiftImm(.asr, .x10, .x9, 16));
    em.put(e.scvtf(.s, .v0, .w, .x10));
    em.put(e.fmemImm(.str_s, .v0, t.cpu_reg, d + y_off));
    em.put(e.memImm(.str_w, .zr, t.cpu_reg, d + z_off));
    em.put(e.memImm(.str_w, .x9, t.cpu_reg, d + word_off));
    em.movImm32(.x10, Value.valid_xy);
    em.put(e.memImm(.str_w, .x10, t.cpu_reg, d + flags_off));
}
