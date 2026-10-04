//! ALU, shift, logic, LUI and SLT ops, inline. Each reads its sources from
//! `Cpu.regs` and stores its result there; `model.zig` resolves the load
//! delay around it. ADD, ADDI and SUB leave for their `exec.zig` handler on
//! overflow, which raises the exception.
//!
//! Compiled only while PGXP is off, so a result is a plain store: the
//! dispatcher clears every GPR shadow when PGXP comes back on (`run.zig`).

const e = @import("emit.zig");
const t = @import("translate.zig");
const Instruction = @import("../../cpu/exec.zig").Instruction;
const sext16 = @import("../../bits.zig").sext16;

const R = @FieldType(Instruction, "r");
const Op = enum { add, sub, and_, orr, eor };
const Operand = union(enum) { reg: u5, imm: u32 };

fn encode(op: Op, rd: e.Reg, rn: e.Reg, rm: e.Reg) u32 {
    return switch (op) {
        .add => e.addReg(.w, rd, rn, rm),
        .sub => e.subReg(.w, rd, rn, rm),
        .and_ => e.andReg(.w, rd, rn, rm),
        .orr => e.orrReg(.w, rd, rn, rm),
        .eor => e.eorReg(.w, rd, rn, rm),
    };
}

/// False, having emitted nothing, for an op this file does not lower.
pub fn emit(ctx: *t.Ctx) bool {
    const in = ctx.op().instr;
    const i = in.i;
    switch (i.opcode) {
        0x00 => return special(ctx, in.r),
        0x08 => checked(ctx, .add, i.rt, i.rs, .{ .imm = sext16(i.imm) }), // ADDI
        0x09 => immediate(ctx, .add, i.rt, i.rs, sext16(i.imm)), // ADDIU
        0x0A => setImm(ctx, .lt, i.rt, i.rs, sext16(i.imm)), // SLTI
        0x0B => setImm(ctx, .lo, i.rt, i.rs, sext16(i.imm)), // SLTIU
        0x0C => immediate(ctx, .and_, i.rt, i.rs, i.imm),
        0x0D => immediate(ctx, .orr, i.rt, i.rs, i.imm),
        0x0E => immediate(ctx, .eor, i.rt, i.rs, i.imm),
        0x0F => lui(ctx, i.rt, i.imm),
        else => return false,
    }
    return true;
}

fn special(ctx: *t.Ctx, r: R) bool {
    switch (r.funct) {
        0x00 => shiftImm(ctx, r, .lsl),
        0x02 => shiftImm(ctx, r, .lsr),
        0x03 => shiftImm(ctx, r, .asr),
        0x04 => shiftVar(ctx, r, .lsl),
        0x06 => shiftVar(ctx, r, .lsr),
        0x07 => shiftVar(ctx, r, .asr),
        0x20 => checked(ctx, .add, r.rd, r.rs, .{ .reg = r.rt }),
        0x21 => register(ctx, .add, r),
        0x22 => checked(ctx, .sub, r.rd, r.rs, .{ .reg = r.rt }),
        0x23 => register(ctx, .sub, r),
        0x24 => register(ctx, .and_, r),
        0x25 => register(ctx, .orr, r),
        0x26 => register(ctx, .eor, r),
        0x27 => nor(ctx, r),
        0x2A => setReg(ctx, .lt, r),
        0x2B => setReg(ctx, .lo, r),
        else => return false,
    }
    return true;
}

// Every op below but `checked` has its destination as its only effect, so
// one that writes $zero is emitted as nothing but the landing load.

fn register(ctx: *t.Ctx, op: Op, r: R) void {
    _ = ctx.beginInline(null, r.rd);
    if (r.rd != 0) {
        const a = ctx.src(r.rs, .x10);
        const b = ctx.src(r.rt, .x11);
        ctx.em.put(encode(op, .x9, a, b));
        ctx.dst(r.rd, .x9);
    }
    ctx.endInline();
}

