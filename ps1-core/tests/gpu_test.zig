const std = @import("std");
const expectEqual = std.testing.expectEqual;
const ps1_core = @import("ps1_core");
const Gpu = ps1_core.gpu.Gpu;

fn xy(x: u16, y: u16) u32 {
    return @as(u32, x & 0x7FF) | (@as(u32, y & 0x7FF) << 16);
}

fn setupGpu(gpu: *Gpu) void {
    // Set Drawing Area to full VRAM
    _ = gpu.writeGp0(0xE3000000); // Top Left: 0,0
    _ = gpu.writeGp0(0xE407FFFF); // Bottom Right: 1023, 511
    // Set Drawing Offset to 0
    _ = gpu.writeGp0(0xE5000000); // Offset: 0,0
}

test "GPU Mono Line (0x40)" {
    var gpu = Gpu.init();
    setupGpu(&gpu);

    const color = 0x00FFFFFF; // White
    const color16 = gpu.getColor16(color);

    _ = gpu.writeGp0(0x40000000 | (color & 0x00FFFFFF));
    _ = gpu.writeGp0(0x00000000); // 0,0
    _ = gpu.writeGp0(0x000A000A); // 10,10

    _ = gpu.step(1000);

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

    _ = gpu.writeGp0(0x50000000 | (c1 & 0x00FFFFFF));
    _ = gpu.writeGp0(0x00000000);
    _ = gpu.writeGp0(c2 & 0x00FFFFFF);
    _ = gpu.writeGp0(0x0000000A); // (0,0) to (10,0) - Horizontal line

    _ = gpu.step(1000);

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

    _ = gpu.writeGp0(0x48000000 | (color & 0x00FFFFFF));
    _ = gpu.writeGp0(0x00000000); // 0,0
    _ = gpu.writeGp0(0x0000000A); // 10,0
    _ = gpu.writeGp0(0x000A000A); // 10,10
    _ = gpu.writeGp0(0x55555555); // Terminator

    _ = gpu.step(1000);

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

    _ = gpu.writeGp0(0x58000000 | (c1 & 0x00FFFFFF));
    _ = gpu.writeGp0(0x00000000); // Vertex 1: (0,0)
    _ = gpu.writeGp0(c2 & 0x00FFFFFF);
    _ = gpu.writeGp0(0x0000000A); // Vertex 2: (10,0)
    _ = gpu.writeGp0(c3 & 0x00FFFFFF);
    _ = gpu.writeGp0(0x000A000A); // Vertex 3: (10,10)
    _ = gpu.writeGp0(0x55555555); // Terminator

    _ = gpu.step(1000);

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
    gpu.vram.copyRect(0, 0, 2, 2, 10, 10, .{});

    // Verify some values
    try expectEqual(@as(u16, 0), gpu.vram.data[2 * 1024 + 2]);
    try expectEqual(@as(u16, 9), gpu.vram.data[2 * 1024 + 11]);
    try expectEqual(@as(u16, 99), gpu.vram.data[11 * 1024 + 11]);

    // Copy back from (2,2) to (0,0) - Destination is left/top of source
    // This requires forward iteration
    gpu.vram.copyRect(2, 2, 0, 0, 10, 10, .{});
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

    _ = gpu.writeGp0(0x60000000 | color);
    _ = gpu.writeGp0(xy(0x7FE, 0x7FE)); // -2, -2 as signed 11-bit coordinates
    _ = gpu.writeGp0(@as(u32, 4) | (@as(u32, 4) << 16));

    _ = gpu.step(1000);

    try expectEqual(color16, gpu.vram.data[0 * 1024 + 0]);
    try expectEqual(color16, gpu.vram.data[1 * 1024 + 1]);
    try expectEqual(@as(u16, 0), gpu.vram.data[2 * 1024 + 2]);
}

test "GPU triangle rasterizer handles clipped signed coordinates without overflow" {
    var gpu = Gpu.init();
    setupGpu(&gpu);

    const color = 0x0000FF00; // Green
    const color16 = gpu.getColor16(color);

    _ = gpu.writeGp0(0x20000000 | color);
    _ = gpu.writeGp0(xy(0x7FE, 0x7FE)); // -2, -2
    _ = gpu.writeGp0(xy(5, 0));
    _ = gpu.writeGp0(xy(0, 5));

    _ = gpu.step(1000);

    try expectEqual(color16, gpu.vram.data[0 * 1024 + 0]);
}

