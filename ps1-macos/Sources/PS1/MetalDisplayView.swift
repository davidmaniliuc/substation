import SwiftUI
import MetalKit

/// Multipliers that fit a 4:3 picture inside a drawable of `width` x `height`.
///
/// The PS1 output is 4:3 whatever the pixel resolution is, so aspect correction
/// is a property of the display, not of the framebuffer's `width/height`.
///
/// Exactly `(1, 1)` when the drawable is already 4:3, and SNAPPED there rather
/// than computed: the window is aspect-locked (see `WindowConfigurator`) so the
/// ratio lands a hair off 1.0, and a scale of 0.99999 blacks out the outermost
/// pixel column for nothing. A zero-sized drawable also returns `(1, 1)`:
/// the shader divides by these, so 0 would hand it a NaN uv.
func letterboxScale(width: Double, height: Double) -> (x: Float, y: Float) {
    guard width > 0, height > 0 else { return (1, 1) }
    let target = 4.0 / 3.0
    let viewAspect = width / height
    // Total bar width in device pixels is height * |viewAspect - target|.
    if height * abs(viewAspect - target) < 0.5 { return (1, 1) }
    return viewAspect > target
        ? (Float(target / viewAspect), 1)
        : (1, Float(viewAspect / target))
}

/// Mirrors `Params` in Shaders/DisplayShader.metal. Field order and types must match
/// exactly. File scope rather than nested in `Coordinator` so the offscreen
/// render test can feed the real struct to the real shader.
///
/// Both sides are 4-byte aligned throughout, so this is 44 bytes with no
/// padding question: pinned by `static_assert` over there and by
/// `theDisplayParamsStrideMatchesTheShaderStruct` here.
struct DisplayParams {
    var vramX: UInt32 = 0
    var vramY: UInt32 = 0
    var width: UInt32 = 0
    var height: UInt32 = 0
    var depth24: UInt32 = 0
    var enabled: UInt32 = 0
    var scaleX: Float = 1
    var scaleY: Float = 1
    var softwareDisplay: UInt32 = 0
    /// Internal resolution, 1...8. Defaults to 1 and never 0: the fragment
    /// shader divides by it.
    var scale: UInt32 = 1
    /// 1 draws the picture as is; the paused game eases toward 0.6.
    var saturation: Float = 1
}

/// The paused picture's grey-out: an ease-in-out over `duration` toward
/// `pausedSaturation`, driven by the draw loop's own clock.
struct PauseFade {
    static let pausedSaturation: Float = 0.6
    static let duration = 0.25

    /// 0 in play, 1 fully paused, before easing.
    private(set) var progress = 0.0
    private var last: Double?

    mutating func saturation(paused: Bool, at now: Double) -> Float {
        let step = last.map { min(now - $0, Self.duration) / Self.duration } ?? 1
        last = now
        progress = paused ? min(progress + step, 1) : max(progress - step, 0)
        let eased = progress * progress * (3 - 2 * progress)
        return 1 - Float(eased) * (1 - Self.pausedSaturation)
    }
}

struct MetalDisplayView: NSViewRepresentable {
    let runner: EmulatorRunner
    /// Internal resolution, 1...8. `ContentView` keys `.id()` on this as well
    /// as on the runner, so a change rebuilds the coordinator rather than
    /// reconfiguring it: see `Coordinator.init`.
    let scale: Int
    /// Whether the PGXP depth plane persists, the EFFECTIVE value
    /// (`EmulatorViewModel.pgxpEffectiveDepthBuffer`); it decides whether `MetalVram`
    /// allocates a `.private` or `.memoryless` depth texture, so like `scale`
    /// it is part of `ContentView`'s `.id()` rather than an ordinary update.
    let depthBuffer: Bool
    /// Where the dither pattern is sampled. NOT part of `ContentView`'s
    /// `.id()`, unlike `scale`: it is a runtime uniform on a pipeline that is
    /// already built, so it rides the ordinary update path instead of
    /// rebuilding the coordinator.
    let ditherMode: DitherMode
    /// How 3D textured primitives sample. Like `ditherMode`, NOT part of the `.id()`.
    let textureFilter: TextureFilter
    /// How sprites sample. Like `ditherMode`, NOT part of the `.id()`.
    let spriteFilter: TextureFilter

