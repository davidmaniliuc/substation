import Testing
import Foundation
import CPs1
@testable import PS1

// The layout guards. These are the reason the record is declared in C: a field
// added to command.Command without updating ps1.h shears every record in every
// fixture, and this is where that gets caught.
@Test func gpuCommandStrideIs72() {
    #expect(MemoryLayout<Ps1GpuCommand>.stride == 72)
    #expect(MemoryLayout<Ps1GpuCommand>.size == 72)
    #expect(MemoryLayout<Ps1GpuVertex>.stride == 12)
}

@Test func gpuCommandKindCountIs17() {
    #expect(Int(PS1_GPU_KIND_COUNT) == 17)
    #expect(PS1_GPU_VRAM_READ_SETUP.rawValue == 16)
}

@Test func fnv1aMatchesThePublishedVectors() {
    #expect(Fnv1a.hash(Data()) == 0xcbf2_9ce4_8422_2325)
    #expect(Fnv1a.hash(Data("a".utf8)) == 0xaf63_dc4c_8601_ec8c)
    #expect(Fnv1a.hash(Data("foobar".utf8)) == 0x8594_4171_f739_67e8)
}

@Test func fnv1aHashesVramAsLittleEndianU16() {
    #expect(Fnv1a.hash(vram: [0x0000, 0x7FFF, 0x8001, 0x1234]) == 0x1b86_415c_7051_1fc8)

    let zeroVram = [UInt16](repeating: 0, count: 1024 * 512)
    #expect(Fnv1a.hash(vram: zeroVram) == 0xa967_7706_9d62_2325)
}

@Test func loadsTheCommittedSyntheticFixture() throws {
    let f = try FixtureFile(contentsOf: FixtureFile.url(named: "synthetic-movers"))
    #expect(f.frames.count == 6)

    // Frame 0 is an A0 upload: a setup record then a coalesced payload run.
    let r0 = f.records(for: 0)
    #expect(r0.count >= 2)
    #expect(r0.contains { $0.commandKind == PS1_GPU_VRAM_WRITE_SETUP })
    #expect(r0.contains { $0.commandKind == PS1_GPU_VRAM_WRITE_DATA })
    #expect(f.payload(for: 0).count == 128)   // 32 x 8 pixels / 2 per word

    // Frame 1's fill must be present with the colour the generator wrote.
    let fill = f.records(for: 1).first { $0.commandKind == PS1_GPU_FILL_RECT }
    #expect(fill != nil)
    #expect(fill?.value == 0x3C1F)
    #expect(fill?.w == 16)
    #expect(fill?.h == 6)

    // Frame 5 aborts mid-payload.
    #expect(f.records(for: 5).contains { $0.commandKind == PS1_GPU_VRAM_WRITE_ABORT })
}

@Test func structurallyChecksTheGeneratedFixtures() throws {
    // Generated, not committed: absent on a fresh clone, and the Croc one is
    // absent on any machine without games/. Skipping is correct; failing is not.
    for name in ["pl-hello-world", "pl-render-polygon", "pl-render-texture-polygon"] {
        let url = FixtureFile.url(named: name)
        guard FileManager.default.fileExists(atPath: url.path) else { continue }

        let f = try FixtureFile(contentsOf: url)
        #expect(f.frames.count > 0)
        for i in 0..<f.frames.count {
            let recs = f.records(for: i)
            for r in recs {
                #expect(r.kind < UInt8(PS1_GPU_KIND_COUNT))
            }
            // A vram_write_data record's .x is FRAME-relative and must address
            // inside this frame's own payload run.
            let payloadCount = f.payload(for: i).count
            for r in recs where r.commandKind == PS1_GPU_VRAM_WRITE_DATA {
                #expect(r.x >= 0)
                #expect(Int(r.x) + Int(r.y) <= payloadCount)
            }
        }
    }
}

@Test func rejectsABadMagic() throws {
    var bytes = try Data(contentsOf: FixtureFile.url(named: "synthetic-movers"))
    bytes[0] = 0x58
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bad.p1fx")
    try bytes.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    #expect(throws: FixtureFile.Error.badMagic) {
        _ = try FixtureFile(contentsOf: tmp)
    }
}

@Test func rejectsATotalRecordsCountAboveIntMax() throws {
    var bytes = try Data(contentsOf: FixtureFile.url(named: "synthetic-movers"))
    // UInt64.max as totalRecords: the pre-fix `Int(data.u64(at: 24))` traps
    // outright on any value above Int.max, before any guard runs at all —
    // this is the smallest input that reaches that particular trap.
    for i in 0..<8 { bytes[24 + i] = 0xFF }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bad-total-records-narrow.p1fx")
    try bytes.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    #expect(throws: FixtureFile.Error.truncated) {
        _ = try FixtureFile(contentsOf: tmp)
    }
}

@Test func rejectsATotalRecordsCountThatOverflowsTheSizeMultiply() throws {
    var bytes = try Data(contentsOf: FixtureFile.url(named: "synthetic-movers"))
    // 2^60 fits inside Int64 on its own, so the pre-fix `Int(u64)` narrowing
    // would NOT trap on this value — but `72 * totalRecords` does, before the
    // pre-fix size guard ever runs. Distinct code path from the test above:
    // that one is the narrowing trap, this one is the multiply overflow.
    let hostile: UInt64 = 0x1000_0000_0000_0000
    for i in 0..<8 { bytes[24 + i] = UInt8((hostile >> (8 * i)) & 0xFF) }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bad-total-records-multiply.p1fx")
    try bytes.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    #expect(throws: FixtureFile.Error.truncated) {
        _ = try FixtureFile(contentsOf: tmp)
    }
}

// The executable half of the bridge gate. Every command in this fixture is a
// memory move rather than a rasterization, which is why Swift can check it at
// all: reproducing a rasterized frame is Phase B's job, and writing a second
// rasterizer is what Phase A's design was built to prevent.
@Test func replaysTheSyntheticFixtureAndMatchesEveryHash() throws {
    let f = try FixtureFile(contentsOf: FixtureFile.url(named: "synthetic-movers"))
    var shadow = ShadowVram()

    // FixtureFile is a class: records(for:)/payload(for:) return buffers into
    // an allocation it owns and frees in deinit. ARC may release `f` after its
    // last use rather than at end of scope, so without this wrapper the
    // buffers could dangle with no compiler diagnostic.
    withExtendedLifetime(f) {
        for i in 0..<f.frames.count {
            let payload = f.payload(for: i)
            for cmd in f.records(for: i) {
                shadow.apply(cmd, payload: payload)
            }
            #expect(shadow.hash == f.frames[i].vramHash,
                    "frame \(i) diverged")
        }
    }
}

@Test func fillRectangleIgnoresTheMaskBits() {
    // The one write in the whole core that ignores GP0(E6). Frame 1 of the
    // synthetic fixture depends on it, but pin it directly too — if a shadow
    // routed fills through the masked store, only this would say why.
    var shadow = ShadowVram()
    shadow.data[0] = 0x8000                    // bit 15 set: the check bit would skip it
    shadow.maskCheck = true
    shadow.maskSet = true

    var fill = Ps1GpuCommand()
    fill.kind = UInt8(PS1_GPU_FILL_RECT.rawValue)
    fill.value = 0x1234
    fill.w = 1
    fill.h = 1
    shadow.apply(fill, payload: UnsafeBufferPointer(start: nil, count: 0))

    #expect(shadow.data[0] == 0x1234)          // written, and bit 15 NOT or'd in
}
