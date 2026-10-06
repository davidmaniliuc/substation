import SwiftUI

/// The app's home screen: everything under the games folder, as a grid of
/// covers or a sortable list.
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
    /// An exit or resume dialog drawn over the grid. It is not a sheet, so
    /// the grid would keep focus under it and take Return and Escape before
    /// the dialog's default and cancel buttons could.
    var isDialogShown: Bool = false

    var viewMode: LibraryViewMode = .grid
    var theme: LibraryTheme = LibraryThemeSetting.defaultTheme
    /// The grid's tile width, from `EmulatorViewModel.libraryTileSize`.
    var tileSize: CGFloat = LibraryLayoutSetting.defaultSize
    /// Per-game play history, for the list's Last Played and Play Time columns.
    var playStats: [String: PlayStats] = [:]
    /// The list's sort, from `EmulatorViewModel.librarySortOrder`.
    @Binding var sortOrder: [KeyPathComparator<LibraryRow>]

    private static let tileSpacing: CGFloat = 20
    /// Today's 132:180 minimum-to-maximum ratio, kept at every size so the
    /// columns still stretch to fill the width.
    private static let tileStretch: CGFloat = 1.36

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: tileSize, maximum: tileSize * Self.tileStretch),
                  spacing: Self.tileSpacing, alignment: .top)]
    }

    /// The selected tile, by group id, so a rescan that keeps the game keeps
    /// the selection.
    @State private var selection: GameGroup.ID?
    /// The grid's laid-out width; the column count is derived from it and
    /// the tile size, so either changing re-derives it.
    @State private var gridWidth: CGFloat = 0
    private var columnCount: Int {
        GridSelection.columns(width: gridWidth, minimum: tileSize, spacing: Self.tileSpacing)
    }
    @FocusState private var gridFocused: Bool

    var body: some View {
        ZStack {
            theme.backdrop.ignoresSafeArea()

            if library.isScanning && groups.isEmpty {
                ProgressView("Scanning…")
                    .controlSize(.large)
            } else if groups.isEmpty {
                emptyState
            } else if viewMode == .list {
                list
            } else {
                grid
            }

            if isDownloading || downloadStatus != nil {
                statusBanner
            }
        }
        .animation(.easeOut(duration: 0.3), value: downloadStatus)
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

    /// Shares `selection` with the grid, so switching views keeps the game.
    private var list: some View {
        LibraryTable(
            rows: LibraryRow.rows(groups, entries: library.entries, stats: playStats),
            selection: $selection,
            theme: theme,
            coverURL: coverURL,
            play: { play($0.first) },
            menu: contextMenu(for:),
            sortOrder: $sortOrder)
        .focused($gridFocused)
        .onAppear { gridFocused = !isDialogShown }
        .onChange(of: isDialogShown) { _, shown in gridFocused = !shown }
    }

    /// The one place a game's menu rules live, for the grid and the list: no
    /// download without a serial to look up, no removal without a cover.
    private func contextMenu(for group: GameGroup) -> GameContextMenu {
        let entry = group.first
        return GameContextMenu(
            entry: entry,
            play: { play(entry) },
            chooseCover: { chooseCover(entry) },
            downloadCover: entry.serial == nil ? nil : { downloadCover(entry) },
            removeCover: coverURL(entry) == nil ? nil : { removeCover(entry) })
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(groups) { group in
                        // The group's first disc carries its cover and is what
                        // Play opens; a multi-disc game always starts on disc 1,
                        // and Machine ▸ Change Disc moves between them.
                        let url = coverURL(group.first)
                        let menu = contextMenu(for: group)
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
                            play: menu.play,
                            chooseCover: menu.chooseCover,
                            downloadCover: menu.downloadCover,
                            removeCover: menu.removeCover)
                        .id(group.id)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                    gridWidth = $0
                }
                .padding(24)
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
            .onAppear { gridFocused = !isDialogShown }
            .onChange(of: isDialogShown) { _, shown in gridFocused = !shown }
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
