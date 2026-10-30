import SwiftUI

@main
struct PS1App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Owned by the delegate, which must have it before any window exists:
    /// a disc opened from Spotlight can launch the app without activating
    /// it, and SwiftUI builds no window until it is, so a model handed over
    /// from a window's `onAppear` left the disc waiting for a Dock click.
    private var model: EmulatorViewModel { appDelegate.model }
    // Sparkle; inert in a build without the update key (local builds).
    private let updates = SoftwareUpdate()

    var body: some Scene {
        Window("Substation", id: LibraryWindow.id) {
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
            // Sparkle's update check sits under About, where macOS apps put it.
            CommandGroup(replacing: .appInfo) {
                AboutButton()
                CheckForUpdatesButton(updates: updates)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Disc…") { model.openDisc() }
                    .keyboardShortcut("o")
                OpenRecentMenu(model: model)
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
        // so: one per game, keyed by what it holds. The main window opens it
        // as a game starts and it closes itself as the game ends, so it is
        // never restored at launch and offers no File menu item to open one
        // empty.
        WindowGroup("Game", id: GameWindow.id, for: GameWindowContent.self) { $content in
            if let content {
                GameWindowView(model: model, content: content)
            }
        }
        .windowStyle(.hiddenTitleBar)
        // A second scene is an ASSOCIATED window by default, which
        // AppKit treats as auxiliary: its green button zooms and it cannot
        // take a fullscreen space. Setting `collectionBehavior` afterwards
        // does not help, since the green button has already been built.
        .windowManagerRole(.principal)
        .defaultSize(width: 960, height: 720)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .commandsRemoved()

        // Substation ▸ About Substation. Opened only from the menu, never
        // restored, and sized to its content.
        Window("About Substation", id: AboutWindow.id) {
            AboutView(info: .current)
                .windowMinimizeBehavior(.disabled)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
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
        .windowResizability(.contentSize)
    }
}

private struct AboutButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Substation") { openWindow(id: AboutWindow.id) }
    }
}

/// File ▸ Open Recent, as every Mac app has it: each disc with its Finder
/// icon, then Clear Menu. Opening one is Finder's open, so a running game
/// is asked about first.
private struct OpenRecentMenu: View {
    let model: EmulatorViewModel

    var body: some View {
        Menu("Open Recent") {
            ForEach(model.recentDiscs, id: \.self) { url in
                Button {
                    model.open(url)
                } label: {
                    Label {
                        Text(FileManager.default.displayName(atPath: url.path))
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    }
                }
            }
            Divider()
            Button("Clear Menu") { model.clearRecentDiscs() }
                .disabled(model.recentDiscs.isEmpty)
        }
    }
}

/// Window ▸ Library: brings the library's window back, or forward.
private struct ShowLibraryButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Library") { openWindow(id: LibraryWindow.id) }
            .keyboardShortcut("l")
    }
}
