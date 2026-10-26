//! The readback gather: a native rect of a scaled texture into a shared
//! buffer, one thread per native pixel, by `readbackNative`'s
//! top-left-subtexel rule (`Readback.metal`). What `readNative` and the
//! capture ring both encode, so a readback costs the rect and never the
//! scaled texture.

const std = @import("std");
const mtl = @import("mtl.zig");
const pi = @import("prim_instance.zig");

/// `Readback.metal`'s `Ps1GatherParams`.
const Params = extern struct { x0: u32, y0: u32, width: u32, height: u32, scale: u32 };

/// Encodes one gather of `r` (inclusive, in bounds) from `src` into `out` at
/// `offset`, row-major. Needs an enclosing pool.
pub fn encode(
    cmd: mtl.CommandBuffer,
    pipeline: mtl.ComputePipelineState,
    src: mtl.Texture,
    out: mtl.Buffer,
    offset: usize,
    r: pi.VramRect,
    scale: u32,
) void {
    const p: Params = .{
        .x0 = @intCast(r.x0),
        .y0 = @intCast(r.y0),
        .width = @intCast(r.x1 - r.x0 + 1),
        .height = @intCast(r.y1 - r.y0 + 1),
        .scale = scale,
    };
    const enc = cmd.computeCommandEncoder() orelse @panic("gather: computeCommandEncoder() returned nil");
    enc.setComputePipelineState(pipeline);
    enc.setTexture(src, 0);
    enc.setBuffer(out, offset, 0);
    enc.setBytes(std.mem.asBytes(&p), 1);
    enc.dispatchThreads(.{ .width = p.width, .height = p.height, .depth = 1 }, .{ .width = 16, .height = 16, .depth = 1 });
    enc.endEncoding();
}
