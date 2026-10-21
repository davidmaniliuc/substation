//! The resume prompt's picture, cropped from core VRAM and scaled to 4:3.
//! Ported from ResumeThumbnailTests: the PNG is decoded back through ImageIO
//! to check its pixels, as the Swift tests did.

const std = @import("std");
const session = @import("ps1_session");
const metal = @import("ps1_metal");

const thumbnail = session.thumbnail;
const Display = metal.stream_queue.Display;
const native_pixels = metal.prim_instance.native_pixels;
const vram_width = 1024;

const alloc = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const CFTypeRef = *anyopaque;
const CGRect = extern struct { x: f64, y: f64, w: f64, h: f64 };
extern "c" fn CFRelease(cf: CFTypeRef) void;
extern "c" fn CFDataCreate(allocator: ?CFTypeRef, bytes: [*]const u8, length: isize) ?CFTypeRef;
extern "c" fn CGImageSourceCreateWithData(data: CFTypeRef, options: ?CFTypeRef) ?CFTypeRef;
extern "c" fn CGImageSourceCreateImageAtIndex(src: CFTypeRef, index: usize, options: ?CFTypeRef) ?CFTypeRef;
extern "c" fn CGImageGetWidth(image: CFTypeRef) usize;
extern "c" fn CGImageGetHeight(image: CFTypeRef) usize;
extern "c" fn CGColorSpaceCreateDeviceRGB() ?CFTypeRef;
extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, width: usize, height: usize, bits_per_component: usize, bytes_per_row: usize, space: CFTypeRef, bitmap_info: u32) ?CFTypeRef;
extern "c" fn CGContextDrawImage(ctx: CFTypeRef, rect: CGRect, image: CFTypeRef) void;

// CGImage.h: kCGImageAlphaPremultipliedLast = 1.
const alpha_premultiplied_last: u32 = 1;

const Decoded = struct {
    width: usize,
    height: usize,
    rgba: []u8,

    fn deinit(self: Decoded) void {
        alloc.free(self.rgba);
    }

    /// RGB of one pixel, (0, 0) the top-left.
    fn pixel(self: Decoded, x: usize, y: usize) [3]u8 {
        const i = (y * self.width + x) * 4;
        return .{ self.rgba[i], self.rgba[i + 1], self.rgba[i + 2] };
    }
};

fn decode(png: []const u8) !Decoded {
    const data = CFDataCreate(null, png.ptr, @intCast(png.len)) orelse return error.ImageIO;
    defer CFRelease(data);
    const src = CGImageSourceCreateWithData(data, null) orelse return error.ImageIO;
    defer CFRelease(src);
    const image = CGImageSourceCreateImageAtIndex(src, 0, null) orelse return error.ImageIO;
    defer CFRelease(image);
    const w = CGImageGetWidth(image);
    const h = CGImageGetHeight(image);
    const rgba = try alloc.alloc(u8, w * h * 4);
    errdefer alloc.free(rgba);
    const space = CGColorSpaceCreateDeviceRGB() orelse return error.ImageIO;
    defer CFRelease(space);
    const ctx = CGBitmapContextCreate(rgba.ptr, w, h, 8, w * 4, space, alpha_premultiplied_last) orelse return error.ImageIO;
    defer CFRelease(ctx);
    CGContextDrawImage(ctx, .{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) }, image);
    return .{ .width = w, .height = h, .rgba = rgba };
}

fn display(x: u32, y: u32, w: u32, h: u32, depth24: bool) Display {
    return .{ .vram_x = x, .vram_y = y, .width = w, .height = h, .depth24 = depth24, .enabled = true };
}

fn newVram(fill: u16) !*[native_pixels]u16 {
    const v = try alloc.create([native_pixels]u16);
    @memset(v, fill);
    return v;
}

test "Thumbnail: a15bppDisplayIsCroppedAndExpanded" {
    // Blue everywhere, pure red inside the 320x240 display area at (64, 32).
    const vram = try newVram(0x1F << 10);
    defer alloc.destroy(vram);
    for (32..32 + 240) |y| for (64..64 + 320) |x| {
        vram[y * vram_width + x] = 0x1F;
    };
    const png = (try thumbnail.png(alloc, vram, display(64, 32, 320, 240, false))).?;
    defer alloc.free(png);
    const d = try decode(png);
    defer d.deinit();
    const p = d.pixel(160, 120);
    try expect(p[0] == 255 and p[1] == 0 and p[2] == 0);
    // The blue outside the crop never reaches the picture.
    try expect(d.pixel(2, 2)[2] < 32);
}

test "Thumbnail: a24bppDisplayIsUnpackedAcrossWords" {
    // R=10, G=200, B=30 packed three bytes per pixel across 16-bit words.
    const vram = try newVram(0);
    defer alloc.destroy(vram);
    const rgb = [_]u16{ 10, 200, 30 };
    for (0..240) |y| for (0..320 * 3) |byte| {
        const word = y * vram_width + byte / 2;
        const value = rgb[byte % 3];
        vram[word] |= if (byte % 2 == 0) value else value << 8;
    };
    const png = (try thumbnail.png(alloc, vram, display(0, 0, 320, 240, true))).?;
    defer alloc.free(png);
    const d = try decode(png);
    defer d.deinit();
    for ([_]usize{ 160, 161 }) |x| {
        const p = d.pixel(x, 120);
        try expect(p[0] == 10 and p[1] == 200 and p[2] == 30);
    }
}

test "Thumbnail: theThumbnailIsAlways320By240" {
    const vram = try newVram(0x7FFF);
    defer alloc.destroy(vram);
    const png = (try thumbnail.png(alloc, vram, display(0, 0, 640, 480, false))).?;
    defer alloc.free(png);
    const d = try decode(png);
    defer d.deinit();
    try expectEqual(320, d.width);
    try expectEqual(240, d.height);
}

test "Thumbnail: aDisabledDisplayHasNoThumbnail" {
    const vram = try newVram(0);
    defer alloc.destroy(vram);
    var d = display(0, 0, 320, 240, false);
    d.enabled = false;
    try expectEqual(null, try thumbnail.png(alloc, vram, d));
}

test "Thumbnail: theCropWrapsAtTheVramEdges" {
    // A display starting near the right and bottom edges reads columns and
    // rows from the far side, as the scanout does.
    const vram = try newVram(0);
    defer alloc.destroy(vram);
    vram[0] = 0x1F; // (0, 0): the wrapped pixel (1, 1) of a display at (1023, 511)
    var rgba: [4 * 4 * 4]u8 = undefined;
    const size = thumbnail.decode(vram, display(1023, 511, 4, 4, false), &rgba).?;
    try expectEqual(4, size.w);
    const i = (1 * 4 + 1) * 4;
    try expectEqual(255, rgba[i]);
    try expectEqual(0, rgba[0]);
}
