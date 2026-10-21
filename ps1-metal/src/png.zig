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
extern "c" fn CGDataProviderCreateWithCFData(data: CFTypeRef) ?CFTypeRef;
extern "c" fn CGImageCreate(width: usize, height: usize, bits_per_component: usize, bits_per_pixel: usize, bytes_per_row: usize, space: CFTypeRef, bitmap_info: u32, provider: CFTypeRef, decode: ?*const CGFloat, should_interpolate: bool, intent: i32) ?CFTypeRef;
extern "c" fn CGImageDestinationCreateWithData(data: CFTypeRef, type_id: CFTypeRef, count: usize, options: ?CFTypeRef) ?CFTypeRef;
extern "c" fn CGImageDestinationAddImage(dest: CFTypeRef, image: CFTypeRef, properties: ?CFTypeRef) void;
extern "c" fn CGImageDestinationFinalize(dest: CFTypeRef) bool;

// CGImage.h: kCGBitmapByteOrder32Little = (2 << 12).
const byte_order_32_little: u32 = 2 << 12;
// CGImage.h: kCGImageAlphaNoneSkipFirst = 6.
const alpha_none_skip_first: u32 = 6;
// CGColorSpace.h: kCGRenderingIntentDefault = 0.
const intent_default: i32 = 0;

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
