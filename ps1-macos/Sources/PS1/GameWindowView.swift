import AppKit
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

/// The running game: its picture, the title strip, the bar, the badge stack
/// and the exit sheet. Its window supplies the chrome (`WindowConfigurator`). Shown in the library's window
/// or in a window of its own (`GameWindowView`), never both.
struct GameScreen: View {
    @Bindable var model: EmulatorViewModel
    /// From the hosting window's own transitions (`FullScreenReader`).
    @State private var isFullScreen = false

    private var menuOpen: Bool { model.isOpen(.pauseMenu) }

    /// The coordinate space the hover and the speed tab's frame share.
    nonisolated static let space = "game"

    var body: some View {
        ZStack(alignment: .bottom) {
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

                // The menu stands in for both while it is open.
                let chrome = model.hudVisible && !menuOpen
                TitleStrip(model: model, isFullScreen: isFullScreen)
                    .frame(maxHeight: .infinity, alignment: .top)
                    // In the title bar's band, level with the traffic
                    // lights, not below the safe area they reserve.
                    .ignoresSafeArea(edges: .top)
                    .opacity(chrome ? 1 : 0)
                    .animation(.easeInOut(duration: 0.25), value: chrome)

                GameHUD(model: model, isVisible: chrome, isFullScreen: isFullScreen)
                    .padding(.bottom, 24)

                if menuOpen {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture { model.setSurface(.pauseMenu, open: false) }
                        .transition(.opacity)
                    PauseMenu(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(16)
                        // Below the traffic lights, which stay up with it.
                        .padding(.top, isFullScreen ? 0 : 24)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                if model.isPaused && !menuOpen && !model.isOpen(.saveStates)
                    && !model.isDialogShown {
                    PausedIndicator(model: model)
                        .transition(.scale(scale: 1.25).combined(with: .opacity))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                BadgeStack(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    // In fullscreen as high as the screen allows, level with
                    // the title; windowed, the traffic lights' band is above.
                    .padding(.trailing, isFullScreen ? TitleStrip.trailing : 16)
                    .padding(.top, isFullScreen ? TitleStrip.fullScreenTop : 16)
            }

            // Here rather than over the library: the sheet asks about the
            // game, so it sits on the game's picture wherever that is.
            if let intent = model.exitPrompt {
                GlassDialog {
                    ConfirmExitSheet(intent: intent,
                                     saveState: $model.saveStateOnExit,
                                     cancel: { model.cancelExit() },
                                     confirm: { model.confirmExit() })
                }
            }
        }
        .animation(.smooth(duration: 0.2), value: model.exitPrompt)
        .animation(.snappy(duration: 0.3), value: menuOpen)
        .animation(.snappy(duration: 0.25), value: model.isPaused)
        .animation(.snappy(duration: 0.25), value: model.hudVisible)
        // The point, not just the phase: this callback also fires for a click,
        // and re-showing on it would undo `hideHUDNow` in the same runloop
        // turn. `hoverMoved` re-shows only when the pointer has actually moved.
        .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
            if case .active(let point) = phase { model.hoverMoved(to: point) }
        }
        .coordinateSpace(.named(Self.space))
        .background(FullScreenReader { isFullScreen = $0 })
        .onAppear { model.showHUDThenHide() }
    }
}

/// The game's own window, used when Settings ▸ General ▸ Open Games In is
/// New Window. It exists only while that game runs, or while a disc opened
/// from outside the library asks its resume question: it closes itself when
/// the game ends, and closing it ejects the game, through the same exit sheet
/// Eject asks with. It is independent of the library's window: either can be
/// closed while the other stays.
public struct GameWindowView: View {
    @Bindable var model: EmulatorViewModel

    public init(model: EmulatorViewModel) { self.model = model }

    public var body: some View {
        ZStack {
            // Black under a launch's sheet. The game is drawn only when it is
            // this window's: a Finder open over a game in the library's
            // window asks here while that game is still installed there.
            Color.black.ignoresSafeArea()
            if model.stage == .playing && model.gameInOwnWindow {
                GameScreen(model: model)
            }
        }
            .frame(minWidth: 640, minHeight: 480)
            .navigationTitle(model.discTitle)
            // Locked to 4:3 with the traffic lights fading with the HUD, as
            // the library's window is while it shows a game.
            .background(WindowConfigurator(lockAspect: true, chromeVisible: model.hudVisible,
                                           opaqueTitlebar: false))
            .background(GameWindow.Marker(shown: model.gameWindowShown,
                                          fullScreenPending: model.gameWindowFullScreenPending,
                                          enteredFullScreen: { model.gameWindowEnteredFullScreen() }))
            .background(CloseInterceptor(shouldClose: { model.closeGameWindow() }))
            .modifier(GameWindowOpener(model: model))
            .modifier(LaunchDialogs(model: model, active: model.launchInGameWindow))
            // `initial`: a window opened with no game in it (restored, or
            // reopened by the system) closes at once.
            .onChange(of: model.gameWindowShown, initial: true) { _, shown in
                if !shown { GameWindow.close() }
            }
    }
}

@MainActor
enum GameWindow {
    static let id = "game"
    /// Kept across a close: SwiftUI REOPENS the same `NSWindow` for the next
    /// game rather than building a new one, and the marker inside it never
    /// moves to a window again. Clearing this on close left the next game
    /// with no window on record, so every key was declined as the library's
    /// and its eject closed nothing.
    static weak var current: NSWindow?

    /// By window NUMBER, as `SettingsWindow.owns`: the key monitor may only
    /// carry Sendable values across into the main actor.
    static func owns(windowNumber: Int) -> Bool {
        guard let current else { return false }
        return current.windowNumber == windowNumber
    }

    /// Through AppKit: measured, `dismissWindow(id:)` left the window open,
    /// empty and without its traffic lights, once the game had ended.
    /// `close()` also skips `windowShouldClose`, which would only ask to eject
    /// a game that has already gone.
    static func close() {
        current?.close()
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
        let shown: Bool
        let fullScreenPending: Bool
        let enteredFullScreen: () -> Void

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
            GameWindow.current = window
            probe.onScreen()
        }

        private final class Probe: NSView {
            var marker: Marker?
            private var observers: [NSObjectProtocol] = []

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard let window else { return }
                GameWindow.current = window
                // Opened with no game in it: the `onChange` that would close
                // it ran before the window existed.
                // A turn later: not from inside AppKit's own window setup.
                if marker?.shown == false { DispatchQueue.main.async { GameWindow.close() } }
                // The window is REOPENED for the next game with this same
                // view, and an update may run before it is on screen: its
                // coming forward is the moment both actions below wait for.
                // Becoming visible as well as key: an app launched in the
                // background puts it on screen without making it key.
                observers.forEach(NotificationCenter.default.removeObserver)
                observers = [NSWindow.didBecomeKeyNotification,
                             NSWindow.didChangeOcclusionStateNotification].map { name in
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                        [weak self] _ in MainActor.assumeIsolated { self?.onScreen() }
                    }
                }
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
