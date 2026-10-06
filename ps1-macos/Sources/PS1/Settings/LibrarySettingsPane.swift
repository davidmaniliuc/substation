import SwiftUI

/// Where the games and the BIOS come from, how discs are grouped, and covers.
struct LibrarySettingsPane: View {
    @Bindable var model: EmulatorViewModel

    var body: some View {
        Form {
            Section("Folders") {
                SettingRow(SettingsCopy.gamesFolder) {
                    FolderButton(name: model.gamesFolderName) { model.chooseGamesFolder() }
                }
                SettingRow(SettingsCopy.biosFolder) {
                    FolderButton(name: model.biosFolderName) { model.chooseBIOSFolder() }
                }
                SettingRow(SettingsCopy.rescan) {
                    Button("Refresh") { model.rescanLibrary() }
                }
            }

            Section("Multi-Disc Games") {
                SettingToggle(SettingsCopy.mergeMultiDisc, isOn: $model.mergeMultiDisc)
            }

            Section {
                SettingRow(SettingsCopy.coverStyle) {
                    Picker(SettingsCopy.coverStyle.title, selection: Binding(
                        get: { model.coverSource.template },
                        set: { model.coverSource = CoverSource(template: $0) }
                    )) {
                        Text("Jewel Case Front").tag(CoverSource.flat)
                        Text("3D Case").tag(CoverSource.threeD)
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                SettingToggle(SettingsCopy.autoCovers, isOn: $model.autoDownloadCovers)

                SettingRow(SettingsCopy.missingCovers) {
                    Button("Download Now") { model.downloadMissingCovers() }
                        .disabled(model.isDownloadingCovers)
                }
            } header: {
                Text("Cover Art")
            } footer: {
                if let status = model.coverDownloadSummary {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The folder's name and a Choose button, as Finder-style settings show them.
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
