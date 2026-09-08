import Testing
import Foundation
import AppKit
@testable import PS1

/// An image with a white band of `topMargin` rows over a solid colour.
private func banded(topMargin: Int, size: Int = 100,
                    colour: (UInt8, UInt8, UInt8) = (20, 30, 100)) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let pixels = rep.bitmapData!
    for y in 0..<size {
        for x in 0..<size {
            let o = y * rep.bytesPerRow + x * 4
            let white = y < topMargin
            pixels[o] = white ? 255 : colour.0
            pixels[o + 1] = white ? 254 : colour.1
            pixels[o + 2] = white ? 255 : colour.2
            pixels[o + 3] = 255
        }
    }
    return rep
}

/// The measured case: the PAL Crash covers carry 4-7 white rows or columns on
/// an edge of their scan, which read as a bright hairline against the grid. A
/// band on the top is that same problem mirrored, and the easiest to assert.
@Test func aWhiteScanningMarginIsTrimmed() {
    let rect = CoverTrim.contentRect(of: banded(topMargin: 7))
    #expect(rect.origin.y == 7)
    #expect(rect.height == 93)
    #expect(rect.origin.x == 0)
    #expect(rect.width == 100)
}

@Test func aCoverWithNoMarginIsLeftExactlyAsItIs() {
    let rep = banded(topMargin: 0)
    #expect(CoverTrim.contentRect(of: rep) == CGRect(x: 0, y: 0, width: 100, height: 100))
    // And the same object comes back, so the common case allocates nothing.
    #expect(CoverTrim.trimmed(rep) === rep)
}

/// The threshold sits between the palest artwork row measured (212,216,211)
/// and the darkest margin row (247,252,240). A cover whose artwork merely
/// starts light must survive.
@Test func lightArtworkIsNotMistakenForAMargin() {
    let rect = CoverTrim.contentRect(of: banded(topMargin: 0, colour: (212, 216, 211)))
    #expect(rect.height == 100)
}

/// A row is margin only if EVERY pixel in it is; a single dark pixel is
/// artwork reaching the edge.
@Test func aRowWithOneDarkPixelIsNotAMargin() {
    let rep = banded(topMargin: 5)
    let pixels = rep.bitmapData!
    pixels[2 * rep.bytesPerRow + 40 * 4] = 10      // one dark pixel in row 2
    pixels[2 * rep.bytesPerRow + 40 * 4 + 1] = 10
    pixels[2 * rep.bytesPerRow + 40 * 4 + 2] = 10

    #expect(CoverTrim.contentRect(of: rep).origin.y == 2)
}

/// The cap is what stops a pale cover being eaten: at most a tenth of a side
/// comes off, so a mostly-white design loses a margin at worst, never its art.
@Test func anAllWhiteCoverKeepsNineTenthsOfItself() {
    let rect = CoverTrim.contentRect(of: banded(topMargin: 100))
    #expect(rect.origin.y == 10)
    #expect(rect.height == 80)   // ten off the top, ten off the bottom
}

@Test func trimmingProducesAnImageOfTheContentSize() {
    let trimmed = CoverTrim.trimmed(banded(topMargin: 7))
    #expect(trimmed.pixelsHigh == 93)
    #expect(trimmed.pixelsWide == 100)
}
