import SwiftUI
import PS1

@main
struct PS1App: App {
    // Not `@State`: that is a macro in the macOS 26 SDK and its SwiftUIMacros
    // plugin ships only with Xcode, which is not installed. A stored `let`
    // holds the model for the App's lifetime, which is the whole process.
    private let model = EmulatorViewModel()

    var body: some Scene {
        Window("PlayStation", id: "main") {
            ContentView(model: model)
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

                Divider()

                // ⇧⌘R, not ⌘R: that is Reset, in the Machine menu.
                Button("Refresh Library") { model.rescanLibrary() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Choose Games Folder…") { model.chooseGamesFolder() }
                Button("Choose BIOS Folder…") { model.chooseBIOSFolder() }
            }
            CommandMenu("Machine") {
                Button(model.isPaused ? "Resume" : "Pause") { model.isPaused.toggle() }
                    .keyboardShortcut("p")
                Button("Reset") { model.reset() }
                    .keyboardShortcut("r")
                Button("Eject") { model.eject() }
                    .keyboardShortcut("e")
            }
            VideoCommands(model: model)
        }
    }
}
