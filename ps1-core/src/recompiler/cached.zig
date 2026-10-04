//! The cached interpreter: a block's words, decoded once into handler
//! calls. It has no instruction semantics of its own; every handler is
//! `exec.zig`'s, so a fix to an instruction fixes it here too.
//!
//! Gone per instruction, compared with `Cpu.step()`: the DMA-stall check,
//! the fetch bus-error check, the I-cache, the Cause.IP2 update and the
//! scheduler tick. The dispatcher does those once per block.
//!
//! `begin`, `commit` and `runOp` are the JIT's too: its emitted code calls
//! them where this loop does, which is what makes `.jit` equal `.cached`.

const Cpu = @import("../cpu/cpu.zig").Cpu;
const block = @import("block.zig");
const Block = block.Block;

/// Runs `b` from `cpu.pipeline.pc`, its start. Each instruction costs 1
/// plus `fetch_cost` plus its load/store wait states, as in the interpreter
/// with the I-cache replaced by a static fetch cost. Returns the
/// instructions it ran: an exception or a `block_exit` stops it early.
pub fn execute(cpu: *Cpu, b: *const Block, fetch_cost: u32) u32 {
    begin(cpu);
    // Charged but not yet handed to the scheduler.
    var cycles: u32 = 0;
    var steps: u32 = 0;
    var ran: u32 = 0;
    for (b.ops) |*op| {
        cycles += 1 + fetch_cost;
        if (op.memory) {
            // An MMIO access syncs the devices. Hand them this block's
            // cycles so far, up to and including this fetch. This
            // instruction's step counts after its access, as the
            // interpreter counts it: a JOY_TX store arms /ACK before its own
            // step ticks it.
            commit(cpu, cycles, steps);
            cycles = 0;
            steps = 0;
        }
        const stop = runOp(cpu, op);
        steps += 1;
        ran += 1;
        if (stop) break;
    }
    commit(cpu, cycles, steps);
    return ran;
}

/// Clears the two flags a block stops on. Before every block.
pub inline fn begin(cpu: *Cpu) void {
    cpu.exception_taken = false;
    cpu.bus.block_exit = false;
}

/// Hands the scheduler `cycles` spanning `steps` instructions, plus the
/// wait states their loads and stores billed.
pub inline fn commit(cpu: *Cpu, cycles: u32, steps: u32) void {
    cpu.chargeCycles(cycles + cpu.bus.wait_cycles, steps);
    cpu.bus.wait_cycles = 0;
}

/// One instruction of a block. True when the block must stop after it: it
/// raised an exception, or a store set `block_exit`.
pub inline fn runOp(cpu: *Cpu, op: *const block.Op) bool {
    cpu.pipeline.current_pc = cpu.pipeline.pc;
    cpu.beginInstruction();
    op.handler(cpu, op.instr);
    cpu.retireLoad();
    return cpu.exception_taken or cpu.bus.block_exit;
}
