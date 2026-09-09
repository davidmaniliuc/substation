import Testing
import Foundation
@testable import PS1

/// The rule is a pure fold over what `GameScanner` already found, so it is
/// reachable from a test with no filesystem at all.
struct DiscGroupingTests {
    private func entry(_ path: String) -> GameEntry {
        GameEntry(url: URL(fileURLWithPath: path), isCue: true)
    }

    @Test func foldsTheFourFF9DiscsIntoOneGroup() {
        let discs = (1...4).map {
            entry("/games/FF9/Final Fantasy IX (France) (Disc \($0)).cue")
        }
        let groups = DiscGrouping.group(discs.shuffled(), merging: true)

        #expect(groups.count == 1)
        #expect(groups[0].title == "Final Fantasy IX (France)")
        #expect(groups[0].discs.count == 4)
        // Ordered by disc number, not by whatever order the scan produced.
        #expect(groups[0].discs.map(\.title).first?.hasSuffix("(Disc 1)") == true)
        #expect(groups[0].discs.map(\.title).last?.hasSuffix("(Disc 4)") == true)
    }

    /// A rename must not split a known disc set: serials come from the image,
    /// while filenames are user-controlled metadata.
    @Test func groupsKnownDiscsByDatabaseMetadataBeforeFilenameTokens() {
        let disc1 = GameEntry(
            url: URL(fileURLWithPath: "/games/renamed-a.cue"),
            isCue: true,
            identity: DiscIdentity(region: .europe, serial: "SLES-02965", volumeID: nil,
                                   gameTitle: "Final Fantasy IX (Europe)", discNumber: 1))
        let disc2 = GameEntry(
            url: URL(fileURLWithPath: "/games/renamed-b.cue"),
            isCue: true,
            identity: DiscIdentity(region: .europe, serial: "SLES-12965", volumeID: nil,
                                   gameTitle: "Final Fantasy IX (Europe)", discNumber: 2))

        let groups = DiscGrouping.group([disc2, disc1], merging: true)

        #expect(groups.count == 1)
        #expect(groups[0].title == "renamed-a")
        #expect(groups[0].discs.map(\.serial) == ["SLES-02965", "SLES-12965"])
    }

    @Test func groupsKnownDiscsAcrossArbitrarilyRenamedFolders() {
        let disc1 = GameEntry(
            url: URL(fileURLWithPath: "/games/FF9/first/one.cue"),
            isCue: true,
            identity: DiscIdentity(region: .europe, serial: "SLES-02965", volumeID: nil,
                                   gameTitle: "Final Fantasy IX (Europe)", discNumber: 1))
        let disc2 = GameEntry(
            url: URL(fileURLWithPath: "/games/FF9/second/two.cue"),
            isCue: true,
            identity: DiscIdentity(region: .europe, serial: "SLES-12965", volumeID: nil,
                                   gameTitle: "Final Fantasy IX (Europe)", discNumber: 2))

        let groups = DiscGrouping.group([disc2, disc1], merging: true)

        #expect(groups.count == 1)
        #expect(groups[0].discs.map(\.serial) == ["SLES-02965", "SLES-12965"])
    }

    @Test func mergingOffYieldsOneGroupPerEntry() {
        let discs = (1...4).map { entry("/games/FF9/FF9 (Disc \($0)).cue") }
        let groups = DiscGrouping.group(discs, merging: false)

        #expect(groups.count == 4)
        #expect(groups.allSatisfy { $0.discs.count == 1 })
        // The title is the file's own, untouched -- turning merging off must
        // not leave the base title on a tile that is only one disc.
        #expect(groups[0].title == "FF9 (Disc 1)")
    }

    @Test func acceptsTheOtherTokenSpellings() {
        #expect(DiscGrouping.discNumber(in: "Game (Disc 2)") == 2)
        #expect(DiscGrouping.discNumber(in: "Game (Disk 2)") == 2)
        #expect(DiscGrouping.discNumber(in: "Game (CD 2)") == 2)
        #expect(DiscGrouping.discNumber(in: "Game [Disc 2]") == 2)
        #expect(DiscGrouping.discNumber(in: "Game (disc 2)") == 2)
        #expect(DiscGrouping.discNumber(in: "Game (Disc 12)") == 12)
        #expect(DiscGrouping.discNumber(in: "Game") == nil)
        // "Discovery" is not a disc token, and neither is a bare number.
        #expect(DiscGrouping.discNumber(in: "Discovery Channel") == nil)
        #expect(DiscGrouping.discNumber(in: "Game (2)") == nil)
    }

    @Test func stripsTheTokenFromTheMiddleOfATitle() {
        #expect(DiscGrouping.baseTitle("Game (Disc 1) (USA)") == "Game (USA)")
        #expect(DiscGrouping.baseTitle("Game (USA) (Disc 1)") == "Game (USA)")
    }

    /// The other common layout, and the one Final Fantasy VII ships in here:
    /// one folder PER DISC, all of them under a parent folder named for the
    /// game. A rule that groups only within a single directory never joins
    /// them, because each disc is alone in its own.
    @Test func foldsDiscsThatEachSitInTheirOwnSubfolder() {
        let discs = (1...3).map {
            entry("/games/Final Fantasy VII (USA)/Final Fantasy VII (USA) (Disc \($0))/Final Fantasy VII (USA) (Disc \($0)).cue")
        }
        let groups = DiscGrouping.group(discs.shuffled(), merging: true)

        #expect(groups.count == 1)
        #expect(groups[0].title == "Final Fantasy VII (USA)")
        #expect(groups[0].discs.count == 3)
        #expect(groups[0].discs.map(\.title).first?.hasSuffix("(Disc 1)") == true)
        #expect(groups[0].discs.map(\.title).last?.hasSuffix("(Disc 3)") == true)
    }

    /// The scope is the parent only when the disc's OWN folder is named for the
    /// disc. A folder named for the game stays the scope, so two unrelated
    /// games under one library root do not collapse into each other.
    @Test func aFolderNamedForTheGameIsStillTheScope() {
        let groups = DiscGrouping.group([
            entry("/games/Alpha/Alpha (Disc 1).cue"),
            entry("/games/Alpha/Alpha (Disc 2).cue"),
            entry("/games/Beta/Beta (Disc 1).cue"),
        ], merging: true)

        #expect(groups.count == 2)
        #expect(groups.first { $0.title == "Alpha" }?.discs.count == 2)
        #expect(groups.first { $0.title == "Beta" }?.discs.count == 1)
    }

    @Test func doesNotGroupAcrossDirectories() {
        let groups = DiscGrouping.group([
            entry("/games/a/Game (Disc 1).cue"),
            entry("/games/b/Game (Disc 2).cue"),
        ], merging: true)

        // Two rips of the same game in different folders are two games. This
        // is the same per-directory rule GameScanner already applies.
        #expect(groups.count == 2)
    }

    @Test func anEntryWithNoTokenNeverJoinsAGroup() {
        let groups = DiscGrouping.group([
            entry("/games/x/Game (Disc 1).cue"),
            entry("/games/x/Game (Disc 2).cue"),
            entry("/games/x/Game.cue"),
        ], merging: true)

        #expect(groups.count == 2)
        #expect(groups.contains { $0.discs.count == 2 })
        #expect(groups.contains { $0.title == "Game" && $0.discs.count == 1 })
    }

    @Test func groupsAreSortedByTitle() {
        let groups = DiscGrouping.group([
            entry("/games/z/Spyro.cue"),
            entry("/games/a/Croc.cue"),
        ], merging: true)

        #expect(groups.map(\.title) == ["Croc", "Spyro"])
    }
}
