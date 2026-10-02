import Testing
import Foundation
import Synchronization
@testable import PS1

private func makeRunner() throws -> EmulatorRunner {
    let core = try Ps1Core()
    try core.loadBIOS(Data(repeating: 0, count: 524288))
    return EmulatorRunner(core: core, ring: AudioRing(capacity: EmulatorRunner.ringCapacity),
                          cards: MemoryCardStore(directory: FileManager.default.temporaryDirectory
                              .appendingPathComponent("save-\(UUID().uuidString)")))
}

@Test func aSaveRequestIsServicedWithAStateThatLoadsBack() throws {
    let runner = try makeRunner()
    let got = Mutex<Result<ResumeSnapshot, Error>?>(nil)
    runner.requestSaveState { result in got.withLock { $0 = result } }
    runner.serviceSaveRequest()

    let snapshot = try #require(got.withLock { $0 }).get()
    let other = try Ps1Core()
    try other.loadBIOS(Data(repeating: 0, count: 524288))
    try other.loadState(snapshot.state)
}

@Test func withNoRequestServicingDoesNothing() throws {
    let runner = try makeRunner()
    runner.serviceSaveRequest() // must not crash or call anything
}

@Test func aRequestIsAnsweredExactlyOnce() throws {
    let runner = try makeRunner()
    let calls = Mutex(0)
    runner.requestSaveState { _ in calls.withLock { $0 += 1 } }
    runner.serviceSaveRequest()
    runner.serviceSaveRequest()
    runner.stop()
    #expect(calls.withLock { $0 } == 1)
}

@Test func aRequestPendingWhenTheRunnerStopsIsAnsweredWithAFailure() throws {
    // Never dropped: whoever asked is waiting on this completion.
    let runner = try makeRunner()
    let got = Mutex<Result<ResumeSnapshot, Error>?>(nil)
    runner.requestSaveState { result in got.withLock { $0 = result } }
    runner.stop()
    let result = try #require(got.withLock { $0 })
    #expect(throws: SaveRequestError.runnerStopped) { try result.get() }
}
