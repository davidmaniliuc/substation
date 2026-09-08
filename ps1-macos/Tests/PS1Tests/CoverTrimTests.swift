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

/// `meanFloor` sits between the margins measured (mean 240-248) and the palest
/// artwork that must survive (mean 222). A cover that merely starts light is
/// artwork.
@Test func lightArtworkIsNotMistakenForAMargin() {
    let rect = CoverTrim.contentRect(of: banded(topMargin: 0, colour: (212, 216, 211)))
    #expect(rect.height == 100)
}

/// Paints `count` pixels of `row` at `value`, which is how both halves of the
/// uniformity rule are set up: JPEG ringing sits near the margin's own value,
/// artwork does not.
private func paint(_ rep: NSBitmapImageRep, row: Int, count: Int, value: UInt8) {
    let pixels = rep.bitmapData!
    for x in 0..<count {
        pixels[row * rep.bytesPerRow + x * 4] = value
        pixels[row * rep.bytesPerRow + x * 4 + 1] = value
        pixels[row * rep.bytesPerRow + x * 4 + 2] = value
    }
}

/// The bug this rule was rewritten for, twice. A margin row is never 100%
/// white — a few pixels carry JPEG ringing off the artwork beside them — so
/// requiring every pixel trimmed nothing at all on the covers that needed it,
/// and even a 97% rule left a residual row at 86-94%. Real margins measure
/// mean 240-248 with a deviation of 5-9, which this row reproduces.
@Test func aRowCarryingJpegRingingIsStillAMargin() {
    let rep = banded(topMargin: 5)
    paint(rep, row: 2, count: 6, value: 210)      // near the margin's own value

    #expect(CoverTrim.contentRect(of: rep).origin.y == 5)
}

/// The other half, and the reason whiteness alone cannot decide this: the four
/// Final Fantasy IX covers are genuinely pale at the top — 82-87% white, mean
/// 222 — and any fraction loose enough to catch a residual margin eats four
/// rows of them. Their deviation is 62-65, because artwork varies and a scan
/// margin does not.
@Test func paleArtworkIsKeptBecauseItIsNotUNIFORM() {
    let rep = banded(topMargin: 5)
    paint(rep, row: 2, count: 15, value: 30)      // dark detail in a pale row

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
