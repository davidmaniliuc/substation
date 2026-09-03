import Foundation
import Synchronization
import CPs1

/// One frame's recorded GP0 stream, COPIED out of the core.
///
/// The copy is not defensive tidiness: `ps1_take_frame_stream` returns slices
/// into the recorder's own storage, valid only until the next `ps1_run_frame`
/// (contract rule 4). Aliasing them would hand the renderer whichever frame the
/// emulator happened to be building when it looked.
///
/// Sized at the recorder's own capacities so the producer never allocates and
/// never truncates. About 6.8 MB per slot.
final class StreamSlot {
    let records: UnsafeMutableBufferPointer<Ps1GpuCommand>
    let payload: UnsafeMutableBufferPointer<UInt32>
    var recordCount = 0
    var payloadCount = 0
    var seq: UInt64 = 0

    init() {
        records = .allocate(capacity: Int(PS1_GPU_MAX_RECORDS))
        records.initialize(repeating: Ps1GpuCommand())
        payload = .allocate(capacity: Int(PS1_GPU_MAX_PAYLOAD_WORDS))
        payload.initialize(repeating: 0)
    }

    deinit {
        records.deinitialize()
        records.deallocate()
        payload.deinitialize()
        payload.deallocate()
    }
}

/// Single-producer / single-consumer ring carrying frames from the emulator
/// thread to the render thread.
///
/// The producer's whole cost is one bounded memcpy: no allocation, no lock, no
/// wait. That is what keeps the emulator thread — which is audio-paced and runs
/// at .userInteractive QoS — off the renderer's clock entirely.
///
/// `head` and `tail` are monotonic counters rather than wrapped indices, so a
/// full ring is `tail - head == capacity` and no slot is wasted to distinguish
/// full from empty.
final class StreamQueue: @unchecked Sendable {
    /// Eight frames is about 133 ms of slack at 60 Hz, and 67 MB of slots.
    /// The price of never touching an allocator on the emulator thread, and
    /// the slack is what absorbs a TRANSIENT overrun — a compositor hitch, a
    /// heavy frame — without losing a frame at all. It does nothing for a
    /// SUSTAINED deficit: at 8x a demanding game costs more than a frame
    /// period to replay, and no depth fixes that, which is why `dropped`
    /// below has to degrade well rather than merely rarely.
    static let capacity = 8

    private let slots: [StreamSlot]
    private let head = Atomic<UInt64>(0)
    private let tail = Atomic<UInt64>(0)
    /// Starts TRUE: the GPU texture's contents bear no relation to the shadow
    /// until the first frame lands, so the first draw callback adopts the
    /// shadow rather than assuming a blank match.
    ///
    /// This is the HARD condition — "the texture is not a picture of anything"
    /// — and its only remedy is adopting the shadow. Keep it distinct from
    /// `dropped`: they were one flag until the 8x flicker, and answering a
    /// lost frame with a full re-adoption is what put a 1x picture on screen.
    private let resync = Atomic<Bool>(true)

    /// One or more frames never reached the queue.
    ///
    /// The SOFT condition. The texture is still a faithful picture of every
    /// frame that did arrive; it is merely missing the mutations of the ones
    /// that did not, and those are gone from the stream for good either way.
    /// The consumer decides what to do about it — see `LiveRenderer.drain` —
    /// and the two answers differ by scale, which is knowledge this side of
    /// the queue does not have.
    private let dropped = Atomic<Bool>(false)

    init() {
        slots = (0..<Self.capacity).map { _ in StreamSlot() }
    }

    /// Loads `head` before `tail`, not the other way round: `head <= tail` is
    /// a standing invariant and `tail` only grows, so a head-then-tail read
    /// always subtracts a smaller-or-equal value from a larger-or-equal one.
    /// Reading `tail` first lets a concurrent drain move `head` past it,
    /// which underflows the `&-` and traps in `Int(_:)`.
    var pendingCount: Int {
        let h = head.load(ordering: .acquiring)
        return Int(tail.load(ordering: .acquiring) &- h)
    }

    var needsResync: Bool { resync.load(ordering: .acquiring) }
    func requestResync() { resync.store(true, ordering: .releasing) }
    func clearResync() { resync.store(false, ordering: .releasing) }

    var hasDroppedFrames: Bool { dropped.load(ordering: .acquiring) }
    func noteDroppedFrame() { dropped.store(true, ordering: .releasing) }

