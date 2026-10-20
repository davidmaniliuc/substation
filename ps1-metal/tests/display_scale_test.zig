//! The display pass against a real, scaled `MetalVram`, and the pause fade.
//! Ported from DisplayScaleTests.swift.
//!
//! A second texture setup rather than a parameter on display_test's: that
//! one builds a plain managed 1024x512 texture, which cannot be scaled at
//! all. This needs the .private renderTarget+shaderRead texture the live
//! path actually samples.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const harness = @import("harness.zig");
const dh = @import("display_harness.zig");

const display = ps1_metal.display;
const MetalVram = ps1_metal.metal_vram.MetalVram;

const alloc = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const native_width = dh.native_width;
const native_pixels = dh.native_pixels;
const Image = [native_pixels]u16;

const Options = struct {
    /// Overrides `native` when given, for the one test that needs blocks
    /// which are NOT uniform.
    scaled: ?[]const u16 = null,
    shadow: ?*const Image = null,
    drawable: [2]u32 = .{ 320, 240 },
    vram_x: u32 = 0,
    vram_y: u32 = 0,
    depth24: bool = false,
    software_display: bool = false,
};

/// Renders the real display pass offscreen against a `MetalVram` at `scale`
/// and hands back the drawable's BGRA bytes.
fn renderScaled(m: harness.Metal, pass: *display.DisplayPass, native: *const Image, scale: u32, o: Options) ![]u8 {
    var vram = try MetalVram.init(alloc, m.device, m.queue, scale, false);
    defer vram.deinit();
    if (o.scaled) |s| vram.upload(s) else vram.uploadNative(native);
    pass.uploadShadow(o.shadow orelse native);

    var p = dh.params();
    p.vram_x = o.vram_x;
    p.vram_y = o.vram_y;
    p.depth24 = @intFromBool(o.depth24);
    p.software_display = @intFromBool(o.software_display);
    p.scale = scale;
    const s = display.letterboxScale(@floatFromInt(o.drawable[0]), @floatFromInt(o.drawable[1]));
    p.scale_x = s.x;
    p.scale_y = s.y;

    // `upload`/`uploadNative` above clear the sidecar and nothing here draws
    // afterwards, so it is absent everywhere: every pixel falls back to VRAM,
    // preserving this suite's meaning exactly.
    return dh.render(alloc, m, pass, vram.texture, vram.sidecar, p, o.drawable[0], o.drawable[1]);
}

/// A full native VRAM in which practically every pixel differs from its
/// neighbours, so an off-by-one in `nx` or a wrong wrap lands on a visibly
/// different colour instead of an identical one. Deterministic: the same
/// bytes on every run and on both sides of every comparison.
fn lcgImage(seed: u32) !*Image {
    const out = try alloc.create(Image);
    var s = seed;
    for (out) |*w| {
        s = s *% 1664525 +% 1013904223;
        w.* = @truncate((s >> 15) & 0x7FFF);
    }
    return out;
}

const default_seed = 0x2545F491;
const ladder = [_]u32{ 2, 3, 4, 8 };

/// Renders at 1x, then requires every scale in the ladder to match it.
fn expectSameAtEveryScale(native: *const Image, o: Options) !void {
    const m = try harness.metal();
    defer m.deinit();
    var pass = try display.DisplayPass.init(m.device, m.lib);
    defer pass.deinit();
    const one = try renderScaled(m, &pass, native, 1, o);
    defer alloc.free(one);
    for (ladder) |scale| {
        const many = try renderScaled(m, &pass, native, scale, o);
        defer alloc.free(many);
        expectEqualSlices(u8, one, many) catch |e| {
            std.debug.print("scale {d}\n", .{scale});
            return e;
        };
    }
}

test "DisplayScale: theDisplayParamsStrideMatchesTheShaderStruct" {
    // DisplayShader.metal carries `static_assert(sizeof(Params) == 68)`. This
    // is the other half of that pair: a field added on one side only shears
    // every field after it.
    try expectEqual(68, @sizeOf(display.Params));
    // Never 0: the fragment shader divides by it. A default of 0 would be a
    // divide-by-zero on the very first frame after a field reorder.
    try expectEqual(1, dh.params().scale);
}

test "DisplayScale: aBlockUniformTextureDisplaysIdenticallyAtEveryScale" {
    // The display-side analogue of Phase C's exactness property: a scaled
    // texture whose every N x N block is uniform must present byte-identically
    // to the native image at 1x. `uploadNative` produces exactly that, so the
    // fixture is free.
    const image = try lcgImage(default_seed);
    defer alloc.destroy(image);
    try expectSameAtEveryScale(image, .{});
}

test "DisplayScale: aDisplayWindowCrossingTheVramEdgeWrapsNatively" {
    // The case the parent spec got wrong, as its own test rather than a hope
    // that the sweep above happens to cross an edge.
    //
    // vram_x 1000 + 320 columns and vram_y 400 + 240 rows both run off the end
    // of VRAM. Scale 3 is what separates form A -- ((vram_x + nx) & 1023) * s
    // + sub_x -- from the parent spec's `& (1024 * s - 1)`: at s = 3 that mask
    // is 3071, which is not `mod 3072`. At px = 75 the mask gives 2051 where
    // the correct column is 3.
    const image = try lcgImage(default_seed);
    defer alloc.destroy(image);
    try expectSameAtEveryScale(image, .{ .vram_x = 1000, .vram_y = 400 });
}

