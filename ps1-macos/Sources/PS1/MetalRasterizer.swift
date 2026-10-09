import Foundation
import Metal
import CPs1

/// Which specialised pipeline a primitive draws with. True colour is NOT
/// here: it is one per-frame setting, so it selects the pipeline TABLE.
struct PrimVariant: Hashable {
    /// The `PS1_PRIM_*` class, 0 (flat triangle) to 6 (shaded line pixel).
    let kind: Int32
    /// Whether the draw's output depends on the destination pixel: blended,
    /// mask-checked, depth-tested, or the depth plane persisting (the shader
    /// writes the stored depth back where it does not write its own).
    let readsDst: Bool
}

/// Turns a recorded GP0 command stream into Metal work against a `MetalVram`.
///
/// Every primitive is one INSTANCE of a bounding-box quad, with all its state
/// resolved here on the CPU and written into a `Ps1PrimInstance`. The only
/// pipeline state that differs between drawing primitives is the specialised
/// variant (`PrimVariant`), so a run of one variant is one instanced draw and
/// ordering is preserved by instance index: a run ends at a variant change, a
/// mover or a hazard. Consecutive draws stay in submission order whatever
/// pipeline each uses.
///
/// Allocation is not on the emulator thread (that one hands over a copied
/// stream and returns), but it is on the render thread once per frame, so the
/// instance and payload buffers are persistent and reused rather than rebuilt.
final class MetalRasterizer {
    enum Error: Swift.Error { case missingFunction(String) }

    // Step/DrawKind, and the `instances`/`steps`/`transfer`/`payloadCount`
    // storage below, are `internal` rather than `private` so `PrimEncoders.swift`
    // (an extension of this class in a sibling file) can read and mutate
    // them. `private` in Swift scopes to the enclosing file, not the type, so a
    // cross-file split forces this; nothing here is part of any public API.
    enum Step {
        case draw(kind: DrawKind, range: Range<Int>)
        /// Blit VRAM into `scratch`. Forces a pass boundary: a blit cannot be
        /// encoded inside a render pass.
        case snapshot
        case passBreak
    }

    enum DrawKind: Hashable { case prim(PrimVariant), fill, upload, copy, depthClear }

    let vram: MetalVram
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: [DrawKind: MTLRenderPipelineState]
    /// [trueColour][variant]: every specialised primitive pipeline, built in
    /// `init` so the first use of a variant mid-game is not a compile hitch.
    private let primPipelines: [Bool: [PrimVariant: MTLRenderPipelineState]]
    var variantPipelineCount: Int { primPipelines.values.reduce(0) { $0 + $1.count } }
    private let scratch: MTLTexture
    /// The sidecar's half of the copy snapshot. Blitted in the SAME `.snapshot`
    /// step as `scratch`, so both halves of a VRAM->VRAM copy read a source
    /// frozen at the same instant.
    private let sidecarScratch: MTLTexture

    private(set) var env = DrawEnv()

    /// What a speculative group changes on the CPU side: the environment and
    /// an upload in progress. `LiveRenderer` puts both back after replaying
    /// one, as it puts the pixels back.
    struct State {
        fileprivate let env: DrawEnv
        fileprivate let transfer: VramTransfer
    }

    var state: State {
        get { State(env: env, transfer: transfer) }
        set {
            env = newValue.env
            transfer = newValue.transfer
        }
    }
    private(set) var passCount = 0
    /// Set once `apply` meets a record this backend does not model, mirroring
    /// `ShadowVram.sawUnmodelledKind`: without it a fixture carrying an
    /// unhandled kind replays to a wrong hash with nothing to say why.
    private(set) var sawUnmodelledKind = false

    /// Where the dither pattern is sampled: see `DitherMode`.
    ///
    /// A UNIFORM, not a flag cleared in PrimBuilder, so the instance bytes stay
    /// identical to the ones Gate 1 checks whatever the mode is. Gate 2
    /// (downsample-invariance) runs it at `.off` on both sides of the
    /// comparison, and at `.native` in the one test that pins dithering as no
    /// longer being an exception to exactness.
    var ditherMode = DitherSetting.defaultMode

