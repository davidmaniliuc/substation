# CLAUDE.md — PS1 Emulator (Zig)

A thin, portable PlayStation 1 emulator core written in **Zig 0.16.0**. The core
(`ps1-core`) is driven by seven frontends: a native debug harness, a native
execution-trace harness, a WebAssembly browser build, the test harness, a
native trace-equivalence harness (`ps1-golden`), a C ABI static library
(`ps1-capi`), and the native macOS app that links it (`ps1-macos`). See `AGENTS.md` for the
original philosophy/roadmap; this file is the day-to-day engineering reference.

> **Current focus: booting and running real games from disc.** Croc, Silent Hill,
> Spyro and Crash Bandicoot all boot from a real `.bin`/`.cue` today.
> **Crash Bandicoot's level-select freeze is CLOSED (2026-08-23): it plays.**
> The cause was never written down — the note that used to sit here blamed
> "zero CD commands while hung", and that evidence had already been retracted
> as an artifact of `ps1-trace`'s dead `cd cmds:` probe. Do not go looking for
> a level-select bug; if a similar hang reappears, start from a real command
> log (`cdrom.debug_enable = true`), not from that probe.
>
> The JaCzekanski ROM suite is **shelved at 12/17** — that work was traded for
> real-game boot, which found far more real bugs per hour. `ps1-test-harnesses`
> has the per-test triage.

---

## Where the detail lives

This file is the always-loaded map: the commands, the machine's shape, and the
rules that must not be broken. The reasoning behind each rule — the
measurements, the approaches that were tried and failed, the dated post-mortems —
lives in seven skills. **Invoke the skill before working in its area**; the
one-line rules below are a tripwire, not a substitute.

| Skill                      | Invoke when                                                                     |
| -------------------------- | ------------------------------------------------------------------------------- |
| `ps1-gpu-metal`            | Anything in `gpu/`, the Metal backend, `.p1fx` fixtures, internal resolution    |
| `ps1-macos-app`            | Anything in `ps1-macos/` — SwiftUI, Xcode project, covers, window, memory cards |
| `ps1-cdrom-disc`           | `cdrom/`, `disc.zig`, `discid.zig`, MSF/BCD, XA, CD-DA, `.sbi`, disc swap       |
| `ps1-core-subsystems`      | CPU/COP0/ALU, GTE/COP2, SPU, DMA, MDEC, memory/interrupt/timer/SIO              |
| `ps1-pgxp`                 | `pgxp.zig` and its hooks in `cop2/`, `cpu/`, `memory.zig`, `gpu/`               |
| `ps1-test-harnesses`       | `trace-golden`, the ROM suites, fixtures, recapturing a golden                  |
| `ps1-debugging-real-games` | A game hangs, freezes, renders wrong, or boots black                            |

---

## Quick commands

Run everything from the **repo root** (the harnesses read the BIOS, disc images
and test ROMs via paths relative to the process CWD).

