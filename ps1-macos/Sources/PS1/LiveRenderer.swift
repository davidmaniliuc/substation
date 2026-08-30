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
    /// copy and the ordinary path never needs it.
    func drain(from queue: StreamQueue, shadow: () -> [UInt16]) {
        if queue.needsResync {
            // Discard BEFORE uploading: the shadow already accounts for every
            // frame in the backlog, so replaying any of them would apply the
            // same mutations twice.
            queue.discardAll()
            vram.uploadNative(shadow())
            queue.clearResync()
            return
        }
        queue.drain { slot in self.execute(slot) }
    }

    private func execute(_ slot: StreamSlot) {
        rasterizer.beginFrame(payload: UnsafeBufferPointer(
            start: slot.payload.baseAddress, count: slot.payloadCount))
        for i in 0..<slot.recordCount { rasterizer.apply(slot.records[i]) }
        rasterizer.endFrame()
        lastExecutedSeq = slot.seq
    }
}
