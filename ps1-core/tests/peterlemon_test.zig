// PeterLemon/PSX test suite — graphical conformance ROMs compared against a
// reference framebuffer. Run with `zig build test-roms-peter-lemon`.
const std = @import("std");
const ps1_core = @import("ps1_core");
const options = @import("rom_test_options");
const readTestFile = @import("rom_test_helpers.zig").readTestFile;
const expectVramEqual = @import("vram_compare.zig").expectVramEqual;

const Bus = ps1_core.memory.Bus;
const Cpu = ps1_core.cpu.Cpu;

const PL_W: usize = 320;
const PL_H: usize = 224;
const PL_PIXELS: usize = PL_W * PL_H; // 71680

fn goldensUpdateMode() bool {
    if (std.c.getenv("PS1_UPDATE_GOLDENS")) |val| {
        return std.mem.span(val).len > 0;
    }
    return false;
}

/// Count display-region pixels matching the reference image, comparing in 5-bit
/// RGB space (both sides reduced to RGB555) so the ABGR1555->RGB888 expansion
/// used to make the reference PNG doesn't register as a difference.
fn countReferenceMatches(bus: *Bus, ref_rgb: []const u8) usize {
    const vram = bus.gpu.getVramPtr();
    const ox: usize = bus.gpu.disp_env.vram_x_start;
    const oy: usize = bus.gpu.disp_env.vram_y_start;
    var matches: usize = 0;
    var y: usize = 0;
    while (y < PL_H) : (y += 1) {
        var x: usize = 0;
        while (x < PL_W) : (x += 1) {
            const vx = (ox + x) & 0x3FF;
            const vy = (oy + y) & 0x1FF;
            const px = vram[vy * 1024 + vx];
            const r5: u8 = @intCast(px & 0x1F);
            const g5: u8 = @intCast((px >> 5) & 0x1F);
            const b5: u8 = @intCast((px >> 10) & 0x1F);
            const idx = (y * PL_W + x) * 3;
            if (r5 == (ref_rgb[idx] >> 3) and
                g5 == (ref_rgb[idx + 1] >> 3) and
                b5 == (ref_rgb[idx + 2] >> 3)) matches += 1;
        }
    }
    return matches;
}

/// Steps `count` instructions, draining and replaying the recorded stream at
/// every vblank edge. The shadow is carried across the whole test — BIOS boot
/// included — so a divergence is attributable to the frame that caused it.
fn stepWithStreamCheck(
    bus: *Bus,
    cpu: *Cpu,
    count: u64,
    shadow: *ps1_core.gpu.Vram,
    shadow_env: *ps1_core.gpu.Regs.DrawingEnv,
    prev_vblank: *bool,
) !void {
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        cpu.step();
        const vblank = bus.gpu.is_vblank;
        defer prev_vblank.* = vblank;
        if (!vblank or prev_vblank.*) continue;

        // The stream aliases the recorder's storage and is valid only until
        // emulation resumes, so it is consumed here, before the next step().
        const s = bus.gpu.sink.rec.takeFrame();
        try std.testing.expect(s.complete);
        ps1_core.gpu.command.replay(s, shadow, shadow_env);
    }
}

