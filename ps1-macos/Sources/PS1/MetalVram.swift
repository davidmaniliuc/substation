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
/// Beside it — NOT instead of it — sits `sidecar`, an RGBA8 texture holding the
/// eight-bit colour of every pixel a draw has touched. It is written by the same
/// fragment shader invocation as a second colour attachment and read only by the
/// display shader. It is never sampled as a texel, never read back by the game,
/// never hashed by a gate and never compared by `PS1_LIVE_DIFF`; VRAM is
/// unchanged in every mode, which is why true colour needs no gate exemption.
/// DuckStation samples indexed texture data out of its RGBA8 target and converts
/// back down — on this axis the sidecar is more accurate than the reference, not
/// less.
///
/// Its ALPHA is per-pixel presence: 255 where it holds a real eight-bit colour,
/// 0 where the display falls back to `c << 3 | c >> 2` over VRAM. Per-pixel
/// rather than CPU-side dirty rectangles because it costs no bookkeeping, cannot
/// go stale, and is exact at rect boundaries — DuckStation needs two dirty rects
/// (`m_vram_dirty_draw_rect`, `m_vram_dirty_write_rect`) to answer the same
/// question.
///
/// This is a DIFFERENT texture from `MetalDisplayView`'s: that one is
/// .shaderRead/.managed and cannot be a render target.
final class MetalVram {
    /// PS1 VRAM's own dimensions. Every `Ps1PrimInstance` field, every
    /// `VramRect`, every `.vram` dump and every fixture hash is in THESE units
    /// at every internal resolution — Phase C scales in the shader, at the
    /// point of use, and nowhere else. Nothing that clamps a record (the box
    /// clamp, the line's VRAM bounds check, `wrapRanges`' axis, the oversized
    /// refusal) may use the scaled ones.
    static let nativeWidth = 1024
    static let nativeHeight = 512
    static let nativePixelCount = nativeWidth * nativeHeight

    /// Internal resolution multiplier, 1...8. At 8 the render texture is
    /// 8192 x 4096 x 2 = 67 MB, and the scratch copy target is another 67 MB.
    ///
    /// Out of range TRAPS rather than returning nil, unlike every other
    /// failure in this failable init. That is right because `InternalResolution`
    /// — the picker that reads a scale back from a persisted `UserDefaults`
    /// setting — is what clamps or rejects a bad value before it ever reaches
    /// here; by the time a scale arrives at this initializer it has already
    /// been validated data, so anything out of range at this point is a
    /// programming error, and a crash naming it beats a silent nil.
    let scale: Int
    var width: Int { Self.nativeWidth * scale }
    var height: Int { Self.nativeHeight * scale }
    var pixelCount: Int { width * height }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let texture: MTLTexture
    /// The display-only eight-bit sidecar — see the type comment. Always
    /// allocated, at every dither mode: the mode is a runtime uniform on an
    /// already-built pipeline, and making the allocation conditional would put
    /// a texture rebuild behind a setting that deliberately has none.
    let sidecar: MTLTexture
    /// Staging for both directions. Shared storage, allocated once: readback
    /// runs per fixture frame and a per-frame allocation of up to 67 MB is
    /// pure waste.
    private let staging: MTLBuffer

    init?(device: MTLDevice, queue: MTLCommandQueue, scale: Int = 1) {
        precondition(scale >= 1 && scale <= 8, "internal resolution must be 1...8")
        // Locals, not `self.width`: a computed property cannot be read before
        // every stored property is initialized.
        let w = Self.nativeWidth * scale
        let h = Self.nativeHeight * scale

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Uint, width: w, height: h, mipmapped: false)
        // .shaderRead as well as .renderTarget: the same texture is `read()`
        // at arbitrary coordinates by the fragment shader that is drawing into
        // it. That aliasing is legal only under the pass-splitting invariant —
        // nothing sampled during a render pass may have been written during
        // that pass — which the encoder's hazard tracking enforces.
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let texture = device.makeTexture(descriptor: desc),
              let staging = device.makeBuffer(length: w * h * 2, options: .storageModeShared)
        else { return nil }

