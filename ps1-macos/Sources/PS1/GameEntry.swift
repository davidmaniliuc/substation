import Foundation

/// One playable disc in the library.
///
/// The file path is the identity. There is no metadata layer — a PS1 disc
/// carries no title or artwork this app reads — so moving or renaming a rip
/// produces a new entry, and its custom cover does not follow it. That is the
/// accepted cost of having no database to keep in sync with the filesystem.
struct GameEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let title: String
    let isCue: Bool

    var id: String { url.path }

    init(url: URL, isCue: Bool) {
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
        self.isCue = isCue
    }
}