fn runPlTest(
    allocator: std.mem.Allocator,
    exe_path: []const u8,
    ref_rgb_path: []const u8,
    floor_path: []const u8,
    max_cycles: u64,
) !void {
    if (!options.enable_rom_tests) return error.SkipZigTest;

    const bus = try Bus.init(allocator);
    defer bus.deinit(allocator);

    var cpu = Cpu.init(bus);

    // The shadow starts where the rasterizer's VRAM starts: all zeros, default
    // drawing environment. Every mutation from then on arrives through the
    // stream, so the two stay in step for the WHOLE test rather than being
    // resynced per frame.
    const shadow = try allocator.create(ps1_core.gpu.Vram);
    defer allocator.destroy(shadow);
    shadow.* = .{};
    var shadow_env: ps1_core.gpu.Regs.DrawingEnv = .{};
    var prev_vblank = false;
    bus.gpu.sink.rec.arm();

    const bios_data = try readTestFile(allocator, "SCPH-1001_BIOS_1995_US.bin", 512 * 1024);
    defer allocator.free(bios_data);
    if (bios_data.len != bus.bios.len) return error.InvalidBiosSize;
    @memcpy(bus.bios[0..], bios_data);

    // Boot the BIOS to init jump tables.
    try stepWithStreamCheck(bus, &cpu, 25_000_000, shadow, &shadow_env, &prev_vblank);

    const exe_data = try readTestFile(allocator, exe_path, 10 * 1024 * 1024);
    defer allocator.free(exe_data);
    try cpu.loadExe(exe_data);

    // Graphical demos render in an infinite loop; a fixed cycle budget yields a
    // deterministic frame (no VRAM-touching RNG in the core).
    try stepWithStreamCheck(bus, &cpu, max_cycles, shadow, &shadow_env, &prev_vblank);

    // The last frame is unfinished — the cycle budget does not land on a
    // vblank edge — so drain and apply its tail before comparing.
    const tail = bus.gpu.sink.rec.takeFrame();
    try std.testing.expect(tail.complete);
    ps1_core.gpu.command.replay(tail, shadow, &shadow_env);

    // Stronger than the ratchet below: the ratchet compares a 320x224 display
    // window reduced to 5 bits against a per-test floor, this compares all
    // 1024x512.
    try expectVramEqual(&bus.gpu.vram, shadow);

    // readTestFile panics on FileNotFound (reporting the path); reference.rgb is
    // guaranteed present by Task 2.
    const ref_rgb = try readTestFile(allocator, ref_rgb_path, PL_PIXELS * 3);
    defer allocator.free(ref_rgb);
    if (ref_rgb.len != PL_PIXELS * 3) {
        std.debug.print("\n=== PL TEST: bad reference size {s}: {d} (want {d}) ===\n", .{ ref_rgb_path, ref_rgb.len, PL_PIXELS * 3 });
        return error.RomOutputMismatch;
    }

    const matches = countReferenceMatches(bus, ref_rgb);
    const pct = @as(f64, @floatFromInt(matches)) / @as(f64, @floatFromInt(PL_PIXELS)) * 100.0;

    if (goldensUpdateMode()) {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{matches}) catch unreachable;
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = floor_path, .data = text });
        std.debug.print("[PS1_UPDATE_GOLDENS] {s}: {d}/{d} px ({d:.2}%) -> floor {s}\n", .{ exe_path, matches, PL_PIXELS, pct, floor_path });
        return;
    }

    // Compare mode: missing floor.txt panics in readTestFile with the path —
    // re-run with PS1_UPDATE_GOLDENS=1 to pin it.
    const floor_raw = try readTestFile(allocator, floor_path, 32);
    defer allocator.free(floor_raw);
    const floor_text = std.mem.trim(u8, floor_raw, " \r\n\t");
    const floor = std.fmt.parseInt(usize, floor_text, 10) catch {
        std.debug.print("\n=== PL TEST: bad floor file {s}: '{s}' ===\n", .{ floor_path, floor_text });
        return error.RomOutputMismatch;
    };

    std.debug.print("[PL] {s}: {d}/{d} px ({d:.2}%), floor {d}\n", .{ exe_path, matches, PL_PIXELS, pct, floor });
    if (matches < floor) {
        std.debug.print("\n=== PL TEST FAILED: {s} ===\n", .{exe_path});
        std.debug.print("match {d} < floor {d} ({d:.2}%); GPU regression?\n", .{ matches, floor, pct });
        return error.RomOutputMismatch;
    }
}

test "PL: HelloWorld 16BPP" {
    try runPlTest(
        std.testing.allocator,
        "test-roms/peterlemon/hello-world/HelloWorld16BPP.exe",
        "test-roms/peterlemon/hello-world/reference.rgb",
        "test-roms/peterlemon/hello-world/floor.txt",
        10_000_000,
    );
}

test "PL: CPU ADD" {
    try runPlTest(
        std.testing.allocator,
        "test-roms/peterlemon/cpu/add/CPUADD.exe",
        "test-roms/peterlemon/cpu/add/reference.rgb",
        "test-roms/peterlemon/cpu/add/floor.txt",
        10_000_000,
    );
}

test "PL: GPU RenderPolygon 16BPP" {
    try runPlTest(
        std.testing.allocator,
        "test-roms/peterlemon/gpu/render-polygon/RenderPolygon16BPP.exe",
        "test-roms/peterlemon/gpu/render-polygon/reference.rgb",
        "test-roms/peterlemon/gpu/render-polygon/floor.txt",
        10_000_000,
    );
}

test "PL: GPU RenderLine 16BPP" {
    try runPlTest(
        std.testing.allocator,
        "test-roms/peterlemon/gpu/render-line/RenderLine16BPP.exe",
        "test-roms/peterlemon/gpu/render-line/reference.rgb",
        "test-roms/peterlemon/gpu/render-line/floor.txt",
        10_000_000,
    );
}

test "PL: GPU RenderRectangle 16BPP" {
    try runPlTest(
        std.testing.allocator,
        "test-roms/peterlemon/gpu/render-rectangle/RenderRectangle16BPP.exe",
        "test-roms/peterlemon/gpu/render-rectangle/reference.rgb",
        "test-roms/peterlemon/gpu/render-rectangle/floor.txt",
        10_000_000,
    );
}

test "PL: GPU RenderTexturePolygon 16BPP" {
    try runPlTest(
        std.testing.allocator,
        "test-roms/peterlemon/gpu/render-texture-polygon/RenderTexturePolygon15BPP.exe",
        "test-roms/peterlemon/gpu/render-texture-polygon/reference.rgb",
        "test-roms/peterlemon/gpu/render-texture-polygon/floor.txt",
        10_000_000,
    );
}
