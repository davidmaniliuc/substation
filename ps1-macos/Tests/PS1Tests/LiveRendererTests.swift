import Testing
import Metal
import CPs1
@testable import PS1

private func makeLive() throws -> (MTLDevice, MTLCommandQueue, LiveRenderer)? {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { return nil }
    return (device, queue, try LiveRenderer(device: device, queue: queue))
}

/// A fill of the whole 16x16 box at (x, y) with `color`. One record, no
/// payload — the smallest stream that provably changes VRAM.
private func fillStream(_ q: StreamQueue, seq: UInt64,
                        x: Int32, y: Int32, color: UInt32) {
    var cmd = Ps1GpuCommand()
    cmd.kind = UInt8(PS1_GPU_FILL_RECT.rawValue)
    cmd.x = x
    cmd.y = y
    cmd.w = 16
    cmd.h = 16
    cmd.value = color
    withUnsafePointer(to: &cmd) { p in
        q.publish(seq: seq, records: p, recordCount: 1,
                  payload: nil, payloadCount: 0, complete: true)
    }
}

@Test func drainExecutesEveryQueuedFrameInOrder() throws {
    guard let (_, _, live) = try makeLive() else { return }
    let q = StreamQueue()
    q.clearResync()

    // Two fills at the SAME place with different colours: only the later one
    // survives, so the final pixel proves the ORDER, not merely that both ran.
    fillStream(q, seq: 1, x: 0, y: 0, color: 0x001F)
    fillStream(q, seq: 2, x: 0, y: 0, color: 0x7C00)

    live.drain(from: q) { ([], 0) }

    let back = live.vram.readbackNative()
    #expect(back[0] == 0x7C00)
    #expect(live.lastExecutedSeq == 2)
}

@Test func drainSkippedFramesAreExecutedNotDropped() throws {
    guard let (_, _, live) = try makeLive() else { return }
    let q = StreamQueue()
    q.clearResync()

    // Distinct places: if drain took only the newest, the first fill's pixels
    // would never appear. A command stream is incremental, so execution may
    // never skip -- only presentation may.
    fillStream(q, seq: 1, x: 0, y: 0, color: 0x001F)
    fillStream(q, seq: 2, x: 64, y: 0, color: 0x7C00)

    live.drain(from: q) { ([], 0) }

    let back = live.vram.readbackNative()
    #expect(back[0] == 0x001F)
    #expect(back[64] == 0x7C00)
}

@Test func aFrameAlreadyFoldedIntoTheShadowIsDiscardedNotReplayed() throws {
    guard let (_, _, live) = try makeLive() else { return }
    let q = StreamQueue()
    q.clearResync()

    fillStream(q, seq: 1, x: 0, y: 0, color: 0x001F)
    q.requestResync()

    var shadow = [UInt16](repeating: 0, count: 1024 * 512)
    shadow[0] = 0x03E0
    shadow[1024 * 512 - 1] = 0x7FFF

    live.drain(from: q) { (shadow, 1) }

    let back = live.vram.readbackNative()
    // The upload happens BEFORE the drain, so this pixel separates the two
    // cases outright: discarded leaves the shadow's green, replayed paints
    // the fill's blue on top of it. Replaying is not a cosmetic waste --
    // VRAM->VRAM copies, semi-transparent blends and mask-bit draws are not
    // idempotent, so a second application is permanent corruption.
    #expect(back[0] == 0x03E0)
    #expect(back[1024 * 512 - 1] == 0x7FFF)
    #expect(q.pendingCount == 0)
    #expect(!q.needsResync)
}

@Test func aFrameNEWERThanTheShadowSurvivesTheResyncAndExecutes() throws {
    guard let (_, _, live) = try makeLive() else { return }
    let q = StreamQueue()
    q.clearResync()

    // The producer publishes VRAM before the stream, so a stream can be newer
    // than the newest shadow. Discarding the whole backlog loses its mutations
    // for good -- a command stream is incremental, and nothing replays it.
    fillStream(q, seq: 1, x: 0, y: 0, color: 0x001F)
    fillStream(q, seq: 2, x: 64, y: 0, color: 0x7C00)
    q.requestResync()

    var shadow = [UInt16](repeating: 0, count: 1024 * 512)
    shadow[0] = 0x03E0

    live.drain(from: q) { (shadow, 1) }

    let back = live.vram.readbackNative()
    #expect(back[0] == 0x03E0)
    #expect(back[64] == 0x7C00)
    #expect(live.lastExecutedSeq == 2)
    #expect(!q.needsResync)
}

