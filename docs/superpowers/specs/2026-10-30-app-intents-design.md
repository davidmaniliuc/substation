# App Intents: games in Spotlight, Shortcuts and Siri

## Intent

Every game in the library becomes an `AppEntity`, and three `AppIntent`s act
on it. One implementation, inside the app target, then reaches Spotlight
(type "Crash", get the game with its cover and a Play action), Shortcuts and
Siri ("Resume Spyro in Substation"). No extension target, no App Group, no
sandbox change: App Intents run in the app's own process.

Source: the "App Intents: the best fit" section of the Substation macOS
integration ideas doc (2026-10-10). The owner asked to start on it.

## Goals

- **A game entity** per library GAME (a merged multi-disc group, not a
  disc), with its title, cover and play history on display.
- **Three intents**:
  - *Play Game* (a game): opens it exactly as Finder opening its first
    disc does, `EmulatorViewModel.open(_:)`. A running game is asked about
    through `ExitGate`; a game with a resume state gets the floating
    `LaunchPanel` offer. It is the entity's `OpenIntent`, so it is what
    Spotlight runs when the game is picked.
  - *Resume Game* (an optional game; omitted means the last one played):
    straight into the resume state with no sheet, as the Continue capsule
    does (`continuePlaying`), but entered from outside, so a running game is
    asked about first and the launch uses the outside-launch routing (the
    panel, the game-window mode). A game with no usable resume falls back to
    Play Game's offer, as the capsule does.
  - *Open Library*: brings the app forward with its library window. A game
    playing in the library window is left alone (the window is the game).
- **Spotlight** finds games by title or serial with their cover, through
  `IndexedEntity`, reindexed after every library scan.
- **App Shortcuts** with Siri phrases, each naming the app:
  "Play \(game) in Substation", "Resume \(game) in Substation",
  "Resume Substation" / "Continue playing in Substation", "Open the
  Substation library". Parameters refreshed after every scan
  (`updateAppShortcutParameters`).

## Decisions (made by Claude, from the doc's open questions)

1. **Play Game while another game runs ASKS, as Finder does.** It is the
   same call (`open(_:)`), so the exit sheet, the save-before-leaving choice
   and `.busy` while a sheet is up all come for free and cannot drift.
   Refusing would make Spotlight a worse door than Finder. When the
   several-windows design (2026-10-29) ships, New Window mode stops asking
   because `open` itself changes; nothing here needs to follow it.
2. **A disc with no serial IS an entity**, keyed on its path hash. The id is
   `SaveStateStore.key(for: group.first)` over the MERGED grouping
   (`LibraryCollection.statsKeys`' rule), the key resume states and play
   stats already use, so the entity, its history and its resume state can
   never disagree. A renamed serial-less rip gets a new id, exactly as its
   resume state does today.
3. **No settings intents in this version** (resolution, speed, PGXP). A
   setting set from Shortcuts before a game launches is a second way to
   change a setting with no visible control; revisit when someone asks.

## Behaviour details

- **The library must be scanned before an entity resolves.** On a cold
  launch from Spotlight or Siri the scan is still running; the query awaits
  the scan in flight (a new `GameLibrary` wait, bounded at 10 s) rather than
  answering from an empty list.
- **Not set up yet** (onboarding unfinished, no games folder, no BIOS): every
  intent fails with a dialog naming the problem ("Choose a games folder in
  Substation first"), and the app comes forward on onboarding.
- **A game no longer in the library** (Shortcuts holds an id from an old
  scan): "That game is no longer in your library."
- **Resume Game with nothing ever played**: "You haven't played anything
  yet."
- **The entity's display**: title (the group's title); subtitle the same
  line the tile shows (`LibraryFormat.tileSubtitle`: disc count or last
  played); image the stored cover file when there is one (`CoverStore`),
  else the app icon.
- **String search** matches as the library's search box does
  (`LibrarySearch.filter`: every word against title, disc titles, serials).
  **Suggested entities** are the played games, newest first, then the rest
  by title.
- **Intents reach the model through `AppDependencyManager`**, registered in
  `AppDelegate` before launch finishes. The model stays the delegate's.
- Every intent runs on the main actor and `openAppWhenRun` (there is no
  background work to do: a game needs the window).

## Non-goals

- Control Center or menu-bar controls, widgets, Quick Look (extension work
  in the doc's later sections).
- CoreSpotlight `CSSearchableItem`s of our own: `IndexedEntity` is the
  index.
- Settings intents (decision 3).
- Per-disc entities: a multi-disc game is one entity; Change Disc stays in
  the game.

## Anti-goals

- **An intent that skips the exit gate** and drops a running game without
  its save prompt.
- An intent launch that leaves the app with no visible window (the
  `LaunchPanel` / `giveWayToGameWindow` routing the Finder path already
  gets right must be the one intents use).
- An entity id that disagrees with the resume-state key, so "Resume X"
  finds no state that the library's Continue would.

## Verification

- Swift tests for the pure parts: entity id and suggestions order, string
  query, Resume Game's target choice (given game / last played / none), the
  not-set-up and missing-game errors, and that Play Game and Resume Game go
  through `requestExit` while a game runs (ScriptedSession).
- `zig build macos`, then by hand: the game in Spotlight with its cover,
  each App Shortcut in the Shortcuts app, Play from Spotlight during a game
  (exit sheet), Resume from a cold launch.
