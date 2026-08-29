import Foundation
import Metal
import CPs1

/// Turns a recorded GP0 command stream into Metal work against a `MetalVram`.
///
/// Every primitive is one INSTANCE of a bounding-box quad, with all its state
/// resolved here on the CPU and written into a `Ps1PrimInstance`. Because no
/// pipeline state differs between drawing primitives, a whole run of them is
/// one instanced draw and ordering is preserved by instance index — the only
/// thing that ends a run is a hazard.
///
/// Allocation on this path is fine: Phase B is fixture-driven and never runs
/// on the emulator thread. Phase D owns the no-allocation requirement.
final class MetalRasterizer {
    enum Error: Swift.Error { case missingFunction(String) }

    // Step/DrawKind, and the `instances`/`steps`/`transfer`/`payloadCount`
    // storage below, are `internal` rather than `private` so `PrimEncoders.swift`
    // — an extension of this class in a sibling file — can read and mutate
    // them. `private` in Swift scopes to the enclosing file, not the type, so a
    // cross-file split forces this; nothing here is part of any public API.
    enum Step {
        case draw(kind: DrawKind, range: Range<Int>)
        /// Blit VRAM into `scratch`. Forces a pass boundary: a blit cannot be
        /// encoded inside a render pass.
        case snapshot
        case passBreak
    }

    enum DrawKind { case prim, fill, upload, copy }

    let vram: MetalVram
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: [DrawKind: MTLRenderPipelineState]
    private let scratch: MTLTexture

    private(set) var env = DrawEnv()
    private(set) var passCount = 0
    /// Set once `apply` meets a record this backend does not model, mirroring
    /// `ShadowVram.sawUnmodelledKind`: without it a fixture carrying an
    /// unhandled kind replays to a wrong hash with nothing to say why.
    private(set) var sawUnmodelledKind = false

    var transfer = VramTransfer()
    var instances: [Ps1PrimInstance] = []
    var steps: [Step] = []
    private var hazards = HazardTracker()
    private var payloadBuffer: MTLBuffer?
    /// The frame's actual payload word count, kept separately from
    /// `payloadBuffer.length`: `beginFrame` rounds a zero-length payload up to
    /// a 4-byte buffer, so deriving the count back from the byte length would
    /// read 1 for an empty frame and let one bogus word through.
    var payloadCount = 0

    init(vram: MetalVram) throws {
        self.vram = vram
        self.device = vram.device
        self.queue = vram.queue

        let library = try Shaders.makeLibrary(device)
        pipelines = [
            .prim: try Self.makePipeline(device: device, library: library, fragment: "ps1_prim_fragment"),
            .fill: try Self.makePipeline(device: device, library: library, fragment: "ps1_fill_fragment"),
            .upload: try Self.makePipeline(device: device, library: library, fragment: "ps1_upload_fragment"),
            .copy: try Self.makePipeline(device: device, library: library, fragment: "ps1_copy_fragment"),
        ]

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Uint, width: MetalVram.width, height: MetalVram.height,
            mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .private
        guard let scratch = device.makeTexture(descriptor: desc) else {
            throw Error.missingFunction("scratch texture")
        }
        self.scratch = scratch
    }

