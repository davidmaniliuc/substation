//! The arm64 JIT (`.jit`): a block emitted as host code. In this skeleton
//! every op calls `cached.zig`'s per-instruction step, so it computes
//! exactly what `.cached` computes and shares its goldens (`trace-block/`).
//! See docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md.

const Cpu = @import("../cpu/cpu.zig").Cpu;
const block = @import("block.zig");
const cached = @import("cached.zig");

pub const emit = @import("arm64/emit.zig");
const code_buffer = @import("arm64/code_buffer.zig");
pub const CodeBuffer = code_buffer.CodeBuffer;
pub const available = code_buffer.available;
pub const translate = @import("arm64/translate.zig");

/// One MAP_JIT region (spec: Machinery). It is flushed whole when full.
pub const buffer_bytes: usize = 32 << 20;

/// Runs `b`'s host code from `cpu.pipeline.pc`, its start. Same contract
/// as `cached.execute`.
pub fn execute(cpu: *Cpu, b: *const block.Block, fetch_cost: u32) u32 {
    cached.begin(cpu);
    return b.code.?(cpu, fetch_cost);
}
