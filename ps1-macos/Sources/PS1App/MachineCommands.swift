import SwiftUI
import AppKit

/// The Machine menu.
///
/// A `Commands` type rather than an inline `CommandMenu` in `PS1App.body` for
/// the reason `VideoCommands` gives: `@Bindable` produces the speed pickers'
/// bindings directly.
struct MachineCommands: Commands {
    @Bindable var model: EmulatorViewModel

    /// The game the menu acts on: the one running.
    private var game: OpenGame? { model.game }
    private var canUseStates: Bool { game?.canUseStates ?? false }

    var body: some Commands {
        CommandMenu("Machine") {
            Button(game?.isPaused == true ? "Resume" : "Pause") { game?.togglePause() }
                .keyboardShortcut("p")
            Button("Reset") { game?.reset() }
                .keyboardShortcut("r")
            Button("Toggle Analog") { game?.toggleAnalog() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(game == nil || game?.isPaused == true || model.isDialogShown)
            Button("Quit Game") { model.eject() }
                .keyboardShortcut("e")

            Button("Take Screenshot") { game?.takeScreenshot() }
                .keyboardShortcut("s")
                .disabled(game == nil)

            Divider()

            // Preferences, like Speed below, so enabled with no game: the
            // arrows are the D-pad, but a ⌘ combination never reaches the pad.
            Button(model.isMuted ? "Unmute" : "Mute") { model.toggleMuteFromMenu() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Increase Volume") { model.stepVolume(by: 1) }
                .keyboardShortcut(.upArrow)
            Button("Decrease Volume") { model.stepVolume(by: -1) }
                .keyboardShortcut(.downArrow)

            Divider()

            Menu("Change Disc") {
                ForEach(Array((game?.currentDiscs ?? []).enumerated()), id: \.element.id) { index, disc in
                    Button {
                        game?.changeDisc(to: disc)
                    } label: {
                        // The checkmark is drawn rather than set through a
                        // Picker: the list is not a preference, it is an
                        // action per item, and a Picker would re-select on
                        // a swap that has not been applied yet.
                        Text(index == game?.currentDiscIndex
                             ? "✓ \(disc.changeDiscLabel)" : "   \(disc.changeDiscLabel)")
                    }
                }
            }
            .disabled((game?.currentDiscs.count ?? 0) < 2)

            Divider()

            // F1-F6 load and ⇧F1-F6 save: ⌘1-8 are Internal Resolution.
            Menu("Save State") {
                ForEach(Array(StateSource.slots), id: \.self) { n in
                    Button(StateSource.slot(n).menuTitle(game?.stateInfo(.slot(n)))) {
                        game?.saveState(toSlot: n)
                    }
                    .keyboardShortcut(Self.functionKey(n), modifiers: .shift)
                }
            }
            .disabled(!canUseStates)

            Menu("Load State") {
                ForEach([StateSource.resume, .previous], id: \.self) { source in
                    let info = game?.stateInfo(source)
                    Button(source.menuTitle(info)) { game?.loadState(source) }
                        .disabled(info == nil)
                }
                Divider()
                ForEach(Array(StateSource.slots), id: \.self) { n in
                    let info = game?.stateInfo(.slot(n))
                    Button(StateSource.slot(n).menuTitle(info)) { game?.loadState(.slot(n)) }
                        .keyboardShortcut(Self.functionKey(n), modifiers: [])
                        .disabled(info == nil)
                }
            }
            .disabled(!canUseStates)

            Button("Undo Load State") { game?.undoLoadState() }
                .keyboardShortcut("z")
                .disabled(!canUseStates || game?.undoState == nil)

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
