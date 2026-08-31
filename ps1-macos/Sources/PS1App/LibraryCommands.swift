import SwiftUI

/// The Library menu.
///
/// A `Commands` type rather than an inline `CommandMenu`, for the reason
/// `VideoCommands` gives: `@Bindable` produces the toggle's binding directly,
/// where `Binding(get:set:)` would capture the `@MainActor` model in two
/// escaping closures.
///
/// These three items were in File, which had become the folder-and-refresh
/// menu by default rather than by design. `Open Disc…` stays there.
struct LibraryCommands: Commands {
    @Bindable var model: EmulatorViewModel

    var body: some Commands {
        CommandMenu("Library") {
            Toggle("Merge Multi-Disc Games", isOn: $model.mergeMultiDisc)

            Divider()

            // ⇧⌘R, not ⌘R: that is Reset, in the Machine menu.
            Button("Refresh Library") { model.rescanLibrary() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Choose Games Folder…") { model.chooseGamesFolder() }
            Button("Choose BIOS Folder…") { model.chooseBIOSFolder() }
        }
    }
}
