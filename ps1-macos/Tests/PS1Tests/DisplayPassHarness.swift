import Metal
@testable import PS1

/// Encodes the real display pass against already-built VRAM/shadow textures
/// and reads the drawable's BGRA bytes back.
///
/// Shared by `DisplayScaleTests` (a real, possibly-scaled `MetalVram.texture`)
/// and `DisplayRenderTests` (a plain managed 1024x512 fill texture): what
/// differs between those two harnesses is only which VRAM texture is bound,
/// never the pipeline, the pass, or the read-back — so only texture setup
/// stays at each call site.
func renderDisplayPass(device: MTLDevice, queue: MTLCommandQueue,
                       vram: MTLTexture, shadow: MTLTexture, sidecar: MTLTexture,
                       params: DisplayParams, width: Int, height: Int)
    throws -> [UInt8]?
{
    let targetDesc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    targetDesc.usage = [.renderTarget, .shaderRead]
    targetDesc.storageMode = .managed
    guard let target = device.makeTexture(descriptor: targetDesc) else { return nil }

    let library = try Shaders.makeLibrary(device)
    let pipeDesc = MTLRenderPipelineDescriptor()
    pipeDesc.vertexFunction = library.makeFunction(name: "display_vertex")
    pipeDesc.fragmentFunction = library.makeFunction(name: "display_fragment")
    pipeDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
    let pipeline = try device.makeRenderPipelineState(descriptor: pipeDesc)

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    pass.colorAttachments[0].storeAction = .store

    var p = params
    guard let cmd = queue.makeCommandBuffer(),
          let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
    enc.setRenderPipelineState(pipeline)
    enc.setFragmentTexture(vram, index: 0)
    enc.setFragmentTexture(shadow, index: 1)
    enc.setFragmentTexture(sidecar, index: 2)
    enc.setVertexBytes(&p, length: MemoryLayout<DisplayParams>.stride, index: 0)
    enc.setFragmentBytes(&p, length: MemoryLayout<DisplayParams>.stride, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()
    guard let blit = cmd.makeBlitCommandEncoder() else { return nil }
    blit.synchronize(resource: target)
    blit.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()

    var out = [UInt8](repeating: 0, count: width * height * 4)
    out.withUnsafeMutableBytes { buf in
        target.getBytes(buf.baseAddress!, bytesPerRow: width * 4,
                        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    }
    return out
}
