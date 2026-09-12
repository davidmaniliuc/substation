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
    // this path. Deliberately no Gouraud shading: the shipped dither mode is
    // `.scaled`, which samples the pattern per subtexel, so a dithered
    // gradient legitimately differs. `.native` is the mode that would hold
    // here, and `aNativeDitheredReplayIsStillDownsampleInvariant` is where
    // that is pinned, on the fixture corpus rather than on two fills.
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

    _ = MetalDisplayView.Coordinator(runner: runner, scale: 2, ditherMode: .scaled)

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
    let coordinator = MetalDisplayView.Coordinator(runner: runner, scale: 3,
                                                   ditherMode: .native)
    // `params.scale` is read back off the renderer rather than off a second
    // stored copy, so the uniform cannot drift from the texture it addresses.
    #expect(coordinator.live.vram.scale == 3)
    // The dither mode is a runtime uniform, so unlike the scale it does NOT
    // rebuild the coordinator -- `updateNSView` assigns it. It is still passed
    // through `init` so the FIRST frame drawn carries the player's setting
    // rather than the rasterizer's own default.
    #expect(coordinator.live.ditherMode == .native)
}

// MARK: - Falling behind

/// A frame the producer could not enqueue at all — a full ring, or a stream
/// too large for a slot — is a LOST frame, not a texture that has come loose
/// from reality. Those are two different conditions with two different
/// remedies, and answering the first with the second is what put a 1x picture
/// on screen at 8x.
///
/// The shadow is a NATIVE image, so adopting it replicates each pixel N x N
/// into the scaled texture. That is the correct base at 1x, where it is also
/// exact; above 1x it is the whole picture collapsing to nearest-neighbour 1x
/// for as long as it takes the game to redraw. Measured on this machine, a
/// real game at 8x costs more than a 60 Hz frame period to replay
/// (silent-hill 28.5 ms, budget 16.7 ms), so the ring fills routinely and the
/// collapse fires over and over — the reported flicker between 8x and 1x.
@Test func aDroppedFrameKeepsTheScaledPictureRatherThanCollapsingToOneX() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { return }

    for scale in [2, 3, 4, 8] {
        let live = try LiveRenderer(device: device, queue: queue, scale: scale)
        let q = StreamQueue()
        q.clearResync()

        // A picture on the texture, executed the ordinary way.
        publish(q, seq: 1, [fillRect(x: 0, y: 0, w: 16, h: 16, color: 0x001F)])
        live.drain(from: q) { ([], 0) }
        #expect(live.vram.readbackNative()[0] == 0x001F, "scale \(scale)")

        // Frame 2 never reaches the queue. `complete: false` is the cheapest
        // of the three ways that happens and the only one that enqueues
        // nothing else, so the assertion below is about the drop alone.
        var lost = Ps1GpuCommand()
        withUnsafePointer(to: &lost) { p in
            q.publish(seq: 2, records: p, recordCount: 1,
                      payload: nil, payloadCount: 0, complete: false)
        }

        var shadowBuilt = false
        live.drain(from: q) {
            shadowBuilt = true
            return ([UInt16](repeating: 0x7C00, count: 1024 * 512), 2)
        }

        // Still ours, not the shadow's red.
        #expect(live.vram.readbackNative()[0] == 0x001F, "scale \(scale)")
        // And the 1 MB copy was never even built: above 1x there is nothing
        // the shadow can be used for on this path.
        #expect(!shadowBuilt, "scale \(scale)")
    }
}

/// The 1x control, and it is not symmetry for its own sake: at scale 1
/// `uploadNative` IS `upload`, so adopting the shadow costs one upload and is
/// byte-exact. That exactness is what `PS1_LIVE_DIFF` at 1x is, and the
/// default scale must not opt out of the only oracle that covers real games.
@Test func aDroppedFrameStillAdoptsTheShadowAtOneX() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { return }
    let live = try LiveRenderer(device: device, queue: queue, scale: 1)
    let q = StreamQueue()
    q.clearResync()

    publish(q, seq: 1, [fillRect(x: 0, y: 0, w: 16, h: 16, color: 0x001F)])
    live.drain(from: q) { ([], 0) }

    var lost = Ps1GpuCommand()
    withUnsafePointer(to: &lost) { p in
        q.publish(seq: 2, records: p, recordCount: 1,
                  payload: nil, payloadCount: 0, complete: false)
    }

    live.drain(from: q) { ([UInt16](repeating: 0x7C00, count: 1024 * 512), 2) }

    #expect(live.vram.readbackNative()[0] == 0x7C00)
    #expect(live.lastExecutedSeq == 2)
}

