import SwiftUI
import AppKit

/// A zero-sized view whose only job is to reach the `NSWindow`.
///
/// SwiftUI exposes neither `contentAspectRatio` nor the standard window
/// buttons, and there is no SwiftUI-native way to reach `NSWindowDelegate`
/// either, so an AppKit probe is the whole mechanism regardless of `@State`'s
/// availability (it compiles fine; that was never what forced this shape).
/// `updateNSView` re-runs on every change to the values passed in, which is
/// what drives the chrome fade.
struct WindowConfigurator: NSViewRepresentable {
    /// The PS1 picture is 4:3 whatever its pixel resolution; locking the
    /// window to it means the game fills the window exactly, with no letterbox
    /// bar and nothing cropped.
    static let aspect = NSSize(width: 4, height: 3)
    /// The smallest game the HUD bar and the title strip are laid out for.
    static let minimumSize = NSSize(width: 640, height: 480)

    let lockAspect: Bool
    let chromeVisible: Bool

    /// The ratio to hold the window to, `.zero` meaning "no lock".
    ///
    /// **The lock has to come OFF for fullscreen.** AppKit honours
    /// `contentAspectRatio` there by CENTRING a 4:3 window on a black desktop
    /// rather than filling the screen, which reads as a letterbox with a
    /// rounded-corner window floating in it. The shader letterboxes instead,
    /// and paints every bar black.
    ///
    /// **`styleMask` alone cannot answer that, and trusting it wedged the exit
    /// outright.** AppKit clears `.fullScreen` from the mask PART WAY THROUGH
    /// the exit (measured at 2.4 s into a 0.6 s transition), while the window
    /// is still 1440x900 and still on the fullscreen space. `updateNSView` runs
    /// on every `hudVisible` flip, and the OSD's 2.5 s idle timer lands square
    /// in that gap, so the lock was re-applied to a window AppKit still
    /// considered fullscreen: it snapped the frame to 1160x870, centred that on
    /// the black desktop, and `didExitFullScreen` then did not arrive for 37 s.
    /// A transition in flight is therefore its own answer, and it is the
    /// `Probe`'s notifications that say so rather than the mask.
    ///
    /// A pure function so the rule is reachable from a test without a window:
    /// the same reason `InternalResolution` and `VolumeControlState` are value types.
    static func wantedAspect(lockAspect: Bool,
                             styleMaskIsFullScreen: Bool,
                             transitioning: Bool) -> NSSize {
        (lockAspect && !styleMaskIsFullScreen && !transitioning) ? aspect : .zero
    }

    /// Turns the ratio lock OFF.
    ///
    /// **This goes through `contentResizeIncrements`, and assigning `.zero` to
    /// `contentAspectRatio` does NOT do it.** The two are mutually exclusive
    /// (setting either resets the other), and that is the only supported way to
    /// turn a ratio off. A `.zero` ratio leaves AppKit in ratio mode with a
    /// zero ratio, so the fullscreen-exit restore derives the height from the
    /// width as `713 * 0 / 0` and hands `-[NSWindow _reallySetFrame:]` a frame
    /// of `{{722, 331}, {713, nan}}`. That throws
    /// NSInternalInconsistencyException out of
    /// `-[_NSExitFullScreenTransitionController setupWindowForAfterFullScreenExit]`,
    /// which nothing catches, and the process aborts: to the player, the
    /// picture goes black on leaving fullscreen.
    ///
    /// Reading `contentAspectRatio` back still reports `.zero` either way, so
    /// the guard above is unaffected; only the write differs.
    static func clearAspectLock(on window: NSWindow) {
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
    }

