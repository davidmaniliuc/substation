import AppKit

/// Decoded images by file. A view's body runs again on every selection move
/// and window resize, and reading a cover there read and decoded its file each
/// time. Keyed on the file's modification date as well as its URL: a cover or
/// a state's thumbnail is replaced in place, under the same name.
@MainActor
enum ImageCache {
    private final class Entry {
        let image: NSImage
        let modified: Date?
        /// The cover generation this entry was last checked against its file in.
        var checked = -1
        lazy var isCutOut = CoverShape.isCutOut(image)

        init(image: NSImage, modified: Date?) {
            self.image = image
            self.modified = modified
        }
    }

    private static let cache: NSCache<NSURL, Entry> = {
        let cache = NSCache<NSURL, Entry>()
        cache.countLimit = 400
        return cache
    }()

    static func image(at url: URL) -> NSImage? { entry(at: url)?.image }

    /// A cover, and whether it is a cut-out (`CoverShape`), which is read off
    /// its pixels once. The grid asks for every visible cover on every body
    /// pass, so a cover already checked since the last `coversChanged` is
    /// answered without touching its file.
    static func cover(at url: URL) -> (image: NSImage, isCutOut: Bool)? {
        if let cached = cache.object(forKey: url as NSURL), cached.checked == coverGeneration {
            return (cached.image, cached.isCutOut)
        }
        guard let entry = entry(at: url) else { return nil }
        entry.checked = coverGeneration
        return (entry.image, entry.isCutOut)
    }

    private static var coverGeneration = 0

    /// A cover was added, replaced or removed (`coverRevision`).
    static func coversChanged() { coverGeneration += 1 }

    private static func entry(at url: URL) -> Entry? {
        // From the file system, not `resourceValues`: a URL caches those,
        // and answers a replaced file with the date it read before.
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let cached = cache.object(forKey: url as NSURL), cached.modified == modified { return cached }
        guard let image = NSImage(contentsOf: url) else {
            cache.removeObject(forKey: url as NSURL)
            return nil
        }
        let entry = Entry(image: image, modified: modified)
        cache.setObject(entry, forKey: url as NSURL)
        return entry
    }
}
