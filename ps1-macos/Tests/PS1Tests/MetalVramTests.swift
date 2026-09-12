import Testing
import Foundation
import Metal
import CoreGraphics
import ImageIO
import CPs1
@testable import PS1

/// Every Metal test in this suite returns early without a device rather than
/// failing: `MTLCreateSystemDefaultDevice()` is nil on a headless runner, and
/// a red suite there would be noise, not a signal.
private func makeVram() -> (MTLDevice, MTLCommandQueue, MetalVram)? {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return nil }
    return (device, queue, vram)
}

@Test func theRenderTextureStartsBlank() throws {
    guard let (_, _, vram) = makeVram() else { return }
    // A .private texture's initial contents are NOT specified by Metal, so
    // MetalVram clears at init. Without that, every fixture's frame 0 hash is
    // a coin flip on whatever the allocator handed back.
    #expect(vram.hash == Fnv1a.hash(vram: [UInt16](repeating: 0, count: 1024 * 512)))
}

@Test func aTextureRoundTripsThroughUploadReadbackAndHash() throws {
    guard let (_, _, vram) = makeVram() else { return }

    var pixels = [UInt16](repeating: 0, count: 1024 * 512)
    for i in 0..<pixels.count { pixels[i] = UInt16(truncatingIfNeeded: i &* 2654435761) }
    // The four corners specifically: a bytesPerRow or origin mistake in the
    // blit shows up there and can average out anywhere else.
    pixels[0] = 0x8001
    pixels[1023] = 0x7FFE
    pixels[511 * 1024] = 0x1234
    pixels[511 * 1024 + 1023] = 0xABCD

    vram.upload(pixels)
    let back = vram.readback()

    #expect(back.count == pixels.count)
    #expect(back == pixels)
    #expect(vram.hash == Fnv1a.hash(vram: pixels))
}

@Test func clearReturnsTheTextureToZero() throws {
    guard let (_, _, vram) = makeVram() else { return }
    vram.upload([UInt16](repeating: 0xFFFF, count: 1024 * 512))
    #expect(vram.hash != Fnv1a.hash(vram: [UInt16](repeating: 0, count: 1024 * 512)))
    vram.clear()
    #expect(vram.hash == Fnv1a.hash(vram: [UInt16](repeating: 0, count: 1024 * 512)))
}

@Test func theRasterizerVertexFunctionAndFillPipelineBuild() throws {
    guard let (device, _, vram) = makeVram() else { return }
    _ = vram
    let library = try Shaders.makeLibrary(device)
    #expect(library.makeFunction(name: "ps1_vertex") != nil)
    #expect(library.makeFunction(name: "ps1_fill_fragment") != nil)
    // The display shader must still be in the SAME library after the merge.
    #expect(library.makeFunction(name: "display_vertex") != nil)

    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = library.makeFunction(name: "ps1_vertex")
    desc.fragmentFunction = library.makeFunction(name: "ps1_fill_fragment")
    desc.colorAttachments[0].pixelFormat = .r16Uint
    // ps1_fill_fragment returns Ps1FragOut, so a descriptor with only
    // attachment 0 no longer builds — which is the pipeline-side half of the
    // "every fragment writes both" rule.
    desc.colorAttachments[1].pixelFormat = .rgba8Uint
    _ = try device.makeRenderPipelineState(descriptor: desc)
}

@Test func theInstanceRecordLayoutIsWhatTheShaderAsserts() {
    // The Metal side carries `static_assert(sizeof(Ps1PrimInstance) == 4 * 48)`.
    // This is the other half of that pair: a field added on one side only is
    // otherwise a silent shear of every instance in the buffer.
    #expect(MemoryLayout<Ps1PrimInstance>.stride == 4 * 48)
    #expect(MemoryLayout<Ps1PrimInstance>.size == 4 * 48)
}

