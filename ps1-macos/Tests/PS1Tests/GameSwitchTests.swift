import Testing
import Foundation
@testable import PS1

/// The switch between two open games as a value type: which steps run, in
/// which order, and when a card write holds them back.
@Suite struct GameSwitchTests {
    let a = UUID(), b = UUID(), c = UUID()

    @Test func aSwitchBackgroundsFlushesReinstallsThenForegroundsInOrder() {
        var s = GameSwitch(running: a)
        #expect(s.request(to: b, outgoingSaving: false)
                == [.background(a), .flushCards(a), .reinstallCards(b), .foreground(b)])
        #expect(s.running == b)
    }

    @Test func aSwitchWhileSavingWaitsForTheBurstToSettle() {
        var s = GameSwitch(running: a)
        #expect(s.request(to: b, outgoingSaving: true) == [.background(a)])
        #expect(s.outgoingSettled() == [.flushCards(a), .reinstallCards(b), .foreground(b)])
        #expect(s.outgoingSettled() == [])
    }

    @Test func aSecondRequestWhileDeferredReplacesTheIncomingGame() {
        var s = GameSwitch(running: a)
        _ = s.request(to: b, outgoingSaving: true)
        #expect(s.request(to: c, outgoingSaving: false) == [])
        let steps = s.outgoingSettled()
        #expect(steps == [.flushCards(a), .reinstallCards(c), .foreground(c)])
        #expect(!steps.contains(.foreground(b)))
    }

    @Test func comingBackToTheSavingGameJustResumesIt() {
        var s = GameSwitch(running: a)
        _ = s.request(to: b, outgoingSaving: true)
        #expect(s.request(to: a, outgoingSaving: true) == [.foreground(a)])
        #expect(s.outgoingSettled() == [])
        #expect(s.running == a)
    }

    @Test func switchingToTheRunningGameDoesNothing() {
        var s = GameSwitch(running: a)
        #expect(s.request(to: a, outgoingSaving: false) == [])
    }

    /// The running game closed: the next one to come forward still reads
    /// the cards again, since others may have written them.
    @Test func withNothingRunningTheIncomingGameReinstallsThenRuns() {
        var s = GameSwitch(running: nil)
        #expect(s.request(to: b, outgoingSaving: false) == [.reinstallCards(b), .foreground(b)])
    }

    @Test func removingTheRunningGameLeavesNothingRunning() {
        var s = GameSwitch(running: a)
        #expect(s.removed(a) == [])
        #expect(s.running == nil)
    }

    /// A closed outgoing game wrote its cards as its session stopped.
    @Test func removingTheSavingOutgoingGameLetsTheIncomingOneIn() {
        var s = GameSwitch(running: a)
        _ = s.request(to: b, outgoingSaving: true)
        #expect(s.removed(a) == [.reinstallCards(b), .foreground(b)])
    }

    @Test func removingTheWaitingIncomingGameCancelsTheSwitch() {
        var s = GameSwitch(running: a)
        _ = s.request(to: b, outgoingSaving: true)
        #expect(s.removed(b) == [])
        #expect(s.outgoingSettled() == [])
        #expect(s.running == nil)
    }
}

/// Several open games through the model, with scripted sessions: only the
/// front one runs, and the cards are handed over on every switch.
@MainActor
@Suite struct OpenGamesTests {
    /// The last `setPaused` a session was sent.
    private func lastPause(_ s: ScriptedSession) -> String? {
        s.calls.last { $0.hasPrefix("setPaused") }
    }

    /// A running in its own window, then B opened beside it with the
    /// hand-over answered, so B runs.
    private func twoGames() -> (EmulatorViewModel, ScriptedSession, ScriptedSession, OpenGame, OpenGame) {
        let model = EmulatorViewModel()
        let a = ScriptedSession(), b = ScriptedSession()
        model.installSessionForTesting(a, resumeKey: nil, ownWindow: true)
        let ga = model.game!
        model.installSessionForTesting(b, resumeKey: nil, ownWindow: true)
        let gb = model.games.last!
        a.answerFlushCards(nil)
        b.answerReinstallCards(nil)
        return (model, a, b, ga, gb)
    }

