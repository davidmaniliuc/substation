import SwiftUI

/// Internal resolution, dithering and texture filtering, the Video menu preferences.
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
            }

            Section {
                SettingRow(SettingsCopy.textureFiltering) {
                    Picker(SettingsCopy.textureFiltering.title, selection: $model.textureFilter) {
                        ForEach(TextureFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
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
