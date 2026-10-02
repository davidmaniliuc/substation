import SwiftUI

/// Where the games and the BIOS come from, how discs are grouped, and covers.
struct LibrarySettingsPane: View {
    @Bindable var model: EmulatorViewModel

    var body: some View {
        Form {
            Section("Folders") {
                LabeledContent {
                    FolderButton(name: model.gamesFolderName) { model.chooseGamesFolder() }
                } label: {
                    Text("Games Folder")
                    Text("Where your disc images live. Every .cue in it and its subfolders becomes a game; a .bin counts on its own only when no .cue sits beside it.")
                }

                LabeledContent {
                    FolderButton(name: model.biosFolderName) { model.chooseBIOSFolder() }
                } label: {
                    Text("BIOS Folder")
                    Text("The PlayStation system software dumped from a console, such as SCPH-1001. The right region is picked for each disc automatically.")
                }

                LabeledContent {
                    Button("Refresh Library") { model.rescanLibrary() }
                } label: {
                    Text("Rescan")
                    Text("Looks for games added to the folder since it was last read (⇧⌘R).")
                }
            }

            Section("Multi-Disc Games") {
                Toggle(isOn: $model.mergeMultiDisc) {
                    Text("Merge Multi-Disc Games")
                    Text("Shows a game that shipped on several discs, such as Final Fantasy VII, as one tile. When the game asks for the next disc, use Machine ▸ Change Disc.")
                }
            }

            Section("Cover Art") {
                Picker(selection: Binding(
                    get: { model.coverSource.template },
                    set: { model.coverSource = CoverSource(template: $0) }
                )) {
                    Text("Jewel Case Front").tag(CoverSource.flat)
                    Text("3D Case").tag(CoverSource.threeD)
                } label: {
                    Text("Style")
                    Text("Flat scans of the front of the case, or rendered 3D boxes with a spine. Changing this only affects covers downloaded from now on.")
                }

                Toggle(isOn: $model.autoDownloadCovers) {
                    Text("Download Covers Automatically")
                    Text("Fetches missing covers after each library scan, matched by the serial number on the disc rather than the file name. Covers you chose yourself are never replaced.")
                }

                LabeledContent {
                    Button("Download Now") { model.downloadMissingCovers() }
                        .disabled(model.isDownloadingCovers)
                } label: {
                    Text("Missing Covers")
                    Text(model.coverDownloadSummary
                         ?? "Fetch covers for every game that does not have one yet. You can also right-click a tile to pick your own image.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 600)
    }
}

/// The folder's name and a Choose… button, Finder-style.
private struct FolderButton: View {
    let name: String?
    let choose: () -> Void

    var body: some View {
        HStack {
            if let name {
                Label(name, systemImage: "folder")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Not Set").foregroundStyle(.secondary)
            }
            Button("Choose…", action: choose)
        }
    }
}
