import SwiftUI
import AppKit

/// The Settings window (⌘,).
///
/// A sidebar of panes and the selected pane beside it, laid out as System
/// Settings is. One window size serves every pane: a pane taller than the
/// window scrolls, rather than the window resizing as the selection changes.
/// The player can resize it down to `SettingsWindow.minimumSize`.
///
/// Every control here is the SAME model property a menu item binds to, so the
/// two can never disagree: a tick in Video ▸ PGXP Geometry Correction shows up
/// here and the other way round, because `@Observable` instruments the stored
/// setting struct both of them write through. Nothing in this window persists
/// anything itself.
///
/// Each row is a `SettingRow`: a title, a one-line summary beneath it, and an
/// info button whose popover explains where the setting helps and where it
/// causes problems. The summary is the second `Text` in the row's label, which
/// a `.grouped` form renders as the secondary description line, as System
/// Settings does. All of the copy lives in `SettingsCopy`.
public struct SettingsView: View {
    @Bindable var model: EmulatorViewModel
    @State private var pane: SettingsPane = .general
    /// Pinned to `.all`, and put back if anything collapses it: with the
    /// toggle removed, nothing in the window could bring the sidebar back.
    @State private var columns: NavigationSplitViewVisibility = .all

    public init(model: EmulatorViewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(SettingsPane.allCases, selection: $pane) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .tag(pane)
            }
            // The sidebar IS the navigation here, so it cannot be folded
            // away: no toggle, and the marker view bounds its width so the
            // divider cannot be dragged shut either.
            .navigationSplitViewColumnWidth(
                min: SettingsWindow.sidebarWidth.lowerBound, ideal: 200,
                max: SettingsWindow.sidebarWidth.upperBound)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .navigationTitle(pane.title)
                .navigationSubtitle("Settings")
        }
        .onChange(of: columns) { if columns != .all { columns = .all } }
        // An unbounded maximum, or SwiftUI snaps a widened window back to
        // the content's natural width (~900pt) when it next lays it out.
        .frame(minWidth: SettingsWindow.minimumSize.width, maxWidth: .infinity,
               minHeight: SettingsWindow.minimumSize.height, maxHeight: .infinity)
        .background(SettingsWindowMarker())
    }

    @ViewBuilder private var detail: some View {
        switch pane {
        case .general: GeneralSettingsPane(model: model)
        case .library: LibrarySettingsPane(model: model)
        case .video: VideoSettingsPane(model: model)
        case .enhancements: EnhancementsSettingsPane(model: model)
        case .controls: ControlsSettingsPane(model: model)
        }
    }
}

private enum SettingsPane: CaseIterable, Identifiable {
    case general, library, video, enhancements, controls

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .library: "Library"
        case .video: "Video"
        case .enhancements: "Enhancements"
        case .controls: "Controls"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .library: "square.grid.2x2"
        case .video: "display"
        case .enhancements: "cube.transparent"
        case .controls: "gamecontroller"
        }
    }
}

/// Remembers which `NSWindow` is the Settings window, so the game's key
/// monitor can tell its events apart.
///
/// The monitor is app-wide: without this, arrow keys and Return pressed in
/// this window while a game runs would drive the pad instead of the controls
/// in front of the player. The window's `identifier` is SwiftUI's own and is
/// left alone: SwiftUI uses it to find the open window when ⌘, is pressed a
/// second time, so tagging the window through it could open a duplicate.
@MainActor
enum SettingsWindow {
    static weak var current: NSWindow?

    /// Narrow enough to give the panes room, wide enough for "Enhancements".
    static let sidebarWidth: ClosedRange<CGFloat> = 180...320
    static let minimumSize = CGSize(width: 600, height: 400)
    /// The panes' own floor, so a widened sidebar narrows the smallest
    /// window rather than squeezing the pane beside it.
    static let paneMinimumWidth: CGFloat = 400

    /// By window NUMBER rather than identity: the key monitor may only carry
    /// Sendable values across into the main actor, and `NSEvent` is not one.
    static func owns(windowNumber: Int) -> Bool {
        guard let current else { return false }
        return current.windowNumber == windowNumber
    }
}

private struct SettingsWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        private var resizable: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            SettingsWindow.current = window
            // A Settings window gets the preferences toolbar, which centres
            // the title in a bar of its own; `.windowToolbarStyle` on the
            // scene does not reach it. Unified puts the title and subtitle at
            // the toolbar's leading edge, as System Settings does. It needs a
            // toolbar to act on, and with the sidebar toggle removed SwiftUI
            // has no item to give it one, so an empty one is supplied.
            if window.toolbar == nil { window.toolbar = NSToolbar() }
            window.toolbarStyle = .unified
            // SwiftUI keeps a Settings window non-resizable: it strips
            // `.resizable` again after any insert here, and
            // `.windowResizability` on the scene does not change that. So the
            // flag is put back whenever it is taken away. The view's minimum
            // size is then the floor.
            window.styleMask.insert(.resizable)
            // KVO calls back on the thread that made the change, and AppKit
            // changes `styleMask` only on the main thread: asserted, not
            // assumed, so a change from anywhere else traps here.
            resizable = window.observe(\.styleMask) { window, _ in
                MainActor.assumeIsolated {
                    guard !window.styleMask.contains(.resizable) else { return }
                    window.styleMask.insert(.resizable)
                }
            }
            // A min/max on `navigationSplitViewColumnWidth` is not enforced
            // against a drag, so the sidebar's split item is bounded directly,
            // once SwiftUI has built it.
            DispatchQueue.main.async { Self.pinSidebar(in: window.contentView) }
        }

        private static func pinSidebar(in view: NSView?) {
            guard let view else { return }
            if let split = view as? NSSplitView,
               let controller = split.delegate as? NSSplitViewController,
               let sidebar = controller.splitViewItems.first {
                sidebar.canCollapse = false
                sidebar.minimumThickness = SettingsWindow.sidebarWidth.lowerBound
                sidebar.maximumThickness = SettingsWindow.sidebarWidth.upperBound
                controller.splitViewItems.last?.minimumThickness = SettingsWindow.paneMinimumWidth
                return
            }
            view.subviews.forEach { pinSidebar(in: $0) }
        }
    }
}
