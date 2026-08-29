import Foundation
import Metal
import CPs1
@testable import PS1

/// Phase C's replay helpers. Separate from `MetalFixtureHarness`, which
/// compares one rasterizer against a fixture's own Zig-produced hash; these
/// compare the backend against ITSELF at two internal resolutions, which is a
/// different question and needs both views of the result.
///
/// Every entry point returns nil rather than failing when there is no Metal
/// device, for the reason `MetalFixtureHarness` already documents: a headless
/// runner would otherwise turn the whole suite red for no signal.
enum MetalScaleHarness {
    struct Frame {
        let scaled: [UInt16]
        let native: [UInt16]
        /// The instances the encoder built, snapshotted BEFORE `endFrame`
        /// clears them. Gate 2b reads the boxes back out of these.
        let instances: [Ps1PrimInstance]
        let width: Int
        let height: Int
        let scale: Int
    }

    /// One frame, from a blank VRAM, at `scale`.
    ///
    /// Dithering is off by default: it is the single exception to exactness,
    /// and every caller here is checking exactness. Gate 1 is what checks the
    /// dithered 1x output, per frame, per fixture.
    static func frame(scale: Int, payload: [UInt32] = [], ditherDisabled: Bool = true,
                      _ body: (MetalRasterizer) -> Void) throws -> Frame? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let vram = MetalVram(device: device, queue: queue, scale: scale) else { return nil }
        let r = try MetalRasterizer(vram: vram)
        r.ditherDisabled = ditherDisabled

        var instances: [Ps1PrimInstance] = []
        payload.withUnsafeBufferPointer { buf in
            r.beginFrame(payload: buf)
            body(r)
            instances = r.instances
            r.endFrame()
        }
        return Frame(scaled: vram.readback(), native: vram.readbackNative(),
                     instances: instances, width: vram.width, height: vram.height,
                     scale: scale)
    }
}
