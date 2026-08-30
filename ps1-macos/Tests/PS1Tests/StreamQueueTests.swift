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

@Test func aFullRingRequestsAResyncAndEnqueuesNothingFurther() {
    let q = StreamQueue()
    q.clearResync()
    for i in 0..<StreamQueue.capacity { publish(q, seq: UInt64(i), records: 1) }
    #expect(!q.needsResync)
    #expect(q.pendingCount == StreamQueue.capacity)

    publish(q, seq: 99, records: 1)
    #expect(q.needsResync)
    #expect(q.pendingCount == StreamQueue.capacity)
}

@Test func anIncompleteStreamIsNeverEnqueued() {
    let q = StreamQueue()
    q.clearResync()
    publish(q, seq: 1, records: 3, complete: false)

    // A prefix applied to VRAM leaves it permanently out of step, so the frame
    // is dropped and the renderer resyncs from the shadow instead.
    #expect(q.needsResync)
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

@Test func aFrameLargerThanASlotIsRefusedRatherThanTruncated() {
    let q = StreamQueue()
    q.clearResync()
    publish(q, seq: 1, records: Int(PS1_GPU_MAX_RECORDS) + 1)

    // The core cannot produce one -- the recorder caps at the same number and
    // reports complete == 0 -- but a truncated slot would be a silent prefix,
    // which is the exact failure the complete flag exists to prevent.
    #expect(q.needsResync)
    #expect(q.pendingCount == 0)
}
