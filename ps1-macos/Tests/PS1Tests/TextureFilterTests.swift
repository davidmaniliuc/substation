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

/// A triangle with explicit vertices and texcoords, for mappings
/// `texturedTriangle` cannot express (turned on its side, mirrored).
private func mappedTriangle(_ xy: [(Int16, Int16)], _ uv: [(UInt8, UInt8)],
                            rw: (Int32, Int32, Int32) = (0, 0, 0))
    -> (MetalRasterizer) -> Void {
    return { r in
        drawingArea(r)
        var tri = Ps1GpuCommand()
        tri.kind = UInt8(PS1_GPU_DRAW_TEXTURED_TRIANGLE.rawValue)
        tri.opcode = 0x25
        tri.tpage = page16
        tri.v.0 = Ps1GpuVertex(x: xy[0].0, y: xy[0].1, u: uv[0].0, v: uv[0].1, _pad: 0, color: 0)
        tri.v.1 = Ps1GpuVertex(x: xy[1].0, y: xy[1].1, u: uv[1].0, v: uv[1].1, _pad: 0, color: 0)
        tri.v.2 = Ps1GpuVertex(x: xy[2].0, y: xy[2].1, u: uv[2].0, v: uv[2].1, _pad: 0, color: 0)
        tri.v.0.rw = rw.0; tri.v.1.rw = rw.1; tri.v.2.rw = rw.2
        r.apply(tri)
    }
}

/// A textured rectangle at (300, 300), `w` x `h` px, texcoord origin (u0, v0).
private func texturedRectangle(opcode: UInt8 = 0x65, tpage: UInt16 = page16,
                               u0: UInt8 = 0, v0: UInt8 = 0, w: Int32 = 4, h: Int32 = 4,
                               color: UInt32 = 0, transparent: UInt8 = 0)
    -> (MetalRasterizer) -> Void {
    return { r in
        drawingArea(r)
        var spr = Ps1GpuCommand()
        spr.kind = UInt8(PS1_GPU_DRAW_TEXTURED_RECTANGLE.rawValue)
        spr.opcode = opcode
        spr.tpage = tpage
        spr.value = color
        spr.transparent = transparent
        spr.x = 300; spr.y = 300; spr.w = w; spr.h = h
        spr.v.0 = Ps1GpuVertex(x: 0, y: 0, u: u0, v: v0, _pad: 0, color: 0)
        r.apply(spr)
    }
}

/// The distinct present sidecar reds of `draw` under one pair of settings.
private func distinctReds(_ draw: @escaping (MetalRasterizer) -> Void, vram: [UInt16],
                          texture: TextureFilter, sprite: TextureFilter) throws -> Int? {
    guard let f = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                              filter: texture, spriteFilter: sprite,
                                              wantSidecar: true, draw) else { return nil }
    return Set(sidecarReds(f)).count
}

/// Every PRESENT sidecar pixel's (red, green, blue) inside the box.
private func sidecarPixels(_ f: MetalScaleHarness.Frame, size: Int = 128)
    -> [(r: UInt8, g: UInt8, b: UInt8)] {
    guard let side = f.sidecar else { return [] }
    var pixels: [(r: UInt8, g: UInt8, b: UInt8)] = []
    let s = f.scale
    for y in (300 * s)..<((300 + size) * s) {
        for x in (300 * s)..<((300 + size) * s) {
            let i = y * f.width + x
            if side[i * 4 + 3] == 255 { pixels.append((side[i * 4], side[i * 4 + 1], side[i * 4 + 2])) }
        }
    }
    return pixels
}

/// Every PRESENT sidecar pixel's red byte inside the triangle's box.
private func sidecarReds(_ f: MetalScaleHarness.Frame, size: Int = 128) -> [UInt8] {
    sidecarPixels(f, size: size).map(\.r)
}

/// Red 1 -> red 31 -> red 31: a hard edge one texel wide, magnified 64x.
private let edgeRow: [UInt16] = [0x0001, 0x001F, 0x001F, 0x001F]

