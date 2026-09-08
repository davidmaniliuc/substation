import SwiftUI

/// The app's home screen: everything under the games folder, as a grid.
struct LibraryView: View {
    @Bindable var library: GameLibrary
    let groups: [GameGroup]
    let coverURL: (GameEntry) -> URL?
    let play: (GameEntry) -> Void
    let chooseCover: (GameEntry) -> Void
    let downloadCover: (GameEntry) -> Void
    let removeCover: (GameEntry) -> Void
    let chooseFolder: () -> Void
    /// A sweep's result, or nil when none has run. Shown in the grid rather
    /// than as a sheet: a library with covers for two thirds of its discs is
    /// the normal outcome, not something to interrupt anyone with.
    var downloadStatus: String? = nil
    var isDownloading: Bool = false

    private static let columns = [GridItem(.adaptive(minimum: 132, maximum: 180),
                                           spacing: 20,
                                           alignment: .top)]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if library.isScanning && groups.isEmpty {
                ProgressView("Scanning…")
                    .controlSize(.large)
            } else if groups.isEmpty {
                emptyState
            } else {
                grid
            }

            if isDownloading || downloadStatus != nil {
                statusBanner
            }
        }
    }

    /// Bottom-trailing, over the grid: the covers appear behind it as they
    /// land, which is the part worth watching.
    private var statusBanner: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 8) {
                    if isDownloading {
                        ProgressView().controlSize(.small)
                        Text("Downloading covers…")
                    } else if let downloadStatus {
                        Text(downloadStatus)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(24)
            }
        }
        .transition(.opacity)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 22) {
                ForEach(groups) { group in
                    // The group's first disc carries its cover and is what
                    // Play opens; a multi-disc game always starts on disc 1,
                    // and Machine ▸ Change Disc moves between them.
                    let url = coverURL(group.first)
                    GameTile(
                        entry: group.first,
                        title: group.title,
                        discCount: group.discs.count,
                        coverURL: url,
                        play: { play(group.first) },
                        chooseCover: { chooseCover(group.first) },
                        downloadCover: group.first.serial == nil
                            ? nil : { downloadCover(group.first) },
                        removeCover: url == nil
                            ? nil : { removeCover(group.first) })
                }
            }
            .padding(24)
            // The title bar is hidden but the window still reserves its height,
            // and the grid scrolls under it.
            .padding(.top, 24)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.tertiary)

            Text(library.folderURL == nil
                 ? "No games folder chosen"
                 : "No games found in \(library.folderURL!.lastPathComponent)")
                .font(.title3.weight(.semibold))

            Text("A game is a .cue file, or a .bin in a folder with no .cue. Subfolders are scanned too.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button("Choose Games Folder…", action: chooseFolder)
                .buttonStyle(.glassProminent)
        }
        .padding(36)
    }
}
