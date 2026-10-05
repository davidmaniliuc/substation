//! ALU, shift, logic, LUI and SLT ops, inline. Each reads its sources from
//! `Cpu.regs` and stores its result there; `model.zig` resolves the load
//! delay around it. ADD, ADDI and SUB leave for their `exec.zig` handler on
//! overflow, which raises the exception.
//!
//! Under PGXP's base tier `Ctx.dst` clears the destination's shadow, which
//! is all `writeReg` does there. Under the CPU tier every op retires through
//! its CPU-mode hook instead (`shadow.hooked`), and the register-move idiom
//! does in both tiers.

const e = @import("emit.zig");
const t = @import("translate.zig");
const shadow = @import("shadow.zig");
const Instruction = @import("../../cpu/exec.zig").Instruction;
const sext16 = @import("../../bits.zig").sext16;
const pgxp = @import("../../pgxp/pgxp.zig");
const ops = pgxp.ops;
const shifts = pgxp.shift;

const R = @FieldType(Instruction, "r");
const Op = enum { add, sub, and_, orr, eor };
const Operand = union(enum) { reg: u5, imm: u32 };
const Arg = shadow.Arg;

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
        0x08 => checked(ctx, .add, i.rt, i.rs, .{ .imm = sext16(i.imm) }, ops.addi), // ADDI
        0x09 => immediate(ctx, .add, i.rt, i.rs, sext16(i.imm), ops.addi), // ADDIU
        0x0A => setImm(ctx, .lt, i.rt, i.rs, sext16(i.imm)), // SLTI
        0x0B => setImm(ctx, .lo, i.rt, i.rs, sext16(i.imm)), // SLTIU
        0x0C => immediate(ctx, .and_, i.rt, i.rs, i.imm, ops.andi),
        0x0D => immediate(ctx, .orr, i.rt, i.rs, i.imm, ops.bitwiseImm),
        0x0E => immediate(ctx, .eor, i.rt, i.rs, i.imm, ops.bitwiseImm),
        0x0F => lui(ctx, i.rt, i.imm),
        else => return false,
    }
    return true;
}

fn special(ctx: *t.Ctx, r: R) bool {
    // `addu`/`or` with $zero is PGXP's register move, which carries a
    // shadow even with CPU mode off (`exec.zig`'s `rOpMove`).
    if ((r.funct == 0x21 or r.funct == 0x25) and r.rt == 0 and ctx.opts.pgxp != .off) {
        move(ctx, r);
        return true;
    }
    switch (r.funct) {
        0x00 => shiftImm(ctx, r, .lsl, shifts.left),
        0x02 => shiftImm(ctx, r, .lsr, shifts.srl),
        0x03 => shiftImm(ctx, r, .asr, shifts.sra),
        0x04 => shiftVar(ctx, r, .lsl, shifts.left),
        0x06 => shiftVar(ctx, r, .lsr, shifts.srlv),
        0x07 => shiftVar(ctx, r, .asr, shifts.srav),
        0x20 => checked(ctx, .add, r.rd, r.rs, .{ .reg = r.rt }, ops.add),
        0x21 => register(ctx, .add, r, ops.add),
        0x22 => checked(ctx, .sub, r.rd, r.rs, .{ .reg = r.rt }, ops.sub),
        0x23 => register(ctx, .sub, r, ops.sub),
        0x24 => register(ctx, .and_, r, ops.bitwise),
        0x25 => register(ctx, .orr, r, ops.bitwise),
        0x26 => register(ctx, .eor, r, ops.bitwise),
        0x27 => nor(ctx, r),
        0x2A => setReg(ctx, .lt, r),
        0x2B => setReg(ctx, .lo, r),
        else => return false,
    }
    return true;
}

// Every op below but `checked` has its destination as its only effect, and
// under the CPU tier its hook's validation of the sources it reads. One with
// neither is emitted as nothing but the landing load.

/// Whether the op does anything: it writes a register, or under the CPU tier
/// its hook validates a source (`ops.source`). $zero's shadow is always
/// none, so reading it validates nothing.
fn runs(ctx: *const t.Ctx, rd: u5, reads: []const u5) bool {
    if (rd != 0) return true;
    if (ctx.opts.pgxp != .cpu) return false;
    for (reads) |r| if (r != 0) return true;
    return false;
}

/// The result in w9 to `rd`: under the CPU tier through `hook`, which takes
/// `a` and `b` beside it, otherwise as `writeReg` stores it.
fn retire(ctx: *t.Ctx, rd: u5, comptime hook: anytype, a: Arg, b: Arg) void {
    if (ctx.opts.pgxp == .cpu) return shadow.hooked(ctx, hook, rd, a, b);
    ctx.dst(rd, .x9);
}

fn register(ctx: *t.Ctx, op: Op, r: R, comptime hook: ops.RegHook) void {
    _ = ctx.beginInline(null, r.rd);
    if (runs(ctx, r.rd, &.{ r.rs, r.rt })) {
        const a = ctx.src(r.rs, .x10);
        const b = ctx.src(r.rt, .x11);
        ctx.em.put(encode(op, .x9, a, b));
        retire(ctx, r.rd, hook, .{ .imm = r.rs }, .{ .imm = r.rt });
    }
    ctx.endInline();
}

