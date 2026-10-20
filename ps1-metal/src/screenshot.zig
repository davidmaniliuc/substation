//! A screenshot is what is on screen: the display pass the window draws,
//! rendered once more into a texture of its own at the internal resolution,
//! in the 4:3 shape the player sees and with no letterbox. Naming and
//! writing the file stay the app's; this is the render half.

const std = @import("std");
const objc = @import("objc.zig");
const mtl = @import("mtl.zig");
const display = @import("display.zig");

pub const Size = struct { width: u32, height: u32 };

/// The displayed lines at the internal scale, and the width that makes it
/// 4:3, the shape the window shows whatever the horizontal resolution. A
/// display that is off, or shows no lines, is a black VGA frame.
pub fn size(display_height: u32, scale: u32, enabled: bool) Size {
    if (!enabled or display_height == 0) return .{ .width = 640, .height = 480 };
    const height = display_height * scale;
    const h: f64 = @floatFromInt(height);
    return .{ .width = @intFromFloat(@round(h * 4 / 3)), .height = height };
}

/// A BGRA target the CPU can read back once the GPU is done with it. Owned
/// by the caller; null where Metal refused the allocation.
pub fn newTarget(device: mtl.Device, s: Size) ?mtl.Texture {
    const desc = mtl.TextureDescriptor.new();
    defer desc.release();
    desc.setPixelFormat(.bgra8Unorm);
    desc.setWidth(s.width);
    desc.setHeight(s.height);
    desc.setStorageMode(.managed);
    desc.setUsage(.{ .renderTarget = true, .shaderRead = true });
    return device.newTexture(desc);
}

/// Encodes the blit that makes a `.managed` target's GPU writes readable by
/// `bytes` once `cmd` completes. False where Metal handed back no encoder.
pub fn synchronize(cmd: mtl.CommandBuffer, target: mtl.Texture) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const blit = cmd.blitCommandEncoder() orelse return false;
    blit.synchronizeResource(target);
    blit.endEncoding();
    return true;
}

/// Encodes the display pass into a new texture of `s`, with the letterbox at
/// (1, 1). The caller commits `cmd`, reads the texture with `bytes` once it
/// has completed, and releases it.
pub fn encode(cmd: mtl.CommandBuffer, pass: *display.DisplayPass, vram: mtl.Texture, sidecar: mtl.Texture, p: display.Params, s: Size) ?mtl.Texture {
    const target = newTarget(cmd.device(), s) orelse return null;
    var q = p;
    q.scale_x = 1;
    q.scale_y = 1;
    // The game's picture, never the paused grey-out or the toolbar band over it.
    q.saturation = 1;
    q.band_mix = 0;
    pass.encode(cmd, target, vram, sidecar, q);
    if (!synchronize(cmd, target)) {
        target.release();
        return null;
    }
    return target;
}

/// A completed `encode` target's BGRA bytes, top row first, into `out`
/// (`width * height * 4` bytes).
pub fn bytes(t: mtl.Texture, out: []u8) void {
    const w = t.width();
    const h = t.height();
    std.debug.assert(out.len == w * h * 4);
    t.getBytes(out, w * 4, .{
        .origin = .{ .x = 0, .y = 0, .z = 0 },
        .size = .{ .width = w, .height = h, .depth = 1 },
    });
}
