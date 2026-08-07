# CLAUDE.md — PS1 Emulator (Zig)

A thin, portable PlayStation 1 emulator core written in **Zig 0.16.0**. The core
(`ps1-core`) is driven by four frontends: a native debug harness, a native
execution-trace harness, a WebAssembly browser build, and the test harness. See
`AGENTS.md` for the original philosophy/roadmap; this file is the day-to-day
engineering reference.

> **Current focus: booting and running real games from disc.** Croc, Silent Hill,
> Spyro and Crash Bandicoot all boot from a real `.bin`/`.cue` today. The open
> blocker is Crash Bandicoot hanging on the level-select map (never enters a
> level; vblank/CPU/input all verified healthy, and the game issues *zero* CD
> commands while hung).
>
> The `cdrom/getloc` ROM test and the JaCzekanski suite generally are
> **shelved** — 8 of its 17 tests still fail. That work was traded for
> real-game boot, which found far more real bugs per hour. The most surprising
> one still red: `gte/test-all` fails from its very first test despite the GTE
> being an Avocado port. See
> [§ CDROM — state of play](#cdrom--state-of-play) for what got fixed along the way.

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
| `zig build test-roms-ja` | Runs the **JaCzekanski** hardware-conformance suite (`jaczekanski_test.zig`, the `ROM:` tests) against the golden `psx.log`s. 9/17 pass. |

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
- **The browser build is always `ReleaseFast`, whatever `-Doptimize` says**
  (`build.zig:44-74`, and it gets its own core module so the core isn't left in
  Debug). A Debug core runs ~5M instr/s against the ~11.7M a real PS1 needs
  (0.45x), which turns a 23-second boot into two minutes and **reads as a hang**.
  Debug builds of the core belong in `ps1-debug`/`ps1-trace`.

---

## Architecture: the CPU is the master clock

There is **no `Bus.step()`**. The whole machine is driven from `Cpu.step()`
(`ps1-core/src/cpu.zig:142`), called in a loop by each frontend. One `step()`:

1. Asks `bus.dma.isCpuStalled` — if DMA owns the bus, it runs **one DMA word**,
   ticks peripherals, and returns (CPU frozen). DMA is **cooperative,
   word-at-a-time**, not burst.
2. Intercepts BIOS TTY (`putchar` at A0/B0 vectors) → `tty_write_fn`. This is how
   all ROM `printf` output is captured. It's a **PC hack, not a real syscall**.
3. Raises a **Bus Error on instruction fetch** for PCs in scratchpad, I_STAT/I_MASK
   or the MDEC registers (`isInstructionBusErrorAddress`, `cpu.zig:132`).
4. Fetches the instruction (I-cache + waitstate timing), snapshots
   `delta_cycles = 1 + bus.wait_cycles`, then **resets `wait_cycles`**.
5. Checks the hardware IRQ line (folds into COP0 Cause IP2). If an interrupt is
   taken, the fetched instruction is **discarded and PC is not advanced**.
6. Advances the PC pipeline / delay slots, executes, then retires the load-delay
   slot — an explicit `writeReg` during `execute()` cancels a pending load
   (matches Avocado's `setReg()`).
7. `tickPeripherals(delta_cycles)` (`cpu.zig:237`) fans the cycles out **in this
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

## Repository layout

```
ps1-core/            emulator core library (root.zig re-exports per-subsystem modules)
  src/
    cpu.zig          R3000A interpreter + I-cache + the master step() loop; loadExe()
    cop0.zig         system coprocessor (SR/Cause/EPC, exceptions, RFE)
    cop2.zig         GTE geometry engine (all COP2 math) — ported from Avocado
    alu.zig          ALU helpers + PS1 mult/div quirks
    memory.zig       Bus: memory map, MMIO dispatch, waitstates; owns all devices
    interrupt.zig    I_STAT/I_MASK level interrupt controller
    timer.zig        the 3 root counters
    cdrom.zig        CDROM controller + interrupt queue + FIFOs + XA-ADPCM
    disc.zig         disc model: CUE/TOC parsing, multi-track, MSF/LBA/BCD
    dma.zig          7-channel DMA (block/linked-list/chopping)
    mdec.zig         MJPEG-style FMV decoder — ported from Avocado
    spu.zig          24-voice SPU (ADSR, noise, gaussian); reverb is DEAD CODE
    spu_gauss.zig    gaussian interpolation table
    gpu/             software rasterizer (gpu.zig, gp0.zig, renderer.zig, vram.zig, registers.zig)
  tests/             disc/cdrom/cpu/gte/dma/gpu/spu/sio/mdec_test (unit; all 9 in `zig build test`)
                     peterlemon_test + jaczekanski_test (ROM suites) + rom_test_helpers
                     bios_trace.zig (scratch harness, not wired into any build step)
ps1-debug/           native CLI harness (embeds BIOS.BIN; optional disc path argv[1])
ps1-trace/           native execution-diff / component-boundary tracer (BIOS + disc at
                     runtime, optional "autostart" button injection)
ps1-wasm/            browser frontend (BIOS/EXE/bin/cue all uploaded from the page)
test-roms/           JaCzekanski ps1-tests .exe + reference psx.log per test
avocado_ref/         C++ Avocado emulator source — the GOLD reference (gitignored)
```

---

## Reference material (use in this order when stuck)

1. **`avocado_ref/src/`** — the C++ Avocado emulator, checked out locally. This is
   the *authoritative implementation reference*; most of this Zig port is a
   translation of it. GTE math lives in `avocado_ref/src/device/gte/`, CDROM in
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

**Black screen + working audio** almost always means the CPU is parked in the
BIOS unresolved-exception hang, not a GPU bug — check PC before touching `gpu/`.

---

## CDROM — state of play

The controller is in decent shape (it boots real discs); these are the things
that bit hardest and must not be regressed.

- **The CPU interrupt is level-triggered.** `updateInterrupts()` (`cdrom.zig:854`)
  mirrors Avocado (`cdrom.cpp:173-179`): on **every** call,
  `if (item.delay <= 0 and (irq_enable & item.irq & 7) != 0) interrupts.trigger(.Cdrom);`
  — no `ack` gate, no once-only latch. Regression test in `cdrom_test.zig`.
  *(The keep-unread-bytes ACK/`readResponse` retain-logic is correct — do **not**
  "fix" byte loss there.)*
- **Drive state is decoupled from `irq_queue`.** Every command byte still calls
  `irq_queue.clear()` (`cdrom.zig:581`), so anything encoded as a queued action
  is lost by a polling loop. `drive_state` is therefore set **synchronously** in
  the command, and the Seeking→Reading transition is driven by `seek_timer` in
  `step()` (`cdrom.zig:389`), gated on `read_after_seek` so SeekL/SeekP (which
  resolve via their own queued INT2) are unaffected.
- **ReadN's 1,000,000-cycle seek is load-bearing — do NOT "port" it.**
  (`cdrom.zig:615-635`.) Avocado's `cmdReadN` sets Reading immediately and lets a
  free-running counter deliver sectors. Porting that faithfully makes Crash
  Bandicoot die at the point every BIOS already fails at with SCPH-101 (the
  loader overruns its decompression buffer into the kernel vectors). The real
  defect is elsewhere in the read pipeline; don't correct this line in isolation.
- **The data FIFO is latched on Request(0x80), not filled on sector arrival**
  (`cdrom.zig:290-310`), and only when the previous sector has been fully drained
  (`if (self.data_fifo_empty)`, Avocado `cdrom.cpp:396`). Re-latching mid-transfer
  rewinds the read pointer and splices a newer sector into an in-flight DMA —
  that hung Crash's Jungle Rollers.
- **Command acknowledge delays matter — a lot.** `ack_delay` is `50000`
  (`cdrom.zig:595`), not the old `1000`; acking ~50x too fast broke Crash's boot.
  A few commands have Avocado's specific values (ReadN 1000, ReadS 500, SeekL
  5000, SeekL/SeekP second response 500000). The rest still share `ack_delay`,
  which is a known approximation.
- **XA-ADPCM submode masks** distinguish video vs audio vs form2 sectors; getting
  them wrong silently drops all in-game music (Croc). The decoder is a direct
  Avocado port.
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

Known remaining gaps (fix opportunistically, none currently blocking):
- `executeCommand` forces `busy_for = 0` (`cdrom.zig:582`); Avocado sets
  `busyFor = 1000`. Setting it here asserts STAT bit7 and blocks CdStatus polls.
- GetlocL's error response is `{stat|0x01, 0x80}` (`cdrom.zig:710`); Avocado
  sends just `{0x80}`.
- No seek-past-end error path (sticky seek-error bit `0x04` + INT5), and
  `getSubchannelQ` has no lead-out (`0xAA`) track. The JaCzekanski `getloc` test
  needs both.
- The disc-less `synthesizeHeaderAndQ` path hardcodes values; it cannot reproduce
  lead-out, seek-past-end, or the pregap index-00 countdown.

### CDROM / disc gotchas
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

**CPU / COP0 / ALU** (`cpu.zig`, `cop0.zig`, `alu.zig`)
- Triple-PC pipeline (`pc`/`next_pc`/`current_pc`) + dual load-delay pairs
  (`load_r/v`, `delay_r/v`) model branch-delay and load-delay slots. Interrupts
  are never taken in/just-before a delay slot.
- I-cache: 256 direct-mapped lines, cacheable only KUSEG/KSEG0 (not KSEG1), tag =
  vaddr & `0xFFFFF000` (virtual, so KUSEG/KSEG0 alias to different lines). Miss
  burst from RAM is a hardcoded **+7 cycles** (`cpu.zig:102`). SR IsC rising edge
  flushes the whole I-cache.
- PS1 div/mult quirks in `alu.zig:53-77` (div-by-0, INT_MIN/-1); computed instantly.
- **Dead code:** `opSlti`/`opSltiu` (`cpu.zig:544/551`) are implemented but never
  dispatched — the live SLTI/SLTIU path goes through `iOpSignExt`+`alu.slt/sltu`.
  Don't "wire them up" without checking equivalence.

**GTE / COP2** (`cop2.zig`) — **now a faithful Avocado port**, not the old
heuristic implementation. It has the real UNR reciprocal table + Newton-Raphson
`divideUNR` (`cop2.zig:163-183`), proper RTPS/RTPT projection with IR0 and
depth cueing, `farColor()` and the shared `depthCueWithRgbc` path used by
NCDS/NCDT/NCCS/CC/CDP (which correctly fold in the RGBC vertex colour), and
MAC1..3 write back the **sf-shifted** value so `mfc2` reads what hardware reads.
Remaining known divergence: **MVMVA's `sf=0` translation scaling**. MAC0..3 live
in a separate `macs: [4]i64`, **not** `data_regs[24..27]`. `try` → field `try_`.
The MVMVA matrix/translation selector bits were once swapped — if 3D geometry is
subtly wrong, re-check the operand decode first.

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

**SPU** (`spu.zig`) — **reverb is fully implemented but never called**: `doReverb`
(`spu.zig:513`) has no call sites, so the result is computed and discarded. Noise
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

**MDEC** (`mdec.zig`) — **ported from Avocado and unit-tested** (`mdec_test.zig`;
these were the first tests this module ever had). It now honours the per-block
`qFactor` from the DCT word, the uploaded scale/IDCT table (`scale_table`), the
zigzag-bypass when `qFactor == 0`, coefficient clamping, the `+128` YCbCr→RGB
bias, and dense 24bpp packing (the striped-garbage bug in Silent Hill's FMV).
Output depth comes from the command word. The struct is **~768 KB by value**
(two 131072-entry FIFOs) and is held by value in `Bus`.

**Memory / interrupts / timers / SIO** (`memory.zig`, `interrupt.zig`,
`timer.zig`, `sio.zig`)
- I_STAT is **write-0-to-ack** (`stat &= value`). Interrupts are **level-based**:
  a device keeps its bit set via `trigger()` until software acks. CDROM's
  `updateInterrupts` is level-triggered too — it re-asserts `.Cdrom` every step
  while the front queue item is ready and enabled.
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
  inline field defaults, devices expose `init()`, and modules are flat. Run
  `zig fmt` before committing.
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
- **`std.log.warn` in `cdrom.zig`/`memory.zig` is gated on `cdrom.debug_enable`**,
  except the per-command line at `cdrom.zig:579` and the unhandled-command warning.
  `ps1-debug` turns `debug_enable` on whenever a disc is passed.
- **Verify, don't guess.** When behavior is unclear, read `avocado_ref` and the
  relevant `psx.log`, and add a focused unit test in `ps1-core/tests/` that
  reproduces only the failure before changing core code.
