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

    live.drain(from: q) { [] }

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

    live.drain(from: q) { [] }

    let back = live.vram.readbackNative()
    #expect(back[0] == 0x001F)
    #expect(back[64] == 0x7C00)
}

@Test func aResyncRequestDiscardsTheBacklogAndAdoptsTheShadow() throws {
    guard let (_, _, live) = try makeLive() else { return }
    let q = StreamQueue()
    q.clearResync()

    fillStream(q, seq: 1, x: 0, y: 0, color: 0x001F)
    q.requestResync()

    var shadow = [UInt16](repeating: 0, count: 1024 * 512)
    shadow[0] = 0x03E0
    shadow[1024 * 512 - 1] = 0x7FFF

    live.drain(from: q) { shadow }

    let back = live.vram.readbackNative()
    // The queued fill must NOT have run: the shadow already accounts for it.
    #expect(back[0] == 0x03E0)
    #expect(back[1024 * 512 - 1] == 0x7FFF)
    #expect(q.pendingCount == 0)
    #expect(!q.needsResync)
}

@Test func theShadowClosureIsNotCalledOnTheOrdinaryPath() throws {
    guard let (_, _, live) = try makeLive() else { return }
    let q = StreamQueue()
    q.clearResync()
    fillStream(q, seq: 1, x: 0, y: 0, color: 0x001F)

    // Building the shadow array is a 1 MB copy. It belongs behind a closure so
    // the common path never pays for it.
    var called = false
    live.drain(from: q) { called = true; return [UInt16](repeating: 0, count: 1024 * 512) }
    #expect(!called)
}
