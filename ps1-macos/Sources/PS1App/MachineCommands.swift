import SwiftUI
import AppKit

/// The Machine menu.
///
/// A `Commands` type rather than an inline `CommandMenu` in `PS1App.body` for
/// the reason `VideoCommands` gives: `@Bindable` produces the speed pickers'
/// bindings directly.
struct MachineCommands: Commands {
    @Bindable var model: EmulatorViewModel

    var body: some Commands {
        CommandMenu("Machine") {
            Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }
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

            // F1-F6 load and ⇧F1-F6 save: ⌘1-8 are Internal Resolution.
            Menu("Save State") {
                ForEach(Array(StateSource.slots), id: \.self) { n in
                    Button(StateSource.slot(n).menuTitle(model.stateInfo(.slot(n)))) {
                        model.saveState(toSlot: n)
                    }
                    .keyboardShortcut(Self.functionKey(n), modifiers: .shift)
                }
            }
            .disabled(!model.canUseStates)

            Menu("Load State") {
                ForEach([StateSource.resume, .previous], id: \.self) { source in
                    let info = model.stateInfo(source)
                    Button(source.menuTitle(info)) { model.loadState(source) }
                        .disabled(info == nil)
                }
                Divider()
                ForEach(Array(StateSource.slots), id: \.self) { n in
                    let info = model.stateInfo(.slot(n))
                    Button(StateSource.slot(n).menuTitle(info)) { model.loadState(.slot(n)) }
                        .keyboardShortcut(Self.functionKey(n), modifiers: [])
                        .disabled(info == nil)
                }
            }
            .disabled(!model.canUseStates)

            Button("Undo Load State") { model.undoLoadState() }
                .disabled(!model.canUseStates || model.undoState == nil)

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

    /// F1 is U+F704 (`NSF1FunctionKey`); AppKit takes the private-use
    /// character as that function key's key equivalent.
    private static func functionKey(_ n: Int) -> KeyEquivalent {
        KeyEquivalent(Character(UnicodeScalar(UInt32(NSF1FunctionKey + n - 1))!))
    }
}
