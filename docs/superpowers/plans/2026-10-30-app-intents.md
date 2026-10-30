# App Intents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Library games as an `AppEntity` with Play Game, Resume Game and Open Library intents, reachable from Spotlight, Shortcuts and Siri.

**Architecture:** A pure `GameCatalog` (entries + stats → games, ids, suggestions) is the tested core. The App Intents types are a thin layer over it in `Sources/PS1/Intents/`, reaching the delegate's `EmulatorViewModel` through `AppDependencyManager`. Launches reuse the Finder path (`open(_:)`), plus a new `.resume` exit intent for Resume Game.

**Tech Stack:** Swift 6, SwiftUI app target, AppIntents (macOS 26), swift-testing.

**Spec:** `docs/superpowers/specs/2026-10-30-app-intents-design.md`

## Global Constraints

- App target only: no new Xcode target, no entitlements, no App Group. New `.swift` files need no project edit (synchronized groups).
- Entity id = `SaveStateStore.key(for: group.first)` over `DiscGrouping.group(entries, merging: true)`, regardless of the Merge Multi-Disc setting.
- Every App Shortcut phrase contains `\(.applicationName)`.
- Error copy (exact): "Choose a games folder in Substation first.", "That game is no longer in your library.", "You haven't played anything yet."
- Library scan wait bounded at 10 s.
- No em or en dashes in user-facing copy (house style, `SettingsCopyTests`).
- Run the Swift suite with `pkill -x Substation; ps1-macos/test.sh` after `zig build capi-lib metallib` are built.
- Commit per task on master, title line only plus the Co-Authored-By trailer.

## Review Focus

- A cold launch from Spotlight: the query arrives before the scan finishes and must wait, not answer empty (Task 2 test `aWaitReturnsOnceTheScanInFlightPublishes`).
- Resume Game while a game runs must raise the exit sheet, never drop the game (Task 3 test `resumeFromOutsideAsksWhileAGamePlays`).
- A second intent while the exit sheet is up gets `.busy` and does nothing (Task 3 test `anIntentWhileTheSheetIsUpDoesNothing`).
- A serial-less disc must still resolve by id (Task 1 test `aDiscWithNoSerialIsKeyedOnItsPathHash`).
- Disc 2 of a merged game played last must make Resume Game pick the GAME, keyed on disc 1 (Task 1 test `lastPlayedIsTheMergedGame`).

---

### Task 1: GameCatalog

**Files:**
- Create: `ps1-macos/Sources/PS1/GameCatalog.swift`
- Test: `ps1-macos/Tests/PS1Tests/GameCatalogTests.swift`

**Interfaces:**
- Produces:
  - `enum GameCatalog`
  - `static func games(_ entries: [GameEntry]) -> [GameGroup]` (merged, in title order)
  - `static func id(of game: GameGroup) -> String`
  - `static func game(id: String, in games: [GameGroup]) -> GameGroup?`
  - `static func suggested(_ games: [GameGroup], stats: [String: PlayStats]) -> [GameGroup]` (played newest first, then unplayed by title)
  - `static func lastPlayed(_ games: [GameGroup], stats: [String: PlayStats]) -> GameGroup?`
  - `static func matching(_ games: [GameGroup], query: String) -> [GameGroup]` (delegates to `LibrarySearch.filter`)

- [ ] **Step 1: Write the failing tests** using `GameEntry(url:identity:)` fixtures (no filesystem): `mergedDiscsAreOneGameKeyedOnDiscOne` (FF7 discs 1-3 by `(Disc N)` names in one folder → one game, id = disc 1's serial), `aDiscWithNoSerialIsKeyedOnItsPathHash` (id == `entry.pathKey`), `gameByIdFindsItAndAStaleIdFindsNothing`, `suggestionsAreNewestPlayedThenUnplayedByTitle`, `lastPlayedIsTheMergedGame` (stats under disc 1's key → the group), `lastPlayedIsNilWhenNothingWasPlayed`, `matchingUsesTheLibrarySearch` (query by serial finds the game).
- [ ] **Step 2: Run, expect compile failure** (`GameCatalog` undefined): `pkill -x Substation; ps1-macos/test.sh`
- [ ] **Step 3: Implement** `GameCatalog.swift` with the signatures above.
- [ ] **Step 4: Run the suite, expect PASS.**
- [ ] **Step 5: Commit** `feat(macos): a catalogue of library games for App Intents`

