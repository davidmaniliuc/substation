import Testing
import Foundation
@testable import PS1

private func makeStore() -> SaveStateStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vm-states-\(UUID().uuidString)")
    return SaveStateStore(resumeDirectory: root.appendingPathComponent("resume"),
                          slotsDirectory: root.appendingPathComponent("slots"))
}

private func makeAutoSave(_ minutes: Int) -> AutoSaveSetting {
    var setting = AutoSaveSetting(key: "k", defaults: UserDefaults(suiteName: "vm-\(UUID().uuidString)")!)
    setting.set(minutes)
    return setting
}

private func makeMachine() throws -> (runner: EmulatorRunner, core: Ps1Core) {
    let core = try Ps1Core()
    try core.loadBIOS(Data(repeating: 0, count: 524288))
    let runner = EmulatorRunner(core: core, ring: AudioRing(capacity: EmulatorRunner.ringCapacity),
                                cards: MemoryCardStore(directory: FileManager.default.temporaryDirectory
                                    .appendingPathComponent("vm-cards-\(UUID().uuidString)")))
    return (runner, core)
}

/// Completions hop to the main actor; give them a bounded chance to land.
@MainActor private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Every test that holds a live game across an `await`, and the one test
/// that posts `willTerminateNotification`. That post tears down EVERY live
/// model in the process, so run in parallel it would land inside these and
/// eject their game mid-test. Serialized together, it cannot.
@Suite(.serialized) @MainActor struct LiveGameTests {}

extension LiveGameTests {
    @Test func savingToASlotWritesThatSlotAndNothingElse() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
        let (runner, _) = try makeMachine()
        model.installRunnerForTesting(runner, resumeKey: "k")
        defer { model.ejectNowForTesting() }

        model.saveState(toSlot: 2)
        runner.serviceSaveRequest()
        #expect(await eventually { store.info(.slot(2), key: "k") != nil })
        #expect(store.info(.resume, key: "k") == nil)
        #expect(model.stateInfo(.slot(2)) != nil)
    }

    @Test func aSlotSaveAnsweredAfterTeardownShowsNoNotice() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
        let (runner, _) = try makeMachine()
        model.installRunnerForTesting(runner, resumeKey: "k")
        model.saveState(toSlot: 3)
        model.ejectNowForTesting()        // stop() answers the save with .runnerStopped
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.notice == nil)
        #expect(store.info(.slot(3), key: "k") == nil)
    }

    @Test func loadingASlotKeepsTheReplacedMachineForUndo() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
        let (runner, core) = try makeMachine()
        let slot = try core.saveState()
        try store.saveSlot(1, state: slot, thumbnail: nil, key: "k")
        core.runFrame()                   // the live machine moves on from the slot
        let before = try core.saveState()
        model.installRunnerForTesting(runner, resumeKey: "k")
        defer { model.ejectNowForTesting() }

        #expect(model.undoState == nil)
        model.loadState(.slot(1))
        runner.serviceLoadRequests()
        #expect(await eventually { model.undoState != nil })
        #expect(model.notice == "Loaded Slot 1")
        #expect(model.undoState == before)

        model.undoLoadState()
        runner.serviceLoadRequests()
        #expect(await eventually { model.notice == "Load undone" })
        #expect(try core.saveState() == before)
        #expect(model.undoState == slot)  // a second Undo returns to the loaded state
    }

    @Test func ejectingDropsTheUndoState() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
        let (runner, core) = try makeMachine()
        try store.saveSlot(1, state: try core.saveState(), thumbnail: nil, key: "k")
        model.installRunnerForTesting(runner, resumeKey: "k")
        model.loadState(.slot(1))
        runner.serviceLoadRequests()
        #expect(await eventually { model.undoState != nil })
        model.ejectNowForTesting()
        #expect(model.undoState == nil)
    }

    @Test func aLoadAnsweredAfterTeardownIsIgnored() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
        let (runner, core) = try makeMachine()
        try store.saveSlot(1, state: try core.saveState(), thumbnail: nil, key: "k")
        model.installRunnerForTesting(runner, resumeKey: "k")
        model.loadState(.slot(1))
        model.ejectNowForTesting()        // stop() answers the load with .runnerStopped
        runner.serviceLoadRequests()      // nothing left to service
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.undoState == nil)
        #expect(model.notice == nil)
    }

    @Test func aDamagedSlotShowsWhyAndChangesNothing() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
        let (runner, _) = try makeMachine()
        try store.saveSlot(4, state: Data([1, 2, 3]), thumbnail: nil, key: "k")
        model.installRunnerForTesting(runner, resumeKey: "k")
        defer { model.ejectNowForTesting() }

        model.loadState(.slot(4))
        #expect(model.notice == "The saved state is damaged.")
        #expect(model.undoState == nil)
    }

    @Test func aTimedAutoSaveWritesTheResumeOnceDue() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(5))
        let (runner, _) = try makeMachine()
        model.installRunnerForTesting(runner, resumeKey: "k")
        defer { model.ejectNowForTesting() }
        model.simulateAppActiveForTesting(true)
        model.isPaused = false            // starts the active-play count
        let now = ProcessInfo.processInfo.systemUptime

        model.autoSaveIfDue(at: now + 60)      // one minute in: not due
        runner.serviceSaveRequest()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(store.info(.resume, key: "k") == nil)

        model.autoSaveIfDue(at: now + 301)
        runner.serviceSaveRequest()
        #expect(await eventually { store.info(.resume, key: "k") != nil })
        #expect(store.saved(key: "k").map(\.source) == [.resume])
    }

    /// The outgoing game's auto-save is answered only after the next game is
    /// installed; until then it must not hold the next game's auto-save off.
    @Test func anAutoSaveInFlightAtEjectDoesNotBlockTheNextGame() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(5))
        model.simulateAppActiveForTesting(true)
        let (first, _) = try makeMachine()
        model.installRunnerForTesting(first, resumeKey: "a")
        model.isPaused = false
        model.autoSaveIfDue(at: ProcessInfo.processInfo.systemUptime + 301)
        model.ejectNowForTesting()        // its answer is still on its way

        let (second, _) = try makeMachine()
        model.installRunnerForTesting(second, resumeKey: "b")
        defer { model.ejectNowForTesting() }
        model.isPaused = false
        model.autoSaveIfDue(at: ProcessInfo.processInfo.systemUptime + 301)
        second.serviceSaveRequest()
        #expect(await eventually { store.info(.resume, key: "b") != nil })
    }

    @Test func autoSaveOffNeverWrites() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
        let (runner, _) = try makeMachine()
        model.installRunnerForTesting(runner, resumeKey: "k")
        defer { model.ejectNowForTesting() }
        model.simulateAppActiveForTesting(true)
        model.isPaused = false
        model.autoSaveIfDue(at: ProcessInfo.processInfo.systemUptime + 100_000)
        runner.serviceSaveRequest()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(store.info(.resume, key: "k") == nil)
    }
}
