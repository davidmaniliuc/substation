const std = @import("std");
const expectEqual = std.testing.expectEqual;
const ps1_core = @import("ps1_core");
const Gpu = ps1_core.gpu.Gpu;
const Renderer = ps1_core.gpu.Renderer;
const Color = ps1_core.gpu.Color;

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

// GPUSTAT bit 13 is hardwired to 1 (Avocado `GPUSTAT |= 1 << 13; // always set`,
// gpu.cpp:543). It is the interlace field, not a PAL flag — driving it from the
// video mode makes every NTSC console read it back as 0.
test "GPUSTAT bit 13 is always set, in either video mode" {
    var gpu = Gpu.init();

    gpu.writeGp1(0x08000000); // GP1(08) display mode: NTSC
    try std.testing.expect(gpu.readStatus() & (1 << 13) != 0);

    gpu.writeGp1(0x08000008); // GP1(08) display mode: PAL (bit 3)
    try std.testing.expect(gpu.readStatus() & (1 << 13) != 0);
}

// Bit 27 is "ready to send VRAM to CPU", i.e. Avocado's
// `readMode == ReadMode::Vram` (gpu.cpp:556). It is only true while a GP0(C0)
// transfer is actually in flight — hardcoding it to 1 tells a game VRAM data is
// waiting when none is.
test "GPUSTAT bit 27 tracks an in-flight VRAM-to-CPU transfer" {
    var gpu = Gpu.init();
    setupGpu(&gpu);

    try expectEqual(@as(u32, 0), gpu.readStatus() & (1 << 27));

    // GP0(C0): read back a single 2x1 strip, i.e. exactly one word.
    _ = gpu.writeGp0(0xC0000000);
    _ = gpu.writeGp0(xy(0, 0));
    _ = gpu.writeGp0(xy(2, 1));
    _ = gpu.step(1000);
    try std.testing.expect(gpu.readStatus() & (1 << 27) != 0);

    _ = gpu.readData(); // drain it
    try expectEqual(@as(u32, 0), gpu.readStatus() & (1 << 27));
}

// Bit 25 is the DMA request line, and for DMA direction 3 (VRAM->CPU) it
// mirrors bit 27 rather than being unconditionally on (Avocado gpu.cpp:530-538).
test "GPUSTAT bit 25 follows bit 27 when the DMA direction is VRAM-to-CPU" {
    var gpu = Gpu.init();
    setupGpu(&gpu);

    gpu.writeGp1(0x04000003); // GP1(04) DMA direction = 3 (VRAM -> CPU)
    try expectEqual(@as(u32, 0), gpu.readStatus() & (1 << 25));

    _ = gpu.writeGp0(0xC0000000);
    _ = gpu.writeGp0(xy(0, 0));
    _ = gpu.writeGp0(xy(2, 1));
    _ = gpu.step(1000);
    try std.testing.expect(gpu.readStatus() & (1 << 25) != 0);

    // Directions 1 and 2 request unconditionally; direction 0 never does.
    gpu.writeGp1(0x04000002);
    try std.testing.expect(gpu.readStatus() & (1 << 25) != 0);
    gpu.writeGp1(0x04000000);
    try expectEqual(@as(u32, 0), gpu.readStatus() & (1 << 25));
}

test "GPU drops a primitive spanning 1024 or more horizontally" {
    // Hardware does not clip an oversized primitive, it refuses it. Geometry
    // crossing the near plane projects to saturated screen coordinates, and
    // the refusal is what keeps it off the screen -- rasterizing it instead
    // smears scenery across the camera.
    var gpu = Gpu.init();
    setupGpu(&gpu);

    const color = 0x0000FF00; // Green
    const color16 = gpu.getColor16(color);

    // Span exactly 1024: -512 .. 512.
    _ = gpu.writeGp0(0x20000000 | color);
    _ = gpu.writeGp0(xy(0x600, 10)); // -512
    _ = gpu.writeGp0(xy(512, 10));
    _ = gpu.writeGp0(xy(0, 40));
    _ = gpu.step(1000);

    try expectEqual(@as(u16, 0), gpu.vram.data[20 * 1024 + 0]);

    // One pixel narrower is inside the limit and still draws.
    _ = gpu.writeGp0(0x20000000 | color);
    _ = gpu.writeGp0(xy(0x601, 10)); // -511
    _ = gpu.writeGp0(xy(512, 10));
    _ = gpu.writeGp0(xy(0, 40));
    _ = gpu.step(1000);

    try expectEqual(color16, gpu.vram.data[20 * 1024 + 0]);
}