    /// Turns the ratio lock ON, holding the window to `minimumSize`.
    ///
    /// **The minimum has to be the window's own `contentMinSize`.** SwiftUI's
    /// `.frame(minWidth:)` reaches a programmatic resize but not a live one
    /// while a ratio is set: a corner drag took the game's window to 301x226,
    /// where the HUD bar no longer fits and the title runs under the traffic
    /// lights.
    ///
    /// Setting the ratio does not resize an already-open window, so it is
    /// snapped once, otherwise the lock only takes effect on the first drag and
    /// the picture is letterboxed until then. The snap FITS the screen:
    /// deriving the height from the width alone is not enough, since a
    /// restored 1432-wide frame wants to be 1074 tall, AppKit clamps that to
    /// the 862 the screen has and leaves the width alone, and the window ends
    /// up further from 4:3 than it started. It never goes below the minimum
    /// either: SwiftUI reopens the same window for the next game, at whatever
    /// size the last one left it.
    static func lockAspect(on window: NSWindow) {
        window.contentAspectRatio = aspect
        window.contentMinSize = minimumSize

        let frame = window.frame
        let visible = window.screen?.visibleFrame.size ?? frame.size
        var width = max(min(frame.width, visible.width), minimumSize.width)
        var height = (width * aspect.height / aspect.width).rounded()
        if height > visible.height {
            height = visible.height
            width = (height * aspect.width / aspect.height).rounded()
        }
        // Keep the top-left corner put; growing downwards off-screen is worse
        // than growing upwards.
        window.setFrame(
            NSRect(x: frame.minX, y: frame.maxY - height, width: width, height: height),
            display: true)
    }

    func makeNSView(context: Context) -> NSView { Probe() }

    func updateNSView(_ nsView: NSView, context: Context) {
        // `nsView.window` is nil while SwiftUI is still building the hierarchy,
        // so the first application has to wait for the view to be installed.
        guard let probe = nsView as? Probe else { return }
        probe.hidesToolbarInFullScreen = lockAspect
        probe.onWindow = { window, transitioning in
            apply(to: window, transitioning: transitioning)
        }
        if let window = nsView.window {
            apply(to: window, transitioning: probe.inFullScreenTransition)
        }
    }

    private func apply(to window: NSWindow, transitioning: Bool) {
        applyAspect(to: window, transitioning: transitioning)
        applyChrome(to: window)
    }

    private func applyAspect(to window: NSWindow, transitioning: Bool) {
        let wanted = Self.wantedAspect(
            lockAspect: lockAspect,
            styleMaskIsFullScreen: window.styleMask.contains(.fullScreen),
            transitioning: transitioning)

        guard window.contentAspectRatio != wanted else { return }

        guard wanted != .zero else {
            Self.clearAspectLock(on: window)
            return
        }
        Self.lockAspect(on: window)
    }

    private func applyChrome(to window: NSWindow) {
        // Every stage draws its own top edge: the library its glass toolbar
        // over the window's material, a game its full-bleed picture.
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }

