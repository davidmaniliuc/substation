import SwiftUI

public struct ContentView: View {
    @Bindable var model: EmulatorViewModel
    /// The window's width, for what the library toolbar folds.
    @State private var windowWidth: CGFloat = 0

    /// The game is in THIS window, in place of the library.
    private var showsGame: Bool { model.stage == .playing && !model.gameInOwnWindow }

    public init(model: EmulatorViewModel) { self.model = model }

    public var body: some View {
        Group {
            if showsGame {
                GameScreen(model: model)
            } else if model.libraryVisible {
                LibraryView(
                    library: model.library,
                    groups: model.visibleGroups,
                    tab: model.libraryTabShown,
                    lastPlayed: model.lastPlayedByGroup,
                    totalCount: model.groups.count,
                    searchText: model.librarySearch,
                    coverURL: { model.coverURL(for: $0) },
                    play: { model.play($0) },
                    chooseCover: { model.chooseCover(for: $0) },
                    downloadCover: { model.downloadCover(for: $0) },
                    removeCover: { model.removeCover(for: $0) },
                    chooseFolder: { model.chooseGamesFolder() },
                    downloadMissingCovers: { model.downloadMissingCovers() },
                    sort: $model.librarySort,
                    downloadStatus: model.coverDownloadSummary,
                    isDownloading: model.isDownloadingCovers,
                    isDialogShown: model.isDialogShown,
                    tileSize: CGFloat(model.libraryTileSize),
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
                LibraryToolbar(model: model, width: windowWidth)
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
            chromeVisible: !showsGame || model.hudVisible
        ))
        // The library's window is see-through: the desktop shows through the
        // system's material and the panel sits inset on it. Everywhere else
        // the window keeps its own colour.
        .containerBackground(model.libraryVisible ? AnyShapeStyle(.thinMaterial)
                                                  : AnyShapeStyle(.windowBackground),
                             for: .window)
        .background(CloseInterceptor(shouldClose: { model.closeLibraryWindow() }))
        .background(LibraryWindow.Marker())
        .modifier(GameWindowOpener(model: model))
        // Here for a click on a tile; in the game window for a disc opened
        // from outside the library in New Window mode.
        .modifier(LaunchDialogs(model: model, active: !model.launchInGameWindow))
    }
}

