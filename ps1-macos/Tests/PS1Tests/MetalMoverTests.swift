import Testing
import Foundation
import Metal
import CPs1
@testable import PS1

// MARK: - The extracted GP0(A0) transfer FSM
//
// ShadowVram and the Metal encoder both need this, and the spec's "no THIRD
// transcription" rule is the whole reason it is extracted rather than copied.
// ShadowVram's own tests in FixtureBridgeTests.swift are the regression net for
// the extraction itself.

@Test func aZeroExtentMeansTheWholeAxis() {
    #expect(VramTransfer.axisExtent(0, 1024) == 1024)
    #expect(VramTransfer.axisExtent(0, 512) == 512)
    #expect(VramTransfer.axisExtent(7, 1024) == 7)
}

@Test func eachWordIsTwoPixelsInRowMajorOrder() {
    var t = VramTransfer()
    t.setup(x: 10, y: 20, w: 3, h: 2)
    #expect(t.active)
    #expect(t.pixelCount == 6)

    let a = t.consume(0x2222_1111)
    #expect(a.count == 2)
    #expect(a[0] == (10, 20, 0x1111))
    #expect(a[1] == (11, 20, 0x2222))

    let b = t.consume(0x4444_3333)
    #expect(b[0] == (12, 20, 0x3333))
    #expect(b[1] == (10, 21, 0x4444))   // wrapped to the next row
}

// Renamed from the brief's `anOddSizedTransferDropsTheFinalHalfWord`: that name
// is already a top-level @Test func in FixtureBridgeTests.swift (pinning the
// SAME behaviour on ShadowVram), and two free functions with an identical name
// and signature in one module is an invalid redeclaration. Same assertions,
// disambiguated name, VramTransfer instead of ShadowVram as the subject.
@Test func vramTransferDropsTheFinalHalfWordOfAnOddSizedRun() {
    var t = VramTransfer()
    t.setup(x: 0, y: 0, w: 3, h: 1)
    _ = t.consume(0x2222_1111)
    let last = t.consume(0x4444_3333)
    #expect(last.count == 1)            // 0x4444 is dropped
    #expect(last[0] == (2, 0, 0x3333))
    #expect(t.active == false)
}

@Test func wordsAfterTheTransferEndsAreIgnored() {
    var t = VramTransfer()
    t.setup(x: 0, y: 0, w: 2, h: 1)
    _ = t.consume(0x2222_1111)
    #expect(t.active == false)
    #expect(t.consume(0xDEAD_BEEF).count == 0)
}

@Test func abortStopsTheTransferMidFlight() {
    var t = VramTransfer()
    t.setup(x: 0, y: 0, w: 8, h: 8)
    _ = t.consume(0)
    t.abort()
    #expect(t.active == false)
    #expect(t.consume(0xFFFF_FFFF).count == 0)
}

@Test func planReportsTheContiguousPixelRunAWordBatchCovers() {
    // The GPU path never walks pixel by pixel: it turns a whole payload run
    // into ONE instance whose fragment maps each pixel back to its word.
    var t = VramTransfer()
    t.setup(x: 4, y: 8, w: 5, h: 3)     // 15 pixels, 8 words
    let a = t.plan(words: 3)
    #expect(a?.first == 0 && a?.last == 5 && a?.consumed == 3)
    let b = t.plan(words: 100)          // clamped to the 5 words remaining
    #expect(b?.first == 6 && b?.last == 14 && b?.consumed == 5)
    #expect(t.active == false)
    #expect(t.plan(words: 1) == nil)
}

@Test func planAndConsumeAgreeOnWhereTheCursorEndsUp() {
    // The two APIs are the ONE place the shadow and the GPU encoder could
    // silently disagree, so pin them against each other directly.
    for (w, h) in [(3, 2), (5, 3), (1, 1), (7, 1), (2, 4)] {
        var byWord = VramTransfer()
        var byPlan = VramTransfer()
        byWord.setup(x: 0, y: 0, w: w, h: h)
        byPlan.setup(x: 0, y: 0, w: w, h: h)
        var pixels = 0
        while byWord.active { pixels += byWord.consume(0).count }
        var planned = 0
        while let r = byPlan.plan(words: 1) { planned += r.last - r.first + 1 }
        #expect(pixels == planned, "w=\(w) h=\(h)")
        #expect(pixels == w * h)
    }
}

