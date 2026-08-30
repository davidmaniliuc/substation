import Testing
@testable import PS1

/// The counter is fed a CUMULATIVE frame count and a monotonic timestamp, so
/// every case here is driven with synthetic numbers — no runner, no window, no
/// wall clock to make the suite flaky.

@Test func theFirstSampleOnlyLatchesAndReportsNothing() {
    var c = FpsCounter()
    c.sample(frames: 100, at: 10)
    #expect(c.value == nil)
}

@Test func aFullWindowReportsFramesPerSecond() {
    var c = FpsCounter()
    c.sample(frames: 0, at: 0)
    c.sample(frames: 30, at: 0.5)
    #expect(c.value == 60)
}

/// Sampling faster than the window must not publish a rate computed off a
/// sliver of time — two frames 1 ms apart is not 2000 fps.
@Test func aSampleInsideTheWindowIsIgnored() {
    var c = FpsCounter()
    c.sample(frames: 0, at: 0)
    c.sample(frames: 2, at: 0.001)
    #expect(c.value == nil)
}

/// The window closes on elapsed time, not on a fixed number of calls: the
/// early sample above must not have consumed the frames it saw.
@Test func framesFromAnIgnoredSampleStillCountTowardsTheNextWindow() {
    var c = FpsCounter()
    c.sample(frames: 0, at: 0)
    c.sample(frames: 2, at: 0.001)
    c.sample(frames: 30, at: 0.5)
    #expect(c.value == 60)
}

/// `eject()` installs a new `EmulatorRunner`, whose cumulative count starts at
/// zero again. Subtracting the old baseline would underflow `UInt64` outright.
@Test func aFrameCountThatGoesBackwardsReportsZeroRatherThanUnderflowing() {
    var c = FpsCounter()
    c.sample(frames: 1000, at: 0)
    c.sample(frames: 5, at: 0.5)
    #expect(c.value == 0)
}

/// A paused emulator produces no frames, and 0 is the honest reading — the
/// counter must not hold the last non-zero rate up.
@Test func aWindowWithNoFramesReportsZero() {
    var c = FpsCounter()
    c.sample(frames: 30, at: 0)
    c.sample(frames: 60, at: 0.5)
    #expect(c.value == 60)
    c.sample(frames: 60, at: 1.0)
    #expect(c.value == 0)
}

/// Each window is measured against the previous window's close, not against
/// the run's start, so a rate change is picked up rather than averaged away.
@Test func eachWindowMeasuresOnlyItsOwnFrames() {
    var c = FpsCounter()
    c.sample(frames: 0, at: 0)
    c.sample(frames: 30, at: 0.5)
    #expect(c.value == 60)
    c.sample(frames: 45, at: 1.0)
    #expect(c.value == 30)
}
