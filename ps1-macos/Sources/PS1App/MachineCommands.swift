import SwiftUI

/// The Machine menu.
///
/// A `Commands` type rather than an inline `CommandMenu` in `PS1App.body` for
/// the reason `VideoCommands` gives: `@Bindable` produces the speed pickers'
/// bindings directly.
struct MachineCommands: Commands {
    @Bindable var model: EmulatorViewModel

    var body: some Commands {
        CommandMenu("Machine") {
            Button(model.isPaused ? "Resume" : "Pause") { model.isPaused.toggle() }
                .keyboardShortcut("p")
            Button("Reset") { model.reset() }
                .keyboardShortcut("r")
            Button("Toggle Analog") { model.toggleAnalog() }
                .disabled(model.stage != .playing || model.isPaused || model.isDialogShown)
            Button("Eject Disc") { model.eject() }
                .keyboardShortcut("e")

            Divider()

            Menu("Change Disc") {
                ForEach(Array(model.currentDiscs.enumerated()), id: \.element.id) { index, disc in
                    Button {
                        model.changeDisc(to: disc)
                    } label: {
                        // The checkmark is drawn rather than set through a
                        // Picker: the list is not a preference, it is an
                        // action per item, and a Picker would re-select on
                        // a swap that has not been applied yet.
                        Text(index == model.currentDiscIndex
                             ? "✓ \(disc.title)" : "   \(disc.title)")
                    }
                }
            }
            .disabled(model.currentDiscs.count < 2)

            Divider()

            // Preferences rather than per-session controls, so Pickers with
            // the system's checkmark, as Video ▸ Internal Resolution is. ⌥⌘
            // because ⌘1…⌘8 are already the internal resolutions.
            Picker("Speed", selection: $model.speed) {
                ForEach(SpeedSetting.choices, id: \.self) { n in
                    Text("\(n)×")
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [.command, .option])
                        .tag(n)
                }
            }
            .pickerStyle(.menu)

            Picker("Fast-Forward Speed (Hold Tab)", selection: $model.fastForwardSpeed) {
                ForEach(SpeedSetting.choices.dropFirst(), id: \.self) { n in
                    Text("\(n)×").tag(n)
                }
            }
            .pickerStyle(.menu)
        }
    }
}
