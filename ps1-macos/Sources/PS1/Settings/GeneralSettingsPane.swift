import SwiftUI

/// Speed, sound, the library's look and what happens when a game is left.
struct GeneralSettingsPane: View {
    @Bindable var model: EmulatorViewModel

    var body: some View {
        Form {
            Section("Emulation Speed") {
                SettingRow(SettingsCopy.speed) {
                    Picker(SettingsCopy.speed.title, selection: $model.speed) {
                        ForEach(SpeedSetting.choices, id: \.self) { n in
                            Text(n == 1 ? "1× (Normal)" : "\(n)×").tag(n)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                SettingRow(SettingsCopy.fastForward) {
                    Picker(SettingsCopy.fastForward.title, selection: $model.fastForwardSpeed) {
                        ForEach(SpeedSetting.choices.dropFirst(), id: \.self) { n in
                            Text("\(n)×").tag(n)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            Section("Processor") {
                SettingRow(SettingsCopy.cpuEngine) {
                    Picker(SettingsCopy.cpuEngine.title, selection: $model.cpuEngine) {
                        ForEach(CpuEngine.menuOrder.filter(\.isAvailable)) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            Section("Sound") {
                SettingRow(SettingsCopy.volume) {
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $model.volume, in: VolumeSetting.range)
                            .frame(width: 140)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                }

                SettingToggle(SettingsCopy.mute, isOn: Binding(
                    get: { model.isMuted },
                    set: { if $0 != model.isMuted { model.toggleMute() } }
                ))
            }

            Section("Appearance") {
                SettingRow(SettingsCopy.libraryTheme) {
                    Picker(SettingsCopy.libraryTheme.title, selection: $model.libraryTheme) {
                        ForEach(LibraryTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            Section("Leaving a Game") {
                SettingToggle(SettingsCopy.saveOnExit, isOn: $model.saveStateOnExit)
            }
        }
        .formStyle(.grouped)
    }
}
