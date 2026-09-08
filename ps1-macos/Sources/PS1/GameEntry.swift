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

    init(url: URL, isCue: Bool, identity: DiscIdentity = .unknown) {
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
        self.isCue = isCue
        self.identity = identity
    }
}
