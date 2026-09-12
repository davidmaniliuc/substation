import Testing
import Metal
@testable import PS1

/// Renders the real shader offscreen and reads the pixels back.
///
/// The bug this pins was invisible to every other kind of test: the shader
/// compiled, the pipeline built, and the scale math was right. Only the pixels
/// were wrong — the right and bottom letterbox bars were painted with a
/// stretched copy of the last texel column, because the vertex stage scaled
/// `position` for the letterbox while deriving `uv` from the UNSCALED vertex,
/// leaving those bars inside the oversized triangle.
private struct Rendered {
    let width: Int
    let height: Int
    let bgra: [UInt8]

    /// Returns (b, g, r) — the target is `.bgra8Unorm`.
    func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let o = (y * width + x) * 4
        return (bgra[o], bgra[o + 1], bgra[o + 2])
    }
}

private func makeVramTexture(_ device: MTLDevice, fill: UInt16) -> MTLTexture? {
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .r16Uint, width: 1024, height: 512, mipmapped: false)
    desc.usage = .shaderRead
    desc.storageMode = .managed
    guard let tex = device.makeTexture(descriptor: desc) else { return nil }
    var pixels = [UInt16](repeating: fill, count: 1024 * 512)
    pixels.withUnsafeBytes { buf in
        tex.replace(region: MTLRegionMake2D(0, 0, 1024, 512), mipmapLevel: 0,
                    withBytes: buf.baseAddress!, bytesPerRow: 1024 * 2)
    }
    return tex
}

private func makeSidecarTexture(_ device: MTLDevice,
                                fill: (UInt8, UInt8, UInt8, UInt8)) -> MTLTexture? {
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Uint, width: 1024, height: 512, mipmapped: false)
    desc.usage = .shaderRead
    desc.storageMode = .managed
    guard let tex = device.makeTexture(descriptor: desc) else { return nil }
    var bytes = [UInt8](repeating: 0, count: 1024 * 512 * 4)
    for i in 0..<(1024 * 512) {
        bytes[i * 4] = fill.0; bytes[i * 4 + 1] = fill.1
        bytes[i * 4 + 2] = fill.2; bytes[i * 4 + 3] = fill.3
    }
    bytes.withUnsafeBytes { buf in
        tex.replace(region: MTLRegionMake2D(0, 0, 1024, 512), mipmapLevel: 0,
                    withBytes: buf.baseAddress!, bytesPerRow: 1024 * 4)
    }
    return tex
}

/// Fills VRAM with a solid non-black colour so ANY picture texel is
/// distinguishable from a letterbox bar.
private func render(width: Int, height: Int,
                    depth24: Bool = false,
                    softwareDisplay: Bool = false,
                    vramFill: UInt16 = 0x7FFF,
                    sidecar: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)) throws -> Rendered? {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    guard let queue = device.makeCommandQueue() else { return nil }

    // The render texture keeps today's opaque white so every existing
    // letterbox assertion is unchanged; the shadow is pure red so a test can
    // tell which one the shader read.
    guard let vram = makeVramTexture(device, fill: vramFill),
          let shadow = makeVramTexture(device, fill: 0x001F),
          let side = makeSidecarTexture(device, fill: sidecar) else { return nil }

    var params = DisplayParams()
    params.width = 320
    params.height = 240
    params.enabled = 1
    params.depth24 = depth24 ? 1 : 0
    params.softwareDisplay = softwareDisplay ? 1 : 0
    (params.scaleX, params.scaleY) = letterboxScale(
        width: Double(width), height: Double(height))

    guard let out = try renderDisplayPass(
        device: device, queue: queue, vram: vram, shadow: shadow, sidecar: side,
        params: params, width: width, height: height) else { return nil }
    return Rendered(width: width, height: height, bgra: out)
}

@Test func pillarboxBarsAreBlackOnBOTHSides() throws {
    // 16:9: bars 12.5% of the width on each side, picture in the middle.
    guard let img = try render(width: 640, height: 360) else { return }
    let mid = 180

    #expect(img.pixel(0, mid) == (0, 0, 0))
    #expect(img.pixel(20, mid) == (0, 0, 0))
    // The regression: this used to be a smeared copy of the last texel column.
    #expect(img.pixel(639, mid) == (0, 0, 0))
    #expect(img.pixel(619, mid) == (0, 0, 0))
    // ...and the picture between them is still drawn.
    #expect(img.pixel(320, mid) != (0, 0, 0))
}

@Test func letterboxBarsAreBlackOnBOTHSides() throws {
    // 4:5: bars top and bottom.
    guard let img = try render(width: 480, height: 600) else { return }
    let mid = 240

    #expect(img.pixel(mid, 0) == (0, 0, 0))
    #expect(img.pixel(mid, 20) == (0, 0, 0))
    #expect(img.pixel(mid, 599) == (0, 0, 0))
    #expect(img.pixel(mid, 579) == (0, 0, 0))
    #expect(img.pixel(mid, 300) != (0, 0, 0))
}

