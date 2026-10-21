//! RGBA8 -> PNG on disk and back, through CoreGraphics and ImageIO's C API.
//! The harness's dump writers use the first half; their tests use the second
//! to check what a writer put in the file, and `decodePng` reads back a
//! PNG held in memory, as `png.encode` returns one.

const std = @import("std");

const CFTypeRef = *anyopaque;
const CGFloat = f64;
const CGRect = extern struct { x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat };

extern "c" fn CFRelease(cf: CFTypeRef) void;
extern "c" fn CFURLCreateFromFileSystemRepresentation(alloc: ?CFTypeRef, buffer: [*]const u8, len: isize, is_directory: bool) ?CFTypeRef;
extern "c" fn CFStringCreateWithCString(alloc: ?CFTypeRef, s: [*:0]const u8, encoding: u32) ?CFTypeRef;
extern "c" fn CGColorSpaceCreateDeviceRGB() ?CFTypeRef;
extern "c" fn CGDataProviderCreateWithData(info: ?*anyopaque, data: *const anyopaque, size: usize, release: ?*const anyopaque) ?CFTypeRef;
extern "c" fn CGImageCreate(width: usize, height: usize, bits_per_component: usize, bits_per_pixel: usize, bytes_per_row: usize, space: CFTypeRef, bitmap_info: u32, provider: CFTypeRef, decode: ?*const CGFloat, should_interpolate: bool, intent: i32) ?CFTypeRef;
extern "c" fn CGImageGetWidth(image: CFTypeRef) usize;
extern "c" fn CGImageGetHeight(image: CFTypeRef) usize;
extern "c" fn CGImageDestinationCreateWithURL(url: CFTypeRef, type_id: CFTypeRef, count: usize, options: ?CFTypeRef) ?CFTypeRef;
extern "c" fn CGImageDestinationAddImage(dest: CFTypeRef, image: CFTypeRef, properties: ?CFTypeRef) void;
extern "c" fn CGImageDestinationFinalize(dest: CFTypeRef) bool;
extern "c" fn CGImageSourceCreateWithURL(url: CFTypeRef, options: ?CFTypeRef) ?CFTypeRef;
extern "c" fn CGImageSourceCreateImageAtIndex(src: CFTypeRef, index: usize, options: ?CFTypeRef) ?CFTypeRef;
extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, width: usize, height: usize, bits_per_component: usize, bytes_per_row: usize, space: CFTypeRef, bitmap_info: u32) ?CFTypeRef;
extern "c" fn CGContextDrawImage(ctx: CFTypeRef, rect: CGRect, image: CFTypeRef) void;
extern "c" fn CFDataCreate(allocator: ?CFTypeRef, bytes: [*]const u8, length: isize) ?CFTypeRef;
extern "c" fn CFDataGetBytePtr(data: CFTypeRef) [*]const u8;
extern "c" fn CFDataGetLength(data: CFTypeRef) isize;
extern "c" fn CGImageSourceCreateWithData(data: CFTypeRef, options: ?CFTypeRef) ?CFTypeRef;
extern "c" fn CGImageGetBytesPerRow(image: CFTypeRef) usize;
extern "c" fn CGImageGetBitsPerPixel(image: CFTypeRef) usize;
extern "c" fn CGImageGetDataProvider(image: CFTypeRef) ?CFTypeRef;
extern "c" fn CGDataProviderCopyData(provider: CFTypeRef) ?CFTypeRef;

// CFString.h: kCFStringEncodingUTF8 = 0x08000100.
const utf8_encoding: u32 = 0x08000100;
// CGImage.h: kCGImageAlphaNoneSkipLast = 5.
const alpha_none_skip_last: u32 = 5;
// CGColorSpace.h: kCGRenderingIntentDefault = 0.
const intent_default: i32 = 0;

fn url(path: []const u8) !CFTypeRef {
    return CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), false) orelse error.BadPath;
}

/// RGBA8, alpha ignored: every PNG this writes is opaque.
pub fn writeRgba(path: []const u8, rgba: []const u8, width: usize, height: usize) !void {
    std.debug.assert(rgba.len == width * height * 4);
    const space = CGColorSpaceCreateDeviceRGB() orelse return error.ImageIO;
    defer CFRelease(space);
    const provider = CGDataProviderCreateWithData(null, rgba.ptr, rgba.len, null) orelse return error.ImageIO;
    defer CFRelease(provider);
    const image = CGImageCreate(width, height, 8, 32, width * 4, space, alpha_none_skip_last, provider, null, false, intent_default) orelse
        return error.ImageIO;
    defer CFRelease(image);
    const where = try url(path);
    defer CFRelease(where);
    const png = CFStringCreateWithCString(null, "public.png", utf8_encoding) orelse return error.ImageIO;
    defer CFRelease(png);
    const dest = CGImageDestinationCreateWithURL(where, png, 1, null) orelse return error.ImageIO;
    defer CFRelease(dest);
    CGImageDestinationAddImage(dest, image, null);
    if (!CGImageDestinationFinalize(dest)) return error.ImageIO;
}

pub const Decoded = struct {
    width: usize,
    height: usize,
    /// RGBX8, one row after another.
    rgba: []u8,
};

/// Reads a PNG back as RGBX8 by drawing it into a bitmap context.
pub fn readRgba(alloc: std.mem.Allocator, path: []const u8) !Decoded {
    const where = try url(path);
    defer CFRelease(where);
    const src = CGImageSourceCreateWithURL(where, null) orelse return error.ImageIO;
    defer CFRelease(src);
    const image = CGImageSourceCreateImageAtIndex(src, 0, null) orelse return error.ImageIO;
    defer CFRelease(image);
    const w = CGImageGetWidth(image);
    const h = CGImageGetHeight(image);
    const rgba = try alloc.alloc(u8, w * h * 4);
    errdefer alloc.free(rgba);
    @memset(rgba, 0);
    const space = CGColorSpaceCreateDeviceRGB() orelse return error.ImageIO;
    defer CFRelease(space);
    const ctx = CGBitmapContextCreate(rgba.ptr, w, h, 8, w * 4, space, alpha_none_skip_last) orelse return error.ImageIO;
    defer CFRelease(ctx);
    CGContextDrawImage(ctx, .{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) }, image);
    return .{ .width = w, .height = h, .rgba = rgba };
}

/// A decoded PNG: its size and pixel (x, y)'s first three bytes, read
/// straight off the image's provider. `NSBitmapImageRep` colour-matches on
/// load, which would measure the conversion, not the file.
pub const DecodedPixel = struct { width: usize, height: usize, px: [3]u8 };

pub fn decodePng(file: []const u8, x: usize, y: usize) !DecodedPixel {
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
    if (o + 3 > @as(usize, @intCast(CFDataGetLength(pixels)))) return error.ImageIO;
    const bytes = CFDataGetBytePtr(pixels);
    return .{
        .width = CGImageGetWidth(image),
        .height = CGImageGetHeight(image),
        .px = .{ bytes[o], bytes[o + 1], bytes[o + 2] },
    };
}
