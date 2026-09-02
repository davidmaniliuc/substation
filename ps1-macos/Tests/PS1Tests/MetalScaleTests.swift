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

// Measured 2026-08-30 (Gate 4, render cost only, no readback): the scale-8
// pass over the two 100-frame geometry fixtures costs 2.22 s (silent-hill-usa)
// plus 0.65 s (tr1-usa-v1-1) — 2.9 s against the 120 s the plan set as the
// point where scale 8 would have to narrow. It does not, so every call site
// here stays on the full ladder. The whole suite runs in about 90 s.

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

/// Two triangles sharing a SHALLOW edge must tile it with no crack, at every
/// internal resolution — checked over the FULL scaled buffer, not at top-left
/// subtexels.
///
/// This is the one thing downsample-invariance cannot see. It samples one
/// subtexel per native pixel, and a fill-rule bias that erodes a fraction of a
/// pixel from every top-left edge leaves those subtexels alone while carving a
/// crack through the ones between them. In a game it reads as a bright dashed
/// seam along every shared edge, because whatever was drawn earlier shows
/// through.
///
/// Shallow on purpose. The erosion a bias of B costs is B divided by the edge
/// function's gradient per subtexel, which is |dy| * 16 / s q-units — so a 45°
/// edge hides the bug completely and only a nearly-horizontal one exposes it.
/// This edge rises 1 px over 390, which at 8x puts the gradient at 32 q-units
/// per subtexel: a bias of PS1_Q_BIAS_SCALE would eat eight of them, a whole
/// native pixel.
@Test func twoTrianglesSharingAShallowEdgeLeaveNoCrackAtAnyScale() throws {
    let background: UInt16 = 0x7C1F
    let fill: UInt16 = 0x03E0

    var preload = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    for y in 0..<80 {
        for x in 0..<512 { preload[y * 1024 + x] = background }
    }

    // The shared edge runs (10, 30) -> (400, 31); one triangle sits above it
    // and one below, and they traverse it in opposite directions, which is
    // what makes the fill rule award each pixel on it to exactly one of them.
    func draw(_ r: MetalRasterizer) {
        var env = Ps1GpuCommand()
        env.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        env.opcode = 0xE4
        env.value = (511 << 10) | 1023
        r.apply(env)

        func tri(_ a: (Int16, Int16), _ b: (Int16, Int16), _ c: (Int16, Int16)) -> Ps1GpuCommand {
            var t = Ps1GpuCommand()
            t.kind = UInt8(PS1_GPU_DRAW_TRIANGLE.rawValue)
            t.value = UInt32(fill)
            t.v = (Ps1GpuVertex(x: a.0, y: a.1, u: 0, v: 0, _pad: 0, color: 0),
                   Ps1GpuVertex(x: b.0, y: b.1, u: 0, v: 0, _pad: 0, color: 0),
                   Ps1GpuVertex(x: c.0, y: c.1, u: 0, v: 0, _pad: 0, color: 0))
            return t
        }
        r.apply(tri((10, 30), (400, 31), (200, 5)))
        r.apply(tri((400, 31), (10, 30), (200, 60)))
    }

    for scale in [1] + scaleLadder {
        guard let f = try MetalScaleHarness.frame(scale: scale, preload: preload, draw) else { return }
        // A band straddling the shared edge, well inside the union's other
        // four edges at both ends, so only the shared one is under test.
        var survivors = 0
        var firstX = 0, firstY = 0
        for ny in 28...34 {
            for nx in 60...350 {
                for sy in 0..<scale {
                    for sx in 0..<scale {
                        let X = nx * scale + sx, Y = ny * scale + sy
                        if f.scaled[Y * f.width + X] == background {
                            if survivors == 0 { (firstX, firstY) = (X, Y) }
                            survivors += 1
                        }
                    }
                }
            }
        }
        #expect(survivors == 0,
                Comment(rawValue: "@\(scale)x: \(survivors) uncovered subtexels, first at (\(firstX), \(firstY))"))
    }
}

// MARK: - Gate 2: downsample-invariance, untextured

/// The three PL ROMs that draw without sampling: 18 flat + 6 Gouraud
/// triangles, 18 rectangles, and 60 mono + 20 shaded lines. `pl-hello-world`
/// and `pl-cpu-add` are NOT here — measured, they carry zero draw records and
/// are pure GP0(A0) upload fixtures, so they gate at Task 5.
let untexturedPlFixtures = ["pl-render-polygon", "pl-render-rectangle", "pl-render-line"]

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

