//! The arm64 JIT (`.jit`): a block emitted as host code. See
//! docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md.

pub const emit = @import("arm64/emit.zig");

const code_buffer = @import("arm64/code_buffer.zig");
pub const CodeBuffer = code_buffer.CodeBuffer;
pub const available = code_buffer.available;
