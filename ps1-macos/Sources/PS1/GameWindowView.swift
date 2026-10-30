import AppKit
import SwiftUI

/// The running game: its picture, the title strip, the bar, the badge stack
/// and the exit sheet. Its window supplies the chrome (`WindowConfigurator`). Shown in the library's window
/// or in a window of its own (`GameWindowView`), never both.
struct GameScreen: View {
    @Bindable var model: EmulatorViewModel
    @Bindable var game: OpenGame
    /// From the hosting window's own transitions (`FullScreenReader`).
    @State private var isFullScreen = false
    /// The same, but changed only once the window has stopped moving: the
    /// bar's symbol replace run DURING the transition's resize lands its
    /// layer outside the bar, or drops it.
    @State private var settledFullScreen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var menuOpen: Bool { game.isOpen(.pauseMenu) }

    /// The coordinate space the hover and the speed tab's frame share.
    nonisolated static let space = "game"

    var body: some View {
        ZStack(alignment: .bottom) {
            if let host = game.hostView {
                // The menu stands in for both while it is open.
                let chrome = game.hudVisible && !menuOpen
                GameDisplayView(host: host)
                    // On the host and nothing else: the representable cannot
                    // swap the view it made, so a new session in the same
                    // window needs a new identity. A scale or depth change is
                    // the session's to rebuild for, not SwiftUI's.
                    .id(ObjectIdentifier(host))
                    // The toolbar band behind the title strip.
                    .onChange(of: chrome, initial: true) { _, b in game.session?.setBandShown(b) }
                    .ignoresSafeArea()
                    // On the picture only, so it sits BELOW the HUD in
                    // this ZStack and a click on an OSD button presses
                    // the button rather than dismissing the OSD.
                    .onTapGesture { game.hideHUDNow() }

                TitleStrip(model: model, game: game, isFullScreen: isFullScreen)
                    .frame(maxHeight: .infinity, alignment: .top)
                    // In the title bar's band, level with the traffic
                    // lights, not below the safe area they reserve.
                    .ignoresSafeArea(edges: .top)
                    .opacity(chrome ? 1 : 0)
                    .animation(.easeInOut(duration: 0.25), value: chrome)

                GameHUD(model: model, game: game, isVisible: chrome, isFullScreen: settledFullScreen)
                    .padding(.bottom, 24)

                if menuOpen {
                    Color.black.opacity(0.2)
                        .ignoresSafeArea()
                        .onTapGesture { game.setSurface(.pauseMenu, open: false) }
                        .transition(.opacity)
                    // Flush to the edge and the full height, the traffic
                    // lights inside it; it slides, and under Reduce Motion
                    // it fades.
                    PauseMenu(model: model, game: game, isFullScreen: isFullScreen)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .ignoresSafeArea()
                        .transition(reduceMotion ? .opacity : .move(edge: .leading))
                }

                if game.showsPaused && !menuOpen && !game.isOpen(.saveStates)
                    && !model.isDialogShown {
                    PausedIndicator(model: model, game: game)
                        .transition(.scale(scale: 1.25).combined(with: .opacity))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                BadgeStack(model: model, game: game)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    // In fullscreen as high as the screen allows, level with
                    // the title; windowed, the traffic lights' band is above.
                    .padding(.trailing, isFullScreen ? TitleStrip.trailing : 16)
                    .padding(.top, isFullScreen ? TitleStrip.fullScreenTop : 16)
            }

            // Here rather than over the library: the sheet asks about the
            // game, so it sits on the game's picture wherever that is.
            if let intent = game.exitPrompt {
                ModalDialog {
                    ConfirmExitSheet(intent: intent,
                                     saveState: $model.saveStateOnExit,
                                     cancel: { model.cancelExit() },
                                     confirm: { model.confirmExit() })
                }
            }
        }
        .animation(.smooth(duration: 0.2), value: game.exitPrompt)
        .animation(.snappy(duration: 0.3), value: menuOpen)
        .animation(.snappy(duration: 0.25), value: game.showsPaused)
        .animation(.snappy(duration: 0.25), value: game.hudVisible)
        // The point, not just the phase: this callback also fires for a click,
        // and re-showing on it would undo `hideHUDNow` in the same runloop
        // turn. `hoverMoved` re-shows only when the pointer has actually moved.
        .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
            if case .active(let point) = phase { game.hoverMoved(to: point) }
        }
        .coordinateSpace(.named(Self.space))
        .background(FullScreenReader { fullScreen, settled in
            isFullScreen = fullScreen
            if settled { settledFullScreen = fullScreen }
        })
        .onAppear { game.showHUDThenHide() }
    }
}

