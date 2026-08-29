import CPs1
import Dispatch
import Metal

/// Loads the precompiled shader library.
///
/// The Metal sources are `ps1-macos/Shaders/DisplayShader.metal` and
/// `ps1-macos/Shaders/Rasterizer.metal`; `build.zig` compiles them offline with
/// `xcrun metal`/`metallib` and embeds the merged result in `libps1shaders.a`,
/// so a syntax error in either fails the build rather than the first frame.
/// The app and the test suite load it through this one call, which is what
/// keeps `DisplayShaderTests`/`DisplayRenderTests`/`MetalVramTests` honest
/// about the binary the app actually runs.
///
/// The blob is static storage in the linked image, so the deallocator must be
/// a no-op — there is no `.none` case, and `.free` would hand a pointer into
/// the binary's own `__const` section to `free()`.
enum Shaders {
    static func makeLibrary(_ device: MTLDevice) throws -> MTLLibrary {
        let bytes = UnsafeRawBufferPointer(
            start: ps1_metallib_ptr(),
            count: ps1_metallib_len())
        let data = DispatchData(bytesNoCopy: bytes, deallocator: .custom(nil, {}))
        return try device.makeLibrary(data: data as __DispatchData)
    }
}
