import AppKit
import SwiftUI

/// The library as a sortable table: the same games as the grid, with their
/// region, serial and play history.
struct LibraryTable: View {
    let rows: [LibraryRow]
    @Binding var selection: GameGroup.ID?
    let coverURL: (GameEntry) -> URL?
    let play: (GameGroup) -> Void
    let menu: (GameGroup) -> GameContextMenu

    /// Session-only, starting by name: a sort is a question asked now.
    @State private var sortOrder = [KeyPathComparator(\LibraryRow.title)]
    private static let thumbnail: CGFloat = 28

    var body: some View {
        Table(rows.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.title) { row in
                HStack(spacing: 8) {
                    Thumbnail(url: coverURL(row.group.first), side: Self.thumbnail)
                    Text(row.title).lineLimit(1)
                }
            }
            .width(min: 180, ideal: 320)
            TableColumn("Region", value: \.region).width(min: 60, ideal: 70)
            TableColumn("Serial", value: \.serial).width(min: 80, ideal: 100)
            TableColumn("Discs", value: \.discs) { Text("\($0.discs)") }.width(min: 40, ideal: 45)
            TableColumn("Last Played", value: \.lastPlayedSortKey) {
                Text(LibraryFormat.lastPlayed($0.lastPlayed, now: Date()))
            }
            .width(min: 80, ideal: 100)
            TableColumn("Play Time", value: \.seconds) {
                Text(LibraryFormat.playTime($0.seconds))
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: GameGroup.ID.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                menu(row.group)
            }
        } primaryAction: { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                play(row.group)
            }
        }
    }
}

/// A row's cover, framed as the grid frames it: a flat scan rounded, a
/// cut-out case drawn as its own shape.
private struct Thumbnail: View {
    let url: URL?
    let side: CGFloat

    var body: some View {
        let image = url.flatMap(NSImage.init(contentsOf:))
        Group {
            if let image {
                let art = Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                if CoverShape.isCutOut(image) {
                    art
                } else {
                    art.clipShape(.rect(cornerRadius: 4))
                }
            } else {
                Image(systemName: "opticaldisc").foregroundStyle(.tertiary)
            }
        }
        .frame(width: side, height: side)
    }
}
