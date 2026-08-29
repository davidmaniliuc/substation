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