test "GPU drops a primitive spanning 512 or more vertically" {
    var gpu = Gpu.init();
    setupGpu(&gpu);

    const color = 0x0000FF00; // Green
    const color16 = gpu.getColor16(color);

    // Span exactly 512: -256 .. 256.
    _ = gpu.writeGp0(0x20000000 | color);
    _ = gpu.writeGp0(xy(10, 0x700)); // -256
    _ = gpu.writeGp0(xy(40, 0x700));
    _ = gpu.writeGp0(xy(10, 256));
    _ = gpu.step(1000);

    try expectEqual(@as(u16, 0), gpu.vram.data[10 * 1024 + 12]);

    // One pixel shorter is inside the limit and still draws.
    _ = gpu.writeGp0(0x20000000 | color);
    _ = gpu.writeGp0(xy(10, 0x701)); // -255
    _ = gpu.writeGp0(xy(40, 0x701));
    _ = gpu.writeGp0(xy(10, 256));
    _ = gpu.step(1000);

    try expectEqual(color16, gpu.vram.data[10 * 1024 + 12]);
}

test "GPU drops an oversized line the same way it drops an oversized polygon" {
    var gpu = Gpu.init();
    setupGpu(&gpu);

    const color = 0x0000FF00; // Green
    const color16 = gpu.getColor16(color);

    // Horizontal span of exactly 1024: -512 .. 512, along y = 30.
    _ = gpu.writeGp0(0x40000000 | color);
    _ = gpu.writeGp0(xy(0x600, 30)); // -512
    _ = gpu.writeGp0(xy(512, 30));
    _ = gpu.step(1000);

    try expectEqual(@as(u16, 0), gpu.vram.data[30 * 1024 + 100]);

    // One pixel shorter draws.
    _ = gpu.writeGp0(0x40000000 | color);
    _ = gpu.writeGp0(xy(0x601, 30)); // -511
    _ = gpu.writeGp0(xy(512, 30));
    _ = gpu.step(1000);

    try expectEqual(color16, gpu.vram.data[30 * 1024 + 100]);
}

test "GPU drops an oversized rectangle" {
    // The GP0 rectangle size field is 16 bits wide, so nothing but this rule
    // bounds it -- hardware drops a rectangle 1024 or more wide, or 512 or
    // more tall, rather than clipping it to the drawing area.
    var gpu = Gpu.init();
    setupGpu(&gpu);

    const color = 0x0000FF00; // Green
    const color16 = gpu.getColor16(color);

    _ = gpu.writeGp0(0x60000000 | color);
    _ = gpu.writeGp0(xy(0, 0));
    _ = gpu.writeGp0(1024 | (16 << 16)); // 1024 wide
    _ = gpu.step(1000);

    try expectEqual(@as(u16, 0), gpu.vram.data[8 * 1024 + 8]);

    _ = gpu.writeGp0(0x60000000 | color);
    _ = gpu.writeGp0(xy(0, 0));
    _ = gpu.writeGp0(1023 | (16 << 16)); // 1023 wide draws
    _ = gpu.step(1000);

    try expectEqual(color16, gpu.vram.data[8 * 1024 + 8]);
}

// --- Phase 0 characterization: behaviours the integer conversion must preserve.

fn envFullArea(gpu: *Gpu) void {
    gpu.draw_env = .{};
    gpu.draw_env.area_bot_right = 1023 | (511 << 10);
}

test "Phase0: triangle honours the drawing area on every side" {
    var gpu = Gpu.init();
    envFullArea(&gpu);
    // Drawing area (10,10)-(20,20); the triangle covers (0,0)-(40,40).
    gpu.draw_env.area_top_left = 10 | (10 << 10);
    gpu.draw_env.area_bot_right = 20 | (20 << 10);

    Renderer.drawTriangle(&gpu.vram, &gpu.draw_env, 0, 0, 40, 0, 0, 40, 0x7FFF, false);

    // Inside the area: painted. Outside on each side: untouched.
    try std.testing.expect(gpu.vram.data[15 * 1024 + 12] != 0);
    try expectEqual(@as(u16, 0), gpu.vram.data[9 * 1024 + 12]); // above
    try expectEqual(@as(u16, 0), gpu.vram.data[21 * 1024 + 12]); // below
    try expectEqual(@as(u16, 0), gpu.vram.data[15 * 1024 + 9]); // left
    try expectEqual(@as(u16, 0), gpu.vram.data[15 * 1024 + 21]); // right
}

