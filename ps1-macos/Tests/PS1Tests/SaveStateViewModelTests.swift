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

/// A state `loadState` can read the header of. Nothing loads it: the session
/// is scripted.
private func makeState() throws -> Data {
    let core = try Ps1Core()
    try core.loadBIOS(Data(repeating: 0, count: 524288))
    return try core.saveState()
}

/// What a scripted save answers with: the view model only stores the bytes.
private let snapshot = ResumeSnapshot(state: Data([1, 2, 3]), thumbnail: nil)

/// A BIOS folder `load(disc:)` boots from, under bookmark keys of its own:
/// the hosted tests share the app's defaults, and the default keys hold the
/// player's real folder.
@MainActor private func makeBios() throws -> (BiosLibrary, cleanup: () -> Void) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vm-bios-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(repeating: 0, count: 524288).write(to: dir.appendingPathComponent("SCPH-1001.bin"))
    let key = "vm-bios-\(UUID().uuidString)"
    let bios = BiosLibrary(folderKey: key, explicitKey: key + ".explicit")
    try? bios.setFolder(dir)
    return (bios, {
        UserDefaults.standard.removeObject(forKey: key)
        try? FileManager.default.removeItem(at: dir)
    })
}

/// A disc `changeDisc` can read. The session is scripted, so the bytes are
/// never booted.
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
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: "k")
        let game = model.game!
        defer { model.ejectNowForTesting() }

        game.saveState(toSlot: 2)
        session.answerSave(.success(snapshot))
        #expect(await eventually { store.info(.slot(2), key: "k") != nil })
        #expect(store.info(.resume, key: "k") == nil)
        #expect(game.stateInfo(.slot(2)) != nil)
    }

    @Test func aSlotSaveAnsweredAfterTeardownShowsNoNotice() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
        model.installSessionForTesting(ScriptedSession(), resumeKey: "k")
        let game = model.game!
        game.saveState(toSlot: 3)
        model.ejectNowForTesting()        // free() answers the save with .sessionStopped
        try? await Task.sleep(for: .milliseconds(100))
        #expect(game.notice == nil)
        #expect(store.info(.slot(3), key: "k") == nil)
    }

    @Test func loadingASlotKeepsTheReplacedMachineForUndo() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
        let slot = try makeState()
        try store.saveSlot(1, state: slot, thumbnail: nil, key: "k")
        let before = Data([1, 2, 3])      // the live machine the load replaces
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: "k")
        let game = model.game!
        defer { model.ejectNowForTesting() }

        #expect(game.undoState == nil)
        game.loadState(.slot(1))
        #expect(session.pendingLoads == [slot])
        session.answerLoad(.success(before))
        #expect(await eventually { game.undoState != nil })
        #expect(game.notice?.text == "Loaded Slot 1")
        #expect(game.undoState == before)

        game.undoLoadState()
        #expect(session.pendingLoads == [before])
        session.answerLoad(.success(slot))
        #expect(await eventually { game.notice?.text == "Load undone" })
        #expect(game.undoState == slot)  // a second Undo returns to the loaded state
    }

    @Test func ejectingDropsTheUndoState() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
        try store.saveSlot(1, state: try makeState(), thumbnail: nil, key: "k")
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: "k")
        let game = model.game!
        game.loadState(.slot(1))
        session.answerLoad(.success(Data([1, 2, 3])))
        #expect(await eventually { game.undoState != nil })
        model.ejectNowForTesting()
        #expect(game.undoState == nil)
    }

    @Test func changingDiscDropsTheUndoState() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
        try store.saveSlot(1, state: try makeState(), thumbnail: nil, key: "k")
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: "k")
        let game = model.game!
        defer { model.ejectNowForTesting() }
        game.loadState(.slot(1))
        session.answerLoad(.success(Data([1, 2, 3])))
        #expect(await eventually { game.undoState != nil })

        game.changeDisc(to: try makeDisc())
        #expect(model.errorMessage == nil)
        #expect(game.undoState == nil)
    }

    /// Paused, a load and a swap can both wait for the emulator thread. The
    /// load's answer then holds the disc the swap is taking out.
    @Test func aLoadQueuedBeforeADiscSwapLeavesNoUndo() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
        try store.saveSlot(1, state: try makeState(), thumbnail: nil, key: "k")
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: "k")
        let game = model.game!
        defer { model.ejectNowForTesting() }

        game.loadState(.slot(1))
        game.changeDisc(to: try makeDisc())
        #expect(model.errorMessage == nil)
        session.answerLoad(.success(Data([1, 2, 3])))
        #expect(await eventually { game.notice?.text == "Loaded Slot 1" })
        #expect(game.undoState == nil)
    }

    @Test func aLoadAnsweredAfterTeardownIsIgnored() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
        try store.saveSlot(1, state: try makeState(), thumbnail: nil, key: "k")
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: "k")
        let game = model.game!
        game.loadState(.slot(1))
        model.ejectNowForTesting()        // free() answers the load with .sessionStopped
        session.answerLoad(.success(Data([1, 2, 3])))   // nothing left to answer
        try? await Task.sleep(for: .milliseconds(100))
        #expect(game.undoState == nil)
        #expect(game.notice == nil)
    }

    @Test func aDamagedSlotShowsWhyAndChangesNothing() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
        try store.saveSlot(4, state: Data([1, 2, 3]), thumbnail: nil, key: "k")
        model.installSessionForTesting(ScriptedSession(), resumeKey: "k")
        let game = model.game!
        defer { model.ejectNowForTesting() }

        game.loadState(.slot(4))
        #expect(game.notice == Notice(icon: NoticeIcon.failure, text: "The saved state is damaged."))
        #expect(game.undoState == nil)
    }

    @Test func aTimedAutoSaveWritesTheResumeOnceDue() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(5))
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: "k")
        let game = model.game!
        defer { model.ejectNowForTesting() }
        model.simulateAppActiveForTesting(true)
        game.isPaused = false            // starts the active-play count
        let now = ProcessInfo.processInfo.systemUptime

        game.autoSaveIfDue(at: now + 60)      // one minute in: not due
        session.answerSave(.success(snapshot))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(store.info(.resume, key: "k") == nil)

        game.autoSaveIfDue(at: now + 301)
        session.answerSave(.success(snapshot))
        #expect(await eventually { store.info(.resume, key: "k") != nil })
        #expect(store.saved(key: "k").map(\.source) == [.resume])
    }

    /// The pill is the whole point of the change: a timed auto-save used to
    /// be silent, and a player could not tell their resume had moved on.
    @Test func aTimedAutoSaveSaysSo() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(5))
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: "k")
        let game = model.game!
        defer { model.ejectNowForTesting() }
        model.simulateAppActiveForTesting(true)
        game.isPaused = false

        game.autoSaveIfDue(at: ProcessInfo.processInfo.systemUptime + 301)
        session.answerSave(.success(snapshot))
        #expect(await eventually {
            game.notice == Notice(icon: NoticeIcon.autoSaved, text: "Auto-saved")
        })
    }

    /// The outgoing game's auto-save is answered only after the next game is
    /// installed; until then it must not hold the next game's auto-save off.
    @Test func anAutoSaveInFlightAtEjectDoesNotBlockTheNextGame() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(5))
        model.simulateAppActiveForTesting(true)
        model.installSessionForTesting(ScriptedSession(), resumeKey: "a")
        model.game!.isPaused = false
        model.game!.autoSaveIfDue(at: ProcessInfo.processInfo.systemUptime + 301)
        model.ejectNowForTesting()        // its answer is still on its way

        let second = ScriptedSession()
        model.installSessionForTesting(second, resumeKey: "b")
        defer { model.ejectNowForTesting() }
        model.game!.isPaused = false
        model.game!.autoSaveIfDue(at: ProcessInfo.processInfo.systemUptime + 301)
        second.answerSave(.success(snapshot))
        #expect(await eventually { store.info(.resume, key: "b") != nil })
    }

    @Test func autoSaveWaitsWhileADialogIsUp() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(5))
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: "k")
        let game = model.game!
        defer { model.ejectNowForTesting() }
        model.simulateAppActiveForTesting(true)
        game.isPaused = false
        let disc = GameEntry(url: URL(fileURLWithPath: "/nonexistent/Game.cue"))
        model.resumeOffer = ResumeOffer(title: "Game", key: "k", launching: disc, first: disc, resumeDisc: disc,
                                        info: nil, others: [])
        let due = ProcessInfo.processInfo.systemUptime + 301

        game.autoSaveIfDue(at: due)
        session.answerSave(.success(snapshot))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(store.info(.resume, key: "k") == nil)

        model.resumeOffer = nil
        game.autoSaveIfDue(at: due)
        session.answerSave(.success(snapshot))
        #expect(await eventually { store.info(.resume, key: "k") != nil })
    }

    /// The load restarts the count at the moment it lands, which the sleep
    /// puts at least 0.2 s after counting began: 300.1 s from that start was
    /// due before the load and is not after it.
    @Test func aLoadRestartsTheAutoSaveCount() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(5))
        try store.saveSlot(1, state: try makeState(), thumbnail: nil, key: "k")
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: "k")
        let game = model.game!
        defer { model.ejectNowForTesting() }
        model.simulateAppActiveForTesting(true)
        game.isPaused = false
        let started = ProcessInfo.processInfo.systemUptime
        try? await Task.sleep(for: .milliseconds(200))

        game.loadState(.slot(1))
        session.answerLoad(.success(Data([1, 2, 3])))
        #expect(await eventually { game.undoState != nil })
        game.autoSaveIfDue(at: started + 300.1)
        session.answerSave(.success(snapshot))
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
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: "k")

        #expect(model.requestExit(.eject) == .prompted)
        model.confirmExit()
        session.answerSave(.success(snapshot))
        #expect(await eventually { model.stage == .library })
        #expect(store.info(.resume, key: "k") != nil)
    }

    @Test func autoSaveOffNeverWrites() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: "k")
        let game = model.game!
        defer { model.ejectNowForTesting() }
        model.simulateAppActiveForTesting(true)
        game.isPaused = false
        game.autoSaveIfDue(at: ProcessInfo.processInfo.systemUptime + 100_000)
        session.answerSave(.success(snapshot))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(store.info(.resume, key: "k") == nil)
    }

    /// The real session answers on the main queue a turn later, so a save
    /// taken just before an eject lands after it. That game is gone: its
    /// answer writes nothing and says nothing.
    @Test func aSaveAnsweredAfterEjectIsIgnored() async throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(5))
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: "k")
        let game = model.game!
        model.simulateAppActiveForTesting(true)
        game.isPaused = false

        game.autoSaveIfDue(at: ProcessInfo.processInfo.systemUptime + 301)
        let land = session.answerSaveLater(.success(snapshot))
        model.ejectNowForTesting()
        land()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(store.info(.resume, key: "k") == nil)
        #expect(game.notice == nil)
    }
}

