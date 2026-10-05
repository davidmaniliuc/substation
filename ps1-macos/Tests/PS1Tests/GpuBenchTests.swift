import Testing
import Metal
@testable import PS1

/// The benchmark is a measuring instrument: the one property worth pinning is
/// that it actually replays frames and reports a positive GPU time for each
/// scale, so a silently empty run (a missing fixture, a hook never called)
/// cannot read as "infinitely fast".
@Test func theBenchmarkReplaysEveryFrameAndTimesTheGpu() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let results = try GpuBench.run(fixtures: ["synthetic-primitives"], scales: [1, 3],
                                   configs: [GpuBench.Config(name: "current")],
                                   repeats: 1)
    #expect(results.count == 2)
    for r in results {
        #expect(r.frames > 0)
        #expect(r.gpuMs > 0)
        #expect(r.cpuMs > 0)
        #expect(r.fps > 0)
    }
    #expect(results.map(\.scale) == [1, 3])
}
