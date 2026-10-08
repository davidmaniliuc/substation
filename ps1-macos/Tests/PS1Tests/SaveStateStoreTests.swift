import Testing
import Foundation
@testable import PS1

private func tempDirectory(_ tag: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(tag)-\(UUID().uuidString)")
}

private func makeStore() -> (store: SaveStateStore, resume: URL, slots: URL) {
    let resume = tempDirectory("resume")
    let slots = tempDirectory("slots")
    return (SaveStateStore(resumeDirectory: resume, slotsDirectory: slots), resume, slots)
}

private func entry(_ path: String, serial: String?) -> GameEntry {
    GameEntry(url: URL(fileURLWithPath: path), identity: DiscIdentity(region: .america, serial: serial, volumeID: nil))
}

@Test func aStateReadsBackByteForByteThroughCompression() throws {
    let (store, _, _) = makeStore()
    let state = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 / 1000) })
    try store.saveResume(state: state, thumbnail: Data([1, 2, 3]), key: "SLUS-00001")
    #expect(store.load(.resume, key: "SLUS-00001") == state)
    let info = try #require(store.info(.resume, key: "SLUS-00001"))
    #expect(info.thumbnail != nil)
    #expect(abs(info.savedAt.timeIntervalSinceNow) < 60)
}

@Test func aGameWithNoStateHasNoInfo() {
    let (store, _, _) = makeStore()
    #expect(store.info(.resume, key: "nothing") == nil)
    #expect(store.load(.resume, key: "nothing") == nil)
    #expect(store.saved(key: "nothing").isEmpty)
}

@Test func savingWithoutAThumbnailDropsTheOldOne() throws {
    let (store, _, _) = makeStore()
    try store.saveSlot(1, state: Data([1]), thumbnail: Data([9]), key: "k")
    try store.saveSlot(1, state: Data([2]), thumbnail: nil, key: "k")
    #expect(store.info(.slot(1), key: "k")?.thumbnail == nil)
}

@Test func anUndecodableFileLoadsAsNilButStillHasInfo() throws {
    // So the prompt still appears and Delete & Boot stays reachable.
    let (store, resume, _) = makeStore()
    try store.saveResume(state: Data([1]), thumbnail: nil, key: "k")
    try Data("garbage".utf8).write(to: resume.appendingPathComponent("k.state"))
    #expect(store.load(.resume, key: "k") == nil)
    #expect(store.info(.resume, key: "k") != nil)
}

@Test func theKeyIsTheSerialElseThePathHash() {
    #expect(SaveStateStore.key(for: entry("/g/a.cue", serial: "SCUS-94163")) == "SCUS-94163")
    let unnamed = entry("/g/b.cue", serial: nil)
    #expect(SaveStateStore.key(for: unnamed) == unnamed.pathKey)
    #expect(unnamed.pathKey.count == 64)
}

@Test func saveOnExitDefaultsOnAndPersists() {
    let defaults = UserDefaults(suiteName: "resume-\(UUID().uuidString)")!
    var setting = ResumeOnExitSetting(key: "k", defaults: defaults)
    #expect(setting.enabled)
    setting.set(false)
    #expect(!ResumeOnExitSetting(key: "k", defaults: defaults).enabled)
}

@Test func aSecondResumeWriteKeepsTheFirstAsPrevious() throws {
    let (store, _, _) = makeStore()
    try store.saveResume(state: Data([1]), thumbnail: Data([7]), key: "k")
    #expect(store.info(.previous, key: "k") == nil)
    try store.saveResume(state: Data([2]), thumbnail: nil, key: "k")
    #expect(store.load(.resume, key: "k") == Data([2]))
    #expect(store.load(.previous, key: "k") == Data([1]))
    // The thumbnail travels with its state, and the new one has none.
    #expect(store.info(.previous, key: "k")?.thumbnail != nil)
    #expect(store.info(.resume, key: "k")?.thumbnail == nil)
}

@Test func aCrashAfterStagingLeavesTheOldResume() throws {
    let (store, resume, _) = makeStore()
    try store.saveResume(state: Data([1]), thumbnail: nil, key: "k")
    // Step 1 of a write done, steps 2 and 3 never ran.
    try StateFile(directory: resume, stem: "k.new").write(state: Data([2]), thumbnail: nil)
    #expect(store.load(.resume, key: "k") == Data([1]))
}

