import Foundation

/// One tile in the library: a single game, or the discs of a multi-disc one.
struct GameGroup: Identifiable, Hashable, Sendable {
    let title: String
    let discs: [GameEntry]

    /// The first disc IS the group's identity — for `Identifiable`, and for
    /// the cover, which `CoverStore` keys on a hash of the disc path. Writing
    /// the same image once per disc instead would multiply the stored files
    /// and still have to pick one to read back from.
    var id: String { first.id }
    var first: GameEntry { discs[0] }
}

/// Folds `GameScanner`'s per-file entries into per-game groups.
///
/// A pure function over what the scan already found, so the whole rule is
/// reachable from a test with no filesystem. With `merging` false every group
/// holds exactly one disc, which is what lets `LibraryView` render groups
/// unconditionally instead of carrying two rendering paths.
enum DiscGrouping {
    /// `(Disc 2)`, `(Disk 2)`, `(CD 2)`, `[Disc 2]`, any case. Anchored on the
    /// bracket so "Discovery Channel" is not a disc and neither is "(2)".
    private static let token = try! NSRegularExpression(
        pattern: #"[\(\[]\s*(?:disc|disk|cd)\s*(\d+)\s*[\)\]]"#,
        options: [.caseInsensitive])

    static func discNumber(in title: String) -> Int? {
        let range = NSRange(title.startIndex..., in: title)
        guard let m = token.firstMatch(in: title, range: range),
              let numberRange = Range(m.range(at: 1), in: title) else { return nil }
        return Int(title[numberRange])
    }

    /// The title with its disc token removed and the leftover whitespace
    /// collapsed, so "Game (Disc 1) (USA)" and "Game (Disc 2) (USA)" meet at
    /// "Game (USA)".
    static func baseTitle(_ title: String) -> String {
        let range = NSRange(title.startIndex..., in: title)
        let stripped = token.stringByReplacingMatches(
            in: title, range: range, withTemplate: "")
        return stripped
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func group(_ entries: [GameEntry], merging: Bool) -> [GameGroup] {
        guard merging else {
            return entries
                .map { GameGroup(title: $0.title, discs: [$0]) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }

        // Keyed on the directory as well as the base title: two rips of one
        // game in different folders are two games, which is the same
        // per-directory rule GameScanner applies to cues and bins.
        struct Key: Hashable { let directory: String; let title: String }

        var grouped: [Key: [(disc: Int, entry: GameEntry)]] = [:]
        var ungrouped: [GameGroup] = []

        for entry in entries {
            guard let n = discNumber(in: entry.title) else {
                ungrouped.append(GameGroup(title: entry.title, discs: [entry]))
                continue
            }
            let key = Key(
                directory: entry.url.deletingLastPathComponent().standardizedFileURL.path,
                title: baseTitle(entry.title))
            grouped[key, default: []].append((n, entry))
        }

        let merged = grouped.map { key, discs in
            GameGroup(title: key.title,
                      // `map { $0.entry }`, not `map(\.entry)`: Swift has no
                      // key paths into tuple elements.
                      discs: discs.sorted { $0.disc < $1.disc }.map { $0.entry })
        }

        return (merged + ungrouped)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
