import Testing
import Metal
@testable import PS1

/// The display shader is compiled at runtime from a string, so a syntax error
/// in it is a `fatalError` the first time a game is opened rather than a build
/// failure. Compiling it here moves that back to the test suite.
@Test func displayShaderCompilesAndExposesBothFunctions() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        // No GPU (headless CI): nothing to assert, and failing would be noise.
        return
    }

    let library = try device.makeLibrary(source: DisplayShader.source, options: nil)
    #expect(library.makeFunction(name: "display_vertex") != nil)
    #expect(library.makeFunction(name: "display_fragment") != nil)

    // The pipeline is where a vertex/fragment signature mismatch shows up.
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = library.makeFunction(name: "display_vertex")
    desc.fragmentFunction = library.makeFunction(name: "display_fragment")
    desc.colorAttachments[0].pixelFormat = .bgra8Unorm
    _ = try device.makeRenderPipelineState(descriptor: desc)
}
