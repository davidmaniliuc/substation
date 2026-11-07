import SwiftUI

/// The paused game's mark: a large play button in the centre of the picture,
/// shown while the game is paused and no menu, panel or dialog says so
/// already. It stays up with the HUD, so the pointer moving toward it (which
/// raises the HUD) never takes it away. It shows the bar button's own symbol,
/// what a click does, so the two never disagree.
struct PausedIndicator: View {
    @Bindable var model: EmulatorViewModel
    @Bindable var game: OpenGame
    var body: some View {
        Button {
            game.resume()
        } label: {
            Image(systemName: "play.fill")
                // The bar button's weight: one symbol at two sizes.
                .font(.largeTitle.weight(.medium))
                .imageScale(.large)
                .frame(width: 80, height: 80)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        // Under the glass: the picture behind a bright frame would wash it out.
        .background(Circle().fill(Design.Dim.scrim))
        .help("Resume")
        .accessibilityLabel("Paused. Resume")
    }
}