// MARK: - Gate 2: the sampling paths

/// A native VRAM holding one texture page at each depth plus a CLUT, laid out
/// the way `synthetic_prims.zig` lays its own out: 4bpp at (0,0), 8bpp at
/// (128,0), 16bpp at (256,0), CLUT row at (0,240). Entry 0 of the CLUT is
/// deliberately 0 — a texel of 0 is a HOLE, discarded rather than drawn.
private func texturedVram() -> [UInt16] {
    var v = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    for i in 0..<256 {
        v[240 * MetalVram.nativeWidth + i] = i == 0 ? 0 : UInt16(truncatingIfNeeded: i &* 0x0123)
    }
    for y in 0..<64 {
        for x in 0..<64 {
            let row = y * MetalVram.nativeWidth
            v[row + x] = UInt16(truncatingIfNeeded: (x &+ y) &* 0x1111 &+ 0x1234)
            v[row + 128 + x] = UInt16(truncatingIfNeeded: (x &* 7 &+ y) &* 0x0303 &+ 0x0A1B)
            // 16bpp texels must not be zero anywhere, or the hole discard
            // hides the comparison instead of making it.
            v[row + 256 + x] = UInt16(truncatingIfNeeded: (x &+ y &* 64) | 0x0421)
        }
    }
    return v
}

@Test func texturedTrianglesAreDownsampleInvariantAtAllThreeDepths() throws {
    // tpage bits: low 4 are the page X in 64-pixel units, bit 4 the page Y,
    // bits 7-8 the depth. Pages at x = 0 / 128 / 256 are units 0 / 2 / 4.
    let pages: [(String, UInt16)] = [("4bpp", 0x0000), ("8bpp", 0x0082), ("16bpp", 0x0104)]
    let clut: UInt16 = UInt16(0) | (240 << 6)   // clut_x = 0, clut_y = 240

    for (label, tpage) in pages {
        func draw(_ r: MetalRasterizer) {
            var env = Ps1GpuCommand()
            env.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
            env.opcode = 0xE4
            env.value = (511 << 10) | 1023
            r.apply(env)

            var tri = Ps1GpuCommand()
            tri.kind = UInt8(PS1_GPU_DRAW_TEXTURED_TRIANGLE.rawValue)
            tri.opcode = 0x25            // bit 0 SET: raw, no modulation
            tri.tpage = tpage
            tri.clut = clut
            // Destination well clear of the pages this samples, so the draw
            // cannot feed itself.
            tri.v.0 = Ps1GpuVertex(x: 400, y: 300, u: 0, v: 0, _pad: 0, color: 0)
            tri.v.1 = Ps1GpuVertex(x: 460, y: 305, u: 60, v: 4, _pad: 0, color: 0)
            tri.v.2 = Ps1GpuVertex(x: 405, y: 360, u: 2, v: 58, _pad: 0, color: 0)
            r.apply(tri)
        }

        let vram = texturedVram()
        guard let one = try MetalScaleHarness.frame(scale: 1, preload: vram, draw) else { return }
        // The draw must actually paint, or "invariant" is a statement about
        // two blank images.
        #expect(one.native.filter { $0 != 0 }.count > 500, "\(label) drew nothing")

        for scale in scaleLadder {
            guard let many = try MetalScaleHarness.frame(scale: scale, preload: vram, draw)
            else { return }
            #expect(many.native == one.native, "\(label) @\(scale)x")
        }
    }
}

