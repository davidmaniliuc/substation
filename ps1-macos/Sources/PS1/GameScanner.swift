import Foundation

/// Walks a games folder and decides what counts as one game.
///
/// The rule is per-DIRECTORY, not per-file: a `.bin` is a game only when its
/// own directory holds no `.cue` at all. Nearly every rip is a cue plus the
/// bin it names, so listing both would show every game twice; a lone bin is
/// still playable (as a single data track at LBA 0) and must not disappear.
///
/// Every entry is also identified from the disc itself as it is found, which
/// is what gives covers a key that survives a rename.
enum GameScanner {
    private static let cueExtension = "cue"
    private static let binExtension = "bin"

    static func scan(root: URL) -> [GameEntry] {
        let fm = FileManager.default
        guard let walk = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var cues: [URL: [URL]] = [:]
        var bins: [URL: [URL]] = [:]

        for case let url as URL in walk {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile == true else { continue }
            let directory = url.deletingLastPathComponent().standardizedFileURL

            switch url.pathExtension.lowercased() {
            case cueExtension: cues[directory, default: []].append(url)
            case binExtension: bins[directory, default: []].append(url)
            default: continue
            }
        }

        // Each disc is identified here, once per scan, rather than lazily at
        // display time: the answer keys the cover, and a tile that has to
        // touch the disc to draw itself would pay for it on every render.
        // Mapped rather than read, so the cost is a handful of page faults —
        // see `DiscIdentity.identify(disc:)`.
        var entries = cues.values.flatMap { $0 }.map {
            GameEntry(url: $0, isCue: true, identity: DiscIdentity.identify(disc: $0) ?? .unknown)
        }
        for (directory, urls) in bins where cues[directory] == nil {
            entries += urls.map {
                GameEntry(url: $0, isCue: false,
                          identity: DiscIdentity.identify(disc: $0) ?? .unknown)
            }
        }

        return entries.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}
