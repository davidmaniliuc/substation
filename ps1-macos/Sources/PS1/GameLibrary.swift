import Foundation
import Observation

/// The games folder and everything found under it.
///
/// The scan is not cached between launches on purpose: it is a directory walk
/// with no file reads, and a stale cache of a folder the user edits in Finder
/// is worse than re-walking it.
@MainActor
@Observable
final class GameLibrary {
    private var bookmark = ScopedBookmark(key: "gamesFolderBookmark")
    private var scanTask: Task<Void, Never>?

    private(set) var entries: [GameEntry] = []
    private(set) var isScanning = false

    var folderURL: URL? { bookmark.url }

    init() {
        if bookmark.url != nil { rescan() }
    }

    func setFolder(_ url: URL) {
        bookmark.set(url)
        rescan()
    }

    /// The walk runs off the main actor so a slow or network volume shows a
    /// spinner instead of freezing the window. `ScopedBookmark` is itself
    /// `Sendable`, so a copy of it — not just the folder URL — crosses into
    /// the detached task and opens/closes the security scope there via
    /// `withAccess`; the result crosses back on `GameEntry`, which is also
    /// `Sendable`.
    ///
    /// A rescan cancels whatever scan is still in flight and, on completion,
    /// only publishes if the folder it walked is still the current one.
    /// Without that guard, picking a second folder before the first folder's
    /// walk finishes lets the stale result win the race: it can overwrite the
    /// newer folder's entries, and whichever scan finishes first clears
    /// `isScanning` while the other is still walking — the spinner disappears
    /// early and never comes back.
    func rescan() {
        scanTask?.cancel()
        guard let folder = bookmark.url else {
            entries = []
            isScanning = false
            scanTask = nil
            return
        }
        isScanning = true
        let scoped = bookmark
        scanTask = Task { [weak self] in
            let found = await Task.detached {
                scoped.withAccess { GameScanner.scan(root: $0) } ?? []
            }.value
            guard let self, self.bookmark.url == folder else { return }
            self.entries = found
            self.isScanning = false
        }
    }
}