@Test func aSpriteWrapsItsTexcoordsInEightBitsAtEveryScale() throws {
    // `tu +% @truncate(xx)` on u8 is a WRAP, and it is in TEXEL units: it must
    // be computed from the native pixel, never from the subpixel. Computed
    // from px, an 8x sprite would wrap every 32 output pixels instead of every
    // 256 texels.
    var vram = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    for u in 0..<256 { vram[256 + u] = UInt16(0x0100 + u) }

    func draw(_ r: MetalRasterizer) {
        var env = Ps1GpuCommand()
        env.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        env.opcode = 0xE4
        env.value = (511 << 10) | 1023
        r.apply(env)

        var spr = Ps1GpuCommand()
        spr.kind = UInt8(PS1_GPU_DRAW_TEXTURED_RECTANGLE.rawValue)
        spr.opcode = 0x65                 // RAW: no modulation
        spr.tpage = 0x0104                // page x 4 (-> 256), 16bpp
        spr.x = 0; spr.y = 300; spr.w = 8; spr.h = 1
        spr.v.0 = Ps1GpuVertex(x: 0, y: 0, u: 252, v: 0, _pad: 0, color: 0)
        r.apply(spr)
    }

    let scale = 3
    guard let one = try MetalScaleHarness.frame(scale: 1, preload: vram, draw),
          let many = try MetalScaleHarness.frame(scale: scale, preload: vram, draw) else { return }

    let row = 300 * MetalVram.nativeWidth
    #expect(one.native[row + 3] == 0x01FF)   // u = 255
    #expect(one.native[row + 4] == 0x0100)   // u wrapped to 0 — a clamp would repeat 0x01FF
    #expect(many.native == one.native)

    // And texture data is NEVER upscaled: each native output pixel is a solid
    // s x s block of one texel, not a window into a finer texture.
    for x in 0..<8 {
        let want = one.native[row + x]
        for sy in 0..<scale {
            for sx in 0..<scale {
                let i = (300 * scale + sy) * many.width + (x * scale + sx)
                #expect(many.scaled[i] == want, "sprite texel \(x) subpixel (\(sx),\(sy))")
            }
        }
    }
}

@Test func aClutIndexPastTheRowEndReadsIntoTheNextRowAtEveryScale() throws {
    // `Vram.index(x, y)` is `y * 1024 + x` with NO masking, so a CLUT whose
    // clut_x + index runs past 1023 reads into the NEXT ROW. That linearize
    // must happen in NATIVE space and only then be scaled: linearizing at
    // scale (`y*1024*s + x*s`) invents a different wrap, and no fixture in the
    // corpus exercises the case.
    //
    // 8bpp page at (256, 0) whose texel 0 is index 20, CLUT at x = 1008:
    // 1008 + 20 = 1028, past the row end, so the read lands at
    // (1028 - 1024, 100 + 1) = (4, 101).
    var vram = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    vram[0 * MetalVram.nativeWidth + 256] = 0x0014          // idx 20 in the low byte
    vram[100 * MetalVram.nativeWidth + 4] = 0x5678          // the SAME-ROW answer
    vram[101 * MetalVram.nativeWidth + 4] = 0x1234          // the correct one

    func draw(_ r: MetalRasterizer) {
        var env = Ps1GpuCommand()
        env.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        env.opcode = 0xE4
        env.value = (511 << 10) | 1023
        r.apply(env)

        var spr = Ps1GpuCommand()
        spr.kind = UInt8(PS1_GPU_DRAW_TEXTURED_RECTANGLE.rawValue)
        spr.opcode = 0x65                                   // RAW
        spr.tpage = 0x0084                                  // page x 4 (-> 256), 8bpp
        spr.clut = UInt16(63) | (100 << 6)                  // clut_x = 1008, clut_y = 100
        spr.x = 10; spr.y = 300; spr.w = 1; spr.h = 1
        spr.v.0 = Ps1GpuVertex(x: 0, y: 0, u: 0, v: 0, _pad: 0, color: 0)
        r.apply(spr)
    }

    for scale in [1] + scaleLadder {
        guard let f = try MetalScaleHarness.frame(scale: scale, preload: vram, draw) else { return }
        #expect(f.native[300 * MetalVram.nativeWidth + 10] == 0x1234, "scale \(scale)")
    }
}

@Test(.enabled(if: generatedFixtureExists("tr1-usa-v1-1"),
               "geometry fixtures are generated from games/ — run `zig build fixtures -Doptimize=ReleaseFast`"))
func theTombRaiderFixtureIsDownsampleInvariant() throws {
    // 12,440 textured triangles, 979 textured rectangles and 50 fills over 100
    // frames of real gameplay — and, measured, zero uploads and zero copies,
    // which is what makes it the one geometry fixture reachable at this task.
    for scale in scaleLadder {
        guard let d = try MetalScaleHarness.compare("tr1-usa-v1-1", scale: scale) else { continue }
        #expect(Bool(false), Comment(rawValue: "tr1-usa-v1-1 @\(scale)x: \(d.message)"))
    }
}

// MARK: - Gate 2: the memory movers

