import Testing
import Foundation
@testable import PS1

private func makeStore() -> SaveStateStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vm-states-\(UUID().uuidString)")
    return SaveStateStore(resumeDirectory: root.appendingPathComponent("resume"),
                          slotsDirectory: root.appendingPathComponent("slots"))
}

/// The setting keeps its value in memory, so its suite can go at once.
private func makeAutoSave(_ minutes: Int) -> AutoSaveSetting {
    let name = "vm-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    var setting = AutoSaveSetting(key: "k", defaults: defaults)
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

/// A disc `changeDisc` can read. The runner never services the swap, so
/// the bytes are never booted.
private func makeDisc() throws -> GameEntry {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vm-disc-\(UUID().uuidString).bin")
    try Data(repeating: 0, count: 2352).write(to: url)
    return GameEntry(url: url)
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
        #expect(model.notice?.text == "Loaded Slot 1")
        #expect(model.undoState == before)

        model.undoLoadState()
        runner.serviceLoadRequests()
        #expect(await eventually { model.notice?.text == "Load undone" })
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

    @Test func changingDiscDropsTheUndoState() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
        let (runner, core) = try makeMachine()
        try store.saveSlot(1, state: try core.saveState(), thumbnail: nil, key: "k")
        model.installRunnerForTesting(runner, resumeKey: "k")
        defer { model.ejectNowForTesting() }
        model.loadState(.slot(1))
        runner.serviceLoadRequests()
        #expect(await eventually { model.undoState != nil })

        model.changeDisc(to: try makeDisc())
        #expect(model.errorMessage == nil)
        #expect(model.undoState == nil)
    }

    /// Paused, a load and a swap can both wait for the emulator thread. The
    /// load's answer then holds the disc the swap is taking out.
    @Test func aLoadQueuedBeforeADiscSwapLeavesNoUndo() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
        let (runner, core) = try makeMachine()
        try store.saveSlot(1, state: try core.saveState(), thumbnail: nil, key: "k")
        model.installRunnerForTesting(runner, resumeKey: "k")
        defer { model.ejectNowForTesting() }

        model.loadState(.slot(1))
        model.changeDisc(to: try makeDisc())
        #expect(model.errorMessage == nil)
        runner.serviceLoadRequests()
        #expect(await eventually { model.notice?.text == "Loaded Slot 1" })
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
        #expect(model.notice == Notice(icon: NoticeIcon.failure, text: "The saved state is damaged."))
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

    /// The pill is the whole point of the change: a timed auto-save used to
    /// be silent, and a player could not tell their resume had moved on.
    @Test func aTimedAutoSaveSaysSo() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(5))
        let (runner, _) = try makeMachine()
        model.installRunnerForTesting(runner, resumeKey: "k")
        defer { model.ejectNowForTesting() }
        model.simulateAppActiveForTesting(true)
        model.isPaused = false

        model.autoSaveIfDue(at: ProcessInfo.processInfo.systemUptime + 301)
        runner.serviceSaveRequest()
        #expect(await eventually {
            model.notice == Notice(icon: NoticeIcon.autoSaved, text: "Auto-saved")
        })
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

    @Test func autoSaveWaitsWhileADialogIsUp() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(5))
        let (runner, _) = try makeMachine()
        model.installRunnerForTesting(runner, resumeKey: "k")
        defer { model.ejectNowForTesting() }
        model.simulateAppActiveForTesting(true)
        model.isPaused = false
        let disc = GameEntry(url: URL(fileURLWithPath: "/nonexistent/Game.cue"))
        model.resumeOffer = ResumeOffer(title: "Game", key: "k", launching: disc, resumeDisc: disc,
                                        info: nil, others: [])
        let due = ProcessInfo.processInfo.systemUptime + 301

        model.autoSaveIfDue(at: due)
        runner.serviceSaveRequest()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(store.info(.resume, key: "k") == nil)

        model.resumeOffer = nil
        model.autoSaveIfDue(at: due)
        runner.serviceSaveRequest()
        #expect(await eventually { store.info(.resume, key: "k") != nil })
    }

    /// The load restarts the count at the moment it lands, which the sleep
    /// puts at least 0.2 s after counting began: 300.1 s from that start was
    /// due before the load and is not after it.
    @Test func aLoadRestartsTheAutoSaveCount() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(5))
        let (runner, core) = try makeMachine()
        try store.saveSlot(1, state: try core.saveState(), thumbnail: nil, key: "k")
        model.installRunnerForTesting(runner, resumeKey: "k")
        defer { model.ejectNowForTesting() }
        model.simulateAppActiveForTesting(true)
        model.isPaused = false
        let started = ProcessInfo.processInfo.systemUptime
        try? await Task.sleep(for: .milliseconds(200))

        model.loadState(.slot(1))
        runner.serviceLoadRequests()
        #expect(await eventually { model.undoState != nil })
        model.autoSaveIfDue(at: started + 300.1)
        runner.serviceSaveRequest()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(store.info(.resume, key: "k") == nil)
    }

    /// The write runs off the main actor, and the exit still waits for it:
    /// the resume is on disk by the time the game is gone.
    @Test func anExitSaveIsWrittenBeforeTheExitFinishes() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
        let was = model.saveStateOnExit
        defer { model.saveStateOnExit = was }
        model.saveStateOnExit = true
        let (runner, _) = try makeMachine()
        model.installRunnerForTesting(runner, resumeKey: "k")

        #expect(model.requestExit(.eject) == .prompted)
        model.confirmExit()
        runner.serviceSaveRequest()
        #expect(await eventually { model.stage == .library })
        #expect(store.info(.resume, key: "k") != nil)
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

/// A delete from the launch sheet removes that one state and keeps the sheet
/// up, even with nothing left: Start Fresh is then the only way forward, and
/// a delete never boots a game by itself.
@MainActor @Test func deletingFromTheSheetKeepsItUp() throws {
    let store = makeStore()
    try store.saveResume(state: Data([1]), thumbnail: nil, key: "k")
    try store.saveSlot(2, state: Data([2]), thumbnail: nil, key: "k")
    let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
    let disc = GameEntry(url: URL(fileURLWithPath: "/nonexistent/Game.cue"))
    model.resumeOffer = ResumeOffer(title: "Game", key: "k", launching: disc, resumeDisc: disc,
                                    info: store.info(.resume, key: "k"),
                                    others: store.saved(key: "k").filter { $0.source != .resume })

    model.deleteOfferedState(.resume)
    #expect(store.info(.resume, key: "k") == nil)
    #expect(store.info(.slot(2), key: "k") != nil)
    #expect(model.resumeOffer?.states.map(\.source) == [.slot(2)])

    model.deleteOfferedState(.slot(2))
    #expect(store.saved(key: "k").isEmpty)
    #expect(model.resumeOffer?.states.isEmpty == true)
    #expect(model.stage != .playing)
}