// MARK: - The foundational risk (spec § The feedback loop)
//
// Everything downstream assumes a texture bound as [[color(0)]] can be read()
// at a DIFFERENT coordinate by the same draw, and that such a read sees the
// PRE-PASS contents. That is what a tile-based GPU gives: the tile being
// rendered lives in tile memory and the rest of the attachment stays in device
// memory until the store action runs. If this test ever fails, the named
// fallback is a second .private texture holding the last committed VRAM,
// refreshed by a blit at each pass boundary and sampled instead of the
// attachment — a substitution behind MetalRasterizer's interface, not a
// redesign.

@Test func aTextureBoundAsAttachmentCanBeReadAtAnotherCoordinate() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }

    var pixels = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    for i in 0..<64 { pixels[500 * 1024 + 100 + i] = UInt16(0x1000 + i) }
    vram.upload(pixels)

    let library = try Shaders.makeLibrary(device)
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = library.makeFunction(name: "ps1_vertex")
    desc.fragmentFunction = library.makeFunction(name: "ps1_copy_fragment")
    desc.colorAttachments[0].pixelFormat = .r16Uint
    let pipeline = try device.makeRenderPipelineState(descriptor: desc)

    // Copy (100,500)-(163,500) to (0,0)-(63,0), reading THE ATTACHMENT ITSELF
    // rather than a scratch snapshot. The source row was written by an earlier
    // command buffer, so the invariant holds and the read must be exact.
    var inst = Ps1PrimInstance()
    inst.kind = Int32(PS1_PRIM_COPY)
    inst.box_x0 = 0; inst.box_y0 = 0; inst.box_x1 = 63; inst.box_y1 = 0
    inst.x0 = 0; inst.y0 = 0
    inst.src_x = 100; inst.src_y = 500
    inst.w = 64; inst.h = 1

    let buffer = device.makeBuffer(bytes: &inst,
                                   length: MemoryLayout<Ps1PrimInstance>.stride,
                                   options: .storageModeShared)!

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = vram.texture
    pass.colorAttachments[0].loadAction = .load
    pass.colorAttachments[0].storeAction = .store

    guard let cmd = queue.makeCommandBuffer(),
          let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
    enc.setRenderPipelineState(pipeline)
    enc.setVertexBuffer(buffer, offset: 0, index: 0)
    enc.setFragmentBuffer(buffer, offset: 0, index: 0)
    enc.setFragmentTexture(vram.texture, index: 0)
    // ps1_vertex reads the raster uniforms; this encoder is hand-rolled and
    // does not go through MetalRasterizer.openPass, so it must bind them
    // itself. An unbound buffer argument is undefined, not zero.
    var uni = Ps1RasterUniforms(scale: 1, dither_mode: UInt32(PS1_DITHER_OFF))
    enc.setVertexBytes(&uni, length: MemoryLayout<Ps1RasterUniforms>.stride, index: 2)
    enc.setFragmentBytes(&uni, length: MemoryLayout<Ps1RasterUniforms>.stride, index: 2)
    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                       instanceCount: 1, baseInstance: 0)
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()

    let back = vram.readback()
    for i in 0..<64 {
        #expect(back[i] == UInt16(0x1000 + i), "attachment-as-read-source failed at \(i)")
    }
}

// MARK: - encodeUpload's payload-overrun guard
//
// Mirrors ShadowVram's PS1_GPU_VRAM_WRITE_DATA guard and its regression tests
// in FixtureBridgeTests.swift (anOddSizedTransferDropsTheFinalHalfWord et
// al.): a record's off/len pair comes straight off the wire and FixtureFile
// never validates it, so a malformed pair reaching `word_base + (pix >> 1)`
// in ps1_upload_fragment would read past payloadBuffer's real allocation — an
// out-of-bounds device-buffer read, not merely a wrong pixel, which is why
// this is worth pinning on the Metal path separately from the shadow's.

