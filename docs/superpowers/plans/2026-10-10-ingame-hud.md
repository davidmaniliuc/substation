# In-game HUD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the app's in-game HUD with the designed one: title strip, the new bar with a speed tab, the Save States panel, Screenshot, one badge stack with icons, and a controller-navigable pause menu.

**Architecture:** Every rule (which surface is open, what pauses, what the arrows do, which tile a key lands on) lives in a value type on or beside `EmulatorViewModel`, unit-tested without a window; the SwiftUI views only render that state and forward input. The views are ported from `ps1-macos/HudPrototype/HudPrototype.swift`, whose LOOK is the reference and whose fake data and structure are not.

**Tech Stack:** Swift 6, SwiftUI (macOS 26 Liquid Glass), AppKit, Metal, IOKit power sources, swift-testing, `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-10-10-ingame-hud-design.md`

## Global Constraints

- Commits directly on master, one per task, **title line only**, no body, no trailer, no push.
- `pkill -x Substation` before any `xcodebuild test`.
- Filtered test run: `xcodebuild -project ps1-macos/PS1.xcodeproj -scheme PS1 -configuration Debug -destination "platform=macOS,arch=$(uname -m)" SYMROOT=.build/xcode test -only-testing:PS1Tests/<SuiteName>` from the repo root. New tests go in `@Suite struct`s so the filter can name them.
- Full suite: `ps1-macos/test.sh` (~3.5 min), run once at the end of a task that touches the model, not after every step.
- App build: `zig build macos` → `zig-out/Substation.app`.
- New `.swift` files need no project edit (synchronized groups).
- Match the codebase's comment style: a doc comment says WHY, never narrates.
- UI is verified by screenshot (`screencapture -l <windowid>`, window raised first), not by reasoning.
- No em or en dashes in user-visible copy.

## Review Focus

1. **A surface opened while the player had already paused.** Closing it must leave the game paused. Pinned in Task 2.
2. **Home pressed while the Save States panel is open from the pause menu.** Closes the panel, leaves the menu. Pinned in Task 6.
3. **A pad button held as the menu opens.** It must be released to the core, not stuck down until the menu closes. Pinned in Task 6.
4. **Eject or disc swap with a surface open.** Every surface closes, and the next game does not start paused. Pinned in Task 2.
5. **Resume tile with no resume state.** Not selectable by mouse or keys. Pinned in Task 4.

---

### Task 1: Notices carry an icon; auto-save posts one

