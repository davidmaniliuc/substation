import Foundation
import Metal
import Testing
import CPs1
@testable import PS1

/// Hands fixture frame `i` to `body` as the pointers `StreamQueue` takes.
private func withFrame(_ f: FixtureFile, _ i: Int,
                       _ body: (UnsafePointer<Ps1GpuCommand>, Int, UnsafePointer<UInt32>?, Int) -> Void) {
    let recs = f.records(for: i)
    let pay = f.payload(for: i)
    var empty = Ps1GpuCommand()
    if let base = recs.baseAddress {
        body(base, recs.count, pay.baseAddress, pay.count)
    } else {
        body(&empty, 0, pay.baseAddress, pay.count)
    }
}

/// The Metal speculation gate: a replay that runs two frames ahead after
/// every frame, as runahead does, and puts them back, must leave the
/// real-timeline texture exactly as a plain replay leaves it.
@Test(arguments: ["synthetic-primitives", "synthetic-movers", "croc-legend-of-the-gobbos", "crash-bandicoot-warped"])
func speculationLeavesTheRealTimelineUntouched(_ name: String) throws {
    let url = FixtureFile.url(named: name)
    guard FileManager.default.fileExists(atPath: url.path),
          let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { return }
    let fixture = try FixtureFile(contentsOf: url)
    let n = fixture.frames.count
    let ahead = 2

    for scale in [1, 2] {
        let plain = try LiveRenderer(device: device, queue: queue, scale: scale)
        let spec = try LiveRenderer(device: device, queue: queue, scale: scale)
        let q1 = StreamQueue(), q2 = StreamQueue()
        q1.clearResync()
        q2.clearResync()

        try withExtendedLifetime(fixture) {
            for i in 0..<n {
                let seq = UInt64(i + 1)
                withFrame(fixture, i) { r, rc, p, pc in
                    q1.publish(seq: seq, records: r, recordCount: rc, payload: p, payloadCount: pc, complete: true)
                    q2.stage(seq: seq, records: r, recordCount: rc, payload: p, payloadCount: pc, complete: true)
                }
                q2.beginSpeculativeGroup(after: seq)
                for j in (i + 1)..<min(i + 1 + ahead, n) {
                    withFrame(fixture, j) { r, rc, p, pc in
                        q2.appendSpeculative(records: r, recordCount: rc, payload: p, payloadCount: pc, complete: true)
                    }
                }
                q2.commitSpeculativeGroup(display: Ps1Display())
                q2.commitStaged()

                plain.drain(from: q1) { ([], nil, 0) }
                spec.drain(from: q2) { ([], nil, 0) }
                if i + 1 < n { #expect(spec.presentDisplay != nil, "\(name) \(scale)x frame \(i): no speculation") }
                spec.settleSpeculation()
                let same = spec.vram.hash == plain.vram.hash
                #expect(same, "\(name) at \(scale)x: frame \(i) differs after speculating")
                if !same { return }
            }
        }
        #expect(spec.vram.readbackSidecar() == plain.vram.readbackSidecar(), "\(name) at \(scale)x: sidecar differs")
    }
}

private func record(_ kind: Ps1GpuCommandKind, x: Int32 = 0, y: Int32 = 0, x2: Int32 = 0, y2: Int32 = 0,
                    w: Int32 = 0, h: Int32 = 0, opcode: UInt8 = 0, value: UInt32 = 0) -> Ps1GpuCommand {
    var c = Ps1GpuCommand()
    c.kind = UInt8(kind.rawValue)
    c.x = x; c.y = y; c.x2 = x2; c.y2 = y2; c.w = w; c.h = h
    c.opcode = opcode
    c.value = value
    return c
}

private func region(_ cmds: [Ps1GpuCommand], env: DrawEnv = DrawEnv(),
                    transfer: VramTransfer = VramTransfer()) -> VramRect? {
    let slot = StreamSlot()
    for (i, c) in cmds.enumerated() { slot.records[i] = c }
    slot.recordCount = cmds.count
    return SpeculativeRegion.of([slot], env: env, transfer: transfer)
}

@Test func aGroupThatDrawsNothingHasNoRegion() {
    #expect(region([]) == nil)
    #expect(region([record(PS1_GPU_SET_DRAW_ENV, opcode: 0xE1, value: 0)]) == nil)
}

@Test func aPrimitiveIsBoundedByTheDrawingAreaItsGroupSet() {
    let area = [
        record(PS1_GPU_SET_DRAW_ENV, opcode: 0xE3, value: 10 | (20 << 10)),
        record(PS1_GPU_SET_DRAW_ENV, opcode: 0xE4, value: 329 | (259 << 10)),
        record(PS1_GPU_DRAW_TRIANGLE),
    ]
    #expect(region(area) == VramRect(x0: 10, y0: 20, x1: 329, y1: 259))
}

@Test func fillsCopiesAndUploadsUseTheirOwnRectangles() {
    #expect(region([record(PS1_GPU_FILL_RECT, x: 100, y: 50, w: 16, h: 8)])
            == VramRect(x0: 100, y0: 50, x1: 115, y1: 57))
    // A copy whose destination crosses the right edge wraps: the whole width.
    #expect(region([record(PS1_GPU_COPY_RECT, x2: 1020, y2: 4, w: 8, h: 2)])
            == VramRect(x0: 0, y0: 4, x1: 1023, y1: 5))
    #expect(region([record(PS1_GPU_VRAM_WRITE_SETUP, x: 640, y: 256, w: 0, h: 1)])
            == VramRect(x0: 0, y0: 256, x1: 1023, y1: 256))
    let both = region([record(PS1_GPU_FILL_RECT, x: 0, y: 0, w: 16, h: 16),
                       record(PS1_GPU_FILL_RECT, x: 100, y: 100, w: 16, h: 16)])
    #expect(both == VramRect(x0: 0, y0: 0, x1: 115, y1: 115))
}

@Test func anUploadTheRealFrameBeganIsPartOfTheRegion() {
    var t = VramTransfer()
    t.setup(x: 512, y: 0, w: 64, h: 64)
    #expect(region([record(PS1_GPU_VRAM_WRITE_DATA)], transfer: t)
            == VramRect(x0: 512, y0: 0, x1: 575, y1: 63))
}
