import Testing
import Foundation
@testable import PS1

private let t0: TimeInterval = 1_000_000

@Test func aStretchOfActivePlayIsBankedWhenItStops() {
    var clock = PlayClock()
    #expect(clock.update(running: true, paused: false, active: true, at: t0) == 0)
    #expect(clock.update(running: true, paused: true, active: true, at: t0 + 90) == 90)
}

@Test func repeatingTheCountingStateDoesNotRestartTheStretch() {
    var clock = PlayClock()
    _ = clock.update(running: true, paused: false, active: true, at: t0)
    _ = clock.update(running: true, paused: false, active: true, at: t0 + 30)
    #expect(clock.update(running: false, paused: false, active: true, at: t0 + 50) == 50)
}

/// The app keeps emulating behind other windows, so "running and unpaused"
/// is not enough: a game left open in the background counts nothing.
@Test func timeInTheBackgroundCountsNothing() {
    var clock = PlayClock()
    _ = clock.update(running: true, paused: false, active: true, at: t0)
    #expect(clock.update(running: true, paused: false, active: false, at: t0 + 10) == 10)
    #expect(clock.update(running: true, paused: false, active: false, at: t0 + 500) == 0)
    _ = clock.update(running: true, paused: false, active: true, at: t0 + 600)
    #expect(clock.update(running: false, paused: false, active: true, at: t0 + 620) == 20)
}

/// Paused AND in the background, then unpaused while still away: the clock
/// must stay stopped until BOTH conditions clear.
@Test func overlappingStopsKeepTheClockStoppedUntilAllClear() {
    var clock = PlayClock()
    _ = clock.update(running: true, paused: false, active: true, at: t0)
    #expect(clock.update(running: true, paused: true, active: true, at: t0 + 5) == 5)
    #expect(clock.update(running: true, paused: true, active: false, at: t0 + 6) == 0)
    #expect(clock.update(running: true, paused: false, active: false, at: t0 + 100) == 0)
    _ = clock.update(running: true, paused: false, active: true, at: t0 + 200)
    #expect(clock.update(running: true, paused: true, active: true, at: t0 + 207) == 7)
}

@Test func stoppingAClockThatNeverRanBanksNothing() {
    var clock = PlayClock()
    #expect(clock.update(running: false, paused: false, active: true, at: t0) == 0)
    #expect(clock.update(running: true, paused: true, active: true, at: t0 + 60) == 0)
}