| Command                                   | What it does                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `zig build`                               | Builds native `ps1-debug`, native `ps1-trace`, and the `wasm32-freestanding` `emulator`.                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `zig build run`                           | Runs the native debug emulator (`ps1-debug`). Takes an optional disc path: `zig build run -- game.bin`.                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `zig build test`                          | Runs **16 test binaries** — the 10 `unit_test_files`, `golden_test`, `capi_test`, `gpu_stream_test` (its own binary: it needs the recording core module), `fixture_test` (the `.p1fx` format + FNV-1a 64, also needs the recording module) and the two ROM suites, which **compile-check here but self-skip** (`enable_rom_tests=false`).                                                                                                                                                                                      |
| `zig build test-roms-pl`                  | Runs the **PeterLemon/PSX** graphical-conformance suite (`peterlemon_test.zig`, the `PL:` tests). Passes today — it's a pixel-match _ratchet_; re-pin floors via `ps1-test-harnesses`.                                                                                                                                                                                                                                                                                                                                         |
| `zig build test-roms-ja`                  | Runs the **JaCzekanski** hardware-conformance suite (`jaczekanski_test.zig`, the `ROM:` tests) against the golden `psx.log`s. 12/17 pass.                                                                                                                                                                                                                                                                                                                                                                                      |
| `zig build capi-lib`                      | Builds `zig-out/lib/libps1core.a`, the C ABI the macOS app links. Built with `gpu_sink = .dual` since Phase D1 — it records the GP0 stream as well as rasterizing, which costs ~6.8 MB of `Recorder` inside `Bus`.                                                                                                                                                                                                                                                                                                             |
| `zig build metallib`                      | Compiles **both** `.metal` sources (`DisplayShader.metal`, `Rasterizer.metal`) into one `zig-out/lib/libps1shaders.a`. Needs Xcode's Metal toolchain, not just CLT.                                                                                                                                                                                                                                                                                                                                                            |
| `zig build macos`                         | Builds the native macOS app bundle, `zig-out/Substation.app`, by driving `xcodebuild` over `ps1-macos/PS1.xcodeproj`. macOS-only; fails with a clear message elsewhere. Needs full Xcode.                                                                                                                                                                                                                                                                                                                                      |
| `ps1-macos/test.sh`                       | Runs the 404 Swift tests (`xcodebuild test`), in about 2.5 min once `zig build fixtures` has run (~90 s without it, when four fixture gates skip). Not a `zig build` step — it needs `capi-lib` and `metallib` built first, and says so.                                                                                                                                                                                                                                                                                       |
| `zig build trace-golden -- verify`        | Machine-state trace equivalence check against `ps1-core/tests/goldens/trace/`. The behaviour-freeze net that gated the P1-P8 core-wide refactor, and the regression gate for any change since. Run it `-Doptimize=ReleaseFast`.                                                                                                                                                                                                                                                                                                |
| `zig build trace-golden -- stream-verify` | Boots every workload with the GP0 recorder armed, replays each frame's command stream into a shadow VRAM, and requires full-VRAM equality with the software rasterizer. The Phase A gate for the Metal renderer's command stream. Run it `-Doptimize=ReleaseFast`.                                                                                                                                                                                                                                                             |
| `zig build trace-golden -- pgxp`          | Boots every workload with PGXP **on** and reports the identity invariant plus a ratcheted per-game shadow hit-rate (`ps1-core/tests/goldens/pgxp/floors.txt`). There is no golden for PGXP-on output and never will be; this is the whole automated gate for the feature. Run it `-Doptimize=ReleaseFast`.                                                                                                                                                                                                                     |
| `zig build ps1-bench-dual`/`-sw`          | Wall-clock benchmark: boots a disc through the same vblank-to-vblank loop `ps1_run_frame` uses and times N frames. `ps1-bench-dual SCPH-1001_BIOS_1995_US.bin games/<g>/<g>.cue 3000`. Run it `-Doptimize=ReleaseFast`, take the BEST of five and let the machine settle first — a run straight after `trace-golden` reads 15% slow. The `-dual`/`-sw` pair is the two `gpu_sink` builds; `-dual` is the one the macOS app ships. `nocopy` drops the per-frame VRAM copy, which is the ~1% it sounds like.                     |
| `zig build fixtures`                      | Writes `.p1fx` command-stream fixtures to `zig-out/fixtures/` — the six PeterLemon ROMs plus a measured Croc window — for the Swift bridge tests. Run it `-Doptimize=ReleaseFast`. The synthetic memory-mover fixture is committed at `ps1-core/tests/goldens/fixtures/` instead, so the executable half of that gate needs no generation step. The Croc run matches nothing without `games/`, and `stream-capture` alone treats that as non-fatal — for `verify`/`stream-verify`/`capture` an empty filter is still an error. |

