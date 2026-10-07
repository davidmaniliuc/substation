import SwiftUI

@main
struct PS1App: App {
    // Not `@State`: `@State` is scoped to a `View`'s lifetime and would be
    // recreated with it, where this model must live for the App's whole
    // process. `@State` itself compiles fine (Xcode 26.6 has been installed
    // since 2026-08-22); a stored `let` here is a design choice, not a
    // workaround for an unavailable macro.
    private let model = EmulatorViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Substation", id: "main") {
            ContentView(model: model).onAppear { appDelegate.model = model }
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