// MARK: - VRAM never moves

@Test func theCorpusRendersIdenticalVramUnderEverySetting() throws {
    // THE gate. Every fixture that exists, every frame, two dither modes (a
    // dithering one, since the VRAM path there carries the offset) and two
    // scales (3 because `/ s` is a shift at every power of two), and every
    // combination of the two settings against Nearest/Nearest.
    // `tr1-usa-v1-1-pgxp` is the one that carries perspective texcoords.
    let corpus = ["synthetic-primitives", "synthetic-movers", "silent-hill-usa", "tr1-usa-v1-1",
                  "tr1-usa-v1-1-pgxp"]
    let settings: [(TextureFilter, TextureFilter)] =
        [(.nearest, .nearest), (.bilinear, .nearest), (.nearest, .bilinear), (.bilinear, .bilinear)]
    for name in corpus where generatedFixtureExists(name) {
        for dither in [DitherMode.native, .trueColor] {
            for scale in [1, 3] {
                guard let device = MTLCreateSystemDefaultDevice(),
                      let queue = device.makeCommandQueue() else { return }
                var vrams: [MetalVram] = []
                var rasterizers: [MetalRasterizer] = []
                for (texture, sprite) in settings {
                    guard let vram = MetalVram(device: device, queue: queue, scale: scale) else { return }
                    let r = try MetalRasterizer(vram: vram)
                    r.ditherMode = dither
                    r.textureFilter = texture
                    r.spriteFilter = sprite
                    vrams.append(vram)
                    rasterizers.append(r)
                }
                let file = try FixtureFile(contentsOf: FixtureFile.url(named: name))
                withExtendedLifetime(file) {
                    for i in 0..<file.frames.count {
                        for r in rasterizers {
                            r.beginFrame(payload: file.payload(for: i))
                            for cmd in file.records(for: i) { r.apply(cmd) }
                            r.endFrame()
                        }
                        let reference = vrams[0].readback()
                        for (k, vram) in vrams.enumerated().dropFirst() {
                            #expect(vram.readback() == reference,
                                    Comment(rawValue: "\(name) \(dither) @\(scale)x frame \(i) "
                                            + "\(settings[k]): VRAM moved"))
                        }
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
    // texel 1 a HOLE between two bright ones, mapped u 0..2 so the hole lies
    // INSIDE the UV limits and only its zero weight keeps it out. Filtering it
    // as black darkens every pixel beside a cut-out.
    let draw = texturedTriangle(u0: 0, u1: 2)
    let vram = vramWithRows([0x001F, 0x0000, 0x001F])
    guard let bil = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                                filter: .bilinear, wantSidecar: true, draw)
    else { return }
    let reds = sidecarReds(bil)
    #expect(reds.count > 1000, "the triangle drew nothing")
    #expect(reds.allSatisfy { $0 == 255 }, "a hole was filtered in: min red \(reds.min() ?? 0)")
}

@Test func uvLimitsKeepAtlasNeighboursOut() throws {
    // An atlas cell mapped u/v 4..8, all blue, with RED in the column and row
    // on BOTH sides of it. A centred sample at U < 4.5 reaches u = 3 unless
    // clamped, and one past U = 7.5 reaches u = 8: the PS1 never draws a
    // primitive's right/bottom texel, so the high limit is max - 1. Magnified
    // at 1x and mapped 1:1 at 4x and 8x, where the last native pixel's
    // subtexel centres lie past 7.5.
    var vram = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    for y in 0..<12 {
        for u in 0..<12 {
            let edge = u == 3 || y == 3 || u == 8 || y == 8
            vram[y * w + pageX + u] = edge ? 0x001F : 0x7C00
        }
    }
    for (size, scale) in [(128, 1), (4, 4), (4, 8)] {
        let draw = texturedTriangle(u0: 4, u1: 8, v0: 4, v1: 8, size: Int16(size))
        guard let bil = try MetalScaleHarness.frame(scale: scale, preload: vram, dither: .trueColor,
                                                    filter: .bilinear, wantSidecar: true, draw)
        else { return }
        let reds = sidecarReds(bil, size: size)
        #expect(reds.count > 50, "@\(scale)x: the triangle drew nothing")
        #expect(reds.allSatisfy { $0 == 0 },
                "@\(scale)x: an atlas neighbour bled in: max red \(reds.max() ?? 0)")
    }
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

@Test func texturedRectanglesFollowTheSpriteSetting() throws {
    let vram = vramWithRows(edgeRow)
    let draw = texturedRectangle()
    guard let near = try MetalScaleHarness.frame(scale: 4, preload: vram, dither: .trueColor,
                                                 filter: .nearest, wantSidecar: true, draw),
          let textureOnly = try MetalScaleHarness.frame(scale: 4, preload: vram, dither: .trueColor,
                                                        filter: .bilinear, spriteFilter: .nearest,
                                                        wantSidecar: true, draw),
          let spriteOn = try MetalScaleHarness.frame(scale: 4, preload: vram, dither: .trueColor,
                                                     filter: .nearest, spriteFilter: .bilinear,
                                                     wantSidecar: true, draw)
    else { return }
    #expect(sidecarReds(near, size: 4).count > 100, "the sprite drew nothing")
    #expect(near.sidecar == textureOnly.sidecar, "Texture Filtering reached a rectangle")
    #expect(Set(sidecarReds(spriteOn, size: 4)).count > 2,
            "Sprite Texture Filtering did not reach a rectangle")
    #expect(near.scaled == spriteOn.scaled, "VRAM moved")
}

// MARK: - Which setting applies

@Test func aScreenAlignedTriangleFollowsTheSpriteSetting() throws {
    // `texturedTriangle` maps u along x and v along y: a 2D quad's half.
    let draw = texturedTriangle(u0: 0, u1: 2)
    let vram = vramWithRows(edgeRow)
    guard let spriteOff = try distinctReds(draw, vram: vram, texture: .bilinear, sprite: .nearest),
          let spriteOn = try distinctReds(draw, vram: vram, texture: .nearest, sprite: .bilinear)
    else { return }
    #expect(spriteOff == 2, "Texture Filtering alone filtered a sprite: \(spriteOff) reds")
    #expect(spriteOn > 16, "Sprite Texture Filtering did not reach a sprite: \(spriteOn) reds")
}

@Test func aTextureTurnedOnItsSideFollowsTheTextureSetting() throws {
    // u runs DOWN the screen and v across it: du/dy != 0, so not a sprite.
    let draw = mappedTriangle([(300, 300), (428, 300), (300, 428)], [(0, 0), (0, 2), (2, 0)])
    let vram = vramWithRows(edgeRow)
    guard let textureOn = try distinctReds(draw, vram: vram, texture: .bilinear, sprite: .nearest),
          let spriteOn = try distinctReds(draw, vram: vram, texture: .nearest, sprite: .bilinear)
    else { return }
    #expect(textureOn > 16, "Texture Filtering did not reach a 3D mapping: \(textureOn) reds")
    #expect(spriteOn == 2, "Sprite Texture Filtering filtered a 3D mapping: \(spriteOn) reds")
}

@Test func aTriangleWithDepthFollowsTheTextureSettingEvenWhenScreenAligned() throws {
    // Review Focus 1. Screen-aligned, but PGXP gave all three vertices a
    // depth: DuckStation's "is_3d" wins over the derivative test. No
    // perspective flag, so the texcoords stay affine and only the class moves.
    let draw = texturedTriangle(u0: 0, u1: 2, rw: (65536, 65536, 65536))
    let vram = vramWithRows(edgeRow)
    guard let textureOn = try distinctReds(draw, vram: vram, texture: .bilinear, sprite: .nearest),
          let spriteOn = try distinctReds(draw, vram: vram, texture: .nearest, sprite: .bilinear)
    else { return }
    #expect(textureOn > 16, "a depth-carrying triangle ignored Texture Filtering")
    #expect(spriteOn == 2, "a depth-carrying triangle was treated as a sprite")
}

@Test func aMirroredScreenAlignedTriangleIsStillASprite() throws {
    // Review Focus 2. u runs right-to-left (du/dx < 0), as a sprite drawn
    // facing the other way: still du/dy == 0 and dv/dx == 0.
    let draw = mappedTriangle([(300, 300), (428, 300), (300, 428)], [(2, 0), (0, 0), (2, 2)])
    let vram = vramWithRows(edgeRow)
    guard let spriteOff = try distinctReds(draw, vram: vram, texture: .bilinear, sprite: .nearest),
          let spriteOn = try distinctReds(draw, vram: vram, texture: .nearest, sprite: .bilinear)
    else { return }
    #expect(spriteOff == 2, "a mirrored 2D triangle followed Texture Filtering")
    #expect(spriteOn > 16, "a mirrored 2D triangle ignored Sprite Texture Filtering")
}

// MARK: - Sprites

@Test func aRectangleAtOneXFiltersToItself() throws {
    // One texel per native pixel: at 1x every subtexel centre IS a texel
    // centre, so Bilinear reproduces Nearest exactly.
    let vram = vramWithRows(edgeRow)
    let draw = texturedRectangle()
    guard let near = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                                 filter: .nearest, wantSidecar: true, draw),
          let bil = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                                filter: .nearest, spriteFilter: .bilinear,
                                                wantSidecar: true, draw)
    else { return }
    #expect(sidecarReds(near, size: 4).count == 16, "the sprite drew nothing")
    #expect(near.sidecar == bil.sidecar)
}