@Test func vramDumpRoundTripsAndReportsTheFirstDifferences() throws {
    var a = [UInt16](repeating: 0, count: 1024 * 512)
    var b = a
    b[5] = 0x1234
    b[1024 + 7] = 0x8000

    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dump.vram")
    defer { try? FileManager.default.removeItem(at: url) }
    try VramDump.write(b, to: url)
    #expect(VramDump.read(url) == b)

    let diffs = VramDump.firstDifferences(a, b, limit: 4)
    #expect(diffs.count == 2)
    #expect(diffs[0].x == 5 && diffs[0].y == 0 && diffs[0].got == 0x1234)
    #expect(diffs[1].x == 7 && diffs[1].y == 1 && diffs[1].got == 0x8000)
    a[5] = 0x1234
    a[1024 + 7] = 0x8000
    #expect(VramDump.firstDifferences(a, b, limit: 4).isEmpty)
}

/// `report()` is what every later task actually calls on a mismatch, and what
/// Task 8's diagnostics will print — the round-trip test above exercises
/// `write`/`read`/`firstDifferences` individually but never this, the function
/// that composes them into the message a developer reads. Fixture names here
/// are unique nonce strings, not a real fixture name, since `report()` writes
/// into `zig-out/fixtures` and must not collide with an actual build artifact.
@Test func reportProducesARegenerationHintWhenNoReferenceDumpExists() throws {
    let fixture = "vramdump-report-test-noref-3f8a1c"
    let frame = 0
    let mine = VramDump.url(fixture: fixture, frame: frame, side: "metal")
    defer { try? FileManager.default.removeItem(at: mine) }

    var got = [UInt16](repeating: 0, count: 1024 * 512)
    got[9] = 0x2222

    let message = VramDump.report(fixture: fixture, frame: frame, got: got)

    #expect(message.contains("\(fixture) frame \(frame) diverged"))
    #expect(message.contains("stream-capture"))
    #expect(message.contains("--dump-frame=\(frame)"))
    #expect(message.contains("--filter=\(fixture)"))
    #expect(VramDump.read(mine) == got)
}

@Test func reportListsTheFirstDifferingPixelsWhenAReferenceDumpExists() throws {
    let fixture = "vramdump-report-test-withref-3f8a1c"
    let frame = 0
    let want = [UInt16](repeating: 0, count: 1024 * 512)
    var got = want
    got[5] = 0x1234
    got[1024 + 7] = 0x8000

    let reference = VramDump.url(fixture: fixture, frame: frame, side: "")
    let mine = VramDump.url(fixture: fixture, frame: frame, side: "metal")
    defer {
        try? FileManager.default.removeItem(at: reference)
        try? FileManager.default.removeItem(at: mine)
    }
    try VramDump.write(want, to: reference)

    let message = VramDump.report(fixture: fixture, frame: frame, got: got)

    #expect(message.contains("\(fixture) frame \(frame) diverged: 2 px"))
    #expect(message.contains(String(format: "  (%4d,%4d) want %04X got %04X", 5, 0, 0, 0x1234)))
    #expect(message.contains(String(format: "  (%4d,%4d) want %04X got %04X", 7, 1, 0, 0x8000)))
    #expect(VramDump.read(mine) == got)
}

// MARK: - Phase C: the native view of a scaled texture

private func makeScaledVram(_ scale: Int) -> MetalVram? {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { return nil }
    return MetalVram(device: device, queue: queue, scale: scale)
}

/// A deterministic native image with distinct values in the places a
/// replication or a downsample bug lands: the four corners and a diagonal.
private func nativePattern() -> [UInt16] {
    var p = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    for i in 0..<p.count { p[i] = UInt16(truncatingIfNeeded: i &* 2654435761) }
    p[0] = 0x8001
    p[MetalVram.nativeWidth - 1] = 0x7FFE
    p[(MetalVram.nativeHeight - 1) * MetalVram.nativeWidth] = 0x1234
    p[MetalVram.nativePixelCount - 1] = 0xABCD
    return p
}

