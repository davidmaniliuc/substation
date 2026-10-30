import Testing
import Foundation
@testable import PS1

/// A throwaway folder of files; an empty `Data` makes an empty file.
private func makeFolder(_ files: [String: String]) throws -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("playlist-\(UUID().uuidString)")
    for (path, text) in files {
        let file = root.appendingPathComponent(path)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    return root
}

private func canonical(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
}

@Test func aPlaylistSkipsCommentsAndBlankLinesAndReadsCRLF() throws {
    let root = try makeFolder([
        "set.m3u": "#EXTM3U\r\n\r\n  d1.cue  \r\n# disc two\r\nsub/d2.chd\r\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let playlist = try Playlist.read(root.appendingPathComponent("set.m3u"))

    #expect(playlist.discs.map(canonical) == [
        canonical(root.appendingPathComponent("d1.cue")),
        canonical(root.appendingPathComponent("sub/d2.chd")),
    ])
}

@Test func aPlaylistTakesAbsolutePathsAsTheyAre() throws {
    let elsewhere = try makeFolder(["d1.cue": ""])
    let root = try makeFolder(["set.m3u": elsewhere.appendingPathComponent("d1.cue").path + "\n"])
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: elsewhere)
    }

    let playlist = try Playlist.read(root.appendingPathComponent("set.m3u"))

    #expect(playlist.discs.map(canonical) == [canonical(elsewhere.appendingPathComponent("d1.cue"))])
}

/// A missing disc is not the playlist's problem until it is chosen.
@Test func aPlaylistNamingAMissingDiscStillReads() throws {
    let root = try makeFolder(["set.m3u": "gone.cue\n"])
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(try Playlist.read(root.appendingPathComponent("set.m3u")).discs.count == 1)
}

@Test func aPlaylistRefusesItselfANestedPlaylistAndAnExecutable() throws {
    let root = try makeFolder([
        "self.m3u": "self.m3u\n",
        "nested.m3u": "d1.cue\nother.m3u\n",
        "exe.m3u": "d1.cue\nboot.exe\n",
        "empty.m3u": "# nothing\r\n\r\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    func read(_ name: String) throws { _ = try Playlist.read(root.appendingPathComponent(name)) }

    #expect(throws: Playlist.Error.unsupportedEntry("self.m3u")) { try read("self.m3u") }
    #expect(throws: Playlist.Error.unsupportedEntry("other.m3u")) { try read("nested.m3u") }
    #expect(throws: Playlist.Error.unsupportedEntry("boot.exe")) { try read("exe.m3u") }
    #expect(throws: Playlist.Error.empty) { try read("empty.m3u") }
}

@Test func aPlaylistIsOneGameAndHidesTheDiscsItNames() throws {
    let root = try makeFolder([
        "Game/set.m3u": "d1.cue\nd2.cue\n",
        "Game/d1.cue": "", "Game/d2.cue": "",
        "Other/Other.cue": "",
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let entries = GameScanner.scan(root: root)

    #expect(entries.map(\.title) == ["Other", "set"])
    let set = try #require(entries.first { $0.kind == .m3u })
    #expect(set.discCount == 2)
    #expect(DiscGrouping.group(entries, merging: false).map(\.discCount) == [1, 2])
}

/// A playlist counts as multi-disc even with merging off: it is already one
/// game, whatever its discs are called.
@Test func aPlaylistGameIsOnTheMultiDiscTab() throws {
    let root = try makeFolder(["set.m3u": "d1.cue\nd2.cue\n", "d1.cue": "", "d2.cue": ""])
    defer { try? FileManager.default.removeItem(at: root) }

    let groups = DiscGrouping.group(GameScanner.scan(root: root), merging: false)

    #expect(LibraryCollection.tabs(groups).contains(.multiDisc))
    #expect(LibraryCollection.filter(groups, tab: .multiDisc) { _ in nil }.count == 1)
}

@MainActor
@Test func aPlaylistsDiscsAreItsSiblingsInItsOrder() throws {
    let root = try makeFolder(["set.m3u": "d2.cue\nd1.cue\n", "d1.cue": "", "d2.cue": ""])
    defer { try? FileManager.default.removeItem(at: root) }
    let entries = GameScanner.scan(root: root)

    let fromPlaylist = EmulatorViewModel.siblingDiscs(of: root.appendingPathComponent("set.m3u"),
                                                      entries: entries)
    let fromDisc = EmulatorViewModel.siblingDiscs(of: root.appendingPathComponent("d1.cue"),
                                                  entries: entries)

    #expect(fromPlaylist.map(\.title) == ["d2", "d1"])
    #expect(fromDisc.map(\.title) == ["d2", "d1"])
    #expect(try EmulatorViewModel.bootDisc(root.appendingPathComponent("set.m3u")).lastPathComponent == "d2.cue")
}

/// A disc opened from outside the library still finds the playlist beside it.
@MainActor
@Test func aDiscOutsideTheLibraryFindsThePlaylistBesideIt() throws {
    let root = try makeFolder(["set.m3u": "d1.cue\nd2.cue\n", "d1.cue": "", "d2.cue": ""])
    defer { try? FileManager.default.removeItem(at: root) }

    let siblings = EmulatorViewModel.siblingDiscs(of: root.appendingPathComponent("d2.cue"), entries: [])

    #expect(siblings.map(\.title) == ["d1", "d2"])
}

@MainActor
@Test func aDiscNoPlaylistNamesStillGroupsByFolder() throws {
    let root = try makeFolder([
        "set.m3u": "a.cue\n", "a.cue": "",
        "Game (Disc 1).cue": "", "Game (Disc 2).cue": "",
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let siblings = EmulatorViewModel.siblingDiscs(of: root.appendingPathComponent("Game (Disc 2).cue"))

    #expect(siblings.map(\.title) == ["Game (Disc 1)", "Game (Disc 2)"])
}

@MainActor
@Test func aMissingDiscIsNamedWhenChosen() {
    let error = CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: "/games/FF7/Disc 2.cue"])
    #expect(EmulatorViewModel.describe(error).hasPrefix("“Disc 2.cue” could not be found."))
}
