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
    /// Whether the table should hold the keyboard: false while a dialog is
    /// drawn over it, so the dialog's buttons get Return and Escape.
    var isFocused: Bool = true
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
            .width(min: 180, ideal: 240)
            TableColumn("Region", value: \.region) { Detail($0.region) }
                .width(min: 55, ideal: 70, max: 75)
            TableColumn("Serial", value: \.serial) { Detail($0.serial) }
                .width(min: 92, ideal: 95, max: 100)
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
        .scrollContentBackground(theme.tableBackground)
        .alternatingRowBackgrounds(theme.tableStripes)
        .background(TableReach(separator: theme.rowSeparator, isFocused: isFocused))
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

/// What SwiftUI's `Table` has no API for, applied to the `NSTableView` it
/// is drawn beside, the way `WindowConfigurator` reaches the window.
///
/// - The row separator: `gridStyleMask` and `gridColor` are public AppKit
///   and SwiftUI sets neither, so a value written here stays.
/// - The keyboard. `.focused` on a `Table` does not make the table view
///   first responder, and an NSTableView that is not draws its selection in
///   gray and ignores the arrow keys. So the table is made first responder
///   when it appears and whenever `isFocused` turns true (a dialog closing),
///   and gives it up when a dialog opens. Only on those changes: taking it
///   on every update would pull the keyboard back from anything the player
///   clicked since.
private struct TableReach: NSViewRepresentable {
    let separator: NSColor?
    let isFocused: Bool

    final class Coordinator { var wasFocused = false }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        apply(near: view, coordinator: context.coordinator, turnsLeft: 10)
    }

    /// On a later turn, retried for a few: the table is not in the hierarchy
    /// yet when the view is first updated, and a first update that finds no
    /// table would never be repeated, since nothing it reads has changed.
    private func apply(near view: NSView, coordinator: Coordinator, turnsLeft: Int) {
        DispatchQueue.main.async {
            guard let table = Self.table(near: view), let window = table.window else {
                if turnsLeft > 0 { apply(near: view, coordinator: coordinator, turnsLeft: turnsLeft - 1) }
                return
            }
            table.gridStyleMask = separator == nil ? [] : .solidHorizontalGridLineMask
            if let separator { table.gridColor = separator }

            guard isFocused != coordinator.wasFocused else { return }
            coordinator.wasFocused = isFocused
            if isFocused {
                window.makeFirstResponder(table)
            } else if window.firstResponder === table {
                window.makeFirstResponder(nil)
            }
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
