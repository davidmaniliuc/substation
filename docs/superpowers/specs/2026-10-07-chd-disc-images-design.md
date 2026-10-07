# CHD disc images

Status: implemented 2026-10-07

## Goal

The core, the macOS app and the native harnesses open a `.chd` disc image
exactly as they open a `.bin`/`.cue` today: same drive, same identification,
same `.sbi` sidecar, same library, same disc swap.

Success is:

1. Every disc in `games/` converted with `chdman createcd` reads back
   sector-for-sector identical to its `.bin`, with the same track table,
   lead-out and identity (`chd-verify`). Each converted copy is deleted as
   soon as it has been checked.
2. Every existing trace golden verifies unchanged when its workload boots from
   the `.chd` instead of the `.cue` (`verify --chd`). No recapture.
3. `games/grandtheftauto.chd`, a CHD with no `.cue` beside it (one MODE2 data
   track plus ten CD-DA tracks, codecs `cdlz`/`cdzl`/`cdfl`), boots and plays
   its CD-DA music in the app.
4. The app lists, opens (Open Disc, Finder, the library) and swaps to a `.chd`,
   and identifies its region and serial during a library scan without
   decompressing the whole image.

Non-goals: CHD v3/v4, parent/child (delta) CHDs, uncompressed CHDs (a map
with no codecs, which `chdman createcd` never writes by default), cooked
2048-byte track types, GD-ROM metadata, writing CHDs, subcode read from the
image (LibCrypt keeps coming from `.sbi`), `.chd` in `ps1-wasm`, ECM, PBP, and
`.m3u`.

## What exists today

- `Disc` (`disc.zig`, 322 lines) holds `data: []const u8`, a flat 2352-byte-per-
  sector image the caller owns and the app memory-maps. Exactly three lines
  touch it: `leadOut` (sector count) and `readSector2352` (bounds check and
  copy). Everything above (`cdrom/`, `discid.zig`, LibCrypt) goes through
  `readSector2352`/`readSectorRaw`, `trackForLba` and `getSubchannelQ`.
- The C ABI's `prepareDisc` (`ps1-capi/src/root.zig`) builds a `Disc` from
  `bin` + optional `cue` + optional `sbi`, shared by `ps1_load_disc` and
  `ps1_swap_disc`; `ps1_identify_disc` builds one from `bin` alone.
- The app knows two disc kinds. File types are declared in `ps1-macos/Info.plist`
  (`cue` Default, `bin` Alternate), scanned by `GameScanner` (a `.bin` counts
  only when its folder has no `.cue`), and carried as `GameEntry.isCue`, which
  also drives the raw-`.bin` "CD-DA will be silent" warning.
- `ps1-golden` discovers workloads as `games/*/<one>.cue`.

## The CHD format, as far as this design depends on it

- A v5 header (124 bytes, big-endian): magic `MComprHD`, version 5, four
  compressor tags, logical size, map offset, metadata offset, hunk bytes, unit
  bytes, SHA-1s. For a CD, unit bytes is 2448 (2352 sector + 96 subcode) and
  hunk bytes is 8 units (19,584). GTA's header reads exactly this.
- The hunk map is itself compressed: per-hunk compression types Huffman-coded,
  then offsets/lengths/CRC16s in a packed bit stream, guarded by a CRC16 over
  the decoded map.
- Track layout is metadata: one `CHT2` entry per track,
  `TRACK:n TYPE:t SUBTYPE:s FRAMES:f PREGAP:p PGTYPE:g PGSUB:u POSTGAP:q`.
- Each track's frames are padded to a multiple of 4 in the image, so a CHD
  frame index is not an LBA.
- A pregap is stored in the image only when `PGTYPE` starts with `V`
  (`VAUDIO`, `VMODE1`, ...), and then `FRAMES` includes it. Otherwise the
  pregap has no frames in the file, and it takes no LBAs here either: that is
  exactly how `Disc.initFromCue` already treats a cue's `PREGAP` command, which
  is what chdman turns into an unstored pregap. A stored pregap is a cue's
  `INDEX 00` and becomes the track's `pregap_lba`.
- Each hunk's CRC16 in the map covers the WHOLE hunk, subcode included.
- Audio samples are stored big-endian.
- The CD codecs (`cdzl`, `cdlz`, `cdzs`, `cdfl`) share one hunk layout: an
  ECC bitmap (one bit per frame), the compressed length of the sector data (2
  bytes, or 3 when the hunk is 64 KB or more), the sector data through the base
  codec, then the subcode through its own stream. A set ECC bit means the
  compressor verified the frame's ECC, then zeroed its sync pattern and its
  P/Q parity, and the decoder must regenerate both.
- Hunk-level types besides the four codecs: `none` (stored), `self` (a copy
  of another hunk), `parent` (a hunk in another file).

## Architecture

### Core: `ps1-core/src/chd/`

