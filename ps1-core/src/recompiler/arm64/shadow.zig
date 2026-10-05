//! PGXP's shadows in emitted code, compiled only under PGXP
//! (`Options.pgxp`). A `Value` moves as whole words through w9. Its rules
//! stay in `exec.zig`; the shims below call them.

const e = @import("emit.zig");
const Emitter = @import("emitter.zig").Emitter;
const Value = @import("../../pgxp/pgxp.zig").Value;
const t = @import("translate.zig");
const layout = @import("layout.zig");
const model = @import("model.zig");
const Cpu = @import("../../cpu/cpu.zig").Cpu;
const exec = @import("../../cpu/exec.zig");

const words = @sizeOf(Value) / 4;

/// `[dst + dst_off] = [src + src_off]`, one `Value`. Clobbers w9.
pub fn copy(em: *Emitter, dst: e.Reg, dst_off: u32, src: e.Reg, src_off: u32) void {
    for (0..words) |k| {
        const o: u32 = @intCast(k * 4);
        em.put(e.memImm(.ldr_w, .x9, src, src_off + o));
        em.put(e.memImm(.str_w, .x9, dst, dst_off + o));
    }
}

/// `[base + off] = Value.none`, which is all zero bytes.
pub fn clear(em: *Emitter, base: e.Reg, off: u32) void {
    for (0..words) |k| em.put(e.memImm(.str_w, .zr, base, off + @as(u32, @intCast(k * 4))));
}

/// At an inline load's `done`: the shadow it issues, into its value's slot.
/// w9 still holds the address and `value` the loaded word, sign- or
/// zero-extended as the handler extends it.
pub fn afterLoad(ctx: *t.Ctx, width: u3, signed: bool, value: e.Reg) void {
    const em = ctx.em;
    const slot_off: u32 = @intCast(layout.pinsLoadShadow(model.slot(value)));
    // A byte keeps no shadow (`exec.loadShadow`): clear the slot, no call.
    if (width == 1) return clear(em, t.pins_reg, slot_off);
    em.put(e.movReg(.w, .x2, .x9));
    em.put(e.movReg(.x, .x0, t.cpu_reg));
    em.put(e.addImm(.x, .x1, t.pins_reg, @intCast(slot_off)));
    em.put(e.movReg(.w, .x3, value));
    em.put(e.movz(.w, .x4, @backingInt(sized(exec.LoadType, width)), 0));
    em.put(e.movz(.w, .x5, @intFromBool(signed), 0));
    em.call(@intFromPtr(&loadShim));
}

/// At an inline store's `done`, before the op retires: what the store does
/// to the shadows. A load landing in `rt` has not landed yet, so the store
/// carries `rt`'s old shadow, as it carries its old value. w9 still holds
/// the address.
pub fn afterStore(ctx: *t.Ctx, width: u3, rt: u5) void {
    const em = ctx.em;
    em.put(e.movReg(.w, .x1, .x9));
    em.put(e.movReg(.x, .x0, t.cpu_reg));
    em.put(e.movz(.w, .x2, rt, 0));
    em.put(e.movz(.w, .x3, @backingInt(sized(exec.StoreType, width)), 0));
    em.call(@intFromPtr(&storeShim));
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
