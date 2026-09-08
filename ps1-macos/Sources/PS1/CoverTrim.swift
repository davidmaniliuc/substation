import AppKit
import Foundation

/// Removes the white scanning margin some covers in the collection carry.
///
/// Measured on the collection itself, with the whole-row rule below: the PAL
/// Crash covers carry theirs on the BOTTOM and RIGHT — `SCES-00344` 5 rows and
/// 4 columns, `SCES-00967` 4 top, 7 bottom and 7 right — while Croc and Doom
/// have none at all. A single-column probe reports the same files as having a
/// band across the top instead; only a whole-row rule locates a margin. It is
/// in the source scans, not in anything this app does to them, and against
/// `GameTile`'s dark grid it reads as a bright hairline on some tiles and not
/// others.
///
/// Trimmed on import rather than at draw time so it costs nothing per render,
/// and so a cover the player picked from their own disk gets the same
/// treatment as a downloaded one.
enum CoverTrim {
    /// A pixel counts as margin when its DARKEST channel is still this bright.
    /// 236 rather than 244 because the palest margin pixels measured run to
    /// 247,252,240, and rather than 210 because the palest artwork against
    /// them is 212,216,211 — the two are 24 apart and this sits between them.
    static let whiteFloor = 236

    /// At most this much of a side, so a cover that is legitimately pale at an
    /// edge loses a margin at worst and never its artwork. The measured margins
    /// are 4-7 pixels of a 500px side, so at most 1.4%; this leaves a wide
    /// margin of error over them while still bounding the damage.
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

    /// Every pixel, not a sample: a row carrying one dark pixel is artwork,
    /// and a scan's margin is uniform by construction. A 500px row is 500
    /// reads, once, on import.
    private static func isMargin(_ rep: NSBitmapImageRep, row: Int, width: Int) -> Bool {
        for x in 0..<width where !isWhite(rep, x, row) { return false }
        return true
    }

    private static func isMargin(_ rep: NSBitmapImageRep, column: Int, height: Int) -> Bool {
        for y in 0..<height where !isWhite(rep, column, y) { return false }
        return true
    }

    private static func isWhite(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
        guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
        let darkest = min(colour.redComponent, min(colour.greenComponent, colour.blueComponent))
        return Int(darkest * 255) >= whiteFloor
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