test "Phase0: triangle check-mask skips pixels whose bit15 is set" {
    var gpu = Gpu.init();
    envFullArea(&gpu);
    gpu.draw_env.mask_bit = 2; // check only

    gpu.vram.data[5 * 1024 + 5] = 0x8000; // masked destination
    gpu.vram.data[6 * 1024 + 5] = 0x0000; // unmasked destination

    Renderer.drawTriangle(&gpu.vram, &gpu.draw_env, 0, 0, 40, 0, 0, 40, 0x1234, false);

    try expectEqual(@as(u16, 0x8000), gpu.vram.data[5 * 1024 + 5]);
    try expectEqual(@as(u16, 0x1234), gpu.vram.data[6 * 1024 + 5]);
}

test "Phase0: triangle set-mask ORs bit15 into every pixel written" {
    var gpu = Gpu.init();
    envFullArea(&gpu);
    gpu.draw_env.mask_bit = 1; // set only

    Renderer.drawTriangle(&gpu.vram, &gpu.draw_env, 0, 0, 40, 0, 0, 40, 0x1234, false);

    try expectEqual(@as(u16, 0x9234), gpu.vram.data[6 * 1024 + 5]);
}

test "Phase0: triangle semi-transparency uses the four integer blend modes" {
    // Back = 20/20/20 in 5-bit, front = 10/10/10. The expected values come
    // straight from Color.blend, which is the shared back end putPixel calls;
    // this pins that the rasterizer keeps routing through it.
    const back: u16 = 20 | (20 << 5) | (20 << 10);
    const front: u16 = 10 | (10 << 5) | (10 << 10);

    var mode: u2 = 0;
    while (true) {
        var gpu = Gpu.init();
        envFullArea(&gpu);
        gpu.draw_env.draw_mode = @as(u32, mode) << 5;
        gpu.vram.data[6 * 1024 + 5] = back;

        Renderer.drawTriangle(&gpu.vram, &gpu.draw_env, 0, 0, 40, 0, 0, 40, front, true);

        try expectEqual(Color.blend(back, front, mode), gpu.vram.data[6 * 1024 + 5]);
        if (mode == 3) break;
        mode += 1;
    }
}

test "Phase0: a fully transparent texel is skipped, not drawn as black" {
    var gpu = Gpu.init();
    envFullArea(&gpu);
    // 16bpp texture page at VRAM (256, 256), left all-zero so every texel
    // reads 0x0000, which hardware treats as "do not draw". The page must NOT
    // be at (0,0): the triangle draws into rows 0-40 there, so it would be
    // sampling the pixels it is writing and the test would pass for the wrong
    // reason.
    const tpage: u16 = (2 << 7) | (1 << 4) | 4; // 16bpp, page x = 4*64 = 256, page y = 256
    gpu.vram.data[6 * 1024 + 5] = 0xABCD;

    Renderer.drawTexturedTriangle(
        &gpu.vram,
        &gpu.draw_env,
        0,
        0,
        0,
        0,
        40,
        0,
        40,
        0,
        0,
        40,
        0,
        40,
        0x7FFF,
        0,
        tpage,
        false,
        0x25, // textured, raw (bit0 set -> no modulation)
    );

    try expectEqual(@as(u16, 0xABCD), gpu.vram.data[6 * 1024 + 5]);
}

// --- Phase 0 Task 2: integer edge-function coverage.

