import Foundation
import Metal
import Synchronization

/// A class around the counter, because an `Atomic` is non-copyable and cannot
/// be captured by the command buffer's escaping completion handler.
private final class GpuNanos: @unchecked Sendable {
    let value = Atomic<UInt64>(0)
}

/// `PS1_GPU_BENCH`: replays `.p1fx` fixtures at several internal resolutions
/// and prints what each frame costs. Read by the APP (like `PS1_LIVE_DIFF`)
/// because the test bundle only builds in Debug, and the Debug Swift encode
/// cost is not what a player pays.
///
/// Two passes per (fixture, scale, config):
/// - SYNCHRONOUS: each frame waited on, so the summed `gpuEndTime -
///   gpuStartTime` is a per-frame cost. Overlapping buffers would otherwise
///   sum past wall time (measured live: 1.5-1.8 s of GPU per second).
/// - PIPELINED: `synchronous = false`, timed wall-clock over the whole run,
///   which is the frame rate a player can actually get.
///
/// Settings come from the player's own `UserDefaults`, so the numbers are
/// for the configuration actually played.
enum GpuBench {
    struct Config {
        let name: String
    }

    struct Result {
        let fixture: String
        let scale: Int
        let config: String
        let gpuMs: Double
        let cpuMs: Double
        let fps: Double
        let frames: Int

        var line: String {
            // Padded by hand: `%-24@` does not pad an object argument.
            "[gpu-bench] " + fixture.padding(toLength: 24, withPad: " ", startingAt: 0)
                + " \(scale)x " + config.padding(toLength: 10, withPad: " ", startingAt: 0)
                + String(format: " gpu %6.2f ms  cpu %6.2f ms  %6.1f fps  (%d frames)",
                         gpuMs, cpuMs, fps, frames)
        }
    }

    /// Best of `repeats` per row, by GPU ms. Configs are interleaved inside
    /// each repeat (A, B, A, B), never run as blocks: thermal drift on a
    /// fanless machine would otherwise land on one config.
    static func run(fixtures: [String], scales: [Int], configs: [Config],
                    repeats: Int) throws -> [Result] {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return [] }
        var best: [String: Result] = [:]
        var order: [String] = []
        for fixture in fixtures {
            let file = try FixtureFile(contentsOf: FixtureFile.url(named: fixture))
            for scale in scales {
                for _ in 0..<repeats {
                    for config in configs {
                        let r = try withExtendedLifetime(file) {
                            try measure(file, fixture: fixture, scale: scale, config: config,
                                        device: device, queue: queue)
                        }
                        let key = "\(fixture)|\(scale)|\(config.name)"
                        if best[key] == nil { order.append(key) }
                        if best[key].map({ r.gpuMs < $0.gpuMs }) ?? true { best[key] = r }
                    }
                }
            }
        }
        return order.compactMap { best[$0] }
    }

    private static func makeRasterizer(_ device: MTLDevice, _ queue: MTLCommandQueue,
                                       scale: Int, config: Config) throws -> MetalRasterizer? {
        guard let vram = MetalVram(device: device, queue: queue, scale: scale) else { return nil }
        let r = try MetalRasterizer(vram: vram)
        r.ditherMode = DitherSetting().mode
        r.textureFilter = TextureFilterSetting().filter
        r.spriteFilter = SpriteFilterSetting().filter
        return r
    }

    private static func replay(_ r: MetalRasterizer, _ file: FixtureFile) {
        for i in 0..<file.frames.count {
            r.beginFrame(payload: file.payload(for: i))
            for cmd in file.records(for: i) { r.apply(cmd) }
            r.endFrame()
        }
    }

    private static func measure(_ file: FixtureFile, fixture: String, scale: Int, config: Config,
                                device: MTLDevice, queue: MTLCommandQueue) throws -> Result {
        // Synchronous pass: per-frame GPU and CPU cost.
        guard let sync = try makeRasterizer(device, queue, scale: scale, config: config) else {
            return Result(fixture: fixture, scale: scale, config: config.name,
                          gpuMs: 0, cpuMs: 0, fps: 0, frames: 0)
        }
        sync.synchronous = true
        let gpuNs = GpuNanos()
        sync.onCommit = { cmd in
            cmd.addCompletedHandler { cb in
                let ns = max(0, (cb.gpuEndTime - cb.gpuStartTime) * 1e9)
                gpuNs.value.wrappingAdd(UInt64(ns), ordering: .relaxed)
            }
        }
        replay(sync, file)                       // warm-up: pipelines, caches
        gpuNs.value.store(0, ordering: .relaxed)
        var cpuNs: UInt64 = 0
        for i in 0..<file.frames.count {
            let t0 = DispatchTime.now().uptimeNanoseconds
            sync.beginFrame(payload: file.payload(for: i))
            for cmd in file.records(for: i) { sync.apply(cmd) }
            // CPU encode only: endFrame's synchronous wait is GPU time, and
            // is excluded by stopping the clock before it.
            cpuNs += DispatchTime.now().uptimeNanoseconds - t0
            sync.endFrame()
        }
        let frames = file.frames.count

        // Pipelined pass: the throughput a player gets.
        guard let piped = try makeRasterizer(device, queue, scale: scale, config: config) else {
            return Result(fixture: fixture, scale: scale, config: config.name,
                          gpuMs: 0, cpuMs: 0, fps: 0, frames: 0)
        }
        piped.synchronous = false
        replay(piped, file)                      // warm-up
        let t0 = DispatchTime.now().uptimeNanoseconds
        replay(piped, file)
        let fence = queue.makeCommandBuffer()!
        fence.commit()
        fence.waitUntilCompleted()
        let wallNs = DispatchTime.now().uptimeNanoseconds - t0

        return Result(fixture: fixture, scale: scale, config: config.name,
                      gpuMs: Double(gpuNs.value.load(ordering: .relaxed)) / 1e6 / Double(frames),
                      cpuMs: Double(cpuNs) / 1e6 / Double(frames),
                      fps: Double(frames) / (Double(wallNs) / 1e9),
                      frames: frames)
    }

    /// The app-launch entry: `PS1_GPU_BENCH=crash-bandicoot-warped,silent-hill-usa`
    /// and optionally `PS1_GPU_BENCH_SCALES=4,6,8` (default 1,4,6,8).
    /// Prints one line per row and exits the process.
    static func runFromEnvironment(_ env: [String: String]) -> Bool {
        guard let list = env["PS1_GPU_BENCH"], !list.isEmpty else { return false }
        let fixtures = list.split(separator: ",").map(String.init)
        let scales = (env["PS1_GPU_BENCH_SCALES"] ?? "1,4,6,8")
            .split(separator: ",").compactMap { Int($0) }
        Thread.detachNewThread {
            do {
                let results = try run(fixtures: fixtures, scales: scales,
                                      configs: configs(env), repeats: 5)
                for r in results { print(r.line) }
                exit(0)
            } catch {
                print("[gpu-bench] failed: \(error)")
                exit(1)
            }
        }
        return true
    }

    /// The renderer as built: one config, named in every row.
    static func configs(_ env: [String: String]) -> [Config] {
        [Config(name: "current")]
    }
}
