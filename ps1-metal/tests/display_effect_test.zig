//! The display effects, rendered through the real pass and read back. Every
//! test builds a picture whose answer is known from the shape of the effect:
//! a flat field has a regular structure, a lattice has a variance, a step has
//! a width.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const harness = @import("harness.zig");
const dh = @import("display_harness.zig");
const image_io = @import("image_io.zig");

const display = ps1_metal.display;
const mtl = ps1_metal.mtl;
const MetalVram = ps1_metal.metal_vram.MetalVram;

const alloc = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const ColourAt = *const fn (x: usize, y: usize) [3]u8;

/// A picture to draw: VRAM words, plus an eight-bit sidecar when `colours`
/// is given (opaque everywhere, so it is what shows).
const Rig = struct {
    m: harness.Metal,
    pass: display.DisplayPass,
    vram: mtl.Texture,
    side: mtl.Texture,
    owner: ?MetalVram = null,

    const Options = struct {
        word: u16 = 0,
        colours: ?ColourAt = null,
        /// Above 1 the textures are a `MetalVram`'s, uniform in every block.
        scale: u32 = 1,
    };

    fn init(o: Options) !Rig {
        const m = try harness.metal();
        errdefer m.deinit();
        var pass = try display.DisplayPass.init(m.device, m.lib);
        errdefer pass.deinit();
        if (o.scale > 1) {
            var owner = try MetalVram.init(alloc, m.device, m.queue, o.scale, false);
            errdefer owner.deinit();
            const native = try alloc.create([dh.native_pixels]u16);
            defer alloc.destroy(native);
            @memset(native, o.word);
            owner.uploadNative(native);
            return .{ .m = m, .pass = pass, .vram = owner.texture, .side = owner.sidecar, .owner = owner };
        }
        const vram = try dh.vramTexture(alloc, m.device, o.word);
        errdefer vram.release();
        const side = if (o.colours) |f| try sidecarOf(m.device, f) else try dh.sidecarTexture(alloc, m.device, .{ 0, 0, 0, 0 });
        return .{ .m = m, .pass = pass, .vram = vram, .side = side };
    }

    fn deinit(self: *Rig) void {
        if (self.owner) |*o| {
            o.deinit();
        } else {
            self.vram.release();
            self.side.release();
        }
        self.pass.deinit();
        self.m.deinit();
    }

    fn sidecarOf(device: mtl.Device, f: ColourAt) !mtl.Texture {
        const px = try alloc.alloc([4]u8, dh.native_pixels);
        defer alloc.free(px);
        for (px, 0..) |*o, i| {
            const c = f(i % dh.native_width, i / dh.native_width);
            o.* = .{ c[0], c[1], c[2], 255 };
        }
        return dh.managedTexture(device, .rgba8Uint, 4, std.mem.sliceAsBytes(px));
    }

    fn base(scale: u32) display.Params {
        var p = dh.params();
        p.scale = scale;
        return p;
    }

    /// Draws `fx` over `p` into a `w` x `h` drawable with the letterbox fitted.
    fn draw(self: *Rig, fx: display.Effect, p: display.Params, w: u32, h: u32) ![]u8 {
        const q = dh.fitted(p, w, h);
        return self.drawWith(fx, q, display.effectParams(q, .{ @floatFromInt(w), @floatFromInt(h) }), w, h);
    }

    fn drawWith(self: *Rig, fx: display.Effect, p: display.Params, e: display.EffectParams, w: u32, h: u32) ![]u8 {
        return dh.renderEffect(alloc, self.m, &self.pass, self.vram, self.side, p, e, fx, w, h);
    }
};

const effects = [_]display.Effect{ .sharp_bilinear, .scanlines, .crt, .composite };

fn lcgColour(x: usize, y: usize) [3]u8 {
    var s: u32 = @truncate(x *% 2654435761 +% y *% 40503 +% 12345);
    s = s *% 1664525 +% 1013904223;
    s = s *% 1664525 +% 1013904223;
    return .{ @truncate(s >> 8), @truncate(s >> 16), @truncate(s >> 24) };
}

