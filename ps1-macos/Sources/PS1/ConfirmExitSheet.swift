import SwiftUI

struct ConfirmExitSheet: View {
    let intent: ExitIntent
    @Binding var saveState: Bool
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(intent.question).font(.headline)
            Toggle("Save state for resume", isOn: $saveState)
                .toggleStyle(.checkbox)
            HStack(spacing: 12) {
                Button(action: cancel) { Text("Cancel").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button(action: confirm) { Text("Quit").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 340)
    }
}
