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
                Text(SettingsCopy.keyboardFooter)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Shortcuts While Playing") {
                SettingRow(SettingsCopy.fastForwardKey) { KeyCap("Tab") }
                SettingRow(SettingsCopy.pauseKey) { KeyCap("⌘P") }
                SettingRow(SettingsCopy.resetKey) { KeyCap("⌘R") }
                SettingRow(SettingsCopy.ejectKey) { KeyCap("⌘E") }
            }

            Section {
                SettingRow(SettingsCopy.controllers) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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
