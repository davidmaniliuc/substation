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

/// The running game: its picture, the HUD, the speed badge and the exit
/// sheet. Its window supplies the chrome (`WindowConfigurator`). Shown in the library's window
/// or in a window of its own (`GameWindowView`), never both.
struct GameScreen: View {
    @Bindable var model: EmulatorViewModel

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

                GameHUD(model: model, isVisible: model.hudVisible)
                    .padding(.bottom, 28)

                SpeedBadge(speed: model.effectiveSpeed)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 36)
                    .padding(.trailing, 16)

                PadNotice(text: model.padNotice)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 36)

                MemoryCardBadge(saving: model.savingToMemoryCard)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 36)
                    .padding(.leading, 16)
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
        // The point, not just the phase: this callback also fires for a click,
        // and re-showing on it would undo `hideHUDNow` in the same runloop
        // turn. `hoverMoved` re-shows only when the pointer has actually moved.
        .onContinuousHover { phase in
            if case .active(let point) = phase { model.hoverMoved(to: point) }
        }
        .onAppear { model.showHUDThenHide() }
    }
}

/// The game's own window, used when Settings ▸ General ▸ Open Games In is
/// New Window. It exists only while that game runs: it closes itself when the
/// game ends, and closing it ejects the game, through the same exit sheet
/// Eject asks with.
public struct GameWindowView: View {
    @Bindable var model: EmulatorViewModel

    public init(model: EmulatorViewModel) { self.model = model }

    public var body: some View {
        GameScreen(model: model)
            .frame(minWidth: 640, minHeight: 480)
            .navigationTitle(model.discTitle)
            // Locked to 4:3 with the traffic lights fading with the HUD, as
            // the library's window is while it shows a game.
            .background(WindowConfigurator(lockAspect: true, chromeVisible: model.hudVisible,
                                           opaqueTitlebar: false))
            .background(GameWindow.Marker(shown: model.gameWindowShown))
            .background(CloseInterceptor(shouldClose: { model.closeGameWindow() }))
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

    struct Marker: NSViewRepresentable {
        let shown: Bool

        func makeNSView(context: Context) -> NSView {
            let probe = Probe()
            probe.shown = shown
            return probe
        }

        /// Records the window on every update as well as on the move: a
        /// reopened window keeps its view, so only an update sees it again.
        func updateNSView(_ nsView: NSView, context: Context) {
            (nsView as? Probe)?.shown = shown
            if let window = nsView.window { GameWindow.current = window }
        }

        private final class Probe: NSView {
            var shown = true

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard let window else { return }
                GameWindow.current = window
                // Opened with no game in it: the `onChange` that would close
                // it ran before the window existed.
                // A turn later: not from inside AppKit's own window setup.
                if !shown { DispatchQueue.main.async { GameWindow.close() } }
            }
        }
    }
}
