import Foundation
import Metal

/// The GPU-side PS1 VRAM: 1024x512 R16Uint, private storage, render target
/// and texture source at once.
///
/// R16Uint and NOT RGBA8 is the decision the whole renderer hangs on. PS1 VRAM
/// is simultaneously framebuffer, texture memory and CLUT storage: a game
/// draws into it and then samples the result as 4bpp, 8bpp or 16bpp indexed
/// data. Storing decoded colour destroys the bit patterns texture sampling
/// depends on, and hides bit 15 — the mask/STP bit that `renderer.zig:36-45`
/// and `vram.zig:83-87` implement carefully.
///
/// This is a DIFFERENT texture from `MetalDisplayView`'s: that one is
/// .shaderRead/.managed and cannot be a render target.
final class MetalVram {
    static let width = 1024
    static let height = 512
    static let pixelCount = width * height

    let device: MTLDevice
    let queue: MTLCommandQueue
    let texture: MTLTexture
    /// Staging for both directions. Shared storage, allocated once: readback
    /// runs per fixture frame and a per-frame 1 MB allocation is pure waste.
    private let staging: MTLBuffer

    init?(device: MTLDevice, queue: MTLCommandQueue) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Uint, width: Self.width, height: Self.height, mipmapped: false)
        // .shaderRead as well as .renderTarget: the same texture is `read()`
        // at arbitrary coordinates by the fragment shader that is drawing into
        // it. That aliasing is legal only under the pass-splitting invariant —
        // nothing sampled during a render pass may have been written during
        // that pass — which the encoder's hazard tracking enforces.
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let texture = device.makeTexture(descriptor: desc),
              let staging = device.makeBuffer(length: Self.pixelCount * 2, options: .storageModeShared)
        else { return nil }

        self.device = device
        self.queue = queue
        self.texture = texture
        self.staging = staging
        clear()
    }

    /// A .private texture's initial contents are unspecified. Every fixture
    /// replay starts from a blank VRAM by the format's own rule
    /// (`fixture.zig`'s FrameEntry doc comment), so this is not hygiene.
    func clear() {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    func upload(_ pixels: [UInt16]) {
        precondition(pixels.count == Self.pixelCount)
        pixels.withUnsafeBytes { src in
            staging.contents().copyMemory(from: src.baseAddress!, byteCount: src.count)
        }
        guard let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { return }
        blit.copy(from: staging, sourceOffset: 0,
                  sourceBytesPerRow: Self.width * 2, sourceBytesPerImage: Self.pixelCount * 2,
                  sourceSize: MTLSize(width: Self.width, height: Self.height, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    func readback() -> [UInt16] {
        guard let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else {
            return [UInt16](repeating: 0, count: Self.pixelCount)
        }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: Self.width, height: Self.height, depth: 1),
                  to: staging, destinationOffset: 0,
                  destinationBytesPerRow: Self.width * 2,
                  destinationBytesPerImage: Self.pixelCount * 2)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        var out = [UInt16](repeating: 0, count: Self.pixelCount)
        out.withUnsafeMutableBytes { dst in
            dst.baseAddress!.copyMemory(from: staging.contents(), byteCount: dst.count)
        }
        return out
    }

    /// FNV-1a 64 over the full 1024x512 as little-endian u16 — the same
    /// convention `ShadowVram` and `fixture.hashVram` already use.
    var hash: UInt64 { Fnv1a.hash(vram: readback()) }
}