@Test func aUniformSpriteFiltersToItselfInEveryMode() throws {
    // Modulated (opcode 0x64) by a five-bit colour, as every sprite is.
    let vram = vramWithRows([UInt16](repeating: 0x2D6B, count: 4))
    let draw = texturedRectangle(opcode: 0x64, color: 0x0000_4210)
    for dither in DitherMode.allCases {
        guard let near = try MetalScaleHarness.frame(scale: 4, preload: vram, dither: dither,
                                                     filter: .nearest, wantSidecar: true, draw),
              let bil = try MetalScaleHarness.frame(scale: 4, preload: vram, dither: dither,
                                                    filter: .nearest, spriteFilter: .bilinear,
                                                    wantSidecar: true, draw)
        else { return }
        #expect(sidecarReds(near, size: 4).count > 100, "\(dither): the sprite drew nothing")
        #expect(near.sidecar == bil.sidecar, "\(dither): a uniform sprite filtered to something else")
    }
}

@Test func aRectangleNeverFiltersPastItsWrapSegment() throws {
    // Review Focus 3. u0 = 250, 12 wide: unwrapped texels 250..261, i.e.
    // segment 0 (250..255) then segment 1 (0..5) after the wrap. Segment 0 is
    // BLUE and segment 1 GREEN, so a sample that crosses the seam (255 with 0,
    // which only an unsegmented limit allows) mixes the two. RED sits at 249
    // (below the first segment), at 6 (past the last column), in row 4 (past
    // the last row of a 4-tall sprite) and on the ADJACENT page (256..263),
    // which an unwrapped read would reach.
    var vram = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    for y in 0..<8 {
        for u in 0..<256 {
            var texel: UInt16 = 0x001F
            if y < 4 {
                if u >= 250 { texel = 0x7C00 } else if u <= 5 { texel = 0x03E0 }
            }
            vram[y * w + pageX + u] = texel
        }
        for u in 256..<264 { vram[y * w + pageX + u] = 0x001F }
    }
    let draw = texturedRectangle(u0: 250, w: 12)
    for scale in [4, 8] {
        guard let bil = try MetalScaleHarness.frame(scale: scale, preload: vram, dither: .trueColor,
                                                    filter: .nearest, spriteFilter: .bilinear,
                                                    wantSidecar: true, draw)
        else { return }
        let pixels = sidecarPixels(bil, size: 12)
        #expect(pixels.count > 100, "@\(scale)x: the sprite drew nothing")
        #expect(pixels.allSatisfy { $0.r == 0 }, "@\(scale)x: a texel outside the sprite bled in")
        #expect(pixels.allSatisfy { $0.g == 0 || $0.b == 0 },
                "@\(scale)x: a sample crossed the wrap seam")
    }
}