        // The pointer is chrome too, and it goes with the rest of it. There is
        // no matching unhide call: `setHiddenUntilMouseMoves` brings it back on
        // the first movement, which is exactly the rule the OSD comes back
        // under (`EmulatorViewModel.hoverMoved`), so the two stay in step
        // without either one having to drive the other.
        if !chromeVisible { NSCursor.setHiddenUntilMouseMoves(true) }

        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        // In full screen the buttons ride in the title bar the menu bar
        // reveals, which only shows when the player asks for it, and a hover
        // there never reaches the game to bring the HUD up: faded with it,
        // the reveal was an empty strip.
        let shown = chromeVisible || window.styleMask.contains(.fullScreen)
        // `alphaValue`, not `isHidden`: hiding makes AppKit reclaim the layout
        // slot and the buttons come back in the wrong place. A 0-alpha button
        // is still hit-testable, which costs nothing here: any click is
        // preceded by a mouse move, and `onContinuousHover` has already brought
        // them back by then.
        NSAnimationContext.runAnimationGroup { ctx in
            // Matches GameHUD's .easeInOut(duration: 0.25) so the two fade as one.
            ctx.duration = 0.25
            for type in buttons {
                window.standardWindowButton(type)?.animator().alphaValue = shown ? 1 : 0
            }
        }
    }

    /// Selector-based observers rather than the closure API: a closure handed to
    /// NotificationCenter is `@Sendable`, and capturing this main-actor NSView
    /// in one does not compile under Swift 6.
    final class Probe: NSView {
        var onWindow: ((NSWindow, Bool) -> Void)?
        /// True from either WILL notification until its matching DID.
        ///
        /// This is the state `styleMask` cannot report: see `wantedAspect`.
        /// `updateNSView` reads it rather than being driven by it, so a SwiftUI
        /// update landing mid-transition leaves the ratio alone instead of
        /// resizing a window AppKit is still animating.
        private(set) var inFullScreenTransition = false
        /// Whether the window shows a game, and so drops its toolbar for
        /// full screen.
        var hidesToolbarInFullScreen = false
        /// The toolbar this probe hid, to show again as full screen ends.
        private var hidToolbar = false
        /// SwiftUI writes its own content minimum over the window's each time
        /// it lays the content out, and that one has no height, since the
        /// lock derives it from the width. AppKit applies the ratio first and
        /// then clamps each side to the minimum on its own, so with SwiftUI's
        /// `{640, 219}` a drag took the game's window to 640x218 (read off the
        /// running app). While the ratio holds, the minimum is put back.
        private var minimums: [NSKeyValueObservation] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            minimums = []
            guard let window else { return }
            minimums = [
                window.observe(\.contentMinSize) { window, _ in Self.holdMinimum(on: window) },
                window.observe(\.minSize) { window, _ in Self.holdMinimum(on: window) },
            ]
            // `updateNSView` does not fire on a fullscreen transition, so all
            // four notifications are observed: the WILL pair opens the window
            // in which the mask lies, the DID pair closes it. WILL-enter is
            // also the only useful hook for entering one: by DID-enter AppKit
            // has already sized the window against the aspect ratio, and
            // clearing it then would not resize anything back.
            for (name, sel) in [
                (NSWindow.willEnterFullScreenNotification, #selector(willEnterFullScreen(_:))),
                (NSWindow.didEnterFullScreenNotification, #selector(didEnterFullScreen(_:))),
                (NSWindow.willExitFullScreenNotification, #selector(willExitFullScreen(_:))),
                (NSWindow.didExitFullScreenNotification, #selector(didExitFullScreen(_:))),
                // Closes the window too: a transition AppKit abandons sends a
                // WILL and no DID (measured: an entry started just after an
                // exit), and the lock stayed off for the rest of the game.
                (Notification.Name.fullScreenTransitionFailed, #selector(transitionFailed(_:))),
            ] {
                center.addObserver(self, selector: sel, name: name, object: window)
            }
            onWindow?(window, false)
        }

        /// KVO calls back on the thread that made the change, and AppKit
        /// sizes windows only on the main thread: asserted, not assumed.
        private nonisolated static func holdMinimum(on window: NSWindow) {
            MainActor.assumeIsolated {
                guard window.contentAspectRatio == WindowConfigurator.aspect,
                      window.contentMinSize != WindowConfigurator.minimumSize
                else { return }
                window.contentMinSize = WindowConfigurator.minimumSize
            }
        }

        /// **A game drops its toolbar for full screen.** The toolbar is an
        /// empty 52 pt band that seats the traffic lights inset in a window;
        /// in full screen the menu bar reveals it whole, an empty strip twice
        /// the title bar's height. Without it the reveal is the title bar and
        /// its buttons. Hidden, never removed: SwiftUI owns the library's
        /// toolbar, and a window that loses its toolbar loses its buttons
        /// (`GameWindow.Marker`).
        private func hideToolbar(_ window: NSWindow) {
            guard hidesToolbarInFullScreen, let toolbar = window.toolbar, toolbar.isVisible else { return }
            toolbar.isVisible = false
            hidToolbar = true
        }

        private func restoreToolbar(_ window: NSWindow) {
            guard hidToolbar else { return }
            hidToolbar = false
            window.toolbar?.isVisible = true
        }

        @objc private func willEnterFullScreen(_ note: Notification) {
            inFullScreenTransition = true
            if let window = note.object as? NSWindow { hideToolbar(window) }
            if let window = note.object as? NSWindow { onWindow?(window, true) }
        }

        @objc private func didEnterFullScreen(_ note: Notification) {
            inFullScreenTransition = false
            if let window = note.object as? NSWindow { onWindow?(window, false) }
        }

        @objc private func willExitFullScreen(_ note: Notification) {
            inFullScreenTransition = true
            if let window = note.object as? NSWindow { restoreToolbar(window) }
        }

        @objc private func didExitFullScreen(_ note: Notification) {
            inFullScreenTransition = false
            if let window = note.object as? NSWindow { onWindow?(window, false) }
        }

        @objc private func transitionFailed(_ note: Notification) {
            inFullScreenTransition = false
            if let window = note.object as? NSWindow, !window.styleMask.contains(.fullScreen) {
                restoreToolbar(window)
            }
            if let window = note.object as? NSWindow { onWindow?(window, false) }
        }

        isolated deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
