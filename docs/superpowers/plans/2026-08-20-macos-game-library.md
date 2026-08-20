# macOS Game Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the macOS app's single "Open a disc" screen with an onboarding that captures a BIOS folder and a games folder, and a thumbnail library of every game found under that folder.

**Architecture:** Two pure, testable logic units (`GameScanner` walks the games folder; `CoverStore` persists user-supplied cover images) sit under an `@Observable` `GameLibrary`. `EmulatorViewModel`'s stage machine becomes `.onboarding → .library → .playing`, and `ContentView` switches between three views on it. Nothing in `ps1-core`, `ps1-capi`, or the C ABI changes.

**Tech Stack:** Swift 6.4 (SwiftPM, tools-version 6.2), SwiftUI on macOS 26, AppKit (`NSOpenPanel`, `NSWorkspace`, `NSImage`), CryptoKit, swift-testing. No Xcode — Command Line Tools only.

**Spec:** `docs/superpowers/specs/2026-08-20-macos-game-library-design.md`

## Global Constraints

- **`@State` cannot be used at all.** It is a macro in the macOS 26 SDK and its `SwiftUIMacros` plugin ships only with Xcode, which is not installed. All view state lives on the `@Observable` `EmulatorViewModel` or `GameLibrary`; views take `@Bindable` references. `@Observable`, `@Bindable` and `@Namespace` ARE available.
- **Run tests with `ps1-macos/test.sh`**, never bare `swift test`. It carries the `-rpath` and `-plugin-path` flags that Command Line Tools requires; without them the bundle either dies in `dlopen` or silently expands `@Test` to nothing.
- **`test.sh` requires `zig-out/lib/libps1core.a`.** If it is missing, run `zig build capi-lib` from the repo root first. It errors out with that message rather than failing obscurely.
- **All commands run from the repo root** (`/Users/david/Documents/develop/zzssxx`).
- **Swift 6 strict concurrency is on.** Anything crossing to a detached task must be `Sendable`; `NSImage`, `NSEvent` and `Notification` are not. Only values (URLs, Strings, structs of those) cross.
- **Match the surrounding style:** doc comments explain *why*, not *what*; no thinking-out-loud comments; no copy-pasted blocks — extract the helper.
- **Commit after every task**, one commit per task, directly on `master`.
- **No file over ~600 lines.**
- **Do not touch** `ps1-core/`, `ps1-capi/`, `MetalDisplayView.swift`, `DisplayShader.swift`, `EmulatorRunner.swift`, `AudioRing.swift`, `AudioOutput.swift`, or `WindowConfigurator.swift`. This plan is the app shell only.

---

### Task 1: `ScopedBookmark` — one security-scoped bookmark mechanism

`BiosLibrary` currently carries its own private `storeBookmark`/`resolveBookmark`/access-scoping statics. The games folder needs the identical mechanism, so it comes out into a value type first.

**Files:**
- Create: `ps1-macos/Sources/PS1/ScopedBookmark.swift`
- Modify: `ps1-macos/Sources/PS1/BiosLibrary.swift` (delete `storeBookmark`, `resolveBookmark`, and the hand-rolled access scoping in `findBIOS`/`read`)
- Test: `ps1-macos/Tests/PS1Tests/ScopedBookmarkTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct ScopedBookmark: Sendable` with `init(key: String)`, `var url: URL? { get }`, `mutating func set(_ url: URL)`, `func withAccess<T>(_ body: (URL) throws -> T) rethrows -> T?`. Tasks 4 and 6 use it.

- [ ] **Step 1: Write the failing test**

Create `ps1-macos/Tests/PS1Tests/ScopedBookmarkTests.swift`:

```swift
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
    bookmark.set(dir)

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
    written.set(dir)

    let reread = ScopedBookmark(key: key)
    #expect(reread.url?.standardizedFileURL == dir.standardizedFileURL)
}

@Test func withAccessRunsTheBodyAndReturnsItsValue() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }

    var bookmark = ScopedBookmark(key: key)
    bookmark.set(dir)

    let name = bookmark.withAccess { $0.lastPathComponent }
    #expect(name == dir.lastPathComponent)
}

@Test func withAccessReturnsNilWhenNoFolderIsSet() {
    let bookmark = ScopedBookmark(key: uniqueKey())
    #expect(bookmark.withAccess { _ in 1 } == nil)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./ps1-macos/test.sh --filter bookmark`
Expected: FAIL — `cannot find 'ScopedBookmark' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ps1-macos/Sources/PS1/ScopedBookmark.swift`:

