import Foundation

/// Where a game opens: in place of the library, or in a window of its own
/// with the library left open beside it. Still one game at a time either way.
enum GameWindowMode: Int, CaseIterable {
    case libraryWindow = 0
    case newWindow = 1

    var title: String {
        switch self {
        case .libraryWindow: "Library Window"
        case .newWindow: "New Window"
        }
    }
}

struct GameWindowSetting {
    static let defaultsKey = "gameWindow"
    static let defaultMode = GameWindowMode.libraryWindow

    private let defaults: UserDefaults
    private let fullScreenKey: String
    private var choice: PersistedChoice<GameWindowMode>
    var mode: GameWindowMode { choice.value }
    /// A game's own window opens in full screen. Means nothing in the
    /// library's window, where the setting is greyed out. Defaults to FALSE,
    /// so `bool(forKey:)`'s false-for-absent is the default.
    private(set) var fullScreen: Bool

    init(key: String = GameWindowSetting.defaultsKey, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fullScreenKey = key + "FullScreen"
        choice = PersistedChoice(key: key, defaults: defaults, fallback: Self.defaultMode)
        fullScreen = defaults.bool(forKey: fullScreenKey)
    }

    mutating func set(_ value: GameWindowMode) { choice.set(value) }

    mutating func setFullScreen(_ value: Bool) {
        fullScreen = value
        defaults.set(value, forKey: fullScreenKey)
    }
}
