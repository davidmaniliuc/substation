import AppKit
import SwiftUI

/// One game in the grid: its cover if it has one, a generated placeholder if
/// not.
///
/// The actions arrive as closures rather than a view-model reference so the
/// tile has no opinion about where a game comes from, which is also what lets
/// `removeCover` be nil to mean "there is nothing to remove", instead of the
/// tile reaching into the store to find out.
struct GameTile: View {
    let entry: GameEntry
    /// The GROUP's title, which for a multi-disc game is the shared one with
    /// the disc token stripped, not `entry.title`, which is disc 1's filename.
    let title: String
    let discCount: Int
    let coverURL: URL?
    /// An accent outline around a flat cover, as Apple Music does; a tinted
    /// glow around a cut-out one (see `framed`).
    let isSelected: Bool
    let select: () -> Void
    let play: () -> Void
    let chooseCover: () -> Void
    /// Nil when the disc names no serial: the collection is keyed on serials,
    /// so there is nothing to look up and the item would only ever fail.
    let downloadCover: (() -> Void)?
    let removeCover: (() -> Void)?

    /// A PlayStation jewel case front is square, so a cover scan is 1:1; a
    /// portrait box crops the artwork's sides or letterboxes it.
    private static let aspect: CGFloat = 1
    private static let corner: CGFloat = 10
    private static let dragPreviewSide: CGFloat = 150

    var body: some View {
        let image = coverURL.flatMap(NSImage.init(contentsOf:))
        let cutOut = image.map(CoverShape.isCutOut) ?? false
        VStack(spacing: 8) {
            framed(art(image), cutOut: cutOut)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                // The payload is the title, never the file URL: a file URL
                // dropped on Finder copies a disc image of hundreds of
                // megabytes. Nothing in the app accepts the drop, so letting
                // go slides the cover back to its tile. `onDrag` rather than
                // `draggable` because its closure runs once, as the drag
                // starts, which is where picking a tile up selects it.
                .onDrag {
                    select()
                    return NSItemProvider(object: title as NSString)
                } preview: {
                    let preview = art(image)
                        .frame(width: Self.dragPreviewSide, height: Self.dragPreviewSide)
                    if cutOut {
                        preview
                    } else {
                        preview.clipShape(.rect(cornerRadius: Self.corner))
                    }
                }

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
        // A row is as tall as its tallest tile (a two-line title, or a disc
        // count), and without this every shorter tile is centred in it, which
        // is what leaves the covers of one row at different heights.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: play)
        // Simultaneous, so a single click selects at once rather than after
        // the double-click interval has run out.
        .simultaneousGesture(TapGesture().onEnded(select))
        .contextMenu {
            Button("Play", action: play)
            Divider()
            Button("Choose Cover Image…", action: chooseCover)
            if let downloadCover {
                Button("Download Cover", action: downloadCover)
            }
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A flat scan is clipped and outlined as a square. A cut-out (a 3D case)
    /// is drawn as its own shape: the square around it is empty, so a clip,
    /// hairline or ring on it outlines nothing but the grid. Its selection is
    /// a tinted glow instead, which follows the alpha as the shadow does.
    @ViewBuilder
    private func framed(_ art: some View, cutOut: Bool) -> some View {
        let square = art.aspectRatio(Self.aspect, contentMode: .fit)
        if cutOut {
            square.shadow(color: isSelected ? .accentColor : .clear, radius: 3)
        } else {
            square
                .clipShape(.rect(cornerRadius: Self.corner))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.corner)
                        .strokeBorder(isSelected
                                      ? AnyShapeStyle(.tint)
                                      : AnyShapeStyle(.white.opacity(0.08)),
                                      lineWidth: isSelected ? 3 : 1)
                }
        }
    }

    @ViewBuilder
    private func art(_ image: NSImage?) -> some View {
        if let image {
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