```swift
import Foundation

/// A remembered folder (or file), stored as a security-scoped bookmark rather
/// than a path.
///
/// The app is not sandboxed today, so a path would work. Bookmarks are used
/// anyway because they also survive the user moving or renaming the folder,
/// and because turning sandboxing on later then becomes a settings change
/// rather than a rewrite of every call site.
struct ScopedBookmark: Sendable {
    private let key: String
    private(set) var url: URL?

    init(key: String) {
        self.key = key
        self.url = Self.resolve(key: key)
    }

    mutating func set(_ url: URL) {
        self.url = url
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Runs `body` inside the bookmark's access scope. Returns nil — rather
    /// than throwing — when nothing is remembered, so "not chosen yet" stays a
    /// value the caller can branch on instead of an error path.
    func withAccess<T>(_ body: (URL) throws -> T) rethrows -> T? {
        guard let url else { return nil }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }

    private static func resolve(key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./ps1-macos/test.sh --filter bookmark`
Expected: PASS, 5 tests.

- [ ] **Step 5: Refactor `BiosLibrary` onto it**

Replace `ps1-macos/Sources/PS1/BiosLibrary.swift`'s `BiosLibrary` class body (keep `BiosRegion` and `BiosError` exactly as they are) with:

```swift
/// Holds the user's BIOS folder, and a single explicitly-chosen BIOS file as a
/// fallback for a folder that yields no regional match.
final class BiosLibrary {
    private var folder = ScopedBookmark(key: "biosFolderBookmark")
    private var explicit = ScopedBookmark(key: "biosExplicitBookmark")

    var folderURL: URL? { folder.url }

    func setFolder(_ url: URL) {
        folder.set(url)
    }

    /// Fallback for a folder that yields no match: the user picks one file and
    /// that choice is remembered. Validated before it is stored, so a bad pick
    /// fails now rather than at the next boot.
    func setExplicitBIOS(_ url: URL) throws {
        _ = try Self.read(url)
        explicit.set(url)
    }

    func biosData(forDisc name: String) throws -> Data {
        let region = BiosRegion.forDisc(named: name)

        if let match = folder.withAccess({ Self.findBIOS(in: $0, matching: region) }) ?? nil {
            return try Self.read(match)
        }
        if let data = try explicit.withAccess({ try Self.read($0) }) {
            return data
        }
        if folder.url == nil { throw BiosError.noFolderSelected }
        throw BiosError.noMatchingBIOS(region)
    }

    /// Matches on the stem so `SCPH-1001_BIOS_1995_US.bin` is found from
    /// `SCPH-1001` — which is how the files in this repo are actually named.
    private static func findBIOS(in folder: URL, matching region: BiosRegion) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil) else { return nil }

        return entries.first { $0.lastPathComponent.lowercased()
            .hasPrefix(region.rawValue.lowercased()) }
    }

    private static func read(_ url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { throw BiosError.unreadable }
        guard data.count == 524288 else { throw BiosError.wrongSize(data.count) }
        return data
    }
}
```

Note the double-optional flattening (`?? nil`): `withAccess` returns `T?` where
`T` is itself `URL?`. Leaving it as `URL??` compiles but always takes the
"found" branch.

- [ ] **Step 6: Run the whole suite to verify nothing regressed**

Run: `./ps1-macos/test.sh`
Expected: PASS. `BiosLibraryTests` is unchanged and must still be green — especially `scph101IsNotMistakenForScph1001`.

- [ ] **Step 7: Commit**

```bash
git add ps1-macos/Sources/PS1/ScopedBookmark.swift \
        ps1-macos/Sources/PS1/BiosLibrary.swift \
        ps1-macos/Tests/PS1Tests/ScopedBookmarkTests.swift
git commit -m "refactor(macos): extract ScopedBookmark from BiosLibrary"
```

---

### Task 2: `GameEntry` + `GameScanner` — what counts as a game

**Files:**
- Create: `ps1-macos/Sources/PS1/GameEntry.swift`
- Create: `ps1-macos/Sources/PS1/GameScanner.swift`
- Test: `ps1-macos/Tests/PS1Tests/GameScannerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct GameEntry: Identifiable, Hashable, Sendable` with `init(url: URL, isCue: Bool)`, `var id: String`, `let url: URL`, `let title: String`, `let isCue: Bool`; and `enum GameScanner { static func scan(root: URL) -> [GameEntry] }`. Tasks 3, 4, 5 use both.

- [ ] **Step 1: Write the failing test**

Create `ps1-macos/Tests/PS1Tests/GameScannerTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./ps1-macos/test.sh --filter scanner`
Expected: FAIL — `cannot find 'GameScanner' in scope`.

- [ ] **Step 3: Write `GameEntry`**

Create `ps1-macos/Sources/PS1/GameEntry.swift`:

