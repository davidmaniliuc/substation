import SwiftUI

/// What makes SwiftUI rebuild the display view. A new disc is a new runner and
/// a new queue; a new internal resolution is a new `MetalVram` and therefore a
/// new render texture, new pipelines and a new coordinator. Toggling the
/// EFFECTIVE depth setting is the same kind of change: `MetalVram` allocates
/// its depth texture `.private` or `.memoryless` depending on it, so there is
/// deliberately no reconfiguration path for any of the three.
private struct DisplayIdentity: Hashable {
    let runner: ObjectIdentifier
    let scale: Int
    let depthBuffer: Bool
}

public struct ContentView: View {
    @Bindable var model: EmulatorViewModel
    @State private var coverSliderDragging = false

    /// The cover-size slider's binding: it moves the live size ONLY during a
    /// drag. AppKit pushes values back through a slider's binding with no
    /// drag at all, and one hosted run opened the grid at an off-step 119.47
    /// that way. The cost is that keyboard and VoiceOver adjustment of the
    /// slider is ignored; Library ▸ Bigger/Smaller Covers (⌘+/⌘−) cover it.
    private var coverSizeWhileDragging: Binding<Double> {
        Binding(get: { model.libraryTileSize },
                set: { if coverSliderDragging { model.libraryTileSize = $0 } })
    }

    public init(model: EmulatorViewModel) { self.model = model }

    /// Finder's arrangement: the title at the leading edge, and the controls
    /// trailing in groups, the view switcher in one capsule and the cover
    /// size in its own.
    ///
    /// The title is a toolbar item, not the window title: `.hiddenTitleBar`
    /// hides `navigationTitle` along with the bar, and un-hiding the bar
    /// would put an opaque strip over the game's picture.
    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Library").font(.headline)
                Text(LibraryFormat.gameCount(model.groups.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

        if model.libraryViewMode == .grid {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Slider(value: coverSizeWhileDragging,
                       in: LibraryLayoutSetting.sizeRange,
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
                .frame(width: 100)
                .padding(.horizontal, 4)
                .help("Cover Size")
            }
        }
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            switch model.stage {
            case .playing:
                if let runner = model.runner {
                    // The EFFECTIVE value, not the raw sub-setting: a depth
                    // buffer left on while PGXP itself is off (by the player or
                    // by the game's preset) must build a memoryless plane,
                    // exactly as if the sub-setting were off.
                    let depthBuffer = model.pgxpEffectiveDepthBuffer
                    MetalDisplayView(runner: runner, scale: model.internalScale,
                                     depthBuffer: depthBuffer, ditherMode: model.ditherMode,
                                     textureFilter: model.textureFilter,
                                     spriteFilter: model.spriteFilter)
                        // SwiftUI may otherwise keep this view's identity
                        // across a disc swap and leave the coordinator holding
                        // the PREVIOUS runner. Harmless when it only read
                        // frames; wrong now that it drains a stream. The scale
                        // and depth buffer are in the key for the same reason:
                        // the coordinator owns a texture sized/shaped by both.
                        .id(DisplayIdentity(runner: ObjectIdentifier(runner),
                                            scale: model.internalScale,
                                            depthBuffer: depthBuffer))
                        .ignoresSafeArea()
                        // On the picture only, so it sits BELOW the HUD in
                        // this ZStack and a click on an OSD button presses
                        // the button rather than dismissing the OSD.
                        .onTapGesture { model.hideHUDNow() }

                    GameHUD(model: model, isVisible: model.hudVisible)
                        .padding(.bottom, 28)

                    SpeedBadge(speed: model.effectiveSpeed)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.top, 36)
                        .padding(.trailing, 16)
                }
            case .library:
                LibraryView(
                    library: model.library,
                    groups: model.groups,
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
                    sortOrder: $model.librarySortOrder)
            case .onboarding:
                OnboardingView(model: model)
            }

            if let intent = model.exitPrompt {
                GlassDialog {
                    ConfirmExitSheet(intent: intent,
                                     saveState: $model.saveStateOnExit,
                                     cancel: { model.cancelExit() },
                                     confirm: { model.confirmExit() })
                }
            } else if let offer = model.resumeOffer {
                GlassDialog {
                    ResumePromptSheet(offer: offer) { model.chooseResume($0) }
                }
            }
        }
        .animation(.smooth(duration: 0.2), value: model.exitPrompt)
        .animation(.smooth(duration: 0.2), value: model.resumeOffer?.id)
        .frame(minWidth: 640, minHeight: 480)
        // Hidden by the title bar style, but it is what the Window menu,
        // Mission Control and the Dock's window list show.
        .navigationTitle(model.stage == .playing ? model.discTitle : "Substation")
        // Library only: a game keeps its full-bleed picture and glass HUD.
        .toolbar {
            if model.stage == .library { libraryToolbar }
        }
        .toolbar(model.stage == .library ? .visible : .hidden, for: .windowToolbar)
        .toolbarBackgroundVisibility(model.libraryTheme.toolbarBackground, for: .windowToolbar)
        // The library's theme decides its appearance; a game and onboarding
        // follow the system.
        .preferredColorScheme(model.stage == .library ? model.libraryTheme.colorScheme : nil)
        // Zero-sized, so it cannot affect layout: it only reaches the NSWindow.
        // The traffic lights stay put outside play: there is no HUD there to
        // bring them back with.
        .background(WindowConfigurator(
            lockAspect: model.stage == .playing,
            chromeVisible: model.stage != .playing || model.hudVisible
        ))
        .background(CloseInterceptor(shouldClose: { model.requestExit(.closeWindow) == .proceed }))
        // The point, not just the phase: this callback also fires for a click,
        // and re-showing on it would undo `hideHUDNow` in the same runloop
        // turn. `hoverMoved` re-shows only when the pointer has actually moved.
        .onContinuousHover { phase in
            if case .active(let point) = phase { model.hoverMoved(to: point) }
        }
        .onAppear { model.showHUDThenHide() }
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