    @Test func theHandOverWaitsForTheFlushAnswer() {
        let model = EmulatorViewModel()
        let a = ScriptedSession(), b = ScriptedSession()
        model.installSessionForTesting(a, resumeKey: nil, ownWindow: true)
        model.installSessionForTesting(b, resumeKey: nil, ownWindow: true)
        defer { model.ejectAllForTesting() }
        #expect(lastPause(a) == "setPaused(true)")
        #expect(a.pendingFlushCards == 1)
        #expect(!b.calls.contains("requestReinstallCards"))
        #expect(lastPause(b) == "setPaused(true)")

        a.answerFlushCards(nil)
        #expect(b.pendingReinstallCards == 1)
        #expect(lastPause(b) == "setPaused(true)")

        b.answerReinstallCards(nil)
        #expect(lastPause(b) == "setPaused(false)")
        #expect(model.game === model.games.last)
    }

    @Test func aPlayerPauseSurvivesABackgroundRoundTrip() {
        let model = EmulatorViewModel()
        let a = ScriptedSession(), b = ScriptedSession()
        model.installSessionForTesting(a, resumeKey: nil, ownWindow: true)
        let ga = model.game!
        defer { model.ejectAllForTesting() }
        ga.isPaused = true
        model.installSessionForTesting(b, resumeKey: nil, ownWindow: true)
        let gb = model.games.last!
        a.answerFlushCards(nil)
        b.answerReinstallCards(nil)

        model.gameWindowBecameKey(ga.id)
        #expect(lastPause(b) == "setPaused(true)")
        b.answerFlushCards(nil)
        a.answerReinstallCards(nil)
        #expect(model.game === ga)
        #expect(lastPause(a) == "setPaused(true)")
        #expect(ga.isPaused)
        #expect(!gb.isPaused)
    }

    @Test func aBackgroundPauseNeverOverwritesThePlayers() {
        let (model, a, b, ga, _) = twoGames()
        defer { model.ejectAllForTesting() }
        #expect(lastPause(a) == "setPaused(true)")
        #expect(!ga.isPaused)

        model.gameWindowBecameKey(ga.id)
        b.answerFlushCards(nil)
        a.answerReinstallCards(nil)
        #expect(lastPause(a) == "setPaused(false)")
    }

    @Test func closingTheRunningGameResumesNothing() {
        let (model, a, _, ga, gb) = twoGames()
        defer { model.ejectAllForTesting() }
        let before = a.calls.count
        model.ejectNowForTesting(gb)
        #expect(model.game == nil)
        #expect(model.games.map(\.id) == [ga.id])
        #expect(!a.calls.dropFirst(before).contains("setPaused(false)"))
        #expect(model.stage == .playing)
    }

    @Test func aSwitchReleasesTheOutgoingGamesKeys() {
        let model = EmulatorViewModel()
        let a = ScriptedSession(), b = ScriptedSession()
        model.installSessionForTesting(a, resumeKey: nil, ownWindow: true)
        let ga = model.game!
        defer { model.ejectAllForTesting() }
        _ = model.keyDown(126)   // up
        #expect(ga.inputMaskForTesting & PadButton.up.rawValue == 0)

        model.installSessionForTesting(b, resumeKey: nil, ownWindow: true)
        #expect(ga.inputMaskForTesting == 0xFFFF)
        #expect(a.calls.last { $0.hasPrefix("setButtons") } == "setButtons(65535)")
        a.answerFlushCards(nil)
        b.answerReinstallCards(nil)

        let aCalls = a.calls.count
        _ = model.keyDown(126)
        #expect(a.calls.count == aCalls)
        #expect(model.games.last!.inputMaskForTesting & PadButton.up.rawValue == 0)
    }

    @Test func openingAnOpenGameBringsItsWindowForward() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let discs = ["Game (Disc 1).cue", "Game (Disc 2).cue"].map { name in
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            return GameEntry(url: url, identity: .unknown)
        }
        let model = EmulatorViewModel()
        var made = 0
        model.makeSession = { _ throws(Ps1Error) in made += 1; return ScriptedSession() }
        model.installSessionForTesting(ScriptedSession(), resumeKey: nil, ownWindow: true)
        let game = model.game!
        defer { model.ejectAllForTesting() }
        model.simulateDiscsForTesting(discs, inserted: 0, bios: nil)

