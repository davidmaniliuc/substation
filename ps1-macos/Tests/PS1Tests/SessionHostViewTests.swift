import Testing
import SwiftUI
import AppKit
@testable import PS1

@MainActor
@Test func theHostViewReportsItsSizeAndBackingScale() {
    let host = SessionHostView(frame: .zero)
    var reports: [(CGSize, CGFloat)] = []
    host.onGeometry = { reports.append(($0, $1)) }
    host.setFrameSize(NSSize(width: 640, height: 480))
    #expect(reports.count == 1)
    #expect(reports.last?.0 == CGSize(width: 640, height: 480))
    #expect(reports.last?.1 == 1)
    host.viewDidChangeBackingProperties()
    #expect(reports.count == 2)
}

@MainActor private func hostViews(in view: NSView) -> [SessionHostView] {
    var found: [SessionHostView] = []
    if let host = view as? SessionHostView { found.append(host) }
    for sub in view.subviews { found += hostViews(in: sub) }
    return found
}

/// Rebuilding the representable (a changed `.id`) calls `makeNSView` again, and
/// each call must hand back the model's one view. The first build's view is
/// pulled out of the hierarchy first, so a rebuild that returned a fresh view
/// would show up as a different instance.
@MainActor
@Test func theRepresentableReturnsTheModelsHostView() {
    let host = SessionHostView(frame: .zero)
    let hosting = NSHostingView(rootView: GameDisplayView(host: host).id(1))
    hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
    hosting.layoutSubtreeIfNeeded()
    #expect(hostViews(in: hosting).first === host)

    host.removeFromSuperview()
    hosting.rootView = GameDisplayView(host: host).id(2)
    hosting.layoutSubtreeIfNeeded()
    let after = hostViews(in: hosting)
    #expect(after.count == 1)
    #expect(after.first === host)

    let second = NSHostingView(rootView: GameDisplayView(host: host).id(3))
    second.frame = hosting.frame
    second.layoutSubtreeIfNeeded()
    #expect(hostViews(in: second).first === host)
}