```swift
import Foundation

/// One playable disc in the library.
///
/// The file path is the identity. There is no metadata layer — a PS1 disc
/// carries no title or artwork this app reads — so moving or renaming a rip
/// produces a new entry, and its custom cover does not follow it. That is the
/// accepted cost of having no database to keep in sync with the filesystem.
struct GameEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let title: String
    let isCue: Bool

    var id: String { url.path }

    init(url: URL, isCue: Bool) {
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
        self.isCue = isCue
    }
}
```

- [ ] **Step 4: Write `GameScanner`**

Create `ps1-macos/Sources/PS1/GameScanner.swift`:

```swift
import Foundation

/// Walks a games folder and decides what counts as one game.
///
/// The rule is per-DIRECTORY, not per-file: a `.bin` is a game only when its
/// own directory holds no `.cue` at all. Nearly every rip is a cue plus the
/// bin it names, so listing both would show every game twice; a lone bin is
/// still playable (as a single data track at LBA 0) and must not disappear.
enum GameScanner {
    private static let cueExtension = "cue"
    private static let binExtension = "bin"

    static func scan(root: URL) -> [GameEntry] {
        let fm = FileManager.default
        guard let walk = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var cues: [URL: [URL]] = [:]
        var bins: [URL: [URL]] = [:]

        for case let url as URL in walk {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile == true else { continue }
            let directory = url.deletingLastPathComponent().standardizedFileURL

            switch url.pathExtension.lowercased() {
            case cueExtension: cues[directory, default: []].append(url)
            case binExtension: bins[directory, default: []].append(url)
            default: continue
            }
        }

        var entries = cues.values.flatMap { $0 }.map { GameEntry(url: $0, isCue: true) }
        for (directory, urls) in bins where cues[directory] == nil {
            entries += urls.map { GameEntry(url: $0, isCue: false) }
        }

        return entries.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `./ps1-macos/test.sh --filter scanner`
Expected: PASS, 9 tests.

- [ ] **Step 6: Commit**

```bash
git add ps1-macos/Sources/PS1/GameEntry.swift \
        ps1-macos/Sources/PS1/GameScanner.swift \
        ps1-macos/Tests/PS1Tests/GameScannerTests.swift
git commit -m "feat(macos): scan a games folder recursively into GameEntry list"
```

---

### Task 3: `CoverStore` — user-supplied artwork that survives a rescan

**Files:**
- Create: `ps1-macos/Sources/PS1/CoverStore.swift`
- Test: `ps1-macos/Tests/PS1Tests/CoverStoreTests.swift`

**Interfaces:**
- Consumes: `GameEntry` (Task 2).
- Produces: `final class CoverStore` with `init(directory: URL? = nil)`, `func coverURL(for: GameEntry) -> URL?`, `func setCover(from source: URL, for: GameEntry) throws`, `func removeCover(for: GameEntry) throws`, and `enum CoverError: Error { case undecodable }`. Tasks 5 and 6 use it.

- [ ] **Step 1: Write the failing test**

Create `ps1-macos/Tests/PS1Tests/CoverStoreTests.swift`:

```swift
import Testing
import Foundation
import AppKit
@testable import PS1

private func makeStoreDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("covers-\(UUID().uuidString)")
}

/// A real, decodable image on disk — `setCover` re-encodes through NSImage, so
/// a file of random bytes would (correctly) be rejected.
private func writeTestImage(_ colour: NSColor, size: Int = 8) throws -> URL {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    colour.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    NSGraphicsContext.restoreGraphicsState()

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cover-source-\(UUID().uuidString).png")
    try rep.representation(using: .png, properties: [:])!.write(to: url)
    return url
}

private func makeEntry(_ path: String) -> GameEntry {
    GameEntry(url: URL(fileURLWithPath: path), isCue: true)
}

@Test func coverStoreHasNoCoverBeforeOneIsSet() {
    let store = CoverStore(directory: makeStoreDirectory())
    #expect(store.coverURL(for: makeEntry("/games/Croc/Croc.cue")) == nil)
}

@Test func coverStoreReadsBackWhatItWasGiven() throws {
    let dir = makeStoreDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = CoverStore(directory: dir)
    let entry = makeEntry("/games/Croc/Croc.cue")
    let source = try writeTestImage(.red)
    defer { try? FileManager.default.removeItem(at: source) }

    try store.setCover(from: source, for: entry)

    let cover = try #require(store.coverURL(for: entry))
    #expect(FileManager.default.fileExists(atPath: cover.path))
    #expect(NSImage(contentsOf: cover) != nil)
}