@Test func theNativeConstantsDoNotFollowTheScale() throws {
    // Every Ps1PrimInstance field, every VramRect and every .vram dump is in
    // these units at EVERY internal resolution. If a scale ever leaks into
    // them, the encoder starts clamping in the wrong space and the oversized
    // refusal changes meaning.
    #expect(MetalVram.nativeWidth == 1024)
    #expect(MetalVram.nativeHeight == 512)
    #expect(MetalVram.nativePixelCount == 1024 * 512)

    guard let v = makeScaledVram(3) else { return }
    #expect(v.scale == 3)
    #expect(v.width == 3072)
    #expect(v.height == 1536)
    #expect(v.pixelCount == 3072 * 1536)
}

@Test func atOneXTheNativeViewIsTheWholeTexture() throws {
    guard let v = makeScaledVram(1) else { return }
    let pattern = nativePattern()
    v.uploadNative(pattern)
    #expect(v.readbackNative() == pattern)
    #expect(v.readback() == pattern)
    #expect(v.nativeHash == Fnv1a.hash(vram: pattern))
    #expect(v.nativeHash == v.hash)
}

@Test func uploadNativeReplicatesEveryPixelIntoAnNbyNBlock() throws {
    // scale 3, not 2 or 4: `px / s` and `px % s` are shifts and masks at every
    // power of two, so an odd scale is the only one that catches a bug written
    // as `>> log2(s)` or an assumption that s divides some extent.
    guard let v = makeScaledVram(3) else { return }
    let pattern = nativePattern()
    v.uploadNative(pattern)

    let full = v.readback()
    #expect(full.count == v.pixelCount)
    for (nx, ny) in [(0, 0), (1023, 0), (0, 511), (1023, 511), (17, 43)] {
        let want = pattern[ny * MetalVram.nativeWidth + nx]
        for sy in 0..<3 {
            for sx in 0..<3 {
                let i = (ny * 3 + sy) * v.width + (nx * 3 + sx)
                #expect(full[i] == want, "block (\(nx),\(ny)) subpixel (\(sx),\(sy))")
            }
        }
    }
}

@Test func readbackNativeRecoversTheImageUploadNativeReplicated() throws {
    for scale in [2, 3, 4, 8] {
        guard let v = makeScaledVram(scale) else { return }
        let pattern = nativePattern()
        v.uploadNative(pattern)
        #expect(v.readbackNative() == pattern, "scale \(scale)")
        #expect(v.nativeHash == Fnv1a.hash(vram: pattern), "scale \(scale)")
    }
}

@Test func readbackNativeTakesTheTopLeftSubtexelOfEachBlock() throws {
    // The downsample rule is "top-left subtexel", NOT an average and not the
    // last write to land in the block: at scale, subpixels other than the
    // top-left legitimately differ from their block's native value, and
    // discarding them is exactly what makes the exactness property a property.
    guard let v = makeScaledVram(2) else { return }
    var full = [UInt16](repeating: 0, count: v.pixelCount)
    for y in 0..<v.height {
        for x in 0..<v.width {
            // Top-left subpixels get 0x0101, every other subpixel 0xFFFF.
            full[y * v.width + x] = (x % 2 == 0 && y % 2 == 0) ? 0x0101 : 0xFFFF
        }
    }
    v.upload(full)
    #expect(v.readbackNative() == [UInt16](repeating: 0x0101,
                                           count: MetalVram.nativePixelCount))
}

@Test func aScaledTextureStartsBlankJustLikeAOneXOne() throws {
    guard let v = makeScaledVram(4) else { return }
    #expect(v.nativeHash == Fnv1a.hash(vram: [UInt16](repeating: 0,
                                                      count: MetalVram.nativePixelCount)))
    #expect(v.readback().allSatisfy { $0 == 0 })
}