    /// How 3D textured primitives sample, for the sidecar only: see `TextureFilter`.
    /// A uniform for `ditherMode`'s reason: the instance bytes Gate 1 checks
    /// stay identical whatever it is.
    var textureFilter = TextureFilterSetting.defaultFilter

    /// How sprites sample: textured rectangles and screen-aligned 2D polygons.
    /// A uniform for `textureFilter`'s reason.
    var spriteFilter = SpriteFilterSetting.defaultFilter

    /// Whether `endFrame` blocks until the GPU has finished.
    ///
    /// True for every fixture gate, which reads VRAM back the instant
    /// `endFrame` returns. False on the live path, where blocking the draw
    /// callback on the GPU would cost a frame for nothing: `LiveRenderer`
    /// shares one command queue with the display pass, so commit order already
    /// orders the rasterizer's writes before the display's sampling.
    var synchronous = true

    /// Called with each frame's command buffer just before it is committed.
    /// The benchmark's only way in: it adds a completed handler that reads
    /// the GPU's own timestamps. Nil on every other path.
    var onCommit: ((MTLCommandBuffer) -> Void)?

    var transfer = VramTransfer()
    var instances: [Ps1PrimInstance] = []
    var steps: [Step] = []
    private var hazards = HazardTracker()
    /// The frame's actual payload word count. A slot's payload buffer is
    /// always sized at `PS1_GPU_MAX_PAYLOAD_WORDS`; this is how much of it is
    /// valid for the current frame.
    var payloadCount = 0

    /// One frame's two persistent buffers, plus the command buffer that may
    /// still be reading them.
    ///
    /// Commit order (see `synchronous` above) orders GPU work against GPU
    /// work; it says nothing about the CPU overwriting a buffer while a
    /// committed-but-unfinished command buffer is still issuing reads of it.
    /// That is the race persistent buffers introduce and per-frame ones never
    /// had, and the first answer to it was to block the next `beginFrame` on
    /// the previous frame's completion.
    ///
    /// Correct, but it serializes encode against execute: per frame the cost
    /// became CPU + GPU rather than max(CPU, GPU), and (the part that
    /// mattered) draining a backlog of N frames in one draw callback cost N
    /// full frames back to back, so a renderer that fell behind could never
    /// catch up and the queue overran instead. Cycling the buffers lets the
    /// CPU write frame n+1 while the GPU still reads frame n.
    private final class FrameBuffers {
        /// Sized once at the recorder's own cap (2 MB) and reused. A per-frame
        /// allocation here is up to 2 MB at 60 Hz for nothing.
        let payload: MTLBuffer
        /// Grows by doubling and then stays. Instance count is NOT bounded by
        /// record count (`LineExpander` turns one line record into one
        /// instance per pixel), so this cannot be sized from the recorder's
        /// cap. Per slot, because a grown buffer must not be shared with a
        /// slot whose in-flight command buffer bound the old one.
        var instances: MTLBuffer
        var instanceCapacity: Int
        /// Left `nil` whenever nothing is genuinely pending, so a frame that
        /// commits no work (see `endFrame`'s early guard) neither drops a real
        /// pending buffer nor makes a later `beginFrame` wait on a stale one.
        var inFlight: MTLCommandBuffer?

        init(payload: MTLBuffer, instances: MTLBuffer, instanceCapacity: Int) {
            self.payload = payload
            self.instances = instances
            self.instanceCapacity = instanceCapacity
        }
    }

    /// Three, matching MTKView's triple-buffered drawables: with up to three
    /// frames in flight, a depth of two would hit the wait every frame and put
    /// the serialization straight back.
    private static let frameBufferDepth = 3
    private var frameBuffers: [FrameBuffers] = []
    private var frameBufferIndex = 0
    private var current: FrameBuffers { frameBuffers[frameBufferIndex] }

