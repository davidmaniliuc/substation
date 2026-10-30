import AppKit
import SwiftUI

/// First launch. Both folders are captured here, either one first, and the
/// pane beside them lists what each holds as it is scanned, so a folder
/// with no BIOS in it is caught here rather than at the first boot.
struct OnboardingView: View {
    @Bindable var model: EmulatorViewModel

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
                setup
            }
            .frame(minWidth: 380)
            .layoutPriority(1)
            Divider().ignoresSafeArea()
            // Gives way first in a narrow window: the folders are the task.
            OnboardingPreview(model: model)
                .frame(minWidth: 240, idealWidth: 340, maxWidth: 340)
                .frame(maxHeight: .infinity)
                .background(.background.secondary)
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 24)
            Text("Set Up Your Library")
                .font(.title2.weight(.semibold))
            Text("Substation needs a BIOS from your console and a folder of games.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            VStack(spacing: 4) {
                FolderRow(
                    symbol: "cpu",
                    title: model.biosFolderURL == nil ? "Choose BIOS Folder…" : "Change BIOS Folder…",
                    hint: "The SCPH files dumped from your console",
                    folder: model.biosFolderURL,
                    status: biosStatus,
                    choose: model.chooseBIOSFolder,
                    drop: model.setBIOSFolder)
                FolderRow(
                    symbol: "opticaldisc",
                    title: model.gamesFolderURL == nil ? "Choose Games Folder…" : "Change Games Folder…",
                    hint: "Disc images in .cue, .chd, .ccd, .ecm, .iso or .bin, in any subfolder",
                    folder: model.gamesFolderURL,
                    status: model.library.isScanning ? .scanning : .found,
                    choose: model.chooseGamesFolder,
                    drop: model.setGamesFolder)
            }
            // The rows' hover highlight reaches past the text column, so the
            // symbols line up with the title above.
            .padding(.horizontal, -12)
            .padding(.top, 24)

            Spacer(minLength: 24)

            HStack {
                Text("You can change these later in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Library") { model.finishOnboarding() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.onboardingReady)
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: 460)
        .padding(.horizontal, 32)
    }

    private var biosStatus: FolderRow.Status {
        if model.isSurveyingBios { return .scanning }
        return model.biosFound.isEmpty ? .empty : .found
    }
}

/// One folder to choose: a symbol tile, the action, and under it the chosen
/// folder or what belongs there. A folder dragged from Finder onto the row
/// counts as choosing it.
private struct FolderRow: View {
    enum Status { case scanning, found, empty }

    let symbol: String
    let title: String
    let hint: String
    let folder: URL?
    let status: Status
    let choose: () -> Void
    let drop: (URL) -> Void
    @State private var targeted = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 38, height: 38)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Group {
                        if let folder {
                            Text((folder.path as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(folder.path)
                        } else {
                            Text(hint).lineLimit(2)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if folder != nil { badge }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(RowButtonStyle())
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(.tint, lineWidth: 2)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first,
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { return false }
            drop(url)
            return true
        } isTargeted: { targeted = $0 }
    }

    @ViewBuilder private var badge: some View {
        switch status {
        case .scanning:
            ProgressView().controlSize(.small)
        case .found:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .accessibilityLabel("Ready")
        case .empty:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.yellow)
                .accessibilityLabel("No BIOS images found")
        }
    }
}

/// A borderless row that highlights under the pointer and darkens while
/// pressed. It never moves: a Mac hover brightens, it does not lift.
private struct RowButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.fill.opacity(configuration.isPressed ? 1 : hovering ? 0.6 : 0),
                        in: .rect(cornerRadius: 8))
            .onHover { hovering = $0 }
    }
}

/// What the two folders hold: each BIOS image by region and model, and each
/// game as the library will show it.
private struct OnboardingPreview: View {
    let model: EmulatorViewModel

    var body: some View {
        if model.biosFolderURL == nil && model.gamesFolderURL == nil {
            ContentUnavailableView {
                Label("Your Library", systemImage: "square.stack")
            } description: {
                Text("The BIOS images and games in your folders appear here.")
            }
        } else {
            List {
                Section {
                    biosRows
                } header: {
                    header("BIOS", count: model.biosFolderURL == nil || model.isSurveyingBios
                           ? nil : model.biosFound.count)
                }
                Section {
                    gameRows
                } header: {
                    header("Games", count: model.gamesFolderURL == nil || model.library.isScanning
                           ? nil : model.groups.count)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private var biosRows: some View {
        if model.biosFolderURL == nil {
            Text("No folder chosen").foregroundStyle(.tertiary)
        } else if model.isSurveyingBios {
            scanning
        } else if model.biosFound.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("No BIOS Images Found", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                Text("Substation looks for the SCPH files dumped from a PlayStation. Games can’t start without one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        } else {
            ForEach(model.biosFound, id: \.self) { found in
                Label {
                    if let image = found.image {
                        LabeledContent(GameInfo.region(image.region), value: GameInfo.model(image))
                    } else {
                        LabeledContent {
                            Text("Unidentified")
                        } label: {
                            Text(found.file).lineLimit(1).truncationMode(.middle)
                        }
                    }
                } icon: {
                    Image(systemName: "cpu")
                }
            }
        }
    }

    @ViewBuilder private var gameRows: some View {
        if model.gamesFolderURL == nil {
            Text("No folder chosen").foregroundStyle(.tertiary)
        } else if model.library.isScanning {
            scanning
        } else if model.groups.isEmpty {
            Text("No games in this folder").foregroundStyle(.secondary)
        } else {
            ForEach(model.groups) { group in
                Label {
                    HStack {
                        Text(group.title).lineLimit(1)
                        Spacer(minLength: 4)
                        if !model.isSurveyingBios, let region = model.missingBios(for: group.first) {
                            missingBios(region)
                        }
                    }
                } icon: {
                    Image(systemName: "opticaldisc")
                }
            }
        }
    }

    /// Only the games that cannot start are marked: a region beside every
    /// title crowded the titles out of a narrow pane.
    private func missingBios(_ needed: BiosRegion) -> some View {
        let region = GameInfo.region(needed)
        return Image(systemName: "exclamationmark.triangle.fill")
            .symbolRenderingMode(.multicolor)
            .help("No BIOS for \(region) in the BIOS folder")
            .accessibilityLabel("No BIOS for \(region)")
    }

    private var scanning: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Scanning…").foregroundStyle(.secondary)
        }
    }

    private func header(_ title: String, count: Int?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let count { Text("\(count)").monospacedDigit() }
        }
        .padding(.trailing, 10)
    }
}