/// What a game window holds: a game, by the id it was given at load, or a
/// launch's alerts before there is one. `WindowGroup(for:)` keys a window by
/// it, so it is `Codable`, and a `UUID` rather than an `ObjectIdentifier`.
enum GameWindowContent: Hashable, Codable, Sendable {
    case launch
    case game(UUID)
}

/// A game's own window, used when Settings ▸ General ▸ Open Games In is
/// New Window. It exists only while its content is wanted: it closes itself
/// when the game ends, and closing it ejects the game, through the same exit
/// sheet Eject asks with. It is independent of the library's window: either
/// can be closed while the other stays.
public struct GameWindowView: View {
    @Bindable var model: EmulatorViewModel
    let content: GameWindowContent

    /// The model still wants this window: its game is open, or its
    /// launch's alerts are up.
    private var shown: Bool { model.wantsWindow(content) }

    /// The game this window holds, while it is still open.
    private var game: OpenGame? {
        guard case .game(let id) = content else { return nil }
        return model.game(with: id)
    }

    public var body: some View {
        ZStack {
            // Black under a launch's alerts.
            Color.black.ignoresSafeArea()
            if let game, shown {
                GameScreen(model: model, game: game)
            }
        }
            // No minimum height: the 4:3 lock derives it from the width, and
            // one here would apply below the toolbar band (`ContentView`).
            .frame(minWidth: 640)
            .navigationTitle(game?.discTitle ?? "")
            // Locked to 4:3 with the traffic lights fading with the HUD, as
            // the library's window is while it shows a game.
            .background(WindowConfigurator(lockAspect: true, chromeVisible: game?.hudVisible ?? true))
            // The toolbar's band and the white title strip are a game's dark
            // chrome under a Light system too.
            .preferredColorScheme(.dark)
            .background(GameWindow.Marker(content: content, shown: shown,
                                          fullScreenPending: game?.fullScreenPending ?? false,
                                          enteredFullScreen: { game?.enteredFullScreen() },
                                          occluded: { game?.session?.setOccluded($0) },
                                          becameKey: { if let game { model.gameWindowBecameKey(game.id) } }))
            .background(CloseInterceptor(shouldClose: { model.closeGameWindow(content) }, showsGame: { true }))
            .modifier(GameWindowOpener(model: model))
            .modifier(LaunchDialogs(model: model, active: model.launchInGameWindow && content == .launch))
            // `initial`: a window opened with nothing to show (restored, or
            // reopened by the system) closes at once.
            .onChange(of: shown, initial: true) { _, shown in
                if !shown { GameWindow.close(content) }
            }
    }
}

@MainActor
enum GameWindow {
    static let id = "game"

    private final class Weak {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }

    /// Every game window on screen, by what it holds. A `WindowGroup` builds
    /// a NEW `NSWindow` for each value, unlike the single `Window` scene this
    /// replaced, which reopened one window for every game; so a window is
    /// forgotten as it closes (`Marker`), and recorded again by the next
    /// window's marker.
    private static var windows: [GameWindowContent: Weak] = [:]

    static func record(_ window: NSWindow, for content: GameWindowContent) {
        windows[content] = Weak(window)
    }

    static func forget(_ content: GameWindowContent) {
        windows[content] = nil
    }

    static func window(for content: GameWindowContent) -> NSWindow? {
        windows[content]?.window
    }

    /// By window NUMBER, as `SettingsWindow.owns`: the key monitor may only
    /// carry Sendable values across into the main actor.
    static func content(owningWindowNumber number: Int) -> GameWindowContent? {
        windows.first { $0.value.window?.windowNumber == number }?.key
    }

