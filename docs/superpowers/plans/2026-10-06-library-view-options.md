# Library View Options Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the macOS library a toolbar with a Grid/List switch and a cover-size slider, a sortable list view, and per-game last-played and active play-time tracking.

**Architecture:** Pure value types carry every rule (`PlayClock`, `LibraryLayoutSetting`, `LibraryFormat`, `LibraryRow`) so they are testable without a window; one `@Observable` store (`PlayStatsStore`) persists stats as JSON; `EmulatorViewModel` feeds the clock and exposes the settings as seams that both the toolbar and the Library menu bind to; `LibraryView` switches between the existing grid and a new `LibraryTable`.

**Tech Stack:** Swift 6 / SwiftUI on macOS 26, swift-testing, `xcodebuild` (no `Package.swift`).

**Spec:** `docs/superpowers/specs/2026-10-06-library-view-options-design.md`

## Global Constraints

- Every persisted setting is a small typed struct on the view model (`init` resolves from `UserDefaults`, `set` persists, the rule lives in the type). Never `@AppStorage`.
- An Int-backed enum persists through `PersistedChoice` (rejecting load). A numeric value whose 0 is meaningful is probed with `object(forKey:)`, never `double(forKey:)`.
- Menu items and the toolbar bind to the SAME view-model property; nothing in a view persists anything.
- New `.swift` files need no project edit: `Sources/` and `Tests/` are synchronized groups.
- `Sources/PS1` and `Sources/PS1App` are ONE module; no `public` needed to cross them.
- Tests that touch `UserDefaults` use a fresh `UUID` key per test (`"test-<name>-\(UUID().uuidString)"`). Tests that touch disk use a fresh temp directory.
- `pkill -x Substation` before any `xcodebuild test`: a running app shares the bundle id.
- No hover or selection animation on tiles. The selection ring stays as it is.
- Shortcuts: as Grid ⌃⌘1, as List ⌃⌘2, Bigger Covers ⌘+, Smaller Covers ⌘−. (⌘1 to ⌘8 are Video ▸ Internal Resolution.)
- Tile size: default 132 pt, clamp 100...260, step 20. Grid maximum is `size * 1.36`.
- Commit messages are a title line only, no body, directly on `master`.
- Comments state the rule and why, in the codebase's voice; no thinking-out-loud.

**Running one test** (from `ps1-macos/`; free functions need the parentheses, and a filter that matches nothing reports "passed" with 0 tests, so check the count):

```bash
pkill -x Substation; xcodebuild -project PS1.xcodeproj -scheme PS1 -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" SYMROOT="$PWD/../.build/xcode" test \
  '-only-testing:PS1Tests/<testName>()' 2>&1 | grep -E "✔|✘|error:|Test run with"
```

## Review Focus

- A game left running while the player is in another app accrues NOTHING (the app does not pause on resign-active): pinned in Task 1 and wired in Task 4.
- Pause AND background at once, then un-pausing while still in the background, must not start the clock: pinned in Task 1.
- Quit (⌘Q) mid-game must bank the session: `willTerminate` already runs `teardownRunningMachine`, which records; covered by Task 4's teardown hook.
- A damaged `stats.json` must not crash the library or be deleted on read: pinned in Task 2.
- Switching Grid ↔ List keeps the selected game, and Return/double-click in the list plays it: Task 6 manual check list.

---

### Task 1: PlayClock

**Files:**
- Create: `ps1-macos/Sources/PS1/PlayClock.swift`
- Test: `ps1-macos/Tests/PS1Tests/PlayClockTests.swift`

**Interfaces:**
- Produces: `struct PlayClock { mutating func update(running: Bool, paused: Bool, active: Bool, at now: Date) -> TimeInterval }`. Returns the seconds banked by THIS call (non-zero only on a call that stops a counting clock).

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import PS1

private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

@Test func aStretchOfActivePlayIsBankedWhenItStops() {
    var clock = PlayClock()
    #expect(clock.update(running: true, paused: false, active: true, at: t0) == 0)
    #expect(clock.update(running: true, paused: true, active: true, at: t0 + 90) == 90)
}

@Test func repeatingTheCountingStateDoesNotRestartTheStretch() {
    var clock = PlayClock()
    _ = clock.update(running: true, paused: false, active: true, at: t0)
    _ = clock.update(running: true, paused: false, active: true, at: t0 + 30)
    #expect(clock.update(running: false, paused: false, active: true, at: t0 + 50) == 50)
}

/// The app keeps emulating behind other windows, so "running and unpaused"
/// is not enough: a game left open in the background counts nothing.
@Test func timeInTheBackgroundCountsNothing() {
    var clock = PlayClock()
    _ = clock.update(running: true, paused: false, active: true, at: t0)
    #expect(clock.update(running: true, paused: false, active: false, at: t0 + 10) == 10)
    #expect(clock.update(running: true, paused: false, active: false, at: t0 + 500) == 0)
    _ = clock.update(running: true, paused: false, active: true, at: t0 + 600)
    #expect(clock.update(running: false, paused: false, active: true, at: t0 + 620) == 20)
}

/// Paused AND in the background, then unpaused while still away: the clock
/// must stay stopped until BOTH conditions clear.
@Test func overlappingStopsKeepTheClockStoppedUntilAllClear() {
    var clock = PlayClock()
    _ = clock.update(running: true, paused: false, active: true, at: t0)
    #expect(clock.update(running: true, paused: true, active: true, at: t0 + 5) == 5)
    #expect(clock.update(running: true, paused: true, active: false, at: t0 + 6) == 0)
    #expect(clock.update(running: true, paused: false, active: false, at: t0 + 100) == 0)
    _ = clock.update(running: true, paused: false, active: true, at: t0 + 200)
    #expect(clock.update(running: true, paused: true, active: true, at: t0 + 207) == 7)
}

