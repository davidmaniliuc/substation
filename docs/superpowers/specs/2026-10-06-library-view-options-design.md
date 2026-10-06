# Library view options: toolbar, cover size, list view, play time

Date: 2026-10-06. Status: approved in conversation, awaiting spec review.

## Intent

The library is a single full-bleed grid of covers with no controls on screen.
The player wants it to feel less bare by adding function, not decoration (two
rounds of purely visual backdrops were rejected). Three things were chosen:

- a cover-size slider, as Finder and Photos have;
- a list view as an alternative to the grid, with name, region, serial, last
  played and total play time;
- somewhere to put those controls: a toolbar.

Explicitly NOT wanted: hover or selection animation on tiles (scale, lift).
Apple's Mac apps mark selection with a ring or highlight only, and the grid
already has Music's ring. The selection ring stays exactly as it is.

Success: both views are usable from the keyboard and the mouse, the chosen
view and size survive a relaunch, and play time reflects actual play rather
than time a game sat loaded.

## 1. Toolbar, library only

- A real window toolbar on the `.library` stage; hidden on `.playing` (the
  game keeps its full-bleed picture and glass HUD) and on `.onboarding`.
- Trailing items: a segmented **Grid | List** picker, and, in grid view only,
  a **cover-size slider** with small and large photo glyphs at its ends.
- Library menu gains a View section mirroring them:
  **as Grid (⌃⌘1)**, **as List (⌃⌘2)**, **Bigger Covers (⌘+)**,
  **Smaller Covers (⌘−)**. ⌘1 to ⌘8 are taken by Video ▸ Internal
  Resolution, hence the ⌃.
- The menu and the toolbar bind to the same view-model properties (the
  Settings-window rule: a second view over the model, never a second store).

**Risk.** The window uses `.windowStyle(.hiddenTitleBar)` and
`WindowConfigurator` manages the traffic lights, the 4:3 lock and the
fullscreen-exit abort fix (`ps1-macos-app` skill). A toolbar appearing and
disappearing with the stage touches the same window. Acceptance includes
fullscreen in and out, in the library and in a game, several times each.

## 2. Grid cover size

- `LibraryLayoutSetting` persists two values: the view mode
  (`LibraryViewMode`, Int-backed, via `PersistedChoice`, default `.grid`) and
  the tile width in points (default 132, today's minimum; clamped to
  100...260 by the type, as `InternalResolution` clamps its scale).
- The grid's `GridItem(.adaptive(minimum: size, maximum: size * 1.36))` keeps
  today's minimum-to-maximum ratio (132:180), so columns still re-flow to
  fill the width. `GridSelection.columns` takes the same `size`, so arrow-key
  stepping follows the new column count.
- Bigger and Smaller step by 20 pt and stop at the bounds.
- The 260 pt ceiling stays inside `CoverStore.maxCoverSize` (540 px wide)
  at 2x; no change to stored covers.

## 3. List view

A SwiftUI `Table` over the same `[GameGroup]` the grid shows:

| Column      | Content                                                   |
| ----------- | --------------------------------------------------------- |
| Name        | 28 pt cover thumbnail, then the group title              |
| Region      | USA / Europe / Japan from `DiscIdentity.region`, else "—" |
| Serial      | first disc's serial, else "—"                            |
| Discs       | disc count                                                |
| Last Played | relative date ("Yesterday", "3 Oct"), else "—"           |
| Play Time   | "12 h 40 min" / "35 min" / "< 1 min", else "—"           |

- Sortable by every column; starts sorted by Name; the sort is session-only.
- Selection is the same `GameGroup.ID` the grid uses, so switching views
  keeps the selected game.
- Double-click and Return play; the context menu is the tile's (Play,
  covers, Show in Finder), extracted so the two views share one definition.
- A thumbnail is drawn as the tile draws its cover (a cut-out case without a
  frame, `CoverShape`), at thumbnail size.

## 4. Play time and last played

**Store.** `PlayStatsStore`: one JSON file,
`Application Support/Substation/PlayStats.json`, mapping a game key to
`{ lastPlayed: Date, seconds: Double }`. The key is
`ResumeStateStore.key(for:)` (first disc's serial, else the path hash), so a
multi-disc game has one record and a renamed rip keeps its history. Writes
are atomic. A missing or unreadable file reads as empty and is left on disk
untouched until the next record is written over it; nothing deletes it on
read.

**Last played** is stamped when a game finishes loading (the same point that
sets `stage = .playing`).

**Play time** counts only while all three hold: a game is running, it is not
paused, and the app is active. The app does NOT pause a game when it goes to
the background, so the third condition is a separate input, fed from the
existing `didResignActive` observer and a new `didBecomeActive` one.

`PlayClock` is a value type that takes those three booleans and a timestamp
on each change, and accrues elapsed time only across intervals where all
three were true. Timestamps are injected, so the rule is testable without a
window, the same reason `FpsCounter` is a value type.

**Saving.** The accrued time is added to the store and the clock reset on
every transition that stops the clock (pause, resign active, eject, disc
load over a running game, quit via `willTerminateNotification`). A crash
loses at most the current uninterrupted stretch. A disc swap (Machine ▸
Change Disc) keeps accruing to the game that was launched.

Every game starts at zero: there is no history to recover.

## 5. Tests

- `PlayClockTests`: pause, background and resume intervals accrue exactly;
  a stop with nothing running accrues nothing; overlapping stops (paused
  AND background) do not double-subtract.
- `PlayStatsStoreTests`: round trip in a temp directory; missing file reads
  empty; corrupt file reads empty and survives until the next write.
- `LibraryLayoutSettingTests`: the size clamp, the step bounds, and both
  values persisting; an absent key gives the defaults.
- Formatting of Play Time and Last Played as pure functions.
- The full Swift suite (`ps1-macos/test.sh`), plus screenshots of both views
  in the running app and the fullscreen round trips from section 1.

## Out of scope

Search, filters, a Continue row, badges on tiles, memory-card management.
Any of them can reuse `PlayStatsStore` and the toolbar later.
