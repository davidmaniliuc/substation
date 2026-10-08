import Testing
import Foundation
import Synchronization
@testable import PS1

private func makeMachine() throws -> (runner: EmulatorRunner, core: Ps1Core, cards: MemoryCardStore) {
    let core = try Ps1Core()
    try core.loadBIOS(Data(repeating: 0, count: 524288))
    let cards = MemoryCardStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("load-\(UUID().uuidString)"))
    let runner = EmulatorRunner(core: core, ring: AudioRing(capacity: EmulatorRunner.ringCapacity),
                                cards: cards)
    return (runner, core, cards)
}

@Test func aLoadAnswersWithTheMachineItReplaced() throws {
    let (runner, core, _) = try makeMachine()
    let saved = try core.saveState()
    let got = Mutex<Result<Data, Error>?>(nil)
    runner.requestLoadState(saved) { result in got.withLock { $0 = result } }
    runner.serviceLoadRequests()

    let undo = try #require(got.withLock { $0 }).get()
    let other = try Ps1Core()
    try other.loadBIOS(Data(repeating: 0, count: 524288))
    try other.loadState(undo)
}

@Test func aRefusedLoadLeavesTheMachineAsItWas() throws {
    let (runner, core, _) = try makeMachine()
    let before = try core.saveState()
    let got = Mutex<Result<Data, Error>?>(nil)
    runner.requestLoadState(Data("garbage".utf8)) { result in got.withLock { $0 = result } }
    runner.serviceLoadRequests()

    let result = try #require(got.withLock { $0 })
    #expect(throws: (any Error).self) { try result.get() }
    #expect(try core.saveState() == before)
}

/// A card write still waiting must reach disk before the load: the load
/// re-installs the cards from disk, and a stale file would undo the save.
@Test func aPendingCardWriteReachesDiskBeforeTheLoad() throws {
    let (runner, core, cards) = try makeMachine()
    let image = Data(repeating: 0x5A, count: MemoryCardStore.bytes)
    runner.pendingCards[0] = image
    runner.requestLoadState(try core.saveState()) { _ in }
    runner.serviceLoadRequests()
    #expect(cards.load(slot: 0) == image)
    #expect(runner.pendingCards.isEmpty)
}

@Test func aLoadPendingWhenTheRunnerStopsIsAnsweredWithAFailure() throws {
    let (runner, core, _) = try makeMachine()
    let got = Mutex<Result<Data, Error>?>(nil)
    runner.requestLoadState(try core.saveState()) { result in got.withLock { $0 = result } }
    runner.stop()
    let result = try #require(got.withLock { $0 })
    #expect(throws: SaveRequestError.runnerStopped) { try result.get() }
}
