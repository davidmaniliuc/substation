import Testing
import AppKit
import Foundation
@testable import PS1

/// A fresh defaults key per test, as `LibraryThemeTests` does: these write
/// the real `UserDefaults`, and a shared key would clobber the player's own.
private func uniqueKey() -> String { "test-game-window-\(UUID().uuidString)" }

@Test func anAbsentGameWindowSettingOpensInTheLibraryWindow() {
    #expect(GameWindowSetting(key: uniqueKey()).mode == .libraryWindow)
}

@Test func theGameWindowSettingPersists() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    var setting = GameWindowSetting(key: key)
    setting.set(.newWindow)
    #expect(GameWindowSetting(key: key).mode == .newWindow)
}

/// The raw values are what `UserDefaults` holds.
@Test func gameWindowRawValuesAreStable() {
    #expect(GameWindowMode.libraryWindow.rawValue == 0)
    #expect(GameWindowMode.newWindow.rawValue == 1)
}

/// A game in the library's window replaces the library, toolbar and all.
@MainActor
@Test func aGameInTheLibraryWindowHidesTheLibrary() {
    let model = EmulatorViewModel()
    model.simulatePlayingForTesting(ownWindow: false)
    #expect(!model.libraryVisible)
    #expect(!model.gameWindowShown)
}

/// A game in its own window leaves the library up, and the game window goes
/// once the game has ended.
@MainActor
@Test func aGameInItsOwnWindowLeavesTheLibraryUp() {
    let model = EmulatorViewModel()
    model.simulatePlayingForTesting(ownWindow: true)
    #expect(model.libraryVisible)
    #expect(model.gameWindowShown)

    model.eject()
    #expect(model.libraryVisible)
    #expect(!model.gameWindowShown)
}

/// Closing the game window is Eject: with nothing to ask, it ends the game
/// and lets the window close.
@MainActor
@Test func closingTheGameWindowEjects() {
    let model = EmulatorViewModel()
    model.simulatePlayingForTesting(ownWindow: true)
    #expect(model.closeGameWindow())
    #expect(model.stage == .library)
}

/// The two windows are independent: closing the library leaves a game in its
/// own window running, with nothing asked.
@MainActor
@Test func closingTheLibraryLeavesAGameInItsOwnWindowRunning() {
    let model = EmulatorViewModel()
    model.simulatePlayingForTesting(ownWindow: true)
    #expect(model.closeLibraryWindow())
    #expect(model.stage == .playing)
    #expect(model.exitPrompt == nil)
    #expect(model.gameWindowShown)
}

/// Full screen is off unless asked for, and kept under its own key.
@Test func theFullScreenSettingDefaultsOffAndPersists() {
    let key = uniqueKey()
    defer {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: key + "FullScreen")
    }
    var setting = GameWindowSetting(key: key)
    #expect(!setting.fullScreen)
    setting.setFullScreen(true)
    #expect(GameWindowSetting(key: key).fullScreen)
    #expect(GameWindowSetting(key: key).mode == .libraryWindow)
}

/// `WindowGroup(for:)` restores and routes windows by this value, so it
/// must survive a round trip through its coding.
@Test func gameWindowContentRoundTripsThroughCodable() throws {
    for content in [GameWindowContent.launch, .game(UUID())] {
        let data = try JSONEncoder().encode(content)
        #expect(try JSONDecoder().decode(GameWindowContent.self, from: data) == content)
    }
}

/// Each game's window is its own: a key in one is never another game's.
@MainActor
@Test func aWindowRecordedForOneContentIsNotAnothers() {
    let a = GameWindowContent.game(UUID()), b = GameWindowContent.game(UUID())
    // Not deferred: a deferred window has no number until it is shown.
    let make = { NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false) }
    let wa = make(), wb = make(), other = make()
    GameWindow.record(wa, for: a)
    GameWindow.record(wb, for: b)
    defer { GameWindow.forget(a); GameWindow.forget(b) }
    #expect(GameWindow.content(owningWindowNumber: wa.windowNumber) == a)
    #expect(GameWindow.content(owningWindowNumber: wb.windowNumber) == b)
    #expect(GameWindow.content(owningWindowNumber: other.windowNumber) == nil)
    #expect(GameWindow.window(for: b) === wb)
}
