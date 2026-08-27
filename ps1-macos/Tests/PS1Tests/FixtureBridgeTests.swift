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

// The count and the stride do not pin the ORDINALS: reordering Kind while
// keeping 17 entries compiles clean on both sides, passes both header guards,
// and shears the meaning of every record already written to a fixture — the
// exact failure the C declaration exists to prevent. Mid-list, because the
// first and last are pinned by the count guard already. The Zig half is
// `fixture_test.zig`'s generator comparison, which is byte-exact.
@Test func gpuCommandKindOrdinalsAreFrozen() {
    #expect(PS1_GPU_SET_DRAW_ENV.rawValue == 7)
    #expect(PS1_GPU_FILL_RECT.rawValue == 11)
    #expect(PS1_GPU_VRAM_WRITE_SETUP.rawValue == 13)
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

/// Generated fixtures are build artifacts: absent on a fresh clone, and the Croc
/// one is absent on any machine without `games/`. Skipping is correct — but a
/// bare `continue` made the skip invisible, so the suite reported green having
/// run zero expectations.
private func generatedFixtureExists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: FixtureFile.url(named: name).path)
}

private let generatedPlFixtures = ["pl-hello-world", "pl-render-polygon", "pl-render-texture-polygon"]

@Test(.enabled(if: generatedPlFixtures.contains(where: generatedFixtureExists),
               "no pl-*.p1fx present — run `zig build fixtures -Doptimize=ReleaseFast`"))
func structurallyChecksTheGeneratedFixtures() throws {
    var checked = 0
    for name in generatedPlFixtures {
        let url = FixtureFile.url(named: name)
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        checked += 1

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
    // The trait only proves ONE of the three was present; this proves the loop
    // did not silently check nothing.
    #expect(checked > 0)
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

// MARK: - The two layout guards, exercised (item G)
//
// `record_stride` and `kind_count` exist in the header ONLY to be checked, and
// a loader that dropped both guards passed the suite. These mirror the Zig
// negative tests in `fixture_test.zig`. Patched in memory rather than through a
// temp file: `init(_:)` is the entry point under test either way.

@Test func rejectsARecordStrideMismatch() throws {
    var bytes = try Data(contentsOf: FixtureFile.url(named: "synthetic-movers"))
    for (i, b) in [UInt8(64), 0, 0, 0].enumerated() { bytes[12 + i] = b }

    #expect(throws: FixtureFile.Error.strideMismatch(64)) {
        _ = try FixtureFile(bytes)
    }
}

@Test func rejectsAKindCountMismatch() throws {
    var bytes = try Data(contentsOf: FixtureFile.url(named: "synthetic-movers"))
    for (i, b) in [UInt8(18), 0, 0, 0].enumerated() { bytes[16 + i] = b }

    #expect(throws: FixtureFile.Error.kindCountMismatch(18)) {
        _ = try FixtureFile(bytes)
    }
}

// MARK: - The three mover behaviours the committed fixture does not reach
//
// Measured, not assumed: of the six behaviours the format's movers have, the
// synthetic fixture pins the unmasked fill, the backwards-overlap copy order
// and mask.check, and the banked PL/Croc fixtures rescue none of the other
// three (Croc's E6 low bits are 0 throughout, all its transfers are even-sized,
// and it contains no copy_rect at all). Each test below names the mutation it
// catches, because each of those mutations left the whole suite green.

@Test func vramWriteHonoursTheMaskSetBit() {
    // Catches: deleting `| (maskSet ? 0x8000 : 0)` from maskedWrite.
    var shadow = ShadowVram()
    shadow.maskSet = true

    var setup = Ps1GpuCommand()
    setup.kind = UInt8(PS1_GPU_VRAM_WRITE_SETUP.rawValue)
    setup.w = 1
    setup.h = 1
    shadow.apply(setup, payload: UnsafeBufferPointer(start: nil, count: 0))

    let words: [UInt32] = [0x0000_1234]
    words.withUnsafeBufferPointer { buf in
        var data = Ps1GpuCommand()
        data.kind = UInt8(PS1_GPU_VRAM_WRITE_DATA.rawValue)
        data.x = 0
        data.y = 1
        shadow.apply(data, payload: buf)
    }

    #expect(shadow.data[0] == 0x9234)
}

