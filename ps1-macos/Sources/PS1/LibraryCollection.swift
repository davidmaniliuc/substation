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

/// The order of the grid, for every tab but Recently Played, whose order is
/// the tab. Session state, as the tab and the search are.
enum LibrarySort: Int, CaseIterable {
    case title, lastPlayed, playTime

    var title: String {
        switch self {
        case .title: "Title"
        case .lastPlayed: "Last Played"
        case .playTime: "Play Time"
        }
    }

    /// The two directions, named for what they mean to this order rather
    /// than as Ascending and Descending: the natural one first.
    func direction(reversed: Bool) -> String {
        switch self {
        case .title: reversed ? "Z to A" : "A to Z"
        case .lastPlayed: reversed ? "Oldest First" : "Newest First"
        case .playTime: reversed ? "Least Played" : "Most Played"
        }
    }
}

/// An order and its direction. `reversed` is relative to the order's
/// natural direction (A to Z, newest first, most played first), so picking
/// an order starts it the way round people expect.
struct LibraryOrder: Equatable {
    var sort = LibrarySort.title
    var reversed = false

    /// A new order starts in its natural direction; picking the open one
    /// changes nothing.
    mutating func pick(_ sort: LibrarySort) {
        guard sort != self.sort else { return }
        self.sort = sort
        reversed = false
    }

    var direction: String { sort.direction(reversed: reversed) }
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

    /// `groups` in `order`. Titles sort as Finder sorts names; the play
    /// orders sort newest or longest first, ties by title. A game never
    /// played follows every played one in BOTH directions, by title: Oldest
    /// First means the oldest of what was played, not a wall of unplayed
    /// games ahead of it.
    static func sorted(_ groups: [GameGroup], by order: LibraryOrder,
                       stats: (GameGroup) -> PlayStats?) -> [GameGroup] {
        let byTitle = { (a: GameGroup, b: GameGroup) in
            a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        func value(_ group: GameGroup) -> Double? {
            switch order.sort {
            case .title: nil
            case .lastPlayed: stats(group)?.lastPlayed?.timeIntervalSinceReferenceDate
            case .playTime: stats(group)?.seconds.nonZero
            }
        }
        guard order.sort != .title else {
            let titled = groups.sorted(by: byTitle)
            return order.reversed ? titled.reversed() : titled
        }
        let played = groups.compactMap { group in value(group).map { (group, $0) } }
            .sorted { a, b in a.1 == b.1 ? byTitle(a.0, b.0) : (a.1 > b.1) != order.reversed }
            .map(\.0)
        let never = groups.filter { value($0) == nil }.sorted(by: byTitle)
        return played + never
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

private extension Double {
    /// Nil for zero: a game with no play time has not been played.
    var nonZero: Double? { self == 0 ? nil : self }
}