fn channelSum(px: [3]u8) u32 {
    return @as(u32, px[0]) + px[1] + px[2];
}

// MARK: Plumbing

test "DisplayEffect: noneThroughEncodeEffectIsTheSamePictureAsEncode" {
    var rig = try Rig.init(.{ .colours = lcgColour });
    defer rig.deinit();
    var p = Rig.base(1);
    p.saturation = 0.7;
    const w = 800;
    const h = 450;
    var q = dh.fitted(p, w, h);
    display.applyBand(&q, .{ .height = 52, .edge = 10, .sigma = 8 }, 1, .{ w, h }, .{ 400, 225 });
    const want = try dh.render(alloc, rig.m, &rig.pass, rig.vram, rig.side, q, w, h);
    defer alloc.free(want);
    const got = try rig.drawWith(.none, q, display.effectParams(q, .{ w, h }), w, h);
    defer alloc.free(got);
    try expectEqualSlices(u8, want, got);
    try expect(rig.pass.picture == null);
}

test "DisplayEffect: aDisabledDisplayIsBlackUnderEveryEffect" {
    var rig = try Rig.init(.{ .word = 0x7FFF });
    defer rig.deinit();
    var p = Rig.base(1);
    p.enabled = 0;
    for (effects) |fx| {
        const img = try rig.draw(fx, p, 640, 480);
        defer alloc.free(img);
        for (0..640 * 480) |i| try expect(dh.isBlack(.{ img[i * 4], img[i * 4 + 1], img[i * 4 + 2] }));
    }
}

test "DisplayEffect: theBarsAreBlackUnderEveryEffect" {
    var rig = try Rig.init(.{ .word = 0x7FFF });
    defer rig.deinit();
    for (effects) |fx| {
        const img = try rig.draw(fx, Rig.base(1), 1600, 900);
        defer alloc.free(img);
        try expect(dh.isBlack(dh.pixel(img, 1600, 0, 450)));
        try expect(dh.isBlack(dh.pixel(img, 1600, 150, 450)));
        try expect(dh.isBlack(dh.pixel(img, 1600, 1599, 450)));
        try expect(!dh.isBlack(dh.pixel(img, 1600, 800, 450)) or fx == .scanlines or fx == .crt);
    }
}

test "DisplayEffect: thePictureIsReallocatedOnlyWhenItsSizeChanges" {
    var rig = try Rig.init(.{ .word = 0x7FFF });
    defer rig.deinit();
    const device = rig.m.device;
    try expect(rig.pass.picture == null);
    try expect(rig.pass.ensurePicture(device, 320, 240));
    const first = rig.pass.picture.?.id;
    try expect(rig.pass.ensurePicture(device, 320, 240));
    try expectEqual(first, rig.pass.picture.?.id);
    try expect(rig.pass.ensurePicture(device, 960, 720));
    try expectEqual(960, rig.pass.picture.?.width());
    try expectEqual(720, rig.pass.picture.?.height());
    rig.pass.dropPicture();
    try expect(rig.pass.picture == null);
    rig.pass.dropPicture();
}

test "DisplayEffect: anEffectDrawsThePictureAtTheInternalResolution" {
    var rig = try Rig.init(.{ .word = 0x7FFF, .scale = 3 });
    defer rig.deinit();
    const img = try rig.draw(.sharp_bilinear, Rig.base(3), 640, 480);
    alloc.free(img);
    try expectEqual(960, rig.pass.picture.?.width());
    try expectEqual(720, rig.pass.picture.?.height());
    // An effect turned off holds no picture, and the next frame still draws.
    rig.pass.dropPicture();
    const again = try rig.draw(.none, Rig.base(3), 640, 480);
    alloc.free(again);
    try expect(rig.pass.picture == null);
}

// MARK: Sharp Bilinear

