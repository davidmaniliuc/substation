import Testing
import Foundation
@testable import PS1

/// Builds a throwaway games folder from a list of relative paths. The files are
/// empty: the scanner classifies on extension and directory layout only, and
/// never reads a byte, which is what keeps a scan of a few hundred rips fast.
private func makeGamesFolder(_ paths: [String]) throws -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("games-\(UUID().uuidString)")
    for path in paths {
        let file = root.appendingPathComponent(path)
        try fm.createDirectory(at: file.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data().write(to: file)
    }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func scannerPairsACueWithItsBinAsOneEntry() throws {
    let root = try makeGamesFolder(["Croc/Croc.cue", "Croc/Croc.bin"])
    defer { try? FileManager.default.removeItem(at: root) }

    let entries = GameScanner.scan(root: root)

    #expect(entries.count == 1)
    #expect(entries.first?.title == "Croc")
    #expect(entries.first?.kind == .cue)
}

@Test func scannerFindsGamesNestedSeveralLevelsDeep() throws {
    let root = try makeGamesFolder([
        "PS1/A-M/Croc/Croc.cue",
        "PS1/N-Z/Spyro/Spyro.cue",
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(GameScanner.scan(root: root).map(\.title) == ["Croc", "Spyro"])
}

@Test func scannerAcceptsABinWithNoCueInItsFolder() throws {
    let root = try makeGamesFolder(["Loose/Some Game (USA).bin"])
    defer { try? FileManager.default.removeItem(at: root) }

    let entries = GameScanner.scan(root: root)

    #expect(entries.count == 1)
    #expect(entries.first?.title == "Some Game (USA)")
    #expect(entries.first?.kind == .bin)
}

/// A directory holding several games at once: every cue counts, and the bins
/// are all suppressed because the directory has at least one cue.
@Test func scannerSuppressesEveryBinInADirectoryThatHasAnyCue() throws {
    let root = try makeGamesFolder([
        "Flat/Croc.cue", "Flat/Croc.bin",
        "Flat/Spyro.cue", "Flat/Spyro.bin",
        "Flat/Orphan.bin",
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(GameScanner.scan(root: root).map(\.title) == ["Croc", "Spyro"])
}

@Test func scannerIgnoresHiddenAndUnrelatedFiles() throws {
    let root = try makeGamesFolder([
        "Croc/Croc.cue",
        "Croc/.DS_Store",
        "Croc/Croc.sbi",
        "Croc/readme.txt",
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(GameScanner.scan(root: root).map(\.title) == ["Croc"])
}

@Test func scannerMatchesExtensionsCaseInsensitively() throws {
    let root = try makeGamesFolder(["Loud/GAME.CUE"])
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(GameScanner.scan(root: root).map(\.title) == ["GAME"])
}

@Test func scannerSortsNaturallyRegardlessOfCase() throws {
    let root = try makeGamesFolder([
        "a/spyro.cue", "b/Croc.cue", "c/Tomb Raider.cue",
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(GameScanner.scan(root: root).map(\.title)
        == ["Croc", "spyro", "Tomb Raider"])
}

@Test func scannerReturnsNothingForAnEmptyFolder() throws {
    let root = try makeGamesFolder([])
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(GameScanner.scan(root: root).isEmpty)
}

@Test func scannerReturnsNothingForAFolderThatDoesNotExist() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("no-such-\(UUID().uuidString)")
    #expect(GameScanner.scan(root: missing).isEmpty)
}

@Test func scannerListsALoneChd() throws {
    let root = try makeGamesFolder(["GTA/grandtheftauto.chd"])
    defer { try? FileManager.default.removeItem(at: root) }
    let entries = GameScanner.scan(root: root)
    #expect(entries.map(\.title) == ["grandtheftauto"])
    #expect(entries.first?.kind == .chd)
}

@Test func scannerShowsACueAndItsSameNamedChdOnce() throws {
    let root = try makeGamesFolder(["Croc/Croc.cue", "Croc/Croc.bin", "Croc/Croc.chd"])
    defer { try? FileManager.default.removeItem(at: root) }
    let entries = GameScanner.scan(root: root)
    #expect(entries.count == 1)
    #expect(entries.first?.kind == .cue)
}

@Test func scannerPrefersAChdOverASameNamedLoneBin() throws {
    let root = try makeGamesFolder(["Loose/Game.bin", "Loose/Game.chd"])
    defer { try? FileManager.default.removeItem(at: root) }
    let entries = GameScanner.scan(root: root)
    #expect(entries.count == 1)
    #expect(entries.first?.kind == .chd)
}

@Test func scannerKeepsADifferentlyNamedChdBesideACue() throws {
    let root = try makeGamesFolder(["Mixed/Croc.cue", "Mixed/Croc.bin", "Mixed/Spyro.chd"])
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(GameScanner.scan(root: root).map(\.title) == ["Croc", "Spyro"])
}

/// A CHD the core refuses still shows: unidentified, never dropped.
@Test func scannerKeepsAChdItCannotIdentify() throws {
    let root = try makeGamesFolder(["Old/Old.chd"])
    defer { try? FileManager.default.removeItem(at: root) }
    let entries = GameScanner.scan(root: root)
    #expect(entries.count == 1)
    #expect(entries.first?.serial == nil)
}

/// A PS-X EXE header with a 16-byte payload: what `ps1_identify_exe` accepts.
func psExe(marker: String = "") -> Data {
    var bytes = [UInt8](repeating: 0, count: 0x800 + 16)
    bytes.replaceSubrange(0..<8, with: Array("PS-X EXE".utf8))
    func put(_ at: Int, _ v: UInt32) {
        for i in 0..<4 { bytes[at + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(i))) }
    }
    put(0x10, 0x8001_0000)
    put(0x18, 0x8001_0000)
    bytes.replaceSubrange(0x4C..<(0x4C + marker.utf8.count), with: Array(marker.utf8))
    return Data(bytes)
}

/// A Psy-Q CPE: load four bytes at 0x80010000, set the PC there, end.
private let cpe = Data([0x43, 0x50, 0x45, 0x01,
                        1, 0x00, 0x00, 0x01, 0x80, 4, 0, 0, 0, 0xDE, 0xAD, 0xBE, 0xEF,
                        3, 0x90, 0x00, 0x00, 0x00, 0x01, 0x80,
                        0])

@Test func scannerListsOnlyExecutablesItCanBoot() throws {
    let root = try makeGamesFolder([])
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("Homebrew")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try psExe(marker: "Sony Computer Entertainment Inc. for Europe area").write(to: dir.appendingPathComponent("hello.exe"))
    try cpe.write(to: dir.appendingPathComponent("hello.cpe"))
    try Data("MZ\u{90}\0This program cannot be run in DOS mode.".utf8).write(to: dir.appendingPathComponent("setup.exe"))
    try psExe().write(to: dir.appendingPathComponent("libps.exe"))

    let entries = GameScanner.scan(root: root)

    #expect(entries.map(\.url.lastPathComponent).sorted() == ["hello.cpe", "hello.exe"])
    #expect(entries.allSatisfy { $0.kind == .exe && $0.title == "hello" && $0.serial == nil })
    #expect(entries.first { $0.url.pathExtension == "exe" }?.identity.region == .europe)
}

/// A `libps.exe` the core would refuse is left out rather than handed over,
/// or one junk file would stop every program in its folder from loading.
@MainActor @Test func onlyAPsExeLibpsIsLoaded() throws {
    let root = try makeGamesFolder([])
    defer { try? FileManager.default.removeItem(at: root) }
    let program = root.appendingPathComponent("hello.exe")
    try psExe().write(to: program)
    let libps = root.appendingPathComponent("libps.exe")

    try Data("MZ\u{90}\0".utf8).write(to: libps)
    #expect(EmulatorViewModel.libps(forExe: program) == nil)
    try cpe.write(to: libps)
    #expect(EmulatorViewModel.libps(forExe: program) == nil)
    try psExe().write(to: libps)
    #expect(EmulatorViewModel.libps(forExe: program) != nil)
}

/// One stem in one folder is one game, whatever it was converted to: the
/// cue wins over everything, and a CloneCD set's `.img` is never a game.
@Test func scannerPrefersTheCueOverACloneCDSetOfItsStem() throws {
    let root = try makeGamesFolder(["A/a.cue", "A/a.bin", "A/a.ccd", "A/a.img"])
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(GameScanner.scan(root: root).map(\.url.lastPathComponent) == ["a.cue"])
}

@Test func scannerListsACloneCDSetAsItsControlFile() throws {
    let root = try makeGamesFolder(["B/b.ccd", "B/b.img", "B/b.sub"])
    defer { try? FileManager.default.removeItem(at: root) }
    let entries = GameScanner.scan(root: root)
    #expect(entries.map(\.url.lastPathComponent) == ["b.ccd"])
    #expect(entries.first?.kind == .ccd)
}

@Test func scannerListsALoneEcm() throws {
    let root = try makeGamesFolder(["C/c.bin.ecm"])
    defer { try? FileManager.default.removeItem(at: root) }
    let entries = GameScanner.scan(root: root)
    #expect(entries.map(\.url.lastPathComponent) == ["c.bin.ecm"])
    #expect(entries.first?.kind == .ecm)
}

@Test func scannerListsALoneIso() throws {
    let root = try makeGamesFolder(["D/d.iso"])
    defer { try? FileManager.default.removeItem(at: root) }
    let entries = GameScanner.scan(root: root)
    #expect(entries.map(\.url.lastPathComponent) == ["d.iso"])
    #expect(entries.first?.kind == .iso)
}

/// An `.ecm` a cue names is that cue's image, not a second game.
@Test func scannerHidesAnEcmItsFoldersCueNames() throws {
    let root = try makeGamesFolder(["E/e.bin.ecm"])
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("FILE \"e.bin.ecm\" BINARY\r\n  TRACK 01 MODE2/2352\r\n    INDEX 01 00:00:00\r\n".utf8)
        .write(to: root.appendingPathComponent("E/e.cue"))
    #expect(GameScanner.scan(root: root).map(\.url.lastPathComponent) == ["e.cue"])
}

/// Below the cue: a `.chd` over a `.ccd`, a `.ccd` over an `.ecm`, and an
/// `.ecm` over a lone image of its stem (`h.bin.ecm` holds `h.bin`).
@Test func scannerKeepsOneEntryPerStemByPrecedence() throws {
    let root = try makeGamesFolder([
        "F/f.chd", "F/f.ccd", "F/f.img",
        "G/g.ccd", "G/g.img", "G/g.bin.ecm",
        "H/h.bin.ecm", "H/h.bin", "H/h.iso",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(GameScanner.scan(root: root).map(\.url.lastPathComponent)
        == ["f.chd", "g.ccd", "h.bin.ecm"])
}
