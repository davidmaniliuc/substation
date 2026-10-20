import AppKit
import SwiftUI

/// The colours one animated backdrop drifts between, as sRGB triples: the
/// shader's `colors` argument, one point each.
struct BackdropPalette: Hashable {
    let points: [SIMD3<Float>]

    /// The console's logo colours and two near-blacks, muted as a cover's
    /// are: Substation's colours until a game with a cover is selected.
    static let substation = BackdropPalette(points: HSB.muted([
        [0.50, 0.08, 0.12], [0.55, 0.40, 0.04], [0.03, 0.35, 0.22],
        [0.06, 0.16, 0.50], [0.02, 0.02, 0.04], [0.03, 0.03, 0.10],
    ].map(HSB.init(srgb:))).map(\.srgb))

    /// Near-grey with a hint of blue: the Dark theme.
    static let graphite = BackdropPalette(points: [
        [0.10, 0.10, 0.12], [0.20, 0.21, 0.24], [0.14, 0.16, 0.22],
        [0.26, 0.25, 0.27], [0.03, 0.03, 0.04], [0.12, 0.13, 0.16],
    ])

    /// Graphite's pale variant, the same cool greys near white: the Light
    /// theme, drawn without the dim so dark text sits on it.
    static let graphiteLight = BackdropPalette(points: [
        [0.93, 0.93, 0.95], [0.84, 0.85, 0.88], [0.88, 0.90, 0.94],
        [0.81, 0.80, 0.82], [0.97, 0.97, 0.98], [0.87, 0.88, 0.91],
    ])

    var floats: [Float] { points.flatMap { [$0.x, $0.y, $0.z] } }

    /// Six colours from a cover, taken the way Apple Music takes an album's:
    /// the average of each sixth of the art (three across, two down), with
    /// the saturation pulled down and the brightness pulled to the middle,
    /// so the backdrop reads as the cover's light rather than its paint. Nil
    /// only for an image that cannot be drawn.
    static func fromCover(_ image: CGImage) -> BackdropPalette? {
        let (columns, rows, block) = (3, 2, 8)
        let (width, height) = (columns * block, rows * block)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        func average(column: Int, row: Int) -> HSB {
            var sum = SIMD3<Float>()
            for y in row * block ..< (row + 1) * block {
                for x in column * block ..< (column + 1) * block {
                    let i = (y * width + x) * 4
                    sum += SIMD3(Float(bytes[i]), Float(bytes[i + 1]), Float(bytes[i + 2]))
                }
            }
            return HSB(srgb: sum / Float(block * block * 255))
        }
        let regions = (0 ..< rows).flatMap { row in (0 ..< columns).map { average(column: $0, row: row) } }
        return BackdropPalette(points: HSB.muted(regions).map(\.srgb))
    }

    /// `fromCover` for a stored cover, decoded once per file version: the
    /// library asks on every redraw, and a replaced cover keeps its path.
    @MainActor static func fromCover(at url: URL) -> BackdropPalette? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        let key = "\(url.path)|\(modified.timeIntervalSinceReferenceDate)"
        if let cached = coverCache[key] { return cached }
        let palette = NSImage(contentsOf: url)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
            .flatMap { fromCover($0) }
        coverCache[key] = palette
        return palette
    }

    @MainActor private static var coverCache: [String: BackdropPalette?] = [:]
}

/// One region's colour, as `fromCover` mutes it.
private struct HSB {
    let h, s, b: CGFloat

    init(h: CGFloat, s: CGFloat, b: CGFloat) { (self.h, self.s, self.b) = (h, s, b) }
    init(_ color: NSColor) { self.init(h: color.hueComponent, s: color.saturationComponent, b: color.brightnessComponent) }
    init(srgb: SIMD3<Float>) {
        self.init(NSColor(srgbRed: CGFloat(srgb.x), green: CGFloat(srgb.y), blue: CGFloat(srgb.z), alpha: 1))
    }

    /// Apple Music's restraint: at most half saturated, and the set's
    /// brightness stretched across a fixed range, so the light and shade of
    /// a cover survive the averaging and a white cover is not a flat grey.
    static func muted(_ colors: [HSB]) -> [HSB] {
        let darkest = colors.map(\.b).min() ?? 0, lightest = colors.map(\.b).max() ?? 0
        let spread = lightest - darkest
        return colors.map { color in
            let t = spread > 0.02 ? (color.b - darkest) / spread : 0.5
            return HSB(h: color.h, s: min(color.s * 0.8, 0.5), b: 0.2 + t * 0.65)
        }
    }

    var srgb: SIMD3<Float> {
        let c = NSColor(hue: h, saturation: s, brightness: b, alpha: 1).usingColorSpace(.sRGB)!
        return [Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent)]
    }
}

/// A theme's moving backdrop: `LibraryBackdrop.metal` under a dimming layer
/// that keeps white text readable (none over a pale palette). Chosen on the prototype: half speed (full
/// read as too fast), 30 fps, three steps of grain, 45% black.
///
/// A new palette cross-fades in over the old one. Both layers run on one
/// clock, `epoch`, so only the colours change and the points stay put.
struct LibraryBackdrop: View {
    let palette: BackdropPalette
    var dim = Self.darkDim

    static let darkDim = 0.45
    static let epoch = Date.now

    var body: some View {
        ZStack {
            BackdropLayer(palette: palette)
                .id(palette)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.8), value: palette)
        .overlay(Color.black.opacity(dim))
    }
}

/// One palette's shader. It holds still on its current frame under Reduce
/// Motion and whenever its window is not the active one, so a library left
/// behind a game's own window, or behind another app, draws nothing.
private struct BackdropLayer: View {
    let palette: BackdropPalette

    static let speed = 0.5
    static let frameRate = 30.0
    static let falloff: Float = 1.6
    static let grain: Float = 3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / Self.frameRate,
                                paused: reduceMotion || activeState == .inactive)) { timeline in
            let time = Float(timeline.date.timeIntervalSince(LibraryBackdrop.epoch) * Self.speed)
            GeometryReader { proxy in
                Rectangle().colorEffect(Shaders.swiftUI.libraryBackdrop(
                    .float2(proxy.size), .float(time), .floatArray(palette.floats),
                    .float(Self.falloff), .float(Self.grain)))
            }
        }
    }
}
