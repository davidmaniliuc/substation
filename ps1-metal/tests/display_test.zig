//! Renders the real display shader offscreen and reads the pixels back.
//!
//! The bug this pins was invisible to every other kind of test: the shader
//! compiled, the pipeline built, and the scale math was right. Only the
//! pixels were wrong: the right and bottom letterbox bars were painted with a
//! stretched copy of the last texel column, because the vertex stage scaled
//! `position` for the letterbox while deriving `uv` from the UNSCALED vertex,
//! leaving those bars inside the oversized triangle.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const harness = @import("harness.zig");
const dh = @import("display_harness.zig");

const display = ps1_metal.display;

const alloc = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const native_pixels = dh.native_pixels;

const Options = struct {
    depth24: bool = false,
    software_display: bool = false,
    vram_fill: u16 = 0x7FFF,
    /// R, G, B, A as the sidecar stores them.
    sidecar: [4]u8 = .{ 0, 0, 0, 0 },
};

const Rendered = struct {
    width: usize,
    bgra: []u8,

    fn deinit(self: Rendered) void {
        alloc.free(self.bgra);
    }

    /// (b, g, r): the target is `.bgra8Unorm`.
    fn pixel(self: Rendered, x: usize, y: usize) [3]u8 {
        return dh.pixel(self.bgra, self.width, x, y);
    }
};

/// Fills VRAM with a solid non-black colour so ANY picture texel is
/// distinguishable from a letterbox bar.
fn render(width: u32, height: u32, o: Options) !Rendered {
    const m = try harness.metal();
    defer m.deinit();
    var pass = try display.DisplayPass.init(m.device, m.lib);
    defer pass.deinit();

    // The render texture keeps the opaque white so every letterbox assertion
    // is unchanged; the shadow is pure red so a test can tell which one the
    // shader read.
    const vram = try dh.vramTexture(alloc, m.device, o.vram_fill);
    defer vram.release();
    const shadow = try alloc.create([native_pixels]u16);
    defer alloc.destroy(shadow);
    @memset(shadow, 0x001F);
    pass.uploadShadow(shadow);
    const side = try dh.sidecarTexture(alloc, m.device, o.sidecar);
    defer side.release();

    var p = dh.params();
    p.depth24 = @intFromBool(o.depth24);
    p.software_display = @intFromBool(o.software_display);
    const s = display.letterboxScale(@floatFromInt(width), @floatFromInt(height));
    p.scale_x = s.x;
    p.scale_y = s.y;
    return .{ .width = width, .bgra = try dh.render(alloc, m, &pass, vram, side, p, width, height) };
}

const black: [3]u8 = .{ 0, 0, 0 };

test "Display: pillarboxBarsAreBlackOnBOTHSides" {
    // 16:9: bars 12.5% of the width on each side, picture in the middle.
    const img = try render(640, 360, .{});
    defer img.deinit();
    const mid = 180;

    try expectEqual(black, img.pixel(0, mid));
    try expectEqual(black, img.pixel(20, mid));
    // The regression: this used to be a smeared copy of the last texel column.
    try expectEqual(black, img.pixel(639, mid));
    try expectEqual(black, img.pixel(619, mid));
    // ...and the picture between them is still drawn.
    try expect(!dh.isBlack(img.pixel(320, mid)));
}

test "Display: letterboxBarsAreBlackOnBOTHSides" {
    // 4:5: bars top and bottom.
    const img = try render(480, 600, .{});
    defer img.deinit();
    const mid = 240;

    try expectEqual(black, img.pixel(mid, 0));
    try expectEqual(black, img.pixel(mid, 20));
    try expectEqual(black, img.pixel(mid, 599));
    try expectEqual(black, img.pixel(mid, 579));
    try expect(!dh.isBlack(img.pixel(mid, 300)));
}

