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
