//! A block as arm64 code: an op the JIT lowers inline, every other op a call
//! to `cached.runOp` with the block's own `Op`, so `.jit` executes exactly
//! what `.cached` executes. What `cached.execute` does per instruction is
//! resolved at compile time: the cycle and step counts (`pending` and the
//! commit formulas below) and the pipeline and load delay (`model.zig`).
//!
//! Registers for the whole block, callee-saved so a call keeps them:
//!   x19 `*Cpu`; x20 RAM; x21 the scratchpad; x22 the cache's `Pins`;
//!   w23 one instruction's cycles, 1 + the fetch cost;
//!   w24, w25 the cycle adjustment and the commit base (`commitMid`);
//!   w26 the instructions this call has run, less `Ctx.pending`;
//!   x27, x28 the values of loads in flight.
//! Scratch within one op: w9-w13, and x16 for a call's target.

const std = @import("std");
const block = @import("../block.zig");
const cached = @import("../cached.zig");
const Pins = @import("../cache.zig").Pins;
const jit = @import("../jit.zig");
const Cpu = @import("../../cpu/cpu.zig").Cpu;
const e = @import("emit.zig");
const emitter = @import("emitter.zig");
pub const Emitter = emitter.Emitter;
const layout = @import("layout.zig");
const model = @import("model.zig");
const Model = model.Model;
const lower_alu = @import("lower_alu.zig");
const lower_branch = @import("lower_branch.zig");
const lower_memory = @import("lower_memory.zig");

pub const cpu_reg: e.Reg = .x19;
pub const ram_reg: e.Reg = .x20;
pub const scratch_reg: e.Reg = .x21;
pub const pins_reg: e.Reg = .x22;
const cost_reg: e.Reg = .x23;
pub const adjust_reg: e.Reg = .x24;
const base_reg: e.Reg = .x25;
pub const ran_reg: e.Reg = .x26;
const frame_bytes = 96;

/// Every block leaves through here: returns the instructions the call ran
/// and unwinds the frame `prologue` built.
pub const return_stub = [_]u32{
    e.movReg(.w, .x0, ran_reg),
    e.ldp(.signed_offset, .x27, .x28, .sp, 80),
    e.ldp(.signed_offset, .x25, .x26, .sp, 64),
    e.ldp(.signed_offset, .x23, .x24, .sp, 48),
    e.ldp(.signed_offset, .x21, .x22, .sp, 32),
    e.ldp(.signed_offset, .x19, .x20, .sp, 16),
    e.ldp(.post_index, .fp, .lr, .sp, frame_bytes),
    e.ret(),
};

pub const Options = struct {
    lower: jit.Lowering,
};

/// An inline op's way out: `entry` is where its hot code branches, and the
/// cold code comes back to `back`, which the op binds after `endInline`.
pub const Slow = struct { entry: emitter.Label, back: emitter.Label };

