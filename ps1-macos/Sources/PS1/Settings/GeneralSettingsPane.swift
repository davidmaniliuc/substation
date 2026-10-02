import SwiftUI

/// Speed, sound and what happens when a game is left.
struct GeneralSettingsPane: View {
    @Bindable var model: EmulatorViewModel

    var body: some View {
        Form {
            Section("Emulation Speed") {
                Picker(selection: $model.speed) {
                    ForEach(SpeedSetting.choices, id: \.self) { n in
                        Text(n == 1 ? "1× (Normal)" : "\(n)×").tag(n)
                    }
                } label: {
                    Text("Speed")
                    Text("How fast games run. Above 1× the sound is time-stretched so it keeps its pitch. How fast a game can really go depends on your Mac — the FPS readout shows what was reached. Also in Machine ▸ Speed (⌥⌘1–4).")
                }

                Picker(selection: $model.fastForwardSpeed) {
                    ForEach(SpeedSetting.choices.dropFirst(), id: \.self) { n in
                        Text("\(n)×").tag(n)
                    }
                } label: {
                    Text("Fast-Forward Speed")
                    Text("The speed a game runs at while you hold Tab. Useful for skipping long dialogue or grinding.")
                }
            }

            Section("Sound") {
                LabeledContent {
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $model.volume, in: VolumeSetting.range)
                            .frame(minWidth: 140)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Volume")
                    Text("The game's volume, independent of your Mac's system volume.")
                }

                Toggle(isOn: Binding(
                    get: { model.isMuted },
                    set: { if $0 != model.isMuted { model.toggleMute() } }
                )) {
                    Text("Mute")
                    Text("Silences the game without forgetting the volume above.")
                }
            }

            Section("Leaving a Game") {
                Toggle(isOn: $model.saveStateOnExit) {
                    Text("Save Progress When Leaving a Game")
                    Text("Remembers exactly where you were when you quit, eject or close the window, and offers to continue from there next time. This is separate from in-game saves, which always go to the memory card.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 470)
    }
}
