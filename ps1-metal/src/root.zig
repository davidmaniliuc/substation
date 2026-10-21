//! The Metal renderer, headless: VRAM on the GPU, the rasterizer and the
//! display pass, below any window.

pub const objc = @import("objc.zig");
pub const mtl = @import("mtl.zig");
pub const mtl_encode = @import("mtl_encode.zig");
pub const mtl_enums = @import("mtl_enums.zig");
pub const mtl_layer = @import("mtl_layer.zig");
pub const cf = @import("cf.zig");
pub const frame_renderer = @import("frame_renderer.zig");
pub const render_thread = @import("render_thread.zig");
pub const shaders = @import("shaders.zig");
pub const metal_context = @import("metal_context.zig");
pub const prim_instance = @import("prim_instance.zig");
pub const hazard_tracker = @import("hazard_tracker.zig");
pub const prim_builder = @import("prim_builder.zig");
pub const metal_vram = @import("metal_vram.zig");
pub const fixture = @import("fixture");
pub const fixture_corpus = @import("fixture_corpus.zig");
pub const pipelines = @import("pipelines.zig");
pub const rasterizer = @import("rasterizer.zig");
pub const prim_encoders = @import("prim_encoders.zig");
pub const lock = @import("lock.zig");
pub const waker = @import("waker.zig");
pub const stream_queue = @import("stream_queue.zig");
pub const speculative_region = @import("speculative_region.zig");
pub const live_renderer = @import("live_renderer.zig");
pub const frame_exchange = @import("frame_exchange.zig");
pub const display = @import("display.zig");
pub const screenshot = @import("screenshot.zig");
pub const png = @import("png.zig");
