import SwiftUI

public struct ContentView: View {
    @Bindable var model: EmulatorViewModel
    @State private var coverSliderDragging = false
    /// The window's width, for the search field's fold.
    @State private var windowWidth: CGFloat = 0
    @Environment(\.openWindow) private var openWindow

    /// The game is in THIS window, in place of the library.
    private var showsGame: Bool { model.stage == .playing && !model.gameInOwnWindow }

    /// Which game the game window should be showing, or nil when it should
    /// not be open: a new game in it brings it to the front.
    private var gameWindowRunner: ObjectIdentifier? {
        guard model.gameWindowShown, let runner = model.runner else { return nil }
        return ObjectIdentifier(runner)
    }

    /// The cover-size slider's binding: it moves the live size ONLY during a
    /// drag. AppKit pushes values back through a slider's binding with no
    /// drag at all, and one hosted run opened the grid at an off-step 119.47
    /// that way. The cost is that keyboard and VoiceOver adjustment of the
    /// slider is ignored; Library ▸ Bigger/Smaller Covers (⌘+/⌘−) cover it.
    /// A drag snaps to the same column steps those two take.
    private var coverSizeWhileDragging: Binding<Double> {
        Binding(get: { model.libraryTileSize },
                set: { if coverSliderDragging { model.dragCovers(to: $0) } })
    }

    public init(model: EmulatorViewModel) { self.model = model }

    /// Finder's arrangement: the title at the leading edge, and the controls
    /// trailing in groups, the cover size in one capsule and the view
    /// switcher, pinned to the trailing edge, in its own.
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
        // The slider sits LEFT of the switcher: it exists in grid view only,
        // and on this side its coming and going never moves the switcher.
        if model.libraryViewMode == .grid {
            ToolbarItem(placement: .primaryAction) {
                // Photos' arrangement: a − and a + either side of the track,
                // each a click that takes one column step, as ⌘−/⌘+ do.
                HStack(spacing: 6) {
                    coverStepButton("minus", help: "Smaller Covers",
                                    enabled: model.canShrinkCovers) { model.shrinkCovers() }
                    Slider(value: coverSizeWhileDragging,
                           in: LibraryLayoutSetting.sizeRange(width: Double(model.libraryGridWidth),
                                                              height: Double(model.libraryGridHeight)),
                           onEditingChanged: { editing in
                               // Persist only a drag the player made and released.
                               if editing {
                                   coverSliderDragging = true
                               } else if coverSliderDragging {
                                   coverSliderDragging = false
                                   model.commitCoverSize()
                               }
                           }) {
                        Text("Cover Size")
                    }
                    .labelsHidden()
                    // A slim knob, as Finder's: at regular size the glass knob
                    // is taller than the track it sits on.
                    .controlSize(.small)
                    .frame(width: 100)
                    .help("Cover Size")
                    coverStepButton("plus", help: "Bigger Covers",
                                    enabled: model.canGrowCovers) { model.growCovers() }
                }
                .padding(.horizontal, 6)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

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
                folds: LibrarySearchLayout.folds(width: windowWidth,
                                                 viewMode: model.libraryViewMode),
                focusRequest: model.librarySearchFocusRequest)
        }
    }

    private func coverStepButton(_ symbol: String, help: String, enabled: Bool,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .medium))
                .frame(width: 12, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!enabled)
        .help(help)
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
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
                    playStats: model.playStats.all,
                    sortOrder: $model.librarySortOrder,
                    gridWidth: $model.libraryGridWidth,
                    gridHeight: $model.libraryGridHeight)
            } else {
                OnboardingView(model: model)
            }

            // In this window wherever the game is: it answers the click on a
            // tile or Open Disc, both of which happen here.
            if let offer = model.resumeOffer {
                GlassDialog {
                    ResumePromptSheet(offer: offer) { model.chooseResume($0) }
                }
            }
        }
        .animation(.smooth(duration: 0.2), value: model.resumeOffer?.id)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .frame(minWidth: 640, minHeight: 480)
        // Hidden by the title bar style, but it is what the Window menu,
        // Mission Control and the Dock's window list show.
        .navigationTitle(showsGame ? model.discTitle : "Substation")
        // Library only: a game keeps its full-bleed picture and glass HUD.
        .toolbar {
            if model.libraryVisible { libraryToolbar }
        }
        .toolbar(model.libraryVisible ? .visible : .hidden, for: .windowToolbar)
        // The theme's scheme for the library and its toolbar, the system's
        // everywhere else. It must be the WINDOW's appearance: the toolbar's
        // glass capsules are AppKit and ignore an environment value (with
        // `.environment(\.colorScheme, .dark)` they stayed white on black
        // under a Light system). SwiftUI owns that appearance and re-asserts
        // its preference on every update, nil included (measured: a hand-set
        // `darkAqua` was back to nil within a second), so leaving the library
        // does return the window, and only this window, to the system's.
        .preferredColorScheme(model.libraryVisible ? model.libraryTheme.colorScheme : nil)
        // Zero-sized, so it cannot affect layout: it only reaches the NSWindow.
        // The traffic lights stay put outside play: there is no HUD there to
        // bring them back with.
        .background(WindowConfigurator(
            lockAspect: showsGame,
            chromeVisible: !showsGame || model.hudVisible,
            opaqueTitlebar: model.libraryVisible
        ))
        .background(CloseInterceptor(shouldClose: { model.requestExit(.closeWindow) == .proceed }))
        // The game window opens for each game that goes in it, and comes
        // forward when its exit sheet goes up, whichever window asked.
        .onChange(of: gameWindowRunner) { _, runner in
            if runner != nil { openWindow(id: GameWindow.id) }
        }
        .onChange(of: model.exitPrompt) { _, prompt in
            if prompt != nil && model.gameWindowShown { openWindow(id: GameWindow.id) }
        }
        .alert("Could not load", isPresented: .init(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Opened as a raw .bin", isPresented: $model.showRawBinWarning) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("A raw .bin is a single data track at LBA 0 and cannot represent audio tracks. If this game has CD-DA music, it will be silent. Open the .cue instead.")
        }
        // `presenting:` hands each button the failure it was raised for, so
        // Fresh Boot still has its URL whichever runs first: the action or
        // the dismissal clearing `resumeFailure`.
        .alert("Could not resume", isPresented: .init(
            get: { model.resumeFailure != nil },
            set: { if !$0 { model.resumeFailure = nil } }
        ), presenting: model.resumeFailure) { failure in
            Button("Fresh Boot") {
                model.resumeFailure = nil
                model.load(disc: failure.freshBoot)
            }
            Button("Cancel", role: .cancel) { model.cancelResumeFailure() }
        } message: { failure in
            Text(failure.message)
        }
    }
}

