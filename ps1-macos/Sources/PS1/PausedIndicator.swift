import SwiftUI

/// The paused game's mark: a large pause symbol in the centre of the picture,
/// shown while the game is paused with the HUD down and no menu, panel or
/// dialog saying so already. With the HUD up the bar's own button says it.
/// A pointer left still over the centre as the HUD hides can still click it,
/// since a click is not a move (`hoverMoved`).
///
/// A click turns the symbol into play, then resumes; the mark leaves as the
/// game starts, the same way it leaves for a resume from a key or the bar.
struct PausedIndicator: View {
    @Bindable var model: EmulatorViewModel

    /// The click has been taken and the symbol is turning to play.
    @State private var resuming = false

    /// Long enough for the symbol to finish turning before the game moves.
    private static let resumeDelay: Duration = .milliseconds(280)

    var body: some View {
        Button {
            guard !resuming else { return }
            resuming = true
            Task {
                try? await Task.sleep(for: Self.resumeDelay)
                model.isPaused = false
            }
        } label: {
            Image(systemName: resuming ? "play.fill" : "pause.fill")
                // The bar button's weight: one symbol at two sizes.
                .font(.system(size: 40, weight: .medium))
                .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp)))
                .animation(.snappy(duration: 0.25), value: resuming)
                .frame(width: 96, height: 96)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help("Resume")
        .accessibilityLabel("Paused. Resume")
    }
}
