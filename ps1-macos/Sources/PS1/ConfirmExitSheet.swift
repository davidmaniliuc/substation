import SwiftUI

/// The exit prompt: a question for a title, Cancel, and a button named for
/// what it does. Return confirms and Escape cancels. It lays itself out as
/// `ConfirmCard` does, with the one choice a card has no place for.
struct ConfirmExitSheet: View {
    let intent: ExitIntent
    @Binding var saveState: Bool
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(spacing: Design.Spacing.l) {
            Text(intent.title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Toggle("Save state for resume", isOn: $saveState)
                .toggleStyle(.checkbox)
            HStack(spacing: Design.Spacing.buttonGap) {
                Button(action: cancel) { Text("Cancel").frame(minWidth: Design.Size.dialogButton, maxWidth: .infinity) }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button(action: confirm) { Text(intent.verb).frame(minWidth: Design.Size.dialogButton, maxWidth: .infinity) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .buttonBorderShape(.capsule)
            .fixedSize()
            .controlSize(.large)
        }
        .padding(Design.Spacing.dialog)
        .frame(width: Design.Size.card)
    }
}

