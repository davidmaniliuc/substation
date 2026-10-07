import Testing
import Foundation
@testable import PS1

struct LibrarySearchTests {
    private let library: [GameGroup] = [
        GameGroup(title: "Final Fantasy IX (France)", discs: [
            GameEntry(url: URL(fileURLWithPath: "/games/Final Fantasy IX (France) (Disc 1).cue")),
            GameEntry(url: URL(fileURLWithPath: "/games/Final Fantasy IX (France) (Disc 3).cue")),
        ]),
        GameGroup(title: "Crash Bandicoot (USA)", discs: [
            GameEntry(url: URL(fileURLWithPath: "/games/Crash Bandicoot (USA).cue"),
                      identity: DiscIdentity(region: .america, serial: "SCUS-94900", volumeID: nil,
                                             gameTitle: nil, discNumber: nil)),
        ]),
        GameGroup(title: "Pokémon Stadium", discs: [
            GameEntry(url: URL(fileURLWithPath: "/games/Pokémon Stadium.cue")),
        ]),
    ]

    private func titles(_ query: String) -> [String] {
        LibrarySearch.filter(library, query: query).map(\.title)
    }

    @Test func anEmptyOrBlankQueryKeepsEveryGame() {
        #expect(titles("").count == 3)
        #expect(titles("   ").count == 3)
    }

    @Test func everyWordMustMatchInAnyOrderAndAnyCase() {
        #expect(titles("fantasy final") == ["Final Fantasy IX (France)"])
        #expect(titles("CRASH usa") == ["Crash Bandicoot (USA)"])
        #expect(titles("crash france").isEmpty)
    }

    /// A merged tile's title drops the disc token, so "disc 3" is found
    /// only through the disc's own title.
    @Test func aMergedGameIsFoundByADiscTitle() {
        #expect(titles("fantasy disc 3") == ["Final Fantasy IX (France)"])
    }

    @Test func aGameIsFoundByItsSerial() {
        #expect(titles("scus-94900") == ["Crash Bandicoot (USA)"])
    }

    @Test func accentsAreIgnored() {
        #expect(titles("pokemon") == ["Pokémon Stadium"])
    }
}

struct LibrarySearchLayoutTests {
    @Test func aWideWindowKeepsTheFieldAndANarrowOneFoldsIt() {
        #expect(!LibrarySearchLayout.folds(width: 1200, viewMode: .grid))
        #expect(LibrarySearchLayout.folds(width: 640, viewMode: .grid))
    }

    /// List view has no slider, so it keeps the field in a narrower window.
    @Test func listViewHasRoomForTheFieldEarlier() {
        #expect(LibrarySearchLayout.folds(width: 700, viewMode: .grid))
        #expect(!LibrarySearchLayout.folds(width: 700, viewMode: .list))
    }
}