@Test func anUploadReplicatesEachPayloadPixelIntoAnNbyNBlock() throws {
    // Every subpixel of a block resolves to the same payload word, because
    // `pix` is computed from the NATIVE pixel. There is no replication code
    // and there must not be any: a second path would be a second thing to get
    // wrong at the one place where the CPU's bytes enter VRAM.
    let words: [UInt32] = [0xBBBB_AAAA, 0xDDDD_CCCC]   // 4 pixels, 2x2
    func upload(_ r: MetalRasterizer) {
        var setup = Ps1GpuCommand()
        setup.kind = UInt8(PS1_GPU_VRAM_WRITE_SETUP.rawValue)
        setup.x = 40; setup.y = 50; setup.w = 2; setup.h = 2
        r.apply(setup)

        var data = Ps1GpuCommand()
        data.kind = UInt8(PS1_GPU_VRAM_WRITE_DATA.rawValue)
        data.x = 0; data.y = 2         // off, len — in WORDS
        r.apply(data)
    }

    let scale = 3
    guard let one = try MetalScaleHarness.frame(scale: 1, payload: words, upload),
          let many = try MetalScaleHarness.frame(scale: scale, payload: words, upload)
    else { return }

    let w = MetalVram.nativeWidth
    #expect(one.native[50 * w + 40] == 0xAAAA)
    #expect(one.native[50 * w + 41] == 0xBBBB)
    #expect(one.native[51 * w + 40] == 0xCCCC)
    #expect(one.native[51 * w + 41] == 0xDDDD)
    #expect(many.native == one.native)

    for (nx, ny, want) in [(40, 50, UInt16(0xAAAA)), (41, 50, 0xBBBB),
                           (40, 51, 0xCCCC), (41, 51, 0xDDDD)] {
        for sy in 0..<scale {
            for sx in 0..<scale {
                let i = (ny * scale + sy) * many.width + (nx * scale + sx)
                #expect(many.scaled[i] == want, "block (\(nx),\(ny)) subpixel (\(sx),\(sy))")
            }
        }
    }
}

@Test func aCopyPreservesScaledDetailRatherThanReplicatingTheNativePixel() throws {
    // The ONE mover that reads the scaled source. Its destination wrap is
    // native — the encoder has already split the rect into up to four boxes on
    // that basis — but the source read carries sub_x/sub_y, so content a game
    // moves around VRAM stays sharp instead of being flattened to its blocks'
    // top-left subtexels. Dropping those two terms still passes Gate 2, since
    // they are zero at every top-left subtexel; this is what catches it.
    let scale = 2
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue, scale: scale) else { return }
    let r = try MetalRasterizer(vram: vram)

    // A scaled source with a DIFFERENT value in every subpixel of every block.
    var scaled = [UInt16](repeating: 0, count: vram.pixelCount)
    for y in 0..<(4 * scale) {
        for x in 0..<(4 * scale) { scaled[y * vram.width + x] = UInt16(0x0100 + y * 16 + x) }
    }
    vram.upload(scaled)

    var copy = Ps1GpuCommand()
    copy.kind = UInt8(PS1_GPU_COPY_RECT.rawValue)
    copy.x = 0; copy.y = 0            // source origin
    copy.x2 = 100; copy.y2 = 200      // destination origin
    copy.w = 4; copy.h = 4
    r.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
    r.apply(copy)
    r.endFrame()

    let out = vram.readback()
    for y in 0..<(4 * scale) {
        for x in 0..<(4 * scale) {
            let want = scaled[y * vram.width + x]
            let got = out[(200 * scale + y) * vram.width + (100 * scale + x)]
            #expect(got == want, "subpixel (\(x),\(y)): a replicating copy gives the block's top-left")
        }
    }
}

@Test func theWholeSyntheticPrimitivesFixtureIsDownsampleInvariant() throws {
    // All seven frames now, including 2 and 4 (uploads feeding textured draws
    // in the same frame) and 6 (the feedback loop: a draw sampling a page this
    // very frame drew into, which is what makes pass splitting load-bearing).
    for scale in scaleLadder {
        guard let d = try MetalScaleHarness.compare("synthetic-primitives", scale: scale)
        else { continue }
        #expect(Bool(false), Comment(rawValue: "synthetic-primitives @\(scale)x: \(d.message)"))
    }
}

@Test func theCommittedMoverFixtureIsDownsampleInvariant() throws {
    for scale in scaleLadder {
        guard let d = try MetalScaleHarness.compare("synthetic-movers", scale: scale) else { continue }
        #expect(Bool(false), Comment(rawValue: "synthetic-movers @\(scale)x: \(d.message)"))
    }
}

