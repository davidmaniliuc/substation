import Testing
import Foundation
@testable import PS1

/// A fresh defaults key pair per test, exactly as `InternalResolutionTests`
/// does: these write to the real `UserDefaults`, so shared keys would let one
/// test see another's volume — and would clobber the running user's own.
private func uniqueKeys() -> (level: String, muted: String) {
    let id = UUID().uuidString
    return ("test-volume-\(id)", "test-muted-\(id)")
}

private func setting(_ keys: (level: String, muted: String)) -> VolumeSetting {
    VolumeSetting(levelKey: keys.level, mutedKey: keys.muted)
}

@Test func anUnusedKeyLoadsAtFullVolume() {
    // The trap `InternalResolution` does not have: `double(forKey:)` returns 0
    // for a missing key, and 0 is a legitimate volume, so the clamp cannot
    // lift it the way it lifts 1x. A first launch must be audible, so the
    // absence of the key has to be distinguished from a stored zero.
    let s = setting(uniqueKeys())
    #expect(s.level == 1)
    #expect(s.isMuted == false)
}

@Test func theLevelRoundTripsThroughUserDefaults() {
    let keys = uniqueKeys()
    defer { UserDefaults.standard.removeObject(forKey: keys.level) }

    var written = setting(keys)
    written.set(0.25)
    #expect(written.level == 0.25)

    #expect(setting(keys).level == 0.25)
}

@Test func aStoredZeroSurvivesTheLoad() {
    let keys = uniqueKeys()
    defer { UserDefaults.standard.removeObject(forKey: keys.level) }

    // The other half of `anUnusedKeyLoadsAtFullVolume`: a deliberate silence
    // must not be read back as the missing-key default and turned up to full.
    var written = setting(keys)
    written.set(0)
    #expect(setting(keys).level == 0)
}

@Test func settingAnOutOfRangeLevelClampsBeforeItIsStored() {
    let keys = uniqueKeys()
    defer { UserDefaults.standard.removeObject(forKey: keys.level) }

    var s = setting(keys)
    s.set(4.2)
    #expect(s.level == 1)
    #expect(UserDefaults.standard.double(forKey: keys.level) == 1)

    s.set(-1)
    #expect(s.level == 0)
}

@Test func anOutOfRangePersistedLevelIsClampedOnLoad() {
    let keys = uniqueKeys()
    defer { UserDefaults.standard.removeObject(forKey: keys.level) }

    // Hand-edited defaults, or a value written by a future build. A gain
    // above 1 would clip the mix rather than merely being loud.
    UserDefaults.standard.set(9.0, forKey: keys.level)
    #expect(setting(keys).level == 1)
}

@Test func mutingLeavesTheLevelAloneSoUnmutingRestoresIt() {
    let keys = uniqueKeys()
    defer {
        UserDefaults.standard.removeObject(forKey: keys.level)
        UserDefaults.standard.removeObject(forKey: keys.muted)
    }

    // Mute is a flag OVER an untouched level rather than a level of zero with
    // the old value stashed somewhere — which is what makes "restore what you
    // had" fall out instead of needing a second field kept in sync.
    var s = setting(keys)
    s.set(0.4)
    s.toggleMute()
    #expect(s.isMuted)
    #expect(s.level == 0.4)
    #expect(s.gain == 0)

    s.toggleMute()
    #expect(s.isMuted == false)
    #expect(s.gain == 0.4)
}

@Test func muteRoundTripsThroughUserDefaults() {
    let keys = uniqueKeys()
    defer { UserDefaults.standard.removeObject(forKey: keys.muted) }

    var s = setting(keys)
    s.toggleMute()
    #expect(setting(keys).isMuted)
}

@Test func movingTheSliderWhileMutedUnmutes() {
    let keys = uniqueKeys()
    defer {
        UserDefaults.standard.removeObject(forKey: keys.level)
        UserDefaults.standard.removeObject(forKey: keys.muted)
    }

    // Otherwise the slider is a dead control: the fill tracks the drag and
    // nothing comes out of the speakers, with no visible reason why.
    var s = setting(keys)
    s.toggleMute()
    s.set(0.7)
    #expect(s.isMuted == false)
    #expect(s.gain == 0.7)
}

@MainActor
@Test func theViewModelRoundTripsAndClampsTheVolume() {
    let model = EmulatorViewModel()
    let original = model.volume
    let wasMuted = model.isMuted
    defer {
        model.volume = original
        if model.isMuted != wasMuted { model.toggleMute() }
    }

    model.volume = 0.5
    #expect(model.volume == 0.5)
    // A fresh model reads it back: the HUD writes through to the setting, it
    // does not hold a session-only copy.
    #expect(EmulatorViewModel().volume == 0.5)

    model.volume = 3
    #expect(model.volume == 1)
}
