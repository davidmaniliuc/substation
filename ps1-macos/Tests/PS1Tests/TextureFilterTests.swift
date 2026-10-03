import Testing
import Foundation
import Metal
import CPs1
@testable import PS1

/// Texture filtering's own gates.
///
/// The primary assertion is negative, as true colour's was: VRAM is
/// byte-identical under both filters, so nothing a gate reads can move. The
/// rest pin the sidecar: what filtering adds, and the three ways it could
/// smear the wrong colour in (a hole, an atlas neighbour, a texture window).

private let w = MetalVram.nativeWidth
/// The 16bpp texture page every hand-built test samples: tpage 0x0104 puts
/// page X at unit 4, i.e. VRAM x = 256, y = 0.
private let page16: UInt16 = 0x0104
private let pageX = 256

/// A native VRAM with `row` written at (256 + u, v) for v in 0..<rows.
private func vramWithRows(_ row: [UInt16], rows: Int = 16) -> [UInt16] {
    var v = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    for y in 0..<rows { for (u, t) in row.enumerated() { v[y * w + pageX + u] = t } }
    return v
}

private func drawingArea(_ r: MetalRasterizer) {
    var area = Ps1GpuCommand()
    area.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
    area.opcode = 0xE4
    area.value = (511 << 10) | 1023
    r.apply(area)
}

/// A right triangle at (300, 300) whose legs are `size` px and span texcoords
/// `u0...u1` horizontally and `v0...v1` vertically: a magnified texture.
private func texturedTriangle(opcode: UInt8 = 0x25, tpage: UInt16 = page16, clut: UInt16 = 0,
                              u0: UInt8, u1: UInt8, v0: UInt8 = 0, v1: UInt8 = 2,
                              size: Int16 = 128, colors: (UInt32, UInt32, UInt32) = (0, 0, 0),
                              flags: UInt8 = 0, rw: (Int32, Int32, Int32) = (0, 0, 0),
                              transparent: UInt8 = 0)
    -> (MetalRasterizer) -> Void {
    return { r in
        drawingArea(r)
        var tri = Ps1GpuCommand()
        tri.kind = UInt8(PS1_GPU_DRAW_TEXTURED_TRIANGLE.rawValue)
        tri.opcode = opcode
        tri.tpage = tpage
        tri.clut = clut
        tri.v.0 = Ps1GpuVertex(x: 300, y: 300, u: u0, v: v0, _pad: 0, color: colors.0)
        tri.v.1 = Ps1GpuVertex(x: 300 + size, y: 300, u: u1, v: v0, _pad: 0, color: colors.1)
        tri.v.2 = Ps1GpuVertex(x: 300, y: 300 + size, u: u0, v: v1, _pad: 0, color: colors.2)
        tri.v.0.rw = rw.0; tri.v.1.rw = rw.1; tri.v.2.rw = rw.2
        tri.flags = flags
        tri.transparent = transparent
        r.apply(tri)
    }
}

/// Every PRESENT sidecar pixel's red byte inside the triangle's box.
private func sidecarReds(_ f: MetalScaleHarness.Frame, size: Int = 128) -> [UInt8] {
    guard let side = f.sidecar else { return [] }
    var reds: [UInt8] = []
    let s = f.scale
    for y in (300 * s)..<((300 + size) * s) {
        for x in (300 * s)..<((300 + size) * s) {
            let i = y * f.width + x
            if side[i * 4 + 3] == 255 { reds.append(side[i * 4]) }
        }
    }
    return reds
}

/// Red 1 -> red 31 -> red 31: a hard edge one texel wide, magnified 64x.
private let edgeRow: [UInt16] = [0x0001, 0x001F, 0x001F, 0x001F]

// MARK: - VRAM never moves

