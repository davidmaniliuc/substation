# Multi-disc games — disc swapping and library grouping — design

**Date:** 2026-08-31
**Status:** approved; one implementation plan
**Closes:** the "No disc swap" gap recorded in CLAUDE.md § CDROM — state of play.

## Goal

Play a multi-disc game past its first disc.

Final Fantasy IX ships as four `.cue`/`.bin`/`.sbi` triples in one folder. Today
the app shows four unrelated tiles, and reaching the end of disc 1 is the end of
the run: `CdRom.setDisc` replaces the disc slice and nothing else, so there is no
shell-open state, no door-open error, and no signal of any kind that the game
could use to notice that the disc under the laser is a different one. The game
keeps its cached file table and reads disc 2 through disc 1's directory.

This spec adds the shell to the CDROM model, a swap entry point to the C ABI, a
**Machine ▸ Change Disc** menu in the app, and a **Merge Multi-Disc Games**
library toggle shaped after DuckStation's setting of the same name.

## Scope

In:

- Shell open/closed state, the sticky "disc may have changed" latch, and a timed
  tray close in `ps1-core/src/cdrom/`.
- The door-open error response for commands issued while the tray is open.
- `ps1_swap_disc` in `ps1-capi`, sharing `ps1_load_disc`'s validation.
- A pending-swap slot on `EmulatorRunner`, applied on the emulator thread.
- `DiscGrouping` — a pure fold from `[GameEntry]` to `[GameGroup]` — plus the
  `MultiDiscSetting` that switches it and a new `Library` menu holding it.
- `Machine ▸ Change Disc`, populated independently of that setting.

Out — permanently, or elsewhere:

- **Memory-card persistence.** CLAUDE.md pairs it with disc swap because the
  *relaunch workaround* needs it: quitting and reopening the app to start disc 2
  loses the save, because the 128 KB image is in-memory only and `memcard_dirty`
  is set and never consumed. A real swap does not go through that path — the
  game hands its state over in RAM and never touches the card — so the two are
  independent once swapping works. Persisting saves is its own feature with its
  own file-layout, per-game-versus-shared and slot decisions.
- **`ps1-wasm`.** Keeps its current single-disc loading. The browser page has no
  library and no menu bar to hang a disc picker on.
- **`ps1-golden` multi-`FILE` and multi-`.cue` skips.** Both rules stand. FF9's
  directory holds four `.cue` files and is skipped as ambiguous; nothing here
  changes that, and relaxing it is a golden recapture.
- **A tray the player can leave open.** There is no "Open Disc Tray" command.
  The tray opens and closes as one indivisible operation, so the machine has no
  reachable state in which it is sitting open with no disc.
- **Any `trace-golden` recapture.** See § 7 — this is a checkable claim, not an
  aspiration.

## Decisions taken

### 1. The shell is three fields, and bit 4 is derived from two of them

`Drive` (`ps1-core/src/cdrom/cdrom.zig`) gains:

```zig
shell_open: bool = false,      // the tray is physically open
shell_changed: bool = false,   // sticky: a disc MAY have been exchanged
shell_close_timer: i64 = 0,    // cycles until the tray closes again
```

Status bit 4 is **never stored in `drive.status`**. `getDriveStatus` ORs it in:

```zig
if (self.drive.shell_open or self.drive.shell_changed) stat |= 0x10;
```

The alternative — setting and clearing the bit inside `drive.status` — gives the
same observable behaviour with two sources of truth for one fact, and bit 4 sits
inside the existing `& 0x1F` mask, so a stale bit would survive into responses
with nothing to catch it.

Three operations on `CdRom`:

- **`openShell()`** — sets both `shell_open` and `shell_changed`, clears the
  motor bit in `drive.status`, forces `drive_state = .Idle`. Avocado's
  `StatusCode::setShell` does the same three things (`cdrom.h:42-49`).
