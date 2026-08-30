import Testing
import Metal
@testable import PS1

/// Renders the real display pass offscreen against a real `MetalVram` at
/// `scale` and hands back the drawable's BGRA bytes.
///
/// A second harness rather than a parameter on `DisplayRenderTests`' one: that
/// helper builds a plain managed 1024x512 texture, which cannot be scaled at
/// all. This needs the .private renderTarget+shaderRead texture the live path
/// actually samples.
///
/// `scaled` overrides `native` when given, for the one test that needs blocks
/// which are NOT uniform.
private func renderScaled(native: [UInt16],
                          scaled: [UInt16]? = nil,
                          shadow: [UInt16]? = nil,
                          scale: Int,
                          drawable: (width: Int, height: Int) = (320, 240),
                          configure: (inout DisplayParams) -> Void = { _ in })
    throws -> [UInt8]?
{
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue, scale: scale)
    else { return nil }
    if let scaled { vram.upload(scaled) } else { vram.uploadNative(native) }

    let shDesc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .r16Uint, width: 1024, height: 512, mipmapped: false)
    shDesc.usage = .shaderRead
    shDesc.storageMode = .managed
    guard let shadowTex = device.makeTexture(descriptor: shDesc) else { return nil }
    (shadow ?? native).withUnsafeBytes { buf in
        shadowTex.replace(region: MTLRegionMake2D(0, 0, 1024, 512), mipmapLevel: 0,
                          withBytes: buf.baseAddress!, bytesPerRow: 1024 * 2)
    }

    let targetDesc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: drawable.width, height: drawable.height,
        mipmapped: false)
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

    var params = DisplayParams()
    params.width = 320
    params.height = 240
    params.enabled = 1
    params.scale = UInt32(scale)
    configure(&params)
    (params.scaleX, params.scaleY) = letterboxScale(
        width: Double(drawable.width), height: Double(drawable.height))

    guard let cmd = queue.makeCommandBuffer(),
          let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
    enc.setRenderPipelineState(pipeline)
    enc.setFragmentTexture(vram.texture, index: 0)
    enc.setFragmentTexture(shadowTex, index: 1)
    enc.setVertexBytes(&params, length: MemoryLayout<DisplayParams>.stride, index: 0)
    enc.setFragmentBytes(&params, length: MemoryLayout<DisplayParams>.stride, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()
    guard let blit = cmd.makeBlitCommandEncoder() else { return nil }
    blit.synchronize(resource: target)
    blit.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()

    var out = [UInt8](repeating: 0, count: drawable.width * drawable.height * 4)
    out.withUnsafeMutableBytes { buf in
        target.getBytes(buf.baseAddress!, bytesPerRow: drawable.width * 4,
                        from: MTLRegionMake2D(0, 0, drawable.width, drawable.height),
                        mipmapLevel: 0)
    }
    return out
}

/// A full native VRAM in which practically every pixel differs from its
/// neighbours, so an off-by-one in `nx` or a wrong wrap lands on a visibly
/// different colour instead of an identical one. Deterministic: the same
/// bytes on every run and on both sides of every comparison.
private func lcgImage(seed: UInt32 = 0x2545F491) -> [UInt16] {
    var out = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    var s = seed
    for i in 0..<out.count {
        s = s &* 1664525 &+ 1013904223
        out[i] = UInt16((s >> 15) & 0x7FFF)
    }
    return out
}

private let displayScaleLadder = [2, 3, 4, 8]

@Test func theDisplayParamsStrideMatchesTheShaderStruct() {
    // DisplayShader.metal carries `static_assert(sizeof(Params) == 40)`. This
    // is the other half of that pair: a field added on one side only shears
    // every field after it.
    #expect(MemoryLayout<DisplayParams>.stride == 40)
    #expect(MemoryLayout<DisplayParams>.size == 40)
    // Never 0: the fragment shader divides by it. A default of 0 would be a
    // divide-by-zero on the very first frame after a field reorder.
    #expect(DisplayParams().scale == 1)
}

@Test func aBlockUniformTextureDisplaysIdenticallyAtEveryScale() throws {
    // The display-side analogue of Phase C's exactness property: a scaled
    // texture whose every N x N block is uniform must present byte-identically
    // to the native image at 1x. `uploadNative` produces exactly that, so the
    // fixture is free.
    let image = lcgImage()
    guard let one = try renderScaled(native: image, scale: 1) else { return }
    for scale in displayScaleLadder {
        guard let many = try renderScaled(native: image, scale: scale) else { return }
        #expect(many == one, "scale \(scale)")
    }
}

