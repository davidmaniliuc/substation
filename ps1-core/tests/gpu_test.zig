const std = @import("std");
const expectEqual = std.testing.expectEqual;
const ps1_core = @import("ps1_core");
const Gpu = ps1_core.gpu.Gpu;

fn xy(x: u16, y: u16) u32 {
    return @as(u32, x & 0x7FF) | (@as(u32, y & 0x7FF) << 16);
}

fn setupGpu(gpu: *Gpu) void {
    // Set Drawing Area to full VRAM
    gpu.writeGp0(0xE3000000); // Top Left: 0,0
    gpu.writeGp0(0xE407FFFF); // Bottom Right: 1023, 511
    // Set Drawing Offset to 0
    gpu.writeGp0(0xE5000000); // Offset: 0,0
}

test "GPU Mono Line (0x40)" {
    var gpu = Gpu.init();
    setupGpu(&gpu);

    const color = 0x00FFFFFF; // White
    const color16 = gpu.getColor16(color);

    gpu.writeGp0(0x40000000 | (color & 0x00FFFFFF));
    gpu.writeGp0(0x00000000); // 0,0
    gpu.writeGp0(0x000A000A); // 10,10

    // Verify some pixels on the line (0,0 to 10,10)
    try expectEqual(color16, gpu.vram.data[0 * 1024 + 0]);
    try expectEqual(color16, gpu.vram.data[5 * 1024 + 5]);
    try expectEqual(color16, gpu.vram.data[10 * 1024 + 10]);
}

test "GPU Shaded Line (0x50)" {
    var gpu = Gpu.init();
    setupGpu(&gpu);

    const c1 = 0x000000FF; // Red
    const c2 = 0x0000FF00; // Green

    gpu.writeGp0(0x50000000 | (c1 & 0x00FFFFFF));
    gpu.writeGp0(0x00000000);
    gpu.writeGp0(c2 & 0x00FFFFFF);
    gpu.writeGp0(0x0000000A); // (0,0) to (10,0) - Horizontal line

    const c1_16 = gpu.getColor16(c1);
    const c2_16 = gpu.getColor16(c2);

    try expectEqual(c1_16, gpu.vram.data[0 * 1024 + 0]);
    try expectEqual(c2_16, gpu.vram.data[0 * 1024 + 10]);

    // Midpoint should be approximately red + green (Yellow-ish in 555)
    const mid = gpu.vram.data[0 * 1024 + 5];
    const r = mid & 0x1F;
    const g = (mid >> 5) & 0x1F;
    try std.testing.expect(r > 10 and r < 25);
    try std.testing.expect(g > 10 and g < 25);
}

test "GPU Mono Polyline (0x48)" {
    var gpu = Gpu.init();
    setupGpu(&gpu);

    const color = 0x000000FF; // Red
    const color16 = gpu.getColor16(color);

    gpu.writeGp0(0x48000000 | (color & 0x00FFFFFF));
    gpu.writeGp0(0x00000000); // 0,0
    gpu.writeGp0(0x0000000A); // 10,0
    gpu.writeGp0(0x000A000A); // 10,10
    gpu.writeGp0(0x55555555); // Terminator

    try expectEqual(color16, gpu.vram.data[0 * 1024 + 0]);
    try expectEqual(color16, gpu.vram.data[0 * 1024 + 10]);
    try expectEqual(color16, gpu.vram.data[5 * 1024 + 10]);
    try expectEqual(color16, gpu.vram.data[10 * 1024 + 10]);
}

test "GPU Shaded Polyline (0x58)" {
    var gpu = Gpu.init();
    setupGpu(&gpu);

    const c1 = 0x000000FF; // Red
    const c2 = 0x0000FF00; // Green
    const c3 = 0x00FF0000; // Blue

    gpu.writeGp0(0x58000000 | (c1 & 0x00FFFFFF));
    gpu.writeGp0(0x00000000); // Vertex 1: (0,0)
    gpu.writeGp0(c2 & 0x00FFFFFF);
    gpu.writeGp0(0x0000000A); // Vertex 2: (10,0)
    gpu.writeGp0(c3 & 0x00FFFFFF);
    gpu.writeGp0(0x000A000A); // Vertex 3: (10,10)
    gpu.writeGp0(0x55555555); // Terminator

    const c1_16 = gpu.getColor16(c1);
    const c2_16 = gpu.getColor16(c2);
    const c3_16 = gpu.getColor16(c3);

    try expectEqual(c1_16, gpu.vram.data[0 * 1024 + 0]);
    try expectEqual(c2_16, gpu.vram.data[0 * 1024 + 10]);
    try expectEqual(c3_16, gpu.vram.data[10 * 1024 + 10]);
}

