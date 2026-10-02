import SwiftUI
import AppKit

/// The Settings window (⌘,).
///
/// Every control here is the SAME model property a menu item binds to, so the
/// two can never disagree: a tick in Video ▸ PGXP Geometry Correction shows up
/// here and the other way round, because `@Observable` instruments the stored
/// setting struct both of them write through. Nothing in this window persists
/// anything itself.
///
/// Each row carries a second `Text` in its label. In a `.grouped` form that is
/// rendered as the secondary description line under the title — the System
/// Settings idiom — so the explanation lives beside the control rather than in
/// a tooltip a new player would never find.
public struct SettingsView: View {
    @Bindable var model: EmulatorViewModel

    public init(model: EmulatorViewModel) {
        self.model = model
    }

    public var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsPane(model: model)
            }
            Tab("Library", systemImage: "square.grid.2x2") {
                LibrarySettingsPane(model: model)
            }
            Tab("Video", systemImage: "display") {
                VideoSettingsPane(model: model)
            }
            Tab("Enhancements", systemImage: "cube.transparent") {
                EnhancementsSettingsPane(model: model)
            }
            Tab("Controls", systemImage: "gamecontroller") {
                ControlsSettingsPane()
            }
        }
        .background(SettingsWindowMarker())
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
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { SettingsWindow.current = window }
        }
    }
}
