# Easy Disc Formats Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open `.iso`/`.img`, cooked cue tracks, `.ccd`(+`.img`+`.sub`) and `.ecm` everywhere a `.bin`/`.cue`/`.chd` opens today, and `.m3u` playlists in the macOS app.

**Architecture:** Every format that turns bytes into sectors lives in `ps1-core` behind one new entry, `disc_image.open(gpa, bin, cue, side)`, which sniffs by content and returns a `Disc` plus the decoder it owns. The C ABI, `ps1-wasm` and `ps1-golden` all call it instead of their three copies of the CHD/cue/bin switch. Sector rebuilding (sync, header, EDC, ECC) is one module shared with CHD. `.m3u` is app-only.

**Tech Stack:** Zig 0.17.0 (`ps1-core`, `ps1-capi`, `ps1-wasm`, `ps1-golden`), TypeScript/Bun (`ps1-web`), Swift/SwiftUI (`ps1-macos`).

**Spec:** `docs/superpowers/specs/2026-10-30-easy-disc-formats-design.md`

## Global Constraints

- Read DuckStation for behaviour only; never name it in code, comments or commits. Commits are a title line only, one per task, on master, never pushed.
- No file in `ps1-core/src` over ~600 lines. `disc.zig` is 352 today.
- Exported core symbols keep their paths (`ps1_core.disc.Disc`, `ps1_core.chd`); new modules are added to `ps1-core/src/root.zig`.
- New C ABI codes: `PS1_ERR_BAD_ECM (-28)`, `PS1_ERR_BAD_CCD (-29)`. Mirrored in `ps1-wasm/src/codes.zig`, `ps1-web/src/errors.ts`, `ps1-session/src/machine.zig` (`Error` + `codes`), `ps1-macos/Sources/PS1/Ps1Core.swift` (`Ps1Error`) and `EmulatorViewModel.describe`.
- No new C ABI entry points. `ps1_load_disc`/`ps1_swap_disc`/`ps1_identify_disc` keep their signatures; `bin` stays BORROWED, `sbi` (now also a `.sub`) stays COPIED, nothing of a `.sub` is retained past the call.
- A cooked rip may lose Form 2 data; nothing tries to recover it.
- No trace golden moves. `zig build trace-golden -Doptimize=ReleaseFast -- verify` must pass unchanged after every core task.
- App new types are `Alternate` in `Info.plist`; `.sub` is not declared.
- UI copy goes through the `apple-design-guidelines` skill.

## Review Focus

1. **A `.ccd` whose track 1 stores its pregap** (`INDEX 0=0`, `INDEX 1=150`): our LBA 0 is 00:02:00, so the image's first 150 sectors must be skipped, not read as LBA 0..149. Test in Task 4.
2. **An `.ecm` read out of order** (seek to the end, then the start, as identification and the BIOS do): the lazy index must answer any LBA, not only the next one. Test in Task 3.
3. **A lone `.bin` of a real game** must still be one raw data track: the new sniff must not turn it cooked or audio. Test in Task 2.
4. **A `.sub` passed with a cue or a `.chd`** is still `PS1_ERR_BAD_SBI`, never parsed as subcode. Test in Task 5.
5. **An `.m3u` naming a missing file, itself, or another `.m3u`**: the app reports it by name and never loops or crashes. Test in Task 9.

---

### Task 1: Shared sector rebuilding

**Files:**
- Create: `ps1-core/src/sector.zig`
- Modify: `ps1-core/src/chd/cd.zig` (ECC tables, `parity`, `restoreSector` body move out; `restoreSector` stays as a one-line caller), `ps1-core/src/root.zig`, `build.zig` (`unit_test_files`)
- Test: `ps1-core/tests/sector_test.zig`