test "GPU textured rectangle uses direct blitter without triangle seam" {
    var gpu = Gpu.init();
    setupGpu(&gpu);

    // 16-bit direct texture page at VRAM x=64, y=0.
    _ = gpu.writeGp0(0xE1000101);

    const red: u16 = 0x001F;
    const green: u16 = 0x03E0;
    const blue: u16 = 0x7C00;
    const white: u16 = 0x7FFF;

    gpu.vram.data[0 * 1024 + 64] = red;
    gpu.vram.data[0 * 1024 + 65] = green;
    gpu.vram.data[1 * 1024 + 64] = blue;
    gpu.vram.data[1 * 1024 + 65] = white;

    _ = gpu.writeGp0(0x75000000); // 8x8 textured rectangle, raw texture
    _ = gpu.writeGp0(xy(10, 10));
    _ = gpu.writeGp0(0x00000000); // U=0, V=0, CLUT ignored in 16-bit mode

    _ = gpu.step(1000);

    try expectEqual(red, gpu.vram.data[10 * 1024 + 10]);
    try expectEqual(green, gpu.vram.data[10 * 1024 + 11]);
    try expectEqual(blue, gpu.vram.data[11 * 1024 + 10]);
    try expectEqual(white, gpu.vram.data[11 * 1024 + 11]);
}

test "GPU drawing keeps the texel's mask bit so a later check-mask draw is blocked" {
    var gpu = Gpu.init();
    setupGpu(&gpu);

    // 16-bit direct texture page at VRAM x=64, y=0.
    _ = gpu.writeGp0(0xE1000101);

    // Two identical greys, one with the semi-transparency (mask) bit set.
    const grey: u16 = 0x3DEF;
    const grey_stp: u16 = 0x8000 | grey;

    gpu.vram.data[0 * 1024 + 64] = grey_stp;
    gpu.vram.data[0 * 1024 + 65] = grey;

    // GP0(E6) = 0: the written mask bit comes from the texture, not forced.
    _ = gpu.writeGp0(0xE6000000);
    _ = gpu.writeGp0(0x75000000); // 8x8 textured rectangle, raw texture
    _ = gpu.writeGp0(xy(10, 10));
    _ = gpu.writeGp0(0x00000000);
    _ = gpu.step(1000);

    // The texel's bit15 must survive into VRAM; a texel without it must not
    // gain one.
    try expectEqual(grey_stp, gpu.vram.data[10 * 1024 + 10]);
    try expectEqual(grey, gpu.vram.data[10 * 1024 + 11]);

    // GP0(E6) = 3: check-mask + set-mask, the idiom Silent Hill brackets its
    // per-character fog quad with. The masked pixel must be left alone; the
    // unmasked one must be drawn over (and gain a mask bit).
    _ = gpu.writeGp0(0xE6000003);
    _ = gpu.writeGp0(0x60FFFFFF); // opaque white monochrome rectangle
    _ = gpu.writeGp0(xy(10, 10));
    _ = gpu.writeGp0(0x00080008); // 8x8
    _ = gpu.step(1000);

    try expectEqual(grey_stp, gpu.vram.data[10 * 1024 + 10]);
    try expectEqual(@as(u16, 0xFFFF), gpu.vram.data[10 * 1024 + 11]);
}

fn gp1_06(x1: u16, x2: u16) u32 {
    return 0x06000000 | @as(u32, x1) | (@as(u32, x2) << 12);
}

fn gp1_07(y1: u16, y2: u16) u32 {
    return 0x07000000 | @as(u32, y1) | (@as(u32, y2) << 10);
}

test "GPU display size is the programmed visible area, not the nominal mode size" {
    // Register values captured live from real games with ps1-trace. The nominal
    // mode size is always larger than what the game actually scans out, and the
    // extra rows are undrawn VRAM -- they show up as garbage along the edges.
    var gpu = Gpu.init();

    // Crash Bandicoot (Europe), in-game: 512x288 PAL non-interlaced,
    // but the vertical range only covers 256 lines.
    gpu.writeGp1(0x08000000 | 0x0A);
    gpu.writeGp1(gp1_06(608, 3168));
    gpu.writeGp1(gp1_07(37, 293));
    try expectEqual(@as(u32, 512), gpu.getDisplayWidth());
    try expectEqual(@as(u32, 256), gpu.getDisplayHeight());

    // Silent Hill (USA), boot/menu: 640x480 NTSC interlaced. The range spans
    // 239 lines, which is doubled in 480-line mode.
    gpu.writeGp1(0x08000000 | 0x27);
    gpu.writeGp1(gp1_06(608, 3168));
    gpu.writeGp1(gp1_07(16, 255));
    try expectEqual(@as(u32, 640), gpu.getDisplayWidth());
    try expectEqual(@as(u32, 478), gpu.getDisplayHeight());

    // Silent Hill (USA), FMV: 320x240 NTSC 24bpp, range spans 208 lines.
    gpu.writeGp1(0x08000000 | 0x11);
    gpu.writeGp1(gp1_06(600, 3160));
    gpu.writeGp1(gp1_07(32, 240));
    try expectEqual(@as(u32, 320), gpu.getDisplayWidth());
    try expectEqual(@as(u32, 208), gpu.getDisplayHeight());
}

