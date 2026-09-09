---
name: ps1-cdrom-disc
description: Use when touching ps1-core/src/cdrom/, disc.zig, discid.zig, or anything about CD sectors, MSF/BCD, CUE sheets, XA-ADPCM, CD-DA, LibCrypt .sbi sidecars, disc swapping, or disc identification (region and serial). Covers the deferred step() guard, the interrupt edge model, seek/ack timing constants that are load-bearing, and the mode-1 vs mode-2 data offset.
---

# CDROM and disc

## Disc identification — what the disc says about itself

`ps1-core/src/discid.zig` answers two questions from the disc alone, with no
filename rule and no database: **which region** it is, and **which serial** it
carries. `ps1_identify_disc` puts both across the C ABI, `DiscIdentity.swift`
wraps that for the app, and `ps1-golden` uses the region to pick a BIOS.
Measured over the 21 discs in `games/`: every one reports the right region and
every one yields a serial.

- **The licence string at LBA 4 is padded by eye, and the padding lands INSIDE
  the words.** The real bytes are
  `"          Licensed  by          Sony Computer Entertainment Amer  ica "`,
  and `Euro pe` likewise — so `contains("America")` fails on Croc.
  Two further spellings are in circulation: `Entertainment(Europe)` (Rayman,
  Doom) and `Entertainment of America` (Tekken). **DuckStation hardcodes three
  literals and compares them with `memcmp`** (`src/core/system.cpp`,
  `GetRegionFromSystemArea`), which misses the last two and falls through to
  its serial table; `licenseRegion` strips all whitespace first and matches all
  five. The match is anchored on `computerentertainment` so that arbitrary
  sector contents holding "america" are not read as a licence.
- **The serial comes from SYSTEM.CNF's `BOOT` line, whose shape varies more
  than it looks like it should.** `cdrom:\SLUS_005.30;1` is the common form,
  but Castlevania drops the backslash, Tekken 3 puts the executable in a
  subdirectory (`cdrom:\TEKKEN3\SLUS_004.02;1`) and Tomb Raider writes it in
  lowercase. The value is reduced to its last path component, then to four
  letters and its digits: `SLUS-00530`. `PSX.EXE` — the BIOS's own fallback
  boot file — is correctly not a serial.
- **The serial prefix is a second region signal**, and the table is Sony's own
  (the one DuckStation carries): `SCES/SCED/SLES/SLED` PAL,
  `SCPS/SLPS/SLPM/SCZS/PAPX` NTSC-J, `SCUS/SLUS` NTSC-U. Precedence is licence,
  then serial, then — in a frontend, never in the core — the filename.
- **Identification must see the WHOLE image, and this is the sharp edge.**
  SYSTEM.CNF is reached through the ISO directory and its extent is **497 MB
  into Croc and 607 MB into Resident Evil** (Tekken 136 MB; FF7 is at LBA 23).
  A caller that passes a head window gets no serial and no error — the licence
  region alone. Both frontends therefore MAP the file
  (`Data(contentsOf:options:.mappedIfSafe)`), so a library scan costs a handful
  of page faults rather than gigabytes.
- **The user-data offset comes from the sector's own mode byte**, the same rule
  `cdrom.zig` applies: Mode 1 has no sub-header and starts at 010h, everything
  else at 018h. `Disc.readSectorRaw` hardcodes 018h for a 2048-byte request, so
  `discid.zig` reads raw 2352-byte sectors and picks the offset itself —
  `games/` is nearly all MODE2/2352, so a Mode 1 disc is exactly the case that
  would slip through untested. Both are covered by `discid_test.zig`.
