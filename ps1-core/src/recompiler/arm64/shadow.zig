//! PGXP's shadows in emitted code, compiled only under PGXP
//! (`Options.pgxp`). A `Value` moves as whole words through w9. Its rules
//! stay in `exec.zig`; the shims below call them.

const e = @import("emit.zig");
const Emitter = @import("emitter.zig").Emitter;
const Value = @import("../../pgxp/pgxp.zig").Value;

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
