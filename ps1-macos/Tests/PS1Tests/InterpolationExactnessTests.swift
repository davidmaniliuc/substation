import Testing
import Metal
@testable import PS1

/// `ps1_interp` and `ps1_interp_w` answer with a float estimate corrected by
/// an integer remainder instead of a 64-bit divide, which the GPU emulates
/// slowly. The result must still equal the divide bit for bit, or Gate 1 and
/// the PGXP-on parity gate stop being equalities; the corpus exercises only
/// the weights real fixtures happen to produce, so this checks the arithmetic
/// itself over 2^26 random cases per seed, small and large magnitudes alike.
@Test func interpolationMatchesTheSixtyFourBitDivideExactly() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { return }
    let library = try Shaders.makeLibrary(device)
    let pipeline = try device.makeComputePipelineState(
        function: try #require(library.makeFunction(name: "ps1_interp_fuzz")))
    let mismatches = try #require(device.makeBuffer(length: 8, options: .storageModeShared))

    for var seed: UInt32 in [1, 0x9E37_79B9, 0xDEAD_BEEF, 0x1234_5678] {
        mismatches.contents().initializeMemory(as: UInt32.self, repeating: 0, count: 2)
        let cmd = try #require(queue.makeCommandBuffer())
        let enc = try #require(cmd.makeComputeCommandEncoder())
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(mismatches, offset: 0, index: 0)
        enc.setBytes(&seed, length: 4, index: 1)
        enc.dispatchThreads(MTLSize(width: 1 << 26, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        let counts = mismatches.contents().bindMemory(to: UInt32.self, capacity: 2)
        #expect(counts[0] == 0, "affine mismatches, seed \(seed)")
        #expect(counts[1] == 0, "perspective mismatches, seed \(seed)")
    }
}
