//! What the display tests share: plain managed textures to bind, and the
//! real display pass rendered offscreen and read back.
//!
//! One render helper for every display test: what differs between the
//! callers is only which VRAM texture is bound (a plain managed 1024x512
//! fill, or a real, possibly scaled `MetalVram`), never the pipeline, the
//! pass, or the read-back.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const harness = @import("harness.zig");

const objc = ps1_metal.objc;
const mtl = ps1_metal.mtl;
const enums = ps1_metal.mtl_enums;
const display = ps1_metal.display;
const screenshot = ps1_metal.screenshot;
const Allocator = std.mem.Allocator;

pub const native_width = ps1_metal.prim_instance.native_width;
pub const native_height = ps1_metal.prim_instance.native_height;
pub const native_pixels = ps1_metal.prim_instance.native_pixels;

/// Params with the six fields every test sets, the rest at their defaults.
pub fn params() display.Params {
    return .{ .vram_x = 0, .vram_y = 0, .width = 320, .height = 240, .depth24 = 0, .enabled = 1 };
}

/// A shader-readable, managed 1024x512 texture holding `bytes`.
pub fn managedTexture(device: mtl.Device, format: enums.PixelFormat, bytes_per_pixel: usize, bytes: []const u8) !mtl.Texture {
    std.debug.assert(bytes.len == native_pixels * bytes_per_pixel);
    const t = try device.newTexture2D(.{
        .format = format,
        .width = native_width,
        .height = native_height,
        .storage = .managed,
        .usage = .{ .shaderRead = true },
    });
    t.replaceRegion(.{
        .origin = .{ .x = 0, .y = 0, .z = 0 },
        .size = .{ .width = native_width, .height = native_height, .depth = 1 },
    }, bytes, native_width * bytes_per_pixel);
    return t;
}

/// A 1024x512 `.r16Uint` texture with every word `fill`.
pub fn vramTexture(alloc: Allocator, device: mtl.Device, fill: u16) !mtl.Texture {
    const words = try alloc.alloc(u16, native_pixels);
    defer alloc.free(words);
    @memset(words, fill);
    return managedTexture(device, .r16Uint, 2, std.mem.sliceAsBytes(words));
}

/// A 1024x512 `.rgba8Uint` texture with every pixel `fill`.
pub fn sidecarTexture(alloc: Allocator, device: mtl.Device, fill: [4]u8) !mtl.Texture {
    const bytes = try alloc.alloc([4]u8, native_pixels);
    defer alloc.free(bytes);
    @memset(bytes, fill);
    return managedTexture(device, .rgba8Uint, 4, std.mem.sliceAsBytes(bytes));
}

/// Draws the display pass into a `width` x `height` BGRA target, waits, and
/// hands back its bytes. Owned by the caller.
pub fn render(
    alloc: Allocator,
    m: harness.Metal,
    pass: *display.DisplayPass,
    vram: mtl.Texture,
    sidecar: mtl.Texture,
    p: display.Params,
    width: u32,
    height: u32,
) ![]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const target = screenshot.newTarget(m.device, .{ .width = width, .height = height }) orelse
        return error.MetalAllocation;
    defer target.release();
    const cmd = m.queue.commandBuffer() orelse return error.NoCommandBuffer;
    pass.encode(cmd, target, vram, sidecar, p);
    if (!screenshot.synchronize(cmd, target)) return error.NoEncoder;
    cmd.commit();
    cmd.waitUntilCompleted();
    const out = try alloc.alloc(u8, @as(usize, width) * height * 4);
    screenshot.bytes(target, out);
    return out;
}

/// (b, g, r) at (x, y) of a `width`-wide BGRA image.
pub fn pixel(bgra: []const u8, width: usize, x: usize, y: usize) [3]u8 {
    const o = (y * width + x) * 4;
    return .{ bgra[o], bgra[o + 1], bgra[o + 2] };
}

pub fn isBlack(px: [3]u8) bool {
    return px[0] == 0 and px[1] == 0 and px[2] == 0;
}
