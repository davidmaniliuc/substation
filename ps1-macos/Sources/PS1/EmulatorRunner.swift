import Foundation
import Synchronization

/// Owns the emulator thread.
///
/// **Audio is the master clock.** A dropped audio buffer is far more audible
/// than a dropped video frame, and the audio device's clock is the only clock
/// here that cannot be made to wait — so the emulator runs flat out until the
/// ring is full, then blocks until the render callback has drained some.
///
/// Frame handoff is three slots and one atomic index: single producer, single
/// consumer, no lock. If the emulator runs slightly ahead of or behind the
/// display a frame repeats or is skipped, which is invisible at 59.94 against
/// 60 Hz and is correct on a 120 Hz ProMotion panel too.
final class EmulatorRunner: @unchecked Sendable {
    static let vramCount = 1024 * 512

    private let core: Ps1Core
    private let ring: AudioRing

    private var thread: Thread?
    private let running = Atomic<Bool>(false)
    private let paused = Atomic<Bool>(false)

    /// Triple buffer. `newest` is the only shared mutable index.
    private let slots: [UnsafeMutablePointer<UInt16>]
    private let newest = Atomic<Int>(0)
    private var displays: [Ps1Display]
    private let displayLock = NSLock()

    /// The GP0 command stream, frame by frame. Published AFTER the VRAM slot
    /// for the same frame — see `runLoop`.
    let streams = StreamQueue()
    private var seqs = [UInt64](repeating: 0, count: 3)
    private var frameSeq: UInt64 = 0

    /// `frameSeq` republished for readers off this thread — the FPS counter is
    /// the only one. A cumulative total rather than a rate: the reader sets its
    /// own cadence, and a poll it misses costs accuracy, never a frame.
    private let framesProduced = Atomic<UInt64>(0)

    /// Frames the emulator has completed since it started. Monotonic for the
    /// life of one runner; a new disc is a new runner and restarts at zero.
    var totalFramesProduced: UInt64 { framesProduced.load(ordering: .acquiring) }

    /// The producer sleeps on this when the ring is full; the audio callback
    /// signals it once the fill drops below `lowWater`.
    private let pacing = NSCondition()

    /// Signalled by the emulator thread as it exits, so `stop()` can join.
    private let finished = NSCondition()
    private var hasFinished = false

    private let highWater: Int
    private let lowWater: Int

    private let buttons = Atomic<UInt32>(0xFFFF)
    /// PGXP, pushed into the core from the emulator thread like the button
    /// mask beside it. Defaulting to false here rather than to the setting is
    /// deliberate: the runner is rebuilt per game while the setting outlives
    /// every disc, so `play()` re-applies it — the same trap and the same fix
    /// as `AudioOutput.setGain`.
    private let pgxp = Atomic<Bool>(false)

    /// The four PGXP sub-settings, pushed across the same way and defaulting
    /// the same way -- including `culling`, which ships ON but starts false
    /// here because `play()` is what re-applies the player's actual choice.
    ///
    /// `tolerance` travels as the bit pattern of its `Float`: `Synchronization`
    /// has no `Atomic<Float>`, and a lock for one scalar re-applied per frame
    /// would cost more than the conversion.
    private let pgxpCpu = Atomic<Bool>(false)
    private let pgxpCulling = Atomic<Bool>(false)
    private let pgxpVertexCache = Atomic<Bool>(false)
    private let pgxpTolerance = Atomic<UInt32>(Float(-1).bitPattern)

    /// A disc waiting to go in, applied by `runLoop` between frames.
    ///
    /// Not an `Atomic`: the payload is three `Data` values, and
    /// `Synchronization` has no conformance for those. It rides the
    /// `NSCondition` this class already holds for pacing rather than a second
    /// lock.
    ///
    /// This exists because `runLoop` owns the core. Calling `ps1_swap_disc`
    /// from a menu handler on the main actor would widen exactly the race
    /// `EmulatorViewModel.reset()` documents, and against a longer critical
    /// section than `ps1_reset`.
    private struct PendingSwap { let bin: Data; let cue: Data?; let sbi: Data? }
    private var pendingSwap: PendingSwap?