    init(vram: MetalVram) throws {
        self.vram = vram
        self.device = vram.device
        self.queue = vram.queue

        let library = try Shaders.makeLibrary(device)
        pipelines = [
            .fill: try Self.makePipeline(device: device, library: library,
                                         fragment: "ps1_fill_fragment"),
            .upload: try Self.makePipeline(device: device, library: library,
                                           fragment: "ps1_upload_fragment"),
            .copy: try Self.makePipeline(device: device, library: library,
                                         fragment: "ps1_copy_fragment"),
            .depthClear: try Self.makePipeline(device: device, library: library,
                                               fragment: "ps1_depth_clear_fragment"),
        ]

        var tables: [Bool: [PrimVariant: MTLRenderPipelineState]] = [:]
        for trueColour in [false, true] {
            var table: [PrimVariant: MTLRenderPipelineState] = [:]
            for kind in Int32(PS1_PRIM_FLAT_TRI)...Int32(PS1_PRIM_SHADED_LINE_PIXEL) {
                for readsDst in [false, true] {
                    let v = PrimVariant(kind: kind, readsDst: readsDst)
                    table[v] = try Self.makePipeline(
                        device: device, library: library,
                        fragment: readsDst ? "ps1_prim_fragment_dst" : "ps1_prim_fragment_nodst",
                        primClass: kind, trueColour: trueColour)
                }
            }
            tables[trueColour] = table
        }
        primPipelines = tables

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Uint, width: vram.width, height: vram.height,
            mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .private
        guard let scratch = device.makeTexture(descriptor: desc) else {
            throw Error.missingFunction("scratch texture")
        }
        self.scratch = scratch

        let sideDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Uint, width: vram.width, height: vram.height,
            mipmapped: false)
        sideDesc.usage = .shaderRead
        sideDesc.storageMode = .private
        guard let sidecarScratch = device.makeTexture(descriptor: sideDesc) else {
            throw Error.missingFunction("sidecar scratch texture")
        }
        self.sidecarScratch = sidecarScratch