test "DisplayEffect: sharpBilinearAtAWholeRatioIsTheNearestPicture" {
    var rig = try Rig.init(.{ .colours = lcgColour });
    defer rig.deinit();
    for ([_][2]u32{ .{ 1280, 960 }, .{ 960, 720 }, .{ 640, 480 } }) |wh| {
        const none = try rig.draw(.none, Rig.base(1), wh[0], wh[1]);
        defer alloc.free(none);
        const sharp = try rig.draw(.sharp_bilinear, Rig.base(1), wh[0], wh[1]);
        defer alloc.free(sharp);
        expectEqualSlices(u8, none, sharp) catch |err| {
            std.debug.print("{d}x{d}\n", .{ wh[0], wh[1] });
            return err;
        };
    }
}

test "DisplayEffect: sharpBilinearAtAWholeRatioOfAScaledPictureIsTheNearestPicture" {
    var rig = try Rig.init(.{ .word = 0x03E0, .scale = 3 });
    defer rig.deinit();
    const none = try rig.draw(.none, Rig.base(3), 1920, 1440);
    defer alloc.free(none);
    const sharp = try rig.draw(.sharp_bilinear, Rig.base(3), 1920, 1440);
    defer alloc.free(sharp);
    try expectEqualSlices(u8, none, sharp);
}

fn halves(x: usize, _: usize) [3]u8 {
    return if (x < 160) .{ 0, 0, 0 } else .{ 255, 255, 255 };
}

test "DisplayEffect: sharpBilinearBlendsOnlyAtATexelEdgeWhereTheRatioIsNotWhole" {
    var rig = try Rig.init(.{ .colours = halves });
    defer rig.deinit();
    // 1.5 drawable pixels a texel: the prescale is 1, so a plain bilinear
    // blend across the one edge, and nowhere else.
    const img = try rig.draw(.sharp_bilinear, Rig.base(1), 480, 360);
    defer alloc.free(img);
    try expectEqual(0, dh.pixel(img, 480, 100, 100)[0]);
    try expectEqual(255, dh.pixel(img, 480, 400, 100)[0]);
    var between: usize = 0;
    for (0..480) |x| {
        const v = dh.pixel(img, 480, x, 100)[0];
        if (v != 0 and v != 255) between += 1;
    }
    try expect(between >= 1 and between <= 3);
}

// MARK: Scanlines

/// The colour of column `x` down rows `y0...y1`.
fn column(img: []const u8, width: usize, x: usize, y0: usize, y1: usize, out: []u8) void {
    for (y0..y1) |y| out[y - y0] = dh.pixel(img, width, x, y)[1];
}

test "DisplayEffect: scanlinesDarkenTheGapBetweenNativeRows" {
    var rig = try Rig.init(.{ .word = 0x7FFF });
    defer rig.deinit();
    // 4 drawable pixels a scan row: the two middle pixels are the line.
    const img = try rig.draw(.scanlines, Rig.base(1), 1280, 960);
    defer alloc.free(img);
    for (10..40) |r| {
        try expectEqual(255, dh.pixel(img, 1280, 640, r * 4 + 1)[1]);
        try expectEqual(255, dh.pixel(img, 1280, 640, r * 4 + 2)[1]);
        try expect(dh.pixel(img, 1280, 640, r * 4)[1] < 200);
        try expect(dh.pixel(img, 1280, 640, r * 4 + 3)[1] < 200);
    }
}

test "DisplayEffect: scanlinesKeepBlackBlack" {
    var rig = try Rig.init(.{ .word = 0 });
    defer rig.deinit();
    const img = try rig.draw(.scanlines, Rig.base(1), 1280, 960);
    defer alloc.free(img);
    for (0..1280 * 960) |i| try expect(dh.isBlack(.{ img[i * 4], img[i * 4 + 1], img[i * 4 + 2] }));
}

