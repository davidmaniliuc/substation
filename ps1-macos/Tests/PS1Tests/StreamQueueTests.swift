import Testing
import CPs1
@testable import PS1

/// Builds a stream of `n` distinguishable records. `value` carries the index so
/// a drain can assert ORDER, which is the queue's whole job.
private func publish(_ q: StreamQueue, seq: UInt64, records n: Int,
                     payload words: Int = 0, complete: Bool = true) {
    var recs = [Ps1GpuCommand](repeating: Ps1GpuCommand(), count: max(n, 1))
    for i in 0..<n { recs[i].value = UInt32(seq) }
    var pay = [UInt32](repeating: UInt32(seq), count: max(words, 1))
    recs.withUnsafeBufferPointer { r in
        pay.withUnsafeBufferPointer { p in
            q.publish(seq: seq, records: r.baseAddress!, recordCount: n,
                      payload: p.baseAddress!, payloadCount: words,
                      complete: complete)
        }
    }
}

@Test func aQueueStartsAskingForAResync() {
    // The GPU texture's contents are unrelated to the shadow until the first
    // frame lands, so the very first draw callback must adopt the shadow
    // rather than assume a blank match.
    #expect(StreamQueue().needsResync)
}

@Test func drainHandsBackEveryPublishedFrameInOrder() {
    let q = StreamQueue()
    q.clearResync()
    publish(q, seq: 1, records: 3)
    publish(q, seq: 2, records: 5)

    var seen: [(UInt64, Int)] = []
    q.drain { seen.append(($0.seq, $0.recordCount)) }

    #expect(seen.count == 2)
    #expect(seen[0] == (1, 3))
    #expect(seen[1] == (2, 5))
    #expect(q.pendingCount == 0)
}

@Test func drainCopiesRecordsAndPayloadRatherThanAliasingThem() {
    let q = StreamQueue()
    q.clearResync()
    publish(q, seq: 7, records: 2, payload: 4)

    var records: [UInt32] = []
    var payload: [UInt32] = []
    q.drain { slot in
        for i in 0..<slot.recordCount { records.append(slot.records[i].value) }
        for i in 0..<slot.payloadCount { payload.append(slot.payload[i]) }
    }

    // The core reuses its recorder storage the instant emulation resumes, so a
    // slot that aliased it would hand the renderer the NEXT frame's bytes.
    #expect(records == [7, 7])
    #expect(payload == [7, 7, 7, 7])
}

@Test func aFullRingNotesADroppedFrameAndEnqueuesNothingFurther() {
    let q = StreamQueue()
    q.clearResync()
    for i in 0..<StreamQueue.capacity { publish(q, seq: UInt64(i), records: 1) }
    #expect(!q.hasDroppedFrames)
    #expect(q.pendingCount == StreamQueue.capacity)

    publish(q, seq: 99, records: 1)
    // A DROP, not a resync. The consumer's texture is still a faithful
    // picture of every frame it executed -- it is this frame's mutations that
    // are gone, and re-adopting a native shadow over it is what collapsed the
    // picture to 1x at scale.
    #expect(q.hasDroppedFrames)
    #expect(!q.needsResync)
    #expect(q.pendingCount == StreamQueue.capacity)
}

@Test func takingTheDroppedFlagClearsIt() {
    let q = StreamQueue()
    q.clearResync()
    #expect(!q.takeDroppedFrames())

    q.noteDroppedFrame()
    // Read-and-clear in one step, unlike clearResync: clearing this one in a
    // separate store would swallow a drop recorded between the two.
    #expect(q.takeDroppedFrames())
    #expect(!q.takeDroppedFrames())
}

@Test func anIncompleteStreamIsNeverEnqueued() {
    let q = StreamQueue()
    q.clearResync()
    publish(q, seq: 1, records: 3, complete: false)

    // A prefix applied to VRAM leaves it permanently out of step, so the
    // frame is dropped whole rather than partly applied.
    #expect(q.hasDroppedFrames)
    #expect(!q.needsResync)
    #expect(q.pendingCount == 0)
}

@Test func requestResyncSurvivesAnEmptyQueue() {
    let q = StreamQueue()
    q.clearResync()
    #expect(!q.needsResync)

    // A front-panel reset rebuilds Bus and clears software VRAM while the GPU
    // texture still holds the old picture. Nothing is queued at that instant,
    // so the flag is the only thing carrying the news.
    q.requestResync()
    #expect(q.needsResync)
    #expect(q.pendingCount == 0)
}

