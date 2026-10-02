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

    private static let tileMinimum: CGFloat = 132
    private static let tileSpacing: CGFloat = 20
    private static let columns = [GridItem(.adaptive(minimum: tileMinimum, maximum: 180),
                                           spacing: tileSpacing,
                                           alignment: .top)]

    /// The selected tile, by group id, so a rescan that keeps the game keeps
    /// the selection.
    @State private var selection: GameGroup.ID?
    /// How many columns the grid laid out, which up and down step by.
    @State private var columnCount = 1
    @FocusState private var gridFocused: Bool

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
        ScrollViewReader { proxy in
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
                            isSelected: selection == group.id,
                            select: {
                                selection = group.id
                                gridFocused = true
                            },
                            play: { play(group.first) },
                            chooseCover: { chooseCover(group.first) },
                            downloadCover: group.first.serial == nil
                                ? nil : { downloadCover(group.first) },
                            removeCover: url == nil
                                ? nil : { removeCover(group.first) })
                        .id(group.id)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                    columnCount = GridSelection.columns(
                        width: $0, minimum: Self.tileMinimum, spacing: Self.tileSpacing)
                }
                .padding(24)
                // The title bar is hidden but the window still reserves its height,
                // and the grid scrolls under it.
                .padding(.top, 24)
                // The gaps between tiles: a click there clears the selection,
                // as it does in Apple Music.
                .background {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture {
                            selection = nil
                            gridFocused = true
                        }
                }
            }
            .focusable()
            .focused($gridFocused)
            .focusEffectDisabled()
            .onAppear { gridFocused = true }
            .onMoveCommand { direction in
                let index = groups.firstIndex { $0.id == selection }
                guard let next = GridSelection.move(
                    from: index, direction, count: groups.count, columns: columnCount)
                else { return }
                selection = groups[next].id
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(groups[next].id) }
            }
            .onExitCommand { selection = nil }
            .onKeyPress(.return) {
                guard let group = groups.first(where: { $0.id == selection }) else {
                    return .ignored
                }
                play(group.first)
                return .handled
            }
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