@Test func theTextureAdoptsTheSampledFramesSeq() throws {
    guard let (_, _, live) = try makeLive() else { return }
    let q = StreamQueue()
    q.requestResync()

    // After an upload the texture IS that frame, so the oracle must be able to
    // compare against it. Leaving the seq behind makes every post-resync frame
    // an unexplained skip.
    live.drain(from: q) { ([UInt16](repeating: 0, count: 1024 * 512), 7) }
    #expect(live.lastExecutedSeq == 7)
}

@Test func aHoleBetweenTheShadowAndTheQueueLeavesTheResyncRaised() throws {
    guard let (_, _, live) = try makeLive() else { return }
    let q = StreamQueue()
    q.clearResync()

    // Frame 2 never reached the queue (a full ring drops it at the producer),
    // so what survives cannot be replayed onto a matching base. Execute it to
    // keep moving, but leave the flag up so the next draw adopts a shadow that
    // covers the hole.
    fillStream(q, seq: 3, x: 64, y: 0, color: 0x7C00)
    q.requestResync()

    live.drain(from: q) { ([UInt16](repeating: 0, count: 1024 * 512), 1) }

    #expect(live.vram.readbackNative()[64] == 0x7C00)
    #expect(q.needsResync)
}

@Test func aResyncRaisedWhileTheShadowIsSampledIsNotSwallowed() throws {
    guard let (_, _, live) = try makeLive() else { return }
    let q = StreamQueue()
    q.requestResync()

    // clearResync is a store, not a compare-and-clear. Clearing AFTER the
    // sample drops a request the producer raised in between -- and the frame
    // that raised it was never enqueued, so its mutations are lost for good.
    live.drain(from: q) {
        q.requestResync()
        return ([UInt16](repeating: 0, count: 1024 * 512), 1)
    }
    #expect(q.needsResync)
}

@Test func theShadowClosureIsNotCalledOnTheOrdinaryPath() throws {
    guard let (_, _, live) = try makeLive() else { return }
    let q = StreamQueue()
    q.clearResync()
    fillStream(q, seq: 1, x: 0, y: 0, color: 0x001F)

    // Building the shadow array is a 1 MB copy. It belongs behind a closure so
    // the common path never pays for it.
    var called = false
    live.drain(from: q) {
        called = true
        return ([UInt16](repeating: 0, count: 1024 * 512), 1)
    }
    #expect(!called)
}

@Test func theDiffIsSilentWhenTheTextureMatchesTheShadow() throws {
    guard let (_, _, live) = try makeLive() else { return }
    let q = StreamQueue()
    q.clearResync()
    fillStream(q, seq: 1, x: 0, y: 0, color: 0x001F)
    live.drain(from: q) { ([], 0) }

    var shadow = [UInt16](repeating: 0, count: 1024 * 512)
    for y in 0..<16 { for x in 0..<16 { shadow[y * 1024 + x] = 0x001F } }

    #expect(live.diff(against: shadow, seq: 1) == nil)
}

@Test func theDiffNamesTheFrameAndTheFirstDifferingPixel() throws {
    guard let (_, _, live) = try makeLive() else { return }
    let q = StreamQueue()
    q.clearResync()
    fillStream(q, seq: 3, x: 0, y: 0, color: 0x001F)
    live.drain(from: q) { ([], 0) }

    // Right shape, wrong colour: 256 pixels differ, the first at (0, 0).
    var shadow = [UInt16](repeating: 0, count: 1024 * 512)
    for y in 0..<16 { for x in 0..<16 { shadow[y * 1024 + x] = 0x7C00 } }

    let report = try #require(live.diff(against: shadow, seq: 3))
    #expect(report.contains("seq 3"))
    #expect(report.contains("256"))
    #expect(report.contains("(0, 0)"))
}

@Test func theDiffRefusesToCompareTwoDifferentInstants() throws {
    guard let (_, _, live) = try makeLive() else { return }
    let q = StreamQueue()
    q.clearResync()
    fillStream(q, seq: 1, x: 0, y: 0, color: 0x001F)
    live.drain(from: q) { ([], 0) }

    // The shadow is from frame 9; the texture holds frame 1. Comparing them
    // would report a divergence on every frame the emulator runs ahead, which
    // is exactly the noise that would make the oracle useless.
    #expect(live.diff(against: [UInt16](repeating: 0, count: 1024 * 512), seq: 9) == nil)
}