/// The three generated fixtures whose content is movers: 26 and 432 uploads
/// with zero draw records, and 1,014 uploads at real FMV payload sizes.
/// `pl-render-texture-polygon` is here rather than with the textured tests
/// because its texture ARRIVES by upload, in the same frame as the 48
/// triangles that sample it.
let moverFixtures = ["pl-hello-world", "pl-cpu-add",
                     "pl-render-texture-polygon", "croc-legend-of-the-gobbos"]

@Test(.enabled(if: moverFixtures.contains(where: generatedFixtureExists),
               "generated fixtures are absent — run `zig build fixtures -Doptimize=ReleaseFast`"))
func theMoverFixturesAreDownsampleInvariant() throws {
    var checked = 0
    for name in moverFixtures {
        guard generatedFixtureExists(name) else { continue }
        checked += 1
        for scale in scaleLadder {
            guard let d = try MetalScaleHarness.compare(name, scale: scale) else { continue }
            #expect(Bool(false), Comment(rawValue: "\(name) @\(scale)x: \(d.message)"))
        }
    }
    #expect(checked > 0)
}

@Test(.enabled(if: generatedFixtureExists("silent-hill-usa"),
               "geometry fixtures are generated from games/ — run `zig build fixtures -Doptimize=ReleaseFast`"))
func theSilentHillFixtureIsDownsampleInvariant() throws {
    // 100 frames of real gameplay: 55,793 textured triangles, 28,120 Gouraud
    // triangles, 132 sprites, 100 copies and 50 fills. The copies are why it
    // waits for this task.
    for scale in scaleLadder {
        guard let d = try MetalScaleHarness.compare("silent-hill-usa", scale: scale) else { continue }
        #expect(Bool(false), Comment(rawValue: "silent-hill-usa @\(scale)x: \(d.message)"))
    }
}

