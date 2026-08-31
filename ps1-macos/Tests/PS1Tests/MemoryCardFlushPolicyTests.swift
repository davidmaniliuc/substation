import Testing
@testable import PS1

@Test func aCleanCardIsNeverWritten() {
    var policy = MemoryCardFlushPolicy()
    #expect(policy.shouldWrite(dirty: false, now: 0) == false)
    #expect(policy.shouldWrite(dirty: false, now: 100) == false)
    #expect(policy.hasPendingWrite == false)
}

@Test func aDirtyCardIsNotWrittenImmediately() {
    // A game committing a save writes ten or so blocks in a burst. Writing on
    // the first would put ten 128 KB files through the disk for one save.
    var policy = MemoryCardFlushPolicy()
    #expect(policy.shouldWrite(dirty: true, now: 0) == false)
    #expect(policy.hasPendingWrite)
}

@Test func aDirtyCardIsWrittenOnceItSettles() {
    var policy = MemoryCardFlushPolicy()
    _ = policy.shouldWrite(dirty: true, now: 0)
    #expect(policy.shouldWrite(dirty: false, now: 0.5) == false)
    #expect(policy.shouldWrite(dirty: false, now: 1.0) == true)
}

@Test func theSettleWindowRestartsOnEachNewWrite() {
    // The burst is the thing being waited out, so the clock restarts on every
    // block: one write at the end of the burst, not one part-way through it.
    var policy = MemoryCardFlushPolicy()
    _ = policy.shouldWrite(dirty: true, now: 0)
    #expect(policy.shouldWrite(dirty: true, now: 0.9) == false)
    #expect(policy.shouldWrite(dirty: false, now: 1.5) == false)
    #expect(policy.shouldWrite(dirty: false, now: 1.9) == true)
}

@Test func aWriteIsNotRepeatedWhileTheCardStaysClean() {
    var policy = MemoryCardFlushPolicy()
    _ = policy.shouldWrite(dirty: true, now: 0)
    #expect(policy.shouldWrite(dirty: false, now: 1.0) == true)
    #expect(policy.shouldWrite(dirty: false, now: 2.0) == false)
    #expect(policy.shouldWrite(dirty: false, now: 60.0) == false)
    #expect(policy.hasPendingWrite == false)
}

@Test func aNewWriteAfterAFlushStartsAFreshWindow() {
    var policy = MemoryCardFlushPolicy()
    _ = policy.shouldWrite(dirty: true, now: 0)
    #expect(policy.shouldWrite(dirty: false, now: 1.0) == true)
    #expect(policy.shouldWrite(dirty: true, now: 5.0) == false)
    #expect(policy.shouldWrite(dirty: false, now: 6.0) == true)
}
