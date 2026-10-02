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
            Text("Saved \(offer.info.savedAt.formatted(date: .abbreviated, time: .shortened))")
                .foregroundStyle(.secondary)
            if offer.resumeDisc == nil {
                Text("The disc this state was saved on is no longer in the library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("Cancel") { choose(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Delete & Boot", role: .destructive) { choose(.deleteAndBoot) }
                Button("Fresh Boot") { choose(.freshBoot) }
                Button("Resume") { choose(.resume) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(offer.resumeDisc == nil)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 520)
    }

    @ViewBuilder private var thumbnail: some View {
        if let url = offer.info.thumbnail, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            Rectangle().fill(.black)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }
}
