//! RGBA8 -> PNG on disk and back, through CoreGraphics and ImageIO's C API.
//! The harness's dump writers use the first half; their tests use the second
//! to check what a writer put in the file.

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
