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

    func makeCoordinator() -> Proxy { Proxy() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.shouldClose = shouldClose
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

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard shouldClose() else { return false }
            return original?.windowShouldClose?(sender) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : nil
        }
    }
}
