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
        static let thumbnail: CGFloat = 4
        /// A highlighted row, an inset list.
        static let row: CGFloat = 8
        /// A cover in the grid.
        static let tile: CGFloat = 10
        /// The library's panel, a large screenshot.
        static let panel: CGFloat = 12
        /// A smaller card than a dialog: a confirmation laid over one.
        static let raised: CGFloat = 18
        /// A modal card: the resume sheet, the exit prompt.
        static let dialog: CGFloat = 22

        /// A cover outside the grid, by its side: small in a list row, a
        /// step rounder once it heads a surface.
        static func cover(_ side: CGFloat) -> CGFloat {
            side < 56 ? thumbnail : row
        }
    }

    /// The one rounded shape every surface takes, so the corner style is
    /// stated once.
    static func cardShape(_ cornerRadius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    /// The corner of a shape set `inset` inside one with `outer`'s corner,
    /// so the two stay concentric.
    /// Past a large inset the result would be all but square, so it stops
    /// at `floor`.
    static func concentric(_ outer: CGFloat, inset: CGFloat, floor: CGFloat = 2) -> CGFloat {
        max(outer - inset, floor)
    }

    /// Spacing on a 4 pt grid.
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
        /// A modal card's padding and the gap between its buttons.
        static let dialog: CGFloat = 20
        static let buttonGap: CGFloat = 8
        /// The room a borderless panel leaves round its card for the shadow.
        static let shadowMargin: CGFloat = 48
    }

    /// Fixed widths that recur across surfaces.
    enum Size {
        /// The narrowest a dialog's push button gets, so Cancel and a short
        /// verb read as a pair.
        static let dialogButton: CGFloat = 84
        /// A small card or popover: the exit prompt, the Save States panel.
        static let card: CGFloat = 340
        /// A control trailing a settings row: a picker, a slider.
        static let trailingControl: CGFloat = 132
        /// The height of a line of key hints under a surface.
        static let hintStrip: CGFloat = 30
    }

    /// The one outline width: a pixel on a Retina display.
    static let hairline: CGFloat = 0.5

    /// How far a control fades when it is disabled.
    static let disabledOpacity = 0.45

    /// The two dimming layers: behind a modal and under clear glass over the
    /// picture, and behind a sidebar the picture should still read through.
    enum Dim {
        static let scrim = Color.black.opacity(0.35)
        static let light = Color.black.opacity(0.2)
    }

    /// Lift, smallest to largest.
    enum Shadow {
        case text, thumbnail, tile, card

        var opacity: Double {
            switch self {
            case .text: 0.3
            case .thumbnail: 0.3
            case .tile: 0.3
            case .card: 0.3
            }
        }

        var radius: CGFloat {
            switch self {
            case .text: 2
            case .thumbnail: 3
            case .tile: 6
            case .card: 30
            }
        }

        var y: CGFloat {
            switch self {
            case .text, .thumbnail: 1
            case .tile: 3
            case .card: 12
            }
        }
    }

    /// The keyboard focus ring drawn by a custom control.
    enum Focus {
        static let width: CGFloat = 2
        static let gap: CGFloat = 3
        /// A selected cover's ring: a step heavier than focus, so a selection
        /// reads at a glance across a grid.
        static let selectionWidth: CGFloat = 3
    }
}

extension View {
    func designShadow(_ shadow: Design.Shadow) -> some View {
        self.shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius, y: shadow.y)
    }

    /// The accent ring a custom control draws while it holds keyboard focus,
    /// concentric with its own `cornerRadius`.
    func focusRing(_ shown: Bool, cornerRadius: CGFloat) -> some View {
        focusRing(shown, in: Design.cardShape(cornerRadius + Design.Focus.gap))
    }

    /// The same ring for a control of another shape, a capsule button's:
    /// `shape` is the ring's own outline, `Focus.gap` outside the control.
    func focusRing(_ shown: Bool, in shape: some InsettableShape) -> some View {
        overlay {
            if shown {
                shape.strokeBorder(Color.accentColor, lineWidth: Design.Focus.width)
                    .padding(-Design.Focus.gap)
            }
        }
    }
}