pub const Ctx = struct {
    em: *Emitter,
    b: *const block.Block,
    opts: Options,
    return_stub: usize,
    /// The op being emitted.
    i: usize = 0,
    /// Ops emitted inline whose count w26 does not include yet.
    pending: u32 = 0,
    /// Ops emitted as calls (`Block.calls`).
    calls: u32 = 0,
    model: Model,
    /// The stop tail: a call's op raised an exception or set `block_exit`.
    stop: emitter.Label,

    pub fn op(ctx: *const Ctx) *const block.Op {
        return &ctx.b.ops[ctx.i];
    }

    pub fn pc(ctx: *const Ctx) u32 {
        return ctx.b.start_pc +% @as(u32, @intCast(ctx.i)) * 4;
    }

    pub fn isDelaySlot(ctx: *const Ctx) bool {
        return ctx.i > 0 and block.isBranch(ctx.b.ops[ctx.i - 1].instr.raw);
    }

    /// Guest register `r`, loaded into `into`. $zero reads as the zero
    /// register, which only the register forms of an instruction accept.
    pub fn src(ctx: *Ctx, r: u5, into: e.Reg) e.Reg {
        if (r == 0) return .zr;
        ctx.em.put(e.memImm(.ldr_w, into, cpu_reg, layout.reg(r)));
        return into;
    }

    /// Stores `from` to guest register `r`. A write to $zero is dropped.
    pub fn dst(ctx: *Ctx, r: u5, from: e.Reg) void {
        if (r == 0) return;
        ctx.em.put(e.memImm(.str_w, from, cpu_reg, layout.reg(r)));
    }

    /// Starts the op inline. Returns the model as it stood before it, which
    /// a slow path syncs from. `issues`: the load target it issues;
    /// `writes`: the register it writes through `writeReg`.
    pub fn beginInline(ctx: *Ctx, issues: ?u5, writes: ?u5) Model {
        const before = ctx.model;
        ctx.model.advance(ctx.i, ctx.pc(), ctx.isDelaySlot(), issues, writes);
        return before;
    }

    /// Ends the op inline: the landed load retires, and the op counts.
    pub fn endInline(ctx: *Ctx) void {
        ctx.model.retire(ctx.em);
        ctx.pending += 1;
    }

    /// Ends a branch inline: the landed load retires, then memory takes the
    /// branch's whole state, with its target in `target`.
    pub fn endBranch(ctx: *Ctx, target: e.Reg) void {
        ctx.model.retire(ctx.em);
        ctx.model.sync(ctx.em, target);
        ctx.pending += 1;
    }

    /// The op's slow path, in the cold section: memory brought to the state
    /// before the op, then the op as a call, exactly as `emitCall` runs it.
    /// Call it after `beginInline`.
    pub fn slowPath(ctx: *Ctx, before: Model) Slow {
        const em = ctx.em;
        const s: Slow = .{ .entry = em.label(), .back = em.label() };
        em.section = .cold;
        em.bind(s.entry);
        var m = before;
        if (m.dirty) m.sync(em, null);
        const counted: u12 = @intCast(ctx.pending + 1);
        em.put(e.addImm(.w, ran_reg, ran_reg, counted));
        if (ctx.op().memory) commitMid(em);
        callRunOp(ctx);
        // Back on the hot path, which counts this op among `pending`.
        em.put(e.subImm(.w, ran_reg, ran_reg, counted));
        // The hot path still owes this op's sync, and for an op in a delay
        // slot that sync is relative: it moves `next_pc`, the branch
        // target, into `pc`. The call already did, so hand it back.
        if (ctx.model.delay_slot) {
            em.put(e.memImm(.ldr_w, .x9, cpu_reg, layout.pc));
            em.put(e.memImm(.str_w, .x9, cpu_reg, layout.next_pc));
        }
        if (ctx.model.issued) |l| em.put(e.memImm(.ldr_w, l.value, cpu_reg, layout.load_v));
        em.branch(.b, .{ .label = s.back });
        em.section = .hot;
        return s;
    }
};

/// Emits `b`, installs it in `j`'s buffer and sets `b.code`,
/// `b.code_words` and `b.calls`.
pub fn compile(j: *jit.Jit, pins: *Pins, b: *block.Block, opts: Options) error{CodeBufferFull}!void {
    std.debug.assert(b.ops.len <= block.max_len + 1);
    const em = &j.em;
    em.reset();
    var ctx: Ctx = .{
        .em = em,
        .b = b,
        .opts = opts,
        .return_stub = j.return_stub,
        .model = .entry(b.start_pc),
        .stop = em.label(),
    };
    prologue(&ctx, pins);
    while (ctx.i < b.ops.len) : (ctx.i += 1) emitOp(&ctx);
    end(&ctx);
    const code = em.finish(j.buf.cursor());
    const entry: block.JitEntry = @ptrCast(try j.buf.install(code));
    b.code = entry;
    b.code_words = @intCast(code.len);
    b.calls = ctx.calls;
}

const Family = enum { alu, branch, load, other };

fn family(raw: u32) Family {
    return switch (raw >> 26) {
        0x00 => switch (raw & 0x3F) {
            0x00, 0x02, 0x03, 0x04, 0x06, 0x07, 0x20...0x27, 0x2A, 0x2B => .alu,
            0x08, 0x09 => .branch,
            else => .other,
        },
        0x01...0x07 => .branch,
        0x08...0x0F => .alu,
        0x20...0x26 => .load,
        else => .other,
    };
}

fn emitOp(ctx: *Ctx) void {
    const lower = ctx.opts.lower;
    const lowered = switch (family(ctx.op().instr.raw)) {
        .alu => lower.alu and lower_alu.emit(ctx),
        .branch => lower.branch and lower_branch.emit(ctx),
        .load => lower.load and lower_memory.emitLoad(ctx),
        .other => false,
    };
    if (!lowered) emitCall(ctx);
}