test "GPU display size crops horizontally and never exceeds the mode size" {
    var gpu = Gpu.init();

    // 320-pixel mode is 8 GPU cycles per pixel. A 1600-cycle range is 200 pixels.
    gpu.writeGp1(0x08000000 | 0x01);
    gpu.writeGp1(gp1_06(600, 2200));
    gpu.writeGp1(gp1_07(24, 248));
    try expectEqual(@as(u32, 200), gpu.getDisplayWidth());
    try expectEqual(@as(u32, 224), gpu.getDisplayHeight());

    // An oversized range is clamped to the mode's nominal size rather than
    // running off the end of the framebuffer.
    gpu.writeGp1(gp1_06(0, 4095));
    gpu.writeGp1(gp1_07(0, 1023));
    try expectEqual(@as(u32, 320), gpu.getDisplayWidth());
    try expectEqual(@as(u32, 240), gpu.getDisplayHeight());

    // A degenerate/empty range falls back to the nominal size instead of
    // producing a zero-sized frame.
    gpu.writeGp1(gp1_06(2000, 2000));
    gpu.writeGp1(gp1_07(248, 24));
    try expectEqual(@as(u32, 320), gpu.getDisplayWidth());
    try expectEqual(@as(u32, 240), gpu.getDisplayHeight());
}

// GP0(A0) CPU->VRAM transfers honour GP0(E6), exactly like a drawn primitive:
// set-mask-while-drawing ORs bit15 into every uploaded pixel, and
// check-mask-before-draw skips pixels whose existing bit15 is set. Avocado
// funnels the transfer through GPU::maskedWrite (gpu.cpp:437) for this reason.
// Reproduces gpu/mask-bit's testSetBit + testCheckMaskBit.
test "GPU CPU-to-VRAM upload honours the E6 mask bits" {
    var gpu = Gpu.init();
    setupGpu(&gpu);

    // set-mask-while-drawing: the uploaded pixel comes back with bit15 set.
    _ = gpu.writeGp0(0xE6000001);
    _ = gpu.writeGp0(0xA0000000);
    _ = gpu.writeGp0(xy(0x20, 0x21));
    _ = gpu.writeGp0(xy(1, 1));
    _ = gpu.writeGp0(0x00000000); // upload colour 0x0000
    _ = gpu.step(1000);
    try expectEqual(@as(u16, 0x8000), gpu.vram.data[0x21 * 1024 + 0x20]);

    // check-mask-before-draw: a pixel already carrying bit15 must not be
    // overwritten by a later upload.
    _ = gpu.writeGp0(0xE6000002);
    _ = gpu.writeGp0(0xA0000000);
    _ = gpu.writeGp0(xy(0x20, 0x21));
    _ = gpu.writeGp0(xy(1, 1));
    _ = gpu.writeGp0(0x00001234);
    _ = gpu.step(1000);
    try expectEqual(@as(u16, 0x8000), gpu.vram.data[0x21 * 1024 + 0x20]);

    // With both bits clear the upload writes through untouched.
    _ = gpu.writeGp0(0xE6000000);
    _ = gpu.writeGp0(0xA0000000);
    _ = gpu.writeGp0(xy(0x20, 0x21));
    _ = gpu.writeGp0(xy(1, 1));
    _ = gpu.writeGp0(0x00001234);
    _ = gpu.step(1000);
    try expectEqual(@as(u16, 0x1234), gpu.vram.data[0x21 * 1024 + 0x20]);
}