@Test func vramImageWritesAPngWhoseChannelsAreTheFiveBitOnesExpanded() throws {
    // ABGR1555 -> 8 bits per channel is `(c << 3) | (c >> 2)`, so 31 becomes
    // 255 and 0 becomes 0 — a plain `<< 3` would top out at 248 and every
    // dumped image would be subtly dark, which is exactly the kind of thing
    // an eyeball gate would rationalize away.
    let pixels: [UInt16] = [
        0x001F,             // red   = 31
        0x03E0,             // green = 31
        0x7C00,             // blue  = 31
        0x8000,             // all channels 0, mask bit set (and ignored)
    ]
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vramimage-test.png")
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(VramImage.write(pixels, width: 2, height: 2, to: url))

    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        #expect(Bool(false), "the PNG did not read back")
        return
    }
    #expect(image.width == 2)
    #expect(image.height == 2)

    var back = [UInt8](repeating: 0, count: 2 * 2 * 4)
    back.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: 2, height: 2,
                            bitsPerComponent: 8, bytesPerRow: 8,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 2))
    }
    #expect(back[0] == 255 && back[1] == 0 && back[2] == 0)     // red
    #expect(back[4] == 0 && back[5] == 255 && back[6] == 0)     // green
    #expect(back[8] == 0 && back[9] == 0 && back[10] == 255)    // blue
    #expect(back[12] == 0 && back[13] == 0 && back[14] == 0)    // mask bit only
}

@Test func theSidecarStartsAbsentAndIsScaledLikeTheRenderTexture() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue, scale: 3) else { return }

    // The sidecar is a SECOND attachment on the same passes, so it must match
    // the render texture pixel for pixel at every internal resolution — a
    // mismatched size is a render-pass validation failure, not a wrong pixel.
    #expect(vram.sidecar.width == vram.width)
    #expect(vram.sidecar.height == vram.height)
    #expect(vram.sidecar.pixelFormat == .rgba8Uint)

    // Alpha is PRESENCE. A .private texture's initial contents are
    // unspecified, so a blank VRAM must come with a blank sidecar or the very
    // first frame displays whatever the allocator handed back.
    let side = vram.readbackSidecar()
    #expect(side.count == vram.pixelCount * 4)
    #expect(side.allSatisfy { $0 == 0 })

    let native = vram.readbackSidecarNative()
    #expect(native.count == MetalVram.nativePixelCount * 4)
    #expect(native.allSatisfy { $0 == 0 })
}

@Test func clearSidecarLeavesTheRenderTextureAlone() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    var pixels = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    pixels[7] = 0x1234
    vram.upload(pixels)

    // The invalidation path: the sidecar is cleared through a pass that LOADS
    // and STORES attachment 0. Clearing both would silently wipe VRAM on every
    // resync, which at 1x is every dropped frame.
    vram.clearSidecar()
    #expect(vram.readback()[7] == 0x1234)
    #expect(vram.readbackSidecar().allSatisfy { $0 == 0 })
}

// MARK: - Task 2: the coherence table

