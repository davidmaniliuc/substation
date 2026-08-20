import Testing
import Foundation
@testable import PS1

/// Builds a throwaway games folder from a list of relative paths. The files are
/// empty — the scanner classifies on extension and directory layout only, and
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
    #expect(entries.first?.isCue == true)
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
    #expect(entries.first?.isCue == false)
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