Five files, each under the ~600-line budget, re-exported from `root.zig` as
`ps1_core.chd`:

- **`bitstream.zig`**: the MSB-first bit reader the map and FLAC share.
- **`map.zig`**: the v5 hunk map (Huffman-coded compression types, RLE,
  self-references, CRC16 over the decoded map).
- **`chd.zig`**: `Reader`. `open(gpa, bytes) !*Reader` validates the header,
  decodes the map, parses the `CHT2` metadata into the same `[99]Track` table a
  cue produces, and builds the per-track LBA→frame table that absorbs padding
  and unstored pregaps. `readSector(lba, *[2352]u8) bool` finds the hunk,
  decompresses it through a small cache (the last 4 hunks), and copies the
  frame out. `sectorCount()` serves `leadOut`. `close()` frees it. The reader
  holds slices into the caller's bytes and never copies the image.
- **`cd.zig`**: the CD codec wrapper (ECC bitmap, length field, base-codec
  dispatch, the subcode decompressed only so the hunk's CRC16 can be checked,
  then never read), ECC P/Q
  regeneration (the same Reed-Solomon tables and algorithm chdman verifies
  with, so a regenerated frame is byte-identical), and the audio byte swap.
  Base codecs: `std.compress.flate` (`Container.raw`) for `cdzl`,
  `std.compress.lzma.Decode` with explicit properties for `cdlz` (CHD writes
  no LZMA header, and the dictionary size is derived from the hunk size the
  way chdman's encoder normalises it), `std.compress.zstd` for `cdzs`, and
  `flac.zig` for `cdfl`.
- **`flac.zig`**: a FLAC frame decoder (no metadata blocks, no seeking: CHD
  stores bare frames). 16-bit stereo at 44.1 kHz, block size from the hunk.
  Constant, verbatim, fixed (orders 0–4) and LPC (up to 32) subframes; Rice
  partitions with escape codes; independent, left/side, right/side and
  mid/side stereo; frame CRC8 and CRC16 checked.

Unsupported input is refused at `open`, never at read time: a version other
than 5, any `parent` hunk or non-zero parent SHA-1, an unknown codec tag, an
uncompressed map, a unit size other than 2448, a track type other than
`MODE1_RAW`/`MODE2_RAW`/`AUDIO`, metadata other than `CHT2`/`CHTR`, or a map
whose CRC fails. Each hunk is checked against its map CRC16 on
decompression. A mismatch fails that read and logs once, and the drive sees
the same failed read it sees past the end of a `.bin`. Corrupt data is never
passed off as good.

### `Disc` gets a source

```zig
source: union(enum) { flat: []const u8, chd: *chd.Reader },
```

`data` becomes the `flat` arm. `leadOut` and `readSector2352` dispatch on
the source; nothing else in `Disc` changes, and nothing above it changes at
all. `Disc.initFromChd(reader)` takes its tracks from the reader. `Disc`
stays a value: copying it copies the pointer, and the reader's cache is
reached only from the thread that owns the machine (identification opens its
own reader).

A `.sbi` beside a `.chd` is found by stem and attached through `setSbi`
exactly as beside a `.cue`.

Savestates are untouched: disc bytes were never in a state, and neither is
the reader or its cache.

### C ABI: no new entry points

`prepareDisc` and `ps1_identify_disc` check `bin` for the `MComprHD` magic
when no cue is given. On a match they open a `chd.Reader` instead of calling
`Disc.init`. The handle owns its reader and closes it on the next load or
swap and on destroy. As with every other `prepareDisc` rejection, a refused
file returns before the handle is touched. The new error code is
`PS1_ERR_BAD_CHD`, added to the header beside the existing codes.
`ps1_identify_disc` opens a temporary reader, so a library scan decompresses
only the hunks the ISO walk reaches.

### Harnesses

- `ps1-trace` and `ps1-bench` accept a `.chd` path through the same
  detection. `ps1-trace`'s multi-FILE cue loader moves to
  `ps1-trace/src/cue_files.zig` and becomes a named module `ps1-golden` imports
  too, so `chd-verify` compares against multi-FILE rips (Tomb Raider's 57
  tracks) without a second copy of it.
- `ps1-golden` workload discovery stays on `games/*/<one>.cue`, so converting
  a disc never mints a duplicate workload. GTA, at the root of `games/` with
  no cue, is not a workload; giving CHD-only discs golden coverage is a
  follow-up.
- **No converted copy outlives its check.** The disk has ~45 GB free and a
  converted disc is 300–450 MB, so `games/` never holds a whole converted
  library. `tools/chd-roundtrip.sh` takes one disc at a time: it runs
  `chdman createcd` into the session's scratch directory, runs `chd-verify`
  and `verify --chd` against that one pair, then deletes the `.chd` before
  starting the next disc. It deletes on failure too (the failing disc's name is
  enough to reproduce), refuses to start with less than 2 GB free, and only
  ever deletes the file it created in that run. `games/grandtheftauto.chd` is
  the user's and is never touched.

### macOS app

- `Info.plist`: a third `CFBundleDocumentTypes` entry, `chd`, named
  "PlayStation CHD Image", role Viewer, rank Default.
- `GameScanner` scans `.chd`. A `.chd` and a `.cue` with the same stem in the
  same folder are one game, the cue, so a conversion that kept the originals
  does not show the game twice. Two copies under different names or folders
  still show as two tiles, exactly as two `.cue` copies do today. Deduplicating
  on serial is rejected because some multi-disc sets reuse one serial on every
  disc, and a wrong merge hides a disc.
- **Resume states and covers are already shared between the two formats.**
  `ResumeStateStore.key` and `CoverStore` key on the disc's serial (the path
  only when there is none), and the core's savestate identity is the original
  BIOS hash plus the serial (`savestate.zig`'s `identityOf`). A `.chd` reads
  back the same sectors, so it identifies to the same serial: a state saved
  from the `.cue` resumes from the `.chd` and vice versa. Memory cards were
  never per-disc. A Swift test pins the shared key.
- `GameEntry.isCue` becomes a computed `kind: DiscKind` (`.cue`, `.bin`,
  `.chd`), read off the extension. The raw-`.bin` warning shows for `.bin`
  alone. A `.bin` with a same-stem `.chd` beside it is suppressed too.
- Load and swap read the `.chd` exactly as they read a lone `.bin`, and
  identification maps it as it maps a `.bin`; each passes it as `bin` with no
  cue.
- `PS1_ERR_BAD_CHD` reaches the existing load-error dialog as "This CHD was
  made by an old chdman or depends on a parent image. Re-create it with
  `chdman createcd`."
- Wording: the open panel, `LibraryView`'s empty state and `OnboardingView`
  name `.chd`.
- Multi-disc grouping (filename) and covers (serial) need nothing.

## Testing

Unit tests in `ps1-core/tests/chd_test.zig`, added to `unit_test_files`:

- **FLAC**: fixtures encoded with Homebrew's `flac` (silence, a ramp, noise, a
  correlated stereo tone) committed as bare frames with their expected PCM.
  These force constant, fixed, verbatim/escape, LPC and each stereo mode. The
  decoder must match every sample.