/// The cover must be a COPY: the library cannot break because the user moved
/// the image they picked out of their Downloads folder.
@Test func coverStoreSurvivesTheSourceImageBeingDeleted() throws {
    let dir = makeStoreDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = CoverStore(directory: dir)
    let entry = makeEntry("/games/Croc/Croc.cue")
    let source = try writeTestImage(.blue)

    try store.setCover(from: source, for: entry)
    try FileManager.default.removeItem(at: source)

    #expect(store.coverURL(for: entry) != nil)
}

@Test func coverStoreReplacesAnExistingCover() throws {
    let dir = makeStoreDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = CoverStore(directory: dir)
    let entry = makeEntry("/games/Croc/Croc.cue")
    let first = try writeTestImage(.red, size: 8)
    let second = try writeTestImage(.green, size: 16)
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }

    try store.setCover(from: first, for: entry)
    try store.setCover(from: second, for: entry)

    let cover = try #require(store.coverURL(for: entry))
    let image = try #require(NSImage(contentsOf: cover))
    #expect(image.size.width == 16)
}

@Test func coverStoreRemovesACover() throws {
    let dir = makeStoreDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = CoverStore(directory: dir)
    let entry = makeEntry("/games/Croc/Croc.cue")
    let source = try writeTestImage(.red)
    defer { try? FileManager.default.removeItem(at: source) }

    try store.setCover(from: source, for: entry)
    try store.removeCover(for: entry)

    #expect(store.coverURL(for: entry) == nil)
}

@Test func coverStoreRemoveIsHarmlessWhenThereIsNoCover() throws {
    let dir = makeStoreDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = CoverStore(directory: dir)
    try store.removeCover(for: makeEntry("/games/Croc/Croc.cue"))
}

/// The key is derived from the path, so a rescan — which rebuilds every
/// GameEntry from scratch — finds the same cover again.
@Test func coverStoreKeepsTheCoverAcrossAFreshlyBuiltEntry() throws {
    let dir = makeStoreDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = CoverStore(directory: dir)
    let source = try writeTestImage(.red)
    defer { try? FileManager.default.removeItem(at: source) }

    try store.setCover(from: source, for: makeEntry("/games/Croc/Croc.cue"))

    let rescanned = makeEntry("/games/Croc/Croc.cue")
    #expect(store.coverURL(for: rescanned) != nil)
}

@Test func coverStoreKeepsTwoGamesApart() throws {
    let dir = makeStoreDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = CoverStore(directory: dir)
    let source = try writeTestImage(.red)
    defer { try? FileManager.default.removeItem(at: source) }

    try store.setCover(from: source, for: makeEntry("/games/Croc/Croc.cue"))

    #expect(store.coverURL(for: makeEntry("/games/Spyro/Spyro.cue")) == nil)
}