/// Through the session, never the machine: the emulator thread may be
/// mid-frame, and under the recompiler the reset frees the code it runs.
@MainActor @Test func theViewModelsResetGoesThroughTheSession() {
    let model = EmulatorViewModel(saveStates: makeStore(), autoSave: makeAutoSave(0))
    let session = ScriptedSession()
    model.installSessionForTesting(session, resumeKey: nil)
    defer { model.ejectNowForTesting() }

    model.game!.reset()
    #expect(session.calls.contains("requestReset"))
    #expect(session.pendingResets == 1)
}

/// A resume state the session refuses is the launch's "Could not resume",
/// whose Start Fresh boots the disc it was offered on, with no game left
/// behind.
@MainActor @Test func aRefusedResumeShowsTheStateError() throws {
    let (bios, cleanup) = try makeBios()
    defer { cleanup() }
    let model = EmulatorViewModel(saveStates: makeStore(), autoSave: makeAutoSave(0), bios: bios)
    model.makeSession = { _ throws(Ps1Error) in throw .stateVersion }
    let disc = try makeDisc()

    model.load(disc: disc.url, resume: Data([1, 2, 3]))
    #expect(model.resumeFailure?.message == "This state was saved by a newer version of Substation.")
    #expect(model.resumeFailure?.freshBoot == DiscRef(url: disc.url))
    #expect(model.errorMessage == nil)
    #expect(model.game?.session == nil)
    #expect(model.stage != .playing)
}