// VRAM->VRAM copies go through the same masked write (Avocado gpu.cpp:523),
// while Fill Rectangle (GP0(02)) deliberately does NOT — hardware ignores E6
// for fills.
test "GPU VRAM-to-VRAM copy honours E6 while fill rectangle ignores it" {
    var gpu = Gpu.init();
    setupGpu(&gpu);
    _ = gpu.step(1000);

    gpu.vram.data[0x40 * 1024 + 0x10] = 0x1234; // source
    gpu.vram.data[0x50 * 1024 + 0x10] = 0x8000; // masked destination

    // check-mask: the masked destination pixel survives the copy.
    _ = gpu.writeGp0(0xE6000002);
    _ = gpu.writeGp0(0x80000000);
    _ = gpu.writeGp0(xy(0x10, 0x40));
    _ = gpu.writeGp0(xy(0x10, 0x50));
    _ = gpu.writeGp0(xy(1, 1));
    _ = gpu.step(1000);
    try expectEqual(@as(u16, 0x8000), gpu.vram.data[0x50 * 1024 + 0x10]);

    // set-mask: the copied pixel gains bit15.
    _ = gpu.writeGp0(0xE6000001);
    _ = gpu.writeGp0(0x80000000);
    _ = gpu.writeGp0(xy(0x10, 0x40));
    _ = gpu.writeGp0(xy(0x11, 0x50));
    _ = gpu.writeGp0(xy(1, 1));
    _ = gpu.step(1000);
    try expectEqual(@as(u16, 0x9234), gpu.vram.data[0x50 * 1024 + 0x11]);

    // Fill rectangle ignores both mask bits and clears the masked pixel.
    _ = gpu.writeGp0(0xE6000002); // check-mask on
    _ = gpu.writeGp0(0x02000000); // fill colour 0 (black)
    _ = gpu.writeGp0(xy(0x10, 0x50));
    _ = gpu.writeGp0(xy(0x10, 1));
    _ = gpu.step(1000);
    try expectEqual(@as(u16, 0x0000), gpu.vram.data[0x50 * 1024 + 0x10]);
}

// A textured polygon's texpage word writes through into the E1 register, so it
// is visible in GPUSTAT afterwards: texpage x/y, semi-transparency and colour
// depth (bits 0-8) plus, when GP1(09) allowed it, texture-disable (E1 bit 11 ->
// GPUSTAT bit 15). Bits 9/10 (dither, draw-to-display) are preserved.
// Avocado gpu.cpp:293-304. Reproduces gpu/gp0-e1's testTexturedPolygons*.
test "GPU textured polygon latches its texpage into GPUSTAT" {
    // bits 0-10 of the E1 register plus texture-disable at GPUSTAT bit 15
    const E1_STAT_MASK: u32 = 0x87FF;

    var gpu = Gpu.init();
    setupGpu(&gpu);

    // Dither + draw-to-display set, every texpage bit clear.
    _ = gpu.writeGp0(0xE1000600);
    _ = gpu.step(1000);
    try expectEqual(@as(u32, 0x0600), gpu.readStatus() & E1_STAT_MASK);

    // Textured triangle carrying texpage 0x01FF in its second UV word.
    _ = gpu.writeGp0(0x24808080);
    _ = gpu.writeGp0(xy(0, 0));
    _ = gpu.writeGp0(0x00000000); // uv0 + clut
    _ = gpu.writeGp0(xy(4, 0));
    _ = gpu.writeGp0(0x01FF0000); // uv1 + texpage
    _ = gpu.writeGp0(xy(0, 4));
    _ = gpu.writeGp0(0x00000000); // uv2
    _ = gpu.step(1000);
    try expectEqual(@as(u32, 0x07FF), gpu.readStatus() & E1_STAT_MASK);

    // Texture-disable (texpage bit 11) is dropped unless GP1(09) allowed it.
    gpu.writeGp1(0x09000000);
    _ = gpu.writeGp0(0x24808080);
    _ = gpu.writeGp0(xy(0, 0));
    _ = gpu.writeGp0(0x00000000);
    _ = gpu.writeGp0(xy(4, 0));
    _ = gpu.writeGp0(0x09FF0000); // texpage with bit 11 set
    _ = gpu.writeGp0(xy(0, 4));
    _ = gpu.writeGp0(0x00000000);
    _ = gpu.step(1000);
    try expectEqual(@as(u32, 0x07FF), gpu.readStatus() & E1_STAT_MASK);

    gpu.writeGp1(0x09000001); // allow texture disable
    _ = gpu.writeGp0(0x24808080);
    _ = gpu.writeGp0(xy(0, 0));
    _ = gpu.writeGp0(0x00000000);
    _ = gpu.writeGp0(xy(4, 0));
    _ = gpu.writeGp0(0x09FF0000);
    _ = gpu.writeGp0(xy(0, 4));
    _ = gpu.writeGp0(0x00000000);
    _ = gpu.step(1000);
    try expectEqual(@as(u32, 0x87FF), gpu.readStatus() & E1_STAT_MASK);
}