@Test func coverStoreRejectsAFileThatIsNotAnImage() throws {
    let dir = makeStoreDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = CoverStore(directory: dir)
    let junk = FileManager.default.temporaryDirectory
        .appendingPathComponent("junk-\(UUID().uuidString).png")
    try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: junk)
    defer { try? FileManager.default.removeItem(at: junk) }

    #expect(throws: CoverError.undecodable) {
        try store.setCover(from: junk, for: makeEntry("/games/Croc/Croc.cue"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./ps1-macos/test.sh --filter cover`
Expected: FAIL — `cannot find 'CoverStore' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ps1-macos/Sources/PS1/CoverStore.swift`:

```swift
import AppKit
import CryptoKit
import Foundation

enum CoverError: Error, Equatable {
    case undecodable
}

/// Custom cover images, one per game, on disk.
///
/// A chosen image is COPIED and re-encoded to PNG rather than referenced: the
/// library must not break when the user moves the file they picked out of
/// their Downloads folder, and re-encoding means one decoder path at display
/// time whatever they picked.
final class CoverStore {
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PS1/Covers", isDirectory: true)
    }

    func coverURL(for entry: GameEntry) -> URL? {
        let url = fileURL(for: entry)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func setCover(from source: URL, for entry: GameEntry) throws {
        guard let image = NSImage(contentsOf: source),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw CoverError.undecodable }

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try png.write(to: fileURL(for: entry), options: .atomic)
    }

    func removeCover(for entry: GameEntry) throws {
        guard let url = coverURL(for: entry) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Hashed rather than escaped: a disc path can be any length and hold any
    /// character, and a fixed-width hex name is a filename on every volume.
    private func fileURL(for entry: GameEntry) -> URL {
        let digest = SHA256.hash(data: Data(entry.id.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).png")
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./ps1-macos/test.sh --filter cover`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add ps1-macos/Sources/PS1/CoverStore.swift \
        ps1-macos/Tests/PS1Tests/CoverStoreTests.swift
git commit -m "feat(macos): store per-game cover images keyed by disc path"
```

---

### Task 4: `GameLibrary` — the observable folder + entries

**Files:**
- Create: `ps1-macos/Sources/PS1/GameLibrary.swift`
- Test: none — this is a thin `@Observable` wrapper whose two collaborators (`ScopedBookmark`, `GameScanner`) are already covered, and whose only other behaviour is main-actor scheduling. It is verified by compiling and by the manual smoke check in Task 7.

**Interfaces:**
- Consumes: `ScopedBookmark` (Task 1), `GameScanner`/`GameEntry` (Task 2).
- Produces: `@MainActor @Observable final class GameLibrary` with `var folderURL: URL? { get }`, `private(set) var entries: [GameEntry]`, `private(set) var isScanning: Bool`, `func setFolder(_ url: URL)`, `func rescan()`. Tasks 5 and 6 use it.

- [ ] **Step 1: Write the implementation**

Create `ps1-macos/Sources/PS1/GameLibrary.swift`:

```swift
import Foundation
import Observation

/// The games folder and everything found under it.
///
/// The scan is not cached between launches on purpose: it is a directory walk
/// with no file reads, and a stale cache of a folder the user edits in Finder
/// is worse than re-walking it.
@MainActor
@Observable
final class GameLibrary {
    private var bookmark = ScopedBookmark(key: "gamesFolderBookmark")

    private(set) var entries: [GameEntry] = []
    private(set) var isScanning = false

    var folderURL: URL? { bookmark.url }

    init() {
        if bookmark.url != nil { rescan() }
    }

    func setFolder(_ url: URL) {
        bookmark.set(url)
        rescan()
    }

    /// The walk runs off the main actor so a slow or network volume shows a
    /// spinner instead of freezing the window. Only the folder URL crosses the
    /// boundary — `GameEntry` is Sendable, so the result crosses back freely.
    func rescan() {
        guard let folder = bookmark.url else {
            entries = []
            return
        }
        isScanning = true
        Task { [weak self] in
            let found = await Task.detached { [folder] in
                let accessed = folder.startAccessingSecurityScopedResource()
                defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
                return GameScanner.scan(root: folder)
            }.value
            guard let self else { return }
            self.entries = found
            self.isScanning = false
        }
    }
}
```

- [ ] **Step 2: Verify it compiles and nothing regressed**

Run: `./ps1-macos/test.sh`
Expected: PASS — the whole suite, with the new file compiled into the module. Any Swift 6 concurrency complaint about the detached task is a real bug: fix it here, do not silence it with `@unchecked Sendable`.

- [ ] **Step 3: Commit**

```bash
git add ps1-macos/Sources/PS1/GameLibrary.swift
git commit -m "feat(macos): add GameLibrary, the observable games folder"
```

---

### Task 5: `GameTile` + `LibraryView` — the grid

Built before it is wired in, so it compiles and can be reviewed on its own. The app still shows the old empty state after this task; Task 6 switches to it.

**Files:**
- Create: `ps1-macos/Sources/PS1/GameTile.swift`
- Create: `ps1-macos/Sources/PS1/LibraryView.swift`
- Test: none — views. This build has no SwiftUI test harness (`@State` is unusable and XCTest is absent under Command Line Tools), so everything worth asserting already lives in `GameScanner` and `CoverStore`.

**Interfaces:**
- Consumes: `GameEntry` (Task 2), `CoverStore` (Task 3), `GameLibrary` (Task 4).
- Produces: `struct GameTile: View` with `init(entry: GameEntry, coverURL: URL?, play: @escaping () -> Void, chooseCover: @escaping () -> Void, removeCover: (() -> Void)?)`, and `struct LibraryView: View` with `init(library: GameLibrary, coverURL: @escaping (GameEntry) -> URL?, play:…, chooseCover:…, removeCover:…, chooseFolder:…)`. Task 6 wires both to `EmulatorViewModel`.

- [ ] **Step 1: Write `GameTile`**

Create `ps1-macos/Sources/PS1/GameTile.swift`:

```swift
import AppKit
import SwiftUI

/// One game in the grid: its cover if it has one, a generated placeholder if
/// not.
///
/// The actions arrive as closures rather than a view-model reference so the
/// tile has no opinion about where a game comes from — which is also what lets
/// `removeCover` be nil to mean "there is nothing to remove", instead of the
/// tile reaching into the store to find out.
struct GameTile: View {
    let entry: GameEntry
    let coverURL: URL?
    let play: () -> Void
    let chooseCover: () -> Void
    let removeCover: (() -> Void)?

    private static let aspect: CGFloat = 3.0 / 4.0
    private static let corner: CGFloat = 10

    var body: some View {
        VStack(spacing: 8) {
            art
                .aspectRatio(Self.aspect, contentMode: .fit)
                .clipShape(.rect(cornerRadius: Self.corner))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.corner)
                        .strokeBorder(.white.opacity(0.08))
                }
                .shadow(color: .black.opacity(0.35), radius: 6, y: 3)

            Text(entry.title)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: play)
        .contextMenu {
            Button("Play", action: play)
            Divider()
            Button("Choose Cover Image…", action: chooseCover)
            if let removeCover {
                Button("Remove Custom Cover", action: removeCover)
            }
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
        }
        .help(entry.title)
        .accessibilityLabel(entry.title)
    }

    @ViewBuilder
    private var art: some View {
        if let coverURL, let image = NSImage(contentsOf: coverURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.20), Color(white: 0.12)],
                startPoint: .top, endPoint: .bottom)

            VStack(spacing: 10) {
                Image(systemName: "opticaldisc")
                    .font(.system(size: 34, weight: .thin))
                    .foregroundStyle(.tertiary)
                Text(entry.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            }
        }
    }
}
```

- [ ] **Step 2: Write `LibraryView`**

Create `ps1-macos/Sources/PS1/LibraryView.swift`:

```swift
import SwiftUI

/// The app's home screen: everything under the games folder, as a grid.
struct LibraryView: View {
    @Bindable var library: GameLibrary
    let coverURL: (GameEntry) -> URL?
    let play: (GameEntry) -> Void
    let chooseCover: (GameEntry) -> Void
    let removeCover: (GameEntry) -> Void
    let chooseFolder: () -> Void

    private static let columns = [GridItem(.adaptive(minimum: 132, maximum: 180),
                                           spacing: 20)]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if library.isScanning && library.entries.isEmpty {
                ProgressView("Scanning…")
                    .controlSize(.large)
            } else if library.entries.isEmpty {
                emptyState
            } else {
                grid
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 22) {
                ForEach(library.entries) { entry in
                    GameTile(
                        entry: entry,
                        coverURL: coverURL(entry),
                        play: { play(entry) },
                        chooseCover: { chooseCover(entry) },
                        removeCover: coverURL(entry) == nil
                            ? nil : { removeCover(entry) })
                }
            }
            .padding(24)
            // The title bar is hidden but the window still reserves its height,
            // and the grid scrolls under it.
            .padding(.top, 24)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.tertiary)

            Text(library.folderURL == nil
                 ? "No games folder chosen"
                 : "No games found in \(library.folderURL!.lastPathComponent)")
                .font(.title3.weight(.semibold))

            Text("A game is a .cue file, or a .bin in a folder with no .cue. Subfolders are scanned too.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button("Choose Games Folder…", action: chooseFolder)
                .buttonStyle(.glassProminent)
        }
        .padding(36)
    }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `./ps1-macos/test.sh`
Expected: PASS — the suite is unchanged, but both new views must compile into the module.

- [ ] **Step 4: Commit**

```bash
git add ps1-macos/Sources/PS1/GameTile.swift \
        ps1-macos/Sources/PS1/LibraryView.swift
git commit -m "feat(macos): add the library grid and its game tiles"
```

---

### Task 6: Stage rework — onboarding, and the library as home

**Files:**
- Create: `ps1-macos/Sources/PS1/OnboardingView.swift`
- Delete: `ps1-macos/Sources/PS1/EmptyStateView.swift`
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift`
- Modify: `ps1-macos/Sources/PS1/ContentView.swift`

**Interfaces:**
- Consumes: `GameLibrary` (Task 4), `CoverStore` (Task 3), `LibraryView` (Task 5).
- Produces: `EmulatorViewModel.Stage` = `.onboarding | .library | .playing`; `var library: GameLibrary`, `var covers: CoverStore`, `var hasBIOSFolder: Bool`, `var biosFolderName: String?`, `func chooseGamesFolder()`, `func finishOnboarding()`, `func play(_:)`, `func chooseCover(for:)`, `func removeCover(for:)`, `func coverURL(for:) -> URL?`. Task 7 calls `chooseGamesFolder` and `library.rescan` from the menus.

- [ ] **Step 1: Rework the view model**

In `ps1-macos/Sources/PS1/EmulatorViewModel.swift`, replace the stage enum and the stored properties at the top:

```swift
    enum Stage { case onboarding, library, playing }

    private(set) var stage: Stage = .onboarding
```

and add, next to `private let bios = BiosLibrary()`:

```swift
    let library = GameLibrary()
    let covers = CoverStore()

    /// Bumped whenever a cover is added or removed. The grid keys off it: the
    /// covers live on disk rather than in observable state, so nothing else
    /// would tell SwiftUI that a tile's picture changed.
    private(set) var coverRevision = 0
```

Replace the body of `init()`'s first line with:

```swift
        stage = (bios.folderURL != nil && library.folderURL != nil) ? .library : .onboarding
```

- [ ] **Step 2: Add the new view-model methods**

In the same file, replace `chooseBIOSFolder()` and add the rest after it:

```swift
    var hasBIOSFolder: Bool { bios.folderURL != nil }
    var biosFolderName: String? { bios.folderURL?.lastPathComponent }
    var gamesFolderName: String? { library.folderURL?.lastPathComponent }

    public func chooseBIOSFolder() {
        guard let url = Self.chooseFolder(
            message: "Choose the folder holding your SCPH-*.bin BIOS files"
        ) else { return }
        bios.setFolder(url)
    }

    public func chooseGamesFolder() {
        guard let url = Self.chooseFolder(
            message: "Choose the folder holding your games. Subfolders are scanned too."
        ) else { return }
        library.setFolder(url)
    }

    /// Onboarding's Continue. Guarded rather than trusted: the button is
    /// disabled until both folders are set, but the stage is the thing the
    /// rest of the app branches on, so it checks for itself.
    func finishOnboarding() {
        guard hasBIOSFolder, library.folderURL != nil else { return }
        stage = .library
    }

    func play(_ entry: GameEntry) {
        load(disc: entry.url)
    }

    func coverURL(for entry: GameEntry) -> URL? {
        _ = coverRevision      // read it so SwiftUI re-runs this on a change
        return covers.coverURL(for: entry)
    }

    func chooseCover(for entry: GameEntry) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a cover image for \(entry.title)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try covers.setCover(from: url, for: entry)
            coverRevision += 1
        } catch {
            errorMessage = "That image could not be read."
        }
    }

    func removeCover(for entry: GameEntry) {
        try? covers.removeCover(for: entry)
        coverRevision += 1
    }

    private static func chooseFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = message
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
```

Add `import UniformTypeIdentifiers` at the top of the file — `.image` is a `UTType`.

- [ ] **Step 3: Point `eject()` at the library and stop swallowing keys outside play**

In the same file, change `eject()`'s last line from `stage = .needsDisc` to:

```swift
        stage = .library
```

and guard both key handlers, which currently swallow every mapped key — the
arrow keys are the D-pad, so without this the library grid cannot be scrolled
with the keyboard:

```swift
    func keyDown(_ keyCode: UInt16) -> Bool {
        guard stage == .playing, let b = InputMap.button(forKey: keyCode) else { return false }
        input.press(b)
        runner?.setButtons(input.mask)
        return true
    }

    func keyUp(_ keyCode: UInt16) -> Bool {
        guard stage == .playing, let b = InputMap.button(forKey: keyCode) else { return false }
        input.release(b)
        runner?.setButtons(input.mask)
        return true
    }
```

- [ ] **Step 4: Write `OnboardingView`**

Create `ps1-macos/Sources/PS1/OnboardingView.swift`:

```swift
import SwiftUI

/// First launch. Both folders are captured here; either can be done first.
struct OnboardingView: View {
    @Bindable var model: EmulatorViewModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 22) {
                Image(systemName: "opticaldisc")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.secondary)

                Text("Set up PlayStation")
                    .font(.title2.weight(.semibold))

                VStack(spacing: 14) {
                    row(
                        title: "BIOS folder",
                        detail: "The folder holding your SCPH-*.bin files. The right one is picked per disc — a US BIOS in front of a PAL disc stops at the region-lock screen.",
                        chosen: model.biosFolderName,
                        action: model.chooseBIOSFolder)

                    Divider()

                    row(
                        title: "Games folder",
                        detail: "Scanned recursively for .cue files. A .bin counts too, when its folder has no .cue.",
                        chosen: model.gamesFolderName,
                        action: model.chooseGamesFolder)
                }
                .frame(maxWidth: 420)

                Button("Continue") { model.finishOnboarding() }
                    .buttonStyle(.glassProminent)
                    .disabled(!isReady)
            }
            .padding(36)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            .frame(maxWidth: 520)
        }
    }

    private var isReady: Bool {
        model.hasBIOSFolder && model.gamesFolderName != nil
    }

    private func row(
        title: String, detail: String, chosen: String?, action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: chosen == nil ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(chosen == nil ? .tertiary : Color.accentColor)
                .font(.system(size: 15))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(chosen ?? "Not chosen")
                    .font(.caption)
                    .foregroundStyle(chosen == nil ? .tertiary : .secondary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("Choose…", action: action)
                .buttonStyle(.glass)
        }
    }
}
```

- [ ] **Step 5: Switch `ContentView` onto the three stages**

In `ps1-macos/Sources/PS1/ContentView.swift`, replace the `if/else` inside the `ZStack` with:

```swift
            switch model.stage {
            case .playing:
                if let runner = model.runner {
                    MetalDisplayView(runner: runner)
                        .ignoresSafeArea()

                    GameHUD(model: model, isVisible: model.hudVisible)
                        .padding(.bottom, 28)
                }
            case .library:
                LibraryView(
                    library: model.library,
                    coverURL: { model.coverURL(for: $0) },
                    play: { model.play($0) },
                    chooseCover: { model.chooseCover(for: $0) },
                    removeCover: { model.removeCover(for: $0) },
                    chooseFolder: { model.chooseGamesFolder() })
            case .onboarding:
                OnboardingView(model: model)
            }
```

The `WindowConfigurator` call below it needs no change: `lockAspect: model.stage == .playing` already leaves the library window freely resizable, and `chromeVisible: model.stage != .playing || model.hudVisible` already keeps the traffic lights up outside play.

- [ ] **Step 6: Delete the old empty state**

```bash
rm ps1-macos/Sources/PS1/EmptyStateView.swift
```

- [ ] **Step 7: Verify it compiles and the suite is green**

Run: `./ps1-macos/test.sh`
Expected: PASS. A `cannot find 'EmptyStateView'` error means a reference survived the delete — remove it rather than restoring the file.

- [ ] **Step 8: Commit**

```bash
git add -A ps1-macos/Sources/PS1
git commit -m "feat(macos): onboarding and a library home, replacing the empty state"
```

---

### Task 7: Menus, and a real launch

**Files:**
- Modify: `ps1-macos/Sources/PS1App/PS1App.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: the shipped app.

- [ ] **Step 1: Add the folder and refresh items**

In `ps1-macos/Sources/PS1App/PS1App.swift`, replace the `CommandGroup(replacing: .newItem)` block with:

```swift
            CommandGroup(replacing: .newItem) {
                Button("Open Disc…") { model.openDisc() }
                    .keyboardShortcut("o")

                Divider()

                // ⇧⌘R, not ⌘R: that is Reset, in the Machine menu.
                Button("Refresh Library") { model.library.rescan() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Choose Games Folder…") { model.chooseGamesFolder() }
                Button("Choose BIOS Folder…") { model.chooseBIOSFolder() }
            }
```

- [ ] **Step 2: Build the app**

Run: `zig build capi-lib && zig build macos`
Expected: `==> built /Users/david/Documents/develop/zzssxx/zig-out/PS1.app`.

- [ ] **Step 3: Run the full suite one more time**

Run: `./ps1-macos/test.sh`
Expected: PASS, every test.

- [ ] **Step 4: Smoke check by hand**

Run: `open zig-out/PS1.app`

Walk it: onboarding appears with both rows unchecked and Continue disabled →
choose the repo root as the BIOS folder → choose `games/` as the games folder →
Continue → the grid lists Croc, Crash, Silent Hill, Spyro, Tomb Raider and the
rest, each with a placeholder tile → right-click one, Show in Finder → right-click,
Choose Cover Image…, pick any PNG, the tile updates → right-click, Remove Custom
Cover, the placeholder returns → double-click Croc, it boots and the window locks
to 4:3 → Eject (⌘E), the grid comes back and the window is resizable again →
File ▸ Choose Games Folder… points somewhere else and the grid rescans.

Report anything that misbehaves rather than patching past it.

- [ ] **Step 5: Commit**

```bash
git add ps1-macos/Sources/PS1App/PS1App.swift
git commit -m "feat(macos): menu items for the games folder and a library refresh"
```

- [ ] **Step 6: Update `CLAUDE.md`**

The "The macOS app" section describes an app whose only screen is a disc
picker. Add a paragraph to it recording the shell as it now is:

> The app has three stages — `.onboarding`, `.library`, `.playing`. Onboarding
> captures a BIOS folder and a games folder as security-scoped bookmarks
> (`ScopedBookmark`); the library is the home screen, and `eject()` returns to
> it. `GameScanner`'s rule is per-DIRECTORY: every `.cue` is a game, and a
> `.bin` counts only when its own directory holds no `.cue`, so the usual
> cue+bin pair is one tile rather than two. Covers are user-supplied only — a
> PS1 disc carries no artwork — and are copied into Application Support keyed
> by a SHA-256 of the disc path, so a rescan keeps them and a move loses them.
> The `NSEvent` key monitor is gated on `.playing`: the arrow keys are the
> D-pad, and outside a game they must reach the grid instead.

```bash
git add CLAUDE.md
git commit -m "docs: record the macOS library shell in CLAUDE.md"
```
