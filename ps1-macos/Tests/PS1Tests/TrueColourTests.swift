import Testing
import Foundation
import Metal
import CPs1
@testable import PS1

/// True colour's own gates.
///
/// The primary assertion of the whole feature is negative: a rendering change
/// that moves no hash. VRAM in `.trueColor` is byte-identical to VRAM in
/// `.off`, which is a mode every existing gate already covers; the difference
/// lives entirely in the sidecar, which no gate reads.

/// Draws a shallow Gouraud ramp with GP0(E1) bit 9 set — a channel that changes
/// by well under one 8-bit step per pixel, which is where a ±4 dither offset
/// decides the output and a 5-bit truncation bands. The same geometry
/// `scaledDitheringActuallyChangesThePictureAboveOneX` uses, for the same
/// reason.
private func ditheredRamp(_ r: MetalRasterizer) {
    var area = Ps1GpuCommand()
    area.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
    area.opcode = 0xE4
    area.value = (511 << 10) | 1023
    r.apply(area)

    var mode = Ps1GpuCommand()
    mode.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
    mode.opcode = 0xE1
    mode.value = 1 << 9
    r.apply(mode)

    var tri = Ps1GpuCommand()
    tri.kind = UInt8(PS1_GPU_DRAW_SHADED_TRIANGLE.rawValue)
    tri.v.0 = Ps1GpuVertex(x: 4, y: 4, u: 0, v: 0, _pad: 0, color: 0x0040_4040)
    tri.v.1 = Ps1GpuVertex(x: 500, y: 8, u: 0, v: 0, _pad: 0, color: 0x0050_5050)
    tri.v.2 = Ps1GpuVertex(x: 8, y: 300, u: 0, v: 0, _pad: 0, color: 0x0048_4848)
    r.apply(tri)
}

@Test func trueColourNeverAppliesADitherOffset() throws {
    // Mutually exclusive BY CONSTRUCTION: DuckStation asserts the same thing
    // (gpu_hw_shadergen.cpp:2479), and it is why this is a fourth case of
    // DitherMode rather than a second control beside it. Two controls that
    // cannot both be on is a control that silently no-ops.
    guard let off = try MetalScaleHarness.frame(scale: 1, dither: .off, ditheredRamp),
          let tc = try MetalScaleHarness.frame(scale: 1, dither: .trueColor, ditheredRamp),
          let nat = try MetalScaleHarness.frame(scale: 1, dither: .native, ditheredRamp)
    else { return }
    #expect(tc.native == off.native, "a dither offset reached VRAM in .trueColor")
    // The control: without this the test passes for a mode that does nothing.
    #expect(nat.native != off.native, "the ramp carries no dithered primitive")
}

@Test func theCorpusRendersIdenticalVramInTrueColourAndOff() throws {
    // The "moves no hash" claim, over real recorded streams rather than one
    // hand-built triangle. `.off` is a mode every existing gate already runs
    // at, so equality with it is what lets true colour ship as the default
    // without a gate exemption.
    for name in ["synthetic-primitives", "synthetic-movers"] {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let a = MetalVram(device: device, queue: queue),
              let b = MetalVram(device: device, queue: queue) else { return }
        let offR = try MetalRasterizer(vram: a)
        let tcR = try MetalRasterizer(vram: b)
        offR.ditherMode = .off
        tcR.ditherMode = .trueColor

        let file = try FixtureFile(contentsOf: FixtureFile.url(named: name))
        withExtendedLifetime(file) {
            for i in 0..<file.frames.count {
                for r in [offR, tcR] {
                    r.beginFrame(payload: file.payload(for: i))
                    for cmd in file.records(for: i) { r.apply(cmd) }
                    r.endFrame()
                }
                #expect(a.hash == b.hash,
                        Comment(rawValue: "\(name) frame \(i): VRAM differs between .off and .trueColor"))
            }
        }
    }
}

