import SwiftUI

@main
struct PS1App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Owned by the delegate, which must have it before any window exists:
    /// a disc opened from Spotlight can launch the app without activating
    /// it, and SwiftUI builds no window until it is, so a model handed over
    /// from a window's `onAppear` left the disc waiting for a Dock click.
    private var model: EmulatorViewModel { appDelegate.model }

    var body: some Scene {
        Window("Substation", id: "main") {
            ContentView(model: model)
        }
        // Full-size content: the Metal view extends under the title bar so the
        // glass chrome floats OVER the game rather than sitting in an opaque
        // strip above it. Without this the material has nothing to refract.
        .windowStyle(.hiddenTitleBar)
        // Regular height, as Finder's: the compact style shrinks the
        // library's controls to small capsules. The toolbar is hidden in a
        // game, so its height never reaches the picture or the 4:3 lock.
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Disc…") { model.openDisc() }
                    .keyboardShortcut("o")
            }
            // The library window can be closed while a game plays in its
            // own, and SwiftUI lists no `Window` scene in the Window menu.
            CommandGroup(before: .windowArrangement) {
                ShowLibraryButton()
            }
            MachineCommands(model: model)
            LibraryCommands(model: model)
            VideoCommands(model: model)
        }

        // A game's own window, when Settings ▸ General ▸ Open Games In says
        // so. The main window opens it as a game starts and it closes itself
        // as the game ends, so it is never restored at launch and offers no
        // Window menu item to open it empty.
        Window("Game", id: GameWindow.id) {
            GameWindowView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        // A second `Window` scene is an ASSOCIATED window by default, which
        // AppKit treats as auxiliary: its green button zooms and it cannot
        // take a fullscreen space. Setting `collectionBehavior` afterwards
        // does not help, since the green button has already been built.
        .windowManagerRole(.principal)
        .defaultSize(width: 960, height: 720)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .commandsRemoved()

        // The standard Settings scene: SwiftUI adds "Settings…" to the app
        // menu with ⌘, and keeps it to one instance at a remembered position.
        // Every control in it binds to the same model property as its menu
        // item.
        Settings {
            SettingsView(model: model)
        }
        // Without it a Settings window opens at its content's minimum size.
        .defaultSize(width: 820, height: 600)
    }
}

/// Window ▸ Library: brings the library's window back, or forward.
private struct ShowLibraryButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Library") { openWindow(id: "main") }
            .keyboardShortcut("l")
    }
}
