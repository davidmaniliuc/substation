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
        guard queue.needsResync else {
            queue.drain { slot in self.execute(slot) }
            return
        }

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

    /// Returns nil when the texture matches, or when `seq` is not the frame
    /// the texture currently holds.
    ///
    /// The seq check is what keeps this usable: without it, every frame the
    /// emulator runs ahead of the renderer reports a divergence, and the real
    /// ones drown.
    func diff(against shadow: [UInt16], seq: UInt64) -> String? {
        guard seq == lastExecutedSeq else { return nil }
        let got = vram.readbackNative()
        guard got.count == shadow.count else { return nil }

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
}