fn prologue(ctx: *Ctx, pins: *Pins) void {
    const em = ctx.em;
    em.put(e.stp(.pre_index, .fp, .lr, .sp, -frame_bytes));
    em.put(e.addImm(.x, .fp, .sp, 0));
    em.put(e.stp(.signed_offset, .x19, .x20, .sp, 16));
    em.put(e.stp(.signed_offset, .x21, .x22, .sp, 32));
    em.put(e.stp(.signed_offset, .x23, .x24, .sp, 48));
    em.put(e.stp(.signed_offset, .x25, .x26, .sp, 64));
    em.put(e.stp(.signed_offset, .x27, .x28, .sp, 80));
    em.put(e.movReg(.x, cpu_reg, .x0));
    em.put(e.addImm(.w, cost_reg, .x1, 1));
    em.movImm64(pins_reg, @intFromPtr(pins));
    em.put(e.ldp(.signed_offset, ram_reg, scratch_reg, pins_reg, layout.pins_ram));
    em.put(e.movz(.w, ran_reg, 0, 0));
    // Everything above holds for the whole call, everything below for this
    // block.
    em.put(e.movz(.w, adjust_reg, 0, 0));
    em.put(e.movReg(.w, base_reg, ran_reg));
    em.put(e.memImm(.ldr_w, model.loadReg(1), cpu_reg, layout.load_v));
}

/// The op as a call to `cached.runOp`, as `cached.execute` runs it.
fn emitCall(ctx: *Ctx) void {
    const em = ctx.em;
    ctx.calls += 1;
    if (ctx.model.dirty) ctx.model.sync(em, null);
    countThrough(ctx);
    if (ctx.op().memory) commitMid(em);
    callRunOp(ctx);
    ctx.model.afterCall(em, ctx.i, ctx.pc(), ctx.isDelaySlot(), block.issuesLoad(ctx.op().instr.raw));
}

fn callRunOp(ctx: *Ctx) void {
    const em = ctx.em;
    em.put(e.movReg(.x, .x0, cpu_reg));
    em.movImm64(.x1, @intFromPtr(ctx.op()));
    em.call(@intFromPtr(&opShim));
    em.branch(.{ .cbnz = .{ .w, .x0 } }, .{ .label = ctx.stop });
}

/// Brings w26 up to date and counts the op about to run: a stop after it
/// returns it as run, as `cached.execute` counts it.
fn countThrough(ctx: *Ctx) void {
    ctx.em.put(e.addImm(.w, ran_reg, ran_reg, @intCast(ctx.pending + 1)));
    ctx.pending = 0;
}

/// Before a load or store's call, which may sync the devices: hands the
/// scheduler what `cached.execute`'s commit hands it, the cycles of every op
/// since the last commit with this one's fetch included, and the steps of
/// those before it. w26 already counts this op, so with `n = w26 - w25`:
///   cycles = n * w23 + w24, steps = n - 1.
/// The base then moves to just before this op and w24 to -w23: the next
/// commit counts from the op after this one, whose fetch was not paid here.
fn commitMid(em: *Emitter) void {
    em.put(e.subReg(.w, .x9, ran_reg, base_reg));
    em.put(e.madd(.w, .x1, .x9, cost_reg, adjust_reg));
    em.put(e.subImm(.w, .x2, .x9, 1));
    em.put(e.subImm(.w, base_reg, ran_reg, 1));
    em.put(e.neg(.w, adjust_reg, cost_reg));
    em.put(e.movReg(.x, .x0, cpu_reg));
    em.call(@intFromPtr(&commitShim));
}

/// At the block's end: `n * w23 + w24` cycles over `n` steps, every op
/// since the last commit.
fn commitFinal(em: *Emitter) void {
    em.put(e.subReg(.w, .x2, ran_reg, base_reg));
    em.put(e.madd(.w, .x1, .x2, cost_reg, adjust_reg));
    em.put(e.movReg(.x, .x0, cpu_reg));
    em.call(@intFromPtr(&commitShim));
}

fn end(ctx: *Ctx) void {
    const em = ctx.em;
    if (ctx.pending > 0) em.put(e.addImm(.w, ran_reg, ran_reg, @intCast(ctx.pending)));
    if (ctx.model.dirty) ctx.model.sync(em, null);
    commitFinal(em);
    em.branch(.b, .{ .address = ctx.return_stub });
    // The stop tail: memory is exactly as the stopping op's call left it.
    em.section = .cold;
    em.bind(ctx.stop);
    commitFinal(em);
    em.branch(.b, .{ .address = ctx.return_stub });
    em.section = .hot;
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
