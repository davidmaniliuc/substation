import AppKit
import SwiftUI

/// The library as a sortable table: the same games as the grid, with their
/// region, serial and play history.
struct LibraryTable: View {
    let rows: [LibraryRow]
    @Binding var selection: GameGroup.ID?
    let theme: LibraryTheme
    let coverURL: (GameEntry) -> URL?
    let play: (GameGroup) -> Void
    let menu: (GameGroup) -> GameContextMenu
    /// From `EmulatorViewModel.librarySortOrder`, which outlives this view.
    @Binding var sortOrder: [KeyPathComparator<LibraryRow>]
    /// Finder's density: its rows are about 24 pt around a 16 pt icon.
    private static let thumbnail: CGFloat = 18

    var body: some View {
        Table(rows.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.title) { row in
                HStack(spacing: 6) {
                    Thumbnail(url: coverURL(row.group.first), side: Self.thumbnail)
                    Text(row.title).lineLimit(1)
                }
            }
            // No maximum, and every other column's is close to its ideal, so
            // the free width goes to the name, as in Finder.
            .width(min: 180, ideal: 360)
            TableColumn("Region", value: \.region) { Detail($0.region) }
                .width(min: 55, ideal: 70, max: 75)
            TableColumn("Serial", value: \.serial) { Detail($0.serial) }
                .width(min: 80, ideal: 95, max: 100)
            TableColumn("Discs", value: \.discs) { Detail("\($0.discs)") }
                .width(min: 40, ideal: 45, max: 50)
                .alignment(.trailing)
            TableColumn("Last Played", value: \.lastPlayedSortKey) {
                Detail(LibraryFormat.lastPlayed($0.lastPlayed, now: Date()))
            }
            .width(min: 80, ideal: 110, max: 120)
            TableColumn("Play Time", value: \.seconds) {
                Detail(LibraryFormat.playTime($0.seconds))
            }
            .width(min: 65, ideal: 80, max: 90)
            .alignment(.trailing)
        }
        // Off the native chrome the backdrop shows through the table, its
        // header included, and the theme's hairlines separate the rows.
        .scrollContentBackground(theme.nativeTableChrome ? .automatic : .hidden)
        .alternatingRowBackgrounds(theme.nativeTableChrome ? .enabled : .disabled)
        .background(RowSeparators(color: theme.rowSeparator))
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

/// Draws `color` between the table's rows, or restores none.
///
/// SwiftUI's `Table` has no separator API, so this reaches the `NSTableView`
/// it is drawn beside, the way `WindowConfigurator` reaches the window:
/// `gridStyleMask` and `gridColor` are public AppKit, and SwiftUI does not
/// set either, so a value written here stays.
private struct RowSeparators: NSViewRepresentable {
    let color: NSColor?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // On the next turn: the table is not in the hierarchy yet when the
        // view is first updated.
        DispatchQueue.main.async {
            guard let table = Self.table(near: view) else { return }
            table.gridStyleMask = color == nil ? [] : .solidHorizontalGridLineMask
            if let color { table.gridColor = color }
        }
    }

    /// The nearest table under one of the marker's few closest ancestors:
    /// the marker and the table are siblings in SwiftUI's background stack.
    private static func table(near view: NSView) -> NSTableView? {
        var ancestor = view.superview
        for _ in 0..<4 {
            guard let current = ancestor else { return nil }
            if let found = firstTable(in: current) { return found }
            ancestor = current.superview
        }
        return nil
    }

    private static func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap(firstTable(in:)).first
    }
}

/// Every column but the name, in the secondary colour Finder gives its
/// dates and sizes, so the eye lands on the title.
private struct Detail: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).foregroundStyle(.secondary).lineLimit(1)
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
                    art.clipShape(.rect(cornerRadius: 3))
                }
            } else {
                Image(systemName: "opticaldisc").foregroundStyle(.tertiary)
            }
        }
        .frame(width: side, height: side)
    }
}
