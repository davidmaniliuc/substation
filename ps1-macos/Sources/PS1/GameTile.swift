import AppKit
import SwiftUI

/// One game in the grid: its cover if it has one, a generated placeholder if
/// not.
///
/// The actions arrive as closures rather than a view-model reference so the
/// tile has no opinion about where a game comes from — which is also what lets
/// `removeCover` be nil to mean "there is nothing to remove", instead of the
/// tile reaching into the store to find out.
struct GameTile: View {
    let entry: GameEntry
    /// The GROUP's title, which for a multi-disc game is the shared one with
    /// the disc token stripped — not `entry.title`, which is disc 1's filename.
    let title: String
    let discCount: Int
    let coverURL: URL?
    let play: () -> Void
    let chooseCover: () -> Void
    let removeCover: (() -> Void)?

    private static let aspect: CGFloat = 3.0 / 4.0
    private static let corner: CGFloat = 10

    var body: some View {
        VStack(spacing: 8) {
            art
                .aspectRatio(Self.aspect, contentMode: .fit)
                .clipShape(.rect(cornerRadius: Self.corner))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.corner)
                        .strokeBorder(.white.opacity(0.08))
                }
                .shadow(color: .black.opacity(0.35), radius: 6, y: 3)

            Text(title)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if discCount > 1 {
                Text("\(discCount) discs")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: play)
        .contextMenu {
            Button("Play", action: play)
            Divider()
            Button("Choose Cover Image…", action: chooseCover)
            if let removeCover {
                Button("Remove Custom Cover", action: removeCover)
            }
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
        }
        .help(entry.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
    }

    @ViewBuilder
    private var art: some View {
        if let coverURL, let image = NSImage(contentsOf: coverURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.20), Color(white: 0.12)],
                startPoint: .top, endPoint: .bottom)

            Image(systemName: "opticaldisc")
                .font(.system(size: 34, weight: .thin))
                .foregroundStyle(.tertiary)
        }
    }
}
