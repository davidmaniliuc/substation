import SwiftUI

/// First launch — the one screen every user sees.
struct EmptyStateView: View {
    @Bindable var model: EmulatorViewModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "opticaldisc")
                    .font(.system(size: 46, weight: .thin))
                    .foregroundStyle(.secondary)

                Text(title)
                    .font(.title2.weight(.semibold))

                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)

                HStack(spacing: 12) {
                    if model.stage == .needsBIOS {
                        Button("Choose BIOS Folder…") { model.chooseBIOSFolder() }
                            .buttonStyle(.glassProminent)
                    } else {
                        Button("Open Disc…") { model.openDisc() }
                            .buttonStyle(.glassProminent)
                        Button("Change BIOS Folder…") { model.chooseBIOSFolder() }
                            .buttonStyle(.glass)
                    }
                }
                .padding(.top, 4)
            }
            .padding(36)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            .frame(maxWidth: 460)
        }
    }

    private var title: String {
        model.stage == .needsBIOS ? "Choose a BIOS folder" : "Open a disc"
    }

    private var subtitle: String {
        model.stage == .needsBIOS
            ? "Point at the folder holding your SCPH-*.bin files. The right one is picked per disc — a US BIOS in front of a PAL disc stops at the region-lock screen."
            : "A .cue is preferred. A raw .bin works, but it cannot represent audio tracks, so CD-DA music will be silent."
    }
}