    /// The cards, and the newest image taken from each. `nil` in tests that
    /// build a runner without a store — there is then nothing to write to and
    /// the card is simply never persisted.
    private let cards: MemoryCardStore?
    /// `internal` rather than `private`: a test that cannot dirty a card over
    /// the ABI (`ps1_load_memcard` clears the dirty flag by design, so there
    /// is no way to stage one from Swift without actually running a game)
    /// stages an image here directly instead, then calls `writePendingCards`
    /// to cover that half of the composition.
    var pendingCards: [Int: Data] = [:]
    private var cardFlush = MemoryCardFlushPolicy()
    /// Sized from `MemoryCardStore.bytes`, not from `PS1_MEMCARD_BYTES`
    /// directly — deliberate, not an oversight. `Ps1Core.takeMemcard` already
    /// asserts `scratch.count == Int(PS1_MEMCARD_BYTES)`, so a genuine
    /// divergence between the two constants still fails loudly right here,
    /// at construction, with a clear cause. Sourcing the size from the C
    /// constant instead would move that same divergence's failure into
    /// `MemoryCardStore.write`'s own size guard — which discards a
    /// wrong-length image silently — trading a loud crash for silent total
    /// save loss on every write.
    private var cardScratch = [UInt8](repeating: 0, count: MemoryCardStore.bytes)

    /// Guards `pendingCards`/`cardScratch`/`cardFlush` across the two card
    /// methods. `serviceMemoryCards()` (emulator thread) and
    /// `flushMemoryCards()` (whichever thread calls `stop()`) are not
    /// ordered by anything else — `stop()`'s join has a one-second timeout
    /// and can fall through while `runLoop` is still mid-iteration, so
    /// without this lock the two could mutate the same `Dictionary` and take
    /// `&cardScratch` as `inout` concurrently: heap corruption and a dynamic-
    /// exclusivity trap, not merely a stale read. Held across each method's
    /// whole body, including the write to disk: the only lock taken inside is
    /// `MemoryCardStore`'s own private queue, always acquired in the same
    /// order, so there is no deadlock risk, and holding it across the write
    /// only costs anything during shutdown's rare timeout path — the
    /// alternative (copy the pending images out, release, then write) was
    /// considered and rejected as one more moving piece for a cost that is
    /// never paid in the common case.
    private let cardLock = NSLock()

    init(core: Ps1Core, ring: AudioRing, cards: MemoryCardStore? = nil) {
        self.core = core
        self.ring = ring
        self.cards = cards
        self.slots = (0..<3).map { _ in
            let p = UnsafeMutablePointer<UInt16>.allocate(capacity: Self.vramCount)
            p.initialize(repeating: 0, count: Self.vramCount)
            return p
        }
        self.displays = Array(repeating: Ps1Display(), count: 3)
        // About four emulated frames of stereo audio: 44100/60 * 2 ~= 1470
        // floats a frame.
        self.highWater = 1470 * 4
        self.lowWater = 1470 * 2
    }

    deinit {
        stop()
        for s in slots {
            s.deinitialize(count: Self.vramCount)
            s.deallocate()
        }
    }

    var isPaused: Bool {
        get { paused.load(ordering: .acquiring) }
        set {
            paused.store(newValue, ordering: .releasing)
            pacing.lock(); pacing.signal(); pacing.unlock()
        }
    }

    func setButtons(_ mask: UInt16) {
        buttons.store(UInt32(mask), ordering: .releasing)
    }

    func setPgxp(_ enabled: Bool) {
        pgxp.store(enabled, ordering: .releasing)
    }

    func setPgxpCpu(_ enabled: Bool) {
        pgxpCpu.store(enabled, ordering: .releasing)
    }

    func setPgxpCulling(_ enabled: Bool) {
        pgxpCulling.store(enabled, ordering: .releasing)
    }

    func setPgxpVertexCache(_ enabled: Bool) {
        pgxpVertexCache.store(enabled, ordering: .releasing)
    }

    func setPgxpTolerance(_ tolerance: Float) {
        pgxpTolerance.store(tolerance.bitPattern, ordering: .releasing)
    }

    func requestDiscSwap(bin: Data, cue: Data?, sbi: Data?) {
        pacing.lock()
        pendingSwap = PendingSwap(bin: bin, cue: cue, sbi: sbi)
        // The loop may be parked waiting on the audio high-water mark; wake it
        // so the swap lands now rather than at the next drain.
        pacing.signal()
        pacing.unlock()
    }

    private func takePendingSwap() -> PendingSwap? {
        pacing.lock()
        defer { pacing.unlock() }
        let swap = pendingSwap
        pendingSwap = nil
        return swap
    }

