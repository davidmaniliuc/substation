import AppKit

/// The `NSTableView` behind a SwiftUI `Table` or `List`, found from a marker
/// view drawn beside it, for what SwiftUI has no API for.
@MainActor
enum NearestTable {
    /// Runs `body` on a later turn, retried for a few: the table is not in
    /// the hierarchy yet when the marker is first updated, and a first update
    /// that finds no table would never be repeated, since nothing it reads
    /// has changed.
    static func whenFound(near view: NSView, turnsLeft: Int = 10,
                          _ body: @escaping (NSTableView, NSWindow) -> Void) {
        DispatchQueue.main.async {
            guard let table = table(near: view), let window = table.window else {
                if turnsLeft > 0 { whenFound(near: view, turnsLeft: turnsLeft - 1, body) }
                return
            }
            body(table, window)
        }
    }

    /// The nearest table under one of the marker's few closest ancestors:
    /// the marker and the table are siblings in SwiftUI's background stack.
    private static func table(near view: NSView) -> NSTableView? {
        var ancestor = view.superview
        for _ in 0..<4 {
            guard let current = ancestor else { return nil }
            if let found = firstTable(in: current) { return found }
            ancestor = current.superview
        }
        return nil
    }

    private static func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap(firstTable(in:)).first
    }
}
