import AppKit
import SwiftUI

/// Routes the window's close button and ⌘W through the exit sheet.
///
/// SwiftUI owns the window's delegate and offers no `windowShouldClose`, so
/// this installs a proxy that answers that one question and forwards every
/// other delegate message to SwiftUI's own delegate untouched. The proxy is
/// re-installed whenever SwiftUI puts its delegate back.
struct CloseInterceptor: NSViewRepresentable {
    let shouldClose: () -> Bool
    /// Whether the window shows a game, asked as it enters full screen.
    var showsGame: () -> Bool = { false }

    func makeCoordinator() -> Proxy { Proxy() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.shouldClose = shouldClose
        context.coordinator.showsGame = showsGame
        DispatchQueue.main.async {
            guard let window = view.window, window.delegate !== context.coordinator else { return }
            context.coordinator.original = window.delegate
            window.delegate = context.coordinator
        }
    }

    final class Proxy: NSObject, NSWindowDelegate {
        /// Strong: `NSWindow.delegate` is weak, and this is now the only
        /// reference the window path holds to SwiftUI's delegate.
        var original: NSWindowDelegate?
        var shouldClose: () -> Bool = { true }
        var showsGame: () -> Bool = { false }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard shouldClose() else { return false }
            return original?.windowShouldClose?(sender) ?? true
        }

        /// **A game's toolbar band hides WITH the menu bar in full screen.**
        /// AppKit keeps a full-screen window's toolbar on screen unless asked
        /// and lays the content out below it, so the empty band that seats
        /// the traffic lights stayed as an opaque strip over the picture.
        /// Only this answer reaches it: `NSApp.presentationOptions` set once
        /// the window is in full screen is ignored (measured: the set read
        /// back unchanged and the toolbar stayed). The library keeps its
        /// toolbar, whose controls it needs, so a game started in a
        /// full-screen library keeps the band until the next entry.
        func window(_ window: NSWindow,
                    willUseFullScreenPresentationOptions proposed: NSApplication.PresentationOptions = [])
            -> NSApplication.PresentationOptions {
            let options = original?.window?(window, willUseFullScreenPresentationOptions: proposed) ?? proposed
            return Self.fullScreenPresentation(options, showsGame: showsGame())
        }

        /// `.autoHideToolbar` is valid only beside `.autoHideMenuBar`, and
        /// AppKit throws on an invalid set.
        nonisolated static func fullScreenPresentation(_ options: NSApplication.PresentationOptions,
                                                       showsGame: Bool) -> NSApplication.PresentationOptions {
            showsGame ? options.union([.autoHideMenuBar, .autoHideToolbar]) : options
        }

        /// A failed transition reaches the delegate only, never a
        /// notification, so it is relayed for `WindowConfigurator`: without
        /// it a WILL with no DID holds the aspect lock off for good.
        func windowDidFailToEnterFullScreen(_ window: NSWindow) {
            NotificationCenter.default.post(name: .fullScreenTransitionFailed, object: window)
            original?.windowDidFailToEnterFullScreen?(window)
        }

        func windowDidFailToExitFullScreen(_ window: NSWindow) {
            NotificationCenter.default.post(name: .fullScreenTransitionFailed, object: window)
            original?.windowDidFailToExitFullScreen?(window)
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : nil
        }
    }
}

extension Notification.Name {
    /// AppKit gave up on entering or leaving full screen (`CloseInterceptor`).
    static let fullScreenTransitionFailed = Notification.Name("SubstationFullScreenTransitionFailed")
}
