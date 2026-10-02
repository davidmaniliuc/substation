import SwiftUI

/// PGXP geometry correction and its sub-settings.
///
/// Same gating as Video ▸ PGXP: every sub-setting is ANDed with the master
/// flag inside the core, so with geometry correction off they are disabled
/// rather than left to silently do nothing, and Transparent Depth is a
/// sub-setting of Depth Buffer in turn.
struct EnhancementsSettingsPane: View {
    @Bindable var model: EmulatorViewModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.pgxpEnabled) {
                    Text("PGXP Geometry Correction")
                    Text("Stops the wobbling, jittering and warping of 3D models the PlayStation is known for, by keeping every vertex at sub-pixel precision instead of rounding it to whole pixels. Off reproduces the original console exactly. The options below need this turned on.")
                }
            }

            Section("Picture") {
                Toggle(isOn: $model.pgxpTextureCorrection) {
                    Text("Texture Correction")
                    Text("Draws textures with correct perspective, so floors, roads and walls no longer bend and swim as the camera moves. Recommended.")
                }
                Toggle(isOn: $model.pgxpColorCorrection) {
                    Text("Colour Correction")
                    Text("Applies the same perspective correction to lighting and shading across a polygon. Subtle; a few games look wrong with it, so it starts off.")
                }
                Toggle(isOn: $model.pgxpCulling) {
                    Text("Culling Correction")
                    Text("Uses precise positions to decide which side of a polygon faces the camera, so thin or distant polygons stop flickering in and out. Recommended.")
                }
                Toggle(isOn: $model.pgxpDisable2d) {
                    Text("Disable on 2D")
                    Text("Leaves flat 2D elements such as menus, text and sprites exactly where the game put them, which can fix small gaps or seams in a HUD.")
                }
            }
            .disabled(!model.pgxpEnabled)

            Section("Depth Buffer (Experimental)") {
                Toggle(isOn: $model.pgxpDepthBuffer) {
                    Text("Depth Buffer")
                    Text("Sorts overlapping polygons pixel by pixel instead of trusting the order the game drew them in, which can fix models poking through each other. Can break effects some games rely on.")
                }
                Toggle(isOn: $model.pgxpTransparentDepth) {
                    Text("Transparent Depth")
                    Text("Lets see-through effects like water, glass and smoke be hidden behind solid objects without hiding what is behind them. Needs Depth Buffer.")
                }
                .disabled(!model.pgxpDepthBuffer)
            }
            .disabled(!model.pgxpEnabled)

            Section("Advanced") {
                Toggle(isOn: $model.pgxpCpu) {
                    Text("CPU Mode")
                    Text("Follows precise positions through the game's own maths as well as the geometry chip's. Most games need this for PGXP to work at all. Leave it on.")
                }
                Toggle(isOn: $model.pgxpPreserveProjection) {
                    Text("Preserve Projection Precision")
                    Text("Projects vertices from the geometry chip's full internal precision rather than its rounded results. A small accuracy gain.")
                }
                Toggle(isOn: $model.pgxpVertexCache) {
                    Text("Vertex Cache")
                    Text("Recovers precise positions for vertices a game copies around in memory, by looking them up by screen position. Helps a few specific games; uses about 83 MB of memory.")
                }
                Picker(selection: $model.pgxpTolerance) {
                    Text("Off").tag(Float(-1))
                    Text("0.5 px").tag(Float(0.5))
                    Text("1 px").tag(Float(1))
                    Text("2 px").tag(Float(2))
                } label: {
                    Text("Tolerance")
                    Text("How far a precise position may stray from the console's own before it is thrown away. A rejected vertex snaps its whole polygon back to whole pixels, so lower values bring some wobble back. Off trusts every position and is recommended.")
                }
            }
            .disabled(!model.pgxpEnabled)
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 640)
    }
}