@Test func stoppingAClockThatNeverRanBanksNothing() {
    var clock = PlayClock()
    #expect(clock.update(running: false, paused: false, active: true, at: t0) == 0)
    #expect(clock.update(running: true, paused: true, active: true, at: t0 + 60) == 0)
}
```

- [ ] **Step 2: Run them to verify they fail**

Run the five names with the "Running one test" command (one `-only-testing` each).
Expected: build error, `cannot find 'PlayClock' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Active play time: the clock runs only while a game is running, unpaused,
/// AND the app is in front.
///
/// The third condition is its own input because the app does not pause a
/// game when it goes to the background: the emulator keeps running behind
/// other windows, and a game left open overnight is not a game played.
///
/// A value type fed timestamps, like `FpsCounter`, so the rule is reachable
/// from a test with synthetic times and no window.
struct PlayClock {
    /// When the current counting stretch began, or nil while stopped.
    private var since: Date?

    /// Applies the three inputs as of `now`. Returns the seconds banked by
    /// this call: the length of the stretch it ended, or 0 when it ended none.
    mutating func update(running: Bool, paused: Bool, active: Bool,
                         at now: Date) -> TimeInterval {
        let counting = running && !paused && active
        switch (since, counting) {
        case (nil, true):
            since = now
            return 0
        case (let start?, false):
            since = nil
            return max(0, now.timeIntervalSince(start))
        default:
            return 0
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Expected: 5 tests passed.

- [ ] **Step 5: Commit**

```bash
git add ps1-macos/Sources/PS1/PlayClock.swift ps1-macos/Tests/PS1Tests/PlayClockTests.swift
git commit -m "feat(macos): PlayClock counts active play only"
```

---

### Task 2: PlayStatsStore

**Files:**
- Create: `ps1-macos/Sources/PS1/PlayStatsStore.swift`
- Test: `ps1-macos/Tests/PS1Tests/PlayStatsStoreTests.swift`

**Interfaces:**
- Consumes: `AppSupport.directory(_ component: String) -> URL`.
- Produces:
  - `struct PlayStats: Codable, Equatable, Sendable { var lastPlayed: Date?; var seconds: TimeInterval }`
  - `@Observable final class PlayStatsStore { init(directory: URL? = nil); private(set) var all: [String: PlayStats]; func stats(for key: String) -> PlayStats?; func markPlayed(_ key: String, at date: Date); func add(_ seconds: TimeInterval, to key: String) }`
  - File: `<directory>/stats.json`, default directory `AppSupport.directory("PlayStats")` (i.e. `Application Support/Substation/PlayStats/stats.json`; the spec's single top-level file is placed in a component folder so it goes through `AppSupport`'s migration like every other store).

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import PS1

private func makeDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("playstats-\(UUID().uuidString)")
}

@Test func playStatsSurviveAReload() {
    let dir = makeDirectory()
    let when = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let store = PlayStatsStore(directory: dir)
    store.markPlayed("SLUS-00530", at: when)
    store.add(125, to: "SLUS-00530")
    store.add(5, to: "SLUS-00530")

    let reloaded = PlayStatsStore(directory: dir)
    #expect(reloaded.stats(for: "SLUS-00530") == PlayStats(lastPlayed: when, seconds: 130))
}

@Test func aMissingFileIsAnEmptyLibraryOfStats() {
    let store = PlayStatsStore(directory: makeDirectory())
    #expect(store.all.isEmpty)
    #expect(store.stats(for: "SLUS-00530") == nil)
}

/// Unreadable stats read as none, and nothing deletes the file on read: it
/// stays on disk until the next record is written over it.
@Test func aDamagedFileReadsAsEmptyAndIsLeftAlone() throws {
    let dir = makeDirectory()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("stats.json")
    try Data("not json".utf8).write(to: file)

    let store = PlayStatsStore(directory: dir)
    #expect(store.all.isEmpty)
    #expect(try Data(contentsOf: file) == Data("not json".utf8))

    store.add(10, to: "SLUS-00530")
    #expect(PlayStatsStore(directory: dir).stats(for: "SLUS-00530")?.seconds == 10)
}

@Test func addingNoTimeWritesNothing() {
    let dir = makeDirectory()
    PlayStatsStore(directory: dir).add(0, to: "SLUS-00530")
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("stats.json").path))
}
```

- [ ] **Step 2: Run them to verify they fail**

Expected: build error, `cannot find 'PlayStatsStore' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation
import Observation

/// One game's history: when it was last started and how long it has been
/// actively played (`PlayClock`'s rule).
struct PlayStats: Codable, Equatable, Sendable {
    var lastPlayed: Date?
    var seconds: TimeInterval = 0
}

/// Play stats for every game, one JSON file, keyed exactly as resume states
/// are (`ResumeStateStore.key(for:)`: the first disc's serial, else the path
/// hash), so a multi-disc game has one record and a renamed rip keeps its
/// history.
///
/// `@Observable` so the list view's columns follow a write without a revision
/// counter. A missing or unreadable file reads as empty and is never deleted
/// on read: a damaged file is replaced only by the next successful write.
@Observable
final class PlayStatsStore {
    private(set) var all: [String: PlayStats]
    @ObservationIgnored private let file: URL

