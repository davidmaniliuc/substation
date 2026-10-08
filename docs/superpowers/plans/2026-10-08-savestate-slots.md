# Savestate Slots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Six manual save-state slots, a kept previous resume state, timed auto-save into the resume state, and Undo Load State, in the macOS app.

**Architecture:** One on-disk unit (`StateFile`: LZFSE state + PNG) is shared by a renamed store (`ResumeStateStore` becomes `SaveStateStore`) that owns resume, previous and slot files. The emulator runner gains a load request serviced between frames (and its save request becomes a queue so two askers never displace each other). The view model glues them: slot save/load, undo, a timed auto-save driven by a pure `AutoSaveClock`, and the Machine menu and launch sheet read the store.

**Tech Stack:** Swift 6, SwiftUI, swift-testing, `xcodebuild` (no SwiftPM), the `ps1-capi` C ABI through `Ps1Core`.

**Spec:** `docs/superpowers/specs/2026-10-08-savestate-slots-design.md`

## Global Constraints

- macOS app only: no change under `ps1-core/`, `ps1-capi/`, `ps1-wasm/`, `ps1-web/`, and no golden recapture.
- Slots are numbered `1...6` (`StateSource.slots`). Slot files: `Application Support/Substation/SaveStates/<key>/slot<N>.state` + `.png`. Resume files stay `ResumeStates/<key>.state` + `.png`; previous is `<key>.prev.*`; the staging file is `<key>.new.*`.
- `<key>` is `SaveStateStore.key(for:)`: the merged game's first disc's serial, else its path hash.
- Nothing automatic ever writes a slot. Delete & Boot never removes a slot.
- Auto-save setting key `autoSaveInterval`, minutes, choices `[0, 1, 5, 10]`, `0` = Off, default `5`; absence probed with `object(forKey:)`.
- Shortcuts: Load Slot N = F*N* (no modifier), Save Slot N = ⇧F*N*. Undo Load State, Load Resume, Load Previous Resume: no shortcut.
- Settings copy lives in `SettingsCopy.swift` and must pass `SettingsCopyTests` (no em/en dashes, finished sentences).
- No reference emulator names in code comments or commits.
- Commit messages are a **title line only**: no body, no trailer. Commit directly on `master`. Stage only the files the task names: the working tree carries unrelated modified goldens that must NOT be committed.
- `pkill -x Substation` before any Swift test run.
- Prerequisites once per session: `zig build capi-lib && zig build metallib` from the repo root.
- **Focused test command** (run from the repo root; `NAME` is a swift-testing free function, parentheses required, and check the `Executed N tests` line since a filter that matches nothing "passes"):

  ```bash
  pkill -x Substation; xcodebuild -project ps1-macos/PS1.xcodeproj -scheme PS1 -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" SYMROOT=.build/xcode test \
    "-only-testing:PS1Tests/NAME()" 2>&1 | grep -E "✔|✘|Executed|error:"
  ```

  Several names: repeat the `-only-testing` argument. Full suite: `ps1-macos/test.sh`.

## Review Focus

1. **A save on exit and a timed auto-save landing together.** Both write `<key>` from different threads; a reasonable person expects one complete resume and one complete previous, never a torn or missing file. Pinned in Task 1 (`concurrentResumeWritesLeaveOneWholeState`) by the store's serial queue.
2. **Two save requests queued before one frame** (slot save pressed while an auto-save is pending, or an exit save behind an auto-save). Today the second replaces the first, which is then never answered and would hold an exit for its 3 s fallback. Expected: both answered with the same snapshot. Pinned in Task 2 (`twoSaveRequestsBeforeOneFrameAreBothAnswered`).
3. **A load completing after the game was ejected or replaced.** Expected: nothing about the new game changes (no undo buffer, no notice from the old one). Pinned in Task 4 by the `self.runner === runner` guard (`aLoadAnsweredAfterTeardownIsIgnored`).
4. **A crash between the two renames of a resume write.** Expected: the launch sheet still offers something, and the next resume write does not destroy the surviving previous. Pinned in Task 1 (`aWriteAfterACrashMidRotationKeepsThePrevious`) and Task 6 (`onlyAPreviousStillProducesAnOffer`).
5. **Loading a slot saved on the other disc of a multi-disc game, and that load being refused** (different BIOS, newer version). Expected: the running game keeps running with a notice, not the launch-time failure alert whose Cancel ejects. No automated test can reach it (a state naming a serial needs a real disc, and the suite has none), so Task 4 routes it through `load(disc:resume:freshBoot:resumeRefused:)` and Task 7 Step 3 checks it by hand on Final Fantasy VII.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `ps1-macos/Sources/PS1/StateFile.swift` (new) | One saved machine on disk: write, load, info, remove, atomic move. |
| `ps1-macos/Sources/PS1/SaveStateStore.swift` (renamed from `ResumeStateStore.swift`) | `StateSource`, the key rule, where each source lives, resume rotation, slot writes, serialised writes. |
| `ps1-macos/Sources/PS1/EmulatorRunner.swift` | Save request queue; new load request; card re-install after a load. |
| `ps1-macos/Sources/PS1/AutoSaveSetting.swift` (new) | The interval preference. |
| `ps1-macos/Sources/PS1/AutoSaveClock.swift` (new) | Active play since the last auto-save. |
| `ps1-macos/Sources/PS1/EmulatorViewModel.swift` | Slot save/load, undo, auto-save tick, notice rename, injection seams. |
| `ps1-macos/Sources/PS1App/MachineCommands.swift` | Save State / Load State / Undo Load State menus. |
| `ps1-macos/Sources/PS1/ResumeOffer.swift`, `ResumePromptSheet.swift` | Launch sheet lists previous resume and slots. |
| `ps1-macos/Sources/PS1/Settings/SettingsCopy.swift`, `GeneralSettingsPane.swift` | Auto-save row. |
| `ps1-macos/Sources/PS1/GameHUD.swift`, `GameWindowView.swift` | `PadNotice` becomes `GameNotice`. |
| `.claude/skills/ps1-macos-app/SKILL.md` | "Resume states" section updated. |

---

### Task 1: `StateFile` and `SaveStateStore`

**Files:**
- Create: `ps1-macos/Sources/PS1/StateFile.swift`
- Rename: `ps1-macos/Sources/PS1/ResumeStateStore.swift` → `ps1-macos/Sources/PS1/SaveStateStore.swift` (rewritten)
- Rename: `ps1-macos/Tests/PS1Tests/ResumeStateStoreTests.swift` → `ps1-macos/Tests/PS1Tests/SaveStateStoreTests.swift`
- Modify (rename call sites only): `Sources/PS1/ResumeOffer.swift`, `Sources/PS1/LibraryRow.swift`, `Sources/PS1/PlayStatsStore.swift` (comment), `Sources/PS1/EmulatorViewModel.swift`, `Tests/PS1Tests/ResumeOfferTests.swift`, `Tests/PS1Tests/EmulatorViewModelStageTests.swift`, `Tests/PS1Tests/DiscKindTests.swift`

**Interfaces:**
- Produces:
  - `struct StateFile: Sendable { struct Info: Equatable { let savedAt: Date; let thumbnail: URL? }; init(directory: URL, stem: String); let directory, state, thumbnail: URL; var info: Info?; func load() -> Data?; func write(state: Data, thumbnail: Data?) throws; func remove(); func move(to: StateFile) throws }`
  - `enum StateSource: Hashable, Sendable { case resume, previous, slot(Int); static let slots: ClosedRange<Int> /* 1...6 */; var title: String }`
  - `struct SavedState: Equatable { let source: StateSource; let info: StateFile.Info }`
  - `final class SaveStateStore: Sendable { typealias Info = StateFile.Info; init(resumeDirectory: URL? = nil, slotsDirectory: URL? = nil); static func key(for: GameEntry) -> String; func file(_: StateSource, key: String) -> StateFile; func info(_: StateSource, key: String) -> Info?; func load(_: StateSource, key: String) -> Data?; func saved(key: String) -> [SavedState]; func saveResume(state: Data, thumbnail: Data?, key: String) throws; func saveSlot(_ n: Int, state: Data, thumbnail: Data?, key: String) throws; func removeResume(_ key: String) }`
  - `EmulatorViewModel.saveStates: SaveStateStore` (renamed from `resumeStates`)

- [ ] **Step 1: Rename the files with git so history follows**

```bash
cd /Users/david/Documents/develop/substation
git mv ps1-macos/Sources/PS1/ResumeStateStore.swift ps1-macos/Sources/PS1/SaveStateStore.swift
git mv ps1-macos/Tests/PS1Tests/ResumeStateStoreTests.swift ps1-macos/Tests/PS1Tests/SaveStateStoreTests.swift
```

- [ ] **Step 2: Write the failing tests**

Replace the whole of `ps1-macos/Tests/PS1Tests/SaveStateStoreTests.swift` with:

