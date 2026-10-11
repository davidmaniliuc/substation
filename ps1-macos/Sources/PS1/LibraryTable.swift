import AppKit
import SwiftUI

/// The library as a sortable table: the same games as the grid, with their
/// region and play history.
struct LibraryTable: View {
    let rows: [LibraryRow]
    @Binding var selection: GameGroup.ID?
    let theme: LibraryTheme
    let size: LibraryListSize
    let coverURL: (GameEntry) -> URL?
    let play: (GameGroup) -> Void
    let menu: (GameGroup) -> GameContextMenu
    /// From `EmulatorViewModel.librarySortOrder`, which outlives this view.
    @Binding var sortOrder: [KeyPathComparator<LibraryRow>]
    /// Whether the table should hold the keyboard: false while a dialog is
    /// drawn over it, so the dialog's buttons get Return and Escape.
    var isFocused: Bool = true

    var body: some View {
        Table(rows.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn(LibraryColumn.name.title, value: \.title) { row in
                HStack(spacing: 6) {
                    Thumbnail(url: coverURL(row.group.first), side: size.coverSide)
                    Text(row.title).lineLimit(1)
                }
            }
            // No maximum, and every other column's is close to its ideal, so
            // the free width goes to the name, as in Finder.
            .width(min: 180, ideal: LibraryColumn.name.idealWidth)
            TableColumn(LibraryColumn.region.title, value: \.region) { Detail($0.region) }
                .width(min: 55, ideal: LibraryColumn.region.idealWidth, max: 75)
            TableColumn(LibraryColumn.discs.title, value: \.discs) { Detail("\($0.discs)") }
                .width(min: 40, ideal: LibraryColumn.discs.idealWidth, max: 50)
                .alignment(.trailing)
            TableColumn(LibraryColumn.lastPlayed.title, value: \.lastPlayedSortKey) {
                Detail(LibraryFormat.lastPlayed($0.lastPlayed, now: Date()))
            }
            .width(min: 80, ideal: LibraryColumn.lastPlayed.idealWidth, max: 120)
            TableColumn(LibraryColumn.playTime.title, value: \.seconds) {
                Detail(LibraryFormat.playTime($0.seconds))
            }
            .width(min: 65, ideal: LibraryColumn.playTime.idealWidth, max: 90)
            .alignment(.trailing)
        }
        // Off the native chrome the backdrop shows through the table, its
        // header included, and the theme's hairlines separate the rows.
        // Inset, never automatic: AppKit resolves automatic to full width
        // once the columns are wider than the window, and the selection
        // loses its rounded corners.
        .tableStyle(.inset)
        .scrollContentBackground(theme.tableBackground)
        .alternatingRowBackgrounds(theme.tableStripes)
        .background(TableReach(separator: theme.rowSeparator, isFocused: isFocused,
                               size: size))
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

/// The list's columns: each one's title, and the width a double click on
/// its trailing divider puts back.
enum LibraryColumn: CaseIterable {
    case name, region, discs, lastPlayed, playTime

    var title: String {
        switch self {
        case .name: "Name"
        case .region: "Region"
        case .discs: "Discs"
        case .lastPlayed: "Last Played"
        case .playTime: "Play Time"
        }
    }

    var idealWidth: CGFloat {
        switch self {
        case .name: 240
        case .region: 70
        case .discs: 45
        case .lastPlayed: 110
        case .playTime: 80
        }
    }

    init?(title: String) {
        guard let column = Self.allCases.first(where: { $0.title == title }) else { return nil }
        self = column
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
/// - The row heights, measured again when the list size shrinks.
/// - A double click on a column divider puts the column before it back to
///   its ideal width, as Finder's divider does. SwiftUI's table delegate has
///   no `sizeToFitWidthOfColumn`, so a local monitor watches the header.
private struct TableReach: NSViewRepresentable {
    let separator: NSColor?
    let isFocused: Bool
    let size: LibraryListSize

    @MainActor final class Coordinator {
        var wasFocused = false
        var measuredSize: LibraryListSize?
        weak var table: NSTableView?
        private var monitor: Any?

        /// Installs the divider monitor once, on the first table found.
        func watchDividers(of table: NSTableView) {
            self.table = table
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                // Local monitors run on the main thread.
                MainActor.assumeIsolated {
                    if event.clickCount == 2 { self?.resetColumn(at: event) }
                }
                return event
            }
        }

        /// The divider's hit zone either side of it, matching the region
        /// where the header shows its resize cursor.
        private static let dividerSlop: CGFloat = 4

        private func resetColumn(at event: NSEvent) {
            guard let table, let header = table.headerView, event.window === table.window
            else { return }
            let point = header.convert(event.locationInWindow, from: nil)
            guard header.bounds.contains(point) else { return }
            let hit = table.tableColumns.indices.first { index in
                abs(header.headerRect(ofColumn: index).maxX - point.x) <= Self.dividerSlop
            }
            guard let hit else { return }
            let column = table.tableColumns[hit]
            guard let ideal = LibraryColumn(title: column.headerCell.stringValue)?.idealWidth
            else { return }
            column.width = ideal
        }

        isolated deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        remeasureIfShrunk(context.coordinator)
        apply(near: view, coordinator: context.coordinator, turnsLeft: 10)
    }

    /// The rows size themselves to their cells, and growing needs nothing
    /// more. Shrinking does: AppKit keeps each row's measured height, so a
    /// smaller cover was left in a large row. Turning automatic heights off
    /// and on drops those heights. It is done here, in the update that
    /// redraws the cover, not on a later turn: the rows are measured at the
    /// next layout, before anything is drawn, so cover and row change in
    /// one frame, where a later turn moved the text in a second step.
    private func remeasureIfShrunk(_ coordinator: Coordinator) {
        guard let table = coordinator.table, let measured = coordinator.measuredSize,
              measured != size else { return }
        coordinator.measuredSize = size
        guard size.rawValue < measured.rawValue else { return }
        table.usesAutomaticRowHeights = false
        table.usesAutomaticRowHeights = true
        table.noteHeightOfRows(withIndexesChanged: IndexSet(0..<table.numberOfRows))
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
            coordinator.watchDividers(of: table)
            if coordinator.measuredSize == nil { coordinator.measuredSize = size }
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