/// `addu`/`or rd, rs, $zero` under PGXP, in either tier.
fn move(ctx: *t.Ctx, r: R) void {
    _ = ctx.beginInline(null, r.rd);
    if (r.rd != 0 or r.rs != 0) {
        ctx.em.put(e.movReg(.w, .x9, ctx.src(r.rs, .x10)));
        shadow.hooked(ctx, shadow.move, r.rd, .{ .imm = r.rs }, .{ .imm = 0 });
    }
    ctx.endInline();
}

fn nor(ctx: *t.Ctx, r: R) void {
    _ = ctx.beginInline(null, r.rd);
    if (runs(ctx, r.rd, &.{ r.rs, r.rt })) {
        const a = ctx.src(r.rs, .x10);
        const b = ctx.src(r.rt, .x11);
        ctx.em.put(e.orrReg(.w, .x9, a, b));
        ctx.em.put(e.ornReg(.w, .x9, .zr, .x9));
        retire(ctx, r.rd, ops.bitwise, .{ .imm = r.rs }, .{ .imm = r.rt });
    }
    ctx.endInline();
}

/// SLT/SLTU. Its hook reads nothing but the result.
fn setReg(ctx: *t.Ctx, cond: e.Cond, r: R) void {
    _ = ctx.beginInline(null, r.rd);
    if (r.rd != 0) {
        const a = ctx.src(r.rs, .x10);
        const b = ctx.src(r.rt, .x11);
        ctx.em.put(e.cmpReg(.w, a, b));
        ctx.em.put(e.cset(.w, .x9, cond));
        retire(ctx, r.rd, ops.sltReg, .{ .imm = r.rs }, .{ .imm = r.rt });
    }
    ctx.endInline();
}

fn shiftImm(ctx: *t.Ctx, r: R, shift: e.Shift, comptime hook: shifts.Hook) void {
    _ = ctx.beginInline(null, r.rd);
    if (runs(ctx, r.rd, &.{r.rt})) {
        const v = ctx.src(r.rt, .x10);
        ctx.em.put(e.shiftImm(shift, .x9, v, r.shamt));
        retire(ctx, r.rd, hook, .{ .imm = r.rt }, .{ .imm = r.shamt });
    }
    ctx.endInline();
}

/// SLLV/SRLV/SRAV shift by `rs` modulo 32, which is what the host does too.
fn shiftVar(ctx: *t.Ctx, r: R, shift: e.Shift, comptime hook: shifts.Hook) void {
    _ = ctx.beginInline(null, r.rd);
    if (runs(ctx, r.rd, &.{r.rt})) {
        const v = ctx.src(r.rt, .x10);
        const n = ctx.src(r.rs, .x11);
        ctx.em.put(e.shiftReg(.w, shift, .x9, v, n));
        retire(ctx, r.rd, hook, .{ .imm = r.rt }, .{ .reg = n });
    }
    ctx.endInline();
}

fn immediate(ctx: *t.Ctx, op: Op, rt: u5, rs: u5, imm: u32, comptime hook: ops.ImmHook) void {
    _ = ctx.beginInline(null, rt);
    if (runs(ctx, rt, &.{rs})) {
        const a = ctx.src(rs, .x10);
        ctx.em.movImm32(.x11, imm);
        ctx.em.put(encode(op, .x9, a, .x11));
        retire(ctx, rt, hook, .{ .imm = rs }, .{ .imm = imm });
    }
    ctx.endInline();
}

/// SLTI/SLTIU. Its hook reads nothing but the result.
fn setImm(ctx: *t.Ctx, cond: e.Cond, rt: u5, rs: u5, imm: u32) void {
    _ = ctx.beginInline(null, rt);
    if (rt != 0) {
        const a = ctx.src(rs, .x10);
        ctx.em.movImm32(.x11, imm);
        ctx.em.put(e.cmpReg(.w, a, .x11));
        ctx.em.put(e.cset(.w, .x9, cond));
        retire(ctx, rt, ops.exact, .{ .imm = rs }, .{ .imm = imm });
    }
    ctx.endInline();
}

fn lui(ctx: *t.Ctx, rt: u5, imm: u16) void {
    _ = ctx.beginInline(null, rt);
    if (rt != 0) {
        ctx.em.put(e.movz(.w, .x9, imm, 1));
        retire(ctx, rt, ops.exact, .{ .imm = 0 }, .{ .imm = imm });
    }
    ctx.endInline();
}

/// ADD, ADDI, SUB. On overflow nothing has been written and the slow path
/// runs the op's handler, which raises the exception and stops the block;
/// even a write to $zero can overflow, so these are always emitted.
fn checked(ctx: *t.Ctx, op: enum { add, sub }, rd: u5, rs: u5, b: Operand, comptime hook: anytype) void {
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
    const rt: u5 = switch (b) {
        .reg => |r| r,
        .imm => 0,
    };
    if (runs(ctx, rd, &.{ rs, rt })) retire(ctx, rd, hook, .{ .imm = rs }, switch (b) {
        .reg => |r| .{ .imm = r },
        .imm => |imm| .{ .imm = imm },
    });
    ctx.endInline();
    ctx.em.bind(slow.back);
}