- **`closeShell()`** — clears `shell_open`, restores the motor. **`shell_changed`
  survives.** That is the entire mechanism by which the game learns anything
  happened, and it is the half Avocado does not model.
- **`swapDisc(d, open_cycles)`** — `openShell()`, install the disc, arm
  `shell_close_timer`.

The disc is installed at **open**, not at close. Nothing can read it while the
tray is open, so deferring the install would add a third state carrying a
pending disc for no observable difference.

### 2. The sticky latch is what makes a swap detectable

PSX-SPX: bit 4 is set when the shell opens and *stays* set after it closes,
until the status is read via `Getstat` (01h) — and only then if the shell is
actually closed by that point. Software polls `Getstat`, sees bit 4, and knows
to re-read the TOC rather than trust its cached file table.

`Getstat` therefore clears `shell_changed`, with two orderings that are
load-bearing:

- **After `ackStatus`, not before.** `queueIrq` snapshots the response bytes at
  queue time, so clearing afterwards still delivers a byte with bit 4 set.
  Clearing first delivers a clean status and the swap goes unnoticed.
- **Only when `shell_open` is false.** A `Getstat` issued while the tray is
  still open must not consume the latch — the game has not yet been given a
  disc to notice.

Avocado models neither the latch nor the clear (`StatusCode` has `shellOpen`
alone) and its swap is `setShell(true); disc = …; setShell(false);` executed in
one instant (`system_tools.cpp:76-79`, `platform/windows/main.cpp:236-240`).
That sequence leaves the status byte identical before and after, so on Avocado's
own model a game that polls has nothing to observe. **Avocado is not an oracle
for this feature.** PSX-SPX is.

### 3. Commands during an open tray answer INT5, and the general rule subsumes Avocado's special case

While `shell_open`, `processCommand` short-circuits every command to:

```zig
cdrom.queueIrq(5, ack_delay, &[_]u8{ cdrom.getDriveStatus() | 0x01, 0x80 });
```

except **`Getstat` (0x01)** and **`Test` (0x19)**, which pass through. Test is
exempt because Test 0x03 is *force motor off* and is, in Avocado's own comment
at `commands.cpp:370`, "used in swap".

Worth recording because it looks like a coincidence and is not: with the tray
open the motor bit is clear, so `getDriveStatus()` is `0x10`, and the expression
above evaluates to `{0x11, 0x80}` — byte for byte the response Avocado
hardcodes into `cmdGetId` for the shell-open case (`commands.cpp:413-417`). The
general form is PSX-SPX's `INT5(stat+1, 80h)`; Avocado's constant is that same
response written out for one command. Implementing the general rule gets GetID
right and every other command right at the same time.

### 4. The tray stays open for a real interval, and that needs `nextDeadline`

`shell_close_timer` is armed at one second of emulated time —
`constants.cpu_clock_hz`, 33,868,800 cycles — as a named constant beside the
other CDROM timings.

An instant swap is the cheaper design and is rejected: the point of § 2 is to
give a polling game a window in which the machine visibly has no disc, and a
real tray takes about a second to travel. A game that watches for the open state
itself, rather than for the latch afterwards, only works with a real window.

The timer is decremented in `applyElapsed`, fired in `stepEvents`, and **named in
`nextDeadline`**, joining the six terms already there.

That last one is load-bearing, and not for the reason CLAUDE.md's general rule
gives. The rule says a timer the slow path acts on but `nextDeadline` does not
name never fires at all, because the guard steps past its deadline. Here the
mechanism is different and sharper: `applyElapsed` **clamps** the timer at 0 and
deliberately fires nothing, while `stepEvents` — the only thing that calls
`closeShell` — acts only on a timer still above 0. `nextDeadline`'s last term,
`768 - audio_tick_counter`, is unconditional, so a deadline bounded by it alone
still settles every 768 cycles; but a 768-cycle batch applied to a timer with
less than 768 left lands it on exactly 0 inside `applyElapsed`, and `stepEvents`
then declines to act on it. The tray never closes and the game is refused every
command for the rest of the run.

