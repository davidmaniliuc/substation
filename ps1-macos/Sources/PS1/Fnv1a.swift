import Foundation

/// FNV-1a 64, the .p1fx fixture hash.
///
/// Mirrors ps1-golden/src/fixture.zig. Deliberately not the Wyhash the trace
/// harness uses: that is a Zig-standard-library implementation which may change
/// across releases, and a file format pinned to it would break silently on a
/// toolchain upgrade. Both sides are pinned against the same literal vectors so
/// neither is verified only against the other.
enum Fnv1a {
    static func hash(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x100_0000_01b3
        }
        return h
    }

    static func hash(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { hash($0) }
    }

    /// VRAM as little-endian u16, row-major, full extent.
    static func hash(vram: [UInt16]) -> UInt64 {
        vram.withUnsafeBytes { hash($0) }
    }
}
