# Hard Disc Formats Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open `.pbp` eboots (any of up to five discs) and Alcohol `.mds`+`.mdf` images everywhere a `.bin`/`.cue` opens today, with LibCrypt read from an `.mdf`'s own subchannel, and a multi-disc eboot as one game in the macOS app.

**Architecture:** Both formats are sniffed by content in `disc_image.open`, as the easy formats are. An eboot is a new `Source.pbp` over a `pbp.Reader` that inflates one 16-sector block at a time from the BORROWED file; an Alcohol image is a parsed track table over a new `Source.strided` (2352 or 2448 bytes a sector). The disc's position inside one file crosses every ABI as a zero-based `disc` index, and a new identify call returns the disc count and the eboot's title. In the app a multi-disc eboot reuses the playlist machinery, with a disc reference widened from a URL to a URL plus an index.

**Tech Stack:** Zig 0.17.0 (`ps1-core`, `ps1-capi`, `ps1-session`, `ps1-wasm`, `ps1-golden`; `std.compress.flate` for both directions), TypeScript/Bun (`ps1-web`), Swift/SwiftUI (`ps1-macos`).

**Spec:** `docs/superpowers/specs/2026-10-31-hard-disc-formats-design.md`

## Global Constraints

- Read DuckStation for behaviour only (`util/cd_image_pbp.cpp`, `util/cd_image_mds.cpp`); never name it in code, comments or commits. Commits are a title line only, one per task, on master, never pushed.
- No file in `ps1-core/src` over ~600 lines. `disc.zig` is 393 today.
- Encrypted eboots (`\0PGD`) are refused, never decrypted.
- New C ABI codes: `PS1_ERR_BAD_PBP (-30)`, `PS1_ERR_ENCRYPTED_PBP (-31)`, `PS1_ERR_BAD_MDS (-32)`. Mirrored in `ps1-wasm/src/codes.zig`, `ps1-web/src/errors.ts`, `ps1-session/src/machine.zig` (`Error` + `codes`), `ps1-macos/Sources/PS1/Ps1Core.swift` (`Ps1Error`) and `EmulatorViewModel.describe`.
- `bin` stays BORROWED (an eboot's reader slices into it; nothing of the block table is copied), the sidecar stays COPIED.
- A non-zero disc index for any non-eboot is `PS1_ERR_BAD_CUE`; past an eboot's last disc is `PS1_ERR_BAD_PBP`.
- A `.ppf` applies to an eboot's disc 0 only: every frontend passes none for disc 1+. A `.sbi` applies to whichever disc is in.
- An `.mdf`'s own LibCrypt records win only when there is at least one; otherwise a passed `.sbi` applies.
- No trace golden moves. `zig build -Doptimize=ReleaseFast && zig build trace-golden -Doptimize=ReleaseFast -- verify` must pass unchanged after every core task.
- App new types `pbp`, `mds` are `Alternate` in `Info.plist`; `.mdf` is not declared. UI copy goes through `apple-design-guidelines`.

## Review Focus

1. **An eboot's track 2+ pregap is ON file, track 1's is not.** A two-track eboot (data + audio with a 150-sector pregap) must read audio sector `start_lba` from file sector `start_lba + 150 - track1_pregap`, never shifted by the pregap. Test in Task 1.
2. **The last block of an eboot is short.** A disc whose sector count is not a multiple of 16 must read its final sector, and a read past `sectorCount` returns false rather than inflating a size-0 block. Test in Task 1.
3. **An `.mdf` with no broken Q beside a `.sbi`**: the `.sbi` must apply (FF9's protection still passes); with one broken Q the `.mdf`'s records win. Test in Task 3.
4. **Swapping between two discs of ONE eboot** reuses the same borrowed buffer: the old reader is closed only after the new one is in, and the swap carries no `.ppf` to disc 1+. Test in Task 4 (`capi_test`).
5. **An `.m3u` naming a `.pbp`, and a `.pbp` whose SFO has no `TITLE`**: the playlist boots disc 0; Change Disc titles fall back to "Disc N". Test in Task 8.

---

### Task 1: Eboot reader

**Files:**
- Create: `ps1-core/src/pbp/pbp.zig` (container, disc table, block read), `ps1-core/src/pbp/sfo.zig` (PARAM.SFO), `ps1-core/src/pbp/toc.zig` (TOC → tracks)
- Modify: `ps1-core/src/disc.zig` (`Source.pbp`, `Disc.initFromPbp`, the `pbp` arms), `ps1-core/src/root.zig` (`pub const pbp = @import("pbp/pbp.zig");`), `ps1-golden/src/image_write.zig` (`encodePbp`), `ps1-core/tests/image_fixtures.zig` (re-export), `build.zig` (`unit_test_files`)
- Test: `ps1-core/tests/pbp_test.zig`

**Interfaces:**
- Produces (`pbp.zig`):
  - `pub fn isPbp(data: []const u8) bool` (`"\x00PBP"` at 0)
  - `pub const Error = error{ OutOfMemory, BadPbp, EncryptedPbp }`
  - `pub fn discCount(data: []const u8) Error!u8` (1..5, no allocation)
  - `pub fn title(data: []const u8) Error![]const u8` (SFO `TITLE`, borrowed, may be empty)
  - `pub const Reader` with `pub fn open(gpa, data: []const u8, index: u8) Error!*Reader`, `close`, `sectorCount(self) i32`, `readSector(self, lba: i32, out: *[2352]u8) bool`, `tracks: [99]disc.Track`, `track_count: u8`.
  - `Disc.initFromPbp(reader) Disc` (copies the reader's track table, as `initFromChd` does).
- Produces (`image_write.zig`): `pub const PbpDisc = struct { raw: []const u8, d: Disc }` and `pub fn encodePbp(gpa, discs: []const PbpDisc, title: []const u8, stored: bool) ![]u8` (`stored = true` writes every block uncompressed; else raw deflate at the default level, falling back to stored for a block that does not shrink).

Layout (all little-endian; every offset and size is u32 and checked against `data.len` before use, so nothing wraps):

| Where | What |
| --- | --- |
| 0x00 | `\0PBP`, u32 version, then 8 u32 offsets; [0] at 0x08 is `PARAM.SFO`, [7] at 0x24 is `DATA.PSAR` |
| SFO | `\0PSF`, version, key-table off, data-table off (both relative to SFO), count (> 16384 refused); entries at +0x14, 16 bytes: u16 key off, u16 type, u32 len, u32 max len, u32 data off. Type 0x0204 = NUL-terminated UTF-8, 0x0404 = u32, any other refused. Requires `BOOTABLE` u32 == 1 and `CATEGORY` == `"ME"`. |
| PSAR | `PSTITLEIMG000000` → multi-disc: five u32 at PSAR+0x200, relative to PSAR, zero-terminated, ≥ 1; else one disc at PSAR. Table entry 0 == `0x44475000` → `EncryptedPbp`. |
| disc | `PSISOIMG0000`; u32 at +0x400 == `0x44475000` → `EncryptedPbp`; TOC at +0x800, 102 × 10 bytes: `type, _, point, pregap m s f, _, user m s f` (BCD); image offset u32 at +0xBFC; block table at +0x4000, 32256 × 32 bytes: u32 offset (relative to disc + image offset), u16 size. |

TOC rules (`toc.zig`, `pub fn tracks(toc: *const [1020]u8, out: *[99]disc.Track) error{BadPbp}!struct { count: u8, sectors: i32, track1_pregap: i32 }`): every BCD byte read is validated (`BadPbp` on a nibble > 9). Entries 0..2 have points A0, A1, A2. `first = A0.user.m` must be 1; `last = A1.user.m` ≥ first. Track N is entry N+2: type 0x01 → `.audio`, else `.data`. Positions come from `MSF.toLba` (our LBA, lead-in removed). If `user < pregap`: allowed only for a data track 1, which then takes `track1_pregap = user + 150` frames; else `BadPbp`. Otherwise `track1_pregap` for track 1 is `user − pregap` frames. `pregap_lba` is null for track 1 and for a track whose pregap equals its start, else the pregap's LBA. A non-last track refuses (`BadPbp`) when entry N+3's point is not N+1 or its pregap starts before this track's user data; a mismatch in a track's own point is accepted. `sectors = A2.user` as raw frames (no lead-in removed) `− 150`, plus track 1's pregap frames only when track 1's user ≥ its pregap; the last track's start must be below it. (Our writer's `A2 = MSF.fromFrames(count)` therefore reads back as `count`.)

Reads: file sector `= lba + 150 − track1_pregap`; block `= sector / 16`; a block of size 0, past the table, or past `data` is a failed read. Size == 37632 → copied; else inflated with `std.compress.flate.Decompress` (`.raw` container) into the reader's one cached block; an inflate error or a short result is a failed read. The reader owns only that block, the flate window and the track table.

- [ ] **Step 1: Write `encodePbp`** to the layout above (PSAR at a 0x10-aligned offset after a minimal SFO with `TITLE`, `CATEGORY "ME"`, `BOOTABLE 1`, `DISC_ID`; per disc: header, zero at +0x400, TOC from `d`'s tracks with A2 = `MSF.fromFrames(sector count)`, image offset 0x100000, the table, the blocks, the last block zero-padded to 16 sectors).
- [ ] **Step 2: Write the failing tests** in `pbp_test.zig`, over `image_fixtures.disc_bin`/`disc_cue` (three tracks, 113 sectors):
  - `"an eboot reads back as its cue's disc"` (both `stored` true and false): `open(…, 0)`, `track_count == 3`, tracks equal `Disc.initFromCue`'s, `sectorCount() == 113`, every `readSector` equals the bin (Review Focus 1: track 2 has a pregap).
  - `"the last short block reads, and past the end does not"`: sector 112 equals the bin; `readSector(113)` false (Review Focus 2).
  - `"a two-disc eboot opens each disc"`: `encodePbp` of the fixture disc twice, the second built from the first 40 sectors only as one data track; `discCount == 2`; `open(…, 1).sectorCount() == 40`; `open(…, 2)` → `BadPbp`.
  - `"refusals"`: `CATEGORY "EG"` → `BadPbp`; `BOOTABLE 0` → `BadPbp`; a disc without `PSISOIMG0000` → `BadPbp`; `0x44475000` at disc+0x400 → `EncryptedPbp`; as multi-disc table entry 0 → `EncryptedPbp`; TOC entry 1 point A0 → `BadPbp`; an SFO type 0x0004 → `BadPbp`; a PSAR offset past the end → `BadPbp`.
  - `"title is the SFO TITLE"`: `"Fixture"`; an SFO without `TITLE` → `""`.
  - `"an eboot disc reads through Disc"`: `Disc.initFromPbp(r).readSector2352(50)` equals the bin.
- [ ] **Step 3: Run** `zig build test`; `pbp_test` fails to compile.
- [ ] **Step 4: Implement** the three files and the `pbp` arms in `Disc.sectorCount`/`readSector2352`.
- [ ] **Step 5: Run** `zig build test`: all pass.
- [ ] **Step 6: Write the shared fixture.** A test `"write the two-disc fixture"` in `pbp_test.zig`, skipped unless `PS1_WRITE_FIXTURES=1`, writes the two-disc eboot above (deflated, `title "Fixture"`) to `ps1-core/tests/fixtures/two-disc.pbp`. Run it once and add the file to this commit: Task 6's bun tests and Task 8's Swift tests read it, and neither can run Zig.
- [ ] **Step 7: Commit** `feat(core): PS1 eboots, read block by block from the borrowed file`

---

### Task 2: Strided images and interleaved subchannel records

**Files:**
- Modify: `ps1-core/src/disc.zig` (`Source.strided`), `ps1-core/src/ccd.zig` (records from any Q source)
- Test: `ps1-core/tests/disc_test.zig`, `ps1-core/tests/ccd_test.zig`

**Interfaces:**
- Produces:
  - `Source.strided: struct { data: []const u8, stride: u16 }`: sector `lba` is the first 2352 bytes at `lba * stride`; `sectorCount = data.len / stride`.
  - `ccd.zig`: `pub fn qRecords(gpa, sectors: usize, skip: usize, ctx: anytype) error{OutOfMemory}![]u8`, where `ctx.q(i: usize) [12]u8` returns sector `i`'s Q with its CRC; the body is today's `subRecords` loop (zero Q skipped, CRC check, `MSF.fromLba(i − skip)`, type byte). `subRecords` becomes its caller over a deinterleaved `.sub` view.
  - `ccd.zig`: `pub fn deinterleaveQ(pw: *const [96]u8) [12]u8`: Q byte `j` bit `7 − k` is bit 6 of `pw[j * 8 + k]`.

- [ ] **Step 1: Write the failing tests**:
  - `disc_test`: `"a strided image reads its 2352 bytes and skips the subchannel"`: the fixture bin re-laid at 2448 bytes a sector with `0xEE` in each 96-byte tail; `Disc{ .source = .{ .strided = .{ .data = s, .stride = 2448 } } }` has `sectorCount() == 113` and `readSector2352(60)` equals the bin.
  - `ccd_test`: `"deinterleaveQ unpacks bit 6 of each byte"`: a 96-byte block whose bit 6 carries Q `{0x41,0x01,0x01,0,0,0,0,0x00,0x02,0x00,0x28,0x32}` and whose other bits are all 1 → that Q.
  - `ccd_test`: existing `subRecords` tests pass unchanged.
- [ ] **Step 2: Run** `zig build test`; fails to compile.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `zig build test`: all pass.
- [ ] **Step 5: Commit** `feat(core): strided images and interleaved subchannel Q`

---

### Task 3: Alcohol sheets

**Files:**
- Create: `ps1-core/src/mds.zig`
- Modify: `ps1-core/src/root.zig`, `build.zig`, `ps1-golden/src/image_write.zig` (`encodeMds`), `ps1-core/tests/image_fixtures.zig`
- Test: `ps1-core/tests/mds_test.zig`

**Interfaces:**
- Consumes: `Source.strided`, `ccd.qRecords`, `ccd.deinterleaveQ`.
- Produces:
  - `pub fn isMds(sheet: []const u8) bool` (`"MEDIA DESCRIPTOR"` at 0)
  - `pub fn parse(sheet: []const u8, mdf: []const u8) error{BadMds}!Disc`
  - `pub fn stride(sheet: []const u8) error{BadMds}!u16` (2352 or 2448)
  - `pub fn subRecords(gpa, mdf: []const u8) error{OutOfMemory}![]u8`: `qRecords` over every 2448-byte sector's deinterleaved Q, skip 0. `"SBI\x00"` alone when none fail.
  - `image_write.encodeMds(gpa, d: Disc, raw: []const u8, subchannel: bool) !struct { mds: []u8, mdf: []u8 }`: the subchannel is interleaved P..W with only Q set (`image_write.subchannel`'s Q, LibCrypt sectors' CRC inverted).

Parse (DuckStation's reading; every u32 offset bounds-checked): session offset u32 at 0x50; track count u16 at session+14 (≤ 99, ≥ 1); track-block offset u32 at session+20. 80-byte entries: skip those with point ≥ 0xA0, then one per track: byte 4 its BCD number (must be N, else `BadMds`), byte 0 type (0xA9 → `.audio`, else `.data`), byte 1 subchannel (non-zero → 2448), bytes 9..11 start MSF (BCD, `MSF.toLba`), u32 at 12 extra offset → u32 pregap, u32 length, u32 at 40 the track's offset in the `.mdf`. Track 1's pregap is off file; a later track's pregap precedes its data on file and becomes `pregap_lba = start − pregap`. A pregap larger than `start + 150` is refused. Lead-out = last start + length.

Our deliberate narrowing (my call): the image is ONE `Source.strided`, so every track must share one stride and sit where a contiguous image puts it: track N's mdf offset `== (its first on-file LBA) * stride`, where track 1's first on-file LBA is 0 and a later track's is `pregap_lba orelse start`. Anything else, and an `.mdf` shorter than `lead-out * stride`, is `BadMds`. Alcohol writes every PS1 dump this way.

- [ ] **Step 1: Write `encodeMds`** (one session; A0/A1/A2 entries before the tracks; per track the entry, an extra block, offsets as above).
- [ ] **Step 2: Write the failing tests** in `mds_test.zig`:
  - `"an Alcohol image reads back as its cue's disc"` with and without subchannel: tracks equal `initFromCue`'s, every sector equals the bin.
  - `"subchannel LibCrypt records equal the sbi's"`: `encodeMds(subchannel = true)` with sectors 7 and 60 marked LibCrypt; `subRecords` = `"SBI\x00"` + 2 records naming `MSF.fromLba(7)` and `(60)`.
  - `"refusals"`: bad signature; track count 100; a track numbered 3 in slot 2; a pregap past its start; a track 2 offset off by one sector; a mixed-stride sheet; an `.mdf` one sector short. Each `BadMds`.
- [ ] **Step 3: Run** `zig build test`; fails to compile.
- [ ] **Step 4: Implement `mds.zig`.**
- [ ] **Step 5: Run** `zig build test`: all pass.
- [ ] **Step 6: Commit** `feat(core): Alcohol images, with LibCrypt read from the subchannel`

---

### Task 4: The disc index through the core, the C ABI, the session and wasm

**Files:**
- Modify: `ps1-core/src/disc_image.zig`; `ps1-capi/src/root.zig`, `ps1-capi/include/ps1.h`, `ps1-capi/include/ps1_session.h`, `ps1-capi/src/capi_test.zig`; `ps1-session/src/machine.zig` (`discCall`, `Error`, `codes`), `ps1-session/src/settings.zig` (`:101` identify); `ps1-wasm/src/media.zig`, `ps1-wasm/src/machine.zig`, `ps1-wasm/src/codes.zig`
- Test: `ps1-core/tests/disc_image_test.zig`, `ps1-capi/src/capi_test.zig`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces:
  - `Decoder` gains `pbp: *pbp.Reader`; `Error` gains `BadPbp, EncryptedPbp, BadMds`.
  - `pub fn open(gpa, bin, cue, side, disc: u8) Error!Opened`. New rules, before today's: `pbp.isPbp(bin)` → cue must be empty (`BadPbp`), `Reader.open(…, disc)`; `mds.isMds(cue)` → `mds.parse`, then if `stride == 2448` the `.mdf`'s `subRecords`: more than the magic → `sbi` = those and `side` is ignored; else freed and `side` handled as today. `disc != 0` on any other format → `BadCue`.
  - `pub const Image = struct { id: discid.DiscId, discs: u8, title: []const u8 }` and `pub fn identifyImage(gpa, bin, sheet, disc: u8) Error!Image` (`title` borrowed from `bin`, empty for a non-eboot). `identify(gpa, bin)` stays as `identifyImage(gpa, bin, "", 0).id`.
  - C: `ps1_load_disc` and `ps1_swap_disc` gain a trailing `uint32_t disc`; `Ps1DiscBytes` gains a trailing `uint32_t disc`. `typedef struct { uint32_t disc_count; char title[129]; } Ps1ImageInfo;` and `int32_t ps1_identify_disc_image(const uint8_t* bin, size_t bin_len, const uint8_t* sheet, size_t sheet_len, uint32_t disc, Ps1DiscId* out, Ps1ImageInfo* info);` (`info` may be NULL; the title is truncated at 128 bytes, NUL-terminated). `ps1_identify_disc` is unchanged in signature and behaviour.
  - wasm: `loadDisc(…, ppf, ppf_len, disc: u32)`; `identifyDisc(bin, bin_len, sheet: ?[*]const u8, sheet_len, disc: u32)` whose JSON result adds `discs` and `title`.

- [ ] **Step 1: Write the failing tests.** `disc_image_test.zig`:
  - `"open sniffs an eboot and an Alcohol sheet"`: Task 1's two-disc eboot with `disc = 1` → `.pbp` decoder, 40 sectors; `encodeMds` → `.strided`.
  - `"a disc index on a single-disc format is BadCue"`: the fixture bin + cue with `disc = 1`.
  - `"an mdf's own records win only when it has some"` (Review Focus 3): `encodeMds(subchannel = true)` with two LibCrypt sectors plus a `.sbi` naming sector 9 → `sbi` names 7 and 60; with none marked plus the same `.sbi` → `sbi` names 9.
  - `"identifyImage counts an eboot's discs and reads its title"`: `discs == 2`, `title == "Fixture"`; the fixture bin → `discs == 1`, `title == ""`.
  - `capi_test.zig`: `"ps1_load_disc opens disc 1 of an eboot and swaps to disc 0 on the same buffer"` (`PS1_OK` both; Review Focus 4); `"an encrypted eboot is PS1_ERR_ENCRYPTED_PBP"`; `"ps1_identify_disc_image with the mds sheet identifies a 2448-byte mdf"` (same `Ps1DiscId.region` as the raw bin).
- [ ] **Step 2: Run** `zig build test`; fails to compile.
- [ ] **Step 3: Implement**, updating every existing caller to pass `0` (capi_test's `ps1_load_disc` calls, `ps1-session/src/machine.zig`, `ps1-wasm`, `ps1-golden`'s `openImage`, and `ps1-macos/Sources/PS1/Ps1Core.swift`'s two calls so the app keeps building until Task 7), the session's `settings.zig` identify to `ps1_identify_disc_image` with the disc's cue and index, and the `ps1_load_disc` doc comment's slot table with the spec's two rows. Add the three codes everywhere the Global Constraints list.
- [ ] **Step 4: Run** `zig build test` (all pass), `zig build capi-lib` (its `nm` check passes), `zig build macos` (builds), and the trace-golden `verify` (unchanged).
- [ ] **Step 5: Commit** `feat(capi): eboots and Alcohol images, and a disc index across the ABI`

---

### Task 5: Harness gates and the round trip

**Files:**
- Modify: `ps1-golden/src/image_write.zig` (`Format`, `write`), `ps1-golden/src/image_verify.zig` (`openImage`, `run`), `ps1-golden/src/boot.zig` (`.image` gains `disc: u8`), `ps1-golden/src/main.zig` (options), `tools/format-roundtrip.sh`, `CLAUDE.md` (the two Quick commands rows)

**Interfaces:**
- Consumes: `encodePbp`, `encodeMds`, `disc_image.open(…, disc)`.
- Produces (CLI):
  - `image-write --cue=<c>[,<c>…] --format=<ccd|ecm|iso|pbp|mds|mds-sub> --out=<stem>`: several cues only with `pbp`, one disc each in order, titled by the first cue's stem. `mds` writes `<stem>.mds/.mdf` without subchannel, `mds-sub` with (LibCrypt sectors from the cue's `.sbi` broken).
  - `image-verify` and `verify` take `--disc=<n>` (default 0) for an eboot. `openImage`: `.mds` reads `<stem>.mdf`; `.pbp` reads the file (limit raised to 4 GB). With an `.mds` written with subchannel and a cue that has an `.sbi`, the image's own records must equal the `.sbi`'s as MSF sets.
  - `format-roundtrip.sh`: per `games/*/*.cue` also `pbp`, `mds` and `mds-sub`, each `image-verify`'d and `verify --image`'d; once per run, a two-disc eboot from the first two cues in the filter, with `--disc=1` verified against the second cue.

- [ ] **Step 1: Implement** the CLI, `openImage`/`run` and the script.
- [ ] **Step 2: Run** the trace-golden `verify`: unchanged.
- [ ] **Step 3: Run** `tools/format-roundtrip.sh`: every disc `identical` and every `verify --image` passes in all six formats; FF9 PAL's `mds-sub` records equal its `.sbi`; the two-disc eboot's disc 1 matches the second cue's golden. Paste the summary into the task report.
- [ ] **Step 4: Commit** `feat(golden): eboot and Alcohol round trips`

---

### Task 6: Browser package

**Files:**
- Modify: `ps1-web/src/disc-files.ts`, `ps1-web/src/core.ts`, `ps1-web/src/protocol.ts` (`DiscInput.disc?: number`), `ps1-web/src/index.ts` (`identifyDisc(bin, { sheet?, disc?, wasmUrl? })`), `ps1-web/src/errors.ts` (`BAD_PBP: -30`, `ENCRYPTED_PBP: -31`, `BAD_MDS: -32` with messages)
- Test: `ps1-web/test/disc-files.test.ts`, `ps1-web/test/core.test.ts`

**Interfaces:**
- Produces: `discFromFiles` order `.chd` → first `.cue` → first `.ccd` → first `.mds` (its stem's `.mdf` as `bin`, the sheet as `cue`; no `.mdf` throws naming it) → largest `.pbp` → largest `.ecm` → `.iso`/`.img` → `.bin`. A `.ppf` is passed for a `.pbp` only when `disc` is 0. `DiscInfo` gains `discs: number`, `title: string`.

- [ ] **Step 1: Write the failing tests**: `"an .mds set becomes mdf + mds text"`, `"an .mds without its .mdf names it"`, `"a .pbp alone is the bin"`, `"a .ccd still beats an .mds"`, `"a .ppf rides only with disc 0 of a .pbp"`; in `core.test.ts` (no BIOS needed) `"identifyDisc reports an eboot's disc count and title"` over `ps1-core/tests/fixtures/two-disc.pbp`: `discs == 2`, `title == "Fixture"`, and `{ disc: 2 }` throws `BAD_PBP`.
- [ ] **Step 2: Run** `cd ps1-web && bun test`; fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `zig build && cd ps1-web && bun test`: all pass.
- [ ] **Step 5: Commit** `feat(web): open eboots and Alcohol images`

---

### Task 7: macOS app opens, lists, identifies and swaps both formats

Invoke `ps1-macos-app` and `apple-design-guidelines` first.

**Files:**
- Modify: `DiscKind.swift`, `DiscFiles.swift`, `GameScanner.swift`, `DiscIdentity.swift`, `Ps1Core.swift` (`Ps1Error`, `loadDisc`/`swapDisc` pass `disc`), `GameSession.swift` (`DiscBytes.disc: UInt32 = 0`, into `Ps1DiscBytes`), `EmulatorViewModel.swift` (`describe`, the Open panel message), `ThumbnailIndex.swift`, `ps1-macos/Info.plist`
- Test: `ps1-macos/Tests/PS1Tests/DiscFilesTests.swift`, scanner tests

**Interfaces:**
- Produces:
  - `DiscKind` cases gain `pbp`, `mds`; `"mdf"` maps to `.iso` (a lone `.mdf` is a lone image; the core sniffs).
  - `DiscFiles.read(_ url: URL, disc: Int = 0) throws -> DiscBytes`: `.mds` → bin = stem `.mdf`, cue = the sheet, sbi = `sidecar`, ppf = `patch`; `.pbp` → bin = the file, sbi = `sidecar`, ppf = `disc == 0 ? patch : nil`, `disc`. `disc != 0` for any other kind is a programming error (`precondition`).
  - `DiscIdentity.identify(disc: URL, index: Int = 0) -> DiscIdentity?` and `DiscIdentity.imageInfo(_ url: URL) -> (discs: Int, title: String)?`, both over `ps1_identify_disc_image` (an `.mds` passes its `.mdf` mapped and its sheet).
  - `Ps1Error.badPBP`, `.encryptedPBP`, `.badMDS` with `describe` copy; the encrypted one says the file is a protected PlayStation Store download that can't be played.

Scanner precedence for one stem in one folder: cue > chd > ccd > mds > pbp > ecm > iso/img/bin; an `.mdf` with an `.mds` of its stem is never its own game.

- [ ] **Step 1: Write the failing tests**: `DiscKind` for `pbp`, `mds`, `mdf`; scanner fixtures `{a.mds,a.mdf}` → one entry `a.mds`; `{b.cue,b.bin,b.pbp}` → `b.cue`; `{c.mdf}` alone → one entry; `DiscFiles.read(x.pbp, disc: 1)` with `x.ppf` beside it has `ppf == nil` and `disc == 1`; `DiscFiles.read(y.mds)` passes `y.mdf` as `bin`.
- [ ] **Step 2: Run** `pkill -x Substation; zig build capi-lib metallib && ps1-macos/test.sh`; new tests fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `ps1-macos/test.sh` (all pass) and `zig build macos`.
- [ ] **Step 5: Commit** `feat(macos): open eboots and Alcohol images`

---

### Task 8: A multi-disc eboot is one game

**Files:**
- Create: `ps1-macos/Sources/PS1/DiscRef.swift`
- Modify: `GameEntry.swift`, `Playlist.swift`, `GameScanner.swift`, `DiscGrouping.swift`, `EmulatorViewModel.swift` (`bootDisc`, `siblingDiscs`, `playlistDiscs`, `discEntry`, `load(disc:…)`), `OpenGame.swift` (`changeDisc`, the resume rebuild at `:479`), `ResumeOffer.swift`, `LibraryCollection.swift`
- Test: `ps1-macos/Tests/PS1Tests/EbootTests.swift`, `PlaylistTests.swift`

**Interfaces:**
- Consumes: `DiscFiles.read(_:disc:)`, `DiscIdentity.identify(disc:index:)`, `DiscIdentity.imageInfo`.
- Produces:
  - `struct DiscRef: Hashable, Sendable { let url: URL; let disc: Int }` (`disc` 0-based; 0 for every non-eboot).
  - `GameEntry` gains `let disc: Int` (default 0); `id` is `url.path` for disc 0, else `"\(url.path)#\(disc + 1)"`; `playlist` becomes `[DiscRef]`; `pathKey` hashes `playlist.first?.url.path ?? url.path` as today, so an eboot's states key as its first disc.
  - `Playlist.discs: [DiscRef]`; a line naming a `.pbp` is `DiscRef(url, 0)`.
  - `EmulatorViewModel.load(disc: URL, index: Int = 0, …)`; `bootDisc(_:) -> DiscRef`.

Behaviour: the scanner emits ONE entry for a `.pbp`, with `playlist` = `(0..<discs).map { DiscRef(url, $0) }` when `discs > 1`. `siblingDiscs(of:)` for a `.pbp` (or an entry of one) returns one entry per disc, each identified by its index and titled `"<TITLE> (Disc N)"`, or `"Disc N"` when the SFO has no `TITLE`. Change Disc, the resume offer's disc pick (`ResumeOffer.disc(forSerial:in:)`) and the Multi-Disc collection follow from the playlist path unchanged.

- [ ] **Step 1: Write the failing tests**: with the committed `two-disc.pbp`: the scanner gives one entry with `playlist.count == 2`; `siblingDiscs(of:)` gives two entries titled `"Fixture (Disc 1)"`, `"Fixture (Disc 2)"` with distinct `id`s; an untitled eboot gives `"Disc 1"`, `"Disc 2"`; `pathKey` of disc 1's entry equals disc 0's; an `.m3u` naming the `.pbp` gives `[DiscRef(pbp, 0)]` (Review Focus 5); existing playlist tests pass with `DiscRef`.
- [ ] **Step 2: Run** `ps1-macos/test.sh`; fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `ps1-macos/test.sh` and `zig build macos`.
- [ ] **Step 5: Commit** `feat(macos): a multi-disc eboot is one game`

---

### Task 9: Docs and the hand check

**Files:**
- Modify: `CLAUDE.md` (test binary count, the layout block's `pbp/` and `mds.zig`, the `disc_image.zig` line), `.claude/skills/ps1-cdrom-disc/SKILL.md` (eboot and Alcohol sections: the sniff rows, track 1's pregap off file in both, the A2 count, the stride narrowing, interleaved Q and the `.sbi` fallback, `.ppf` disc 0 only), `.claude/skills/ps1-macos-app/SKILL.md` (`DiscRef`, eboot as a playlist, precedence)

- [ ] **Step 1: Update the docs.**
- [ ] **Step 2: Run** `zig build test`, `ps1-macos/test.sh`, `cd ps1-web && bun test`: all pass.
- [ ] **Step 3: Hand check (owner)**: a `.pbp` made by a real converter, ideally multi-disc, booted and swapped in the app; a real Alcohol `.mds`/`.mdf`, preferably a LibCrypt title dumped with subchannel. Record what was covered and what was not in `ps1-cdrom-disc`.
- [ ] **Step 4: Commit** `docs: hard disc formats`
