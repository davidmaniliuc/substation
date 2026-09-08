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
    private var bookmark: ScopedBookmark
    private var scanGeneration = 0

    private(set) var entries: [GameEntry] = []
    private(set) var isScanning = false

    /// Called on the main actor after a scan publishes its results, and only
    /// for the scan that wins the `scanGeneration` race — a superseded scan
    /// must not trigger work on entries that are already stale.
    ///
    /// Assigning it after `init` is safe even though `init` may start a scan:
    /// `rescan` publishes from inside a `Task`, which cannot run before the
    /// synchronous caller that created this object has returned.
    var didFinishScan: (() -> Void)?

    var folderURL: URL? { bookmark.url }

    /// `key` defaults to the real defaults key so production call sites are
    /// unaffected; a test passes its own so it can drive a scan without
    /// resolving — or clobbering — the developer's actual games-folder
    /// bookmark.
    init(key: String = "gamesFolderBookmark") {
        bookmark = ScopedBookmark(key: key)
        if bookmark.url != nil { rescan() }
    }

    /// `rescan()` runs from `defer` so a folder that fails to persist (see
    /// `ScopedBookmark.set`) is still scanned for this session — only the
    /// error propagates, not the folder change.
    func setFolder(_ url: URL) throws {
        defer { rescan() }
        try bookmark.set(url)
    }

    /// The walk runs off the main actor so a slow or network volume shows a
    /// spinner instead of freezing the window. `ScopedBookmark` is itself
    /// `Sendable`, so a copy of it — not just the folder URL — crosses into
    /// the detached task and opens/closes the security scope there via
    /// `withAccess`; the result crosses back on `GameEntry`, which is also
    /// `Sendable`.
    ///
    /// `GameScanner.scan` is a synchronous walk with no cancellation
    /// checkpoints, so once started it always runs to completion — there is
    /// no way to interrupt it early, and cancelling the wrapper `Task` would
    /// not reach into it anyway (`Task.detached` is not part of the parent's
    /// tree). What actually prevents a stale result from winning is
    /// `scanGeneration`: every call bumps it and captures the new value, and
    /// a scan only publishes to `entries`/`isScanning` if its captured value
    /// still matches when it finishes. That covers both a folder change
    /// mid-walk and a same-folder refresh (e.g. File > Refresh Library)
    /// mid-walk — either way, an older, slower scan can no longer overwrite a
    /// newer one's results or clear `isScanning` after the newer scan
    /// already has.
    func rescan() {
        scanGeneration += 1
        let generation = scanGeneration
        guard bookmark.url != nil else {
            entries = []
            isScanning = false
            return
        }
        isScanning = true
        let scoped = bookmark
        Task { [weak self] in
            let found = await Task.detached {
                scoped.withAccess { GameScanner.scan(root: $0) } ?? []
            }.value
            guard let self, generation == self.scanGeneration else { return }
            self.entries = found
            self.isScanning = false
            self.didFinishScan?()
        }
    }
}
