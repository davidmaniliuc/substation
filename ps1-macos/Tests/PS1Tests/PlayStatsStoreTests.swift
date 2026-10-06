import Testing
import Foundation
@testable import PS1

private func makeDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("playstats-\(UUID().uuidString)")
}

@Test func playStatsSurviveAReload() {
    let dir = makeDirectory()
    let when = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let store = PlayStatsStore(directory: dir)
    store.markPlayed("SLUS-00530", at: when)
    store.add(125, to: "SLUS-00530")
    store.add(5, to: "SLUS-00530")

    let reloaded = PlayStatsStore(directory: dir)
    #expect(reloaded.stats(for: "SLUS-00530") == PlayStats(lastPlayed: when, seconds: 130))
}

@Test func aMissingFileIsAnEmptyLibraryOfStats() {
    let store = PlayStatsStore(directory: makeDirectory())
    #expect(store.all.isEmpty)
    #expect(store.stats(for: "SLUS-00530") == nil)
}

/// Unreadable stats read as none, and nothing deletes the file on read: it
/// stays on disk until the next record is written over it.
@Test func aDamagedFileReadsAsEmptyAndIsLeftAlone() throws {
    let dir = makeDirectory()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("stats.json")
    try Data("not json".utf8).write(to: file)

    let store = PlayStatsStore(directory: dir)
    #expect(store.all.isEmpty)
    #expect(try Data(contentsOf: file) == Data("not json".utf8))

    store.add(10, to: "SLUS-00530")
    #expect(PlayStatsStore(directory: dir).stats(for: "SLUS-00530")?.seconds == 10)
}

@Test func addingNoTimeWritesNothing() {
    let dir = makeDirectory()
    PlayStatsStore(directory: dir).add(0, to: "SLUS-00530")
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("stats.json").path))
}