// The test that fails for a plausible, entirely self-consistent
// implementation: scaling only the WRAPS is a no-op. Every sample then lands
// on its block's top-left subtexel, which by Phase C's exactness property is
// byte-identical to the 1x picture -- the player selects 8x, pays 67 MB and
// sees nothing. No other test here notices, because every other one compares
// against the 1x picture on purpose.
//
// Two named cases over a shared helper rather than one test with an internal
// loop, so a regression at one scale is reported by name. 3 is here on
// purpose: a mask-form split -- `sub_x = px & (p.scale - 1)` -- is wrong at
// s = 3 but identical to `px % s` at s = 2, so a scale-2-only version of this
// test cannot tell the two apart (`/ s` and `% s` are shifts and masks at
// every power of two, and a `>> log2(s)` bug is invisible at 2, 4 and 8).
test "DisplayScale: theDisplayPassSamplesSubtexelsNotJustTheBlockCornerAtScaleTwo" {
    try checkSubtexelSampling(2);
}

test "DisplayScale: theDisplayPassSamplesSubtexelsNotJustTheBlockCornerAtScaleThree" {
    try checkSubtexelSampling(3);
}

fn checkSubtexelSampling(scale: u32) !void {
    const m = try harness.metal();
    defer m.deinit();
    var pass = try display.DisplayPass.init(m.device, m.lib);
    defer pass.deinit();

    const w: usize = native_width * scale;
    const scaled = try alloc.alloc(u16, native_pixels * scale * scale);
    defer alloc.free(scaled);
    @memset(scaled, 0);
    scaled[0] = 0x001F; // native (0,0) subtexel (0,0): red
    scaled[1] = 0x03E0; //                     (1,0): green
    scaled[w] = 0x7C00; //                     (0,1): blue
    scaled[w + 1] = 0x7FFF; //                 (1,1): white
    if (scale >= 3) {
        // (2,0) and (0,2): the subtexels a `& (s - 1)` split gets wrong where
        // `%`/`/` do not.
        scaled[2] = 0x03FF; //                 (2,0): yellow
        scaled[2 * w] = 0x7FE0; //             (0,2): cyan
    }
    const zero = try alloc.create(Image);
    defer alloc.destroy(zero);
    @memset(zero, 0);

    // The drawable is 320 * scale by 240 * scale, so it maps 1:1 onto the
    // scaled sample grid and each subtexel of ONE native pixel lands on a
    // distinct drawable pixel.
    const dw = 320 * scale;
    const dheight = 240 * scale;
    const img = try renderScaled(m, &pass, zero, scale, .{ .scaled = scaled, .drawable = .{ dw, dheight } });
    defer alloc.free(img);

    const px = dh.pixel;
    errdefer std.debug.print("scale {d}\n", .{scale});
    // (b, g, r): the target is .bgra8Unorm.
    const red = px(img, dw, 0, 0);
    try expect(red[2] > 240 and red[1] < 16);
    const green = px(img, dw, 1, 0);
    try expect(green[1] > 240 and green[2] < 16);
    const blue = px(img, dw, 0, 1);
    try expect(blue[0] > 240 and blue[2] < 16);
    const white = px(img, dw, 1, 1);
    try expect(white[0] > 240 and white[1] > 240 and white[2] > 240);
    if (scale >= 3) {
        const yellow = px(img, dw, 2, 0);
        try expect(yellow[0] < 16 and yellow[1] > 240 and yellow[2] > 240);
        const cyan = px(img, dw, 0, 2);
        try expect(cyan[0] > 240 and cyan[1] > 240 and cyan[2] < 16);
    }
}

test "DisplayScale: twentyFourBppDisplaysIdenticallyAtEveryScale" {
    // The trap in the phase. 24bpp reconstructs pixels by byte-packing across
    // ADJACENT 16-bit VRAM words, arithmetic that is meaningless in scaled
    // space -- which is why it reads the 1024x512 shadow permanently. It must
    // be addressed with `nx`/`ny`; `px` at scale 4 reads a column four times
    // too far along and breaks every FMV in Croc and Silent Hill.
    const shadow = try lcgImage(default_seed);
    defer alloc.destroy(shadow);
    // The render texture holds something DIFFERENT, so a 24bpp path that read
    // it instead of the shadow fails here too.
    const render = try lcgImage(0x9E3779B9);
    defer alloc.destroy(render);
    try expectSameAtEveryScale(render, .{ .shadow = shadow, .depth24 = true });
}

test "DisplayScale: theSoftwareDisplaySeamStaysOnTheNativeShadowAtEveryScale" {
    // Same routing rule as 24bpp, same reason: the shadow is 1024x512 at every
    // N, so it is addressed natively or not at all.
    const shadow = try lcgImage(default_seed);
    defer alloc.destroy(shadow);
    const render = try lcgImage(0x9E3779B9);
    defer alloc.destroy(render);
    try expectSameAtEveryScale(render, .{ .shadow = shadow, .software_display = true });
}

test "DisplayScale: aPauseGreysThePictureOutOverAQuarterSecondAndBack" {
    var fade: display.PauseFade = .{};
    // The first draw has no clock to step from: it lands on the target.
    try expectEqual(1, fade.saturation(false, 10));
    const mid = fade.saturation(true, 10.125);
    try expect(mid < 1 and mid > display.PauseFade.paused_saturation);
    try expectEqual(display.PauseFade.paused_saturation, fade.saturation(true, 10.25));
    // A long stall between draws is one full step, never an overshoot.
    try expectEqual(1, fade.saturation(false, 99));
}
