//! What the emitted code knows at compile time that memory does not hold
//! yet. `cached.runOp` leaves `Cpu.pipeline` and `Cpu.load_delay` current
//! after every instruction. An op emitted inline writes neither: it moves
//! this model on instead, and `sync` writes what `runOp` would have left
//! before anything reads them, which is a call, a slow path or the block's
//! end.
//!
//! The load delay is resolved here too. A load's value waits in x27 or x28,
//! by the parity of the op that issued it, and lands as the next op retires
//! unless that op writes the same register (`Cpu.writeReg` cancels it). The
//! block's entry counts as op -1: whatever `load_v` holds is a load to
//! $zero in flight, read into x28 by the prologue. A block entered with a
//! load to any other register runs through `.cached` (`jit.execute`).

const std = @import("std");
const e = @import("emit.zig");
const Emitter = @import("emitter.zig").Emitter;
const layout = @import("layout.zig");
const t = @import("translate.zig");

/// A load in flight: its target, and the register holding its value.
pub const Load = struct { rt: u5, value: e.Reg };

/// The register a load issued by op `i` keeps its value in. Entry is op -1,
/// so its value sits in x28.
pub fn loadReg(i: usize) e.Reg {
    return if (i % 2 == 0) .x27 else .x28;
}

pub const Model = struct {
    /// Memory lags the inline ops: `sync` must run before anything reads it.
    dirty: bool = false,
    /// The last op's PC, and whether it ran in a branch's delay slot. Its
    /// successor is then the branch target, which memory's `next_pc` holds:
    /// the branch wrote it, inline or as a call.
    pc: u32,
    delay_slot: bool = false,
    /// The load the last op issued: `load_r`/`load_v` after it.
    issued: ?Load = null,
    /// The load that landed as the last op retired: `delay_v` after it, and
    /// `delay_r` unless the last op's own write cancelled it.
    landed: ?Load = null,
    cancelled: bool = false,

    pub fn entry(start_pc: u32) Model {
        return .{ .pc = start_pc -% 4, .issued = .{ .rt = 0, .value = loadReg(1) } };
    }

    /// Op `i`, at `pc`, runs inline next. The load the last op issued lands
    /// as it retires. `issues` is its own load's target, if it is a load;
    /// `writes` the register it writes through `writeReg`.
    pub fn advance(m: *Model, i: usize, pc: u32, delay_slot: bool, issues: ?u5, writes: ?u5) void {
        m.landed = m.issued;
        m.cancelled = false;
        if (m.landed) |l| {
            if (writes) |w| m.cancelled = l.rt != 0 and w == l.rt;
        }
        m.issued = if (issues) |rt| .{ .rt = rt, .value = loadReg(i) } else null;
        m.pc = pc;
        m.delay_slot = delay_slot;
        m.dirty = true;
    }

    /// After a call to op `i`: memory is exact. A load it issued is read
    /// back into its register, where an inline successor expects it.
    pub fn afterCall(m: *Model, em: *Emitter, i: usize, pc: u32, delay_slot: bool, issues: ?u5) void {
        m.* = .{ .pc = pc, .delay_slot = delay_slot };
        if (issues) |rt| {
            m.issued = .{ .rt = rt, .value = loadReg(i) };
            em.put(e.memImm(.ldr_w, loadReg(i), t.cpu_reg, layout.load_v));
        }
    }

    /// The landed load's write-back, unless cancelled: `Cpu.retireLoad`.
    pub fn retire(m: *const Model, em: *Emitter) void {
        const l = m.landed orelse return;
        if (m.cancelled or l.rt == 0) return;
        em.put(e.memImm(.str_w, l.value, t.cpu_reg, layout.reg(l.rt)));
    }

    /// Writes the pipeline and the load delay as `runOp` would have left
    /// them after the last op, and marks memory exact. `branch_target`: the
    /// last op is a branch whose target is in that register (never x9).
    pub fn sync(m: *Model, em: *Emitter, branch_target: ?e.Reg) void {
        std.debug.assert(m.dirty);
        if (branch_target) |r| std.debug.assert(r != .x9);
        const cpu = t.cpu_reg;
        em.movImm32(.x9, m.pc);
        em.put(e.memImm(.str_w, .x9, cpu, layout.current_pc));
        if (branch_target) |target| {
            em.put(e.addImm(.w, .x9, .x9, 4));
            em.put(e.memImm(.str_w, .x9, cpu, layout.pc));
            em.put(e.memImm(.str_w, target, cpu, layout.next_pc));
        } else if (m.delay_slot) {
            em.put(e.memImm(.ldr_w, .x9, cpu, layout.next_pc));
            em.put(e.memImm(.str_w, .x9, cpu, layout.pc));
            em.put(e.addImm(.w, .x9, .x9, 4));
            em.put(e.memImm(.str_w, .x9, cpu, layout.next_pc));
        } else {
            em.put(e.addImm(.w, .x9, .x9, 4));
            em.put(e.memImm(.str_w, .x9, cpu, layout.pc));
            em.put(e.addImm(.w, .x9, .x9, 4));
            em.put(e.memImm(.str_w, .x9, cpu, layout.next_pc));
        }
        storeByte(em, @intFromBool(m.delay_slot), layout.is_delay_slot);
        storeByte(em, @intFromBool(branch_target != null), layout.next_is_delay_slot);
        storeByte(em, if (m.issued) |l| l.rt else 0, layout.load_r);
        em.put(e.memImm(.str_w, if (m.issued) |l| l.value else .zr, cpu, layout.load_v));
        const delay_r: u5 = if (m.landed) |l| (if (m.cancelled) 0 else l.rt) else 0;
        storeByte(em, delay_r, layout.delay_r);
        em.put(e.memImm(.str_w, if (m.landed) |l| l.value else .zr, cpu, layout.delay_v));
        m.dirty = false;
    }
};

fn storeByte(em: *Emitter, value: u8, offset: u32) void {
    if (value == 0) return em.put(e.memImm(.strb, .zr, t.cpu_reg, offset));
    em.put(e.movz(.w, .x9, value, 0));
    em.put(e.memImm(.strb, .x9, t.cpu_reg, offset));
}
