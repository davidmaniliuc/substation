import SwiftUI

/// PGXP geometry correction and its sub-settings.
///
/// Same gating as Video ▸ PGXP: every sub-setting is ANDed with the master
/// flag inside the core, so with geometry correction off their controls are
/// disabled rather than left to silently do nothing, and Transparent Depth is
/// a sub-setting of Depth Buffer in turn. The info buttons stay live, so a
/// player can read about a setting before turning on what it depends on.
struct EnhancementsSettingsPane: View {
    @Bindable var model: EmulatorViewModel

    var body: some View {
        let on = model.pgxpEnabled

        Form {
            Section {
                SettingToggle(SettingsCopy.pgxp, isOn: $model.pgxpEnabled)
            } footer: {
                if !on {
                    Text(SettingsCopy.pgxpOffFooter)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section("Picture") {
                SettingToggle(SettingsCopy.textureCorrection,
                              isOn: $model.pgxpTextureCorrection, isEnabled: on)
                SettingToggle(SettingsCopy.colorCorrection,
                              isOn: $model.pgxpColorCorrection, isEnabled: on)
                SettingToggle(SettingsCopy.culling,
                              isOn: $model.pgxpCulling, isEnabled: on)
                SettingToggle(SettingsCopy.disable2d,
                              isOn: $model.pgxpDisable2d, isEnabled: on)
            }

            Section("Depth Buffer (Experimental)") {
                SettingToggle(SettingsCopy.depthBuffer,
                              isOn: $model.pgxpDepthBuffer, isEnabled: on)
                SettingToggle(SettingsCopy.transparentDepth,
                              isOn: $model.pgxpTransparentDepth,
                              isEnabled: on && model.pgxpDepthBuffer)
            }

            Section("Advanced") {
                SettingToggle(SettingsCopy.cpuMode,
                              isOn: $model.pgxpCpu, isEnabled: on)
                SettingToggle(SettingsCopy.preserveProjection,
                              isOn: $model.pgxpPreserveProjection, isEnabled: on)
                SettingToggle(SettingsCopy.vertexCache,
                              isOn: $model.pgxpVertexCache, isEnabled: on)
                SettingRow(SettingsCopy.tolerance, isEnabled: on) {
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
