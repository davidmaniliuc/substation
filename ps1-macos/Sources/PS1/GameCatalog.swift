import Foundation

/// The library as App Intents see it: one game per MERGED group, whatever
/// Merge Multi-Disc Games says, identified by the key its resume states and
/// play stats are filed under (`LibraryCollection.statsKeys`' rule). So
/// Spotlight, Shortcuts, the Continue capsule and the resume sheet all name
/// one game the same way.
enum GameCatalog {
    static func games(_ entries: [GameEntry]) -> [GameGroup] {
        DiscGrouping.group(entries, merging: true)
    }

    /// What the game's resume states and play stats are filed under.
    static func key(of game: GameGroup) -> String {
        SaveStateStore.key(for: game.first)
    }

    /// The key, unless another game in the library shares it (two rips of
    /// one disc): those share their states, but each must stay a thing to
    /// pick, so their ids add the first disc's path hash.
    static func id(of game: GameGroup, in games: [GameGroup]) -> String {
        let key = key(of: game)
        let shared = games.lazy.filter { self.key(of: $0) == key }.dropFirst().first != nil
        return shared ? "\(key)#\(game.first.pathKey)" : key
    }

    static func game(id: String, in games: [GameGroup]) -> GameGroup? {
        games.first { self.id(of: $0, in: games) == id }
    }

    /// The played games, most recent first, then the rest by title.
    static func suggested(_ games: [GameGroup], stats: [String: PlayStats]) -> [GameGroup] {
        let played = games
            .compactMap { game in stats[key(of: game)]?.lastPlayed.map { (game, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        let playedKeys = Set(played.map(key))
        let rest = games
            .filter { !playedKeys.contains(key(of: $0)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return played + rest
    }

    static func lastPlayed(_ games: [GameGroup], stats: [String: PlayStats]) -> GameGroup? {
        games
            .compactMap { game in stats[key(of: game)]?.lastPlayed.map { (game, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    static func matching(_ games: [GameGroup], query: String) -> [GameGroup] {
        LibrarySearch.filter(games, query: query)
    }
}

/// Why an intent could not act, in the words the player is shown.
enum IntentFailure: Error, Equatable {
    case notSetUp
    case gameMissing
    case nothingPlayed
    /// A sheet or prompt is up and waiting for the player.
    case busy

    var message: String {
        switch self {
        case .notSetUp: "Choose a games folder in Substation first."
        case .gameMissing: "That game is no longer in your library."
        case .nothingPlayed: "You haven't played anything yet."
        case .busy: "Substation is waiting for you to answer a question."
        }
    }
}