@Test func aVramWriteDataRecordThatOverrunsThePayloadUploadsNoInstanceAndMovesNoPixel() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let rasterizer = try MetalRasterizer(vram: vram)
    let before = vram.hash   // MetalVram starts cleared; this is the "nothing happened" baseline.

    // Payload holds 1 word (2 pixels). off=0, len=2 claims a SECOND word that
    // was never uploaded — off + len (2) > payloadCount (1).
    let words: [UInt32] = [0x2222_1111]
    words.withUnsafeBufferPointer { buf in
        rasterizer.beginFrame(payload: buf)

        var setup = Ps1GpuCommand()
        setup.kind = UInt8(PS1_GPU_VRAM_WRITE_SETUP.rawValue)
        setup.w = 2
        setup.h = 1
        rasterizer.apply(setup)

        var data = Ps1GpuCommand()
        data.kind = UInt8(PS1_GPU_VRAM_WRITE_DATA.rawValue)
        data.x = 0   // off
        data.y = 2   // len
        rasterizer.apply(data)

        rasterizer.endFrame()
    }

    #expect(vram.hash == before)
}

@Test func aVramWriteDataRecordLandingExactlyOnThePayloadEdgeStillUploads() throws {
    // The boundary the guard must NOT reject: off + len == payloadCount is a
    // legitimate, fully-backed transfer. Pinned so the guard above can never
    // be tightened by one word without this test going red.
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let rasterizer = try MetalRasterizer(vram: vram)

    let words: [UInt32] = [0xBBBB_AAAA, 0xDDDD_CCCC]   // 2 words = 4 pixels, exactly payloadCount
    words.withUnsafeBufferPointer { buf in
        rasterizer.beginFrame(payload: buf)

        var setup = Ps1GpuCommand()
        setup.kind = UInt8(PS1_GPU_VRAM_WRITE_SETUP.rawValue)
        setup.w = 2
        setup.h = 2
        rasterizer.apply(setup)

        var data = Ps1GpuCommand()
        data.kind = UInt8(PS1_GPU_VRAM_WRITE_DATA.rawValue)
        data.x = 0   // off
        data.y = 2   // len -- off + len == 2 == payloadCount
        rasterizer.apply(data)

        rasterizer.endFrame()
    }

    let back = vram.readback()
    #expect(back[0] == 0xAAAA)
    #expect(back[1] == 0xBBBB)
    #expect(back[MetalVram.nativeWidth] == 0xCCCC)
    #expect(back[MetalVram.nativeWidth + 1] == 0xDDDD)
}

// MARK: - The mover gate
//
// synthetic-movers is committed, so this runs on a fresh clone. Croc is the one
// real-game fixture at real payload sizes — 200 frames, 1,014 transfers, 50
// fills — and it is generated from games/, so it skips when absent.

@Test func replaysTheSyntheticMoverFixtureOnTheGpu() throws {
    guard let r = try MetalFixtureHarness.replay("synthetic-movers") else { return }
    #expect(r.framesChecked == 6)
    #expect(r.firstDivergence == nil, Comment(rawValue: r.message))
}

@Test(.enabled(if: FileManager.default.fileExists(
                    atPath: FixtureFile.url(named: "croc-legend-of-the-gobbos").path),
               "croc-legend-of-the-gobbos.p1fx is generated from games/ — run `zig build fixtures -Doptimize=ReleaseFast`"))
func replaysTheCrocMoverFixtureOnTheGpu() throws {
    guard let r = try MetalFixtureHarness.replay("croc-legend-of-the-gobbos") else { return }
    #expect(r.framesChecked == 200)
    #expect(r.firstDivergence == nil, Comment(rawValue: r.message))
}
