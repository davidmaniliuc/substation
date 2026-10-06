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

@Test func theGameCountIsSingularForOne() {
    #expect(LibraryFormat.gameCount(1) == "1 game")
    #expect(LibraryFormat.gameCount(16) == "16 games")
    #expect(LibraryFormat.gameCount(0) == "0 games")
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

    let rows = LibraryRow.rows([played, never], entries: played.discs + never.discs,
                               stats: ["SLUS-00530": PlayStats(lastPlayed: when, seconds: 600)])

    #expect(rows[0].serial == "SLUS-00530")
    #expect(rows[0].region == "USA")
    #expect(rows[0].seconds == 600)
    #expect(rows[0].lastPlayedSortKey == when)
    #expect(rows[1].serial == "—")
    #expect(rows[1].seconds == 0)
    #expect(rows[1].lastPlayedSortKey == .distantPast)
}

/// A two-disc game whose discs carry their own serials. The recorder files
/// its stats under disc 1's key, so that record is the game's only one.
private func twoDiscGame() -> (discs: [GameEntry], stats: [String: PlayStats]) {
    let discs = [("1", "SLUS-90001"), ("2", "SLUS-90002")].map { n, serial in
        GameEntry(url: URL(fileURLWithPath: "/g/Epic (Disc \(n)).cue"), isCue: true,
                  identity: DiscIdentity(region: .america, serial: serial, volumeID: nil))
    }
    return (discs, ["SLUS-90001": PlayStats(lastPlayed: Date(timeIntervalSinceReferenceDate: 1), seconds: 3600)])
}

@Test func aMergedMultiDiscRowShowsTheRecordKeyedOnItsFirstDisc() {
    let (discs, stats) = twoDiscGame()
    let rows = LibraryRow.rows(DiscGrouping.group(discs, merging: true), entries: discs, stats: stats)
    #expect(rows.count == 1)
    #expect(rows[0].discs == 2)
    #expect(rows[0].seconds == 3600)
}

/// With merging off each disc is its own row, and every one of them shows
/// the game's single record rather than disc 2 reading as never played.
@Test func everyUnmergedDiscRowShowsItsGamesRecord() {
    let (discs, stats) = twoDiscGame()
    let rows = LibraryRow.rows(DiscGrouping.group(discs, merging: false), entries: discs, stats: stats)
    #expect(rows.map(\.serial) == ["SLUS-90001", "SLUS-90002"])
    #expect(rows.map(\.seconds) == [3600, 3600])
}
