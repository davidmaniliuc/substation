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
/// wait. That is what keeps the emulator thread (which is audio-paced and runs
/// at .userInteractive QoS) off the renderer's clock entirely.
///
/// `head` and `tail` are monotonic counters rather than wrapped indices, so a
/// full ring is `tail - head == capacity` and no slot is wasted to distinguish
/// full from empty.
final class StreamQueue: @unchecked Sendable {
    /// Five frames, where DuckStation queues two: a renderer that falls behind
    /// now stops the producer (`StreamBackpressure`) instead of losing a frame,
    /// so depth no longer buys fewer drops, only a picture further behind the
    /// game's audio and input once the queue fills. It is this deep because
    /// the queue drains from the display callback, not a dedicated thread, so
    /// depth times the 60 Hz callback is a hard cap on emulated frames per
    /// second: three capped 4x speed at 180 fps, under NTSC's 240 and PAL's
    /// 200. Five clears both.
    static let capacity = 5

    private let slots: [StreamSlot]
    private let head = Atomic<UInt64>(0)
    private let tail = Atomic<UInt64>(0)
    /// Starts TRUE: the GPU texture's contents bear no relation to the shadow
    /// until the first frame lands, so the first draw callback adopts the
    /// shadow rather than assuming a blank match.
    ///
    /// This is the HARD condition ("the texture is not a picture of anything"),
    /// and its only remedy is adopting the shadow. Keep it distinct from
    /// `dropped`: they were one flag until the 8x flicker, and answering a
    /// lost frame with a full re-adoption is what put a 1x picture on screen.
    private let resync = Atomic<Bool>(true)

    /// One or more frames never reached the queue.
    ///
    /// The SOFT condition. The texture is still a faithful picture of every
    /// frame that did arrive; it is merely missing the mutations of the ones
    /// that did not, and those are gone from the stream for good either way.
    /// The consumer decides what to do about it, see `LiveRenderer.drain`,
    /// and the two answers differ by scale, which is knowledge this side of
    /// the queue does not have.
    private let dropped = Atomic<Bool>(false)

    /// The current consumer's claim: see `claimConsumer`.
    private let consumer = Atomic<UInt64>(0)

    /// Runahead's two group buffers and which of them is where; see
    /// `SpeculativeGroup`. A lock rather than atomics: three indices change
    /// together, a few times a frame, never around a copy.
    fileprivate var groups: [SpeculativeGroup] = []
    fileprivate let groupLock = NSLock()
    fileprivate var groupReady: Int?
    fileprivate var groupReading: Int?
    /// Producer-only.
    fileprivate var groupWriting: Int?
    /// Producer-only: a frame `stage` copied and `commitStaged` has not yet
    /// handed over.
    private var staged = false

    // TEMPORARY probe (2026-09-04), for the "8x is laggy on Crash Warped"
    // report. Counters rather than the flags above, because the question is
    // HOW OFTEN a frame is lost, not whether one ever was. Remove with the fix.
    let publishedCount = Atomic<UInt64>(0)
    let droppedCount = Atomic<UInt64>(0)

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

    var isFull: Bool { pendingCount >= Self.capacity }

    var needsResync: Bool { resync.load(ordering: .acquiring) }
    func requestResync() { resync.store(true, ordering: .releasing) }
    func clearResync() { resync.store(false, ordering: .releasing) }

    /// The queue has ONE consumer, and this is how a new one takes over.
    ///
    /// Claiming raises `resync` for the claimant's blank texture and supersedes
    /// every earlier claim. A superseded consumer must not drain at all. The
    /// flag is on the queue rather than the renderer, so an old view drawing
    /// once more after a rebuild consumed the new renderer's adoption. The new
    /// texture then took streams onto a blank VRAM and never got the texture
    /// pages back: every textured polygon sampled texel 0 and vanished.
    func claimConsumer() -> UInt64 {
        let id = consumer.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue
        requestResync()
        return id
    }

    func isConsumer(_ id: UInt64) -> Bool { consumer.load(ordering: .acquiring) == id }

    var hasDroppedFrames: Bool { dropped.load(ordering: .acquiring) }
    func noteDroppedFrame() {
        droppedCount.wrappingAdd(1, ordering: .relaxed)
        dropped.store(true, ordering: .releasing)
    }

    /// Reads and clears in one step, unlike `clearResync`.
    ///
    /// A plain store could swallow a drop the producer recorded between the
    /// read and the clear. `resync` gets away with that because clearing it
    /// early only costs a redundant re-adoption; clearing this one early would
    /// silently keep a stale picture with nothing left to say so.
    func takeDroppedFrames() -> Bool { dropped.exchange(false, ordering: .acquiringAndReleasing) }

