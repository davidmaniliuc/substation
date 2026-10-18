import AppKit
import Testing
@testable import PS1

/// A cover made of vertical bands, one per colour, each band as wide.
private func cover(_ colors: [NSColor], side: Int = 64) -> CGImage {
    let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let band = CGFloat(side) / CGFloat(colors.count)
    for (i, color) in colors.enumerated() {
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: CGFloat(i) * band, y: 0, width: band, height: CGFloat(side)))
    }
    return context.makeImage()!
}

private func hue(_ point: SIMD3<Float>) -> CGFloat {
    NSColor(srgbRed: CGFloat(point.x), green: CGFloat(point.y), blue: CGFloat(point.z), alpha: 1).hueComponent
}

/// The shader is handed six points whatever the cover holds: a one-colour
/// cover repeats its colour rather than leaving the array short.
@Test func aCoverPaletteAlwaysHasSixPoints() throws {
    let palette = try #require(BackdropPalette.fromCover(cover([.systemRed])))
    #expect(palette.points.count == 6)
    #expect(BackdropPalette.substation.points.count == 6)
}

/// Every colour is darkened so white text stays readable over it: no channel
/// of any point reaches the cover's own full brightness.
@Test func aCoverPaletteIsDarkened() throws {
    let palette = try #require(BackdropPalette.fromCover(cover([.white, .yellow, .cyan])))
    for point in palette.points {
        #expect(max(point.x, point.y, point.z) <= 0.5)
    }
}

/// A cover's distinct hues each reach the palette, not only its most
/// vivid one.
@Test func aCoverPaletteKeepsEachDistinctHue() throws {
    let red = NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)
    let blue = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1)
    let palette = try #require(BackdropPalette.fromCover(cover([red, blue])))
    let hues = palette.points.prefix(5).map(hue)
    #expect(hues.contains { abs($0 - red.hueComponent) < 0.05 || abs($0 - red.hueComponent) > 0.95 })
    #expect(hues.contains { abs($0 - blue.hueComponent) < 0.05 })
}
