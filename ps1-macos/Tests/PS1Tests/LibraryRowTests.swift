import Testing
import Foundation
@testable import PS1

@Test func playTimeReadsInHoursAndMinutes() {
    #expect(LibraryFormat.playTime(nil) == "—")
    #expect(LibraryFormat.playTime(0) == "—")
    #expect(LibraryFormat.playTime(42) == "< 1 min")
    #expect(LibraryFormat.playTime(35 * 60 + 20) == "35 min")
    #expect(LibraryFormat.playTime(12 * 3600) == "12 h")
    #expect(LibraryFormat.playTime(12 * 3600 + 40 * 60 + 59) == "12 h 40 min")
}

@Test func lastPlayedIsRelativeNearbyAndADateBeyond() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let locale = Locale(identifier: "en_GB")
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 12))!
    func at(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 9))!
    }
    #expect(LibraryFormat.lastPlayed(nil, now: now, calendar: calendar, locale: locale) == "—")
    #expect(LibraryFormat.lastPlayed(at(2026, 10, 6), now: now, calendar: calendar, locale: locale) == "Today")
    #expect(LibraryFormat.lastPlayed(at(2026, 10, 5), now: now, calendar: calendar, locale: locale) == "Yesterday")
    #expect(LibraryFormat.lastPlayed(at(2026, 10, 3), now: now, calendar: calendar, locale: locale) == "3 Oct")
    #expect(LibraryFormat.lastPlayed(at(2025, 12, 24), now: now, calendar: calendar, locale: locale) == "24 Dec 2025")
}

@Test func regionNamesTheMarket() {
    #expect(LibraryFormat.region(.america) == "USA")
    #expect(LibraryFormat.region(.europe) == "Europe")
    #expect(LibraryFormat.region(.japan) == "Japan")
    #expect(LibraryFormat.region(nil) == "—")
}

/// A row reads its stats under the resume-state key of the group's FIRST
/// disc, and a game never played sorts as the oldest.
@Test func rowsJoinGroupsToTheirStats() {
    let played = GameGroup(title: "Croc", discs: [GameEntry(
        url: URL(fileURLWithPath: "/g/Croc.cue"), isCue: true,
        identity: DiscIdentity(region: .america, serial: "SLUS-00530", volumeID: nil))])
    let never = GameGroup(title: "Doom", discs: [GameEntry(
        url: URL(fileURLWithPath: "/g/Doom.cue"), isCue: true)])
    let when = Date(timeIntervalSinceReferenceDate: 800_000_000)

    let rows = LibraryRow.rows([played, never],
                               stats: ["SLUS-00530": PlayStats(lastPlayed: when, seconds: 600)])

    #expect(rows[0].serial == "SLUS-00530")
    #expect(rows[0].region == "USA")
    #expect(rows[0].seconds == 600)
    #expect(rows[0].lastPlayedSortKey == when)
    #expect(rows[1].serial == "—")
    #expect(rows[1].seconds == 0)
    #expect(rows[1].lastPlayedSortKey == .distantPast)
}