Naming the timer is what keeps every batch strictly shorter than what remains of
it, so the last step of the window always lands in `stepEvents` with the timer
still positive. Two tests in `cdrom_test.zig` pin this — one stepping three
cycles at a time, one also polling Getstat through the window so `catchUp` runs
— and both were verified to FAIL with the `nextDeadline` line removed.

### 5. `ps1_swap_disc` is `ps1_load_disc` with a different last line

```c
int32_t ps1_swap_disc(Ps1*, const uint8_t* bin, size_t bin_len,
                            const char* cue, size_t cue_len,
                            const uint8_t* sbi, size_t sbi_len);
```

Identical validation, identical lifetime contract: **bin borrowed** and must
outlive the handle or the next call, cue parsed immediately, **sbi copied** into
the handle. The two functions share one private helper that validates and copies
and hands back a `Disc`, rather than duplicating that block — including its
ordering rule, that the sidecar copy happens *after* every rejection, because
the function returns a code and `errdefer` would never fire.

No `ps1_shell_open` getter and no separate open/close entry points. The picker
UX in § 8 needs neither, and § 3's Out list rules out a player-visible tray
state that would.

### 6. The swap runs on the emulator thread

`EmulatorRunner.runLoop` is explicit that "this thread owns the core", and
`EmulatorViewModel.reset()` carries a documented main-actor race that CLAUDE.md
says is not to be widened. Calling `ps1_swap_disc` from a menu handler would
widen exactly that race, and against a longer critical section than `ps1_reset`.

`EmulatorRunner` gains a pending-swap slot guarded by the `NSCondition` it
already holds for pacing. `runLoop` drains it immediately before
`core.runFrame()` and applies it there. `Ps1Core.swapDisc` assigns its retained
`discData` on that same thread, so the previous `Data` is released only after
the core has stopped pointing into it.

No resync is raised. A swap mutates no VRAM, and the command stream is unbroken
across it.

### 7. The goldens must not move, and that is the check

No `ps1-golden` workload opens the shell: nothing calls `swapDisc`, so
`shell_open` and `shell_changed` stay false, `shell_close_timer` stays zero, and
`getDriveStatus` returns exactly what it returns today.

The three fields are added to `hashCdrom` in `ps1-golden/src/state_hash.zig` by
hand — that file is written by hand on purpose, so that the check polices a
refactor instead of following it — and `trace-golden -- verify` must then report
OK for all ten workloads **with no recapture**. A red verify means the design is
wrong, not that the goldens are stale.

The machine also boots with the tray **closed and the latch clear**, which is
today's behaviour exactly. Avocado's `StatusCode` constructor instead starts
with `shellOpen = true` and relies on disc load to close it; adopting that would
put bit 4 in front of the BIOS's first `Getstat` on every workload and move
every golden for no gain.

### 8. Grouping is a pure fold, and the view never branches on the setting

`GameScanner` is untouched — it keeps returning one `GameEntry` per playable
file under its existing per-directory rule. A new value type folds that output:

```
DiscGrouping.group(_ entries: [GameEntry], merging: Bool) -> [GameGroup]
```

`GameGroup` is `{ title: String, discs: [GameEntry] }`. **With `merging` false
every group holds exactly one disc**, so `LibraryView` renders groups
unconditionally and there is no second rendering path to keep in step.

The rule, matching DuckStation's: strip the first `(Disc N)`, `(Disk N)` or
`(CD N)` token — case-insensitive, square brackets accepted — from anywhere in
the title, collapse the leftover whitespace, and group entries sharing **both**
that base title and their directory, ordered by N. An entry with no disc token
is never grouped, even against entries that have one.

Same-directory is not incidental. It matches `GameScanner`'s existing
per-directory rule, and it is what stops two unrelated rips of the same game in
different folders collapsing into one tile.

