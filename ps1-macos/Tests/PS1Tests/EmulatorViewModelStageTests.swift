import AppKit
import Testing
import Foundation
@testable import PS1

/// `EmulatorViewModel.init()` reads real bookmarks from UserDefaults, so the
/// stage it launches into varies by whichever machine runs the suite. Every
/// test here drives the model to a known stage itself — via `eject()`, which
/// is unconditional — rather than asserting on whatever it started in.
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
/// across an eject would otherwise survive it — the next report of the still-
/// held button (which a real controller keeps sending on every poll) would
/// overwrite `input` again before the next game even starts. A real
/// `GCExtendedGamepad` can't be synthesised here, so this drives
/// `applyPadInput` through `simulatePadInputForTesting`, the same method the
/// real handler calls — reverting the stage gate on `applyPadInput` makes
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
/// to run the block SYNCHRONOUSLY on the posting thread — the guarantee that
/// makes a save reach disk before the process actually exits. Until this test
/// nothing drove that path at all. A real `runner`/`core` pair needs a BIOS
/// and a disc, which this suite deliberately does not depend on, so this
/// observes teardown through its other, always-available effect: it resets
/// `input`, which a held key would otherwise leave latched.
@MainActor
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
