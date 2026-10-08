import Foundation

/// One saved machine on disk: `<stem>.state` (the core's state, LZFSE
/// compressed; the core never compresses) and `<stem>.png` (its thumbnail).
/// The resume state, its previous copy and every manual slot are each one of
/// these, so there is one write path.
///
/// Writes are atomic (`.atomic` writes a temporary file and renames it), so a
/// crash mid-save leaves the previous file rather than a torn one. The
/// thumbnail is written first (or removed first, when there is none), so a
/// crash between the two leaves the old state under a new picture or under
/// no picture; the tile falls back to its placeholder.
struct StateFile: Sendable {
    struct Info: Equatable {
        let savedAt: Date
        let thumbnail: URL?
    }

    let directory: URL
    let state: URL
    let thumbnail: URL

    init(directory: URL, stem: String) {
        self.directory = directory
        state = directory.appendingPathComponent("\(stem).state")
        thumbnail = directory.appendingPathComponent("\(stem).png")
    }

    var info: Info? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: state.path)
        guard let savedAt = attrs?[.modificationDate] as? Date else { return nil }
        return Info(savedAt: savedAt,
                    thumbnail: FileManager.default.fileExists(atPath: thumbnail.path) ? thumbnail : nil)
    }

    func load() -> Data? {
        guard let packed = try? Data(contentsOf: state) else { return nil }
        return try? (packed as NSData).decompressed(using: .lzfse) as Data
    }

    func write(state data: Data, thumbnail png: Data?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let png {
            try png.write(to: thumbnail, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: thumbnail)
        }
        let packed = try (data as NSData).compressed(using: .lzfse) as Data
        try packed.write(to: state, options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: state)
        try? FileManager.default.removeItem(at: thumbnail)
    }

    /// Renames this state over `destination`, replacing it. `rename(2)`
    /// replaces atomically; `FileManager.moveItem` refuses an existing
    /// destination, so it would need a remove first, and a crash between the
    /// two would lose both. The thumbnail moves first, for the write order's
    /// reason; a state with none clears the destination's.
    func move(to destination: StateFile) throws {
        if rename(thumbnail.path, destination.thumbnail.path) != 0 {
            try? FileManager.default.removeItem(at: destination.thumbnail)
        }
        guard rename(state.path, destination.state.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