/// The session starts with the player's settings in place: the config
/// carries them, and the two that are not settings are set before `start()`,
/// which would otherwise run the first frames without them.
@MainActor @Test func everySettingIsAppliedBeforeStart() throws {
    let (bios, cleanup) = try makeBios()
    defer { cleanup() }
    let model = EmulatorViewModel(saveStates: makeStore(), autoSave: makeAutoSave(0), bios: bios)
    let session = ScriptedSession()
    var config: SessionConfig?
    model.makeSession = { cfg throws(Ps1Error) in
        config = cfg
        return session
    }
    // A started game is marked played in the app's own stats, which the
    // hosted test shares: one fixed name keeps that to one entry.
    let disc = FileManager.default.temporaryDirectory.appendingPathComponent("vm-settings-disc.bin")
    try Data(repeating: 0, count: 2352).write(to: disc)

    model.load(disc: disc)
    defer { model.ejectNowForTesting() }
    #expect(model.errorMessage == nil)
    #expect(model.game?.session === session)
    let start = try #require(session.calls.firstIndex(of: "start()"))
    #expect(config?.settings.scale == model.internalScale)
    for setter in ["setSpeed", "setBandShown"] {
        let applied = session.calls.firstIndex { $0.hasPrefix(setter + "(") }
        #expect(applied.map { $0 < start } == true, "\(setter) before start()")
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
    model.resumeOffer = ResumeOffer(title: "Game", key: "k", launching: disc, first: disc, resumeDisc: disc,
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

/// A disc opened from outside the library asks in the floating panel in
/// either Open Games In mode, since Finder and Spotlight can launch the app
/// with no window to hold a sheet; a click in the library asks there.
/// Independent of the mode on purpose: the hosted test app shares the real
/// app's defaults, so the test cannot pick one without writing over it.
@MainActor @Test func anOutsideOpenAsksInThePanelAndALibraryClickDoesNot() throws {
    let store = makeStore()
    let disc = try makeDisc()
    try store.saveResume(state: Data([1]), thumbnail: nil, key: SaveStateStore.key(for: disc))
    let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))

    model.open(disc.url)
    #expect(model.resumeOffer != nil)
    #expect(model.resumeInPanel)

    model.chooseResume(.cancel)
    model.play(disc)
    #expect(model.resumeOffer != nil)
    #expect(!model.resumeInPanel)
}
