# Hard disc formats (`.pbp`, `.mds`/`.mdf`): design

Project 3 of 4 in the DuckStation format-parity work (order agreed 2026-10-30,
see `2026-10-30-exe-boot-design.md`): executables → easy disc formats →
**hard disc formats** → PSF music player.

## Intent

DuckStation parity, as before: "opens whatever DuckStation opens, the way
DuckStation opens it", with no particular rip in mind (owner, 2026-10-31).
DuckStation is read for behaviour only (`util/cd_image_pbp.cpp`,
`util/cd_image_mds.cpp`, the sub-image calls in `core/system.cpp` and
`core/game_list.cpp`), never ported, and never named in code or commits.

One deliberate step past parity, the owner's call: LibCrypt is read from an
`.mdf`'s own subchannel, as it already is from a CloneCD `.sub`.

## What DuckStation does (the behaviour to match)

### `.pbp` (a PSP "EBOOT" holding a PS1 disc)

- Header `\0PBP`, a version, then eight u32 offsets: `PARAM.SFO`, four PNGs,
  `SND0.AT3`, `DATA.PSP`, `DATA.PSAR`. Only `PARAM.SFO` and `DATA.PSAR` are
  read.
- `PARAM.SFO`: `\0PSF`, version, key-table offset, data-table offset, entry
  count (refused above 16384), then 16-byte index entries. Values are
  NUL-terminated UTF-8 (type `0x0204`) or u32 (`0x0404`); any other type is
  refused. The file is a PS1 eboot only if `BOOTABLE` is u32 `1` and
  `CATEGORY` is the string `"ME"`; anything else is refused.
- At `DATA.PSAR`: the 16 bytes `PSTITLEIMG000000` mean multi-disc. Five u32
  disc offsets at PSAR+0x200, relative to PSAR, zero-terminated (≥1 required).
  Otherwise one disc at PSAR itself.
- Each disc: magic `PSISOIMG0000`; `\0PGD` at +0x400 (or as the first
  multi-disc table entry) means **encrypted: refused** with its own message.
  A 102-entry TOC of 10-byte records at +0x800 (type, ?, point, pregap MSF,
  0, user-data MSF; all BCD); the compressed-image offset as u32 at +0xBFC;
  a block table of 32256 32-byte entries at +0x4000 (u32 offset relative to
  disc+image offset, u16 size, the rest ignored).
