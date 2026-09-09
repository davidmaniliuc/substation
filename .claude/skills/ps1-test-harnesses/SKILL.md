---
name: ps1-test-harnesses
description: Use when running or changing any test harness - ps1-golden (zig build trace-golden - verify, capture, stream-verify, pgxp, stream-capture), the JaCzekanski and PeterLemon ROM suites, or the .p1fx fixture generator - and when a golden or a pixel floor needs recapturing. Covers what the trace goldens do and do not prove, workload discovery rules, per-region coverage gaps, and the status of the shelved ROM tests.
---

# The trace-equivalence harness

## The trace-equivalence harness

`ps1-golden` (a fifth frontend, `ps1-golden/src/main.zig`) boots the BIOS plus
each disc in `games/` for 600M instructions and, every 2,500,000 instructions,
folds full machine state into twelve per-region 64-bit hashes, diffing against
goldens checked into `ps1-core/tests/goldens/trace/`. It is the behaviour-freeze
net for the P1-P8 core-wide structural refactor — before it existed,
`cdrom/` and `cpu/` had no automated coverage at all from a real disc
boot; the 9 unit-test files and the two ROM suites don't touch either from a
CD-boot path.

**What it does and does not prove.** `ps1-golden` checks *equivalence against
a recorded baseline*, not *conformance to hardware*. A green sweep means the
refactor changed nothing the harness can see; it does not mean the baseline
itself was correct — a bug present when a golden was captured is baked in and
will pass forever. Treat "all eight OK" as "this commit didn't change
behaviour," never as "this behaviour is right." Hardware/golden-log
conformance is what the JaCzekanski suite and PeterLemon ratchet are for.

- `zig build trace-golden -- capture` rewrites the goldens. **Only do this when
  an intentional behaviour change lands**, as its own commit, with the diff
  explained in the message.
- `zig build trace-golden -- verify` is the gate. Real flags (runtime
  arguments to `ps1-golden`, not `-D` build options — they don't force a
  rebuild): `--filter=<substring>` narrows to one workload,
  `--interval=<n>` tightens sampling to localise a divergence,
  `--instructions=<n>` overrides the per-workload instruction budget, and
  `--bios=<path>` overrides the auto-selected BIOS.
- **State dumps in `state_hash.zig` are written by hand, never by reflection.**
  Reflection would make the check follow a refactor instead of policing it. When
  a field moves, update the dump in the same commit — the hashes must still match.
- Excluded on purpose, all documented in-file: host pointers (`cpu.bus`,
  `tty_write_fn`), host toggles (`cdrom.debug_enable`, `spu.reverb_enable`), and
  `cdrom.disc` (a slice whose address varies per run). BIOS and expansion RAM
  are hashed once at start and end of the run rather than per sample — if that
  pre/post hash doesn't match, `verify` reports the workload as diverged (the
  static region is assumed constant; a mismatch means something wrote to BIOS
  or expansion space, which is itself a bug worth knowing about).
