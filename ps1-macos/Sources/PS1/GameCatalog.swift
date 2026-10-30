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

    static func id(of game: GameGroup) -> String {
        SaveStateStore.key(for: game.first)
    }

    static func game(id: String, in games: [GameGroup]) -> GameGroup? {
        games.first { self.id(of: $0) == id }
    }

    /// The played games, most recent first, then the rest by title.
    static func suggested(_ games: [GameGroup], stats: [String: PlayStats]) -> [GameGroup] {
        let played = games
            .compactMap { game in stats[id(of: game)]?.lastPlayed.map { (game, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        let playedIDs = Set(played.map(id))
        let rest = games
            .filter { !playedIDs.contains(id(of: $0)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return played + rest
    }

    static func lastPlayed(_ games: [GameGroup], stats: [String: PlayStats]) -> GameGroup? {
        games
            .compactMap { game in stats[id(of: game)]?.lastPlayed.map { (game, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    static func matching(_ games: [GameGroup], query: String) -> [GameGroup] {
        LibrarySearch.filter(games, query: query)
    }
}
