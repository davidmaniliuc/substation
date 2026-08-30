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

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 12) {
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

                // Emulated frames, not presented ones: the question this
                // answers is whether the core is keeping up with the ~59.94 a
                // real NTSC machine runs at, which the display's own refresh
                // rate cannot tell you. Monospaced digits so the capsule does
                // not resize as the number changes.
                Text(model.fps.map { "\(Int($0.rounded())) FPS" } ?? "— FPS")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .trailing)
                    .accessibilityLabel("Frames per second")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
        }
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: isVisible)
        .allowsHitTesting(isVisible)
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
