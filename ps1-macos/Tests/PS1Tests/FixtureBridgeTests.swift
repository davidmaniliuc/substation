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
