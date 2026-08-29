import Testing
import Metal
@testable import PS1

/// A syntax error in the shader is caught by `build-shaders.sh`; what is NOT
/// caught there is the metallib failing to reach the bundle, or the two
/// function names drifting from what the pipeline asks for. Both would be a
/// `fatalError` the first time a game is opened, so they are checked here.
@Test func displayShaderCompilesAndExposesBothFunctions() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        // No GPU (headless CI): nothing to assert, and failing would be noise.
        return
    }

    let library = try Shaders.makeLibrary(device)
    #expect(library.makeFunction(name: "display_vertex") != nil)
    #expect(library.makeFunction(name: "display_fragment") != nil)

    // The pipeline is where a vertex/fragment signature mismatch shows up.
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = library.makeFunction(name: "display_vertex")
    desc.fragmentFunction = library.makeFunction(name: "display_fragment")
    desc.colorAttachments[0].pixelFormat = .bgra8Unorm
    _ = try device.makeRenderPipelineState(descriptor: desc)
}
