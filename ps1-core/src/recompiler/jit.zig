//! The arm64 JIT (`.jit`): a block emitted as host code; it computes
//! exactly what `.cached` computes and shares its goldens (`trace-block/`).
//! See docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md.

const std = @import("std");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const block = @import("block.zig");
const cached = @import("cached.zig");

pub const emit = @import("arm64/emit.zig");
pub const emitter = @import("arm64/emitter.zig");
const code_buffer = @import("arm64/code_buffer.zig");
pub const CodeBuffer = code_buffer.CodeBuffer;
pub const available = code_buffer.available;
pub const translate = @import("arm64/translate.zig");

/// One MAP_JIT region (spec: Machinery). It is flushed whole when full.
pub const buffer_bytes: usize = 32 << 20;

/// What the JIT keeps beside the block cache: its code memory, the emitter a
/// compile builds in, and the stub every block returns through. Heap-only:
/// the emitter alone is about 100 KB.
pub const Jit = struct {
    buf: CodeBuffer,
    em: emitter.Emitter = .{},
    return_stub: usize = 0,

    /// Fails with `EngineUnavailable` when MAP_JIT is refused.
    pub fn create(allocator: std.mem.Allocator, bytes: usize) error{ OutOfMemory, EngineUnavailable }!*Jit {
        const j = try allocator.create(Jit);
        errdefer allocator.destroy(j);
        j.* = .{ .buf = CodeBuffer.init(bytes) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.EngineUnavailable,
        } };
        // A fresh buffer has room for the stubs.
        j.return_stub = @intFromPtr(j.buf.install(&translate.return_stub) catch unreachable);
        j.buf.pin();
        return j;
    }

    pub fn destroy(j: *Jit, allocator: std.mem.Allocator) void {
        j.buf.deinit();
        allocator.destroy(j);
    }
};

/// Runs `b`'s host code from `cpu.pipeline.pc`, its start. Same contract
/// as `cached.execute`.
pub fn execute(cpu: *Cpu, b: *const block.Block, fetch_cost: u32) u32 {
    cached.begin(cpu);
    return b.code.?(cpu, fetch_cost);
}