```swift
import Testing
import Foundation
@testable import PS1

private func tempDirectory(_ tag: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(tag)-\(UUID().uuidString)")
}

private func makeStore() -> (store: SaveStateStore, resume: URL, slots: URL) {
    let resume = tempDirectory("resume")
    let slots = tempDirectory("slots")
    return (SaveStateStore(resumeDirectory: resume, slotsDirectory: slots), resume, slots)
}

private func entry(_ path: String, serial: String?) -> GameEntry {
    GameEntry(url: URL(fileURLWithPath: path), identity: DiscIdentity(region: .america, serial: serial, volumeID: nil))
}

@Test func aStateReadsBackByteForByteThroughCompression() throws {
    let (store, _, _) = makeStore()
    let state = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 / 1000) })
    try store.saveResume(state: state, thumbnail: Data([1, 2, 3]), key: "SLUS-00001")
    #expect(store.load(.resume, key: "SLUS-00001") == state)
    let info = try #require(store.info(.resume, key: "SLUS-00001"))
    #expect(info.thumbnail != nil)
    #expect(abs(info.savedAt.timeIntervalSinceNow) < 60)
}

@Test func aGameWithNoStateHasNoInfo() {
    let (store, _, _) = makeStore()
    #expect(store.info(.resume, key: "nothing") == nil)
    #expect(store.load(.resume, key: "nothing") == nil)
    #expect(store.saved(key: "nothing").isEmpty)
}

@Test func savingWithoutAThumbnailDropsTheOldOne() throws {
    let (store, _, _) = makeStore()
    try store.saveSlot(1, state: Data([1]), thumbnail: Data([9]), key: "k")
    try store.saveSlot(1, state: Data([2]), thumbnail: nil, key: "k")
    #expect(store.info(.slot(1), key: "k")?.thumbnail == nil)
}

@Test func anUndecodableFileLoadsAsNilButStillHasInfo() throws {
    // So the prompt still appears and Delete & Boot stays reachable.
    let (store, resume, _) = makeStore()
    try store.saveResume(state: Data([1]), thumbnail: nil, key: "k")
    try Data("garbage".utf8).write(to: resume.appendingPathComponent("k.state"))
    #expect(store.load(.resume, key: "k") == nil)
    #expect(store.info(.resume, key: "k") != nil)
}

@Test func theKeyIsTheSerialElseThePathHash() {
    #expect(SaveStateStore.key(for: entry("/g/a.cue", serial: "SCUS-94163")) == "SCUS-94163")
    let unnamed = entry("/g/b.cue", serial: nil)
    #expect(SaveStateStore.key(for: unnamed) == unnamed.pathKey)
    #expect(unnamed.pathKey.count == 64)
}

@Test func saveOnExitDefaultsOnAndPersists() {
    let defaults = UserDefaults(suiteName: "resume-\(UUID().uuidString)")!
    var setting = ResumeOnExitSetting(key: "k", defaults: defaults)
    #expect(setting.enabled)
    setting.set(false)
    #expect(!ResumeOnExitSetting(key: "k", defaults: defaults).enabled)
}

@Test func aSecondResumeWriteKeepsTheFirstAsPrevious() throws {
    let (store, _, _) = makeStore()
    try store.saveResume(state: Data([1]), thumbnail: Data([7]), key: "k")
    #expect(store.info(.previous, key: "k") == nil)
    try store.saveResume(state: Data([2]), thumbnail: nil, key: "k")
    #expect(store.load(.resume, key: "k") == Data([2]))
    #expect(store.load(.previous, key: "k") == Data([1]))
    // The thumbnail travels with its state, and the new one has none.
    #expect(store.info(.previous, key: "k")?.thumbnail != nil)
    #expect(store.info(.resume, key: "k")?.thumbnail == nil)
}

@Test func aCrashAfterStagingLeavesTheOldResume() throws {
    let (store, resume, _) = makeStore()
    try store.saveResume(state: Data([1]), thumbnail: nil, key: "k")
    // Step 1 of a write done, steps 2 and 3 never ran.
    try StateFile(directory: resume, stem: "k.new").write(state: Data([2]), thumbnail: nil)
    #expect(store.load(.resume, key: "k") == Data([1]))
}

@Test func aWriteAfterACrashMidRotationKeepsThePrevious() throws {
    // Step 2 ran (the resume became previous), step 3 never did: no resume.
    let (store, resume, _) = makeStore()
    try StateFile(directory: resume, stem: "k.prev").write(state: Data([1]), thumbnail: nil)
    #expect(store.info(.resume, key: "k") == nil)
    try store.saveResume(state: Data([2]), thumbnail: nil, key: "k")
    #expect(store.load(.resume, key: "k") == Data([2]))
    #expect(store.load(.previous, key: "k") == Data([1]))
}

@Test func slotsLiveInAFolderPerGame() throws {
    let (store, _, slots) = makeStore()
    try store.saveSlot(3, state: Data([5]), thumbnail: Data([6]), key: "SLUS-1")
    #expect(FileManager.default.fileExists(atPath: slots.appendingPathComponent("SLUS-1/slot3.state").path))
    #expect(FileManager.default.fileExists(atPath: slots.appendingPathComponent("SLUS-1/slot3.png").path))
    #expect(store.load(.slot(3), key: "SLUS-1") == Data([5]))
    #expect(store.info(.slot(4), key: "SLUS-1") == nil)
}

@Test func savedListsEveryStateInMenuOrder() throws {
    let (store, _, _) = makeStore()
    try store.saveSlot(5, state: Data([1]), thumbnail: nil, key: "k")
    try store.saveResume(state: Data([1]), thumbnail: nil, key: "k")
    try store.saveResume(state: Data([2]), thumbnail: nil, key: "k")
    try store.saveSlot(2, state: Data([1]), thumbnail: nil, key: "k")
    #expect(store.saved(key: "k").map(\.source) == [.resume, .previous, .slot(2), .slot(5)])
}

@Test func removingTheResumeLeavesEverySlot() throws {
    let (store, _, _) = makeStore()
    try store.saveResume(state: Data([1]), thumbnail: nil, key: "k")
    try store.saveResume(state: Data([2]), thumbnail: nil, key: "k")
    try store.saveSlot(1, state: Data([3]), thumbnail: nil, key: "k")
    store.removeResume("k")
    #expect(store.info(.resume, key: "k") == nil)
    #expect(store.info(.previous, key: "k") == nil)
    #expect(store.load(.slot(1), key: "k") == Data([3]))
}

/// An exit save and a timed auto-save can land at once from two threads.
@Test func concurrentResumeWritesLeaveOneWholeState() throws {
    let (store, _, _) = makeStore()
    DispatchQueue.concurrentPerform(iterations: 16) { i in
        try? store.saveResume(state: Data(repeating: UInt8(i), count: 4096), thumbnail: nil, key: "k")
    }
    let resume = try #require(store.load(.resume, key: "k"))
    let previous = try #require(store.load(.previous, key: "k"))
    #expect(resume.count == 4096 && Set(resume).count == 1)
    #expect(previous.count == 4096 && Set(previous).count == 1)
    #expect(resume != previous)
}

@Test func sourcesHaveMenuTitles() {
    #expect(StateSource.resume.title == "Resume")
    #expect(StateSource.previous.title == "Previous Resume")
    #expect(StateSource.slot(4).title == "Slot 4")
    #expect(StateSource.slots == 1...6)
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run the focused command with `NAME` = `aSecondResumeWriteKeepsTheFirstAsPrevious`.
Expected: build FAILS, `error: cannot find 'SaveStateStore' in scope`.

- [ ] **Step 4: Write `StateFile.swift`**

```swift
import Foundation

/// One saved machine on disk: `<stem>.state` (the core's state, LZFSE
/// compressed; the core never compresses) and `<stem>.png` (its thumbnail).
/// The resume state, its previous copy and every manual slot are each one of
/// these, so there is one write path.
///
/// Writes are atomic (`.atomic` writes a temporary file and renames it), so a
/// crash mid-save leaves the previous file rather than a torn one. The
/// thumbnail is written first (or removed first, when there is none), so a
/// crash between the two leaves the old state under a new picture or under
/// no picture; the tile falls back to its placeholder.
struct StateFile: Sendable {
    struct Info: Equatable {
        let savedAt: Date
        let thumbnail: URL?
    }

    let directory: URL
    let state: URL
    let thumbnail: URL

    init(directory: URL, stem: String) {
        self.directory = directory
        state = directory.appendingPathComponent("\(stem).state")
        thumbnail = directory.appendingPathComponent("\(stem).png")
    }

