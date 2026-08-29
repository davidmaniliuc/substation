import Testing
import Foundation
import Metal
import CPs1
@testable import PS1

// Phase C's gate ladder. Gate 1 (Metal == Zig at 1x) lives in
// MetalRasterizerTests and MetalMoverTests and is a FREEZE: nothing here may
// move it. What these tests add is Gate 2 (downsample-invariance), Gate 2b
// (bounds, the clip conversion and coverage density) and, at Task 6, Gates 3
// and 4.

/// The scales every sweep runs. 3 is in the list on purpose: `px / s` and
/// `px % s` compile to shifts and masks at every power of two, so a bug
/// written as `>> log2(s)`, or an assumption that `s` divides some extent, is
/// invisible at 2, 4 and 8 and fires at 3.
let scaleLadder = [2, 3, 4, 8]

@Test func theRasterUniformIsEightBytesOnBothSides() {
    // The Metal side carries `static_assert(sizeof(Ps1RasterUniforms) == 8)`.
    // This is the other half of that pair: a field added on one side only
    // shears `scale` and `dither_off` against each other, and the symptom
    // would be "scale 1 renders at scale 0", i.e. nothing drawn at all.
    #expect(MemoryLayout<Ps1RasterUniforms>.stride == 8)
    #expect(MemoryLayout<Ps1RasterUniforms>.size == 8)
}

@Test func aFillPaintsExactlyItsScaledBoxAndNothingElse() throws {
    // ps1_fill_fragment has no coverage test, no clip and no mask, so whatever
    // region it paints IS the quad ps1_vertex emitted. That isolates the
    // vertex shader: this test fails for a wrong box expansion and for nothing
    // else.
    let scale = 4
    guard let f = try MetalScaleHarness.frame(scale: scale, { r in
        var fill = Ps1GpuCommand()
        fill.kind = UInt8(PS1_GPU_FILL_RECT.rawValue)
        fill.x = 10; fill.y = 20; fill.w = 20; fill.h = 20
        fill.value = 0x7C1F
        r.apply(fill)
    }) else { return }

    var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min, count = 0
    for y in 0..<f.height {
        for x in 0..<f.width where f.scaled[y * f.width + x] != 0 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            count += 1
        }
    }
    // The box is INCLUSIVE (10,20)-(29,39), so the scaled span is
    // [10*s, (29+1)*s - 1] — the same +1 the vertex shader applies, and the
    // same one the drawing-area clip will need in Task 3.
    #expect(minX == 10 * scale)
    #expect(maxX == 30 * scale - 1)
    #expect(minY == 20 * scale)
    #expect(maxY == 40 * scale - 1)
    #expect(count == 20 * scale * 20 * scale)
    #expect(f.native.filter { $0 != 0 }.count == 20 * 20)
}

@Test func aFillIsDownsampleInvariantAtEveryScale() throws {
    // The first instance of the property the whole phase is built on, on the
    // one path that is already complete after this task. An odd, prime-ish
    // extent (33 x 17) so no scale divides it evenly.
    func draw(_ r: MetalRasterizer) {
        var fill = Ps1GpuCommand()
        fill.kind = UInt8(PS1_GPU_FILL_RECT.rawValue)
        fill.x = 7; fill.y = 11; fill.w = 33; fill.h = 17
        fill.value = 0x03E0
        r.apply(fill)
    }

    guard let one = try MetalScaleHarness.frame(scale: 1, draw) else { return }
    for scale in scaleLadder {
        guard let many = try MetalScaleHarness.frame(scale: scale, draw) else { return }
        #expect(many.native == one.native, "scale \(scale)")
    }
}