/// The condition the skip must NOT swallow. A rebuilt `MetalVram` is a BLANK
/// texture — a scale change, a disc change, the first coordinator — and there
/// is no picture there to preserve. Skipping here leaves the window black
/// until something happens to repaint all of VRAM, which for a game with a
/// static backdrop is never.
@Test func aHardResyncStillAdoptsTheShadowAtEveryScale() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { return }

    for scale in [1, 2, 3, 4, 8] {
        let live = try LiveRenderer(device: device, queue: queue, scale: scale)
        let q = StreamQueue()
        q.requestResync()

        var shadow = [UInt16](repeating: 0, count: 1024 * 512)
        shadow[0] = 0x03E0

        live.drain(from: q) { (shadow, 9) }

        #expect(live.vram.readbackNative()[0] == 0x03E0, "scale \(scale)")
        #expect(live.lastExecutedSeq == 9, "scale \(scale)")
    }
}

/// Keeping the scaled picture across a dropped frame is only half a policy:
/// the other half is that the frame's mutations have to be REPAIRED, and
/// until this test there was nothing that ever did.
///
/// "Games clear and redraw every frame, so it is corrected on the next one"
/// is true of the display area and false of everything else in VRAM. A
/// texture page, a CLUT and a VRAM->VRAM copy are uploaded ONCE and sampled
/// by every frame after; nothing repeats them, so a frame lost while one is
/// in flight is lost for the rest of the scene. Measured on FF7's main menu
/// (`ff7-menu.p1fx`): the frame that opens it carries a single 256x3 upload
/// at (256, 493) — the menu's palettes — and every frame after it carries 197
/// textured rectangles and ZERO payload words. Lose that one frame and the
/// menu draws its text through a stale CLUT for as long as it stays open,
/// which is the reported "text doesn't appear".
///
/// So the repair is DEFERRED, not abandoned: skipped while frames are still
/// being lost — re-adopting into a sustained deficit is the 8x/1x flicker
/// coming straight back — and taken on the first drain that loses none.
@Test func aLostFramesMutationIsRepairedOnceTheDropsStop() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { return }

    for scale in [2, 3, 4, 8] {
        let live = try LiveRenderer(device: device, queue: queue, scale: scale)
        let q = StreamQueue()
        q.clearResync()

        publish(q, seq: 1, [fillRect(x: 0, y: 0, w: 16, h: 16, color: 0x001F)])
        live.drain(from: q) { ([], 0) }

        // The frame that never arrived. Stands for FF7's palette upload: its
        // mutation appears in no later stream, so executing what follows can
        // never put it back.
        var lost = Ps1GpuCommand()
        withUnsafePointer(to: &lost) { p in
            q.publish(seq: 2, records: p, recordCount: 1,
                      payload: nil, payloadCount: 0, complete: false)
        }

        var shadow = [UInt16](repeating: 0, count: 1024 * 512)
        shadow[0] = 0x7C00

        // The drain that observes the drop keeps the scaled picture, exactly
        // as before — the flicker fix is not being undone here.
        var built = 0
        live.drain(from: q) { built += 1; return (shadow, 2) }
        #expect(live.vram.readbackNative()[0] == 0x001F, "scale \(scale)")
        #expect(built == 0, "scale \(scale)")

        // The next one loses nothing, so the debt is settled.
        live.drain(from: q) { built += 1; return (shadow, 2) }
        #expect(built == 1, "scale \(scale)")
        #expect(live.vram.readbackNative()[0] == 0x7C00, "scale \(scale)")
        #expect(live.lastExecutedSeq == 2, "scale \(scale)")

        // And settled ONCE: a debt that never clears re-adopts a native
        // shadow every frame, which is the collapse under another name.
        live.drain(from: q) { built += 1; return (shadow, 2) }
        #expect(built == 1, "scale \(scale)")
    }
}