@Test func aSpriteHoleDrawsNoFringe() throws {
    // texel 1 is a HOLE between two bright texels; at 4x every filtered
    // subtexel beside it must stay at full red.
    let vram = vramWithRows([0x001F, 0x0000, 0x001F, 0x001F])
    let draw = texturedRectangle()
    guard let bil = try MetalScaleHarness.frame(scale: 4, preload: vram, dither: .trueColor,
                                                filter: .nearest, spriteFilter: .bilinear,
                                                wantSidecar: true, draw)
    else { return }
    let reds = sidecarReds(bil, size: 4)
    #expect(reds.count > 100, "the sprite drew nothing")
    #expect(reds.allSatisfy { $0 == 255 }, "a hole was filtered in: min red \(reds.min() ?? 0)")
}

@Test func aSemiTransparentFilteredSpriteBlendsTheFilteredColour() throws {
    // Review Focus 4. Raw, semi-transparent (opcode 0x67), STP-set texels,
    // mode 1 (add) over a dark red fill, in a dithering mode.
    let vram = vramWithRows([0x8001, 0x801F, 0x801F, 0x801F])
    let draw: (MetalRasterizer) -> Void = { r in
        drawingArea(r)
        var fill = Ps1GpuCommand()
        fill.kind = UInt8(PS1_GPU_FILL_RECT.rawValue)
        fill.value = 0x0008                // dark red background, 15-bit
        fill.x = 288; fill.y = 288; fill.w = 32; fill.h = 32
        r.apply(fill)
        var latch = Ps1GpuCommand()
        latch.kind = UInt8(PS1_GPU_LATCH_TEXPAGE.rawValue)
        latch.tpage = page16 | (1 << 5)
        r.apply(latch)
        texturedRectangle(opcode: 0x67, tpage: page16 | (1 << 5), transparent: 1)(r)
    }
    for dither in [DitherMode.off, .trueColor] {
        guard let bil = try MetalScaleHarness.frame(scale: 4, preload: vram, dither: dither,
                                                    filter: .nearest, spriteFilter: .bilinear,
                                                    wantSidecar: true, draw)
        else { return }
        #expect(Set(sidecarReds(bil, size: 4)).count > 2,
                "\(dither): the blend used the nearest texel")
    }
}

@Test func aWindowedSpriteFiltersInsideItsWindow() throws {
    // Review Focus 5. GP0(E2) mask 0x1F on both axes: every coordinate wraps
    // into 0..7. Blue inside that window, red outside it, and a 20 x 20
    // sprite tiles the window more than twice.
    var vram = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    for y in 0..<24 {
        for u in 0..<24 { vram[y * w + pageX + u] = (u < 8 && y < 8) ? 0x7C00 : 0x001F }
    }
    let draw: (MetalRasterizer) -> Void = { r in
        var win = Ps1GpuCommand()
        win.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        win.opcode = 0xE2
        win.value = 0x1F | (0x1F << 5)
        r.apply(win)
        texturedRectangle(w: 20, h: 20)(r)
    }
    guard let bil = try MetalScaleHarness.frame(scale: 4, preload: vram, dither: .trueColor,
                                                filter: .nearest, spriteFilter: .bilinear,
                                                wantSidecar: true, draw)
    else { return }
    let reds = sidecarReds(bil, size: 20)
    #expect(reds.count > 1000, "the sprite drew nothing")
    #expect(reds.allSatisfy { $0 == 0 }, "a texel outside the window bled in")
}
