import Foundation

/// One resume state per GAME, on disk: `<key>.state` (LZFSE-compressed core
/// state) and `<key>.png` (its thumbnail), under
/// `Application Support/Substation/ResumeStates/`.
///
/// Keyed on the game's FIRST disc, so a multi-disc game has one slot, and
/// the state's own header says which disc was in the tray. Serial first,
/// path hash for a disc that names none: the `CoverStore` rule, so a rip
/// that is moved or renamed keeps its state.
///
/// Writes are atomic (`.atomic` writes a temporary file and renames it), so a
/// crash mid-save leaves the previous state rather than a torn one to be
/// offered. The thumbnail is written first (or removed first, when there is
/// none), so a crash between the two leaves the old state under a new picture
/// or under no picture; the tile falls back to its placeholder.
final class ResumeStateStore: Sendable {
    struct Info: Equatable {
        let savedAt: Date
        let thumbnail: URL?
    }

    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? AppSupport.directory("ResumeStates")
    }

    static func key(for game: GameEntry) -> String {
        game.serial ?? game.pathKey
    }

    func info(_ key: String) -> Info? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: stateURL(key).path)
        guard let savedAt = attrs?[.modificationDate] as? Date else { return nil }
        let png = thumbnailURL(key)
        return Info(savedAt: savedAt,
                    thumbnail: FileManager.default.fileExists(atPath: png.path) ? png : nil)
    }

    func load(_ key: String) -> Data? {
        guard let packed = try? Data(contentsOf: stateURL(key)) else { return nil }
        return try? (packed as NSData).decompressed(using: .lzfse) as Data
    }

    func save(state: Data, thumbnail: Data?, key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let thumbnail {
            try thumbnail.write(to: thumbnailURL(key), options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: thumbnailURL(key))
        }
        let packed = try (state as NSData).compressed(using: .lzfse) as Data
        try packed.write(to: stateURL(key), options: .atomic)
    }

    func remove(_ key: String) {
        try? FileManager.default.removeItem(at: stateURL(key))
        try? FileManager.default.removeItem(at: thumbnailURL(key))
    }

    private func stateURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).state")
    }

    private func thumbnailURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).png")
    }
}
