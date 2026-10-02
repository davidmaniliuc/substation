import SwiftUI

/// Internal resolution and dithering, the two Video menu preferences.
struct VideoSettingsPane: View {
    @Bindable var model: EmulatorViewModel

    var body: some View {
        Form {
            Section {
                SettingRow(SettingsCopy.internalResolution) {
                    Picker(SettingsCopy.internalResolution.title, selection: $model.internalScale) {
                        ForEach(InternalResolution.range, id: \.self) { n in
                            Text(Self.resolutionTitle(n)).tag(n)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            Section {
                SettingRow(SettingsCopy.dithering) {
                    Picker(SettingsCopy.dithering.title, selection: $model.ditherMode) {
                        ForEach(DitherMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } footer: {
                Text(SettingsCopy.ditherMode(model.ditherMode))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    /// Each scale with the picture height it produces, so "4×" means
    /// something to a player who has never seen a 240-line console.
    static func resolutionTitle(_ n: Int) -> String {
        n == 1 ? "1× (240p, Native)" : "\(n)× (\(240 * n)p)"
    }
}