**Interfaces:**
- Produces:
  - `pub const sync_pattern: [12]u8`
  - `pub const CookedMode = enum { mode1, mode2, mode2_form1, mode2_form2, mode2_mixed }` with `pub fn bytes(self) usize` → 2048, 2336, 2048, 2324, 2332
  - `pub fn edc(bytes: []const u8) u32` (CD-ROM EDC, poly 0xD8018001 reflected, init 0)
  - `pub fn writeEcc(sector: *[2352]u8) void` (P then Q; a Mode 2 sector's header counts as zero, as `cd.parity` does today)
  - `pub fn writeHeader(sector: *[2352]u8, lba: i32, mode: u8) void` (sync, BCD MSF via `disc.MSF.fromLba`, mode byte)
  - `pub fn dress(mode: CookedMode, lba: i32, payload: []const u8, out: *[2352]u8) void`: the layout table below.

| mode         | payload at | subheader                                   | EDC over → at            | ECC |
| ------------ | ---------- | ------------------------------------------- | ------------------------ | --- |
| mode1        | 0x10       | none; 0x814..0x81B zero                     | `[0..0x810)` → 0x810     | yes |
| mode2        | 0x10       | (in payload)                                | none                     | no  |
| mode2_form1  | 0x18       | `00 00 08 00 00 00 08 00`                   | `[0x10..0x818)` → 0x818  | yes |
| mode2_form2  | 0x18       | `00 00 28 00 00 00 28 00`                   | `[0x10..0x92C)` → 0x92C  | no  |
| mode2_mixed  | 0x10       | (in payload); submode bit 5 picks the form  | as form1 or form2        | form1 only |

EDC is stored little-endian.

- [ ] **Step 1: Write the failing tests** in `sector_test.zig`, against `@embedFile("chd/disc.bin")` (sectors 0..21 are Mode 2 Form 1, 22..29 Mode 1, all with valid EDC/ECC):
  - `"dress mode1 rebuilds a real Mode 1 sector"`: payload = `bin[25*2352+0x10..][0..2048]`, `dress(.mode1, 25, payload, &out)`, `expectEqualSlices(binSector(25), out)`.
  - `"dress mode2_form1 rebuilds a real Form 1 sector"`: sector 3, payload at 0x18; equal.
  - `"dress mode2 rebuilds from 2336 bytes"`: sector 3, payload `[0x10..0x930)`, mode `.mode2`; equal (the payload carries its own EDC/ECC).
  - `"dress mode2_mixed rebuilds a Form 1 sector from 2332 bytes"`: sector 3, payload `[0x10..0x92C)`; equal.
  - `"dress mode2_form2 lays out a Form 2 sector"`: 2324 bytes of `0x5A`, lba 100: `out[0..12] == sync_pattern`, `out[12..16] == {0x00,0x03,0x25,0x02}` (LBA 100 = 00:03:25), `out[0x12] == 0x28`, `out[0x18] == 0x5A`, `readInt(u32, out[0x92C..0x930], .little) == edc(out[0x10..0x92C])`.
  - `"edc matches the fixture"`: `edc(binSector(25)[0..0x810]) == readInt(u32, binSector(25)[0x810..0x814], .little)`.
- [ ] **Step 2: Run** `zig build test` and see `sector_test` fail to compile (`sector` missing).
- [ ] **Step 3: Implement `sector.zig`**, moving the ECC tables, `pOffset`/`qOffset`/`parity` and the P/Q writes out of `chd/cd.zig`; `cd.restoreSector` becomes `sector[0..12].* = sync_pattern; sector_mod.writeEcc(sector);`. Add `pub const sector = @import("sector.zig");` to `root.zig` and the test to `unit_test_files`.
- [ ] **Step 4: Run** `zig build test`: all pass, including `chd_test`'s two ECC restore tests.
- [ ] **Step 5: Commit** `feat(core): one sector-rebuilding module for CHD and cooked images`

---

### Task 2: Cooked sources, cooked cue tracks and the lone-image sniff

**Files:**
- Modify: `ps1-core/src/disc.zig`
- Test: `ps1-core/tests/disc_test.zig`

**Interfaces:**
- Consumes: `sector.CookedMode`, `sector.dress`, `sector.sync_pattern`.
- Produces:
  - `Source.cooked: struct { data: []const u8, mode: sector.CookedMode }`; `sectorCount` = `data.len / mode.bytes()`; `readSector2352` copies `mode.bytes()` at `lba * mode.bytes()` and calls `sector.dress`.
  - `pub fn initLone(data: []const u8) Disc`: the sniff. Sync at 0, byte 15 ∈ {1,2} and `len % 2352 == 0` → `init(data)` (unchanged raw data track); `len % 2352 == 0` without sync → one track of type `.audio` over `.flat`; else one data track over `.cooked{ .mode1 }`.
  - `pub fn cueCookedMode(cue_text: []const u8) error{CookedLayout}!?sector.CookedMode`: null when every TRACK is `MODE1/2352`, `MODE2/2352` or `AUDIO`; the mode for exactly one TRACK of `MODE1/2048`, `MODE2/2336`, `MODE2/2048`, `MODE2/2324`, `MODE2/2332` in a cue with one FILE; `error.CookedLayout` for a cooked mode alongside a second TRACK or FILE.
  - `pub fn initCookedCue(cue_text, data, mode) Disc`: `initFromCue` for the track table, source replaced by `.cooked`.
  - `readSectorRaw` picks its 2048-byte offset by the sector's own mode byte (0x10 for mode 1, 0x18 for mode 2) instead of always 0x18. Today it serves `discid` from 0x18 unconditionally, which would misread every dressed Mode 1 sector.

- [ ] **Step 1: Write the failing tests** in `disc_test.zig`:
  - `"a lone raw image stays one raw data track"`: `initLone(chd/disc.bin)` has `source == .flat`, one `.data` track, and `readSector2352(3)` equals the bin's sector 3.
  - `"a lone image with no sync is one audio track"`: 2 × 2352 bytes of `0x11`; one `.audio` track, `.flat`.
  - `"a lone 2048-byte image is cooked Mode 1"`: 3 × 2048 bytes, sector `i` filled with `i+1`; `sectorCount() == 3`; `readSector2352(2)` has byte 15 == 1, `[0x10] == 3`, and `readSector(2)` returns 2048 bytes of 3.
  - `"cueCookedMode reads a single cooked track"`: `FILE "x.iso" BINARY\n TRACK 01 MODE1/2048\n INDEX 01 00:00:00` → `.mode1`; `MODE2/2352` cue → null.
  - `"cueCookedMode refuses a cooked track beside another"`: `MODE1/2048` + a `TRACK 02 AUDIO` → `error.CookedLayout`.
- [ ] **Step 2: Run** `zig build test`; the new tests fail to compile.
- [ ] **Step 3: Implement** the three functions and the `cooked` arm in `sectorCount`/`readSector2352`.
- [ ] **Step 4: Run** `zig build test` (all pass) and `zig build -Doptimize=ReleaseFast && zig build trace-golden -Doptimize=ReleaseFast -- verify` (unchanged).
- [ ] **Step 5: Commit** `feat(core): cooked images and the lone-image sniff`

---

### Task 3: ECM reader

**Files:**
- Create: `ps1-core/src/ecm.zig`
- Modify: `ps1-core/src/disc.zig` (`Source.ecm: *ecm.Reader`), `ps1-core/src/root.zig`, `build.zig`
- Test: `ps1-core/tests/ecm_test.zig`

**Interfaces:**
- Consumes: `sector.dress`/`writeEcc`/`edc`/`sync_pattern`.
- Produces:
  - `pub fn isEcm(data: []const u8) bool` (`"ECM\x00"`)
  - `pub const Reader` with `pub fn open(gpa, data: []const u8) error{ OutOfMemory, BadEcm }!*Reader`, `pub fn close(self: *Reader) void`, `pub fn sectorCount(self: *Reader) i32`, `pub fn readSector(self: *Reader, lba: i32, out: *[2352]u8) bool`.
  - `Disc.initFromEcm(reader) Disc` (one data track; a cue's tracks are applied by Task 5).

Format: after the magic, chunks of `header, records`. Header byte `b`: type = `b & 3`, count = `(b >> 2) & 0x1F`, then while `b & 0x80` the next byte adds `(b & 0x7F) << shift` (shift starts 5, +7 each). `count == 0xFFFFFFFF` ends the stream; else `count += 1`, and `count >= 0x80000000` is `BadEcm`. Records decode into the byte stream of the original `.bin`:

| type | stored per record                | decodes to (bytes) |
| ---- | -------------------------------- | ------------------ |
| 0    | `count` raw bytes (one record)   | `count`            |
| 1    | 3 address bytes + 2048 data      | 2352, Mode 1 sector, address at 0x0C, mode 1 |
| 2    | 4 subheader + 2048 data (0x804)  | 2336 = a Mode 2 Form 1 sector from 0x10 (subheader copied to 0x10 and 0x14) |
| 3    | 4 subheader + 2324 data (0x918)  | 2336 = a Form 2 sector from 0x10 |

A raw image's Mode 2 sector is a 16-byte type-0 chunk (sync + header) followed by one type-2/3 record, so a sector usually spans two chunks: read by decoded BYTE offset `lba * 2352`, not by chunk.

Index (my call, binding): lazy and sparse. A checkpoint `{ decoded: u64, file: u64 }` is recorded at the start of every 64th chunk header; `readSector` binary-searches the last checkpoint at or before the wanted offset and walks headers forward from it, extending the checkpoint list when it walks past the end. `open` walks only the first chunk (to validate the magic and first header); `sectorCount` walks to the end once and caches the total. A decoded total not a multiple of 2352, a record running past the end of `data`, or a missing terminator is `BadEcm` (from `open` if met there, else `readSector` returns false and `sectorCount` returns what was valid).

- [ ] **Step 1: Write the failing tests** in `ecm_test.zig`. A helper `pub fn encodeEcm(gpa, raw: []const u8) ![]u8` in a new `ps1-core/tests/image_fixtures.zig` (shared with Task 5) writes the format above (type 1 for a Mode 1 sector, 16 raw bytes + type 2 for a Form 1 sector, type 0 otherwise); tests use `chd/disc.bin`:
  - `"ECM decodes every sector of the fixture disc"`: `encodeEcm` all 113 sectors, `open`, `sectorCount() == 113`, every `readSector` equals the bin.
  - `"ECM answers sectors out of order"`: read LBA 112, then 0, then 57: each equals the bin (Review Focus 2).
  - `"ECM refuses a bad magic, a truncated stream and a misaligned total"`: `"ECX\x00"` → `BadEcm`; the encoding minus its last 10 bytes → `sectorCount` < 113 and `readSector(112)` false; a stream of one 100-byte raw chunk + terminator → `BadEcm` on `sectorCount`'s walk (asserted via `open` then `sectorCount() == 0`).
  - `"an ECM disc reads through Disc"`: `Disc.initFromEcm(r).readSector2352(25)` equals the bin.
- [ ] **Step 2: Run** `zig build test`; fails to compile.
- [ ] **Step 3: Implement** `ecm.zig` and the `ecm` arm in `Disc.sectorCount`/`readSector2352`.
- [ ] **Step 4: Run** `zig build test`; all pass.
- [ ] **Step 5: Commit** `feat(core): ECM images, decoded sector by sector`

---

### Task 4: CloneCD control files and `.sub` LibCrypt records

**Files:**
- Create: `ps1-core/src/ccd.zig`
- Modify: `ps1-core/src/disc.zig` (`sbi_magic`, `sbi_record_bytes` become `pub`), `ps1-core/src/root.zig`, `build.zig`
- Test: `ps1-core/tests/ccd_test.zig`

**Interfaces:**
- Produces:
  - `pub fn isCcd(text: []const u8) bool`: a line `[CloneCD]` (case-insensitive, trimmed).
  - `pub fn parse(text: []const u8, img: []const u8) error{BadCcd}!Disc`: tracks and a `.flat` source.
  - `pub fn subRecords(gpa, sub: []const u8, skip: usize) error{ OutOfMemory, BadCcd }![]u8`: an sbi-shaped buffer (`"SBI\x00"` + 14-byte records) for every sector `i ≥ skip` whose stored Q fails its CRC; MSF = `MSF.fromLba(i - skip)`, type byte 1, then the 10 stored Q bytes. `sub.len % 96 != 0` is `BadCcd`.
  - `pub fn qCrc(q: *const [10]u8) u16`: CRC-16, poly 0x1021, init 0, result inverted; stored big-endian at Q bytes 10..11 (the `.sub` keeps Q at offset 12 of each 96-byte sector).
  - `pub fn pregapSkip(text) usize`: the sectors of the image before our LBA 0 (Track 1's `INDEX 1` when an `INDEX 0` is present, else 0); `parse` slices `img[skip*2352..]` and subtracts `skip` from every LBA.

Parse rules (from the spec): INI lines, `;` comments, `[Section]`, `key=value`, integers decimal or `0x` hex. Require `[CloneCD]`, `[Disc]` with `TocEntries >= 3`. `[Entry N]` for N < TocEntries: `Point` 0xA2 with `PLBA` → lead-out; `Point` 1..99 → track with `Control` and `PLBA`. `[TRACK n]` `MODE` 0 → `.audio`, 1/2 → `.data`; with no `MODE`, `Control & 4` → data. `INDEX 1` (else `PLBA`) → `start_lba`; `INDEX 0` → `pregap_lba`. Lead-out missing → `img.len / 2352`. Refuse (`BadCcd`): no tracks, track 1 missing, a gap in numbering, `start < pregap`, a next track starting at or before this one's `INDEX 1`, an `img` shorter than the lead-out.

- [ ] **Step 1: Write the failing tests** in `ccd_test.zig` with hand-written sheets against `chd/disc.bin` (113 sectors; track 1 data at 0, track 2 audio pregap 30 start 40, track 3 audio pregap 91 start 93, matching `chd/disc.cue`):
  - `"a CloneCD sheet reads as the cue's disc"`: a sheet with three `[Entry]`s, an A2 entry (PLBA 113) and `[TRACK 1..3]`; `parse` gives the same `tracks` as `Disc.initFromCue(chd/disc.cue, bin)` and `readSector2352(50)` equals it.
  - `"a stored track-1 pregap is skipped"`: an img of 150 zero sectors + the bin, sheet with `[TRACK 1] INDEX 0=0 INDEX 1=150`, track 2 `INDEX 1=190`: `tracks[0].start_lba == 0`, `tracks[1].start_lba == 40`, `readSector2352(0)` equals bin sector 0 (Review Focus 1).
  - `"a missing lead-out comes from the image size"`: no A2 entry; `sectorCount() == 113`.
  - `"refusals"`: no `[CloneCD]`; `TocEntries=2`; tracks 1 and 3 only; an img of 50 sectors under an A2 of 113. Each `BadCcd`.
  - `"qCrc matches a known Q"`: Q `{0x41,0x01,0x01,0x00,0x00,0x00,0x00,0x00,0x02,0x00}` (track 1 index 1, rel 00:00:00, abs 00:02:00) → `0x2832` (stored as bytes `0x28, 0x32`); 10 zero bytes → `0xFFFF`.
  - `"subRecords keeps only sectors whose Q fails its CRC"`: a `.sub` of 113 × 96 bytes with valid Q (built with `qCrc`), sectors 7 and 60 given a flipped CRC byte; result is `"SBI\x00"` + 2 records whose MSF bytes are `MSF.fromLba(7)` and `MSF.fromLba(60)`; `Disc.setSbi` on it makes `isLibCryptSector(60)` true and `(61)` false.
- [ ] **Step 2: Run** `zig build test`; fails to compile.
- [ ] **Step 3: Implement** `ccd.zig`.
- [ ] **Step 4: Run** `zig build test`; all pass.
- [ ] **Step 5: Commit** `feat(core): CloneCD images, with LibCrypt read from the subchannel`

---

### Task 5: One disc-opening path for the C ABI and the browser core

**Files:**
- Create: `ps1-core/src/disc_image.zig`
- Modify: `ps1-core/src/root.zig`, `build.zig`; `ps1-capi/src/root.zig` (`prepareDisc`, `ps1_identify_disc`, `Handle.chd` → `Handle.decoder`), `ps1-capi/include/ps1.h` (codes and the `ps1_load_disc` comment's slot table), `ps1-capi/src/capi_test.zig`; `ps1-wasm/src/media.zig` (`loadDisc`, identify), `ps1-wasm/src/machine.zig` (`replaceDisc`'s `reader` → `Decoder`), `ps1-wasm/src/codes.zig`; `ps1-session/src/machine.zig` (`Error`, `codes`)
- Test: `ps1-core/tests/disc_image_test.zig`, `ps1-capi/src/capi_test.zig`

**Interfaces:**
- Consumes: Tasks 2–4; `chd.Reader`, `chd.isChd`, `disc.countCueFiles`, `disc.cueFilesAreLaidOut`.
- Produces:
  - `pub const Decoder = union(enum) { none, chd: *chd.Reader, ecm: *ecm.Reader }` with `pub fn close(self: Decoder) void`.
  - `pub const Opened = struct { disc: Disc, decoder: Decoder, sbi: []u8 }`: `sbi` is owned (gpa), `"SBI\x00"`-prefixed or empty, NOT yet attached; the caller attaches it with `disc.setSbi` after any PPF so the existing order in `prepareDisc` holds.
  - `pub const Error = error{ OutOfMemory, BadCue, MultiFileCue, BadChd, BadEcm, BadCcd, BadSbi }`
  - `pub fn open(gpa, bin: []const u8, cue: []const u8, side: []const u8) Error!Opened`
  - `pub fn identify(gpa, bin: []const u8) ?discid.Identity` (open with no cue/side, identify, close; null on any error).

`open` rules, in order (every refusal frees what it allocated):
1. `bin.len < 2048` → `BadCue` (today's floor is 2352; a lone cooked image of one sector is 2048).
2. `chd.isChd(bin)`: cue must be empty (`BadChd`); `Disc.initFromChd`.
3. `ecm.isEcm(bin)`: open the reader (`BadEcm`); with a cue: it must have exactly one FILE (`BadCue`) and its tracks come from `initFromCue` with the source replaced by `.ecm`; else `initFromEcm`.
4. `ccd.isCcd(cue)`: `ccd.parse(cue, bin)` (`BadCcd`).
5. Non-empty cue: today's checks (`countCueFiles == 0` → `BadCue`; multi-FILE without seams → `MultiFileCue`; no `"TRACK "` → `BadCue`), then `cueCookedMode` (`CookedLayout` → `BadCue`; a mode → `initCookedCue`), else `initFromCue`.
6. Empty cue: `Disc.initLone(bin)`.
7. `side`: empty → `sbi = &.{}`. Starts with `"SBI\x00"` → dupe. Else, only if step 4 was taken and `side.len % 96 == 0` → `ccd.subRecords(side, pregapSkip)`. Anything else → `BadSbi` (Review Focus 4).

C ABI codes: `PS1_ERR_BAD_ECM (-28)`, `PS1_ERR_BAD_CCD (-29)`. `prepareDisc` keeps its PPF build, sbi attach and handle swap, now over `Opened`; `Prepared.old_chd` becomes `old_decoder: Decoder`. `ps1_identify_disc` uses `disc_image.identify`.

- [ ] **Step 1: Write the failing tests.** `disc_image_test.zig`:
  - `"open sniffs each format"`: `chd/disc-default.chd` → `.chd` decoder; `image_fixtures.encodeEcm` of the bin → `.ecm`; Task 4's sheet with the bin → `.flat` with three tracks; `chd/disc.cue` + bin → three tracks; 3 × 2048 bytes → `.cooked`.
  - `"an ECM named by a one-FILE cue takes the cue's tracks"`: ECM of the bin + `chd/disc.cue` → three tracks, `readSector2352(50)` equals the bin.
  - `"a .sub is accepted only beside a CloneCD sheet"`: the Task 4 `.sub` with the sheet → `sbi` has 2 records; the same bytes with `chd/disc.cue` → `BadSbi`; with the CHD → `BadSbi`.
  - `"refusals map to their errors"`: CHD + cue → `BadChd`; ECM + a two-FILE cue → `BadCue`; `[CloneCD]` with no `[Disc]` → `BadCcd`; cooked cue with two tracks → `BadCue`.
  `capi_test.zig`: `"ps1_load_disc opens an ECM and a CloneCD image"` (returns `PS1_OK`), `"ps1_load_disc refuses a corrupt ECM with PS1_ERR_BAD_ECM"`, `"ps1_identify_disc identifies a cooked image"` (a cooked copy of the bin's Form 1 user data returns the same `Ps1DiscId` region as the raw bin).
- [ ] **Step 2: Run** `zig build test`; fails to compile.
- [ ] **Step 3: Implement `disc_image.zig`**, then rewrite `prepareDisc`, `ps1_identify_disc`, wasm `loadDisc`/identify and `machine.replaceDisc` over it; add the two codes to `ps1.h`, `codes.zig`, `ps1-session/src/machine.zig`. Update the `ps1_load_disc` doc comment with the spec's slot table.
- [ ] **Step 4: Run** `zig build test` (all pass), `zig build capi-lib`, `zig build -Doptimize=ReleaseFast && zig build trace-golden -Doptimize=ReleaseFast -- verify` (unchanged).
- [ ] **Step 5: Commit** `feat(capi): every disc format opens through one core path`

---

### Task 6: Harness gates: `image-verify`, `image-write`, `verify --image`, round trip

**Files:**
- Create: `ps1-golden/src/image_write.zig`, `tools/format-roundtrip.sh`
- Rename: `ps1-golden/src/chd_verify.zig` → `ps1-golden/src/image_verify.zig`
- Modify: `ps1-golden/src/main.zig` (modes and options), `ps1-golden/src/boot.zig` (workload source `.chd` → `.image: { cue, image, sub: ?[]const u8 }` through `disc_image.open`), `tools/chd-roundtrip.sh`, `CLAUDE.md` (Quick commands rows)

**Interfaces:**
- Consumes: `disc_image.open`, `sector`, `ccd.qCrc`, `Disc.getSubchannelQ`, `Disc.isLibCryptSector`.
- Produces (CLI):
  - `image-verify --cue=<c> --image=<i> [--sub=<s>]`: replaces `chd-verify` (same checks, image opened through `disc_image.open`; a `.ccd` image reads its `.img` by stem). For a `.cooked` source it compares, over every cue data sector that is Mode 1 or Mode 2 Form 1, the 2048 user bytes, counts skipped Form 2 sectors, and checks identity; track table and sector count are not compared. With `--sub`, the `.sub` records must equal the cue's `.sbi` records (as MSF sets).
  - `verify --cue=<c> --image=<i>`: replaces `--chd=` for every format; the golden must match unchanged.
  - `image-write --cue=<c> --format=<ccd|ecm|iso> --out=<stem>`: writes `<stem>.ccd/.img/.sub`, `<stem>.ecm`, or `<stem>.iso`. `.sub`: per sector 96 bytes, Q at +12 = control/adr (`0x41` data, `0x01` audio), the `getSubchannelQ` fields, `qCrc` big-endian; LibCrypt sectors (`isLibCryptSector`, from the cue's `.sbi`) get the CRC inverted. `.ecm`: per sector, Mode 1 with valid EDC/ECC → type 1; Mode 2 whose subheader copies match and whose Form 1/2 EDC (and Form 1 ECC) regenerate → 16 raw bytes + type 2/3; else raw; adjacent raw merged. `.iso`: single-track data discs only, 2048 user bytes per sector (at 0x10 for Mode 1, 0x18 for Mode 2); refuses a multi-track cue.

`tools/format-roundtrip.sh [filter]`: same shape as `chd-roundtrip.sh` (temp dir, 2 GB free check, one disc at a time, never writes to `games/`). Per `games/*/*.cue`: for each of `ccd ecm iso` (iso only where `image-write` accepts it), `image-write`, `image-verify` (with `--sub` for ccd), `verify --image`, delete. `chd-roundtrip.sh` switches to `image-verify`/`--image`.

- [ ] **Step 1: Implement** the rename, `boot.zig` source, `image_write.zig` and the CLI.
- [ ] **Step 2: Run** `zig build -Doptimize=ReleaseFast && zig build trace-golden -Doptimize=ReleaseFast -- verify`: unchanged.
- [ ] **Step 3: Run** `tools/format-roundtrip.sh`: every disc `identical`, every `verify --image` passes; Final Fantasy IX PAL's `.sub` records equal its `.sbi`. Paste the summary into the task report.
- [ ] **Step 4: Run** `tools/chd-roundtrip.sh croc` (needs `chdman`): passes under the new names.
- [ ] **Step 5: Commit** `feat(golden): image-verify, image-write and a round trip for every format`

---

### Task 7: Browser package picks the new formats

**Files:**
- Modify: `ps1-web/src/disc-files.ts`, `ps1-web/src/errors.ts`
- Test: `ps1-web/test/disc-files.test.ts`

**Interfaces:**
- Consumes: the core sniffing through `ps1-wasm`'s unchanged `loadDisc`.
- Produces: `discFromFiles` order `.chd` → first `.cue` → first `.ccd` (its stem's `.img` as `bin`, the `.ccd` text as `cue`, its stem's `.sub` as `sbi` when present, else the `.sbi`) → largest `.ecm` → largest `.iso`/`.img` → largest `.bin`. A cue naming an `.ecm` FILE passes the `.ecm` as `bin`. The error message lists the new formats. `errors.ts` gains `BAD_ECM: -28`, `BAD_CCD: -29` in its existing shape.

- [ ] **Step 1: Write the failing tests**: `"a .ccd set becomes img + ccd text + sub"`, `"an .ecm alone is the bin"`, `"an .iso alone is the bin"`, `"a .cue still beats a .ccd"`.
- [ ] **Step 2: Run** `cd ps1-web && bun test test/disc-files.test.ts`; fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `zig build && cd ps1-web && bun test`; all pass.
- [ ] **Step 5: Commit** `feat(web): open CloneCD, ECM and ISO images`

---

### Task 8: macOS app opens, lists, identifies and swaps the new formats

Invoke `ps1-macos-app` and `apple-design-guidelines` first.

**Files:**
- Create: `ps1-macos/Sources/PS1/DiscFiles.swift`
- Modify: `DiscKind.swift`, `GameScanner.swift`, `DiscIdentity.swift` (`identify(disc:)`), `EmulatorViewModel.swift` (`load`, `sidecar`, `patch`, `describe`, raw-bin warning), `OpenGame.swift` (`changeDisc`), `Ps1Core.swift` (`Ps1Error`), `ThumbnailIndex.swift` (`kinds`), `RecentDiscs.swift`/`OnboardingView.swift`/`LibraryView.swift` where they list extensions, `ps1-macos/Info.plist`
- Test: `ps1-macos/Tests/` (new `DiscFilesTests.swift`, existing scanner tests)

**Interfaces:**
- Produces:
  - `DiscKind` cases `cue, bin, chd, exe, iso, ccd, ecm, m3u` (`iso` covers `.iso` and `.img`).
  - `enum DiscFiles { static func read(_ url: URL) throws -> DiscBytes }`: the one place a disc's bytes are gathered, replacing the duplicated blocks in `load` and `changeDisc`. `.cue` → `discImage(forCue:)` (a single FILE naming an `.ecm` passes it unchanged; several FILEs with an `.ecm` among them throws `Ps1Error.badCue`); `.ccd` → bin = stem `.img` (mapped), cue = the `.ccd` text, sbi = stem `.sub` else stem `.sbi`; others → the file (mapped) with `.sbi`/`.ppf` beside it. Sidecars for `X.bin.ecm` try stem `X.bin` then `X`.
  - `Ps1Error.badECM`, `.badCCD` with `describe` copy.

Scanner precedence for one stem in one folder: cue > chd > ccd > ecm > iso/img/bin; an `.img` with a `.ccd` of its stem is never its own game; an `.ecm` named by a cue in its folder is never its own game. `DiscIdentity.identify(disc:)`: `.ccd` identifies its `.img`; `.ecm`/`.iso` the file itself (the core sniffs). `showRawBinWarning` only for `.bin` and `.img`. `Info.plist`: `iso`, `img`, `ccd`, `ecm`, `m3u` as `Alternate` with UTTypes in the existing `dev.substation.*` shape.

- [ ] **Step 1: Write the failing tests**: `DiscKind` for each extension; scanner fixtures in a temp dir: `{a.cue,a.bin,a.ccd,a.img}` → one entry `a.cue`; `{b.ccd,b.img,b.sub}` → `b.ccd`; `{c.bin.ecm}` → one entry; `{d.iso}` → one; `{e.cue naming e.bin.ecm, e.bin.ecm}` → only `e.cue`. `DiscFiles.read` of `b.ccd` passes the `.sub` as `sbi`; of `c.bin.ecm` with `c.bin.sbi` beside it passes that `.sbi`.
- [ ] **Step 2: Run** `pkill -x Substation; zig build capi-lib metallib && ps1-macos/test.sh`; new tests fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `ps1-macos/test.sh` (all pass) and `zig build macos`.
- [ ] **Step 5: Commit** `feat(macos): open ISO, CloneCD and ECM images`

---

### Task 9: `.m3u` playlists in the app

**Files:**
- Create: `ps1-macos/Sources/PS1/Playlist.swift`
- Modify: `GameScanner.swift`, `DiscGrouping.swift` or `EmulatorViewModel.siblingDiscs`, `EmulatorViewModel.swift` (`load` of an `.m3u`), `ResumeOffer.swift` callers, `LibraryCollection.swift` (Multi-Disc)
- Test: `ps1-macos/Tests/PlaylistTests.swift`

**Interfaces:**
- Produces: `struct Playlist { let url: URL; let discs: [URL]; static func read(_ url: URL) throws -> Playlist }`. Lines trimmed; blank and `#` lines skipped; relative paths resolved against the playlist's folder; URLs canonicalised as `EmulatorViewModel.canonicalPath` does. An entry that is an `.m3u` or an executable, or the playlist itself, throws a `Playlist.Error.unsupportedEntry(name)`; an empty playlist throws `.empty`.

Behaviour: the scanner emits one `GameEntry` per playlist (identity from its first disc) and drops every disc a playlist in the scan names. `siblingDiscs(of:)` returns the playlist's discs, in order, as entries when the URL is an `.m3u` or a disc a playlist names; folder grouping otherwise unchanged. Opening an `.m3u` loads its first disc with the playlist as the set (Change Disc, resume disc pick, Multi-Disc collection). A missing entry fails only when chosen, with copy naming the file.

- [ ] **Step 1: Write the failing tests**: parse with comments, CRLF, blank lines, relative and absolute paths; refuses itself, a nested `.m3u`, an `.exe` (Review Focus 5); scanner with `{set.m3u → d1.cue, d2.cue}` gives one entry and `siblingDiscs(of: set.m3u)` gives `[d1, d2]`; a disc not named by any playlist still groups by folder.
- [ ] **Step 2: Run** `ps1-macos/test.sh`; fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `ps1-macos/test.sh` and `zig build macos`.
- [ ] **Step 5: Commit** `feat(macos): m3u playlists are one multi-disc game`

---

### Task 10: Docs and the hand check

**Files:**
- Modify: `CLAUDE.md` (test binary count, `image-verify`/`format-roundtrip.sh` rows, the layout block's new `sector.zig`/`ecm.zig`/`ccd.zig`/`disc_image.zig`), `.claude/skills/ps1-cdrom-disc/SKILL.md` (a section on the formats: the sniff table, `.sub` → records and its deliberate gap, the stored-pregap skip, the ECM sector-spans-chunks trap), `.claude/skills/ps1-macos-app/SKILL.md` (DiscFiles, precedence, playlists)

- [ ] **Step 1: Update the docs.**
- [ ] **Step 2: Run** `zig build test`, `ps1-macos/test.sh`, `cd ps1-web && bun test`: all pass.
- [ ] **Step 3: Hand check (owner)**: in the app, open one game as `.ccd`, `.ecm`, `.iso`; an `.m3u` set and Change Disc between its discs; FF9 PAL as `.ccd`+`.sub` with no `.sbi` past its protection. The `image-write` outputs from Task 6 serve as inputs.
- [ ] **Step 4: Commit** `docs: easy disc formats`
