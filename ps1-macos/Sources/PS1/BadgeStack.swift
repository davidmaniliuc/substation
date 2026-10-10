import AppKit
import SwiftUI

/// Every transient status in ONE corner, each with its own icon, shown with
/// the HUD hidden or not: the press that caused most of them came from a
/// controller or a key, not the pointer.
///
/// Speed shows for any speed above 1×: a persistent 3× with nothing on
/// screen reads as a broken emulator. Paused is not a badge: it is the
/// centred `PausedIndicator`.
struct BadgeStack: View {
    @Bindable var model: EmulatorViewModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if model.effectiveSpeed > 1 {
                Badge(icon: "forward.fill", text: "\(model.effectiveSpeed)×", mono: true)
                    .accessibilityLabel("Running at \(model.effectiveSpeed) times speed")
            }
            if model.isRewinding {
                Badge(icon: "backward.fill",
                      text: String(format: "%.0f s", model.rewindSecondsLeft.rounded(.down)), mono: true)
                    .accessibilityLabel("Rewinding, \(Int(model.rewindSecondsLeft)) seconds left")
            }
            if model.savingToMemoryCard {
                Badge(icon: "sdcard.fill", text: "Saving", pulse: true)
                    .accessibilityLabel("Saving to memory card")
            }
            if let notice = model.notice { NoticeBadge(notice: notice) }
        }
        .animation(.snappy(duration: 0.25), value: model.effectiveSpeed)
        .animation(.snappy(duration: 0.25), value: model.isRewinding)
        .animation(.snappy(duration: 0.25), value: model.savingToMemoryCard)
        .animation(.snappy(duration: 0.25), value: model.notice)
    }
}

struct Badge: View {
    let icon: String
    let text: String
    var mono = false
    var pulse = false
    /// Only a notice that reveals a file takes a click; the rest let it
    /// through to the picture.
    var interactive = false

    var body: some View {
        Label(text, systemImage: icon)
            .symbolEffect(.pulse, isActive: pulse)
            .font(.system(size: 13, weight: .semibold, design: mono ? .monospaced : .default))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
            .transition(.move(edge: .trailing).combined(with: .opacity))
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
            .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            Badge(icon: notice.icon, text: notice.text)
        }
    }
}
