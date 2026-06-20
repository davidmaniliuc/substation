# Design: Boot real games from disc (CUE/TOC + readable data track)

**Date:** 2026-06-20
**Status:** Approved, pre-implementation

## Problem

On the wasm frontend, loading a real commercial game (Silent Hill, Castlevania:
SOTN) leaves the BIOS shell looping forever — the game never launches. Two
independent gaps cause this:

1. **No disc geometry.** `disc.zig` hardcodes a single track at LBA 0 with no
   CUE/TOC parsing. Multi-track / multi-`.bin` games (SOTN) cannot be modeled.
2. **CD-boot read path unverified.** The whole disc/CD-boot pipeline has zero
   test coverage; `setDisc()` is wired only into wasm. The BIOS's read loop may
   stall somewhere unknown.

### What the real files look like

- **Silent Hill (USA):** one `.bin`, one `TRACK 01 MODE2/2352`, `INDEX 01
  00:00:00`. Already fits the current single-track model → its failure is the
  read path, not the disc model.
- **SOTN:** `.cue` + **two** `.bin`s — `TRACK 01 MODE2/2352` (data) and
  `TRACK 02 AUDIO` with `INDEX 00 00:00:00` / `INDEX 01 00:02:00` (150-sector
  pregap). Needs CUE + multi-track + multi-file.

Both games only need the **data track** readable to *boot*. Audio track matters
for in-game music, not launch → in-game CD audio is out of scope here.

## Goals / non-goals

**Goals**
- Model CUE-described discs (multi-FILE, multi-track, data + audio) in the core.
- Browser can load a game folder (`.cue` + `.bin`s) via a directory picker.
- Silent Hill boots past the BIOS shell to its executable / first GPU frame.
- SOTN's disc is correctly modeled (GetTN reports tracks 1–2; audio track present)
  and boots its data track.
- The disc model is unit-tested in `zig build test` (no browser needed).

**Non-goals**
- In-game CD-DA / XA audio fidelity for SOTN.
- CUE features beyond what these games use (CATALOG, REM, FLAGS, ISRC,
  PREGAP/POSTGAP commands, MODE2/2336, indices > 01).
- Save states, memory cards, region patching.

## Phase A — CUE/TOC + multi-track disc model

### Key approach: parse CUE in the Zig core, not JS

The browser only gathers files; `disc.zig` owns the TOC. One source of truth,
and — critically — unit-testable without a browser.

### Data plane unchanged

In a multi-FILE `.cue`, each file's sectors are contiguous on the disc, so
concatenating the `.bin`s **in CUE order** yields an image where
`sector N == byte N*2352`. `readSector2352` (offset = `lba*2352`) is unchanged.
Only TOC metadata is enriched.

### Core changes (`disc.zig`)

- `Track` gains: `type` (`.data` / `.audio`), `start_lba` (absolute, from
  INDEX 01), `pregap_lba` (absolute, from INDEX 00; `null` if absent).
- `Disc.initFromCue(cue_text: []const u8, data: []const u8) Disc`:
  - Parse `FILE "name" BINARY`: each FILE contributes
    `len(file)/2352` sectors; maintain a running `file_base_lba`.
  - Parse `TRACK nn MODE2/2352 | MODE1/2352 | AUDIO` → track number + type.
  - Parse `INDEX 00 mm:ss:ff` and `INDEX 01 mm:ss:ff` (MSF relative to current
    FILE start) → `pregap_lba` / `start_lba` = `file_base_lba + msf_to_frames`.
  - Ignore all other lines.
  - **Per-FILE sizes (decided):** to advance `file_base_lba`, the core needs each
    FILE's sector count. The browser emits a `REM FILESIZE <bytes>` line
    immediately before each `FILE` line; the core reads it and sets that FILE's
    sector span = `bytes/2352`. Keeps the wasm contract text-only and
    deterministic; no separate sidecar array. The harness/tests construct the
    same `REM FILESIZE` lines. File-name resolution stays the browser's job — the
    core only ever sees concatenated `data`.