test "DisplayEffect: theLinesFollowNativeRowsAtEveryInternalScale" {
    var rig1 = try Rig.init(.{ .word = 0x7FFF });
    defer rig1.deinit();
    const want = try rig1.draw(.scanlines, Rig.base(1), 1280, 960);
    defer alloc.free(want);
    for ([_]u32{ 3, 8 }) |scale| {
        var rig = try Rig.init(.{ .word = 0x7FFF, .scale = scale });
        defer rig.deinit();
        const got = try rig.draw(.scanlines, Rig.base(scale), 1280, 960);
        defer alloc.free(got);
        expectEqualSlices(u8, want, got) catch |err| {
            std.debug.print("scale {d}\n", .{scale});
            return err;
        };
    }
}

test "DisplayEffect: anInterlacedDisplayDrawsOneLinePerPairOfRows" {
    var rig = try Rig.init(.{ .word = 0x7FFF });
    defer rig.deinit();
    var p = Rig.base(1);
    p.height = 480;
    const img = try rig.draw(.scanlines, p, 1280, 960);
    defer alloc.free(img);
    var col: [64]u8 = undefined;
    column(img, 1280, 640, 16, 80, &col);
    for (0..col.len - 4) |i| try expectEqual(col[i], col[i + 4]);
    var differs = false;
    for (0..col.len - 2) |i| differs = differs or col[i] != col[i + 2];
    try expect(differs);
}

test "DisplayEffect: scanlinesFadeOutWhereARowHasNoRoom" {
    var rig = try Rig.init(.{ .colours = lcgColour });
    defer rig.deinit();
    // 2 drawable pixels a row: the effect is the sharp picture, untouched.
    const lines = try rig.draw(.scanlines, Rig.base(1), 640, 480);
    defer alloc.free(lines);
    const sharp = try rig.draw(.sharp_bilinear, Rig.base(1), 640, 480);
    defer alloc.free(sharp);
    try expectEqualSlices(u8, sharp, lines);
    // Between the floors it is partway: darker than the sharp picture, not as
    // dark as in full.
    var p = Rig.base(1);
    p.height = 240;
    const w = 800;
    const h = 600;
    const q = dh.fitted(p, w, h);
    var half = display.effectParams(q, .{ w, h });
    half.scan_strength = 0.5;
    var full = half;
    full.scan_strength = 1;
    var rig2 = try Rig.init(.{ .word = 0x7FFF });
    defer rig2.deinit();
    const mid = try rig2.drawWith(.scanlines, q, half, w, h);
    defer alloc.free(mid);
    const top = try rig2.drawWith(.scanlines, q, full, w, h);
    defer alloc.free(top);
    var darkest_mid: u8 = 255;
    var darkest_top: u8 = 255;
    for (0..h) |y| {
        darkest_mid = @min(darkest_mid, dh.pixel(mid, w, 400, y)[1]);
        darkest_top = @min(darkest_top, dh.pixel(top, w, 400, y)[1]);
    }
    try expect(darkest_top < darkest_mid and darkest_mid < 255);
}

// MARK: CRT

test "DisplayEffect: crtKeepsBlackBlack" {
    var rig = try Rig.init(.{ .word = 0 });
    defer rig.deinit();
    const img = try rig.draw(.crt, Rig.base(1), 1920, 1440);
    defer alloc.free(img);
    for (0..1920 * 1440) |i| try expect(dh.isBlack(.{ img[i * 4], img[i * 4 + 1], img[i * 4 + 2] }));
}

