import AppKit
import SwiftUI

/// The colours one animated backdrop drifts between, as sRGB triples: the
/// shader's `colors` argument, one point each.
struct BackdropPalette: Hashable {
    let points: [SIMD3<Float>]

    /// The console's logo colours, muted, over two near-blacks: Substation's
    /// colours until a game with a cover is selected.
    static let substation = BackdropPalette(points: [
        [0.50, 0.08, 0.12], [0.55, 0.40, 0.04], [0.03, 0.35, 0.22],
        [0.06, 0.16, 0.50], [0.02, 0.02, 0.04], [0.03, 0.03, 0.10],
    ])

    /// Near-grey with a hint of blue: the quiet one.
    static let graphite = BackdropPalette(points: [
        [0.10, 0.10, 0.12], [0.20, 0.21, 0.24], [0.14, 0.16, 0.22],
        [0.26, 0.25, 0.27], [0.03, 0.03, 0.04], [0.12, 0.13, 0.16],
    ])

    var floats: [Float] { points.flatMap { [$0.x, $0.y, $0.z] } }

    /// Six colours from a cover: the most vivid pixels of a small thumbnail
    /// with distinct hues, darkened so white text stays readable over them,
    /// and a near-black of the most vivid hue. Nil only for an image that
    /// cannot be drawn.
    static func fromCover(_ image: CGImage) -> BackdropPalette? {
        let side = 24
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                      bytesPerRow: side * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        func channel(_ i: Int) -> CGFloat { CGFloat(bytes[i]) / 255 }
        var pixels: [HSB] = stride(from: 0, to: bytes.count, by: 4).map { i in
            HSB(NSColor(srgbRed: channel(i), green: channel(i + 1), blue: channel(i + 2), alpha: 1))
        }
        pixels.sort { $0.vividness > $1.vividness }

        var picked: [HSB] = []
        for pixel in pixels where picked.count < 5 && picked.allSatisfy({ pixel.isDistinct(from: $0) }) {
            picked.append(pixel)
        }
        guard let mostVivid = picked.first else { return nil }
        var colors = picked.map { HSB(h: $0.h, s: min($0.s * 1.1, 1), b: min($0.b, 0.7) * 0.7) }
        while colors.count < 5 { colors.append(colors[colors.count % picked.count]) }
        colors.append(HSB(h: mostVivid.h, s: 0.6, b: 0.05))
        return BackdropPalette(points: colors.map(\.srgb))
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

/// One pixel, as `fromCover` weighs it.
private struct HSB {
    let h, s, b: CGFloat

    init(h: CGFloat, s: CGFloat, b: CGFloat) { (self.h, self.s, self.b) = (h, s, b) }
    init(_ color: NSColor) { self.init(h: color.hueComponent, s: color.saturationComponent, b: color.brightnessComponent) }

    var vividness: CGFloat { s * b }

    /// A hue apart on the wheel, or far apart in brightness.
    func isDistinct(from other: HSB) -> Bool {
        let d = abs(h - other.h)
        return min(d, 1 - d) > 0.06 || abs(b - other.b) > 0.3
    }

    var srgb: SIMD3<Float> {
        let c = NSColor(hue: h, saturation: s, brightness: b, alpha: 1).usingColorSpace(.sRGB)!
        return [Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent)]
    }
}

/// A theme's moving backdrop: `LibraryBackdrop.metal` under a dimming layer
/// that keeps white text readable. Chosen on the prototype: half speed (full
/// read as too fast), 30 fps, three steps of grain, 45% black.
///
/// A new palette cross-fades in over the old one. Both layers run on one
/// clock, `epoch`, so only the colours change and the points stay put.
struct LibraryBackdrop: View {
    let palette: BackdropPalette

    static let dim = 0.45
    static let epoch = Date.now

    var body: some View {
        ZStack {
            BackdropLayer(palette: palette)
                .id(palette)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.8), value: palette)
        .overlay(Color.black.opacity(Self.dim))
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
