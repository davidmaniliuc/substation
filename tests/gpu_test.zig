const std = @import("std");
const expectEqual = std.testing.expectEqual;
const zzssxx = @import("zzssxx");
const Gpu = zzssxx.gpu.Gpu;

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
