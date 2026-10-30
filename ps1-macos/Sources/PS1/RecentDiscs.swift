import AppKit

/// File ▸ Open Recent: AppKit's recent-documents list, which also fills the
/// Dock menu's recents with no code of ours. AppKit keeps it for any type the
/// app declares in `CFBundleDocumentTypes`, so a `.cue`, `.chd`, `.bin` or
/// PlayStation executable is remembered and nothing else. The executable
/// extensions are Alternate, as `.bin` is: `.exe` and `.elf` are generic,
/// and claiming them would take over unrelated files.
@MainActor struct RecentDiscs {
    let note: (URL) -> Void
    let clear: () -> Void
    /// Newest first, as AppKit keeps them.
    let urls: () -> [URL]

    /// The hosted test app shares the bundle id, and so AppKit's list:
    /// it gets one of its own, in memory.
    static var current: RecentDiscs {
        EmulatorViewModel.publishesToSystem ? system : memory()
    }

    static let system = RecentDiscs(
        note: { NSDocumentController.shared.noteNewRecentDocumentURL($0) },
        clear: { NSDocumentController.shared.clearRecentDocuments(nil) },
        urls: { NSDocumentController.shared.recentDocumentURLs })

    static func memory() -> RecentDiscs {
        final class Box { var urls: [URL] = [] }
        let box = Box()
        return RecentDiscs(
            note: { url in box.urls = [url] + box.urls.filter { $0 != url } },
            clear: { box.urls = [] },
            urls: { box.urls })
    }
}
