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

/// Holds the user's BIOS folder as a security-scoped bookmark.
///
/// The app is not sandboxed in v1, but storing a bookmark rather than a path
/// makes sandboxing later a settings change instead of a rewrite.
final class BiosLibrary {
    private static let bookmarkKey = "biosFolderBookmark"
    private static let explicitKey = "biosExplicitBookmark"

    private(set) var folderURL: URL?
    private var explicitURL: URL?

    init() {
        folderURL = Self.resolveBookmark(forKey: Self.bookmarkKey)
        explicitURL = Self.resolveBookmark(forKey: Self.explicitKey)
    }

    func setFolder(_ url: URL) {
        folderURL = url
        Self.storeBookmark(url, forKey: Self.bookmarkKey)
    }

    /// Fallback for a folder that yields no match: the user picks one file and
    /// that choice is remembered.
    func setExplicitBIOS(_ url: URL) throws {
        _ = try Self.read(url)
        explicitURL = url
        Self.storeBookmark(url, forKey: Self.explicitKey)
    }

    func biosData(forDisc name: String) throws -> Data {
        let region = BiosRegion.forDisc(named: name)

        if let folder = folderURL,
           let match = Self.findBIOS(in: folder, matching: region) {
            return try Self.read(match)
        }
        if let explicitURL {
            return try Self.read(explicitURL)
        }
        if folderURL == nil { throw BiosError.noFolderSelected }
        throw BiosError.noMatchingBIOS(region)
    }

    /// Matches on the stem so `SCPH-1001_BIOS_1995_US.bin` is found from
    /// `SCPH-1001` — which is how the files in this repo are actually named.
    private static func findBIOS(in folder: URL, matching region: BiosRegion) -> URL? {
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }

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

    private static func storeBookmark(_ url: URL, forKey key: String) {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func resolveBookmark(forKey key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale) else { return nil }
        return url
    }
}
