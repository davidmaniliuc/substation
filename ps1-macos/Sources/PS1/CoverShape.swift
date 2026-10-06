import AppKit

/// Whether a cover is a flat scan or an object on a transparent background.
///
/// The 3D source draws a jewel case at an angle inside a transparent square,
/// so its corners are empty. Framed the way `GameTile` frames a flat scan
/// (rounded clip, hairline, selection ring, all on the square) the empty part
/// shows the grid's black inside that frame and reads as a dark block beside
/// and under the case.
enum CoverShape {
    /// Any corner short of fully opaque. A flat scan is opaque edge to edge,
    /// trimmed of its margin on import, so a transparent corner can only be
    /// a cut-out. `hasAlpha` cannot decide it: every stored cover has an
    /// alpha channel, because the downscale draws into a premultiplied
    /// context whatever the source was.
    static func isCutOut(_ rep: NSBitmapImageRep) -> Bool {
        let right = rep.pixelsWide - 1, bottom = rep.pixelsHigh - 1
        guard rep.hasAlpha, right >= 0, bottom >= 0 else { return false }
        return [(0, 0), (right, 0), (0, bottom), (right, bottom)].contains { x, y in
            (rep.colorAt(x: x, y: y)?.alphaComponent ?? 1) < 1
        }
    }

    static func isCutOut(_ image: NSImage) -> Bool {
        image.representations.contains { ($0 as? NSBitmapImageRep).map(isCutOut) ?? false }
    }
}
