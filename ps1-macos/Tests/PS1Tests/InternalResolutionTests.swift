import Testing
import Foundation
@testable import PS1

/// A fresh defaults key per test, exactly as `ScopedBookmarkTests` does: these
/// write to the real `UserDefaults`, so a shared key would let one test see
/// another's scale — and would clobber the running user's own setting.
private func uniqueKey() -> String { "test-resolution-\(UUID().uuidString)" }

@Test func anUnusedKeyLoadsAsOneX() {
    // `UserDefaults.integer(forKey:)` returns 0 for a missing key, and the
    // clamp lifts that to 1. The shipped default therefore falls out of the
    // clamp rather than being a second constant that could drift from it.
    let res = InternalResolution(key: uniqueKey())
    #expect(res.scale == 1)
}

@Test func theScaleRoundTripsThroughUserDefaults() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }

    var written = InternalResolution(key: key)
    written.set(4)
    #expect(written.scale == 4)

    // The point of persisting it: a fresh instance built from the same key
    // reads the same scale back, which is what makes the choice survive a
    // relaunch.
    #expect(InternalResolution(key: key).scale == 4)
}

@Test func anOutOfRangePersistedValueLoadsInsteadOfTrapping() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }

    // Hand-edited defaults, or a value written by a future build with a wider
    // range and then downgraded. `MetalVram.init` traps outside 1...8
    // (MetalVram.swift:51) and its own comment says the picker must clamp
    // rather than let the app abort at launch — this is that clamp.
    UserDefaults.standard.set(99, forKey: key)
    #expect(InternalResolution(key: key).scale == 8)

    UserDefaults.standard.set(-3, forKey: key)
    #expect(InternalResolution(key: key).scale == 1)
}

@Test func settingAnOutOfRangeScaleClampsBeforeItIsStored() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }

    var res = InternalResolution(key: key)
    res.set(99)
    #expect(res.scale == 8)
    // Clamped on the way IN as well as on the way out, so a bad value never
    // reaches the defaults database in the first place.
    #expect(UserDefaults.standard.integer(forKey: key) == 8)
}

@MainActor
@Test func theViewModelRoundTripsAndClampsTheInternalScale() {
    let model = EmulatorViewModel()
    let original = model.internalScale
    defer { model.internalScale = original }

    model.internalScale = 4
    #expect(model.internalScale == 4)
    // A fresh model reads it back: the menu writes through to the setting, it
    // does not hold a session-only copy.
    #expect(EmulatorViewModel().internalScale == 4)

    model.internalScale = 99
    #expect(model.internalScale == 8)
}
