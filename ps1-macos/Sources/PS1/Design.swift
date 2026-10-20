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
                    Text(hints[i].key).fontWeight(.medium).foregroundStyle(.secondary)
                    Text(hints[i].action).foregroundStyle(.tertiary)
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
