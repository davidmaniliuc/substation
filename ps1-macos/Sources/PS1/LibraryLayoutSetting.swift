import Foundation

/// How the library shows its games.
enum LibraryViewMode: Int, CaseIterable {
    case grid = 0
    case list = 1

    /// The menu item's title, and the toolbar segment's tooltip and
    /// accessibility label.
    var title: String {
        switch self {
        case .grid: "as Grid"
        case .list: "as List"
        }
    }

    var symbol: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }
}

/// The library's view mode and grid tile width, persisted. Shaped after
/// `InternalResolution`: `init` resolves, `set` persists, the clamp lives in
/// the type so it is reachable from a test without a window.
///
/// The tile size has two values. `tileSize` is LIVE: the slider moves it on
/// every drag tick so tiles resize as it goes, and AppKit may also push a
/// value with no drag at all (a bare test launch once stored 119.47, a
/// knob position). Only `commitTileSize()` persists it, and the view calls
/// that when a drag is released, so a value nobody chose never reaches
/// `UserDefaults`.
///
/// The size is probed with `object(forKey:)`: `double(forKey:)` reads an
/// absent key as 0, which the clamp would turn into the SMALLEST tiles
/// rather than today's default.
struct LibraryLayoutSetting {
    /// The smallest tile, which sets the most columns a width can hold.
    /// There is no fixed largest: the top of the range is one column at the
    /// grid's width (`sizeRange(width:)`), so it moves with the window.
    static let minimumSize = 100.0
    /// Today's grid minimum, so the library looks unchanged until the
    /// slider moves.
    static let defaultSize = 132.0
    /// The gap between tiles, which the column count depends on.
    static let tileSpacing = 20.0

    private let defaults: UserDefaults
    private let sizeKey: String
    private var mode: PersistedChoice<LibraryViewMode>
    private(set) var tileSize: Double
    /// What `UserDefaults` holds (or would, absent a key), to skip no-op writes.
    private var committedSize: Double

    var viewMode: LibraryViewMode { mode.value }

    init(viewModeKey: String = "libraryViewMode", sizeKey: String = "libraryTileSize",
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.sizeKey = sizeKey
        mode = PersistedChoice(key: viewModeKey, defaults: defaults, fallback: .grid)
        let stored = (defaults.object(forKey: sizeKey) as? NSNumber)?.doubleValue
        tileSize = Self.clamped(stored ?? Self.defaultSize)
        committedSize = tileSize
    }

    mutating func setViewMode(_ value: LibraryViewMode) { mode.set(value) }

    /// Moves the live size. Persists nothing.
    mutating func setTileSize(_ value: Double) {
        tileSize = Self.clamped(value)
    }

    /// Persists the live size, unless it is already what is stored.
    mutating func commitTileSize() {
        guard tileSize != committedSize else { return }
        committedSize = tileSize
        defaults.set(tileSize, forKey: sizeKey)
    }

    /// Puts the size back to `defaultSize` and persists it: View ▸ Actual Size.
    mutating func resetTileSize() {
        setTileSize(Self.defaultSize)
        commitTileSize()
    }

    /// The slider's range at a grid `width` wide: from the most columns
    /// `minimumSize` lays out to one column, both ends a column step. Before
    /// the grid has reported a width, up to `defaultSize`.
    static func sizeRange(width: Double) -> ClosedRange<Double> {
        guard width > 0, let one = size(forColumns: 1, width: width) else {
            return minimumSize...defaultSize
        }
        return minimumSize...max(minimumSize, one)
    }

    /// The SMALLEST tile size, no smaller than `minimumSize`, at which a grid `width` wide
    /// lays out exactly `columns` columns, or nil when none does.
    ///
    /// Bigger and Smaller Covers step by a column, not by points: the grid
    /// is `.adaptive`, so a fixed step often keeps the column count and only
    /// re-stretches the tiles, and the press reads as doing nothing. The
    /// smallest size is taken so a press lands just inside the new count.
    /// The answer is checked against `GridSelection.columns`, the count the
    /// grid itself arrives at, so the two cannot disagree.
    static func size(forColumns columns: Int, width: Double) -> Double? {
        guard columns >= 1 else { return nil }
        let below = (width + tileSpacing) / Double(columns + 1) - tileSpacing
        let size = max(minimumSize, below.rounded(.down) + 1)
        guard GridSelection.columns(width: width, minimum: size, spacing: tileSpacing) == columns
        else { return nil }
        return size
    }

    /// The column step a slider drag at `value` lands on: the size
    /// `size(forColumns:width:)` gives the column count `value` lays out, so
    /// the slider moves in the same unseen notches as Bigger/Smaller Covers.
    /// Every value from one column's step up lands on it, so the range's top
    /// is a notch too. The value itself, clamped, before the grid has a
    /// width to step at.
    static func snapped(_ value: Double, width: Double) -> Double {
        let value = clamped(value)
        guard width > 0 else { return value }
        let count = GridSelection.columns(width: width, minimum: value, spacing: tileSpacing)
        return size(forColumns: count, width: width) ?? value
    }

    private static func clamped(_ value: Double) -> Double {
        max(value, minimumSize)
    }
}
