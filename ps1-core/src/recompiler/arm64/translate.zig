//! A block as arm64 code. In this skeleton every instruction is a call to
//! `cached.runOp` with the block's own `Op`, so `.jit` executes exactly what
//! `.cached` executes. The emitted code owns the control flow and the cycle
//! accounting, and does both as `cached.execute` does, op for op.
//!
//! Registers, for the whole block, all callee-saved so the calls keep them:
//! x19 `*Cpu`; w23 one instruction's cost (1 + the fetch cost); w24 the
//! cycles and w25 the steps not yet committed; w26 the instructions run.

const std = @import("std");
const block = @import("../block.zig");
const cached = @import("../cached.zig");
const Cpu = @import("../../cpu/cpu.zig").Cpu;
const CodeBuffer = @import("code_buffer.zig").CodeBuffer;
const e = @import("emit.zig");

const cpu_reg: e.Reg = .x19;
const cost_reg: e.Reg = .x23;
const cycles_reg: e.Reg = .x24;
const steps_reg: e.Reg = .x25;
const ran_reg: e.Reg = .x26;
/// IP0, the intra-procedure-call scratch register: holds a call's target.
const call_reg: e.Reg = .x16;

// Every piece has a fixed size, so the scratch buffer's bound is exact.
const prologue_words = 10;
const call_words = 5; // a 64-bit address, blr
const commit_words = 3 + call_words; // three argument moves
const op_words = 1 + 1 + 4 + call_words + 3; // cost, cpu, op address, call, counts + cbnz
const memory_words = commit_words + 2; // and zero the two counters
const epilogue_words = commit_words + 6; // result, four ldp, ret
pub const max_words = prologue_words + (block.max_len + 1) * (op_words + memory_words) + epilogue_words;

const Emitter = struct {
    words: [max_words]u32 = undefined,
    len: usize = 0,

    fn put(self: *Emitter, word: u32) void {
        self.words[self.len] = word;
        self.len += 1;
    }

    /// Always four words, whatever the value.
    fn movImm64(self: *Emitter, rd: e.Reg, value: u64) void {
        self.put(e.movz(.x, rd, @truncate(value), 0));
        self.put(e.movk(.x, rd, @truncate(value >> 16), 1));
        self.put(e.movk(.x, rd, @truncate(value >> 32), 2));
        self.put(e.movk(.x, rd, @truncate(value >> 48), 3));
    }

    fn call(self: *Emitter, target: usize) void {
        self.movImm64(call_reg, target);
        self.put(e.blr(call_reg));
    }

    /// `commitShim(cpu, cycles, steps)`.
    fn commit(self: *Emitter) void {
        self.put(e.movReg(.x, .x0, cpu_reg));
        self.put(e.movReg(.w, .x1, cycles_reg));
        self.put(e.movReg(.w, .x2, steps_reg));
        self.call(@intFromPtr(&commitShim));
    }
};

/// Emits `b` and installs it in `buf`.
pub fn compile(buf: *CodeBuffer, b: *const block.Block) error{CodeBufferFull}!block.JitEntry {
    std.debug.assert(b.ops.len <= block.max_len + 1);
    var em: Emitter = .{};

    em.put(e.stp(.pre_index, .fp, .lr, .sp, -64));
    em.put(e.addImm(.x, .fp, .sp, 0));
    em.put(e.stp(.signed_offset, .x19, .x20, .sp, 16));
    em.put(e.stp(.signed_offset, .x23, .x24, .sp, 32));
    em.put(e.stp(.signed_offset, .x25, .x26, .sp, 48));
    em.put(e.movReg(.x, cpu_reg, .x0));
    em.put(e.addImm(.w, cost_reg, .x1, 1));
    em.put(e.movz(.w, cycles_reg, 0, 0));
    em.put(e.movz(.w, steps_reg, 0, 0));
    em.put(e.movz(.w, ran_reg, 0, 0));

    // Each op's stop branch, patched once the epilogue's position is known.
    var stops: [block.max_len + 1]usize = undefined;
    for (b.ops, 0..) |*op, i| {
        em.put(e.addReg(.w, cycles_reg, cycles_reg, cost_reg));
        if (op.memory) {
            em.commit();
            em.put(e.movz(.w, cycles_reg, 0, 0));
            em.put(e.movz(.w, steps_reg, 0, 0));
        }
        em.put(e.movReg(.x, .x0, cpu_reg));
        em.movImm64(.x1, @intFromPtr(op));
        em.call(@intFromPtr(&opShim));
        em.put(e.addImm(.w, steps_reg, steps_reg, 1));
        em.put(e.addImm(.w, ran_reg, ran_reg, 1));
        stops[i] = em.len;
        em.put(0); // cbnz w0, epilogue
    }

    const epilogue = em.len;
    for (stops[0..b.ops.len]) |at| em.words[at] = e.cbnz(.w, .x0, @intCast((epilogue - at) * 4));
    em.commit();
    em.put(e.movReg(.w, .x0, ran_reg));
    em.put(e.ldp(.signed_offset, .x25, .x26, .sp, 48));
    em.put(e.ldp(.signed_offset, .x23, .x24, .sp, 32));
    em.put(e.ldp(.signed_offset, .x19, .x20, .sp, 16));
    em.put(e.ldp(.post_index, .fp, .lr, .sp, 64));
    em.put(e.ret());

    return @ptrCast(try buf.install(em.words[0..em.len]));
}

// What the emitted code calls. Thin on purpose: the semantics are
// `cached.zig`'s. `u32` rather than `bool`, so `cbnz w0` reads a defined
// register whatever the ABI leaves above the low byte.

fn opShim(cpu: *Cpu, op: *const block.Op) callconv(.c) u32 {
    return @intFromBool(cached.runOp(cpu, op));
}

fn commitShim(cpu: *Cpu, cycles: u32, steps: u32) callconv(.c) void {
    cached.commit(cpu, cycles, steps);
}
