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

    let lockAspect: Bool
    let chromeVisible: Bool
    /// Whether the title bar draws as a bar rather than as nothing.
    ///
    /// `.hiddenTitleBar` makes it transparent, and a transparent title bar
    /// gets no scroll edge effect: the library's covers slid under the
    /// toolbar with no blur behind it at all. Opaque, the bar is still
    /// titleless and the content still full-size, so the toolbar keeps its
    /// layout and the scroll view gets Photos' blurred band. A game keeps it
    /// transparent: its picture is full-bleed under the hidden toolbar.
    let opaqueTitlebar: Bool

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
    /// the same reason `FpsCounter` and `VolumeControlState` are value types.
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

    func makeNSView(context: Context) -> NSView { Probe() }

    func updateNSView(_ nsView: NSView, context: Context) {
        // `nsView.window` is nil while SwiftUI is still building the hierarchy,
        // so the first application has to wait for the view to be installed.
        guard let probe = nsView as? Probe else { return }
        probe.opaqueTitlebar = opaqueTitlebar
        probe.onWindow = { [weak probe] window, transitioning in
            apply(to: window, transitioning: transitioning, probe: probe)
        }
        if let window = nsView.window {
            apply(to: window, transitioning: probe.inFullScreenTransition, probe: probe)
        }
    }

    private func apply(to window: NSWindow, transitioning: Bool, probe: Probe?) {
        applyAspect(to: window, transitioning: transitioning)
        applyChrome(to: window, probe: probe)
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
        window.contentAspectRatio = wanted

        // Setting the ratio does not resize an already-open window, so snap it
        // once, otherwise the lock only takes effect on the first drag and the
        // picture is letterboxed until then.
        //
        // Snap to a size that FITS the screen. Deriving the height from the
        // width alone is not enough: a restored 1432-wide frame wants to be
        // 1074 tall, AppKit clamps that to the 862 the screen has and leaves
        // the width alone, and the window ends up further from 4:3 than it
        // started.
        let frame = window.frame
        let visible = window.screen?.visibleFrame.size ?? frame.size
        var width = min(frame.width, visible.width)
        var height = (width * Self.aspect.height / Self.aspect.width).rounded()
        if height > visible.height {
            height = visible.height
            width = (height * Self.aspect.width / Self.aspect.height).rounded()
        }
        // Keep the top-left corner put; growing downwards off-screen is worse
        // than growing upwards.
        window.setFrame(
            NSRect(x: frame.minX, y: frame.maxY - height, width: width, height: height),
            display: true)
    }

    private func applyChrome(to window: NSWindow, probe: Probe?) {
        if opaqueTitlebar {
            probe?.holdTitlebarOpaque(window)
        } else if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
        }

        // The pointer is chrome too, and it goes with the rest of it. There is
        // no matching unhide call: `setHiddenUntilMouseMoves` brings it back on
        // the first movement, which is exactly the rule the OSD comes back
        // under (`EmulatorViewModel.hoverMoved`), so the two stay in step
        // without either one having to drive the other.
        if !chromeVisible { NSCursor.setHiddenUntilMouseMoves(true) }

        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        // `alphaValue`, not `isHidden`: hiding makes AppKit reclaim the layout
        // slot and the buttons come back in the wrong place. A 0-alpha button
        // is still hit-testable, which costs nothing here: any click is
        // preceded by a mouse move, and `onContinuousHover` has already brought
        // them back by then.
        NSAnimationContext.runAnimationGroup { ctx in
            // Matches GameHUD's .easeInOut(duration: 0.25) so the two fade as one.
            ctx.duration = 0.25
            for type in buttons {
                window.standardWindowButton(type)?.animator().alphaValue = chromeVisible ? 1 : 0
            }
        }
    }

    /// Selector-based observers rather than the closure API: a closure handed to
    /// NotificationCenter is `@Sendable`, and capturing this main-actor NSView
    /// in one does not compile under Swift 6.
    final class Probe: NSView {
        var onWindow: ((NSWindow, Bool) -> Void)?
        /// The latest `opaqueTitlebar`, for the deferred flip to re-check.
        var opaqueTitlebar = false
        /// The window whose `titlebarAppearsTransparent` is observed.
        private weak var observedWindow: NSWindow?
        nonisolated private static let transparentKey = "titlebarAppearsTransparent"

        /// Makes the title bar opaque a turn later, and again every time
        /// SwiftUI makes it transparent while the library wants it opaque.
        ///
        /// `.hiddenTitleBar` is not applied once: SwiftUI's bar bridge writes
        /// `titlebarAppearsTransparent = true` whenever the toolbar reappears
        /// and on later preference updates, so a single flip on leaving a
        /// game was undone by whichever of those landed after it, and the
        /// library came back with no blur (measured with a breakpoint on the
        /// setter: six writes from SwiftUI on one return). The flip waits a
        /// turn because one made before AppKit has rebuilt the toolbar never
        /// gets the blur back either. The latest wanted value is read again
        /// then, so a game started in between keeps its transparent bar.
        func holdTitlebarOpaque(_ window: NSWindow) {
            guard window.titlebarAppearsTransparent else { return }
            DispatchQueue.main.async { [weak window, weak self] in
                guard let window, self?.opaqueTitlebar == true,
                      window.titlebarAppearsTransparent else { return }
                window.titlebarAppearsTransparent = false
            }
        }

        private func observeTitlebar(of window: NSWindow?) {
            guard observedWindow !== window else { return }
            observedWindow?.removeObserver(self, forKeyPath: Self.transparentKey)
            window?.addObserver(self, forKeyPath: Self.transparentKey, context: nil)
            observedWindow = window
        }

        override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                   change: [NSKeyValueChangeKey: Any]?,
                                   context: UnsafeMutableRawPointer?) {
            guard keyPath == Self.transparentKey, let window = object as? NSWindow else {
                return super.observeValue(forKeyPath: keyPath, of: object,
                                          change: change, context: context)
            }
            MainActor.assumeIsolated {
                if opaqueTitlebar { holdTitlebarOpaque(window) }
            }
        }

        /// True from either WILL notification until its matching DID.
        ///
        /// This is the state `styleMask` cannot report: see `wantedAspect`.
        /// `updateNSView` reads it rather than being driven by it, so a SwiftUI
        /// update landing mid-transition leaves the ratio alone instead of
        /// resizing a window AppKit is still animating.
        private(set) var inFullScreenTransition = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            observeTitlebar(of: window)
            guard let window else { return }
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

        @objc private func willEnterFullScreen(_ note: Notification) {
            inFullScreenTransition = true
            if let window = note.object as? NSWindow { onWindow?(window, true) }
        }

        @objc private func didEnterFullScreen(_ note: Notification) {
            inFullScreenTransition = false
        }

        @objc private func willExitFullScreen(_ note: Notification) {
            inFullScreenTransition = true
        }

        @objc private func didExitFullScreen(_ note: Notification) {
            inFullScreenTransition = false
            if let window = note.object as? NSWindow { onWindow?(window, false) }
        }

        @objc private func transitionFailed(_ note: Notification) {
            inFullScreenTransition = false
            if let window = note.object as? NSWindow { onWindow?(window, false) }
        }

        isolated deinit {
            NotificationCenter.default.removeObserver(self)
            observedWindow?.removeObserver(self, forKeyPath: Self.transparentKey)
        }
    }
}