    /// Takes whatever the game has written and writes it out once the burst
    /// settles. Called from `runLoop` only — this thread owns the core.
    ///
    /// Taking BEFORE the frame rather than after is deliberate and costs
    /// nothing: a block committed in frame N is collected at the top of frame
    /// N+1, and this way the one call site also runs while the emulator is
    /// paused or waiting on the audio ring.
    ///
    /// Sitting above `runLoop`'s paused early-out is what makes that possible,
    /// and it is a real change to the loop's invariant, not a free lunch: the
    /// emulator thread now calls into the core on every paused iteration
    /// (`runLoop`'s 20 Hz poll), where a paused loop previously touched the
    /// core not at all. Code that reasons about a paused emulator thread as
    /// quiescent — see `EmulatorViewModel.reset()`'s comment — can no longer
    /// assume that.
    ///
    /// `internal` rather than `private` so a test can drive it directly —
    /// `runLoop` itself only starts on a real BIOS + disc, which the test
    /// suite deliberately does not depend on.
    func serviceMemoryCards() {
        guard let cards else { return }
        cardLock.lock()
        defer { cardLock.unlock() }

        let dirty = takeCards()

        guard cardFlush.shouldWrite(dirty: dirty,
                                    now: Date().timeIntervalSinceReferenceDate)
        else { return }

        writePendingCards(to: cards)
    }

    /// The unconditional flush, on eject and on quit. Called from `stop()`,
    /// after it attempts to join the emulator thread — but that join has a
    /// one-second timeout and falls through on expiry rather than blocking
    /// forever, so in that timeout case this can race a frame still in
    /// flight on that thread. `cardLock` keeps that race from corrupting
    /// `pendingCards`/`cardScratch`; it does not make the timeout path safe
    /// against the core itself — see `stop()`'s own doc comment for that
    /// pre-existing, unrelated hazard.
    ///
    /// `internal` rather than `private` for the same reason as
    /// `serviceMemoryCards()` above — a test needs to reach it without a real
    /// `runLoop`.
    func flushMemoryCards() {
        guard let cards else { return }
        cardLock.lock()
        defer { cardLock.unlock() }

        _ = takeCards()
        writePendingCards(to: cards)
        // Otherwise the policy's debounce state (`pendingSince`) stays set
        // past the point where everything staged has actually reached disk —
        // harmless today since the runner is discarded right after `stop()`,
        // but it leaves the policy inconsistent with what is on disk.
        cardFlush = MemoryCardFlushPolicy()
    }

    /// Drains every slot's newly dirtied card into `pendingCards`, returning
    /// whether any slot had new bytes. Caller must hold `cardLock`.
    private func takeCards() -> Bool {
        var dirty = false
        for slot in 0..<MemoryCardStore.slots {
            if let image = core.takeMemcard(slot: slot, into: &cardScratch) {
                pendingCards[slot] = image
                dirty = true
            }
        }
        return dirty
    }

    /// Writes every staged image to disk and clears the backlog. Caller must
    /// hold `cardLock`. `internal` rather than `private` for the same test
    /// seam as `pendingCards` above.
    func writePendingCards(to cards: MemoryCardStore) {
        for (slot, image) in pendingCards { cards.write(image, slot: slot) }
        pendingCards.removeAll()
    }

    /// Raised on a front-panel reset: `ps1_reset` rebuilds Bus and clears
    /// software VRAM, while the GPU texture still holds the old picture.
    func requestResync() { streams.requestResync() }

    func start() {
        guard !running.load(ordering: .acquiring) else { return }
        running.store(true, ordering: .releasing)

        finished.lock()
        hasFinished = false
        finished.unlock()

        let t = Thread { [weak self] in self?.runLoop() }
        t.name = "ps1.emulator"
        t.qualityOfService = .userInteractive
        t.stackSize = 1 << 20
        thread = t
        t.start()
    }

    /// Blocks until the emulator thread has actually left `runLoop`.
    ///
    /// This wait is load-bearing, not tidiness: the runner holds the only
    /// strong reference to `Ps1Core` that the thread uses, and the view model
    /// drops its own reference right after calling `stop()`. Returning while
    /// the thread is still mid-frame lets it call into a destroyed handle —
    /// a use-after-free that would surface as a random crash on eject.
    func stop() {
        guard running.load(ordering: .acquiring) else { return }
        running.store(false, ordering: .releasing)

        pacing.lock(); pacing.broadcast(); pacing.unlock()

        finished.lock()
        while !hasFinished {
            if !finished.wait(until: Date().addingTimeInterval(1.0)) { break }
        }
        finished.unlock()

        thread = nil

        // After the join attempt, never before: placing this any earlier
        // would race the state machine that raises the dirty flag on every
        // ordinary stop, not just the rare timeout one. The join above has a
        // one-second timeout and falls through on expiry, so this can still
        // land while `runLoop` is mid-frame on that rare path — see
        // `flushMemoryCards()`.
        flushMemoryCards()
    }

    /// Called from the audio callback once it has taken samples out of the ring.
    func signalAudioDrained() {
        guard ring.filled < lowWater else { return }
        pacing.lock(); pacing.signal(); pacing.unlock()
    }