- **Deliberately absent: a title, and multi-disc grouping.** Neither is on a PS1
  disc. The ISO volume-set fields that exist for precisely this
  (`volume set size`, `sequence number`) read **1-of-1 on every rip measured**,
  and the volume identifier is absent on Silent Hill, FF9 and Metal Gear Solid
  and is `SLUS_00067` on Castlevania — it is not a title. Serials are per DISC
  and their multi-disc conventions do not even agree with each other: FF7 is
  SCUS-94163/94164/94165 (consecutive) while FF9 is
  SLES-02966/12966/22966/32966 (a digit swapped in place). DuckStation answers
  both questions from a curated Redump-derived `gamedb` — `Entry.disc_set` →
  `DiscSetEntry.serials` — and the libretro cores make the user write an
  `.m3u`. So **`DiscGrouping` is unchanged and stays filename-driven**, and
  two rules that looked attractive were rejected on measurement rather than
  taste: grouping on a shared volume id would merge two unrelated discs that
  happen to share one (a wrong merge HIDES a game, where a missed merge merely
  shows two tiles), and splitting a group on differing regions would split a
  real group whenever one disc of it failed to identify.

## CDROM — state of play

The controller is in decent shape (it boots real discs); these are the things
that bit hardest and must not be regressed.

- **`step` is DEFERRED, and the deferral is the single sharpest edge in this
  file.** It used to run six timer checks per emulated instruction — ~11.7M
  times a second — and in the steady state every one of them was a no-op: a
  sector is ~450k cycles out and the tightest deadline of the six, the
  768-cycle CD-audio tick, is still ~300 instructions away. It was **12% of
  total emulator runtime**, most of it the call into this 700 KB struct rather
  than the work. `step` is now an inline three-instruction guard on
  `event_countdown`, and the body runs about once every 300 instructions
  (2.47x -> 2.83x realtime on Croc, measured with `ps1-bench`). Four rules, all
  of them load-bearing and two of them shipped broken first:
  - **`nextDeadline` must name EVERY timer the slow path acts on.** One left
    out is not a late event, it is an event that never fires at all — the guard
    steps straight past it.
  - **`applyElapsed` is separate from the firing in `stepEvents` because the
    body's blocks are ORDER-DEPENDENT.** The seek block sets `sector_timer` and
    the read block three lines below charges it *that instruction's* cycles;
    the same goes for the `delay` on an interrupt a command has just queued.
    Handing the body a whole batch charges those up to 768 cycles instead of
    2 — so the first sector after every seek lands early, and that gap is
    exactly what stops a GetStat poll eating its own INT1 (see the entry
    below). The batch is therefore split: skipped cycles land in
    `applyElapsed` as a pure decrement that cannot fire anything, then the
    **unmodified** per-instruction body runs with only this step's cycles.
  - **`catchUp` re-arms unconditionally, BEFORE its early return.**
    `commands.zig` arms a fresh timer on the next line of the register write
    that called it, and a deadline derived from the state before that write
    would stand. It looks harmless — the audio tick forces a settle within 768
    cycles regardless, so the command still runs, just late — which is why it
    needs `ps1-golden` and not an eyeball: it moved four of ten workloads,
    3,000 samples later than the other bug did.
  - **`pending_cycles`/`event_countdown` are deliberately NOT in the state
    hash, and `ps1-golden` calls `catchUp()` before each sample instead.**
    That is what let the goldens captured before this rewrite verify it
    unchanged rather than be recaptured around it — the strongest available
    evidence that a pure-performance change is pure. Settling cannot fire
    anything (the guard only skips cycles no deadline falls inside), so the
    timers then hold exactly what a per-instruction tick would have left.
  `updateInterrupts` got the same treatment, with an inline early-out on an
  empty queue and a low line. Pinned by two tests in `cdrom_test.zig`, each
  verified to FAIL against its own bug — a guard test that cannot fail is
  worse than none here.