@Test func aDisplayWindowCrossingTheVramEdgeWrapsNatively() throws {
    // The case the parent spec got wrong, as its own test rather than a hope
    // that the sweep above happens to cross an edge.
    //
    // vram_x 1000 + 320 columns and vram_y 400 + 240 rows both run off the end
    // of VRAM. Scale 3 is what separates form A -- ((vram_x + nx) & 1023) * s
    // + sub_x -- from the parent spec's `& (1024 * s - 1)`: at s = 3 that mask
    // is 3071, which is not `mod 3072`. At px = 75 the mask gives 2051 where
    // the correct column is 3.
    let image = lcgImage()
    func window(_ p: inout DisplayParams) {
        p.vramX = 1000
        p.vramY = 400
    }
    guard let one = try renderScaled(native: image, scale: 1, configure: window)
    else { return }
    for scale in displayScaleLadder {
        guard let many = try renderScaled(native: image, scale: scale, configure: window)
        else { return }
        #expect(many == one, "scale \(scale)")
    }
}

@Test func theDisplayPassSamplesSubtexelsNotJustTheBlockCorner() throws {
    // The test that fails for a plausible, entirely self-consistent
    // implementation of this whole phase: scaling only the WRAPS is a no-op.
    // Every sample then lands on its block's top-left subtexel, which by Phase
    // C's exactness property is byte-identical to the 1x picture -- the player
    // selects 8x, pays 67 MB and sees nothing. No other test here notices,
    // because every other one compares against the 1x picture on purpose.
    let scale = 2
    let w = MetalVram.nativeWidth * scale
    var scaled = [UInt16](repeating: 0, count: MetalVram.nativePixelCount * scale * scale)
    scaled[0] = 0x001F          // native (0,0) subtexel (0,0): red
    scaled[1] = 0x03E0          //                     (1,0): green
    scaled[w] = 0x7C00          //                     (0,1): blue
    scaled[w + 1] = 0x7FFF      //                     (1,1): white

    // sw = 320 * 2 = 640 and sh = 240 * 2 = 480, so a 640x480 drawable maps
    // 1:1 onto the scaled sample grid and the four subtexels of ONE native
    // pixel land on four distinct drawable pixels.
    guard let img = try renderScaled(
        native: [UInt16](repeating: 0, count: MetalVram.nativePixelCount),
        scaled: scaled, scale: scale, drawable: (640, 480)) else { return }

    // (b, g, r) — the target is .bgra8Unorm.
    func px(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let o = (y * 640 + x) * 4
        return (img[o], img[o + 1], img[o + 2])
    }
    #expect(px(0, 0).2 > 240 && px(0, 0).1 < 16)   // red
    #expect(px(1, 0).1 > 240 && px(1, 0).2 < 16)   // green
    #expect(px(0, 1).0 > 240 && px(0, 1).2 < 16)   // blue
    #expect(px(1, 1).0 > 240 && px(1, 1).1 > 240 && px(1, 1).2 > 240)  // white
}

@Test func twentyFourBppDisplaysIdenticallyAtEveryScale() throws {
    // The trap in the phase. 24bpp reconstructs pixels by byte-packing across
    // ADJACENT 16-bit VRAM words, arithmetic that is meaningless in scaled
    // space -- which is why D1 routed it to the 1024x512 shadow permanently.
    // It must be addressed with `nx`/`ny`; `px` at scale 4 reads a column four
    // times too far along and breaks every FMV in Croc and Silent Hill.
    let shadow = lcgImage()
    // The render texture holds something DIFFERENT, so a 24bpp path that read
    // it instead of the shadow fails here too.
    let render = lcgImage(seed: 0x9E3779B9)
    func depth(_ p: inout DisplayParams) { p.depth24 = 1 }

    guard let one = try renderScaled(native: render, shadow: shadow,
                                     scale: 1, configure: depth) else { return }
    for scale in displayScaleLadder {
        guard let many = try renderScaled(native: render, shadow: shadow,
                                          scale: scale, configure: depth) else { return }
        #expect(many == one, "scale \(scale)")
    }
}

@Test func theSoftwareDisplaySeamStaysOnTheNativeShadowAtEveryScale() throws {
    // Same routing rule as 24bpp, same reason: the shadow is 1024x512 at every
    // N, so it is addressed natively or not at all.
    let shadow = lcgImage()
    let render = lcgImage(seed: 0x9E3779B9)
    func seam(_ p: inout DisplayParams) { p.softwareDisplay = 1 }

    guard let one = try renderScaled(native: render, shadow: shadow,
                                     scale: 1, configure: seam) else { return }
    for scale in displayScaleLadder {
        guard let many = try renderScaled(native: render, shadow: shadow,
                                          scale: scale, configure: seam) else { return }
        #expect(many == one, "scale \(scale)")
    }
}
