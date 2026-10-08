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
    #expect(model.keyDown(126) == true)
    #expect(model.inputMaskForTesting & PadButton.up.rawValue == 0)   // held

    model.eject()
    #expect(model.inputMaskForTesting == 0xFFFF)   // idle, not just "released"

    // The next game's first setButtons call must not inherit the old bit.
    model.simulatePlayingForTesting()
    #expect(model.inputMaskForTesting == 0xFFFF)
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
    model.simulatePadInputForTesting(heldUp)
    #expect(model.inputMaskForTesting & PadButton.up.rawValue == 0)   // held

    model.eject()
    #expect(model.inputMaskForTesting == 0xFFFF)   // idle, not just "released"

    // The pad is still physically held: its next report arrives after the
    // eject and must be dropped, not published into `input`.
    model.simulatePadInputForTesting(heldUp)
    #expect(model.inputMaskForTesting == 0xFFFF)

    // The next game's first setButtons call must not inherit the old bit.
    model.simulatePlayingForTesting()
    #expect(model.inputMaskForTesting == 0xFFFF)
}

/// The entire ⌘Q path: `EmulatorViewModel.init()` registers its teardown
/// against `willTerminateNotification` with `queue: nil`, which is documented
/// to run the block SYNCHRONOUSLY on the posting thread; the guarantee that
/// makes a save reach disk before the process actually exits. Until this test
/// nothing drove that path at all. A real `runner`/`core` pair needs a BIOS
/// and a disc, which this suite deliberately does not depend on, so this
/// observes teardown through its other, always-available effect: it resets
/// `input`, which a held key would otherwise leave latched.
extension LiveGameTests {
    @Test func willTerminateNotificationRunsTeardownSynchronously() {
        let model = EmulatorViewModel()
        model.simulatePlayingForTesting()
        #expect(model.keyDown(126) == true)   // up arrow
        #expect(model.inputMaskForTesting & PadButton.up.rawValue == 0)   // held

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

        // If the observer had been registered with a non-nil queue and that queue
        // ever enqueued instead of running inline, this would still be the
        // pre-teardown value immediately after `post` returns.
        #expect(model.inputMaskForTesting == 0xFFFF)
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

    #expect(model.keyDown(EmulatorViewModel.fastForwardKey) == true)
    #expect(model.isFastForwarding)
    #expect(model.effectiveSpeed == model.fastForwardSpeed)
    // The pad never sees it.
    #expect(model.inputMaskForTesting == 0xFFFF)

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

private func makeIdleRunner() throws -> EmulatorRunner {
    let core = try Ps1Core()
    try core.loadBIOS(Data(repeating: 0, count: 524288))
    return EmulatorRunner(core: core, ring: AudioRing(capacity: EmulatorRunner.ringCapacity),
                          cards: MemoryCardStore(directory: FileManager.default.temporaryDirectory
                              .appendingPathComponent("exit-\(UUID().uuidString)")))
}

private func makeOffer() -> ResumeOffer {
    let disc = GameEntry(url: URL(fileURLWithPath: "/nonexistent/Game.cue"))
    return ResumeOffer(title: "Game", key: "test-key", launching: disc, resumeDisc: disc,
                       info: SaveStateStore.Info(savedAt: Date(), thumbnail: nil), others: [])
}

/// ⌘Q over the launch sheet must be refused, not stacked as a second sheet a
/// `.terminateLater` would then wait on forever.
@MainActor @Test func aLeaveRequestOverTheResumeSheetIsBusy() throws {
    let model = EmulatorViewModel()
    model.installRunnerForTesting(try makeIdleRunner(), resumeKey: nil)
    defer { model.eject() }
    model.resumeOffer = makeOffer()
    #expect(model.requestExit(.quit) == .busy)
    #expect(model.exitPrompt == nil)
    model.resumeOffer = nil
}

@MainActor @Test func aLeaveRequestOverTheResumeFailureIsBusy() throws {
    let model = EmulatorViewModel()
    model.installRunnerForTesting(try makeIdleRunner(), resumeKey: nil)
    defer { model.eject() }
    model.resumeFailure = .init(message: "x", freshBoot: URL(fileURLWithPath: "/nonexistent"))
    #expect(model.requestExit(.quit) == .busy)
    model.resumeFailure = nil
}

/// Yes hands the gate's intent back at once, but the save can take up to the
/// 3 s fallback. Until the exit finishes, a second request must stay out:
/// it would raise a second sheet and replace the runner's pending save.
@MainActor @Test func theGateStaysBusyUntilTheExitFinishes() async throws {
    let model = EmulatorViewModel()
    let was = model.saveStateOnExit
    defer { model.saveStateOnExit = was }
    model.saveStateOnExit = true

    let runner = try makeIdleRunner()
    model.installRunnerForTesting(runner, resumeKey: "test-\(UUID().uuidString)")
    #expect(model.requestExit(.eject) == .prompted)
    model.confirmExit()
    #expect(model.requestExit(.quit) == .busy)

    // The runner never ran, so the save is answered only by its stop: a
    // failure, which still finishes the eject. Waited on in time, not in
    // yields: the answer is logged off the main actor before the exit ends.
    runner.stop()
    for _ in 0..<200 where model.stage != .library { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(model.stage == .library)
    #expect(model.requestExit(.quit) == .proceed)
}

/// Cancel on the launch sheet after Open Disc ▸ Yes: the outgoing game was
/// already confirmed away, so it ends in the library, not paused underneath.
@MainActor @Test func cancellingTheResumeSheetOverAGameReturnsToTheLibrary() throws {
    let model = EmulatorViewModel()
    model.installRunnerForTesting(try makeIdleRunner(), resumeKey: nil)
    model.resumeOffer = makeOffer()
    model.chooseResume(.cancel)
    #expect(model.stage == .library)
    #expect(model.runner == nil)
    #expect(model.resumeOffer == nil)
}

@MainActor @Test func cancellingTheResumeFailureOverAGameReturnsToTheLibrary() throws {
    let model = EmulatorViewModel()
    model.installRunnerForTesting(try makeIdleRunner(), resumeKey: nil)
    model.resumeFailure = .init(message: "x", freshBoot: URL(fileURLWithPath: "/nonexistent"))
    model.cancelResumeFailure()
    #expect(model.stage == .library)
    #expect(model.runner == nil)
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
    model.simulatePadInputForTesting(held)
    #expect(model.sticksForTesting.lx == 0)

    model.eject()
    model.simulatePadInputForTesting(held)
    #expect(model.sticksForTesting == .centred)
}

/// Analog toggles once per physical press: the system's key repeat of a held
/// key must not queue another toggle.
@MainActor @Test func aRepeatedKeyDownDoesNotToggleAnalog() throws {
    let model = EmulatorViewModel()
    let runner = try makeIdleRunner()
    model.installRunnerForTesting(runner, resumeKey: nil)
    defer { model.eject() }
    model.beginCapture(.analog)
    #expect(model.captureKey(14, command: false))   // E
    defer { model.restoreDefaultKeyBindings() }

    #expect(model.keyDown(14) == true)
    #expect(runner.takeAnalogPress())
    #expect(model.keyDown(14, isRepeat: true) == true)
    #expect(!runner.takeAnalogPress())
}

/// A press made while paused would wait in the runner and switch the mode on
/// resume, so a paused model takes none.
@MainActor @Test func aPausedModelQueuesNoAnalogPress() throws {
    let model = EmulatorViewModel()
    let runner = try makeIdleRunner()
    model.installRunnerForTesting(runner, resumeKey: nil)
    defer { model.eject() }

    model.isPaused = true
    model.toggleAnalog()
    #expect(!runner.takeAnalogPress())
    model.isPaused = false
    model.toggleAnalog()
    #expect(runner.takeAnalogPress())
}

/// The notice follows the pad's own mode bit, so it also reports a game
/// switching the mode itself, and says nothing while the mode holds.
@MainActor
@Test func theAnalogNoticeFollowsTheModeBit() {
    let model = EmulatorViewModel()
    model.simulatePlayingForTesting()
    model.simulatePadStatusForTesting(.idle)
    #expect(model.notice == nil)

    model.simulatePadStatusForTesting(PadStatus(analog: true, small: 0, large: 0))
    #expect(model.notice == "Analog on")

    model.simulatePadStatusForTesting(PadStatus(analog: false, small: 0, large: 0))
    #expect(model.notice == "Analog off")
}

/// Every 16 ms poll reports the status, motors and all: a status whose mode
/// holds raises no notice, however its motors move.
@MainActor
@Test func aHoldingModeRaisesNoNotice() {
    let model = EmulatorViewModel()
    model.simulatePlayingForTesting()
    model.simulatePadStatusForTesting(.idle)
    model.simulatePadStatusForTesting(PadStatus(analog: false, small: 255, large: 0x40))
    model.simulatePadStatusForTesting(PadStatus(analog: false, small: 0, large: 0xFF))
    #expect(model.notice == nil)
}

/// `rumbleAllowed` is the only thing between a paused game and a motor left
/// running: pause, a dialog, Vibration off and the app in the background each
/// still it, and the same
/// motor status drives it again once nothing forbids it.
@MainActor @Test func everyReasonToKeepStillStillsTheMotors() throws {
    let model = EmulatorViewModel()
    let was = model.vibration
    defer { model.vibration = was }
    model.vibration = true
    model.installRunnerForTesting(try makeIdleRunner(), resumeKey: nil)
    defer { model.eject() }
    model.simulateAppActiveForTesting(true)
    let rumbling = PadStatus(analog: true, small: 255, large: 0xFF)
    let driven = MotorDrive(large: 1, small: true)

    model.simulatePadStatusForTesting(rumbling)
    #expect(model.hapticsDriveForTesting == driven)

    model.isPaused = true
    model.simulatePadStatusForTesting(rumbling)
    #expect(model.hapticsDriveForTesting == .stopped)
    model.isPaused = false

    model.resumeOffer = makeOffer()
    model.simulatePadStatusForTesting(rumbling)
    #expect(model.hapticsDriveForTesting == .stopped)
    model.resumeOffer = nil

    model.vibration = false
    model.simulatePadStatusForTesting(rumbling)
    #expect(model.hapticsDriveForTesting == .stopped)
    model.vibration = true

    model.simulateAppActiveForTesting(false)
    model.simulatePadStatusForTesting(rumbling)
    #expect(model.hapticsDriveForTesting == .stopped)
    model.simulateAppActiveForTesting(true)

    model.simulatePadStatusForTesting(rumbling)
    #expect(model.hapticsDriveForTesting == driven)
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
    #expect(model.sticksForTesting.lx == 0)

    model.simulateControllerDisconnectForTesting(ObjectIdentifier(active))
    #expect(model.sticksForTesting == .centred)
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
