# Multi-file discs without concatenation

Status: design, awaiting review. Independent of Spec A
(`2026-10-07-bios-fast-boot-design.md`).

## Goal

A cue sheet may split a disc across several `.bin` files (one per track is
common: Rayman has 51). `Disc` holds ONE data slice, so today every frontend
that loads such a rip concatenates the files into a fresh buffer and rewrites
the cue with a `REM FILESIZE` line before each `FILE`, the only record left of
where the seams were. Teach `Disc` to hold the files as they are.

Not a player-visible feature: these rips already play in the app and in wasm.
What it buys:

1. **Memory.** The concatenated copy is a full-size anonymous allocation, up
   to ~700 MB, made on every boot of a multi-file rip. The files are already
   memory-mapped (`EmulatorViewModel.discImage(forCue:)`) or read; the copy
   goes, and the core reads each sector from the file that holds it.
2. **One layout rule instead of three.** The concatenation exists today in
   `EmulatorViewModel.swift:1528` (Swift), `ps1-wasm/www/index.html:270`
   (JavaScript) and `ps1-trace/src/main.zig:122` (`loadCue`, Zig). The
   `REM FILESIZE` convention, `cueFilesAreLaidOut`, `countCueFiles` and
   `PS1_ERR_MULTI_FILE_CUE` exist only to support it.
3. **Golden coverage.** `ps1-golden` skips any cue with more than one `FILE`
   (`golden.zig:266`), so six discs in `games/` have never been gated:
   Castlevania SotN (2 files), Doom EU (8), Rayman EU (51), Tekken (28),
   Tekken 3 (3), Tetris Plus (52). After this they load like any other disc.

DuckStation reads multi-file rips the same way: one open file per `FILE`
line, each sector read from the file that holds it
(`duckstation_ref/src/util/cd_image_cue.cpp:156`, `:592-649`). It never
concatenates.

Non-goals: CHD/ECM/compressed images, reading files on demand from the host
(every frontend still hands the core the whole of each file, mapped or read),
any change to how a single-file rip loads.

## Core: `ps1-core/src/disc.zig`

```zig
pub const max_files = 99; // a FILE holds at least one TRACK; a disc has <= 99

pub const Disc = struct {
    files: [max_files][]const u8 = undefined,
    /// Absolute LBA at which each file begins.
    file_lba: [max_files]i32 = undefined,
    file_count: u8 = 0,
    sbi: []const u8 = &.{},
    tracks: [99]Track = undefined,
    track_count: u8 = 0,

    pub fn init(data: []const u8) Disc;                       // one file, one data track
    pub fn initFromCue(cue_text: []const u8, files: []const []const u8) !Disc;
    pub fn sectorCount(self: Disc) i32;                       // replaces data.len / 2352
    ...
};

/// The quoted image name of each FILE line, in cue order. The one cue parser
/// the Zig frontends use to find the files they must read.
pub fn cueFileNames(cue_text: []const u8) CueFileIterator;
```

- **Layout.** File `i` begins at the sum of `files[0..i].len / 2352`, which is
  exactly where `REM FILESIZE` placed it (`@divTrunc` of the same byte count),
  so the absolute LBA of every track is unchanged. `INDEX` times stay relative
  to their file, as now.
- **`initFromCue` returns an error** when the number of `FILE` lines is not
  `files.len`, or is zero with a non-empty `files` list, instead of the silent
  stacking the old path guarded against with `cueFilesAreLaidOut`. A cue with
  no `TRACK` keeps today's fallback to a single data track.
- **`readSector2352`** finds the file whose range holds `lba` by a linear scan
  of `file_lba` (at most 99 entries, and almost always one) and copies the
  2352 bytes from it. A sector past the end of its file is `false`, as a
  sector past the end of `data` is now. No sector straddles two files, by
  construction of the layout.
- `leadOut` uses `sectorCount()`.
- **Removed:** `REM FILESIZE` parsing in `initFromCue`, `countCueFiles`,
  `cueFilesAreLaidOut`. `Disc` stays a value type: 99 slices plus 99 LBAs is
  about 2 KB, copied only on load.
- `discid.identify` reads through `readSector2352`, so it needs no change.
  Savestates record the disc's serial, not its bytes: no format change.

## C ABI (`ps1-capi`)

