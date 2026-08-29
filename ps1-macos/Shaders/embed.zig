//! Exposes the offline-compiled Metal shaders to Swift as a byte blob.
//!
//! The metallib is embedded in the binary rather than shipped as a bundle
//! resource. A resource would have to be declared in Package.swift (a missing
//! declared resource is a manifest error, so `swift build` could not run until
//! the shader had been compiled once), copied into PS1.app by hand, and found
//! again at runtime through Bundle.module. Embedding it removes all three.
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