- **The drive asserts a level; I_STAT latches the edge.** `updateInterrupts()`
  computes the line as
  `item.delay <= 0 and !item.ack and (irq_enable & item.irq & 7) != 0`
  and calls `interrupts.trigger(.Cdrom)` **only on a low→high transition**
  (`irq_line`). Writing the CDROM IFR also forces the line low, so the next
  queued response produces a fresh edge. Both halves are load-bearing and both
  have been wrong here before:
  - Re-latching on the *level* (which is what Avocado `cdrom.cpp:173-179` does,
    and what this code did from June until 2026-08-08) delivers a **phantom
    second interrupt**: the BIOS/PSn00bSDK handler acknowledges I_STAT *before*
    it writes the CDROM IFR, so the level immediately re-sets the bit. The
    handler re-enters, reads an IFR that now reads 0, and records IRQ=0 —
    `cdrom/getloc`'s "GetlocL failed, IRQ = 0" was exactly this.
  - A once-only latch *per queue item* (the pre-June model) loses any interrupt
    that is queued while masked and enabled afterwards. Tracking the line gets
    that case right; a per-item flag does not.
  Regression tests in `cdrom_test.zig` pin all three behaviours.
  *(The keep-unread-bytes ACK/`readResponse` retain-logic is correct — do **not**
  "fix" byte loss there. An acked-but-undrained item keeps its bytes readable but
  must report 0 in the IFR.)*
- **Drive state is decoupled from `irq_queue`.** Every command byte still calls
  `irq_queue.clear()` (`cdrom/commands.zig:9`), so anything encoded as a queued action
  is lost by a polling loop. `drive_state` is therefore set **synchronously** in
  the command, and the Seeking→Reading transition is driven by `seek_timer` in
  `step()` (`cdrom/cdrom.zig:272`), gated on `read_after_seek` so SeekL/SeekP (which
  resolve via their own queued INT2) are unaffected.
- **ReadN's 1,000,000-cycle seek is load-bearing — do NOT "port" it.**
  (`cdrom/commands.zig:55-74`.) Avocado's `cmdReadN` sets Reading immediately and lets a
  free-running counter deliver sectors. Porting that faithfully makes Crash
  Bandicoot die at the point every BIOS already fails at with SCPH-101 (the
  loader overruns its decompression buffer into the kernel vectors). The real
  defect is elsewhere in the read pipeline; don't correct this line in isolation.
- **The first sector after a seek costs a full sector period — the drive must
  not deliver one in the instant it starts Reading.** When `seek_timer` expires,
  `sector_timer` is set to `cyclesPerSector()`, not `0` (`cdrom/cdrom.zig`).
  This is not cosmetic pacing. Software polls GetStat waiting for the Reading
  bit, and **every command clears `irq_queue`**, so an INT1 posted in the same
  instant that bit goes up is destroyed by the very poll that observed the
  transition — and the caller then receives sector *n+1* as its first sector.
  Tekken 3's CD library catches that: its data-ready ISR reads the 12-byte
  header/sub-header with `CdGetSector(buf, 3)`, converts it back to an LBA and
  compares it against the one it asked for, retrying the whole read on a
  mismatch. With the zero gap it retried Pause/Setmode/Setloc/ReadN from the
  same position forever, which is what wedged every headless run on the
  "STAGE 1 XIAOYU VS JIN" screen. Fixed 2026-08-17, pinned by a test in
  `cdrom_test.zig`. Note this is *not* the invented 1,000,000-cycle ReadN seek
  above; that is untouched, and this gap is added after it.
- **The data FIFO is latched on Request(0x80), not filled on sector arrival**
  (`cdrom/cdrom.zig:167-187`), and only when the previous sector has been fully drained
  (`if (self.data_fifo_empty)`, Avocado `cdrom.cpp:396`). Re-latching mid-transfer
  rewinds the read pointer and splices a newer sector into an in-flight DMA —
  that hung Crash's Jungle Rollers.
- **Command acknowledge delays matter — a lot.** `ack_delay` is `50000`
  (`cdrom/commands.zig:22`), not the old `1000`; acking ~50x too fast broke Crash's boot.
  A few commands have Avocado's specific values (ReadN 1000, ReadS 500, SeekL
  5000, SeekL/SeekP second response 500000). The rest still share `ack_delay`,
  which is a known approximation.
- **XA-ADPCM submode masks** distinguish video vs audio vs form2 sectors; getting
  them wrong silently drops all in-game music (Croc). The decoder is a direct
  Avocado port.
