import SwiftUI

/// The Library menu.
///
/// A `Commands` type rather than an inline `CommandMenu`, as `VideoCommands`
/// is: `@Bindable` produces a binding directly wherever the model has the
/// property to bind. `Binding(get:set:)` is kept for the controls that have
/// none: a view mode's checkmark and the cover style's template.
///
/// Library ▸ Refresh, Choose Games Folder and Choose BIOS Folder were in
/// File, which had become the folder-and-refresh menu by default rather than
/// by design. `Open Disc…` stays there.
struct LibraryCommands: Commands {
    @Bindable var model: EmulatorViewModel

    var body: some Commands {
        CommandMenu("Library") {
            // A toggle per mode rather than an inline Picker: a shortcut on a
            // Picker's tagged Text is not reliably registered in a menu.
            ForEach(LibraryViewMode.allCases, id: \.self) { mode in
                Toggle(mode.title, isOn: Binding(
                    get: { model.libraryViewMode == mode },
                    set: { if $0 { model.libraryViewMode = mode } }
                ))
                .keyboardShortcut(Self.shortcut(mode), modifiers: [.command, .control])
                .disabled(!model.libraryVisible)
            }

            Button("Actual Size") { model.resetCovers() }
                .keyboardShortcut("0")
                .disabled(!model.canResetCovers)
            Button("Bigger Covers") { model.growCovers() }
                .keyboardShortcut("+")
                .disabled(!model.canGrowCovers)
            Button("Smaller Covers") { model.shrinkCovers() }
                .keyboardShortcut("-")
                .disabled(!model.canShrinkCovers)

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

    /// ⌃⌘1/2, because ⌘1-⌘8 are Video ▸ Internal Resolution.
    private static func shortcut(_ mode: LibraryViewMode) -> KeyEquivalent {
        switch mode {
        case .grid: "1"
        case .list: "2"
        }
    }
}