- `zig version` must be **0.16.0** (the std API here — `std.Io.Dir.cwd()`,
  `std.process.Init`, `std.ArrayList(...).empty`, `addRunArtifact` — is 0.16-specific).
- **`capi_test` compiles against the RECORDING core module**, not the shared
  one, because the shipped `libps1core.a` is built `.dual`. A test binary built
  against a configuration no frontend links would leave `ps1_take_frame_stream`
  untested.
- BIOS files (`SCPH-*.bin`) live in the repo root and are loaded at runtime by
  the ROM-test suites, `ps1-trace` and wasm; the **native `ps1-debug` harness
  embeds `ps1-debug/src/BIOS.BIN` at compile time** (`@embedFile`, must be
  exactly 512 KB).
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
   produced earlier _in the same call_, so reordering breaks timer timing.
   `cdrom.updateInterrupts()` runs right after `cdrom.step()`.

**The GPU runs on a scaled clock.** `tickPeripherals` converts CPU cycles to
video cycles at **11/7** (53.2224 MHz vs 33.8688 MHz) with a carried remainder
(`gpu_clock_frac`). Without this the vblank period is ~1.57x too long relative to
the CPU-cycle root counters and the BIOS VSync wait times out during KERNEL SETUP.
The resulting frame period is NTSC-exact (~571,212 CPU cycles/frame) and is
**verified correct against the BIOS's own vblank counter — do not "fix" it.**

Consequences worth internalizing:

- **Load/store waitstates are billed one step late.** `delta_cycles` is snapshotted
  right after _fetch_; waitstates that `execute()`'s memory ops add land in
  `bus.wait_cycles` and are charged on the _next_ `step()`.
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
    discid.zig       what a disc says about itself: licence region, ISO walk,
                     SYSTEM.CNF boot serial. No filename rule, no database.
    dma.zig          7-channel DMA (block/linked-list/chopping)
    mdec/            MJPEG-style FMV decoder: mdec.zig (registers, FIFOs)
                     + algorithm.zig (idct, decodeBlock, YCbCr->RGB)
    spu/             24-voice SPU: spu.zig, voice.zig, adsr.zig, reverb.zig,
                     noise.zig, regs.zig, gauss.zig (was spu_gauss.zig)
    gpu/             software rasterizer: gpu.zig, gp0.zig, renderer.zig, vram.zig,
                     registers.zig, color.zig (texel fetch/blend), primitive.zig
                     + the command-stream seam: sink.zig (what gp0 calls),
                     command.zig (the record type + the one execute/replay),
                     recorder.zig (fixed-capacity per-frame capture)
  tests/             disc/cdrom/cpu/gte/dma/gpu/spu/sio/mdec_test (unit; all 9 in `zig build test`)
                     gpu_stream_test (command-stream round trip; own binary, needs
                     the recording core module) + vram_compare (shared full-VRAM equality)
                     peterlemon_test + jaczekanski_test (ROM suites) + rom_test_helpers
                     bios_trace.zig (scratch harness, not wired into any build step)
ps1-debug/           native CLI harness (embeds BIOS.BIN; optional disc path argv[1])
ps1-trace/           native execution-diff / component-boundary tracer (BIOS + disc at
                     runtime, optional "autostart" button injection)
