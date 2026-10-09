//! Block linking. A block that ends in a direct branch leaves through one
//! `bl` per outcome. Unlinked, the `bl` reaches `relink_stub`, which
//! records it and returns to the dispatcher; the dispatcher's next lookup
//! rewrites it to `bl` the target block's linked entry (`run.relink`), and
//! from then on the two blocks run back to back inside one `Cpu.runFor`.
//! A jump through a register looks its target up in the RAM table inline
//! (`lookup`) and enters the same linked entry.
//!
//! Skipping the dispatcher changes nothing it would have seen. A linked
//! block starts only while `downcount > 0` and fewer steps than the
//! budget have run, which is when the dispatcher would have started it
//! next. In between, interrupt state changes only at a device sync (an
//! MMIO access, which zeroes `downcount`) or at an MTC0 or RFE, and a block
//! holding either never links out. A DMA stall starts only at an MMIO
//! store or a deadline; SR.IsC only at an MTC0; and a block at 0xA0 or
//! 0xB0, whose TTY hook only the dispatcher runs, is never linked to.

const block = @import("../block.zig");
const e = @import("emit.zig");
const t = @import("translate.zig");
const layout = @import("layout.zig");

/// Installed once, right before `translate.return_stub`, which it falls
/// into: records the `bl` that came here and the PC it was leaving for.
/// It trusts `lr`, so only a `bl` may reach it (the lookup's `br` never
/// reaches a dropped block's entry, because `drop` clears its slot).
pub const relink_stub = [_]u32{
    e.subImm(.x, .x9, .lr, 4),
    e.memImm(.str_x, .x9, t.pins_reg, layout.pins_link_site),
    e.memImm(.ldr_w, .x9, t.cpu_reg, layout.pc),
    e.memImm(.str_w, .x9, t.pins_reg, layout.pins_link_pc),
};

/// A PC a block may link to: RAM entered through KUSEG or KSEG0, whose
/// fetch cost is the cached-hit 0, the same for every block that links;
/// and never 0xA0 or 0xB0.
pub fn isLinkPc(pc: u32) bool {
    const phys = pc & 0x1FFF_FFFF;
    return pc < 0xA000_0000 and block.regionOf(phys) == .ram and phys != 0xA0 and phys != 0xB0;
}

/// The block's linked entry, in the cold section, ending in a branch to
/// `ctx.body`. Its first word is the one `Jit.unlink` rewrites.
pub fn entry(ctx: *t.Ctx) t.Label {
    const em = ctx.em;
    const l = em.label();
    // A conditional branch reaches 1 MB, the return stub may be 32 MB away.
    const out = em.label();
    em.section = .cold;
    em.bind(l);
    em.put(e.memImm(.ldr_w, .x9, t.pins_reg, layout.pins_budget));
    em.put(e.cmpReg(.w, t.ran_reg, .x9));
    em.branch(.{ .cond = .hs }, .{ .label = out });
    em.put(e.memImm(.ldr_x, .x9, t.pins_reg, layout.pins_downcount));
    em.put(e.memImm(.ldr_x, .x9, .x9, 0));
    em.put(e.cmpImm(.x, .x9, 0));
    em.branch(.{ .cond = .le }, .{ .label = out });
    em.movImm64(.x9, @intFromPtr(ctx.b));
    em.put(e.memImm(.str_x, .x9, t.pins_reg, layout.pins_running));
    em.branch(.b, .{ .label = ctx.body });
    em.bind(out);
    em.branch(.b, .{ .address = ctx.return_stub });
    em.section = .hot;
    return l;
}

/// Whether this block's exits may link: the lowering allows it, the block
/// links at all, its delay slot is no branch (whose own delay slot the
/// dispatcher steps), and it holds no COP0 op. A load in the delay slot is
/// still in flight as the next block starts, which takes it over from
/// `load_r` (`model.zig`).
fn exitsLink(ctx: *const t.Ctx) bool {
    if (!ctx.opts.lower.link or !isLinkPc(ctx.b.start_pc)) return false;
    if (block.isBranch(ctx.b.ops[ctx.b.ops.len - 1].instr.raw)) return false;
    for (ctx.b.ops) |op| if (op.instr.i.opcode == 0x10) return false;
    return true;
}

/// The block's normal end, after the final commit: where it goes next.
pub fn exits(ctx: *t.Ctx) void {
    const em = ctx.em;
    switch (ctx.exit) {
        .direct => |d| if (exitsLink(ctx)) {
            const nt = d.not_taken orelse return site(ctx, d.taken);
            const not_taken = em.label();
            em.put(e.memImm(.ldr_w, .x9, t.cpu_reg, layout.pc));
            em.movImm32(.x10, d.taken);
            em.put(e.cmpReg(.w, .x9, .x10));
            em.branch(.{ .cond = .ne }, .{ .label = not_taken });
            site(ctx, d.taken);
            em.bind(not_taken);
            site(ctx, nt);
            return;
        },
        // The lookup's refusals fall through to the return below.
        .indirect => if (exitsLink(ctx)) lookup(ctx),
        .none => {},
    }
    em.branch(.b, .{ .address = ctx.return_stub });
}

/// JR, JALR: the target block from the RAM table, entered at its linked
/// entry if it has one and was compiled for exactly this PC; otherwise the
/// dispatcher. A dropped block is never found: dropping clears its slot.
/// Every refusal branches to the end, where `exits` returns: as in `entry`,
/// a conditional branch cannot reach the return stub itself.
fn lookup(ctx: *t.Ctx) void {
    const em = ctx.em;
    const out = em.label();
    const to: t.Target = .{ .label = out };
    em.put(e.memImm(.ldr_w, .x9, t.cpu_reg, layout.pc));
    em.put(e.shiftImm(.lsr, .x10, .x9, 29));
    em.put(e.cmpImm(.w, .x10, 5)); // KSEG1 and above
    em.branch(.{ .cond = .hs }, to);
    em.put(e.ubfx(.x10, .x9, 0, 29));
    em.put(e.shiftImm(.lsr, .x11, .x10, 23)); // past RAM and its mirrors
    em.branch(.{ .cbnz = .{ .w, .x11 } }, to);
    em.put(e.ubfx(.x11, .x10, 2, 19)); // the word within 2 MB
    em.put(e.memImm(.ldr_x, .x10, t.pins_reg, layout.pins_ram_blocks));
    em.put(e.memReg(.ldr_x, .x10, .x10, .x11, true));
    em.branch(.{ .cbz = .{ .x, .x10 } }, to);
    em.put(e.memImm(.ldr_w, .x11, .x10, layout.block_start_pc));
    em.put(e.cmpReg(.w, .x11, .x9));
    em.branch(.{ .cond = .ne }, to);
    // None at 0xA0 or 0xB0, or outside the cached segment: the dispatcher
    // runs the TTY hook.
    em.put(e.memImm(.ldr_x, .x10, .x10, layout.block_link_entry));
    em.branch(.{ .cbz = .{ .x, .x10 } }, to);
    em.put(e.br(.x10));
    em.bind(out);
}

/// One exit to a known PC: a `bl` the dispatcher rewrites to reach the
/// target's linked entry, or a plain return when it can never link.
fn site(ctx: *t.Ctx, target: u32) void {
    if (isLinkPc(target)) {
        ctx.em.branch(.bl, .{ .address = ctx.relink_stub });
    } else {
        ctx.em.branch(.b, .{ .address = ctx.return_stub });
    }
}
