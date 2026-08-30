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

// MARK: - Gate 2b: bounds, the clip conversion, and coverage density

/// Gate 2b, bounds half. Every non-zero scaled pixel must lie inside some
/// instance's scaled box — intersected with that instance's scaled drawing
/// area for the seven DRAWING kinds. The three movers carry no clip: their
/// instances are zero-initialized by the encoder and the shader never applies
/// one to them.
private func assertNothingOutsideTheScaledBoxes(_ f: MetalScaleHarness.Frame,
                                                _ label: String) {
    let s = f.scale
    var allowed = [Bool](repeating: false, count: f.width * f.height)
    for inst in f.instances {
        var x0 = Int(inst.box_x0) * s, x1 = (Int(inst.box_x1) + 1) * s - 1
        var y0 = Int(inst.box_y0) * s, y1 = (Int(inst.box_y1) + 1) * s - 1
        if inst.kind <= Int32(PS1_PRIM_SHADED_LINE_PIXEL) {
            x0 = max(x0, Int(inst.clip_x0) * s)
            x1 = min(x1, (Int(inst.clip_x1) + 1) * s - 1)
            y0 = max(y0, Int(inst.clip_y0) * s)
            y1 = min(y1, (Int(inst.clip_y1) + 1) * s - 1)
        }
        guard x0 <= x1, y0 <= y1 else { continue }
        for y in y0...y1 {
            let row = y * f.width
            for x in x0...x1 { allowed[row + x] = true }
        }
    }
    var strays = 0
    var first = "none"
    for i in 0..<f.scaled.count where f.scaled[i] != 0 && !allowed[i] {
        if strays == 0 {
            first = String(format: "(%d,%d)=%04X", i % f.width, i / f.width, f.scaled[i])
        }
        strays += 1
    }
    #expect(strays == 0, Comment(rawValue: "\(label): \(strays) px outside every scaled box, first \(first)"))
}

/// Gate 2b, density half.
///
/// The spec proposes a tolerance of `perimeter * s`; that bound is not
/// provable — a native covered pixel on a primitive's boundary can have
/// anywhere from 1 to s*s of its subpixels covered, so the per-boundary-pixel
/// error is O(s^2), not O(s). What the check exists to catch is two gross
/// failures Gate 2 is blind to, because Gate 2 constrains only the top-left
/// subtexel of each block:
///
///   - every OTHER subpixel left black  -> ratio ~ 1/s^2, at most 0.25
///   - the whole bounding box painted    -> ratio well above 1.6
///
/// so a ratio band catches both with a wide margin on these three frames,
/// whose primitives are chunky triangles and exact-by-construction rectangles
/// and line pixels. `perimeter` is still computed and printed: it is the
/// number that says how much slack the band actually has.
private func assertCoverageDensity(oneX: [UInt16], _ f: MetalScaleHarness.Frame,
                                   _ label: String) {
    let n1 = oneX.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
    guard n1 > 0 else {
        #expect(Bool(false), Comment(rawValue: "\(label): the 1x replay drew nothing"))
        return
    }
    let w = MetalVram.nativeWidth, h = MetalVram.nativeHeight
    var perimeter = 0
    for y in 0..<h {
        for x in 0..<w where oneX[y * w + x] != 0 {
            let up = y == 0 || oneX[(y - 1) * w + x] == 0
            let down = y == h - 1 || oneX[(y + 1) * w + x] == 0
            let left = x == 0 || oneX[y * w + x - 1] == 0
            let right = x == w - 1 || oneX[y * w + x + 1] == 0
            if up || down || left || right { perimeter += 1 }
        }
    }
    let nN = f.scaled.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
    let expected = Double(n1 * f.scale * f.scale)
    let ratio = Double(nN) / expected
    print("[gate-2b] \(label): n1=\(n1) perimeter=\(perimeter) nN=\(nN) ratio=\(String(format: "%.4f", ratio))")
    #expect(ratio >= 0.6 && ratio <= 1.6,
            Comment(rawValue: "\(label): coverage ratio \(ratio) outside [0.6, 1.6]"))
}

/// Gate 2b runs at these scales only. The bounds half allocates and scans one
/// Bool per scaled pixel, which is 33.5M at scale 8 — for three frames on
/// every run of the suite. Scale 8's bounds are covered instead by
/// `theDrawingAreaClipScalesAsAnInclusiveBound` (the specific off-by-one this
/// gate exists for) and by Gate 2 at scale 8 in Task 6.
private let gate2bScales = [2, 3, 4]