/// Opt-in switch for the two gates a machine cannot judge, read from a file
/// rather than from the environment.
///
/// That is forced, not chosen. The shared scheme's TestAction carries
/// `shouldUseLaunchSchemeArgsEnv`, and the hosted test process therefore sees
/// neither an exported variable nor one passed with xcodebuild's
/// `TEST_RUNNER_` prefix — verified with a probe that printed an EMPTY
/// environment for both spellings. A marker file needs no xcodebuild plumbing
/// at all, and `zig-out/` is gitignored, so one cannot be committed by
/// accident. Returns the file's trimmed contents, or nil when it is absent.
///
///     echo 4 > zig-out/fixtures/PS1_DUMP_SCALED     # Gate 3, at 4x
///     touch  zig-out/fixtures/PS1_SCALE_TIMING      # Gate 4
private func gateSwitch(_ name: String) -> String? {
    let url = FixtureFile.repoURL
        .appendingPathComponent("zig-out/fixtures")
        .appendingPathComponent(name)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Gate 3: images
//
// Seams along quad diagonals, texture bleeding and gaps between adjacent
// primitives are visible in an image and move no hash. Opt-in, because it
// writes ~50 MB of PNG and nothing asserts on it.

/// The densest frame of each geometry fixture by draw-record count, measured
/// 2026-08-29 over `zig-out/fixtures/`: Silent Hill frame 74 carries 1,694
/// draws and Tomb Raider frame 58 carries 281.
///
/// The two `ff7-mako-*` entries are an ad-hoc capture of a FIELD scene with a
/// character model in it — the shape neither geometry fixture has, and the one
/// a scale defect shows up in first, since a distant model's facets are about a
/// pixel across. They are captured by `stream-capture --cue=... --memcard=...
/// --input=...`, PGXP on and off, and are absent on any machine that has not
/// run it; `generatedFixtureExists` skips them there.
private let gate3Frames: [(String, Int)] = [
    ("silent-hill-usa", 74), ("tr1-usa-v1-1", 58),
    ("ff7-mako-pgxp", 6), ("ff7-mako-off", 6),
]

@Test(.enabled(if: gateSwitch("PS1_DUMP_SCALED") != nil,
               "echo <N> > zig-out/fixtures/PS1_DUMP_SCALED to write the comparison PNGs"))
func dumpsScaledImagesForEyeballing() throws {
    guard let n = Int(gateSwitch("PS1_DUMP_SCALED") ?? ""), n >= 1, n <= 8 else {
        #expect(Bool(false), "PS1_DUMP_SCALED must hold 1...8")
        return
    }
    for (name, frame) in gate3Frames {
        guard generatedFixtureExists(name) else { continue }
        for scale in Set([1, n]).sorted() {
            guard let f = try MetalScaleHarness.replayTo(name, frame: frame, scale: scale)
            else { return }
            let url = VramImage.url(fixture: name, frame: frame, scale: scale)
            #expect(VramImage.write(f.scaled, width: f.width, height: f.height, to: url))
            // Neither geometry fixture uploads a texture — their windows start
            // from a blank VRAM, so their textured draws sample whatever the
            // fills and copies left behind and a texel of 0 is a discarded
            // HOLE. This number is how much picture there actually is to read.
            let painted = f.native.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
            print("[gate-3] \(name) frame \(frame) @\(scale)x -> \(url.path) "
                  + "(\(painted) of \(MetalVram.nativePixelCount) native px painted)")
        }
    }
}

// MARK: - Gate 4: cost
//
// The bounding-box overdraw Phase B accepted deliberately costs s^2 more
// fragments, and it had never been measured at any scale. Opt-in: it is a
// measurement, not an assertion, and it replays the whole corpus four times.

@Test(.enabled(if: gateSwitch("PS1_SCALE_TIMING") != nil,
               "touch zig-out/fixtures/PS1_SCALE_TIMING to measure per-scale replay cost"))
func measuresReplayCostAtEachScale() throws {
    let corpus = ["synthetic-primitives", "synthetic-movers"] + untexturedPlFixtures
        + moverFixtures + ["silent-hill-usa", "tr1-usa-v1-1"]
    for name in corpus {
        // `generatedFixtureExists` covers the committed synthetics too:
        // FixtureFile.url(named:) resolves those out of
        // ps1-core/tests/goldens/fixtures before falling back to zig-out.
        guard generatedFixtureExists(name) else { continue }
        for scale in [1, 2, 4, 8] {
            let t0 = DispatchTime.now().uptimeNanoseconds
            guard let frames = try replayForTiming(name, scale: scale) else { continue }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            let label = name.padding(toLength: 30, withPad: " ", startingAt: 0)
            print("[gate-4] \(label) @\(scale)x  "
                  + String(format: "%8.1f ms", ms) + "  (\(frames) frames)")
        }
    }
}

/// Replays a fixture at one scale and returns the frame count — no comparison,
/// no readback, so the number Gate 4 prints is render cost and not the cost of
/// moving 67 MB back over the bus per frame.
private func replayForTiming(_ name: String, scale: Int) throws -> Int? {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue, scale: scale) else { return nil }
    let r = try MetalRasterizer(vram: vram)
    let file = try FixtureFile(contentsOf: FixtureFile.url(named: name))
    var frames = 0
    withExtendedLifetime(file) {
        for i in 0..<file.frames.count {
            r.beginFrame(payload: file.payload(for: i))
            for cmd in file.records(for: i) { r.apply(cmd) }
            r.endFrame()
            frames += 1
        }
    }
    return frames
}

@Test func subPixelSliversAreRefusedAndPaintedIdenticallyAtEveryScale() throws {
    // The coverage test's "not all three zero" half is the only part of
    // ps1_triangle_coverage that is not scale-invariant by construction, and
    // only a sliver can reach it: all three biased edge functions are zero at
    // once only when twice-area is 1, 2 or 3, since each term contributes
    // 0 or 1 to their sum. PrimBuilder refuses area == 0 and nothing else, so
    // these reach the shader.
    //
    // The first triangle below is the exact failing case: twice-area 1, and at
    // (100,100) the unbiased weights are (1,0,0) with edge 0 top-left, so 1x
    // computes b == (0,0,0) and refuses it. Before the s^2 comparison it was
    // painted at 2x, 3x, 4x and 8x alike — one native pixel appearing out of
    // nothing above 1x, which is downsample-invariance broken outright. No
    // fixture in the corpus contains such a triangle; real distant geometry
    // does.
    let slivers: [(String, [(Int16, Int16)])] = [
        ("twice-area 1", [(100, 100), (101, 100), (100, 101)]),
        ("twice-area 1, reversed", [(100, 100), (100, 101), (101, 100)]),
        ("twice-area 2", [(100, 100), (102, 100), (100, 101)]),
        ("twice-area 3", [(100, 100), (103, 100), (100, 101)]),
    ]

    var everPainted = 0
    for (label, v) in slivers {
        func draw(_ r: MetalRasterizer) {
            var env = Ps1GpuCommand()
            env.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
            env.opcode = 0xE4
            env.value = (511 << 10) | 1023
            r.apply(env)
            var tri = Ps1GpuCommand()
            tri.kind = UInt8(PS1_GPU_DRAW_TRIANGLE.rawValue)
            tri.value = 0x7FFF
            tri.v.0 = Ps1GpuVertex(x: v[0].0, y: v[0].1, u: 0, v: 0, _pad: 0, color: 0)
            tri.v.1 = Ps1GpuVertex(x: v[1].0, y: v[1].1, u: 0, v: 0, _pad: 0, color: 0)
            tri.v.2 = Ps1GpuVertex(x: v[2].0, y: v[2].1, u: 0, v: 0, _pad: 0, color: 0)
            r.apply(tri)
        }

        guard let one = try MetalScaleHarness.frame(scale: 1, draw) else { return }
        everPainted += one.native.filter { $0 != 0 }.count
        for scale in scaleLadder {
            guard let many = try MetalScaleHarness.frame(scale: scale, draw) else { return }
            #expect(many.native == one.native, "\(label) @\(scale)x")
        }
    }

    // Without this the test would pass just as well against a shader that
    // refused every sliver at every scale, which is a different bug with the
    // same symptom. The twice-area 2 and 3 cases do paint at 1x.
    #expect(everPainted > 0, "every sliver was refused at 1x — the check is vacuous")
}