/// The coherence invariant, asserted directly: wherever the sidecar is
/// present, it is the eight-bit expansion of the VRAM pixel beside it.
///
/// This is the five-bit mirror invariant: `.off`, `.native` and `.scaled` all
/// share it, because none of them keeps more than five bits per channel
/// anywhere. `.trueColor` deliberately does not — it is pinned out below —
/// and every later test in this feature rests on this one holding for the
/// three modes that still quantise.
@Test func theSidecarMirrorsVramWhereverItIsPresent() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let r = try MetalRasterizer(vram: vram)
    // Pinned rather than inherited from `DitherSetting.defaultMode`: this
    // invariant is "the sidecar is the 8-bit expansion of 5-bit VRAM", which
    // `.trueColor` — now the shipped default — deliberately breaks by keeping
    // genuine 8-bit precision the expansion can't reproduce. That is the new
    // mode working, not this test's plumbing check failing.
    r.ditherMode = .native

    var area = Ps1GpuCommand()
    area.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
    area.opcode = 0xE4
    area.value = (511 << 10) | 1023

    var fill = Ps1GpuCommand()
    fill.kind = UInt8(PS1_GPU_FILL_RECT.rawValue)
    fill.x = 8; fill.y = 8; fill.w = 32; fill.h = 32
    fill.value = 0x2955          // low bits set in all three channels

    var tri = Ps1GpuCommand()
    tri.kind = UInt8(PS1_GPU_DRAW_SHADED_TRIANGLE.rawValue)
    tri.v.0 = Ps1GpuVertex(x: 100, y: 100, u: 0, v: 0, _pad: 0, color: 0x0020_4060)
    tri.v.1 = Ps1GpuVertex(x: 300, y: 110, u: 0, v: 0, _pad: 0, color: 0x00C0_8040)
    tri.v.2 = Ps1GpuVertex(x: 110, y: 260, u: 0, v: 0, _pad: 0, color: 0x0040_C080)

    r.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
    r.apply(area); r.apply(fill); r.apply(tri)
    r.endFrame()

    let pixels = vram.readback()
    let side = vram.readbackSidecar()
    var present = 0
    for i in 0..<pixels.count {
        let a = side[i * 4 + 3]
        if a == 0 {
            // Absent means nothing has drawn here, so VRAM is still blank.
            #expect(pixels[i] == 0, "pixel \(i) is drawn but absent from the sidecar")
            continue
        }
        #expect(a == 255, "alpha is presence: only 0 or 255 are legal")
        present += 1
        let p = pixels[i]
        let want = [UInt16(p & 0x1F), UInt16((p >> 5) & 0x1F), UInt16((p >> 10) & 0x1F)]
            .map { UInt8(($0 << 3) | ($0 >> 2)) }
        #expect(side[i * 4] == want[0] && side[i * 4 + 1] == want[1]
                && side[i * 4 + 2] == want[2],
                "pixel \(i) sidecar disagrees with the expansion of VRAM")
    }
    // Guards the whole loop against passing vacuously.
    //
    // CONTROLLER RULING R2 (supersedes the plan's `> 20_000`): this geometry
    // paints ~16,974 native pixels — the triangle is |cross| / 2 = 15,950 plus
    // the 32x32 fill's 1,024 — so 20,000 fails on correct code. 10,000 still
    // catches a blank frame, which is all this guard is for.
    #expect(present > 10_000)
}

/// GP0(A0). The payload is genuine 5551 from the game and no extra precision
/// exists, so the destination rect goes ABSENT — exactly the rect, which is
/// what per-pixel presence buys over a dirty rectangle.
@Test func theSidecarIsAbsentWhereVramWasUploaded() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let r = try MetalRasterizer(vram: vram)

    var fill = Ps1GpuCommand()
    fill.kind = UInt8(PS1_GPU_FILL_RECT.rawValue)
    fill.x = 0; fill.y = 0; fill.w = 64; fill.h = 64
    fill.value = 0x7FFF

    var setup = Ps1GpuCommand()
    setup.kind = UInt8(PS1_GPU_VRAM_WRITE_SETUP.rawValue)
    setup.x = 16; setup.y = 16; setup.w = 8; setup.h = 4

    var data = Ps1GpuCommand()
    data.kind = UInt8(PS1_GPU_VRAM_WRITE_DATA.rawValue)
    data.x = 0                      // payload word offset
    data.y = 16                     // 8 * 4 pixels / 2 per word

    let payload = [UInt32](repeating: 0x1234_1234, count: 16)
    payload.withUnsafeBufferPointer { buf in
        r.beginFrame(payload: buf)
        r.apply(fill); r.apply(setup); r.apply(data)
        r.endFrame()
    }

    let side = vram.readbackSidecar()
    func alpha(_ x: Int, _ y: Int) -> UInt8 { side[(y * 1024 + x) * 4 + 3] }
    // Inside the destination rect: absent.
    #expect(alpha(16, 16) == 0)
    #expect(alpha(23, 19) == 0)
    // One pixel outside it on each axis: still present from the fill.
    #expect(alpha(15, 16) == 255)
    #expect(alpha(24, 16) == 255)
    #expect(alpha(16, 15) == 255)
    #expect(alpha(16, 20) == 255)
}

