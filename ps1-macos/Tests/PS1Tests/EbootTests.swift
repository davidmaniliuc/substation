import Testing
import Foundation
@testable import PS1

/// The committed two-disc eboot (SFO title "Fixture").
private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("ps1-core/tests/fixtures/two-disc.pbp")

/// A throwaway folder holding the fixture as `name`. With `untitled`, the
/// copy's SFO key `TITLE` is renamed to `TITLX`: the reader looks keys up by
/// name, so the eboot then names no title.
private func ebootFolder(_ name: String = "Game.pbp", untitled: Bool = false) throws -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("eboot-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    var bytes = try Data(contentsOf: fixture)
    if untitled {
        let key = try #require(bytes.range(of: Data("TITLE\0".utf8)))
        bytes.replaceSubrange(key, with: Data("TITLX\0".utf8))
    }
    try bytes.write(to: root.appendingPathComponent(name))
    return root
}

@Test func aMultiDiscEbootIsOneEntryListingEachDisc() throws {
    let root = try ebootFolder()
    defer { try? FileManager.default.removeItem(at: root) }

    let entries = GameScanner.scan(root: root)

    #expect(entries.count == 1)
    let eboot = try #require(entries.first)
    #expect(eboot.playlist.map(\.disc) == [0, 1])
    #expect(eboot.playlist.allSatisfy { $0.url == eboot.url })
    #expect(eboot.discCount == 2)
    #expect(DiscGrouping.group(entries, merging: true).map(\.discCount) == [2])
}

@MainActor
@Test func anEbootsSiblingsAreItsDiscsTitledBySFO() throws {
    let root = try ebootFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Game.pbp")

    let siblings = EmulatorViewModel.siblingDiscs(of: url, entries: GameScanner.scan(root: root))

    #expect(siblings.map(\.title) == ["Fixture (Disc 1)", "Fixture (Disc 2)"])
    #expect(siblings.map(\.disc) == [0, 1])
    #expect(Set(siblings.map(\.id)).count == 2)
    #expect(siblings[0].id == url.path)
    // Found outside the library too.
    #expect(EmulatorViewModel.siblingDiscs(of: url, entries: []).map(\.disc) == [0, 1])
}

@MainActor
@Test func anUntitledEbootsDiscsAreNumbered() throws {
    let root = try ebootFolder(untitled: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let siblings = EmulatorViewModel.siblingDiscs(of: root.appendingPathComponent("Game.pbp"))

    #expect(siblings.map(\.title) == ["Disc 1", "Disc 2"])
}

/// An eboot's states are filed under its first disc, whichever is in.
@MainActor
@Test func anEbootsSecondDiscKeysAsItsFirst() throws {
    let root = try ebootFolder()
    defer { try? FileManager.default.removeItem(at: root) }

    let siblings = EmulatorViewModel.siblingDiscs(of: root.appendingPathComponent("Game.pbp"))

    #expect(siblings.count == 2)
    #expect(siblings[1].pathKey == siblings[0].pathKey)
}

@MainActor
@Test func anEbootBootsItsFirstDisc() throws {
    let url = URL(fileURLWithPath: "/games/Game.pbp")
    #expect(try EmulatorViewModel.bootDisc(url) == DiscRef(url: url, disc: 0))
}

/// A playlist naming an eboot names its first disc.
@Test func aPlaylistNamingAnEbootNamesItsFirstDisc() throws {
    let root = try ebootFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("Game.pbp\n".utf8).write(to: root.appendingPathComponent("set.m3u"))

    let playlist = try Playlist.read(root.appendingPathComponent("set.m3u"))

    #expect(playlist.discs == [DiscRef(url: Playlist.canonical(root.appendingPathComponent("Game.pbp")), disc: 0)])
}
