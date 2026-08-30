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
/// pixel column for nothing. A zero-sized drawable also returns `(1, 1)` —
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
}

struct MetalDisplayView: NSViewRepresentable {
    let runner: EmulatorRunner

    func makeCoordinator() -> Coordinator { Coordinator(runner: runner) }

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

    func updateNSView(_ nsView: MTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice
        private let queue: MTLCommandQueue
        private let pipeline: MTLRenderPipelineState
        private let shadowTexture: MTLTexture
        private let runner: EmulatorRunner
        private let live: LiveRenderer
        /// PS1_SOFTWARE_DISPLAY=1 routes 15bpp back to the shadow, so a
        /// suspect frame can be A/B'd against the software rasterizer without
        /// a rebuild. An environment variable is fine HERE — the standing
        /// warning in CLAUDE.md is about the hosted TEST process, which sees
        /// neither an exported variable nor xcodebuild's TEST_RUNNER_ prefix.
        private let softwareDisplay =
            ProcessInfo.processInfo.environment["PS1_SOFTWARE_DISPLAY"] == "1"

        init(runner: EmulatorRunner) {
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
                live = try LiveRenderer(device: device, queue: queue)
            } catch {
                fatalError("Live renderer failed to build: \(error)")
            }
            self.live = live

            self.device = device
            self.queue = queue
            self.pipeline = pipeline
            self.shadowTexture = texture
            self.runner = runner
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let pass = view.currentRenderPassDescriptor,
                  let cmd = queue.makeCommandBuffer() else { return }

            var params = DisplayParams()
            params.softwareDisplay = softwareDisplay ? 1 : 0

            // Drain-all, present-newest. Every queued stream is EXECUTED, in
            // order; only the presentation is allowed to skip, which is what
            // keeps 59.94-against-60 and 120 Hz ProMotion as invisible as they
            // are on the shadow path.
            live.drain(from: runner.streams) {
                var out = [UInt16](repeating: 0, count: EmulatorRunner.vramCount)
                self.runner.withNewestFrame { vram, _, _ in
                    out.withUnsafeMutableBufferPointer { dst in
                        dst.baseAddress!.update(from: vram, count: EmulatorRunner.vramCount)
                    }
                }
                return out
            }

            runner.withNewestFrame { vram, display, _ in
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
                runner.withNewestFrame { vram, _, seq in
                    let shadow = [UInt16](UnsafeBufferPointer(
                        start: vram, count: EmulatorRunner.vramCount))
                    if let report = self.live.diff(against: shadow, seq: seq) {
                        print(report)
                    }
                }
            }

            let size = view.drawableSize
            (params.scaleX, params.scaleY) = letterboxScale(
                width: size.width, height: size.height)

            guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
            enc.setRenderPipelineState(pipeline)
            // BOTH bindings, always: an unbound texture2d is a Metal
            // validation failure, not a black pixel.
            enc.setFragmentTexture(live.texture, index: 0)
            enc.setFragmentTexture(shadowTexture, index: 1)
            enc.setVertexBytes(&params, length: MemoryLayout<DisplayParams>.stride, index: 0)
            enc.setFragmentBytes(&params, length: MemoryLayout<DisplayParams>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()

            cmd.present(drawable)
            cmd.commit()
        }
    }
}
