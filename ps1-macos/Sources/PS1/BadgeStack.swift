import AppKit
import SwiftUI

/// Every transient status in ONE corner, each with its own icon, shown with
/// the HUD hidden or not: the press that caused most of them came from a
/// controller or a key, not the pointer.
///
/// Speed shows for any speed above 1×: a persistent 3× with nothing on
/// screen reads as a broken emulator. Paused is not a badge: it is the
/// centred `PausedIndicator`. A clock away from 100% shows for the same
/// reason, whether the player set it or the game's table did.
struct BadgeStack: View {
    @Bindable var model: EmulatorViewModel
    @Bindable var game: OpenGame

    var body: some View {
        VStack(alignment: .trailing, spacing: Design.Spacing.s) {
            if model.effectiveSpeed > 1 {
                Badge(icon: "forward.fill", text: "\(model.effectiveSpeed)×")
                    .accessibilityLabel("Running at \(model.effectiveSpeed) times speed")
            }
            if model.cpuOverclock(for: game) != 100 {
                Badge(icon: "cpu", text: "CPU \(model.cpuOverclock(for: game))%")
                    .accessibilityLabel("Processor at \(model.cpuOverclock(for: game)) percent")
            }
            if game.isRewinding {
                Badge(icon: "backward.fill",
                      text: String(format: "%.0f s", game.rewindSecondsLeft.rounded(.down)))
                    .accessibilityLabel("Rewinding, \(Int(game.rewindSecondsLeft)) seconds left")
            }
            if game.savingToMemoryCard {
                Badge(icon: "sdcard.fill", text: "Saving", pulse: true)
                    .accessibilityLabel("Saving to memory card")
            }
            if let notice = game.notice { NoticeBadge(notice: notice) }
        }
        .animation(.snappy(duration: 0.25), value: model.effectiveSpeed)
        .animation(.snappy(duration: 0.25), value: game.isRewinding)
        .animation(.snappy(duration: 0.25), value: game.savingToMemoryCard)
        .animation(.snappy(duration: 0.25), value: game.notice)
    }
}

struct Badge: View {
    let icon: String
    let text: String
    var pulse = false
    /// Only a notice that reveals a file takes a click; the rest let it
    /// through to the picture.
    var interactive = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label(text, systemImage: icon)
            .symbolVariant(.fill)
            .symbolEffect(.pulse, isActive: pulse && !reduceMotion)
            .font(.callout.weight(.semibold).monospacedDigit())
            .padding(.horizontal, Design.Spacing.m)
            .padding(.vertical, Design.Spacing.s)
            .glassEffect(.regular, in: .capsule)
            .badgeTransition()
            .allowsHitTesting(interactive)
    }
}

/// A notice; the one badge that takes a click, and only when it names a
/// file, which the click shows in Finder.
private struct NoticeBadge: View {
    let notice: Notice

    var body: some View {
        if let url = notice.reveal {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Badge(icon: notice.icon, text: notice.text, interactive: true)
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
            .badgeTransition()
        } else {
            Badge(icon: notice.icon, text: notice.text)
        }
    }
}

private extension View {
    /// Slides in from the trailing edge; under Reduce Motion it only fades.
    func badgeTransition() -> some View { modifier(BadgeTransition()) }
}

private struct BadgeTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(reduceMotion ? .opacity
                                        : .move(edge: .trailing).combined(with: .opacity))
    }
}
