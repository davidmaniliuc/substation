import AppKit
import Testing
import Foundation
@testable import PS1

/// `EmulatorViewModel.init()` reads real bookmarks from UserDefaults, so the
/// stage it launches into varies by whichever machine runs the suite. Every
/// test here drives the model to a known stage itself (via `eject()`, which
/// is unconditional), rather than asserting on whatever it started in.
@MainActor
@Test func ejectReturnsToLibraryAndArrowKeysReachTheGrid() {
    let model = EmulatorViewModel()
    model.eject()
    #expect(model.stage == .library)

    // The up-arrow is the D-pad's up button; keyDown must decline it so the
    // event falls through to the grid's own scrolling instead of being
    // consumed as game input.
    #expect(model.keyDown(126) == false)
}

/// Pins the fix for the phantom-held-button regression: the stage gate on
/// `keyUp` means a release made after `eject()` never reaches `input`, so
/// without an explicit reset a key held into an eject stayed latched and was
/// re-transmitted as a stuck button on the very next game.
@MainActor
@Test func ejectClearsAKeyHeldAcrossIt() {
    let model = EmulatorViewModel()

    model.simulatePlayingForTesting()
    let game = model.game!
    #expect(model.keyDown(126) == true)
    #expect(game.inputMaskForTesting & PadButton.up.rawValue == 0)   // held

    model.eject()
    #expect(game.inputMaskForTesting == 0xFFFF)   // idle, not just "released"
    // A release after the eject reaches no game.
    #expect(model.keyUp(126) == false)

    // The next game's first setButtons call must not inherit the old bit.
    model.simulatePlayingForTesting()
    #expect(model.game!.inputMaskForTesting == 0xFFFF)
}

/// The gamepad half of the same fix: `bind(_:)`'s `valueChangedHandler` has
/// no stage gate of its own, unlike `keyDown`/`keyUp`, so a pad button held
/// across an eject would otherwise survive it; the next report of the still-
/// held button (which a real controller keeps sending on every poll) would
/// overwrite `input` again before the next game even starts. A real
/// `GCExtendedGamepad` can't be synthesised here, so this drives
/// `applyPadInput` through `simulatePadInputForTesting`, the same method the
/// real handler calls: reverting the stage gate on `applyPadInput` makes
/// this fail exactly as `ejectClearsAKeyHeldAcrossIt` would for the keyboard.
@MainActor
@Test func ejectClearsAPadButtonHeldAcrossIt() {
    let model = EmulatorViewModel()
    var heldUp = InputMap()
    heldUp.press(.up)

    model.simulatePlayingForTesting()
    let game = model.game!
    model.simulatePadInputForTesting(heldUp)
    #expect(game.inputMaskForTesting & PadButton.up.rawValue == 0)   // held

    model.eject()
    #expect(game.inputMaskForTesting == 0xFFFF)   // idle, not just "released"

    // The pad is still physically held: its next report arrives after the
    // eject and must be dropped, not published into `input`.
    model.simulatePadInputForTesting(heldUp)
    #expect(game.inputMaskForTesting == 0xFFFF)

    // The next game's first setButtons call must not inherit the old bit.
    model.simulatePlayingForTesting()
    #expect(model.game!.inputMaskForTesting == 0xFFFF)
}

/// The entire ⌘Q path: `EmulatorViewModel.init()` registers its teardown
/// against `willTerminateNotification` with `queue: nil`, which is documented
/// to run the block SYNCHRONOUSLY on the posting thread; the guarantee that
/// makes a save reach disk before the process actually exits. Until this test
/// nothing drove that path at all. A real session needs a BIOS
/// and a disc, which this suite deliberately does not depend on, so this
/// observes teardown through its other, always-available effect: it resets
/// `input`, which a held key would otherwise leave latched.
extension LiveGameTests {
    @Test func willTerminateNotificationRunsTeardownSynchronously() {
        let model = EmulatorViewModel()
        model.simulatePlayingForTesting()
        let game = model.game!
        #expect(model.keyDown(126) == true)   // up arrow
        #expect(game.inputMaskForTesting & PadButton.up.rawValue == 0)   // held

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

        // If the observer had been registered with a non-nil queue and that queue
        // ever enqueued instead of running inline, this would still be the
        // pre-teardown value immediately after `post` returns.
        #expect(game.inputMaskForTesting == 0xFFFF)
        #expect(model.game == nil)
    }
}

