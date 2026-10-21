//! An sRGB PNG of BGRA bytes, as `.bgra8Unorm` lays them out, through
//! CoreGraphics and ImageIO's C API. Plain C calls: nothing here is
//! Objective-C, so nothing goes through `objc`.

const std = @import("std");

const Allocator = std.mem.Allocator;
const CGFloat = f64;

/// CoreFoundation, declared once: the tests that decode a PNG back use these.
pub const CFTypeRef = *anyopaque;
pub extern "c" fn CFRelease(cf: CFTypeRef) void;
pub extern "c" fn CFDataCreate(allocator: ?CFTypeRef, bytes: [*]const u8, length: isize) ?CFTypeRef;
pub extern "c" fn CFDataGetBytePtr(data: CFTypeRef) [*]const u8;
pub extern "c" fn CFDataGetLength(data: CFTypeRef) isize;
extern "c" fn CFDataCreateMutable(allocator: ?CFTypeRef, capacity: isize) ?CFTypeRef;
extern "c" fn __CFStringMakeConstantString(c_str: [*:0]const u8) CFTypeRef;

extern "c" const kCGColorSpaceSRGB: CFTypeRef;
extern "c" fn CGColorSpaceCreateWithName(name: CFTypeRef) ?CFTypeRef;
extern "c" fn CGColorSpaceCreateDeviceRGB() ?CFTypeRef;
extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, width: usize, height: usize, bits_per_component: usize, bytes_per_row: usize, space: CFTypeRef, bitmap_info: u32) ?CFTypeRef;
extern "c" fn CGBitmapContextCreateImage(ctx: CFTypeRef) ?CFTypeRef;
extern "c" fn CGContextSetInterpolationQuality(ctx: CFTypeRef, quality: i32) void;
extern "c" fn CGContextDrawImage(ctx: CFTypeRef, rect: CGRect, image: CFTypeRef) void;
extern "c" fn CGDataProviderCreateWithCFData(data: CFTypeRef) ?CFTypeRef;
extern "c" fn CGImageCreate(width: usize, height: usize, bits_per_component: usize, bits_per_pixel: usize, bytes_per_row: usize, space: CFTypeRef, bitmap_info: u32, provider: CFTypeRef, decode: ?*const CGFloat, should_interpolate: bool, intent: i32) ?CFTypeRef;
extern "c" fn CGImageDestinationCreateWithData(data: CFTypeRef, type_id: CFTypeRef, count: usize, options: ?CFTypeRef) ?CFTypeRef;
extern "c" fn CGImageDestinationAddImage(dest: CFTypeRef, image: CFTypeRef, properties: ?CFTypeRef) void;
extern "c" fn CGImageDestinationFinalize(dest: CFTypeRef) bool;

// CGImage.h: kCGBitmapByteOrder32Little = (2 << 12).
const byte_order_32_little: u32 = 2 << 12;
// CGImage.h: kCGImageAlphaNoneSkipFirst = 6, kCGImageAlphaNoneSkipLast = 5.
const alpha_none_skip_first: u32 = 6;
const alpha_none_skip_last: u32 = 5;
// CGContext.h: kCGInterpolationHigh = 3.
const interpolation_high: i32 = 3;
// CGColorSpace.h: kCGRenderingIntentDefault = 0.
const intent_default: i32 = 0;

const CGRect = extern struct { x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat };

/// The PNG file's bytes, owned by the caller. `bgra` is COPIED into a CFData
/// first, as the Swift encoder did: releasing our references does not prove
/// CoreGraphics or ImageIO dropped theirs, so the image must not point into
/// memory the caller is free to reuse once this returns.
pub fn encode(alloc: Allocator, bgra: []const u8, width: u32, height: u32, bytes_per_row: u32) ![]u8 {
    if (bgra.len < @as(usize, height) * bytes_per_row) @panic("png.encode: bgra shorter than height * bytes_per_row");
    const space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB) orelse return error.ImageIO;
    defer CFRelease(space);
    const pixels = CFDataCreate(null, bgra.ptr, @intCast(bgra.len)) orelse return error.ImageIO;
    defer CFRelease(pixels);
    const provider = CGDataProviderCreateWithCFData(pixels) orelse return error.ImageIO;
    defer CFRelease(provider);
    const image = CGImageCreate(width, height, 8, 32, bytes_per_row, space, byte_order_32_little | alpha_none_skip_first, provider, null, false, intent_default) orelse
        return error.ImageIO;
    defer CFRelease(image);
    return encodeImage(alloc, image);
}

/// An RGBA8 image (alpha ignored) drawn at `out_width` x `out_height` with
/// high-quality interpolation, as a PNG owned by the caller: the resume
/// thumbnail, drawn at 4:3 whatever the display's pixel size. Device RGB, as
/// the Swift thumbnail was.
pub fn encodeScaled(alloc: Allocator, rgba: []const u8, width: u32, height: u32, out_width: u32, out_height: u32) ![]u8 {
    if (rgba.len < @as(usize, width) * height * 4) @panic("png.encodeScaled: rgba shorter than width * height * 4");
    const space = CGColorSpaceCreateDeviceRGB() orelse return error.ImageIO;
    defer CFRelease(space);
    const pixels = CFDataCreate(null, rgba.ptr, @intCast(@as(usize, width) * height * 4)) orelse return error.ImageIO;
    defer CFRelease(pixels);
    const provider = CGDataProviderCreateWithCFData(pixels) orelse return error.ImageIO;
    defer CFRelease(provider);
    const source = CGImageCreate(width, height, 8, 32, @as(usize, width) * 4, space, alpha_none_skip_last, provider, null, true, intent_default) orelse
        return error.ImageIO;
    defer CFRelease(source);
    const ctx = CGBitmapContextCreate(null, out_width, out_height, 8, 0, space, alpha_none_skip_last) orelse return error.ImageIO;
    defer CFRelease(ctx);
    CGContextSetInterpolationQuality(ctx, interpolation_high);
    CGContextDrawImage(ctx, .{ .x = 0, .y = 0, .w = @floatFromInt(out_width), .h = @floatFromInt(out_height) }, source);
    const scaled = CGBitmapContextCreateImage(ctx) orelse return error.ImageIO;
    defer CFRelease(scaled);
    return encodeImage(alloc, scaled);
}

/// One CGImage as a PNG file's bytes, owned by the caller.
fn encodeImage(alloc: Allocator, image: CFTypeRef) ![]u8 {
    const data = CFDataCreateMutable(null, 0) orelse return error.ImageIO;
    defer CFRelease(data);
    // CFSTR("public.png"): a constant string, never released.
    const dest = CGImageDestinationCreateWithData(data, __CFStringMakeConstantString("public.png"), 1, null) orelse
        return error.ImageIO;
    defer CFRelease(dest);
    CGImageDestinationAddImage(dest, image, null);
    if (!CGImageDestinationFinalize(dest)) return error.ImageIO;
    const len: usize = @intCast(CFDataGetLength(data));
    return alloc.dupe(u8, CFDataGetBytePtr(data)[0..len]);
}
