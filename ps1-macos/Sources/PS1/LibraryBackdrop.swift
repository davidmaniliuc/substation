import SwiftUI

/// The colours one animated backdrop drifts between, as sRGB triples: the
/// shader's `colors` argument, one point each.
struct BackdropPalette: Equatable {
    let points: [SIMD3<Float>]

    /// The console's logo colours, muted, over two near-blacks.
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
}

/// A theme's moving backdrop: `LibraryBackdrop.metal` under a dimming layer
/// that keeps white text readable. Chosen on the prototype: half speed (full
/// read as too fast), 30 fps, three steps of grain, 45% black.
///
/// It holds still on its current frame under Reduce Motion and whenever its
/// window is not the active one, so a library left behind a game's own
/// window, or behind another app, draws nothing.
struct LibraryBackdrop: View {
    let palette: BackdropPalette

    static let speed = 0.5
    static let frameRate = 30.0
    static let falloff: Float = 1.6
    static let grain: Float = 3
    static let dim = 0.45

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @State private var start = Date.now

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / Self.frameRate,
                                paused: reduceMotion || activeState == .inactive)) { timeline in
            let time = Float(timeline.date.timeIntervalSince(start) * Self.speed)
            GeometryReader { proxy in
                Rectangle().colorEffect(Shaders.swiftUI.libraryBackdrop(
                    .float2(proxy.size), .float(time), .floatArray(palette.floats),
                    .float(Self.falloff), .float(Self.grain)))
            }
        }
        .overlay(Color.black.opacity(Self.dim))
    }
}