        let sideDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Uint, width: w, height: h, mipmapped: false)
        // .shaderRead as well as .renderTarget for the same reason the render
        // texture needs it: the copy path samples a frozen snapshot of it, and
        // the display pass reads it every frame.
        sideDesc.usage = [.renderTarget, .shaderRead]
        sideDesc.storageMode = .private
        guard let sidecar = device.makeTexture(descriptor: sideDesc) else { return nil }

        self.scale = scale
        self.device = device
        self.queue = queue
        self.texture = texture
        self.sidecar = sidecar
        self.staging = staging
        clear()
    }

    /// A .private texture's initial contents are unspecified. Every fixture
    /// replay starts from a blank VRAM by the format's own rule
    /// (`fixture.zig`'s FrameEntry doc comment), so this is not hygiene.
    ///
    /// The nil guards below trap rather than degrade, here and in `upload`/
    /// `readback`: this class was written for test-and-fixture tooling only,
    /// and it is the trust anchor every Phase B gate reads its pass/fail answer
    /// from. Since Phase D1, `MetalDisplayView.Coordinator` also builds a
    /// `LiveRenderer` over this class, so it is now on the app's real-time
    /// render path too (`uploadNative` runs on every resync) — Phase D2 came
    /// and went without revisiting that: the traps stayed, on purpose. A
    /// silently-skipped clear or a readback that quietly hands back zeroes is
    /// indistinguishable from a correct blank VRAM — the exact failure this
    /// phase cannot absorb — so a hard crash naming the failed call is still
    /// strictly better than a wrong hash, or a wrong frame, nobody notices.
    func clear() {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        // Alpha 0 is ABSENT, so a cleared sidecar is the correct starting
        // state: the display expands VRAM, which is blank too.
        pass.colorAttachments[1].texture = sidecar
        pass.colorAttachments[1].loadAction = .clear
        pass.colorAttachments[1].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[1].storeAction = .store
        runClearPass(pass, label: "MetalVram.clear")
    }

    /// Marks the WHOLE sidecar absent without touching VRAM.
    ///
    /// The invalidation half of the coherence rules: a resync from a software
    /// frame (`LiveRenderer`'s `uploadNative`) carries a 5551 picture with no
    /// extra precision in it, so there is nothing to keep and claiming
    /// otherwise would display stale eight-bit colour under a new frame.
    ///
    /// Attachment 0 LOADS and STORES rather than being left off the
    /// descriptor: a pass with a hole at index 0 is a shape Metal validation
    /// has opinions about, and load/store says exactly what is meant — VRAM
    /// survives this.
    func clearSidecar() {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[1].texture = sidecar
        pass.colorAttachments[1].loadAction = .clear
        pass.colorAttachments[1].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[1].storeAction = .store
        runClearPass(pass, label: "MetalVram.clearSidecar")
    }

    /// The encode-and-wait both clears above share. Traps rather than degrades,
    /// for the reason `clear()`'s comment gives: a silently-skipped clear is
    /// indistinguishable from a correct blank.
    private func runClearPass(_ pass: MTLRenderPassDescriptor, label: String) {
        guard let cmd = queue.makeCommandBuffer() else {
            preconditionFailure("\(label): queue.makeCommandBuffer() returned nil")
        }
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else {
            preconditionFailure("\(label): makeRenderCommandEncoder(descriptor:) returned nil")
        }
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    private func blitStagingToTexture() {
        guard let cmd = queue.makeCommandBuffer() else {
            preconditionFailure("MetalVram.upload: queue.makeCommandBuffer() returned nil")
        }
        guard let blit = cmd.makeBlitCommandEncoder() else {
            preconditionFailure("MetalVram.upload: makeBlitCommandEncoder() returned nil")
        }
        blit.copy(from: staging, sourceOffset: 0,
                  sourceBytesPerRow: width * 2, sourceBytesPerImage: pixelCount * 2,
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    private func blitTextureToStaging() {
        guard let cmd = queue.makeCommandBuffer() else {
            preconditionFailure("MetalVram.readback: queue.makeCommandBuffer() returned nil")
        }
        guard let blit = cmd.makeBlitCommandEncoder() else {
            preconditionFailure("MetalVram.readback: makeBlitCommandEncoder() returned nil")
        }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: staging, destinationOffset: 0,
                  destinationBytesPerRow: width * 2,
                  destinationBytesPerImage: pixelCount * 2)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    /// A SCALED image: `pixelCount` entries. Identical to Phase B's at scale 1.
    func upload(_ pixels: [UInt16]) {
        precondition(pixels.count == pixelCount)
        pixels.withUnsafeBytes { src in
            staging.contents().copyMemory(from: src.baseAddress!, byteCount: src.count)
        }
        blitStagingToTexture()
    }

    /// A NATIVE image, replicated N x N into the scaled texture.
    ///
    /// This is the resync path the parent spec's § Frame pacing requires when
    /// the frame queue or the stream buffer overflows and the software side's
    /// VRAM becomes the truth. It is built here, where it is a scale concern
    /// and headlessly testable; Phase D consumes it. CPU-side replication into
    /// the existing staging buffer is sufficient — the path is rare by
    /// construction, and a blit-and-blow-up render pass would need a pipeline
    /// and a pass boundary to save a copy nobody is waiting on.
    func uploadNative(_ pixels: [UInt16]) {
        precondition(pixels.count == Self.nativePixelCount)
        if scale == 1 { upload(pixels); return }
        let dst = staging.contents().bindMemory(to: UInt16.self, capacity: pixelCount)
        for y in 0..<Self.nativeHeight {
            let srcRow = y * Self.nativeWidth
            for sy in 0..<scale {
                var o = (y * scale + sy) * width
                for x in 0..<Self.nativeWidth {
                    let v = pixels[srcRow + x]
                    for _ in 0..<scale { dst[o] = v; o += 1 }
                }
            }
        }
        blitStagingToTexture()
    }

    /// The SCALED image: `pixelCount` entries.
    func readback() -> [UInt16] {
        blitTextureToStaging()
        var out = [UInt16](repeating: 0, count: pixelCount)
        out.withUnsafeMutableBytes { dst in
            dst.baseAddress!.copyMemory(from: staging.contents(), byteCount: dst.count)
        }
        return out
    }

    /// The NATIVE view: each N x N block's TOP-LEFT subtexel, `nativePixelCount`
    /// entries. Subpixels other than the top-left may legitimately differ from
    /// their block's native value — that is what supersampling is — and this
    /// discards them, which is what makes the exactness property checkable.
    ///
    /// Reads out of the staging buffer directly rather than through
    /// `readback()`: at scale 8 that would materialize a 67 MB array per frame
    /// to keep 1/64th of it, on the hottest path in Gate 2.
    func readbackNative() -> [UInt16] {
        blitTextureToStaging()
        let src = staging.contents().bindMemory(to: UInt16.self, capacity: pixelCount)
        var out = [UInt16](repeating: 0, count: Self.nativePixelCount)
        for y in 0..<Self.nativeHeight {
            let srcRow = y * scale * width
            let dstRow = y * Self.nativeWidth
            for x in 0..<Self.nativeWidth { out[dstRow + x] = src[srcRow + x * scale] }
        }
        return out
    }

    /// Staging for the sidecar, allocated on FIRST USE and then kept.
    ///
    /// Lazy because the app never takes this path: the display samples the
    /// sidecar on the GPU and `PS1_LIVE_DIFF` reads VRAM. Only tests and Gate 3
    /// pull it back over the bus, and at scale 8 an eager allocation is 134 MB
    /// that a shipped build would never touch.
    private var sidecarStaging: MTLBuffer?

    private func sidecarStagingBuffer() -> MTLBuffer {
        if let b = sidecarStaging { return b }
        guard let b = device.makeBuffer(length: pixelCount * 4, options: .storageModeShared) else {
            preconditionFailure("MetalVram.readbackSidecar: makeBuffer returned nil")
        }
        sidecarStaging = b
        return b
    }

    private func blitSidecarToStaging() -> MTLBuffer {
        let buffer = sidecarStagingBuffer()
        guard let cmd = queue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else {
            preconditionFailure("MetalVram.readbackSidecar: blit encoder returned nil")
        }
        blit.copy(from: sidecar, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: width * 4,
                  destinationBytesPerImage: pixelCount * 4)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return buffer
    }

    /// The SCALED sidecar: `pixelCount * 4` bytes, R, G, B, A per pixel.
    func readbackSidecar() -> [UInt8] {
        let buffer = blitSidecarToStaging()
        var out = [UInt8](repeating: 0, count: pixelCount * 4)
        out.withUnsafeMutableBytes { dst in
            dst.baseAddress!.copyMemory(from: buffer.contents(), byteCount: dst.count)
        }
        return out
    }

    /// The NATIVE view of the sidecar: each N x N block's TOP-LEFT subtexel,
    /// `nativePixelCount * 4` bytes. The same view — and the same reasoning —
    /// as `readbackNative()`.
    func readbackSidecarNative() -> [UInt8] {
        let buffer = blitSidecarToStaging()
        let src = buffer.contents().bindMemory(to: UInt8.self, capacity: pixelCount * 4)
        var out = [UInt8](repeating: 0, count: MetalVram.nativePixelCount * 4)
        for y in 0..<Self.nativeHeight {
            let srcRow = y * scale * width * 4
            let dstRow = y * Self.nativeWidth * 4
            for x in 0..<Self.nativeWidth {
                let s = srcRow + x * scale * 4
                let d = dstRow + x * 4
                out[d] = src[s]; out[d + 1] = src[s + 1]
                out[d + 2] = src[s + 2]; out[d + 3] = src[s + 3]
            }
        }
        return out
    }

    /// FNV-1a 64 over the full SCALED texture as little-endian u16 — the same
    /// convention `ShadowVram` and `fixture.hashVram` already use. At scale 1
    /// this is the value every Phase B gate compares.
    var hash: UInt64 { Fnv1a.hash(vram: readback()) }

    /// FNV-1a 64 over the native view. This is the Phase C gate's currency:
    /// at every scale it must equal the 1x `hash` of the same replay.
    var nativeHash: UInt64 { Fnv1a.hash(vram: readbackNative()) }
}
