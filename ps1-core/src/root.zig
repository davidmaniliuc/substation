//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
pub const cpu = @import("cpu.zig");
pub const memory = @import("memory.zig");
pub const gpu = @import("gpu/gpu.zig");
pub const dma = @import("dma.zig");
pub const timer = @import("timer.zig");
pub const spu = @import("spu.zig");
pub const disc = @import("disc.zig");
pub const cdrom = @import("cdrom.zig");
pub const interrupt = @import("interrupt.zig");
