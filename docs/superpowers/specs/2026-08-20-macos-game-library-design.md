# macOS Game Library — Design

**Date:** 2026-08-20
**Scope:** `ps1-macos` only. No change to `ps1-core`, `ps1-capi`, or the C ABI.

## Goal

Replace the app's single dead-end "Open a disc" screen with a real shell: a
first-launch onboarding that captures a BIOS folder and a games folder, a
library of every game found under that games folder, and menu items to change
either folder later. The library is the app's home — you leave it to play and
come back to it on eject.

## Non-goals

- No settings/preferences window. Both folders are changed from menu items that
  open an `NSOpenPanel` directly.
- No box art download, and no reading of artwork out of the disc image. A PS1
  disc carries no cover art; the only picture that exists is one the user
  supplies. Tiles show a generated placeholder until then.
- No search field, no sorting controls, no multi-disc grouping. A four-cue game
  shows as four tiles.
- No change to the display path, audio path, input, or window aspect behaviour
  beyond what falls out of the new stage (below).

## Stage machine

`EmulatorViewModel.Stage` grows from three cases to three different ones:

```
.onboarding  -> both folders unset (or BIOS unset) on launch
.library     -> folders set, no disc running
.playing     -> a disc is running
```

- Launch resolves to `.library` when the BIOS folder bookmark resolves and a
  games folder bookmark resolves, `.onboarding` otherwise.
- `eject()` returns to `.library` rather than to an empty screen.
- `ContentView` already passes `lockAspect: stage == .playing` to
  `WindowConfigurator`, so the library window is freely resizable and the game
  window keeps its 4:3 lock with no change to that file.

The old `.needsBIOS` / `.needsDisc` pair and `EmptyStateView` are deleted.

## Components

Each is a separate file under `ps1-macos/Sources/PS1/`, and the two that carry
logic (`GameScanner`, `CoverStore`) have no UI and no main-actor isolation, so
they are testable directly.

### `FolderBookmark.swift`

The security-scoped bookmark store/resolve currently private to `BiosLibrary`,
lifted out so the BIOS folder and the games folder share one mechanism.

```swift
struct FolderBookmark {
    init(key: String)
    var url: URL? { get }        // resolved at init, nil when unset/unresolvable
    mutating func set(_ url: URL)
    func withAccess<T>(_ body: (URL) throws -> T) rethrows -> T?
}
```

`withAccess` wraps `startAccessingSecurityScopedResource` /
`stopAccessingSecurityScopedResource` around a body, which is the pattern
`BiosLibrary.findBIOS` and `BiosLibrary.read` already spell out by hand. The app
is not sandboxed today; bookmarks are kept so that turning sandboxing on later
is a settings change rather than a rewrite.

`BiosLibrary` is refactored onto it and keeps its existing public behaviour —
`BiosLibraryTests` must stay green untouched.

### `GameEntry.swift`

```swift
struct GameEntry: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL          // the .cue (or the .bin when there is no cue)
    let title: String     // filename stem, e.g. "Crash Bandicoot (Europe)"
    let isCue: Bool
}
```

The path is the identity. A rip that is moved or renamed becomes a new entry and
loses its custom cover; that is the accepted trade for having no metadata layer.

### `GameScanner.swift`

```swift
enum GameScanner {
    static func scan(root: URL) -> [GameEntry]
}
```

Pure and synchronous. Recursive `FileManager.enumerator` walk, skipping hidden
files and package descendants. Rule, as decided:

- Every `.cue` at any depth is one entry.
- A `.bin` is an entry **only if its own directory contains no `.cue` at all**,
  so the usual `game.cue` + `game.bin` pair yields one tile, not two.
- Result sorted by `title`, case- and diacritic-insensitive.

A multi-`FILE` cue (Doom, Tekken) is listed like any other. It cannot be loaded
today, and clicking it surfaces the existing `Ps1Error.multiFileCue` message.
Hiding it silently would leave the user hunting for a game they can see in
Finder; an explicit failure is the better report.

### `GameLibrary.swift`

```swift
@MainActor @Observable final class GameLibrary {
    var folderURL: URL? { get }
    var entries: [GameEntry] { get }
    var isScanning: Bool { get }
    func setFolder(_ url: URL)   // persists the bookmark, then rescans
    func rescan()
}
```

Holds a `FolderBookmark(key: "gamesFolderBookmark")`. `rescan()` flips
`isScanning`, runs `GameScanner.scan` off the main actor, and publishes the
result back on it. Scanning a folder of a few hundred rips is a directory walk
with no file reads, so this is fast; the flag exists so a slow network volume
shows a spinner instead of a frozen window.

### `CoverStore.swift`