/// The coverage rule this rasterizer is required to implement, written out
/// independently of the implementation: integer edge functions in the
/// positive-area normalization, biased by the top-left fill rule, ANDed with
/// the drawing area. Used to differential-test rasterizeTriangle.
fn refCovers(
    vx: [3]i32,
    vy: [3]i32,
    px: i32,
    py: i32,
) bool {
    const o2d = struct {
        fn f(ax: i32, ay: i32, bx: i32, by: i32, cx: i32, cy: i32) i32 {
            return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
        }
    }.f;
    const topleft = struct {
        fn f(dx: i32, dy: i32) bool {
            return dy > 0 or (dy == 0 and dx < 0);
        }
    }.f;

    const area_signed = o2d(vx[0], vy[0], vx[1], vy[1], vx[2], vy[2]);
    if (area_signed == 0) return false;
    const s: i32 = if (area_signed < 0) -1 else 1;

    var w: [3]i32 = undefined;
    w[0] = s * o2d(vx[1], vy[1], vx[2], vy[2], px, py);
    w[1] = s * o2d(vx[2], vy[2], vx[0], vy[0], px, py);
    w[2] = s * o2d(vx[0], vy[0], vx[1], vy[1], px, py);

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const a = (i + 1) % 3;
        const b = (i + 2) % 3;
        const bias: i32 = if (topleft(s * (vx[b] - vx[a]), s * (vy[b] - vy[a]))) -1 else 0;
        w[i] += bias;
    }
    return (w[0] | w[1] | w[2]) > 0;
}

test "Phase0: a sub-pixel sliver triangle covers no pixel centre" {
    // THE RED TEST for this task. Both triangles have |2*area| == 1, i.e. an
    // area of half a pixel, and neither contains a pixel centre under the
    // top-left rule -- so neither may paint anything. The scanline span search
    // paints exactly one pixel for each: it intersects the edges with the
    // scanline using @divTrunc and then applies the edge test, and the span's
    // own endpoint survives.
    //
    // One case per winding (2*area is -1 and +1 respectively), because the
    // sign normalization is the part of this rewrite most likely to be wrong.
    const cases = [2][6]i16{
        .{ 18, 24, 13, 25, 54, 17 },
        .{ 0, 0, 1, 0, 260, 1 },
    };
    for (cases, 0..) |c, i| {
        var gpu = Gpu.init();
        envFullArea(&gpu);
        Renderer.drawTriangle(&gpu.vram, &gpu.draw_env, c[0], c[1], c[2], c[3], c[4], c[5], 0x7FFF, false);

        for (gpu.vram.data, 0..) |px, idx| {
            if (px != 0) {
                std.debug.print("\nsliver {d} painted ({d},{d}) = {x:0>4}\n", .{ i, idx % 1024, idx / 1024, px });
                return error.SliverPainted;
            }
        }
    }
}

test "Phase0: triangle coverage matches the edge-function rule exactly" {
    // A LOCK, not a red test: the two coverage rules agree on ordinary
    // triangles (5 in 3,000 random ones over this box differ, all slivers), so
    // this passes before and after. It is here to stop a later phase drifting
    // the rule, which is the thing Phase B's shader has to match.
    var rng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = rng.random();

    var t: usize = 0;
    while (t < 200) : (t += 1) {
        var gpu = Gpu.init();
        envFullArea(&gpu);

        var vx: [3]i32 = undefined;
        var vy: [3]i32 = undefined;
        var k: usize = 0;
        while (k < 3) : (k += 1) {
            vx[k] = rand.intRangeAtMost(i32, 0, 63);
            vy[k] = rand.intRangeAtMost(i32, 0, 63);
        }

        Renderer.drawTriangle(
            &gpu.vram,
            &gpu.draw_env,
            @intCast(vx[0]),
            @intCast(vy[0]),
            @intCast(vx[1]),
            @intCast(vy[1]),
            @intCast(vx[2]),
            @intCast(vy[2]),
            0x7FFF,
            false,
        );

        var y: i32 = 0;
        while (y < 64) : (y += 1) {
            var x: i32 = 0;
            while (x < 64) : (x += 1) {
                const drawn = gpu.vram.data[@intCast(y * 1024 + x)] != 0;
                const want = refCovers(vx, vy, x, y);
                if (drawn != want) {
                    std.debug.print(
                        "\ntriangle {d} ({d},{d})-({d},{d})-({d},{d}) pixel ({d},{d}): drawn={} want={}\n",
                        .{ t, vx[0], vy[0], vx[1], vy[1], vx[2], vy[2], x, y, drawn, want },
                    );
                    return error.CoverageMismatch;
                }
            }
        }
    }
}