    func makeCoordinator() -> Coordinator {
        Coordinator(runner: runner, scale: scale, ditherMode: ditherMode,
                    textureFilter: textureFilter, spriteFilter: spriteFilter,
                    depthBuffer: depthBuffer)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        // Black, not clear: the game view gets no glass effect, so there is
        // nothing to refract through it.
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.live.ditherMode = ditherMode
        context.coordinator.live.textureFilter = textureFilter
        context.coordinator.live.spriteFilter = spriteFilter
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice
        private let queue: MTLCommandQueue
        private let pipeline: MTLRenderPipelineState
        private let shadowTexture: MTLTexture
        private let runner: EmulatorRunner
        /// The live Metal renderer. Internal rather than private: tests need
        /// to see which scale it was built at (`liveForTesting` used to
        /// re-expose the same class reference under a second name, which
        /// enforced nothing `LiveRenderer` being a reference type didn't
        /// already allow).
        let live: LiveRenderer
        /// PS1_SOFTWARE_DISPLAY=1 routes 15bpp back to the shadow, so a
        /// suspect frame can be A/B'd against the software rasterizer without
        /// a rebuild. An environment variable is fine HERE: the standing
        /// warning in CLAUDE.md is about the hosted TEST process, which sees
        /// neither an exported variable nor xcodebuild's TEST_RUNNER_ prefix.
        private let softwareDisplay =
            ProcessInfo.processInfo.environment["PS1_SOFTWARE_DISPLAY"] == "1"

        /// A scale change rebuilds `MetalVram` and therefore the render
        /// texture, so this whole object is rebuilt with it: the same path a
        /// disc change already takes. Rebuilding pipelines for a rare,
        /// user-initiated event is fine; a second bespoke reconfiguration path
        /// is not. `depthBuffer` rebuilds for the same reason: it decides
        /// whether `MetalVram`'s depth texture persists or is memoryless.
        init(runner: EmulatorRunner, scale: Int, ditherMode: DitherMode,
             textureFilter: TextureFilter = TextureFilterSetting.defaultFilter,
             spriteFilter: TextureFilter = SpriteFilterSetting.defaultFilter,
             depthBuffer: Bool = false) {
            guard let device = MTLCreateSystemDefaultDevice() else {
                fatalError("No Metal device")
            }
            guard let queue = device.makeCommandQueue() else {
                fatalError("No Metal command queue")
            }

            let library: MTLLibrary
            do {
                library = try Shaders.makeLibrary(device)
            } catch {
                fatalError("Display shader library failed to load: \(error)")
            }

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "display_vertex")
            desc.fragmentFunction = library.makeFunction(name: "display_fragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else {
                fatalError("Display pipeline failed to build")
            }

            let texDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r16Uint, width: 1024, height: 512, mipmapped: false)
            texDesc.usage = .shaderRead
            texDesc.storageMode = .managed
            guard let texture = device.makeTexture(descriptor: texDesc) else {
                fatalError("VRAM texture allocation failed")
            }

            let live: LiveRenderer
            do {
                live = try LiveRenderer(device: device, queue: queue, scale: scale,
                                        depthBuffer: depthBuffer)
            } catch {
                fatalError("Live renderer failed to build: \(error)")
            }
            self.live = live
            // Set here as well as in `updateNSView`, so the first frame this
            // coordinator draws already carries the setting rather than the
            // rasterizer's own default.
            live.ditherMode = ditherMode
            live.textureFilter = textureFilter
            live.spriteFilter = spriteFilter

            self.device = device
            self.queue = queue
            self.pipeline = pipeline
            self.shadowTexture = texture
            self.runner = runner