    // MARK: Producer; emulator thread only

    /// Copies one frame into the ring.
    ///
    /// Three conditions lose the frame instead of enqueuing it, and all three
    /// lose it the same way (its mutations never reach the consumer), so the
    /// policy lives here rather than being restated at each call site: an
    /// incomplete stream (a prefix), a frame too large for a slot, and a full
    /// ring. A renderer that is merely behind never fills it, because the
    /// producer waits first (`StreamBackpressure`); a full ring here means one
    /// that stopped draining (a hidden window, a torn-down view).
    ///
    /// All three note a DROP, not a resync. None of them says anything about
    /// the consumer's texture, which is still exactly the frames it executed;
    /// conflating the two is what made a renderer that fell behind at 8x
    /// re-adopt a native shadow and collapse the picture to 1x.
    func publish(seq: UInt64,
                 records: UnsafePointer<Ps1GpuCommand>, recordCount: Int,
                 payload: UnsafePointer<UInt32>?, payloadCount: Int,
                 complete: Bool) {
        if stage(seq: seq, records: records, recordCount: recordCount,
                 payload: payload, payloadCount: payloadCount, complete: complete) {
            commitStaged()
        }
    }

    /// `publish`'s first half: copies the frame into the next slot without
    /// handing it over. Runahead stages the real frame, runs its speculative
    /// frames, commits their group and only then `commitStaged`s, so a drain
    /// never sees the real frame without the group that follows it, which
    /// would put a picture without runahead on screen for a frame. Returns
    /// false, having noted the drop, when `publish` would have dropped it.
    @discardableResult
    func stage(seq: UInt64,
               records: UnsafePointer<Ps1GpuCommand>, recordCount: Int,
               payload: UnsafePointer<UInt32>?, payloadCount: Int,
               complete: Bool) -> Bool {
        guard complete,
              recordCount <= Int(PS1_GPU_MAX_RECORDS),
              payloadCount <= Int(PS1_GPU_MAX_PAYLOAD_WORDS)
        else { noteDroppedFrame(); return false }

        let t = tail.load(ordering: .relaxed)
        guard t &- head.load(ordering: .acquiring) < UInt64(Self.capacity) else {
            noteDroppedFrame()
            return false
        }

        let slot = slots[Int(t % UInt64(Self.capacity))]
        slot.records.baseAddress!.update(from: records, count: recordCount)
        if let payload, payloadCount > 0 {
            slot.payload.baseAddress!.update(from: payload, count: payloadCount)
        }
        slot.recordCount = recordCount
        slot.payloadCount = payloadCount
        slot.seq = seq
        staged = true
        return true
    }

    /// Hands over the frame `stage` copied, if it copied one.
    func commitStaged() {
        guard staged else { return }
        staged = false
        // Releasing: everything written into the slot must be visible to the
        // consumer before it can observe the new tail.
        tail.store(tail.load(ordering: .relaxed) &+ 1, ordering: .releasing)
        publishedCount.wrappingAdd(1, ordering: .relaxed)
    }

    // MARK: Consumer; render thread only

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
    /// oldest frame still queued: nil when the ring is now empty.
    ///
    /// This is the resync's discard half, and the bound is the whole point.
    /// A resync adopts one sampled shadow, tagged with the seq it was published
    /// under; frames at or below that seq are ALREADY folded into it, and
    /// replaying one applies its mutations a second time: VRAM->VRAM copies,
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
    /// queued: `discardThrough` is the form that establishes that rather than
    /// assuming it.
    func discardAll() {
        head.store(tail.load(ordering: .acquiring), ordering: .releasing)
    }
}

/// Runahead's speculative frames: the picture N frames ahead of the real
/// timeline, replayed for display and then undone (`LiveRenderer`).
///
/// Only the NEWEST group can ever be shown: one followed by a real frame is
/// already stale. So they do not queue. Two buffers alternate, one the
/// consumer may be replaying and one the producer writes, and a group
/// committed before the last was taken simply replaces it. Each buffer is
/// `maxSpeculativeFrames` slots, allocated the first time runahead runs.
final class SpeculativeGroup {
    let slots: [StreamSlot]
    fileprivate(set) var count = 0
    fileprivate(set) var afterSeq: UInt64 = 0
    fileprivate(set) var display = Ps1Display()
    /// A frame was a prefix, or there were more frames than slots: a
    /// partial group would replay the wrong picture and restore the wrong
    /// region, so it is never handed over.
    fileprivate(set) var spoiled = false

    init() { slots = (0..<StreamQueue.maxSpeculativeFrames).map { _ in StreamSlot() } }

