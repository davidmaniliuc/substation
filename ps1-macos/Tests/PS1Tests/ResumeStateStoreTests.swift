import Testing
import Foundation
@testable import PS1

private func makeStore() -> ResumeStateStore {
    ResumeStateStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("resume-\(UUID().uuidString)"))
}

private func entry(_ path: String, serial: String?) -> GameEntry {
    GameEntry(url: URL(fileURLWithPath: path), identity: DiscIdentity(region: .america, serial: serial, volumeID: nil))
}

@Test func aStateReadsBackByteForByteThroughCompression() throws {
    let store = makeStore()
    let state = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 / 1000) })
    try store.save(state: state, thumbnail: Data([1, 2, 3]), key: "SLUS-00001")
    #expect(store.load("SLUS-00001") == state)
    let info = try #require(store.info("SLUS-00001"))
    #expect(info.thumbnail != nil)
    #expect(abs(info.savedAt.timeIntervalSinceNow) < 60)
}

@Test func aGameWithNoStateHasNoInfo() {
    #expect(makeStore().info("nothing") == nil)
    #expect(makeStore().load("nothing") == nil)
}

@Test func savingWithoutAThumbnailDropsTheOldOne() throws {
    let store = makeStore()
    try store.save(state: Data([1]), thumbnail: Data([9]), key: "k")
    try store.save(state: Data([2]), thumbnail: nil, key: "k")
    #expect(store.info("k")?.thumbnail == nil)
}

@Test func removeDeletesStateAndThumbnail() throws {
    let store = makeStore()
    try store.save(state: Data([1]), thumbnail: Data([9]), key: "k")
    store.remove("k")
    #expect(store.info("k") == nil)
}

@Test func anUndecodableFileLoadsAsNilButStillHasInfo() throws {
    // So the prompt still appears and Delete & Boot stays reachable.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID().uuidString)")
    let store = ResumeStateStore(directory: dir)
    try store.save(state: Data([1]), thumbnail: nil, key: "k")
    try Data("garbage".utf8).write(to: dir.appendingPathComponent("k.state"))
    #expect(store.load("k") == nil)
    #expect(store.info("k") != nil)
}

@Test func theKeyIsTheSerialElseThePathHash() {
    #expect(ResumeStateStore.key(for: entry("/g/a.cue", serial: "SCUS-94163")) == "SCUS-94163")
    let unnamed = entry("/g/b.cue", serial: nil)
    #expect(ResumeStateStore.key(for: unnamed) == unnamed.pathKey)
    #expect(unnamed.pathKey.count == 64)
}

@Test func saveOnExitDefaultsOnAndPersists() {
    let defaults = UserDefaults(suiteName: "resume-\(UUID().uuidString)")!
    var setting = ResumeOnExitSetting(key: "k", defaults: defaults)
    #expect(setting.enabled)
    setting.set(false)
    #expect(!ResumeOnExitSetting(key: "k", defaults: defaults).enabled)
}
