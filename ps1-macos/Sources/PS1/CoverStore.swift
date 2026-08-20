import AppKit
import CryptoKit
import Foundation

enum CoverError: Error, Equatable {
    case undecodable
}

/// Custom cover images, one per game, on disk.
///
/// A chosen image is COPIED and re-encoded to PNG rather than referenced: the
/// library must not break when the user moves the file they picked out of
/// their Downloads folder, and re-encoding means one decoder path at display
/// time whatever they picked.
final class CoverStore {
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PS1/Covers", isDirectory: true)
    }

    func coverURL(for entry: GameEntry) -> URL? {
        let url = fileURL(for: entry)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func setCover(from source: URL, for entry: GameEntry) throws {
        guard let image = NSImage(contentsOf: source),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw CoverError.undecodable }

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try png.write(to: fileURL(for: entry), options: .atomic)
    }

    func removeCover(for entry: GameEntry) throws {
        guard let url = coverURL(for: entry) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Hashed rather than escaped: a disc path can be any length and hold any
    /// character, and a fixed-width hex name is a filename on every volume.
    private func fileURL(for entry: GameEntry) -> URL {
        let digest = SHA256.hash(data: Data(entry.id.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).png")
    }
}