/// GP0(80). The sidecar is copied alongside VRAM, alpha included, in the SAME
/// shader pass — so an absent source yields an absent destination and the
/// invariant carries itself with no extra rule.
@Test func aCopyCarriesPresenceWithThePixels() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let r = try MetalRasterizer(vram: vram)

    var fill = Ps1GpuCommand()
    fill.kind = UInt8(PS1_GPU_FILL_RECT.rawValue)
    fill.x = 0; fill.y = 0; fill.w = 32; fill.h = 32
    fill.value = 0x7FFF

    // Present -> absent region.
    var down = Ps1GpuCommand()
    down.kind = UInt8(PS1_GPU_COPY_RECT.rawValue)
    down.x = 0; down.y = 0          // source: the fill
    down.x2 = 200; down.y2 = 200    // destination: never drawn
    down.w = 16; down.h = 16

    // Absent -> present region.
    var up = Ps1GpuCommand()
    up.kind = UInt8(PS1_GPU_COPY_RECT.rawValue)
    up.x = 500; up.y = 400          // source: never drawn
    up.x2 = 0; up.y2 = 0            // destination: the fill
    up.w = 8; up.h = 8

    r.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
    r.apply(fill); r.apply(down); r.apply(up)
    r.endFrame()

    let side = vram.readbackSidecar()
    func alpha(_ x: Int, _ y: Int) -> UInt8 { side[(y * 1024 + x) * 4 + 3] }
    #expect(alpha(205, 205) == 255)   // carried presence into a blank region
    #expect(alpha(4, 4) == 0)         // carried absence over a drawn one
    #expect(alpha(20, 20) == 255)     // the rest of the fill is untouched
}

/// A resync from a software frame is 5551 with no extra precision in it, so
/// both upload paths invalidate the WHOLE sidecar. Keeping presence across one
/// would display last frame's eight-bit colour under this frame's picture.
@Test func bothUploadPathsInvalidateTheWholeSidecar() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue, scale: 2) else { return }
    let r = try MetalRasterizer(vram: vram)

    var fill = Ps1GpuCommand()
    fill.kind = UInt8(PS1_GPU_FILL_RECT.rawValue)
    fill.x = 0; fill.y = 0; fill.w = 64; fill.h = 64
    fill.value = 0x7FFF

    r.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
    r.apply(fill)
    r.endFrame()
    #expect(vram.readbackSidecar().contains { $0 == 255 })

    vram.uploadNative([UInt16](repeating: 0x1234, count: MetalVram.nativePixelCount))
    #expect(vram.readbackSidecar().allSatisfy { $0 == 0 })

    r.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
    r.apply(fill)
    r.endFrame()
    #expect(vram.readbackSidecar().contains { $0 == 255 })

    vram.upload([UInt16](repeating: 0x1234, count: vram.pixelCount))
    #expect(vram.readbackSidecar().allSatisfy { $0 == 0 })
}

@Test func theSidecarPngWriterRoundTripsItsBytes() throws {
    // Gate 3's only assertable half. The dump itself is eyeball-only, but a
    // writer that silently drops a channel would make the comparison it exists
    // for meaningless — and the PNG is the only place the eight-bit picture
    // is ever visible outside the app.
    let w = 4, h = 2
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    for i in 0..<(w * h) {
        bytes[i * 4] = UInt8(i * 8)
        bytes[i * 4 + 1] = UInt8(i * 8 + 1)
        bytes[i * 4 + 2] = UInt8(i * 8 + 2)
        bytes[i * 4 + 3] = i % 2 == 0 ? 255 : 0
    }
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sidecar-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(VramImage.writeSidecar(bytes, width: w, height: h, to: url))
    #expect(FileManager.default.fileExists(atPath: url.path))

    // The names must differ or the two dumps overwrite each other and the
    // comparison silently becomes one image against itself.
    let a = VramImage.url(fixture: "x", frame: 1, scale: 4)
    let b = VramImage.url(fixture: "x", frame: 1, scale: 4, sidecar: true)
    #expect(a != b)
}