    var frames: ArraySlice<StreamSlot> { slots[0..<count] }
}

extension StreamQueue {
    /// The most runahead frames a group holds.
    static let maxSpeculativeFrames = 3

    // MARK: Producer; emulator thread only

    /// Starts a group that runs ahead of real frame `seq`, in whichever
    /// buffer the consumer is not replaying.
    func beginSpeculativeGroup(after seq: UInt64) {
        groupLock.lock()
        if groups.isEmpty { groups = [SpeculativeGroup(), SpeculativeGroup()] }
        let free = groupReading == 0 ? 1 : (groupReading == 1 ? 0 : (groupReady == 0 ? 1 : 0))
        // A committed group the consumer never took is superseded by this one.
        if groupReady == free { groupReady = nil }
        groupWriting = free
        groupLock.unlock()

        let g = groups[free]
        g.count = 0
        g.afterSeq = seq
        g.spoiled = false
    }

    func appendSpeculative(records: UnsafePointer<Ps1GpuCommand>, recordCount: Int,
                           payload: UnsafePointer<UInt32>?, payloadCount: Int,
                           complete: Bool) {
        guard let w = groupWriting else { return }
        let g = groups[w]
        guard complete, g.count < Self.maxSpeculativeFrames,
              recordCount <= Int(PS1_GPU_MAX_RECORDS),
              payloadCount <= Int(PS1_GPU_MAX_PAYLOAD_WORDS)
        else { g.spoiled = true; return }
        let slot = g.slots[g.count]
        slot.records.baseAddress!.update(from: records, count: recordCount)
        if let payload, payloadCount > 0 {
            slot.payload.baseAddress!.update(from: payload, count: payloadCount)
        }
        slot.recordCount = recordCount
        slot.payloadCount = payloadCount
        slot.seq = g.afterSeq
        g.count += 1
    }

    /// Hands the group over. `display` is its last frame's: a game that
    /// flips buffers shows the speculative picture somewhere else.
    func commitSpeculativeGroup(display: Ps1Display) {
        guard let w = groupWriting else { return }
        let g = groups[w]
        g.display = display
        groupLock.lock()
        groupWriting = nil
        groupReady = g.spoiled || g.count == 0 ? nil : w
        groupLock.unlock()
    }

    // MARK: Consumer; render thread only

    /// The newest committed group if it runs ahead of real frame `seq`,
    /// held for the consumer until `releaseSpeculativeGroup`. A group ahead
    /// of an older frame is stale and is dropped; one ahead of a newer frame
    /// waits for that frame to be executed.
    func takeSpeculativeGroup(after seq: UInt64) -> SpeculativeGroup? {
        groupLock.lock()
        defer { groupLock.unlock() }
        guard let r = groupReady else { return nil }
        let after = groups[r].afterSeq
        if after > seq { return nil }
        groupReady = nil
        guard after == seq else { return nil }
        groupReading = r
        return groups[r]
    }

    func releaseSpeculativeGroup() {
        groupLock.lock()
        groupReading = nil
        groupLock.unlock()
    }
}

/// The producer's flow control: whether the emulator thread should wait for
/// the renderer before running another frame.
///
/// Waiting is DuckStation's answer to a renderer that falls behind (its core
/// thread blocks once `gpu_max_queued_frames` are queued, and spins on a full
/// command FIFO), and it replaced dropping the frame here. A dropped frame's
/// mutations are gone, and above 1x the only repair is adopting the native
/// shadow, which put a 1x picture on screen every time the renderer hitched.
/// Waiting costs the game time instead: a stall longer than the audio ring's
/// slack is heard as a gap.
///
/// A renderer that stops draining altogether is a different case and must not
/// be waited on, or the game freezes behind a hidden window. Past
/// `stallTimeoutNs` of a continuously full queue it is given up on, and stays
/// given up on, so frames drop as they used to, until it drains once.
struct StreamBackpressure {
    /// Longer than the worst renderer stall measured live at 4x (draw
    /// callbacks averaging 170 ms over a second), short enough that hiding
    /// the window costs one audible hitch rather than a frozen game.
    static let stallTimeoutNs: UInt64 = 250_000_000

    private var fullSince: UInt64?
    private var stalled = false

    mutating func shouldWait(queueFull: Bool, now: UInt64) -> Bool {
        guard queueFull else {
            fullSince = nil
            stalled = false
            return false
        }
        if stalled { return false }
        guard let since = fullSince else {
            fullSince = now
            return true
        }
        if now &- since < Self.stallTimeoutNs { return true }
        stalled = true
        return false
    }
}
