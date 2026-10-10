import SwiftUI

/// The paused game's mark: a large pause symbol in the centre of the picture,
/// shown whenever the game is paused and no menu, panel or dialog is saying so
/// already. It shows with the HUD up as well as down: moving the pointer to
/// click it brings the HUD up, and a mark that hid then could never be clicked.
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
                .font(.system(size: 40, weight: .semibold))
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
