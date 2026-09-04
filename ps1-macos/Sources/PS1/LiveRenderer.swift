import Foundation
import Metal

/// The live command-stream renderer: drains the queue into the GPU's VRAM.
///
/// This is deliberately NOT the MTKView coordinator. A coordinator is not
/// reachable without a view, and the letterbox bug of 2026-08-20 is the
/// standing reminder of what that costs: it survived every compile-and-pipeline
/// test because only the pixels were ever wrong. The policy lives here so it is
/// testable offscreen; the coordinator keeps only MTKView plumbing.
final class LiveRenderer {
    let vram: MetalVram
    private let rasterizer: MetalRasterizer

    /// The seq of the most recently executed stream. Task 8's divergence
    /// oracle compares against the shadow only when this matches the newest
    /// published frame, so it never diffs two different instants.
    private(set) var lastExecutedSeq: UInt64 = 0

    /// A dropped frame's mutations are still missing from the texture.
    ///
    /// Set when a frame is lost above 1x, where the answer is to KEEP the
    /// scaled picture rather than adopt a native shadow, and cleared by the
    /// adoption that eventually settles it. It exists because "keep the
    /// picture" was mistaken for a complete answer: the frame's mutations are
    /// gone from the stream either way, so without a debt recorded here
    /// nothing ever puts them back.
    private var repairOwed = false

    var texture: MTLTexture { vram.texture }

    init(device: MTLDevice, queue: MTLCommandQueue, scale: Int = 1) throws {
        guard let vram = MetalVram(device: device, queue: queue, scale: scale) else {
            throw MetalRasterizer.Error.missingFunction("MetalVram")
        }
        self.vram = vram
        self.rasterizer = try MetalRasterizer(vram: vram)
        // The display pass shares this queue, so commit order orders the
        // rasterizer's writes before its sampling. Blocking the draw callback
        // on the GPU would cost a frame for nothing.
        self.rasterizer.synchronous = false
    }

    /// Reached on eject, which is where a run shorter than one report interval
    /// would otherwise end with no tally at all.
    deinit {
        if diffEnabled && diffChecked + diffSkipped > 0 { print(diffSummary) }
    }

    /// Executes everything queued, in order, then returns.
    ///
    /// `shadow` is a closure rather than a value because building it is a 1 MB
    /// copy and the ordinary path never needs it. It returns the sampled VRAM
    /// **and the seq it was published under**, from a SINGLE sample: the whole
    /// resync rule below is written against that seq, and two samples would not
    /// describe the same instant.
    ///
    /// The producer publishes VRAM before the stream, so a shadow sampled at
    /// seq `S` accounts for every frame up to and including `S` and for none
    /// above it. That is what makes both halves of a resync exact — see
    /// `StreamQueue.discardThrough`. "Adopt the newest shadow and discard the
    /// whole backlog" is sound only if the shadow is sampled before the queue
    /// is inspected, which no ordering here can guarantee across two threads.
    func drain(from queue: StreamQueue, shadow: () -> ([UInt16], UInt64)) {
        let hard = queue.needsResync
        // Read-and-clear, so a drop the producer records during this call is
        // seen next time rather than lost.
        let lostFrames = queue.takeDroppedFrames()

        // A dropped frame is answered DIFFERENTLY by scale, which is why the
        // decision lives here and not in the queue.
        //
        // At 1x adopting the shadow is exact — `uploadNative` IS `upload` —
        // and costs one upload, so a lost frame is genuinely repaired. That
        // exactness is what `PS1_LIVE_DIFF` at 1x is, and the default scale
        // must not opt out of the only oracle covering real games.
        //
        // Above 1x the shadow is a NATIVE image and adopting it replicates
        // each pixel N x N: the entire picture drops to nearest-neighbour 1x
        // until the game repaints it. On this machine a demanding game at 8x
        // costs more than a 60 Hz frame period to replay (silent-hill 28.5 ms
        // against 16.7 ms), so the ring fills over and over and the collapse
        // fires with it — the flicker between 8x and 1x. Keeping the scaled
        // texture is the cheaper error by far while the deficit lasts: what it
        // costs is a stale region rather than the whole image.
        //
        // This is the one place the "execution never skips a frame" rule is
        // relaxed, and it is narrower than it looks: a frame that never
        // reached the queue has NO records here to execute. The choice is not
        // whether to run it — nothing can — but whether to answer its absence
        // by throwing the scaled picture away.
        //
        // Deferred, though, and NOT abandoned. "Games clear and redraw every
        // frame, so it is corrected on the next one" is true of the display
        // area and false of the rest of VRAM: a texture page, a CLUT and a
        // VRAM->VRAM copy are written ONCE and sampled by every frame after,
        // and no later stream repeats them. FF7's main menu is the measured
        // case — the frame that opens it carries one 256x3 upload at
        // (256, 493), its palettes, and every frame after it carries 197
        // textured rectangles and zero payload words. Dropping that one frame
        // left the menu drawing its text through a stale CLUT for as long as
        // it stayed open, with nothing in the design that could ever repair
        // it.
        //
        // So a lost frame above 1x records a DEBT and keeps the picture, and
        // the debt is settled by the first drain that loses nothing. Settling
        // it while frames are still being lost would re-adopt a native shadow
        // on every draw of a sustained deficit, which is the 8x/1x flicker
        // under another name; waiting for the deficit to lift costs one frame
        // of nearest-neighbour picture at the end of a burst and repairs
        // everything the burst lost. A deficit that NEVER lifts is not
        // repaired at all — at that point no policy here both keeps the scale
        // and stays correct, and the remedy is a lower internal resolution.
        if lostFrames { repairOwed = true }
        // At 1x this reduces to "adopt on the drop", the previous behaviour
        // and the exact one: there `uploadNative` IS `upload`, so the debt is
        // never carried and `PS1_LIVE_DIFF`'s per-frame equality is unbroken.
        let repairDue = repairOwed && (vram.scale == 1 || !lostFrames)

        guard hard || repairDue else {
            queue.drain { slot in self.execute(slot) }
            return
        }
        repairOwed = false

        // Cleared BEFORE the sample, never after. `clearResync` is a store, not
        // a compare-and-clear, so a request raised by the producer after the
        // sample and cleared here would be swallowed — and the frame that
        // raised it was never enqueued, so its mutations would be lost for
        // good. Clearing first costs at worst one redundant resync.
        queue.clearResync()

        let (pixels, seq) = shadow()
        vram.uploadNative(pixels)
        // The texture now IS that frame, exactly. Adopting its seq is not
        // bookkeeping: it is the one moment the texture is known equal to a
        // specific shadow, and the oracle needs it to compare at all.
        lastExecutedSeq = seq

        let next = queue.discardThrough(seq: seq)
        // A hole between the adopted shadow and the oldest surviving stream
        // means frames were lost (a full ring drops them at the producer), so
        // what remains cannot be replayed onto a matching base. Execute it
        // anyway to keep moving, and leave the flag raised so the next draw
        // adopts a shadow that covers the hole.
        if let next, next != seq &+ 1 { queue.requestResync() }

        queue.drain { slot in self.execute(slot) }
    }

