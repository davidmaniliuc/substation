# Easy disc formats (`.iso`/`.img`, `.ccd`, `.ecm`, `.m3u`): design

Project 2 of 4 in the DuckStation format-parity work (order agreed 2026-10-30,
see `2026-10-30-exe-boot-design.md`): executables → **easy disc formats** →
hard disc formats (`.pbp`, `.mds`) → PSF music player.

## Intent

DuckStation parity. DuckStation's `System::IsDiscPath` accepts `.bin .cue .img
.iso .chd .ecm .mds .pbp .ccd .m3u`; we accept `.bin .cue .chd`. This project
closes the four "easy" ones. As with executables, the owner has no particular
rip in mind: the bar is "opens whatever DuckStation opens, the way DuckStation
opens it". DuckStation is read for behaviour only (`util/cd_image.cpp`,
`cd_image_cue.cpp`, `cd_image_ccd.cpp`, `cd_image_m3u.cpp`), never ported, and
never named in code or commits.

## What DuckStation does (the behaviour to match)

- **Lone image (`.bin`, `.img`, `.iso`)**: one track, mode sniffed from the
  file (`DetectSingleFileTrackMode`): a sync pattern at offset 0, mode byte 1
  or 2 and a size that is a multiple of 2352 → raw Mode 1/Mode 2; a multiple of
  2352 with no sync → one Audio track; anything else → **cooked Mode 1, 2048
  bytes a sector**. A cooked sector is dressed into a raw one on read
  (`ConvertSectorToRaw`): sync, BCD MSF header, mode byte 1, user data at 010h,
  EDC, zeroed intermediate, P/Q ECC.
- **Cue track modes**: cue sheets may name `MODE1/2048`, `MODE2/2336`,
  `MODE2/2048` (Form 1), `MODE2/2324` (Form 2) and `MODE2/2332`, each dressed
  the same way. Sizes per mode: 2352, 2048, 2352, 2336, 2048, 2324, 2332, 2352.
- **`.ecm`**: a `.bin` with sync, headers, EDC and ECC stripped. File magic
  `ECM\0`, then a stream of chunk headers (2-bit type, variable-length count,
  `0xFFFFFFFF` terminates), each followed by `count` records of that type:
  type 0 raw bytes, type 1 Mode 1 (3-byte address + 2048 data), type 2
  Mode 2 Form 1 (4-byte subheader + 2048), type 3 Mode 2 Form 2 (4-byte
  subheader + 2324). DuckStation indexes the chunks once at open and decodes
  sector by sector on read. It handles `.ecm` both opened directly and named as
  a cue `FILE`.
- **`.ccd` (CloneCD)**: an INI-style control file beside a raw `.img`
  (2352/sector, same stem) and an optional `.sub` (96 bytes/sector,
  deinterleaved P..W, Q at +12). Requires `[CloneCD]` and `[Disc]`
  (`TocEntries` ≥ 3). Tracks come from `[Entry N]` (`Point` 1..99, `Control`,
  `PLBA`; point `0xA2` is the lead-out, else lead-out = img size / 2352) refined
  by `[TRACK N]` (`MODE` 0/1/2, `INDEX 0`, `INDEX 1`). Track 1 with no
  `INDEX 0` gets the implicit 150-sector pregap. Tracks must start at 1 and be
  contiguous. Subchannel Q is served from the `.sub` when present: this is how
  a CloneCD rip carries LibCrypt without a `.sbi`.
- **`.m3u`**: a text list of disc paths, one per line, `#` comments, relative
  to the playlist. It is one game; disc 1 boots, and `System > Change Disc`
  lists the playlist's entries (titled by file stem). Each entry may be any
  disc format, `.m3u` excepted in practice.

## Goals

1. The core, the C ABI, the session, the native harnesses **and the browser
   package** open a lone `.iso`/`.img`, a cue with cooked tracks, a `.ccd`
   (+`.img`, +optional `.sub`) and an `.ecm` with the same drive,
   identification, `.sbi`/`.ppf` handling and disc swap as a `.bin`/`.cue`.
2. A CloneCD `.sub` supplies LibCrypt protection on its own: Final Fantasy IX
   (PAL) as a `.ccd`+`.img`+`.sub` with no `.sbi` passes its check.
3. The macOS app lists, opens (Open Disc, Finder, Open Recent, the library),
   identifies and swaps to every one of these, and treats an `.m3u` as ONE
   multi-disc game whose Change Disc list is the playlist.
4. No trace golden moves. Nothing a `.bin`/`.cue`/`.chd` does today changes,
   with the one deliberate exception under "Behaviour change" below.

## Non-goals

