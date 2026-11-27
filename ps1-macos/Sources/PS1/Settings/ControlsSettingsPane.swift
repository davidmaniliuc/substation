import SwiftUI

/// Controller port routing, vibration, rewind button, and rebindable keyboard
/// and gamepad button mappings.
///
/// Clicking a key or gamepad cap starts a capture on the model
/// (`beginCapture` / `beginGamepadCapture`): the row shows `WaitingDots` until
/// the next key or controller button press binds it, and a click anywhere else
/// cancels. Changes apply to a running game at once.
struct ControlsSettingsPane: View {
    private enum MappingDevice: String, CaseIterable {
        case keyboard = "Keyboard"
        case gamepad = "Gamepad"
    }

    @Bindable var model: EmulatorViewModel
    @State private var mappingDevice: MappingDevice = .keyboard

    var body: some View {
        Form {
            Section("Controller Ports") {
                SettingRow(SettingsCopy.port1Controller) {
                    Picker(SettingsCopy.port1Controller.title, selection: $model.port1ControllerChoice) {
                        Text(model.port1AutomaticTitle).tag(Port1Choice.automatic)
                        Text("Keyboard Only").tag(Port1Choice.keyboardOnly)
                        if !model.connectedControllers.isEmpty {
                            Divider()
                            ForEach(model.connectedControllers) { controller in
                                Text(controller.displayName).tag(Port1Choice.controller(controller.id))
                            }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingRow(SettingsCopy.port2Controller) {
                    Picker(SettingsCopy.port2Controller.title, selection: $model.port2ControllerChoice) {
                        Text(model.port2AutomaticTitle).tag(Port2Choice.automatic)
                        Text("Disconnected").tag(Port2Choice.off)
                        if !model.connectedControllers.isEmpty {
                            Divider()
                            ForEach(model.connectedControllers) { controller in
                                Text(controller.displayName).tag(Port2Choice.controller(controller.id))
                            }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

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
                Picker("Mapping Device", selection: $mappingDevice) {
                    ForEach(MappingDevice.allCases, id: \.self) { device in
                        Text(device.rawValue).tag(device)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: mappingDevice) { _, _ in model.cancelCapture() }

                switch mappingDevice {
                case .keyboard:
                    ForEach(KeyBindings.controls, id: \.self) { control in
                        LabeledContent(control.title) {
                            KeyBindingField(
                                key: model.keyBindings.key(for: control),
                                isCapturing: model.capturing == control,
                                begin: { model.beginCapture(control) })
                        }
                    }
                case .gamepad:
                    ForEach(GamepadBindings.controls, id: \.self) { control in
                        LabeledContent(control.title) {
                            GamepadBindingField(
                                input: model.gamepadBindings.input(for: control),
                                isCapturing: model.capturingGamepad == control,
                                begin: { model.beginGamepadCapture(control) })
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Button Mapping")
                    Spacer()
                    Button("Restore Defaults") {
                        switch mappingDevice {
                        case .keyboard: model.restoreDefaultKeyBindings()
                        case .gamepad: model.restoreDefaultGamepadBindings()
                        }
                    }
                    .controlSize(.small)
                    .disabled(mappingDevice == .keyboard
                              ? model.keyBindings.isDefault
                              : model.gamepadBindings.isDefault)
                }
            } footer: {
                if mappingDevice == .gamepad {
                    Text(SettingsCopy.gamepadMappingFooter)
                }
            }

            Section("Shortcuts While Playing") {
                SettingRow(SettingsCopy.fastForwardKey) { KeyCap("Tab") }
                SettingRow(SettingsCopy.pauseKey) { KeyCap("⌘P") }
                SettingRow(SettingsCopy.resetKey) { KeyCap("⌘R") }
                SettingRow(SettingsCopy.quitGameKey) { KeyCap("⌘E") }
                SettingRow(SettingsCopy.pauseMenuKey) {
                    HStack(spacing: 6) {
                        KeyCap("Esc")
                        KeyCap("Home")
                    }
                }
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
        // A capture left running would take the first key or button pressed
        // the next time the window opens.
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

/// A gamepad binding's cap: click it, and it waits for a controller button.
private struct GamepadBindingField: View {
    let input: GamepadInput?
    let isCapturing: Bool
    let begin: () -> Void

    var body: some View {
        Button(action: begin) {
            if isCapturing {
                KeyCapShape { WaitingDots() }
            } else if let input {
                KeyCap(input.title)
            } else {
                KeyCap("Not Set").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(isCapturing
              ? "Press a controller button, Delete to clear, or click elsewhere to cancel"
              : "Click to change")
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
            .background(.quaternary, in: RoundedRectangle(cornerRadius: Design.Radius.thumbnail))
            .overlay(RoundedRectangle(cornerRadius: Design.Radius.thumbnail).strokeBorder(.separator))
            .contentShape(RoundedRectangle(cornerRadius: Design.Radius.thumbnail))
    }
}