test "DisplayEffect: theMaskRepeatsEveryThreeDrawablePixels" {
    var rig = try Rig.init(.{ .word = 0x4210 });
    defer rig.deinit();
    const w = 1920;
    const img = try rig.draw(.crt, Rig.base(1), w, 1440);
    defer alloc.free(img);
    // The centre of a scan row, away from the edges.
    const y = 6 * 60 + 3;
    for (600..700) |x| {
        try expectEqual(dh.pixel(img, w, x, y), dh.pixel(img, w, x + 3, y));
    }
    // And a stripe is a colour: no two of three neighbours are the same.
    const a = dh.pixel(img, w, 600, y);
    const b = dh.pixel(img, w, 601, y);
    const c = dh.pixel(img, w, 602, y);
    try expect(!std.mem.eql(u8, &a, &b) and !std.mem.eql(u8, &b, &c) and !std.mem.eql(u8, &a, &c));
    // Each stripe is led by its own channel.
    var leaders: [3]usize = undefined;
    for ([_][3]u8{ a, b, c }, 0..) |px, i| leaders[i] = std.mem.indexOfMax(u8, &px);
    try expect(leaders[0] != leaders[1] and leaders[1] != leaders[2] and leaders[0] != leaders[2]);
}

test "DisplayEffect: theMaskIsAbsentBelowItsFloor" {
    var rig = try Rig.init(.{ .word = 0x4210 });
    defer rig.deinit();
    // 3 drawable pixels a native column: under the mask's 4.5 ceiling the
    // fade is zero at 3, so the picture is flat along a scan row.
    const w = 960;
    const img = try rig.draw(.crt, Rig.base(1), w, 720);
    defer alloc.free(img);
    for ([_]usize{ 3 * 100 + 1, 3 * 100 + 2 }) |y| {
        for (200..700) |x| try expectEqual(dh.pixel(img, w, 200, y), dh.pixel(img, w, x, y));
    }
}

fn meanLinear(img: []const u8, width: usize, x0: usize, x1: usize, y0: usize, y1: usize) f64 {
    var sum: f64 = 0;
    var n: f64 = 0;
    for (y0..y1) |y| {
        for (x0..x1) |x| {
            for (dh.pixel(img, width, x, y)) |v| {
                const c = @as(f64, @floatFromInt(v)) / 255.0;
                sum += c * c;
                n += 1;
            }
        }
    }
    return sum / n;
}

test "DisplayEffect: theMaskKeepsTheMeanBrightness" {
    var rig = try Rig.init(.{ .word = 0x4210 });
    defer rig.deinit();
    const w = 1920;
    const q = dh.fitted(Rig.base(1), w, 1440);
    const on = display.effectParams(q, .{ w, 1440 });
    var off = on;
    off.mask_strength = 0;
    const masked = try rig.drawWith(.crt, q, on, w, 1440);
    defer alloc.free(masked);
    const plain = try rig.drawWith(.crt, q, off, w, 1440);
    defer alloc.free(plain);
    const with = meanLinear(masked, w, 600, 900, 360, 720);
    const without = meanLinear(plain, w, 600, 900, 360, 720);
    try expect(@abs(with - without) / without < 0.03);
}

test "DisplayEffect: aBrightRowBleedsIntoTheGapButADimOneDoesNot" {
    var rig = try Rig.init(.{ .word = 0x7FFF });
    defer rig.deinit();
    var dim = try Rig.init(.{ .word = 0x1084 });
    defer dim.deinit();
    const w = 1920;
    const bright = try rig.draw(.crt, Rig.base(1), w, 1440);
    defer alloc.free(bright);
    const faint = try dim.draw(.crt, Rig.base(1), w, 1440);
    defer alloc.free(faint);
    // The pixel in a gap (a row's edge) against the row's centre, in the
    // stripe's lead channel summed over a triad.
    const y_centre = 6 * 60 + 3;
    const y_gap = 6 * 60;
    var ratio: [2]f64 = undefined;
    for ([_][]const u8{ bright, faint }, 0..) |img, i| {
        var centre: f64 = 0;
        var gap: f64 = 0;
        for (600..603) |x| {
            centre += @floatFromInt(channelSum(dh.pixel(img, w, x, y_centre)));
            gap += @floatFromInt(channelSum(dh.pixel(img, w, x, y_gap)));
        }
        ratio[i] = gap / centre;
    }
    try expect(ratio[0] > ratio[1]);
}

// MARK: Composite