    private func execute(_ slot: StreamSlot) {
        rasterizer.beginFrame(payload: UnsafeBufferPointer(
            start: slot.payload.baseAddress, count: slot.payloadCount))
        for i in 0..<slot.recordCount { rasterizer.apply(slot.records[i]) }
        rasterizer.endFrame()
        lastExecutedSeq = slot.seq
    }

    /// The exploratory oracle: the render texture against the software shadow,
    /// per frame, on whatever is actually being played.
    ///
    /// The fixture corpus is eleven streams; five games booting and playing is
    /// coverage it does not have. This is how a divergence gets LOCALISED once
    /// it exists — the response is then to bank that window as a fixture with
    /// `zig build fixtures`, never to weaken a gate.
    ///
    /// An environment variable is fine here: the standing warning in CLAUDE.md
    /// is about the hosted TEST process, which sees neither an exported
    /// variable nor xcodebuild's TEST_RUNNER_ prefix. This switch is never read
    /// from a test.
    let diffEnabled = ProcessInfo.processInfo.environment["PS1_LIVE_DIFF"] == "1"

    /// How many frames the oracle actually compared, and how many it declined
    /// to.
    ///
    /// Counted because the absence of output is otherwise ambiguous: a run that
    /// skipped every frame prints exactly what a run in which every frame
    /// matched prints — nothing. Only the second is evidence, and the skip is
    /// not rare. The diff runs after `drain`, which blocks on the GPU, so any
    /// frame the emulator publishes in that window advances the newest seq past
    /// `lastExecutedSeq` and the oracle goes quiet for it.
    private(set) var diffChecked = 0
    private(set) var diffSkipped = 0

    var diffSummary: String {
        "PS1_LIVE_DIFF: checked \(diffChecked) frames, skipped \(diffSkipped)"
    }

    /// Decisions between running tallies. About five seconds at 60 Hz — often
    /// enough to see the ratio move against what is on screen, rare enough not
    /// to bury a divergence report.
    private static let diffReportInterval = 300

    /// Returns nil when the texture matches, or when `seq` is not the frame
    /// the texture currently holds.
    ///
    /// The seq check is what keeps this usable: without it, every frame the
    /// emulator runs ahead of the renderer reports a divergence, and the real
    /// ones drown. It is also what makes the counters necessary — see
    /// `diffChecked`.
    ///
    /// `shadow` is a closure for the same reason `drain`'s is, and it matters
    /// MORE here: a skip is the common case rather than the rare one, so
    /// building the 1 MB copy before the seq check spends it on exactly the
    /// frames that were never going to read it.
    func diff(seq: UInt64, shadow: () -> [UInt16]) -> String? {
        guard seq == lastExecutedSeq else { return skipped() }
        let shadow = shadow()
        // A wrong-sized shadow is counted as a skip too: it is one more way to
        // return nil without having compared anything.
        guard shadow.count == MetalVram.nativePixelCount else { return skipped() }
        diffChecked += 1
        reportTally()

        let got = vram.readbackNative()

        var differing = 0
        var first = -1
        for i in 0..<got.count where got[i] != shadow[i] {
            differing += 1
            if first < 0 { first = i }
        }
        guard differing > 0 else { return nil }

        let x = first % MetalVram.nativeWidth
        let y = first / MetalVram.nativeWidth
        return """
        PS1_LIVE_DIFF: seq \(seq) diverged — \(differing) pixels, \
        first at (\(x), \(y)) gpu=0x\(String(got[first], radix: 16, uppercase: true)) \
        shadow=0x\(String(shadow[first], radix: 16, uppercase: true))
        """
    }

    private func skipped() -> String? {
        diffSkipped += 1
        reportTally()
        return nil
    }

    private func reportTally() {
        guard diffEnabled,
              (diffChecked + diffSkipped) % Self.diffReportInterval == 0 else { return }
        print(diffSummary)
    }
}