/// CONTROLLER RULING R3: the same geometry and the same GP0(E1) bit 9 as
/// `ditheredRamp`, but vertex colours spanning the WHOLE channel range.
///
/// `ditheredRamp`'s colours span 0x40..0x50 — seventeen distinct eight-bit
/// levels — so the `> 32` assertion below is arithmetically unreachable on it.
/// That assertion states the feature's whole value (256 levels per channel
/// instead of 32) and needs a ramp wide enough to carry it. `ditheredRamp`
/// stays shallow for the two tests that need it that way: the dither-offset
/// test (a +-4 offset has to cross a `>> 3` boundary) and the copy test (which
/// needs sub-five-bit detail to survive a blit).
private func wideRamp(_ r: MetalRasterizer) {
    var area = Ps1GpuCommand()
    area.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
    area.opcode = 0xE4
    area.value = (511 << 10) | 1023
    r.apply(area)

    var mode = Ps1GpuCommand()
    mode.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
    mode.opcode = 0xE1
    mode.value = 1 << 9
    r.apply(mode)

    var tri = Ps1GpuCommand()
    tri.kind = UInt8(PS1_GPU_DRAW_SHADED_TRIANGLE.rawValue)
    tri.v.0 = Ps1GpuVertex(x: 4, y: 4, u: 0, v: 0, _pad: 0, color: 0x0000_0000)
    tri.v.1 = Ps1GpuVertex(x: 500, y: 8, u: 0, v: 0, _pad: 0, color: 0x00FF_FFFF)
    tri.v.2 = Ps1GpuVertex(x: 8, y: 300, u: 0, v: 0, _pad: 0, color: 0x0080_8080)
    r.apply(tri)
}

@Test func aGouraudRampKeepsMoreThanThirtyTwoLevelsInTheSidecar() throws {
    // The reported defect, stated as a number. Dithering redistributes
    // quantisation error; it cannot add levels, and a 5-bit channel has 32 of
    // them at every internal resolution. This is what the sidecar buys.
    //
    // `wideRamp`, not `ditheredRamp` — see CONTROLLER RULING R3 above.
    guard let tc = try MetalScaleHarness.frame(scale: 1, dither: .trueColor,
                                               wantSidecar: true, wideRamp),
          let side = tc.sidecar else { return }

    var vramLevels = Set<UInt16>()
    var sideLevels = Set<UInt8>()
    for i in 0..<tc.scaled.count where side[i * 4 + 3] == 255 {
        vramLevels.insert(tc.scaled[i] & 0x1F)
        sideLevels.insert(side[i * 4])
    }
    #expect(vramLevels.count <= 32)
    #expect(sideLevels.count > 32,
            "the sidecar has \(sideLevels.count) red levels — it is still five-bit data")
}

@Test func aFlatUntexturedDrawKeepsTheFiveBitCarveOut() throws {
    // DuckStation's ShouldTruncate32To16 (gpu_hw.cpp:167) still truncates a
    // draw that is untextured, unshaded AND undithered, with per-game traits
    // overriding it both ways. We adopt the carve-out and not the second menu
    // entry: a flat draw has no extra precision to carry, so it writes the
    // expansion of its own five-bit colour and there is nothing to choose.
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let r = try MetalRasterizer(vram: vram)
    r.ditherMode = .trueColor

    var area = Ps1GpuCommand()
    area.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
    area.opcode = 0xE4
    area.value = (511 << 10) | 1023

    var tri = Ps1GpuCommand()
    tri.kind = UInt8(PS1_GPU_DRAW_TRIANGLE.rawValue)
    tri.value = 0x1555
    tri.v.0 = Ps1GpuVertex(x: 10, y: 10, u: 0, v: 0, _pad: 0, color: 0)
    tri.v.1 = Ps1GpuVertex(x: 200, y: 10, u: 0, v: 0, _pad: 0, color: 0)
    tri.v.2 = Ps1GpuVertex(x: 10, y: 200, u: 0, v: 0, _pad: 0, color: 0)

    r.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
    r.apply(area); r.apply(tri)
    r.endFrame()

    let side = vram.readbackSidecar()
    let i = 50 * 1024 + 50
    #expect(side[i * 4 + 3] == 255)
    // 0x1555 is r = 21, g = 10, b = 5.
    #expect(side[i * 4] == UInt8((21 << 3) | (21 >> 2)))
    #expect(side[i * 4 + 1] == UInt8((10 << 3) | (10 >> 2)))
    #expect(side[i * 4 + 2] == UInt8((5 << 3) | (5 >> 2)))
}