fn flatColour(_: usize, _: usize) [3]u8 {
    return .{ 200, 90, 40 };
}

test "DisplayEffect: compositeLeavesAFlatFieldFlat" {
    var rig = try Rig.init(.{ .colours = flatColour });
    defer rig.deinit();
    const none = try rig.draw(.none, Rig.base(1), 1280, 960);
    defer alloc.free(none);
    const img = try rig.draw(.composite, Rig.base(1), 1280, 960);
    defer alloc.free(img);
    for (0..1280 * 960) |i| {
        for (0..3) |c| {
            const d = @as(i32, img[i * 4 + c]) - none[i * 4 + c];
            try expect(@abs(d) <= 1);
        }
    }
}

const dither = [4][4]i32{
    .{ -4, 0, -3, 1 },
    .{ 2, -2, 3, -1 },
    .{ -3, 1, -4, 0 },
    .{ 3, -1, 2, -2 },
};

/// A slow ramp the way the PS1 draws one: each channel's level plus the
/// lattice offset, cut to five bits and expanded to eight. The ramp crosses
/// every phase of the lattice against the five-bit steps.
fn dithered(x: usize, y: usize) [3]u8 {
    const starts = [3]f64{ 96, 120, 88 };
    var out: [3]u8 = undefined;
    for (starts, 0..) |start, c| {
        const level: i32 = @intFromFloat(start + @as(f64, @floatFromInt(x)) * 0.1);
        const v: u32 = @intCast(std.math.clamp(level + dither[y % 4][x % 4], 0, 255));
        const q = v >> 3;
        out[c] = @intCast((q << 3) | (q >> 2));
    }
    return .{ out[2], out[1], out[0] };
}

/// How rough the lattice is: the variance of the channel sum within each
/// aligned 4x4 block of native pixels (read at each pixel's centre of a 4x
/// drawable), averaged over the picture's middle, and the picture's mean.
fn latticeStats(img: []const u8, w: usize) struct { mean: f64, roughness: f64 } {
    var total: f64 = 0;
    var sum: f64 = 0;
    var blocks: f64 = 0;
    var n: f64 = 0;
    var by: usize = 10;
    while (by < 50) : (by += 1) {
        var bx: usize = 10;
        while (bx < 70) : (bx += 1) {
            var s: f64 = 0;
            var sq: f64 = 0;
            for (0..4) |dy| {
                for (0..4) |dx| {
                    const v: f64 = @floatFromInt(channelSum(dh.pixel(img, w, (bx * 4 + dx) * 4 + 2, (by * 4 + dy) * 4 + 2)));
                    s += v;
                    sq += v * v;
                }
            }
            const mean = s / 16;
            total += sq / 16 - mean * mean;
            sum += s;
            blocks += 1;
            n += 16;
        }
    }
    return .{ .mean = sum / n, .roughness = total / blocks };
}

test "DisplayEffect: compositeMeltsTheDitherLatticeAndKeepsItsMean" {
    var rig = try Rig.init(.{ .colours = dithered });
    defer rig.deinit();
    const w = 1280;
    const none = try rig.draw(.none, Rig.base(1), w, 960);
    defer alloc.free(none);
    const img = try rig.draw(.composite, Rig.base(1), w, 960);
    defer alloc.free(img);
    const before = latticeStats(none, w);
    const after = latticeStats(img, w);
    std.debug.print("dither: roughness {d:.2} -> {d:.2}, mean {d:.2} -> {d:.2}\n", .{ before.roughness, after.roughness, before.mean, after.mean });
    try expect(before.roughness > 10);
    try expect(after.roughness < before.roughness * 0.5);
    try expect(@abs(after.mean - before.mean) < 2);
}

fn lumaStep(x: usize, _: usize) [3]u8 {
    return if (x < 160) .{ 64, 64, 64 } else .{ 192, 192, 192 };
}

