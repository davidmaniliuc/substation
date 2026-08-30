import SwiftUI

/// The floating control cluster.
///
/// Every effect lives in ONE GlassEffectContainer so they batch into a single
/// pass rather than N independent ones — a glass effect samples the drawable
/// behind it every frame, over a 60fps Metal view, so the batching is what
/// keeps the cost bounded. The HUD is also hidden during actual play.
struct GameHUD: View {
    @Bindable var model: EmulatorViewModel
    let isVisible: Bool

    @Namespace private var glass

    /// Whether the volume slider is open. View state, and deliberately so:
    /// it means nothing outside this bar and must not survive the bar being
    /// hidden — which is what the `isVisible` change below enforces.
    @State private var volume = VolumeControlState()

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 12) {
                // The slider takes the place of everything else rather than
                // being appended to it: the bar is already as wide as a 4:3
                // window comfortably holds, and growing it would push the
                // controls off-centre every time the speaker is clicked.
                if volume.isExpanded {
                    VolumeSlider(level: $model.volume, isMuted: model.isMuted)
                        .frame(width: 132, height: 28)
                        .glassEffectID("volumeslider", in: glass)
                } else {
                    transport
                }

                VolumeButton(level: model.volume, isMuted: model.isMuted) {
                    if volume.iconTapped() == .toggleMute { model.toggleMute() }
                }
                .glassEffectID("volume", in: glass)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .animation(.snappy(duration: 0.28), value: volume.isExpanded)
        }
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: isVisible)
        .allowsHitTesting(isVisible)
        // A slider left open would come back open on the next hover, with the
        // transport controls still hidden behind it and no click to explain
        // why.
        .onChange(of: isVisible) { _, visible in
            if !visible { volume.collapse() }
        }
    }

    @ViewBuilder
    private var transport: some View {
        button(model.isPaused ? "play.fill" : "pause.fill", "Play/Pause") {
            model.isPaused.toggle()
        }
        .glassEffectID("playpause", in: glass)

        button("arrow.counterclockwise", "Reset") { model.reset() }
            .glassEffectID("reset", in: glass)

        button("eject.fill", "Eject") { model.eject() }
            .glassEffectID("eject", in: glass)

        button("arrow.up.left.and.arrow.down.right", "Full Screen") {
            NSApp.keyWindow?.toggleFullScreen(nil)
        }
        .glassEffectID("fullscreen", in: glass)

        Divider().frame(height: 20)

        // Emulated frames, not presented ones: the question this answers is
        // whether the core is keeping up with the ~59.94 a real NTSC machine
        // runs at, which the display's own refresh rate cannot tell you.
        // Monospaced digits so the capsule does not resize as the number
        // changes.
        Text(model.fps.map { "\(Int($0.rounded())) FPS" } ?? "— FPS")
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 62, alignment: .trailing)
            .accessibilityLabel("Frames per second")
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
