//! The picture on the resume prompt, taken from CORE VRAM at the instant of
//! the save so it shows exactly the saved frame.
//!
//! Never from the Metal texture: that may be upscaled, a frame later, or
//! under the HUD. The display area is cropped and decoded here the way
//! `DisplayShader.metal` scans it out (15 bpp, or 24 bpp packed three bytes
//! per pixel across 16-bit words) with the same `c << 3 | c >> 2`
//! expansion, then drawn at 4:3 whatever the display's pixel size, which is
//! how the game is shown.

const std = @import("std");
const metal = @import("ps1_metal");

const Display = metal.stream_queue.Display;
const native_pixels = metal.prim_instance.native_pixels;
const vram_width = metal.prim_instance.native_width;
const vram_height = metal.prim_instance.native_height;

pub const width = 320;
pub const height = 240;

/// The largest display area a game can program, 640x480, in RGBA.
pub const max_rgba = 640 * 480 * 4;

pub const Size = struct { w: u32, h: u32 };

/// The display area as RGBA8 (alpha 255) into `out_rgba`, which must hold
/// `w * h * 4` bytes. Null for a disabled or empty display.
pub fn decode(vram: *const [native_pixels]u16, d: Display, out_rgba: []u8) ?Size {
    const w: usize = d.width;
    const h: usize = d.height;
    if (!d.enabled or w == 0 or h == 0) return null;
    std.debug.assert(out_rgba.len >= w * h * 4);
    for (0..h) |y| {
        const row = ((d.vram_y + y) & (vram_height - 1)) * vram_width;
        for (0..w) |x| {
            const o = (y * w + x) * 4;
            if (d.depth24) {
                // Byte k of the row lives in halfword (vram_x + k/2), low byte first.
                inline for (0..3) |c| out_rgba[o + c] = byte24(vram, row, d.vram_x, x * 3 + c);
            } else {
                const p = vram[row + ((d.vram_x + x) & (vram_width - 1))];
                out_rgba[o] = expand(p & 0x1F);
                out_rgba[o + 1] = expand((p >> 5) & 0x1F);
                out_rgba[o + 2] = expand((p >> 10) & 0x1F);
            }
            out_rgba[o + 3] = 255;
        }
    }
    return .{ .w = @intCast(w), .h = @intCast(h) };
}

fn byte24(vram: *const [native_pixels]u16, row: usize, vram_x: u32, k: usize) u8 {
    const word = vram[row + ((vram_x + k / 2) & (vram_width - 1))];
    return @truncate(if (k % 2 == 0) word else word >> 8);
}

/// 5 -> 8 bits by replicating the high bits, so 31 maps to 255: the one
/// expansion every display path uses.
fn expand(c: u16) u8 {
    return @intCast((c << 3) | (c >> 2));
}

/// The 320x240 PNG, owned by the caller, or null for a disabled display.
pub fn png(alloc: std.mem.Allocator, vram: *const [native_pixels]u16, d: Display) !?[]u8 {
    const rgba = try alloc.alloc(u8, @as(usize, d.width) * d.height * 4);
    defer alloc.free(rgba);
    const size = decode(vram, d, rgba) orelse return null;
    return try metal.png.encodeScaled(alloc, rgba, size.w, size.h, width, height);
}