    static func owns(windowNumber: Int) -> Bool {
        content(owningWindowNumber: windowNumber) != nil
    }

    /// Through AppKit: measured, `dismissWindow(id:)` left the window open,
    /// empty and without its traffic lights, once the game had ended.
    /// `close()` also skips `windowShouldClose`, which would only ask to eject
    /// a game that has already gone.
    static func close(_ content: GameWindowContent) {
        window(for: content)?.close()
    }

    /// Takes the window into full screen for a game that asked for it
    /// (Settings ▸ General ▸ Open in Full Screen). Once per load: a player who
    /// leaves full screen mid-game is not put back.
    private static func enterFullScreen(_ window: NSWindow) {
        // A turn later: a window still being ordered in ignores the request.
        DispatchQueue.main.async {
            if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        }
    }

    struct Marker: NSViewRepresentable {
        let content: GameWindowContent
        let shown: Bool
        let fullScreenPending: Bool
        let enteredFullScreen: () -> Void
        /// Whether the window is hidden from view: a covered or minimised
        /// window's picture is not presented.
        let occluded: (Bool) -> Void
        /// The window came forward: its game runs.
        let becameKey: () -> Void

        func makeNSView(context: Context) -> NSView {
            let probe = Probe()
            probe.marker = self
            return probe
        }

        /// Records the window on every update as well as on the move: a
        /// reopened window keeps its view, so only an update sees it again.
        func updateNSView(_ nsView: NSView, context: Context) {
            guard let probe = nsView as? Probe else { return }
            probe.marker = self
            guard let window = nsView.window else { return }
            GameWindow.record(window, for: content)
            probe.onScreen()
        }

        private final class Probe: NSView {
            var marker: Marker?
            private var observers: [NSObjectProtocol] = []

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard let window, let content = marker?.content else { return }
                GameWindow.record(window, for: content)
                // An empty unified toolbar, as the library's window keeps
                // during a game: it seats the traffic lights inset in a
                // 52 pt band rather than tight in the corner, and the title
                // strip sits beside them. Transparent under `.hiddenTitleBar`,
                // so the picture stays full-bleed. Never `.toolbar(.hidden)`
                // here: that removes the buttons outright.
                if window.toolbar == nil { window.toolbar = NSToolbar() }
                window.toolbarStyle = .unified
                // Opened with no game in it: the `onChange` that would close
                // it ran before the window existed.
                // A turn later: not from inside AppKit's own window setup.
                if marker?.shown == false { DispatchQueue.main.async { GameWindow.close(content) } }
                // An update may run before the window is on screen: its
                // coming forward is the moment both actions below wait for.
                // Becoming visible as well as key: an app launched in the
                // background puts it on screen without making it key.
                observers.forEach(NotificationCenter.default.removeObserver)
                observers = [NSWindow.didBecomeKeyNotification,
                             NSWindow.didChangeOcclusionStateNotification].map { name in
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                        [weak self] _ in MainActor.assumeIsolated {
                            if name == NSWindow.didChangeOcclusionStateNotification { self?.occlusionChanged() }
                            if name == NSWindow.didBecomeKeyNotification { self?.marker?.becameKey() }
                            self?.onScreen()
                        }
                    }
                }
                observers.append(NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { [weak window] _ in MainActor.assumeIsolated {
                    // Only if no newer window took the content over.
                    if GameWindow.window(for: content) === window { GameWindow.forget(content) }
                } })
            }

            /// The session presents nothing while none of the window shows.
            func occlusionChanged() {
                guard let window else { return }
                marker?.occluded(!window.occlusionState.contains(.visible))
            }

            /// The game window is up with its game or its launch in it: the
            /// library can give way, and a pending full screen is taken.
            func onScreen() {
                guard let marker, marker.shown, let window, window.isVisible else { return }
                LibraryWindow.gameWindowOpened()
                if marker.fullScreenPending {
                    marker.enteredFullScreen()
                    GameWindow.enterFullScreen(window)
                }
            }
        }
    }
}