@Test func aWriteAfterACrashMidRotationKeepsThePrevious() throws {
    // Step 2 ran (the resume became previous), step 3 never did: no resume.
    let (store, resume, _) = makeStore()
    try StateFile(directory: resume, stem: "k.prev").write(state: Data([1]), thumbnail: nil)
    #expect(store.info(.resume, key: "k") == nil)
    try store.saveResume(state: Data([2]), thumbnail: nil, key: "k")
    #expect(store.load(.resume, key: "k") == Data([2]))
    #expect(store.load(.previous, key: "k") == Data([1]))
}

@Test func slotsLiveInAFolderPerGame() throws {
    let (store, _, slots) = makeStore()
    try store.saveSlot(3, state: Data([5]), thumbnail: Data([6]), key: "SLUS-1")
    #expect(FileManager.default.fileExists(atPath: slots.appendingPathComponent("SLUS-1/slot3.state").path))
    #expect(FileManager.default.fileExists(atPath: slots.appendingPathComponent("SLUS-1/slot3.png").path))
    #expect(store.load(.slot(3), key: "SLUS-1") == Data([5]))
    #expect(store.info(.slot(4), key: "SLUS-1") == nil)
}

@Test func savedListsEveryStateInMenuOrder() throws {
    let (store, _, _) = makeStore()
    try store.saveSlot(5, state: Data([1]), thumbnail: nil, key: "k")
    try store.saveResume(state: Data([1]), thumbnail: nil, key: "k")
    try store.saveResume(state: Data([2]), thumbnail: nil, key: "k")
    try store.saveSlot(2, state: Data([1]), thumbnail: nil, key: "k")
    #expect(store.saved(key: "k").map(\.source) == [.resume, .previous, .slot(2), .slot(5)])
}

@Test func removingTheResumeLeavesEverySlot() throws {
    let (store, _, _) = makeStore()
    try store.saveResume(state: Data([1]), thumbnail: nil, key: "k")
    try store.saveResume(state: Data([2]), thumbnail: nil, key: "k")
    try store.saveSlot(1, state: Data([3]), thumbnail: nil, key: "k")
    store.removeResume("k")
    #expect(store.info(.resume, key: "k") == nil)
    #expect(store.info(.previous, key: "k") == nil)
    #expect(store.load(.slot(1), key: "k") == Data([3]))
}

/// An exit save and a timed auto-save can land at once from two threads.
@Test func concurrentResumeWritesLeaveOneWholeState() throws {
    let (store, _, _) = makeStore()
    DispatchQueue.concurrentPerform(iterations: 16) { i in
        try? store.saveResume(state: Data(repeating: UInt8(i), count: 4096), thumbnail: nil, key: "k")
    }
    let resume = try #require(store.load(.resume, key: "k"))
    let previous = try #require(store.load(.previous, key: "k"))
    #expect(resume.count == 4096 && Set(resume).count == 1)
    #expect(previous.count == 4096 && Set(previous).count == 1)
    #expect(resume != previous)
}

@Test func sourcesHaveMenuTitles() {
    #expect(StateSource.resume.title == "Resume")
    #expect(StateSource.previous.title == "Previous Resume")
    #expect(StateSource.slot(4).title == "Slot 4")
    #expect(StateSource.slots == 1...6)
}

@Test func menuTitlesNameTheTimeOrSayEmpty() {
    let calendar = Calendar.current
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 18))!
    let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 14, minute: 32))!
    let yesterday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 9, minute: 5))!
    let older = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 21))!
    func info(_ date: Date) -> SaveStateStore.Info { SaveStateStore.Info(savedAt: date, thumbnail: nil) }
    func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    #expect(StateSource.slot(2).menuTitle(info(today), now: now) == "Slot 2 · Today \(time(today))")
    #expect(StateSource.resume.menuTitle(info(yesterday), now: now) == "Resume · Yesterday \(time(yesterday))")
    #expect(StateSource.slot(5).menuTitle(info(older), now: now)
            == "Slot 5 · \(older.formatted(date: .abbreviated, time: .shortened))")
    #expect(StateSource.slot(3).menuTitle(nil) == "Slot 3 · Empty")
    #expect(StateSource.previous.menuTitle(nil) == "Previous Resume · Empty")
}

/// Midnight is the boundary, not 24 hours: a minute before it is yesterday.
@Test func savedAtCountsCalendarDays() {
    let calendar = Calendar.current
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 0, minute: 1))!
    let lateLastNight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 23, minute: 59))!
    let twoDaysAgo = calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 23, minute: 59))!
    #expect(StateSource.savedAt(lateLastNight, now: now).hasPrefix("Yesterday "))
    #expect(StateSource.savedAt(twoDaysAgo, now: now)
            == twoDaysAgo.formatted(date: .abbreviated, time: .shortened))
}