fn nor(ctx: *t.Ctx, r: R) void {
    _ = ctx.beginInline(null, r.rd);
    if (r.rd != 0) {
        const a = ctx.src(r.rs, .x10);
        const b = ctx.src(r.rt, .x11);
        ctx.em.put(e.orrReg(.w, .x9, a, b));
        ctx.em.put(e.ornReg(.w, .x9, .zr, .x9));
        ctx.dst(r.rd, .x9);
    }
    ctx.endInline();
}

fn setReg(ctx: *t.Ctx, cond: e.Cond, r: R) void {
    _ = ctx.beginInline(null, r.rd);
    if (r.rd != 0) {
        const a = ctx.src(r.rs, .x10);
        const b = ctx.src(r.rt, .x11);
        ctx.em.put(e.cmpReg(.w, a, b));
        ctx.em.put(e.cset(.w, .x9, cond));
        ctx.dst(r.rd, .x9);
    }
    ctx.endInline();
}

fn shiftImm(ctx: *t.Ctx, r: R, shift: e.Shift) void {
    _ = ctx.beginInline(null, r.rd);
    if (r.rd != 0) {
        const v = ctx.src(r.rt, .x10);
        ctx.em.put(e.shiftImm(shift, .x9, v, r.shamt));
        ctx.dst(r.rd, .x9);
    }
    ctx.endInline();
}

/// SLLV/SRLV/SRAV shift by `rs` modulo 32, which is what the host does too.
fn shiftVar(ctx: *t.Ctx, r: R, shift: e.Shift) void {
    _ = ctx.beginInline(null, r.rd);
    if (r.rd != 0) {
        const v = ctx.src(r.rt, .x10);
        const n = ctx.src(r.rs, .x11);
        ctx.em.put(e.shiftReg(.w, shift, .x9, v, n));
        ctx.dst(r.rd, .x9);
    }
    ctx.endInline();
}

fn immediate(ctx: *t.Ctx, op: Op, rt: u5, rs: u5, imm: u32) void {
    _ = ctx.beginInline(null, rt);
    if (rt != 0) {
        const a = ctx.src(rs, .x10);
        ctx.em.movImm32(.x11, imm);
        ctx.em.put(encode(op, .x9, a, .x11));
        ctx.dst(rt, .x9);
    }
    ctx.endInline();
}

fn setImm(ctx: *t.Ctx, cond: e.Cond, rt: u5, rs: u5, imm: u32) void {
    _ = ctx.beginInline(null, rt);
    if (rt != 0) {
        const a = ctx.src(rs, .x10);
        ctx.em.movImm32(.x11, imm);
        ctx.em.put(e.cmpReg(.w, a, .x11));
        ctx.em.put(e.cset(.w, .x9, cond));
        ctx.dst(rt, .x9);
    }
    ctx.endInline();
}

fn lui(ctx: *t.Ctx, rt: u5, imm: u16) void {
    _ = ctx.beginInline(null, rt);
    if (rt != 0) {
        ctx.em.put(e.movz(.w, .x9, imm, 1));
        ctx.dst(rt, .x9);
    }
    ctx.endInline();
}

/// ADD, ADDI, SUB. On overflow nothing has been written and the slow path
/// runs the op's handler, which raises the exception and stops the block;
/// even a write to $zero can overflow, so these are always emitted.
fn checked(ctx: *t.Ctx, op: enum { add, sub }, rd: u5, rs: u5, b: Operand) void {
    const before = ctx.beginInline(null, rd);
    const slow = ctx.slowPath(before);
    const a = ctx.src(rs, .x10);
    const rm: e.Reg = switch (b) {
        .reg => |r| ctx.src(r, .x11),
        .imm => |imm| blk: {
            ctx.em.movImm32(.x11, imm);
            break :blk .x11;
        },
    };
    ctx.em.put(switch (op) {
        .add => e.addsReg(.w, .x9, a, rm),
        .sub => e.subsReg(.w, .x9, a, rm),
    });
    ctx.em.branch(.{ .cond = .vs }, .{ .label = slow.entry });
    ctx.dst(rd, .x9);
    ctx.endInline();
    ctx.em.bind(slow.back);
}