@Test func theCorpusRendersIdenticalVramUnderBothFilters() throws {
    // THE gate. Every fixture that exists, every frame, two dither modes (a
    // dithering one, since the VRAM path there carries the offset) and two
    // scales (3 because `/ s` is a shift at every power of two).
    // `tr1-usa-v1-1-pgxp` is the one that carries perspective texcoords.
    let corpus = ["synthetic-primitives", "synthetic-movers", "silent-hill-usa", "tr1-usa-v1-1",
                  "tr1-usa-v1-1-pgxp"]
    for name in corpus where generatedFixtureExists(name) {
        for dither in [DitherMode.native, .trueColor] {
            for scale in [1, 3] {
                guard let device = MTLCreateSystemDefaultDevice(),
                      let queue = device.makeCommandQueue(),
                      let a = MetalVram(device: device, queue: queue, scale: scale),
                      let b = MetalVram(device: device, queue: queue, scale: scale) else { return }
                let nearest = try MetalRasterizer(vram: a)
                let bilinear = try MetalRasterizer(vram: b)
                for r in [nearest, bilinear] { r.ditherMode = dither }
                nearest.textureFilter = .nearest
                bilinear.textureFilter = .bilinear
                let file = try FixtureFile(contentsOf: FixtureFile.url(named: name))
                withExtendedLifetime(file) {
                    for i in 0..<file.frames.count {
                        for r in [nearest, bilinear] {
                            r.beginFrame(payload: file.payload(for: i))
                            for cmd in file.records(for: i) { r.apply(cmd) }
                            r.endFrame()
                        }
                        #expect(a.readback() == b.readback(),
                                Comment(rawValue: "\(name) \(dither) @\(scale)x frame \(i): VRAM moved"))
                    }
                }
            }
        }
    }
}

// MARK: - What it adds

@Test func bilinearAddsLevelsAcrossAMagnifiedEdge() throws {
    let draw = texturedTriangle(u0: 0, u1: 2)
    let vram = vramWithRows(edgeRow)
    guard let near = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                                 filter: .nearest, wantSidecar: true, draw),
          let bil = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                                filter: .bilinear, wantSidecar: true, draw)
    else { return }
    #expect(Set(sidecarReds(near)).count == 2, "the control: nearest has exactly two reds")
    #expect(Set(sidecarReds(bil)).count > 16,
            "bilinear has \(Set(sidecarReds(bil)).count) reds across a 64x-magnified edge")
    #expect(near.scaled == bil.scaled, "VRAM moved")
}

@Test func bilinearAddsLevelsAtEveryTextureDepth() throws {
    // Filtered on the CLUT's OUTPUT. A 4bpp/8bpp texel is an index; the four
    // indices 1, 2, 2, 2 map through CLUT entries 1 and 2 at (0, 240) to
    // edgeRow's colours (index 0 would be a hole).
    var vram = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    vram[240 * w + 1] = 0x0001
    vram[240 * w + 2] = 0x001F
    for y in 0..<16 {
        vram[y * w + pageX] = 0x2221        // 4bpp: indices 1,2,2,2 in one word
        vram[y * w + 128] = 0x0201          // 8bpp page at x = 128: indices 1,2
        vram[y * w + 129] = 0x0202          //                          2,2
    }
    let clut: UInt16 = 240 << 6
    for (label, tpage) in [("4bpp", UInt16(0x0004)), ("8bpp", UInt16(0x0082))] {
        let draw = texturedTriangle(tpage: tpage, clut: clut, u0: 0, u1: 2)
        guard let bil = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                                    filter: .bilinear, wantSidecar: true, draw)
        else { return }
        #expect(Set(sidecarReds(bil)).count > 16, "\(label): filtering did not reach the CLUT colours")
    }
}

@Test func aUniformTextureFiltersToItselfInEveryMode() throws {
    // T == t5 << 3 everywhere, and every per-mode formula reproduces today's
    // sidecar there bit for bit. Modulated and Gouraud-shaded with dithering
    // ON (GP0(E1) bit 9), so the dithering modes' formula is exercised too.
    let vram = vramWithRows([UInt16](repeating: 0x2D6B, count: 4))
    let draw: (MetalRasterizer) -> Void = { r in
        var mode = Ps1GpuCommand()
        mode.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        mode.opcode = 0xE1
        mode.value = 1 << 9
        r.apply(mode)
        texturedTriangle(opcode: 0x34, u0: 0, u1: 3, v1: 3,
                         colors: (0x0020_4060, 0x00FF_C080, 0x0010_8040))(r)
    }
    for dither in DitherMode.allCases {
        guard let near = try MetalScaleHarness.frame(scale: 2, preload: vram, dither: dither,
                                                     filter: .nearest, wantSidecar: true, draw),
              let bil = try MetalScaleHarness.frame(scale: 2, preload: vram, dither: dither,
                                                    filter: .bilinear, wantSidecar: true, draw)
        else { return }
        #expect(sidecarReds(near).count > 1000, "\(dither): the triangle drew nothing")
        #expect(near.sidecar == bil.sidecar, "\(dither): a uniform texture filtered to something else")
        #expect(near.scaled == bil.scaled)
    }
}

