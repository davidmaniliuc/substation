import Testing
import Foundation
import CPs1
@testable import PS1

private func makeDefaults() -> (defaults: UserDefaults, name: String) {
    let name = "runahead-\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

@Test func runaheadIsOffWhenNeverSetAndPersists() {
    let (defaults, name) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    var setting = RunaheadSetting(key: "k", defaults: defaults)
    #expect(setting.frames == 0)
    setting.set(2)
    #expect(RunaheadSetting(key: "k", defaults: defaults).frames == 2)
    setting.set(9)
    #expect(setting.frames == 2)
    defaults.set(7, forKey: "k")
    #expect(RunaheadSetting(key: "k", defaults: defaults).frames == 0)
    #expect(RunaheadSetting.choices == [0, 1, 2, 3])
    #expect(RunaheadSetting.title(0) == "Off")
    #expect(RunaheadSetting.title(1) == "1 Frame")
}

/// Records what runahead asks of the core, in order.
private final class FakeCore: SpeculativeCore {
    var calls: [String] = []
    var record = Ps1GpuCommand()
    var audioPerFrame = 6

    func snapshotMark() throws { calls.append("mark") }
    func snapshotReturn() throws { calls.append("return") }
    func runFrame() { calls.append("run") }
    func readAudio(into dst: UnsafeMutablePointer<Float>, maxFloats: Int) -> Int {
        calls.append("audio")
        for i in 0..<audioPerFrame { dst[i] = 1 }
        return audioPerFrame
    }
    func takeFrameStream() -> Ps1GpuStream {
        calls.append("stream")
        return withUnsafePointer(to: &record) { p in
            Ps1GpuStream(records: p, record_count: 1, payload: nil, payload_count: 0, complete: 1, _pad: (0, 0, 0, 0, 0, 0, 0))
        }
    }
    func display() -> Ps1Display {
        calls.append("display")
        var d = Ps1Display()
        d.vram_x = 320
        return d
    }
}

@Test func runaheadMarksRunsDrainsAndReturnsInThatOrder() {
    let core = FakeCore()
    let q = StreamQueue()
    var scratch = [Float](repeating: 0, count: 64)
    Runahead.speculate(2, after: 9, core: core, streams: q, audioScratch: &scratch)

    // Every speculative frame's audio is read (so none is left for the real
    // timeline) and its stream taken; the return comes last.
    #expect(core.calls == ["mark", "run", "audio", "stream", "run", "audio", "stream", "display", "return"])
    let g = q.takeSpeculativeGroup(after: 9)
    #expect(g?.count == 2)
    #expect(g?.display.vram_x == 320)
}
