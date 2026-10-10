import AppKit
import SwiftUI

/// The bar along the bottom:
/// `⏸ · Save States · Screenshot │ Speed · Full Screen · 🔊 · …`.
///
/// The bar is ONE glass effect, its `BarShape`, which carries the speed tab
/// as part of the same outline. One effect is one pass over the 60 fps Metal
/// view below it, with or without a `GlassEffectContainer`, which is the
/// cost the old single container was there to bound.
///
/// The volume slider is the one deliberate second glass: a capsule laid OVER
/// the bar from the speaker, as Apple Music does, so the bar keeps its width,
/// its layout and its contents, and the pill covers what it physically sits
/// over. It exists only while the slider is open. That makes three layers:
/// the bar, the pill, and the speaker icon drawn ONCE on top of both, so the
/// pill slides out from under it and it is never dimmed by the glass.
struct GameHUD: View {
    @Bindable var model: EmulatorViewModel
    let isVisible: Bool
    let isFullScreen: Bool

    /// Whether the volume slider is open. View state, and deliberately so:
    /// it means nothing outside this bar and must not survive the bar being
    /// hidden, which is what the `isVisible` change below enforces.
    @State private var volume = VolumeControlState()

    /// The insets the three layers share. The pill's seat for the speaker
    /// lands exactly on the bar's: `pillInset + pillPadding == barInset`.
    private let iconSize: CGFloat = 28
    private let barInset: CGFloat = 16
    private let pillInset: CGFloat = 7
    private var pillPadding: CGFloat { barInset - pillInset }
    private let spacing: CGFloat = 6
    /// The menu button right of the speaker, and the spacing before it: the
    /// pill stops short of it.
    private var trailingWidth: CGFloat { IconButton.width + spacing }
    /// The pill's own right padding, tight so it ends just past the speaker.
    private let pillRight: CGFloat = 4

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: spacing) {
                IconButton(symbol: model.isPaused ? "play.fill" : "pause.fill",
                           help: model.isPaused ? "Play" : "Pause", size: 17) {
                    model.togglePause()
                }
                SaveStatesButton(model: model)
                IconButton(symbol: "camera", help: "Screenshot") { model.takeScreenshot() }

                Divider().frame(height: 22)

                SpeedButton(model: model)
                IconButton(symbol: isFullScreen ? "arrow.down.right.and.arrow.up.left"
                                                : "arrow.up.left.and.arrow.down.right",
                           help: isFullScreen ? "Exit Full Screen" : "Full Screen") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                iconSeat
                IconButton(symbol: "ellipsis", help: "Menu") {
                    model.setSurface(.pauseMenu, open: true)
                }
            }
            .padding(.horizontal, barInset)
            .padding(.vertical, SpeedPick.barPad)
            .backgroundPreferenceValue(SpeedTabKey.self) { tab in glass(tab) }

            // One hover region over the pill and the icon together: the icon
            // sits on top of the pill, so separate regions would report the
            // icon's exit as the pointer moved onto the slider and close it.
            ZStack(alignment: .trailing) {
                if volume.isExpanded { pill }
                VolumeButton(level: model.volume, isMuted: model.isMuted) {
                    if volume.iconTapped() == .toggleMute { model.toggleMute() }
                }
                .frame(width: IconButton.width)
                .padding(.trailing, barInset + trailingWidth)
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
        // controls under it still covered and no click to explain why.
        .onChange(of: isVisible) { _, visible in
            if !visible { volume.collapse() }
        }
    }

    /// The bar's glass, tab included, behind the controls. Always the full
    /// height of an open tab, so it never takes a click meant for the game.
    private func glass(_ tab: SpeedTab) -> some View {
        GeometryReader { geo in
            let button = tab.anchor.map { geo[$0] }
            Color.clear
                .frame(width: geo.size.width, height: geo.size.height + SpeedPick.rise)
                .glassEffect(.regular, in: BarShape(
                    tabMinX: (button?.minX ?? 0) - SpeedPick.pad,
                    tabWidth: (button?.width ?? 0) + 2 * SpeedPick.pad,
                    rise: tab.rise,
                    reach: SpeedPick.rise,
                    barHeight: geo.size.height))
                .offset(y: -SpeedPick.rise)
                .allowsHitTesting(false)
                .animation(.snappy(duration: 0.22), value: tab.rise)
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
            .frame(width: VolumeSlider.width, height: iconSize)
            iconSeat
        }
        .padding(.leading, pillPadding)
        .padding(.trailing, pillRight)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
        // The whole capsule, so a click in the pill's padding lands on the
        // pill rather than on the bar button it is covering.
        .contentShape(.capsule)
        .padding(.trailing, barInset + trailingWidth - pillRight)
        // Grows out of the icon rather than fading in over the bar.
        .transition(.scale(scale: 0.1, anchor: .trailing).combined(with: .opacity))
    }

    /// The space the speaker icon occupies in a capsule that does not draw
    /// it: as wide as a button, so the pitch around it stays even.
    private var iconSeat: some View {
        Color.clear
            .frame(width: IconButton.width, height: iconSize)
            .allowsHitTesting(false)
    }
}

/// Opens the Save States panel from the bar. A popover is a window of its
/// own, so the panel may spill past the game window, which an overlay in it
/// never can.
struct SaveStatesButton: View {
    @Bindable var model: EmulatorViewModel

    private var shown: Binding<Bool> {
        Binding(get: { model.isOpen(.saveStates) && model.saveStatesOrigin == .bar },
                set: { if !$0 { model.setSurface(.saveStates, open: false) } })
    }

    var body: some View {
        IconButton(symbol: "rectangle.stack", help: "Save States") {
            if model.isOpen(.saveStates) {
                model.setSurface(.saveStates, open: false)
            } else {
                model.openSaveStates(from: .bar)
            }
        }
        .disabled(!model.canUseStates)
        .popover(isPresented: shown, arrowEdge: .top) { SaveStatesPanel(model: model) }
    }
}