/// A plain row, capsule or segment that answers the pointer as a menu row
/// does: a soft fill on hover, a firmer one while pressed, dimmed when
/// disabled. `hovers` is off where something else already draws the hover,
/// as the pause menu's highlight does.
struct FillPressStyle<S: Shape>: ButtonStyle {
    let shape: S
    var hovers = true

    init(_ shape: S, hovers: Bool = true) {
        self.shape = shape
        self.hovers = hovers
    }

    func makeBody(configuration: Configuration) -> some View {
        Fill(configuration: configuration, shape: shape, hovers: hovers)
    }

    private struct Fill: View {
        let configuration: Configuration
        let shape: S
        let hovers: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .contentShape(shape)
                .background {
                    if configuration.isPressed {
                        shape.fill(.fill.secondary)
                    } else if hovers && hovering && isEnabled {
                        shape.fill(.fill.tertiary)
                    }
                }
                .opacity(isEnabled ? 1 : Design.disabledOpacity)
                .onHover { hovering = $0 }
        }
    }
}

extension FillPressStyle where S == RoundedRectangle {
    init(cornerRadius: CGFloat = Design.Radius.row, hovers: Bool = true) {
        self.init(Design.cardShape(cornerRadius), hovers: hovers)
    }
}

extension View {
    /// A modal card's surface: Liquid Glass tinted toward the window
    /// background, as a system alert draws itself on macOS 26, so what is
    /// behind shows through as colour and shape but never competes with the
    /// card's text. The tint is what earlier attempts lacked: untinted glass
    /// read as a pane apart from the app, and a blur under an 80% fill read as
    /// an opaque slab. The glass draws its own rim, so the card takes no
    /// hairline; a soft shadow lifts it.
    ///
    /// The card clips its own content to the shape it fills, so an inset strip
    /// along an edge (the resume sheet's footer) meets the corner exactly. A
    /// clip with any other shape, even at the same radius, leaves a sliver of
    /// the card showing past the strip's corner.
    func dialogSurface(cornerRadius: CGFloat = Design.Radius.dialog) -> some View {
        let shape = Design.cardShape(cornerRadius)
        return clipShape(shape)
            .glassEffect(.regular.tint(Design.dialogTint), in: shape)
            .designShadow(.card)
    }
}

extension Design {
    /// How far a modal card's glass leans toward the window background.
    static let dialogTint = Color(nsColor: .windowBackgroundColor).opacity(0.3)
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
/// in Dark, a shade lighter in Light, so it reads as inset in either. Under
/// Increase Contrast it is the system's opaque control background, so nothing
/// behind the window shows through the content.
struct InsetFill: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        if environment.colorSchemeContrast == .increased {
            return Color(nsColor: .controlBackgroundColor)
        }
        return environment.colorScheme == .dark ? Color.black.opacity(0.28) : Color.white.opacity(0.55)
    }
}

/// A line of key hints: each key, then what it does, a step quieter. Hints
/// only: nothing that must be clicked lives at a bottom edge (HIG Layout),
/// and every action named here is reachable another way.
struct KeyHints<Trailing: View>: View {
    let hints: [(key: String, action: String)]
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Design.Spacing.s) {
            ForEach(hints.indices, id: \.self) { i in
                if i > 0 { Text("·").foregroundStyle(.tertiary) }
                HStack(spacing: Design.Spacing.xs) {
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
        .frame(height: Design.Size.hintStrip)
        .accessibilityElement(children: .combine)
    }
}

extension KeyHints where Trailing == EmptyView {
    init(_ hints: [(key: String, action: String)]) {
        self.init(hints: hints) { EmptyView() }
    }
}