/// A small triangle that 1x paints must not be HOLLOW above 1x.
///
/// The degeneracy clause — "and not all three zero", restated as
/// `b_i < PS1_Q_BIAS_SCALE` — is a statement about a whole NATIVE pixel, but
/// it was evaluated at the SUBTEXEL sample point. Off the native lattice the
/// three biased edge functions are no longer multiples of PS1_Q_BIAS_SCALE, so
/// for any triangle of twice-area under 3 * PS1_Q_BIAS_SCALE a band around the
/// centroid has all three under it at once and is refused — while every
/// subtexel nearer an edge, where one term is large, is kept. The result is a
/// RING: the triangle is painted round its rim and hollow in the middle.
///
/// The triangle below is native twice-area 2. It paints 2 px at 1x, and before
/// the fix it painted 18 of 20 subtexels at 4x and 60 of 72 at 8x, with the
/// missing ones forming a solid triangular hole dead centre.
///
/// This is exactly the shape the two existing gates cannot see. Gate 1 and
/// Gate 2 compare `readbackNative()`, which is the TOP-LEFT subtexel of each
/// block, and at a top-left subtexel the sample point IS the native pixel — so
/// the clause reproduces its 1x decision there by construction and both gates
/// pass. Gate 2b's coverage ratio is a whole-frame average and a corpus of
/// mostly-large primitives dilutes it away. Only the interior of a small
/// triangle shows it, and a real game at 8x is made of them: a distant
/// character model whose facets are all about a pixel across comes out as
/// scattered rims with the scene showing through.
@Test func aSmallTriangleIsSolidRatherThanHollowAtEveryScale() throws {
    let fill: UInt16 = 0x7FFF
    // Native twice-area 2: small enough to reach the clause, large enough that
    // 1x paints it. Twice-area 1 is the genuine sliver and is refused at every
    // scale — `subPixelSliversAreRefusedAndPaintedIdenticallyAtEveryScale`
    // pins that, and this test must not weaken it.
    let v: [(Int16, Int16)] = [(100, 100), (102, 100), (100, 101)]

    func draw(_ r: MetalRasterizer) {
        var env = Ps1GpuCommand()
        env.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        env.opcode = 0xE4
        env.value = (511 << 10) | 1023
        r.apply(env)
        var tri = Ps1GpuCommand()
        tri.kind = UInt8(PS1_GPU_DRAW_TRIANGLE.rawValue)
        tri.value = UInt32(fill)
        tri.v.0 = Ps1GpuVertex(x: v[0].0, y: v[0].1, u: 0, v: 0, _pad: 0, color: 0)
        tri.v.1 = Ps1GpuVertex(x: v[1].0, y: v[1].1, u: 0, v: 0, _pad: 0, color: 0)
        tri.v.2 = Ps1GpuVertex(x: v[2].0, y: v[2].1, u: 0, v: 0, _pad: 0, color: 0)
        r.apply(tri)
    }

    guard let one = try MetalScaleHarness.frame(scale: 1, draw) else { return }
    // Without this the test passes against a shader that refuses the triangle
    // outright at every scale, which is a different bug with the same shape.
    #expect(one.native.filter { $0 != 0 }.count > 0, "the 1x replay drew nothing")

    for scale in [1] + scaleLadder {
        guard let f = try MetalScaleHarness.frame(scale: scale, draw) else { return }
        // A window around the triangle, one native pixel of margin on each
        // side, so "enclosed" is decided inside the drawn shape and never
        // against the edge of the scan.
        let x0 = 99 * scale, x1 = 104 * scale - 1
        let y0 = 99 * scale, y1 = 103 * scale - 1

        var holes: [(Int, Int)] = []
        for y in y0...y1 {
            for x in x0...x1 where f.scaled[y * f.width + x] != fill {
                let left = (x0..<x).contains { f.scaled[y * f.width + $0] == fill }
                let right = ((x + 1)..<(x1 + 1)).contains { f.scaled[y * f.width + $0] == fill }
                let up = (y0..<y).contains { f.scaled[$0 * f.width + x] == fill }
                let down = ((y + 1)..<(y1 + 1)).contains { f.scaled[$0 * f.width + x] == fill }
                if left && right && up && down { holes.append((x, y)) }
            }
        }
        #expect(holes.isEmpty,
                Comment(rawValue: "@\(scale)x: \(holes.count) enclosed unpainted subtexels, first at \(holes.first ?? (0, 0))"))
    }
}

