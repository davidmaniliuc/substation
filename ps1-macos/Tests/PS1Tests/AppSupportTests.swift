import Testing
import Foundation
@testable import PS1

private func makeRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("appsupport-\(UUID().uuidString)")
}

/// Writes `<root>/<folder>/<component>/<name>` and returns the file's URL.
@discardableResult
private func plant(_ contents: String,
                   as name: String,
                   in folder: String,
                   component: String,
                   under root: URL) throws -> URL {
    let directory = root.appendingPathComponent(folder, isDirectory: true)
        .appendingPathComponent(component, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(name)
    try Data(contents.utf8).write(to: file)
    return file
}

private func read(_ url: URL) -> String? {
    (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
}

@Test func aPS1EraFolderIsMovedUnderSubstation() throws {
    let root = makeRoot()
    try plant("save", as: "card1.mcd", in: "PS1", component: "MemoryCards", under: root)

    #expect(AppSupport.migrate("MemoryCards", in: root))

    let moved = root.appendingPathComponent("Substation/MemoryCards/card1.mcd")
    #expect(read(moved) == "save")
    #expect(!FileManager.default.fileExists(atPath:
        root.appendingPathComponent("PS1/MemoryCards").path))
}

@Test func resolvingTheDirectoryIsWhatPerformsTheMigration() throws {
    // The stores never call `migrate` themselves — they ask for a directory —
    // so the wiring is what has to move the folder, not the mover alone.
    let root = makeRoot()
    try plant("png", as: "SLUS-00530.png", in: "PS1", component: "Covers", under: root)

    let directory = AppSupport.directory("Covers", in: root)

    #expect(directory == root.appendingPathComponent("Substation/Covers", isDirectory: true))
    #expect(read(directory.appendingPathComponent("SLUS-00530.png")) == "png")
}

@Test func anExistingDestinationIsLeftAloneRatherThanMergedInto() throws {
    // A destination that exists is the live data. Merging risks a stale
    // PS1-era card landing on top of a newer save, and there is no way to
    // tell which is which from the filesystem — so the old folder is left
    // where it is, intact, rather than half-consumed.
    let root = makeRoot()
    try plant("old", as: "card1.mcd", in: "PS1", component: "MemoryCards", under: root)
    try plant("new", as: "card1.mcd", in: "Substation", component: "MemoryCards", under: root)

    #expect(!AppSupport.migrate("MemoryCards", in: root))

    #expect(read(root.appendingPathComponent("Substation/MemoryCards/card1.mcd")) == "new")
    #expect(read(root.appendingPathComponent("PS1/MemoryCards/card1.mcd")) == "old")
}

@Test func aFirstLaunchWithNothingToMigrateCreatesNothingAtAll() {
    // Resolving a path must not make one. Each store creates its own folder
    // when it first writes, so a player who has never saved should not find
    // an empty Substation/ — nor a PS1/ that the app has never used — sitting
    // in Application Support from launch one.
    let root = makeRoot()

    _ = AppSupport.directory("Covers", in: root)

    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test func theEmptiedPS1FolderIsRemovedOnlyOnceNothingIsLeftInIt() throws {
    // Each store migrates its own folder, so the first one through must leave
    // the shell standing — removing it there would strand the other store's
    // data where nothing looks for it any more.
    let root = makeRoot()
    try plant("save", as: "card1.mcd", in: "PS1", component: "MemoryCards", under: root)
    try plant("png", as: "SLUS-00530.png", in: "PS1", component: "Covers", under: root)
    let legacy = root.appendingPathComponent("PS1")

    AppSupport.migrate("MemoryCards", in: root)
    #expect(FileManager.default.fileExists(atPath: legacy.path))

    AppSupport.migrate("Covers", in: root)
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
}
