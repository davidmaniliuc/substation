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
        self.directory = directory ?? AppSupport.directory("Covers")
    }

    func coverURL(for entry: GameEntry) -> URL? {
        adoptLegacyCover(for: entry)
        let url = fileURL(for: entry)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func setCover(from source: URL, for entry: GameEntry) throws {
        guard let data = try? Data(contentsOf: source) else { throw CoverError.undecodable }
        try setCover(from: data, for: entry)
    }

    /// The same path a chosen file takes — one decode, one downscale, one PNG
    /// re-encode — so a downloaded JPEG is stored exactly like a picked one
    /// and `GameTile` has a single kind of file to draw.
    func setCover(from data: Data, for entry: GameEntry) throws {
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              // Before the downscale, so the margin is gone rather than
              // resampled into a soft edge.
              let png = Self.downscaledPNG(from: CoverTrim.trimmed(rep))
        else { throw CoverError.undecodable }

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try png.write(to: fileURL(for: entry), options: .atomic)

        // A cover set under the old key would otherwise sit there forever,
        // and reappear if the disc ever stopped identifying.
        if let legacy = legacyURL(for: entry) {
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    func removeCover(for entry: GameEntry) throws {
        guard let url = coverURL(for: entry) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Keyed on the disc's own serial, so a cover survives the rip being moved
    /// or renamed — which is the whole reason the scanner identifies discs.
    /// A serial is per DISC, not per game (Final Fantasy VII's three are
    /// SCUS-94163/94164/94165), so it keys exactly what the path used to.
    ///
    /// Two rips of one game therefore SHARE a cover, where they used to have
    /// one each. They stay two tiles — `DiscGrouping` keeps them apart on
    /// their scope — and one piece of art for one game is the better answer.
    private func fileURL(for entry: GameEntry) -> URL {
        directory.appendingPathComponent("\(entry.serial ?? Self.pathKey(entry)).png")
    }

    /// Where a cover set before the disc was identifiable would have gone.
    /// Nil when the entry has no serial, because then nothing has moved.
    private func legacyURL(for entry: GameEntry) -> URL? {
        guard entry.serial != nil else { return nil }
        return directory.appendingPathComponent("\(Self.pathKey(entry)).png")
    }

    /// Moves a path-keyed cover onto the serial key the first time it is asked
    /// for. A migration with no pass over the library: an entry that is never
    /// displayed is never migrated, and costs nothing.
    private func adoptLegacyCover(for entry: GameEntry) {
        let fm = FileManager.default
        guard let legacy = legacyURL(for: entry),
              fm.fileExists(atPath: legacy.path),
              !fm.fileExists(atPath: fileURL(for: entry).path)
        else { return }
        try? fm.moveItem(at: legacy, to: fileURL(for: entry))
    }

    /// Hashed rather than escaped: a disc path can be any length and hold any
    /// character, and a fixed-width hex name is a filename on every volume.
    private static func pathKey(_ entry: GameEntry) -> String {
        SHA256.hash(data: Data(entry.id.utf8)).map { String(format: "%02x", $0) }.joined()
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
