import Testing
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
