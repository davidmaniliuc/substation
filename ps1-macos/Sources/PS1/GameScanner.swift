import Foundation

/// Walks a games folder and decides what counts as one game.
///
/// A game is a `.cue`, a `.chd` or a lone `.bin`. The `.bin` rule is
/// per-DIRECTORY: a `.bin` counts only when its own directory holds no `.cue`
/// at all. Nearly every rip is a cue plus the bin it names, so listing both
/// would show every game twice; a lone bin is still playable (as a single
/// data track at LBA 0) and must not disappear. A converted copy kept beside
/// its original is the same game, matched on the file stem: the cue wins over
/// its `.chd`, and a `.chd` wins over a lone `.bin` of its name. A `.chd` of
/// another name is another game.
///
/// Every entry is also identified from the disc itself as it is found, which
/// is what gives covers a key that survives a rename.
enum GameScanner {
    private static let cueExtension = "cue"
    private static let binExtension = "bin"
    private static let chdExtension = "chd"

    static func scan(root: URL) -> [GameEntry] {
        let fm = FileManager.default
        guard let walk = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var cues: [URL: [URL]] = [:]
        var bins: [URL: [URL]] = [:]
        var chds: [URL: [URL]] = [:]

        for case let url as URL in walk {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile == true else { continue }
            let directory = url.deletingLastPathComponent().standardizedFileURL

            switch url.pathExtension.lowercased() {
            case cueExtension: cues[directory, default: []].append(url)
            case binExtension: bins[directory, default: []].append(url)
            case chdExtension: chds[directory, default: []].append(url)
            default: continue
            }
        }

        // Each disc is identified here, once per scan, rather than lazily at
        // display time: the answer keys the cover, and a tile that has to
        // touch the disc to draw itself would pay for it on every render.
        // Mapped rather than read, so the cost is a handful of page faults:
        // see `DiscIdentity.identify(disc:)`.
        func stem(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent.lowercased() }
        func stems(_ urls: [URL]?) -> Set<String> { Set((urls ?? []).map(stem)) }
        func entry(_ url: URL) -> GameEntry {
            GameEntry(url: url, identity: DiscIdentity.identify(disc: url) ?? .unknown)
        }

        var entries = cues.values.flatMap { $0 }.map(entry)
        for (directory, urls) in chds {
            let taken = stems(cues[directory])
            entries += urls.filter { !taken.contains(stem($0)) }.map(entry)
        }
        for (directory, urls) in bins where cues[directory] == nil {
            let taken = stems(chds[directory])
            entries += urls.filter { !taken.contains(stem($0)) }.map(entry)
        }

        return entries.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}