@Test func theDrawingAreaClipScalesAsAnInclusiveBound() throws {
    // The native drawing area is INCLUSIVE, so the scaled test is
    // `px > (x1 + 1) * s - 1`, not `px > x1 * s`. The two agree at every
    // top-left subtexel — which is exactly the set Gate 1 and Gate 2 compare —
    // so neither can see the difference; the wrong form silently drops the
    // last (s - 1) columns and rows of every clipped primitive.
    //
    // A flat rectangle is the subject because it is covered by construction:
    // no edge function participates, so the extent of what lands in VRAM is
    // decided by the clip and by nothing else.
    let scale = 4
    guard let f = try MetalScaleHarness.frame(scale: scale, { r in
        func env(_ op: UInt8, _ v: UInt32) -> Ps1GpuCommand {
            var c = Ps1GpuCommand()
            c.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
            c.opcode = op
            c.value = v
            return c
        }
        r.apply(env(0xE3, (100 << 10) | 100))   // top-left  (100, 100)
        r.apply(env(0xE4, (130 << 10) | 140))   // bottom-right (140, 130), INCLUSIVE

        var rect = Ps1GpuCommand()
        rect.kind = UInt8(PS1_GPU_DRAW_RECTANGLE.rawValue)
        rect.x = 90; rect.y = 90; rect.w = 80; rect.h = 80   // overflows all four sides
        rect.value = 0x7FFF
        r.apply(rect)
    }) else { return }

    var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
    for y in 0..<f.height {
        for x in 0..<f.width where f.scaled[y * f.width + x] != 0 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    #expect(minX == 100 * scale)          // 400
    #expect(maxX == (140 + 1) * scale - 1) // 563, NOT 140 * 4 == 560
    #expect(minY == 100 * scale)          // 400
    #expect(maxY == (130 + 1) * scale - 1) // 523, NOT 130 * 4 == 520
}

@Test func aFullVramGouraudTriangleDoesNotOverflowTheInterpolator() throws {
    // ps1_interp's numerator is bounded by area * 255, and BOTH the weights
    // and the area scale by s^2. An oversized-capped primitive reaches about
    // 2.13e9 at s = 4 — 1% under int32's ceiling — and goes over it at s = 5.
    // This triangle is 1022 x 510, the largest the oversized refusal admits,
    // with the full 0..255 colour range, so a shader that kept `int`
    // intermediates wraps here and nowhere else in the corpus.
    func draw(_ r: MetalRasterizer) {
        var env = Ps1GpuCommand()
        env.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        env.opcode = 0xE4
        env.value = (511 << 10) | 1023
        r.apply(env)

        var tri = Ps1GpuCommand()
        tri.kind = UInt8(PS1_GPU_DRAW_SHADED_TRIANGLE.rawValue)
        tri.v.0 = Ps1GpuVertex(x: 0, y: 0, u: 0, v: 0, _pad: 0, color: 0x00FF_FFFF)
        tri.v.1 = Ps1GpuVertex(x: 1022, y: 0, u: 0, v: 0, _pad: 0, color: 0x0000_00FF)
        tri.v.2 = Ps1GpuVertex(x: 0, y: 510, u: 0, v: 0, _pad: 0, color: 0x00FF_0000)
        r.apply(tri)
    }

    guard let one = try MetalScaleHarness.frame(scale: 1, draw) else { return }
    for scale in [4, 8] {
        guard let many = try MetalScaleHarness.frame(scale: scale, draw) else { return }
        #expect(many.native == one.native, "scale \(scale)")
    }
}

// MARK: - Gate 2: downsample-invariance, untextured

/// The three PL ROMs that draw without sampling: 18 flat + 6 Gouraud
/// triangles, 18 rectangles, and 60 mono + 20 shaded lines. `pl-hello-world`
/// and `pl-cpu-add` are NOT here — measured, they carry zero draw records and
/// are pure GP0(A0) upload fixtures, so they gate at Task 5.
private let untexturedPlFixtures = ["pl-render-polygon", "pl-render-rectangle", "pl-render-line"]

@Test(.enabled(if: untexturedPlFixtures.contains(where: generatedFixtureExists),
               "pl-*.p1fx are build artifacts — run `zig build fixtures -Doptimize=ReleaseFast`"))
func theUntexturedPeterLemonRomsAreDownsampleInvariant() throws {
    var checked = 0
    for name in untexturedPlFixtures {
        guard generatedFixtureExists(name) else { continue }
        for scale in scaleLadder {
            guard let d = try MetalScaleHarness.compare(name, scale: scale) else { continue }
            #expect(Bool(false), Comment(rawValue: "\(name) @\(scale)x: \(d.message)"))
        }
        checked += 1
    }
    #expect(checked > 0)
}

@Test func theUntexturedSyntheticFramesAreDownsampleInvariant() throws {
    // Frames 0 and 1 are flat and Gouraud triangles and can be replayed
    // cumulatively. Frame 2 uploads three texture pages and a CLUT, so the
    // cumulative replay stops before it: uploads scale in Task 5.
    for scale in scaleLadder {
        guard let d = try MetalScaleHarness.compare("synthetic-primitives", scale: scale, upTo: 2)
        else { continue }
        #expect(Bool(false), Comment(rawValue: "synthetic-primitives @\(scale)x: \(d.message)"))
    }

    // Frames 3 (rectangles) and 5 (lines) each open with their own E3/E4/E5,
    // so a from-blank single-frame replay of either is well defined and skips
    // the upload frames between them.
    for frame in [3, 5] {
        guard let one = try MetalScaleHarness.fixtureFrame("synthetic-primitives",
                                                           frame: frame, scale: 1) else { return }
        for scale in scaleLadder {
            guard let many = try MetalScaleHarness.fixtureFrame("synthetic-primitives",
                                                                frame: frame, scale: scale)
            else { return }
            #expect(many.native == one.native, "frame \(frame) @\(scale)x")
        }
    }
}

@Test func theUntexturedSyntheticFramesRespectTheirScaledBoxesAndCoverTheirBlocks() throws {
    // Gate 2 constrains only the top-left subtexel of each block, so a bug
    // that left every other subpixel black would pass it and look
    // catastrophic. This is what catches that mechanically.
    for frame in [0, 3, 5] {
        guard let one = try MetalScaleHarness.fixtureFrame("synthetic-primitives",
                                                           frame: frame, scale: 1) else { return }
        for scale in gate2bScales {
            guard let f = try MetalScaleHarness.fixtureFrame("synthetic-primitives",
                                                             frame: frame, scale: scale)
            else { return }
            assertNothingOutsideTheScaledBoxes(f, "frame \(frame) @\(scale)x")
            assertCoverageDensity(oneX: one.native, f, "frame \(frame) @\(scale)x")
        }
    }
}
