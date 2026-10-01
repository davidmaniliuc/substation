import Testing
@testable import PS1

private let full = EmulatorRunner.waterMarks(speed: 4).low
private let empty = EmulatorRunner.waterMarks(speed: 1).low

@Test func aRingTheCoreKeepsFullStretchesAtTheTarget() {
    #expect(TempoControl.rate(target: 4, fill: full) == 4)
    #expect(TempoControl.rate(target: 4, fill: full * 2) == 4)
}

@Test func aDrainedRingFallsBackToRealTime() {
    // Real time is the one speed the core always sustains, so it is the
    // floor the fill recovers from — never below it, or fast-forward would
    // become slow motion.
    #expect(TempoControl.rate(target: 4, fill: empty) == 1)
    #expect(TempoControl.rate(target: 4, fill: 0) == 1)
}

@Test func theRateRisesWithTheFillBetweenTheTwo() {
    var last: Float = 0
    for step in 0...10 {
        let fill = empty + (full - empty) * step / 10
        let r = TempoControl.rate(target: 4, fill: fill)
        #expect(r >= last)
        #expect((1...4).contains(r))
        last = r
    }
}

@Test func smoothingGlidesTowardTheRateRatherThanJumping() {
    var t = TempoControl()
    t.reset(to: 1)
    let first = t.step(toward: 4)
    #expect(first > 1 && first < 4)
    for _ in 0..<500 { _ = t.step(toward: 4) }
    #expect(abs(t.step(toward: 4) - 4) < 0.01)
}
