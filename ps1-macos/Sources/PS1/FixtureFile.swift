import Foundation
import CPs1

/// A .p1fx fixture: a recorded GP0 command stream plus a per-frame VRAM hash.
///
/// The format is defined in ps1-golden/src/fixture.zig and documented in
/// docs/superpowers/specs/2026-08-24-metal-renderer-phase-a2-fixture-bridge-design.md.
///
/// The record type comes from ps1.h via CPs1 and is NOT redeclared here: Swift
/// does not guarantee C-compatible layout for its own structs, so a raw read
/// into a Swift struct would rely on something the language does not promise.
///
/// A CLASS, not a struct: `records(for:)`/`payload(for:)` hand back buffers
/// into a stable backing allocation owned by this instance. `Data.withUnsafeBytes`
/// only promises its pointer for the duration of its own closure — Swift's docs
/// say explicitly not to store or return it — so those buffers are copied out of
/// the loaded `Data` once, at init, into a manually managed allocation that lives
/// exactly as long as this object does.
final class FixtureFile {
    enum Error: Swift.Error, Equatable {
        case badMagic
        case badVersion(UInt32)
        case strideMismatch(UInt32)
        case kindCountMismatch(UInt32)
        case truncated
        case badOffsets
    }

    struct Frame {
        let recordOff: Int
        let recordCount: Int
        let payloadOff: Int
        let payloadCount: Int
        let vramHash: UInt64
    }

    private static let magic = Data("PS1FIXT\0".utf8)
    private static let headerBytes = 48
    private static let frameEntryBytes = 24

    let frames: [Frame]
    /// The whole file, copied into a manually managed allocation at init so
    /// `records(for:)`/`payload(for:)` can hand out buffers that outlive any
    /// one call. Aligned to 8 because the file's own fields go up to u64.
    private let storage: UnsafeMutableRawBufferPointer
    private let recordsBase: Int
    private let payloadBase: Int

    convenience init(contentsOf url: URL) throws {
        try self.init(Data(contentsOf: url))
    }

    init(_ data: Data) throws {
        guard data.count >= Self.headerBytes else { throw Error.truncated }
        guard data.prefix(8) == Self.magic else { throw Error.badMagic }

        let version = data.u32(at: 8)
        guard version == 1 else { throw Error.badVersion(version) }

        // The two layout guards. A field added to command.Command without
        // updating ps1.h shears every record in the file; a Kind added without
        // a mirror in ps1.h surfaces as an unrecognised record in Phase B.
        // Both are caught here instead.
        let stride = data.u32(at: 12)
        guard stride == UInt32(PS1_GPU_COMMAND_STRIDE) else { throw Error.strideMismatch(stride) }
        let kinds = data.u32(at: 16)
        guard kinds == UInt32(PS1_GPU_KIND_COUNT) else { throw Error.kindCountMismatch(kinds) }

        let frameCount = Int(data.u32(at: 20))
        // Kept as UInt64 on purpose: these two are attacker-controlled 64-bit
        // fields, and narrowing either with plain Int(_:) traps outright once
        // the value exceeds Int.max (e.g. a hostile 0xFFFF...FFFF).
        let totalRecordsRaw = data.u64(at: 24)
        let totalPayloadRaw = data.u64(at: 32)

        // frameCount is only ever a u32, so this multiply can't overflow Int
        // on a 64-bit host (24 * UInt32.max is ~1e11, far under Int64.max) —
        // no checked arithmetic needed for it.
        let recordsBase = Self.headerBytes + Self.frameEntryBytes * frameCount

        // totalRecords/totalPayload have no such bound: a hostile file can set
        // either to anything up to UInt64.max (e.g. 2^60), and 72 * that (or
        // the running byte-offset sum) overflows before the size check below
        // ever runs — the old code trapped here, not in a guard. Do every step
        // in overflow-reporting UInt64 arithmetic, and only narrow to Int once
        // each value is proven to fit inside the file that's actually present;
        // any failure along the way means a malformed header, which must exit
        // through .truncated rather than crash the process.
        let (recordsSpan, recordsOverflowed) =
            UInt64(PS1_GPU_COMMAND_STRIDE).multipliedReportingOverflow(by: totalRecordsRaw)
        let (payloadBaseU64, payloadBaseOverflowed) =
            UInt64(recordsBase).addingReportingOverflow(recordsSpan)
        let (payloadSpan, payloadOverflowed) = totalPayloadRaw.multipliedReportingOverflow(by: 4)
        let (fileSizeU64, fileSizeOverflowed) = payloadBaseU64.addingReportingOverflow(payloadSpan)
        guard !recordsOverflowed, !payloadBaseOverflowed, !payloadOverflowed, !fileSizeOverflowed,
              fileSizeU64 == UInt64(data.count),
              let payloadBase = Int(exactly: payloadBaseU64),
              let totalRecords = Int(exactly: totalRecordsRaw),
              let totalPayload = Int(exactly: totalPayloadRaw)
        else { throw Error.truncated }

        var frames: [Frame] = []
        frames.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let o = Self.headerBytes + Self.frameEntryBytes * i
            // Each field here is a u32, so both this struct's values and the
            // sums checked right below top out around 2^33 — nowhere near
            // enough to overflow Int64, unlike the two u64 totals above.
            let f = Frame(
                recordOff: Int(data.u32(at: o)),
                recordCount: Int(data.u32(at: o + 4)),
                payloadOff: Int(data.u32(at: o + 8)),
                payloadCount: Int(data.u32(at: o + 12)),
                vramHash: data.u64(at: o + 16))
            guard f.recordOff + f.recordCount <= totalRecords,
                  f.payloadOff + f.payloadCount <= totalPayload else { throw Error.badOffsets }
            frames.append(f)
        }

