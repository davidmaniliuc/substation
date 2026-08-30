import SwiftUI

/// The floating control cluster.
///
/// Every effect lives in ONE GlassEffectContainer so they batch into a single
/// pass rather than N independent ones — a glass effect samples the drawable
/// behind it every frame, over a 60fps Metal view, so the batching is what
/// keeps the cost bounded. The HUD is also hidden during actual play.
///
/// The volume slider is the one exception, and deliberately: it is a SECOND
/// capsule laid OVER the bar, so it must not be merged into the bar's shape by
/// the container. It only exists while the slider is open, which is only while
/// the OSD is up.
struct GameHUD: View {
    @Bindable var model: EmulatorViewModel
    let isVisible: Bool

    @Namespace private var glass

    /// Whether the volume slider is open. View state, and deliberately so:
    /// it means nothing outside this bar and must not survive the bar being
    /// hidden — which is what the `isVisible` change below enforces.
    @State private var volume = VolumeControlState()

    /// Every inset the three layers share. The speaker icon is drawn ONCE, on
    /// top of both capsules, and these are what put the pill's seat for it in
    /// exactly the place the bar's own seat is: `barInset` from the trailing
    /// edge either way, since `pillInset + pillPadding == barInset`.
    private let iconSize: CGFloat = 28
    private let barInset: CGFloat = 18
    private let pillInset: CGFloat = 8
    private let pillPadding: CGFloat = 10

    var body: some View {
        ZStack(alignment: .trailing) {
            GlassEffectContainer(spacing: 16) {
                // Untouched when the slider opens. The pill covers what it
                // physically sits over and nothing else — hiding the whole bar
                // makes the controls to the LEFT of the pill disappear for no
                // reason the player can see.
                HStack(spacing: 12) {
                    transport
                    iconSeat
                }
                .padding(.horizontal, barInset)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
            }

            // One hover region over both, rather than one each: the icon sits
            // on top of the pill, so separate regions would report the icon's
            // exit as the pointer moved onto the slider and close it there.
            ZStack(alignment: .trailing) {
                if volume.isExpanded { pill }

                // On top of both capsules, so the pill slides out from under
                // it and it is never dimmed by the glass covering the bar.
                VolumeButton(level: model.volume, isMuted: model.isMuted) {
                    if volume.iconTapped() == .toggleMute { model.toggleMute() }
                }
                .padding(.trailing, barInset)
            }
            .onHover { inside in
                if !inside { volume.pointerExited() }
            }
        }
        .animation(.snappy(duration: 0.28), value: volume.isExpanded)
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

    /// The slider capsule. Its height leaves `pillInset` of the bar showing
    /// above and below, which is what makes it read as a second capsule laid
    /// over the first rather than as the bar itself changing shape.
    private var pill: some View {
        HStack(spacing: 12) {
            VolumeSlider(level: $model.volume, isMuted: model.isMuted) {
                if $0 { volume.adjustingBegan() } else { volume.adjustingEnded() }
            }
            .frame(width: 132, height: iconSize)
            iconSeat
        }
        .padding(.horizontal, pillPadding)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
        // The whole capsule, so a click in the pill's padding lands on the
        // pill rather than on the bar button it is covering.
        .contentShape(.capsule)
        .padding(.trailing, pillInset)
        // Grows out of the icon rather than fading in over the bar.
        .transition(.scale(scale: 0.1, anchor: .trailing).combined(with: .opacity))
    }

    /// The space the speaker icon occupies in a capsule that does not draw it.
    private var iconSeat: some View {
        Color.clear
            .frame(width: iconSize, height: iconSize)
            .allowsHitTesting(false)
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
