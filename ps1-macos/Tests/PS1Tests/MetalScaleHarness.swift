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
    static func frame(scale: Int, payload: [UInt32] = [], preload: [UInt16]? = nil,
                      ditherDisabled: Bool = true,
                      _ body: (MetalRasterizer) -> Void) throws -> Frame? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let vram = MetalVram(device: device, queue: queue, scale: scale) else { return nil }
        // A NATIVE image, replicated N x N — the state a 1x replay would have
        // reached, expressed at this scale. Uploading it any other way would
        // seed a difference the comparison would then attribute to the shader.
        if let preload { vram.uploadNative(preload) }
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

    /// One fixture frame, replayed from a BLANK VRAM.
    ///
    /// Not equivalent to the cumulative replay `compare` runs — a frame that
    /// depends on an earlier frame's VRAM or drawing environment will differ.
    /// It is used only on frames that open with their own E3/E4/E5 and sample
    /// nothing, which is what lets Gate 2b index into the middle of a fixture
    /// without dragging the upload frames along.
    static func fixtureFrame(_ name: String, frame i: Int, scale: Int) throws -> Frame? {
        let file = try FixtureFile(contentsOf: FixtureFile.url(named: name))
        return try withExtendedLifetime(file) {
            let payload = Array(file.payload(for: i))
            return try frame(scale: scale, payload: payload) { r in
                for cmd in file.records(for: i) { r.apply(cmd) }
            }
        }
    }

    struct Divergence {
        let frame: Int
        let message: String
    }

    /// Gate 2. The same fixture replayed cumulatively at 1x and at `scale`,
    /// dithering forced off on both sides, compared per frame on the NATIVE
    /// view. Returns the first frame that disagrees, or nil if every frame
    /// agreed — or if there is no Metal device.
    ///
    /// The reference side is the backend's own 1x output, NOT the fixture's
    /// Zig hash: that comparison is Gate 1's job and it runs with dithering
    /// on, where it belongs.
    static func compare(_ name: String, scale: Int, upTo: Int? = nil) throws -> Divergence? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let oneVram = MetalVram(device: device, queue: queue, scale: 1),
              let manyVram = MetalVram(device: device, queue: queue, scale: scale)
        else { return nil }
        let one = try MetalRasterizer(vram: oneVram)
        let many = try MetalRasterizer(vram: manyVram)
        one.ditherDisabled = true
        many.ditherDisabled = true

        let file = try FixtureFile(contentsOf: FixtureFile.url(named: name))
        let count = min(upTo ?? file.frames.count, file.frames.count)
        var out: Divergence?
        withExtendedLifetime(file) {
            for i in 0..<count {
                let payload = file.payload(for: i)
                for r in [one, many] {
                    r.beginFrame(payload: payload)
                    for cmd in file.records(for: i) { r.apply(cmd) }
                    r.endFrame()
                }
                guard oneVram.hash != manyVram.nativeHash else { continue }
                let want = oneVram.readback()
                let got = manyVram.readbackNative()
                let diffs = VramDump.firstDifferences(want, got, limit: 6)
                let total = zip(want, got).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
                let lines = diffs.map {
                    String(format: "  (%4d,%4d) 1x %04X %dx %04X", $0.x, $0.y, $0.want, scale, $0.got)
                }
                out = Divergence(frame: i,
                                 message: "frame \(i): \(total) native px differ\n"
                                     + lines.joined(separator: "\n"))
                return
            }
        }
        return out
    }

    /// Cumulative replay through `frame`, returning that frame's result.
    ///
    /// Dithering defaults to SHIPPING behaviour here, not to off: Gate 3 is
    /// about how the picture looks, and at 1x that includes the dither
    /// pattern. Gate 2's comparisons pass `ditherDisabled: true` instead.
    static func replayTo(_ name: String, frame last: Int, scale: Int,
                         ditherDisabled: Bool = false) throws -> Frame? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let vram = MetalVram(device: device, queue: queue, scale: scale) else { return nil }
        let r = try MetalRasterizer(vram: vram)
        r.ditherDisabled = ditherDisabled

        let file = try FixtureFile(contentsOf: FixtureFile.url(named: name))
        var instances: [Ps1PrimInstance] = []
        withExtendedLifetime(file) {
            for i in 0...min(last, file.frames.count - 1) {
                r.beginFrame(payload: file.payload(for: i))
                for cmd in file.records(for: i) { r.apply(cmd) }
                instances = r.instances
                r.endFrame()
            }
        }
        return Frame(scaled: vram.readback(), native: vram.readbackNative(),
                     instances: instances, width: vram.width, height: vram.height,
                     scale: scale)
    }
}
