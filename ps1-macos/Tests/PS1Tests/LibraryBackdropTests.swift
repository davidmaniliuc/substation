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

/// The shader is handed six points whatever the cover holds, one per sixth
/// of the art.
@Test func aCoverPaletteAlwaysHasSixPoints() throws {
    let palette = try #require(BackdropPalette.fromCover(cover([.systemRed])))
    #expect(palette.points.count == 6)
    #expect(BackdropPalette.substation.points.count == 6)
}

/// Every colour is muted, as Apple Music mutes an album's: at most half
/// saturated, and never so bright that white text is lost or so dark that
/// the backdrop is a hole, however bright or dark the cover.
@Test func aCoverPaletteIsMuted() throws {
    for colors: [NSColor] in [[.white, .yellow, .cyan], [.black], [.systemRed, .black]] {
        let palette = try #require(BackdropPalette.fromCover(cover(colors)))
        for point in palette.points {
            let color = NSColor(srgbRed: CGFloat(point.x), green: CGFloat(point.y), blue: CGFloat(point.z), alpha: 1)
            #expect(color.saturationComponent <= 0.51)
            #expect((0.19 ... 0.86).contains(color.brightnessComponent))
        }
    }
}

/// A cover's light and shade survive the averaging: a cover half white and
/// half black spans the whole brightness range, not one flat grey.
@Test func aCoverPaletteKeepsItsLightAndShade() throws {
    let palette = try #require(BackdropPalette.fromCover(cover([.white, .black])))
    let brightness = palette.points.map { max($0.x, $0.y, $0.z) }
    #expect(try #require(brightness.max()) - #require(brightness.min()) > 0.5)
}

/// A cover's distinct hues each reach the palette: its regions are
/// averaged apart, not into one colour.
@Test func aCoverPaletteKeepsEachDistinctHue() throws {
    let red = NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)
    let blue = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1)
    let palette = try #require(BackdropPalette.fromCover(cover([red, blue])))
    let hues = palette.points.map(hue)
    #expect(hues.contains { abs($0 - red.hueComponent) < 0.05 || abs($0 - red.hueComponent) > 0.95 })
    #expect(hues.contains { abs($0 - blue.hueComponent) < 0.05 })
}
