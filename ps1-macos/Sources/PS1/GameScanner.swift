import Foundation

/// Walks a games folder and decides what counts as one game.
///
/// The rule is per-DIRECTORY, not per-file: a `.bin` is a game only when its
/// own directory holds no `.cue` at all. Nearly every rip is a cue plus the
/// bin it names, so listing both would show every game twice; a lone bin is
/// still playable (as a single data track at LBA 0) and must not disappear.
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

        var entries = cues.values.flatMap { $0 }.map { GameEntry(url: $0, isCue: true) }
        for (directory, urls) in bins where cues[directory] == nil {
            entries += urls.map { GameEntry(url: $0, isCue: false) }
        }

        return entries.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}
