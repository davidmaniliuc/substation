import SwiftUI

/// The app's home screen: everything under the games folder, as a grid.
struct LibraryView: View {
    @Bindable var library: GameLibrary
    let groups: [GameGroup]
    let coverURL: (GameEntry) -> URL?
    let play: (GameEntry) -> Void
    let chooseCover: (GameEntry) -> Void
    let removeCover: (GameEntry) -> Void
    let chooseFolder: () -> Void

    private static let columns = [GridItem(.adaptive(minimum: 132, maximum: 180),
                                           spacing: 20)]

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
        }
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
