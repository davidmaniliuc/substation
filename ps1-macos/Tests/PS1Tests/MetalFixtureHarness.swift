import Foundation
import Metal
@testable import PS1

/// Drives a `.p1fx` through `MetalRasterizer` frame by frame and compares the
/// GPU VRAM hash against the fixture's own.
///
/// Returns nil rather than failing when there is no Metal device: a headless
/// runner would otherwise turn the whole suite red for no signal.
enum MetalFixtureHarness {
    struct ReplayResult {
        let framesChecked: Int
        let firstDivergence: Int?
        let passCount: Int
        let message: String
    }

    /// `upTo` bounds the replay to the first N frames — the gate ladder in
    /// Tasks 6-10 walks `synthetic-primitives` one frame at a time, because a
    /// hash is cumulative and a later frame's mismatch would otherwise mask an
    /// earlier feature that already works.
    ///
    /// `dither` is PINNED here rather than inherited from
    /// `DitherSetting.defaultMode`, and the default is `.native` rather than
    /// whatever ships. This gate's reference is the software rasterizer, which
    /// dithers whenever GP0(E1) bit 9 is set, so a mode is part of the gate;
    /// `.scaled` is the same expression at 1x and `.trueColor` deliberately is
    /// not. Inheriting the player's setting made the shipped default decide
    /// what every fixture hash was compared against.
    static func replay(_ name: String, upTo: Int? = nil,
                       dither: DitherMode = .native) throws -> ReplayResult? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let vram = MetalVram(device: device, queue: queue) else { return nil }

        let fixture = try FixtureFile(contentsOf: FixtureFile.url(named: name))
        let renderer = try MetalRasterizer(vram: vram)
        renderer.ditherMode = dither
        let count = min(upTo ?? fixture.frames.count, fixture.frames.count)

        var result: ReplayResult?
        withExtendedLifetime(fixture) {
            for i in 0..<count {
                let payload = fixture.payload(for: i)
                renderer.beginFrame(payload: payload)
                for cmd in fixture.records(for: i) { renderer.apply(cmd) }
                renderer.endFrame()

                if vram.hash != fixture.frames[i].vramHash {
                    result = ReplayResult(
                        framesChecked: i + 1,
                        firstDivergence: i,
                        passCount: renderer.passCount,
                        message: VramDump.report(fixture: name, frame: i, got: vram.readback()))
                    return
                }
            }
            result = ReplayResult(framesChecked: count, firstDivergence: nil,
                                  passCount: renderer.passCount,
                                  message: "\(name): \(count) frames, \(renderer.passCount) passes")
        }
        return result
    }
}
