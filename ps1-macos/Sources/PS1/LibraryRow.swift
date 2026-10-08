import Foundation

/// How the list view writes its columns. Pure functions, so the wording is
/// pinned by tests rather than by screenshots.
enum LibraryFormat {
    static func playTime(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        let minutes = Int(seconds) / 60
        if minutes == 0 { return "< 1 min" }
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// "Today" and "Yesterday" by calendar day, a day and month within the
    /// current year, and the year as well beyond it.
    static func lastPlayed(_ date: Date?, now: Date,
                           calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let date else { return "—" }
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .day().month(.abbreviated)
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return date.formatted(style)
    }

    /// The toolbar's subtitle under "Library".
    static func gameCount(_ count: Int) -> String {
        count == 1 ? "1 game" : "\(count) games"
    }

    static func region(_ region: DiscIdentity.Region?) -> String {
        switch region {
        case .america: "USA"
        case .europe: "Europe"
        case .japan: "Japan"
        case nil: "—"
        }
    }
}

/// One line of the list view: a game group joined to its play stats, with
/// every column as a comparable value so `Table` can sort on it.
struct LibraryRow: Identifiable {
    let group: GameGroup
    let title: String
    let region: String
    let discs: Int
    let lastPlayed: Date?
    let seconds: TimeInterval

    var id: GameGroup.ID { group.id }
    /// A game never played sorts as the oldest.
    var lastPlayedSortKey: Date { lastPlayed ?? .distantPast }

    /// `entries` is the whole library, so every disc can be traced to the
    /// key its game's stats are filed under: the resume key of its MERGED
    /// game's first disc, as the recorder files them (`siblingDiscs` always
    /// merges). With Merge Multi-Disc Games off, disc 2 is a row of its own
    /// and still shows the one record its game has.
    static func rows(_ groups: [GameGroup], entries: [GameEntry],
                     stats: [String: PlayStats]) -> [LibraryRow] {
        let keys = statsKeys(entries)
        return groups.map { group in
            let record = stats[keys[group.first.id] ?? SaveStateStore.key(for: group.first)]
            return LibraryRow(
                group: group,
                title: group.title,
                region: LibraryFormat.region(group.first.identity.region),
                discs: group.discs.count,
                lastPlayed: record?.lastPlayed,
                seconds: record?.seconds ?? 0)
        }
    }

    /// Each disc's stats key, by entry id.
    private static func statsKeys(_ entries: [GameEntry]) -> [GameEntry.ID: String] {
        var keys: [GameEntry.ID: String] = [:]
        for game in DiscGrouping.group(entries, merging: true) {
            let key = SaveStateStore.key(for: game.first)
            for disc in game.discs { keys[disc.id] = key }
        }
        return keys
    }
}
