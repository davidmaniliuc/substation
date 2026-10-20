//! The shader library the app ships: the offline-compiled metallib that
//! `ps1-macos/Shaders/embed.zig` embeds, loaded into a device.
//!
//! `build.zig` compiles both `.metal` sources with `xcrun metal`/`metallib`,
//! so a syntax error fails the build rather than the first frame, and this
//! one loader is what keeps a test honest about the binary the app runs.

const objc = @import("objc.zig");
const mtl = @import("mtl.zig");

extern fn ps1_metallib_ptr() [*]const u8;
extern fn ps1_metallib_len() usize;

extern "c" fn dispatch_data_create(buffer: *const anyopaque, size: usize, queue: ?*anyopaque, destructor: ?*anyopaque) ?*anyopaque;
extern "c" fn dispatch_release(object: *anyopaque) void;

/// Owned by the caller. The blob is copied once into the dispatch data
/// (the default destructor), which is released once the library holds it.
pub fn makeLibrary(device: mtl.Device) !mtl.Library {
    const data = dispatch_data_create(ps1_metallib_ptr(), ps1_metallib_len(), null, null) orelse
        return error.OutOfMemory;
    defer dispatch_release(data);
    return device.newLibraryWithData(data);
}