@Test func perspectiveTexcoordsFilterToo() throws {
    let draw = texturedTriangle(u0: 0, u1: 2, flags: UInt8(PS1_GPU_FLAG_TEXTURE_PERSPECTIVE),
                                rw: (65536, 16384, 65536))
    let vram = vramWithRows(edgeRow)
    guard let near = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                                 filter: .nearest, wantSidecar: true, draw),
          let bil = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                                filter: .bilinear, wantSidecar: true, draw)
    else { return }
    #expect(Set(sidecarReds(bil)).count > 16)
    #expect(near.scaled == bil.scaled, "VRAM moved on the perspective path")
}

@Test func aOneToOneMappingFiltersToTheNearestTexelAtOneX() throws {
    // One texel per pixel at 1x: every pixel CENTRE lands on a texel centre,
    // so the filter must give back exactly the nearest texel. Sampled at the
    // pixel's corner instead, every pixel averages a 2x2 block half a texel
    // up and to the left. Every texel differs from its neighbours on both
    // axes, so any blur shows.
    var vram = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    for y in 0..<20 {
        for u in 0..<20 { vram[y * w + pageX + u] = UInt16((u * 5 + y * 3) % 31 + 1) }
    }
    let draw = texturedTriangle(u0: 0, u1: 16, v0: 0, v1: 16, size: 16)
    for (label, d) in [("affine", draw),
                       ("perspective", texturedTriangle(u0: 0, u1: 16, v0: 0, v1: 16, size: 16,
                                                        flags: UInt8(PS1_GPU_FLAG_TEXTURE_PERSPECTIVE),
                                                        rw: (4096, 4096, 4096)))] {
        guard let near = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                                     filter: .nearest, wantSidecar: true, d),
              let bil = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                                    filter: .bilinear, wantSidecar: true, d)
        else { return }
        #expect(sidecarReds(near, size: 16).count > 100, "\(label): the triangle drew nothing")
        #expect(near.sidecar == bil.sidecar, "\(label): a 1:1 mapping was blurred")
        #expect(near.scaled == bil.scaled, "\(label): VRAM moved")
    }
}

// MARK: - What it must not smear in

@Test func aHoleNeighbourDrawsNoFringe() throws {
    // texel 0 bright, texel 1 a HOLE. Filtering the hole as black darkens
    // every pixel beside a cut-out; weight zero leaves them at the texel.
    let draw = texturedTriangle(u0: 0, u1: 1)
    let vram = vramWithRows([0x001F, 0x0000])
    guard let bil = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                                filter: .bilinear, wantSidecar: true, draw)
    else { return }
    let reds = sidecarReds(bil)
    #expect(reds.count > 1000, "the triangle drew nothing")
    #expect(reds.allSatisfy { $0 == 255 }, "a hole was filtered in: min red \(reds.min() ?? 0)")
}

@Test func uvLimitsKeepAtlasNeighboursOut() throws {
    // An atlas cell at u/v 4..7, all blue, with RED in the column and row just
    // below it. A centred sample at U < 4.5 reaches u = 3 unless clamped.
    var vram = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    for y in 0..<12 {
        for u in 0..<12 {
            vram[y * w + pageX + u] = (u == 3 || y == 3) ? 0x001F : 0x7C00
        }
    }
    let draw = texturedTriangle(u0: 4, u1: 7, v0: 4, v1: 7)
    guard let bil = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                                filter: .bilinear, wantSidecar: true, draw)
    else { return }
    let reds = sidecarReds(bil)
    #expect(reds.count > 1000, "the triangle drew nothing")
    #expect(reds.allSatisfy { $0 == 0 }, "an atlas neighbour bled in: max red \(reds.max() ?? 0)")
}

@Test func filteredNeighboursWrapInsideTheTextureWindow() throws {
    // GP0(E2) mask field 0x1F clears bits 3-7 of u and v, offset 0: every
    // coordinate wraps into 0..7. Inside that window texels are blue;
    // u = 8.. and v = 8.. are red and must never be reached.
    var vram = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    for y in 0..<24 {
        for u in 0..<24 { vram[y * w + pageX + u] = (u < 8 && y < 8) ? 0x7C00 : 0x001F }
    }
    let draw: (MetalRasterizer) -> Void = { r in
        var win = Ps1GpuCommand()
        win.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        win.opcode = 0xE2
        win.value = 0x1F | (0x1F << 5)     // u & 7, v & 7
        r.apply(win)
        texturedTriangle(u0: 0, u1: 20, v0: 0, v1: 20)(r)
    }
    guard let bil = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                                filter: .bilinear, wantSidecar: true, draw)
    else { return }
    let reds = sidecarReds(bil)
    #expect(reds.count > 1000, "the triangle drew nothing")
    #expect(reds.allSatisfy { $0 == 0 }, "a texel outside the window bled in")
}

