//! The cached interpreter: a block's words, decoded once into handler
//! calls. It has no instruction semantics of its own; every handler is
//! `exec.zig`'s, so a fix to an instruction fixes it here too.
//!
//! Gone per instruction, compared with `Cpu.step()`: the DMA-stall check,
//! the fetch bus-error check, the I-cache, the Cause.IP2 update and the
//! scheduler tick. The dispatcher does those once per block.

const Cpu = @import("../cpu/cpu.zig").Cpu;
const Block = @import("block.zig").Block;

/// Runs `b` from `cpu.pipeline.pc`, its start. Each instruction costs 1
/// plus `fetch_cost` plus its load/store wait states, as in the interpreter
/// with the I-cache replaced by a static fetch cost. Returns the
/// instructions it ran: an exception or a `block_exit` stops it early.
pub fn execute(cpu: *Cpu, b: *const Block, fetch_cost: u32) u32 {
    const bus = cpu.bus;
    cpu.exception_taken = false;
    bus.block_exit = false;
    // Charged but not yet handed to the scheduler.
    var cycles: u32 = 0;
    var steps: u32 = 0;
    var ran: u32 = 0;
    for (b.ops) |op| {
        cycles += 1 + fetch_cost;
        if (op.memory) {
            // An MMIO access syncs the devices. Hand them this block's
            // cycles so far, up to and including this fetch. This
            // instruction's step counts after its access, as the
            // interpreter counts it: a JOY_TX store arms /ACK before its own
            // step ticks it.
            cpu.chargeCycles(cycles + bus.wait_cycles, steps);
            bus.wait_cycles = 0;
            cycles = 0;
            steps = 0;
        }
        cpu.pipeline.current_pc = cpu.pipeline.pc;
        cpu.beginInstruction();
        op.handler(cpu, op.instr);
        cpu.retireLoad();
        steps += 1;
        ran += 1;
        if (cpu.exception_taken or bus.block_exit) break;
    }
    cpu.chargeCycles(cycles + bus.wait_cycles, steps);
    bus.wait_cycles = 0;
    return ran;
}
