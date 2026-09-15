import Foundation
import Testing
import CPs1
@testable import PS1

/// PGXP-ON PARITY, at STRICT equality — the gate that proves the shared
/// integer perspective path.
///
/// Every other fixture in the corpus was captured with PGXP off, so every `rw`
/// in them is zero and every textured triangle takes the affine branch: the
/// perspective interpolant is entirely uncovered by Gate 1 and Gate 2. This
/// fixture is the same 100-frame Tomb Raider window captured with PGXP on, so
/// its textured triangles carry real reciprocal depths and its per-frame VRAM
/// hashes are the software rasterizer's answer to them.
///
/// It is a STRICT equality rather than a tolerance only because the
/// interpolant is exact: every term is an integer and the division is an
/// integer division, so the two rasterizers evaluate one expression over
/// identical inputs and agree by construction. No float formulation could
/// offer this, and it matters because the comparison is a HASH — under float,
/// one ULP anywhere is a red gate with no diagnostic.
///
/// Skipped rather than failed when the fixture is absent: it needs
/// `zig build fixtures -Doptimize=ReleaseFast` and a `games/` directory.
@Test(.enabled(if: FileManager.default.fileExists(
                    atPath: FixtureFile.url(named: "tr1-usa-v1-1-pgxp").path)),
      .timeLimit(.minutes(5)))
func aPgxpOnCaptureReplaysBitExactlyInMetal() throws {
    guard let r = try MetalFixtureHarness.replay("tr1-usa-v1-1-pgxp") else { return }
    #expect(r.firstDivergence == nil, Comment(rawValue: r.message))
    #expect(r.framesChecked == 100)
}

/// The gate above is worthless if the capture carried no perspective triangles
/// — a fixture recorded with PGXP accidentally off would pass it trivially, by
/// taking exactly the affine path Gate 1 already covers.
@Test(.enabled(if: FileManager.default.fileExists(
                    atPath: FixtureFile.url(named: "tr1-usa-v1-1-pgxp").path)))
func thePgxpParityFixtureActuallyCarriesPerspectiveTriangles() throws {
    let file = try FixtureFile(contentsOf: FixtureFile.url(named: "tr1-usa-v1-1-pgxp"))
    var perspective = 0
    withExtendedLifetime(file) {
        for i in 0..<file.frames.count {
            for cmd in file.records(for: i)
            where cmd.kind == UInt8(PS1_GPU_DRAW_TEXTURED_TRIANGLE.rawValue) {
                let v = withUnsafeBytes(of: cmd.v) { raw -> [Ps1GpuVertex] in
                    let p = raw.bindMemory(to: Ps1GpuVertex.self)
                    return [p[0], p[1], p[2]]
                }
                if v[0].rw != 0 && v[1].rw != 0 && v[2].rw != 0 { perspective += 1 }
            }
        }
    }
    #expect(perspective > 1000,
            Comment(rawValue: "only \(perspective) perspective triangles — was the capture really --pgxp-on?"))
}
