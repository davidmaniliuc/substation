//! A screenshot is what is on screen: the picture at the internal
//! resolution, in the 4:3 shape the player sees, with no letterbox.
//! Ported from ScreenshotTests.swift, plus Review Focus 5: a completion
//! block that outlives the renderer which asked for it.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const harness = @import("harness.zig");
const dh = @import("display_harness.zig");
const lh = @import("live_harness.zig");

const objc = ps1_metal.objc;
const mtl = ps1_metal.mtl;
const display = ps1_metal.display;
const screenshot = ps1_metal.screenshot;
const png = ps1_metal.png;
const Allocator = std.mem.Allocator;

const alloc = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const native_pixels = dh.native_pixels;

// ImageIO's decoding half, for reading back what `png.encode` wrote. The
// CoreFoundation half is `png.zig`'s.
const CFTypeRef = png.CFTypeRef;
const CFRelease = png.CFRelease;
const CFDataCreate = png.CFDataCreate;
const CFDataGetBytePtr = png.CFDataGetBytePtr;
const CFDataGetLength = png.CFDataGetLength;
extern "c" fn CGImageSourceCreateWithData(data: CFTypeRef, options: ?CFTypeRef) ?CFTypeRef;
extern "c" fn CGImageSourceCreateImageAtIndex(src: CFTypeRef, index: usize, options: ?CFTypeRef) ?CFTypeRef;
extern "c" fn CGImageGetWidth(image: CFTypeRef) usize;
extern "c" fn CGImageGetHeight(image: CFTypeRef) usize;
extern "c" fn CGImageGetBytesPerRow(image: CFTypeRef) usize;
extern "c" fn CGImageGetBitsPerPixel(image: CFTypeRef) usize;
extern "c" fn CGImageGetDataProvider(image: CFTypeRef) ?CFTypeRef;
extern "c" fn CGDataProviderCopyData(provider: CFTypeRef) ?CFTypeRef;

/// A decoded PNG: its size and pixel (x, y)'s first three bytes, read
/// straight off the image's provider. `NSBitmapImageRep` colour-matches on
/// load, which would measure the conversion, not the file.
const Decoded = struct { width: usize, height: usize, px: [3]u8 };

fn decode(file: []const u8, x: usize, y: usize) !Decoded {
    const data = CFDataCreate(null, file.ptr, @intCast(file.len)) orelse return error.ImageIO;
    defer CFRelease(data);
    const source = CGImageSourceCreateWithData(data, null) orelse return error.NotAnImage;
    defer CFRelease(source);
    const image = CGImageSourceCreateImageAtIndex(source, 0, null) orelse return error.NotAnImage;
    defer CFRelease(image);
    const provider = CGImageGetDataProvider(image) orelse return error.ImageIO;
    const pixels = CGDataProviderCopyData(provider) orelse return error.ImageIO;
    defer CFRelease(pixels);
    const o = y * CGImageGetBytesPerRow(image) + x * (CGImageGetBitsPerPixel(image) / 8);
    try expect(o + 3 <= @as(usize, @intCast(CFDataGetLength(pixels))));
    const bytes = CFDataGetBytePtr(pixels);
    return .{
        .width = CGImageGetWidth(image),
        .height = CGImageGetHeight(image),
        .px = .{ bytes[o], bytes[o + 1], bytes[o + 2] },
    };
}

test "Screenshot: theHeightIsTheDisplayedLinesAtTheScale" {
    try expectEqual(screenshot.Size{ .width = 1280, .height = 960 }, screenshot.size(240, 4, true));
    try expectEqual(screenshot.Size{ .width = 1280, .height = 960 }, screenshot.size(480, 2, true));
    try expectEqual(screenshot.Size{ .width = 896, .height = 672 }, screenshot.size(224, 3, true));
}

test "Screenshot: aDisabledDisplayIsAPlainBlackFrame" {
    try expectEqual(screenshot.Size{ .width = 640, .height = 480 }, screenshot.size(0, 4, false));
    try expectEqual(screenshot.Size{ .width = 640, .height = 480 }, screenshot.size(0, 4, true));
}

test "Screenshot: aPngRoundTripsItsPixels" {
    // BGRA: pure red, opaque.
    const bytes: [4][4]u8 = @splat(.{ 0, 0, 255, 255 });
    const file = try png.encode(alloc, std.mem.asBytes(&bytes), 2, 2, 8);
    defer alloc.free(file);
    const d = try decode(file, 1, 1);
    try expectEqual(2, d.width);
    try expectEqual(2, d.height);
    try expectEqual([3]u8{ 255, 0, 0 }, d.px);
}