/// Two colours with the same luma and far apart chroma.
fn chromaStep(x: usize, _: usize) [3]u8 {
    return if (x < 160) .{ 40, 150, 180 } else .{ 200, 100, 30 };
}

fn yiq(px: [3]u8) [3]f64 {
    const b: f64 = @floatFromInt(px[0]);
    const g: f64 = @floatFromInt(px[1]);
    const r: f64 = @floatFromInt(px[2]);
    return .{
        0.299 * r + 0.587 * g + 0.114 * b,
        0.595716 * r - 0.274453 * g - 0.321263 * b,
        0.211456 * r - 0.522591 * g + 0.311135 * b,
    };
}

/// How many of the 4x drawable's native pixels along row 400 sit strictly
/// inside the 10%...90% of component `c`'s step.
fn transitionWidth(img: []const u8, w: usize, c: usize) usize {
    const lo = yiq(dh.pixel(img, w, 60 * 4 + 2, 400))[c];
    const hi = yiq(dh.pixel(img, w, 260 * 4 + 2, 400))[c];
    var n: usize = 0;
    for (100..220) |x| {
        const t = (yiq(dh.pixel(img, w, x * 4 + 2, 400))[c] - lo) / (hi - lo);
        if (t > 0.1 and t < 0.9) n += 1;
    }
    return n;
}

test "DisplayEffect: compositeSpreadsChromaWiderThanLuma" {
    var rig_l = try Rig.init(.{ .colours = lumaStep });
    defer rig_l.deinit();
    var rig_c = try Rig.init(.{ .colours = chromaStep });
    defer rig_c.deinit();
    const w = 1280;
    const luma = try rig_l.draw(.composite, Rig.base(1), w, 960);
    defer alloc.free(luma);
    const chroma = try rig_c.draw(.composite, Rig.base(1), w, 960);
    defer alloc.free(chroma);
    const luma_width = transitionWidth(luma, w, 0);
    const chroma_width = transitionWidth(chroma, w, 1);
    std.debug.print("composite: luma step {d} px, chroma step {d} px\n", .{ luma_width, chroma_width });
    try expect(chroma_width > luma_width);
}

// MARK: Band and saturation

fn spread(px: [3]u8) i32 {
    return @as(i32, @max(px[0], @max(px[1], px[2]))) - @min(px[0], @min(px[1], px[2]));
}

test "DisplayEffect: thePausedGreyOutReachesEveryEffect" {
    var rig = try Rig.init(.{ .colours = flatColour });
    defer rig.deinit();
    for (effects) |fx| {
        const full = try rig.draw(fx, Rig.base(1), 1920, 1440);
        defer alloc.free(full);
        var p = Rig.base(1);
        p.saturation = 0.5;
        const grey = try rig.draw(fx, p, 1920, 1440);
        defer alloc.free(grey);
        // Away from a scan row's gap, where the colour is the picture's.
        const y = 6 * 60 + 3;
        const a = spread(dh.pixel(full, 1920, 900, y));
        const b = spread(dh.pixel(grey, 1920, 900, y));
        try expect(a > 40);
        try expect(b * 10 < a * 6);
    }
}

test "DisplayEffect: theToolbarBandReachesEveryEffectAndOnlyTheStripUnderIt" {
    var rig = try Rig.init(.{ .colours = flatColour });
    defer rig.deinit();
    const w = 1280;
    const h = 960;
    var p = dh.fitted(Rig.base(1), w, h);
    const e = display.effectParams(p, .{ w, h });
    for (effects) |fx| {
        const bare = try rig.drawWith(fx, p, e, w, h);
        defer alloc.free(bare);
        var banded = p;
        display.applyBand(&banded, .{ .height = 52, .edge = 10, .sigma = 8 }, 1, .{ w, h }, .{ w, h });
        const shown = try rig.drawWith(fx, banded, e, w, h);
        defer alloc.free(shown);
        // The band is 52 px high; below it the picture is untouched. Over a
        // scan row's dark gap the band is the brighter of the two, so only
        // that it changed is asserted.
        try expect(!std.mem.eql(u8, &dh.pixel(shown, w, 640, 20), &dh.pixel(bare, w, 640, 20)));
        for (200..220) |y| try expectEqual(dh.pixel(bare, w, 640, y), dh.pixel(shown, w, 640, y));
    }
    p.saturation = 1;
}

