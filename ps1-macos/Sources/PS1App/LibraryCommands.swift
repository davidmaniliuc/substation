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
            // Two toggles rather than an inline Picker: a shortcut on a
            // Picker's tagged Text is not reliably registered in a menu.
            // ⌃⌘1/2, because ⌘1-⌘8 are Video ▸ Internal Resolution.
            Toggle("as Grid", isOn: Binding(
                get: { model.libraryViewMode == .grid },
                set: { if $0 { model.libraryViewMode = .grid } }
            ))
            .keyboardShortcut("1", modifiers: [.command, .control])
            .disabled(model.stage != .library)
            Toggle("as List", isOn: Binding(
                get: { model.libraryViewMode == .list },
                set: { if $0 { model.libraryViewMode = .list } }
            ))
            .keyboardShortcut("2", modifiers: [.command, .control])
            .disabled(model.stage != .library)

            Button("Bigger Covers") { model.growCovers() }
                .keyboardShortcut("+")
                .disabled(model.stage != .library || model.libraryViewMode != .grid
                          || !model.canGrowCovers)
            Button("Smaller Covers") { model.shrinkCovers() }
                .keyboardShortcut("-")
                .disabled(model.stage != .library || model.libraryViewMode != .grid
                          || !model.canShrinkCovers)

            Divider()

            Toggle("Merge Multi-Disc Games", isOn: $model.mergeMultiDisc)

            Divider()

            // A submenu for the same reason Video ▸ Internal Resolution is
            // one: two related items flattened into the menu bury the
            // folder commands under them. The style is a preference and gets
            // the system's checkmark; the download is an action.
            Menu("Cover Art") {
                Picker("Style", selection: Binding(
                    get: { model.coverSource.template },
                    set: { model.coverSource = CoverSource(template: $0) }
                )) {
                    Text("Jewel Case Front").tag(CoverSource.flat)
                    Text("3D Case").tag(CoverSource.threeD)
                }
                .pickerStyle(.inline)

                Divider()

                Toggle("Download Automatically", isOn: $model.autoDownloadCovers)

                Button("Download Missing Covers") { model.downloadMissingCovers() }
                    .disabled(model.isDownloadingCovers)
            }

            Divider()

            // ⇧⌘R, not ⌘R: that is Reset, in the Machine menu.
            Button("Refresh Library") { model.rescanLibrary() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Choose Games Folder…") { model.chooseGamesFolder() }
            Button("Choose BIOS Folder…") { model.chooseBIOSFolder() }
        }
    }
}
