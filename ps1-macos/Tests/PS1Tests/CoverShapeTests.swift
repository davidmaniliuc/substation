import Testing
import AppKit
@testable import PS1

/// A solid opaque square, with the bottom-right `cutOut` pixels made fully
/// transparent: the shape of a 3D cover, whose case leaves the corner empty.
private func cover(size: Int = 64, cutOut: Int = 0) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let pixels = rep.bitmapData!
    for y in 0..<size {
        for x in 0..<size {
            let o = y * rep.bytesPerRow + x * 4
            let empty = x >= size - cutOut && y >= size - cutOut
            pixels[o] = empty ? 0 : 40
            pixels[o + 1] = empty ? 0 : 80
            pixels[o + 2] = empty ? 0 : 120
            pixels[o + 3] = empty ? 0 : 255
        }
    }
    return rep
}

/// Every stored cover carries an alpha channel (the downscale draws into a
/// premultiplied context), so `hasAlpha` cannot be the test: a flat scan has
/// one too and must keep its square frame.
@Test func aFlatScanWithAnAlphaChannelIsNotACutOut() {
    let rep = cover()
    #expect(rep.hasAlpha)
    #expect(!CoverShape.isCutOut(rep))
}

@Test func aCoverWithATransparentCornerIsACutOut() {
    #expect(CoverShape.isCutOut(cover(cutOut: 8)))
}