/// Change Disc derives its list from the running disc's own DIRECTORY, not
/// from the library tile that was clicked, so it also works for a game opened
/// through File > Open Disc... that was never in the library folder.
@MainActor
@Test func siblingDiscsAreFoundFromTheDiscsOwnDirectory() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("changedisc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    for n in 1...3 {
        try Data().write(to: dir.appendingPathComponent("Game (Disc \(n)).cue"))
    }
    // A different game in the same folder must not join the list.
    try Data().write(to: dir.appendingPathComponent("Other.cue"))

    let siblings = EmulatorViewModel.siblingDiscs(
        of: dir.appendingPathComponent("Game (Disc 2).cue"))

    #expect(siblings.count == 3)
    #expect(siblings.map(\.title) == [
        "Game (Disc 1)", "Game (Disc 2)", "Game (Disc 3)",
    ])
}

@MainActor
@Test func aSingleDiscGameHasNoSiblingsToSwapTo() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("changedisc-solo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let cue = dir.appendingPathComponent("Croc.cue")
    try Data().write(to: cue)

    // One entry, not zero: the menu is disabled on a count of 1, and an empty
    // list would make "which disc am I on" unanswerable.
    #expect(EmulatorViewModel.siblingDiscs(of: cue).map(\.title) == ["Croc"])
}

/// The Final Fantasy VII layout: one folder per disc under a parent named for
/// the game. Scanning the disc's OWN folder finds one disc and Change Disc
/// would have nothing to offer, so the scan has to start at the scope.
@MainActor
@Test func siblingDiscsSpanPerDiscSubfolders() throws {
    let game = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ff7-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: game) }

    for n in 1...3 {
        let discDir = game.appendingPathComponent("Game (Disc \(n))")
        try FileManager.default.createDirectory(at: discDir, withIntermediateDirectories: true)
        try Data().write(to: discDir.appendingPathComponent("Game (Disc \(n)).cue"))
    }

    let siblings = EmulatorViewModel.siblingDiscs(
        of: game.appendingPathComponent("Game (Disc 2)/Game (Disc 2).cue"))

    #expect(siblings.count == 3)
    #expect(siblings.map(\.title) == ["Game (Disc 1)", "Game (Disc 2)", "Game (Disc 3)"])
}

/// Tab is fast-forward, not a pad button: held, it runs the game at the turbo
/// speed; released, at the base speed again. Only the session flag is
/// asserted: `speed` itself persists to the real defaults.
@MainActor
@Test func holdingTabFastForwardsAndReleasingItStops() {
    let model = EmulatorViewModel()
    model.simulatePlayingForTesting()
    let game = model.game!

    #expect(model.keyDown(EmulatorViewModel.fastForwardKey) == true)
    #expect(model.isFastForwarding)
    #expect(model.effectiveSpeed == model.fastForwardSpeed)
    // The pad never sees it.
    #expect(game.inputMaskForTesting == 0xFFFF)

    #expect(model.keyUp(EmulatorViewModel.fastForwardKey) == true)
    #expect(!model.isFastForwarding)
    #expect(model.effectiveSpeed == model.speed)
    model.eject()
}

/// The fast-forward twin of `ejectClearsAKeyHeldAcrossIt`: a Tab held into an
/// eject would never deliver its release, and the next game would start
/// fast-forwarding with nothing held.
@MainActor
@Test func ejectReleasesAFastForwardHeldAcrossIt() {
    let model = EmulatorViewModel()
    model.simulatePlayingForTesting()
    _ = model.keyDown(EmulatorViewModel.fastForwardKey)

    model.eject()
    #expect(!model.isFastForwarding)
    // And outside a game Tab is left to the grid.
    #expect(model.keyDown(EmulatorViewModel.fastForwardKey) == false)
}

@MainActor @Test func leavingTheLibraryNeedsNoPrompt() {
    let model = EmulatorViewModel()
    #expect(model.requestExit(.quit) == .proceed)
    #expect(model.exitPrompt == nil)
}

@MainActor @Test func theSaveOnExitCheckboxIsTheSetting() {
    let model = EmulatorViewModel()
    let was = model.saveStateOnExit
    defer { model.saveStateOnExit = was }
    model.saveStateOnExit = !was
    #expect(ResumeOnExitSetting().enabled == !was)
}

