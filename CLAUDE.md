# CLAUDE.md — PS1 Emulator (Zig)

A thin, portable PlayStation 1 emulator core written in **Zig 0.16.0**. The core
(`ps1-core`) is driven by five frontends: a native debug harness, a native
execution-trace harness, a WebAssembly browser build, the test harness, and a
native trace-equivalence harness (`ps1-golden`). See `AGENTS.md` for the
original philosophy/roadmap; this file is the day-to-day engineering reference.

> **Current focus: booting and running real games from disc.** Croc, Silent Hill,
> Spyro and Crash Bandicoot all boot from a real `.bin`/`.cue` today. The open
> blocker is Crash Bandicoot hanging on the level-select map (never enters a
> level; vblank/CPU/input all verified healthy, and the game issues *zero* CD
> commands while hung).
>
> The `cdrom/getloc` ROM test and the JaCzekanski suite generally are
> **shelved** — 5 of its 17 tests still fail. That work was traded for
> real-game boot, which found far more real bugs per hour. See
> [§ CDROM — state of play](#cdrom--state-of-play) for what got fixed along the way.
>
> `gte/test-all`, `cpu/io-access-bitwidth` and `spu/memory-transfer` now pass.
> **Three of the five still red are hangs, not mismatches** — re-triaged
> 2026-08-08 by reading the actual diffs, because the older one-line summaries
> here hid that:
> `mdec/4bit` and `mdec/8bit` spin forever in `common/mdec.cpp`'s
> `while (mdec_dataOutFifoEmpty());` because the *monochrome* MDEC decode path
> does not exist (a one-block layout instead of the 6-block colour macroblock;
> Avocado does not implement it either), so the data-out FIFO never fills.
> Implementing it fixes a real hang, but the goldens are stale besides — the
> current ROM source hardcodes `int BS = 0x20;` where the golden logs
> `blockSize=0x8`, plus a different buffer address.
> `mdec/step-by-step-log` stops after ~1,056 bytes of a 124,980-byte golden,
> dying right after `mdec_quantTa…`; cause unknown. (It *also* differs at byte 20
> on an `itb`/`ehk` address, which is what this file used to blame — but that is
> the smaller half of the problem.)
> `cdrom/timing` hangs immediately after `psxcd: Init Ok!` and never prints a
> measurement: 188 bytes against 2,551. Verified not a budget problem — 10x the
> `max_cycles` produces byte-for-byte the same 188. Its assertions do want
> real-hardware tick counts, but that is moot until the hang is fixed.
> **`spu/memory-transfer` now passes** (2026-08-08). All four of its failures had
> one cause: sync mode 1 never released the bus, so the CPU was frozen for the
> whole transfer, its polling loop never ran, and `measuredCycles` came back
> **0** — not "too fast". Fixed by pacing mode-1 blocks on the SPU channel
> (`blockPacingCyclesPerWord` in `dma.zig`). Two things this file previously got
> wrong, both worth remembering: there was **no need for a per-word cost change
> at all** — RAM wait states already bill ~14 cycles a word, comfortably inside
> the test's 6.4..70 window, so the "we bill 2" figure was the fallback constant
> and not what the transfer actually costs; and the earlier abandoned attempt at
> the bus release failed only because it handed the CPU **one instruction** per
> gap (16 blocks = 16 instructions, not enough for the ROM's poll loop to
> complete one iteration), not because a cost model was missing.
> **`cdrom/getloc` can never pass**: its golden was captured against a different build of the ROM.
> The shipped `getloc.exe` links a PSn00bSDK `psxcd` compiled with
> `MAX_RESULT_SIZE == 7` (`slti at,a1,7` at 0x800115b4), so it drains only 7 of
> GetlocP's 8 response bytes and `result[7]` — the absolute frame — always prints
> `00`, where the golden has real values. Its remaining diffs also need a real
> disc in the drive (lead-out track `aa`, seek-past-end, exact MSFs), which the
> EXE-sideload harness cannot provide, and a distance-dependent seek time. It is
> still worth running: the phantom-second-interrupt bug fixed on 2026-08-08 came
> out of it.

---

## Quick commands

Run everything from the **repo root** (the harnesses read the BIOS, disc images
and test ROMs via paths relative to the process CWD).

| Command | What it does |
|---|---|
| `zig build` | Builds native `ps1-debug`, native `ps1-trace`, and the `wasm32-freestanding` `emulator`. |
| `zig build run` | Runs the native debug emulator (`ps1-debug`). Takes an optional disc path: `zig build run -- game.bin`. |
| `zig build test` | Runs the 9 unit-test files. **Both ROM suites also compile-check here but self-skip** (`enable_rom_tests=false`). |
| `zig build test-roms-pl` | Runs the **PeterLemon/PSX** graphical-conformance suite (`peterlemon_test.zig`, the `PL:` tests). Passes today — it's a pixel-match *ratchet*, see below. |
| `zig build test-roms-ja` | Runs the **JaCzekanski** hardware-conformance suite (`jaczekanski_test.zig`, the `ROM:` tests) against the golden `psx.log`s. 12/17 pass. |
| `zig build trace-golden -- verify` | Machine-state trace equivalence check against `ps1-core/tests/goldens/trace/`. The behaviour-freeze net that gated the P1-P8 core-wide refactor, and the regression gate for any change since. Run it `-Doptimize=ReleaseFast`. |

- `zig version` must be **0.16.0** (the std API here — `std.Io.Dir.cwd()`,
  `std.process.Init`, `std.ArrayList(...).empty`, `addRunArtifact` — is 0.16-specific).
- `enable_rom_tests` is a **compile-time `b.addOptions` flag**, not a `-D` CLI
  option. The `test` step hardcodes it `false` (compile-check + skip); each
  `test-roms-*` step hardcodes it `true`. Each ROM suite's run functions check it
  and `return error.SkipZigTest` when false.
- BIOS files (`SCPH-*.bin`) live in the repo root and are loaded at runtime by
  the ROM-test suites, `ps1-trace` and wasm; the **native `ps1-debug` harness
  embeds `ps1-debug/src/BIOS.BIN` at compile time** (`@embedFile`, must be
  exactly 512 KB).
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
- **The browser build is always `ReleaseFast`, whatever `-Doptimize` says**
  (`build.zig:44-74`, and it gets its own core module so the core isn't left in
  Debug). A Debug core runs ~5M instr/s against the ~11.7M a real PS1 needs
  (0.45x), which turns a 23-second boot into two minutes and **reads as a hang**.
  Debug builds of the core belong in `ps1-debug`/`ps1-trace`.

---

## Architecture: the CPU is the master clock

There is **no `Bus.step()`**. The whole machine is driven from `Cpu.step()`
(`ps1-core/src/cpu/cpu.zig:78`), called in a loop by each frontend. One `step()`:

1. Asks `bus.dma.isCpuStalled` — if DMA owns the bus, it runs **one DMA word**,
   ticks peripherals, and returns (CPU frozen). DMA is **cooperative,
   word-at-a-time**, not burst.
2. Intercepts BIOS TTY (`putchar` at A0/B0 vectors) → `tty_write_fn`. This is how
   all ROM `printf` output is captured. It's a **PC hack, not a real syscall**.
3. Raises a **Bus Error on instruction fetch** for PCs in scratchpad, I_STAT/I_MASK
   or the MDEC registers (`isInstructionBusErrorAddress`, `cpu/cpu.zig:68`).
4. Fetches the instruction (I-cache + waitstate timing), snapshots
   `delta_cycles = 1 + bus.wait_cycles`, then **resets `wait_cycles`**.
5. Checks the hardware IRQ line (folds into COP0 Cause IP2). If an interrupt is
   taken, the fetched instruction is **discarded and PC is not advanced**.
6. Advances the PC pipeline / delay slots, executes, then retires the load-delay
   slot — an explicit `writeReg` during `execute()` cancels a pending load
   (matches Avocado's `setReg()`).
7. `tickPeripherals(delta_cycles)` (`cpu/cpu.zig:173`) fans the cycles out **in this
   order — and the order matters**:
   `SPU → GPU → SIO → Timer0/1/2 → CDROM`, followed by
   `dma.tickCpuWindow(delta_cycles)` back in `step()`.
   Timer0 consumes GPU dotclock ticks and Timer1 consumes GPU hblank ticks
   produced earlier *in the same call*, so reordering breaks timer timing.
   `cdrom.updateInterrupts()` runs right after `cdrom.step()`.

**The GPU runs on a scaled clock.** `tickPeripherals` converts CPU cycles to
video cycles at **11/7** (53.2224 MHz vs 33.8688 MHz) with a carried remainder
(`gpu_clock_frac`). Without this the vblank period is ~1.57x too long relative to
the CPU-cycle root counters and the BIOS VSync wait times out during KERNEL SETUP.
The resulting frame period is NTSC-exact (~571,212 CPU cycles/frame) and is
**verified correct against the BIOS's own vblank counter — do not "fix" it.**

Consequences worth internalizing:
- **Load/store waitstates are billed one step late.** `delta_cycles` is snapshotted
  right after *fetch*; waitstates that `execute()`'s memory ops add land in
  `bus.wait_cycles` and are charged on the *next* `step()`.
- `Bus` is **heap-allocated** (`memory.zig:47`, `*Bus`) and owns every device
  inline. After `@memset(0)` it re-runs each device `.init()` because zero is not
  a valid default for several of them. `Cpu` is a value type that holds `*Bus`.
- Adding per-frame logic means editing the frontend loop or `tickPeripherals` —
  there is no central run-loop in `ps1-core`.

---

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
  `croc-legend-of-the-gobbos`,
  `metal-gear-solid-special-missions-europe-enfrdeesit`, `silent-hill-usa`,
  `spyro-the-dragon-usa`, `tr1-usa-v1-1`. **Multi-`FILE` cues skip by rule**:
  `Disc.initFromCue` takes a single data slice, so any cue declaring more than
  one `FILE` is skipped (`countCueFiles != 1`) — today Castlevania (2), Tekken 3
  (3), Doom (8), Tekken (28) and **Rayman (51, since the PS1 rip replaced the
  PC one)**. It's a rule, not a set of one-off exclusions.
- **`verify` exits non-zero for a disc that has no golden**, which reads like a
  regression and is not one. `resident-evil-usa` is in that state today. Note
  the workload name is derived from the directory, so *replacing* a rip can
  orphan its golden under a name that no longer exists — that is what happened
  to `rayman-europe.txt` (the disc is now `rayman-europe-en-fr-de`, and skipped).
- **BIOS is auto-selected per workload from the rip's name**: `(Europe)` →
  `SCPH-7502`, `(Japan)` → `SCPH-1000`, otherwise `SCPH-1001` (US). A US BIOS in
  front of a PAL disc stops at the region-lock screen and wastes the workload —
  `--bios=<path>` overrides this when you need to.
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
  full set of 8 is about 416 KB.

---

## Repository layout

```
ps1-core/            emulator core library (root.zig re-exports per-subsystem modules)
  src/
    constants.zig    cross-module hardware facts only (VRAM size, sector bytes, …)
    bits.zig         cast/bit idioms that clear the extraction bar (sext16/sext8)
    cpu/             cpu.zig (struct, step(), tickPeripherals(), exceptions, loadExe())
                     icache.zig (CacheLine, fetchInstruction) + exec.zig (all opXxx)
    cop0.zig         system coprocessor (SR/Cause/EPC, exceptions, RFE)
    cop2/            GTE geometry engine: cop2.zig (regs, flags, dispatch),
                     math.zig (divideUNR, MAC/IR saturation), opcodes.zig (opRtps..opCc)
    alu.zig          ALU helpers + PS1 mult/div quirks
    memory.zig       Bus: memory map, MMIO dispatch, waitstates; owns all devices
    interrupt.zig    I_STAT/I_MASK level interrupt controller
    timer.zig        the 3 root counters
    cdrom/           cdrom.zig (struct, step, sector read) + commands.zig + fifo.zig
                     + xa.zig (XA-ADPCM) + cdda.zig (Red Book, owns no state)
    disc.zig         disc model: CUE/TOC parsing, multi-track, MSF/LBA/BCD
    dma.zig          7-channel DMA (block/linked-list/chopping)
    mdec/            MJPEG-style FMV decoder: mdec.zig (registers, FIFOs)
                     + algorithm.zig (idct, decodeBlock, YCbCr->RGB)
    spu/             24-voice SPU: spu.zig, voice.zig, adsr.zig, reverb.zig,
                     noise.zig, regs.zig, gauss.zig (was spu_gauss.zig)
    gpu/             software rasterizer: gpu.zig, gp0.zig, renderer.zig, vram.zig,
                     registers.zig, color.zig (texel fetch/blend), primitive.zig
  tests/             disc/cdrom/cpu/gte/dma/gpu/spu/sio/mdec_test (unit; all 9 in `zig build test`)
                     peterlemon_test + jaczekanski_test (ROM suites) + rom_test_helpers
                     bios_trace.zig (scratch harness, not wired into any build step)
ps1-debug/           native CLI harness (embeds BIOS.BIN; optional disc path argv[1])
ps1-trace/           native execution-diff / component-boundary tracer (BIOS + disc at
                     runtime, optional "autostart" button injection)
ps1-wasm/            browser frontend (BIOS/EXE/bin/cue all uploaded from the page)
ps1-golden/          native trace-equivalence harness (BIOS + games/*/*.cue at
                     runtime; capture/verify goldens in ps1-core/tests/goldens/trace/)
test-roms/           JaCzekanski ps1-tests .exe + reference psx.log per test
avocado_ref/         C++ Avocado emulator source — the GOLD reference (gitignored)
```

---

## Reference material (use in this order when stuck)

1. **`avocado_ref/src/`** — the C++ Avocado emulator, checked out locally. This is
   the *authoritative implementation reference*; most of this Zig port is a
   translation of it. GTE math lives in `avocado_ref/src/cpu/gte/`, CDROM in
   `avocado_ref/src/device/cdrom/{cdrom.cpp,commands.cpp,cdrom.h,fifo.h}`.
2. **NoCash PSX-SPX** (<https://psx-spx.consoledev.net>) — hardware bible.
3. **Lionel Flandrin's psx-guide** — system-level interactions/timing.
4. **JaCzekanski/ps1-tests** — the source of `test-roms/`; each test has a golden
   `psx.log` captured on real hardware.

When porting/fixing, **diff against `avocado_ref` first** — many "quirks" in this
codebase are deliberate matches to (or unintended divergences from) Avocado.

### Debugging real games

The workflow that actually found the recent bugs:

1. Run headless with `ps1-trace <bios.bin> <disc.bin> <max_instr> <snapdir> [autostart]`.
   `autostart` cycles Start/Cross/Circle with real button codes so intros, FMVs
   and title menus get walked past and a run reaches gameplay.
2. Anchor on an event (a syscall, a GP0 command, a CD command), then do an
   **event-anchored PC diff** against Avocado's headless tracer to find the exact
   diverging instruction. Do *not* diff on cycle counts: Avocado bills 1 cycle per
   instruction and is waitstate-blind, so its clock and ours legitimately differ
   by ~3x. Diffing that number produces phantom "timing bugs".
3. For GTE specifically there's a replay harness: capture real GTE calls from a
   run, replay them through Avocado, diff per-opcode.

**`ps1-trace`'s `cd cmds:` histogram is dead instrumentation — it always prints
empty.** It samples `cdrom.pending_command` *after* `cpu.step()` returns, but a
command is latched and consumed inside that same step, so the counter never
sees one. Any past conclusion of the form "the game issues zero CD commands
while hung" that rests on it is unsupported — **including the one recorded for
Crash's level-select freeze.** To get a real command log, set
`cdrom.debug_enable = true` on the frontend and read the `CDROM cmd=` lines.

**A game sitting on a static screen is not necessarily hung.** Rayman's Ubi Soft
logo looked like a freeze and was one, but the piracy-notice and language-select
screens before it are *timed or input-gated* and take hundreds of millions of
instructions to pass. Before debugging, run long (1.5B) with `autostart`, and
diff consecutive `frame_*.ppm` snapshots: if the framebuffer stops changing
permanently, it's a hang; if it keeps animating, you are just early.

**Black screen + working audio** almost always means the CPU is parked in the
BIOS unresolved-exception hang, not a GPU bug — check PC before touching `gpu/`.

---

## CDROM — state of play

The controller is in decent shape (it boots real discs); these are the things
that bit hardest and must not be regressed.

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

---

## Per-subsystem cheat-sheet (sharp edges only)

**CPU / COP0 / ALU** (`cpu/{cpu,icache,exec}.zig`, `cop0.zig`, `alu.zig`)
- Triple-PC pipeline (`pc`/`next_pc`/`current_pc`) + dual load-delay pairs
  (`load_r/v`, `delay_r/v`) model branch-delay and load-delay slots. Interrupts
  are never taken in/just-before a delay slot.
- I-cache: 256 direct-mapped lines, cacheable only KUSEG/KSEG0 (not KSEG1), tag =
  vaddr & `0xFFFFF000` (virtual, so KUSEG/KSEG0 alias to different lines). Miss
  burst from RAM is a hardcoded **+7 cycles** (`cpu/icache.zig:37`). SR IsC rising edge
  flushes the whole I-cache.
- **An interrupt is never taken on a GTE command instruction**
  (`is_gte_command`, `cpu/cpu.zig`). Hardware has already issued the operation
  when the exception is recognised, so the BIOS handler *deliberately returns to
  EPC+4* — it reads the instruction at EPC and skips it when
  `(instr >> 24) & 0xFE == 0x4A`, the COP2-command encoding (kernel handler at
  `0x00000cc0`). Discard the instruction here and the handler's skip drops the
  operation outright: the GTE silently keeps its previous result. That is how
  Silent Hill got a stale colour-FIFO entry whose CODE byte turned an 8-word
  POLY_G4 into a 12-word POLY_GT4 and tore the rest of the display list.
  **Avocado has this bug too** (`CPU::checkForInterrupts`, no GTE case), so it is
  not an oracle here — diffing against it shows nothing. Pinned by a test in
  `cpu_test.zig`.
- PS1 div/mult quirks in `alu.zig:53-77` (div-by-0, INT_MIN/-1); computed instantly.
- SLTI/SLTIU dispatch through `iOpSignExt` + `alu.slt`/`sltu`. The unused
  `opSlti`/`opSltiu` that used to shadow that path were deleted in the P1-P8
  refactor; don't reintroduce them.

**GTE / COP2** (`cop2/{cop2,math,opcodes}.zig`) — **now a faithful Avocado port**, not the old
heuristic implementation. It has the real UNR reciprocal table + Newton-Raphson
`divideUNR` (`cop2/math.zig:23`), proper RTPS/RTPT projection with IR0 and
depth cueing, `farColor()` and the shared `depthCueWithRgbc` path used by
NCDS/NCDT/NCCS/CC/CDP (which correctly fold in the RGBC vertex colour), and
MAC1..3 write back the **sf-shifted** value so `mfc2` reads what hardware reads.
**It passes all 1150 `gte/test-all` cases** — treat that suite as the ratchet
before touching anything here.

MAC0..3 live in a separate `macs: [4]i64`, **not** `data_regs[24..27]`, but they
are **32-bit registers**: `storeMac` narrows on the way in, because the 44-bit
width belongs to the accumulator, not the register. Everything that reads a MAC
back — `mfc2`, the colour FIFO's `>> 4`, GPL's `<< sf` re-scale — must see the
narrowed value. Two more rules that cost real debugging time: **IR saturation
raises the same FLAG bit in both directions** (24/23/22, never the colour-FIFO
bits 21/20/19), and **IR is clipped from the low 32 bits of MAC**, which at sf=0
routinely disagrees in sign with the whole. MAC overflow trips at ±2^43.

`try` → field `try_`. The MVMVA matrix/translation selector bits were once
swapped — if 3D geometry is subtly wrong, re-check the operand decode first.
MVMVA's `mx=3` and `cv=2` select documented hardware *bugs*, not a second copy
of RT and an ordinary far-colour translation; OP crosses IR with the RT
diagonal, not its third column.

**GPU** (`gpu/`) — software scanline rasterizer, ABGR1555. **No texture/CLUT
cache** (re-reads VRAM per texel). GP0 goes through a real 16-word FIFO with a
`cycle_debt` budget; cycle "cost" is hand-tuned heuristics, not real clocks.
Quads decompose into 2 triangles (possible diagonal seam); the textured-rectangle
path avoids decomposition on purpose. Scanout uses the **programmed display area**
(`disp_env.screen_x1/x2`, `screen_y1/y2` → `getVisibleWidth/Height`), not the
nominal mode size. Every VRAM write except Fill Rectangle honours the GP0(E6)
mask bits: drawn pixels via `putPixel`, CPU->VRAM and VRAM->VRAM transfers via
`Vram.maskedWrite`. Fill Rectangle is unmasked **on purpose** — hardware ignores
E6 there. Bit15 of a drawn pixel is the **source** pixel's own bit15 (a textured
primitive's texel STP bit, 0 when untextured) OR'd with GP0(E6).bit0, and blending
carries it through — never clear it, games leave STP-set texels in VRAM
specifically to mask later check-mask draws (Silent Hill brackets its player that
way). VRAM transfers are a stateful multi-word FSM — a bug there silently swallows
real commands. A textured **polygon** latches its texpage word back into
GP0(E1) so GPUSTAT reflects it; a textured **rectangle** does not, because it
reads the current texpage rather than carrying one. GPUSTAT bit 15 is the E1
texture-disable bit, *not* GP1(09)'s "texture disable is allowed" latch.
Three more GPUSTAT bits are easy to get wrong: **bit 13 is hardwired to 1**
(it is the interlace field, not a PAL flag), **bit 27 is `readMode == Vram`**
— true only while a GP0(C0) transfer is in flight, so GPUREAD reports the
register once it drains and GP1(00) must not re-select VRAM — and **bit 25's
DMA request depends on the programmed direction** (off for 0, on for 1 and 2,
a mirror of bit 27 for 3).

**SPU** (`spu/`) — **reverb is live.** `doReverb` runs at 22.05 kHz (even
samples only; the odd sample re-adds the held `reverb_out_l/r`), after the
CD/external mixes and before main volume, behind `reverb_enable` (default on —
a host toggle, not hardware). Three rules that were all wrong before: SPUCNT
bit 7 gates the reverb SRAM **writes only** — reads still happen and
`reverb_curr_addr` still advances, so the gate lives inside `writeReverbSram`;
a write to 0x1F801DA2 must **rewind `reverb_curr_addr` to `base * 8`**; and
every reverb add/subtract **saturates to i16 individually**, because Avocado's
`Sample` type clamps on each `+`/`-` but not on `*` — summing the four comb
terms into one i32 and clamping once gives a different answer. `doReverb` is
pinned by two goldens (impulse + pseudo-random, 512 pairs each) generated from
Avocado's own `spu::doReverb`; regenerate via
`avocado_ref/build_headless.sh` → `build_headless/reverb_golden ps1-core/tests/goldens`,
and keep `ps1-core/tests/goldens/reverb_preset.zig` in step with the copy of the
preset inside `reverb_golden.cpp`.
**"Reverb disabled" does not mean "reverb silent."** Bit 7 gating the writes but
not the reads is faithful, and its consequence is sharp: with the reverb
registers unprogrammed and `reverb_vol_l/r` non-zero, both APF stages collapse to
`R(reverb_curr_addr)` and the stage reads raw voice-sample bytes back out as
full-scale noise — swept across all 512 KB, since `reverb_base` defaults to 0.
Avocado does the same, so real games presumably never sit in that state (libspu
zeroes the reverb volume in `SpuInit`), but no automated test boots a game, so a
regression here would surface as noise in a real title and nowhere else.
`reverb_enable` (default on) is the isolation switch; it has no setter, so
reaching it needs a recompile.
Two known gaps, both shared with Avocado: reverb SRAM accesses don't run
`checkIrq`, so a game using SPU IRQ as a timer with its IRQ address inside the
reverb work area would miss it; and an `sb` to 0x1F801DA2 now rebases
`reverb_curr_addr` onto a corrupted base, because `memory.zig` widens sub-word
SPU stores by re-dispatching the zero-extended byte at the unaligned address —
Avocado only rebases on the high-byte write to 0x1F801DA3. libspu uses 16-bit
stores throughout, so neither is known to fire.
Noise
+ ADSR are duckstation-style approximations, not Avocado's model. CD audio has its
*own* 768-cycle counter separate from the SPU's, so the two can drift. SPU IRQ is
level-style. Volume sweeps are not implemented (bit15 masked off). `decodeBlock`
is exported + unit-tested — keep its signature stable.
**The exponential-decrease step must stay signed.** Avocado keeps a decreasing
envelope's step negative and arithmetic-shifts it (`voice.cpp:67-73`), which
guarantees a magnitude of at least 1 and therefore that a release terminates.
Our step is positive, so `stepAdsr` negates around the shift. Scaling a positive
step and shifting right floors to **0**: the envelope stalls at a small non-zero
level, `is_on` never clears, and all 24 voices are permanently "busy" — a game
polling for a free voice then stops triggering sound effects entirely.

**DMA** (`dma.zig`) — cooperative, **one word per `step()`**. An active channel
stalls the CPU, so anything that leaves a channel active without a sane
`words_remaining` is a hard hang; sync mode 3 (reserved) must therefore start
no transfer at all (Avocado dispatches only modes 0/1/2). Channel priority is
*not* implemented (fixed 0..6 loop — matches Avocado). **Sub-word stores to DMA
registers must be shifted into the addressed byte lane**; latching the raw value
unshifted killed Croc's FMV entirely. DICR is a full-word latch, not byte-granular.
The CDROM 32-bit data path is a 4×8-bit-FIFO read special-cased in
`memory.zig:229`. Chopping mixes "words" and "cycles" as one counter (known
inaccuracy). There is a latent SPU-DMA overflow around `dma.zig:260`.
MDECin/PIO DMA effectively stubbed.
**Sync mode 1 hands the bus back between blocks, but only on the SPU channel**
(`blockPacingCyclesPerWord`). Mode 1 syncs to *device requests*, so the gap
between blocks is set by how fast the device asks for the next one — a
per-device rate, not a global one. Channel 3 already models its own request
signal (the `data_fifo_empty` check); the SPU gets a timed one at 32 cycles per
word end-to-end, which is the only rate we have a hardware measurement for
(`spu/memory-transfer`). Channels 2 (GPU) and 3 (CDROM) are deliberately left
unpaced: they carry the bulk of real game traffic, pacing them changes CPU/DMA
interleaving everywhere, and no disc image is present to smoke-test Croc or
Crash against it. A gap must be long enough for software to run a poll loop —
an earlier attempt granted one instruction per gap and changed nothing.
**A DMA word costs a per-channel hardware rate, NOT the memory map's wait
states** (`transferCyclesPerWord`, PSX-SPX "DMA Transfer Rates": 1 clk/word for
MDECin/MDECout/GPU/OTC, 4 for SPU, 20 for PIO, 24 for CDROM). Wait states
describe what the *CPU* pays to touch an address; the controller has its own
path to RAM. Summing both ends billed ~6 cycles for a GPU or MDECout word that
hardware moves in one, and because a DMA-stalled CPU still ticks the peripherals
with whatever the DMA billed, the overcharge came straight out of the CPU's
budget between CDROM sector interrupts. Croc's FMV starved on exactly that: it
missed roughly one STR chunk per frame, so the RLE stream feeding the MDEC
desynced and the decoder emitted 240 or 301+ macroblocks instead of 300 — a torn
right-hand side, plus a `MDEC_in_sync timeout` (leftover words keep MDEC_STAT
bit 29 busy) that froze video for ~1.7s. Fixed 2026-08-13; the give-away is that
`ps1-trace` showed sectors arriving ~40k instructions apart instead of ~143k
while the *cycle* cadence stayed constant. The wait states are still collected
into `bus.wait_cycles` around the transfer and discarded, so they leak into
neither clock.

**MDEC** (`mdec/{mdec,algorithm}.zig`) — **ported from Avocado and unit-tested** (`mdec_test.zig`;
these were the first tests this module ever had). It now honours the per-block
`qFactor` from the DCT word, the uploaded scale/IDCT table (`scale_table`), the
zigzag-bypass when `qFactor == 0`, coefficient clamping, the `+128` YCbCr→RGB
bias, and dense 24bpp packing (the striped-garbage bug in Silent Hill's FMV).
Output depth comes from the command word. The struct is **~768 KB by value**
(two 131072-entry FIFOs) and is held by value in `Bus`.
**MDEC_STAT bit 31 means data-out FIFO *empty*, not "data ready"** — it was
inverted, and since every decoder poll loop spins waiting for it to go low, the
inversion hangs the caller outright. The whole register now follows Avocado's
`MDEC::Status` (bits 30/29 FIFO-full/busy recomputed per read, 28/27 the DMA0/
DMA1 request bits gated by MDEC_CTRL 30/29, 26-23 the command's output format,
15-0 the remaining parameter words *minus one*). **Only the 24bpp and 15bpp
colour paths exist**: 4bpp and 8bpp are monochrome modes with a one-block
layout, so the decoder mis-parses them and emits nothing (Avocado does not
implement them either).

**Memory / interrupts / timers / SIO** (`memory.zig`, `interrupt.zig`,
`timer.zig`, `sio.zig`)
- I_STAT is **write-0-to-ack** (`stat &= value`) and is a **latch**: `trigger()`
  sets a bit that stays set until software acks. Most devices call it on a
  one-shot event, so the latch is all they need. A device that instead asserts a
  *level* must edge-detect on its own side before calling `trigger()` — see the
  CDROM's `irq_line` above. Calling `trigger()` every step from a level makes
  software that acknowledges I_STAT before acknowledging the device take a
  second, phantom interrupt.
- The JOY port raises **IRQ7 (Controller)**, not IRQ8 (that's SIO1 at `0x1F801050`).
- **The controller /ACK is deferred, and that is load-bearing** (`sio.zig`). A byte
  written to JOY_TX does *not* raise IRQ7 there and then; it arms `irq_timer`
  (`ack_delay` = 500, matching Avocado's `irqTimer = 5` ticked once per
  100-instruction batch), and `Sio.step()` — called from `tickPeripherals` —
  raises it later. The BIOS pad routine clocks a byte, waits, then clears *both*
  JOY_CTRL bit 4 and I_STAT bit 7 before polling for /ACK, so a synchronous
  interrupt is swallowed by the routine's own acknowledge; it then times out after
  ~81 polls and reports "no controller". Don't "simplify" this back.
- JOY_STAT bit 7 is the /ACK level (asserted while the pad is mid-packet, cleared
  by the read); bit 9 is the IRQ line, cleared by JOY_CTRL bit 4. Clearing
  JOY_CTRL bit 1 (deselect) resets the peripheral's transfer state — without it
  the state machine leaks across polls and desyncs permanently.
- The pad reports as a **digital** controller (ID `0x41`, 5-byte packet). The
  analog escape commands (`0x43`/`0x44`) aren't implemented, so `analog_enabled`
  is never set and the `CtrlJoy*` states are unreachable. Regression tests live in
  `tests/sio_test.zig`.
- Memory card **read/write commands (`0x81`) are emulated against an in-memory
  128 KB image** with a `memcard_dirty` flag, but nothing persists it — no
  frontend saves or restores the card.
- **Access width matters at two device ports.** The CDROM is an 8-bit device
  and a wider store hits the *addressed* port once per byte lane — it does not
  walk 0x1800..0x1803, which would drop a byte into the command register; a
  word read mirrors one status byte across all four lanes. And a CPU word read
  spanning 0x1F801DA8 covers two 16-bit *registers* (the SPU RAM transfer FIFO
  and SPUCNT), whereas DMA4 pops the FIFO twice — hence `Bus.dmaRead32`, which
  exists to keep those two paths apart.
- Several reads spoof magic values (`0xC0C00000` at SIO regs, `0x3C045678` shadow
  at Timer1 mode `0x1108`) to satisfy BIOS/test patterns — not real hardware.
- Timer mode read clears the reached-target/overflow latch bits (bits 11/12)
  per PSX-SPX (`timer.zig:17`); bit 10 (IRQ-request) and bit 6 (once/repeat) are
  still unimplemented.

**Frontends + test harness**
- `setDisc()` now has four callers: `ps1-debug` (optional argv disc path),
  `ps1-trace`, `ps1-wasm`, and `cdrom_test.zig`. The disc/CD-boot pipeline **is**
  exercised, but only by hand — no automated test boots a game from disc.
- The ROM suites (`peterlemon_test.zig`, `jaczekanski_test.zig`) still use
  `cpu.loadExe()` (PS-EXE sideload, bypasses BIOS CD boot) and leave `disc = null`.
- wasm exports are a hard ABI contract with `ps1-wasm/www/index.html` — renaming an
  export silently breaks the browser frontend. The page uploads BIOS, EXE, `.bin`
  and `.cue` (`allocCdBuffer` / `allocCueBuffer` / `loadCdFromBuffer`), including
  via a directory picker.
- `jaczekanski_test.zig` normalizes output (strip `\r`, strip leading `% ` prefixes,
  plus a hardcoded SIO_CTRL string fixup). Changing TTY formatting causes spurious
  mismatches until the normalizers are updated. `rom_test_helpers.zig` holds the
  shared `readTestFile`.
- **`peterlemon_test.zig` is a ratchet, not a pass/fail comparison.** It counts
  how many of the 71,680 framebuffer pixels match the test's `reference.rgb` and
  fails only if the count drops below the per-test `floor.txt` — so the suite
  passes today at 77–99% match, and its job is to catch GPU *regressions*. After a
  genuine rendering improvement, re-pin the floors with
  `PS1_UPDATE_GOLDENS=1 zig build test-roms-pl`.

---

## Conventions & housekeeping

- **Match the surrounding style.** This is a single-author codebase; structs use
  inline field defaults and devices expose `init()`. Subsystems big enough to
  split live in a directory whose entry file carries the struct
  (`spu/spu.zig`, `cdrom/cdrom.zig`); `root.zig` re-exports them under the
  *old* paths, so `ps1_core.spu.Spu` survives the move. Renaming an exported
  symbol breaks a frontend silently. Run `zig fmt` before committing.
- **No file in `ps1-core/src` over ~600 lines.** Split by function, mirroring
  `avocado_ref`'s layout where one exists.
- **Casts: Tier A over Tier B, always.** Tier A is letting Zig infer the cast
  target from the result location (`const s: i32 = @bitCast(a);`) — no new API,
  no review burden. Tier B is extracting a named helper into `bits.zig`, and
  the bar is high: an idiom must be **3+ operations AND appear at 4+ sites**.
  Count with `grep -c` before extracting; at 2 sites, leave it written out.
  Forty tiny wrappers nobody can remember is worse than the casts were.
- **Constants live in two scopes.** `constants.zig` holds only genuine
  cross-module hardware facts (VRAM dimensions, sector bytes, the 150-frame
  lead-in, the CPU clock). Everything else is a module-private `const` block at
  the top of its own file — `0x1F` is *not* one constant, it is a 5-bit colour
  channel in `renderer.zig` and an ADSR shift field in `spu/`.
- **Interrupts are level-based.** New devices should call
  `bus.interrupts.trigger(.X)` while their condition holds.
- **BCD/MSF discipline** (see CDROM section) is the #1 source of off-by-2-second
  and double-encoding bugs.
- **Watch for temporary probes in the working tree.** Debug scaffolding gets added
  to the frontends (currently a kernel-integrity / exception-storm probe in
  `ps1-wasm/src/main.zig`, and an audio-pipeline probe in `ps1-trace/src/main.zig`)
  and is meant to be reverted once its bug is closed. `avocado_ref/`, `*.bin`/
  `*.BIN` and `debug_output.txt` are gitignored.
- **`ps1-trace` takes a `.cue` as well as a `.bin`.** Passing the raw `.bin` uses
  `Disc.init`'s single-data-track-at-LBA-0 fallback, which cannot represent audio
  tracks at all — any CD-DA investigation must pass the `.cue`.
- **`std.log.warn` in `cdrom/`/`memory.zig` is gated on `cdrom.debug_enable`**,
  except the per-command line at `cdrom/commands.zig:7` and the unhandled-command warning.
  `ps1-debug` turns `debug_enable` on whenever a disc is passed.
- **Verify, don't guess.** When behavior is unclear, read `avocado_ref` and the
  relevant `psx.log`, and add a focused unit test in `ps1-core/tests/` that
  reproduces only the failure before changing core code.
