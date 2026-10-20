//! The Metal renderer, headless: VRAM on the GPU, the rasterizer and the
//! display pass, below any window.

pub const objc = @import("objc.zig");
pub const mtl = @import("mtl.zig");
pub const mtl_encode = @import("mtl_encode.zig");
pub const mtl_enums = @import("mtl_enums.zig");
pub const shaders = @import("shaders.zig");