test "VRAM Copy Overlap" {
    var gpu = Gpu.init();

    // Fill a 10x10 area with some data
    for (0..10) |y| {
        for (0..10) |x| {
            gpu.vram.data[y * 1024 + x] = @intCast(x + y * 10);
        }
    }

    // Copy (0,0, 10,10) to (2,2) - Destination is right/bottom of source
    // This requires backward iteration
    gpu.vram.copyRect(0, 0, 2, 2, 10, 10);

    // Verify some values
    try expectEqual(@as(u16, 0), gpu.vram.data[2 * 1024 + 2]);
    try expectEqual(@as(u16, 9), gpu.vram.data[2 * 1024 + 11]);
    try expectEqual(@as(u16, 99), gpu.vram.data[11 * 1024 + 11]);

    // Copy back from (2,2) to (0,0) - Destination is left/top of source
    // This requires forward iteration
    gpu.vram.copyRect(2, 2, 0, 0, 10, 10);
    try expectEqual(@as(u16, 0), gpu.vram.data[0 * 1024 + 0]);
    try expectEqual(@as(u16, 99), gpu.vram.data[9 * 1024 + 9]);
}

test "GPU CRT step tracks NTSC HBlank and VBlank edges" {
    var gpu = Gpu.init();

    var result = gpu.step(Gpu.ntsc_cycles_per_scanline - 1);
    try std.testing.expect(!result.tick_hblank_timer);
    try expectEqual(@as(u32, 0), gpu.v_count);

    result = gpu.step(1);
    try std.testing.expect(result.tick_hblank_timer);
    try expectEqual(@as(u32, 1), gpu.v_count);
    try expectEqual(@as(u32, 0), gpu.h_count);

    result = gpu.step(Gpu.ntsc_cycles_per_scanline * (Gpu.ntsc_vblank_start_line - 1));
    try std.testing.expect(result.trigger_vblank_irq);
    try std.testing.expect((gpu.readStatus() & (1 << 19)) != 0);
    try expectEqual(Gpu.ntsc_vblank_start_line, gpu.v_count);
}

test "GPU dotclock divider follows horizontal resolution" {
    var gpu = Gpu.init();

    var result = gpu.step(10);
    try expectEqual(@as(u32, 1), result.dotclock_ticks);

    gpu.writeGp1(0x08000001); // 320-pixel mode, 8 CPU cycles per dot.
    result = gpu.step(8);
    try expectEqual(@as(u32, 1), result.dotclock_ticks);

    gpu.writeGp1(0x08000040); // 368-pixel mode, 7 CPU cycles per dot.
    result = gpu.step(7);
    try expectEqual(@as(u32, 1), result.dotclock_ticks);
}

test "GPU color packing is ABGR1555 with red in low bits" {
    var gpu = Gpu.init();

    try expectEqual(@as(u16, 0x001F), gpu.getColor16(0x000000FF));
    try expectEqual(@as(u16, 0x03E0), gpu.getColor16(0x0000FF00));
    try expectEqual(@as(u16, 0x7C00), gpu.getColor16(0x00FF0000));
    try expectEqual(@as(u16, 0x7FFF), gpu.getColor16(0x00FFFFFF));
}

test "GPU mono rectangle clips negative signed coordinates" {
    var gpu = Gpu.init();
    setupGpu(&gpu);

    const color = 0x000000FF; // Red
    const color16 = gpu.getColor16(color);

    gpu.writeGp0(0x60000000 | color);
    gpu.writeGp0(xy(0x7FE, 0x7FE)); // -2, -2 as signed 11-bit coordinates
    gpu.writeGp0(@as(u32, 4) | (@as(u32, 4) << 16));

    try expectEqual(color16, gpu.vram.data[0 * 1024 + 0]);
    try expectEqual(color16, gpu.vram.data[1 * 1024 + 1]);
    try expectEqual(@as(u16, 0), gpu.vram.data[2 * 1024 + 2]);
}

test "GPU triangle rasterizer handles clipped signed coordinates without overflow" {
    var gpu = Gpu.init();
    setupGpu(&gpu);

    const color = 0x0000FF00; // Green
    const color16 = gpu.getColor16(color);

    gpu.writeGp0(0x20000000 | color);
    gpu.writeGp0(xy(0x7FE, 0x7FE)); // -2, -2
    gpu.writeGp0(xy(5, 0));
    gpu.writeGp0(xy(0, 5));

    try expectEqual(color16, gpu.vram.data[0 * 1024 + 0]);
}

test "GPU textured rectangle uses direct blitter without triangle seam" {
    var gpu = Gpu.init();
    setupGpu(&gpu);

    // 16-bit direct texture page at VRAM x=64, y=0.
    gpu.writeGp0(0xE1000101);

    const red: u16 = 0x001F;
    const green: u16 = 0x03E0;
    const blue: u16 = 0x7C00;
    const white: u16 = 0x7FFF;

    gpu.vram.data[0 * 1024 + 64] = red;
    gpu.vram.data[0 * 1024 + 65] = green;
    gpu.vram.data[1 * 1024 + 64] = blue;
    gpu.vram.data[1 * 1024 + 65] = white;

    gpu.writeGp0(0x75000000); // 8x8 textured rectangle, raw texture
    gpu.writeGp0(xy(10, 10));
    gpu.writeGp0(0x00000000); // U=0, V=0, CLUT ignored in 16-bit mode

    try expectEqual(red, gpu.vram.data[10 * 1024 + 10]);
    try expectEqual(green, gpu.vram.data[10 * 1024 + 11]);
    try expectEqual(blue, gpu.vram.data[11 * 1024 + 10]);
    try expectEqual(white, gpu.vram.data[11 * 1024 + 11]);
}
