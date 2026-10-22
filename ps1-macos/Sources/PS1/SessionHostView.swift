import AppKit

/// The view a session draws into. `ps1_session_new` takes it and installs its
/// own layer, so this view never sets `wantsLayer` or its layer itself; it
/// only reports where it is and how sharp the screen behind it is.
final class SessionHostView: NSView {
    /// Called with the view's size in points and the window's backing scale
    /// whenever either changes.
    var onGeometry: ((CGSize, CGFloat) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportGeometry()
    }

    private func reportGeometry() {
        onGeometry?(bounds.size, window?.backingScaleFactor ?? 1)
    }
}
