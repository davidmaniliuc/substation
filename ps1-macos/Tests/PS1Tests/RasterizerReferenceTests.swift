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

/// Trimmed to fit the suite. Measured in a Debug host on an M1, one lockstep
/// over the whole corpus costs ~29 s at 1x, ~170 s at 3x and ~300 s at 4x
/// comparing every frame, so the brief's 5 settings x {1, 3, 4} plus depth
/// came to ~2500 s. Two cuts, in the order the plan allows:
/// - every 10th frame (and the last) is compared; every frame is still
///   REPLAYED, so a divergence persists in VRAM until a compared frame unless
///   a later draw paints over it;
/// - 4x only for the first setting and the depth run: the variant split does
///   not depend on the scale, and 3x already covers the non-power-of-two path.
/// Every setting, scale 3 for every setting, the depth run and the full corpus
/// are kept. Measured runtime: 299 s in a Debug host on an M1 (2026-10-05).
@Test func theSpecialisedVariantsPaintExactlyWhatTheUberShaderPainted() throws {
    let settings: [(DitherMode, TextureFilter, TextureFilter)] = [
        (.trueColor, .bilinear, .bilinear), (.trueColor, .nearest, .nearest),
        (.native, .bilinear, .nearest), (.scaled, .nearest, .bilinear), (.off, .nearest, .nearest),
    ]
    for fixture in ReferenceLockstep.corpus {
        for (n, (dither, filter, sprite)) in settings.enumerated() {
            for scale in n == 0 ? [1, 3, 4] : [1, 3] {
                let msg = try ReferenceLockstep.compare(fixture, scale: scale, dither: dither,
                                                       filter: filter, spriteFilter: sprite,
                                                       reference: .uberShader, every: 10)
                #expect(msg == nil, Comment(rawValue: "\(dither)/\(filter)/\(sprite): \(msg ?? "")"))
            }
        }
        // The depth plane forces the destination read on every variant.
        let msg = try ReferenceLockstep.compare(fixture, scale: 4, depthBuffer: true,
                                               reference: .uberShader, every: 10)
        #expect(msg == nil, Comment(rawValue: "depth on: \(msg ?? "")"))
    }
}

@Test func everyVariantIsBuiltAtInit() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue, scale: 1) else { return }
    let t0 = DispatchTime.now().uptimeNanoseconds
    let r = try MetalRasterizer(vram: vram)
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    // 7 classes x true colour on/off x destination read on/off. Built up
    // front so the first use of a variant mid-game is not a compile hitch.
    #expect(r.variantPipelineCount == 28)
    print("[variants] MetalRasterizer.init built \(r.variantPipelineCount) pipelines in \(String(format: "%.0f", ms)) ms")
}



/// The one destination read no flag announces: while the depth plane
/// persists, a draw that does not write its own depth writes the STORED depth
/// back, so it must take the reading variant even when it is opaque, unmasked
/// and untested. The corpus cannot see this (the depth-on run passes with the
/// `depthPersists` term deleted), so it is pinned here: an untested opaque
/// triangle between a near depth-written one and a far depth-tested one must
/// leave the near depth in place, and the far triangle must be refused.
@Test func anUntestedDrawKeepsTheStoredDepthWhileThePlanePersists() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
    else { return }
    let xs: [Int16] = [10, 90, 10]
    var plain = Ps1GpuCommand()
    plain.kind = UInt8(PS1_GPU_DRAW_TRIANGLE.rawValue)
    plain.value = 0x03E0                                   // green
    plain.v = (Ps1GpuVertex(x: 10, y: 10, u: 0, v: 0, _pad: 0, color: 0),
               Ps1GpuVertex(x: 90, y: 50, u: 0, v: 0, _pad: 0, color: 0),
               Ps1GpuVertex(x: 10, y: 90, u: 0, v: 0, _pad: 0, color: 0))
    for reference in [RasterizerReference(), .uberShader] {
        guard let vram = MetalVram(device: device, queue: queue, depthBuffer: true) else { return }
        let r = try MetalRasterizer(vram: vram, reference: reference)
        r.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
        r.apply(fullDrawingAreaCommand())
        r.apply(depthTestedTriangle(color: 0x001F, xs: xs, izs: [1000, 1000, 1000]))   // near, red
        r.apply(plain)
        r.apply(depthTestedTriangle(color: 0x7C00, xs: xs, izs: [500, 500, 500]))      // far, blue
        r.endFrame()
        #expect(vram.readback()[50 * 1024 + 20] == 0x03E0, "reference \(reference.rawValue)")
    }
}

