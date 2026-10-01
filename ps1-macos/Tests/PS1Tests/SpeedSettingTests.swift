import Testing
import Foundation
@testable import PS1

/// A fresh defaults key pair per test, exactly as `VolumeSettingTests` does:
/// these write to the real `UserDefaults`.
private func uniqueKeys() -> (base: String, turbo: String) {
    let id = UUID().uuidString
    return ("test-speed-\(id)", "test-turbo-\(id)")
}

private func setting(_ keys: (base: String, turbo: String)) -> SpeedSetting {
    SpeedSetting(baseKey: keys.base, turboKey: keys.turbo)
}

private func forget(_ keys: (base: String, turbo: String)) {
    UserDefaults.standard.removeObject(forKey: keys.base)
    UserDefaults.standard.removeObject(forKey: keys.turbo)
}

@Test func anUnusedKeyLoadsAtFullSpeedWithADoubleSpeedTurbo() {
    let s = setting(uniqueKeys())
    #expect(s.base == 1)
    #expect(s.turbo == 2)
    #expect(s.effective == 1)
}

@Test func bothSpeedsRoundTripThroughUserDefaults() {
    let keys = uniqueKeys()
    defer { forget(keys) }

    var written = setting(keys)
    written.setBase(3)
    written.setTurbo(4)

    let read = setting(keys)
    #expect(read.base == 3)
    #expect(read.turbo == 4)
}

@Test func speedsOutsideTheChoicesAreClamped() {
    let keys = uniqueKeys()
    defer { forget(keys) }

    var s = setting(keys)
    s.setBase(9)
    #expect(s.base == SpeedSetting.choices.upperBound)
    s.setBase(0)
    #expect(s.base == SpeedSetting.choices.lowerBound)

    // A stored value from some other build is clamped on the way in too.
    UserDefaults.standard.set(17, forKey: keys.turbo)
    #expect(setting(keys).turbo == SpeedSetting.choices.upperBound)
}

@Test func cyclingWalksTheChoicesAndWrapsToFullSpeed() {
    let keys = uniqueKeys()
    defer { forget(keys) }

    var s = setting(keys)
    var seen: [Int] = []
    for _ in SpeedSetting.choices {
        s.cycleBase()
        seen.append(s.base)
    }
    #expect(seen == [2, 3, 4, 1])
}

@Test func holdingFastForwardRunsAtTurboAndReleasingRestoresTheBase() {
    let keys = uniqueKeys()
    defer { forget(keys) }

    var s = setting(keys)
    s.setBase(3)
    s.setTurbo(2)

    s.isFastForwarding = true
    // The held speed wins even when it is SLOWER than the base: the key means
    // "run at the turbo speed", not "run at whichever is faster".
    #expect(s.effective == 2)

    s.isFastForwarding = false
    #expect(s.effective == 3)
}

@Test func fastForwardIsNeverPersisted() {
    let keys = uniqueKeys()
    defer { forget(keys) }

    var s = setting(keys)
    s.isFastForwarding = true
    s.setBase(2)

    #expect(setting(keys).isFastForwarding == false)
}

@Test func theRingBuffersTheSameTimeOfAudioAtEverySpeed() {
    // At N× the audio path drains the ring N times as fast, so a fixed mark
    // would leave a quarter of the margin at 4× and underrun.
    let one = EmulatorRunner.waterMarks(speed: 1)
    for n in SpeedSetting.choices {
        let marks = EmulatorRunner.waterMarks(speed: n)
        #expect(marks.high == one.high * n)
        #expect(marks.low == one.low * n)
    }
}

@Test func theRingHoldsTheHighWaterMarkAtTheFastestSpeed() {
    // Past capacity the loop would never see the ring "full enough", run
    // unpaced, and drop every sample that did not fit.
    let fastest = EmulatorRunner.waterMarks(speed: SpeedSetting.choices.upperBound)
    #expect(fastest.high < EmulatorRunner.ringCapacity)
}
