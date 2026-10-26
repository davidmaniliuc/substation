import SwiftUI

/// Internal resolution, dithering, the two texture filters and the running
/// game's VRAM readbacks: the Video menu's entries.
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
                            Text(SettingsCopy.ditherOptionTitle(mode)).tag(mode)
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
                SettingRow(SettingsCopy.spriteTextureFiltering) {
                    Picker(SettingsCopy.spriteTextureFiltering.title, selection: $model.spriteFilter) {
                        ForEach(TextureFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            // Per game, unlike the rows above: it acts on the running game
            // and is disabled with none, as in the Video menu.
            Section {
                SettingRow(SettingsCopy.vramReadbacks, isEnabled: model.vramReadbacksAvailable) {
                    Picker(SettingsCopy.vramReadbacks.title, selection: $model.vramReadbacks) {
                        ForEach(VramReadbacks.allCases) { choice in
                            Text(model.vramReadbacksTitle(choice)).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } footer: {
                if !model.vramReadbacksAvailable {
                    Text(SettingsCopy.vramReadbacksNoGameFooter)
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
