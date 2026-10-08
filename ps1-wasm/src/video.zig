//! The displayed picture as RGBA, converted here rather than in JavaScript:
//! it is the per-pixel loop of every frame, and wasm runs it several times
//! faster. JavaScript never reads VRAM.

const std = @import("std");
const ps1 = @import("ps1_core");
const machine = @import("machine.zig");

const vram_w = 1024;
const vram_h = 512;

var rgba: [vram_w * vram_h * 4]u8 = undefined;
var width: u32 = 0;
var height: u32 = 0;

/// Converts the displayed area into a buffer this module owns and returns
/// it. Valid until the next call; `frameWidth`/`frameHeight` give its size.
/// A display the game has switched off is opaque black, as on hardware.
export fn renderFrame() [*]const u8 {
    const g = &machine.bus.gpu;
    g.syncRaster();
    width = @min(g.getDisplayWidth(), vram_w);
    height = @min(g.getDisplayHeight(), vram_h);
    const out = rgba[0 .. width * height * 4];
    if (g.disp_env.display_disabled) {
        fillBlack(out);
    } else if (g.disp_env.display_mode & (1 << 4) != 0) {
        convert24(g, out);
    } else {
        convert15(g, out);
    }
    return &rgba;
}

export fn frameWidth() u32 {
    return width;
}

export fn frameHeight() u32 {
    return height;
}

/// 1 for a 50 Hz machine: the player paces frames by it.
export fn isPal() u32 {
    return @intFromBool(!machine.bus.gpu.is_ntsc);
}

fn fillBlack(out: []u8) void {
    var i: usize = 0;
    while (i < out.len) : (i += 4) {
        out[i..][0..4].* = .{ 0, 0, 0, 255 };
    }
}

/// The same 5-to-8-bit expansion as the rest of the codebase: `c << 3 | c >> 2`.
fn expand5(c: u16) u8 {
    const v: u8 = @intCast(c & 0x1F);
    return v << 3 | v >> 2;
}

fn convert15(g: *const ps1.gpu.Gpu, out: []u8) void {
    const x0: usize = g.disp_env.vram_x_start;
    const y0: usize = g.disp_env.vram_y_start;
    var o: usize = 0;
    for (0..height) |y| {
        const row = ((y0 + y) & (vram_h - 1)) * vram_w;
        for (0..width) |x| {
            const c = g.vram.data[row + ((x0 + x) & (vram_w - 1))];
            out[o..][0..4].* = .{ expand5(c), expand5(c >> 5), expand5(c >> 10), 255 };
            o += 4;
        }
    }
}

/// 24-bit mode packs three bytes per pixel across the 16-bit words; the
/// start X is still in words. Each byte wraps within its VRAM row.
fn convert24(g: *const ps1.gpu.Gpu, out: []u8) void {
    const bytes = std.mem.sliceAsBytes(g.vram.data[0..]);
    const row_bytes = vram_w * 2;
    const x0: usize = g.disp_env.vram_x_start;
    const y0: usize = g.disp_env.vram_y_start;
    var o: usize = 0;
    for (0..height) |y| {
        const row = ((y0 + y) & (vram_h - 1)) * row_bytes;
        for (0..width) |x| {
            const bx = x0 * 2 + x * 3;
            for (0..3) |k| out[o + k] = bytes[row + (bx + k) % row_bytes];
            out[o + 3] = 255;
            o += 4;
        }
    }
}
