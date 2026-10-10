import SwiftUI

/// A button in a `ConfirmCard`.
struct ConfirmButton: Hashable {
    let title: String
    var destructive = false
}

/// The question a state tile asks before it acts, laid over the resume sheet
/// and the in-game Save States panel alike: a title, one line under it, and
/// equal-width buttons, as a system alert lays them out.
///
/// `highlighted` is the button Return presses, or nil for none. It is drawn
/// as the default (accent) only when it is a safe choice: never Cancel and
/// never a destructive button, which the HIG keeps off the default so a
/// reflexive Return cannot delete or dismiss unread. A delete therefore asks
/// with no default at all, Delete in red. While `showsFocus` (a key or the
/// controller moved), a ring marks the highlighted button whatever it is.
struct ConfirmCard: View {
    let title: String
    let message: String
    let buttons: [ConfirmButton]
    var highlighted: Int?
    var showsFocus = false
    /// Whether the card takes Escape itself. The in-game panel's keys reach
    /// it through the model instead.
    var bindsKeys = false
    let press: (Int) -> Void

    /// What every delete says under its title.
    static let deleteMessage = "This can’t be undone."

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text(title).font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                ForEach(buttons.indices, id: \.self) { button($0) }
            }
            .fixedSize()
            .controlSize(.large)
        }
        .padding(20)
        .background { if bindsKeys { keys } }
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }

    @ViewBuilder private func button(_ i: Int) -> some View {
        let spec = buttons[i]
        let base = Button(role: spec.destructive ? .destructive : nil) { press(i) } label: {
            Text(spec.title).frame(minWidth: 84, maxWidth: .infinity)
        }
        Group {
            if i == highlighted && !spec.destructive && spec.title != "Cancel" {
                base.buttonStyle(.borderedProminent)
            } else {
                base.buttonStyle(.bordered).foregroundStyle(spec.destructive ? Color.red : .primary)
            }
        }
        .overlay {
            if showsFocus && i == highlighted {
                Capsule().strokeBorder(Color.accentColor, lineWidth: 3).padding(-4)
            }
        }
    }

    /// Escape as an unseen button. Return is the highlighted button's when
    /// there is one; nothing when there is not.
    private var keys: some View {
        ZStack {
            if let highlighted {
                Button("") { press(highlighted) }.keyboardShortcut(.return, modifiers: [])
            }
            if let cancel = buttons.firstIndex(where: { $0.title == "Cancel" }) {
                Button("") { press(cancel) }.keyboardShortcut(.cancelAction)
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A `ConfirmCard` over what it asks about: the content is dimmed, and a
/// click on the dimming is Cancel.
struct ConfirmScrim<Card: View>: View {
    let cornerRadius: CGFloat
    let cancel: () -> Void
    @ViewBuilder let card: Card

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius).fill(.black.opacity(0.35))
                .onTapGesture(perform: cancel)
            card
        }
        .transition(.opacity)
    }
}
