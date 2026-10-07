import Foundation

/// The toolbar search's rule, as Finder's: every word typed must appear
/// somewhere in the game, in any order, ignoring case and accents. A game is
/// its tile's title, each disc's own title and each disc's serial, so
/// "ff9 disc 3" and "SLES-02965" both find a merged Final Fantasy IX.
enum LibrarySearch {
    static func filter(_ groups: [GameGroup], query: String) -> [GameGroup] {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return groups }
        return groups.filter { group in
            let fields = [group.title] + group.discs.flatMap { [$0.title, $0.serial ?? ""] }
            return words.allSatisfy { word in
                fields.contains { $0.localizedStandardContains(word) }
            }
        }
    }
}