- **ECC**: a real Mode 1 frame with its sync and P/Q zeroed regenerates to
  the original bytes.
- **Codecs**: four small `.chd` files made with `chdman createcd -c <codec>`
  (`cdzl`, `cdlz`, `cdzs`, `cdfl`) from one synthetic cue (a short data track
  plus a short audio track with a stored pregap), committed beside their
  `.bin`, a few hundred KB in all. Each must read back identical to the `.bin`.
- **Refusals**: a v4 header, a parent CHD, an unknown codec tag and a
  corrupted map each fail `open` with the right error, and a corrupted hunk
  fails its read only.
- **`Disc`**: a `Disc` over a CHD reports the same tracks, lead-out,
  subchannel Q and LibCrypt answers as one over the matching `.bin`/`.cue`.

Whole-disc gates (run `-Doptimize=ReleaseFast`):

- **`trace-golden -- chd-verify --cue=<path> --chd=<path>`**: for that one
  pair, every sector from LBA 0 to lead-out, the track table, the lead-out and
  the identity must match. `tools/chd-roundtrip.sh` is what iterates over
  `games/`.
- **`trace-golden -- verify --cue=<path> --chd=<path>`**: the workload whose
  `.cue` is `--cue` boots from the `.chd` instead, and its existing golden must
  verify unchanged. A cue that is not a verify workload (multi-FILE, or a
  folder with two cues) says so and exits 0: the sector gate above already
  covered it, and there is no golden to boot against.
- **`ps1-bench --chd`**: a check, not a gate. One hunk is 8 sectors, about
  54 ms of a 2x read. Measured (interleaved, Croc, 3000 frames): CHD is ~4%
  slower than the cue, all of it LZMA decode in `std.compress.lzma`.

C ABI: `capi_test` loads, swaps and identifies a committed codec fixture, and
identification of the `.chd` must equal identification of its `.bin`.

App: Swift tests for `GameScanner`'s same-stem rule and `.chd` pickup, for
`DiscKind` (no raw-`.bin` warning on a `.chd`), and for the shared resume key. GTA boots with music in `zig-out/Substation.app` as
the manual check.

## Documentation

- `ps1-cdrom-disc` gains a CHD section: the three traps (padding, unstored
  pregaps, big-endian audio), ECC regeneration, why subcode is skipped, the
  refusals, and the two gates.
- CLAUDE.md: `chd-verify` and `verify --chd` in the command table, `chd/` in
  the repository layout, `chd_test` in the unit test list (24 test binaries).
- Tooling prerequisites: `brew install rom-tools flac`, needed only to make
  the committed fixtures and to run `tools/chd-roundtrip.sh`, never to build
  or test.
