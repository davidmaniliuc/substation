import Testing
import Metal
import CPs1
@testable import PS1

/// Publishes one frame of records with no payload.
private func publish(_ q: StreamQueue, seq: UInt64, _ cmds: [Ps1GpuCommand]) {
    cmds.withUnsafeBufferPointer { buf in
        q.publish(seq: seq, records: buf.baseAddress!, recordCount: buf.count,
                  payload: nil, payloadCount: 0, complete: true)
    }
}

private func fillRect(x: Int32, y: Int32, w: Int32, h: Int32,
                      color: UInt32) -> Ps1GpuCommand {
    var c = Ps1GpuCommand()
    c.kind = UInt8(PS1_GPU_FILL_RECT.rawValue)
    c.x = x; c.y = y; c.w = w; c.h = h
    c.value = color
    return c
}

/// `copy_rect` reads x/y as the SOURCE and x2/y2 as the DESTINATION
/// (`command.zig:64`).
private func copyRect(srcX: Int32, srcY: Int32, dstX: Int32, dstY: Int32,
                      w: Int32, h: Int32) -> Ps1GpuCommand {
    var c = Ps1GpuCommand()
    c.kind = UInt8(PS1_GPU_COPY_RECT.rawValue)
    c.x = srcX; c.y = srcY; c.x2 = dstX; c.y2 = dstY; c.w = w; c.h = h
    return c
}

@Test func aLiveDrainAtScaleMatchesTheOneXReplayOfTheSameStream() throws {
    // Phase C's downsample-invariance property, re-run through the LIVE path
    // rather than the fixture harness -- the queue, the resync decision and
    // the persistent buffers are all in the picture here and are not in
    // MetalScaleHarness's.
    //
    // Fills and a VRAM->VRAM copy: both are exactly scale-invariant, and the
    // copy is the one read Phase C does NOT reduce to native (it carries
    // sub_x/sub_y so a blit preserves scaled detail), so it is worth having on
    // this path. Deliberately no Gouraud shading: dithering is on at 1x and
    // off above it BY DESIGN, so a dithered gradient legitimately differs.
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { return }

    func run(_ live: LiveRenderer) {
        let q = StreamQueue()
        q.clearResync()
        publish(q, seq: 1, [
            fillRect(x: 7, y: 11, w: 33, h: 17, color: 0x03E0),
            fillRect(x: 40, y: 11, w: 20, h: 20, color: 0x7C00),
        ])
        publish(q, seq: 2, [copyRect(srcX: 7, srcY: 11, dstX: 200, dstY: 300,
                                     w: 33, h: 17)])
        live.drain(from: q) { ([], 0) }
    }

    let one = try LiveRenderer(device: device, queue: queue, scale: 1)
    run(one)
    let reference = one.vram.readbackNative()
    #expect(reference.contains { $0 != 0 }, "the stream painted nothing")

    for scale in [2, 3, 4, 8] {
        let many = try LiveRenderer(device: device, queue: queue, scale: scale)
        run(many)
        #expect(many.vram.readbackNative() == reference, "scale \(scale)")
        #expect(many.lastExecutedSeq == 2)
    }
}

@Test func buildingTheCoordinatorRaisesAResyncOnTheRunnersQueue() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let runner = EmulatorRunner(core: try Ps1Core(), ring: AudioRing(capacity: 8192))
    // A scale change keeps the runner, and therefore keeps its queue, so
    // StreamQueue's `resync` default (true, for a FRESH queue) does not fire.
    // Clearing it here is what a running game looks like.
    runner.streams.clearResync()

    _ = MetalDisplayView.Coordinator(runner: runner, scale: 2)

    // A fresh MetalVram is a BLANK texture and a command stream is a set of
    // incremental mutations: applying the next queued stream to it leaves the
    // picture permanently wrong with nothing naming the cause. The request
    // belongs in `init` -- unmissable there, and a harmless no-op on the
    // disc-change path where the flag is already set.
    #expect(runner.streams.needsResync)
}

@Test func theCoordinatorBuildsItsRendererAtTheScaleItWasGiven() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let runner = EmulatorRunner(core: try Ps1Core(), ring: AudioRing(capacity: 8192))
    let coordinator = MetalDisplayView.Coordinator(runner: runner, scale: 3)
    // `params.scale` is read back off the renderer rather than off a second
    // stored copy, so the uniform cannot drift from the texture it addresses.
    #expect(coordinator.live.vram.scale == 3)
}
