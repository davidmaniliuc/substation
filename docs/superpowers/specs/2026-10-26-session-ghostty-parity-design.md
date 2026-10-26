# The session decides, Swift asks: Ghostty parity, step two

The engine-into-Zig move (Plans A-C, done 2026-10-26) put the machine, the
threads, the audio and the renderer in Zig. Swift still does work that is not
user interface: it polls the session for what happened, it assembles disc
images byte by byte, and it keeps a hand-written list of every setting a new
session needs. This spec moves those three jobs behind the session's C ABI, so
the shape matches Ghostty's: the library owns behaviour and policy and TELLS
the app what happened; the app renders UI and forwards OS events.

## Why now

- Two crashes in the 2026-10-26 hand checks (a load and a save trapping on the
  emulator thread, `3427b50`, `5f2e75d`) came from the seam between the two
  sides. The fewer crossings, the fewer of those.
- The polling loop (`EmulatorViewModel.startWatchingPad`, every 16 ms, and
  `startSamplingFps`, every 0.5 s) wakes the main thread 62 times a second
  for nothing most of the time, and rumble reaches the motors up to 16 ms late.
- `load(disc:)` re-applies settings from a list (`EmulatorViewModel.swift`,
  the block after `teardownRunningMachine()`). A setting missing from that list
  is a silent bug: `controls.zig` defaults every setting to "off" precisely so
  such a bug shows, but it still has to be noticed.
- The Swift side reads a whole disc into a `Data` (a CHD included, up to
  ~700 MB) and concatenates per-track rips, then `disc.zig` parses the cue a
  second time. Two cue parsers exist (`CueSheet.swift`, `disc.zig`) and the
  `REM FILESIZE` line is a private protocol between them.

## Goals

1. **Events are pushed.** The session calls the host back when something the
   UI shows changes. Swift polls nothing.
2. **A disc is a path.** The host names a file; the session opens it, finds its
   `.sbi` and `.ppf`, and owns the bytes. Swift reads no disc bytes to start or
   swap a game.
3. **Settings are one value.** The host hands the session one settings struct,
   at creation and on every change; the session applies what changed. The
   per-game PGXP preset is folded in by the session, which knows which disc is
   in the tray.
4. **The dead Swift goes.** What only existed to feed the old bytes API, the
   old polling and the old per-setting calls is deleted.

## Non-goals

- **Keybindings and the input map stay in Swift.** The pad is a 16-bit mask
  and two stick bytes, which already cross as values; the events producing them
  come from AppKit and GameController, which must stay in Swift. Ghostty
  resolves keys in Zig because a terminal encodes keystrokes; a pad does not.
- **The save-state store, the auto-save clock and the resume offer stay in
  Swift.** They are file and UI policy built on Apple's `Compression`, the slot
  UI and the exit gate. The session already produces and consumes the state
  bytes.
