import AppKit

/// The widescreen hack: the core narrows every 3D position so the picture,
/// drawn at a wider shape, shows more of the world undistorted. The raw
/// values are the C ABI's `PS1_WIDESCREEN_*` numbers, pinned by
/// `widescreenRawValuesMatchTheHeader`.
public enum Widescreen: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case wide16x10 = 1
    case wide16x9 = 2
    case wide21x9 = 3

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .wide16x10: return "16:10"
        case .wide16x9: return "16:9"
        case .wide21x9: return "21:9"
        }
    }

    /// The shape a game's window is held to, and the picture drawn at.
    var aspect: NSSize {
        switch self {
        case .off: return NSSize(width: 4, height: 3)
        case .wide16x10: return NSSize(width: 16, height: 10)
        case .wide16x9: return NSSize(width: 16, height: 9)
        case .wide21x9: return NSSize(width: 21, height: 9)
        }
    }
}

/// The persisted widescreen mode. Same shape as `DisplayEffectSetting`.
struct WidescreenSetting {
    static let defaultsKey = "widescreen"
    static let defaultMode = Widescreen.off

    private var choice: PersistedChoice<Widescreen>
    var mode: Widescreen { choice.value }

    init(key: String = WidescreenSetting.defaultsKey,
         defaults: UserDefaults = .standard) {
        choice = PersistedChoice(key: key, defaults: defaults, fallback: Self.defaultMode)
    }

    mutating func set(_ value: Widescreen) { choice.set(value) }
}