- **An XA-ADPCM sector the decoder consumes must NOT post INT1.** With Setmode
  bit6 set, a real-time audio sector (submode audio|form2|realtime) belongs to
  the audio decoder alone: it never reaches the data FIFO, and a sector the
  filter rejects is dropped just as silently. That is the entire point of the
  interleave — a game issues one ReadN over a file of mixed data and audio
  sectors and sees a *contiguous* data stream with the music playing underneath.
  Posting INT1 for them as well splices audio bytes into the game's stream and
  desyncs every structure it parses. **Avocado has this bug** (`handleSector`
  calls `ackMoreData()` before it looks at the submode, `cdrom.cpp:109`), so it
  is not an oracle here — this is the second Croc/Silent Hill-class defect that
  diffing against it could not find. Croc's title cutscene reads its camera
  script through such a stream: the extra sectors desynced it, it parsed an
  all-zero record, and passed a field-of-view of 0 to SetGeomScreen. With
  **H = 0 the GTE divide returns 0 for every vertex**, so RTPS/RTPT project the
  whole scene onto (OFX>>16, OFY>>16) — the screen-filling wedges before
  `PRESS START`, plus a 40M-instruction stretch where the game rendered nothing
  at all. Fixed 2026-08-13, pinned by a test in `cdrom_test.zig`. Note the gate
  is Setmode **bit6**: with ADPCM off the drive is not decoding, so the same
  sector is ordinary data and does post INT1.
- **CD-DA (Red Book) playback is a second, separate audio path from XA.** A game
  whose music is on audio tracks (Tomb Raider: 1 data track + 56 audio tracks)
  gets nothing from the XA decoder. `readNextSector`'s `.Playing` branch reads
  the raw 2352-byte sector as 588 stereo 16-bit frames straight into the same
  `audio_fifo_*` the SPU drains, gated on `!muted` and mode bit0 (`cddaEnable`).
  Two traps here, both of which were live bugs:
  - The CDDA **report** gate is mode **bit2** (`0x04`), not bit4 — bit4 is the
    "ignore" bit. Reports also fire on a frame cadence (absolute every 0x20
    frames, track-relative offset 0x10 into that window), not once per sector.
  - **`Play` takes an optional track-number parameter** and must seek to that
    track's INDEX 01. Dropping it leaves the drive in the previous track's
    INDEX 00 pregap, which is digital silence on the disc — the game plays,
    the drive spins, and you hear nothing.
  - **Mode bit1 is CDDA autopause, and a missing INT4 hangs games outright.**
    When playback crosses out of the track it was started on, the drive stops
    and reports INT4. `Drive.previous_track` is latched by `Play` and advanced
    in `cdda.zig`, so only a real boundary crossing fires. Rayman plays its Ubi
    Soft logo jingle from track 2 with mode `0x07` and spins on a flag its CD
    callback sets only from that INT4; without it the drive ran on into track 3
    and the logo stayed up forever (fixed 2026-08-11). Avocado's own version
    carries a "Broken :(" comment about firing too early in Ridge Racer — the
    `previous_track` latch on `Play` is what avoids that. Pinned by two tests in
    `cdrom_test.zig`, including a control that playback *without* bit1 crosses
    boundaries freely (a game streaming consecutive tracks must not be cut off).
- **LibCrypt discs need their `.sbi` sidecar, and the mechanism is the opposite
  of what the file format suggests.** Much of Sony Europe's own PAL catalogue
  (Final Fantasy IX among it) hides a key in the subchannel Q of 32 sectors.
  Each of those sectors carries a Q with a **deliberately broken CRC**, so a
  real drive discards the frame and goes on reporting the *previous* position —
  and that stall is what the protection measures. The corrupt MSF values the
  sidecar records never reach software at all, which is why
  `Disc.isLibCryptSector` reads only the address out of each 14-byte record and
  `updateSubchannelQ` returns early without touching `last_subchannel_q`.
  Serving the corrupt Q instead — the obvious reading of the format, and what
  this code did first — leaves the check failing exactly as if no sidecar were
  present: FF9 sweeps its 16 sectors forever behind a black screen, retrying
  from GetID. Avocado gets this right via `q.crc16 = ~q.calculateCrc()` in
  `disc/disc.cpp`'s `loadSbi` plus `if (q.validCrc())` at
  `device/cdrom/cdrom.cpp:29`, so it *is* an oracle here — unusually.
  Sidecars are loaded from `<disc>.sbi` by `ps1-trace` and `ps1-golden`, in
  the browser by `allocSbiBuffer` from the uploaded folder, and in the macOS
  app by `EmulatorViewModel.sidecar(forDisc:)` through `ps1_load_disc`'s
  `sbi` argument; `ps1-debug` does not load them (it takes a raw `.bin` and
  caps at 700 MB, so it cannot open these discs anyway).
