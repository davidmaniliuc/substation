import SwiftUI
import PS1

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
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Disc…") { model.openDisc() }
                    .keyboardShortcut("o")
            }
            MachineCommands(model: model)
            LibraryCommands(model: model)
            VideoCommands(model: model)
        }

        // The standard Settings scene: SwiftUI adds "Settings…" to the app
        // menu with ⌘, and gives it the native preferences window; toolbar
        // tabs, one instance, remembered position. Every control in it binds
        // to the same model property as its menu item.
        Settings {
            SettingsView(model: model)
        }
    }
}
