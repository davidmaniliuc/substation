import SwiftUI

/// The keyboard layout, rebindable, and how game controllers are picked up.
///
/// Clicking a key starts a capture on the model (`beginCapture`): the row
/// shows `WaitingDots` until the next key-down in this window binds it, and a
/// click anywhere else cancels. The bindings are `model.keyBindings`, the same
/// value `keyDown`/`keyUp` read, so a change applies to a running game at once.
struct ControlsSettingsPane: View {
    @Bindable var model: EmulatorViewModel

    var body: some View {
        Form {
            Section("Controller") {
                SettingToggle(SettingsCopy.vibration, isOn: $model.vibration)
                SettingRow(SettingsCopy.rewindPadButton) {
                    Picker(SettingsCopy.rewindPadButton.title, selection: $model.rewindPadButton) {
                        ForEach(RewindSetting.PadButton.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            Section {
                ForEach(KeyBindings.controls, id: \.self) { control in
                    LabeledContent(control.title) {
                        KeyBindingField(
                            key: model.keyBindings.key(for: control),
                            isCapturing: model.capturing == control,
                            begin: { model.beginCapture(control) })
                    }
                }
            } header: {
                HStack {
                    Text("Keyboard")
                    Spacer()
                    Button("Restore Defaults") { model.restoreDefaultKeyBindings() }
                        .controlSize(.small)
                        .disabled(model.keyBindings.isDefault)
                }
            }

            Section("Shortcuts While Playing") {
                SettingRow(SettingsCopy.fastForwardKey) { KeyCap("Tab") }
                SettingRow(SettingsCopy.pauseKey) { KeyCap("⌘P") }
                SettingRow(SettingsCopy.resetKey) { KeyCap("⌘R") }
                SettingRow(SettingsCopy.ejectKey) { KeyCap("⌘E") }
                SettingRow(SettingsCopy.analogButton) { KeyCap("Home") }
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
        // A capture left running would take the first key typed in the
        // window the next time it opens.
        .onDisappear { model.cancelCapture() }
    }
}

/// A binding's key cap: click it, and it waits for a key.
private struct KeyBindingField: View {
    let key: UInt16?
    let isCapturing: Bool
    let begin: () -> Void

    var body: some View {
        Button(action: begin) {
            if isCapturing {
                KeyCapShape { WaitingDots() }
            } else if let key {
                KeyCap(KeyName.of(key))
            } else {
                KeyCap("Not Set").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(isCapturing ? "Press a key, or click elsewhere to cancel" : "Click to change")
    }
}

/// Three dots with a brightness wave running through them, left to right.
private struct WaitingDots: View {
    private static let period = 1.2

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate / Self.period
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    // Each dot peaks a third of a period after the one before.
                    let phase = (t - Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    let glow = max(0, cos(phase * 2 * .pi))
                    Circle()
                        .frame(width: 6, height: 6)
                        .opacity(0.3 + 0.7 * glow)
                }
            }
            .foregroundStyle(.primary)
            .frame(height: 17)
        }
    }
}

/// A key drawn as a keyboard key.
private struct KeyCap: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        KeyCapShape {
            Text(label)
                .font(.system(.body, design: .rounded).weight(.medium))
                .monospacedDigit()
        }
    }
}

/// The keycap's outline, around whatever it holds.
private struct KeyCapShape<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .frame(minWidth: 44)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
            .contentShape(RoundedRectangle(cornerRadius: 5))
    }
}