// MARK: Eyeballing

const dump_frames = [_]struct { name: []const u8, frame: usize }{
    .{ .name = "silent-hill-usa", .frame = 74 },
    .{ .name = "crash-bandicoot-warped", .frame = 60 },
};

/// The 320x240 window of the top two rows of a double buffer holding the
/// most picture: a fixture has no display record, and a picture is what
/// is wanted.
fn busiestWindow(pixels: []const u16) u32 {
    var best_y: u32 = 0;
    var best: usize = 0;
    for ([_]u32{ 0, 240 }) |y0| {
        var n: usize = 0;
        for (y0..y0 + 240) |y| {
            for (0..320) |x| n += @intFromBool(pixels[y * dh.native_width + x] != 0);
        }
        if (n > best) {
            best = n;
            best_y = y0;
        }
    }
    return best_y;
}

// Writes every effect over a real frame at 1920x1440 into `zig-out/effects`,
// for looking at: nothing asserts on it. Opt in with
//
//     PS1_DUMP_EFFECTS=1 zig build test-metal -Doptimize=ReleaseFast -Dmetal-filter=dumpEveryEffect
test "DisplayEffect: dumpEveryEffectOverARealFrame" {
    if (harness.gateSwitch("PS1_DUMP_EFFECTS") == null) {
        std.debug.print("PS1_DUMP_EFFECTS is unset; set it to write one PNG per effect to zig-out/effects\n", .{});
        return error.SkipZigTest;
    }
    const m = try harness.metal();
    defer m.deinit();
    var pass = try display.DisplayPass.init(m.device, m.lib);
    defer pass.deinit();
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-out/effects");

    var written: usize = 0;
    for (dump_frames) |g| {
        if (!harness.fixtureExists(alloc, g.name)) continue;
        const parsed = try harness.loadFixture(alloc, g.name);
        defer parsed.deinit(alloc);
        const rig = try harness.Rig.create(alloc, m, .{});
        defer rig.destroy();
        rig.r.dither_mode = .scaled;
        for (0..@min(g.frame + 1, parsed.frames.len)) |i| {
            const pool = ps1_metal.objc.Pool.push();
            defer pool.pop();
            const s = parsed.frameStream(i);
            rig.frame(s.payload, s.records);
        }
        const native = try alloc.alloc(u16, dh.native_pixels);
        defer alloc.free(native);
        rig.vram.readback(native);

        var p = dh.params();
        p.vram_y = busiestWindow(native);
        const w = 1920;
        const h = 1440;
        const q = dh.fitted(p, w, h);
        const e = display.effectParams(q, .{ w, h });
        for ([_]display.Effect{ .none, .sharp_bilinear, .scanlines, .crt, .composite }) |fx| {
            const bgra = try dh.renderEffect(alloc, m, &pass, rig.vram.texture, rig.vram.sidecar, q, e, fx, w, h);
            defer alloc.free(bgra);
            for (0..w * h) |i| std.mem.swap(u8, &bgra[i * 4], &bgra[i * 4 + 2]);
            const path = try std.fmt.allocPrint(alloc, "zig-out/effects/{s}-{s}.png", .{ g.name, @tagName(fx) });
            defer alloc.free(path);
            try image_io.writeRgba(path, bgra, w, h);
            std.debug.print("[effects] {s} (window y {d})\n", .{ path, p.vram_y });
        }
        written += 1;
    }
    if (written == 0) {
        std.debug.print("no fixture to draw: run `zig build fixtures -Doptimize=ReleaseFast`\n", .{});
        return error.SkipZigTest;
    }
}
