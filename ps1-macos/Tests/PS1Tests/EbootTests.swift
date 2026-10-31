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
@Test func anEbootsSiblingsAreItsDiscsLabelledBySFO() throws {
    let root = try ebootFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Game.pbp")

    let siblings = EmulatorViewModel.siblingDiscs(of: url, entries: GameScanner.scan(root: root))

    #expect(siblings.map(\.changeDiscLabel) == ["Fixture (Disc 1)", "Fixture (Disc 2)"])
    // The title is what the disc's identity gives, as for any other disc.
    #expect(siblings.map(\.title) == ["Game", "Game"])
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

    #expect(siblings.map(\.changeDiscLabel) == ["Disc 1", "Disc 2"])
}

/// An eboot's states are filed under its first disc, whichever is in: a
/// running game files them under `SaveStateStore.key(for:)` of the first of
/// its discs (`EmulatorViewModel.load`), and these discs carry no serial, so
/// that is the path key.
@MainActor
@Test func anEbootsSecondDiscKeysAsItsFirst() throws {
    let root = try ebootFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Game.pbp")

    let siblings = EmulatorViewModel.siblingDiscs(of: url)

    #expect(siblings.count == 2)
    #expect(siblings.allSatisfy { $0.serial == nil })
    let first = SaveStateStore.key(for: siblings[0])
    #expect(SaveStateStore.key(for: siblings[1]) == first)
    // Opened from disc 1 the game still keys on the first disc of its set.
    #expect(SaveStateStore.key(for: try #require(siblings.first)) == first)
    #expect(SaveStateStore.key(for: EmulatorViewModel.discEntry(for: url, index: 1)) == first)
    // And the key is this eboot's, not one every eboot shares.
    let other = try ebootFolder("Other.pbp")
    defer { try? FileManager.default.removeItem(at: other) }
    let others = EmulatorViewModel.siblingDiscs(of: other.appendingPathComponent("Other.pbp"))
    #expect(SaveStateStore.key(for: others[0]) != first)
}

@MainActor
@Test func anEbootBootsItsFirstDisc() throws {
    let root = try ebootFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Game.pbp")
    #expect(try EmulatorViewModel.bootDisc(url) == DiscRef(url: url, disc: 0))
}

/// Changing to an eboot's second disc hands the session that disc's index and
/// no `.ppf`, which names bytes of disc 1 only; changing back brings it again.
@MainActor
@Test func changingToAnEbootsSecondDiscReadsItWithoutThePatch() throws {
    let root = try ebootFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Game.pbp")
    try Data("PPF30".utf8).write(to: root.appendingPathComponent("Game.ppf"))
    let suite = "eboot-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var autoSave = AutoSaveSetting(key: "a", defaults: defaults)
    autoSave.set(0)
    let store = SaveStateStore(resumeDirectory: root.appendingPathComponent("resume"),
                               slotsDirectory: root.appendingPathComponent("slots"))
    let model = EmulatorViewModel(saveStates: store, autoSave: autoSave)
    let session = ScriptedSession()
    model.installSessionForTesting(session, resumeKey: "k")
    defer { model.ejectNowForTesting() }
    let siblings = EmulatorViewModel.siblingDiscs(of: url)
    let bytes = try Data(contentsOf: fixture)

    model.game!.changeDisc(to: siblings[1])
    let second = try #require(session.pendingSwap?.disc)
    #expect(second.disc == 1)
    #expect(second.bin == bytes)
    #expect(second.ppf == nil)

    model.game!.changeDisc(to: siblings[0])
    let first = try #require(session.pendingSwap?.disc)
    #expect(first.disc == 0)
    #expect(first.ppf == Data("PPF30".utf8))
    #expect(model.errorMessage == nil)
}

/// A playlist naming an eboot names its first disc.
@Test func aPlaylistNamingAnEbootNamesItsFirstDisc() throws {
    let root = try ebootFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("Game.pbp\n".utf8).write(to: root.appendingPathComponent("set.m3u"))

    let playlist = try Playlist.read(root.appendingPathComponent("set.m3u"))

    #expect(playlist.discs == [DiscRef(url: Playlist.canonical(root.appendingPathComponent("Game.pbp")), disc: 0)])
}

/// The SFO title names discs in Change Disc only: the resume sheet is titled
/// as it is for any other disc.
@MainActor
@Test func anEbootsResumeOfferIsNotTitledBySFO() throws {
    let root = try ebootFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let siblings = EmulatorViewModel.siblingDiscs(of: root.appendingPathComponent("Game.pbp"))
    let store = SaveStateStore(resumeDirectory: root.appendingPathComponent("resume"),
                               slotsDirectory: root.appendingPathComponent("slots"))
    try store.saveResume(state: Data([1, 2, 3]), thumbnail: nil, key: SaveStateStore.key(for: siblings[0]))

    let offer = try #require(ResumeOffer.make(launching: siblings[1], siblings: siblings, store: store))

    #expect(offer.title == "Game")
}

/// A playlist naming an eboot governs it: the line means that file's first
/// disc, so the set is the playlist's from either of its discs.
@MainActor
@Test func aPlaylistNamingAnEbootIsTheSetFromEitherDisc() throws {
    let root = try ebootFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: root.appendingPathComponent("y.cue"))
    try Data("Game.pbp\ny.cue\n".utf8).write(to: root.appendingPathComponent("set.m3u"))
    let entries = GameScanner.scan(root: root)
    func names(_ discs: [GameEntry]) -> [String] {
        discs.map { "\($0.url.lastPathComponent)#\($0.disc)" }
    }

    let fromEboot = EmulatorViewModel.siblingDiscs(of: root.appendingPathComponent("Game.pbp"), entries: entries)
    let fromCue = EmulatorViewModel.siblingDiscs(of: root.appendingPathComponent("y.cue"), entries: entries)

    #expect(names(fromEboot) == ["Game.pbp#0", "y.cue#0"])
    #expect(names(fromCue) == ["Game.pbp#0", "y.cue#0"])
}

/// A patch applies to an eboot's first disc only, so only there is one shown.
@Test func anEbootsLaterDiscShowsNoPatch() throws {
    let root = try ebootFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Game.pbp")
    try Data("PPF".utf8).write(to: root.appendingPathComponent("Game.ppf"))
    func patched(_ disc: Int) -> Bool {
        GameInfo.rows(disc: GameEntry(url: url, disc: disc), index: disc, count: 2, bios: nil,
                      played: 0, identityInHeader: true).contains { $0.label == "Patch" }
    }

    #expect(patched(0))
    #expect(!patched(1))
}
