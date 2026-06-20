# CLAUDE.md — PS1 Emulator (Zig)

A thin, portable PlayStation 1 emulator core written in **Zig 0.16.0**. The core
(`ps1-core`) is driven by three frontends: a native debug harness, a WebAssembly
browser build, and an integration test harness. See `AGENTS.md` for the original
philosophy/roadmap; this file is the day-to-day engineering reference.

> **Current focus:** getting the `cdrom/getloc` ROM test to pass. The root-cause
> analysis and a prioritized fix plan live in [§ CDROM / getloc — active work](#cdrom--getloc--active-work).
> **Root cause #1 (level-triggered IRQ) is DONE; the next step is root cause #2**
> (decouple the drive state machine from `irq_queue`).

---

## Quick commands

Run everything from the **repo root** (the test harness reads the BIOS and test
ROMs via paths relative to the process CWD).

| Command | What it does |
|---|---|
| `zig build` | Builds native `ps1-debug` and the `wasm32-freestanding` `emulator`. |
| `zig build run` | Runs the native debug emulator (`ps1-debug`). |
| `zig build test` | Runs the 7 unit/integration test files. **ROM tests self-skip here** (`enable_rom_tests=false`). |
| `zig build rom-test` | Recompiles `rom_test.zig` with `enable_rom_tests=true` and runs the JaCzekanski hardware-conformance ROMs. In practice only **`ROM: CDROM - Getloc`** is live; the other 9 bodies are `if (false)`. |

- `zig version` must be **0.16.0** (the std API here — `std.Io.Dir.cwd()`,
  `std.ArrayList(...).empty`, `addRunArtifact` — is 0.16-specific).
- `enable_rom_tests` is a **compile-time `b.addOptions` flag**, not a `-D` CLI
  option. `zig build test` hardcodes it `false` (`build.zig:63`); `zig build
  rom-test` hardcodes it `true` (`build.zig:80`).
- BIOS files (`SCPH-*.bin`) live in the repo root and are loaded at runtime by
  `rom_test.zig` and wasm; the **native harness embeds `ps1-debug/src/BIOS.BIN`
  at compile time** (`@embedFile`, must be exactly 512 KB).

---

## Architecture: the CPU is the master clock

There is **no `Bus.step()`**. The whole machine is driven from `Cpu.step()`
(`ps1-core/src/cpu.zig:138`), called in a loop by each frontend. One `step()`:

1. Asks `bus.dma.isCpuStalled` — if DMA owns the bus, it runs **one DMA word** and
   returns (CPU frozen). DMA is **cooperative, word-at-a-time**, not burst.
2. Intercepts BIOS TTY (`putchar` at A0/B0 vectors) → `tty_write_fn`. This is how
   all ROM `printf` output is captured for `rom_test`. It's a **PC hack, not a
   real syscall**.
3. Fetches the instruction (I-cache + waitstate timing), snapshots
   `delta_cycles = 1 + bus.wait_cycles`, then **resets `wait_cycles`**.
4. Checks the hardware IRQ line (folds into COP0 Cause IP2). If an interrupt is
   taken, the fetched instruction is **discarded and PC is not advanced**.
5. Advances the PC pipeline / delay slots, retires the load-delay slot, executes.
6. `tickPeripherals(delta_cycles)` fans the cycles out to devices, **in this
   order — and the order matters**:
   `SPU → GPU → Timer0/1/2 → CDROM` (`cpu.zig:242-279`).
   Timer0 consumes GPU dotclock ticks and Timer1 consumes GPU hblank ticks
   produced earlier *in the same call*, so reordering breaks timer timing.
   `cdrom.updateInterrupts()` runs right after `cdrom.step()`.

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
    cop2.zig         GTE geometry engine (all COP2 math)
    alu.zig          ALU helpers + PS1 mult/div quirks
    memory.zig       Bus: memory map, MMIO dispatch, waitstates; owns all devices
    interrupt.zig    I_STAT/I_MASK level interrupt controller
    timer.zig        the 3 root counters
    cdrom.zig        CDROM controller + interrupt queue + FIFOs + XA-ADPCM   <-- active work
    disc.zig         flat-image disc model + MSF/LBA/BCD conversions
    dma.zig          7-channel DMA (block/linked-list/chopping)
    mdec.zig         MJPEG-style FMV decoder (least-tested subsystem)
    spu.zig          24-voice SPU (ADSR, noise, gaussian); reverb is DEAD CODE
    spu_gauss.zig    gaussian interpolation table
    gpu/             software rasterizer (gpu.zig, gp0.zig, renderer.zig, vram.zig, registers.zig)
  tests/             cdrom_test, cpu_test, gte_test, dma_test, gpu_test, spu_test, rom_test
ps1-debug/           native CLI harness (embeds BIOS.BIN at compile time)
ps1-wasm/            browser frontend; the ONLY place setDisc() is called
test-roms/           JaCzekanski ps1-tests .exe + reference psx.log per test
avocado_ref/         C++ Avocado emulator source — the GOLD reference (gitignored)
```

---

## Reference material (use in this order when stuck)

1. **`avocado_ref/src/`** — the C++ Avocado emulator, checked out locally. This is
   the *authoritative implementation reference*; most of this Zig port is a
   translation of it. The CDROM logic in particular lives in
   `avocado_ref/src/device/cdrom/{cdrom.cpp,commands.cpp,cdrom.h,fifo.h}`.
2. **NoCash PSX-SPX** (<https://psx-spx.consoledev.net>) — hardware bible.
3. **Lionel Flandrin's psx-guide** — system-level interactions/timing.
4. **JaCzekanski/ps1-tests** — the source of `test-roms/`; each test has a golden
   `psx.log` captured on real hardware.

When porting/fixing, **diff against `avocado_ref` first** — many "quirks" in this
codebase are deliberate matches to (or unintended divergences from) Avocado.

---

## CDROM / getloc — active work

The `cdrom/getloc` ROM test (`zig build rom-test`) is the thing currently being
debugged. The failure is **not one bug but three layered ones**, diagnosed by
live-tracing the EXE and disassembling its IRQ handler against `avocado_ref`.

### Root causes (in fix priority order)

1. **CDROM CPU interrupt is edge-triggered; Avocado is level-triggered.**
   *(This is the first failing byte: expected `absolute [00:01:68]`, got `[00:01:00]`.)*
   `updateInterrupts()` (`cdrom.zig:738-749`) fires the CPU IRQ **once** per queue
   item (`cpu_irq_triggered`) and additionally suppresses it once `item.ack` is set
   (`!item.ack`). The getloc EXE's CD callback reads at most **7 of the 8** GetlocP
   response bytes per IRQ (its loop is hard-capped, `slti at,a1,7`), ACKs, and
   relies on the IRQ being **re-asserted** (1 byte still unread → IFR still reports
   `irq=3`) to re-enter and drain the 8th byte (`0x68`). Avocado re-fires
   `interrupt::CDROM` **every step** while the front queue item has `delay<=0` and
   its IFR bit is enabled (`avocado cdrom.cpp:173-179`), with no `ack` gate and no
   once-only latch. **Fix:** make `updateInterrupts` level-triggered — mirror
   Avocado: `if (item.delay <= 0 and (irq_enable & item.irq & 7) != 0)
   interrupts.trigger(.Cdrom);` every call; drop `cpu_irq_triggered` and the
   `!item.ack` guard. The already-correct keep-unread-bytes ACK then lets the
   handler re-enter. *(The rewritten ACK/`readResponse` retain-logic is correct and
   matches Avocado — do **not** "fix" the byte loss there.)*

2. **Drive state machine is coupled to `irq_queue`, which every command clears.**
   *(This is the `GetStat -> 0x42` expected vs `0x02` got.)*
   `getDriveStatus()` is correct (Seeking=`0x40`, Reading=`0x20`, Playing=`0x80`,
   motor=`0x02`). But ReadN encodes the Seeking→Reading transition and per-sector
   data as **queued actions/INT1s**, and *every command byte* calls
   `irq_queue.clear()` (`cdrom.zig:199`, `:484`). The getloc "waiting for read"
   poll loop issues repeated GetStat, each wiping the pending transition → drive
   lands Idle → `0x02`. Avocado stores drive mode in a dedicated `stat` field set
   **synchronously** in the command (`commands.cpp:111`) and drives sectors from
   `step()→handleSector()` gated on `stat.read`, independent of the queue clear.
   **Fix:** decouple `drive_state` + seek/read from `irq_queue`. Use explicit
   `i64` timers ticked unconditionally in `step()`; set `drive_state=.Seeking`
   synchronously in ReadN; transition to `.Reading` from a step-driven seek timer,
   not a queued `.SetReading` action.

3. **The getloc test fundamentally needs disc geometry, but the harness loads no disc.**
   `rom_test.zig` boots the BIOS + `loadExe()` but **never calls `setDisc()`**
   (the only `setDisc` call in the repo is `ps1-wasm/main.zig:84`). The golden
   `psx.log` was captured with a real ~74-minute test disc: it reads sector
   headers, reports lead-out **`track aa`** (`0xAA`), and expects a seek to
   `[74:30:00]` to **fail** (`irq=5, status=0x04`, past disc end). The current
   disc-less `synthesizeHeaderAndQ` path hardcodes values and cannot reproduce
   lead-out, the seek-past-end error, or pregap index-00 countdown.
   **Fix:** build a synthetic single Mode-2 data track `Disc` with an explicit
   `total_sectors`/lead-out (so size-dependent behavior works), fabricate each
   sector's 4-byte header = `BCD(MSF of lba+150) + mode 2`, and call `setDisc()`
   in the harness. Add lead-out (`0xAA`) + pregap-countdown to
   `disc.zig:getSubchannelQ`, and a seek-past-end error path
   (sticky seek-error bit `0x04`, `INT5`) to SeekL/SeekP. Because a data sector's
   header *is* its absolute MSF, a correctly-built synthetic disc reproduces the
   Getloc values **without** needing the real `.bin`.

**Also revert:** the WIP "physical overshoot" edit in ReadN/ReadS
(`cdrom.zig:519-521`) permanently rewrites `seek_target = lba-3`, corrupting the
first delivered sectors and Getloc positions. Avocado does plain
`readSector = seekSector`.

### Secondary CDROM fidelity gaps (fix after the blockers)
- Command delays are collapsed to one `ack_delay = 1000`; Avocado uses per-command
  values (Getstat 50000, Setloc 5000, Setmode 2000, GetlocP 1000, GetlocL 50000,
  SeekL 5000/500000, etc.). Pause/Seek/GetID/ReadTOC second-response delays
  (`2000000`/`500000`/`10000`) are all wrong vs Avocado's `50000`.
- `executeCommand` forces `busy_for = 0`; Avocado sets `busyFor = 1000` and asserts
  STAT bit7 during a command.
- GetlocL error response is `{stat|0x01, 0x80}`; Avocado/the test expect the plain
  drive status (`0x02`/`0x04`) — Avocado sends just `{0x80}`.

### CDROM gotchas (general)
- **MSF fields are always BCD.** `MSF.fromLba/fromFrames` return BCD; `toLba`
  decodes. Never `binaryToBcd` an MSF field — it double-encodes. `toLba` subtracts
  the 150-frame lead-in (MSF `00:02:00` == LBA 0). `fromLba` re-adds 150 (absolute
  disc MSF); `fromFrames` does **not** (relative-in-track MSF). Mixing them shifts
  positions by 2 seconds.
- The interrupt model is an `irq_queue` FIFO; **only the head item's `delay` ticks**.
  A queued second response (INT2/INT5) can't fire before the first INT3 is ACK'd
  and popped — matches Avocado's structure, but see blocker #1 for the IRQ-line bug.
- `disc.zig` is a **flat 2352-byte/sector image** with a single hardcoded track;
  there is no CUE/TOC parsing.
- `queueIrq`/`pushAction` emit **unconditional `std.log.warn`** on every call
  (`cdrom.zig:41,46`) — debug spam from the active session, not gated by
  `debug_enable`. Remove before trusting logs.

---

## Per-subsystem cheat-sheet (sharp edges only)

**CPU / COP0 / ALU** (`cpu.zig`, `cop0.zig`, `alu.zig`)
- Triple-PC pipeline (`pc`/`next_pc`/`current_pc`) + dual load-delay pairs
  (`load_r/v`, `delay_r/v`) model branch-delay and load-delay slots. Interrupts
  are never taken in/just-before a delay slot.
- I-cache: 256 direct-mapped lines, cacheable only KUSEG/KSEG0 (not KSEG1), tag =
  vaddr & `0xFFFFF000` (virtual, so KUSEG/KSEG0 alias to different lines). Miss
  burst from RAM is a hardcoded **+7 cycles** (`cpu.zig:98`). SR IsC rising edge
  flushes the whole I-cache.
- PS1 div/mult quirks in `alu.zig:53-77` (div-by-0, INT_MIN/-1); computed instantly.
- **Dead code:** `opSlti`/`opSltiu` (`cpu.zig:526/533`) are implemented but never
  dispatched — the live SLTI/SLTIU path goes through `iOpSignExt`+`alu.slt/sltu`.
  Don't "wire them up" without checking equivalence.
- The `trace_cpu` debug hook actually lives on the **CdRom struct** and auto-arms
  when CDROM cmd `0x06` (ReadN) is issued (`cdrom.zig:493`) — surprising coupling.

**GTE / COP2** (`cop2.zig`) — **math diverges from hardware in several ops.** The
divide is plain integer `(h<<17)/sz` (no Newton-Raphson/UNR table); RTPS screen
coords use a bespoke `>>1`+`>>16` split; MVMVA buggy-matrix/FarColor quirks are
absent; NCCS/CDP use `/255` and `*16` heuristics. Tests assert *this*
implementation's outputs, so they pass despite the divergence. MAC0..3 live in a
separate `macs: [4]i64`, **not** `data_regs[24..27]`. `try` → field named `try_`.

**GPU** (`gpu/`) — software scanline rasterizer, ABGR1555. **No texture/CLUT
cache** (re-reads VRAM per texel). Cycle "cost" is hand-tuned heuristics, not real
clocks. Quads decompose into 2 triangles (possible diagonal seam); the textured-
rectangle path avoids decomposition on purpose. Mask-bit handling is only in
`putPixel` (fill/copy rects bypass it). VRAM transfers are a stateful multi-word
FSM — a bug there silently swallows real commands.

**SPU** (`spu.zig`) — **reverb is fully implemented but never called** (computed,
then discarded). Noise + ADSR are duckstation-style approximations, not Avocado's
model. CD audio has its *own* 768-cycle counter separate from the SPU's, so the two
can drift. SPU IRQ is level-style. Volume sweeps are not implemented (bit15 masked
off). `decodeBlock` is exported + unit-tested — keep its signature stable.

**DMA** (`dma.zig`) — cooperative, **one word per `step()`**. Channel priority is
*not* implemented (fixed 0..6 loop — matches Avocado). The CDROM 32-bit data path
is a 4×8-bit-FIFO read special-cased in `memory.zig:203`. Chopping mixes "words"
and "cycles" as one counter (known inaccuracy). MDECin/PIO DMA effectively stubbed.

**MDEC** (`mdec.zig`) — **least-tested (no tests at all).** The IDCT ignores the
uploaded table and uses a hardcoded cosine matrix; `qFactor` handling is absent;
coefficient clamping and the proper 24bpp pack are missing; YCbCr→RGB lacks the
+128 bias. Treat any change as unverified. The struct is **~768 KB by value**
(huge fixed FIFOs) and is held by value in `Bus`.

**Memory / interrupts / timers / SIO** (`memory.zig`, `interrupt.zig`,
`timer.zig`, `sio.zig`)
- I_STAT is **write-0-to-ack** (`stat &= value`). Interrupts are **level-based**:
  a device keeps its bit set via `trigger()` until software acks. (CDROM's
  edge-guard is the exception — and the source of the getloc bug, see above.)
- **Likely bug:** the JOY/SIO port (`memory.zig:332`) raises `.Sio` (IRQ8) but a
  controller/memcard transfer should raise IRQ7 (Controller). `sio.zig`'s own
  comment says IRQ7. Avocado triggers `CONTROLLER=7`.
- Several reads spoof magic values (`0xC0C00000` at SIO regs, `0x3C045678` shadow
  at Timer1 mode `0x1108`) to satisfy BIOS/test patterns — not real hardware.
- Timer mode read does **not** clear the reached-target/overflow latch bits the way
  real hardware does.

**Frontends + test harness** (`ps1-debug`, `ps1-wasm`, `rom_test.zig`)
- `setDisc()` is called from **exactly one place** (wasm). Native + tests use
  `cpu.loadExe()` (PS-EXE sideload, bypasses BIOS CD boot) and leave `disc = null`.
  **The disc/CD-boot pipeline is effectively untested by the suite.**
- wasm exports are a hard ABI contract with `ps1-wasm/www/index.html` — renaming an
  export silently breaks the browser frontend.
- `rom_test` normalizes output (strip `\r`, strip leading `% ` prefixes, plus a
  hardcoded SIO_CTRL string fixup). Changing TTY formatting causes spurious
  mismatches until the normalizers are updated.

---

## Conventions & housekeeping

- **Match the surrounding style.** This is a single-author codebase; structs use
  inline field defaults, devices expose `init()`, and modules are flat.
- **Interrupts are level-based** except the (buggy) CDROM edge-guard. New devices
  should call `bus.interrupts.trigger(.X)` while their condition holds.
- **BCD/MSF discipline** (see CDROM section) is the #1 source of off-by-2-second
  and double-encoding bugs.
- **Don't commit/trust the debug cruft.** The working tree carries a lot of
  scratch: `debug_output.txt` (**184 MB**, gitignored), `rom_test_output*.log`,
  `*.patch`, `cdrom.zig.orig`, `dump.zig`/`scratch.zig`/`run_getloc.zig`, and
  `std.log.warn` spam in `cdrom.zig`. Clean these up before relying on logs or
  committing. `avocado_ref/`, `*.bin`/`*.BIN`, and `debug_output.txt` are
  gitignored.
- **Verify, don't guess.** When behavior is unclear, read `avocado_ref` and the
  relevant `psx.log`, and add a focused unit test in `ps1-core/tests/` that
  reproduces only the failure before changing core code.
