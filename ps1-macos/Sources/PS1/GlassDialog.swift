import SwiftUI

/// A modal card drawn IN the window, over a dimmed backdrop. Not a `.sheet`:
/// a macOS sheet is its own window with an opaque material behind the
/// content, so Liquid Glass inside one has nothing to refract and reads as a
/// flat grey panel. Drawn here, the glass sits on the game picture or the
/// library itself.
///
/// The modality a sheet gave for free is kept by hand: the backdrop eats
/// clicks, `ExitGate` already answers `.busy` to a second leave-request (the
/// close button, ⌘Q), and the key monitor stops feeding key-downs to the pad
/// while a dialog is up, so Return reaches the default button.
struct GlassDialog<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}

            content
                .glassEffect(.regular, in: .rect(cornerRadius: 26))
                .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}