- **The subchannel Q and the sector header must describe the same sector.**
  `readNextSector` used to refresh both *before* advancing `current_pos`, so
  GetlocP reported the sector before the one just handed over. Nothing noticed
  for months, because only software that correlates the two can see it —
  LibCrypt does exactly that, and with the Q one sector late every protected
  address reads back clean. Fixed 2026-08-19, pinned by a test in
  `cdrom_test.zig`. It moved the `cdrom` state hash of every disc workload and
  nothing else, which is what the accompanying golden recapture records.

- **A disc swap is a TRAY, not a slice replacement.** `swapDisc` opens the
  shell, installs the disc and closes the tray one emulated second later
  (`shell_open_cycles`); status **bit 4 is derived, never stored**, from
  `shell_open or shell_changed`, and `shell_changed` is STICKY — it survives the
  close and is consumed only by a `Getstat` issued once the tray is shut. That
  latch is the entire mechanism by which a game learns its disc changed and
  re-reads the TOC instead of trusting the file table it cached from the
  previous one; `setDisc` alone is invisible to it. Commands during the window
  are refused with PSX-SPX's `INT5(stat+1, 80h)`, which with the motor off is
  the `{0x11, 0x80}` Avocado hardcodes into GetID alone — the general form gets
  GetID right and every other command with it. **Avocado is not an oracle
  here**: it models `shellOpen` but neither the latch nor its clear, and swaps
  in one instant, so on its own model a polling game has nothing to observe.
  **`shell_close_timer` MUST stay in `nextDeadline`, and not for the usual
  reason.** `applyElapsed` clamps it at 0 and fires nothing; `stepEvents` is the
  only thing that calls `closeShell`, and only on a timer still above 0. Bounded
  by the unconditional 768-cycle audio tick alone, one batch lands the last of
  the window on exactly 0 inside `applyElapsed` and the close is lost for the
  rest of the run — tray stuck open, every command refused forever. Two tests in
  `cdrom_test.zig` pin it, both verified to FAIL with that line deleted.
  Reached over the ABI as `ps1_swap_disc` (which shares `prepareDisc` with
  `ps1_load_disc`, so the validation and the sidecar-copy ordering cannot
  drift), and in the app through `EmulatorRunner.requestDiscSwap` — queued for
  the emulator thread, because `runLoop` owns the core and a main-actor call
  would widen the race `reset()` documents. `shell_open_cycles` is the one
  number here with no hardware measurement behind it and is the first thing to
  vary if a title will not cross a disc boundary.

Known remaining gaps (fix opportunistically, none currently blocking):
- `executeCommand` forces `busy_for = 0` (`cdrom/commands.zig:10`); Avocado sets
  `busyFor = 1000`. Setting it here asserts STAT bit7 and blocks CdStatus polls.
- GetlocL's error response is `{stat|0x01, 0x80}` (`cdrom/commands.zig:148`); Avocado
  sends just `{0x80}`. PSX-SPX documents `INT5(stat+1, 80h)`, so ours is the one
  that matches hardware — leave it.
- No seek-past-end error path (sticky seek-error bit `0x04` + INT5), and
  `getSubchannelQ` has no lead-out (`0xAA`) track. `cdrom/getloc` exercises both,
  but only with a disc in the drive — there is no way to check an implementation
  of either against that test from the EXE-sideload harness, so build a synthetic
  `Disc` in `cdrom_test.zig` if you take these on.
