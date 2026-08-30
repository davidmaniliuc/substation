import SwiftUI

/// The Video menu.
///
/// A `Commands` type rather than an inline `CommandMenu` in `PS1App.body` so
/// `@Bindable` produces the picker's binding directly. Building one with
/// `Binding(get:set:)` instead would capture the `@MainActor` model in two
/// escaping closures, which the Swift 6 language mode this target builds under
/// has to be argued out of. This is the same shape `ContentView` already uses.
///
/// Always enabled: both entries are preferences, not per-session controls,
/// and changing one with no game loaded simply persists it.
struct VideoCommands: Commands {
    @Bindable var model: EmulatorViewModel

    var body: some Commands {
        CommandMenu("Video") {
            Picker("Internal Resolution", selection: $model.internalScale) {
                ForEach(InternalResolution.range, id: \.self) { n in
                    Text("\(n)×")
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")))
                        .tag(n)
                }
            }
            // Inline, so the eight scales are top-level items in the Video
            // menu and their shortcuts are visible rather than buried in a
            // submenu.
            .pickerStyle(.inline)

            Divider()
            Toggle("PGXP Geometry Correction", isOn: $model.pgxpEnabled)
        }
    }
}
