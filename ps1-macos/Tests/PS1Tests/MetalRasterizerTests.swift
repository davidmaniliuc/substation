import Testing
import Foundation
import Metal
import CPs1
@testable import PS1

// The gate ladder. `synthetic-primitives` puts one feature group per frame, in
// the order documented in the Phase B plan; each task below extends the prefix
// this replays. A hash is CUMULATIVE, so bounding the replay is what keeps a
// later frame's mismatch from masking an earlier feature that already works.

@Test func flatTrianglesMatchTheSoftwareRasterizer() throws {
    guard let r = try MetalFixtureHarness.replay("synthetic-primitives", upTo: 1) else { return }
    #expect(r.firstDivergence == nil, Comment(rawValue: r.message))
}

// The one assumption underneath every blend in the corpus. Metal orders
// framebuffer reads by primitive submission order, instances included; a
// raster order group orders accesses to DEVICE memory, which this backend
// never does. If this ever fails, add [[raster_order_group(0)]] to the
// [[color(0)]] input — do NOT reorder the encoder to work around it.
@Test func overlappingInstancesBlendInSubmissionOrder() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let renderer = try MetalRasterizer(vram: vram)

    var env = Ps1GpuCommand()
    env.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
    env.opcode = 0xE4
    env.value = (511 << 10) | 1023

    // Blend mode 1 is B + F. Three identical opaque-then-additive triangles
    // over the same pixel must land at 3x, not 1x, and not in some other order.
    var mode = Ps1GpuCommand()
    mode.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
    mode.opcode = 0xE1
    mode.value = 1 << 5

    func tri(_ transparent: Bool, _ colour: UInt32) -> Ps1GpuCommand {
        var c = Ps1GpuCommand()
        c.kind = UInt8(PS1_GPU_DRAW_TRIANGLE.rawValue)
        c.transparent = transparent ? 1 : 0
        c.value = colour
        c.v.0 = Ps1GpuVertex(x: 0, y: 0, u: 0, v: 0, _pad: 0, color: 0)
        c.v.1 = Ps1GpuVertex(x: 40, y: 0, u: 0, v: 0, _pad: 0, color: 0)
        c.v.2 = Ps1GpuVertex(x: 0, y: 40, u: 0, v: 0, _pad: 0, color: 0)
        return c
    }

    renderer.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
    renderer.apply(env)
    renderer.apply(mode)
    renderer.apply(tri(false, 0x0005))          // opaque red = 5
    renderer.apply(tri(true, 0x0005))           // +5
    renderer.apply(tri(true, 0x0005))           // +5
    renderer.endFrame()

    #expect(vram.readback()[5 * 1024 + 5] == 0x000F)
}

@Test func gouraudTrianglesAndDitherMatchTheSoftwareRasterizer() throws {
    guard let r = try MetalFixtureHarness.replay("synthetic-primitives", upTo: 2) else { return }
    #expect(r.firstDivergence == nil, Comment(rawValue: r.message))
}

@Test func texturedTrianglesMatchTheSoftwareRasterizer() throws {
    guard let r = try MetalFixtureHarness.replay("synthetic-primitives", upTo: 3) else { return }
    #expect(r.firstDivergence == nil, Comment(rawValue: r.message))
}

@Test func rectanglesAndSpritesMatchTheSoftwareRasterizer() throws {
    guard let r = try MetalFixtureHarness.replay("synthetic-primitives", upTo: 5) else { return }
    #expect(r.firstDivergence == nil, Comment(rawValue: r.message))
}

@Test func linesMatchTheSoftwareRasterizer() throws {
    guard let r = try MetalFixtureHarness.replay("synthetic-primitives", upTo: 6) else { return }
    #expect(r.firstDivergence == nil, Comment(rawValue: r.message))
}

