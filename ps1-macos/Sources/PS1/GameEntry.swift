import CryptoKit
import Foundation

/// One playable disc in the library.
///
/// The file path is the entry's identity, because a library is a set of files.
/// The disc's own serial and region are read off the disc by `GameScanner`;
/// the serial names the TITLE through the core's table (a PS1 disc records
/// none), and it is what makes a cover survive the rip being moved or renamed.
/// An uncatalogued disc is titled by its filename.
struct GameEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let title: String
    /// What the disc says it is. Empty for a disc that could not be read, or
    /// one that answers nothing: every caller has a filename fallback.
    let identity: DiscIdentity

    var id: String { url.path }
    var serial: String? { identity.serial }
    var kind: DiscKind { DiscKind(url) }

    /// The fallback key for a disc that names no serial. Hashed rather than
    /// escaped: a path can be any length and hold any character, and a
    /// fixed-width hex name is a filename on every volume.
    var pathKey: String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    init(url: URL, identity: DiscIdentity = .unknown) {
        self.url = url
        self.title = identity.title ?? url.deletingPathExtension().lastPathComponent
        self.identity = identity
    }
}
