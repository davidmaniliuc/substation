import Testing
import Foundation
@testable import PS1

/// A fresh defaults key per test, mirroring `ScopedBookmarkTests`: these
/// write to the real `UserDefaults`, so a shared key would let one test see
/// another's folder — and, before `GameLibrary(key:)` existed, every test
/// here would have shared the developer's own real games-folder bookmark.
private func uniqueKey() -> String { "test-library-\(UUID().uuidString)" }

private func makeGamesFolder(_ paths: [String]) throws -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)")
    for path in paths {
        let file = root.appendingPathComponent(path)
        try fm.createDirectory(at: file.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data().write(to: file)
    }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// A folder wide enough that `GameScanner.scan`'s enumerator — one
/// `resourceValues` stat call per entry — takes measurably longer than a
/// single-file folder. Used to force a genuine reordering in
/// `rescanDiscardsAnOlderOverlappingScan` rather than relying on two
/// near-instant scans happening to finish in call order, which they did even
/// with the generation guard deleted — that ordering is not what the guard
/// protects against, so a test that never forces disorder cannot pin it.
private func makeWideGamesFolder(fileCount: Int) throws -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("library-wide-\(UUID().uuidString)")
    for i in 0..<fileCount {
        let dir = root.appendingPathComponent("dir\(i % 64)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("file\(i).dat"))
    }
    return root
}

/// Proves the injected key actually isolates a `GameLibrary` from the real
/// bookmark: a fresh key with nothing stored under it starts with no folder
/// and no entries, same as `ScopedBookmark`'s own "unused key" case.
@MainActor
@Test func libraryStartsEmptyForAnUnusedKey() {
    let library = GameLibrary(key: uniqueKey())
    #expect(library.folderURL == nil)
    #expect(library.entries.isEmpty)
    #expect(library.isScanning == false)
}

/// Pins the generation guard in `rescan()`: the OLDER of two overlapping
/// scans must not publish, even when it is also the SLOWER one and finishes
/// after the newer scan — which is the case this exercises, deliberately,
/// because it is the only case that can tell the guard apart from mere call
/// order. `scanGeneration` is bumped synchronously inside `rescan()`, before
/// either call's `Task` is even scheduled to run (nothing here awaits between
/// the two `setFolder` calls), so which detached scan finishes first is
/// irrelevant to what SHOULD publish — only the guard makes it irrelevant to
/// what DOES. `folderOne` is built wide (4,000 files) specifically so its
/// scan reliably outlasts `folderTwo`'s single-file scan despite starting
/// first: without that size gap, both scans finish in call order regardless
/// of the guard, which does not distinguish "protected" from "coincidence".
@MainActor
@Test func rescanDiscardsAnOlderOverlappingScan() async throws {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    let folderOne = try makeWideGamesFolder(fileCount: 4000)
    let folderTwo = try makeGamesFolder(["Two/Two.cue"])
    defer {
        try? FileManager.default.removeItem(at: folderOne)
        try? FileManager.default.removeItem(at: folderTwo)
    }

    let library = GameLibrary(key: key)
    try library.setFolder(folderOne)   // generation 1: slow, 4,000-file scan
    try library.setFolder(folderTwo)   // generation 2: fast, one-file scan

    // Wait for generation 2's fast scan to land, then keep waiting past it
    // long enough for generation 1's slow scan to also finish and (with the
    // guard reverted) clobber the result — the assertion below is only a
    // real test of the guard once both scans have actually completed.
    for _ in 0..<400 where library.isScanning || library.entries.isEmpty {
        try await Task.sleep(for: .milliseconds(5))
    }
    try await Task.sleep(for: .milliseconds(500))

    #expect(library.entries.map(\.title) == ["Two"])
    #expect(library.isScanning == false)
}
