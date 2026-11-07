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
    /// the disc token stripped, not `entry.title`, which is disc 1's own.
    let title: String
    /// The second line: the disc count, or when the game was last played.
    let subtitle: String
    let coverURL: URL?
    /// An accent outline around a flat cover, as Apple Music does; around a
    /// cut-out one it follows the case's own silhouette (see `framed`).
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
    private static let corner = Design.Radius.tile
    private static let dragPreviewSide: CGFloat = 150
    /// A cut-out's selection highlight sits `highlightInset` past its
    /// square, concentric with it, on the scale's next step up.
    private static let highlightRadius = Design.Radius.tileHighlight
    private static let highlightInset = highlightRadius - corner

    var body: some View {
        let image = coverURL.flatMap(NSImage.init(contentsOf:))
        let cutOut = image.map(CoverShape.isCutOut) ?? false
        VStack(alignment: .leading, spacing: Design.Spacing.s) {
            framed(art(image), cutOut: cutOut)
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
                        preview.clipShape(Design.cardShape(Self.corner))
                    }
                }

            VStack(alignment: .leading, spacing: Design.Spacing.xxs) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Design.Spacing.xxs)
        }
        // The caption sits flush with the cover's leading edge, whatever
        // width the grid's column gives the tile.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: play)
        // Simultaneous, so a single click selects at once rather than after
        // the double-click interval has run out.
        .simultaneousGesture(TapGesture().onEnded(select))
        .contextMenu {
            GameContextMenu(entry: entry, play: play, chooseCover: chooseCover,
                            downloadCover: downloadCover, removeCover: removeCover)
        }
        .help(entry.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Play", play)
    }

    /// A flat scan is clipped and outlined as a square. A cut-out (a 3D case)
    /// is drawn as its own shape: the square around it is empty, so a clip,
    /// hairline or ring on it outlines nothing but the grid. Its selection is
    /// a soft rounded highlight behind the square, as Finder selects an icon.
    /// A ring traced round the case's alpha read as a coloured slab under
    /// it. The shadow goes on the art alone, never on the highlight.
    @ViewBuilder
    private func framed(_ art: some View, cutOut: Bool) -> some View {
        let square = art.aspectRatio(Self.aspect, contentMode: .fit)
        if cutOut {
            square
                .designShadow(.tile)
                .background {
                    if isSelected {
                        Design.cardShape(Self.highlightRadius)
                            .fill(.tint.tertiary)
                            .padding(-Self.highlightInset)
                    }
                }
        } else {
            square
                .clipShape(Design.cardShape(Self.corner))
                .overlay {
                    Design.cardShape(Self.corner).strokeBorder(.separator)
                }
                // Outside the art and concentric with it, so the ring never
                // covers the cover and its inner corner matches the cover's.
                .overlay {
                    if isSelected {
                        Design.cardShape(Self.corner + Design.Focus.selectionWidth)
                            .strokeBorder(.tint, lineWidth: Design.Focus.selectionWidth)
                            .padding(-Design.Focus.selectionWidth)
                    }
                }
                .designShadow(.tile)
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
            Rectangle().fill(.fill.quaternary)

            Image(systemName: "opticaldisc")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.secondary)
        }
    }
}
