//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
pub const cpu = @import("cpu.zig");
pub const memory = @import("memory.zig");
pub const gpu = @import("gpu/gpu.zig");
pub const dma = @import("dma.zig");
