import SwiftUI

struct ConfirmExitSheet: View {
    let intent: ExitIntent
    @Binding var saveState: Bool
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Confirm Exit").font(.headline)
            Text(intent.question)
            Toggle("Save State For Resume", isOn: $saveState)
                .toggleStyle(.checkbox)
            HStack(spacing: 12) {
                Button(action: cancel) { Text("No").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.cancelAction)
                Button(action: confirm) { Text("Yes").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 320)
    }
}