        let storage = UnsafeMutableRawBufferPointer.allocate(byteCount: data.count, alignment: 8)
        data.copyBytes(to: storage)

        self.storage = storage
        self.frames = frames
        self.recordsBase = recordsBase
        self.payloadBase = payloadBase
    }

    deinit {
        storage.deallocate()
    }

    /// Records for one frame. The buffer points into this file's own backing
    /// allocation and is valid for the lifetime of this FixtureFile instance —
    /// do not retain it past that.
    ///
    /// This offset multiply can't overflow: init already proved
    /// `stride * totalRecords` fits inside the file, and the badOffsets guard
    /// there caps every frame's `recordOff` at `totalRecords`.
    func records(for frame: Int) -> UnsafeBufferPointer<Ps1GpuCommand> {
        let f = frames[frame]
        let off = recordsBase + Int(PS1_GPU_COMMAND_STRIDE) * f.recordOff
        return UnsafeBufferPointer(
            start: storage.baseAddress!.advanced(by: off).assumingMemoryBound(to: Ps1GpuCommand.self),
            count: f.recordCount)
    }

    /// This frame's payload run. Record `.x` offsets are relative to THIS
    /// slice, never to the whole file — the format keeps them frame-relative so
    /// neither side rebases anything. Valid for the lifetime of this
    /// FixtureFile instance — do not retain it past that.
    ///
    /// Same reasoning as `records(for:)`: init proved `4 * totalPayload` fits
    /// inside the file, and badOffsets caps every frame's `payloadOff` at
    /// `totalPayload`, so this multiply can't overflow either.
    func payload(for frame: Int) -> UnsafeBufferPointer<UInt32> {
        let f = frames[frame]
        let off = payloadBase + 4 * f.payloadOff
        return UnsafeBufferPointer(
            start: storage.baseAddress!.advanced(by: off).assumingMemoryBound(to: UInt32.self),
            count: f.payloadCount)
    }

    // MARK: - Locating fixtures

    /// Fixtures are build artifacts, not bundle resources — the app deliberately
    /// has no copy-resources phase (see the metallib note in CLAUDE.md). The
    /// repo root is derived from this file's own path at compile time.
    static var repoURL: URL {
        URL(fileURLWithPath: #filePath)             // …/ps1-macos/Sources/PS1/FixtureFile.swift
            .deletingLastPathComponent()            // …/PS1
            .deletingLastPathComponent()            // …/Sources
            .deletingLastPathComponent()            // …/ps1-macos
            .deletingLastPathComponent()            // repo root
    }

    /// The committed synthetic fixture lives with the other checked-in test
    /// data; everything else is generated into zig-out/fixtures/.
    static func url(named name: String) -> URL {
        let committed = repoURL
            .appendingPathComponent("ps1-core/tests/goldens/fixtures")
            .appendingPathComponent("\(name).p1fx")
        if FileManager.default.fileExists(atPath: committed.path) { return committed }
        return repoURL
            .appendingPathComponent("zig-out/fixtures")
            .appendingPathComponent("\(name).p1fx")
    }
}

extension Ps1GpuCommand {
    /// `kind` is a byte on the wire; the C enum imports into Swift as a
    /// RawRepresentable struct over UInt32. Going through this one accessor
    /// keeps every comparison in the app spelled the same way, rather than
    /// some sites casting the byte up and others casting the enum down.
    var commandKind: Ps1GpuCommandKind {
        Ps1GpuCommandKind(rawValue: UInt32(kind))
    }
}

private extension Data {
    func u32(at i: Int) -> UInt32 {
        UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    func u64(at i: Int) -> UInt64 {
        UInt64(u32(at: i)) | UInt64(u32(at: i + 4)) << 32
    }
}
