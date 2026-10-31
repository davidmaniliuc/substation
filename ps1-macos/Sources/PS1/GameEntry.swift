import CryptoKit
import Foundation

/// One playable disc in the library.
///
/// The file path is the entry's identity, because a library is a set of
/// files; a multi-disc eboot's later discs add their number to it.
/// The disc's own serial and region are read off the disc by `GameScanner`;
/// the serial names the TITLE through the core's table (a PS1 disc records
/// none), and it is what makes a cover survive the rip being moved or renamed.
/// An uncatalogued disc is titled by its filename.
struct GameEntry: Identifiable, Hashable, Sendable {
    let url: URL
    /// Which disc of `url` this is: 0 for every file but an eboot's later discs.
    let disc: Int
    let title: String
    /// What the disc says it is. Empty for a disc that could not be read, or
    /// one that answers nothing: every caller has a filename fallback.
    let identity: DiscIdentity
    /// The discs an `.m3u` entry names, or a multi-disc eboot holds, in
    /// order; empty for any other file. The entry stands for them all, and
    /// `identity` is its first disc's.
    let playlist: [DiscRef]

    /// The path alone for a first disc, so no existing id changes.
    var id: String { disc == 0 ? url.path : "\(url.path)#\(disc + 1)" }
    var ref: DiscRef { DiscRef(url: url, disc: disc) }
    var serial: String? { identity.serial }
    var kind: DiscKind { DiscKind(url) }

    /// The fallback key for a disc that names no serial. Hashed rather than
    /// escaped: a path can be any length and hold any character, and a
    /// fixed-width hex name is a filename on every volume. A playlist takes
    /// its first disc's, the disc a running game of it is filed under, and
    /// every disc of an eboot takes the eboot's.
    var pathKey: String {
        let path = playlist.first?.url.path ?? url.path
        return SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `title` overrides the disc's own: an eboot's discs are named by it.
    init(url: URL, disc: Int = 0, identity: DiscIdentity = .unknown,
         playlist: [DiscRef] = [], title: String? = nil) {
        self.url = url
        self.disc = disc
        // A playlist is named for its set, never for its first disc.
        let named = title ?? (playlist.isEmpty ? identity.title : identity.gameTitle)
        self.title = named ?? url.deletingPathExtension().lastPathComponent
        self.identity = identity
        self.playlist = playlist
    }

    /// How many discs the entry is: a playlist's count, else one.
    var discCount: Int { max(playlist.count, 1) }
}
