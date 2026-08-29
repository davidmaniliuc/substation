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

    private enum Step {
        case draw(kind: DrawKind, range: Range<Int>)
        /// Blit VRAM into `scratch`. Forces a pass boundary: a blit cannot be
        /// encoded inside a render pass.
        case snapshot
        case passBreak
    }

    private enum DrawKind { case prim, fill, upload, copy }

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

    private var transfer = VramTransfer()
    private var instances: [Ps1PrimInstance] = []
    private var steps: [Step] = []
    private var payloadBuffer: MTLBuffer?
    /// The frame's actual payload word count, kept separately from
    /// `payloadBuffer.length`: `beginFrame` rounds a zero-length payload up to
    /// a 4-byte buffer, so deriving the count back from the byte length would
    /// read 1 for an empty frame and let one bogus word through.
    private var payloadCount = 0

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
    private func breakPass() {
        if case .passBreak? = steps.last { return }
        steps.append(.passBreak)
    }

    /// Drawing primitives accumulate into ONE instanced draw. The only thing
    /// that ends a run is a mover (Decision 9) or, from Task 11, a hazard.
    private func appendPrim(_ inst: Ps1PrimInstance) {
        let i = instances.count
        instances.append(inst)
        if case let .draw(kind, range)? = steps.last, kind == .prim, range.upperBound == i {
            steps[steps.count - 1] = .draw(kind: .prim, range: range.lowerBound..<(i + 1))
        } else {
            steps.append(.draw(kind: .prim, range: i..<(i + 1)))
        }
    }

    /// One 1x1 instance per Bresenham step. The pixel itself is the box, so
    /// coverage is trivially true; the drawing-area clip and the mask still run
    /// in the shader's putPixel tail, exactly as `drawLine` calls `putPixel`.
    private func encodeLine(_ cmd: Ps1GpuCommand) {
        let shaded = cmd.commandKind == PS1_GPU_DRAW_SHADED_LINE
        let v = withUnsafeBytes(of: cmd.v) { raw -> [Ps1GpuVertex] in
            let p = raw.bindMemory(to: Ps1GpuVertex.self)
            return [p[0], p[1]]
        }
        let ox = env.offsetX, oy = env.offsetY
        guard let walk = LineExpander.walk(x0: Int(v[0].x) + ox, y0: Int(v[0].y) + oy,
                                           x1: Int(v[1].x) + ox, y1: Int(v[1].y) + oy)
        else { return }

        var proto = PrimBuilder.base(env)
        proto.kind = Int32(shaded ? PS1_PRIM_SHADED_LINE_PIXEL : PS1_PRIM_LINE_PIXEL)
        proto.color = cmd.value & 0xFFFF
        proto.c0 = v[0].color
        proto.c1 = v[1].color
        proto.steps = Int32(walk.total)
        if cmd.transparent != 0 { proto.flags |= PS1_PRIM_TRANSPARENT }
        // A mono line never dithers; drawLine has no dither branch.
        if !shaded { proto.flags &= ~PS1_PRIM_DITHER }

        for step in walk.steps {
            // Outside VRAM the software path's putPixel returns immediately, so
            // skipping the instance is equivalent and saves the box clamp.
            guard step.x >= 0, step.x < MetalVram.width,
                  step.y >= 0, step.y < MetalVram.height else { continue }
            var inst = proto
            (inst.box_x0, inst.box_x1) = (Int32(step.x), Int32(step.x))
            (inst.box_y0, inst.box_y1) = (Int32(step.y), Int32(step.y))
            (inst.x0, inst.y0) = (Int32(step.x), Int32(step.y))
            inst.k = Int32(step.k)
            appendPrim(inst)
        }
    }

    private func maskFlags() -> UInt32 {
        (env.maskSet ? PS1_PRIM_SET_MASK : 0) | (env.maskCheck ? PS1_PRIM_CHECK_MASK : 0)
    }

    /// Clamps an inclusive box to VRAM. Returns nil when nothing is left, which
    /// is the encoder's equivalent of the software path's `continue`.
    private func clampBox(x0: Int, y0: Int, x1: Int, y1: Int) -> (Int, Int, Int, Int)? {
        let cx0 = max(x0, 0), cy0 = max(y0, 0)
        let cx1 = min(x1, MetalVram.width - 1), cy1 = min(y1, MetalVram.height - 1)
        guard cx0 <= cx1, cy0 <= cy1 else { return nil }
        return (cx0, cy0, cx1, cy1)
    }

    /// A wrapping run on one axis, as at most two non-wrapping ranges.
    private func wrapRanges(origin: Int, extent: Int, axis: Int) -> [(Int, Int)] {
        if extent >= axis { return [(0, axis - 1)] }
        let o = ((origin % axis) + axis) % axis
        if o + extent <= axis { return [(o, o + extent - 1)] }
        return [(o, axis - 1), (0, o + extent - axis - 1)]
    }

    private func encodeFill(_ cmd: Ps1GpuCommand) {
        let x = Int(cmd.x), y = Int(cmd.y), w = Int(cmd.w), h = Int(cmd.h)
        guard w > 0, h > 0,
              let box = clampBox(x0: x, y0: y, x1: x + w - 1, y1: y + h - 1) else { return }
        var inst = Ps1PrimInstance()
        inst.kind = Int32(PS1_PRIM_FILL)
        (inst.box_x0, inst.box_y0, inst.box_x1, inst.box_y1) =
            (Int32(box.0), Int32(box.1), Int32(box.2), Int32(box.3))
        inst.color = cmd.value & 0xFFFF
        let first = instances.count
        instances.append(inst)
        breakPass()
        steps.append(.draw(kind: .fill, range: first..<instances.count))
        breakPass()
    }

    private func encodeCopy(_ cmd: Ps1GpuCommand) {
        let w = VramTransfer.axisExtent(Int(cmd.w), MetalVram.width)
        let h = VramTransfer.axisExtent(Int(cmd.h), MetalVram.height)
        guard w > 0, h > 0 else { return }

        var base = Ps1PrimInstance()
        base.kind = Int32(PS1_PRIM_COPY)
        base.x0 = Int32(Int(cmd.x2) & 0x3FF)
        base.y0 = Int32(Int(cmd.y2) & 0x1FF)
        base.src_x = Int32(Int(cmd.x) & 0x3FF)
        base.src_y = Int32(Int(cmd.y) & 0x1FF)
        base.w = Int32(w)
        base.h = Int32(h)
        base.flags = maskFlags()

        let first = instances.count
        for (bx0, bx1) in wrapRanges(origin: Int(base.x0), extent: w, axis: MetalVram.width) {
            for (by0, by1) in wrapRanges(origin: Int(base.y0), extent: h, axis: MetalVram.height) {
                var inst = base
                (inst.box_x0, inst.box_x1) = (Int32(bx0), Int32(bx1))
                (inst.box_y0, inst.box_y1) = (Int32(by0), Int32(by1))
                instances.append(inst)
            }
        }
        breakPass()
        steps.append(.snapshot)
        steps.append(.draw(kind: .copy, range: first..<instances.count))
        breakPass()
    }

    private func encodeUpload(_ cmd: Ps1GpuCommand) {
        // Mirrors ShadowVram.apply's PS1_GPU_VRAM_WRITE_DATA arm: FixtureFile
        // validates a FRAME's payload slice against the file totals but never
        // a RECORD's offsets within it, so a malformed off/len pair reaches
        // both consumers unchecked. The shadow's guard makes that a no-op;
        // without the same guard here, word_base + (pix >> 1) in
        // ps1_upload_fragment would index past payloadBuffer's real
        // allocation — an out-of-bounds device-buffer read, not merely a
        // wrong pixel.
        let off = Int(cmd.x), len = Int(cmd.y)
        guard off >= 0, len >= 0, off + len <= payloadCount else { return }
        var wordCursor = off
        var remaining = len
        let first = instances.count
        while remaining > 0, transfer.active, let run = transfer.plan(words: remaining) {
            appendUploadInstance(bufferWordOffset: wordCursor, run: run)
            wordCursor += run.consumed
            remaining -= run.consumed
        }
        guard instances.count > first else { return }
        breakPass()
        steps.append(.draw(kind: .upload, range: first..<instances.count))
        breakPass()
    }

    private func appendUploadInstance(bufferWordOffset: Int,
                                      run: (first: Int, last: Int, consumed: Int)) {
        let w = transfer.w
        let rowFirst = run.first / w, rowLast = run.last / w
        guard let box = clampBox(x0: transfer.x, y0: transfer.y + rowFirst,
                                 x1: transfer.x + w - 1, y1: transfer.y + rowLast) else { return }
        var inst = Ps1PrimInstance()
        inst.kind = Int32(PS1_PRIM_UPLOAD)
        (inst.box_x0, inst.box_y0, inst.box_x1, inst.box_y1) =
            (Int32(box.0), Int32(box.1), Int32(box.2), Int32(box.3))
        inst.x0 = Int32(transfer.x)
        inst.y0 = Int32(transfer.y)
        inst.w = Int32(w)
        inst.h = Int32(transfer.h)
        // A run always starts on an EVEN pixel index, so this bias is exact.
        inst.word_base = Int32(bufferWordOffset - run.first / 2)
        inst.pixel_first = Int32(run.first)
        inst.pixel_last = Int32(run.last)
        inst.flags = maskFlags()
        instances.append(inst)
    }
}
