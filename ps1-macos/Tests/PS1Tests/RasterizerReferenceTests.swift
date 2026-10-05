import Testing
import Metal
import Foundation
import CPs1
@testable import PS1

/// Replays a fixture through two rasterizers in lockstep (one with
/// `reference` set, one optimised) and compares the FULL scaled VRAM and
/// sidecar, not `readbackNative()`: the corner-only view is the scaled
/// path's known blind spot, and an optimisation that drops interior
/// subtexels passes it.
enum ReferenceLockstep {
    static func compare(_ fixture: String, scale: Int, dither: DitherMode = .trueColor,
                        filter: TextureFilter = .bilinear, spriteFilter: TextureFilter = .bilinear,
                        depthBuffer: Bool = false, reference: RasterizerReference,
                        every: Int = 1) throws -> String? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let va = MetalVram(device: device, queue: queue, scale: scale, depthBuffer: depthBuffer),
              let vb = MetalVram(device: device, queue: queue, scale: scale, depthBuffer: depthBuffer)
        else { return nil }
        let a = try MetalRasterizer(vram: va, reference: reference)
        let b = try MetalRasterizer(vram: vb)
        for r in [a, b] {
            r.ditherMode = dither
            r.textureFilter = filter
            r.spriteFilter = spriteFilter
        }
        let file = try FixtureFile(contentsOf: FixtureFile.url(named: fixture))
        return withExtendedLifetime(file) {
            let last = file.frames.count - 1
            for i in 0...last {
                for r in [a, b] {
                    r.beginFrame(payload: file.payload(for: i))
                    for cmd in file.records(for: i) { r.apply(cmd) }
                    r.endFrame()
                }
                guard i % every == 0 || i == last else { continue }
                if va.readback() != vb.readback() {
                    return "\(fixture) @\(scale)x frame \(i): VRAM differs"
                }
                if va.readbackSidecar() != vb.readbackSidecar() {
                    return "\(fixture) @\(scale)x frame \(i): sidecar differs"
                }
            }
            return nil
        }
    }

    /// Every fixture present, committed or generated.
    static var corpus: [String] {
        ["synthetic-primitives", "synthetic-movers", "pl-render-polygon", "pl-render-rectangle",
         "pl-render-line", "pl-render-texture-polygon", "croc-legend-of-the-gobbos",
         "silent-hill-usa", "tr1-usa-v1-1", "tr1-usa-v1-1-pgxp", "crash-bandicoot-warped"]
            .filter(generatedFixtureExists)
    }

    /// The scale ladder: 3 and 6 because `/ s` and `% s` are shifts at every
    /// power of two, so a bug there is invisible at 2, 4 and 8.
    static let scales = [1, 2, 3, 4, 6]
}
