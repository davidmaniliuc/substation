import SwiftUI
import MetalKit

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
        /// Mirrors `Params` in DisplayShader.source. Field order and types must
        /// match exactly.
        private struct Params {
            var vramX: UInt32 = 0
            var vramY: UInt32 = 0
            var width: UInt32 = 0
            var height: UInt32 = 0
            var depth24: UInt32 = 0
            var enabled: UInt32 = 0
            var scaleX: Float = 1
            var scaleY: Float = 1
        }

        let device: MTLDevice
        private let queue: MTLCommandQueue
        private let pipeline: MTLRenderPipelineState
        private let texture: MTLTexture
        private let runner: EmulatorRunner

        init(runner: EmulatorRunner) {
            guard let device = MTLCreateSystemDefaultDevice() else {
                fatalError("No Metal device")
            }
            guard let queue = device.makeCommandQueue() else {
                fatalError("No Metal command queue")
            }

            // Compiled here, at runtime — see DisplayShader for why.
            let library: MTLLibrary
            do {
                library = try device.makeLibrary(source: DisplayShader.source, options: nil)
            } catch {
                fatalError("Display shader failed to compile: \(error)")
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

            self.device = device
            self.queue = queue
            self.pipeline = pipeline
            self.texture = texture
            self.runner = runner
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let pass = view.currentRenderPassDescriptor,
                  let cmd = queue.makeCommandBuffer() else { return }

            var params = Params()

            runner.withNewestFrame { vram, display in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, 1024, 512),
                    mipmapLevel: 0,
                    withBytes: vram,
                    bytesPerRow: 1024 * MemoryLayout<UInt16>.size
                )
                params.vramX = display.vram_x
                params.vramY = display.vram_y
                params.width = display.width
                params.height = display.height
                params.depth24 = UInt32(display.depth24)
                params.enabled = UInt32(display.enabled)
            }

            // The PS1 output is 4:3 whatever the pixel resolution is, so aspect
            // correction is a property of the display, not of `width/height`.
            let target: Float = 4.0 / 3.0
            let size = view.drawableSize
            if size.height > 0 {
                let viewAspect = Float(size.width / size.height)
                if viewAspect > target {
                    params.scaleX = target / viewAspect
                    params.scaleY = 1
                } else {
                    params.scaleX = 1
                    params.scaleY = viewAspect / target
                }
            }

            guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(texture, index: 0)
            enc.setVertexBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
            enc.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()

            cmd.present(drawable)
            cmd.commit()
        }
    }
}