**Files:**
- Create: `ps1-macos/Sources/PS1/Notice.swift`
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift` (the `notice` property ~58, `showNotice` ~1601, every caller, `autoSaveIfDue` ~1321, `changeDisc` ~1093)
- Modify: `ps1-macos/Sources/PS1/GameHUD.swift` (`GameNotice` takes a `Notice?`)
- Test: `ps1-macos/Tests/PS1Tests/NoticeTests.swift`

**Interfaces:**
- Produces: `struct Notice: Equatable { let icon: String; let text: String; var reveal: URL? }`, `enum NoticeIcon` constants, `EmulatorViewModel.notice: Notice?`, `showNotice(_ icon: String, _ text: String, reveal: URL? = nil)`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import PS1

@MainActor
@Suite struct NoticeTests {
    @Test func theAnalogNoticeCarriesTheControllerIcon() {
        let model = EmulatorViewModel()
        model.simulatePadStatusForTesting(PadStatus(packed: 1))
        #expect(model.notice == Notice(icon: NoticeIcon.analog, text: "Analog on"))
    }
}
```
(Check `PadStatus(packed:)`'s analog bit in `PadState.swift` and use the value that reads as analog.)

- [ ] **Step 2: Run it: FAIL** (`Notice` undefined).
- [ ] **Step 3: Implement.** `Notice.swift`:

```swift
import Foundation

/// A status shown for a moment in the badge stack: an icon and a line. A
/// notice with `reveal` is the one badge that takes a click, which shows that
/// file in Finder.
struct Notice: Equatable {
    let icon: String
    let text: String
    var reveal: URL? = nil
}

/// One symbol per kind of notice, so the same event always looks the same.
enum NoticeIcon {
    static let analog = "gamecontroller.fill"
    static let saved = "square.and.arrow.down.fill"
    static let loaded = "clock.arrow.circlepath"
    static let undone = "arrow.uturn.backward"
    static let failure = "exclamationmark.triangle.fill"
    static let disc = "circle.circle"
    static let screenshot = "camera.fill"
    static let autoSaved = "clock.badge.checkmark.fill"
}
```
Model: `private(set) var notice: Notice?`; `showNotice(_ icon:_ text:reveal:)` with a 2 s lifetime. Callers: Analog → `.analog`; "Saved to Slot n" → `.saved`, its failure → `.failure`; loads → `.loaded`; "Load undone" → `.undone`; every `resumeMessage` refusal → `.failure`. `changeDisc` posts `.disc`, "Disc \(n) inserted" (n = index + 1). `autoSaveIfDue`'s success posts `.autoSaved`, "Auto-saved" (only when `self.runner === runner`); failures stay logged. Update `autoSaveIfDue`'s doc comment (no longer silent). `GameNotice(notice:)` renders `Label(notice.text, systemImage: notice.icon)`.
- [ ] **Step 4: Add the auto-save and failure tests** (a refused `loadState` on a game with no state reads `.failure`; use `installRunnerForTesting` and an empty store directory as `SaveStateViewModelTests` does) and run the suite filter: PASS.
- [ ] **Step 5: Commit** `feat(macos): notices carry an icon, and a timed auto-save says so`

### Task 2: HUD surfaces: what is open, what pauses, what holds the HUD

**Files:**
- Create: `ps1-macos/Sources/PS1/HudSurfaces.swift`
- Modify: `EmulatorViewModel.swift` (`showHUDThenHide`, `hideHUDNow`, `teardownRunningMachine`, `changeDisc`, `requestExit`)
- Test: `ps1-macos/Tests/PS1Tests/HudSurfacesTests.swift`

**Interfaces:**
- Produces:

```swift
enum HudSurface: Hashable { case speedTab, saveStates, pauseMenu }
/// Where the Save States panel was opened from: it decides the sheet's default.
enum SaveStatesOrigin: Equatable { case bar, menuSave, menuLoad }

struct HudSurfaces {
    private(set) var open: Set<HudSurface> = []
    private var pausedBefore = false
    var holdsHUD: Bool { !open.isEmpty }
    /// Returns the pause state to apply, or nil to leave it.
    mutating func set(_ s: HudSurface, open isOpen: Bool, paused: Bool) -> Bool?
    mutating func closeAll() -> Bool?
}
```
Model: `func setSurface(_ s: HudSurface, open: Bool)`, `func isOpen(_ s: HudSurface) -> Bool`, `private(set) var saveStatesOrigin: SaveStatesOrigin = .bar`, `func openSaveStates(from: SaveStatesOrigin)`.

- [ ] **Step 1: Failing tests**

```swift
@Suite struct HudSurfacesTests {
    @Test func theMenuPausesARunningGameAndResumesItOnClose() {
        var s = HudSurfaces()
        #expect(s.set(.pauseMenu, open: true, paused: false) == true)
        #expect(s.set(.pauseMenu, open: false, paused: true) == false)
    }
    @Test func aGameThePlayerPausedStaysPaused() {
        var s = HudSurfaces()
        #expect(s.set(.pauseMenu, open: true, paused: true) == true)
        #expect(s.set(.pauseMenu, open: false, paused: true) == true)
    }
    @Test func thePanelOpenedFromTheMenuDoesNotResumeOnItsOwnClose() {
        var s = HudSurfaces()
        _ = s.set(.pauseMenu, open: true, paused: false)
        #expect(s.set(.saveStates, open: true, paused: true) == nil)
        #expect(s.set(.saveStates, open: false, paused: true) == nil)
        #expect(s.set(.pauseMenu, open: false, paused: true) == false)
    }
    @Test func theSpeedTabHoldsTheHUDWithoutPausing() {
        var s = HudSurfaces()
        #expect(s.set(.speedTab, open: true, paused: false) == nil)
        #expect(s.holdsHUD)
    }
    @Test func closeAllRestoresThePauseFromBefore() {
        var s = HudSurfaces()
        _ = s.set(.saveStates, open: true, paused: false)
        #expect(s.closeAll() == false)
        #expect(!s.holdsHUD)
    }
}
```
Plus model tests (`@MainActor`): an open menu keeps `hudVisible` true after `hideHUDNow()`; `ejectNowForTesting()` closes every surface (`!model.isOpen(.pauseMenu)`).
- [ ] **Step 2: Run: FAIL.**
- [ ] **Step 3: Implement.**

```swift
mutating func set(_ s: HudSurface, open isOpen: Bool, paused: Bool) -> Bool? {
    let pausingBefore = pausing
    if isOpen { open.insert(s) } else { open.remove(s) }
    switch (pausingBefore, pausing) {
    case (false, true): pausedBefore = paused; return true
    case (true, false): return pausedBefore
    default: return nil
    }
}
mutating func closeAll() -> Bool? {
    let wasPausing = pausing
    open = []
    return wasPausing ? pausedBefore : nil
}
private var pausing: Bool { open.contains(.saveStates) || open.contains(.pauseMenu) }
```
Model: `setSurface` applies the returned pause through `isPaused`, releases held keys and pad input to the core when a pausing surface opens (`releaseAllKeys()`), then: opening → `hudVisible = true; hideTask?.cancel()`; closing the last → `showHUDThenHide()`. `showHUDThenHide` skips scheduling the hide while `surfaces.holdsHUD`. `hideHUDNow` closes `.speedTab` first, then returns early if `surfaces.holdsHUD`. `teardownRunningMachine`, `changeDisc` and a `.prompted` `requestExit` call `closeAll()` (apply its pause only when a runner remains, and BEFORE `pausedBeforePrompt` is read in `requestExit`).
- [ ] **Step 4: Run the filter + `HudVisibilityTests`: PASS.**
- [ ] **Step 5: Commit** `feat(macos): HUD surfaces hold the HUD up and pause the game while open`

### Task 3: Pause menu navigation

**Files:**
- Create: `ps1-macos/Sources/PS1/PauseMenuNavigation.swift`
- Test: `ps1-macos/Tests/PS1Tests/PauseMenuNavigationTests.swift`

**Interfaces:**
- Produces:

```swift
enum MenuMove: Equatable { case up, down, left, right, confirm, back }
enum PauseMenuPage: Equatable { case root, quickSettings, gameInfo }
enum PauseMenuRow: CaseIterable, Equatable {
    case resume, saveState, loadState, changeDisc, quickSettings, gameInfo, reset, quitGame
}
enum QuickSetting: CaseIterable, Equatable { case speed, resolution, pgxp, analog, volume }
enum PauseMenuAction: Equatable {
    case none, close
    case saveStates(SaveStatesOrigin)
    case reset, quitGame
    case adjust(QuickSetting, Int)
    case insertDisc(Int)
}
struct PauseMenuNavigation {
    private(set) var page: PauseMenuPage = .root
    private(set) var selection = 0
    /// The highlighted disc while Change Disc's flyout is open.
    private(set) var flyout: Int?
    var discCount = 1
    var insertedDisc = 0
    func isDisabled(_ row: PauseMenuRow) -> Bool
    mutating func handle(_ move: MenuMove) -> PauseMenuAction
    /// A hover or click on row `index` of the current page.
    mutating func point(at index: Int)
    mutating func pointFlyout(at index: Int)
}
```

- [ ] **Step 1: Failing tests** (one `@Test` each): down from Resume lands on Save State; down skips Change Disc when `discCount == 1`; confirm on Save State → `.saveStates(.menuSave)`, on Load State → `.saveStates(.menuLoad)`; confirm on Change Disc opens the flyout on the first disc that is not inserted and returns `.none`; flyout confirm on the inserted disc closes the flyout with `.none`, on another → `.insertDisc(i)`; back in the flyout closes it; right on Quick Settings enters the page at row 0; on that page left → `.adjust(.speed, -1)`, right and confirm → `.adjust(.speed, 1)`; back from Quick Settings returns to root with Quick Settings selected; back at root → `.close`; confirm on Resume → `.close`; Game Info: back returns to root on Game Info, up/down do nothing; Reset → `.reset`; Quit Game → `.quitGame`.
- [ ] **Step 2: Run: FAIL.**
- [ ] **Step 3: Implement** to those rules. Root rows are `PauseMenuRow.allCases`; `move(by:)` steps past disabled rows and stops at the ends (no wrap).
- [ ] **Step 4: Run: PASS.**
- [ ] **Step 5: Commit** `feat(macos): pause menu navigation`

### Task 4: Save States panel navigation

**Files:**
- Create: `ps1-macos/Sources/PS1/SaveStatesNavigation.swift`
- Test: `ps1-macos/Tests/PS1Tests/SaveStatesNavigationTests.swift`

**Interfaces:**
- Consumes: `MenuMove`, `SaveStatesOrigin`, `StateSource`.
- Produces:

```swift
enum SlotSheetButton: Equatable { case cancel, overwrite, saveHere, load }
enum SaveStatesAction: Equatable { case none, close, load(StateSource), save(Int) }
struct SaveStatesNavigation {
    /// Tile 0 is Resume, 1...6 the slots.
    private(set) var selection: Int
    /// The open sheet's buttons and which one is highlighted.
    private(set) var sheet: (buttons: [SlotSheetButton], index: Int)?   // make it a small Equatable struct
    let filled: Set<Int>
    let origin: SaveStatesOrigin
    init(filled: Set<Int>, origin: SaveStatesOrigin)
    func isSelectable(_ tile: Int) -> Bool     // Resume only when filled
    static func buttons(tile: Int, filled: Bool) -> [SlotSheetButton]
    mutating func handle(_ move: MenuMove) -> SaveStatesAction
    mutating func point(at tile: Int)
    /// A click on a tile: selects it and opens its sheet.
    mutating func pick(_ tile: Int)
    /// A click on a sheet button.
    mutating func press(_ button: SlotSheetButton) -> SaveStatesAction
}
```
Layout: Resume is column 0; slot n is column `(n - 1) % 3 + 1`, row `(n - 1) / 3`.

- [ ] **Step 1: Failing tests:** initial selection is the first filled tile in order Resume, 1-6 (else 1) for `.bar`/`.menuLoad`, and slot 1 for `.menuSave`; left from slots 1 and 4 lands on Resume when filled, stays otherwise; right from Resume lands on slot 1; down from slot 2 → 5, up from 5 → 2; buttons: Resume `[cancel, load]`, empty `[cancel, saveHere]`, full `[cancel, overwrite, load]`; the sheet opens on `load` unless the origin is `.menuSave` (then `overwrite`/`saveHere`), Resume always `load`; in the sheet confirm on `load` → `.load(.slot(n))` or `.load(.resume)`, on `overwrite`/`saveHere` → `.save(n)`, on `cancel` closes the sheet with `.none`; back in the sheet closes it; back on the grid → `.close`; `pick(0)` with no resume does nothing.
- [ ] **Step 2: Run: FAIL.** **Step 3: Implement.** **Step 4: PASS.**
- [ ] **Step 5: Commit** `feat(macos): Save States panel navigation`

### Task 5: "Playing for": active play this session

**Files:**
- Modify: `ps1-macos/Sources/PS1/PlayClock.swift`, `EmulatorViewModel.swift` (`updatePlayClock`, load, teardown)
- Create: `ps1-macos/Sources/PS1/PlayingFor.swift`
- Test: `ps1-macos/Tests/PS1Tests/PlayClockTests.swift` (append), `PlayingForTests.swift`

**Interfaces:**
- Produces: `PlayClock.elapsed(at: TimeInterval) -> TimeInterval`; `EmulatorViewModel.sessionPlayed(at: TimeInterval) -> TimeInterval`; `enum PlayingFor { static func format(_ seconds: TimeInterval) -> String }`.

- [ ] **Step 1: Failing tests:** `elapsed` is 0 stopped and `now - since` counting; `format(59) == "0 min"`, `format(42*60) == "42 min"`, `format(65*60) == "1 h 05 min"`; a model test: `installRunnerForTesting` + `simulateAppActiveForTesting(true)` then `sessionPlayed(at:)` grows, and `ejectNowForTesting()` returns it to 0.
- [ ] **Step 2: FAIL. Step 3: Implement** (`sessionBanked` added in `updatePlayClock` beside `playStats.add`, zeroed where `resumeKey` is set on load and after teardown; a disc swap keeps it). **Step 4: PASS.**
- [ ] **Step 5: Commit** `feat(macos): session play time for the title strip`

### Task 6: Input reaches the open surface, Home opens the menu

**Files:**
- Create: `ps1-macos/Sources/PS1/PadEdges.swift`
- Modify: `EmulatorViewModel.swift` (`keyDown`, `keyUp`, the key monitor's window gate, `applyPadInput`, `bind`'s Home handler, `toggleAnalog`)
- Test: `ps1-macos/Tests/PS1Tests/HudInputTests.swift`

**Interfaces:**
- Consumes: Tasks 2-4.
- Produces: `struct PadEdges { mutating func moves(for snapshot: InputMap) -> [MenuMove] }` (D-pad and left stick past 0.5 as edges; ✕ confirm; ○ back); model `menu: PauseMenuNavigation`, `saveStatesNav: SaveStatesNavigation?`, `func surfaceMove(_ m: MenuMove)`, `func homePressed()`, `func perform(_ a: PauseMenuAction)`, `func perform(_ a: SaveStatesAction)`, `func pressAnalogFromMenu()`.

- [ ] **Step 1: Failing tests:** Esc key-down while playing opens the menu; with the menu open the down-arrow key moves `menu.selection` and `inputMaskForTesting == 0xFFFF`; a pad snapshot with D-pad down held across two reports moves once; pressing ✕ on Resume closes the menu and unpauses; `homePressed()` opens the menu, again closes it; with the panel open from the menu, `homePressed()` closes the panel and the menu stays; a button held when the menu opens is released (`inputMaskForTesting == 0xFFFF` immediately after); Tab is ignored while the menu is open.
- [ ] **Step 2: FAIL.**
- [ ] **Step 3: Implement.** Key map: arrows → up/down/left/right, Return/keypad Enter/Space → confirm, Esc → back. While a pausing surface is open the key monitor routes every key-down to `surfaceMove` (returning handled) from ANY window but the Settings window, before the `gameInOwnWindow` gate; key-ups still release. `applyPadInput` while a pausing surface is open feeds `PadEdges` and sends a released `InputMap()` to the core; the rewind pad hold is ignored. Home calls `homePressed()`. `toggleAnalog` keeps its guard for the keyboard and menu bar; `pressAnalogFromMenu()` queues `runner?.pressAnalogButton()` without the pause guard (the pad acts on it when the game resumes). `perform(.saveStates(o))` opens the panel from `o`; `.insertDisc(i)` → `changeDisc(to: currentDiscs[i])` then closes the menu; `.reset` → close then `reset()`; `.quitGame` → close then `eject()`; `.adjust` applies to `speed` (1...4), `internalScale` (1...8), `pgxpEnabled`, Analog, `volume` (±0.1, clamped 0...1, unmutes).
- [ ] **Step 4: PASS**, then `ps1-macos/test.sh` once: all green.
- [ ] **Step 5: Commit** `feat(macos): the pause menu and Save States take the keyboard and controller; Home opens the menu`

### Task 7: Screenshot

**Files:**
- Create: `ps1-macos/Sources/PS1/Screenshot.swift` (size rule, filename, PNG encode, write)
- Modify: `EmulatorRunner.swift` (a one-deep request slot under a lock: `requestScreenshot(_:)`, `takeScreenshotRequest()`), `MetalDisplayView.swift` (an offscreen pass after the presented one), `EmulatorViewModel.swift` (`takeScreenshot()`)
- Test: `ps1-macos/Tests/PS1Tests/ScreenshotTests.swift`

**Interfaces:**
- Produces: `enum Screenshot { static func size(displayHeight: Int, scale: Int, enabled: Bool) -> (width: Int, height: Int); static func fileName(title: String, at: Date) -> String; static func png(bgra: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) -> Data?; static var folder: URL }`; `EmulatorViewModel.takeScreenshot()`.

- [ ] **Step 1: Failing tests:** `size(displayHeight: 240, scale: 4, enabled: true)` → 1280×960; `(480, 2)` → 1280×960; `(224, 3)` → 896×672; disabled → 640×480; `fileName(title: "Crash: Warped", at: fixed)` → `"Crash Warped 2026-10-10 at 14.03.22.png"` with the fixed date in the current calendar; `png` of a 2×2 red buffer decodes back (via `NSBitmapImageRep`) to 2×2 with red pixels; an offscreen render test following `DisplayRenderTests`' harness that draws a 320×240 display at scale 1 into a 320×240 target and reads a non-black centre.
- [ ] **Step 2: FAIL. Step 3: Implement.** The coordinator, after `cmd.present`, if `runner.takeScreenshotRequest()` returns a completion: makes a `.shared` texture of the size rule in `view.colorPixelFormat`, encodes the same pipeline and textures with `params.scaleX = 1, params.scaleY = 1`, and in `addCompletedHandler` reads it with `getBytes` and calls the completion with `Screenshot.png(...)`. The model's completion hops to the main actor, creates the folder, writes, and posts `Notice(icon: NoticeIcon.screenshot, text: "Screenshot saved", reveal: url)`; a nil PNG or a write error posts the failure notice. **Step 4: PASS.**
- [ ] **Step 5: Commit** `feat(macos): Screenshot saves what is on screen to Pictures/Substation`

### Task 8: The bar, the title strip and the badge stack

**Files:**
- Create: `ps1-macos/Sources/PS1/HudControls.swift` (`HoverStyle`, `IconButton`, `BarShape`, `SpeedTab`/`SpeedTabKey`, `SpeedButton`, `SpeedPick`), `TitleStrip.swift` (+ `FullScreenReader`, `Battery`), `BadgeStack.swift`
- Modify: `GameHUD.swift` (rebuilt), `GameWindowView.swift` (`GameScreen` composition)
- Test: `ps1-macos/Tests/PS1Tests/SpeedPickTests.swift`, `BatteryTests.swift` (format only)

**Interfaces:**
- Consumes: Tasks 1, 2, 5, 7.
- Produces: `struct SpeedPick { static func index(at p: CGPoint, width: CGFloat) -> Int?; static func outcome(pickedIndex: Int?, dragged: Bool, wasOpen: Bool) -> (speed: Int?, open: Bool) }`.

- [ ] **Step 1: Failing tests** for `SpeedPick`: a point in the button itself (y ≥ 0) → nil; just above the separator → index 0 (1×); four slots up → 3 (4×); outside the tab's width → nil; outcome: picked → (i + 1, closed); nothing picked after a drag → closed; nothing picked on a plain click of a closed button → stays open; on an open one → closes.
- [ ] **Step 2: FAIL. Step 3: Implement**, porting from the prototype:
  - `HoverStyle`, `IconButton` (prototype 317-351), `BarShape` (373-414), `SpeedTab`/`SpeedTabKey` (357-371), `SpeedButton` (416-528) with its open state bound to `model.isOpen(.speedTab)` / `setSurface(.speedTab, open:)` and its pick rule through `SpeedPick`.
  - `GameHUD`: the prototype's `VolumeCapsule` + `BarFinal` (534-616, 707-729) driven by the real model: ⏸ toggles `isPaused`; Save States `IconButton("rectangle.stack")` with a `.popover(isPresented:)` bound to `isOpen(.saveStates) && saveStatesOrigin == .bar` (content: a placeholder `Text` until Task 9); Screenshot `camera` → `takeScreenshot()`; divider; `SpeedButton`; Full Screen (symbol from `isFullScreen`); speaker; `ellipsis` → `setSurface(.pauseMenu, open: true)`. The bar is ONE glass effect (the `BarShape` background); the pill keeps its existing behaviour; seat 32 in both capsules with `pillInset + pillPadding == barInset`.
  - `TitleStrip` (prototype 662-705) with the real title, `fps`, `isPaused`, `PlayingFor.format(model.sessionPlayed(at:))` on a 30 s `TimelineView`; leading inset 78 in a window, 20 in fullscreen; fullscreen adds the clock and `Battery.current()` (IOKit; nil without an internal battery).
  - `FullScreenReader`: an `NSViewRepresentable` reporting its window's fullscreen state from the will/did enter/exit notifications filtered on `object === window`, into `@State isFullScreen` in `GameScreen`.
  - `BadgeStack` (prototype 278-315) over the real speed, rewind, card, Paused, and `Notice`; the notice badge is a `Button` revealing `reveal` in Finder when set, and the only hit-testable badge. Top padding 48 extra while fullscreen and the HUD shows.
  - `GameScreen`: picture, `TitleStrip` (fades with `hudVisible`), `GameHUD`, `BadgeStack`; the old `SpeedBadge`/`RewindBadge`/`GameNotice`/`MemoryCardBadge` views are deleted.
- [ ] **Step 4:** Tests PASS; `zig build macos`, launch a game, screenshot: windowed, HUD shown; speed tab open (bar material unchanged versus closed, compare the bar's pixels); volume pill open (speaker at the same x); fullscreen with clock and battery; a notice in the stack. Compare each against the prototype (`ps1-macos/HudPrototype/run.sh`).
- [ ] **Step 5: Commit** `feat(macos): the new HUD bar, title strip and badge stack`

### Task 9: Save States panel

**Files:**
- Create: `ps1-macos/Sources/PS1/SaveStatesPanel.swift` (`SaveStatesPanel`, `SlotTile`, `SlotThumbnail`, `SlotSheet`)
- Modify: `GameHUD.swift` (the popover content), `EmulatorViewModel.swift` (`slotTiles` for the view)

**Interfaces:**
- Consumes: Task 4 navigation, `stateInfo(_:)` (`StateFile.Info.thumbnail`, `.savedAt`), `StateSource.savedAt`.
- Produces: `SaveStatesPanel(model:)`.

- [ ] **Step 1: Implement**, porting prototype 1093-1238: Resume tile + divider + 3×2 slots, titles and `StateSource.savedAt` times (Resume reads "Auto-saved …"); thumbnails loaded from the PNG URL with `.interpolation(.none)`; highlight follows `saveStatesNav.selection`; hover calls `point(at:)`, click `pick(_:)`; the sheet's buttons from `sheet.buttons` with the highlighted one `.borderedProminent`, click → `press(_:)` → `perform(_:)`. Save → `saveState(toSlot:)`, Load → `loadState(_:)`; both close the panel.
- [ ] **Step 2:** In the app: open from the bar, check the glass and the dimmed sheet inside the popover, that it may leave the game window (small window), that it survives the HUD's idle timer, that the game is paused while open, and that arrows/Return/Esc and a controller drive it. Save into slot 4, load it back.
- [ ] **Step 3: Commit** `feat(macos): Save States panel`

### Task 10: Pause menu

**Files:**
- Create: `ps1-macos/Sources/PS1/PauseMenu.swift`, `GameInfo.swift` (rows from the model)
- Modify: `GameWindowView.swift` (`GameScreen` shows the scrim + menu while open; the bar hides), `EmulatorViewModel.swift` (`gameInfo: [GameInfoRow]`, record the chosen BIOS's description at load)
- Test: `ps1-macos/Tests/PS1Tests/GameInfoTests.swift`

**Interfaces:**
- Consumes: Tasks 3, 6, 9.
- Produces: `struct GameInfoRow: Equatable { let icon: String; let label: String; let value: String }`, `EmulatorViewModel.gameInfo`.

- [ ] **Step 1: Failing test** for `gameInfo` with an installed runner and known `currentDiscs`: Serial, Region ("North America"/"Europe"/"Japan"), Disc "2 of 3", Image "CUE/BIN"/"CHD"/"BIN"; PPF and LibCrypt rows only when present.
- [ ] **Step 2: FAIL. Step 3: Implement** `gameInfo` and the menu, porting prototype 776-1090: header (title, "Paused"), rows from `PauseMenuRow.allCases` with dividers after Resume and before Reset, `Game Info ›` added; Quick Settings stepper rows bound to the real values; Game Info page read-only; Change Disc flyout over `currentDiscs`; footer hints; the Save State/Load State rows anchor the same `SaveStatesPanel` popover (`isOpen(.saveStates) && saveStatesOrigin != .bar`). Selection, flyout and page come from `model.menu`; hover → `point(at:)`, click → `point` then `surfaceMove(.confirm)`. The scrim's tap closes the menu.
- [ ] **Step 4:** Tests PASS; in the app: open with `…`, Esc and a controller's Home; walk every row with arrows; change a Quick Setting; open Game Info; swap a disc on FF7; Reset; Quit Game raises the exit sheet. Screenshots against the prototype.
- [ ] **Step 5: Commit** `feat(macos): pause menu`

### Task 11: Docs

**Files:**
- Modify: `.claude/skills/ps1-macos-app/SKILL.md` (HUD layout, the bar's single glass, the surfaces' pause and hold rules, input routing, Home opens the menu, auto-save is no longer silent, Screenshot), `CLAUDE.md` (Swift test count), the HUD handoffs (point at the spec and say built), the memory entry.
- [ ] **Step 1:** Edit; run `ps1-macos/test.sh` for the final count.
- [ ] **Step 2: Commit** `docs: the in-game HUD in the macOS app skill`
