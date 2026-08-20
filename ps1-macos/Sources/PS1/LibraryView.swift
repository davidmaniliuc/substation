import SwiftUI

/// The app's home screen: everything under the games folder, as a grid.
struct LibraryView: View {
    @Bindable var library: GameLibrary
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

            if library.isScanning && library.entries.isEmpty {
                ProgressView("Scanning…")
                    .controlSize(.large)
            } else if library.entries.isEmpty {
                emptyState
            } else {
                grid
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 22) {
                ForEach(library.entries) { entry in
                    GameTile(
                        entry: entry,
                        coverURL: coverURL(entry),
                        play: { play(entry) },
                        chooseCover: { chooseCover(entry) },
                        removeCover: coverURL(entry) == nil
                            ? nil : { removeCover(entry) })
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