- The disc-less `synthesizeHeaderAndQ` path hardcodes values; it cannot reproduce
  lead-out, seek-past-end, or the pregap index-00 countdown.

### CDROM / disc gotchas
- **Where a sector's user data starts depends on the sector's own mode byte.**
  A raw 2352-byte sector is sync(12) + header(4), and the header's last byte
  (raw offset 15) is the mode. **Mode 2 adds an 8-byte sub-header, so its 800h
  data bytes begin at 018h; Mode 1 has no sub-header and begins them at 010h.**
  The Request(0x80) latch in `cdrom/cdrom.zig` picks between them on that byte;
  any other value keeps the Mode 2 offset, so synthetic zero-header sectors in
  tests read as they always did. This is a **deliberate divergence from
  Avocado**, whose `dataStart = 12; if (!mode.sectorSize) dataStart += 12;`
  gets Mode 1 wrong (`cdrom.cpp:127` literally asks "Does PSX even support
  Mode1?"). Taking 018h on a Mode 1 disc shifts every sector eight bytes late
  and makes its ISO filesystem unreadable — the BIOS then fails to find
  SYSTEM.CNF, falls back to the default boot file `cdrom:PSX.EXE;1`, fails to
  open that too, and parks forever in `SystemErrorBootOrDiskFailure('B', 906)`.
  This also settles the old `disc.zig`/`cdrom.zig` "sub-header offset
  disagreement": 16 and 24 are both right, for Mode 1 and Mode 2 respectively.
  Note `games/` is nearly all MODE2/2352, so this bug hid for months.
- **A boot that dies in `SystemErrorBootOrDiskFailure` may mean the disc image
  is not a PlayStation disc at all.** Before suspecting the CD stack, parse the
  image: PVD at LBA 16 (`\x01CD001` at the mode-appropriate offset), a
  `SYSTEM.CNF` in the root, and a non-zero "Licensed by ..." string in the
  license area at LBA 4. The bare `PlayStation™`/`SCEA™` screen with no coloured
  PS logo and no "Licensed by" line is the BIOS's *unlicensed-disc* screen, not
  a GPU bug: the same BIOS draws that screen perfectly for Croc. The
  `Rayman (Europe)` rip used to be exactly this case — it was the PC/DOS release
  — but **it was replaced with the real PS1 PAL rip on 2026-08-11**, which boots
  to gameplay. Re-run the three checks against the current image before
  believing any "not a PlayStation disc" note.
- **GetID hardcodes `SCEA`** (`cdrom/commands.zig`), and Test `0x22` hardcodes
  `"for U/C"`. On hardware that 4-byte string comes from the *console's* drive
  firmware, so a PAL machine reports `SCEE`. The visible tell is the BIOS boot
  screen printing `SCEA™` under `Licensed by ... (Europe)` even on SCPH-7502.
  Nothing is known to gate on it yet, but a region-checking protection would.
- **MSF fields are always BCD.** `MSF.fromLba/fromFrames` return BCD; `toLba`
  decodes. Never `binaryToBcd` an MSF field — it double-encodes. `toLba` subtracts
  the 150-frame lead-in (MSF `00:02:00` == LBA 0). `fromLba` re-adds 150 (absolute
  disc MSF); `fromFrames` does **not** (relative-in-track MSF). Mixing them shifts
  positions by 2 seconds.
- The interrupt model is an `irq_queue` FIFO; **only the head item's `delay` ticks**.
  A queued second response (INT2/INT5) can't fire before the first INT3 is ACK'd
  and popped — matches Avocado's structure.
- `disc.zig` parses **CUE sheets** into up to 99 `Track`s (`initFromCue`), with
  per-track type (data/audio), `start_lba` (INDEX 01) and `pregap_lba` (INDEX 00).
  Multi-`FILE` cues are laid out using `REM FILESIZE` lines; a cue without them
  will stack every FILE at the same base LBA. `Disc.init(bytes)` is still the
  raw-`.bin` fallback: one data track at LBA 0. The underlying image is always
  flat **2352 bytes/sector**.
