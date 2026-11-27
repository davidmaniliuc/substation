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
/// it. Every entry shows the running game's value: where the game overrides a
/// setting, the menu reads and changes that override, never the global value
/// the game does not run under. The PGXP sub-settings below them are NOT: each is ANDed with the
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
            Picker("Internal Resolution", selection: $model[running: \.internalScale, global: \.internalScale]) {
                ForEach(InternalResolution.range, id: \.self) { n in
                    Text("\(n)×")
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")))
                        .tag(n)
                }
            }
            .pickerStyle(.menu)

            // Flat rather than a submenu: three entries do not bury anything,
            // and unlike the scales there is no natural accelerator for them.
            Picker("Dithering", selection: $model[running: \.ditherMode, global: \.ditherMode]) {
                ForEach(DitherMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)

            Picker("Texture Filtering", selection: $model[running: \.textureFilter, global: \.textureFilter]) {
                ForEach(TextureFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.menu)

            Picker("Sprite Texture Filtering", selection: $model[running: \.spriteFilter, global: \.spriteFilter]) {
                ForEach(TextureFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.menu)

            Picker("Widescreen", selection: $model[running: \.widescreen, global: \.widescreen]) {
                ForEach(Widescreen.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)

            Picker("Deinterlacing", selection: $model[running: \.deinterlacing, global: \.deinterlacing]) {
                ForEach(Deinterlacing.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)

            Picker("Display Effect", selection: $model[running: \.displayEffect, global: \.displayEffect]) {
                ForEach(DisplayEffect.allCases) { effect in
                    Text(effect.title).tag(effect)
                }
            }
            .pickerStyle(.menu)

            // Per game, unlike every entry above: with no game running (or a
            // disc with no serial) there is no game to file the choice under,
            // so the whole submenu is disabled. Automatic names what it
            // resolved to for the running game.
            Picker("Accurate VRAM Readbacks", selection: $model.vramReadbacks) {
                ForEach(VramReadbacks.allCases) { choice in
                    Text(model.vramReadbacksTitle(choice)).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .disabled(!model.vramReadbacksAvailable)

            Divider()
            Toggle("PGXP Geometry Correction", isOn: $model[running: \.pgxpEnabled, global: \.pgxpEnabled])
                .disabled(model.pgxpPresetDecides(\.enabled))
            Toggle("PGXP Per-Game Fixes", isOn: $model[running: \.pgxpUsePresets, global: \.pgxpUsePresets])

            // Sub-settings of the master, not peers of it. Disabled rather
            // than silently ineffective: see the type comment.
            Group {
                Toggle("PGXP Texture Correction", isOn: $model[running: \.pgxpTextureCorrection, global: \.pgxpTextureCorrection])
                    .disabled(model.pgxpPresetDecides(\.textureCorrection))
                Toggle("PGXP Colour Correction", isOn: $model[running: \.pgxpColorCorrection, global: \.pgxpColorCorrection])
                    .disabled(model.pgxpPresetDecides(\.colorCorrection))
                Toggle("PGXP Depth Buffer", isOn: $model[running: \.pgxpDepthBuffer, global: \.pgxpDepthBuffer])
                    .disabled(model.pgxpPresetDecides(\.depthBuffer))
                Toggle("PGXP Transparent Depth", isOn: $model[running: \.pgxpTransparentDepth, global: \.pgxpTransparentDepth])
                    .disabled(!model.pgxpEffectiveDepthBuffer)
                Toggle("PGXP Disable on 2D", isOn: $model[running: \.pgxpDisable2d, global: \.pgxpDisable2d])
                    .disabled(model.pgxpPresetDecides(\.disable2d))
                Toggle("PGXP Culling Correction", isOn: $model[running: \.pgxpCulling, global: \.pgxpCulling])
                    .disabled(model.pgxpPresetDecides(\.culling))
                Toggle("PGXP Preserve Projection Precision", isOn: $model[running: \.pgxpPreserveProjection, global: \.pgxpPreserveProjection])
                    .disabled(model.pgxpPresetDecides(\.preserveProjection))
                Toggle("PGXP CPU Mode", isOn: $model[running: \.pgxpCpuMode, global: \.pgxpCpu])
                    .disabled(model.pgxpPresetDecides(\.cpu))
                Toggle("PGXP Vertex Cache", isOn: $model[running: \.pgxpVertexCache, global: \.pgxpVertexCache])
                    .disabled(model.pgxpPresetDecides(\.vertexCache))
                Picker("PGXP Tolerance",
                       selection: $model[running: \.pgxpTolerance, global: \.pgxpToleranceChoice]) {
                    ForEach(PgxpTolerance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .disabled(model.pgxpPresetDecides(\.tolerance))
            }
            .disabled(!model.pgxpEffectivelyEnabled)
        }
    }
}
