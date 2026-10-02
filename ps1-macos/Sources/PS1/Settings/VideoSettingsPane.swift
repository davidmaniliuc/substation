import SwiftUI

/// Internal resolution and dithering — the two Video menu preferences.
struct VideoSettingsPane: View {
    @Bindable var model: EmulatorViewModel

    var body: some View {
        Form {
            Section {
                Picker(selection: $model.internalScale) {
                    ForEach(InternalResolution.range, id: \.self) { n in
                        Text(Self.resolutionTitle(n)).tag(n)
                    }
                } label: {
                    Text("Internal Resolution")
                    Text("Draws 3D at a multiple of the PlayStation's own resolution for sharper edges and finer detail. 1× is exactly what the console output; higher settings ask more of your Mac's GPU. Also ⌘1–⌘8.")
                }
            }

            Section {
                Picker(selection: $model.ditherMode) {
                    ForEach(DitherMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    Text("Dithering")
                    Text("The PlayStation could only show 32 shades per colour and hid the steps with a fine checkerboard pattern. This decides how that is handled.")
                }
            } footer: {
                Text(Self.ditherDescription(model.ditherMode))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 360)
    }

    /// Each scale with the picture height it produces, so "4×" means
    /// something to a player who has never seen a 240-line console.
    static func resolutionTitle(_ n: Int) -> String {
        let label = "\(n)× (\(240 * n)p)"
        return n == 1 ? label + " — Native" : label
    }

    static func ditherDescription(_ mode: DitherMode) -> String {
        switch mode {
        case .trueColor:
            return "True Colour (recommended): no pattern at all. Shading is drawn with full 8-bit colour, so gradients like skies and lighting come out smooth."
        case .scaled:
            return "Scaled: keeps the pattern but makes it as fine as the screen allows, so it blends into a smooth gradient at higher resolutions."
        case .native:
            return "Native: the pattern exactly as the console drew it. The most authentic look, but at high resolutions it shows as visible blocky cross-hatching."
        case .off:
            return "Off: no pattern and no extra colour, so slow gradients show hard bands of colour. Mostly useful for comparison."
        }
    }
}
