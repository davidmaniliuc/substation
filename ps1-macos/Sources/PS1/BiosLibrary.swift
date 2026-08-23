import Foundation

/// The BIOS a disc needs, keyed off its filename — `ps1-golden`'s rule,
/// verbatim. A US BIOS in front of a PAL disc stops at the region-lock screen,
/// so this is load-bearing.
enum BiosRegion: String, CaseIterable {
    case europe = "SCPH-7502"
    case japan  = "SCPH-1000"
    case us     = "SCPH-1001"

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

    func biosData(forDisc name: String) throws -> Data {
        let region = BiosRegion.forDisc(named: name)

        if let match = folder.withAccess({ Self.findBIOS(in: $0, matching: region) }) ?? nil {
            return try Self.read(match)
        }
        if let data = try explicit.withAccess({ try Self.read($0) }) {
            return data
        }
        if folder.url == nil { throw BiosError.noFolderSelected }
        throw BiosError.noMatchingBIOS(region)
    }

    /// Matches on the stem so `SCPH-1001_BIOS_1995_US.bin` is found from
    /// `SCPH-1001` — which is how the files in this repo are actually named.
    private static func findBIOS(in folder: URL, matching region: BiosRegion) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil) else { return nil }

        return entries.first { $0.lastPathComponent.lowercased()
            .hasPrefix(region.rawValue.lowercased()) }
    }

    private static func read(_ url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { throw BiosError.unreadable }
        guard data.count == 524288 else { throw BiosError.wrongSize(data.count) }
        return data
    }
}