@Test func theSidecarNeverReachesTexelFetch() throws {
    // DuckStation samples indexed texture data out of its RGBA8 target and
    // converts back down. Ours keeps reading r16Uint, so on this axis the
    // sidecar is MORE accurate than the reference — and the way to prove it is
    // that a draw which samples a true-colour region produces the same VRAM as
    // the same draw in `.off`, where the sidecar holds nothing extra.
    func draw(_ r: MetalRasterizer) {
        var area = Ps1GpuCommand()
        area.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        area.opcode = 0xE4
        area.value = (511 << 10) | 1023
        r.apply(area)

        // A ramp into the 16bpp texture page at (256, 0) — the region the
        // sprite below samples. Its low three bits per channel are exactly
        // what the sidecar keeps and VRAM does not.
        var ramp = Ps1GpuCommand()
        ramp.kind = UInt8(PS1_GPU_DRAW_SHADED_TRIANGLE.rawValue)
        ramp.v.0 = Ps1GpuVertex(x: 256, y: 0, u: 0, v: 0, _pad: 0, color: 0x0011_2233)
        ramp.v.1 = Ps1GpuVertex(x: 500, y: 4, u: 0, v: 0, _pad: 0, color: 0x00AA_BBCC)
        ramp.v.2 = Ps1GpuVertex(x: 260, y: 60, u: 0, v: 0, _pad: 0, color: 0x0055_6677)
        r.apply(ramp)

        var spr = Ps1GpuCommand()
        spr.kind = UInt8(PS1_GPU_DRAW_TEXTURED_RECTANGLE.rawValue)
        spr.opcode = 0x65                 // RAW: no modulation
        spr.tpage = 0x0104                // page x 4 (-> 256), 16bpp
        spr.x = 0; spr.y = 300; spr.w = 32; spr.h = 16
        spr.v.0 = Ps1GpuVertex(x: 0, y: 0, u: 0, v: 0, _pad: 0, color: 0)
        r.apply(spr)
    }

    guard let off = try MetalScaleHarness.frame(scale: 1, dither: .off, draw),
          let tc = try MetalScaleHarness.frame(scale: 1, dither: .trueColor, draw)
    else { return }
    #expect(tc.native == off.native, "the sidecar leaked into a texel fetch")
    // The control: the ramp really does have sub-five-bit detail to leak.
    guard let side = try MetalScaleHarness.frame(scale: 1, dither: .trueColor,
                                                 wantSidecar: true, draw)?.sidecar
    else { return }
    let i = 30 * 1024 + 300
    #expect(side[i * 4 + 3] == 255)
    let vramR = Int(tc.native[i] & 0x1F)
    #expect(Int(side[i * 4]) != ((vramR << 3) | (vramR >> 2)),
            "the ramp carries no sub-five-bit detail at this pixel")
}

