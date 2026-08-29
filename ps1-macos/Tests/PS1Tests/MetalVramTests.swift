import Testing
import Foundation
import Metal
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
    _ = try device.makeRenderPipelineState(descriptor: desc)
}

@Test func theInstanceRecordLayoutIsWhatTheShaderAsserts() {
    // The Metal side carries `static_assert(sizeof(Ps1PrimInstance) == 4 * 42)`.
    // This is the other half of that pair: a field added on one side only is
    // otherwise a silent shear of every instance in the buffer.
    #expect(MemoryLayout<Ps1PrimInstance>.stride == 4 * 42)
    #expect(MemoryLayout<Ps1PrimInstance>.size == 4 * 42)
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
