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

    /// The directory a disc groups WITHIN.
    ///
    /// Two layouts are both common and both have to work: every disc loose in
    /// one game folder (Final Fantasy IX here), and one folder PER DISC under
    /// a parent folder named for the game (Final Fantasy VII here). When the
    /// disc's own folder carries a `(Disc N)` token it is named for the disc,
    /// not the game — so the game is its parent, and that is the scope.
    ///
    /// Keeping a scope at all, rather than grouping on the title alone, is
    /// what stops two unrelated rips of one game in different corners of the
    /// library collapsing into a single tile.
    static func scopeDirectory(of url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        return discNumber(in: directory.lastPathComponent) != nil
            ? directory.deletingLastPathComponent()
            : directory
    }

    static func group(_ entries: [GameEntry], merging: Bool) -> [GameGroup] {
        guard merging else {
            return entries
                .map { GameGroup(title: $0.title, discs: [$0]) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }

        // Filename groups stay scoped, so duplicate rips remain separate.
        // Catalogued serials are exact game membership, so they may cross
        // arbitrary user-renamed folders.
        struct Key: Hashable { let directory: String; let title: String }

        var grouped: [Key: [(disc: Int, entry: GameEntry)]] = [:]
        var ungrouped: [GameGroup] = []

        for entry in entries {
            if let title = entry.identity.gameTitle,
               let n = entry.identity.discNumber {
                let key = Key(
                    directory: "",
                    title: title)
                grouped[key, default: []].append((n, entry))
                continue
            }
            guard let n = discNumber(in: entry.title) else {
                ungrouped.append(GameGroup(title: entry.title, discs: [entry]))
                continue
            }
            let key = Key(
                directory: scopeDirectory(of: entry.url).standardizedFileURL.path,
                title: baseTitle(entry.title))
            grouped[key, default: []].append((n, entry))
        }

        let merged = grouped.map { key, discs in
            let sorted = discs.sorted { $0.disc < $1.disc }
            // A database key makes membership precise, but a user rename
            // remains their library's display name. Filename groups retain
            // their token-stripped key as their display title.
            let title = sorted[0].entry.identity.gameTitle == nil
                ? key.title
                : sorted[0].entry.title
            return GameGroup(title: title,
                             // `map { $0.entry }`, not `map(\.entry)`: Swift has no
                             // key paths into tuple elements.
                             discs: sorted.map { $0.entry })
        }

        return (merged + ungrouped)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
