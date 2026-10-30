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
    /// The discs an `.m3u` entry names, in order; empty for any other file.
    /// The entry stands for them all, and `identity` is its first disc's.
    let playlist: [URL]

    var id: String { url.path }
    var serial: String? { identity.serial }
    var kind: DiscKind { DiscKind(url) }

    /// The fallback key for a disc that names no serial. Hashed rather than
    /// escaped: a path can be any length and hold any character, and a
    /// fixed-width hex name is a filename on every volume.
    var pathKey: String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    init(url: URL, identity: DiscIdentity = .unknown, playlist: [URL] = []) {
        self.url = url
        // A playlist is named for its set, never for its first disc.
        let named = playlist.isEmpty ? identity.title : identity.gameTitle
        self.title = named ?? url.deletingPathExtension().lastPathComponent
        self.identity = identity
        self.playlist = playlist
    }

    /// How many discs the entry is: a playlist's count, else one.
    var discCount: Int { max(playlist.count, 1) }
}
