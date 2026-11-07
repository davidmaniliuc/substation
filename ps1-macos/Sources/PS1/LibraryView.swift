import SwiftUI

/// The app's home screen: everything under the games folder, as a grid of
/// covers in one rounded panel over the window's material, with a line of
/// key hints beneath. A game's details live in the resume sheet a tile opens,
/// never in a second panel beside the grid.
struct LibraryView: View {
    @Bindable var library: GameLibrary
    /// Already narrowed by the toolbar's tab and search.
    let groups: [GameGroup]
    /// The grid's order; Library ▸ Sort By binds the same model property.
    @Binding var order: LibraryOrder
    /// The open tab, for the panel's header and what an empty one says.
    var tab: LibraryTab = .all
    /// When each game was last played, for the tiles' second line.
    var lastPlayed: [GameGroup.ID: Date] = [:]
    /// Every game in the library, for the hint line's "12 of 21".
    var totalCount: Int = 0
    /// The search that narrowed `groups`: an empty result under one is "no
    /// results", never the no-games-folder state.
    var searchText: String = ""
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

    /// The grid's tile width, from `EmulatorViewModel.libraryTileSize`.
    var tileSize: CGFloat = LibraryLayoutSetting.defaultSize

    private static let tileSpacing = CGFloat(LibraryLayoutSetting.tileSpacing)
    private static let tileStretch = CGFloat(LibraryLayoutSetting.tileStretch)
    private static let rowSpacing = CGFloat(LibraryLayoutSetting.rowSpacing)

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: tileSize, maximum: tileSize * Self.tileStretch),
                  spacing: Self.tileSpacing, alignment: .top)]
    }

    /// The panel's inset from the window's edges.
    private static let panelInset = Design.Spacing.m
    private static let panelRadius = Design.Radius.panel
    /// The one inset inside the panel, on both sides: the header, the grid,
    /// the status banner and the hint line below all keep their content on it.
    private static let contentInset = Design.Spacing.l

    /// The selected tile, by group id, so a rescan that keeps the game keeps
    /// the selection.
    @State private var selection: GameGroup.ID?
    /// The grid's laid-out width, from `EmulatorViewModel.libraryGridWidth`;
    /// the column count is derived from it and the tile size, so either
    /// changing re-derives it, and Bigger/Smaller Covers step from it.
    @Binding var gridWidth: CGFloat
    /// The grid's visible height, from `EmulatorViewModel.libraryGridHeight`,
    /// which bounds the biggest cover.
    @Binding var gridHeight: CGFloat
    private var columnCount: Int {
        GridSelection.columns(width: gridWidth, minimum: tileSize, spacing: Self.tileSpacing)
    }
    @FocusState private var gridFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var isSearching: Bool { !searchText.allSatisfy(\.isWhitespace) }

    var body: some View {
        VStack(spacing: 0) {
            panel
                .padding(.horizontal, Self.panelInset)
            LibraryHints(shown: groups.count, total: totalCount,
                         inset: Self.panelInset + Self.contentInset)
        }
        .animation(.easeOut(duration: 0.3), value: downloadStatus)
    }

    /// The covers on a plain fill with a hairline: the content layer, over
    /// the window's material, and never glass (HIG Materials).
    private var panel: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                if library.isScanning && groups.isEmpty && !isSearching {
                    ProgressView("Scanning…")
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if groups.isEmpty && !isSearching && tab == .all {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // A search keeps the grid in place, empty or not: swapped
                    // out for "No Results", it was rebuilt as a query matched
                    // again, and its `onAppear` took the keyboard from the
                    // search field mid-word.
                    grid
                        .overlay {
                            if groups.isEmpty {
                                // Clicks reach the grid beneath, so a click on it
                                // still ends the search's focus.
                                emptyResult.allowsHitTesting(false)
                            }
                        }
                }

                if isDownloading || downloadStatus != nil {
                    statusBanner
                }
            }
        }
        .background(InsetFill(), in: Design.cardShape(Self.panelRadius))
        .overlay {
            Design.cardShape(Self.panelRadius)
                .strokeBorder(.separator, lineWidth: Design.hairline)
        }
        .clipShape(Design.cardShape(Self.panelRadius))
    }

    /// The tab's name and how many games it shows, and the grid's order.
    private var header: some View {
        HStack(spacing: Design.Spacing.s) {
            Image(systemName: tab.symbol)
                .font(.body)
                .foregroundStyle(.secondary)
            Text(tab.title)
                .font(.headline)
            Text("\(groups.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: Design.Spacing.s)
            // Recently Played's newest-first order is the tab itself.
            if tab != .recent {
                LibraryOrderPill(order: $order)
            }
        }
        .padding(.horizontal, Self.contentInset)
        .frame(minHeight: 44)
    }

    /// "No Results" under a search; under an empty tab, what fills it.
    @ViewBuilder private var emptyResult: some View {
        if isSearching {
            ContentUnavailableView.search(text: searchText)
        } else if tab == .recent {
            ContentUnavailableView("Nothing Played Yet", systemImage: LibraryTab.recent.symbol,
                                   description: Text("Games you play appear here, most recent first."))
        } else {
            ContentUnavailableView("No Games", systemImage: tab.symbol)
        }
    }

    /// Bottom-trailing, over the grid: the covers appear behind it as they
    /// land, which is the part worth watching.
    private var statusBanner: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: Design.Spacing.s) {
                    if isDownloading {
                        ProgressView().controlSize(.small)
                        Text("Downloading covers…")
                    } else if let downloadStatus {
                        Text(downloadStatus)
                    }
                }
                .font(.callout)
                .padding(.horizontal, Design.Spacing.m)
                .padding(.vertical, Design.Spacing.s)
                // Material, not glass: the banner floats over the covers in
                // the content layer, where glass is reserved for controls.
                .background(.thickMaterial, in: .capsule)
                .accessibilityElement(children: .combine)
                .padding(Self.contentInset)
            }
        }
        .transition(.opacity)
    }

    /// The one place a game's menu rules live: no
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
                LazyVGrid(columns: columns, spacing: Self.rowSpacing) {
                    ForEach(groups) { group in
                        // The group's first disc carries its cover and is what
                        // Play opens; a multi-disc game always starts on disc 1,
                        // and Machine ▸ Change Disc moves between them.
                        let url = coverURL(group.first)
                        let menu = contextMenu(for: group)
                        GameTile(
                            entry: group.first,
                            title: group.title,
                            subtitle: LibraryFormat.tileSubtitle(discs: group.discCount,
                                                                 lastPlayed: lastPlayed[group.id]),
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
                .padding(Self.contentInset)
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
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                gridHeight = $0
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
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
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                    proxy.scrollTo(groups[next].id)
                }
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
        ContentUnavailableView {
            Label(library.folderURL.map { "No games found in \($0.lastPathComponent)" }
                  ?? "No games folder chosen",
                  systemImage: LibraryTab.all.symbol)
        } description: {
            Text("A game is a .cue, .chd, .ccd, .mds, .pbp or .ecm file, or a .bin, .iso or .img in a folder with no .cue. Subfolders are scanned too.")
        } actions: {
            Button("Choose Games Folder…", action: chooseFolder)
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Key hints under the panel, with how much of the library a search or a
/// tab shows when it is not all of it.
private struct LibraryHints: View {
    let shown: Int
    let total: Int
    let inset: CGFloat

    var body: some View {
        KeyHints(hints: [("↩", "Play"), ("⌘F", "Search"), ("⌘,", "Settings")]) {
            if shown != total {
                Text("\(shown) of \(total)").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, inset)
    }
}
