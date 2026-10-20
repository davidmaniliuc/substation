import SwiftUI

/// A modal card drawn IN the window, over a dimmed backdrop. Not a `.sheet`:
/// a macOS sheet is its own window, attached under the toolbar, where this
/// card sits centred on the game picture or the library as the pause menu
/// sits on the game.
///
/// The modality a sheet gave for free is kept by hand: the backdrop eats
/// clicks (or, given `dismiss`, a click on it cancels, as the resume prompt
/// does; the exit prompt keeps its click), `ExitGate` already answers `.busy` to a second leave-request (the
/// close button, ⌘Q), and the key monitor stops feeding key-downs to the pad
/// while a dialog is up, so Return reaches the default button.
struct ModalDialog<Content: View>: View {
    var dismiss: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss?() }

            content
                .dialogSurface()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}
