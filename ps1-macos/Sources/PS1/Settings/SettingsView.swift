import SwiftUI
import AppKit

/// The Settings window (⌘,).
///
/// A sidebar of panes and the selected pane beside it, laid out as System
/// Settings is. One window size serves every pane: a pane taller than the
/// window scrolls, rather than the window resizing as the selection changes.
/// Resizing stays within the useful range defined by `SettingsWindow`.
///
/// Every control here is the SAME model property a menu item binds to, so the
/// two can never disagree: a tick in Video ▸ PGXP Geometry Correction shows up
/// here and the other way round, because `@Observable` instruments the stored
/// setting struct both of them write through. Nothing in this window persists
/// anything itself.
///
/// Each `SettingRow` has a title and an optional description. A grouped form
/// renders the description as secondary text. Copy lives in `SettingsCopy`.
public struct SettingsView: View {
    @Bindable var model: EmulatorViewModel
    @State private var pane: SettingsPane = .general

    public init(model: EmulatorViewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(SettingsPane.allCases, selection: $pane) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .tag(pane)
            }
            .scrollContentBackground(model.libraryTheme.settingsBackground)
            .background { backdrop }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(SettingsWindow.sidebarWidth)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .scrollContentBackground(model.libraryTheme.settingsBackground)
                .navigationTitle(pane.title)
                .navigationSubtitle("Settings")
        }
        .frame(minWidth: SettingsWindow.minimumSize.width,
               maxWidth: SettingsWindow.maximumSize.width,
               minHeight: SettingsWindow.minimumSize.height,
               maxHeight: SettingsWindow.maximumSize.height)
        .background { backdrop }
        .background(SettingsWindowMarker())
        // The game window opens from here too when it is the only other
        // window left: the library's may be closed while a game runs.
        .modifier(GameWindowOpener(model: model))
        // The library's theme reaches this window too, so a Black or Dark
        // library under a Light system does not open a light Settings window.
        .preferredColorScheme(model.libraryTheme.colorScheme)
    }

    /// The theme's backdrop where it replaces the system's background.
    @ViewBuilder private var backdrop: some View {
        if model.libraryTheme.settingsBackground == .hidden {
            model.libraryTheme.backdrop().ignoresSafeArea()
        }
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
    static let sidebarWidth: CGFloat = 200
    static let minimumSize = CGSize(width: 720, height: 400)
    static let maximumSize = CGSize(width: 900, height: 760)

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

        override func layout() {
            super.layout()
            if let controller = window?.contentViewController {
                Self.configureSidebar(in: controller)
            }
        }

        private static func configureSidebar(in controller: NSViewController) {
            if let split = controller as? NSSplitViewController,
               let sidebar = split.splitViewItems.first {
                // Constrain the native sidebar itself, before a drag starts.
                // No collapse-and-reopen state observer or draggable range.
                if sidebar.canCollapse { sidebar.canCollapse = false }
                if sidebar.maximumThickness != SettingsWindow.sidebarWidth {
                    sidebar.maximumThickness = SettingsWindow.sidebarWidth
                }
                if sidebar.minimumThickness != SettingsWindow.sidebarWidth {
                    sidebar.minimumThickness = SettingsWindow.sidebarWidth
                }
                return
            }
            controller.children.forEach { configureSidebar(in: $0) }
        }

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
            window.contentMinSize = SettingsWindow.minimumSize
            window.contentMaxSize = SettingsWindow.maximumSize
            // Bring a previously oversized window into the same bounds.
            let size = window.contentLayoutRect.size
            window.setContentSize(NSSize(
                width: min(max(size.width, SettingsWindow.minimumSize.width), SettingsWindow.maximumSize.width),
                height: min(max(size.height, SettingsWindow.minimumSize.height), SettingsWindow.maximumSize.height)
            ))
            DispatchQueue.main.async { [weak self] in
                guard let controller = self?.window?.contentViewController else { return }
                Self.configureSidebar(in: controller)
            }
        }
    }
}