@Test func discardAllDropsTheBacklogWithoutExecutingIt() {
    let q = StreamQueue()
    q.clearResync()
    publish(q, seq: 1, records: 1)
    publish(q, seq: 2, records: 1)

    q.discardAll()

    var drained = 0
    q.drain { _ in drained += 1 }
    #expect(drained == 0)
    #expect(q.pendingCount == 0)
}

@Test func discardThroughDropsOnlyTheFramesAtOrBelowTheSeq() {
    let q = StreamQueue()
    q.clearResync()
    publish(q, seq: 1, records: 1)
    publish(q, seq: 2, records: 1)
    publish(q, seq: 3, records: 1)

    // A resync adopts ONE shadow, and that shadow accounts for every frame up
    // to its own seq and for none above it. Dropping more loses mutations;
    // dropping fewer applies them twice.
    q.discardThrough(seq: 2)

    var seen: [UInt64] = []
    q.drain { seen.append($0.seq) }
    #expect(seen == [3])
}

@Test func discardThroughNamesTheOldestSurvivingFrame() {
    let q = StreamQueue()
    q.clearResync()
    publish(q, seq: 5, records: 1)

    // The caller needs this to tell "the queue resumes exactly where the
    // shadow ends" from "frames were dropped in between", which is the
    // difference between a complete resync and one that has to be repeated.
    #expect(q.discardThrough(seq: 2) == 5)
    #expect(q.discardThrough(seq: 5) == nil)
}

@Test func aFrameLargerThanASlotIsRefusedRatherThanTruncated() {
    let q = StreamQueue()
    q.clearResync()
    publish(q, seq: 1, records: Int(PS1_GPU_MAX_RECORDS) + 1)

    // The core cannot produce one -- the recorder caps at the same number and
    // reports complete == 0 -- but a truncated slot would be a silent prefix,
    // which is the exact failure the complete flag exists to prevent.
    #expect(q.hasDroppedFrames)
    #expect(!q.needsResync)
    #expect(q.pendingCount == 0)
}

@Test func isFullOnlyOnceEverySlotIsTaken() {
    let q = StreamQueue()
    q.clearResync()
    for i in 0..<StreamQueue.capacity {
        #expect(!q.isFull)
        publish(q, seq: UInt64(i), records: 1)
    }
    #expect(q.isFull)
    q.drain { _ in }
    #expect(!q.isFull)
}

/// Feeds `bp` one observation per entry and returns its answers, because
/// `#expect` cannot call a mutating method.
private func waits(_ bp: inout StreamBackpressure, _ steps: [(full: Bool, now: UInt64)]) -> [Bool] {
    steps.map { bp.shouldWait(queueFull: $0.full, now: $0.now) }
}

@Test func theProducerWaitsForAFullQueueRatherThanDroppingAFrame() {
    var bp = StreamBackpressure()
    let t = StreamBackpressure.stallTimeoutNs
    // A renderer that is merely behind gets the time it needs: a dropped
    // frame is what forced the native-shadow repair that showed 1x above 1x.
    #expect(waits(&bp, [(false, 0), (true, 1_000), (true, 1_000 + t - 1)])
            == [false, true, true])
}

@Test func aRendererThatStopsDrainingIsGivenUpOnUntilItDrainsAgain() {
    var bp = StreamBackpressure()
    let t = StreamBackpressure.stallTimeoutNs
    // Past the timeout the renderer is not behind, it is gone (a hidden
    // window, a torn-down view), and waiting on it would freeze the game. It
    // stays given up on: a fresh timeout per frame would run the game at four
    // frames a second behind a hidden window. Draining once earns the wait
    // back.
    #expect(waits(&bp, [(true, 0), (true, t), (true, 10 * t), (false, 11 * t), (true, 12 * t)])
            == [true, false, false, false, true])
}

/// One speculative frame, `n` records each carrying `tag` in `value`.
private func speculate(_ q: StreamQueue, tag: UInt32, records n: Int = 1, complete: Bool = true) {
    var recs = [Ps1GpuCommand](repeating: Ps1GpuCommand(), count: max(n, 1))
    for i in 0..<n { recs[i].value = tag }
    var pay: UInt32 = tag
    recs.withUnsafeBufferPointer { r in
        q.appendSpeculative(records: r.baseAddress!, recordCount: n,
                            payload: &pay, payloadCount: 1, complete: complete)
    }
}