private func makeOffer() -> ResumeOffer {
    let disc = GameEntry(url: URL(fileURLWithPath: "/nonexistent/Game.cue"))
    return ResumeOffer(title: "Game", key: "test-key", launching: disc, first: disc, resumeDisc: disc,
                       info: SaveStateStore.Info(savedAt: Date(), thumbnail: nil), others: [])
}

/// ⌘Q over the launch sheet must be refused, not stacked as a second sheet a
/// `.terminateLater` would then wait on forever.
@MainActor @Test func aLeaveRequestOverTheResumeSheetIsBusy() throws {
    let model = EmulatorViewModel()
    model.installSessionForTesting(ScriptedSession(), resumeKey: nil)
    defer { model.eject() }
    model.resumeOffer = makeOffer()
    #expect(model.requestExit(.quit) == .busy)
    #expect(model.exitPrompt == nil)
    model.resumeOffer = nil
}

@MainActor @Test func aLeaveRequestOverTheResumeFailureIsBusy() throws {
    let model = EmulatorViewModel()
    model.installSessionForTesting(ScriptedSession(), resumeKey: nil)
    defer { model.eject() }
    model.resumeFailure = .init(message: "x", freshBoot: URL(fileURLWithPath: "/nonexistent"))
    #expect(model.requestExit(.quit) == .busy)
    model.resumeFailure = nil
}

