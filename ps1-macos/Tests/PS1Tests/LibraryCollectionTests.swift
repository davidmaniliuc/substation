import Testing
import Foundation
@testable import PS1

private func game(_ title: String, serial: String? = nil) -> GameGroup {
    GameGroup(title: title, discs: [GameEntry(
        url: URL(fileURLWithPath: "/g/\(title).cue"),
        identity: DiscIdentity(region: .america, serial: serial, volumeID: nil))])
}

/// A two-disc game whose discs carry their own serials. The recorder files
/// its stats under disc 1's key, so that record is the game's only one.
private func twoDiscGame() -> (discs: [GameEntry], stats: [String: PlayStats]) {
    let discs = [("1", "SLUS-90001"), ("2", "SLUS-90002")].map { n, serial in
        GameEntry(url: URL(fileURLWithPath: "/g/Epic (Disc \(n)).cue"),
                  identity: DiscIdentity(region: .america, serial: serial, volumeID: nil))
    }
    return (discs, ["SLUS-90001": PlayStats(lastPlayed: Date(timeIntervalSinceReferenceDate: 1), seconds: 3600)])
}

private let day = 86_400.0

struct LibraryCollectionTests {
    @Test func allGamesKeepsTheLibrarysOrder() {
        let groups = [game("Croc"), game("Doom"), game("Rayman")]
        let all = LibraryCollection.filter(groups, tab: .all) { _ in nil }
        #expect(all.map(\.title) == ["Croc", "Doom", "Rayman"])
    }

    /// Recently Played holds only played games, most recent first: that
    /// order is the section.
    @Test func recentlyPlayedIsPlayedGamesNewestFirst() {
        let groups = [game("Croc"), game("Doom"), game("Rayman")]
        let played: [String: Date] = [
            "Croc": Date(timeIntervalSinceReferenceDate: 1 * day),
            "Rayman": Date(timeIntervalSinceReferenceDate: 3 * day),
        ]
        let recent = LibraryCollection.filter(groups, tab: .recent) { played[$0.title] }
        #expect(recent.map(\.title) == ["Rayman", "Croc"])
        #expect(LibraryCollection.continueGroup(groups) { played[$0.title] }?.title == "Rayman")
    }

    @Test func nothingPlayedOffersNoContinue() {
        #expect(LibraryCollection.continueGroup([game("Croc")]) { _ in nil } == nil)
    }

    @Test func multiDiscHoldsOnlyGamesWithMoreThanOneDisc() {
        let (discs, _) = twoDiscGame()
        let groups = DiscGrouping.group(discs, merging: true) + [game("Croc")]
        let multi = LibraryCollection.filter(groups, tab: .multiDisc) { _ in nil }
        #expect(multi.map(\.discs.count) == [2])
    }

    /// With Merge Multi-Disc Games off no tile has two discs, so the tab is
    /// not offered, and one left open falls back to All Games.
    @Test func theMultiDiscTabNeedsAMergedGame() {
        let (discs, _) = twoDiscGame()
        let merged = DiscGrouping.group(discs, merging: true)
        let unmerged = DiscGrouping.group(discs, merging: false)
        #expect(LibraryCollection.tabs(merged) == [.all, .recent, .multiDisc])
        #expect(LibraryCollection.tabs(unmerged) == [.all, .recent])
        #expect(LibraryCollection.effective(.multiDisc, groups: unmerged) == .all)
        #expect(LibraryCollection.effective(.recent, groups: unmerged) == .recent)
    }

    /// A game reads its stats under the resume-state key of its FIRST disc.
    @Test func aGameReadsItsStatsUnderItsFirstDiscsKey() {
        let croc = game("Croc", serial: "SLUS-00530")
        let when = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let keys = LibraryCollection.statsKeys(croc.discs)
        let stats = LibraryCollection.stats(for: croc, keys: keys,
                                            stats: ["SLUS-00530": PlayStats(lastPlayed: when, seconds: 600)])
        #expect(stats?.lastPlayed == when)
        #expect(LibraryCollection.stats(for: game("Doom"), keys: keys, stats: [:]) == nil)
    }

    /// With merging off each disc is its own tile, and every one of them
    /// reads the game's single record rather than disc 2 reading as never
    /// played.
    @Test func everyUnmergedDiscReadsItsGamesRecord() {
        let (discs, stats) = twoDiscGame()
        let keys = LibraryCollection.statsKeys(discs)
        let seconds = DiscGrouping.group(discs, merging: false).map {
            LibraryCollection.stats(for: $0, keys: keys, stats: stats)?.seconds
        }
        #expect(seconds == [3600, 3600])
    }
}

struct LibraryFormatTests {
    @Test func theGameCountIsSingularForOne() {
        #expect(LibraryFormat.gameCount(1) == "1 game")
        #expect(LibraryFormat.gameCount(16) == "16 games")
        #expect(LibraryFormat.gameCount(0) == "0 games")
    }

    /// A multi-disc game names its discs; any other names when it was played.
    @Test func aTilesSecondLineIsItsDiscsOrWhenItWasPlayed() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let english = Locale(identifier: "en_GB")
        #expect(LibraryFormat.tileSubtitle(discs: 4, lastPlayed: now, now: now, locale: english) == "4 discs")
        #expect(LibraryFormat.tileSubtitle(discs: 1, lastPlayed: nil, now: now, locale: english)
                == "Not played yet")
        #expect(LibraryFormat.tileSubtitle(discs: 1, lastPlayed: now - day, now: now, locale: english)
                == "Yesterday")
        #expect(LibraryFormat.tileSubtitle(discs: 1, lastPlayed: now - 2 * 3600, now: now, locale: english)
                == "2 hours ago")
    }
}

struct LibrarySortTests {
    private let groups = [game("Tekken 3"), game("croc"), game("Doom"), game("Tekken")]
    private let stats: [String: PlayStats] = [
        "Doom": PlayStats(lastPlayed: Date(timeIntervalSinceReferenceDate: 2 * 86_400), seconds: 60),
        "croc": PlayStats(lastPlayed: Date(timeIntervalSinceReferenceDate: 5 * 86_400), seconds: 60),
        "Tekken": PlayStats(lastPlayed: nil, seconds: 900),
    ]

    private func titles(_ order: LibrarySort) -> [String] {
        LibraryCollection.sorted(groups, by: order) { stats[$0.title] }.map(\.title)
    }

    /// As Finder sorts names: case ignored, and "Tekken" before "Tekken 3".
    @Test func titleSortsAToZAsFinderDoes() {
        #expect(titles(.title) == ["croc", "Doom", "Tekken", "Tekken 3"])
    }

    /// Newest first; games never played follow, by title.
    @Test func lastPlayedIsNewestFirstAndNeverPlayedLast() {
        #expect(titles(.lastPlayed) == ["croc", "Doom", "Tekken", "Tekken 3"])
    }

    /// Longest first; a tie keeps title order.
    @Test func playTimeIsLongestFirstWithTiesByTitle() {
        #expect(titles(.playTime) == ["Tekken", "croc", "Doom", "Tekken 3"])
    }
}
