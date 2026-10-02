import CryptoKit
import Foundation

/// One playable disc in the library.
///
/// The file path is the entry's identity, because a library is a set of files.
/// The TITLE still comes from the filename — a PS1 disc records none — but the
/// disc's own serial and region are read off the disc by `GameScanner`, and
/// the serial is what makes a cover survive the rip being moved or renamed.
struct GameEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let title: String
    let isCue: Bool
    /// What the disc says it is. Empty for a disc that could not be read, or
    /// one that answers nothing — every caller has a filename fallback.
    let identity: DiscIdentity

    var id: String { url.path }
    var serial: String? { identity.serial }

    /// The fallback key for a disc that names no serial. Hashed rather than
    /// escaped: a path can be any length and hold any character, and a
    /// fixed-width hex name is a filename on every volume.
    var pathKey: String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    init(url: URL, isCue: Bool, identity: DiscIdentity = .unknown) {
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
        self.isCue = isCue
        self.identity = identity
    }
}
