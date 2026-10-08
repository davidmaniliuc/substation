import Testing
import Foundation
@testable import PS1

private func makeDefaults() -> (defaults: UserDefaults, name: String) {
    let name = "autosave-\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

@Test func autoSaveDefaultsToFiveMinutesWhenNeverSet() {
    let (defaults, name) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let setting = AutoSaveSetting(key: "k", defaults: defaults)
    #expect(setting.minutes == 5)
    #expect(setting.interval == 300)
}

@Test func autoSaveOffPersistsAndHasNoInterval() {
    let (defaults, name) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    var setting = AutoSaveSetting(key: "k", defaults: defaults)
    setting.set(0)
    let reread = AutoSaveSetting(key: "k", defaults: defaults)
    #expect(reread.minutes == 0)
    #expect(reread.interval == nil)
}

@Test func anUnknownStoredIntervalReadsAsTheDefault() {
    let (defaults, name) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(7, forKey: "k")
    #expect(AutoSaveSetting(key: "k", defaults: defaults).minutes == 5)
    var setting = AutoSaveSetting(key: "k", defaults: defaults)
    setting.set(3)
    #expect(setting.minutes == 5)
}

@Test func autoSaveTitles() {
    #expect(AutoSaveSetting.title(0) == "Off")
    #expect(AutoSaveSetting.title(1) == "Every Minute")
    #expect(AutoSaveSetting.title(10) == "Every 10 Minutes")
}

private let t0: TimeInterval = 1_000_000

@Test func theClockCountsOnlyActivePlay() {
    var clock = AutoSaveClock()
    clock.update(counting: true, at: t0)
    clock.update(counting: false, at: t0 + 100)   // paused
    #expect(clock.elapsed(at: t0 + 1_000) == 100)
    clock.update(counting: true, at: t0 + 1_000)
    #expect(clock.elapsed(at: t0 + 1_050) == 150)
}

@Test func restartingZeroesTheCountAndKeepsCounting() {
    var clock = AutoSaveClock()
    clock.update(counting: true, at: t0)
    clock.restart(at: t0 + 300)
    #expect(clock.elapsed(at: t0 + 300) == 0)
    #expect(clock.elapsed(at: t0 + 360) == 60)
}

@Test func restartingAStoppedClockLeavesItStopped() {
    var clock = AutoSaveClock()
    clock.update(counting: true, at: t0)
    clock.update(counting: false, at: t0 + 10)
    clock.restart(at: t0 + 20)
    #expect(clock.elapsed(at: t0 + 500) == 0)
}

@Test func autoSaveClockIgnoresARepeatedCountingState() {
    var clock = AutoSaveClock()
    clock.update(counting: true, at: t0)
    clock.update(counting: true, at: t0 + 30)
    #expect(clock.elapsed(at: t0 + 50) == 50)
}
