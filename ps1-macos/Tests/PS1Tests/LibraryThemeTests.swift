import Testing
import Foundation
@testable import PS1

/// A fresh defaults key per test, as `DitherModeTests` does: these write the
/// real `UserDefaults`, and a shared key would clobber the player's own theme.
private func uniqueKey() -> String { "test-library-theme-\(UUID().uuidString)" }

@Test func anAbsentThemeFollowsTheSystem() {
    #expect(LibraryThemeSetting(key: uniqueKey()).theme == .system)
    #expect(LibraryThemeSetting.defaultTheme == .system)
    #expect(LibraryTheme.system.colorScheme == nil)
}

@Test func theThemePersists() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    var setting = LibraryThemeSetting(key: key)
    setting.set(.dark)
    #expect(setting.theme == .dark)
    #expect(LibraryThemeSetting(key: key).theme == .dark)
}

@Test func anUnknownStoredThemeFallsBackToTheSystem() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    // A theme written by a newer build and then downgraded: the raw value is
    // data, and a library drawn in a theme this build lacks is no theme.
    UserDefaults.standard.set(7, forKey: key)
    #expect(LibraryThemeSetting(key: key).theme == .system)
}

/// A stored Black is the player's choice and survives the new default.
@Test func aStoredBlackStaysBlack() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    UserDefaults.standard.set(0, forKey: key)
    #expect(LibraryThemeSetting(key: key).theme == .black)
}

/// The raw values are what `UserDefaults` holds: renumbering one would put
/// every player in the other theme.
@Test func themeRawValuesAreStable() {
    #expect(LibraryTheme.black.rawValue == 0)
    #expect(LibraryTheme.dark.rawValue == 1)
    #expect(LibraryTheme.light.rawValue == 2)
    #expect(LibraryTheme.system.rawValue == 3)
}

/// Light round-trips like the others, and is the one theme in the light scheme.
@Test func lightPersistsAndIsTheLightScheme() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    var setting = LibraryThemeSetting(key: key)
    setting.set(.light)
    #expect(LibraryThemeSetting(key: key).theme == .light)
    #expect(LibraryTheme.allCases.filter { $0.colorScheme == .light } == [.light])
}