Covers are keyed on a SHA-256 of the disc path (`CoverStore`), so **a group's
cover is its first disc's cover**, and setting one on the group sets it there.
The alternative — writing the same image for every disc in the group — is worse
in both directions: it multiplies the stored files, and it still has to pick a
disc to read back from.

### 9. `MultiDiscSetting` defaults on, so absence is ambiguous

Shaped after `PgxpSetting`, with one difference that is a real trap rather than
a style note. `PgxpSetting`'s own doc comment explains that it needs no
`object(forKey:)` probe *because* `bool(forKey:)` returns false for a missing
key and false is its intended default. This setting defaults to **true**, so
that reasoning inverts: a first launch would read false and ship the feature
off. Absence is probed with `object(forKey:)` and resolved to true, the way
`VolumeSetting` handles its level.

Four FF9 tiles is noise, and grouping is what the feature is for; on is the
useful default. This is not one of the byte-exactness defaults (1×, PGXP off) —
it changes no emulated behaviour at all.

The toggle lives in a new **`Library`** menu, which also takes over
`Refresh Library` (⇧⌘R) and `Choose Games Folder…` / `Choose BIOS Folder…` from
File. Those are library commands sitting in File today only because there was no
better menu; `Open Disc…` (⌘O) stays in File, where it belongs.

### 10. Change Disc is independent of the merge setting

**`Machine ▸ Change Disc ▸`** lists the running game's discs with a checkmark on
the active one, and is disabled when there is only one. DuckStation's
`System ▸ Change Disc` behaves the same way regardless of how its game list is
displayed, and the coupling would be surprising: a player who prefers separate
tiles has not asked to lose disc swapping.

`load(disc:)` derives the sibling list by running § 8's rule over the launched
disc's **own directory**, not by remembering which tile was clicked. That falls
out of the same code and buys a real property: Change Disc also works for a game
opened through `File ▸ Open Disc…` that was never in the library folder at all.

Each disc's own `.sbi` is picked up with no change.
`EmulatorViewModel.sidecar(forDisc:)` already matches on the disc's own stem,
and CLAUDE.md flags FF9 as precisely the case that rule exists for: the four
discs share a directory and each sidecar names sectors of its own image.

## Testing

| Where | What |
|---|---|
| `cdrom_test.zig` | `openShell` sets bit 4 and clears the motor; a command issued while open answers `{0x11, 0x80}`; `Getstat` clears the latch only once the tray is closed, and the response it queues still carries bit 4; `shell_close_timer` fires from the deferred `step` path; a sector read after a swap returns the **new** disc's bytes. |
| `capi_test.zig` | `ps1_swap_disc` rejects a bad `.sbi` and an un-laid-out multi-`FILE` cue exactly as `ps1_load_disc` does, and a successful swap leaves the handle's sidecar replaced rather than appended. |
| `trace-golden -- verify` | Green for all ten workloads, no recapture. § 7. |
| `DiscGroupingTests.swift` | Each token form; ordering by N; the directory boundary; an entry with no token left ungrouped; `merging: false` yielding one group per entry. |
| `MultiDiscSettingTests.swift` | A missing key reads **true**; `set` persists and reads back. |

Every core test is written to **fail first** against the unmodified code. CLAUDE.md
is explicit that a guard test that cannot fail is worse than none, and § 4's
`nextDeadline` entry in particular is invisible without a test that exercises the
deferred path rather than calling `stepEvents` directly.

## Risks

- **A game may not poll `Getstat` at all.** Some titles watch for the tray via
  the INT5 error responses instead. § 3 and § 4 cover both — the error responses
  during the window, and the latch afterwards — which is why the window is real
  rather than instant.
- **One second may be the wrong window.** It is a constant, and the only
  evidence for the exact figure is that physical trays take about that long. If
  FF9 does not cross the boundary, it is the first thing to vary.
- **The grouping regex meets rips this spec has not seen.** The rule is
  deliberately narrow: no token, no grouping. A rip it does not recognise shows
  as separate tiles — today's behaviour — rather than mis-grouping two games.
