import AppKit
import QuickLookThumbnailing

/// Finder's thumbnail for a `.cue` or `.chd` in the library: the game's
/// cover. The app writes which cover each disc shows
/// (`ThumbnailIndex`, `Thumbnails/index.json`); this only looks it up, so a
/// disc the app has not scanned, or one with no cover, keeps the document
/// icon.
///
/// Sandboxed, as every extension is. It reads the index and the covers
/// through a read-only exception for those two folders
/// (`Thumbnail.entitlements`), and nothing else.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        guard let cover = Self.cover(for: request.fileURL),
              let image = NSImage(contentsOf: cover),
              image.size.width > 0, image.size.height > 0
        else { return handler(nil, ThumbnailError.noCover) }

        let fit = min(request.maximumSize.width / image.size.width,
                      request.maximumSize.height / image.size.height)
        let size = CGSize(width: (image.size.width * fit).rounded(),
                          height: (image.size.height * fit).rounded())
        let reply = QLThumbnailReply(contextSize: size) {
            image.draw(in: CGRect(origin: .zero, size: size))
            return true
        }
        reply.extensionBadge = request.fileURL.pathExtension.uppercased()
        handler(reply, nil)
    }

    private static func cover(for disc: URL) -> URL? {
        let index = support.appendingPathComponent("Thumbnails/index.json")
        guard let data = try? Data(contentsOf: index),
              let covers = try? JSONDecoder().decode([String: String].self, from: data),
              let path = covers[disc.resolvingSymlinksInPath().standardizedFileURL.path]
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The app's folder in the REAL home: inside the sandbox
    /// `homeDirectoryForCurrentUser` is the extension's own container.
    private static let support: URL = {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) }
            ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Substation", isDirectory: true)
    }()
}

private enum ThumbnailError: Error {
    case noCover
}
