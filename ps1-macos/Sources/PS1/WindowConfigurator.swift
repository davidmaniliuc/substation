import SwiftUI
import AppKit

/// A zero-sized view whose only job is to reach the `NSWindow`.
///
/// SwiftUI exposes neither `contentAspectRatio` nor the standard window
/// buttons, and `@State`/`NSWindowDelegate` are both out of reach in this build
/// (`@State` is a macro whose SwiftUIMacros plugin ships only with Xcode), so
/// an AppKit probe is the whole mechanism. `updateNSView` re-runs on every
/// change to the values passed in, which is what drives the chrome fade.
struct WindowConfigurator: NSViewRepresentable {
    /// The PS1 picture is 4:3 whatever its pixel resolution — locking the
    /// window to it means the game fills the window exactly, with no letterbox
    /// bar and nothing cropped.
    static let aspect = NSSize(width: 4, height: 3)

    let lockAspect: Bool
    let chromeVisible: Bool

    func makeNSView(context: Context) -> NSView { Probe() }

    func updateNSView(_ nsView: NSView, context: Context) {
        // `nsView.window` is nil while SwiftUI is still building the hierarchy,
        // so the first application has to wait for the view to be installed.
        (nsView as? Probe)?.onWindow = apply(to:enteringFullScreen:)
        if let window = nsView.window { apply(to: window, enteringFullScreen: false) }
    }

    private func apply(to window: NSWindow, enteringFullScreen: Bool) {
        applyAspect(to: window, enteringFullScreen: enteringFullScreen)
        applyChrome(to: window)
    }

    private func applyAspect(to window: NSWindow, enteringFullScreen: Bool) {
        // **The lock has to come OFF for fullscreen.** AppKit honours
        // contentAspectRatio there by CENTRING a 4:3 window on a black desktop
        // rather than filling the screen, which reads as a letterbox with a
        // rounded-corner window floating in it. The shader letterboxes instead,
        // and now paints every bar black.
        let isFullScreen = enteringFullScreen || window.styleMask.contains(.fullScreen)
        let wanted: NSSize = (lockAspect && !isFullScreen) ? Self.aspect : .zero

        guard window.contentAspectRatio != wanted else { return }
        window.contentAspectRatio = wanted
        guard wanted != .zero else { return }

        // Setting the ratio does not resize an already-open window, so snap it
        // once — otherwise the lock only takes effect on the first drag and the
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

    private func applyChrome(to window: NSWindow) {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        // `alphaValue`, not `isHidden`: hiding makes AppKit reclaim the layout
        // slot and the buttons come back in the wrong place. A 0-alpha button
        // is still hit-testable, which costs nothing here — any click is
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

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            guard let window else { return }
            // `updateNSView` does not fire on a fullscreen transition, and
            // WILL-enter is the only useful hook for entering one: by DID-enter
            // AppKit has already sized the window against the aspect ratio, and
            // clearing it then would not resize anything back.
            center.addObserver(self, selector: #selector(willEnterFullScreen(_:)),
                               name: NSWindow.willEnterFullScreenNotification, object: window)
            center.addObserver(self, selector: #selector(didExitFullScreen(_:)),
                               name: NSWindow.didExitFullScreenNotification, object: window)
            onWindow?(window, false)
        }

        @objc private func willEnterFullScreen(_ note: Notification) {
            if let window = note.object as? NSWindow { onWindow?(window, true) }
        }

        @objc private func didExitFullScreen(_ note: Notification) {
            if let window = note.object as? NSWindow { onWindow?(window, false) }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
