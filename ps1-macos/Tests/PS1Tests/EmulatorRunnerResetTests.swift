import Testing
import Foundation
@testable import PS1

/// A core on a blank BIOS, kept by the test so it can read the machine back.
private func makeCore() throws -> Ps1Core {
    let core = try Ps1Core()
    try core.loadBIOS(Data(repeating: 0, count: 524288))
    return core
}

private func makeRunner(_ core: Ps1Core) -> EmulatorRunner {
    EmulatorRunner(core: core, ring: AudioRing(capacity: EmulatorRunner.ringCapacity), cards: nil)
}

/// The reset frees the machine a running frame is executing (under the
/// recompiler, its code buffer), so it must wait for the emulator thread to
/// take it between frames, never run on the caller's thread.
@Test func aResetRequestWaitsForTheEmulatorThread() throws {
    let core = try makeCore()
    let runner = makeRunner(core)
    core.runFrame()
    core.runFrame()
    let before = try core.saveState()

    runner.requestReset()
    #expect(try core.saveState() == before)

    runner.serviceResetRequest()
    #expect(try core.saveState() == (try makeCore().saveState()))
}

@Test func withNoResetRequestServicingDoesNothing() throws {
    let core = try makeCore()
    let runner = makeRunner(core)
    core.runFrame()
    let before = try core.saveState()
    runner.serviceResetRequest()
    #expect(try core.saveState() == before)
}

@MainActor
@Test func theViewModelsResetGoesThroughTheRunner() throws {
    let core = try makeCore()
    let runner = makeRunner(core)
    let model = EmulatorViewModel()
    model.installRunnerForTesting(runner, resumeKey: nil)
    core.runFrame()
    let before = try core.saveState()

    model.reset()
    #expect(try core.saveState() == before)
    runner.serviceResetRequest()
    #expect(try core.saveState() == (try makeCore().saveState()))
}
