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
        #expect(GameEntity(ff9, id: "ff9", stats: nil, cover: nil).subtitle == "2 discs")
        #expect(GameEntity(crash, id: "crash", stats: nil, cover: nil).subtitle == "Not played yet")
    }

    /// Spotlight keeps what it was given until the next write, so a played
    /// game says when as a date, never "2 hours ago".
    @Test func aPlayedGameSaysWhenAsADate() {
        let played = Date(timeIntervalSince1970: 1_793_318_400)   // 2026-10-30
        #expect(LibraryFormat.entitySubtitle(discs: 1, lastPlayed: played,
                                             locale: Locale(identifier: "en_US"),
                                             timeZone: TimeZone(identifier: "UTC")!)
                == "Last played Oct 30, 2026")
        #expect(LibraryFormat.entitySubtitle(discs: 2, lastPlayed: played) == "2 discs")
        #expect(LibraryFormat.entitySubtitle(discs: 1, lastPlayed: nil) == "Not played yet")
    }

    @Test func anEntityIdIsTheCatalogueId() {
        let crash = GameCatalog.games([disc("/games/Crash.cue", serial: "SCUS-94900")])[0]
        let entity = GameEntity(crash, id: "crash-id", stats: PlayStats(lastPlayed: .now), cover: nil)
        #expect(entity.id == "crash-id")
        #expect(entity.title == crash.title)
    }
}

extension GameEntityTests {
    /// Spotlight searches the index, not the query: a serial typed there
    /// finds the game only if the entity carries it.
    @Test func spotlightIndexesEverySerial() {
        let ff9 = GameCatalog.games([
            disc("/games/FF9/Final Fantasy IX (Disc 1).cue", serial: "SLUS-01251"),
            disc("/games/FF9/Final Fantasy IX (Disc 2).cue", serial: "SLUS-01295"),
        ])[0]
        let keywords = GameEntity(ff9, id: "ff9", stats: nil, cover: nil).attributeSet.keywords ?? []
        #expect(keywords.contains("SLUS-01251"))
        #expect(keywords.contains("SLUS-01295"))
    }
}

@MainActor @Suite(.serialized)
struct GamePublishingTests {
    private func makeModel() -> (EmulatorViewModel, () -> Int) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("publish-\(UUID().uuidString)")
        let model = EmulatorViewModel(
            saveStates: SaveStateStore(resumeDirectory: root.appendingPathComponent("r"),
                                       slotsDirectory: root.appendingPathComponent("s")),
            autoSave: AutoSaveSetting())
        final class Count { var n = 0 }
        let count = Count()
        model.publishEntities = { _ in count.n += 1 }
        return (model, { count.n })
    }

    /// The hosted test app scans the developer's real library: it must not
    /// write their Spotlight index each time a test builds a model.
    @Test func aTestHostPublishesNowhere() {
        #expect(EmulatorViewModel.publishesToSystem == false)
    }

    /// A download sweep changes covers one by one: Spotlight gets one write
    /// for the burst, and no two writes interleave.
    @Test func aBurstOfChangesPublishesOnce() async {
        let (model, published) = makeModel()
        model.publishGamesToSystem()
        model.publishGamesToSystem()
        model.publishGamesToSystem()
        try? await Task.sleep(for: .seconds(2))
        #expect(published() == 1)
    }

    /// A changed cover reaches Spotlight without waiting for a rescan.
    @Test func aCoverChangeRepublishes() async {
        let (model, published) = makeModel()
        try? await Task.sleep(for: .seconds(2))
        let before = published()
        model.removeCover(for: GameEntry(url: URL(fileURLWithPath: "/publish-tests/Game.cue")))
        try? await Task.sleep(for: .seconds(2))
        #expect(published() == before + 1)
    }
}
