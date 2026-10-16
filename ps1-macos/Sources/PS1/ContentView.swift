import SwiftUI

public struct ContentView: View {
    @Bindable var model: EmulatorViewModel
    /// The window's width, for the search field's fold.
    @State private var windowWidth: CGFloat = 0

    /// The game is in THIS window, in place of the library.
    private var showsGame: Bool { model.stage == .playing && !model.gameInOwnWindow }

    public init(model: EmulatorViewModel) { self.model = model }

    /// Finder's arrangement: the title at the leading edge, and the view
    /// switcher and the search trailing. The cover size has no control here:
    /// Library ▸ Bigger/Smaller Covers (⌘+/⌘−) step it.
    ///
    /// The title is a toolbar item, not the window title: `.hiddenTitleBar`
    /// hides `navigationTitle` along with the bar, and that style (full-size
    /// content under a hidden bar) is what `WindowConfigurator`'s aspect lock
    /// and traffic-light fade are built on.
    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Library").font(.headline)
                // Not "0 games" beside "Scanning…" during the first scan.
                if !(model.library.isScanning && model.groups.isEmpty) {
                    Text(LibraryFormat.gameCount(model.visibleGroups.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarSpacer(.flexible)
        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: $model.libraryViewMode) {
                ForEach(LibraryViewMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.symbol)
                        .labelStyle(.iconOnly)
                        .help(mode.title)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            LibrarySearchBox(
                text: $model.librarySearch,
                folds: LibrarySearchLayout.folds(width: windowWidth),
                focusRequest: model.librarySearchFocusRequest)
        }
    }

    public var body: some View {
        Group {
            if showsGame {
                GameScreen(model: model)
            } else if model.libraryVisible {
                LibraryView(
                    library: model.library,
                    groups: model.visibleGroups,
                    searchText: model.librarySearch,
                    coverURL: { model.coverURL(for: $0) },
                    play: { model.play($0) },
                    chooseCover: { model.chooseCover(for: $0) },
                    downloadCover: { model.downloadCover(for: $0) },
                    removeCover: { model.removeCover(for: $0) },
                    chooseFolder: { model.chooseGamesFolder() },
                    downloadStatus: model.coverDownloadSummary,
                    isDownloading: model.isDownloadingCovers,
                    isDialogShown: model.isDialogShown,
                    viewMode: model.libraryViewMode,
                    theme: model.libraryTheme,
                    tileSize: CGFloat(model.libraryTileSize),
                    listSize: model.libraryListSize,
                    playStats: model.playStats.all,
                    sortOrder: $model.librarySortOrder,
                    gridWidth: $model.libraryGridWidth,
                    gridHeight: $model.libraryGridHeight)
            } else {
                OnboardingView(model: model)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .frame(minWidth: 640, minHeight: 480)
        // Hidden by the title bar style, but it is what the Window menu,
        // Mission Control and the Dock's window list show.
        .navigationTitle(showsGame ? model.discTitle : "Substation")
        // Library only: a game keeps its full-bleed picture and glass HUD.
        // Emptied rather than hidden: `.toolbar(.hidden)` on a window that
        // never had one (a disc opened from Finder) hides the title bar's
        // container, traffic lights and all, as it does on the game window.
        .toolbar {
            if model.libraryVisible {
                libraryToolbar
            } else if showsGame {
                // An invisible item keeps the unified band its full height,
                // so the traffic lights stay where the library had them and
                // the title strip sits beside them. Emptied, the band
                // collapses and the lights ride up into the corner.
                ToolbarItem(placement: .navigation) {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        // The theme's scheme for the library and its toolbar, the system's
        // everywhere else. It must be the WINDOW's appearance: the toolbar's
        // glass capsules are AppKit and ignore an environment value (with
        // `.environment(\.colorScheme, .dark)` they stayed white on black
        // under a Light system). SwiftUI owns that appearance and re-asserts
        // its preference on every update, nil included (measured: a hand-set
        // `darkAqua` was back to nil within a second), so leaving the library
        // does return the window, and only this window, to the system's.
        .preferredColorScheme(showsGame ? .dark
            : model.stage == .onboarding || model.libraryVisible
            ? model.libraryTheme.colorScheme : nil)
        // Zero-sized, so it cannot affect layout: it only reaches the NSWindow.
        // The traffic lights stay put outside play: there is no HUD there to
        // bring them back with.
        .background(WindowConfigurator(
            lockAspect: showsGame,
            chromeVisible: !showsGame || model.hudVisible,
            opaqueTitlebar: model.libraryVisible
        ))
        .background(CloseInterceptor(shouldClose: { model.closeLibraryWindow() }))
        .background(LibraryWindow.Marker())
        .modifier(GameWindowOpener(model: model))
        // Here for a click on a tile; in the game window for a disc opened
        // from outside the library in New Window mode.
        .modifier(LaunchDialogs(model: model, active: !model.launchInGameWindow))
    }
}

