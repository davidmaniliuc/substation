//! PGXP's shadows in emitted code, compiled only under PGXP
//! (`Options.pgxp`). A `Value` moves as whole words through w9. Word and
//! byte accesses move shadows through the tables inline; a half-word calls
//! its handler's rule, and the ALU's rules stay in `exec.zig` and `pgxp/`,
//! which the shims below call.

const std = @import("std");
const e = @import("emit.zig");
const Emitter = @import("emitter.zig").Emitter;
const Value = @import("../../pgxp/pgxp.zig").Value;
const t = @import("translate.zig");
const layout = @import("layout.zig");
const model = @import("model.zig");
const Cpu = @import("../../cpu/cpu.zig").Cpu;
const exec = @import("../../cpu/exec.zig");

const words = @sizeOf(Value) / 4;

/// `[dst + dst_off] = [src + src_off]`, one `Value`, through `via`.
pub fn copyVia(em: *Emitter, via: e.Reg, dst: e.Reg, dst_off: u32, src: e.Reg, src_off: u32) void {
    for (0..words) |k| {
        const o: u32 = @intCast(k * 4);
        em.put(e.memImm(.ldr_w, via, src, src_off + o));
        em.put(e.memImm(.str_w, via, dst, dst_off + o));
    }
}

/// `[dst + dst_off] = [src + src_off]`, one `Value`. Clobbers w9.
pub fn copy(em: *Emitter, dst: e.Reg, dst_off: u32, src: e.Reg, src_off: u32) void {
    copyVia(em, .x9, dst, dst_off, src, src_off);
}

/// x12 the slot, in the table at `table` (a `Pins` offset), of the word
/// holding byte `offset` of that table's memory: `Bus.shadowSlot`'s index
/// for RAM's first 2 MB and the scratchpad. Clobbers w13.
pub fn slotAddress(em: *Emitter, table: u32, offset: e.Reg) void {
    comptime std.debug.assert(@sizeOf(Value) == 20);
    em.put(e.memImm(.ldr_x, .x12, t.pins_reg, table));
    em.put(e.shiftImm(.lsr, .x13, offset, 2));
    em.put(e.addRegLsl(.w, .x13, .x13, .x13, 2)); // the word's index * 5
    em.put(e.addRegLsl(.x, .x12, .x12, .x13, 2)); // * 4: * 20 bytes
}

/// Whether an inline access of `width` bytes moves its shadow through the
/// table itself (`slotAddress`), or leaves it to a shim. A word load copies
/// its slot, and a word or byte store writes it. A byte load reads no
/// table, and a half-word access validates or merges halves in its shim.
pub fn usesSlot(load: bool, width: u3) bool {
    return if (load) width == 4 else width != 2;
}

/// `[base + off] = Value.none`, which is all zero bytes.
pub fn clear(em: *Emitter, base: e.Reg, off: u32) void {
    for (0..words) |k| em.put(e.memImm(.str_w, .zr, base, off + @as(u32, @intCast(k * 4))));
}

/// At an inline load's `done`: the shadow it issues, into its value's slot.
/// For a word x12 is the table slot (`slotAddress`). For a half w9 still
/// holds the address and `value` the loaded word, extended as the handler
/// extends it.
pub fn afterLoad(ctx: *t.Ctx, width: u3, signed: bool, value: e.Reg) void {
    const em = ctx.em;
    const slot_off: u32 = @intCast(layout.pinsLoadShadow(model.slot(value)));
    switch (width) {
        // A byte keeps no shadow (`exec.loadShadow`).
        1 => clear(em, t.pins_reg, slot_off),
        // `Bus.shadowLoad`: the word's shadow as the table holds it.
        4 => copy(em, t.pins_reg, slot_off, .x12, 0),
        // `Bus.shadowLoadHalf` validates and rewrites the slot: its shim.
        2 => {
            em.put(e.movReg(.w, .x2, .x9));
            em.put(e.movReg(.x, .x0, t.cpu_reg));
            em.put(e.addImm(.x, .x1, t.pins_reg, @intCast(slot_off)));
            em.put(e.movReg(.w, .x3, value));
            em.put(e.movz(.w, .x4, @backingInt(sized(exec.LoadType, width)), 0));
            em.put(e.movz(.w, .x5, @intFromBool(signed), 0));
            em.call(@intFromPtr(&loadShim));
        },
        else => unreachable,
    }
}

