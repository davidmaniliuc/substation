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
              let png = Self.downscaledPNG(from: rep)
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

    /// The largest a cover is ever actually drawn at: `LibraryView`'s grid is
    /// `GridItem(.adaptive(minimum: 132, maximum: 180))`, a 3:4 tile up to
    /// 180pt wide (240pt tall), and 3x is the highest Retina scale factor in
    /// play — 540x720. Storing anything bigger buys the tile nothing; it just
    /// makes every `GameTile` body evaluation decode a bitmap far larger than
    /// it will ever show. Re-encoding at this bound fixes that cost at store
    /// time, once, instead of paying it on every render.
    private static let maxCoverSize = CGSize(width: 540, height: 720)

    /// Only ever shrinks: a source already within the bound is encoded as-is,
    /// so a small placeholder image is never blown up past its own detail.
    private static func downscaledPNG(from source: NSBitmapImageRep) -> Data? {
        let sourceSize = CGSize(width: source.pixelsWide, height: source.pixelsHigh)
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let scale = min(
            1,
            min(maxCoverSize.width / sourceSize.width, maxCoverSize.height / sourceSize.height))
        guard scale < 1, let sourceImage = source.cgImage else {
            return source.representation(using: .png, properties: [:])
        }

        let targetSize = (
            width: max(1, Int((sourceSize.width * scale).rounded())),
            height: max(1, Int((sourceSize.height * scale).rounded()))
        )

        // A private CGContext, not `NSGraphicsContext.current`: that property
        // is process-global, and this can run from a concurrent test suite or
        // (in principle) more than one cover being set at once.
        guard let context = CGContext(
            data: nil, width: targetSize.width, height: targetSize.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(sourceImage, in: CGRect(
            x: 0, y: 0, width: targetSize.width, height: targetSize.height))

        guard let scaledImage = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaledImage)
            .representation(using: .png, properties: [:])
    }
}
