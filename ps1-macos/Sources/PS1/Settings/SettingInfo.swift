import SwiftUI

/// A settings label and an optional description shown beneath it.
struct SettingInfo: Sendable {
    let title: String
    var description: String? = nil

    var allText: [String] {
        [title, description].compactMap { $0 }
    }
}

/// Keeps the description readable when the control is disabled.
struct SettingRow<Control: View>: View {
    let info: SettingInfo
    let isEnabled: Bool
    let control: Control

    init(_ info: SettingInfo, isEnabled: Bool = true,
         @ViewBuilder control: () -> Control) {
        self.info = info
        self.isEnabled = isEnabled
        self.control = control()
    }

    var body: some View {
        LabeledContent {
            control.disabled(!isEnabled)
        } label: {
            Text(info.title)
            if let description = info.description { Text(description) }
        }
    }
}

/// A switch row, the common case.
struct SettingToggle: View {
    let info: SettingInfo
    @Binding var isOn: Bool
    var isEnabled = true

    init(_ info: SettingInfo, isOn: Binding<Bool>, isEnabled: Bool = true) {
        self.info = info
        self._isOn = isOn
        self.isEnabled = isEnabled
    }

    var body: some View {
        SettingRow(info, isEnabled: isEnabled) {
            Toggle(info.title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}
