import Testing
import Foundation
@testable import PS1

struct GameCatalogTests {
    private func disc(_ path: String, serial: String? = nil) -> GameEntry {
        GameEntry(url: URL(fileURLWithPath: path),
                  identity: DiscIdentity(region: .america, serial: serial, volumeID: nil))
    }

    private var ff7: [GameEntry] {
        [disc("/games/FF7/Final Fantasy VII (Disc 1).cue", serial: "SCUS-94163"),
         disc("/games/FF7/Final Fantasy VII (Disc 2).cue", serial: "SCUS-94164"),
         disc("/games/FF7/Final Fantasy VII (Disc 3).cue", serial: "SCUS-94165")]
    }
    private var crash: GameEntry { disc("/games/Crash Bandicoot.cue", serial: "SCUS-94900") }
    private var homebrew: GameEntry { disc("/games/Homebrew.cue") }

    @Test func mergedDiscsAreOneGameKeyedOnDiscOne() {
        let games = GameCatalog.games(ff7)
        #expect(games.count == 1)
        #expect(games.first.map(GameCatalog.id) == "SCUS-94163")
    }

    @Test func aDiscWithNoSerialIsKeyedOnItsPathHash() {
        let games = GameCatalog.games([homebrew])
        #expect(games.first.map(GameCatalog.id) == homebrew.pathKey)
    }

    @Test func gameByIdFindsItAndAStaleIdFindsNothing() {
        let games = GameCatalog.games(ff7 + [crash])
        #expect(GameCatalog.game(id: "SCUS-94900", in: games)?.title == crash.title)
        #expect(GameCatalog.game(id: "SLUS-00000", in: games) == nil)
    }

    @Test func suggestionsAreNewestPlayedThenUnplayedByTitle() {
        let games = GameCatalog.games(ff7 + [crash, homebrew])
        let stats = [
            "SCUS-94163": PlayStats(lastPlayed: Date(timeIntervalSince1970: 100)),
            "SCUS-94900": PlayStats(lastPlayed: Date(timeIntervalSince1970: 200)),
        ]
        let ids = GameCatalog.suggested(games, stats: stats).map(GameCatalog.id)
        #expect(ids == ["SCUS-94900", "SCUS-94163", homebrew.pathKey])
    }

    @Test func lastPlayedIsTheMergedGame() {
        let games = GameCatalog.games(ff7 + [crash])
        let stats = [
            "SCUS-94163": PlayStats(lastPlayed: Date(timeIntervalSince1970: 300)),
            "SCUS-94900": PlayStats(lastPlayed: Date(timeIntervalSince1970: 200)),
        ]
        let last = GameCatalog.lastPlayed(games, stats: stats)
        #expect(last.map(GameCatalog.id) == "SCUS-94163")
        #expect(last?.discs.count == 3)
    }

    @Test func lastPlayedIsNilWhenNothingWasPlayed() {
        let games = GameCatalog.games([crash])
        #expect(GameCatalog.lastPlayed(games, stats: [:]) == nil)
        #expect(GameCatalog.lastPlayed(games, stats: ["SCUS-94900": PlayStats(seconds: 5)]) == nil)
    }

    @Test func matchingUsesTheLibrarySearch() {
        let games = GameCatalog.games(ff7 + [crash])
        #expect(GameCatalog.matching(games, query: "scus-94900").map(GameCatalog.id) == ["SCUS-94900"])
        #expect(GameCatalog.matching(games, query: "fantasy").count == 1)
    }
}