test "Phase0: two triangles sharing an edge paint every pixel exactly once" {
    // Also a LOCK: today's span search already tiles this correctly. It is the
    // human-readable statement of what the fill rule is FOR, and it is the
    // first thing to break if someone "simplifies" the bias or the (w0|w1|w2)
    // test later.
    //
    // Additive semi-transparency (mode 1) over a black background: a pixel
    // painted once reads 8, a pixel painted twice reads 16, a gap reads 0.
    // Quad (0,0)-(31,0)-(31,31)-(0,31) split on the 0-2 diagonal, which is
    // exactly what gp0.zig does to every quad it decodes.
    var gpu = Gpu.init();
    envFullArea(&gpu);
    gpu.draw_env.draw_mode = 1 << 5; // blend mode 1: B + F
    const c: u16 = 8 | (8 << 5) | (8 << 10);

    Renderer.drawTriangle(&gpu.vram, &gpu.draw_env, 0, 0, 31, 0, 31, 31, c, true);
    Renderer.drawTriangle(&gpu.vram, &gpu.draw_env, 0, 0, 31, 31, 0, 31, c, true);

    var y: usize = 1;
    while (y < 31) : (y += 1) {
        var x: usize = 1;
        while (x < 31) : (x += 1) {
            const px = gpu.vram.data[y * 1024 + x];
            const r = px & 0x1F;
            if (r != 8) {
                std.debug.print("\npixel ({d},{d}) red={d}, want 8 ({s})\n", .{
                    x,                                       y, r,
                    if (r == 0) "gap" else "double-painted",
                });
                return error.SharedEdgeMismatch;
            }
        }
    }
}

// --- Phase 0 Task 3: exact integer Gouraud interpolation.

/// The interpolation rule this rasterizer is required to implement, written
/// out independently: floor((w0*a0 + w1*a1 + w2*a2) / area) in i64, with the
/// un-biased weights and a positive area.
fn refInterp(vx: [3]i32, vy: [3]i32, px: i32, py: i32, a: [3]i32) i32 {
    const o2d = struct {
        fn f(ax: i32, ay: i32, bx: i32, by: i32, cx: i32, cy: i32) i32 {
            return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
        }
    }.f;
    const area_signed = o2d(vx[0], vy[0], vx[1], vy[1], vx[2], vy[2]);
    const s: i32 = if (area_signed < 0) -1 else 1;
    const area = @as(i64, area_signed * s);
    const w0 = @as(i64, s * o2d(vx[1], vy[1], vx[2], vy[2], px, py));
    const w1 = @as(i64, s * o2d(vx[2], vy[2], vx[0], vy[0], px, py));
    const w2 = @as(i64, s * o2d(vx[0], vy[0], vx[1], vy[1], px, py));
    const num = w0 * @as(i64, a[0]) + w1 * @as(i64, a[1]) + w2 * @as(i64, a[2]);
    return @intCast(@divFloor(num, area));
}

test "Phase0: a flat-coloured Gouraud triangle is flat" {
    // THE RED TEST for this task, and it needs no reference implementation:
    // if all three vertex colours are equal, every covered pixel must be that
    // colour. The exact rule gives it for free -- sum(w_i)*a / area == a by the
    // barycentric identity -- while the f32 path divides three weights by the
    // area, multiplies each by the colour and sums, and lands a hair low.
    //
    // This triangle (2*area == 222) has six such pixels at colour 0x808080.
    var gpu = Gpu.init();
    envFullArea(&gpu);

    const c: u32 = 0x00808080; // r = g = b = 128 -> 5-bit 16 each
    const want: u16 = 16 | (16 << 5) | (16 << 10); // 0x4210

    Renderer.drawShadedTriangle(&gpu.vram, &gpu.draw_env, 15, 25, c, 26, 11, c, 23, 35, c, false);

    var painted: usize = 0;
    for (gpu.vram.data, 0..) |px, idx| {
        if (px == 0) continue;
        painted += 1;
        if (px != want) {
            std.debug.print("\npixel ({d},{d}) = {x:0>4}, want {x:0>4}\n", .{ idx % 1024, idx / 1024, px, want });
            return error.FlatTriangleNotFlat;
        }
    }
    try std.testing.expect(painted > 0);
}

