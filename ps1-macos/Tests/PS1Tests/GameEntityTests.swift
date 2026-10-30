import Testing
import Foundation
@testable import PS1

struct GameEntityTests {
    private func disc(_ path: String, serial: String) -> GameEntry {
        GameEntry(url: URL(fileURLWithPath: path),
                  identity: DiscIdentity(region: .america, serial: serial, volumeID: nil))
    }

    @Test func anEntityShowsTheTileSubtitle() {
        let ff9 = GameCatalog.games([
            disc("/games/FF9/Final Fantasy IX (Disc 1).cue", serial: "SLUS-01251"),
            disc("/games/FF9/Final Fantasy IX (Disc 2).cue", serial: "SLUS-01295"),
        ])[0]
        let crash = GameCatalog.games([disc("/games/Crash.cue", serial: "SCUS-94900")])[0]
        #expect(GameEntity(ff9, stats: nil, cover: nil).subtitle == "2 discs")
        #expect(GameEntity(crash, stats: nil, cover: nil).subtitle == "Not played yet")
    }

    @Test func anEntityIdIsTheCatalogueId() {
        let crash = GameCatalog.games([disc("/games/Crash.cue", serial: "SCUS-94900")])[0]
        let entity = GameEntity(crash, stats: PlayStats(lastPlayed: .now), cover: nil)
        #expect(entity.id == GameCatalog.id(of: crash))
        #expect(entity.title == crash.title)
    }
}