// MARK: - Dithering modes and blending

@Test func theDitheringModesStayFiveBitUnderBilinear() throws {
    let draw = texturedTriangle(u0: 0, u1: 2)
    let vram = vramWithRows(edgeRow)
    for dither in [DitherMode.off, .native, .scaled] {
        guard let near = try MetalScaleHarness.frame(scale: 2, preload: vram, dither: dither,
                                                     filter: .nearest, wantSidecar: true, draw),
              let bil = try MetalScaleHarness.frame(scale: 2, preload: vram, dither: dither,
                                                    filter: .bilinear, wantSidecar: true, draw)
        else { return }
        let reds = sidecarReds(bil)
        // `expand` of a five-bit value: the byte is (c << 3) | (c >> 2).
        #expect(reds.allSatisfy { r in let c = r >> 3; return r == (c << 3) | (c >> 2) },
                "\(dither): an eight-bit value reached a five-bit mode's sidecar")
        #expect(Set(reds).count > Set(sidecarReds(near)).count,
                "\(dither): filtering changed nothing")
    }
}

@Test func aSemiTransparentFilteredDrawBlendsTheFilteredColourInDitheringModes() throws {
    // Review Focus 1. Raw + semi-transparent (opcode 0x27), STP-set texels,
    // mode 1 (add) over a dark red fill. Before the fix `out8` came from the
    // NEAREST blend in the dithering modes and showed exactly two reds.
    let vram = vramWithRows([0x8001, 0x801F, 0x801F, 0x801F])
    let draw: (MetalRasterizer) -> Void = { r in
        drawingArea(r)
        var fill = Ps1GpuCommand()
        fill.kind = UInt8(PS1_GPU_FILL_RECT.rawValue)
        fill.value = 0x0008                // dark red background, 15-bit
        fill.x = 288; fill.y = 288; fill.w = 160; fill.h = 160
        r.apply(fill)
        var latch = Ps1GpuCommand()
        latch.kind = UInt8(PS1_GPU_LATCH_TEXPAGE.rawValue)
        latch.tpage = page16 | (1 << 5)
        r.apply(latch)
        texturedTriangle(opcode: 0x27, tpage: page16 | (1 << 5), u0: 0, u1: 2,
                         transparent: 1)(r)
    }
    for dither in [DitherMode.off, .trueColor] {
        guard let bil = try MetalScaleHarness.frame(scale: 2, preload: vram, dither: dither,
                                                    filter: .bilinear, wantSidecar: true, draw)
        else { return }
        #expect(Set(sidecarReds(bil)).count > 8,
                "\(dither): the blend shows \(Set(sidecarReds(bil)).count) reds; it used the nearest texel")
    }
}

@Test func texturedRectanglesAreNeverFiltered() throws {
    let vram = vramWithRows(edgeRow)
    let draw: (MetalRasterizer) -> Void = { r in
        drawingArea(r)
        var spr = Ps1GpuCommand()
        spr.kind = UInt8(PS1_GPU_DRAW_TEXTURED_RECTANGLE.rawValue)
        spr.opcode = 0x65                  // raw textured sprite
        spr.tpage = page16
        spr.x = 300; spr.y = 300; spr.w = 4; spr.h = 4
        spr.v.0 = Ps1GpuVertex(x: 0, y: 0, u: 0, v: 0, _pad: 0, color: 0)
        r.apply(spr)
    }
    guard let near = try MetalScaleHarness.frame(scale: 4, preload: vram, dither: .trueColor,
                                                 filter: .nearest, wantSidecar: true, draw),
          let bil = try MetalScaleHarness.frame(scale: 4, preload: vram, dither: .trueColor,
                                                filter: .bilinear, wantSidecar: true, draw)
    else { return }
    #expect(sidecarReds(near, size: 4).count > 100, "the sprite drew nothing")
    #expect(near.sidecar == bil.sidecar)
}