        // 65,536 instances is 11 MB at 168 bytes each, and covers every frame
        // in the fixture corpus with room to spare.
        let initialInstances = 65_536
        for _ in 0..<Self.frameBufferDepth {
            guard let payload = device.makeBuffer(
                length: Int(PS1_GPU_MAX_PAYLOAD_WORDS) * 4,
                options: .storageModeShared) else {
                throw Error.missingFunction("payload buffer")
            }
            guard let instances = device.makeBuffer(
                length: initialInstances * MemoryLayout<Ps1PrimInstance>.stride,
                options: .storageModeShared) else {
                throw Error.missingFunction("instance buffer")
            }
            frameBuffers.append(FrameBuffers(payload: payload, instances: instances,
                                             instanceCapacity: initialInstances))
        }
    }

    /// A `static` helper rather than a closure nested in `init`: a nested
    /// function declared before every stored property is set captures `self`
    /// for the Swift compiler's definite-initialization check even though it
    /// never touches a `self` member, and that trips "variable used before
    /// being initialized" on the very `pipelines =` assignment that calls it.
    /// Taking `device`/`library` as explicit parameters sidesteps the capture
    /// entirely.
    private static func makePipeline(device: MTLDevice, library: MTLLibrary,
                                      fragment: String,
                                      primClass: Int32? = nil,
                                      trueColour: Bool = false) throws -> MTLRenderPipelineState {
        guard let vs = library.makeFunction(name: "ps1_vertex") else {
            throw Error.missingFunction("ps1_vertex")
        }
        let fs: MTLFunction
        if let primClass {
            // Rasterizer.metal's PS1_FC_CLASS (1) and PS1_FC_TRUE_COLOR (2).
            let fc = MTLFunctionConstantValues()
            var cls = primClass
            var tc = trueColour
            fc.setConstantValue(&cls, type: .int, index: 1)
            fc.setConstantValue(&tc, type: .bool, index: 2)
            fs = try library.makeFunction(name: fragment, constantValues: fc)
        } else {
            guard let f = library.makeFunction(name: fragment) else {
                throw Error.missingFunction(fragment)
            }
            fs = f
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vs
        desc.fragmentFunction = fs
        desc.colorAttachments[0].pixelFormat = .r16Uint
        // Every rasterizer pipeline declares the same three colour formats
        // unconditionally, so every pass shares one attachment set and no
        // fragment function's [[color(1)]]/[[color(2)]] output ever finds
        // nothing behind it. (A narrower pipeline is not itself an error:
        // MetalMoverTests's one-attachment mover pipeline creates fine even
        // though the shared fragment functions write all three outputs;
        // Metal just drops the ones with nothing behind them. Declaring all
        // three here is for uniformity and cost, not to dodge a creation-time
        // failure.)
        desc.colorAttachments[1].pixelFormat = .rgba8Uint
        desc.colorAttachments[2].pixelFormat = .r32Uint
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    // MARK: - Frame lifecycle

    func beginFrame(payload: UnsafeBufferPointer<UInt32>) {
        // Advance FIRST, then wait on the slot about to be overwritten, and
        // on that slot alone. With three slots and at most three frames in
        // flight this wait is essentially never reached; when it is, it is the
        // genuine "the GPU is a full cycle behind" case that no depth avoids.
        frameBufferIndex = (frameBufferIndex + 1) % frameBuffers.count
        let f = current
        f.inFlight?.waitUntilCompleted()
        f.inFlight = nil

        hazards.reset()
        instances.removeAll(keepingCapacity: true)
        steps.removeAll(keepingCapacity: true)
        payloadCount = payload.count
        if let base = payload.baseAddress, payload.count > 0 {
            precondition(payload.count <= Int(PS1_GPU_MAX_PAYLOAD_WORDS))
            f.payload.contents().copyMemory(
                from: base, byteCount: payload.count * 4)
        }
    }

    func endFrame() {
        defer {
            // `endFrame` closes the last pass too (see `closePass()` below),
            // so this is a fourth reset site alongside `beginFrame`/`breakPass`:
            // deliberate, not load-bearing: the next `beginFrame` would reset
            // it anyway, but leaving it implicit invited exactly this question.
            hazards.reset()
            instances.removeAll(keepingCapacity: true)
            steps.removeAll(keepingCapacity: true)
        }
        guard !steps.isEmpty, !instances.isEmpty else { return }
        guard let cmd = queue.makeCommandBuffer() else { return }

        let f = current
        if instances.count > f.instanceCapacity {
            var cap = f.instanceCapacity
            while cap < instances.count { cap *= 2 }
            guard let grown = device.makeBuffer(
                length: cap * MemoryLayout<Ps1PrimInstance>.stride,
                options: .storageModeShared) else { return }
            f.instances = grown
            f.instanceCapacity = cap
        }
        instances.withUnsafeBytes { src in
            f.instances.contents().copyMemory(
                from: src.baseAddress!, byteCount: src.count)
        }

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
            // .load here too: the sidecar persists across frames and across
            // passes exactly as VRAM does, and every pass after the first in a
            // frame must see the previous one's presence flags.
            pass.colorAttachments[1].texture = vram.sidecar
            pass.colorAttachments[1].loadAction = .load
            pass.colorAttachments[1].storeAction = .store
            vram.attachDepth(to: pass, clearing: false)
            guard let e = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            e.setVertexBuffer(f.instances, offset: 0, index: 0)
            e.setFragmentBuffer(f.instances, offset: 0, index: 0)
            e.setFragmentBuffer(f.payload, offset: 0, index: 1)
            var uni = Ps1RasterUniforms(scale: UInt32(vram.scale),
                                        dither_mode: ditherMode.uniformValue,
                                        texture_filter: textureFilter.uniformValue,
                                        sprite_filter: spriteFilter.uniformValue)
            e.setVertexBytes(&uni, length: MemoryLayout<Ps1RasterUniforms>.stride, index: 2)
            e.setFragmentBytes(&uni, length: MemoryLayout<Ps1RasterUniforms>.stride, index: 2)
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
                              sourceSize: MTLSize(width: vram.width,
                                                  height: vram.height, depth: 1),
                              to: scratch, destinationSlice: 0, destinationLevel: 0,
                              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                    blit.copy(from: vram.sidecar, sourceSlice: 0, sourceLevel: 0,
                              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                              sourceSize: MTLSize(width: vram.width,
                                                  height: vram.height, depth: 1),
                              to: sidecarScratch, destinationSlice: 0, destinationLevel: 0,
                              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                    blit.endEncoding()
                }
            case let .draw(kind, range):
                let state: MTLRenderPipelineState?
                if case let .prim(v) = kind {
                    state = primPipelines[ditherMode == .trueColor]?[v]
                } else {
                    state = pipelines[kind]
                }
                guard !range.isEmpty, let e = openPass(), let state else { continue }
                e.setRenderPipelineState(state)
                // The prim path samples the ATTACHMENT ITSELF; only copy reads
                // the snapshot. Nothing else binds a texture at all.
                e.setFragmentTexture(kind == .copy ? scratch : vram.texture, index: 0)
                // Bound for every kind, like the display pass's two: only
                // ps1_copy_fragment declares it, and a declared-but-unbound
                // texture2d is a validation failure rather than a black pixel.
                e.setFragmentTexture(sidecarScratch, index: 1)
                e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                 instanceCount: range.count, baseInstance: range.lowerBound)
            }
        }
        closePass()
        onCommit?(cmd)
        cmd.commit()
        // Retained on THIS slot so the `beginFrame` that comes back round to
        // it waits before overwriting the buffers this command buffer bound.
        // When `synchronous` waits below, the buffer is already complete by
        // the time anything reads it back, so that wait is free.
        f.inFlight = cmd
        if synchronous { cmd.waitUntilCompleted() }
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
            // § Ownership and sync), so there is nothing to do here, and
            // that is "irrelevant", not "unmodelled".
            break
        case PS1_GPU_CLEAR_DEPTH:
            encodeDepthClear(cmd)

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

    /// Drawing primitives of one `PrimVariant` accumulate into ONE instanced
    /// draw. A run ends at a variant change, a mover (Decision 9) or a hazard.
    ///
    /// `internal`, not `private`: called from `PrimEncoders.swift` (line
    /// encoding) across the file split, and Task 11 patches this function by
    /// name.
    func appendPrim(_ inst: Ps1PrimInstance) {
        let sampled = PrimBuilder.sampledRects(of: inst)
        let box = VramRect(x0: Int(inst.box_x0), y0: Int(inst.box_y0),
                           x1: Int(inst.box_x1), y1: Int(inst.box_y1))
        if hazards.needsBreak(sampling: sampled) || hazards.needsBreak(writing: box) {
            breakPass()
        }
        hazards.markRead(sampled)
        hazards.markWritten(box)
        // The destination is read wherever `ps1_prim_shade` reads `dst`,
        // `dst_side` or `dst_depth`: blending, the mask check and the depth
        // test, plus a persisting depth plane, where every draw that does
        // not write its own depth writes the stored one back.
        let variant = PrimVariant(
            kind: inst.kind,
            readsDst: inst.flags & (PS1_PRIM_TRANSPARENT | PS1_PRIM_CHECK_MASK | PS1_PRIM_DEPTH_TEST) != 0
                || vram.depthPersists)
        let i = instances.count
        instances.append(inst)
        if case let .draw(.prim(v), range)? = steps.last, v == variant, range.upperBound == i {
            steps[steps.count - 1] = .draw(kind: .prim(variant), range: range.lowerBound..<(i + 1))
        } else {
            steps.append(.draw(kind: .prim(variant), range: i..<(i + 1)))
        }
    }
}