- `.pbp`, `.mds` (project 3), PSF (project 4).
- `.m3u` in the core, the C ABI, `ps1-wasm` or `ps1-web`. A playlist is a list
  of host file paths; the browser has no paths. (Owner's call, see below.)
- Cooked tracks in a cue with more than one track or more than one `FILE`.
  PS1 cooked rips are single data-track `.iso`s in practice; multi-track
  cooked cues are refused, not mis-laid-out.
- An `.ecm` named by a cue with more than one `FILE`. Refused.
- Reading P or R..W subchannel from `.sub`; only Q matters to the drive.
- Writing or converting any of these formats.
- Recovering Mode 2 Form 2 data from a `.iso`. A cooked rip lost it (XA audio,
  STR movie sectors); such a disc plays exactly as badly as on DuckStation.

## Decisions

### Where each format lives (decided in this design)

Anything that turns bytes into sectors goes in the **core**, behind the
existing `ps1_load_disc`/`ps1_swap_disc`/`ps1_identify_disc` slots, exactly as
CHD did. That is what gives the harnesses, the session and the browser the
formats for free and keeps one implementation. `.m3u` stays in the **app**:
it holds no sectors, the core already swaps discs, and the app already owns
multi-disc grouping and Change Disc.

### No new C ABI entry points; the existing slots sniff by content

`ps1_load_disc(bin, cue, sbi, ppf)` already sniffs `bin` for `MComprHD`. It
now also sniffs:

| Slot  | Content                         | Meaning                                    |
| ----- | ------------------------------- | ------------------------------------------ |
| `bin` | `ECM\0`                         | an ECM image, decoded on demand            |
| `bin` | no cue, sniff per DuckStation   | raw Mode 1/2, one Audio track, or cooked   |
| `cue` | contains a `[CloneCD]` section  | a CloneCD control file; `bin` is its `.img`|
| `sbi` | `SBI\0`                         | a LibCrypt sidecar, as today               |
| `sbi` | no magic, sheet is CloneCD, length a multiple of 96 | a CloneCD `.sub`         |

A `.sub` passed with anything but a CloneCD sheet stays `PS1_ERR_BAD_SBI`, as
a non-`SBI\0` buffer is today. `ps1_identify_disc(bin)` gains the `ECM\0` and
cooked sniffing, so a library scan identifies `.iso` and `.ecm` from the image
alone; a `.ccd`'s `.img` is raw and already identifies.

New error codes, mirrored in `ps1-wasm/src/codes.zig` and
`ps1-web/src/errors.ts` per the browser rule: `PS1_ERR_BAD_ECM` (bad magic,
truncated or corrupt chunk stream, misaligned length), `PS1_ERR_BAD_CCD`
(missing sections, no track 1, a gap in track numbers, an invalid track
length, an `.img` shorter than the lead-out). A cue that names a cooked mode
on more than one track or `FILE`, or names an `.ecm` among several `FILE`s, is
`PS1_ERR_BAD_CUE`.

### `.sub` becomes LibCrypt records at load (my call)

The drive already models LibCrypt one way: a sector listed in the `.sbi` has
a broken-CRC Q and `GetlocP` drops it (`Disc.isLibCryptSector`). Rather than
add a second Q path, the core scans the `.sub` once at load and keeps, as the
same records, every sector whose stored Q fails its CRC-16. The `.sub` is not
retained (it is ~31 MB for a full disc; the records are a few hundred bytes),
which keeps it under the existing "sbi is COPIED" contract. If both a `.sbi`
and a `.sub` exist, the app passes the `.sub` for a `.ccd` (it is the rip's
own data) and the `.sbi` for everything else; the `sbi` slot carries one.

This is behaviourally equal to DuckStation for LibCrypt, which is the only
thing a PS1 game reads Q for beyond position. A `.sub` whose Q disagrees with
our generated Q but has a VALID CRC (non-LibCrypt subcode quirks) is not
reproduced; that is a deliberate gap.

### The sector model (my call; the builder may restructure)

`Disc.Source` gains two variants beside `flat` and `chd`:

- `cooked: { data, mode, sector_bytes }`: one track; `readSector2352` copies
  the user bytes and dresses the sector (the `ConvertSectorToRaw` table
  above). A cue's single cooked track and a sniffed `.iso` both build this.
- `ecm: *ecm.Reader`: owned by the C ABI handle exactly as `chd.Reader` is
  (`h.chd`, closed on replace), built over the BORROWED image. The index is
  built once at open by walking chunk headers (one header per run, so a
  library-scan identify touches few pages); a read seeks the chunk and
  rebuilds sync, header, EDC and ECC.

A `.ccd` builds a `flat` source with a track table from its parser, plus
records from the `.sub`. Sync/header/EDC/ECC generation is shared: the P/Q
ECC already in `chd/cd.zig` moves (or is re-exported) beside a new EDC
routine into one sector-dressing module used by CHD, cooked and ECM.
`disc.zig` is 352 lines; the CloneCD parser and the ECM reader are new files,
keeping every file under the ~600-line rule.

The cdrom side changes nothing: it reads user data at 010h or 018h by the
sector's own mode byte, which a dressed Mode 1 sector sets to 1.

### Behaviour change: a lone `.bin` is sniffed

Today a cue-less `.bin` is always one data track at LBA 0. It now follows the
DuckStation sniff, so a lone 2352-aligned file with no sync is one Audio track
and a non-2352-aligned one is cooked. A real PS1 game `.bin` begins with sync
and is unchanged. Goldens all boot from cues and cannot move.

### `.m3u` in the app (decided by this design, from DuckStation's behaviour)

- `.m3u` is a `DiscKind`; parsing (trim, skip blank and `#` lines, resolve
  relative to the playlist, file-URL canonicalisation as in
  `reference-macos-path-identity`) lives in one Swift type.
- The library shows one tile per playlist, titled and covered from disc 1.
  The discs it names are hidden from the library, so a set never appears twice
  (my call: DuckStation lists both; our grouping already hides siblings).
- A playlist's discs are its sibling set: Change Disc, the resume offer's disc
  pick and the Multi-Disc collection use the playlist order instead of folder
  grouping. Folder grouping is unchanged for discs no playlist names.
- Opening the `.m3u` boots its first entry. An entry that is missing or fails
  to load is reported by name; the others stay swappable.
- An entry may be any disc format this app opens, including `.chd`, `.ccd`,
  `.ecm`; an `.m3u` naming an `.m3u` or an executable is refused.

### App file handling

- `Info.plist` declares `iso`, `img`, `ccd`, `ecm`, `m3u` (and `sub` is NOT
  declared; it is a sidecar). All **Alternate**, like `.bin`, so Substation
  claims no system-wide `.iso`/`.img` (my call).
- `DiscKind` gains `iso` (`.iso` and a lone `.img`), `ccd`, `ecm`, `m3u`.
- `GameScanner`: a `.ccd` is a game and wins over the `.img` of its stem; a
  lone `.iso`/`.img` counts like a lone `.bin` (stem not already taken by a
  cue, chd or ccd); an `.ecm` is a game unless a cue in its folder names it;
  a cue naming an `.ecm` `FILE` passes the `.ecm` bytes as `bin`. Precedence
  for one stem: cue > chd > ccd > ecm > iso/img/bin (my call).
- Sidecars (`.sbi`, `.ppf`) for `Game.bin.ecm` are looked up by stem
  `Game.bin` and then `Game` (my call). A `.ccd` passes its `.sub` (stem match)
  in the `sbi` slot.
- The raw-`.bin` "CD-DA will be silent" warning applies only to a lone `.bin`
  or `.img`, not to `.iso` (no audio to lose) and never to `.ccd`.

### Browser package

`ps1-web`'s `discFromFiles` recognises the new sets from a directory pick:
a `.ccd` with its `.img` (+`.sub`), an `.ecm`, a lone `.iso`/`.img`.
Preference when several are present extends the current order (`.chd`, then
the first `.cue`, then `.ccd`, `.ecm`, `.iso`/`.img`, `.bin`; my call). No
`ps1-wasm` export changes; it reaches the same core sniffing.

## Gates

- **Unit tests** (`ps1-core/tests/`, in `zig build test`): the sniff table;
  Mode 1 / Form 1 / Form 2 dressing against sectors cut from a real image
  (EDC and ECC bit-exact); ECM decode of a test-side encoded image equal to
  its source; a CloneCD parse of hand-written sheets (implicit pregap, an
  `INDEX 0` pregap, a missing `A2` lead-out, each refusal); `.sub` to records.
- **`trace-golden -- image-verify --cue=<c> --image=<i> [--sub=<s>]`**,
  generalising `chd-verify`: every sector, the track table and the identity
  match the cue's disc. For a cooked image it compares only what survives
  cooking (Form 1 user data of data sectors) plus identity. `verify --image`
  boots a workload from the converted image and must match its UNCHANGED
  golden, as `verify --chd` does.
- **`tools/format-roundtrip.sh`**, alongside `tools/chd-roundtrip.sh`: for
  each `games/*/*.cue`, writes into a temp dir a `.ccd`/`.img`/`.sub` (the
  `.sub` carrying our generated Q, with the `.sbi`'s sectors given a broken
  CRC), an `.ecm` (via `ecm` from ecm-tools if installed, else a test-side
  encoder) and, for single-track discs, an `.iso`; runs `image-verify` and
  `verify --image`; deletes the copies. Never writes to `games/`. For FF9 PAL
  the `.sub`-derived records must equal the `.sbi`'s.
- **App**: Swift tests for `DiscKind`, the scanner precedence, `.m3u` parsing
  and the playlist-as-siblings rule; `ps1-macos/test.sh` green.
- **Browser**: `cd ps1-web && bun test` with the new `discFromFiles` cases.
- **Hand check**: open one game in each format in the app, swap discs in an
  `.m3u` set, and boot a `.ccd`+`.sub` LibCrypt title with no `.sbi`.

## Left to the builder

File and type names, the ECM index's shape (per run with stride is enough),
whether sector dressing lives in `disc/` or a new sibling, how
`image-verify` shares code with `chd-verify`, and the wording of app errors
(through `apple-design-guidelines`).
