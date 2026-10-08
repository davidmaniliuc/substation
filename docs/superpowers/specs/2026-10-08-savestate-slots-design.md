# Savestate slots, previous resume and timed auto-save

macOS app only (`ps1-macos`). No core, C ABI, golden or browser change.

## Goal

Two kinds of state, never written by the same hand:

- **Resume**: the machine's own bookmark. Written on exit (existing
  `saveStateOnExit`) and by a timed auto-save. The player can load it but
  never save into it.
- **Slots 1-6**: the player's manual saves. Nothing automatic ever writes one.

That separation is the point of the feature: an auto-save can never destroy
a deliberate save, and a manual save can never break resume.

## 1. Storage

**Resume** keeps its path: `Application Support/Substation/ResumeStates/<key>.state`
plus `<key>.png`, `<key>` as today (`ResumeStateStore.key(for:)`, the first
disc of the merged game).

**Previous resume.** Every resume write (exit or timed) rotates:

1. write the new state and thumbnail to temporary files in the same folder;
2. rename the current `<key>.state`/`.png` to `<key>.prev.state`/`.prev.png`,
   replacing any older previous;
3. rename the temporary files into place.

A crash after step 1 leaves the old resume intact; after step 2 leaves no
current resume but a valid previous, which the launch sheet offers. Previous
is exactly one write back: the last timed save, or the last exit when timed
saves are off.

**Slots** live at `Application Support/Substation/SaveStates/<key>/slot<N>.state`
plus `slot<N>.png`, N = 1..6, same key, same LZFSE compression, same atomic
write and thumbnail-first order as the resume store.

**One store type.** `ResumeStateStore`'s file logic (LZFSE, atomic write,
thumbnail, `Info` from the modification date) becomes a single store over a
directory and a file stem, used for resume, previous and slots. No second
copy of the write path.

**Delete & Boot** removes the resume and the previous resume. It never
removes a slot.

## 2. Machine menu

`Machine ▸ Save State` and `Machine ▸ Load State`, beside Reset/Eject:

| Item | Shortcut |
| --- | --- |
| Save State ▸ Slot 1-6 | ⇧F1-⇧F6 |
| Load State ▸ Resume | none |
| Load State ▸ Previous Resume | none |
| Load State ▸ Slot 1-6 | F1-F6 |
| Undo Load State | none |

Each item names its state's time (`Slot 2 · Today 14:32`) or `Empty`; an
empty entry is disabled under Load. ⌘1-8 are taken (Internal Resolution),
which is why the slots use the function keys; on a laptop they need `fn`
unless the system setting makes them standard keys, and the menu remains the
fallback.

Saving to a slot overwrites without a confirmation; the timestamp in the
menu is the guard. A transient notice (the "Analog on" mechanism) confirms:
"Saved to Slot 2", "Loaded Slot 2", or the failure.

All items are disabled outside `.playing` and while a dialog is shown.

## 3. Loading in a running game

A new runner request, `EmulatorRunner.requestLoadState(_:completion:)`, shaped
like `requestSaveState` (pending under `pacing`, signalled, serviced between
frames, also while paused, answered exactly once, `.runnerStopped` if the
runner stops first). On the emulator thread, in this order:

1. drain any pending memory-card write (`serviceMemoryCards`), so the card
   images the app holds are current;
2. snapshot the running machine (`core.saveState()`) for undo;
3. `core.loadState(data)`; on refusal stop here, the machine is untouched
   (the ABI is all-or-nothing), and the completion carries the error;
4. re-install both cards with `setMemoryCardData`, so they read as freshly
   inserted, as after a launch-time resume (the state restores the card's
   flag byte, and the cards may have changed since it was saved);
5. republish the pad status word;
6. `requestResync()`, as `serviceResetRequest` does.

**Another disc of the same game.** Before requesting, the view model peeks
the state (`ps1_peek_state`). If its serial is not the disc in the tray but
is one of `currentDiscs`, the load goes through the existing
`load(disc:resume:freshBoot:)` path, which rebuilds the machine on the right
disc. No undo is offered for that path. A serial matching no disc of the
game is refused with the existing state-disc message.

**Undo Load State.** The step-2 snapshot is kept on the view model, one
deep. Undo loads it through the same request (which takes a new snapshot,
so a second Undo returns to the loaded state). The buffer is cleared on
eject, disc load and disc swap. Failure messages reuse
`EmulatorViewModel.resumeMessage`.

## 4. Timed auto-save

`AutoSaveIntervalSetting`, key `autoSaveInterval`, minutes: `0` (Off), `1`,
`5`, `10`; default `5`. Absence is probed with `object(forKey:)` (a missing
key must read 5, not Off). Settings ▸ General shows it as "Auto-Save" next to
the existing save-on-exit row; its copy lives in `SettingsCopy.swift` under
the house style (`SettingsCopyTests`). The two settings are independent:
turning timed saves off keeps save-on-exit, and the reverse.

The clock counts **active play** on `PlayClock`'s terms: running, unpaused,
app active, on `systemUptime`. When the accumulated time reaches the
interval, the view model requests a save and writes it as the resume (with
the rotation in section 1), then restarts the count. It skips (and keeps
counting) while a dialog, a resume offer or an exit is in progress, and is
reset on every load and eject.

Compression and the disk write run off the main actor; only the snapshot and
thumbnail run on the emulator thread. The plan measures that cost; the
acceptance bar is no audio underrun at 1x on Silent Hill and Crash Warped.

## 5. Launch sheet

The resume offer appears when the game has a resume, a previous resume or
any filled slot. It gains an "Other States" pull-down listing Previous
Resume and each filled slot with its time; picking one loads it as Resume
does (disc chosen from the state's serial, as today). Resume, Fresh Boot,
Delete & Boot and Cancel are unchanged; Resume is disabled when only the
others exist.

## Testing

Swift tests (`ps1-macos/test.sh`):

- the store's rotation: new resume moves the old one to previous; each crash
  window (after temp write, after the first rename) leaves a loadable state;
- slot paths, keys, `Info` timestamps, empty slots;
- Delete & Boot leaves slots alone;
- `AutoSaveIntervalSetting`: absent key reads 5, Off persists;
- the auto-save clock against synthetic uptime: counts only active play,
  skips during a dialog, resets on load;
- the runner's load request: a refused state leaves the machine and answers
  with the error; a successful one re-installs the cards with the fresh flag
  and resyncs; answered once with `.runnerStopped` on stop;
- the undo buffer: one deep, swap on undo, cleared on eject and disc change.

## Out of scope

The browser build (`ps1-wasm`/`ps1-web`); more than six slots; renaming
slots; slot thumbnails inside the menu.
