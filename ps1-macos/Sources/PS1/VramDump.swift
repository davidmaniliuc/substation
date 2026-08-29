import Foundation

/// Raw 1 MB VRAM blobs, and the pixel-wise diff that turns "frame 137
/// diverged" into an address.
///
/// The reference side is written by `ps1-golden stream-capture --dump-frame=N`;
/// this side writes its own on mismatch. Built BEFORE there is anything to
/// debug, deliberately — it is worthless to write while staring at a red frame.
enum VramDump {
    struct Difference {
        let x: Int, y: Int, want: UInt16, got: UInt16
    }

    /// Sits next to the fixtures, which are already build artifacts.
    static func url(fixture: String, frame: Int, side: String) -> URL {
        FixtureFile.repoURL
            .appendingPathComponent("zig-out/fixtures")
            .appendingPathComponent("\(fixture)-frame\(frame)\(side.isEmpty ? "" : "-" + side).vram")
    }

    static func write(_ pixels: [UInt16], to url: URL) throws {
        try pixels.withUnsafeBytes { Data($0) }.write(to: url)
    }

    static func read(_ url: URL) -> [UInt16]? {
        guard let data = try? Data(contentsOf: url),
              data.count == MetalVram.nativePixelCount * 2 else { return nil }
        var out = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
        out.withUnsafeMutableBytes { dst in _ = data.copyBytes(to: dst) }
        return out
    }

    static func firstDifferences(_ want: [UInt16], _ got: [UInt16], limit: Int) -> [Difference] {
        var out: [Difference] = []
        for i in 0..<min(want.count, got.count) where want[i] != got[i] {
            out.append(Difference(x: i % MetalVram.nativeWidth, y: i / MetalVram.nativeWidth,
                                  want: want[i], got: got[i]))
            if out.count == limit { break }
        }
        return out
    }

    /// The failure message. Writes this side's VRAM unconditionally, and if the
    /// Zig reference dump for that frame is present, lists where they part.
    static func report(fixture: String, frame: Int, got: [UInt16]) -> String {
        let mine = url(fixture: fixture, frame: frame, side: "metal")
        try? write(got, to: mine)
        guard let want = read(url(fixture: fixture, frame: frame, side: "")) else {
            return """
            \(fixture) frame \(frame) diverged. Metal VRAM written to \(mine.path).
            No reference dump — produce one with:
              zig build trace-golden -Doptimize=ReleaseFast -- stream-capture \\
                --filter=\(fixture) --dump-frame=\(frame)
            """
        }
        let diffs = firstDifferences(want, got, limit: 10)
        let total = zip(want, got).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        let lines = diffs.map {
            String(format: "  (%4d,%4d) want %04X got %04X", $0.x, $0.y, $0.want, $0.got)
        }
        return "\(fixture) frame \(frame) diverged: \(total) px\n" + lines.joined(separator: "\n")
    }
}
