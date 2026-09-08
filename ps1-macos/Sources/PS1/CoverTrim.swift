import AppKit
import Foundation

/// Removes the white scanning margin some covers in the collection carry.
///
/// Measured on the collection itself: `SCES-00344` (Crash Bandicoot PAL)
/// carries a margin on all of its top, bottom and right edges, `SCES-00967`
/// on its top and right, and `SLES-00132` (Doom) three rows along its bottom,
/// while Croc has none at all. It is in the source scans, not in anything this
/// app does to them, and against `GameTile`'s dark grid it reads as a bright
/// hairline on some tiles and not others.
///
/// The rule is UNIFORMITY, not whiteness, and the two earlier attempts here
/// both failed on that. Requiring every pixel in a row to be white trims
/// nothing at all: a margin row is 97-100% white, never 100%, because a
/// handful of pixels carry JPEG ringing off the artwork beside them. Loosening
/// that to "97% of pixels are white" then leaves a residual row on each edge
/// at 86-94%, and the fraction cannot be lowered to catch those, because the
/// four Final Fantasy IX covers are genuinely pale at the top and their
/// ARTWORK is 82-87% white — the two ranges overlap.
///
/// What separates them cleanly is how uniform the row is. Measured: the
/// residual margins run mean 240-248 with a standard deviation of 5-9, while
/// FF9's pale artwork is mean 222 with a deviation of 62-65. A scan margin is
/// nearly constant; artwork is not, however bright it is.
///
/// Trimmed on import rather than at draw time so it costs nothing per render,
/// and so a cover the player picked from their own disk gets the same
/// treatment as a downloaded one.
enum CoverTrim {
    /// A row's mean darkest-channel value must reach this. Margins measure
    /// 240-248 and the palest artwork that must survive measures 222.
    static let meanFloor = 235.0

    /// And its standard deviation must stay under this. Margins measure 5-9;
    /// FF9's pale artwork measures 62-65. Nothing observed lands between 25
    /// and 62, so the exact value here is not delicate — which is the point of
    /// choosing the axis that separates cleanly.
    static let deviationCeiling = 25.0

    /// At most this much of a side, so a cover that is legitimately pale at an
    /// edge loses a margin at worst and never its artwork. The measured
    /// margins are 1-7 pixels of a 500px side, so at most 1.4%; this leaves a
    /// wide margin of error over them while still bounding the damage.
    static let maxFraction = 0.1

    /// The rectangle worth keeping. Full-size when there is no margin, which
    /// is the common case.
    static func contentRect(of rep: NSBitmapImageRep) -> CGRect {
        let width = rep.pixelsWide, height = rep.pixelsHigh
        guard width > 0, height > 0 else { return .zero }

        let maxRows = Int(Double(height) * maxFraction)
        let maxColumns = Int(Double(width) * maxFraction)

        var top = 0
        while top < maxRows, isMargin(rep, row: top, width: width) { top += 1 }
        var bottom = height - 1
        while height - 1 - bottom < maxRows, bottom > top,
              isMargin(rep, row: bottom, width: width) { bottom -= 1 }

        var left = 0
        while left < maxColumns, isMargin(rep, column: left, height: height) { left += 1 }
        var right = width - 1
        while width - 1 - right < maxColumns, right > left,
              isMargin(rep, column: right, height: height) { right -= 1 }

        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    private static func isMargin(_ rep: NSBitmapImageRep, row: Int, width: Int) -> Bool {
        isMargin((0..<width).map { ($0, row) }, in: rep)
    }

    private static func isMargin(_ rep: NSBitmapImageRep, column: Int, height: Int) -> Bool {
        isMargin((0..<height).map { (column, $0) }, in: rep)
    }

    /// Bright AND flat. A 500px row is 500 reads, once, on import.
    private static func isMargin(_ points: [(Int, Int)], in rep: NSBitmapImageRep) -> Bool {
        var sum = 0.0, sumOfSquares = 0.0
        for (x, y) in points {
            let value = Double(darkestChannel(rep, x, y))
            sum += value
            sumOfSquares += value * value
        }
        let count = Double(points.count)
        let mean = sum / count
        // Clamped at zero because the variance of a constant row lands a hair
        // below it in floating point, and a negative square root is a NaN that
        // compares false against every threshold.
        let deviation = max(0, sumOfSquares / count - mean * mean).squareRoot()
        return mean >= meanFloor && deviation <= deviationCeiling
    }

    /// The darkest of the three channels, so a strong single-channel tint
    /// counts as colour rather than as white.
    private static func darkestChannel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Int {
        guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
        return Int(min(colour.redComponent, min(colour.greenComponent, colour.blueComponent)) * 255)
    }

    /// `rep` cropped to `contentRect`, or `rep` itself when there is nothing to
    /// crop — so the common case allocates nothing.
    static func trimmed(_ rep: NSBitmapImageRep) -> NSBitmapImageRep {
        let rect = contentRect(of: rep)
        guard rect.width > 0, rect.height > 0,
              Int(rect.width) != rep.pixelsWide || Int(rect.height) != rep.pixelsHigh,
              let source = rep.cgImage,
              let cropped = source.cropping(to: rect)
        else { return rep }
        return NSBitmapImageRep(cgImage: cropped)
    }
}