@Test(.enabled(if: FileManager.default.fileExists(
                    atPath: FixtureFile.url(named: "pl-render-line").path),
               "pl-*.p1fx are build artifacts — run `zig build fixtures -Doptimize=ReleaseFast`"))
func replaysThePeterLemonLineRom() throws {
    // 60 mono lines and 20 shaded ones.
    guard let r = try MetalFixtureHarness.replay("pl-render-line") else { return }
    #expect(r.framesChecked == 17)
    #expect(r.firstDivergence == nil, Comment(rawValue: r.message))
}

@Test(.enabled(if: FileManager.default.fileExists(
                    atPath: FixtureFile.url(named: "pl-render-rectangle").path),
               "pl-*.p1fx are build artifacts — run `zig build fixtures -Doptimize=ReleaseFast`"))
func replaysThePeterLemonRectangleRom() throws {
    guard let r = try MetalFixtureHarness.replay("pl-render-rectangle") else { return }
    #expect(r.framesChecked == 17)
    #expect(r.firstDivergence == nil, Comment(rawValue: r.message))
}

@Test func aSpriteWrapsItsTexcoordsInEightBits() throws {
    // `tu +% @truncate(xx)` on u8 — a WRAP. The triangle path interpolates and
    // clamps instead, so this is a genuinely separate shader path, and the
    // A2 corpus contains not one draw_textured_rectangle to catch it.
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }

    // A 16bpp texture page at (256, 0) whose row 0 is a ramp: texel at u is
    // 0x0100 + u, so a wrapped read is visibly different from a clamped one.
    var pixels = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    for u in 0..<256 { pixels[256 + u] = UInt16(0x0100 + u) }
    vram.upload(pixels)

    let renderer = try MetalRasterizer(vram: vram)
    func env(_ op: UInt8, _ v: UInt32) -> Ps1GpuCommand {
        var c = Ps1GpuCommand(); c.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        c.opcode = op; c.value = v; return c
    }

    var spr = Ps1GpuCommand()
    spr.kind = UInt8(PS1_GPU_DRAW_TEXTURED_RECTANGLE.rawValue)
    spr.opcode = 0x65                 // RAW: no modulation
    spr.tpage = 0x0104                // page x 4 (-> 256), 16bpp
    spr.x = 0; spr.y = 300; spr.w = 8; spr.h = 1
    spr.v.0 = Ps1GpuVertex(x: 0, y: 0, u: 252, v: 0, _pad: 0, color: 0)

    renderer.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
    renderer.apply(env(0xE4, (511 << 10) | 1023))
    renderer.apply(spr)
    renderer.endFrame()

    let back = vram.readback()
    let row = 300 * 1024
    #expect(back[row + 0] == 0x01FC)   // u = 252
    #expect(back[row + 3] == 0x01FF)   // u = 255
    #expect(back[row + 4] == 0x0100)   // u wrapped to 0 — a clamp would repeat 0x01FF
    #expect(back[row + 7] == 0x0103)
}

// 48 textured triangles, 34 latch_texpage records and four uploads, all in
// frame 0 — and the uploads are in the SAME frame as the draws that sample
// them, which is what makes the mover-ends-the-pass rule load-bearing here
// rather than merely conservative.
@Test(.enabled(if: FileManager.default.fileExists(
                    atPath: FixtureFile.url(named: "pl-render-texture-polygon").path),
               "pl-*.p1fx are build artifacts — run `zig build fixtures -Doptimize=ReleaseFast`"))
func replaysThePeterLemonTexturePolygonRom() throws {
    guard let r = try MetalFixtureHarness.replay("pl-render-texture-polygon") else { return }
    #expect(r.framesChecked == 17)
    #expect(r.firstDivergence == nil, Comment(rawValue: r.message))
}

