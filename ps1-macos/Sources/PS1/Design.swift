import AppKit
import SwiftUI

/// The app's one visual language, shared by the library, the resume sheet and
/// the pause menu so the three read as one app. Monochrome by default: the
/// accent marks what a click acts on (the selection, the default button, a
/// control's value), never decoration. Surfaces step down from the window's
/// material to one inset fill, edged by the system hairline.
enum Design {
    /// Corner radii, smallest to largest. A shape takes the step for its
    /// size, so nested shapes stay roughly concentric.
    enum Radius {
        /// A small cover or a state's thumbnail in a row.
        static let thumbnail: CGFloat = 5
        /// A highlighted row, an inset list.
        static let row: CGFloat = 8
        /// A cover in the grid.
        static let tile: CGFloat = 10
        /// The library's panel, a large screenshot.
        static let panel: CGFloat = 12
        /// A confirmation laid over a dialog.
        static let alert: CGFloat = 18
        /// A modal card: the resume sheet, the exit prompt.
        static let dialog: CGFloat = 22
    }

    /// The one shape a modal card and anything laid over it take.
    static func cardShape(_ cornerRadius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

extension View {
    /// A modal card's surface: a blur under the window background, so what
    /// is behind shows only as a tint, as Things' Quick Entry. Over the
    /// library the blur is in the window and the tint 80%; over the desktop
    /// (`overDesktop`, the panel a Finder or Spotlight launch shows) it is
    /// the desktop's own blur and the tint lighter, as a Spotlight panel. Not glass (that is for controls floating over content, HIG
    /// Materials), and not a bare material either: alone it lets the covers
    /// show through the card's edge and leaves a bordered button no bezel.
    /// Edged by the system hairline and lifted by a soft shadow.
    ///
    /// The card clips its own content to the shape it fills, so an inset strip
    /// along an edge (the resume sheet's footer) meets the corner exactly. A
    /// clip with any other shape, even at the same radius, leaves a sliver of
    /// the card showing past the strip's corner.
    func dialogSurface(cornerRadius: CGFloat = Design.Radius.dialog,
                       overDesktop: Bool = false) -> some View {
        let shape = Design.cardShape(cornerRadius)
        return clipShape(shape)
            .background {
                if overDesktop {
                    BehindWindowBlur(material: .hudWindow).clipShape(shape)
                    shape.fill(.windowBackground.opacity(0.45))
                } else {
                    shape.fill(.thickMaterial)
                    shape.fill(.windowBackground.opacity(0.8))
                }
            }
            .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
    }
}

/// What is behind the window, blurred: the desktop under the About window
/// or a panel with no window of ours behind it. A SwiftUI material blurs
/// only within its window, which there holds nothing.
struct BehindWindowBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }

    /// Whatever it is offered, as a background should be. Left to AppKit, the
    /// view's zero fitting size reaches a panel that sizes itself to its
    /// content, which then never appears.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSVisualEffectView,
                      context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

/// The inset fill under content set into a surface: the library's panel, the
/// resume sheet's list and its button strip. A shade darker than the material
/// in Dark, a shade lighter in Light, so it reads as inset in either.
struct InsetFill: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        environment.colorScheme == .dark ? Color.black.opacity(0.28) : Color.white.opacity(0.55)
    }
}

/// A line of key hints: each key, then what it does, a step quieter. Hints
/// only: nothing that must be clicked lives at a bottom edge (HIG Layout),
/// and every action named here is reachable another way.
struct KeyHints<Trailing: View>: View {
    let hints: [(key: String, action: String)]
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            ForEach(hints.indices, id: \.self) { i in
                if i > 0 { Text("·").foregroundStyle(.tertiary) }
                HStack(spacing: 4) {
                    Text(hints[i].key).fontWeight(.semibold).foregroundStyle(.secondary)
                    // Secondary, not tertiary: small grey on the dark panel
                    // falls under the 4.5:1 text contrast at tertiary.
                    Text(hints[i].action).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .font(.caption)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

extension KeyHints where Trailing == EmptyView {
    init(_ hints: [(key: String, action: String)]) {
        self.init(hints: hints) { EmptyView() }
    }
}