    init(directory: URL? = nil) {
        let directory = directory ?? AppSupport.directory("PlayStats")
        file = directory.appendingPathComponent("stats.json")
        all = (try? Data(contentsOf: file))
            .flatMap { try? JSONDecoder().decode([String: PlayStats].self, from: $0) } ?? [:]
    }

    func stats(for key: String) -> PlayStats? { all[key] }

    func markPlayed(_ key: String, at date: Date) {
        all[key, default: PlayStats()].lastPlayed = date
        save()
    }

    func add(_ seconds: TimeInterval, to key: String) {
        guard seconds > 0 else { return }
        all[key, default: PlayStats()].seconds += seconds
        save()
    }

    /// Atomic, so a crash mid-write leaves the previous file.
    private func save() {
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Expected: 4 tests passed.

- [ ] **Step 5: Commit**

```bash
git add ps1-macos/Sources/PS1/PlayStatsStore.swift ps1-macos/Tests/PS1Tests/PlayStatsStoreTests.swift
git commit -m "feat(macos): PlayStatsStore persists last played and play time"
```

---

### Task 3: LibraryFormat and LibraryRow

**Files:**
- Create: `ps1-macos/Sources/PS1/LibraryRow.swift`
- Test: `ps1-macos/Tests/PS1Tests/LibraryRowTests.swift`

**Interfaces:**
- Consumes: `GameGroup` (`id`, `title`, `discs`, `first`), `GameEntry.identity.region`, `GameEntry.serial`, `PlayStats`, `ResumeStateStore.key(for:)`.
- Produces:
  - `enum LibraryFormat { static func playTime(_ seconds: TimeInterval?) -> String; static func lastPlayed(_ date: Date?, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String; static func region(_ region: DiscIdentity.Region?) -> String }`
  - `struct LibraryRow: Identifiable { let group: GameGroup; let title: String; let region: String; let serial: String; let discs: Int; let lastPlayed: Date?; let seconds: TimeInterval; var id: GameGroup.ID; var lastPlayedSortKey: Date; static func rows(_ groups: [GameGroup], stats: [String: PlayStats]) -> [LibraryRow] }`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import PS1

@Test func playTimeReadsInHoursAndMinutes() {
    #expect(LibraryFormat.playTime(nil) == "—")
    #expect(LibraryFormat.playTime(0) == "—")
    #expect(LibraryFormat.playTime(42) == "< 1 min")
    #expect(LibraryFormat.playTime(35 * 60 + 20) == "35 min")
    #expect(LibraryFormat.playTime(12 * 3600) == "12 h")
    #expect(LibraryFormat.playTime(12 * 3600 + 40 * 60 + 59) == "12 h 40 min")
}

@Test func lastPlayedIsRelativeNearbyAndADateBeyond() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let locale = Locale(identifier: "en_GB")
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 12))!
    func at(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 9))!
    }
    #expect(LibraryFormat.lastPlayed(nil, now: now, calendar: calendar, locale: locale) == "—")
    #expect(LibraryFormat.lastPlayed(at(2026, 10, 6), now: now, calendar: calendar, locale: locale) == "Today")
    #expect(LibraryFormat.lastPlayed(at(2026, 10, 5), now: now, calendar: calendar, locale: locale) == "Yesterday")
    #expect(LibraryFormat.lastPlayed(at(2026, 10, 3), now: now, calendar: calendar, locale: locale) == "3 Oct")
    #expect(LibraryFormat.lastPlayed(at(2025, 12, 24), now: now, calendar: calendar, locale: locale) == "24 Dec 2025")
}

@Test func regionNamesTheMarket() {
    #expect(LibraryFormat.region(.america) == "USA")
    #expect(LibraryFormat.region(.europe) == "Europe")
    #expect(LibraryFormat.region(.japan) == "Japan")
    #expect(LibraryFormat.region(nil) == "—")
}

/// A row reads its stats under the resume-state key of the group's FIRST
/// disc, and a game never played sorts as the oldest.
@Test func rowsJoinGroupsToTheirStats() {
    let played = GameGroup(title: "Croc", discs: [GameEntry(
        url: URL(fileURLWithPath: "/g/Croc.cue"), isCue: true,
        identity: DiscIdentity(region: .america, serial: "SLUS-00530", volumeID: nil))])
    let never = GameGroup(title: "Doom", discs: [GameEntry(
        url: URL(fileURLWithPath: "/g/Doom.cue"), isCue: true)])
    let when = Date(timeIntervalSinceReferenceDate: 800_000_000)

    let rows = LibraryRow.rows([played, never],
                               stats: ["SLUS-00530": PlayStats(lastPlayed: when, seconds: 600)])

    #expect(rows[0].serial == "SLUS-00530")
    #expect(rows[0].region == "USA")
    #expect(rows[0].seconds == 600)
    #expect(rows[0].lastPlayedSortKey == when)
    #expect(rows[1].serial == "—")
    #expect(rows[1].seconds == 0)
    #expect(rows[1].lastPlayedSortKey == .distantPast)
}
```

Before Step 2, check `DiscIdentity`'s initializer (`Sources/PS1/DiscIdentity.swift:30`) and `GameGroup`'s memberwise init (`DiscGrouping.swift:4`); adjust only the test's construction calls if their labels differ, never the production types.

- [ ] **Step 2: Run them to verify they fail**

Expected: build error, `cannot find 'LibraryFormat' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// How the list view writes its columns. Pure functions, so the wording is
/// pinned by tests rather than by screenshots.
enum LibraryFormat {
    static func playTime(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        let minutes = Int(seconds) / 60
        if minutes == 0 { return "< 1 min" }
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// "Today" and "Yesterday" by calendar day, a day and month within the
    /// current year, and the year as well beyond it.
    static func lastPlayed(_ date: Date?, now: Date,
                           calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let date else { return "—" }
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .day().month(.abbreviated)
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return date.formatted(style)
    }

    static func region(_ region: DiscIdentity.Region?) -> String {
        switch region {
        case .america: "USA"
        case .europe: "Europe"
        case .japan: "Japan"
        case nil: "—"
        }
    }
}

/// One line of the list view: a game group joined to its play stats, with
/// every column as a comparable value so `Table` can sort on it.
struct LibraryRow: Identifiable {
    let group: GameGroup
    let title: String
    let region: String
    let serial: String
    let discs: Int
    let lastPlayed: Date?
    let seconds: TimeInterval