/// The point of the aspect lock: at 4:3 the picture reaches all four edges.
@Test func aFourThreeTargetHasNoBarAtAll() throws {
    guard let img = try render(width: 640, height: 480) else { return }
    for (x, y) in [(0, 0), (639, 0), (0, 479), (639, 479), (320, 240)] {
        #expect(img.pixel(x, y) != (0, 0, 0))
    }
}

@Test func fifteenBppScansOutOfTheRenderTextureNotTheShadow() throws {
    guard let r = try render(width: 320, height: 240) else { return }
    // The render texture is opaque white, the shadow pure red. Anything but
    // white here means the 15bpp branch is reading the wrong texture.
    let (b, g, rr) = r.pixel(160, 120)
    #expect(b > 240 && g > 240 && rr > 240)
}

@Test func twentyFourBppScansOutOfTheShadowPermanently() throws {
    guard let r = try render(width: 320, height: 240, depth24: true) else { return }
    // 24bpp reconstructs pixels by byte-packing across ADJACENT 16-bit words,
    // arithmetic that N x N replication in the scaled texture destroys. FMV is
    // uploaded through A0 and was never upscaled geometry, so it stays on the
    // shadow forever. Croc and Silent Hill both depend on this.
    //
    // The shadow is 0x001F in every word, so the packed bytes are 1F 00 1F 00:
    // r = 0x1F, g = 0x00, b = 0x1F.
    let (b, g, rr) = r.pixel(160, 120)
    #expect(rr == 0x1F)
    #expect(g == 0x00)
    #expect(b == 0x1F)
}

@Test func theSoftwareDisplaySwitchRoutesFifteenBppToTheShadow() throws {
    guard let r = try render(width: 320, height: 240, softwareDisplay: true) else { return }
    // PS1_SOFTWARE_DISPLAY=1: the debug seam for A/B-ing a suspect frame
    // against the software rasterizer without a rebuild. Not a mode, and not
    // a user-facing setting -- D2 owns any of those.
    //
    // The shadow is 0x001F: red 5 bits set, green and blue clear.
    let (b, g, rr) = r.pixel(160, 120)
    #expect(rr > 240)
    #expect(g < 16)
    #expect(b < 16)
}

@Test func theDisplayPrefersTheSidecarWherePresent() throws {
    // Alpha 255: the sidecar holds a real eight-bit colour and the display
    // shows it rather than the five-bit VRAM pixel beneath. The render
    // texture is white, so anything but this exact triple means the fallback
    // ran instead.
    guard let r = try render(width: 320, height: 240,
                             sidecar: (10, 20, 30, 255)) else { return }
    let (b, g, rr) = r.pixel(160, 120)
    #expect(rr == 10)
    #expect(g == 20)
    #expect(b == 30)
}

@Test func theDisplayFallsBackToVramWhereTheSidecarIsAbsent() throws {
    // Alpha 0: whatever the sidecar's colour bytes happen to hold is ignored.
    // Every invalidation degrades to today's picture, which is the whole
    // reason presence is a channel rather than a dirty rectangle.
    guard let r = try render(width: 320, height: 240,
                             sidecar: (10, 20, 30, 0)) else { return }
    let (b, g, rr) = r.pixel(160, 120)
    #expect(rr > 240 && g > 240 && b > 240)
}

@Test func anAbsentPixelExpandsByReplicationJustLikeASidecarPixel() throws {
    // The fallback and the sidecar must be the SAME expansion, or the boundary
    // of an invalidated rect shows as a seam — one level of difference along a
    // hard edge is exactly the kind of artifact this feature exists to remove.
    //
    // Red = 3: `c << 3 | c >> 2` is 24, which is what the sidecar would hold
    // for that pixel. The old `c / 31.0` is 24.67 and rounds to 25.
    guard let r = try render(width: 320, height: 240, vramFill: 0x0003) else { return }
    let (b, g, rr) = r.pixel(160, 120)
    #expect(rr == 24)
    #expect(g == 0)
    #expect(b == 0)
}

@Test func twentyFourBppIgnoresTheSidecar() throws {
    // FMV scans out of the 1x shadow permanently: it byte-packs across
    // adjacent 16-bit words, arithmetic N x N replication destroys. A present
    // sidecar must not divert it — Croc and Silent Hill both depend on this.
    guard let r = try render(width: 320, height: 240, depth24: true,
                             sidecar: (10, 20, 30, 255)) else { return }
    let (b, g, rr) = r.pixel(160, 120)
    #expect(rr == 0x1F)
    #expect(g == 0x00)
    #expect(b == 0x1F)
}

@Test func theSoftwareDisplaySeamIgnoresTheSidecar() throws {
    // PS1_SOFTWARE_DISPLAY exists to A/B a suspect frame against the software
    // rasterizer. A sidecar read here would be comparing the new path against
    // itself.
    guard let r = try render(width: 320, height: 240, softwareDisplay: true,
                             sidecar: (10, 20, 30, 255)) else { return }
    let (b, g, rr) = r.pixel(160, 120)
    #expect(rr > 240)
    #expect(g < 16)
    #expect(b < 16)
}