/// Yes hands the gate's intent back at once, but the save can take up to the
/// 3 s fallback. Until the exit finishes, a second request must stay out:
/// it would raise a second sheet and a second pending save.
@MainActor @Test func theGateStaysBusyUntilTheExitFinishes() async throws {
    let model = EmulatorViewModel()
    let was = model.saveStateOnExit
    defer { model.saveStateOnExit = was }
    model.saveStateOnExit = true

    let session = ScriptedSession()
    model.installSessionForTesting(session, resumeKey: "test-\(UUID().uuidString)")
    #expect(model.requestExit(.eject) == .prompted)
    model.confirmExit()
    #expect(model.requestExit(.quit) == .busy)

    // The session never ran, so the save is answered only by its free: a
    // failure, which still finishes the eject. Waited on in time, not in
    // yields: the answer is logged off the main actor before the exit ends.
    session.free()
    for _ in 0..<200 where model.stage != .library { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(model.stage == .library)
    #expect(model.requestExit(.quit) == .proceed)
}

/// Cancel on the launch sheet after Open Disc ▸ Yes: the outgoing game was
/// already confirmed away, so it ends in the library, not paused underneath.
@MainActor @Test func cancellingTheResumeSheetOverAGameReturnsToTheLibrary() throws {
    let model = EmulatorViewModel()
    model.installSessionForTesting(ScriptedSession(), resumeKey: nil)
    model.resumeOffer = makeOffer()
    model.chooseResume(.cancel)
    #expect(model.stage == .library)
    #expect(model.game?.session == nil)
    #expect(model.resumeOffer == nil)
}

@MainActor @Test func cancellingTheResumeFailureOverAGameReturnsToTheLibrary() throws {
    let model = EmulatorViewModel()
    model.installSessionForTesting(ScriptedSession(), resumeKey: nil)
    model.resumeFailure = .init(message: "x", freshBoot: URL(fileURLWithPath: "/nonexistent"))
    model.cancelResumeFailure()
    #expect(model.stage == .library)
    #expect(model.game?.session == nil)
    #expect(model.resumeFailure == nil)
}

/// A disc opened from outside the library must still carry its serial, or
/// its resume key is a path hash and Resume reads as "no longer in the library".
@MainActor @Test func aDiscOutsideTheLibraryIsIdentified() throws {
    let bin = FileManager.default.temporaryDirectory
        .appendingPathComponent("outside-\(UUID().uuidString).bin")
    try identifiableDiscImage().write(to: bin)
    defer { try? FileManager.default.removeItem(at: bin) }

    let siblings = EmulatorViewModel.siblingDiscs(of: bin, entries: [])
    #expect(siblings.map(\.serial) == ["SLUS-00530"])
    #expect(SaveStateStore.key(for: siblings[0]) == "SLUS-00530")
}

/// A stick held across an eject is the same trap as a button held across
/// one: the next game must start centred.
@MainActor
@Test func ejectCentresAStickHeldAcrossIt() {
    let model = EmulatorViewModel()
    var held = InputMap()
    held.sticks = Sticks(lx: 0, ly: 0x80, rx: 0x80, ry: 0x80)

    model.simulatePlayingForTesting()
    let game = model.game!
    model.simulatePadInputForTesting(held)
    #expect(game.sticksForTesting.lx == 0)

    model.eject()
    model.simulatePadInputForTesting(held)
    #expect(game.sticksForTesting == .centred)
}

/// Analog toggles once per physical press: the system's key repeat of a held
/// key must not queue another toggle.
@MainActor @Test func aRepeatedKeyDownDoesNotToggleAnalog() throws {
    let model = EmulatorViewModel()
    let session = ScriptedSession()
    model.installSessionForTesting(session, resumeKey: nil)
    defer { model.eject() }
    model.beginCapture(.analog)
    #expect(model.captureKey(14, command: false))   // E
    defer { model.restoreDefaultKeyBindings() }
    let presses = { session.calls.filter { $0 == "pressAnalog()" }.count }

    #expect(model.keyDown(14) == true)
    #expect(presses() == 1)
    #expect(model.keyDown(14, isRepeat: true) == true)
    #expect(presses() == 1)
}

/// A press made while paused would wait in the session and switch the mode
/// on resume, so a paused model takes none.
@MainActor @Test func aPausedModelQueuesNoAnalogPress() throws {
    let model = EmulatorViewModel()
    let session = ScriptedSession()
    model.installSessionForTesting(session, resumeKey: nil)
    defer { model.eject() }
    let presses = { session.calls.filter { $0 == "pressAnalog()" }.count }

    model.game!.isPaused = true
    model.game!.toggleAnalog()
    #expect(presses() == 0)
    model.game!.isPaused = false
    model.game!.toggleAnalog()
    #expect(presses() == 1)
}

/// The notice follows the pad's own mode bit, so it also reports a game
/// switching the mode itself, and says nothing while the mode holds.
@MainActor
@Test func theAnalogNoticeFollowsTheModeBit() {
    let model = EmulatorViewModel()
    model.simulatePlayingForTesting()
    model.game!.sessionEvent(.pad(.idle))
    #expect(model.game!.notice == nil)

    model.game!.sessionEvent(.pad(PadStatus(analog: true, small: 0, large: 0)))
    #expect(model.game!.notice?.text == "Analog on")

    model.game!.sessionEvent(.pad(PadStatus(analog: false, small: 0, large: 0)))
    #expect(model.game!.notice?.text == "Analog off")
}

/// A pad event carries the status, motors and all: one whose mode holds
/// raises no notice, however its motors move.
@MainActor
@Test func aHoldingModeRaisesNoNotice() {
    let model = EmulatorViewModel()
    model.simulatePlayingForTesting()
    model.game!.sessionEvent(.pad(.idle))
    model.game!.sessionEvent(.pad(PadStatus(analog: false, small: 255, large: 0x40)))
    model.game!.sessionEvent(.pad(PadStatus(analog: false, small: 0, large: 0xFF)))
    #expect(model.game!.notice == nil)
}

/// Lets the main queue run until `done` holds or a second passes.
@MainActor
private func settle(until done: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(1)
    while !done(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// `rumbleAllowed` is the only thing between a paused game and a motor left
/// running: pause, a dialog, Vibration off and the app in the background each
/// still it, and the motors run again once nothing forbids it. The pad sends
/// nothing new once frames stop, so the gate must act on its own: ONE event
/// starts the motors and every change after it comes from the gate. In
/// `LiveGameTests`: it holds a live game across an `await`.
extension LiveGameTests {
    @Test func theMotorsStillWithoutANewPadEvent() async throws {
        let model = EmulatorViewModel()
        let was = model.vibration
        defer { model.vibration = was }
        model.vibration = true
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: nil)
        let game = model.game!
        defer { model.eject() }
        model.simulateAppActiveForTesting(true)
        let driven = MotorDrive(large: 1, small: true)

        session.emit(.pad(PadStatus(analog: true, small: 255, large: 0xFF)))
        #expect(model.hapticsDriveForTesting == driven)

        let reasons: [(set: () -> Void, clear: () -> Void)] = [
            ({ game.isPaused = true }, { game.isPaused = false }),
            ({ model.resumeOffer = makeOffer() }, { model.resumeOffer = nil }),
            ({ model.vibration = false }, { model.vibration = true }),
            ({ model.simulateAppActiveForTesting(false) }, { model.simulateAppActiveForTesting(true) }),
        ]
        for (i, r) in reasons.enumerated() {
            r.set()
            await settle { model.hapticsDriveForTesting == .stopped }
            #expect(model.hapticsDriveForTesting == .stopped, "reason \(i)")
            r.clear()
            await settle { model.hapticsDriveForTesting == driven }
            #expect(model.hapticsDriveForTesting == driven, "reason \(i)")
        }
    }
}

/// A rate that stops arriving while the game is not paused is a stall: the
/// emulator thread is blocked, or parked on a renderer that stopped draining,
/// and sends nothing. The reading must not freeze at its last value. In
/// `LiveGameTests`: it holds a live game across an `await`.
extension LiveGameTests {
    @Test func aFrameRateThatStopsArrivingGoesStale() async throws {
        let model = EmulatorViewModel()
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: nil)
        defer { model.eject() }
        session.emit(.frameRate(60))
        #expect(model.game!.fps == 60)
        try await Task.sleep(for: .seconds(OpenGame.fpsStaleAfter + 0.3))
        #expect(model.game!.fps == nil)
    }
}

/// A disc change frees the outgoing session after the next one is
/// installed: an event already on its way from the old game must not reach
/// the new game's HUD.
@MainActor @Test func anOutgoingSessionsEventIsIgnored() {
    let model = EmulatorViewModel()
    let a = ScriptedSession(), b = ScriptedSession()
    model.installSessionForTesting(a, resumeKey: nil)
    model.installSessionForTesting(b, resumeKey: nil)
    defer { model.eject() }
    let analog = PadStatus(analog: true, small: 0, large: 0)
    a.emit(.pad(analog))
    #expect(model.game!.notice == nil)
    b.emit(.pad(analog))
    #expect(model.game!.notice?.text == "Analog on")
}

@MainActor @Test func theFrameRateEventSetsTheReading() {
    let model = EmulatorViewModel()
    let session = ScriptedSession()
    model.installSessionForTesting(session, resumeKey: nil)
    defer { model.eject() }
    session.emit(.frameRate(59.94))
    #expect(model.game!.fps == 59.94)
}

/// The badge goes up on a new write count only: the same count again is
/// not a new write and does not restart the badge's timer.
@MainActor @Test func aCardWriteEventRaisesTheBadge() {
    let model = EmulatorViewModel()
    let session = ScriptedSession()
    model.installSessionForTesting(session, resumeKey: nil)
    defer { model.eject() }
    #expect(!model.game!.savingToMemoryCard)
    session.emit(.cardWrites(1))
    #expect(model.game!.savingToMemoryCard)
    let timer = model.game!.cardSavingTaskForTesting
    session.emit(.cardWrites(1))
    #expect(model.game!.cardSavingTaskForTesting == timer)
}

/// The pad driving the input leaves while another stays connected: its
/// stick must not hold. An idle pad leaving must not touch the input.
@MainActor @Test func onlyTheActivePadLeavingCentresTheStick() {
    let model = EmulatorViewModel()
    let active = NSObject(), idle = NSObject()
    var held = InputMap()
    held.sticks = Sticks(lx: 0, ly: 0x80, rx: 0x80, ry: 0x80)

    model.simulatePlayingForTesting()
    defer { model.eject() }
    model.simulatePadInputForTesting(held)
    model.simulateControllerInputForTesting(ObjectIdentifier(active))

    model.simulateControllerDisconnectForTesting(ObjectIdentifier(idle))
    #expect(model.game!.sticksForTesting.lx == 0)

    model.simulateControllerDisconnectForTesting(ObjectIdentifier(active))
    #expect(model.game!.sticksForTesting == .centred)
}

/// A menu title saved "Today" reads "Yesterday" after midnight only if the
/// menus re-read their titles.
@MainActor @Test func aNewDayMakesTheMenusReReadTheirTitles() async {
    let model = EmulatorViewModel()
    let before = model.stateRevision
    NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
    for _ in 0..<200 where model.stateRevision == before { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(model.stateRevision > before)
}

/// Cancel on the floating sheet of a Finder or Spotlight launch opens no
/// window; a game, or an alert about the launch, opens the library's.
@MainActor @Test func cancellingTheFloatingSheetWantsNoLibrary() {
    let model = EmulatorViewModel()
    model.resumeOffer = makeOffer()
    model.chooseResume(.cancel)
    #expect(!model.libraryWantedAfterPanel)

    model.errorMessage = "Could not load"
    #expect(model.libraryWantedAfterPanel)
    model.errorMessage = nil

    model.simulatePlayingForTesting()
    #expect(model.libraryWantedAfterPanel)
}
