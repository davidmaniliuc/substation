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
