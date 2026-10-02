import SwiftUI

/// The keyboard layout, read-only, and how game controllers are picked up.
///
/// Read-only because the bindings are fixed: `InputMap` keys them on virtual
/// key codes so they stay on the same physical keys on any layout. The table
/// is `InputMap.keyboardLegend`, which a test pins to the bindings themselves.
struct ControlsSettingsPane: View {
    var body: some View {
        Form {
            Section {
                ForEach(InputMap.keyboardLegend, id: \.keyCode) { entry in
                    LabeledContent(entry.button.title) { KeyCap(entry.key) }
                }
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Keys are matched by position, so they stay in the same place on AZERTY, Dvorak and other layouts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Shortcuts While Playing") {
                LabeledContent {
                    KeyCap("Tab")
                } label: {
                    Text("Fast-Forward")
                    Text("Hold to run at the fast-forward speed set in General.")
                }
                LabeledContent {
                    KeyCap("⌘P")
                } label: {
                    Text("Pause / Resume")
                }
                LabeledContent {
                    KeyCap("⌘R")
                } label: {
                    Text("Reset")
                    Text("Restarts the game, like pressing the console's reset button.")
                }
                LabeledContent {
                    KeyCap("⌘E")
                } label: {
                    Text("Eject")
                    Text("Leaves the game and returns to the library.")
                }
            }

            Section {
                LabeledContent {
                    Image(systemName: "gamecontroller.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                } label: {
                    Text("Game Controllers")
                    Text("PlayStation, Xbox and other controllers macOS supports are used automatically as soon as they connect — over Bluetooth or USB, no setup needed.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 600)
    }
}

/// A key drawn as a keyboard key.
private struct KeyCap: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(.body, design: .rounded).weight(.medium))
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .frame(minWidth: 28)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
    }
}