// The point of the aspect lock: at 4:3 the picture reaches all four edges.
test "Display: aFourThreeTargetHasNoBarAtAll" {
    const img = try render(640, 480, .{});
    defer img.deinit();
    for ([_][2]usize{ .{ 0, 0 }, .{ 639, 0 }, .{ 0, 479 }, .{ 639, 479 }, .{ 320, 240 } }) |xy| {
        try expect(!dh.isBlack(img.pixel(xy[0], xy[1])));
    }
}

test "Display: fifteenBppScansOutOfTheRenderTextureNotTheShadow" {
    const img = try render(320, 240, .{});
    defer img.deinit();
    // The render texture is opaque white, the shadow pure red. Anything but
    // white here means the 15bpp branch is reading the wrong texture.
    const b, const g, const r = img.pixel(160, 120);
    try expect(b > 240 and g > 240 and r > 240);
}

test "Display: twentyFourBppScansOutOfTheShadowPermanently" {
    const img = try render(320, 240, .{ .depth24 = true });
    defer img.deinit();
    // 24bpp reconstructs pixels by byte-packing across ADJACENT 16-bit words,
    // arithmetic that N x N replication in the scaled texture destroys. FMV is
    // uploaded through A0 and was never upscaled geometry, so it stays on the
    // shadow forever. Croc and Silent Hill both depend on this.
    //
    // The shadow is 0x001F in every word, so the packed bytes are 1F 00 1F 00:
    // r = 0x1F, g = 0x00, b = 0x1F.
    const b, const g, const r = img.pixel(160, 120);
    try expectEqual(0x1F, r);
    try expectEqual(0x00, g);
    try expectEqual(0x1F, b);
}

test "Display: theSoftwareDisplaySwitchRoutesFifteenBppToTheShadow" {
    const img = try render(320, 240, .{ .software_display = true });
    defer img.deinit();
    // PS1_SOFTWARE_DISPLAY=1: the debug seam for A/B-ing a suspect frame
    // against the software rasterizer without a rebuild. Not a mode, and not
    // a user-facing setting.
    //
    // The shadow is 0x001F: red 5 bits set, green and blue clear.
    const b, const g, const r = img.pixel(160, 120);
    try expect(r > 240);
    try expect(g < 16);
    try expect(b < 16);
}

test "Display: theDisplayPrefersTheSidecarWherePresent" {
    // Alpha 255: the sidecar holds a real eight-bit colour and the display
    // shows it rather than the five-bit VRAM pixel beneath. The render
    // texture is white, so anything but this exact triple means the fallback
    // ran instead.
    const img = try render(320, 240, .{ .sidecar = .{ 10, 20, 30, 255 } });
    defer img.deinit();
    const b, const g, const r = img.pixel(160, 120);
    try expectEqual(10, r);
    try expectEqual(20, g);
    try expectEqual(30, b);
}

test "Display: theDisplayFallsBackToVramWhereTheSidecarIsAbsent" {
    // Alpha 0: whatever the sidecar's colour bytes happen to hold is ignored.
    // Every invalidation degrades to today's picture, which is the whole
    // reason presence is a channel rather than a dirty rectangle.
    const img = try render(320, 240, .{ .sidecar = .{ 10, 20, 30, 0 } });
    defer img.deinit();
    const b, const g, const r = img.pixel(160, 120);
    try expect(r > 240 and g > 240 and b > 240);
}

test "Display: anAbsentPixelExpandsByReplicationJustLikeASidecarPixel" {
    // The fallback and the sidecar must be the SAME expansion, or the boundary
    // of an invalidated rect shows as a seam: one level of difference along a
    // hard edge is exactly the kind of artifact this feature exists to remove.
    //
    // Red = 3: `c << 3 | c >> 2` is 24, which is what the sidecar would hold
    // for that pixel. The old `c / 31.0` is 24.67 and rounds to 25.
    const img = try render(320, 240, .{ .vram_fill = 0x0003 });
    defer img.deinit();
    const b, const g, const r = img.pixel(160, 120);
    try expectEqual(24, r);
    try expectEqual(0, g);
    try expectEqual(0, b);
}