- **No app-level handle** (Ghostty's `ghostty_app_t` beside its surfaces). One
  game at a time is a standing decision (shared memory cards, single audio
  pacing, single exit gate); a handle that outlives games would hold nothing.
- **UserDefaults stays the store of record.** Swift keeps persisting settings
  as today; only the hand-over changes. No settings file, no migration.
- **The `EmulatorViewModel` split** is a separate, later spec, sized once this
  one has shrunk it.
- **The browser build is untouched.** `ps1-wasm` is a separate frontend by
  decision; `ps1.h`'s bytes API (`ps1_load_disc`) stays for it and for
  `Ps1Core`'s disc and resume inspection.
- **No core change.** Nothing here touches `ps1-core`; no trace golden, PGXP
  floor or fixture may move.

## Anti-goals (a failure even if it works)

- A completion or event trampoline that inherits the main actor. Every C
  callback in Swift is a `nonisolated static`, never a closure literal written
  in a method (`GameSession.swift`'s rule since `5f2e75d`).
- An event callback that blocks or allocates unboundedly on the emulator
  thread, or that can be called after `ps1_session_free` returns.
- A settings struct that a later field addition can silently misread: the
  struct carries its own size, and the session refuses one it does not know.
- A disc that loads in the app today and is refused after (multi-`FILE` cues,
  CHDs, `.sbi` and `.ppf` sidecars, raw `.bin`s), or a memory-use regression
  for a single-file disc.

## Constraints

- Zig 0.17.0; the session's existing threading rules (`ps1_session.h` rules
  1-4) hold for everything added.
- `zig build test`, `zig build test-metal`, `zig build capi-lib`'s `nm` check
  and `ps1-macos/test.sh` stay green; `trace-golden -- verify` is unaffected
  because the core is.
- The app is not sandboxed, so the session may open the paths it is given; the
  security-scoped bookmarks Swift holds keep doing what they do today.
- The savestate identity includes the PPF fingerprint: the session loading the
  `.ppf` itself must produce the same fingerprint the bytes API does today, or
  every existing resume state becomes `statePatch`.

## The design

### 1. Events

`Ps1SessionConfig` gains an event callback and its context:

    void (*on_event)(void* ctx, const Ps1Event* ev);   /* may be NULL */
    void*  event_ctx;

`Ps1Event` is a tagged struct, valid only during the call. The kinds this spec
needs, each replacing a poll:

| event | replaces | sent when |
|---|---|---|
| pad status (analog bit, small and large motor) | the 16 ms `padStatus` poll | any of the three changes |
| card written | the `cardWrites` poll | a card file write lands |
| rewind seconds left | the `rewindSeconds` poll while rewinding | each rewind step |
| frame rate | `framesProduced` + `FpsCounter` | twice a second, from the emulator thread's own count |

Rules:

- Called on a session thread, never after `ps1_session_free` returns (the same
  guarantee as rule 1 for completions). The host copies what it needs and
  returns; Swift's trampoline hops to the main actor with `async`.
- Change-driven events are coalesced at the source: the emulator thread sends
  one when the value differs from the last one sent, at most once per frame.
- `event_ctx` must stay valid until `ps1_session_free` returns; Swift retains
  the object behind it for the session's life and releases it after `free()`.
- While paused the frame-rate event may stop; the title strip shows "Paused"
  then and ignores the rate (my call: no event is owed for a value nobody
  shows).
- The counters (`ps1_session_frames_produced`, `_pad_status`, `_card_writes`,
  `_rewind_seconds`) stay in the ABI for tests and tools; the app stops reading
  them.

Swift then deletes `startWatchingPad`, `startSamplingFps`, `FpsCounter` and the
`padTask`/`fpsTask` plumbing; `padStatusChanged`, `memoryCardWritesChanged`
and the rewind badge are driven by the event instead.

### 2. A disc is a path

`Ps1SessionConfig.disc` and `ps1_session_request_swap` take a path instead of
`Ps1DiscBytes`:

    const char* disc_path;   /* NUL-terminated: a .cue, .chd or .bin; NULL boots the shell */

Swift passes the URL's file-system representation
(`withUnsafeFileSystemRepresentation`), never `path`, so a name with
decomposed Unicode reaches the file it names.

The session:

- opens a `.cue` and every `FILE` it names relative to the cue's directory;
  a `.chd` through the CHD reader; anything else as a single-track `.bin`;
- picks up `<stem>.sbi` and `<stem>.ppf` beside the disc, matched on the disc's
  own stem (the rule `EmulatorViewModel.sidecar(forDisc:)` and `patch(forDisc:)`
  follow today: FF9's four discs share a folder);
- owns the bytes for as long as the disc is in the tray, and frees them when the
  disc is replaced or the session freed. The `release` callback, `DiscBox` and
  the retain protocol go away.

New error codes for a path that cannot be opened or read, mapped in `ps1.h`,
`Ps1Error` and `ps1-web/src/errors.ts` (the mirror rule), each with a message
in `EmulatorViewModel.describe`.

Swift still identifies the disc itself before `ps1_session_new`, through
`DiscIdentity.identify(disc:)` (mapped, as the scanner does), because it needs
the serial and region to choose the BIOS and the resume key. Choosing the BIOS
stays in Swift: it is file choice over the player's BIOS folder.

Swift deletes `discImage(forCue:)`, `CueSheet.swift` (if nothing else reads it:
`DiscIdentity.trackOneImage` does today, and may keep a minimal form), the
`sidecar`/`patch` helpers, `DiscBox`, `DiscBytes` and `withDisc`/`withBytes`.

### 3. Settings are one value

One struct carries every setting a session reads:

    typedef struct {
        uint32_t        size;            /* sizeof(Ps1SessionSettings) */
        float           gain;
        int32_t         cpu_engine;
        size_t          rewind_budget;
        int32_t         runahead;
        int32_t         scale;
        int32_t         dither;
        int32_t         texture_filter;
        int32_t         sprite_filter;
        Ps1PgxpSettings pgxp;            /* the PLAYER's values */
        uint8_t         pgxp_use_presets;
    } Ps1SessionSettings;

- `Ps1SessionConfig` carries one, so a session starts with every setting
  applied and there is no list to keep.
- `ps1_session_set_settings(Ps1Session*, const Ps1SessionSettings*)` replaces
  the per-setting setters for these fields; the session diffs against what it
  holds and stores only what changed into `Controls` (so the CPU engine, the
  vertex cache and the rewind budget still cross only on change).
- A `size` the session does not know is refused with an error code, never
  read.
- Controls that change at input rate stay their own calls: buttons, sticks,
  the Analog press, paused, rewinding, the speed (held Tab changes it per key
  press), size, occlusion and the band. (My call: the speed is input, not a
  setting, because fast-forward is a held key.)
- **The PGXP preset is folded by the session.** It looks the serial up in
  `pgxp_presets.zon` when a disc goes in (at creation and when a swap is
  ANSWERED, not requested), and applies preset-over-player for the fields the
  preset names, exactly as `EmulatorViewModel.pgxpSettings` does today
  (`transparent_depth` is never a preset field). A refused swap therefore
  keeps the old disc's preset, which today it does not. Swift still calls
  `ps1_lookup_pgxp_preset` for the UI (greying, the footer that names the
  preset), but sends only the player's values, and updates the preset it
  shows when the swap's completion reports success rather than when it asks
  (my call: the UI then agrees with the session on a refused swap too).

Swift builds the struct from its settings in one computed property and sends it
from one place whenever any of them changes; `pushPgxp`, `applySpeed`'s session
call and the setters' individual session calls collapse into that.

### 4. The dead Swift

- `Ps1Core.swift` keeps only what the app calls: BIOS and disc identity,
  `peekStateSerial`. Methods called only from tests (`readAudio`, `display`,
  `loadMemcard`, `takeMemcard`, `swapDisc`, `padStatus`, `setCpuEngine`,
  `loadState`/`saveState` on a handle) go, with their tests where `capi_test`
  already covers the same ABI; a test that pins something `capi_test` does not
  moves there first.
- The stale handoff `docs/superpowers/handoffs/2026-10-22-engine-into-zig-plan-c.md`
  is not part of this; the untracked prototype folders are the owner's.

## Order

Three plans, each shippable alone, in this order:

1. **Events** (smallest, removes the polling, independent of the others).
2. **Settings as one value**, preset fold included.
3. **Disc by path**, with the `Ps1Core` trim last since it depends on 3.

## Gates

- Each plan: `zig build test`, `capi-lib` (its `nm` check updated for added
  and removed symbols), `ps1-macos/test.sh`, `zig build macos`.
- Plan 2: a session test that a swap refused keeps the old preset, and one
  per preset-decided field that the folded value reaches `Controls`.
- Plan 3: every rip shape in `games/` opens by path (single and multi-`FILE`
  cues, CHD, raw `.bin`, a disc with `.sbi`, one with `.ppf`), and an existing
  resume state of a PPF-patched disc still loads (the fingerprint is
  unchanged). `tools/chd-roundtrip.sh` is unaffected.
- Hand check after each plan: a game starts, rumble and the Analog notice
  follow the pad, the FPS readout moves, a card save shows its badge, rewind
  shows seconds, a disc swap works.

## Left to the builder

- `Ps1Event`'s exact layout (a tag plus a union, or a tag plus fixed fields).
- Whether a single-file disc is mapped or read: mapping is preferred where
  `Disc` takes one slice (one file, or a CHD through its reader), and a
  multi-`FILE` cue may still concatenate into one allocation as Swift does
  today. No memory regression either way.
- Whether `ps1-trace`'s `cue_files.zig` and the session's loader share code.
  Sharing is welcome if it moves no golden; `ps1-golden` must never pick up a
  `.ppf` (CLAUDE.md's PPF rule), so a shared loader takes the sidecar rule as
  a parameter.
- Where in `ps1-session/` the loader and the event emitter live.
