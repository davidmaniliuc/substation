import CPs1
import Dispatch
import Metal

/// Loads the precompiled display shader.
///
/// The Metal source is `ps1-macos/Shaders/DisplayShader.metal`; `build.zig`
/// compiles it offline with `xcrun metal`/`metallib` and embeds the result in
/// `libps1shaders.a`, so a syntax error in it fails the build rather than the
/// first frame. The app and the test suite load it through this one call, which
/// is what keeps `DisplayShaderTests`/`DisplayRenderTests` honest about the
/// binary the app actually runs.
///
/// The blob is static storage in the linked image, so the deallocator must be
/// a no-op — there is no `.none` case, and `.free` would hand a pointer into
/// the binary's own `__const` section to `free()`.
enum DisplayShader {
    static func makeLibrary(_ device: MTLDevice) throws -> MTLLibrary {
        let bytes = UnsafeRawBufferPointer(
            start: ps1_display_metallib_ptr(),
            count: ps1_display_metallib_len())
        let data = DispatchData(bytesNoCopy: bytes, deallocator: .custom(nil, {}))
        return try device.makeLibrary(data: data as __DispatchData)
    }
}
