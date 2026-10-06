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
    let serial: String
    let discs: Int
    let lastPlayed: Date?
    let seconds: TimeInterval

    var id: GameGroup.ID { group.id }
    /// A game never played sorts as the oldest.
    var lastPlayedSortKey: Date { lastPlayed ?? .distantPast }

    static func rows(_ groups: [GameGroup], stats: [String: PlayStats]) -> [LibraryRow] {
        groups.map { group in
            let record = stats[ResumeStateStore.key(for: group.first)]
            return LibraryRow(
                group: group,
                title: group.title,
                region: LibraryFormat.region(group.first.identity.region),
                serial: group.first.serial ?? "—",
                discs: group.discs.count,
                lastPlayed: record?.lastPlayed,
                seconds: record?.seconds ?? 0)
        }
    }
}
