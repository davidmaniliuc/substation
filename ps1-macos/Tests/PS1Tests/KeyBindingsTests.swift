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
        #expect(b.control(forKey: 126) == .button(.up))
        #expect(b.control(forKey: 6) == .button(.cross))
        #expect(b.control(forKey: 36) == .button(.start))
    }

    @Test func everyListedButtonHasADefaultAndNoTwoShareAKey() {
        let buttons = KeyBindings.controls.filter { $0 != .analog && $0 != .rewind }
        let codes = buttons.compactMap { KeyBindings.defaults[$0] }
        #expect(codes.count == buttons.count)
        #expect(Set(codes).count == codes.count)
        #expect(Set(KeyBindings.defaults.keys) == Set(buttons + [.rewind]))
    }

    @Test func assigningRebindsTheButton() {
        var b = KeyBindings(defaults: freshDefaults())
        let accepted = b.assign(14, to: .button(.cross))   // E
        #expect(accepted)
        #expect(b.key(for: .button(.cross)) == 14)
        #expect(b.control(forKey: 14) == .button(.cross))
        #expect(b.control(forKey: 6) == nil)  // Z no longer drives anything
    }

    /// A key another button holds moves: two buttons on one key would press
    /// both at once.
    @Test func assigningATakenKeyUnbindsItsOldButton() {
        var b = KeyBindings(defaults: freshDefaults())
        b.assign(126, to: .button(.triangle))         // the Up arrow
        #expect(b.control(forKey: 126) == .button(.triangle))
        #expect(b.key(for: .button(.up)) == nil)
        #expect(b.key(for: .button(.triangle)) == 126)
    }

    @Test func reassigningAButtonItsOwnKeyChangesNothing() {
        var b = KeyBindings(defaults: freshDefaults())
        b.assign(126, to: .button(.up))
        #expect(b.isDefault)
    }

    @Test func reservedKeysAreRefused() {
        var b = KeyBindings(defaults: freshDefaults())
        let tab = b.assign(48, to: .button(.cross))      // Tab, fast-forward
        #expect(!tab)
        let escape = b.assign(53, to: .button(.cross))   // Escape
        #expect(!escape)
        #expect(b.isDefault)
    }

    @Test func bindingsPersistIncludingAnUnboundButton() {
        let d = freshDefaults()
        var b = KeyBindings(defaults: d)
        b.assign(126, to: .button(.triangle))
        let reloaded = KeyBindings(defaults: d)
        #expect(reloaded == b)
        #expect(reloaded.key(for: .button(.up)) == nil)
    }

    @Test func restoringDefaultsPersists() {
        let d = freshDefaults()
        var b = KeyBindings(defaults: d)
        b.assign(14, to: .button(.cross))
        b.restoreDefaults()
        #expect(b.isDefault)
        #expect(KeyBindings(defaults: d).isDefault)
    }

    @Test func analogIsUnboundByDefault() {
        let b = KeyBindings(defaults: freshDefaults())
        #expect(b.key(for: .analog) == nil)
        #expect(b.isDefault)
    }

    /// A key moves to Analog like it moves between buttons.
    @Test func analogTakesAKeyFromAButton() {
        var b = KeyBindings(defaults: freshDefaults())
        b.assign(6, to: .analog)          // Z, Cross by default
        #expect(b.control(forKey: 6) == .analog)
        #expect(b.key(for: .button(.cross)) == nil)
    }

    /// A map saved before Analog existed has no "analog" entry; it must load,
    /// with Analog unbound and every button where the player left it.
    @Test func aMapSavedBeforeAnalogStillLoads() {
        let d = freshDefaults()
        d.set([String(PadButton.cross.rawValue): 14], forKey: KeyBindings.storageKey)
        let b = KeyBindings(defaults: d)
        #expect(b.key(for: .button(.cross)) == 14)
        #expect(b.key(for: .analog) == nil)
        #expect(b.key(for: .button(.up)) == nil)   // a present map is the whole map
    }

    @Test func analogPersists() {
        let d = freshDefaults()
        var b = KeyBindings(defaults: d)
        b.assign(0, to: .analog)          // A, L2 by default
        #expect(KeyBindings(defaults: d) == b)
    }

    @Test func specialKeysHaveNames() {
        #expect(KeyName.of(126) == "↑")
        #expect(KeyName.of(36) == "Return")
        #expect(KeyName.of(49) == "Space")
    }

    @Test func rewindIsOnBackspaceByDefault() {
        let b = KeyBindings(defaults: freshDefaults())
        #expect(b.key(for: .rewind) == 51)
        #expect(b.control(forKey: 51) == .rewind)
    }

    /// A map saved before rewind existed has no "rewind" entry: rewind takes
    /// its default key, unless the player already gave that key to a button.
    @Test func aMapSavedBeforeRewindGetsBackspace() {
        let d = freshDefaults()
        d.set(["16": 126], forKey: KeyBindings.storageKey)   // D-Pad Up on the Up arrow
        #expect(KeyBindings(defaults: d).key(for: .rewind) == 51)
        d.set(["16": 51], forKey: KeyBindings.storageKey)    // D-Pad Up on Backspace
        let taken = KeyBindings(defaults: d)
        #expect(taken.key(for: .rewind) == nil)
        #expect(taken.control(forKey: 51) == .button(.up))
    }

    /// Once the map knows about rewind, unbinding it sticks.
    @Test func anUnboundRewindStaysUnbound() {
        let d = freshDefaults()
        var b = KeyBindings(defaults: d)
        b.assign(51, to: .button(.select))
        #expect(b.key(for: .rewind) == nil)
        #expect(KeyBindings(defaults: d).key(for: .rewind) == nil)
    }
}
