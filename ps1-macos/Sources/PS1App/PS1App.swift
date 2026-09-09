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

    var body: some Scene {
        Window("Substation", id: "main") {
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
            }
            CommandMenu("Machine") {
                Button(model.isPaused ? "Resume" : "Pause") { model.isPaused.toggle() }
                    .keyboardShortcut("p")
                Button("Reset") { model.reset() }
                    .keyboardShortcut("r")
                Button("Eject") { model.eject() }
                    .keyboardShortcut("e")

                Divider()

                Menu("Change Disc") {
                    ForEach(Array(model.currentDiscs.enumerated()), id: \.element.id) { index, disc in
                        Button {
                            model.changeDisc(to: disc)
                        } label: {
                            // The checkmark is drawn rather than set through a
                            // Picker: the list is not a preference, it is an
                            // action per item, and a Picker would re-select on
                            // a swap that has not been applied yet.
                            Text(index == model.currentDiscIndex
                                 ? "✓ \(disc.title)" : "   \(disc.title)")
                        }
                    }
                }
                .disabled(model.currentDiscs.count < 2)
            }
            LibraryCommands(model: model)
            VideoCommands(model: model)
        }
    }
}