test "Screenshot: theOffscreenPassDrawsThePicture" {
    const m = try harness.metal();
    defer m.deinit();
    var pass = try display.DisplayPass.init(m.device, m.lib);
    defer pass.deinit();

    const vram = try dh.vramTexture(alloc, m.device, 0x7FFF);
    defer vram.release();
    const shadow = try alloc.create([native_pixels]u16);
    defer alloc.destroy(shadow);
    @memset(shadow, 0);
    pass.uploadShadow(shadow);
    const sidecar = try dh.sidecarTexture(alloc, m.device, .{ 0, 0, 0, 0 });
    defer sidecar.release();

    var p = dh.params();
    p.scale = 1;
    // A letterbox the screenshot must ignore.
    p.scale_x = 0.5;
    p.scale_y = 0.5;

    const pool = objc.Pool.push();
    defer pool.pop();
    const cmd = m.queue.commandBuffer() orelse return error.NoCommandBuffer;
    const target = screenshot.encode(cmd, &pass, vram, sidecar, p, .{ .width = 320, .height = 240 }) orelse
        return error.NoTarget;
    defer target.release();
    cmd.commit();
    cmd.waitUntilCompleted();

    const bgra = try alloc.alloc(u8, 320 * 240 * 4);
    defer alloc.free(bgra);
    screenshot.bytes(target, bgra);
    for ([_][2]usize{ .{ 1, 1 }, .{ 160, 120 }, .{ 318, 238 } }) |xy| {
        const o = (xy[1] * 320 + xy[0]) * 4;
        expect(bgra[o + 2] > 200) catch |e| {
            std.debug.print("pixel {d},{d} is not the white picture\n", .{ xy[0], xy[1] });
            return e;
        };
    }
}

/// What a screenshot's completion block owns. Everything it reads is HERE:
/// the target texture (owned, released by the block) and the answer slot.
/// Nothing in it points into the renderer or the display pass, which are
/// gone by the time it runs.
const Pending = struct {
    alloc: Allocator,
    target: mtl.Texture,
    /// Set once the renderer and the pass are freed; the block waits for it,
    /// so "freed before the block runs" is an ordering, not a race won.
    freed: std.atomic.Value(bool) = .init(false),
    runs: std.atomic.Value(u32) = .init(0),
    answer: ?[]u8 = null,

    fn completed(self: *Pending, _: objc.Id) void {
        while (!self.freed.load(.acquire)) std.atomic.spinLoopHint();
        const w = self.target.width();
        const h = self.target.height();
        if (self.alloc.alloc(u8, w * h * 4)) |bgra| {
            defer self.alloc.free(bgra);
            screenshot.bytes(self.target, bgra);
            self.answer = png.encode(self.alloc, bgra, @intCast(w), @intCast(h), @intCast(w * 4)) catch null;
        } else |_| {}
        self.target.release();
        _ = self.runs.fetchAdd(1, .release);
    }
};

test "Screenshot: aScreenshotBlockOutlivesTheRendererThatAskedForIt" {
    const m = try harness.metal();
    defer m.deinit();
    const live = try lh.make(m, 1, false);
    var live_alive = true;
    defer if (live_alive) live.deinit();
    var pass = try display.DisplayPass.init(m.device, m.lib);
    var pass_alive = true;
    defer if (pass_alive) pass.deinit();
    const shadow = try alloc.create([native_pixels]u16);
    defer alloc.destroy(shadow);
    @memset(shadow, 0);
    pass.uploadShadow(shadow);

    const ctx = try alloc.create(Pending);
    defer alloc.destroy(ctx);

    const p = dh.params();
    const s = screenshot.size(p.height, p.scale, p.enabled != 0);
    const cmd = blk: {
        const pool = objc.Pool.push();
        defer pool.pop();
        const cmd = (m.queue.commandBuffer() orelse return error.NoCommandBuffer).retain();
        errdefer cmd.release();
        const target = screenshot.encode(cmd, &pass, live.vram.texture, live.vram.sidecar, p, s) orelse
            return error.NoTarget;
        ctx.* = .{ .alloc = alloc, .target = target };
        // The literal lives for this call only; the command buffer copies it.
        var block = objc.Block(Pending, Pending.completed).init(ctx);
        cmd.addCompletedHandler(block.ptr());
        cmd.commit();
        break :blk cmd;
    };
    defer cmd.release();

    live.deinit();
    live_alive = false;
    pass.deinit();
    pass_alive = false;
    ctx.freed.store(true, .release);

    cmd.waitUntilCompleted();
    // The handler may still be finishing on Metal's thread after the wait.
    while (ctx.runs.load(.acquire) == 0) std.atomic.spinLoopHint();
    defer if (ctx.answer) |a| alloc.free(a);

    try expectEqual(1, ctx.runs.load(.acquire));
    const file = ctx.answer orelse return error.NoPng;
    const d = try decode(file, 0, 0);
    try expectEqual(s.width, d.width);
    try expectEqual(s.height, d.height);
}
