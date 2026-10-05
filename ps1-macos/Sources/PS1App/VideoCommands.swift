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
/// it. The PGXP sub-settings below them are NOT: each is ANDed with the
/// master flag inside the core, so a tick while geometry correction is off
/// does nothing at all, and a control that silently no-ops is worse than one
/// that says it cannot act.
struct VideoCommands: Commands {
    @Bindable var model: EmulatorViewModel

    var body: some Commands {
        CommandMenu("Video") {
            // A submenu, matching Machine ▸ Change Disc: eight scales spread
            // flat over the Video menu bury the one other entry under them.
            // Unlike Change Disc (which is an action per item and draws its
            // own checkmark) this really is a preference, so it stays a
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

            // Flat rather than a submenu: three entries do not bury anything,
            // and unlike the scales there is no natural accelerator for them.
            Picker("Dithering", selection: $model.ditherMode) {
                ForEach(DitherMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)

            Picker("Texture Filtering", selection: $model.textureFilter) {
                ForEach(TextureFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.menu)

            Picker("Sprite Texture Filtering", selection: $model.spriteFilter) {
                ForEach(TextureFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.menu)

            Divider()
            Toggle("PGXP Geometry Correction", isOn: $model.pgxpEnabled)
                .disabled(model.pgxpPresetDecides(\.enabled))
            Toggle("PGXP Per-Game Fixes", isOn: $model.pgxpUsePresets)

            // Sub-settings of the master, not peers of it. Disabled rather
            // than silently ineffective: see the type comment.
            Group {
                Toggle("PGXP Texture Correction", isOn: $model.pgxpTextureCorrection)
                    .disabled(model.pgxpPresetDecides(\.textureCorrection))
                Toggle("PGXP Colour Correction", isOn: $model.pgxpColorCorrection)
                    .disabled(model.pgxpPresetDecides(\.colorCorrection))
                Toggle("PGXP Depth Buffer", isOn: $model.pgxpDepthBuffer)
                    .disabled(model.pgxpPresetDecides(\.depthBuffer))
                Toggle("PGXP Transparent Depth", isOn: $model.pgxpTransparentDepth)
                    .disabled(!model.pgxpEffectiveDepthBuffer)
                Toggle("PGXP Disable on 2D", isOn: $model.pgxpDisable2d)
                    .disabled(model.pgxpPresetDecides(\.disable2d))
                Toggle("PGXP Culling Correction", isOn: $model.pgxpCulling)
                    .disabled(model.pgxpPresetDecides(\.culling))
                Toggle("PGXP Preserve Projection Precision", isOn: $model.pgxpPreserveProjection)
                    .disabled(model.pgxpPresetDecides(\.preserveProjection))
                Toggle("PGXP CPU Mode", isOn: $model.pgxpCpu)
                    .disabled(model.pgxpPresetDecides(\.cpu))
                Toggle("PGXP Vertex Cache", isOn: $model.pgxpVertexCache)
                    .disabled(model.pgxpPresetDecides(\.vertexCache))
                Picker("PGXP Tolerance", selection: $model.pgxpTolerance) {
                    Text("Off").tag(Float(-1))
                    Text("0.5 px").tag(Float(0.5))
                    Text("1 px").tag(Float(1))
                    Text("2 px").tag(Float(2))
                    Text("3 px").tag(Float(3))
                    Text("4 px").tag(Float(4))
                }
                .pickerStyle(.menu)
                .disabled(model.pgxpPresetDecides(\.tolerance))
            }
            .disabled(!model.pgxpEffectivelyEnabled)
        }
    }
}
