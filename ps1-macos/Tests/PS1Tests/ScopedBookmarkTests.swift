import Testing
import Foundation
@testable import PS1

/// A fresh defaults key per test: these write to the real UserDefaults, so
/// sharing a key would let one test see another's folder.
private func uniqueKey() -> String { "test-bookmark-\(UUID().uuidString)" }

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("scoped-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func bookmarkStartsEmptyForAnUnusedKey() {
    let bookmark = ScopedBookmark(key: uniqueKey())
    #expect(bookmark.url == nil)
}

@Test func bookmarkRemembersTheFolderItWasGiven() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }

    var bookmark = ScopedBookmark(key: key)
    try bookmark.set(dir)

    #expect(bookmark.url?.standardizedFileURL == dir.standardizedFileURL)
}

/// The point of a bookmark over a stored path: a NEW instance built from the
/// same key resolves to the same folder, which is what makes the choice
/// survive a relaunch.
@Test func bookmarkResolvesInAFreshInstance() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }

    var written = ScopedBookmark(key: key)
    try written.set(dir)

    let reread = ScopedBookmark(key: key)
    #expect(reread.url?.standardizedFileURL == dir.standardizedFileURL)
}

@Test func withAccessRunsTheBodyAndReturnsItsValue() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }

    var bookmark = ScopedBookmark(key: key)
    try bookmark.set(dir)

    let name = bookmark.withAccess { $0.lastPathComponent }
    #expect(name == dir.lastPathComponent)
}

@Test func withAccessReturnsNilWhenNoFolderIsSet() {
    let bookmark = ScopedBookmark(key: uniqueKey())
    #expect(bookmark.withAccess { _ in 1 } == nil)
}
