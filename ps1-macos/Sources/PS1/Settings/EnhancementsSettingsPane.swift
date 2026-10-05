import SwiftUI

/// PGXP geometry correction and its sub-settings.
///
/// Same gating as Video ▸ PGXP: every sub-setting is ANDed with the master
/// flag inside the core, so with geometry correction off their controls are
/// disabled rather than left to silently do nothing, and Transparent Depth is
/// a sub-setting of Depth Buffer in turn. The info buttons stay live, so a
/// player can read about a setting before turning on what it depends on.
///
/// While a game runs, a setting its preset decides is disabled too, for the
/// same reason: a change to it would do nothing until the game is left.
struct EnhancementsSettingsPane: View {
    @Bindable var model: EmulatorViewModel

    var body: some View {
        let on = model.pgxpEffectivelyEnabled

        Form {
            Section {
                SettingToggle(SettingsCopy.pgxp, isOn: $model.pgxpEnabled,
                              isEnabled: !model.pgxpPresetDecides(\.enabled))
                SettingToggle(SettingsCopy.usePresets, isOn: $model.pgxpUsePresets)
            } header: {
                // Where Controls puts its own, so the two panes read alike.
                HStack {
                    Text("Geometry")
                    Spacer()
                    Button("Restore Defaults") { model.restoreDefaultPgxp() }
                        .controlSize(.small)
                        .disabled(model.pgxpIsDefault)
                }
            } footer: {
                if model.pgxpEnabled, let changes = model.pgxpPreset?.changes,
                   !changes.isEmpty {
                    Text(SettingsCopy.presetFooter(changes))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !on {
                    Text(SettingsCopy.pgxpOffFooter)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section("Picture") {
                SettingToggle(SettingsCopy.textureCorrection,
                              isOn: $model.pgxpTextureCorrection,
                              isEnabled: on && !model.pgxpPresetDecides(\.textureCorrection))
                SettingToggle(SettingsCopy.colorCorrection,
                              isOn: $model.pgxpColorCorrection,
                              isEnabled: on && !model.pgxpPresetDecides(\.colorCorrection))
                SettingToggle(SettingsCopy.culling,
                              isOn: $model.pgxpCulling,
                              isEnabled: on && !model.pgxpPresetDecides(\.culling))
                SettingToggle(SettingsCopy.disable2d,
                              isOn: $model.pgxpDisable2d,
                              isEnabled: on && !model.pgxpPresetDecides(\.disable2d))
            }

            Section("Depth Buffer (Experimental)") {
                SettingToggle(SettingsCopy.depthBuffer,
                              isOn: $model.pgxpDepthBuffer,
                              isEnabled: on && !model.pgxpPresetDecides(\.depthBuffer))
                SettingToggle(SettingsCopy.transparentDepth,
                              isOn: $model.pgxpTransparentDepth,
                              isEnabled: model.pgxpEffectiveDepthBuffer)
            }

            Section("Advanced") {
                SettingToggle(SettingsCopy.cpuMode,
                              isOn: $model.pgxpCpu,
                              isEnabled: on && !model.pgxpPresetDecides(\.cpu))
                SettingToggle(SettingsCopy.preserveProjection,
                              isOn: $model.pgxpPreserveProjection,
                              isEnabled: on && !model.pgxpPresetDecides(\.preserveProjection))
                SettingToggle(SettingsCopy.vertexCache,
                              isOn: $model.pgxpVertexCache,
                              isEnabled: on && !model.pgxpPresetDecides(\.vertexCache))
                SettingRow(SettingsCopy.tolerance, isEnabled: on && !model.pgxpPresetDecides(\.tolerance)) {
                    Picker(SettingsCopy.tolerance.title, selection: $model.pgxpTolerance) {
                        Text("Off").tag(Float(-1))
                        Text("0.5 px").tag(Float(0.5))
                        Text("1 px").tag(Float(1))
                        Text("2 px").tag(Float(2))
                        Text("3 px").tag(Float(3))
                        Text("4 px").tag(Float(4))
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        .formStyle(.grouped)
    }
}
