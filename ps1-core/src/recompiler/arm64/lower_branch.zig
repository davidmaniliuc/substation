//! Branches and jumps, inline. A branch computes its target into w10,
//! links where it links, and then writes the pipeline as `exec.zig`'s
//! handler leaves it (`next_pc` the target, `next_is_delay_slot` set) along
//! with everything else the model holds: its delay slot is the next op,
//! inline or a call, and a call would clobber w10.
//!
//! A branch in another branch's delay slot stays a call: its own delay slot
//! is not in the block. So does a reserved REGIMM, which raises.

const e = @import("emit.zig");
const t = @import("translate.zig");
const sext16 = @import("../../bits.zig").sext16;

/// False, having emitted nothing, for an op this file does not lower.
pub fn emit(ctx: *t.Ctx) bool {
    if (ctx.isDelaySlot()) return false;
    const in = ctx.op().instr;
    const pc = ctx.pc();
    const relative = pc +% 4 +% (sext16(in.i.imm) << 2);
    const absolute = ((pc +% 4) & 0xF000_0000) | @as(u32, in.j.target) << 2;
    switch (in.i.opcode) {
        0x00 => switch (in.r.funct) {
            0x08 => register(ctx, in.r.rs, null), // JR
            0x09 => register(ctx, in.r.rs, in.r.rd), // JALR
            else => return false,
        },
        0x01 => switch (in.i.rt) {
            0x00 => conditional(ctx, in.i.rs, null, .lt, relative, null), // BLTZ
            0x01 => conditional(ctx, in.i.rs, null, .ge, relative, null), // BGEZ
            0x10 => conditional(ctx, in.i.rs, null, .lt, relative, 31), // BLTZAL
            0x11 => conditional(ctx, in.i.rs, null, .ge, relative, 31), // BGEZAL
            else => return false,
        },
        0x02 => jump(ctx, absolute, null), // J
        0x03 => jump(ctx, absolute, 31), // JAL
        0x04 => conditional(ctx, in.i.rs, in.i.rt, .eq, relative, null), // BEQ
        0x05 => conditional(ctx, in.i.rs, in.i.rt, .ne, relative, null), // BNE
        0x06 => conditional(ctx, in.i.rs, null, .le, relative, null), // BLEZ
        0x07 => conditional(ctx, in.i.rs, null, .gt, relative, null), // BGTZ
        else => return false,
    }
    return true;
}

/// `rs` against `rt`, or against zero when `rt` is null. The link is
/// written after `rs` is read, as `opRegimm` reads it first.
fn conditional(ctx: *t.Ctx, rs: u5, rt: ?u5, cond: e.Cond, taken: u32, link: ?u5) void {
    const em = ctx.em;
    _ = ctx.beginInline(null, link);
    const a = ctx.src(rs, .x10);
    const b: e.Reg = if (rt) |r| ctx.src(r, .x11) else .zr;
    em.put(e.cmpReg(.w, a, b));
    const not_taken = ctx.pc() +% 8;
    // Neither MOVZ, MOVK nor STR touches the flags.
    if (link) |r| {
        em.movImm32(.x11, not_taken);
        ctx.dst(r, .x11);
    }
    em.movImm32(.x10, taken);
    em.movImm32(.x11, not_taken);
    em.put(e.csel(.w, .x10, .x10, .x11, cond));
    ctx.endBranch(.x10);
}

fn jump(ctx: *t.Ctx, target: u32, link: ?u5) void {
    _ = ctx.beginInline(null, link);
    if (link) |r| {
        ctx.em.movImm32(.x11, ctx.pc() +% 8);
        ctx.dst(r, .x11);
    }
    ctx.em.movImm32(.x10, target);
    ctx.endBranch(.x10);
}

/// JR, JALR. The link is written before the target is read, as `opJalr`
/// does, so with rd == rs the jump goes to the link.
fn register(ctx: *t.Ctx, rs: u5, link: ?u5) void {
    _ = ctx.beginInline(null, link);
    if (link) |r| {
        ctx.em.movImm32(.x11, ctx.pc() +% 8);
        ctx.dst(r, .x11);
    }
    ctx.endBranch(ctx.src(rs, .x10));
}