- TOC entries 0..2 must be points `A0`, `A1`, `A2`. First track (A0's minute)
  must be 1; last track is A1's minute; A2's user-data MSF is the sector count
  on file. Track N is entry N+2; type `0x01` is audio, anything else data,
  read raw (the sector's own mode byte decides). Track 1's pregap is not on
  file (and is added to the length); every later pregap is. A track whose
  user data starts before its pregap is accepted only for a DATA track 1
  (pregap assumed off file); otherwise refused. A track whose own point
  disagrees with its number is only warned about; what refuses is the NEXT
  entry being misnumbered or starting before this track's user data, so in
  practice only the last track's point goes unchecked. The last track ends at
  the sector count (with track 1's pregap added) and must be non-empty.
- A block is 16 raw sectors (37632 bytes), raw deflate (no header). A block
  whose stored size equals 37632 is uncompressed. A block of size 0 is
  unreadable. One decompressed block is cached.
- Audio tracks live in the same block stream (the homebrew layout; the
  separate audio-track table official eboots carry is not read).
- A multi-disc eboot is ONE game: a playlist entry in the list, Change Disc
  lists its discs titled `"<TITLE> (Disc N)"` from the SFO `TITLE`, and a
  savestate records which disc was in.

### `.mds` + `.mdf` (Alcohol 120%)

- `.mds` starts `MEDIA DESCRIPTOR`; the `.mdf` is found by replacing the
  extension. Session block offset u32 at 0x50; within it, track count u16 at
  +14 (≤99) and track-block offset u32 at +20. Only that first session is
  read.
- 80-byte track entries: entries with point ≥ `A0` are skipped, then one per
  track; each must carry its own BCD track number in order. Type `0xA9` is
  audio, anything else data read raw. A non-zero subchannel byte means
  2448-byte sectors on file (2352 + 96 subchannel), else 2352. The one mode
  Alcohol writes is `0x08`, which libmirage's MDS parser documents as "96-byte
  PW subchannel, interleaved": raw P..W, one bit of each channel per byte,
  NOT the deinterleaved layout of a CloneCD `.sub`.
- Per track: start MSF (BCD), an "extra" offset to two u32 (pregap, length),
  and the track's byte offset in the `.mdf`. Track 1's pregap is not on file;
  a later track's is, and its data follows it. A pregap larger than the start
  LBA is refused.
- Lead-out = last track's start + length. DuckStation discards the
  subchannel on read.

## Goals

1. The core, the C ABI, the session, the native harnesses and the browser
   package open a `.pbp` (any disc of it) and a `.mds`+`.mdf` with the same
   drive, identification, `.sbi`/`.ppf` handling and swap as a `.bin`/`.cue`.
2. The macOS app lists, opens (Open Disc, Finder, Open Recent, the library),
   identifies and swaps both; a multi-disc `.pbp` is ONE multi-disc game
   whose Change Disc lists its discs, exactly as an `.m3u` is.
3. A `.mdf` with subchannel supplies LibCrypt protection on its own, with no
   `.sbi`.
4. An encrypted eboot is refused with a message that says so, never
   mis-read.
5. No trace golden moves, and nothing any existing format does changes.

## Non-goals

- Decrypting eboots (`\0PGD`). Not now, not later: it means breaking Sony's
  encryption.
- The official-eboot audio-track table; multi-session `.mds` beyond session
  one; split `.mdf` (`.mdf.00`, …); MDS v2 / `.mdx` (Daemon Tools); a
  cooked-sector `.mdf`. All refused or read as DuckStation reads them.
- Using the eboot's `ICON0.PNG`, or its `TITLE` as a library title. `TITLE`
  names the discs in Change Disc only (owner's call: as DuckStation does).
- Subchannel other than Q's CRC from a `.mdf` (positions are generated, as
  for every format).
- Disc swap in the browser package: it has none for any format.

## Decisions

### Where it lives (as the easy formats)

Bytes to sectors in the **core**, behind the existing load/swap/identify
paths, so every frontend gets it at once. `disc_image.zig` sniffs:

| Slot  | Content                    | Meaning                                       |
| ----- | -------------------------- | --------------------------------------------- |
| `bin` | `\0PBP`                    | an eboot; `cue` must be empty                 |
| `cue` | starts `MEDIA DESCRIPTOR`  | an Alcohol sheet; `bin` is its `.mdf`         |

New codes, mirrored in `ps1-wasm/src/codes.zig` and `ps1-web/src/errors.ts`:
`PS1_ERR_BAD_PBP` (anything above that refuses, including "not a PS1 eboot"
and a disc index past the last disc), `PS1_ERR_ENCRYPTED_PBP` (its own code
so the app can say why), `PS1_ERR_BAD_MDS` (bad signature, offsets out of
range, misnumbered tracks, a pregap past its start, an `.mdf` shorter than
the last track needs).

A lone `.mdf` (no `.mds`) is sniffed as any lone image is: one stored
without subchannel boots as a flat 2352 image, which is what it is. One
stored with subchannel does not divide into 2352-byte sectors cleanly and is
not a valid lone image; the app never offers an `.mdf` as a game (below), so
this reaches only a frontend handed the file directly, and no rule is added
for it.

### Choosing a disc inside one file (the one ABI change)

A `.pbp` holds up to five discs in one buffer, so the disc's position in its
image has to cross the ABI. `ps1_load_disc`, `ps1_swap_disc`, `Ps1DiscBytes`
and `ps1-wasm`'s `loadDisc` gain a zero-based **disc index**. It must be 0 for
every other format (`PS1_ERR_BAD_CUE` otherwise: there is no general
invalid-argument code, and the image cannot be what was asked for); for an
eboot, past the last disc is `PS1_ERR_BAD_PBP`.

A library scan needs the count and the per-disc serial: `ps1_identify_disc`
identifies disc 0 of a lone image as today, and a new call takes the image,
**an optional sheet** and a disc index, and returns the number of discs (1 for
every non-eboot) and identifies disc N. The sheet is needed for `.mds`: a
`.mdf` stored with subchannel is 2448 bytes a sector, which no lone-image
sniff reads, and without the sheet every such disc would list with no
serial, so no cover, grouping or resume (my call). `DiscIdentity.swift`, the
wasm export and `ps1-web`'s `identifyDisc` carry the sheet. Shape and names
are the builder's; `Ps1DiscId` itself does not change (callers allocate it).

The savestate identity is unchanged: it hashes the BIOS, the serial of the
disc in the drive and the PPF fingerprint, and each disc of an eboot has its
own serial.

### The sector model (my call; the builder may restructure)

- `pbp.zig`: a `Reader` over the BORROWED file, owned by the handle as
  `chd.Reader`/`ecm.Reader` are (a new `Decoder` case), holding the SFO
  values needed (`TITLE`, the two checks), the disc offsets, and for the open
  disc its block table and one cached block. `Disc.Source` gains a `pbp`
  variant; a read finds the block, inflates it with `std.compress.flate`
  (raw container), copies 2352 bytes. A swap to another disc of the same file
  opens a new reader (or reopens it) behind the same tray sequence as any
  swap. The block table is NOT copied: it lies in the borrowed file at disc
  +0x4000, 32 bytes an entry, and a read looks its entry up in place. The
  reader owns only the inflate state and one 37632-byte block, which keeps
  the identify call as light as `ps1.h` promises.
- `mds.zig`: a parser like `ccd.zig`, producing a track table over a `flat`
  source with a per-track file stride (2352 or 2448) and offset. The flat
  source may need a stride field; today it assumes 2352.
- **LibCrypt from the `.mdf` (owner's call)**: when any data track carries
  subchannel, the core scans every sector's 96 bytes once at load and keeps,
  as `.sbi`-equivalent records, the sectors whose Q fails its CRC-16: the same
  records a `.sub` produces. Q is first DEINTERLEAVED from the 96 bytes
  (bit 6 of each byte, 12 bytes of Q); after that the CRC check and record
  building are `ccd.zig`'s, shared rather than copied. The `.mdf`
  is the image, so nothing extra is retained. If the image's subchannel
  yields at least one record, those win and a passed `.sbi` is ignored (the
  rip's own data). If it yields none, or the image has no subchannel, a
  passed `.sbi` applies as for any image (my call). Many Alcohol dumps store
  regenerated Q with no broken CRCs at all, and discarding a correct `.sbi`
  then would fail a LibCrypt check that works today. A unit test pins the
  fallback.
- **The subchannel layout is settled from libmirage, not from our round
  trip**: interleaved P..W (mode `0x08`). The round trip cannot check it,
  because our writer and reader share the layout, so a unit test pins the
  deinterleave against a hand-built sector whose Q is known, and a real
  Alcohol dump in the hand check is the confirmation.

### Behaviour the builder must keep

- The TOC's pregap rules exactly as above, including track 1's pregap being
  off file in both formats. Getting this wrong desynchronises every later
  track, the same trap the CHD pregap rule records.
- The cdrom side changes nothing: raw sectors, mode byte decides 010h/018h.
- File and track offsets in both formats are u32: a file over 4 GB cannot be
  one of these, and the parser must refuse rather than wrap.
- Every refusal frees what it allocated (`disc_image.open`'s contract).

### macOS app

- `DiscKind` gains `pbp` and `mds`. `.mdf` is not a game (a sidecar of its
  `.mds`, as `.img` is of a `.ccd`); `.mds` wins over the `.mdf` of its stem.
  Precedence for one stem extends to: cue > chd > ccd > mds > pbp > ecm >
  iso/img/bin (my call).
- `Info.plist` declares `pbp` and `mds`, Alternate, like the others.
- A multi-disc `.pbp` is one game, modelled the way `Playlist` is: its sibling
  set is (file, index) pairs in disc order, Change Disc titles them
  `"<TITLE> (Disc N)"` (falling back to "Disc N" with no `TITLE`), the resume
  offer's disc pick and the Multi-Disc collection follow it, and its states
  are keyed as its first disc, as a playlist's are. A disc ref that today is a
  URL becomes URL + index; how that threads through `GameEntry`, `OpenGame`
  and `GameSwitch` is the builder's, keeping path identity canonical
  (`reference-macos-path-identity`).
- An `.m3u` may name a `.pbp`; it then means that file's first disc (my
  call; a playlist line has no way to name disc N).
- `.sbi`/`.ppf` beside a `.pbp` or `.mds` are found by stem as for any image.
  For a multi-disc `.pbp` (one file, one stem):
  - the `.sbi` applies to whichever disc is in, matching DuckStation's lookup
    by path; records name sectors and refuse nothing;
  - the `.ppf` applies to **disc 1 only** (my call). A patch is made against
    one disc's sectors: on another disc it is either refused
    (`PS1_ERR_PPF_MISMATCH`, so the swap fails) or, for a PPF1/2 with no
    checks, silently patches the wrong sectors. Discs 2+ boot unpatched. The
    session, the app and the harnesses pass no patch on a swap to them.
- Errors through `apple-design-guidelines`; the encrypted one says the file
  is a protected PSN download that cannot be played.

### Browser package

`discFromFiles` recognises a `.pbp`, and a `.mds` with its `.mdf`.
Preference when several are present extends today's order (… `.ccd`, `.mds`,
`.pbp`, `.ecm`, `.iso`/`.img`, `.bin`; my call). `loadDisc` takes the
optional disc index (default 0); with no swap in the browser, a page picks one
disc to boot.

## Gates

- **Unit tests** (`zig build test`): SFO parse and each eboot refusal
  (not ME, not bootable, bad magic, PGD in either place, bad TOC points, index
  past the last disc); block decode of stored and deflated blocks;
  the pregap rules for both formats; MDS parse of hand-built sheets and each
  refusal; `.mdf` subchannel to records equal to the `.sbi`'s.
- **`image-write --format=pbp|mds`** in `ps1-golden/src/image_write.zig`, with
  a real deflate via `std.compress.flate` for `.pbp` (not only stored blocks,
  or inflate goes untested), and `.mds`+`.mdf` written with subchannel (the
  `.sbi`'s sectors given a broken Q CRC) and without. `--multi=<cue,cue,…>`
  (or equivalent) writes a multi-disc eboot from several cues.
- **`image-verify` / `verify --image`** take both and must match every
  sector, the track table, the identity and the UNCHANGED golden;
  `tools/format-roundtrip.sh` gains both formats. For FF9 PAL, the
  `.mdf`-derived records must equal the `.sbi`'s.
- **App**: Swift tests for `DiscKind`, scanner precedence (`.mds` over
  `.mdf`), the eboot-as-playlist sibling set and its titles, an `.m3u` naming
  a `.pbp`; `ps1-macos/test.sh` green.
- **Browser**: `bun test` with the new `discFromFiles` cases and the index.
- **Hand check (owner's call: the round trip is the automated gate, real
  files are the hand check)**: at least one `.pbp` made by a real converter
  (popstation-style), ideally multi-disc, booted and swapped in the app; and
  a real Alcohol `.mds`/`.mdf` if one can be had, preferably a LibCrypt title
  dumped with subchannel. What the hand check found, and what it could not
  cover, is recorded in `ps1-cdrom-disc`.

## Left to the builder

File and type names, the ABI spelling of the disc index and the count call,
whether `flat` gains a stride or `.mds` gets its own source variant, how the
reader caches a block, how `image-verify` drives a multi-disc eboot, and the
wording of app errors (through `apple-design-guidelines`).