    /// Reads and clears in one step, unlike `clearResync`.
    ///
    /// A plain store could swallow a drop the producer recorded between the
    /// read and the clear. `resync` gets away with that because clearing it
    /// early only costs a redundant re-adoption; clearing this one early would
    /// silently keep a stale picture with nothing left to say so.
    func takeDroppedFrames() -> Bool { dropped.exchange(false, ordering: .acquiringAndReleasing) }

    // MARK: Producer — emulator thread only

    /// Copies one frame into the ring.
    ///
    /// Three conditions lose the frame instead of enqueuing it, and all three
    /// lose it the same way — its mutations never reach the consumer — so the
    /// policy lives here rather than being restated at each call site: an
    /// incomplete stream (a prefix), a frame too large for a slot, and a full
    /// ring (the renderer has fallen behind, or the window is backgrounded).
    ///
    /// All three note a DROP, not a resync. None of them says anything about
    /// the consumer's texture, which is still exactly the frames it executed;
    /// conflating the two is what made a renderer that fell behind at 8x
    /// re-adopt a native shadow and collapse the picture to 1x.
    func publish(seq: UInt64,
                 records: UnsafePointer<Ps1GpuCommand>, recordCount: Int,
                 payload: UnsafePointer<UInt32>?, payloadCount: Int,
                 complete: Bool) {
        guard complete,
              recordCount <= Int(PS1_GPU_MAX_RECORDS),
              payloadCount <= Int(PS1_GPU_MAX_PAYLOAD_WORDS)
        else { noteDroppedFrame(); return }

        let t = tail.load(ordering: .relaxed)
        guard t &- head.load(ordering: .acquiring) < UInt64(Self.capacity) else {
            noteDroppedFrame()
            return
        }

        let slot = slots[Int(t % UInt64(Self.capacity))]
        slot.records.baseAddress!.update(from: records, count: recordCount)
        if let payload, payloadCount > 0 {
            slot.payload.baseAddress!.update(from: payload, count: payloadCount)
        }
        slot.recordCount = recordCount
        slot.payloadCount = payloadCount
        slot.seq = seq

        // Releasing: everything written above must be visible to the consumer
        // before it can observe the new tail.
        tail.store(t &+ 1, ordering: .releasing)
    }

    // MARK: Consumer — render thread only

    /// Hands every queued slot to `body`, oldest first.
    ///
    /// Drain-ALL, not take-newest: a command stream is a set of incremental
    /// mutations, so a skipped frame is lost permanently. Only PRESENTATION is
    /// allowed to skip.
    func drain(_ body: (StreamSlot) -> Void) {
        var h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        while h < t {
            body(slots[Int(h % UInt64(Self.capacity))])
            h &+= 1
            head.store(h, ordering: .releasing)
        }
    }

    /// Drops every queued frame at or below `seq`, and returns the seq of the
    /// oldest frame still queued — nil when the ring is now empty.
    ///
    /// This is the resync's discard half, and the bound is the whole point.
    /// A resync adopts one sampled shadow, tagged with the seq it was published
    /// under; frames at or below that seq are ALREADY folded into it, and
    /// replaying one applies its mutations a second time — VRAM->VRAM copies,
    /// semi-transparent blends and mask-bit draws are not idempotent, so that
    /// is permanent corruption rather than a transient. Frames above it are not
    /// in the shadow at all, and dropping them loses their mutations for good.
    /// The producer publishes VRAM before the stream, so a queued stream can be
    /// newer than the newest shadow but never older than its own.
    @discardableResult
    func discardThrough(seq: UInt64) -> UInt64? {
        var h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        while h < t {
            // Safe to read: the producer writes only the slot at `tail`, and it
            // cannot reach an unconsumed `h` without the ring exceeding
            // `capacity`, which `publish` refuses.
            let s = slots[Int(h % UInt64(Self.capacity))].seq
            if s > seq { return s }
            h &+= 1
            head.store(h, ordering: .releasing)
        }
        return nil
    }

    /// Drops the whole backlog without executing it. Only ever correct as half
    /// of a resync whose shadow is known to be at least as new as everything
    /// queued — `discardThrough` is the form that establishes that rather than
    /// assuming it.
    func discardAll() {
        head.store(tail.load(ordering: .acquiring), ordering: .releasing)
    }
}