```c
typedef struct {
    const uint8_t* bytes;
    size_t         len;
} Ps1DiscFile;

int32_t ps1_load_disc(Ps1*, const Ps1DiscFile* files, size_t file_count,
                            const uint8_t* cue, size_t cue_len,
                            const uint8_t* sbi, size_t sbi_len);
int32_t ps1_swap_disc(Ps1*, const Ps1DiscFile* files, size_t file_count,
                            const uint8_t* cue, size_t cue_len,
                            const uint8_t* sbi, size_t sbi_len);
```

- **Borrow contract, per file:** every `bytes` buffer must outlive the handle
  or the next load/swap, exactly as `bin` does today. The `Ps1DiscFile` array
  itself is copied into the handle and need not be retained.
- `files` are in cue order. With `cue_len == 0` exactly one file is required
  (the raw-`.bin` fallback, unchanged).
- `PS1_ERR_MULTI_FILE_CUE` (`-3`) is renamed
  `PS1_ERR_CUE_FILE_COUNT`: the number of files passed does not match the
  cue's `FILE` lines. The value is kept so no code is reused for a different
  meaning.
- `ps1_identify_disc` keeps taking one buffer: identification only ever reads
  the track-1 image, which the caller already passes alone.
- `Handle` holds `[max_files]` slices for the disc; the `Disc` borrows them.

## Frontends

Each frontend still finds and reads its files (that is I/O, and stays per
host); none of them lays them out any more.

- **macOS app:** `discImage(forCue:)` returns `[Data]` (each mapped, as now)
  and the cue text unmodified. The runner keeps the array alive for as long
  as it would have kept the concatenated `Data`. `CueSheet` is unchanged.
- **wasm:** `allocCdBuffer(size)` becomes `allocDiscFile(index, size)`; the
  JavaScript reads each referenced `.bin` into its own buffer and stops
  emitting `REM FILESIZE`. `loadCdFromBuffer` builds the file list.
- **ps1-trace:** `loadCue` reads each file into its own allocation via
  `disc.cueFileNames` and drops its FILESIZE pass.
- **ps1-golden:** drops the `countCueFiles` skip and loads every file of the
  cue via `disc.cueFileNames`.
- **ps1-bench / ps1-debug:** move to the new `initFromCue` signature; no
  behaviour change.

## The six new goldens

Once `ps1-golden` loads them, `verify` exits non-zero for each of the six
discs because they have no golden (a known, non-regression failure). Their
goldens are captured in **their own commit** after the core change, with the
reason stated in `ps1-test-harnesses`: new coverage, not a behaviour change.
Before capturing, each disc is checked to reach the same scene as before
through `ps1-trace` with the concatenated image (the last commit before the
change), so the first golden records today's behaviour rather than a bug the
change introduced.

Expected cost: six more workloads in every `verify`, `stream-verify`,
`savestate` and `pgxp` run. The time added is measured and recorded in the
skill; if it is out of proportion, the workloads that duplicate an existing
code path (two Tekkens) are the first candidates to trim.

## Testing

- `disc_test.zig`:
  - **Equivalence.** A synthetic three-file disc (one data file, two audio
    files, odd sizes included) loaded through the new path returns, for every
    LBA and every track start, exactly what the old concatenated +
    `REM FILESIZE` layout returned. The old layout is computed inside the test
    from the same bytes; it is the reference and nothing else uses it.
  - A file-count mismatch is an error; a cue-less single file is the
    fallback; a sector read past the last file is `false`.
- `capi_test`: the two multi-file tests move to `Ps1DiscFile` arrays and lose
  their `REM FILESIZE` lines; a count mismatch returns
  `PS1_ERR_CUE_FILE_COUNT`.
- Swift: the existing `discImage(forCue:)` tests assert a `[Data]` and an
  unmodified cue.
- Gates: `zig build test`, `trace-golden -- verify` (existing nine goldens unchanged),
  then the six new goldens, `ps1-macos/test.sh`, and a manual boot of Tekken 3
  in the app and in wasm.

## Docs

CLAUDE.md and `ps1-cdrom-disc`: the `Disc` line in the layout, the C ABI
note, and `ps1-test-harnesses`' list of gated discs. The capi `ps1.h` comment
on `ps1_load_disc` loses its concatenation paragraph.
