import SwiftUI

/// The words for one setting: a title, the one-line summary shown under it,
/// and optional detail shown in the row's info popover.
///
/// All of the Settings window's copy lives in `SettingsCopy` as values of this
/// type rather than inline in the views, so it can be read and edited in one
/// place and so `SettingsCopyTests` can hold it to the house style.
struct SettingInfo: Sendable {
    let title: String
    let summary: String
    /// What the setting does, in more depth than the summary.
    var details: String? = nil
    /// Where it makes a visible difference, with named games where measured.
    var helps: String? = nil
    /// Where it goes wrong, and what that looks like.
    var caution: String? = nil

    var hasMore: Bool { details != nil || helps != nil || caution != nil }

    var allText: [String] {
        [title, summary, details, helps, caution].compactMap { $0 }
    }
}

/// One Settings row: the title and summary on the left, the control on the
/// right, and an info button between them when there is more to say.
///
/// `isEnabled` disables the CONTROL only. The info button stays live, because
/// a setting that cannot be changed yet is exactly the one a new player wants
/// to read about before turning on what it depends on.
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
            HStack(spacing: 8) {
                if info.hasMore { InfoButton(info: info) }
                control.disabled(!isEnabled)
            }
        } label: {
            Text(info.title)
            Text(info.summary)
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

private struct InfoButton: View {
    let info: SettingInfo
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("About \(info.title)")
        .accessibilityLabel("About \(info.title)")
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            InfoPopover(info: info)
        }
    }
}

private struct InfoPopover: View {
    let info: SettingInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(info.title).font(.headline)
            if let details = info.details {
                Text(details)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let helps = info.helps {
                Part(heading: "Where It Helps", symbol: "checkmark.circle", tint: .green, text: helps)
            }
            if let caution = info.caution {
                Part(heading: "Things to Watch For", symbol: "exclamationmark.triangle", tint: .orange, text: caution)
            }
        }
        .font(.callout)
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }

    private struct Part: View {
        let heading: String
        let symbol: String
        let tint: Color
        let text: String

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Label(heading, systemImage: symbol)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tint)
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
