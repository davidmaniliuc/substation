//! Exposes the offline-compiled Metal shaders to the renderer as a byte blob
//! (`ps1-metal/src/shaders.zig` loads it into a device).
//!
//! The metallib is embedded in the binary rather than shipped as a bundle
//! resource, so nothing has to copy it into the app or find it again at
//! runtime, and a test binary links the same bytes the app does.
//!
//! This lives OUTSIDE ps1-capi on purpose: libps1core.a is the portable
//! emulator ABI and must not require the Metal toolchain to build.

const metallib = @embedFile("metallib");

export fn ps1_metallib_ptr() [*]const u8 {
    return metallib.ptr;
}

export fn ps1_metallib_len() usize {
    return metallib.len;
}