    var info: Info? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: state.path)
        guard let savedAt = attrs?[.modificationDate] as? Date else { return nil }
        return Info(savedAt: savedAt,
                    thumbnail: FileManager.default.fileExists(atPath: thumbnail.path) ? thumbnail : nil)
    }

    func load() -> Data? {
        guard let packed = try? Data(contentsOf: state) else { return nil }
        return try? (packed as NSData).decompressed(using: .lzfse) as Data
    }

    func write(state data: Data, thumbnail png: Data?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let png {
            try png.write(to: thumbnail, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: thumbnail)
        }
        let packed = try (data as NSData).compressed(using: .lzfse) as Data
        try packed.write(to: state, options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: state)
        try? FileManager.default.removeItem(at: thumbnail)
    }

    /// Renames this state over `destination`, replacing it. `rename(2)`
    /// replaces atomically; `FileManager.moveItem` refuses an existing
    /// destination, so it would need a remove first, and a crash between the
    /// two would lose both. The thumbnail moves first, for the write order's
    /// reason; a state with none clears the destination's.
    func move(to destination: StateFile) throws {
        if rename(thumbnail.path, destination.thumbnail.path) != 0 {
            try? FileManager.default.removeItem(at: destination.thumbnail)
        }
        guard rename(state.path, destination.state.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
```

- [ ] **Step 5: Replace the whole of `SaveStateStore.swift`**

```swift
import Foundation

/// Which saved machine: the resume state the app writes on exit and on a
/// timer, the one it replaced, or one of the player's manual slots.
enum StateSource: Hashable, Sendable {
    case resume, previous, slot(Int)

    static let slots = 1...6

    var title: String {
        switch self {
        case .resume: "Resume"
        case .previous: "Previous Resume"
        case .slot(let n): "Slot \(n)"
        }
    }
}

struct SavedState: Equatable {
    let source: StateSource
    let info: StateFile.Info
}

/// Every saved machine of every game, on disk.
///
/// **Resume** is the machine's own bookmark:
/// `Application Support/Substation/ResumeStates/<key>.state` + `.png`. The
/// player loads it but never saves into it. Every write keeps the one it
/// replaces as `<key>.prev.*`, so a resume written at a bad moment can be
/// undone: the new state is staged as `<key>.new.*`, the current one renamed
/// to previous, then the staged one renamed into place. A crash leaves the
/// old resume (after staging) or a previous with no resume (after the first
/// rename), never nothing.
///
/// **Slots** are the player's: `SaveStates/<key>/slot<N>.*`, N in 1...6.
/// Nothing automatic writes one, and Delete & Boot never removes one.
///
/// Keyed on the game's FIRST disc, so a multi-disc game has one set, and a
/// state's own header says which disc was in the tray. Serial first, path
/// hash for a disc that names none: the `CoverStore` rule, so a rip that is
/// moved or renamed keeps its states.
///
/// Every write goes through one queue: an exit save and a timed auto-save
/// can arrive together from two threads, and the rotation is three steps.
final class SaveStateStore: Sendable {
    typealias Info = StateFile.Info

    private let resumeDirectory: URL
    private let slotsDirectory: URL
    private let queue = DispatchQueue(label: "PS1.SaveStateStore")

    init(resumeDirectory: URL? = nil, slotsDirectory: URL? = nil) {
        self.resumeDirectory = resumeDirectory ?? AppSupport.directory("ResumeStates")
        self.slotsDirectory = slotsDirectory ?? AppSupport.directory("SaveStates")
    }

    static func key(for game: GameEntry) -> String {
        game.serial ?? game.pathKey
    }

    func file(_ source: StateSource, key: String) -> StateFile {
        switch source {
        case .resume:
            StateFile(directory: resumeDirectory, stem: key)
        case .previous:
            StateFile(directory: resumeDirectory, stem: "\(key).prev")
        case .slot(let n):
            StateFile(directory: slotsDirectory.appendingPathComponent(key, isDirectory: true),
                      stem: "slot\(n)")
        }
    }

    func info(_ source: StateSource, key: String) -> Info? {
        file(source, key: key).info
    }

    func load(_ source: StateSource, key: String) -> Data? {
        file(source, key: key).load()
    }

    /// Every state the game has, in menu order: resume, previous, slots.
    func saved(key: String) -> [SavedState] {
        ([.resume, .previous] + StateSource.slots.map { .slot($0) }).compactMap { source in
            info(source, key: key).map { SavedState(source: source, info: $0) }
        }
    }

    func saveResume(state: Data, thumbnail: Data?, key: String) throws {
        try queue.sync {
            let current = file(.resume, key: key)
            let staged = StateFile(directory: resumeDirectory, stem: "\(key).new")
            try staged.write(state: state, thumbnail: thumbnail)
            // Only a resume that exists is rotated: after a crash mid-rotation
            // the previous is the only state left, and it must survive.
            if current.info != nil { try current.move(to: file(.previous, key: key)) }
            try staged.move(to: current)
        }
    }

    func saveSlot(_ n: Int, state: Data, thumbnail: Data?, key: String) throws {
        precondition(StateSource.slots.contains(n), "slot \(n) is outside \(StateSource.slots)")
        try queue.sync {
            try file(.slot(n), key: key).write(state: state, thumbnail: thumbnail)
        }
    }

    /// Delete & Boot: the resume and its previous, never a slot.
    func removeResume(_ key: String) {
        queue.sync {
            file(.resume, key: key).remove()
            file(.previous, key: key).remove()
            StateFile(directory: resumeDirectory, stem: "\(key).new").remove()
        }
    }
}
```

- [ ] **Step 6: Update every call site of the old store**

```bash
cd /Users/david/Documents/develop/substation/ps1-macos
grep -rl "ResumeStateStore" Sources Tests | xargs sed -i '' 's/ResumeStateStore/SaveStateStore/g'
grep -rl "resumeStates" Sources Tests | xargs sed -i '' 's/resumeStates/saveStates/g'
```

Then by hand in `Sources/PS1/EmulatorViewModel.swift`:
- the declaration comment above `let saveStates = SaveStateStore()` becomes `/// Every saved machine of every game. Outlives every disc, like \`cards\`.`
- in `chooseResume`: `saveStates.load(offer.key)` → `saveStates.load(.resume, key: offer.key)`; `saveStates.remove(offer.key)` → `saveStates.removeResume(offer.key)`
- in `confirmExit`: `store.save(state: snap.state, thumbnail: snap.thumbnail, key: key)` → `store.saveResume(state: snap.state, thumbnail: snap.thumbnail, key: key)`

In `Sources/PS1/ResumeOffer.swift`: `store.info(key)` → `store.info(.resume, key: key)`, `store.load(key)` → `store.load(.resume, key: key)`.

In `Tests/PS1Tests/ResumeOfferTests.swift`:
- `makeStore()` returns `SaveStateStore(resumeDirectory: <temp "offer-…">, slotsDirectory: <temp "offer-slots-…">)`;
- `store.save(state:thumbnail:key:)` → `store.saveResume(state:thumbnail:key:)`;
- in `aDamagedStateStillProducesAnOffer`, `SaveStateStore(directory: dir)` → `SaveStateStore(resumeDirectory: dir, slotsDirectory: dir.appendingPathComponent("slots"))`.

Build check: `grep -rn "store.save(\|\.remove(offer\|SaveStateStore(directory" Sources Tests` prints nothing.

- [ ] **Step 7: Run the store and offer tests**

Run the focused command with every test in `SaveStateStoreTests.swift` and `ResumeOfferTests.swift` (one `-only-testing` per name).
Expected: all PASS; the `Executed` line counts 18.

- [ ] **Step 8: Commit**

```bash
cd /Users/david/Documents/develop/substation
git add ps1-macos/Sources/PS1/StateFile.swift ps1-macos/Sources/PS1/SaveStateStore.swift \
  ps1-macos/Tests/PS1Tests/SaveStateStoreTests.swift ps1-macos/Sources/PS1/ResumeOffer.swift \
  ps1-macos/Sources/PS1/LibraryRow.swift ps1-macos/Sources/PS1/PlayStatsStore.swift \
  ps1-macos/Sources/PS1/EmulatorViewModel.swift ps1-macos/Tests/PS1Tests/ResumeOfferTests.swift \
  ps1-macos/Tests/PS1Tests/EmulatorViewModelStageTests.swift ps1-macos/Tests/PS1Tests/DiscKindTests.swift
git status --short ps1-macos   # ResumeStateStore*.swift must show as renamed, nothing unstaged under ps1-macos
git commit -m "feat(macos): one store for resume, previous resume and save slots"
```

---

### Task 2: Runner save queue and load request

**Files:**
- Modify: `ps1-macos/Sources/PS1/EmulatorRunner.swift` (`pendingSave` ~136, `requestSaveState` ~322, `takePendingSave`/`serviceSaveRequest`/`failPendingSave` ~354-382, `stop()` ~500, `runLoop()` ~554)
- Create: `ps1-macos/Tests/PS1Tests/EmulatorRunnerLoadStateTests.swift`
- Modify: `ps1-macos/Tests/PS1Tests/EmulatorRunnerSaveStateTests.swift` (one new test)

**Interfaces:**
- Consumes: `Ps1Core.saveState()`, `loadState(_:)`, `loadMemcard(_:slot:)`, `padStatus()`; `MemoryCardStore.load(slot:)`.
- Produces:
  - `func requestLoadState(_ state: Data, _ completion: @escaping @Sendable (Result<Data, Error>) -> Void)`: success carries the machine the load REPLACED (the undo state).
  - `func serviceLoadRequests()` (internal, a test seam like `serviceSaveRequest`).
  - `requestSaveState` unchanged in signature; now queues.

- [ ] **Step 1: Write the failing tests**

Append to `EmulatorRunnerSaveStateTests.swift`:

```swift
/// A slot save pressed while an auto-save waits: the second must not
/// displace the first, which would then never be answered.
@Test func twoSaveRequestsBeforeOneFrameAreBothAnswered() throws {
    let runner = try makeRunner()
    let got = Mutex<[Data]>([])
    for _ in 0..<2 {
        runner.requestSaveState { result in
            if case .success(let snap) = result { got.withLock { $0.append(snap.state) } }
        }
    }
    runner.serviceSaveRequest()
    let states = got.withLock { $0 }
    #expect(states.count == 2)
    #expect(states.first == states.last)
}
```

Create `EmulatorRunnerLoadStateTests.swift`:

```swift
import Testing
import Foundation
import Synchronization
@testable import PS1

private func makeMachine() throws -> (runner: EmulatorRunner, core: Ps1Core, cards: MemoryCardStore) {
    let core = try Ps1Core()
    try core.loadBIOS(Data(repeating: 0, count: 524288))
    let cards = MemoryCardStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("load-\(UUID().uuidString)"))
    let runner = EmulatorRunner(core: core, ring: AudioRing(capacity: EmulatorRunner.ringCapacity),
                                cards: cards)
    return (runner, core, cards)
}

@Test func aLoadAnswersWithTheMachineItReplaced() throws {
    let (runner, core, _) = try makeMachine()
    let saved = try core.saveState()
    let got = Mutex<Result<Data, Error>?>(nil)
    runner.requestLoadState(saved) { result in got.withLock { $0 = result } }
    runner.serviceLoadRequests()

    let undo = try #require(got.withLock { $0 }).get()
    let other = try Ps1Core()
    try other.loadBIOS(Data(repeating: 0, count: 524288))
    try other.loadState(undo)
}

@Test func aRefusedLoadLeavesTheMachineAsItWas() throws {
    let (runner, core, _) = try makeMachine()
    let before = try core.saveState()
    let got = Mutex<Result<Data, Error>?>(nil)
    runner.requestLoadState(Data("garbage".utf8)) { result in got.withLock { $0 = result } }
    runner.serviceLoadRequests()

    let result = try #require(got.withLock { $0 })
    #expect(throws: (any Error).self) { try result.get() }
    #expect(try core.saveState() == before)
}

/// A card write still waiting must reach disk before the load: the load
/// re-installs the cards from disk, and a stale file would undo the save.
@Test func aPendingCardWriteReachesDiskBeforeTheLoad() throws {
    let (runner, core, cards) = try makeMachine()
    let image = Data(repeating: 0x5A, count: MemoryCardStore.bytes)
    runner.pendingCards[0] = image
    runner.requestLoadState(try core.saveState()) { _ in }
    runner.serviceLoadRequests()
    #expect(cards.load(slot: 0) == image)
    #expect(runner.pendingCards.isEmpty)
}

@Test func aLoadPendingWhenTheRunnerStopsIsAnsweredWithAFailure() throws {
    let (runner, core, _) = try makeMachine()
    let got = Mutex<Result<Data, Error>?>(nil)
    runner.requestLoadState(try core.saveState()) { result in got.withLock { $0 = result } }
    runner.stop()
    let result = try #require(got.withLock { $0 })
    #expect(throws: SaveRequestError.runnerStopped) { try result.get() }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run the focused command with `NAME` = `aLoadAnswersWithTheMachineItReplaced`.
Expected: build FAILS, `value of type 'EmulatorRunner' has no member 'requestLoadState'`.

- [ ] **Step 3: Make the save request a queue**

In `EmulatorRunner.swift` replace the `pendingSave` property (keep its doc comment, amended) with:

```swift
    /// Every caller waiting on a snapshot. A queue, not one slot: a slot save
    /// pressed while a timed auto-save waits would otherwise displace it,
    /// and the displaced caller (perhaps an exit) would never be answered.
    /// All of them are answered from ONE snapshot.
    private var pendingSaves: [@Sendable (Result<ResumeSnapshot, Error>) -> Void] = []
```

Replace `requestSaveState`'s `pendingSave = completion` with `pendingSaves.append(completion)`.

Replace `takePendingSave`, `serviceSaveRequest` and `failPendingSave` with:

```swift
    private func takePendingSaves() -> [@Sendable (Result<ResumeSnapshot, Error>) -> Void] {
        pacing.lock()
        defer { pacing.unlock() }
        let completions = pendingSaves
        pendingSaves = []
        return completions
    }

    /// The state and its thumbnail, taken in one go so the picture is exactly
    /// the saved frame. Called from `runLoop` only (this thread owns the
    /// core), and `internal` so a test can drive it.
    func serviceSaveRequest() {
        let completions = takePendingSaves()
        guard !completions.isEmpty else { return }

        let result = Result {
            let state = try core.saveState()
            var vram = [UInt16](repeating: 0, count: Self.vramCount)
            vram.withUnsafeMutableBufferPointer { core.copyVRAM(into: $0.baseAddress!) }
            let display = core.display()
            let thumbnail = vram.withUnsafeBufferPointer { ResumeThumbnail.png(vram: $0, display: display) }
            return ResumeSnapshot(state: state, thumbnail: thumbnail)
        }
        for completion in completions { completion(result) }
    }

    /// A request still waiting once the thread is gone is ANSWERED, never
    /// dropped: whoever asked is waiting on it, perhaps to finish an exit.
    private func failPendingRequests() {
        for completion in takePendingSaves() { completion(.failure(SaveRequestError.runnerStopped)) }
        for load in takePendingLoads() { load.completion(.failure(SaveRequestError.runnerStopped)) }
    }
```

Rename the three `failPendingSave()` calls (two in `stop()`, one in `runLoop`'s `defer`) to `failPendingRequests()`.

- [ ] **Step 4: Add the load request**

Beside `pendingSaves`:

```swift
    private struct PendingLoad {
        let state: Data
        let completion: @Sendable (Result<Data, Error>) -> Void
    }
    private var pendingLoads: [PendingLoad] = []
```

After `requestSaveState`:

```swift
    /// Asks the emulator thread to load `state` between frames, paused or
    /// not. The completion gets the machine the load replaced (the undo
    /// state), or the core's refusal, in which case nothing changed: the
    /// load is all-or-nothing. It runs ON THE EMULATOR THREAD (or with
    /// `.runnerStopped` on whichever thread calls `stop()`).
    func requestLoadState(_ state: Data,
                          _ completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        pacing.lock()
        pendingLoads.append(PendingLoad(state: state, completion: completion))
        // The loop may be parked on the pause or the audio high-water mark.
        pacing.signal()
        pacing.unlock()
    }

    private func takePendingLoads() -> [PendingLoad] {
        pacing.lock()
        defer { pacing.unlock() }
        let loads = pendingLoads
        pendingLoads = []
        return loads
    }

    /// Called from `runLoop` only (this thread owns the core), and `internal`
    /// so a test can drive it.
    ///
    /// The cards are flushed FIRST, then re-installed from disk after the
    /// load: a state carries no card bytes, but it does carry the card's
    /// flag byte, so without the re-install the game would trust a directory
    /// it read before the state was saved. Re-installing marks the card
    /// freshly inserted, as a launch-time resume does, and the flush is what
    /// makes the file on disk the newest card.
    func serviceLoadRequests() {
        for load in takePendingLoads() {
            flushMemoryCards()
            load.completion(Result {
                let replaced = try core.saveState()
                try core.loadState(load.state)
                reinstallMemoryCards()
                padStatusWord.store(core.padStatus().packed, ordering: .releasing)
                // The GPU texture still holds the replaced machine's picture.
                requestResync()
                return replaced
            })
        }
    }

    private func reinstallMemoryCards() {
        guard let cards else { return }
        for slot in 0..<MemoryCardStore.slots {
            guard let image = cards.load(slot: slot) else { continue }
            try? core.loadMemcard(image, slot: slot)
        }
    }
```

In `runLoop`, after `serviceSaveRequest()` and before `serviceResetRequest()`:

```swift
            // After the save, so a save asked for before a load captures the
            // machine the player was looking at.
            serviceLoadRequests()
```

- [ ] **Step 5: Run the runner tests**

Run the focused command with every test in `EmulatorRunnerSaveStateTests.swift` and `EmulatorRunnerLoadStateTests.swift`.
Expected: all 9 PASS. If `aRefusedLoadLeavesTheMachineAsItWas` fails on byte equality, print both lengths first: a state save that is not deterministic for an idle machine is a finding to report, not to weaken the test over.

- [ ] **Step 6: Commit**

```bash
cd /Users/david/Documents/develop/substation
git add ps1-macos/Sources/PS1/EmulatorRunner.swift ps1-macos/Tests/PS1Tests/EmulatorRunnerSaveStateTests.swift \
  ps1-macos/Tests/PS1Tests/EmulatorRunnerLoadStateTests.swift
git commit -m "feat(macos): runner loads a state between frames and queues save requests"
```

---

### Task 3: Auto-save setting, clock and Settings row

**Files:**
- Create: `ps1-macos/Sources/PS1/AutoSaveSetting.swift`, `ps1-macos/Sources/PS1/AutoSaveClock.swift`
- Create: `ps1-macos/Tests/PS1Tests/AutoSaveTests.swift`
- Modify: `ps1-macos/Sources/PS1/Settings/SettingsCopy.swift` (after `saveOnExit` ~57; `allInfo` ~294)
- Modify: `ps1-macos/Sources/PS1/Settings/GeneralSettingsPane.swift` (~82)
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift` (property beside `saveStateOnExit` ~115)

**Interfaces:**
- Produces:
  - `struct AutoSaveSetting { static let defaultsKey = "autoSaveInterval"; static let choices = [0, 1, 5, 10]; static let defaultMinutes = 5; init(key: String = defaultsKey, defaults: UserDefaults = .standard); private(set) var minutes: Int; var interval: TimeInterval?; mutating func set(_ minutes: Int); static func title(_ minutes: Int) -> String }`
  - `struct AutoSaveClock { mutating func update(counting: Bool, at: TimeInterval); func elapsed(at: TimeInterval) -> TimeInterval; mutating func restart(at: TimeInterval) }`
  - `EmulatorViewModel.autoSaveMinutes: Int { get set }`, `SettingsCopy.autoSave: SettingInfo`

- [ ] **Step 1: Write the failing tests**

`AutoSaveTests.swift`:

```swift
import Testing
import Foundation
@testable import PS1

private func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "autosave-\(UUID().uuidString)")!
}

@Test func autoSaveDefaultsToFiveMinutesWhenNeverSet() {
    let setting = AutoSaveSetting(key: "k", defaults: makeDefaults())
    #expect(setting.minutes == 5)
    #expect(setting.interval == 300)
}

@Test func autoSaveOffPersistsAndHasNoInterval() {
    let defaults = makeDefaults()
    var setting = AutoSaveSetting(key: "k", defaults: defaults)
    setting.set(0)
    let reread = AutoSaveSetting(key: "k", defaults: defaults)
    #expect(reread.minutes == 0)
    #expect(reread.interval == nil)
}

@Test func anUnknownStoredIntervalReadsAsTheDefault() {
    let defaults = makeDefaults()
    defaults.set(7, forKey: "k")
    #expect(AutoSaveSetting(key: "k", defaults: defaults).minutes == 5)
    var setting = AutoSaveSetting(key: "k", defaults: defaults)
    setting.set(3)
    #expect(setting.minutes == 5)
}

@Test func autoSaveTitles() {
    #expect(AutoSaveSetting.title(0) == "Off")
    #expect(AutoSaveSetting.title(1) == "Every Minute")
    #expect(AutoSaveSetting.title(10) == "Every 10 Minutes")
}

private let t0: TimeInterval = 1_000_000

@Test func theClockCountsOnlyActivePlay() {
    var clock = AutoSaveClock()
    clock.update(counting: true, at: t0)
    clock.update(counting: false, at: t0 + 100)   // paused
    #expect(clock.elapsed(at: t0 + 1_000) == 100)
    clock.update(counting: true, at: t0 + 1_000)
    #expect(clock.elapsed(at: t0 + 1_050) == 150)
}

@Test func restartingZeroesTheCountAndKeepsCounting() {
    var clock = AutoSaveClock()
    clock.update(counting: true, at: t0)
    clock.restart(at: t0 + 300)
    #expect(clock.elapsed(at: t0 + 300) == 0)
    #expect(clock.elapsed(at: t0 + 360) == 60)
}

@Test func restartingAStoppedClockLeavesItStopped() {
    var clock = AutoSaveClock()
    clock.update(counting: true, at: t0)
    clock.update(counting: false, at: t0 + 10)
    clock.restart(at: t0 + 20)
    #expect(clock.elapsed(at: t0 + 500) == 0)
}

@Test func repeatingTheCountingStateDoesNotRestartTheStretch() {
    var clock = AutoSaveClock()
    clock.update(counting: true, at: t0)
    clock.update(counting: true, at: t0 + 30)
    #expect(clock.elapsed(at: t0 + 50) == 50)
}
```

- [ ] **Step 2: Run them to verify they fail**

Focused command, `NAME` = `autoSaveDefaultsToFiveMinutesWhenNeverSet`. Expected: build FAILS, `cannot find 'AutoSaveSetting' in scope`.

- [ ] **Step 3: Write `AutoSaveSetting.swift`**

```swift
import Foundation

/// How often a running game writes its resume state on its own, in minutes
/// of active play; 0 is Off. Independent of save-on-exit: either can be off
/// while the other is on.
///
/// Defaults to 5, so absence is probed with `object(forKey:)`:
/// `integer(forKey:)` reads a missing key as 0, which here means Off. A
/// stored value outside `choices` reads as the default rather than being
/// clamped to a neighbour nobody chose.
struct AutoSaveSetting {
    static let defaultsKey = "autoSaveInterval"
    static let choices = [0, 1, 5, 10]
    static let defaultMinutes = 5

    private let defaults: UserDefaults
    private let key: String
    private(set) var minutes: Int

    init(key: String = AutoSaveSetting.defaultsKey, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = key
        let stored = (defaults.object(forKey: key) as? NSNumber)?.intValue
        minutes = stored.flatMap { Self.choices.contains($0) ? $0 : nil } ?? Self.defaultMinutes
    }

    /// Seconds of active play between saves, or nil when Off.
    var interval: TimeInterval? {
        minutes == 0 ? nil : TimeInterval(minutes * 60)
    }

    mutating func set(_ value: Int) {
        guard Self.choices.contains(value) else { return }
        minutes = value
        defaults.set(value, forKey: key)
    }

    static func title(_ minutes: Int) -> String {
        switch minutes {
        case 0: "Off"
        case 1: "Every Minute"
        default: "Every \(minutes) Minutes"
        }
    }
}
```

- [ ] **Step 4: Write `AutoSaveClock.swift`**

```swift
import Foundation

/// Active play since the last timed auto-save, on `PlayClock`'s terms: the
/// caller passes "running, unpaused and the app in front" as `counting`, and
/// times are `systemUptime`, so a game paused, left behind other windows or
/// asleep under a closed lid does not keep rewriting its resume state.
///
/// A value type fed timestamps, like `PlayClock`, so the rule is reachable
/// from a test with synthetic times and no window.
struct AutoSaveClock {
    private var banked: TimeInterval = 0
    /// The uptime the current counting stretch began at, or nil while stopped.
    private var since: TimeInterval?

    mutating func update(counting: Bool, at now: TimeInterval) {
        switch (since, counting) {
        case (nil, true):
            since = now
        case (let start?, false):
            banked += max(0, now - start)
            since = nil
        default:
            break
        }
    }

    func elapsed(at now: TimeInterval) -> TimeInterval {
        banked + (since.map { max(0, now - $0) } ?? 0)
    }

    /// After a save, a load or a new game: count again from zero.
    mutating func restart(at now: TimeInterval) {
        banked = 0
        if since != nil { since = now }
    }
}
```

- [ ] **Step 5: Run the tests**

Focused command over the eight tests in `AutoSaveTests.swift`. Expected: all PASS.

- [ ] **Step 6: The Settings copy and row**

In `SettingsCopy.swift`, after `saveOnExit`:

```swift
    static let autoSave = SettingInfo(
        title: "Save Progress Automatically",
        details: "Saves your exact place every few minutes of play, into the same resume state that leaving a game writes. The state it replaces is kept as Previous Resume, so a save made at a bad moment can be undone from Machine, Load State. Time spent paused or in another app does not count. Your numbered save slots are never touched."
    )
```

Add `autoSave` to `allInfo` right after `saveOnExit`.

In `EmulatorViewModel.swift`, beside `private var resumeOnExit = ResumeOnExitSetting()`:

```swift
    private var autoSave: AutoSaveSetting
```

and beside `saveStateOnExit`:

```swift
    var autoSaveMinutes: Int {
        get { autoSave.minutes }
        set { autoSave.set(newValue) }
    }
```

Rename the existing `public init()` to `init(saveStates: SaveStateStore, autoSave: AutoSaveSetting)` (internal: a `public` initializer cannot take the module's internal types), make its first two lines `self.saveStates = saveStates` and `self.autoSave = autoSave`, and add the app's entry point back beside it:

```swift
    public convenience init() {
        self.init(saveStates: SaveStateStore(), autoSave: AutoSaveSetting())
    }
```

Change the declaration `let saveStates = SaveStateStore()` to `let saveStates: SaveStateStore`. (Tests inject both so they never write the real Application Support or the real defaults: the hosted test app shares the app's.)

In `GeneralSettingsPane.swift`, rename the section `"Leaving a Game"` to `"Saving Your Place"` and add after the save-on-exit toggle:

```swift
                SettingRow(SettingsCopy.autoSave) {
                    Picker(SettingsCopy.autoSave.title, selection: $model.autoSaveMinutes) {
                        ForEach(AutoSaveSetting.choices, id: \.self) { Text(AutoSaveSetting.title($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
```

- [ ] **Step 7: Run the copy tests and build**

Focused command over every test in `SettingsCopyTests.swift` plus `autoSaveDefaultsToFiveMinutesWhenNeverSet`. Expected: all PASS (proves the app target compiles with the new init).

- [ ] **Step 8: Commit**

```bash
cd /Users/david/Documents/develop/substation
git add ps1-macos/Sources/PS1/AutoSaveSetting.swift ps1-macos/Sources/PS1/AutoSaveClock.swift \
  ps1-macos/Tests/PS1Tests/AutoSaveTests.swift ps1-macos/Sources/PS1/Settings/SettingsCopy.swift \
  ps1-macos/Sources/PS1/Settings/GeneralSettingsPane.swift ps1-macos/Sources/PS1/EmulatorViewModel.swift
git commit -m "feat(macos): auto-save interval setting and its active-play clock"
```

---

### Task 4: View model: slot save, load, undo, timed auto-save

**Files:**
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift`
- Modify: `ps1-macos/Sources/PS1/GameHUD.swift` (~190, `struct PadNotice` → `GameNotice`), `ps1-macos/Sources/PS1/GameWindowView.swift` (~57)
- Create: `ps1-macos/Tests/PS1Tests/SaveStateViewModelTests.swift`

**Interfaces:**
- Consumes: Task 1 `SaveStateStore`, `StateSource`; Task 2 `requestLoadState`, `serviceLoadRequests`, `serviceSaveRequest`; Task 3 `AutoSaveSetting`, `AutoSaveClock`; existing `ResumeOffer.disc(forSerial:in:)`, `Ps1Core.peekStateSerial`, `resumeMessage`.
- Produces (all `@MainActor` on `EmulatorViewModel`):
  - `var canUseStates: Bool`
  - `private(set) var undoState: Data?`
  - `private(set) var stateRevision: Int` (bumped after every state write; menus read it to refresh)
  - `func stateInfo(_ source: StateSource) -> SaveStateStore.Info?` (nil without a running game)
  - `func saveState(toSlot n: Int)`
  - `func loadState(_ source: StateSource)`
  - `func undoLoadState()`
  - `func autoSaveIfDue(at now: TimeInterval)` (internal; the 1 s tick calls it)
  - `private(set) var notice: String?` and `private func showNotice(_:)` (renamed from `padNotice`/`showPadNotice`)
  - `load(disc:resume:freshBoot:resumeRefused:)`: new optional last parameter `resumeRefused: ((Error) -> Void)? = nil`
  - `#if DEBUG func ejectNowForTesting()`

- [ ] **Step 1: Rename the notice**

```bash
cd /Users/david/Documents/develop/substation/ps1-macos
sed -i '' 's/padNoticeTask/noticeTask/g; s/showPadNotice/showNotice/g; s/padNotice/notice/g' Sources/PS1/EmulatorViewModel.swift
sed -i '' 's/PadNotice(text: model.padNotice)/GameNotice(text: model.notice)/' Sources/PS1/GameWindowView.swift
sed -i '' 's/struct PadNotice: View/struct GameNotice: View/' Sources/PS1/GameHUD.swift
grep -rn "PadNotice\|padNotice" Sources Tests   # must print nothing
```

Update the doc comment above `notice` to say it carries the Analog notice and the save-state notices.

- [ ] **Step 2: Write the failing tests**

`SaveStateViewModelTests.swift`:

```swift
import Testing
import Foundation
@testable import PS1

private func makeStore() -> SaveStateStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vm-states-\(UUID().uuidString)")
    return SaveStateStore(resumeDirectory: root.appendingPathComponent("resume"),
                          slotsDirectory: root.appendingPathComponent("slots"))
}

private func makeAutoSave(_ minutes: Int) -> AutoSaveSetting {
    var setting = AutoSaveSetting(key: "k", defaults: UserDefaults(suiteName: "vm-\(UUID().uuidString)")!)
    setting.set(minutes)
    return setting
}

private func makeMachine() throws -> (runner: EmulatorRunner, core: Ps1Core) {
    let core = try Ps1Core()
    try core.loadBIOS(Data(repeating: 0, count: 524288))
    let runner = EmulatorRunner(core: core, ring: AudioRing(capacity: EmulatorRunner.ringCapacity),
                                cards: MemoryCardStore(directory: FileManager.default.temporaryDirectory
                                    .appendingPathComponent("vm-cards-\(UUID().uuidString)")))
    return (runner, core)
}

/// Completions hop to the main actor; give them a bounded chance to land.
@MainActor private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor @Test func savingToASlotWritesThatSlotAndNothingElse() async throws {
    let store = makeStore()
    let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
    let (runner, _) = try makeMachine()
    model.installRunnerForTesting(runner, resumeKey: "k")
    defer { model.ejectNowForTesting() }

    model.saveState(toSlot: 2)
    runner.serviceSaveRequest()
    #expect(await eventually { store.info(.slot(2), key: "k") != nil })
    #expect(store.info(.resume, key: "k") == nil)
    #expect(model.stateInfo(.slot(2)) != nil)
}

@MainActor @Test func loadingASlotKeepsTheReplacedMachineForUndo() async throws {
    let store = makeStore()
    let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
    let (runner, core) = try makeMachine()
    try store.saveSlot(1, state: try core.saveState(), thumbnail: nil, key: "k")
    model.installRunnerForTesting(runner, resumeKey: "k")
    defer { model.ejectNowForTesting() }

    #expect(model.undoState == nil)
    model.loadState(.slot(1))
    runner.serviceLoadRequests()
    #expect(await eventually { model.undoState != nil })
    #expect(model.notice == "Loaded Slot 1")

    model.undoLoadState()
    runner.serviceLoadRequests()
    #expect(await eventually { model.notice == "Load undone" })
    #expect(model.undoState != nil)   // a second Undo returns to the loaded state
}

@MainActor @Test func ejectingDropsTheUndoState() async throws {
    let store = makeStore()
    let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
    let (runner, core) = try makeMachine()
    try store.saveSlot(1, state: try core.saveState(), thumbnail: nil, key: "k")
    model.installRunnerForTesting(runner, resumeKey: "k")
    model.loadState(.slot(1))
    runner.serviceLoadRequests()
    #expect(await eventually { model.undoState != nil })
    model.ejectNowForTesting()
    #expect(model.undoState == nil)
}

@MainActor @Test func aLoadAnsweredAfterTeardownIsIgnored() async throws {
    let store = makeStore()
    let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
    let (runner, core) = try makeMachine()
    try store.saveSlot(1, state: try core.saveState(), thumbnail: nil, key: "k")
    model.installRunnerForTesting(runner, resumeKey: "k")
    model.loadState(.slot(1))
    model.ejectNowForTesting()        // stop() answers the load with .runnerStopped
    runner.serviceLoadRequests()      // nothing left to service
    try? await Task.sleep(for: .milliseconds(100))
    #expect(model.undoState == nil)
    #expect(model.notice == nil)
}

@MainActor @Test func aDamagedSlotShowsWhyAndChangesNothing() async throws {
    let store = makeStore()
    let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
    let (runner, _) = try makeMachine()
    try store.saveSlot(4, state: Data([1, 2, 3]), thumbnail: nil, key: "k")
    model.installRunnerForTesting(runner, resumeKey: "k")
    defer { model.ejectNowForTesting() }

    model.loadState(.slot(4))
    #expect(model.notice == "The saved state is damaged.")
    #expect(model.undoState == nil)
}

@MainActor @Test func aTimedAutoSaveWritesTheResumeOnceDue() async throws {
    let store = makeStore()
    let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(5))
    let (runner, _) = try makeMachine()
    model.installRunnerForTesting(runner, resumeKey: "k")
    defer { model.ejectNowForTesting() }
    model.simulateAppActiveForTesting(true)
    model.isPaused = false            // starts the active-play count
    let now = ProcessInfo.processInfo.systemUptime

    model.autoSaveIfDue(at: now + 60)      // one minute in: not due
    runner.serviceSaveRequest()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(store.info(.resume, key: "k") == nil)

    model.autoSaveIfDue(at: now + 301)
    runner.serviceSaveRequest()
    #expect(await eventually { store.info(.resume, key: "k") != nil })
    #expect(store.saved(key: "k").map(\.source) == [.resume])
}

@MainActor @Test func autoSaveOffNeverWrites() async throws {
    let store = makeStore()
    let model = EmulatorViewModel(saveStates: store, autoSave: makeAutoSave(0))
    let (runner, _) = try makeMachine()
    model.installRunnerForTesting(runner, resumeKey: "k")
    defer { model.ejectNowForTesting() }
    model.simulateAppActiveForTesting(true)
    model.isPaused = false
    model.autoSaveIfDue(at: ProcessInfo.processInfo.systemUptime + 100_000)
    runner.serviceSaveRequest()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(store.info(.resume, key: "k") == nil)
}
```

- [ ] **Step 3: Run them to verify they fail**

Focused command, `NAME` = `savingToASlotWritesThatSlotAndNothingElse`. Expected: build FAILS with `value of type 'EmulatorViewModel' has no member 'saveState'` (the injecting init already exists from Task 3).

- [ ] **Step 4: State, gates and the tick**

Add beside `playClock`:

```swift
    private var autoSaveClock = AutoSaveClock()
    private var autoSaveTask: Task<Void, Never>?
    private var autoSaveInFlight = false
    /// The machine as it was before the last in-game load, one deep. Undo
    /// loads it, which keeps the machine IT replaced, so a second Undo
    /// returns to the loaded state. Cleared with the game and on a disc swap.
    private(set) var undoState: Data?
    /// Bumped after every state write so the menus re-read their timestamps.
    private(set) var stateRevision = 0
```

Add near `isDialogShown`:

```swift
    /// A game is running and nothing is in the way of a save or a load.
    var canUseStates: Bool {
        stage == .playing && runner != nil && !isDialogShown && !finishingExit && resumeFailure == nil
    }

    func stateInfo(_ source: StateSource) -> SaveStateStore.Info? {
        _ = stateRevision      // read it so SwiftUI re-runs this on a change
        guard let resumeKey else { return nil }
        return saveStates.info(source, key: resumeKey)
    }
```

Replace `updatePlayClock()` with:

```swift
    private func updatePlayClock() {
        let now = ProcessInfo.processInfo.systemUptime
        let banked = playClock.update(running: runner != nil, paused: isPaused,
                                      active: appActive, at: now)
        if let key = resumeKey { playStats.add(banked, to: key) }
        autoSaveClock.update(counting: runner != nil && !isPaused && appActive, at: now)
    }
```

Find the `appActive = false` / `appActive = true` assignments in the resign/become-active observers (~201, ~212) and confirm each is followed by `updatePlayClock()`; if one is not, add it, since the auto-save clock now depends on it as well. Make `simulateAppActiveForTesting` call `updatePlayClock()` after setting `appActive`.

- [ ] **Step 5: Slot save and timed auto-save**

```swift
    func saveState(toSlot n: Int) {
        guard canUseStates, let runner, let key = resumeKey else { return }
        let store = saveStates
        runner.requestSaveState { [weak self] result in
            // Off the main actor: compression of a multi-megabyte state would
            // otherwise stall the UI for the length of it.
            Task.detached {
                var message = "Could not save to Slot \(n)"
                if case .success(let snap) = result {
                    do {
                        try store.saveSlot(n, state: snap.state, thumbnail: snap.thumbnail, key: key)
                        message = "Saved to Slot \(n)"
                    } catch {
                        NSLog("Substation: slot \(n) failed to write: \(error)")
                    }
                }
                await MainActor.run {
                    self?.stateRevision += 1
                    self?.showNotice(message)
                }
            }
        }
    }

    /// The 1 s tick's body. Silent: a status line about work the player did
    /// not ask for is noise, and a failure is logged.
    func autoSaveIfDue(at now: TimeInterval) {
        guard let interval = autoSave.interval,
              autoSaveClock.elapsed(at: now) >= interval,
              canUseStates, !autoSaveInFlight,
              let runner, let key = resumeKey else { return }
        autoSaveInFlight = true
        autoSaveClock.restart(at: now)
        let store = saveStates
        runner.requestSaveState { [weak self] result in
            Task.detached {
                switch result {
                case .success(let snap):
                    do { try store.saveResume(state: snap.state, thumbnail: snap.thumbnail, key: key) }
                    catch { NSLog("Substation: auto-save failed to write: \(error)") }
                case .failure(let error):
                    NSLog("Substation: auto-save failed: \(error)")
                }
                await MainActor.run {
                    self?.autoSaveInFlight = false
                    self?.stateRevision += 1
                }
            }
        }
    }

    private func startAutoSave() {
        autoSaveTask?.cancel()
        autoSaveClock = AutoSaveClock()
        autoSaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.autoSaveIfDue(at: ProcessInfo.processInfo.systemUptime)
            }
        }
    }
```

In `load(disc:)`, call `startAutoSave()` right after `startWatchingPad()` (before the `updatePlayClock()` further down, so the fresh clock is the one that starts counting).`confirmExit` needs no change beyond Task 1's: the game is being left, so no menu is showing its timestamps.

- [ ] **Step 6: Load and undo**

```swift
    func loadState(_ source: StateSource) {
        guard canUseStates, let key = resumeKey else { return }
        let damaged = Self.resumeMessage(Ps1Error.stateCorrupt)
        guard let data = saveStates.load(source, key: key) else { return showNotice(damaged) }
        let serial: String?
        do { serial = try Ps1Core.peekStateSerial(data) } catch { return showNotice(Self.resumeMessage(error)) }

        // Saved on another disc of this game: rebuild on that disc, as a
        // launch-time resume does. No undo across that rebuild.
        let inTray = currentDiscIndex.map { currentDiscs[$0] }
        if let serial, serial != inTray?.serial {
            guard let disc = ResumeOffer.disc(forSerial: serial, in: currentDiscs) else {
                return showNotice(Self.resumeMessage(Ps1Error.stateDisc))
            }
            load(disc: disc.url, resume: data, freshBoot: nil) { [weak self] error in
                self?.showNotice(Self.resumeMessage(error))
            }
            return
        }
        request(load: data, done: "Loaded \(source.title)")
    }

    func undoLoadState() {
        guard canUseStates, let undoState else { return }
        request(load: undoState, done: "Load undone")
    }

    private func request(load data: Data, done: String) {
        guard let runner else { return }
        runner.requestLoadState(data) { [weak self] result in
            Task { @MainActor in
                // Answered after an eject or another game: not this game's.
                guard let self, self.runner === runner else { return }
                switch result {
                case .success(let replaced):
                    self.undoState = replaced
                    self.autoSaveClock.restart(at: ProcessInfo.processInfo.systemUptime)
                    self.showNotice(done)
                case .failure(let error):
                    self.showNotice(Self.resumeMessage(error))
                }
            }
        }
    }
```

`resumeMessage`'s `default` branch already reads "The saved state is damaged." for `stateCorrupt`.

Change `load(disc:resume:freshBoot:)`'s signature to `func load(disc url: URL, resume: Data? = nil, freshBoot: URL? = nil, resumeRefused: ((Error) -> Void)? = nil)`, and in its `catch` for `core.loadState(resume)`:

```swift
                } catch {
                    // In a running game the refusal is a notice: the launch
                    // alert's Cancel would eject the game still playing.
                    if let resumeRefused { resumeRefused(error); return }
                    resumeFailure = ResumeFailure(message: Self.resumeMessage(error),
                                                  freshBoot: freshBoot ?? url)
                    return
                }
```

- [ ] **Step 7: Teardown, swap, test hook**

In `teardownRunningMachine()`, beside `padTask = nil`:

```swift
        autoSaveTask?.cancel()
        autoSaveTask = nil
        undoState = nil
```

In `changeDisc(to:)`, after `runner.requestDiscSwap(...)`: `undoState = nil` (the undo machine had the other disc in its tray).

In the `#if DEBUG` block beside `installRunnerForTesting`:

```swift
    func ejectNowForTesting() { ejectNow() }
```

- [ ] **Step 8: Run the view-model tests**

Focused command over the seven tests in `SaveStateViewModelTests.swift` plus every test in `EmulatorViewModelStageTests.swift`. Expected: all PASS.

- [ ] **Step 9: Commit**

```bash
cd /Users/david/Documents/develop/substation
git add ps1-macos/Sources/PS1/EmulatorViewModel.swift ps1-macos/Sources/PS1/GameHUD.swift \
  ps1-macos/Sources/PS1/GameWindowView.swift ps1-macos/Tests/PS1Tests/SaveStateViewModelTests.swift
git commit -m "feat(macos): save slots, undo load and timed auto-save in a running game"
```

---

### Task 5: Machine menu

**Files:**
- Modify: `ps1-macos/Sources/PS1App/MachineCommands.swift` (after the Change Disc `Menu` and its `Divider`)
- Modify: `ps1-macos/Sources/PS1/SaveStateStore.swift` (menu label helper on `StateSource`)
- Modify: `ps1-macos/Tests/PS1Tests/SaveStateStoreTests.swift`

**Interfaces:**
- Consumes: Task 4 `canUseStates`, `stateInfo(_:)`, `saveState(toSlot:)`, `loadState(_:)`, `undoLoadState()`, `undoState`.
- Produces: `StateSource.menuTitle(_ info: SaveStateStore.Info?) -> String`, `StateSource.functionKey(_ n: Int) -> KeyEquivalent` (in the commands file, private).

- [ ] **Step 1: Write the failing test**

Append to `SaveStateStoreTests.swift`:

```swift
@Test func menuTitlesNameTheTimeOrSayEmpty() {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let info = SaveStateStore.Info(savedAt: date, thumbnail: nil)
    let when = date.formatted(date: .abbreviated, time: .shortened)
    #expect(StateSource.slot(2).menuTitle(info) == "Slot 2 · \(when)")
    #expect(StateSource.slot(3).menuTitle(nil) == "Slot 3 · Empty")
    #expect(StateSource.previous.menuTitle(nil) == "Previous Resume · Empty")
}
```

- [ ] **Step 2: Verify it fails**

Focused command, `NAME` = `menuTitlesNameTheTimeOrSayEmpty`. Expected: build FAILS, `has no member 'menuTitle'`.

- [ ] **Step 3: Implement the helper**

In `StateSource` (`SaveStateStore.swift`):

```swift
    /// The menu item: the time it was saved, in the launch sheet's format,
    /// so a player picking a slot to overwrite can tell them apart.
    func menuTitle(_ info: StateFile.Info?) -> String {
        "\(title) · \(info.map { $0.savedAt.formatted(date: .abbreviated, time: .shortened) } ?? "Empty")"
    }
```

- [ ] **Step 4: The menu**

In `MachineCommands.swift`, after the `Divider()` that follows the Change Disc menu:

```swift
            // F1-F6 load and ⇧F1-F6 save: ⌘1-8 are Internal Resolution.
            Menu("Save State") {
                ForEach(Array(StateSource.slots), id: \.self) { n in
                    Button(StateSource.slot(n).menuTitle(model.stateInfo(.slot(n)))) {
                        model.saveState(toSlot: n)
                    }
                    .keyboardShortcut(Self.functionKey(n), modifiers: .shift)
                }
            }
            .disabled(!model.canUseStates)

            Menu("Load State") {
                ForEach([StateSource.resume, .previous], id: \.self) { source in
                    let info = model.stateInfo(source)
                    Button(source.menuTitle(info)) { model.loadState(source) }
                        .disabled(info == nil)
                }
                Divider()
                ForEach(Array(StateSource.slots), id: \.self) { n in
                    let info = model.stateInfo(.slot(n))
                    Button(StateSource.slot(n).menuTitle(info)) { model.loadState(.slot(n)) }
                        .keyboardShortcut(Self.functionKey(n), modifiers: [])
                        .disabled(info == nil)
                }
            }
            .disabled(!model.canUseStates)

            Button("Undo Load State") { model.undoLoadState() }
                .disabled(!model.canUseStates || model.undoState == nil)

            Divider()
```

and as a member of `MachineCommands`:

```swift
    /// F1 is U+F704 (`NSF1FunctionKey`); AppKit takes the private-use
    /// character as that function key's key equivalent.
    private static func functionKey(_ n: Int) -> KeyEquivalent {
        KeyEquivalent(Character(UnicodeScalar(UInt32(NSF1FunctionKey + n - 1))!))
    }
```

Add `import AppKit` at the top of `MachineCommands.swift` if `NSF1FunctionKey` is not already in scope.

- [ ] **Step 5: Run the test and build the app**

Focused command, `NAME` = `menuTitlesNameTheTimeOrSayEmpty`. Expected: PASS. Then from the repo root: `zig build macos`. Expected: `zig-out/Substation.app` builds with no error.

- [ ] **Step 6: Check the shortcuts by hand**

`pkill -x Substation; open zig-out/Substation.app`, start any game, open the Machine menu: Save State shows `⇧F1`…`⇧F6`, Load State shows `F1`…`F6`. Press ⇧F2 (with `fn` on a laptop keyboard): the "Saved to Slot 2" notice appears. Press F2: "Loaded Slot 2". Machine ▸ Undo Load State: "Load undone". If the menu shows no F-key glyphs, stop and report: the shortcut encoding is the one unverified assumption in this task.

- [ ] **Step 7: Commit**

```bash
cd /Users/david/Documents/develop/substation
git add ps1-macos/Sources/PS1App/MachineCommands.swift ps1-macos/Sources/PS1/SaveStateStore.swift \
  ps1-macos/Tests/PS1Tests/SaveStateStoreTests.swift
git commit -m "feat(macos): Save State, Load State and Undo Load State in the Machine menu"
```

---

### Task 6: Launch sheet lists the other states

**Files:**
- Modify: `ps1-macos/Sources/PS1/ResumeOffer.swift`
- Modify: `ps1-macos/Sources/PS1/ResumePromptSheet.swift`
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift` (`chooseResume` ~714)
- Modify: `ps1-macos/Tests/PS1Tests/ResumeOfferTests.swift`, `ps1-macos/Tests/PS1Tests/EmulatorViewModelStageTests.swift` (`makeOffer` ~216)

**Interfaces:**
- Consumes: Task 1 `SaveStateStore.saved(key:)`, `load(_:key:)`, `SavedState`.
- Produces:
  - `enum ResumeChoice { case resume, load(StateSource), freshBoot, deleteAndBoot, cancel }`
  - `ResumeOffer.info: SaveStateStore.Info?` (nil when there is no resume, only others)
  - `ResumeOffer.others: [SavedState]` (previous and filled slots, menu order)
  - `static func ResumeOffer.disc(for state: Data, launching: GameEntry, siblings: [GameEntry]) -> GameEntry?`

- [ ] **Step 1: Write the failing tests**

Append to `ResumeOfferTests.swift`:

```swift
@Test func onlyAPreviousStillProducesAnOffer() throws {
    // A crash between a resume write's two renames leaves just the previous.
    let d1 = disc("/g/Game.cue", "SLUS-9")
    let store = makeStore()
    try store.file(.previous, key: "SLUS-9").write(state: try biosOnlyState(), thumbnail: nil)
    let offer = try #require(ResumeOffer.make(launching: d1, siblings: [d1], store: store))
    #expect(offer.info == nil)
    #expect(offer.others.map(\.source) == [.previous])
}

@Test func onlySlotsStillProduceAnOffer() throws {
    let d1 = disc("/g/Game.cue", "SLUS-9")
    let store = makeStore()
    try store.saveSlot(3, state: try biosOnlyState(), thumbnail: nil, key: "SLUS-9")
    let offer = try #require(ResumeOffer.make(launching: d1, siblings: [d1], store: store))
    #expect(offer.others.map(\.source) == [.slot(3)])
}

@Test func theOthersExcludeTheResumeItself() throws {
    let d1 = disc("/g/Game.cue", "SLUS-9")
    let store = makeStore()
    try store.saveResume(state: try biosOnlyState(), thumbnail: nil, key: "SLUS-9")
    try store.saveResume(state: try biosOnlyState(), thumbnail: nil, key: "SLUS-9")
    try store.saveSlot(1, state: try biosOnlyState(), thumbnail: nil, key: "SLUS-9")
    let offer = try #require(ResumeOffer.make(launching: d1, siblings: [d1], store: store))
    #expect(offer.info != nil)
    #expect(offer.others.map(\.source) == [.previous, .slot(1)])
}
```

In `EmulatorViewModelStageTests.swift`'s `makeOffer`, add `others: []` after `info:`.

- [ ] **Step 2: Verify they fail**

Focused command, `NAME` = `onlyAPreviousStillProducesAnOffer`. Expected: build FAILS, `has no member 'others'`.

- [ ] **Step 3: The offer**

In `ResumeOffer.swift`:

```swift
enum ResumeChoice {
    case resume, load(StateSource), freshBoot, deleteAndBoot, cancel
}
```

Change `let info: SaveStateStore.Info` to `let info: SaveStateStore.Info?` with the comment `/// The resume state's, or nil when the game has only a previous resume or slots.` and add `let others: [SavedState]` with `/// Previous resume and filled slots, menu order; the sheet's Other States list.`

Replace `make` with:

```swift
    /// Nil when the game has no state at all. A state that cannot be decoded
    /// still produces an offer (so Delete & Boot is reachable) resuming on
    /// the launching disc, where the core's refusal then explains the damage.
    static func make(launching: GameEntry, siblings: [GameEntry],
                     store: SaveStateStore) -> ResumeOffer? {
        let first = siblings.first ?? launching
        let key = SaveStateStore.key(for: first)
        let saved = store.saved(key: key)
        guard !saved.isEmpty else { return nil }
        let info = saved.first { $0.source == .resume }?.info
        let resumeDisc = store.load(.resume, key: key)
            .map { disc(for: $0, launching: launching, siblings: siblings) } ?? launching
        return ResumeOffer(title: DiscGrouping.baseTitle(first.title), key: key,
                           launching: launching, resumeDisc: resumeDisc, info: info,
                           others: saved.filter { $0.source != .resume })
    }

    /// The disc a state should resume on: the one whose serial it names.
    /// `peekStateSerial` THROWS for an unreadable header and returns nil for
    /// a readable one whose disc names no serial: two different answers, so
    /// they are not collapsed with `try?`. An unreadable state resumes on
    /// the launching disc, whose load then explains the damage.
    static func disc(for state: Data, launching: GameEntry, siblings: [GameEntry]) -> GameEntry? {
        do {
            return disc(forSerial: try Ps1Core.peekStateSerial(state), in: siblings)
        } catch {
            return launching
        }
    }
```

(`resumeDisc` for an offer with no resume is `launching`; Resume is disabled on `info == nil` in the sheet, not on `resumeDisc`.)

- [ ] **Step 4: `chooseResume`**

Replace the `.resume` case with a shared path:

```swift
        case .resume:
            resume(from: .resume, offer: offer)
        case .load(let source):
            resume(from: source, offer: offer)
```

and add:

```swift
    private func resume(from source: StateSource, offer: ResumeOffer) {
        guard let state = saveStates.load(source, key: offer.key) else {
            resumeFailure = ResumeFailure(message: Self.resumeMessage(Ps1Error.stateCorrupt),
                                          freshBoot: offer.launching.url)
            return
        }
        let siblings = Self.siblingDiscs(of: offer.launching.url, entries: library.entries)
        guard let disc = ResumeOffer.disc(for: state, launching: offer.launching, siblings: siblings) else {
            resumeFailure = ResumeFailure(message: Self.resumeMessage(Ps1Error.stateDisc),
                                          freshBoot: offer.launching.url)
            return
        }
        load(disc: disc.url, resume: state, freshBoot: offer.launching.url)
    }
```

(This replaces the old `.resume` body, which used `offer.resumeDisc`; for `.resume` the result is the same disc, since `make` computed `resumeDisc` with the same `disc(for:launching:siblings:)`.)

- [ ] **Step 5: The sheet**

In `ResumePromptSheet.swift`:
- the date line becomes `Text(offer.info.map { "Saved \($0.savedAt.formatted(date: .abbreviated, time: .shortened))" } ?? "No resume state. Choose a saved state below or start fresh.")`
- the thumbnail reads `offer.info?.thumbnail ?? offer.others.first?.info.thumbnail`
- Resume's `.disabled(offer.resumeDisc == nil)` becomes `.disabled(offer.info == nil || offer.resumeDisc == nil)`
- before `Spacer()` in the button row:

```swift
                if !offer.others.isEmpty {
                    Menu("Other States") {
                        ForEach(offer.others, id: \.source) { saved in
                            Button(saved.source.menuTitle(saved.info)) { choose(.load(saved.source)) }
                        }
                    }
                    .fixedSize()
                }
```

`SavedState` needs `Hashable` on `source` only, which `StateSource` already is: `id: \.source` compiles as is.

- [ ] **Step 6: Run the tests**

Focused command over every test in `ResumeOfferTests.swift` and `EmulatorViewModelStageTests.swift`. Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
cd /Users/david/Documents/develop/substation
git add ps1-macos/Sources/PS1/ResumeOffer.swift ps1-macos/Sources/PS1/ResumePromptSheet.swift \
  ps1-macos/Sources/PS1/EmulatorViewModel.swift ps1-macos/Tests/PS1Tests/ResumeOfferTests.swift \
  ps1-macos/Tests/PS1Tests/EmulatorViewModelStageTests.swift
git commit -m "feat(macos): the launch sheet offers the previous resume and every save slot"
```

---

### Task 7: Full suite, measurement, skill notes

**Files:**
- Modify: `.claude/skills/ps1-macos-app/SKILL.md` ("Resume states" section)

- [ ] **Step 1: Full suite**

```bash
cd /Users/david/Documents/develop/substation && pkill -x Substation; ps1-macos/test.sh 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`, with 31 more tests than before this plan (SaveStateStore +8, runner +5, auto-save +8, view model +7, offer +3). Any failure: fix in the task that owns the file and commit there.

- [ ] **Step 2: Measure the auto-save hitch**

`zig build macos`, set Settings ▸ General ▸ Save Progress Automatically to Every Minute, run Silent Hill (`games/silent-hill-usa/`) then Crash Bandicoot Warped at 1x for three minutes each with headphones on. Expected: no audible click or dropout at the 1, 2 and 3 minute marks, and `~/Library/Application Support/Substation/ResumeStates/` holds `<key>.state` and `<key>.prev.state` with modification times a minute apart. A dropout is a finding: report it with the game and the minute, do not tune around it here. Set the setting back to Every 5 Minutes afterwards.

- [ ] **Step 3: The cross-disc load, by hand**

Open Final Fantasy VII (its discs are in per-disc folders under `games/`), let disc 1 reach its opening, ⇧F1. Machine ▸ Change Disc ▸ disc 2, then F1. Expected: the game rebuilds on disc 1 and plays from the slot, and Undo Load State is disabled (no undo across a rebuild). Then save into slot 2 while on disc 2 and load it from disc 1: same, on disc 2. A load that shows the "Could not resume" alert instead of a notice is a failure of `resumeRefused`.

- [ ] **Step 4: Skill notes**

In `.claude/skills/ps1-macos-app/SKILL.md`, replace the **Store.** paragraph of "Resume states" with:

```markdown
**Store.** `SaveStateStore` over `StateFile` (one LZFSE state + PNG; the
core never compresses). Resume: `ResumeStates/<key>.state` + `.png`, written
on exit and by the timed auto-save, never by the player. Every resume write
stages `<key>.new.*`, renames the current one to `<key>.prev.*` and the staged
one into place, so a crash leaves the old resume or a previous, never nothing;
a write with no current resume does NOT rotate, or it would destroy the only
survivor. Slots: `SaveStates/<key>/slot1...6.*`, written only from Machine ▸
Save State (⇧F1-F6). Delete & Boot removes resume and previous, never a slot.
Every write goes through the store's one queue: an exit save and an auto-save
can land together from two threads. `<key>` is the first disc's serial, else
the path hash (the `CoverStore` rule). An empty `Data` is refused
(`.stateBadMagic`) before the C call.

**Timed auto-save** (`AutoSaveSetting`, key `autoSaveInterval`, Off/1/5/10
min, default 5, probed with `object(forKey:)`; independent of save-on-exit)
counts ACTIVE play through `AutoSaveClock`, fed from `updatePlayClock`, and
writes off the main actor. It is silent; failures are logged.

**Loading in a game** goes through `EmulatorRunner.requestLoadState`: flush
the cards, keep the replaced machine (Undo Load State, one deep, swaps on
each Undo, cleared on eject and disc swap), load, re-install both cards from
disk (the state restores the card's FLAG byte, so without this a game trusts
a directory read before the save), resync. A state from another disc of the
game rebuilds through `load(disc:resume:...)` with `resumeRefused`, so a
refusal is a notice and never the launch alert whose Cancel ejects. The
runner's save request is a QUEUE answered from one snapshot: one slot let a
second request displace an exit's, which then waited out its 3 s fallback.
```

- [ ] **Step 5: Commit**

```bash
cd /Users/david/Documents/develop/substation
git add .claude/skills/ps1-macos-app/SKILL.md
git commit -m "docs(skills): save slots, previous resume and timed auto-save"
```

Do not push.
