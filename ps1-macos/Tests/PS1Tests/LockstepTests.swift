import Foundation
import Metal
import Testing
import CPs1
@testable import PS1

/// TEMPORARY (Plan C Task 8 deletes it with the Swift renderer). The Zig
/// renderer, replayed through `ps1_lockstep_replay`, must leave the scaled VRAM
/// and sidecar byte-identical to `MetalRasterizer` after every frame of every
/// fixture, at every scale and setting listed here.
@Suite struct LockstepTests {
    struct Setting {
        let name: String
        let dither: DitherMode
        let filter: TextureFilter
        let spriteFilter: TextureFilter
        let depthBuffer: Bool
    }

    static let scales = [1, 3, 8]

    static let shipped = Setting(name: "shipped", dither: .trueColor, filter: .nearest,
                                 spriteFilter: .nearest, depthBuffer: false)
    static let nativeBilinear = Setting(name: "native-bilinear", dither: .native, filter: .bilinear,
                                        spriteFilter: .bilinear, depthBuffer: false)
    static let depth = Setting(name: "depth", dither: .trueColor, filter: .nearest,
                               spriteFilter: .nearest, depthBuffer: true)

    /// The depth plane is only ever written by a PGXP capture.
    static func settings(for fixture: String) -> [Setting] {
        fixture.hasSuffix("-pgxp") ? [shipped, nativeBilinear, depth] : [shipped, nativeBilinear]
    }