            // A fresh MetalVram is a BLANK texture, and a command stream is a
            // set of incremental mutations: applying the next queued stream
            // to it leaves the picture permanently wrong with no symptom that
            // names its cause. `StreamQueue.resync` defaults true, which
            // covers a FRESH queue; a scale change keeps the runner and
            // therefore keeps its queue, so the default does not fire. Doing
            // it here rather than at the call site makes it unmissable, and on
            // the disc-change path it is a no-op against a flag already set.
            // CLAIMING rather than merely requesting is what makes the request
            // this coordinator's own: the coordinator it replaces can still
            // get a draw callback, and must not consume it.
            consumer = runner.streams.claimConsumer()
        }

        /// The grey-out a pause eases in and out of, read off the runner's
        /// atomic every draw: the view redraws at 60 Hz paused or not.
        private var pauseFade = PauseFade()

        /// This coordinator's claim on the runner's stream queue.
        private let consumer: UInt64

        /// False once a rebuild has built a newer coordinator on the same
        /// runner. A superseded coordinator draws nothing, because draining
        /// would take streams (and the resync) away from the texture on screen.
        var ownsStream: Bool { runner.streams.isConsumer(consumer) }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard ownsStream,
                  let drawable = view.currentDrawable,
                  let pass = view.currentRenderPassDescriptor,
                  let cmd = queue.makeCommandBuffer() else { return }

            var params = DisplayParams()
            params.softwareDisplay = softwareDisplay ? 1 : 0
            // Read off the renderer, not off a second stored copy: the uniform
            // and the texture it addresses cannot drift apart.
            params.scale = UInt32(live.vram.scale)
            params.saturation = pauseFade.saturation(paused: runner.isPaused,
                                                     at: CACurrentMediaTime())

            // Drain-all, present-newest. Every queued stream is EXECUTED, in
            // order; only the presentation is allowed to skip, which is what
            // keeps 59.94-against-60 and 120 Hz ProMotion as invisible as they
            // are on the shadow path.
            live.drain(from: runner.streams) {
                var out = [UInt16](repeating: 0, count: EmulatorRunner.vramCount)
                var depthOut: [UInt32]?
                var seq: UInt64 = 0
                self.runner.withNewestFrame { vram, _, s, depthPtr in
                    seq = s
                    out.withUnsafeMutableBufferPointer { dst in
                        dst.baseAddress!.update(from: vram, count: EmulatorRunner.vramCount)
                    }
                    if let depthPtr {
                        depthOut = Array(UnsafeBufferPointer(
                            start: depthPtr, count: EmulatorRunner.vramCount))
                    }
                }
                return (out, depthOut, seq)
            }

            runner.withNewestFrame { vram, shadowDisplay, _, _ in
                // A runahead picture is shown where its own frame displays,
                // unless either is 24-bit: that is read from the shadow, and
                // a speculative frame publishes none.
                var display = shadowDisplay
                if let ahead = self.live.presentDisplay, ahead.depth24 == 0, shadowDisplay.depth24 == 0 {
                    display = ahead
                }
                params.vramX = display.vram_x
                params.vramY = display.vram_y
                params.width = display.width
                params.height = display.height
                params.depth24 = UInt32(display.depth24)
                params.enabled = UInt32(display.enabled)
                // Only the two paths that READ it pay the 1 MB upload.
                if display.depth24 != 0 || self.softwareDisplay {
                    self.shadowTexture.replace(
                        region: MTLRegionMake2D(0, 0, 1024, 512),
                        mipmapLevel: 0,
                        withBytes: vram,
                        bytesPerRow: 1024 * MemoryLayout<UInt16>.size)
                }
            }

            if live.diffEnabled {
                runner.withNewestFrame { vram, _, seq, _ in
                    let report = self.live.diff(seq: seq) {
                        [UInt16](UnsafeBufferPointer(
                            start: vram, count: EmulatorRunner.vramCount))
                    }
                    if let report { print(report) }
                }
            }

            let size = view.drawableSize
            (params.scaleX, params.scaleY) = letterboxScale(
                width: size.width, height: size.height)

            guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
            enc.setRenderPipelineState(pipeline)
            // ALL THREE bindings, always: an unbound texture2d is a Metal
            // validation failure, not a black pixel.
            enc.setFragmentTexture(live.texture, index: 0)
            enc.setFragmentTexture(shadowTexture, index: 1)
            enc.setFragmentTexture(live.sidecarTexture, index: 2)
            enc.setVertexBytes(&params, length: MemoryLayout<DisplayParams>.stride, index: 0)
            enc.setFragmentBytes(&params, length: MemoryLayout<DisplayParams>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()

            encodeScreenshots(into: cmd, params: params)
            cmd.present(drawable)
            cmd.commit()
        }

        /// Draws this frame once more, unletterboxed at the internal
        /// resolution, for every screenshot the model asked for, and answers
        /// them when the GPU is done with it.
        private func encodeScreenshots(into cmd: MTLCommandBuffer, params: DisplayParams) {
            let requests = runner.takeScreenshotRequests()
            guard !requests.isEmpty else { return }
            let size = Screenshot.size(displayHeight: Int(params.height), scale: Int(params.scale),
                                       enabled: params.enabled != 0)
            guard let target = Screenshot.encode(
                into: cmd, pipeline: pipeline, vram: live.texture, shadow: shadowTexture,
                sidecar: live.sidecarTexture, params: params, size: size)
            else {
                for answer in requests { answer(nil) }
                return
            }
            let shot = PendingScreenshot(target: target)
            cmd.addCompletedHandler { _ in
                let png = shot.png()
                for answer in requests { answer(png) }
            }
        }
    }
}

/// The texture a screenshot pass draws into, carried to the command buffer's
/// completed handler. Unchecked because nothing else holds it: the GPU is
/// done with it by the time the handler reads it.
private final class PendingScreenshot: @unchecked Sendable {
    let target: MTLTexture
    init(target: MTLTexture) { self.target = target }

    func png() -> Data? {
        let bgra = Screenshot.bytes(of: target)
        return bgra.withUnsafeBytes {
            Screenshot.png(bgra: $0, width: target.width, height: target.height,
                           bytesPerRow: target.width * 4)
        }
    }
}
