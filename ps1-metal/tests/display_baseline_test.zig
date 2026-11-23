//! The display pass's own picture, pinned byte for byte over a spread of
//! configurations, so a rewrite of its shader that must not move a pixel
//! cannot move one unseen. The hashes are of what the shader drew when they
//! were pinned, on varied content: every pixel differs from its neighbours,
//! and the sidecar holds some pixels and not others.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const harness = @import("harness.zig");
const dh = @import("display_harness.zig");

const display = ps1_metal.display;
const mtl = ps1_metal.mtl;
const alloc = std.testing.allocator;

const Case = struct {
    name: []const u8,
    scale: u32 = 1,
    drawable: [2]u32 = .{ 640, 480 },
    width: u32 = 320,
    height: u32 = 240,
    vram_x: u32 = 0,
    vram_y: u32 = 0,
    depth24: bool = false,
    software_display: bool = false,
    saturation: f32 = 1,
    band_mix: f32 = 0,
    /// The drawable's size in points, for the band's pixels-per-point.
    points: [2]f64 = .{ 640, 480 },
    hash: u64,
};

const band: display.Band = .{ .height = 52, .edge = 10, .sigma = 8 };

const cases = [_]Case{
    .{ .name = "plain 15bpp, sidecar over vram", .hash = 0x61928a175dfd6b65 },
    .{ .name = "saturation 0.6", .saturation = 0.6, .hash = 0x98d1ca7b947331b5 },
    .{ .name = "24bpp", .depth24 = true, .hash = 0x910fd73b9c53baad },
    .{ .name = "software seam", .software_display = true, .hash = 0x73c766c4a170773d },
    .{ .name = "band, letterboxed", .drawable = .{ 800, 450 }, .points = .{ 400, 225 }, .band_mix = 1, .hash = 0xf9e3260e150a01fa },
    .{ .name = "band half shown, saturated down", .band_mix = 0.5, .saturation = 0.6, .points = .{ 320, 240 }, .hash = 0x32d634da269a1202 },
    .{ .name = "scale 3", .scale = 3, .drawable = .{ 960, 720 }, .hash = 0x7b0f64e16a4003b0 },
    .{ .name = "scale 3, display crossing the vram edge", .scale = 3, .drawable = .{ 960, 720 }, .vram_x = 1000, .vram_y = 400, .hash = 0x485824be875a56e7 },
    .{ .name = "scale 3, band", .scale = 3, .band_mix = 1, .points = .{ 640, 480 }, .hash = 0xd591fa1496922513 },
    .{ .name = "scale 2, 24bpp, tall display", .scale = 2, .depth24 = true, .height = 480, .drawable = .{ 640, 640 }, .hash = 0xdea125da79879d5d },
};

fn lcg(s: *u32) u32 {
    s.* = s.* *% 1664525 +% 1013904223;
    return s.* >> 8;
}

fn texture(device: mtl.Device, format: ps1_metal.mtl_enums.PixelFormat, bytes_per_pixel: usize, scale: u32, bytes: []const u8) !mtl.Texture {
    const w = dh.native_width * scale;
    const h = dh.native_height * scale;
    const t = try device.newTexture2D(.{ .format = format, .width = w, .height = h, .storage = .managed, .usage = .{ .shaderRead = true } });
    t.replaceRegion(.{
        .origin = .{ .x = 0, .y = 0, .z = 0 },
        .size = .{ .width = w, .height = h, .depth = 1 },
    }, bytes, w * bytes_per_pixel);
    return t;
}

fn draw(m: harness.Metal, c: Case) ![]u8 {
    var pass = try display.DisplayPass.init(m.device, m.lib);
    defer pass.deinit();

    const count = @as(usize, dh.native_pixels) * c.scale * c.scale;
    const words = try alloc.alloc(u16, count);
    defer alloc.free(words);
    const side = try alloc.alloc([4]u8, count);
    defer alloc.free(side);
    var seed: u32 = 0x2545F491;
    for (words, side) |*w, *s| {
        w.* = @truncate(lcg(&seed) & 0x7FFF);
        const r = lcg(&seed);
        s.* = .{ @truncate(r), @truncate(r >> 8), @truncate(r >> 16), if (r & 0x4000_00 != 0) 255 else 0 };
    }
    const vram = try texture(m.device, .r16Uint, 2, c.scale, std.mem.sliceAsBytes(words));
    defer vram.release();
    const sidecar = try texture(m.device, .rgba8Uint, 4, c.scale, std.mem.sliceAsBytes(side));
    defer sidecar.release();

    const shadow = try alloc.create([dh.native_pixels]u16);
    defer alloc.destroy(shadow);
    for (shadow) |*w| w.* = @truncate(lcg(&seed) & 0x7FFF);
    pass.uploadShadow(shadow);

    var p = dh.params();
    p.vram_x = c.vram_x;
    p.vram_y = c.vram_y;
    p.width = c.width;
    p.height = c.height;
    p.depth24 = @intFromBool(c.depth24);
    p.software_display = @intFromBool(c.software_display);
    p.scale = c.scale;
    p.saturation = c.saturation;
    const w: f64 = @floatFromInt(c.drawable[0]);
    const h: f64 = @floatFromInt(c.drawable[1]);
    const box = display.letterboxScale(w, h);
    p.scale_x = box.x;
    p.scale_y = box.y;
    if (c.band_mix > 0) display.applyBand(&p, band, c.band_mix, .{ w, h }, c.points);
    return dh.render(alloc, m, &pass, vram, sidecar, p, c.drawable[0], c.drawable[1]);
}

test "Display: theDisplayPassDrawsExactlyWhatItDrewWhenThisWasPinned" {
    const m = try harness.metal();
    defer m.deinit();
    var failed = false;
    for (cases) |c| {
        const bgra = try draw(m, c);
        defer alloc.free(bgra);
        const got = std.hash.Fnv1a_64.hash(bgra);
        if (got != c.hash) {
            std.debug.print("{s}: 0x{x} (pinned 0x{x})\n", .{ c.name, got, c.hash });
            failed = true;
        }
    }
    try std.testing.expect(!failed);
}
