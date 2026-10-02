import SwiftUI

/// Speed, sound and what happens when a game is left.
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

            Section("Leaving a Game") {
                SettingToggle(SettingsCopy.saveOnExit, isOn: $model.saveStateOnExit)
            }
        }
        .formStyle(.grouped)
    }
}
