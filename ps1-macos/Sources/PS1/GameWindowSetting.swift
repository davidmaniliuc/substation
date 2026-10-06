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

    private var choice: PersistedChoice<GameWindowMode>
    var mode: GameWindowMode { choice.value }

    init(key: String = GameWindowSetting.defaultsKey, defaults: UserDefaults = .standard) {
        choice = PersistedChoice(key: key, defaults: defaults, fallback: Self.defaultMode)
    }

    mutating func set(_ value: GameWindowMode) { choice.set(value) }
}
