import SwiftUI

/// First launch. Both folders are captured here; either can be done first.
struct OnboardingView: View {
    @Bindable var model: EmulatorViewModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 22) {
                Image(systemName: "opticaldisc")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.secondary)

                Text("Set up PlayStation")
                    .font(.title2.weight(.semibold))

                VStack(spacing: 14) {
                    row(
                        title: "BIOS folder",
                        detail: "The folder holding your SCPH-*.bin files. The right one is picked per disc — a US BIOS in front of a PAL disc stops at the region-lock screen.",
                        chosen: model.biosFolderName,
                        action: model.chooseBIOSFolder)

                    Divider()

                    row(
                        title: "Games folder",
                        detail: "Scanned recursively for .cue files. A .bin counts too, when its folder has no .cue.",
                        chosen: model.gamesFolderName,
                        action: model.chooseGamesFolder)
                }
                .frame(maxWidth: 420)

                Button("Continue") { model.finishOnboarding() }
                    .buttonStyle(.glassProminent)
                    .disabled(!isReady)
            }
            .padding(36)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            .frame(maxWidth: 520)
        }
    }

    private var isReady: Bool {
        model.hasBIOSFolder && model.gamesFolderName != nil
    }

    private func row(
        title: String, detail: String, chosen: String?, action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: chosen == nil ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(chosen == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                .font(.system(size: 15))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(chosen ?? "Not chosen")
                    .font(.caption)
                    .foregroundStyle(chosen == nil ? .tertiary : .secondary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("Choose…", action: action)
                .buttonStyle(.glass)
        }
    }
}
