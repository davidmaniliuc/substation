import Foundation

/// How the library shows its games.
enum LibraryViewMode: Int, CaseIterable {
    case grid = 0
    case list = 1
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
    static let sizeRange: ClosedRange<Double> = 100...260
    /// Today's grid minimum, so the library looks unchanged until the
    /// slider moves.
    static let defaultSize = 132.0
    /// What Bigger and Smaller Covers move by.
    static let step = 20.0

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

    private static func clamped(_ value: Double) -> Double {
        min(max(value, sizeRange.lowerBound), sizeRange.upperBound)
    }
}
