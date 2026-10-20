import Foundation

/// The library's sections, the toolbar's tabs. Session state, as the search
/// is: which section is open is a question asked now.
enum LibraryTab: Int, CaseIterable {
    case all, recent, multiDisc

    var title: String {
        switch self {
        case .all: "All Games"
        case .recent: "Recently Played"
        case .multiDisc: "Multi-Disc"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .recent: "clock"
        case .multiDisc: "opticaldisc"
        }
    }
}

/// What each tab holds, and which game the Continue capsule offers. Pure
/// functions over the groups and the play stats, so every rule is reachable
/// from a test without a window.
enum LibraryCollection {
    /// The tabs worth showing: Multi-Disc only while some game has more than
    /// one disc, which with Merge Multi-Disc Games off is never.
    static func tabs(_ groups: [GameGroup]) -> [LibraryTab] {
        groups.contains { $0.discs.count > 1 } ? LibraryTab.allCases : [.all, .recent]
    }

    /// `tab` narrowed to one `tabs` offers: a Multi-Disc tab left open as
    /// merging is turned off falls back to All Games rather than to nothing.
    static func effective(_ tab: LibraryTab, groups: [GameGroup]) -> LibraryTab {
        tabs(groups).contains(tab) ? tab : .all
    }

    /// The games `tab` shows. Recently Played is every game with a play
    /// record, most recent first: that order is the section.
    static func filter(_ groups: [GameGroup], tab: LibraryTab,
                       lastPlayed: (GameGroup) -> Date?) -> [GameGroup] {
        switch tab {
        case .all:
            return groups
        case .recent:
            return groups
                .compactMap { group in lastPlayed(group).map { (group, $0) } }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        case .multiDisc:
            return groups.filter { $0.discs.count > 1 }
        }
    }

    /// The game played last, for the Continue capsule, or nil when nothing
    /// has been played.
    static func continueGroup(_ groups: [GameGroup], lastPlayed: (GameGroup) -> Date?) -> GameGroup? {
        filter(groups, tab: .recent, lastPlayed: lastPlayed).first
    }

    /// Each disc's stats key, by entry id. `entries` is the whole library,
    /// so every disc can be traced to the key its game's stats are filed
    /// under: the resume key of its MERGED game's first disc, as the
    /// recorder files them (`siblingDiscs` always merges). With Merge
    /// Multi-Disc Games off, disc 2 is a tile of its own and still reads
    /// the one record its game has.
    static func statsKeys(_ entries: [GameEntry]) -> [GameEntry.ID: String] {
        var keys: [GameEntry.ID: String] = [:]
        for game in DiscGrouping.group(entries, merging: true) {
            let key = SaveStateStore.key(for: game.first)
            for disc in game.discs { keys[disc.id] = key }
        }
        return keys
    }

    /// `group`'s play record, read under its stats key.
    static func stats(for group: GameGroup, keys: [GameEntry.ID: String],
                      stats: [String: PlayStats]) -> PlayStats? {
        stats[keys[group.first.id] ?? SaveStateStore.key(for: group.first)]
    }
}

/// How the library writes counts and dates. Pure functions, so the wording
/// is pinned by tests rather than by screenshots.
enum LibraryFormat {
    /// The toolbar's subtitle under "Library".
    static func gameCount(_ count: Int) -> String {
        count == 1 ? "1 game" : "\(count) games"
    }

    /// A tile's second line: the disc count of a multi-disc game, else when
    /// it was last played ("2 hours ago", "Yesterday").
    static func tileSubtitle(discs: Int, lastPlayed: Date?, now: Date = .now,
                             locale: Locale = .current) -> String {
        if discs > 1 { return "\(discs) discs" }
        guard let lastPlayed else { return "Not played yet" }
        return capitalisedFirst(relative(lastPlayed, now: now, locale: locale))
    }

    /// "2 hours ago", "yesterday", "last week": the system's named form,
    /// measured from `now` so a test can pin it.
    static func relative(_ date: Date, now: Date = .now, locale: Locale = .current) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.locale = locale
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private static func capitalisedFirst(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