    /// Renderer side. Hands the newest complete frame to `body`, with the
    /// sequence number it was produced under.
    ///
    /// The seq is what lets the divergence oracle compare like with like: it
    /// diffs only when the newest shadow is the very frame whose stream was
    /// last executed, rather than one the emulator has since run past.
    func withNewestFrame(_ body: (UnsafePointer<UInt16>, Ps1Display, UInt64) -> Void) {
        let i = newest.load(ordering: .acquiring)
        displayLock.lock()
        let d = displays[i]
        let s = seqs[i]
        displayLock.unlock()
        body(UnsafePointer(slots[i]), d, s)
    }

    private func runLoop() {
        defer {
            finished.lock()
            hasFinished = true
            finished.broadcast()
            finished.unlock()
        }

        var audioScratch = [Float](repeating: 0, count: 8192)
        /// What the core was last told about the vertex cache. A plain local
        /// rather than an `Atomic`: this thread is the only reader and the
        /// only writer, and the setting it shadows costs 83 MB to re-apply.
        var appliedVertexCache = false

        while running.load(ordering: .acquiring) {
            // Above the paused and ring-full early-outs on purpose: a player
            // who saves and immediately hits Pause would otherwise leave the
            // pending write parked until they resumed.
            serviceMemoryCards()

            if paused.load(ordering: .acquiring) {
                pacing.lock()
                if paused.load(ordering: .acquiring) && running.load(ordering: .acquiring) {
                    pacing.wait(until: Date().addingTimeInterval(0.05))
                }
                pacing.unlock()
                continue
            }

            // Audio is the clock: stop producing once the ring is full enough.
            if ring.filled > highWater {
                pacing.lock()
                if ring.filled > highWater && running.load(ordering: .acquiring) {
                    pacing.wait(until: Date().addingTimeInterval(0.05))
                }
                pacing.unlock()
                continue
            }

            if let swap = takePendingSwap() {
                // A failure here is not actionable from this thread and must
                // not take the emulator down: the core rolled the swap back and
                // the game is still running on the disc it had.
                try? core.swapDisc(bin: swap.bin, cue: swap.cue, sbi: swap.sbi)
            }

            core.setButtons(UInt16(truncatingIfNeeded: buttons.load(ordering: .acquiring)))
            // Re-applied every frame rather than on change, for the same
            // reason the button mask is: this thread owns the core, and a
            // latch would need a second flag to say the value moved.
            core.setPgxp(pgxp.load(ordering: .acquiring))
            core.setPgxpCpu(pgxpCpu.load(ordering: .acquiring))
            core.setPgxpCulling(pgxpCulling.load(ordering: .acquiring))
            core.setPgxpTolerance(Float(bitPattern: pgxpTolerance.load(ordering: .acquiring)))
            // Not re-applied blindly like the three above: the core's setter
            // allocates or frees 83 MB, and calling it every frame would churn
            // that allocation at 60 Hz. Only a CHANGE crosses.
            let wantCache = pgxpVertexCache.load(ordering: .acquiring)
            if wantCache != appliedVertexCache {
                core.setPgxpVertexCache(wantCache)
                appliedVertexCache = wantCache
            }
            core.runFrame()

            let produced = audioScratch.withUnsafeMutableBufferPointer { buf in
                core.readAudio(into: buf.baseAddress!, maxFloats: buf.count)
            }
            if produced > 0 {
                audioScratch.withUnsafeBufferPointer { buf in
                    _ = ring.write(buf.baseAddress!, count: produced)
                }
            }

            // VRAM FIRST, then the stream, both under the same seq.
            //
            // That order is load-bearing: it means a stream visible to the
            // consumer ALWAYS has its shadow already published, which is what
            // makes "discard the backlog and adopt the newest shadow" a
            // complete resync needing no per-slot reconciliation.
            frameSeq &+= 1
            framesProduced.store(frameSeq, ordering: .releasing)
            let next = (newest.load(ordering: .relaxed) + 1) % 3
            core.copyVRAM(into: slots[next])
            let d = core.display()
            displayLock.lock()
            displays[next] = d
            seqs[next] = frameSeq
            displayLock.unlock()
            newest.store(next, ordering: .releasing)

            // Once per runFrame, unconditionally: this is a drain, and a frame
            // left untaken stacks onto the next until the recorder overruns.
            let s = core.takeFrameStream()
            if let recs = s.records {
                streams.publish(seq: frameSeq,
                                records: recs, recordCount: s.record_count,
                                payload: s.payload, payloadCount: s.payload_count,
                                complete: s.complete != 0)
            } else {
                // A frame with no records to hand over is a frame whose
                // mutations are lost, not a texture that has come loose from
                // reality — the same class as a full ring, and answered the
                // same way.
                streams.noteDroppedFrame()
            }
        }
    }
}