@Test func aCopiedGradientKeepsItsPrecision() throws {
    // GP0(80) carries the sidecar in the same pass as VRAM, so an eight-bit
    // gradient survives a VRAM->VRAM blit — which is how a game's own
    // double-buffering or scroll does not silently re-quantise the picture.
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let r = try MetalRasterizer(vram: vram)
    r.ditherMode = .trueColor

    var copy = Ps1GpuCommand()
    copy.kind = UInt8(PS1_GPU_COPY_RECT.rawValue)
    copy.x = 4; copy.y = 4          // source: inside the ramp
    copy.x2 = 600; copy.y2 = 400    // destination: blank
    copy.w = 64; copy.h = 64

    r.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
    ditheredRamp(r)
    r.apply(copy)
    r.endFrame()

    let side = vram.readbackSidecar()
    // Hoisted: `readback()` is a synchronous blit plus a 1 MB array, and
    // calling it per pixel turns this test into 4,096 round trips to the GPU.
    let pixels = vram.readback()
    var compared = 0
    var extra = 0
    for dy in 0..<64 {
        for dx in 0..<64 {
            let s = ((4 + dy) * 1024 + 4 + dx) * 4
            let d = ((400 + dy) * 1024 + 600 + dx) * 4
            guard side[s + 3] == 255 else { continue }
            compared += 1
            #expect(side[d] == side[s] && side[d + 1] == side[s + 1]
                    && side[d + 2] == side[s + 2] && side[d + 3] == 255,
                    "the copy re-quantised (\(dx), \(dy))")
            let r5 = Int(pixels[(400 + dy) * 1024 + 600 + dx] & 0x1F)
            if Int(side[d]) != ((r5 << 3) | (r5 >> 2)) { extra += 1 }
        }
    }
    #expect(compared > 1000)
    #expect(extra > 0, "the copied region carries no sub-five-bit detail to keep")
}

@Test func aBlendedDrawStillFallsBackToFiveBitsInMilestoneOne() throws {
    // The milestone boundary, pinned so milestone 2 has a test to CHANGE
    // rather than a silent gap to fill. The blend path still reads VRAM and
    // writes the expansion of its five-bit result: a 5-bit blend is not the
    // truncation of an 8-bit blend, so carrying precision across a composite
    // is its own piece of work, and the spec gates it on finding a scene that
    // bands BECAUSE of layered blending.
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let r = try MetalRasterizer(vram: vram)
    r.ditherMode = .trueColor

    var area = Ps1GpuCommand()
    area.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
    area.opcode = 0xE4
    area.value = (511 << 10) | 1023

    var tri = Ps1GpuCommand()
    tri.kind = UInt8(PS1_GPU_DRAW_SHADED_TRIANGLE.rawValue)
    tri.transparent = 1
    tri.v.0 = Ps1GpuVertex(x: 10, y: 10, u: 0, v: 0, _pad: 0, color: 0x0011_2233)
    tri.v.1 = Ps1GpuVertex(x: 200, y: 14, u: 0, v: 0, _pad: 0, color: 0x00AA_BBCC)
    tri.v.2 = Ps1GpuVertex(x: 14, y: 200, u: 0, v: 0, _pad: 0, color: 0x0055_6677)

    r.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
    r.apply(area); r.apply(tri)
    r.endFrame()

    let pixels = vram.readback()
    let side = vram.readbackSidecar()
    let i = 60 * 1024 + 60
    #expect(side[i * 4 + 3] == 255)
    let p = pixels[i]
    for (c, ch) in [(Int(p & 0x1F), 0), (Int((p >> 5) & 0x1F), 1), (Int((p >> 10) & 0x1F), 2)] {
        #expect(side[i * 4 + ch] == UInt8((c << 3) | (c >> 2)))
    }
}

@Test func gateOneRunsAtADitheringModeRatherThanThePlayersDefault() throws {
    // Gate 1 compares against the fixture's own Zig hash, and `renderer.zig`
    // dithers whenever GP0(E1) bit 9 is set. The mode the harness runs at is
    // therefore part of the gate, not a preference — and it had been inherited
    // from DitherSetting.defaultMode, which is about to stop dithering.
    //
    // The divergence below is not a bug. It is the evidence that the pin is
    // load-bearing: without it, flipping the default turns every fixture hash
    // red and reads as a rendering regression.
    guard let tc = try MetalFixtureHarness.replay("synthetic-primitives",
                                                   upTo: 2, dither: .trueColor)
    else { return }
    #expect(tc.firstDivergence != nil,
            "frame 1 carries no dithered primitive — pin the gate with a frame that does")

    guard let nat = try MetalFixtureHarness.replay("synthetic-primitives",
                                                    upTo: 2, dither: .native)
    else { return }
    #expect(nat.firstDivergence == nil, Comment(rawValue: nat.message))
}