test "Display: twentyFourBppIgnoresTheSidecar" {
    // FMV scans out of the 1x shadow permanently: it byte-packs across
    // adjacent 16-bit words, arithmetic N x N replication destroys. A present
    // sidecar must not divert it: Croc and Silent Hill both depend on this.
    const img = try render(320, 240, .{ .depth24 = true, .sidecar = .{ 10, 20, 30, 255 } });
    defer img.deinit();
    const b, const g, const r = img.pixel(160, 120);
    try expectEqual(0x1F, r);
    try expectEqual(0x00, g);
    try expectEqual(0x1F, b);
}

test "Display: theSoftwareDisplaySeamIgnoresTheSidecar" {
    // PS1_SOFTWARE_DISPLAY exists to A/B a suspect frame against the software
    // rasterizer. A sidecar read here would be comparing the new path against
    // itself.
    const img = try render(320, 240, .{ .software_display = true, .sidecar = .{ 10, 20, 30, 255 } });
    defer img.deinit();
    const b, const g, const r = img.pixel(160, 120);
    try expect(r > 240);
    try expect(g < 16);
    try expect(b < 16);
}

// The letterbox scale is the reason a wrongly-shaped window shows black bars
// rather than a stretched picture, and the reason it used to show a smeared
// copy of the last texel column on the right, which is what these pin.

test "Display letterbox: letterboxIsIdentityOnAFourThreeDrawable" {
    const s = display.letterboxScale(1280, 960);
    try expectEqual(1, s.x);
    try expectEqual(1, s.y);
}

test "Display letterbox: letterboxPillarboxesAWideDrawable" {
    // 16:9; the picture keeps full height and loses width.
    const s = display.letterboxScale(640, 360);
    try expect(@abs(s.x - 0.75) < 1e-6);
    try expectEqual(1, s.y);
}

test "Display letterbox: letterboxLetterboxesATallDrawable" {
    // 4:5; the picture keeps full width and loses height.
    const s = display.letterboxScale(480, 600);
    try expectEqual(1, s.x);
    try expect(@abs(s.y - 0.6) < 1e-6);
}

// The window is aspect-locked, so the ratio lands a hair off 4:3 rather than
// exactly on it. Without the snap, a scale of 0.99999 blacks out the outermost
// pixel column for nothing.
test "Display letterbox: letterboxSnapsToIdentityWithinHalfAPixel" {
    const s = display.letterboxScale(1280.3, 960);
    try expectEqual(1, s.x);
    try expectEqual(1, s.y);
}

// The shader DIVIDES by these, so a zero must not propagate: it would hand the
// vertex stage a NaN uv, which fails every bounds test and reads garbage.
test "Display letterbox: letterboxRejectsADegenerateDrawable" {
    for ([_][2]f64{ .{ 0, 480 }, .{ 640, 0 }, .{ 0, 0 } }) |wh| {
        const s = display.letterboxScale(wh[0], wh[1]);
        try expectEqual(1, s.x);
        try expectEqual(1, s.y);
    }
}

test "Display: paramsForCopiesTheDisplayAndDefaultsTheRest" {
    const p = display.paramsFor(.{ .vram_x = 320, .vram_y = 8, .width = 256, .height = 240, .depth24 = true, .enabled = true });
    try expectEqual(@as(u32, 320), p.vram_x);
    try expectEqual(@as(u32, 8), p.vram_y);
    try expectEqual(@as(u32, 256), p.width);
    try expectEqual(@as(u32, 240), p.height);
    try expectEqual(@as(u32, 1), p.depth24);
    try expectEqual(@as(u32, 1), p.enabled);
    try expectEqual(@as(f32, 1), p.saturation);
    try expectEqual(@as(u32, 1), p.scale);
    try expectEqual(@as(f32, 0), p.band_mix);
}
