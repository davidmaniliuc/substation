//! Loads and stores, inline for the first 2 MB of RAM and for the
//! scratchpad. Anything else (I/O, the BIOS, the RAM mirrors, which cost
//! other wait states) and any misaligned address takes the slow path: the
//! op's own `exec.zig` handler through `Bus`, after a commit, exactly as a
//! call would run it. An inline access bills what `Bus.waitCycles` would.
//!
//! Under PGXP each inline access then runs its handler's shadow rule
//! through a shim (`shadow.afterLoad`/`afterStore`); the slow path never
//! reaches it, so the rule runs once.
//!
//! No access here can meet an isolated cache: a block never runs while
//! SR.IsC is set (`run.zig`), and the MTC0 that sets it ends one.

const block = @import("../block.zig");
const e = @import("emit.zig");
const t = @import("translate.zig");
const Bus = @import("../../memory.zig").Bus;
const Instruction = @import("../../cpu/exec.zig").Instruction;
const sext16 = @import("../../bits.zig").sext16;
const shadow = @import("shadow.zig");

/// Physical addresses below this are RAM's first 2 MB.
const ram_bits = 21;
const scratchpad_base: u32 = 0x1F80_0000;
const scratchpad_bytes = 0x400;

const Form = struct { op: e.MemReg, width: u3 };

/// False, having emitted nothing, for an op this file does not lower.
pub fn emitLoad(ctx: *t.Ctx) bool {
    const in = ctx.op().instr;
    const form: Form = switch (in.i.opcode) {
        0x20 => .{ .op = .ldrsb, .width = 1 },
        0x21 => .{ .op = .ldrsh, .width = 2 },
        0x23 => .{ .op = .ldr_w, .width = 4 },
        0x24 => .{ .op = .ldrb, .width = 1 },
        0x25 => .{ .op = .ldrh, .width = 2 },
        else => return false, // LWL, LWR
    };
    const em = ctx.em;
    const before = ctx.beginInline(in.i.rt, null);
    const slow = ctx.slowPath(before);
    const value = ctx.model.issued.?.value;
    const done = em.label();
    const not_ram = em.label();
    address(ctx, in, form.width, slow);
    em.branch(.{ .cbnz = .{ .w, .x11 } }, .{ .label = not_ram });
    em.put(e.memReg(form.op, value, t.ram_reg, .x10, false));
    em.put(e.addImm(.w, t.adjust_reg, t.adjust_reg, Bus.ram_access_wait));
    em.bind(done);
    if (ctx.opts.pgxp != .off) shadow.afterLoad(ctx, form.width, form.op == .ldrsb or form.op == .ldrsh, value);
    ctx.endInline();
    em.bind(slow.back);

    em.section = .cold;
    em.bind(not_ram);
    scratchpadOffset(em, slow);
    em.put(e.memReg(form.op, value, t.scratch_reg, .x11, false));
    em.branch(.b, .{ .label = done });
    em.section = .hot;
    return true;
}

/// False, having emitted nothing, for an op this file does not lower.
pub fn emitStore(ctx: *t.Ctx) bool {
    // Lockstep's journal records the old word under every RAM store, and
    // sees only stores through `Bus.write`.
    if (!ctx.opts.store_fast) return false;
    const in = ctx.op().instr;
    const form: Form = switch (in.i.opcode) {
        0x28 => .{ .op = .strb, .width = 1 },
        0x29 => .{ .op = .strh, .width = 2 },
        0x2B => .{ .op = .str_w, .width = 4 },
        else => return false, // SWL, SWR
    };
    const em = ctx.em;
    const before = ctx.beginInline(null, null);
    const slow = ctx.slowPath(before);
    const done = em.label();
    const not_ram = em.label();
    address(ctx, in, form.width, slow);
    em.branch(.{ .cbnz = .{ .w, .x11 } }, .{ .label = not_ram });
    // A page holding a block: the slow path's `Bus.write` drops its blocks,
    // and ends this one if it was among them.
    em.put(e.shiftImm(.lsr, .x11, .x10, block.page_shift));
    em.put(e.shiftImm(.lsr, .x12, .x11, 6));
    em.put(e.memReg(.ldr_x, .x12, t.pins_reg, .x12, true));
    em.put(e.shiftReg(.x, .lsr, .x12, .x12, .x11));
    em.branch(.{ .tbnz = .{ .x12, 0 } }, .{ .label = slow.entry });
    // The value is read after the address, from `cpu.regs`: a load landing
    // in it retires only at `endInline`, so the store takes the old value,
    // as the interpreter's does.
    em.put(e.memReg(form.op, ctx.src(in.i.rt, .x13), t.ram_reg, .x10, false));
    em.put(e.addImm(.w, t.adjust_reg, t.adjust_reg, Bus.ram_access_wait));
    em.bind(done);
    if (ctx.opts.pgxp != .off) shadow.afterStore(ctx, form.width, in.i.rt);
    ctx.endInline();
    em.bind(slow.back);

    em.section = .cold;
    em.bind(not_ram);
    scratchpadOffset(em, slow);
    em.put(e.memReg(form.op, ctx.src(in.i.rt, .x13), t.scratch_reg, .x11, false));
    em.branch(.b, .{ .label = done });
    em.section = .hot;
    return true;
}

/// w9 the effective address, w10 its physical address, w11 the bits above
/// RAM's first 2 MB (zero for RAM). A misaligned address goes to `slow`.
pub fn address(ctx: *t.Ctx, in: Instruction, width: u3, slow: t.Slow) void {
    const em = ctx.em;
    const offset = sext16(in.i.imm);
    if (in.i.rs == 0) {
        em.movImm32(.x9, offset);
    } else {
        _ = ctx.src(in.i.rs, .x9);
        const signed: i32 = @bitCast(offset);
        if (signed > 0 and signed < 4096) {
            em.put(e.addImm(.w, .x9, .x9, @intCast(signed)));
        } else if (signed < 0 and signed > -4096) {
            em.put(e.subImm(.w, .x9, .x9, @intCast(-signed)));
        } else if (signed != 0) {
            em.movImm32(.x11, offset);
            em.put(e.addReg(.w, .x9, .x9, .x11));
        }
    }
    if (width >= 2) em.branch(.{ .tbnz = .{ .x9, 0 } }, .{ .label = slow.entry });
    if (width == 4) em.branch(.{ .tbnz = .{ .x9, 1 } }, .{ .label = slow.entry });
    em.put(e.ubfx(.x10, .x9, 0, 29));
    em.put(e.shiftImm(.lsr, .x11, .x10, ram_bits));
}

/// For a physical address in w10 outside RAM: w11 its scratchpad offset, or
/// a branch to `slow` when it is outside the scratchpad too.
pub fn scratchpadOffset(em: *t.Emitter, slow: t.Slow) void {
    em.put(e.movz(.w, .x11, scratchpad_base >> 16, 1));
    em.put(e.subReg(.w, .x11, .x10, .x11));
    em.put(e.cmpImm(.w, .x11, scratchpad_bytes));
    em.branch(.{ .cond = .hs }, .{ .label = slow.entry });
}