```swift
final class CoverStore {
    init(directory: URL)   // default: ~/Library/Application Support/PS1/Covers
    func coverURL(for entry: GameEntry) -> URL?      // nil when none set
    func setCover(from source: URL, for entry: GameEntry) throws
    func removeCover(for entry: GameEntry) throws
}
```

A chosen image is copied (not referenced) into
`~/Library/Application Support/PS1/Covers/<sha256-of-path>.png`, re-encoded to
PNG via `NSImage`, so the library does not break when the source image is moved
or deleted. The injectable `directory` is what makes this testable against a
temp directory.

### `OnboardingView.swift`

One glass panel, replacing `EmptyStateView`:

- Title, one line of explanation.
- Two rows — **BIOS folder** and **Games folder** — each with the chosen
  folder's name (or "Not chosen"), a `Choose…` button, and a checkmark once set.
  Either can be done first.
- A `Continue` button, enabled only when both are set, which moves the stage to
  `.library`.

The BIOS row keeps the existing explanation that the right BIOS is picked per
disc and that a US BIOS in front of a PAL disc stops at the region-lock screen.

### `LibraryView.swift` and `GameTile.swift`

`LazyVGrid` of box-art-shaped tiles (3:4), adaptive columns, inside a
`ScrollView`. The title sits under each tile, truncated to two lines.

`GameTile` shows, in order: the custom cover if `CoverStore` has one, otherwise a
generated placeholder — a flat tile with a disc glyph and the title.

Interaction:

- Double-click, or Return on a selected tile, plays the game.
- `.contextMenu`: **Play** · **Choose Cover Image…** · **Remove Custom Cover**
  (only when one is set) · **Show in Finder** (`NSWorkspace.activateFileViewerSelecting`).

Empty states inside the grid, not as alerts: "No games found in <folder>" with a
`Choose Games Folder…` button when the scan returns nothing, and a progress
spinner while `isScanning`.

## View model changes

`EmulatorViewModel` gains:

- `let library = GameLibrary()`
- `let covers = CoverStore()`
- `func chooseGamesFolder()` — `NSOpenPanel`, directories only, then
  `library.setFolder(url)`.
- `func play(_ entry: GameEntry)` — calls the existing `load(disc:)`, unchanged.
- `func finishOnboarding()` — sets `.library`, guarded on both folders being set.

`eject()` sets `.library`. `chooseBIOSFolder()` no longer moves the stage on its
own; onboarding's `Continue` does that.

## Menus (`PS1App.swift`)

File group (replacing `.newItem`, as today):

- **Open Disc…** ⌘O — unchanged, still the escape hatch for a disc outside the
  library folder.
- **Refresh Library** ⇧⌘R — `model.library.rescan()`. Not ⌘R: that is Reset.
- **Choose Games Folder…**
- **Choose BIOS Folder…** — existing item, kept.

The `Machine` menu is unchanged.

## Error handling

- Scan problems are shown inline in the grid, never as a modal.
- Launch failures keep flowing through `model.errorMessage` and the existing
  alert, so a multi-`FILE` cue, a missing region BIOS, and a bad cue all report
  exactly as they do now.
- `CoverStore` failures (unreadable image, undecodable format) set
  `model.errorMessage` with a plain sentence.

## Testing

TDD: the two logic components get their tests first.

- `GameScannerTests` — temp-dir fixtures covering: nesting several levels deep;
  a `cue` + `bin` pair yielding one entry; a directory with a `bin` and no
  `cue` yielding one entry; a directory with two cues and one bin yielding two;
  hidden files and `.DS_Store` ignored; sort order; an empty root.
- `CoverStoreTests` — set, read back, replace, remove, and that the key is
  derived from the path so a rescan of the same folder keeps the cover.
- `BiosLibraryTests` — unchanged, and must stay green across the
  `FolderBookmark` extraction.

Views stay thin because this build has no SwiftUI test harness (`@State` is
unusable and there is no XCTest UI layer under Command Line Tools). Anything
worth asserting lives in `GameScanner`, `CoverStore`, or the view model.

`ps1-macos/test.sh` is the runner; `zig build macos` must still produce a
launchable `zig-out/PS1.app`.

## Risks

- **Bookmarks going stale** (folder moved or on an unmounted volume) resolve to
  `nil`, which drops the user back to `.onboarding`. That is the correct
  outcome, and it is the only recovery path that does not need a settings
  window.
- **A very large games folder on a network volume** makes the first scan slow.
  Mitigated by scanning off the main actor and showing a spinner; not
  mitigated by caching, which is deliberate — a stale cache is worse than a
  slow scan for a folder the user edits in Finder.