private func display(x: UInt32) -> Ps1Display {
    var d = Ps1Display()
    d.vram_x = x
    return d
}

@Test func aCommittedSpeculativeGroupIsHandedOverWholeWithItsDisplay() {
    let q = StreamQueue()
    q.beginSpeculativeGroup(after: 5)
    speculate(q, tag: 1)
    speculate(q, tag: 2, records: 3)
    q.commitSpeculativeGroup(display: display(x: 320))

    // Not until the real frame it runs ahead of has been executed.
    #expect(q.takeSpeculativeGroup(after: 4) == nil)
    let g = q.takeSpeculativeGroup(after: 5)
    #expect(g?.afterSeq == 5)
    #expect(g?.display.vram_x == 320)
    #expect(g?.frames.map(\.recordCount) == [1, 3])
    #expect(g?.frames[1].records[2].value == 2)
    #expect(g?.frames[0].payload[0] == 1)
    q.releaseSpeculativeGroup()
    // Taken once: the next drain has nothing until the next group.
    #expect(q.takeSpeculativeGroup(after: 5) == nil)
}

@Test func aNewerGroupReplacesOneNeverTaken() {
    let q = StreamQueue()
    q.beginSpeculativeGroup(after: 1)
    speculate(q, tag: 1)
    q.commitSpeculativeGroup(display: display(x: 0))
    q.beginSpeculativeGroup(after: 2)
    speculate(q, tag: 2)
    q.commitSpeculativeGroup(display: display(x: 0))

    let g = q.takeSpeculativeGroup(after: 2)
    #expect(g?.afterSeq == 2)
    #expect(g?.frames[0].records[0].value == 2)
}

@Test func aGroupHoldingAnIncompleteFrameIsNeverHandedOver() {
    let q = StreamQueue()
    q.beginSpeculativeGroup(after: 1)
    speculate(q, tag: 1)
    speculate(q, tag: 2, complete: false)
    q.commitSpeculativeGroup(display: display(x: 0))
    // A prefix replayed for display would leave the restore region wrong.
    #expect(q.takeSpeculativeGroup(after: 1) == nil)
}

@Test func theProducerNeverWritesIntoTheGroupBeingReplayed() {
    let q = StreamQueue()
    q.beginSpeculativeGroup(after: 1)
    speculate(q, tag: 1)
    q.commitSpeculativeGroup(display: display(x: 0))
    let replaying = q.takeSpeculativeGroup(after: 1)

    // Two more groups while the first is still being replayed.
    for tag: UInt32 in [2, 3] {
        q.beginSpeculativeGroup(after: UInt64(tag))
        speculate(q, tag: tag)
        q.commitSpeculativeGroup(display: display(x: 0))
    }
    #expect(replaying?.frames[0].records[0].value == 1)
    q.releaseSpeculativeGroup()
    #expect(q.takeSpeculativeGroup(after: 3)?.frames[0].records[0].value == 3)
}

@Test func moreSpeculativeFramesThanAGroupHoldsSpoilTheGroup() {
    let q = StreamQueue()
    q.beginSpeculativeGroup(after: 1)
    for tag in 0...UInt32(StreamQueue.maxSpeculativeFrames) { speculate(q, tag: tag) }
    q.commitSpeculativeGroup(display: display(x: 0))
    #expect(q.takeSpeculativeGroup(after: 1) == nil)
}

@Test func aGroupBehindTheExecutedFrameIsStaleAndDropped() {
    let q = StreamQueue()
    q.beginSpeculativeGroup(after: 1)
    speculate(q, tag: 1)
    q.commitSpeculativeGroup(display: display(x: 0))
    #expect(q.takeSpeculativeGroup(after: 2) == nil)
    #expect(q.takeSpeculativeGroup(after: 1) == nil)
}

@Test func aStagedFrameIsNotVisibleUntilCommitted() {
    let q = StreamQueue()
    q.clearResync()
    var cmd = Ps1GpuCommand()
    let staged = q.stage(seq: 1, records: &cmd, recordCount: 1, payload: nil, payloadCount: 0, complete: true)
    #expect(staged)
    #expect(q.pendingCount == 0)
    q.commitStaged()
    #expect(q.pendingCount == 1)
    q.commitStaged()   // nothing staged: no second frame
    #expect(q.pendingCount == 1)
}