        model.launch(discs[1].url)
        #expect(made == 0)
        #expect(model.resumeOffer == nil)
        #expect(model.games.count == 1)
        #expect(model.windowRequest?.content == .game(game.id))
    }

    @Test func inLibraryWindowModeALoadReplacesOnlyTheLibraryGame() {
        let model = EmulatorViewModel()
        let own = ScriptedSession(), first = ScriptedSession(), second = ScriptedSession()
        model.installSessionForTesting(own, resumeKey: nil, ownWindow: true)
        model.installSessionForTesting(first, resumeKey: nil)
        own.answerFlushCards(nil)
        first.answerReinstallCards(nil)
        defer { model.ejectAllForTesting() }

        model.installSessionForTesting(second, resumeKey: nil)
        #expect(first.freed)
        #expect(!own.freed)
        #expect(model.games.count == 2)
        #expect(model.libraryGame?.session === second)
    }

    /// In New Window mode a disc opens beside the running game: nothing is
    /// left, so nothing is asked.
    @Test func inNewWindowModeOpeningADiscAsksNothing() {
        var setting = libraryWindowMode()
        setting.set(.newWindow)
        let model = EmulatorViewModel(saveStates: SaveStateStore(), autoSave: AutoSaveSetting(),
                                      gameWindow: setting)
        model.installSessionForTesting(ScriptedSession(), resumeKey: nil, ownWindow: true)
        defer { model.ejectAllForTesting() }
        #expect(model.requestExit(.open(URL(fileURLWithPath: "/nonexistent.cue"))) == .proceed)
        #expect(model.exitPrompt == nil)
    }
}

/// Awaits the saving badge's timer, so it runs with the other live games:
/// a parallel test's `willTerminateNotification` tears down every model.
extension LiveGameTests {
    @Test func aSwitchWhileTheOutgoingGameSavesWaitsForTheWrite() async {
        let model = EmulatorViewModel()
        let a = ScriptedSession(), b = ScriptedSession()
        model.installSessionForTesting(a, resumeKey: nil, ownWindow: true)
        let ga = model.game!
        defer { model.ejectAllForTesting() }
        a.emit(.cardWrites(1))
        #expect(ga.savingToMemoryCard)

        model.installSessionForTesting(b, resumeKey: nil, ownWindow: true)
        #expect(a.calls.last { $0.hasPrefix("setPaused") } == "setPaused(true)")
        #expect(a.pendingFlushCards == 0)

        await ga.cardSavingTaskForTesting?.value
        #expect(a.pendingFlushCards == 1)
        a.answerFlushCards(nil)
        b.answerReinstallCards(nil)
        #expect(b.calls.last { $0.hasPrefix("setPaused") } == "setPaused(false)")
    }
}

/// Quit asks about every open game, one sheet at a time.
extension LiveGameTests {
    /// Two games in their own windows, B running, the hand-over answered.
    private func twoOpenGames() -> (EmulatorViewModel, ScriptedSession, ScriptedSession, OpenGame, OpenGame) {
        let model = EmulatorViewModel()
        let a = ScriptedSession(), b = ScriptedSession()
        model.installSessionForTesting(a, resumeKey: nil, ownWindow: true)
        let ga = model.game!
        model.installSessionForTesting(b, resumeKey: nil, ownWindow: true)
        a.answerFlushCards(nil)
        b.answerReinstallCards(nil)
        return (model, a, b, ga, model.game!)
    }

    private func settled(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func quitAsksEveryOpenGameInTurn() async {
        let (model, a, b, ga, gb) = twoOpenGames()
        defer { model.ejectAllForTesting() }
        var replied: Bool?
        model.terminateReply = { replied = $0 }

        #expect(model.requestExit(.quit) == .prompted)
        #expect(gb.exitPrompt == .quit)
        #expect(ga.exitPrompt == nil)
        model.confirmExit()
        b.answerSave(.failure(.sessionStopped))
        #expect(await settled { ga.exitPrompt == .quit })
        #expect(model.game(with: gb.id) == nil)
        #expect(replied == nil)

        model.confirmExit()
        a.answerSave(.failure(.sessionStopped))
        #expect(await settled { replied == true })
    }

    @Test func cancelOnTheSecondQuitSheetKeepsTheRest() async {
        let (model, a, b, ga, gb) = twoOpenGames()
        defer { model.ejectAllForTesting() }
        var replied: Bool?
        model.terminateReply = { replied = $0 }
        _ = a

        #expect(model.requestExit(.quit) == .prompted)
        model.confirmExit()
        b.answerSave(.failure(.sessionStopped))
        #expect(await settled { ga.exitPrompt == .quit })

        model.cancelExit()
        #expect(replied == false)
        #expect(model.game(with: gb.id) == nil)
        #expect(model.game(with: ga.id) != nil)
        #expect(ga.exitPrompt == nil)
        #expect(!ga.isPaused)
        #expect(model.requestExit(.eject, for: ga) == .prompted)
    }
}