### Task 2: Waiting for the library scan

**Files:**
- Modify: `ps1-macos/Sources/PS1/GameLibrary.swift`
- Test: `ps1-macos/Tests/PS1Tests/GameLibraryTests.swift`

**Interfaces:**
- Produces: `func scanned(timeout: Duration = .seconds(10)) async -> [GameEntry]` on `GameLibrary`: returns `entries` at once when not scanning, else after the winning scan publishes, else after the timeout with whatever `entries` holds.

- [ ] **Step 1: Write the failing tests** with a test bookmark key (as the existing tests do): `aWaitReturnsAtOnceWhenNotScanning`, `aWaitReturnsOnceTheScanInFlightPublishes` (start a scan over a temp folder with one `.cue`, await, expect one entry), `aWaitGivesUpAtItsTimeout` (timeout `.milliseconds(1)` while scanning returns without hanging).
- [ ] **Step 2: Run, expect compile failure.**
- [ ] **Step 3: Implement** with a list of continuations resumed where `rescan` publishes; the timeout races them in a task group. `didFinishScan` keeps its single owner.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat(macos): the library can be awaited until its scan lands`

### Task 3: The model's intent entry points

**Files:**
- Modify: `ps1-macos/Sources/PS1/ExitGate.swift` (add `case resume(GameGroup)`; its question is the game one)
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift` (`finishExit` handles `.resume`; new methods below)
- Test: `ps1-macos/Tests/PS1Tests/IntentEntryTests.swift`

