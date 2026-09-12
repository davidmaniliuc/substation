import SwiftUI

/// The Video menu.
///
/// A `Commands` type rather than an inline `CommandMenu` in `PS1App.body` so
/// `@Bindable` produces the picker's binding directly. Building one with
/// `Binding(get:set:)` instead would capture the `@MainActor` model in two
/// escaping closures, which the Swift 6 language mode this target builds under
/// has to be argued out of. This is the same shape `ContentView` already uses.
///
/// The two top-level entries are always enabled: they are preferences, not
/// per-session controls, and changing one with no game loaded simply persists
/// it. The PGXP sub-settings below them are NOT — each is ANDed with the
/// master flag inside the core, so a tick while geometry correction is off
/// does nothing at all, and a control that silently no-ops is worse than one
/// that says it cannot act.
struct VideoCommands: Commands {
    @Bindable var model: EmulatorViewModel

    var body: some Commands {
        CommandMenu("Video") {
            // A submenu, matching Machine ▸ Change Disc: eight scales spread
            // flat over the Video menu bury the one other entry under them.
            // Unlike Change Disc — which is an action per item and draws its
            // own checkmark — this really is a preference, so it stays a
            // `Picker` and the selected scale gets the system's checkmark
            // rather than a hand-drawn one.
            Picker("Internal Resolution", selection: $model.internalScale) {
                ForEach(InternalResolution.range, id: \.self) { n in
                    Text("\(n)×")
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")))
                        .tag(n)
                }
            }
            .pickerStyle(.menu)

            Divider()
            Toggle("PGXP Geometry Correction", isOn: $model.pgxpEnabled)

            // Sub-settings of the master, not peers of it. Disabled rather
            // than silently ineffective — see the type comment.
            Group {
                Toggle("PGXP Culling Correction", isOn: $model.pgxpCulling)
                Toggle("PGXP CPU Mode", isOn: $model.pgxpCpu)
                Toggle("PGXP Vertex Cache", isOn: $model.pgxpVertexCache)
                Picker("PGXP Tolerance", selection: $model.pgxpTolerance) {
                    Text("Off").tag(Float(-1))
                    Text("0.5 px").tag(Float(0.5))
                    Text("1 px").tag(Float(1))
                    Text("2 px").tag(Float(2))
                }
                .pickerStyle(.menu)
            }
            .disabled(!model.pgxpEnabled)
        }
    }
}
