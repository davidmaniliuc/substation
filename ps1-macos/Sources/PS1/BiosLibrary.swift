import Foundation

/// The BIOS a disc needs. A US BIOS in front of a PAL disc stops at the
/// region-lock screen, so this is load-bearing.
///
/// Answered by the DISC wherever the disc answers — see `DiscIdentity` — and
/// by the filename only when it does not. The filename rule is `ps1-golden`'s,
/// verbatim, and it is a guess: Final Fantasy IX (France) carries no `(Europe)`
/// token and drew a US BIOS under it.
enum BiosRegion: String, CaseIterable {
    case europe = "SCPH-7502"
    case japan  = "SCPH-1000"
    case us     = "SCPH-1001"

    init(_ region: DiscIdentity.Region) {
        switch region {
        case .america: self = .us
        case .europe:  self = .europe
        case .japan:   self = .japan
        }
    }

    /// What the disc says, or what its name suggests when it says nothing.
    static func forDisc(_ identity: DiscIdentity, named name: String) -> BiosRegion {
        if let region = identity.region { return BiosRegion(region) }
        return forDisc(named: name)
    }

    static func forDisc(named name: String) -> BiosRegion {
        let lower = name.lowercased()
        if lower.contains("(europe)") { return .europe }
        if lower.contains("(japan)")  { return .japan }
        return .us
    }
}

enum BiosError: Error {
    case noFolderSelected
    case noMatchingBIOS(BiosRegion)
    case wrongSize(Int)
    case unreadable
}

/// Holds the user's BIOS folder, and a single explicitly-chosen BIOS file as a
/// fallback for a folder that yields no regional match.
final class BiosLibrary {
    private var folder = ScopedBookmark(key: "biosFolderBookmark")
    private var explicit = ScopedBookmark(key: "biosExplicitBookmark")

    var folderURL: URL? { folder.url }

    func setFolder(_ url: URL) throws {
        try folder.set(url)
    }

    /// Fallback for a folder that yields no match: the user picks one file and
    /// that choice is remembered. Validated before it is stored, so a bad pick
    /// fails now rather than at the next boot.
    func setExplicitBIOS(_ url: URL) throws {
        _ = try Self.read(url)
        try explicit.set(url)
    }

    func biosData(forDisc name: String, identity: DiscIdentity = .unknown) throws -> Data {
        let region = BiosRegion.forDisc(identity, named: name)

        if let match = folder.withAccess({ Self.findBIOS(in: $0, matching: region) }) ?? nil {
            return try Self.read(match)
        }
        if let data = try explicit.withAccess({ try Self.read($0) }) {
            return data
        }
        if folder.url == nil { throw BiosError.noFolderSelected }
        throw BiosError.noMatchingBIOS(region)
    }

    /// The BYTES first, the filename only after them.
    ///
    /// Pass 1 asks `BiosIdentity` what each 512 KB file in the folder actually
    /// is, and takes the one whose model is the region's — so the file may be
    /// called anything at all, and a folder whose images have been swapped or
    /// mislabelled still yields the right one.
    ///
    /// Pass 2 is the old stem match (`SCPH-1001_BIOS_1995_US.bin` from
    /// `SCPH-1001`, which is how the files in this repo are named), kept
    /// because the table is curated and an unlisted dump must still be
    /// reachable. Its one addition is that a file the table identifies as
    /// ANOTHER region is passed over: that file's name is known to be lying,
    /// and honouring it costs a boot to the region-lock screen.
    ///
    /// Note pass 1 matches the model, not merely the region, so a folder
    /// holding only `SCPH-101` still yields nothing for a US disc — SCPH-101 is
    /// the model Crash Bandicoot fails on under every BIOS, and selecting it
    /// silently would read as a core regression.
    private static func findBIOS(in folder: URL, matching region: BiosRegion) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }

        let identified = entries.reduce(into: [URL: BiosImage]()) { table, url in
            guard (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                    == BiosIdentity.byteCount,
                  let data = try? Data(contentsOf: url),
                  let image = BiosIdentity.identify(data) else { return }
            table[url] = image
        }

        if let match = entries.first(where: { identified[$0]?.model == region.rawValue }) {
            return match
        }
        return entries.first {
            $0.lastPathComponent.lowercased().hasPrefix(region.rawValue.lowercased())
                && identified[$0].map { $0.region == region } ?? true
        }
    }

    private static func read(_ url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { throw BiosError.unreadable }
        guard data.count == BiosIdentity.byteCount else {
            throw BiosError.wrongSize(data.count)
        }
        return data
    }
}
