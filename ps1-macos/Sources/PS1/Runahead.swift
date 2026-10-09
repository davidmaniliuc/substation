import Foundation
import CPs1

/// What runahead needs from the core, so the sequence can be driven by a
/// test without a BIOS or a disc.
protocol SpeculativeCore: AnyObject {
    func snapshotMark() throws
    func snapshotReturn() throws
    func runFrame()
    func readAudio(into dst: UnsafeMutablePointer<Float>, maxFloats: Int) -> Int
    func takeFrameStream() -> Ps1GpuStream
    func display() -> Ps1Display
}

extension Ps1Core: SpeculativeCore {}

enum Runahead {
    /// Runs `frames` frames past real frame `seq` into a speculative group
    /// and returns the machine to where it was. Their audio is read and
    /// dropped: it is a future the real frames will play themselves. The
    /// pad status is not touched, so it stays the real frame's. The caller
    /// has drained the real frame's audio already: the mark snapshots the
    /// SPU's ring, so what is read here is exactly the speculative frames'.
    static func speculate(_ frames: Int, after seq: UInt64, core: SpeculativeCore,
                          streams: StreamQueue, audioScratch: inout [Float]) {
        guard (try? core.snapshotMark()) != nil else { return }
        streams.beginSpeculativeGroup(after: seq)
        var empty = Ps1GpuCommand()
        for _ in 0..<frames {
            core.runFrame()
            _ = audioScratch.withUnsafeMutableBufferPointer { buf in
                core.readAudio(into: buf.baseAddress!, maxFloats: buf.count)
            }
            // Once per frame, unconditionally: the recorder is a drain.
            let s = core.takeFrameStream()
            if let recs = s.records {
                streams.appendSpeculative(records: recs, recordCount: s.record_count,
                                          payload: s.payload, payloadCount: s.payload_count,
                                          complete: s.complete != 0)
            } else {
                streams.appendSpeculative(records: &empty, recordCount: 0, payload: nil,
                                          payloadCount: 0, complete: false)
            }
        }
        streams.commitSpeculativeGroup(display: core.display())
        // A refused return (the mark was forgotten) leaves the machine in the
        // future; nothing the runner does between mark and return forgets it.
        try? core.snapshotReturn()
    }
}
