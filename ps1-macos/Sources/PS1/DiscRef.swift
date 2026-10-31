import Foundation

/// One disc on the host: a file, and which disc of it. Only an eboot holds
/// more than one, so `disc` (0-based) is 0 for every other file.
struct DiscRef: Hashable, Sendable {
    let url: URL
    let disc: Int

    init(url: URL, disc: Int = 0) {
        self.url = url
        self.disc = disc
    }
}
