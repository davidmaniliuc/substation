# Several games open at once, one playing

## Intent

With Settings ▸ General ▸ Open Games In set to **New Window**, opening a
game from the library opens a new window every time, and any game already
open stays open in its own window. This builds on the existing New Window
mode, which still holds one game. Only one game ever runs. The game window
in front plays, and every other game sits paused, silent and deaf to input.
This is "several games parked side by side", not "several games running at
once".

The `ps1-macos-app` skill records that running several games was weighed
and declined: the shared memory cards, input, audio pacing, the exit gate
and the Machine menu were all single-game. With only one game running at a
time, input, audio and the menu reduce to "follow the front game", and the
memory cards are handled by a hand-over (below). That skill paragraph must
be rewritten when this ships.

## Goals

- In New Window mode, each game opens in a window of its own. Opening a
  game never closes or replaces another one.
- **Exactly one game runs.** When a game window becomes the key window, its
  game resumes and the previously running game pauses.
- **A game the player paused stays paused.** Bringing a game forward
  restores the pause state it had when it went to the background, exactly
  as the pause menu hands back the pause from before it opened. A background
  pause is a separate reason to pause and never overwrites the player's.
- Keyboard, controller, rumble, the Machine menu, Video menu actions on the
  running game (screenshot, save states, swap disc, reset, eject), the HUD
  and the badges all act on the front game.
- Closing a game's window ejects that game only, through its own exit sheet
  ("save before leaving?").
- **Quit asks about each open game in turn**: one exit sheet per game, each
  on its own window, brought forward as it asks. Cancel on any sheet cancels
  the quit, and games already answered stay ejected. *(Their exit choices are
  final: the saves have been written.)*
- **The memory cards stay coherent** across every switch (below).

## Non-goals

- Two games producing frames or sound at the same time.
- Changing Library Window mode. It keeps exactly one game, played in the
  library's own window.
- A limit on how many games can be open. Each open game keeps its whole
  machine in memory, plus up to the Rewind Memory setting (128 to 512 MB)
  when rewind is on. The cost is stated in the setting's copy
  (`SettingsCopy.swift`), not enforced.
- A window or tab switcher of our own. The Window menu and Mission Control
  already list the windows.

## Anti-goals (would make it a failure even if it works)

- **A save lost across a switch.** Game B overwriting a save Game A wrote,
  because B was holding an old copy of the card, is the one outcome that
  must never happen.
- Sound from a background game, or input reaching a game that is not in
  front.
- A paused game resuming by itself because another game's window closed.
- Regressing anything the single-game paths already pin: the window traps in
  the `ps1-macos-app` skill (principal role, `close()` not `dismissWindow`,
  no hidden toolbar on a window without one, the fullscreen aspect lock),
  the exit gate, the play clock.

## The memory cards: the hand-over

All games share one pair of `.mcd` files, and each session holds its own
copy of the cards in its machine. The session already has both halves of
the fix in `ps1-session/src/run_loop.zig`: `flushMemoryCards` (take what the
game has written and write it out now, ignoring the one-second debounce) and
`reinstallMemoryCards` (re-read both files and mark the cards freshly
inserted, which is what a resume and a state load already do).

On every switch from game A to game B:

1. Pause A (the background pause).
2. Ask A's session to flush its cards, and wait for the answer.
3. Ask B's session to re-install its cards from disk, and wait for the answer.
4. Hand B back the pause state it had before it went to the background.

This is the hardware equivalent of pulling the card out of one console and
inserting it into the other. Both steps need a new request in the session's
C ABI (`ps1_session_request_flush_cards`, `ps1_session_request_reinstall_cards`
or one combined call; the builder's choice), answered exactly once under the
contract in `ps1_session.h`. Both must be served while paused, above the
paused early-out, where `serviceMemoryCards` already runs.

**A switch while a game is writing to its card waits for the write to
settle.** A PS1 save is a burst of about ten block writes spread over
frames. Pausing in the middle and handing the card to another game would
leave half a save in the file. While A's saving badge is up
(`savingToMemoryCard`), the switch is deferred: B's window comes forward at
once but B stays paused until A's burst settles, then the hand-over runs.
*(My call: the alternative, refusing the switch, reads as a broken window.)*

## What runs when the library (or Settings) is in front

The game that last ran **keeps running** while the library window, Settings
or About is key, as New Window mode does today. Only another GAME window
coming forward pauses it. *(My call: the user asked for "the window in front
plays", and the library is not a game.)*

## Opening the same game twice

Opening a disc that is already open in a window brings that window forward
instead of starting a second copy. Two machines of one game would share a
resume-state key and a play-stats record. *(My call.)* A disc of the same
multi-disc game that is not the one in the tray counts as the same game.
Bring that game's window forward and do not swap discs; the player swaps
from inside it.

## The shape of the change (the parts decided here)

- **Split the view model.** `EmulatorViewModel` (about 2,700 lines) holds
  the library, the settings and one game together. The per-game state (the
  session, the host view, HUD and surface state, pause, notices, fps, the
  resume key, undo state, rewind, the disc and its swap, its exit prompt,
  its play clock and auto-save clock) moves into a per-game object. The app
  model keeps the library, settings, BIOS, covers, stats, the stores and a
  list of open games, and names the running one. Global settings are pushed
  to every open session, as today's `pushSettings` pushes to one.
- **One window per game.** The single-instance `Window("Game", id:)` scene
  becomes a data-driven `WindowGroup(for:)` keyed by the game's identity.
  The window-level statics (`GameWindow.current`, the key monitor's
  `GameWindow.owns`) become per-window, keyed the same way.
- **Library Window mode** opens its one game in the library window as
  today. Games already open in their own windows (from before the mode
  changed) stay open and take part in the same "one runs" rule.
- **The Machine and Video menus** act on the front game, using SwiftUI's
  focused values or the key window's game, so a menu never acts on a game
  that is not visible.

## Left to the builder

- Whether the request is one combined hand-over call or two, and the
  per-game object's name and exact boundary, as long as every per-game
  piece above moves.
- How the existing Swift tests (16 files reference `EmulatorViewModel`) are
  re-pointed. The `ScriptedSession` seam stays the way tests drive a game.
- Whether the `LaunchPanel` path (a disc opened from Finder or Spotlight)
  needs anything beyond opening a new game window per launch.

## Risks to retire first

- **`WindowGroup(for:)` against the window traps.** Every rule in the
  skill's "A game can open in a window of its own" paragraph was learnt on
  a single `Window` scene: the principal role, close-by-`close()`, SwiftUI
  reopening the same `NSWindow`, fullscreen. Spike a two-window
  `WindowGroup(for:)` with the hidden title bar and check fullscreen enter
  and exit, the traffic lights and close, before the view-model split.
- **One CoreAudio output per session.** Each open session keeps its own
  output unit. Check that a paused session's unit costs nothing audible and
  that several coexist; if not, stop the paused session's output and
  restart it on resume.

## Verification

- `zig build test` for the session's new requests (answered once, served
  while paused, stopped-session answer).
- `ps1-macos/test.sh` for the switch rules as value types: the background
  pause never overwrites the player's, the hand-over order, the deferred
  switch while saving, quit walking every game, the same disc opening an
  existing window.
- By hand, in the app: two games open, save in A, switch to B, save in B,
  switch back to A, open A's card manager. Both saves must be there.
