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

    init(core: Ps1Core, ring: AudioRing) {
        self.core = core
        self.ring = ring
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

        while running.load(ordering: .acquiring) {
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

            core.setButtons(UInt16(truncatingIfNeeded: buttons.load(ordering: .acquiring)))
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
                streams.requestResync()
            }
        }
    }
}