- **Workloads: `bios-only` plus every single-`FILE` disc in `games/`**,
  auto-discovered from `games/*/*.cue` (gitignored, so a missing directory just
  falls back to `bios-only`) — currently `crash-bandicoot-europe-edc`,
  `crash-bandicoot-warped`,
  `crash-bandicoot-2-cortex-strikes-back-europe-australia-en-fr-de-es-it-edc`,
  `croc-legend-of-the-gobbos`,
  `metal-gear-solid-special-missions-europe-enfrdeesit`, `resident-evil-usa`,
  `silent-hill-usa`, `spyro-the-dragon-usa`, `tr1-usa-v1-1` — 9 discs plus
  `bios-only`, 10 workloads total. **Multi-`FILE` cues skip by rule**:
  `Disc.initFromCue` takes a single data slice, so any cue declaring more than
  one `FILE` is skipped (`countCueFiles != 1`) — today Castlevania (2), Tekken 3
  (3), Doom (8), Tekken (28) and **Rayman (51, since the PS1 rip replaced the
  PC one)**. It's a rule, not a set of one-off exclusions. A
  *multi-disc* game is skipped by a different rule — one directory holding more
  than one `.cue` (Final Fantasy IX's four) is ambiguous, so it is passed over.
  Six directories are skipped in total by these two rules today.
- **`verify` exits non-zero for a disc that has no golden**, which reads like a
  regression and is not one. This is a real rule to know before panicking at a
  red `verify` — it just does not have a live example today: as of the Phase 0
  recapture (Task 8, 2026-08-23) every disc under `games/` that isn't skipped
  by the two rules above — including `resident-evil-usa`, which used to be the
  example here — has a golden, and `verify` reports OK for all ten workloads.
  Note the workload name is derived from the directory, so *replacing* a rip
  can orphan its golden under a name that no longer exists — that is what
  happened to `rayman-europe.txt` (the disc is now `rayman-europe-en-fr-de`,
  and skipped).
- **BIOS is auto-selected per workload FROM THE DISC** since 2026-09-08:
  `loadMachine` attaches the disc before it reads the BIOS, so
  `discid.identify` picks it (see the `ps1-cdrom-disc` skill).
  The old rule — `(Europe)` → `SCPH-7502`, `(Japan)` → `SCPH-1000`, otherwise
  `SCPH-1001` — survives as `biosForKey`, and is still what the disc-less
  workloads use and what a disc naming no region falls back to. A US BIOS in
  front of a PAL disc stops at the region-lock screen and wastes the workload;
  `--bios=<path>` beats both. The switch moved no workload (every rip in
  `games/` has a name that already agreed with its disc) and `verify` was green
  across all ten, which is the point — the harness now gets the right answer
  for the right reason rather than by luck.
- **Per-region coverage is uneven, and a refactor bug can hide in the gap.**
  Across each workload's 240 samples: `ram`, `cpu`, `spu`, `gpu` and `timer`
  take on a distinct value every single sample (240/240) in every workload.
  `cdrom`, `vram`, `dma`, `io`, `sio` and `interrupt` move far less densely and
  vary a lot by workload. Sharpest edge: **`mdec` is pinned at one constant
  value for all 240 samples in most workloads** (`bios-only`,
  `crash-bandicoot`, `metal-gear-solid`, `spyro`) — it only moves in
  `croc`, `silent-hill` and `tr1`, the three titles that decode FMV. A refactor
  bug confined to the non-FMV MDEC paths would pass most goldens silently.
  `io` is similarly pinned in `bios-only` alone: a disc-less boot configures
  MEMCTRL once at startup and never touches it again — expected, not alarming,
  but worth knowing before you trust an `io` "OK" from that workload alone.
- **The injected-bug self-check needs a disc workload and a production-sized
  budget — a cheap smoke run proves nothing.** At 60M instructions (the plan's
  original Task 7 number) it caught nothing, because no workload has reached
  the CD command path yet at that budget — croc's first `ReadN` lands around
  90-100M instructions. At the real settings (600M instructions, croc), flipping
  `cdrom/commands.zig`'s `ack_delay` from `50000` to `49999` is caught cleanly:
  `FAIL @ instr 97500000`, attributed to `cdrom`, with `cpu` and `ram` moving too
  as knock-on effects. If you re-run this check at a small instruction budget and
  it finds nothing, that is expected, not evidence the harness is broken.
- Goldens are plain text, 245 lines each (5 header lines + 240 samples), and the
  full set of 10 is about 503 KB.

## The ROM suites: what is shelved and why

The `cdrom/getloc` ROM test and the JaCzekanski suite generally are
**shelved** — 5 of its 17 tests still fail. That work was traded for
real-game boot, which found far more real bugs per hour. See
the `ps1-cdrom-disc` skill for what got fixed along the way.

`gte/test-all`, `cpu/io-access-bitwidth` and `spu/memory-transfer` now pass.
**Three of the five still red are hangs, not mismatches** — re-triaged
2026-08-08 by reading the actual diffs, because the older one-line summaries
here hid that:
`mdec/4bit` and `mdec/8bit` spin forever in `common/mdec.cpp`'s
`while (mdec_dataOutFifoEmpty());` because the *monochrome* MDEC decode path
does not exist (a one-block layout instead of the 6-block colour macroblock;
Avocado does not implement it either), so the data-out FIFO never fills.
Implementing it fixes a real hang, but the goldens are stale besides — the
current ROM source hardcodes `int BS = 0x20;` where the golden logs
`blockSize=0x8`, plus a different buffer address.
`mdec/step-by-step-log` stops after ~1,056 bytes of a 124,980-byte golden,
dying right after `mdec_quantTa…`; cause unknown. (It *also* differs at byte 20
on an `itb`/`ehk` address, which is what this file used to blame — but that is
the smaller half of the problem.)
`cdrom/timing` hangs immediately after `psxcd: Init Ok!` and never prints a
measurement: 188 bytes against 2,551. Verified not a budget problem — 10x the
`max_cycles` produces byte-for-byte the same 188. Its assertions do want
real-hardware tick counts, but that is moot until the hang is fixed.
**`spu/memory-transfer` now passes** (2026-08-08). All four of its failures had
one cause: sync mode 1 never released the bus, so the CPU was frozen for the
whole transfer, its polling loop never ran, and `measuredCycles` came back
**0** — not "too fast". Fixed by pacing mode-1 blocks on the SPU channel
(`blockPacingCyclesPerWord` in `dma.zig`). Two things this file previously got
wrong, both worth remembering: there was **no need for a per-word cost change
at all** — RAM wait states already bill ~14 cycles a word, comfortably inside
the test's 6.4..70 window, so the "we bill 2" figure was the fallback constant
and not what the transfer actually costs; and the earlier abandoned attempt at
the bus release failed only because it handed the CPU **one instruction** per
gap (16 blocks = 16 instructions, not enough for the ROM's poll loop to
complete one iteration), not because a cost model was missing.
**`cdrom/getloc` can never pass**: its golden was captured against a different build of the ROM.
The shipped `getloc.exe` links a PSn00bSDK `psxcd` compiled with
`MAX_RESULT_SIZE == 7` (`slti at,a1,7` at 0x800115b4), so it drains only 7 of
GetlocP's 8 response bytes and `result[7]` — the absolute frame — always prints
`00`, where the golden has real values. Its remaining diffs also need a real
disc in the drive (lead-out track `aa`, seek-past-end, exact MSFs), which the
EXE-sideload harness cannot provide, and a distance-dependent seek time. It is
still worth running: the phantom-second-interrupt bug fixed on 2026-08-08 came
out of it.

## Running the ROM suites

- `enable_rom_tests` is a **compile-time `b.addOptions` flag**, not a `-D` CLI
  option. The `test` step hardcodes it `false` (compile-check + skip); each
  `test-roms-*` step hardcodes it `true`. Each ROM suite's run functions check it
  and `return error.SkipZigTest` when false.
- **`-Drom-filter=<substring>` narrows either ROM suite to matching tests.**
  `zig build test-roms-ja -Drom-filter="GPU - Mask Bit"` runs one ROM in ~11s
  instead of the whole suite. Essential when iterating on a single test.
- **Run the ROM suites with `-Doptimize=ReleaseFast`.** The steps honour it, the
  results are identical (still 12/17, same five), and it is ~25x faster: the whole
  JA suite drops from minutes to **27 seconds**, and a 500M-step single test from
  >10 minutes to 23. Debug builds of the suites only pay off when you need a
  stack trace or safety checks. (The core-in-Debug caveat in the browser-build
  note is about *real-time* behaviour, which the ROM suites do not depend on.)
- **`PS1_CD_PROBE=1` turns on the CDROM register trace in the JA harness** and
  echoes the ROM's TTY stream to stderr interleaved with it, which is the only
  way to line up printf output against register traffic. Always pair it with
  `-Drom-filter`; unfiltered it emits millions of lines.