    /// A `static` helper rather than a closure nested in `init`: a nested
    /// function declared before every stored property is set captures `self`
    /// for the Swift compiler's definite-initialization check even though it
    /// never touches a `self` member, and that trips "variable used before
    /// being initialized" on the very `pipelines =` assignment that calls it.
    /// Taking `device`/`library` as explicit parameters sidesteps the capture
    /// entirely.
    private static func makePipeline(device: MTLDevice, library: MTLLibrary,
                                      fragment: String) throws -> MTLRenderPipelineState {
        guard let vs = library.makeFunction(name: "ps1_vertex") else {
            throw Error.missingFunction("ps1_vertex")
        }
        guard let fs = library.makeFunction(name: fragment) else {
            throw Error.missingFunction(fragment)
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vs
        desc.fragmentFunction = fs
        desc.colorAttachments[0].pixelFormat = .r16Uint
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    // MARK: - Frame lifecycle

    func beginFrame(payload: UnsafeBufferPointer<UInt32>) {
        hazards.reset()
        instances.removeAll(keepingCapacity: true)
        steps.removeAll(keepingCapacity: true)
        // Metal rejects a zero-length buffer, and an empty payload is the
        // common case (only A0 frames have one).
        let bytes = max(payload.count * 4, 4)
        payloadBuffer = device.makeBuffer(length: bytes, options: .storageModeShared)
        payloadCount = payload.count
        if let base = payload.baseAddress, payload.count > 0 {
            payloadBuffer?.contents().copyMemory(from: base, byteCount: payload.count * 4)
        }
    }

    func endFrame() {
        defer {
            instances.removeAll(keepingCapacity: true)
            steps.removeAll(keepingCapacity: true)
        }
        guard !steps.isEmpty, !instances.isEmpty else { return }
        guard let cmd = queue.makeCommandBuffer() else { return }
        let instanceBuffer = device.makeBuffer(
            bytes: instances,
            length: instances.count * MemoryLayout<Ps1PrimInstance>.stride,
            options: .storageModeShared)

        var encoder: MTLRenderCommandEncoder?
        func closePass() {
            encoder?.endEncoding()
            encoder = nil
        }
        func openPass() -> MTLRenderCommandEncoder? {
            if let e = encoder { return e }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = vram.texture
            // .load, never .clear: VRAM persists across frames, and every
            // pass after the first in a frame must see the previous one's work.
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
            guard let e = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            e.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
            e.setFragmentBuffer(instanceBuffer, offset: 0, index: 0)
            if let p = payloadBuffer { e.setFragmentBuffer(p, offset: 0, index: 1) }
            encoder = e
            passCount += 1
            return e
        }

        for step in steps {
            switch step {
            case .passBreak:
                closePass()
            case .snapshot:
                closePass()
                if let blit = cmd.makeBlitCommandEncoder() {
                    blit.copy(from: vram.texture, sourceSlice: 0, sourceLevel: 0,
                              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                              sourceSize: MTLSize(width: MetalVram.width,
                                                  height: MetalVram.height, depth: 1),
                              to: scratch, destinationSlice: 0, destinationLevel: 0,
                              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                    blit.endEncoding()
                }
            case let .draw(kind, range):
                guard !range.isEmpty, let e = openPass(), let state = pipelines[kind] else { continue }
                e.setRenderPipelineState(state)
                // The prim path samples the ATTACHMENT ITSELF; only copy reads
                // the snapshot. Nothing else binds a texture at all.
                e.setFragmentTexture(kind == .copy ? scratch : vram.texture, index: 0)
                e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                 instanceCount: range.count, baseInstance: range.lowerBound)
            }
        }
        closePass()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    // MARK: - Records

    func apply(_ cmd: Ps1GpuCommand) {
        switch cmd.commandKind {
        case PS1_GPU_SET_DRAW_ENV, PS1_GPU_LATCH_TEXPAGE,
             PS1_GPU_SET_TEXTURE_DISABLE_ALLOWED, PS1_GPU_RESET_DRAW_ENV:
            env.apply(cmd)

        case PS1_GPU_DRAW_TRIANGLE:
            if let inst = PrimBuilder.triangle(cmd, env: env, kind: Int32(PS1_PRIM_FLAT_TRI)) {
                appendPrim(inst)
            }

        case PS1_GPU_DRAW_SHADED_TRIANGLE:
            if let inst = PrimBuilder.triangle(cmd, env: env, kind: Int32(PS1_PRIM_GOURAUD_TRI)) {
                appendPrim(inst)
            }

        case PS1_GPU_DRAW_TEXTURED_TRIANGLE:
            if var inst = PrimBuilder.triangle(cmd, env: env, kind: Int32(PS1_PRIM_TEXTURED_TRI)) {
                PrimBuilder.applyTexture(cmd, to: &inst)
                appendPrim(inst)
            }

        case PS1_GPU_DRAW_RECTANGLE:
            if let inst = PrimBuilder.rectangle(cmd, env: env, kind: Int32(PS1_PRIM_RECT)) {
                appendPrim(inst)
            }
        case PS1_GPU_DRAW_TEXTURED_RECTANGLE:
            if var inst = PrimBuilder.rectangle(cmd, env: env, kind: Int32(PS1_PRIM_TEXTURED_RECT)) {
                PrimBuilder.applyTexture(cmd, to: &inst)
                appendPrim(inst)
            }

        case PS1_GPU_DRAW_LINE, PS1_GPU_DRAW_SHADED_LINE:
            encodeLine(cmd)

        case PS1_GPU_FILL_RECT:
            encodeFill(cmd)
        case PS1_GPU_COPY_RECT:
            encodeCopy(cmd)
        case PS1_GPU_VRAM_WRITE_SETUP:
            transfer.setup(x: Int(cmd.x), y: Int(cmd.y), w: Int(cmd.w), h: Int(cmd.h))
        case PS1_GPU_VRAM_WRITE_DATA:
            encodeUpload(cmd)
        case PS1_GPU_VRAM_WRITE_ABORT:
            transfer.abort()

        case PS1_GPU_VRAM_READ_SETUP:
            // Moves no pixel. GPUREAD is served from the shadow (parent spec,
            // § Ownership and sync), so there is nothing to do here — and
            // that is "irrelevant", not "unmodelled".
            break

        default:
            sawUnmodelledKind = true
        }
    }

    // MARK: - Movers

    /// A mover both starts and ends a render pass. Conservative and always
    /// correct: it is what lets a textured primitive sample a texture uploaded
    /// earlier in the SAME frame. Task 11's dirty-rect hazard test is added on
    /// top of this rule, never in place of it.
    ///
    /// `internal`, not `private`: `PrimEncoders.swift`'s encoders call this
    /// across the file split, and Task 11 patches this function by name.
    func breakPass() {
        hazards.reset()
        if case .passBreak? = steps.last { return }
        steps.append(.passBreak)
    }

    /// Drawing primitives accumulate into ONE instanced draw. The only thing
    /// that ends a run is a mover (Decision 9) or, from Task 11, a hazard.
    ///
    /// `internal`, not `private`: called from `PrimEncoders.swift` (line
    /// encoding) across the file split, and Task 11 patches this function by
    /// name.
    func appendPrim(_ inst: Ps1PrimInstance) {
        if hazards.needsBreak(sampling: PrimBuilder.sampledRects(of: inst)) {
            breakPass()
        }
        hazards.markWritten(VramRect(x0: Int(inst.box_x0), y0: Int(inst.box_y0),
                                     x1: Int(inst.box_x1), y1: Int(inst.box_y1)))
        let i = instances.count
        instances.append(inst)
        if case let .draw(kind, range)? = steps.last, kind == .prim, range.upperBound == i {
            steps[steps.count - 1] = .draw(kind: .prim, range: range.lowerBound..<(i + 1))
        } else {
            steps.append(.draw(kind: .prim, range: i..<(i + 1)))
        }
    }
}
