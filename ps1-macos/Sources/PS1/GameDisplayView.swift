import SwiftUI

/// The toolbar band drawn into the picture behind the traffic lights and
/// the title (`TitleStrip`). It is the shader's because no AppKit blur
/// reaches the Metal picture: a material frosts it into a flat tint, and
/// the toolbar's own scroll-edge band drew an opaque bar over it. The
/// session takes these three numbers, in points, at creation.
enum ToolbarBand {
    /// The unified toolbar's height, which centres the traffic lights.
    static let height: Double = 52
    /// The hard scroll edge's short fade at the bottom.
    static let edge: Double = 10
    static let sigma: Double = 8
}

/// Puts a model's `SessionHostView` in SwiftUI. It always returns the SAME
/// view: SwiftUI rebuilds a representable on a fullscreen toggle, a HUD change
/// and a window swap, and a fresh view would lose the layer the session
/// installed.
struct GameDisplayView: NSViewRepresentable {
    let host: SessionHostView

    func makeNSView(context: Context) -> SessionHostView { host }

    func updateNSView(_ nsView: SessionHostView, context: Context) {}
}