    var id: GameGroup.ID { group.id }
    /// A game never played sorts as the oldest.
    var lastPlayedSortKey: Date { lastPlayed ?? .distantPast }

    static func rows(_ groups: [GameGroup], stats: [String: PlayStats]) -> [LibraryRow] {
        groups.map { group in
            let record = stats[ResumeStateStore.key(for: group.first)]
            return LibraryRow(
                group: group,
                title: group.title,
                region: LibraryFormat.region(group.first.identity.region),
                serial: group.first.serial ?? "—",
                discs: group.discs.count,
                lastPlayed: record?.lastPlayed,
                seconds: record?.seconds ?? 0)
        }
    }
}
```

If `"24 Dec 2025"` comes out in a different field order under `en_GB`, fix the FORMAT (e.g. add `.year()` before `.month`), not the expectation: day-month-year is the agreed wording.

- [ ] **Step 4: Run the tests to verify they pass**

Expected: 4 tests passed.

- [ ] **Step 5: Commit**

```bash
git add ps1-macos/Sources/PS1/LibraryRow.swift ps1-macos/Tests/PS1Tests/LibraryRowTests.swift
git commit -m "feat(macos): list-view rows and their column formats"
```

---

### Task 4: Feed the play clock from the view model

**Files:**
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift` (stored properties near line 54; `init` observers near lines 136-150; `isPaused` at 154; `load(disc:)` success near line 918; `reset()` near 941; `teardownRunningMachine()` at 1047)

**Interfaces:**
- Consumes: `PlayClock.update(running:paused:active:at:)`, `PlayStatsStore.markPlayed(_:at:)`, `PlayStatsStore.add(_:to:)`.
- Produces: `let playStats = PlayStatsStore()` on `EmulatorViewModel` (read by Task 6's list view).

- [ ] **Step 1: Add the state**

Beside `let covers = CoverStore()`:

```swift
    /// Last played and active play time per game. Outlives every disc, like
    /// `covers`.
    let playStats = PlayStatsStore()
    private var playClock = PlayClock()
```

- [ ] **Step 2: Add the one update point**

Below `isPaused`:

```swift
    /// The single place the play clock learns anything: every change to
    /// running, paused or app-active calls this, and whatever stretch it ends
    /// is banked under the running game's key. Called BEFORE `resumeKey` is
    /// cleared on teardown, so the last stretch lands on the game it belongs to.
    private func updatePlayClock() {
        let banked = playClock.update(running: runner != nil, paused: isPaused,
                                      active: NSApp?.isActive ?? true, at: Date())
        if let key = resumeKey { playStats.add(banked, to: key) }
    }
```

- [ ] **Step 3: Call it from every transition**

1. `isPaused`'s setter becomes:

```swift
        set {
            runner?.isPaused = newValue
            updatePlayClock()
        }
```

2. `reset()`: after `runner?.isPaused = false`, add `updatePlayClock()`.

3. `load(disc:)`: directly after `stage = .playing`, add:

```swift
            if let resumeKey { playStats.markPlayed(resumeKey, at: Date()) }
            updatePlayClock()
```

4. `teardownRunningMachine()`: make its FIRST lines

```swift
        // Banks the session under the outgoing game before anything below
        // clears the runner and the key it is filed under.
        runner?.isPaused = true
        updatePlayClock()
```

The pause is set on the runner directly (not through `isPaused`) so the banking happens exactly once, here; the runner is stopped two lines later either way.

5. `init`: the existing `didResignActiveNotification` observer body becomes

```swift
            MainActor.assumeIsolated {
                self?.setFastForwarding(false)
                self?.updatePlayClock()
            }
```

and add beside it:

```swift
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePlayClock() }
        }
```

`willTerminateNotification` already calls `teardownRunningMachine()`, so ⌘Q banks the session through hook 4 with no change.

- [ ] **Step 4: Build and run the existing suite**

Run: `cd /Users/david/Documents/develop/substation && pkill -x Substation; ps1-macos/test.sh 2>&1 | grep -E "✘|error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: the run line reports every test passed. If the final line says `TEST FAILED` while the swift-testing line passed, scroll the raw output for the failing XCTest case before continuing; do not assume it is pre-existing.

- [ ] **Step 5: Verify in the app**

```bash
cd /Users/david/Documents/develop/substation && zig build macos && open zig-out/Substation.app
```

Play any game for ~70 s, ⌘Tab away for 30 s, come back, pause, eject. Then:

```bash
cat ~/Library/Application\ Support/Substation/PlayStats/stats.json
```

Expected: one key with `lastPlayed` set and `seconds` ≈ 70 (not ≈ 100).

- [ ] **Step 6: Commit**

```bash
git add ps1-macos/Sources/PS1/EmulatorViewModel.swift
git commit -m "feat(macos): record last played and active play time per game"
```

---

### Task 5: LibraryLayoutSetting and the grid's cover size

**Files:**
- Create: `ps1-macos/Sources/PS1/LibraryLayoutSetting.swift`
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift` (beside `ditherMode`), `ps1-macos/Sources/PS1/LibraryView.swift`, `ps1-macos/Sources/PS1/ContentView.swift:58-69`
- Test: `ps1-macos/Tests/PS1Tests/LibraryLayoutSettingTests.swift`

**Interfaces:**
- Consumes: `PersistedChoice`.
- Produces:
  - `enum LibraryViewMode: Int, CaseIterable { case grid = 0, list = 1 }`
  - `struct LibraryLayoutSetting { static let sizeRange: ClosedRange<Double> = 100...260; static let defaultSize = 132.0; static let step = 20.0; var viewMode: LibraryViewMode; var tileSize: Double; init(viewModeKey:sizeKey:defaults:); mutating func setViewMode(_:); mutating func setTileSize(_:) }`
  - On `EmulatorViewModel`: `var libraryViewMode: LibraryViewMode`, `var libraryTileSize: Double`, `var canGrowCovers: Bool`, `var canShrinkCovers: Bool`, `func growCovers()`, `func shrinkCovers()`.
  - On `LibraryView`: new stored properties `var viewMode: LibraryViewMode = .grid` and `var tileSize: CGFloat = LibraryLayoutSetting.defaultSize`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import PS1

private func keys() -> (String, String) {
    let id = UUID().uuidString
    return ("test-libview-\(id)", "test-libsize-\(id)")
}

@Test func anAbsentLayoutIsTheGridAtTodaysSize() {
    let (mode, size) = keys()
    let setting = LibraryLayoutSetting(viewModeKey: mode, sizeKey: size)
    #expect(setting.viewMode == .grid)
    #expect(setting.tileSize == 132)
}

@Test func theLayoutPersists() {
    let (mode, size) = keys()
    var setting = LibraryLayoutSetting(viewModeKey: mode, sizeKey: size)
    setting.setViewMode(.list)
    setting.setTileSize(200)
    let reloaded = LibraryLayoutSetting(viewModeKey: mode, sizeKey: size)
    #expect(reloaded.viewMode == .list)
    #expect(reloaded.tileSize == 200)
}

@Test func theTileSizeIsClampedOnSetAndOnLoad() {
    let (mode, size) = keys()
    var setting = LibraryLayoutSetting(viewModeKey: mode, sizeKey: size)
    setting.setTileSize(999)
    #expect(setting.tileSize == 260)
    setting.setTileSize(10)
    #expect(setting.tileSize == 100)
    UserDefaults.standard.set(5000.0, forKey: size)
    #expect(LibraryLayoutSetting(viewModeKey: mode, sizeKey: size).tileSize == 260)
}
```

- [ ] **Step 2: Run them to verify they fail**

Expected: build error, `cannot find 'LibraryLayoutSetting' in scope`.

- [ ] **Step 3: Implement the setting**

```swift
import Foundation

/// How the library shows its games.
enum LibraryViewMode: Int, CaseIterable {
    case grid = 0
    case list = 1
}

/// The library's view mode and grid tile width, persisted. Shaped after
/// `InternalResolution`: `init` resolves, `set` persists, the clamp lives in
/// the type so it is reachable from a test without a window.
///
/// The size is probed with `object(forKey:)`: `double(forKey:)` reads an
/// absent key as 0, which the clamp would turn into the SMALLEST tiles
/// rather than today's default.
struct LibraryLayoutSetting {
    static let sizeRange: ClosedRange<Double> = 100...260
    /// Today's grid minimum, so the library looks unchanged until the
    /// slider moves.
    static let defaultSize = 132.0
    /// What Bigger and Smaller Covers move by.
    static let step = 20.0

    private let defaults: UserDefaults
    private let sizeKey: String
    private var mode: PersistedChoice<LibraryViewMode>
    private(set) var tileSize: Double

    var viewMode: LibraryViewMode { mode.value }

    init(viewModeKey: String = "libraryViewMode", sizeKey: String = "libraryTileSize",
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.sizeKey = sizeKey
        mode = PersistedChoice(key: viewModeKey, defaults: defaults, fallback: .grid)
        let stored = (defaults.object(forKey: sizeKey) as? NSNumber)?.doubleValue
        tileSize = Self.clamped(stored ?? Self.defaultSize)
    }

    mutating func setViewMode(_ value: LibraryViewMode) { mode.set(value) }

    mutating func setTileSize(_ value: Double) {
        tileSize = Self.clamped(value)
        defaults.set(tileSize, forKey: sizeKey)
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, sizeRange.lowerBound), sizeRange.upperBound)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Expected: 3 tests passed.

- [ ] **Step 5: View-model seams**

Beside `ditherMode` in `EmulatorViewModel.swift`:

```swift
    private var libraryLayout = LibraryLayoutSetting()

    /// Grid or list. The toolbar and Library ▸ as Grid / as List both bind here.
    var libraryViewMode: LibraryViewMode {
        get { libraryLayout.viewMode }
        set { libraryLayout.setViewMode(newValue) }
    }

    /// The grid's tile width in points, clamped by the setting.
    var libraryTileSize: Double {
        get { libraryLayout.tileSize }
        set { libraryLayout.setTileSize(newValue) }
    }

    var canGrowCovers: Bool { libraryTileSize < LibraryLayoutSetting.sizeRange.upperBound }
    var canShrinkCovers: Bool { libraryTileSize > LibraryLayoutSetting.sizeRange.lowerBound }
    func growCovers() { libraryTileSize += LibraryLayoutSetting.step }
    func shrinkCovers() { libraryTileSize -= LibraryLayoutSetting.step }
```

- [ ] **Step 6: Grid uses the size**

In `LibraryView.swift`:

1. Replace the three statics `tileMinimum`, `tileSpacing`, `columns` with:

```swift
    private static let tileSpacing: CGFloat = 20
    /// Today's 132:180 minimum-to-maximum ratio, kept at every size so the
    /// columns still stretch to fill the width.
    private static let tileStretch: CGFloat = 1.36

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: tileSize, maximum: tileSize * Self.tileStretch),
                  spacing: Self.tileSpacing, alignment: .top)]
    }
```

2. Add after `isDialogShown`:

```swift
    var viewMode: LibraryViewMode = .grid
    /// The grid's tile width, from `EmulatorViewModel.libraryTileSize`.
    var tileSize: CGFloat = LibraryLayoutSetting.defaultSize
```

3. `LazyVGrid(columns: Self.columns, ...)` becomes `LazyVGrid(columns: columns, ...)`.

4. The column count must follow the SIZE as well as the width: `onGeometryChange` fires only on a width change, so a count computed there goes stale the moment the slider moves. Store the width and derive the count. Replace `@State private var columnCount = 1` with:

```swift
    /// The grid's laid-out width; the column count is derived from it and
    /// the tile size, so either changing re-derives it.
    @State private var gridWidth: CGFloat = 0
    private var columnCount: Int {
        GridSelection.columns(width: gridWidth, minimum: tileSize, spacing: Self.tileSpacing)
    }
```

and the `onGeometryChange` action becomes `gridWidth = $0`. The existing `onMoveCommand` reads `columnCount` unchanged.

In `ContentView.swift`, add to the `LibraryView(...)` call after `isDialogShown:`:

```swift
                    isDialogShown: model.isDialogShown,
                    viewMode: model.libraryViewMode,
                    tileSize: CGFloat(model.libraryTileSize))
```

- [ ] **Step 7: Build and check**

Run: `cd /Users/david/Documents/develop/substation && zig build macos`. Temporarily verify by `defaults write <bundle-id> libraryTileSize -float 220` (bundle id from `zig-out/Substation.app/Contents/Info.plist`), launch, and confirm bigger tiles and that ↓ moves exactly one row (Task 7 repeats this after moving the slider live); then `defaults delete <bundle-id> libraryTileSize`.

- [ ] **Step 8: Commit**

```bash
git add ps1-macos/Sources/PS1/LibraryLayoutSetting.swift ps1-macos/Tests/PS1Tests/LibraryLayoutSettingTests.swift ps1-macos/Sources/PS1/EmulatorViewModel.swift ps1-macos/Sources/PS1/LibraryView.swift ps1-macos/Sources/PS1/ContentView.swift
git commit -m "feat(macos): persisted library view mode and cover size"
```

---

### Task 6: The list view

**Files:**
- Create: `ps1-macos/Sources/PS1/GameContextMenu.swift`, `ps1-macos/Sources/PS1/LibraryTable.swift`
- Modify: `ps1-macos/Sources/PS1/GameTile.swift` (its `.contextMenu { … }` block), `ps1-macos/Sources/PS1/LibraryView.swift`, `ps1-macos/Sources/PS1/ContentView.swift`

**Interfaces:**
- Consumes: `LibraryRow.rows(_:stats:)`, `LibraryFormat`, `CoverShape.isCutOut(_ image: NSImage)`, `EmulatorViewModel.playStats.all`.
- Produces:
  - `struct GameContextMenu: View { let entry: GameEntry; let play: () -> Void; let chooseCover: () -> Void; let downloadCover: (() -> Void)?; let removeCover: (() -> Void)? }`
  - `struct LibraryTable: View { let rows: [LibraryRow]; @Binding var selection: GameGroup.ID?; let coverURL: (GameEntry) -> URL?; let play: (GameGroup) -> Void; let menu: (GameGroup) -> GameContextMenu }`
  - `LibraryView` gains `var playStats: [String: PlayStats] = [:]`.

- [ ] **Step 1: Extract the shared context menu**

Create `GameContextMenu.swift`, moving the body of `GameTile`'s `.contextMenu { … }` verbatim:

```swift
import AppKit
import SwiftUI

/// What a right-click on a game offers, in the grid and the list alike, so
/// the two views cannot drift apart.
struct GameContextMenu: View {
    let entry: GameEntry
    let play: () -> Void
    let chooseCover: () -> Void
    /// Nil when the disc names no serial: the collection is keyed on serials.
    let downloadCover: (() -> Void)?
    /// Nil when there is no custom cover to remove.
    let removeCover: (() -> Void)?

    var body: some View {
        Button("Play", action: play)
        Divider()
        Button("Choose Cover Image…", action: chooseCover)
        if let downloadCover {
            Button("Download Cover", action: downloadCover)
        }
        if let removeCover {
            Button("Remove Custom Cover", action: removeCover)
        }
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }
    }
}
```

In `GameTile.swift` replace the whole `.contextMenu { … }` block with:

```swift
        .contextMenu {
            GameContextMenu(entry: entry, play: play, chooseCover: chooseCover,
                            downloadCover: downloadCover, removeCover: removeCover)
        }
```

- [ ] **Step 2: Write the table**

Create `LibraryTable.swift`:

```swift
import AppKit
import SwiftUI

/// The library as a sortable table: the same games as the grid, with their
/// region, serial and play history.
struct LibraryTable: View {
    let rows: [LibraryRow]
    @Binding var selection: GameGroup.ID?
    let coverURL: (GameEntry) -> URL?
    let play: (GameGroup) -> Void
    let menu: (GameGroup) -> GameContextMenu

    /// Session-only, starting by name: a sort is a question asked now.
    @State private var sortOrder = [KeyPathComparator(\LibraryRow.title)]
    private static let thumbnail: CGFloat = 28

    var body: some View {
        Table(rows.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.title) { row in
                HStack(spacing: 8) {
                    Thumbnail(url: coverURL(row.group.first), side: Self.thumbnail)
                    Text(row.title).lineLimit(1)
                }
            }
            .width(min: 180, ideal: 320)
            TableColumn("Region", value: \.region).width(min: 60, ideal: 70)
            TableColumn("Serial", value: \.serial).width(min: 80, ideal: 100)
            TableColumn("Discs", value: \.discs) { Text("\($0.discs)") }.width(min: 40, ideal: 45)
            TableColumn("Last Played", value: \.lastPlayedSortKey) {
                Text(LibraryFormat.lastPlayed($0.lastPlayed, now: Date()))
            }
            .width(min: 80, ideal: 100)
            TableColumn("Play Time", value: \.seconds) {
                Text(LibraryFormat.playTime($0.seconds))
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: GameGroup.ID.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                menu(row.group)
            }
        } primaryAction: { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                play(row.group)
            }
        }
    }
}

/// A row's cover, framed as the grid frames it: a flat scan rounded, a
/// cut-out case drawn as its own shape.
private struct Thumbnail: View {
    let url: URL?
    let side: CGFloat

    var body: some View {
        let image = url.flatMap(NSImage.init(contentsOf:))
        Group {
            if let image {
                let art = Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                if CoverShape.isCutOut(image) {
                    art
                } else {
                    art.clipShape(.rect(cornerRadius: 4))
                }
            } else {
                Image(systemName: "opticaldisc").foregroundStyle(.tertiary)
            }
        }
        .frame(width: side, height: side)
    }
}
```

`primaryAction` covers double-click AND Return in a `Table`.

- [ ] **Step 3: Switch views in LibraryView**

1. Add `var playStats: [String: PlayStats] = [:]` after `tileSize`.
2. In `body`, replace `} else { grid }` with:

```swift
            } else if viewMode == .list {
                list
            } else {
                grid
            }
```

3. Add:

```swift
    /// Shares `selection` with the grid, so switching views keeps the game.
    private var list: some View {
        LibraryTable(
            rows: LibraryRow.rows(groups, stats: playStats),
            selection: $selection,
            coverURL: coverURL,
            play: { play($0.first) },
            menu: { group in
                let url = coverURL(group.first)
                return GameContextMenu(
                    entry: group.first,
                    play: { play(group.first) },
                    chooseCover: { chooseCover(group.first) },
                    downloadCover: group.first.serial == nil ? nil : { downloadCover(group.first) },
                    removeCover: url == nil ? nil : { removeCover(group.first) })
            })
        // The title bar is hidden but still reserves its height.
        .padding(.top, 24)
    }
```

In `ContentView.swift`, add `playStats: model.playStats.all` after `tileSize:` in the `LibraryView(...)` call.

- [ ] **Step 4: Build, run the suite, check by hand**

```bash
cd /Users/david/Documents/develop/substation && pkill -x Substation; ps1-macos/test.sh 2>&1 | grep -E "✘|error:|Test run with|TEST (SUCCEEDED|FAILED)"
zig build macos && defaults write "$(defaults read "$PWD/zig-out/Substation.app/Contents/Info" CFBundleIdentifier)" libraryViewMode -int 1 && open zig-out/Substation.app
```

Check: columns show; clicking Play Time sorts (played games first descending); selecting a row then `defaults write … libraryViewMode -int 0` + relaunch shows the same game selected (selection survives a view switch within a session is checked properly in Task 7 via the toolbar); double-click and Return play; right-click shows the tile's menu; 3D thumbnails have no frame. Reset with `defaults delete … libraryViewMode`.

- [ ] **Step 5: Commit**

```bash
git add ps1-macos/Sources/PS1/GameContextMenu.swift ps1-macos/Sources/PS1/LibraryTable.swift ps1-macos/Sources/PS1/GameTile.swift ps1-macos/Sources/PS1/LibraryView.swift ps1-macos/Sources/PS1/ContentView.swift
git commit -m "feat(macos): library list view with region, serial and play history"
```

---

### Task 7: Toolbar and Library menu

**Files:**
- Modify: `ps1-macos/Sources/PS1/ContentView.swift`, `ps1-macos/Sources/PS1App/LibraryCommands.swift`

**Interfaces:**
- Consumes: `libraryViewMode`, `libraryTileSize`, `canGrowCovers`, `canShrinkCovers`, `growCovers()`, `shrinkCovers()`.

- [ ] **Step 1: Toolbar**

In `ContentView.swift`, after `.navigationTitle(...)`:

```swift
        // Library only: a game keeps its full-bleed picture and glass HUD.
        .toolbar {
            if model.stage == .library {
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.libraryViewMode == .grid {
                        HStack(spacing: 6) {
                            Image(systemName: "photo").imageScale(.small)
                            Slider(value: $model.libraryTileSize,
                                   in: LibraryLayoutSetting.sizeRange)
                                .frame(width: 110)
                            Image(systemName: "photo").imageScale(.large)
                        }
                        .help("Cover Size")
                    }
                    Picker("View", selection: $model.libraryViewMode) {
                        Image(systemName: "square.grid.2x2").tag(LibraryViewMode.grid)
                            .help("as Grid")
                        Image(systemName: "list.bullet").tag(LibraryViewMode.list)
                            .help("as List")
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .toolbar(model.stage == .library ? .visible : .hidden, for: .windowToolbar)
```

`ContentView` declares `@Bindable var model`, so `$model.libraryTileSize` and `$model.libraryViewMode` are available. The slider binds a `Double`, which is why `libraryTileSize` is `Double` and `LibraryView.tileSize` is converted with `CGFloat(model.libraryTileSize)` at the call site.

- [ ] **Step 2: Library menu**

In `LibraryCommands.swift`, at the top of `CommandMenu("Library") { … }`:

```swift
            Picker("View", selection: $model.libraryViewMode) {
                Text("as Grid").tag(LibraryViewMode.grid)
                    .keyboardShortcut("1", modifiers: [.command, .control])
                Text("as List").tag(LibraryViewMode.list)
                    .keyboardShortcut("2", modifiers: [.command, .control])
            }
            .pickerStyle(.inline)
            .disabled(model.stage != .library)

            Button("Bigger Covers") { model.growCovers() }
                .keyboardShortcut("+")
                .disabled(model.stage != .library || model.libraryViewMode != .grid
                          || !model.canGrowCovers)
            Button("Smaller Covers") { model.shrinkCovers() }
                .keyboardShortcut("-")
                .disabled(model.stage != .library || model.libraryViewMode != .grid
                          || !model.canShrinkCovers)

            Divider()
```

If `.keyboardShortcut` on a `Picker`'s tagged `Text` does not register (inline pickers in menus sometimes drop them), replace the picker with two `Toggle`s bound through `Binding(get: { model.libraryViewMode == .grid }, set: { if $0 { model.libraryViewMode = .grid } })` and the same for `.list`, each with its shortcut.

- [ ] **Step 3: Build and verify in the app**

```bash
cd /Users/david/Documents/develop/substation && pkill -x Substation; zig build macos && open zig-out/Substation.app
```

Check each, and fix before committing:
1. Toolbar shows in the library; the slider resizes tiles live, and after moving it ↓ still moves exactly one row; the picker switches views and the selected game stays selected across the switch.
2. ⌃⌘1 / ⌃⌘2 switch views; ⌘+ / ⌘− resize and disable at the bounds.
3. Covers do not hide under the toolbar at the top of the scroll; if they do, adjust `LibraryView`'s `.padding(.top, 24)` (grid and list) rather than the window style.
4. Open a game: the toolbar is gone, the picture is full-bleed, the HUD and traffic lights fade as before.
5. Fullscreen (⌃⌘F) in and out THREE times in the library and THREE times in a game: no abort, no 4:3 letterbox in fullscreen, the window returns to 4:3 in a game. This is the `WindowConfigurator` risk named in the spec.
6. Quit and relaunch: view mode and size are remembered.

Take screenshots of grid and list for the hand-back:

```bash
screencapture -o -l "$(swift -e 'import CoreGraphics; for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]] where (w[kCGWindowOwnerName as String] as? String) == "Substation" && (w[kCGWindowLayer as String] as? Int) == 0 { print(w[kCGWindowNumber as String]!); break }')" /tmp/library-grid.png
```

- [ ] **Step 4: Run the full suite**

Run: `cd /Users/david/Documents/develop/substation && pkill -x Substation; ps1-macos/test.sh 2>&1 | grep -E "✘|error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add ps1-macos/Sources/PS1/ContentView.swift ps1-macos/Sources/PS1App/LibraryCommands.swift
git commit -m "feat(macos): library toolbar and menu for view mode and cover size"
```

---

### Task 8: Document it

**Files:**
- Modify: `.claude/skills/ps1-macos-app/SKILL.md`, `docs/superpowers/specs/2026-10-06-library-view-options-design.md`

- [ ] **Step 1: Skill paragraph**

Add after the `DiscGrouping` paragraph in the skill, in its voice:

```markdown
**The library has a toolbar, and ONLY the library does**
(`LibraryLayoutSetting`, `LibraryTable`, `ContentView`'s `.toolbar`). A
Grid | List picker and, in grid view, a cover-size slider (100-260 pt,
default 132, today's old minimum; Library ▸ Bigger/Smaller Covers ⌘+/⌘−,
as Grid/List ⌃⌘1/⌃⌘2 because ⌘1-8 are Internal Resolution). The toolbar is
hidden on `.playing` so a game keeps its full-bleed picture. The size is
probed with `object(forKey:)` because `double(forKey:)` reads absence as 0,
which the clamp turns into the smallest tiles. The list and the grid share
one selection and one context menu (`GameContextMenu`).

**Play time is ACTIVE play only** (`PlayClock`, `PlayStatsStore`,
`Application Support/Substation/PlayStats/stats.json`). The clock runs while
a game is running AND unpaused AND the app is active: the app does NOT pause
a game in the background, so app-active is its own input, fed by the
resign/become-active observers. Every input change goes through
`EmulatorViewModel.updatePlayClock()`, and teardown banks the last stretch
BEFORE it clears `resumeKey`, which is the key stats are filed under (the
resume-state key: a multi-disc game has one record). A damaged stats file
reads as empty and is only ever replaced by the next write.
```

- [ ] **Step 2: Spec path**

In the spec's section 4, change `Application Support/Substation/PlayStats.json` to `Application Support/Substation/PlayStats/stats.json` (the store goes through `AppSupport.directory` like every other).

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/ps1-macos-app/SKILL.md docs/superpowers/specs/2026-10-06-library-view-options-design.md
git commit -m "docs: library toolbar, list view and play time"
```