/// At an inline store's `done`, before the op retires: what the store does
/// to the shadows (`exec.storeShadow`). A load landing in `rt` has not
/// landed yet, so the store carries `rt`'s old shadow, as it carries its
/// old value. For a word or a byte x12 is the table slot (`slotAddress`);
/// for a half w9 still holds the address.
pub fn afterStore(ctx: *t.Ctx, width: u3, rt: u5) void {
    const em = ctx.em;
    switch (width) {
        // `rt`'s shadow to the slot and to the GP0 provenance.
        4 => {
            copy(em, .x12, 0, t.cpu_reg, layout.shadow(rt));
            em.put(e.memImm(.ldr_x, .x12, t.pins_reg, layout.pins_pgxp_pending));
            copy(em, .x12, 0, t.cpu_reg, layout.shadow(rt));
        },
        // The word's shadow destroyed, and the provenance dropped.
        1 => {
            clear(em, .x12, 0);
            em.put(e.memImm(.ldr_x, .x12, t.pins_reg, layout.pins_pgxp_pending));
            clear(em, .x12, 0);
        },
        // `Bus.shadowStoreHalf` merges one half: its shim.
        2 => {
            em.put(e.movReg(.w, .x1, .x9));
            em.put(e.movReg(.x, .x0, t.cpu_reg));
            em.put(e.movz(.w, .x2, rt, 0));
            em.put(e.movz(.w, .x3, @backingInt(sized(exec.StoreType, width)), 0));
            em.call(@intFromPtr(&storeShim));
        },
        else => unreachable,
    }
}

/// An operand a hook takes beside the result: a constant (a register's
/// number or an immediate) or a host register holding a value.
pub const Arg = union(enum) { imm: u32, reg: e.Reg };

/// An inline ALU op's result, in w9, retired through `hook` as its handler
/// retires it under CPU mode (`writeRegPrecise`). The hook reads its sources
/// before the destination is written, and the destination is often one of
/// them, so the shim writes the register as well as its shadow. `rd` may be
/// $zero: the hook still validates its sources.
pub fn hooked(ctx: *t.Ctx, comptime hook: anytype, rd: u5, a: Arg, b: Arg) void {
    const em = ctx.em;
    em.put(e.movReg(.w, .x3, .x9));
    put(em, .x1, a);
    put(em, .x2, b);
    em.put(e.movz(.w, .x4, rd, 0));
    em.put(e.movReg(.x, .x0, t.cpu_reg));
    em.call(@intFromPtr(&Hooked(hook).shim));
}

fn put(em: *Emitter, to: e.Reg, a: Arg) void {
    switch (a) {
        .imm => |v| em.movImm32(to, v),
        .reg => |r| em.put(e.movReg(.w, to, r)),
    }
}

fn sized(comptime T: type, width: u3) T {
    return switch (width) {
        1 => .Byte,
        2 => .Half,
        4 => .Word,
        else => unreachable,
    };
}

// What the emitted code calls: the handlers' own rules.

fn loadShim(cpu: *Cpu, slot: *Value, address: u32, value: u32, ltype: u32, signed: u32) callconv(.c) void {
    slot.* = exec.loadShadow(cpu, address, @fromBackingInt(@intCast(ltype)), value, signed != 0);
}

fn storeShim(cpu: *Cpu, address: u32, rt: u32, stype: u32) callconv(.c) void {
    exec.storeShadow(cpu, address, @intCast(rt), @fromBackingInt(@intCast(stype)));
}

/// One shim per hook, so the hook is a direct call. `b` is truncated rather
/// than cast: for a variable shift it is `rs`'s whole value, and the hook
/// takes the amount modulo 32, as the handler does.
fn Hooked(comptime hook: anytype) type {
    return struct {
        fn shim(cpu: *Cpu, a: u32, b: u32, result: u32, rd: u32) callconv(.c) void {
            const p = hook(cpu, @truncate(a), @truncate(b), result);
            if (rd == 0) return;
            cpu.regs[rd] = result;
            cpu.gpr_shadow[rd] = p;
        }
    };
}