- `Disc.init(data)` (no cue) → unchanged single MODE2/2352 track 1 fallback, so
  bare `.bin` and Silent Hill work without a cue.
- TOC-consuming helpers read the real tracks:
  - `firstTrack` / `lastTrack` from the track list.
  - `trackStart(track_bcd)` → that track's `start_lba` as MSF.
  - `leadOut()` → total sectors as MSF (unchanged).
  - `getSubchannelQ(lba)` → correct track, `index = 0x00` when
    `pregap_lba <= lba < start_lba` else `0x01`, relative MSF (counts down in
    pregap), absolute MSF, and a control bit reflecting data vs audio track.

### Browser changes (`ps1-wasm/www/index.html`, `src/main.zig`)

- Game input becomes a directory picker (`webkitdirectory`).
- JS finds the `.cue`, parses only its `FILE` lines to order the `.bin`s, reads
  each as an ArrayBuffer, concatenates in CUE order, and records per-FILE byte
  sizes.
- New/changed wasm exports: `allocCueBuffer(size)` to stage the cue text;
  `loadDisc()` builds the disc from `cd_buffer` + `cue_buffer`
  (`initFromCue` if cue present, else `init`).
- No `.cue` in the folder → treat a lone `.bin` as a raw single-track image.

### Tests (`ps1-core/tests/disc_test.zig`, new, wired into `build.zig`)

- SOTN-style two-FILE cue: track 1 = data at LBA 0; track 2 = audio; track 2
  `start_lba` = file1 sector count + 150 (pregap); `pregap_lba` = file1 sector
  count; `getSubchannelQ` returns index 00 inside the pregap and the audio
  control bit on track 2.
- SH-style single-track cue and bare-`.bin` fallback both yield one data track.
- BCD/MSF discipline asserted (no double-encoding).

## Phase B — Make the data track readable through to boot (evidence-driven)

CLAUDE.md's "root cause #2" (drive state coupled to `irq_queue`) is **mostly
already implemented**: the ReadN seek→read transition uses `seek_timer` ticked in
`step()` and survives `irq_queue.clear()`, and `drive_state` is a plain field.
So Phase B is a **debug loop**, not a pre-planned edit.

1. **Reproduce headlessly.** Add a harness path that boots the BIOS with a disc
   set via `setDisc()` and **no** `loadExe` sideload, so the CD-boot sequence
   runs under `zig build` — the currently-missing reproduction. (Uses a small
   synthetic or real data-track image.)
2. **Instrument.** Replace the unconditional `std.log.warn` spam in `cdrom.zig`
   with logging gated behind `debug_enable`, recording each CD command, its
   INT/responses, and drive-state transitions. Run once against the Silent Hill
   data track to capture **where the BIOS stalls**.
3. **Fix the single root cause the evidence points to**, with a focused failing
   test first (systematic-debugging / TDD). Suspects, not commitments:
   `irq_queue.clear()` on every command write (`cdrom.zig:198`) wiping a pending
   INT1; GetID region/flags; sector-data delivery sizing; ISO9660/SYSTEM.CNF
   read. Commit to none until the trace shows it.
4. **Verify end-to-end:** Silent Hill reaches its executable / first GPU frame in
   the harness, then confirm in the browser. SOTN's disc models as 2 tracks and
   boots its data track.

## Success criteria

- `zig build test` covers CUE/TOC parsing (SOTN-style + SH-style).
- Silent Hill boots past the BIOS shell (data-track-only is sufficient).
- SOTN: GetTN reports tracks 1–2, audio track present, data track boots.
- No regressions in existing tests.

## Risks / open questions

- Phase B is open-ended by nature; the trace may reveal a deeper CDROM/GPU/BIOS
  issue. If 3+ fixes fail, stop and question the CDROM architecture per
  systematic-debugging.
- `webkitdirectory` browser-support quirks; acceptable for a debug frontend.