**Interfaces:**
- Consumes: `GameCatalog` (Task 1), `GameLibrary.scanned` (Task 2).
- Produces, on `EmulatorViewModel`:
  - `enum IntentFailure: Error, Equatable { case notSetUp, gameMissing, nothingPlayed }` with `var message: String` (the exact copy in Global Constraints); in `GameCatalog.swift` or beside the model.
  - `func intentGames() async throws(IntentFailure) -> [GameGroup]`: `.notSetUp` while `stage == .onboarding`; else `GameCatalog.games(await library.scanned())`.
  - `func playFromIntent(_ game: GameGroup)`: `open(game.first.url)`.
  - `func resumeFromIntent(_ game: GameGroup)`: `requestExit(.resume(game))`, and on `.proceed` `resumeOpened(game)`, which sets `launchFromOutside = true`, `launchInGameWindow = gameWindowMode == .newWindow`, then follows `continuePlaying`'s rule (resume state straight in, else `launch`).
  - `func openLibraryFromIntent()`: leaves a running game alone; otherwise brings the library window forward (`openWindow(id: LibraryWindow.id)` through the app's existing opener, or `LibraryWindow.current?.makeKeyAndOrderFront`), then `NSApp.activate()`.
  - `continuePlaying` keeps its library-click behaviour (`launchFromOutside = false`); the shared resume rule is extracted rather than copied.

- [ ] **Step 1: Write the failing tests** (ScriptedSession, as `EmulatorViewModelStageTests` builds a model): `intentsRefuseBeforeOnboarding` (`.notSetUp`), `resumeFromOutsideAsksWhileAGamePlays` (playing model → `exitPrompt == .resume(game)`, session still installed), `anIntentWhileTheSheetIsUpDoesNothing` (exit prompt up → resume intent leaves `exitPrompt` unchanged), `resumeWithNoStateOffersTheLaunch` (no resume file → `resumeOffer` set or the load path taken, `launchFromOutside == true`), `failureMessagesAreTheSpecsCopy`.
- [ ] **Step 2: Run, expect compile failure.**
- [ ] **Step 3: Implement** the cases and methods above.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat(macos): intent entry points on the model`

### Task 4: Entity, intents, shortcuts and Spotlight

**Files:**
- Create: `ps1-macos/Sources/PS1/Intents/GameEntity.swift` (`GameEntity: IndexedEntity`, `GameQuery: EntityStringQuery`)
- Create: `ps1-macos/Sources/PS1/Intents/GameIntents.swift` (`PlayGameIntent: OpenIntent`, `ResumeGameIntent`, `OpenLibraryIntent`)
- Create: `ps1-macos/Sources/PS1/Intents/SubstationShortcuts.swift` (`AppShortcutsProvider`)
- Modify: `ps1-macos/Sources/PS1App/AppDelegate.swift` (register the model with `AppDependencyManager.shared.add { model }` in `applicationWillFinishLaunching`)
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift` (after each scan: reindex entities and `SubstationShortcuts.updateAppShortcutParameters()`)
- Test: `ps1-macos/Tests/PS1Tests/GameEntityTests.swift`

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces:
  - `struct GameEntity: IndexedEntity` with `id: String`, `title: String`, `subtitle: String`, `cover: URL?`; `init(_ game: GameGroup, stats: PlayStats?, cover: URL?)`; `displayRepresentation` = title, subtitle, image `.init(url:)` from `cover` or the app icon; `typeDisplayRepresentation` "Game".
  - `GameQuery`: `entities(for:)`, `entities(matching:)`, `suggestedEntities()`, all via `model.intentGames()` and `GameCatalog`, run on the main actor.
  - Intents, all `@MainActor`, `openAppWhenRun = true`, `@Dependency var model: EmulatorViewModel`; a thrown `IntentFailure` surfaces its `message` (conform it to `CustomLocalizedStringResourceConvertible`).
    - `PlayGameIntent` "Play Game", `@Parameter var target: GameEntity`.
    - `ResumeGameIntent` "Resume Game", `@Parameter var game: GameEntity?`; nil → `GameCatalog.lastPlayed`, none → `.nothingPlayed`.
    - `OpenLibraryIntent` "Open Library".
  - Phrases: "Play \(\.$target) in \(.applicationName)", "Resume \(\.$game) in \(.applicationName)", "Resume \(.applicationName)", "Continue playing in \(.applicationName)", "Open the \(.applicationName) library".
  - Reindex: `try await CSSearchableIndex.default().indexAppEntities(entities)` after deleting the previous set (`deleteAppEntities(ofType: GameEntity.self)`), so a removed game leaves Spotlight.

- [ ] **Step 1: Write the failing tests:** `anEntityShowsTheTileSubtitle` (two discs → "2 discs"; unplayed single → "Not played yet"), `anEntityIdIsTheCatalogueId`.
- [ ] **Step 2: Run, expect compile failure.**
- [ ] **Step 3: Implement** the three files, the registration and the post-scan reindex.
- [ ] **Step 4: Run the suite, expect PASS; then `zig build macos`, expect a bundle and no AppIntents metadata errors** (`grep -i appintents` over the build log shows no error lines).
- [ ] **Step 5: Commit** `feat(macos): games in Spotlight, Shortcuts and Siri`

### Task 5: Hand check and the skill

**Files:**
- Modify: `.claude/skills/ps1-macos-app/SKILL.md` (a short "App Intents" section: the id rule, the scan wait, Play Game = Finder's path, Resume Game's `.resume` exit intent, reindex after scan)

- [ ] **Step 1:** `pkill -x Substation; open zig-out/Substation.app`, wait for the scan, then: Spotlight "Crash" lists the game with its cover; picking it raises the resume panel. In Shortcuts, the app's shortcuts are listed, and "Resume Game" with no game continues the last one. Run Play Game from Spotlight during a game: the exit sheet appears on the game. Quit, then run Resume Game from Shortcuts: a cold launch resumes.
- [ ] **Step 2:** Record what was and was not observed in the skill section.
- [ ] **Step 3: Commit** `docs: App Intents in the macOS app skill`