ps1-wasm/            browser frontend (BIOS/EXE/bin/cue all uploaded from the page)
ps1-bench/           wall-clock benchmark frontend (boots a disc, times N frames)
ps1-golden/          native trace-equivalence harness (BIOS + games/*/*.cue at
                     runtime; capture/verify goldens in ps1-core/tests/goldens/trace/)
                     fixture.zig (.p1fx format + FNV-1a 64), synthetic.zig
                     (the committed memory-mover fixture), env_sync.zig
                     (DrawingEnv sync records a capture window needs to be
                     self-contained), fixture_test.zig
ps1-capi/            C ABI static library (libps1core.a) — the contract ps1-macos links
ps1-macos/           native SwiftUI app (PS1.xcodeproj + build.sh -> zig-out/Substation.app)
                     disc identification: DiscIdentity.swift, CueSheet.swift
                     cover art: CoverStore.swift, CoverSource.swift,
                     CoverDownloader.swift
                     the fixture bridge: FixtureFile.swift, ShadowVram.swift,
                     Fnv1a.swift
test-roms/           JaCzekanski ps1-tests .exe + reference psx.log per test
avocado_ref/         C++ Avocado emulator source — the GOLD reference (gitignored)
.claude/skills/      the per-area engineering detail this file indexes
```

---

## Reference material (use in this order when stuck)

1. **`avocado_ref/src/`** — the C++ Avocado emulator, checked out locally; most
   of this Zig port is a translation of it. **Diff against it first** — but see
   the caveat in `ps1-debugging-real-games`: several bugs here are shared with
   it, so agreement is not evidence.
2. duckstation_ref/src/ — the C++ DuckStation emulator, checked out locallyand gitignored. The accuracy reference: where it disagrees with Avocado,DuckStation is usually the one matching real hardware. Read it for behavior,not architecture — it is a recompiler-based, threaded design with its owntiming model, nothing like this core's CPU-master-clock single-step, so thequestion to bring to it is "what does the hardware do here", never "how isthis structured". Resolve the answer in this codebase's own idioms: it is areference to read, not code to port. Mostly one .cpp per subsystem undersrc/core/ (cdrom, gte, gpu_sw, gpu_hw, spu, timers, mdec) —the closest layout-match to this core of any reference. gpu_sw is thearbiter for "what should this pixel be"; gpu_hw answers "how do real gamesactually drive this".
3. **NoCash PSX-SPX** (<https://psx-spx.consoledev.net>) — hardware bible.
4. **Lionel Flandrin's psx-guide** — system-level interactions/timing.
5. **JaCzekanski/ps1-tests** — the source of `test-roms/`; each test has a
   golden `psx.log` captured on real hardware.

---

## Rules that must not be broken

Each of these was learnt from a real bug and each looks like a mistake if you
meet it cold. **The reasoning is in the named skill — read it before touching
the line.** Nothing here is a style preference; every entry has cost a day.

**GPU + Metal** (`ps1-gpu-metal`)

- **No `f32` in the rasterizer inner loop**, and no incremental/stepped
  fixed-point either. The integer edge-function formulas are shared verbatim
  with the Metal backend; "optimising" one desynchronises the two.
- **The fill-rule bias stays at `-1`** in both rasterizers. Scaling it erodes
  interior pixels along top-left edges.
- **A primitive spanning >=1024 horizontally or >=512 vertically is DROPPED**,
  not clipped. That refusal is the only near-plane clip the machine has.
- **`gp0.zig` cannot reach the renderer.** Every VRAM-visible effect goes
  through `gpu/sink.zig`; a primitive absent from the sink does not draw.
- **VRAM stays `.r16Uint`; the true-colour sidecar is DISPLAY-ONLY.** It is
  never sampled as a texel, never read back by a game, never hashed by a gate
  and never compared by `PS1_LIVE_DIFF`. Adopting `RGBA8` for VRAM itself
  surrenders all three gates at once.
- **The sidecar's alpha is PRESENCE, not a mask bit** — 255 means it holds a
  real eight-bit colour, 0 means expand VRAM with `c << 3 | c >> 2`. Both
  expansions in the codebase must stay that one expression or an invalidated
  rect shows a seam.
- **A VRAM->VRAM copy moves BOTH attachments in ONE pass.** A second pass can
  resolve a self-overlap differently from the VRAM copy beside it.
- **A GP0(A0) upload invalidates the sidecar across its destination rect**, and
  a whole-texture `upload`/`uploadNative` invalidates all of it: 5551 payload
  carries no extra precision to keep.
- **`.trueColor` writes VRAM exactly as `.off` does.** That is why it can be the
  default at every scale and why no hash moves — and it also means
  `PS1_LIVE_DIFF` is as loud at the shipped default as it is at `.off`, because
  the software shadow dithers. Switch to `.native` before reading a run.
- **Gate 1's harness pins its own dither mode.** It compares against a software
  rasterizer that dithers, so the mode is part of the gate; it must never
  inherit `DitherSetting.defaultMode` again.
- **A record carries every input its effect needs**; nothing may be re-derived
  at replay time, and records stay in native 1024x512 units at every scale.
- **`ps1_take_frame_stream` is a DRAIN, not a peek** — exactly once per
  `ps1_run_frame`.
- **Dither offsets are 8-bit channel units**, clamped before the `>> 3` to 5 bits.
- **Never clear bit15 of a drawn pixel**; games leave STP-set texels in VRAM to
  mask later check-mask draws.
- **Fill Rectangle is unmasked on purpose** — hardware ignores GP0(E6) there.

**CDROM + disc** (`ps1-cdrom-disc`)

- **ReadN's 1,000,000-cycle seek is load-bearing — do NOT "port" it** to
  Avocado's immediate-Reading model.
- **`ack_delay` is `50000`, not `1000`.** Acking ~50x too fast broke Crash's boot.
- **The first sector after a seek costs a full sector period**, never `0`, or the
  GetStat poll that observed the transition eats its own INT1.
- **`nextDeadline` must name EVERY timer the slow path acts on** —
  `shell_close_timer` included. One left out never fires at all.
- **I_STAT latches an EDGE; the drive asserts a LEVEL.** Re-latching on the level
  delivers a phantom second interrupt. (`interrupt.zig`'s latch is
  write-0-to-ack; a level device must edge-detect on its own side.)
- **MSF fields are always BCD.** Never `binaryToBcd` one — it double-encodes.
- **A sector's user data starts at 010h for Mode 1 and 018h for Mode 2**, decided
  by the sector's own mode byte. Avocado gets Mode 1 wrong.
- **An XA-ADPCM sector the decoder consumes must NOT post INT1**, or audio bytes
  splice into the game's data stream. Avocado has this bug.
- **A disc swap is a TRAY**, not a slice replacement: the sticky shell-changed
  latch is how a game learns to re-read the TOC.

**Core subsystems** (`ps1-core-subsystems`)

- **An interrupt is never taken on a GTE command instruction** — the BIOS handler
  deliberately returns to EPC+4. Avocado has this bug too.
- **MAC1..3 write back the sf-shifted value**, and the MACs are 32-bit registers
  fed by a 44-bit accumulator.
- **The SPU exponential-decrease step must stay signed**, or a release stalls
  above zero and every voice reads as permanently busy.
- **A DMA word costs a per-channel hardware RATE, not the memory map's wait
  states.** Summing both starves the CPU between CD sectors.
- **Sync mode 3 (reserved) must start no transfer at all**, and sub-word stores
  to DMA registers must be shifted into the addressed byte lane.
- **The SIO /ACK is deferred, and the delay is PER-PERIPHERAL** — pad 500 (a
  floor), memory card 150 (a ceiling). One shared constant breaks one of them.
- **MDEC_STAT bit 31 means data-out FIFO EMPTY**, not "data ready".

**PGXP** (`ps1-pgxp`)

- **A `pgxp.Value` is judged by the WORD it was recorded against**, never by
  its coordinates. The identity check is the safety net, not just the gate:
  never make it an assertion, and never log per vertex.
- **A `Value`'s `x`/`y` are the two HALVES of a word, not a screen position.**
  That generalisation is what lets arithmetic propagate at all — a coupled
  screen pair has nothing to say once a game splits a packed SXY in two.
- **CPU mode ships ON, and that is a deliberate break with the reference**,
  which calls it a per-game workaround. Measured, it is the difference between
  PGXP working and not: it took croc 12.6% → 99.4% and spyro 41.6% → 99.9%.
  PGXP itself still ships off.
- **The four sub-settings are ANDed with the master flag in ONE place**,
  `Bus.pgxpConfig`. There is no state in which a sub-setting acts while
  geometry correction does not, and the menu greys them rather than letting one
  silently no-op.
- **A default-ON flag on `Bus` must ALSO be set in `Bus.init`** — the `@memset`
  there does not respect field defaults. `pgxp_culling` and `pgxp_cpu` both
  shipped broken for one build over exactly this.
- **The tolerance check runs BEFORE `toFixed`'s clamp.** The clamp pins a
  disagreeing candidate inside the wire's own pixel, so after it nothing can
  tell a five-pixel drift from a sub-pixel one.
- **Culling correction requires a DEPTH on all three vertices**, not merely a
  position. A screen coordinate a game built itself has none, and that
  requirement is the only thing keeping float NCLIP off a HUD.
- **The `unify` / `weldPoint` / `thinIntegerTriangle` rules are decided in `gp0`
  on the INTEGER geometry**, before the sink, so both rasterizers agree.
- **1/16 px is a deliberate ceiling**, not an accident — more means `long` in
  Metal's per-fragment loop.

**macOS app** (`ps1-macos-app`)

- **Shaders are compiled OFFLINE.** Never reintroduce runtime
  `makeLibrary(source:)`; a shader error belongs at build time.
- **`libps1core.a` is repacked with `xcrun libtool`** — Apple's `ld` rejects
  Zig's own archive members.
- **There is no `Package.swift`.** `xcodebuild` is the only build system, and
  `Sources/`/`Tests/` are synchronized groups: adding a `.swift` file needs no
  project edit.
- **Clearing the 4:3 aspect lock goes through `contentResizeIncrements`.**
  Assigning `.zero` to `contentAspectRatio` does not clear it and aborts the
  process on fullscreen exit.
- **`pkill -x Substation` before running the Swift suite** — a running app shares
  the bundle id and fails the run in a way that looks like a real failure.

**Harnesses** (`ps1-test-harnesses`)

- **`trace-golden -- capture` only for an intentional behaviour change**, as its
  own commit, with the diff explained in the message.
- **State dumps in `state_hash.zig` are written by hand, never by reflection** —
  reflection makes the check follow a refactor instead of policing it.
- **`verify` exits non-zero for a disc with no golden.** That reads like a
  regression and is not one.

**Debugging** (`ps1-debugging-real-games`)

- **Black screen + working audio** is the BIOS unresolved-exception hang, not a
  GPU bug — check PC before touching `gpu/`.
- **A game sitting on a static screen is not necessarily hung.** Diff consecutive
  `frame_*.ppm` snapshots before believing it.
- **`ps1-trace`'s `cd cmds:` histogram is dead instrumentation** and always
  prints empty. Any conclusion resting on it is unsupported.
- **Avocado is the first reference, but it is not always an oracle.** Six bugs
  here are shared with it; when it agrees with you, that is not evidence.

---

## Conventions & housekeeping

- **Match the surrounding style.** This is a single-author codebase; structs use
  inline field defaults and devices expose `init()`. Subsystems big enough to
  split live in a directory whose entry file carries the struct
  (`spu/spu.zig`, `cdrom/cdrom.zig`); `root.zig` re-exports them under the
  _old_ paths, so `ps1_core.spu.Spu` survives the move. Renaming an exported
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
  the top of its own file — `0x1F` is _not_ one constant, it is a 5-bit colour
  channel in `renderer.zig` and an ADSR shift field in `spu/`.
- **Interrupts are level-based.** New devices should call
  `bus.interrupts.trigger(.X)` while their condition holds.
- **BCD/MSF discipline** (see `ps1-cdrom-disc`) is the #1 source of off-by-2-second
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
