import Testing
import Foundation
import AppKit
@testable import PS1

/// A fresh defaults key per test, as `DitherModeTests` does: these write the
/// real `UserDefaults`, and a shared key would clobber the player's own theme.
private func uniqueKey() -> String { "test-library-theme-\(UUID().uuidString)" }

@MainActor @Test func anAbsentThemeFollowsTheSystem() {
    #expect(LibraryThemeSetting(key: uniqueKey()).theme == .system)
    #expect(LibraryThemeSetting.defaultTheme == .system)
    #expect(LibraryTheme.system.colorScheme == SystemAppearance.shared.scheme)
}

/// System resolves to macOS's own setting, never to "no preference": a nil
/// preference left a window that had been Dark or Light as it was.
@MainActor @Test func theSystemThemeIsMacOSsScheme() {
    let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    #expect(LibraryTheme.system.colorScheme == (dark ? .dark : .light))
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

/// Black (0), Substation (4) and Graphite (5) were removed: a player who
/// had chosen one opens on System, and no theme ever takes their numbers.
@Test func aRetiredThemeLoadsAsTheSystem() {
    for retired in [0, 4, 5] {
        let key = uniqueKey()
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(retired, forKey: key)
        #expect(LibraryThemeSetting(key: key).theme == .system)
        #expect(LibraryTheme(rawValue: retired) == nil)
    }
}

/// The raw values are what `UserDefaults` holds: renumbering one would put
/// every player in the other theme.
@Test func themeRawValuesAreStable() {
    #expect(LibraryTheme.dark.rawValue == 1)
    #expect(LibraryTheme.light.rawValue == 2)
    #expect(LibraryTheme.system.rawValue == 3)
}

/// Light round-trips like the others, and is the one fixed theme in the
/// light scheme.
@MainActor @Test func lightPersistsAndIsTheLightScheme() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    var setting = LibraryThemeSetting(key: key)
    setting.set(.light)
    #expect(LibraryThemeSetting(key: key).theme == .light)
    #expect(LibraryTheme.allCases.filter { $0 != .system && $0.colorScheme == .light } == [.light])
}