@Test func theDitherOffsetIsAnEightBitChannelUnit() throws {
    // The offsets are added at 8-BIT scale and clamped to [0,255] BEFORE the
    // >> 3 down to 5 bits. Reading them as 5-bit units is the bug 900daa0
    // fixed, and it survives every hash in the A2 corpus because no PL ROM
    // dithers. Channel 0x80 with dither cell (0,0) = -4 gives 0x7C >> 3 = 15;
    // at 5-bit scale it would give (0x80>>3) - 4 = 12.
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let renderer = try MetalRasterizer(vram: vram)

    func env(_ op: UInt8, _ v: UInt32) -> Ps1GpuCommand {
        var c = Ps1GpuCommand()
        c.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        c.opcode = op
        c.value = v
        return c
    }

    var tri = Ps1GpuCommand()
    tri.kind = UInt8(PS1_GPU_DRAW_SHADED_TRIANGLE.rawValue)
    // A flat-coloured Gouraud triangle: all three vertices 0x808080, so the
    // interpolation is exact everywhere and only the dither varies.
    tri.v.0 = Ps1GpuVertex(x: 0, y: 0, u: 0, v: 0, _pad: 0, color: 0x0080_8080)
    tri.v.1 = Ps1GpuVertex(x: 60, y: 0, u: 0, v: 0, _pad: 0, color: 0x0080_8080)
    tri.v.2 = Ps1GpuVertex(x: 0, y: 60, u: 0, v: 0, _pad: 0, color: 0x0080_8080)

    renderer.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
    renderer.apply(env(0xE4, (511 << 10) | 1023))
    renderer.apply(env(0xE1, 1 << 9))              // dither ON
    renderer.apply(tri)
    renderer.endFrame()

    let back = vram.readback()
    #expect(back[0] == (15 | (15 << 5) | (15 << 10)))          // cell (0,0) = -4
    #expect(back[1] == (16 | (16 << 5) | (16 << 10)))          // cell (1,0) =  0
}

@Test func theFeedbackFrameMatchesTheSoftwareRasterizer() throws {
    // Frame 6 samples a page this very frame drew into. Without pass splitting
    // the read is stale and the hash moves.
    guard let r = try MetalFixtureHarness.replay("synthetic-primitives") else { return }
    #expect(r.framesChecked == 7)
    #expect(r.firstDivergence == nil, Comment(rawValue: r.message))
}

// MARK: - The phase gate
//
// Byte-identical full 1024x512 VRAM on every frame of every fixture. This is a
// strictly stronger check than test-roms-pl, which compares a 320x224 display
// window reduced to 5-bit against a per-test floor and is a ratchet.

private let allGeneratedFixtures = [
    "pl-hello-world", "pl-cpu-add", "pl-render-polygon", "pl-render-line",
    "pl-render-rectangle", "pl-render-texture-polygon",
    "croc-legend-of-the-gobbos",
] + geometryFixtures

@Test(.enabled(if: allGeneratedFixtures.contains(where: generatedFixtureExists),
               "generated fixtures are absent — run `zig build fixtures -Doptimize=ReleaseFast`"))
func everyFixtureIsByteIdenticalOnEveryFrame() throws {
    var checked = 0
    for name in allGeneratedFixtures {
        guard generatedFixtureExists(name) else { continue }
        // `continue`, not `return`: a nil replay means no Metal device for
        // THIS call, not a reason to abandon every other fixture and skip the
        // `checked > 0` backstop below unasserted. A bare early return here
        // was the exact silent-green failure mode `generatedFixtureExists`'s
        // own doc comment already names, just recurring one call site over.
        guard let r = try MetalFixtureHarness.replay(name) else { continue }
        checked += 1
        #expect(r.firstDivergence == nil, Comment(rawValue: r.message))
        // The pass count and the frame count, printed on SUCCESS as well as
        // failure: pass-splitting cost was unknown until the geometry fixtures
        // existed to measure it on, and this is the measurement.
        print("[phase-b] \(name): \(r.framesChecked) frames, \(r.passCount) passes")
    }
    #expect(checked > 0)
}
