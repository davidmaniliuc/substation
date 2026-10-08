import SwiftUI

struct ResumePromptSheet: View {
    let offer: ResumeOffer
    let choose: (ResumeChoice) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Resume \(offer.title)?").font(.headline)
            thumbnail
                .frame(width: 320, height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            Text(offer.info.map { "Saved \(StateSource.savedAt($0.savedAt))" }
                 ?? "No resume state. Choose a saved state below or start fresh.")
                .foregroundStyle(.secondary)
            if offer.resumeDisc == nil {
                Text("The disc this state was saved on is no longer in the library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("Cancel") { choose(.cancel) }
                    .keyboardShortcut(.cancelAction)
                if !offer.others.isEmpty {
                    Menu("Other States") {
                        ForEach(offer.others, id: \.source) { saved in
                            Button(saved.source.menuTitle(saved.info)) { choose(.load(saved.source)) }
                        }
                    }
                    .fixedSize()
                }
                Spacer()
                Button("Delete & Boot", role: .destructive) { choose(.deleteAndBoot) }
                Button("Fresh Boot") { choose(.freshBoot) }
                Button("Resume") { choose(.resume) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(offer.info == nil || offer.resumeDisc == nil)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 520)
    }

    @ViewBuilder private var thumbnail: some View {
        if let url = offer.info?.thumbnail ?? offer.others.first?.info.thumbnail, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            Rectangle().fill(.black)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }
}