/// A sub-pixel MESH must keep every native pixel that 1x paints.
///
/// `aSmallTriangleIsSolidRatherThanHollowAtEveryScale` is the single-triangle
/// half of this and it is not enough, in two ways at once: it draws ONE
/// triangle, and it looks only for an ENCLOSED hole. A character model is a
/// mesh, and the hole a mesh opens reaches the silhouette rather than being
/// surrounded by paint.
///
/// The pixel one facet owns is a pixel every other facet is refused in — a
/// non-owner's native sample point lies outside it by definition — so the pixel
/// used to come out covered by the owner's share alone, with each neighbour's
/// share left as background. The quad below is 2x1, split along its diagonal
/// into two facets of native twice-area 2, the size a distant character model's
/// facets are. 1x paints two pixels; at 8x, 20 of those two pixels' 128
/// subtexels were unpainted, in one wedge — the far facet's whole share of the
/// pixel its neighbour owned. That wedge is the reported hole.
@Test func aSubPixelMeshKeepsEveryNativePixelOneXPaints() throws {
    let fill: UInt16 = 0x7FFF
    let a: [(Int16, Int16)] = [(100, 100), (102, 100), (100, 101)]
    let b: [(Int16, Int16)] = [(102, 100), (102, 101), (100, 101)]

    func draw(_ r: MetalRasterizer) {
        var env = Ps1GpuCommand()
        env.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        env.opcode = 0xE4
        env.value = (511 << 10) | 1023
        r.apply(env)
        for v in [a, b] {
            var tri = Ps1GpuCommand()
            tri.kind = UInt8(PS1_GPU_DRAW_TRIANGLE.rawValue)
            tri.value = UInt32(fill)
            tri.v.0 = Ps1GpuVertex(x: v[0].0, y: v[0].1, u: 0, v: 0, _pad: 0, color: 0)
            tri.v.1 = Ps1GpuVertex(x: v[1].0, y: v[1].1, u: 0, v: 0, _pad: 0, color: 0)
            tri.v.2 = Ps1GpuVertex(x: v[2].0, y: v[2].1, u: 0, v: 0, _pad: 0, color: 0)
            r.apply(tri)
        }
    }

    guard let one = try MetalScaleHarness.frame(scale: 1, draw) else { return }
    var painted: [(Int, Int)] = []
    for y in 96..<106 {
        for x in 96..<108 where one.native[y * one.width + x] == fill { painted.append((x, y)) }
    }
    // Without this the test passes against a shader that draws nothing at all,
    // which is a different bug with the same reading.
    #expect(painted.count > 0, "the 1x replay drew nothing")

    for scale in scaleLadder {
        guard let f = try MetalScaleHarness.frame(scale: scale, draw) else { return }
        var missing = 0
        for (nx, ny) in painted {
            for sy in 0..<scale {
                for sx in 0..<scale
                where f.scaled[(ny * scale + sy) * f.width + nx * scale + sx] != fill {
                    missing += 1
                }
            }
        }
        let total = painted.count * scale * scale
        #expect(missing == 0,
                "scale \(scale): \(missing) of \(total) subtexels unpainted, over the \(painted.count) native px 1x paints")
    }
}