@Test func copyWrapsRatherThanClipping() {
    // Catches: making copy clip like fill. Both committed copy_rect records
    // stay under coordinate 35, so neither `& 0x3FF` nor `& 0x1FF` ever fires
    // there. Clip-vs-wrap is the asymmetry ShadowVram's own comments call out.
    var shadow = ShadowVram()

    // Destination crosses x=1023. Source is a different row, so nothing
    // aliases and the copy direction cannot change the answer.
    for (i, v) in [UInt16(0xAAAA), 0xBBBB, 0xCCCC, 0xDDDD].enumerated() {
        shadow.data[i] = v
    }
    var dstWrap = Ps1GpuCommand()
    dstWrap.kind = UInt8(PS1_GPU_COPY_RECT.rawValue)
    dstWrap.x = 0
    dstWrap.y = 0
    dstWrap.x2 = 1022
    dstWrap.y2 = 5
    dstWrap.w = 4
    dstWrap.h = 1
    shadow.apply(dstWrap, payload: UnsafeBufferPointer(start: nil, count: 0))

    let row5 = 5 * ShadowVram.width
    #expect(shadow.data[row5 + 1022] == 0xAAAA)
    #expect(shadow.data[row5 + 1023] == 0xBBBB)
    #expect(shadow.data[row5 + 0] == 0xCCCC)     // x 1024 wrapped to 0
    #expect(shadow.data[row5 + 1] == 0xDDDD)     // x 1025 wrapped to 1

    // And the same on the read side: a source that runs off x=1023.
    let row10 = 10 * ShadowVram.width
    shadow.data[row10 + 1023] = 0x1111
    shadow.data[row10 + 0] = 0x2222
    var srcWrap = Ps1GpuCommand()
    srcWrap.kind = UInt8(PS1_GPU_COPY_RECT.rawValue)
    srcWrap.x = 1023
    srcWrap.y = 10
    srcWrap.x2 = 100
    srcWrap.y2 = 11
    srcWrap.w = 2
    srcWrap.h = 1
    shadow.apply(srcWrap, payload: UnsafeBufferPointer(start: nil, count: 0))

    let row11 = 11 * ShadowVram.width
    #expect(shadow.data[row11 + 100] == 0x1111)
    #expect(shadow.data[row11 + 101] == 0x2222)  // source x 1024 wrapped to 0
}

@Test func anOddSizedTransferDropsTheFinalHalfWord() {
    // Catches: removing the `< (writeW * writeH)` condition in writeData. All
    // three committed vram_write_setup records have even pixel counts, so the
    // drop never fires there. A 3x1 transfer is the smallest that does.
    var shadow = ShadowVram()

    var setup = Ps1GpuCommand()
    setup.kind = UInt8(PS1_GPU_VRAM_WRITE_SETUP.rawValue)
    setup.w = 3
    setup.h = 1
    shadow.apply(setup, payload: UnsafeBufferPointer(start: nil, count: 0))

    let words: [UInt32] = [0x2222_1111, 0x4444_3333]
    words.withUnsafeBufferPointer { buf in
        var data = Ps1GpuCommand()
        data.kind = UInt8(PS1_GPU_VRAM_WRITE_DATA.rawValue)
        data.x = 0
        data.y = 2
        shadow.apply(data, payload: buf)
    }

    #expect(shadow.data[0] == 0x1111)
    #expect(shadow.data[1] == 0x2222)
    #expect(shadow.data[2] == 0x3333)
    // The dropped half-word would land at the start of the NEXT row, not at
    // index 3 — currX has already wrapped by then. Asserting index 3 would
    // catch nothing.
    #expect(shadow.data[ShadowVram.width] == 0)
}

// MARK: - Real-game payload (item J)

private let crocFixture = "croc-legend-of-the-gobbos"

/// The one fixture that exists to prove the format survives real payload sizes
/// — 200 frames, 2,385 records, 1.9M payload words — and it turns out to be
/// fully hash-checkable: its census is `{set_texture_disable_allowed: 1,
/// set_draw_env: 306, vram_write_setup: 1014, vram_write_data: 1014,
/// fill_rect: 50}`, i.e. zero rasterization records.
@Test(.enabled(if: generatedFixtureExists(crocFixture),
               "croc-legend-of-the-gobbos.p1fx is generated from games/, which is gitignored — run `zig build fixtures -Doptimize=ReleaseFast`"))
func replaysTheCrocFixtureAndMatchesEveryHash() throws {
    let f = try FixtureFile(contentsOf: FixtureFile.url(named: crocFixture))
    var shadow = ShadowVram()
    #expect(f.frames.count > 0)

    withExtendedLifetime(f) {
        for i in 0..<f.frames.count {
            let payload = f.payload(for: i)
            for cmd in f.records(for: i) {
                shadow.apply(cmd, payload: payload)
            }
            #expect(shadow.hash == f.frames[i].vramHash, "frame \(i) diverged")
        }
        // Self-diagnosis: if a future capture window does contain geometry,
        // every hash above goes wrong and the movers would take the blame.
        #expect(shadow.sawUnmodelledKind == false)
    }
}