test "Phase0: Gouraud shading is the exact integer interpolant" {
    var rng = std.Random.DefaultPrng.init(0x5EED);
    const rand = rng.random();

    var t: usize = 0;
    while (t < 100) : (t += 1) {
        var gpu = Gpu.init();
        envFullArea(&gpu);
        // draw_mode stays 0: dithering off, so the only thing under test is
        // the interpolation.

        var vx: [3]i32 = undefined;
        var vy: [3]i32 = undefined;
        var r: [3]i32 = undefined;
        var g: [3]i32 = undefined;
        var b: [3]i32 = undefined;
        var c: [3]u32 = undefined;
        var k: usize = 0;
        while (k < 3) : (k += 1) {
            vx[k] = rand.intRangeAtMost(i32, 0, 63);
            vy[k] = rand.intRangeAtMost(i32, 0, 63);
            r[k] = rand.intRangeAtMost(i32, 0, 255);
            g[k] = rand.intRangeAtMost(i32, 0, 255);
            b[k] = rand.intRangeAtMost(i32, 0, 255);
            c[k] = @as(u32, @intCast(r[k])) |
                (@as(u32, @intCast(g[k])) << 8) |
                (@as(u32, @intCast(b[k])) << 16);
        }

        Renderer.drawShadedTriangle(
            &gpu.vram,
            &gpu.draw_env,
            @intCast(vx[0]),
            @intCast(vy[0]),
            c[0],
            @intCast(vx[1]),
            @intCast(vy[1]),
            c[1],
            @intCast(vx[2]),
            @intCast(vy[2]),
            c[2],
            false,
        );

        var y: i32 = 0;
        while (y < 64) : (y += 1) {
            var x: i32 = 0;
            while (x < 64) : (x += 1) {
                if (!refCovers(vx, vy, x, y)) continue;
                const px = gpu.vram.data[@intCast(y * 1024 + x)];
                const want_r: u16 = @intCast(std.math.clamp(refInterp(vx, vy, x, y, r), 0, 255) >> 3);
                const want_g: u16 = @intCast(std.math.clamp(refInterp(vx, vy, x, y, g), 0, 255) >> 3);
                const want_b: u16 = @intCast(std.math.clamp(refInterp(vx, vy, x, y, b), 0, 255) >> 3);
                const want = want_r | (want_g << 5) | (want_b << 10);
                if (px != want) {
                    std.debug.print(
                        "\ntriangle {d} pixel ({d},{d}): got {x:0>4} want {x:0>4}\n",
                        .{ t, x, y, px, want },
                    );
                    return error.ShadeMismatch;
                }
            }
        }
    }
}

// --- Phase 0 Task 4: exact integer texcoord interpolation.

test "Phase0: textured triangle samples the exact integer texel coordinate" {
    // Unlike the Gouraud sweep this one is reliably red: texcoords are used at
    // full 8-bit precision, with no >> 3 to absorb the f32 error. Expect
    // roughly seven diverging pixels at this seed and sweep size.
    var rng = std.Random.DefaultPrng.init(0x7E77);
    const rand = rng.random();

    var t: usize = 0;
    while (t < 200) : (t += 1) {
        var gpu = Gpu.init();
        envFullArea(&gpu);

        // A 16bpp texture page at VRAM (256, 256): every texel encodes its own
        // (u, v) so a wrong coordinate is visible rather than plausible.
        // Bit15 stays clear (no STP) and the value is never 0x0000, which
        // would be read as "skip this texel".
        var v: usize = 0;
        while (v < 256) : (v += 1) {
            var u: usize = 0;
            while (u < 256) : (u += 1) {
                gpu.vram.data[(256 + v) * 1024 + 256 + u] =
                    @intCast(1 + ((u * 7 + v * 131) & 0x7FFE));
            }
        }
        const tpage: u16 = (2 << 7) | (1 << 4) | 4; // 16bpp, page x = 4*64 = 256, page y = 256

        var vx: [3]i32 = undefined;
        var vy: [3]i32 = undefined;
        var tu: [3]i32 = undefined;
        var tv: [3]i32 = undefined;
        var k: usize = 0;
        while (k < 3) : (k += 1) {
            // 0..127, not 0..63: bigger triangles have bigger areas, and the
            // f32 reciprocal 1/area is where the error comes from.
            vx[k] = rand.intRangeAtMost(i32, 0, 127);
            vy[k] = rand.intRangeAtMost(i32, 0, 127);
            tu[k] = rand.intRangeAtMost(i32, 0, 255);
            tv[k] = rand.intRangeAtMost(i32, 0, 255);
        }

        Renderer.drawTexturedTriangle(
            &gpu.vram,
            &gpu.draw_env,
            @intCast(vx[0]),
            @intCast(vy[0]),
            @intCast(tu[0]),
            @intCast(tv[0]),
            @intCast(vx[1]),
            @intCast(vy[1]),
            @intCast(tu[1]),
            @intCast(tv[1]),
            @intCast(vx[2]),
            @intCast(vy[2]),
            @intCast(tu[2]),
            @intCast(tv[2]),
            0x7FFF,
            0,
            tpage,
            false,
            0x25, // raw texture (opcode bit0 set): no modulation, no dither
        );

        var y: i32 = 0;
        while (y < 128) : (y += 1) {
            var x: i32 = 0;
            while (x < 128) : (x += 1) {
                if (!refCovers(vx, vy, x, y)) continue;
                const u: usize = @intCast(std.math.clamp(refInterp(vx, vy, x, y, tu), 0, 255));
                const uv: usize = @intCast(std.math.clamp(refInterp(vx, vy, x, y, tv), 0, 255));
                const want = gpu.vram.data[(256 + uv) * 1024 + 256 + u];
                const got = gpu.vram.data[@intCast(y * 1024 + x)];
                if (got != want) {
                    std.debug.print(
                        "\ntriangle {d} pixel ({d},{d}): got {x:0>4} want {x:0>4} (u={d} v={d})\n",
                        .{ t, x, y, got, want, u, uv },
                    );
                    return error.TexcoordMismatch;
                }
            }
        }
    }
}

