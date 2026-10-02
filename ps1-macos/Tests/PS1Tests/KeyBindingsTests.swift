import Foundation
import Testing
@testable import PS1

/// Each test gets its own suite: the tests run inside the app, and the app's
/// own `keyBindings` key must never be touched by them.
private func freshDefaults() -> UserDefaults {
    let name = "KeyBindingsTests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

struct KeyBindingsTests {
    @Test func absentKeyMeansTheDefaults() {
        let b = KeyBindings(defaults: freshDefaults())
        #expect(b.isDefault)
        #expect(b.button(forKey: 126) == .up)
        #expect(b.button(forKey: 6) == .cross)
        #expect(b.button(forKey: 36) == .start)
    }

    @Test func everyListedButtonHasADefaultAndNoTwoShareAKey() {
        let codes = KeyBindings.buttons.compactMap { KeyBindings.defaults[$0] }
        #expect(codes.count == KeyBindings.buttons.count)
        #expect(Set(codes).count == codes.count)
        #expect(Set(KeyBindings.defaults.keys) == Set(KeyBindings.buttons))
    }

    @Test func assigningRebindsTheButton() {
        var b = KeyBindings(defaults: freshDefaults())
        let accepted = b.assign(14, to: .cross)   // E
        #expect(accepted)
        #expect(b.key(for: .cross) == 14)
        #expect(b.button(forKey: 14) == .cross)
        #expect(b.button(forKey: 6) == nil)  // Z no longer drives anything
    }

    /// A key another button holds moves: two buttons on one key would press
    /// both at once.
    @Test func assigningATakenKeyUnbindsItsOldButton() {
        var b = KeyBindings(defaults: freshDefaults())
        b.assign(126, to: .triangle)         // the Up arrow
        #expect(b.button(forKey: 126) == .triangle)
        #expect(b.key(for: .up) == nil)
        #expect(b.key(for: .triangle) == 126)
    }

    @Test func reassigningAButtonItsOwnKeyChangesNothing() {
        var b = KeyBindings(defaults: freshDefaults())
        b.assign(126, to: .up)
        #expect(b.isDefault)
    }

    @Test func reservedKeysAreRefused() {
        var b = KeyBindings(defaults: freshDefaults())
        let tab = b.assign(48, to: .cross)      // Tab, fast-forward
        #expect(!tab)
        let escape = b.assign(53, to: .cross)   // Escape
        #expect(!escape)
        #expect(b.isDefault)
    }

    @Test func bindingsPersistIncludingAnUnboundButton() {
        let d = freshDefaults()
        var b = KeyBindings(defaults: d)
        b.assign(126, to: .triangle)
        let reloaded = KeyBindings(defaults: d)
        #expect(reloaded == b)
        #expect(reloaded.key(for: .up) == nil)
    }

    @Test func restoringDefaultsPersists() {
        let d = freshDefaults()
        var b = KeyBindings(defaults: d)
        b.assign(14, to: .cross)
        b.restoreDefaults()
        #expect(b.isDefault)
        #expect(KeyBindings(defaults: d).isDefault)
    }

    @Test func specialKeysHaveNames() {
        #expect(KeyName.of(126) == "↑")
        #expect(KeyName.of(36) == "Return")
        #expect(KeyName.of(49) == "Space")
    }
}
