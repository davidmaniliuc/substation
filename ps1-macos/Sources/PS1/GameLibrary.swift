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
    /// spinner instead of freezing the window. Only the folder URL crosses the
    /// boundary — `GameEntry` is Sendable, so the result crosses back freely.
    func rescan() {
        guard let folder = bookmark.url else {
            entries = []
            return
        }
        isScanning = true
        Task { [weak self] in
            let found = await Task.detached { [folder] in
                let accessed = folder.startAccessingSecurityScopedResource()
                defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
                return GameScanner.scan(root: folder)
            }.value
            guard let self else { return }
            self.entries = found
            self.isScanning = false
        }
    }
}