// --- Phase 0 Task 5: modulate goes integer without changing its output.

test "Phase0: modulate is exhaustively unchanged by the integer conversion" {
    // The full domain: every 5-bit texel channel against every 5-bit colour
    // channel, dither off. The expected value is written out here as the rule
    // rather than referring to the implementation, so this pins the table
    // across the conversion in Task 5 and detects the deliberate change in
    // Task 6.
    var t: u16 = 0;
    while (t < 32) : (t += 1) {
        var c: u16 = 0;
        while (c < 32) : (c += 1) {
            const texel: u16 = t | (t << 5) | (t << 10);
            const color: u16 = c | (c << 5) | (c << 10);
            const want5: u16 = @min(@divFloor(t * c, 16), 31);
            const want: u16 = want5 | (want5 << 5) | (want5 << 10);
            try expectEqual(want, Color.modulate(texel, color, 0, 0, false));
        }
    }
}

test "Phase0: modulate keeps the texel's STP bit" {
    try expectEqual(@as(u16, 0x8000), Color.modulate(0x8000, 0x0000, 0, 0, false) & 0x8000);
    try expectEqual(@as(u16, 0x0000), Color.modulate(0x0001, 0x7FFF, 0, 0, false) & 0x8000);
}

// --- Phase 0 Task 6: modulate's dither offset is an 8-bit-scale offset.

test "Phase0: modulate dithers at 8-bit scale like the Gouraud path" {
    // texel channel 16, colour channel 16 -> product 256, i.e. 8-bit value 128
    // and 5-bit value 16. The dither offsets are 8-bit units, so the strongest
    // one (-4) may move the 5-bit result by at most one step, and usually by
    // none at all. Applied at 5-bit scale it moves it by four.
    const texel: u16 = 16 | (16 << 5) | (16 << 10);
    const color: u16 = 16 | (16 << 5) | (16 << 10);

    // dither_table[0][0] == -4: 128 - 4 = 124, >> 3 == 15.
    try expectEqual(@as(u16, 15), Color.modulate(texel, color, 0, 0, true) & 0x1F);
    // dither_table[1][2] == 3: 128 + 3 = 131, >> 3 == 16.
    try expectEqual(@as(u16, 16), Color.modulate(texel, color, 2, 1, true) & 0x1F);
}

test "Phase0: modulate dither cannot push a channel out of range" {
    const white: u16 = 0x7FFF;
    // Full texel * unity colour (16) is 8-bit 248; +3 dither stays inside 255.
    try expectEqual(@as(u16, 31), Color.modulate(white, 16 | (16 << 5) | (16 << 10), 2, 1, true) & 0x1F);
    // Black texel with the most negative dither must clamp at 0, not wrap.
    try expectEqual(@as(u16, 0), Color.modulate(0x0000, white, 0, 0, true) & 0x1F);
}