    /// Every name `FixtureFile.url(named:)` resolves: the committed fixtures and
    /// everything generated into zig-out/fixtures/.
    static func fixtureNames() -> [String] {
        let dirs = ["ps1-core/tests/goldens/fixtures", "zig-out/fixtures"].map {
            FixtureFile.repoURL.appendingPathComponent($0)
        }
        let names = dirs.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "p1fx" }
                .map { $0.deletingPathExtension().lastPathComponent }
        }
        return Set(names).sorted()
    }

    /// One replay's per-frame hashes and its final state.
    struct Replay {
        var vramHashes: [UInt64] = []
        var sidecarHashes: [UInt64] = []
        var vram: [UInt16] = []
        var sidecar: [UInt8] = []
    }

    static func swiftReplay(_ file: FixtureFile, _ s: Setting, scale: Int, upTo: Int,
                            device: MTLDevice, queue: MTLCommandQueue) throws -> Replay {
        let vram = try #require(MetalVram(device: device, queue: queue, scale: scale,
                                          depthBuffer: s.depthBuffer))
        let r = try MetalRasterizer(vram: vram)
        r.ditherMode = s.dither
        r.textureFilter = s.filter
        r.spriteFilter = s.spriteFilter
        var out = Replay()
        withExtendedLifetime(file) {
            for i in 0..<upTo {
                autoreleasepool {
                    r.beginFrame(payload: file.payload(for: i))
                    for cmd in file.records(for: i) { r.apply(cmd) }
                    r.endFrame()
                    out.vram = vram.readback()
                    out.sidecar = vram.readbackSidecar()
                    out.vramHashes.append(Fnv1a.hash(vram: out.vram))
                    out.sidecarHashes.append(out.sidecar.withUnsafeBytes { Fnv1a.hash($0) })
                }
            }
        }
        return out
    }

    static func zigReplay(_ bytes: Data, _ s: Setting, scale: Int, upTo: Int) -> (Int32, Replay) {
        var cfg = Ps1LockstepConfig(scale: Int32(scale), dither: Int32(s.dither.rawValue),
                                    texture_filter: Int32(s.filter.rawValue),
                                    sprite_filter: Int32(s.spriteFilter.rawValue),
                                    depth_buffer: s.depthBuffer ? 1 : 0)
        let pixels = 1024 * 512 * scale * scale
        var out = Replay(vramHashes: Array(repeating: 0, count: upTo),
                         sidecarHashes: Array(repeating: 0, count: upTo),
                         vram: Array(repeating: 0, count: pixels),
                         sidecar: Array(repeating: 0, count: pixels * 4))
        let frames = bytes.withUnsafeBytes { b in
            ps1_lockstep_replay(b.baseAddress!.assumingMemoryBound(to: UInt8.self), b.count, &cfg,
                                UInt32(upTo), &out.vramHashes, &out.sidecarHashes,
                                &out.vram, &out.sidecar)
        }
        return (frames, out)
    }

    /// The first index at which two equal-length arrays differ.
    static func firstDifference<T: Equatable>(_ a: [T], _ b: [T]) -> Int? {
        a.indices.first { a[$0] != b[$0] }
    }

    /// Where frame `f` first disagrees, read from a replay of both renderers
    /// that stops there.
    static func pixelReport(_ file: FixtureFile, _ bytes: Data, _ s: Setting, scale: Int, frame f: Int,
                            device: MTLDevice, queue: MTLCommandQueue) throws -> String {
        let swift = try swiftReplay(file, s, scale: scale, upTo: f + 1, device: device, queue: queue)
        let (_, zig) = zigReplay(bytes, s, scale: scale, upTo: f + 1)
        let width = 1024 * scale
        var parts: [String] = []
        if let i = firstDifference(swift.vram, zig.vram) {
            parts.append(String(format: "VRAM first differs at (%d, %d): swift %04X zig %04X",
                                i % width, i / width, swift.vram[i], zig.vram[i]))
        }
        if let i = firstDifference(swift.sidecar, zig.sidecar) {
            let p = i / 4
            parts.append("sidecar first differs at (\(p % width), \(p / width)) channel \(i % 4): "
                         + "swift \(swift.sidecar[i]) zig \(zig.sidecar[i])")
        }
        return parts.joined(separator: "; ")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device"))
    func theZigRendererMatchesTheSwiftOneOnEveryFrame() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        var fixtures = 0
        var runs = 0
        for name in Self.fixtureNames() {
            let url = FixtureFile.url(named: name)
            let bytes = try Data(contentsOf: url)
            // An ad-hoc capture `zig build fixtures` does not regenerate can be
            // an older format neither renderer can open: named, not dropped.
            let file: FixtureFile
            do {
                file = try FixtureFile(bytes)
            } catch FixtureFile.Error.badVersion(let v) {
                print("lockstep: \(url.path) is format version \(v); regenerate it to gate it")
                continue
            }
            fixtures += 1
            let count = file.frames.count
            for s in Self.settings(for: name) {
                for scale in Self.scales {
                    runs += 1
                    let run = "\(name) \(s.name) \(scale)x"
                    let swift = try Self.swiftReplay(file, s, scale: scale, upTo: count,
                                                     device: device, queue: queue)
                    let (frames, zig) = Self.zigReplay(bytes, s, scale: scale, upTo: count)
                    #expect(Int(frames) == count, "\(run): replayed \(frames) frames")
                    guard Int(frames) == count else { continue }

                    let vramFrame = Self.firstDifference(swift.vramHashes, zig.vramHashes)
                    let sidecarFrame = Self.firstDifference(swift.sidecarHashes, zig.sidecarHashes)
                    #expect(zig.vramHashes == swift.vramHashes,
                            "\(run): VRAM first differs at frame \(vramFrame ?? -1)")
                    #expect(zig.sidecarHashes == swift.sidecarHashes,
                            "\(run): sidecar first differs at frame \(sidecarFrame ?? -1)")
                    #expect(zig.vram == swift.vram, "\(run): final VRAM differs")
                    #expect(zig.sidecar == swift.sidecar, "\(run): final sidecar differs")
                    if let f = [vramFrame, sidecarFrame].compactMap({ $0 }).min() {
                        let location = try Self.pixelReport(file, bytes, s, scale: scale, frame: f,
                                                          device: device, queue: queue)
                        Issue.record("\(run): frame \(f): \(location)")
                    }
                }
            }
        }
        print("lockstep: \(fixtures) fixtures, \(runs) runs")
    }
}
