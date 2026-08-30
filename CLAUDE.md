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
| `zig build test` | Runs **15 test binaries** — the 9 `unit_test_files`, `golden_test`, `capi_test`, `gpu_stream_test` (its own binary: it needs the recording core module), `fixture_test` (the `.p1fx` format + FNV-1a 64, also needs the recording module) and the two ROM suites, which **compile-check here but self-skip** (`enable_rom_tests=false`). |
| `zig build test-roms-pl` | Runs the **PeterLemon/PSX** graphical-conformance suite (`peterlemon_test.zig`, the `PL:` tests). Passes today — it's a pixel-match *ratchet*, see below. |
| `zig build test-roms-ja` | Runs the **JaCzekanski** hardware-conformance suite (`jaczekanski_test.zig`, the `ROM:` tests) against the golden `psx.log`s. 12/17 pass. |
| `zig build capi-lib` | Builds `zig-out/lib/libps1core.a`, the C ABI the macOS app links. Built with `gpu_sink = .dual` since Phase D1 — it records the GP0 stream as well as rasterizing, which costs ~6.8 MB of `Recorder` inside `Bus`. |
| `zig build metallib` | Compiles **both** `.metal` sources (`DisplayShader.metal`, `Rasterizer.metal`) into one `zig-out/lib/libps1shaders.a`. Needs Xcode's Metal toolchain, not just CLT. |
| `zig build macos` | Builds the native macOS app bundle, `zig-out/PS1.app`, by driving `xcodebuild` over `ps1-macos/PS1.xcodeproj`. macOS-only; fails with a clear message elsewhere. Needs full Xcode. |
| `ps1-macos/test.sh` | Runs the 186 Swift tests (`xcodebuild test`), in about 90 s. Not a `zig build` step — it needs `capi-lib` and `metallib` built first, and says so. |
| `zig build trace-golden -- verify` | Machine-state trace equivalence check against `ps1-core/tests/goldens/trace/`. The behaviour-freeze net that gated the P1-P8 core-wide refactor, and the regression gate for any change since. Run it `-Doptimize=ReleaseFast`. |
| `zig build trace-golden -- stream-verify` | Boots every workload with the GP0 recorder armed, replays each frame's command stream into a shadow VRAM, and requires full-VRAM equality with the software rasterizer. The Phase A gate for the Metal renderer's command stream. Run it `-Doptimize=ReleaseFast`. |
| `zig build fixtures` | Writes `.p1fx` command-stream fixtures to `zig-out/fixtures/` — the six PeterLemon ROMs plus a measured Croc window — for the Swift bridge tests. Run it `-Doptimize=ReleaseFast`. The synthetic memory-mover fixture is committed at `ps1-core/tests/goldens/fixtures/` instead, so the executable half of that gate needs no generation step. The Croc run matches nothing without `games/`, and `stream-capture` alone treats that as non-fatal — for `verify`/`stream-verify`/`capture` an empty filter is still an error. |

- `zig version` must be **0.16.0** (the std API here — `std.Io.Dir.cwd()`,
  `std.process.Init`, `std.ArrayList(...).empty`, `addRunArtifact` — is 0.16-specific).
- `enable_rom_tests` is a **compile-time `b.addOptions` flag**, not a `-D` CLI
  option. The `test` step hardcodes it `false` (compile-check + skip); each
  `test-roms-*` step hardcodes it `true`. Each ROM suite's run functions check it
  and `return error.SkipZigTest` when false.
- **`capi_test` compiles against the RECORDING core module**, not the shared
  one, because the shipped `libps1core.a` is built `.dual`. A test binary built
  against a configuration no frontend links would leave `ps1_take_frame_stream`
  untested.
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
  full set of 10 is about 503 KB.

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
ps1-golden/          native trace-equivalence harness (BIOS + games/*/*.cue at
                     runtime; capture/verify goldens in ps1-core/tests/goldens/trace/)
                     fixture.zig (.p1fx format + FNV-1a 64), synthetic.zig
                     (the committed memory-mover fixture), env_sync.zig
                     (DrawingEnv sync records a capture window needs to be
                     self-contained), fixture_test.zig
ps1-capi/            C ABI static library (libps1core.a) — the contract ps1-macos links
ps1-macos/           native SwiftUI app (PS1.xcodeproj + build.sh -> zig-out/PS1.app)
                     the fixture bridge: FixtureFile.swift, ShadowVram.swift,
                     Fnv1a.swift
test-roms/           JaCzekanski ps1-tests .exe + reference psx.log per test
avocado_ref/         C++ Avocado emulator source — the GOLD reference (gitignored)
```

---

## The macOS app

`ps1-capi` is a flat C ABI over the core (`ps1-capi/include/ps1.h` is the
reviewable contract; a rename in Zig cannot silently break it because the header
is hand-written). `ps1-macos` is an **Xcode project** that links the resulting
`libps1core.a`, runs the emulator on its own thread **paced by the audio
device's clock**, and hands frames to a Metal view through a triple buffer. The
software rasterizer is untouched — this is the display path only.

Build it with `zig build macos`; run the Swift tests with `ps1-macos/test.sh`.
Both are thin wrappers over `xcodebuild`, and both need **full Xcode** — see
below.

The app has three stages — `.onboarding`, `.library`, `.playing`. Onboarding
captures a BIOS folder and a games folder as security-scoped bookmarks
(`ScopedBookmark`); the library is the home screen, and `eject()` returns to
it. `GameScanner`'s rule is per-DIRECTORY: every `.cue` is a game, and a
`.bin` counts only when its own directory holds no `.cue`, so the usual
cue+bin pair is one tile rather than two. Covers are user-supplied only — a
PS1 disc carries no artwork — and are copied into Application Support keyed
by a SHA-256 of the disc path, so a rescan keeps them and a move loses them.
The `NSEvent` key monitor is gated on `.playing`: the arrow keys are the
D-pad, and outside a game they must reach the grid instead.

`InternalResolution` is the app's second persisted setting, after
`ScopedBookmark`, and is shaped after it: `init` resolves from `UserDefaults`,
`set` persists, and the clamp lives in the type so it is reachable from a test
without a window.

`VolumeSetting` is the third, and the same shape — but with one trap
`InternalResolution` does not have: **a missing key must mean full volume, not
silence.** `double(forKey:)` returns 0 for an absent key and 0 is a legitimate
volume, so unlike the scale the default cannot fall out of the clamp and the
key's absence is read separately through `object(forKey:)`. **Mute is a flag
over an untouched level**, not a level of zero with the old one stashed beside
it, so unmuting restores what you had without a second field to keep in step;
moving the slider unmutes, or the control is dead with no visible reason why.
The gain reaches the audio device through `AudioOutput.setGain`, which stores a
`Float` **as its bit pattern in an `Atomic<UInt32>`** — `Synchronization` has no
`Float` conformance and the render callback may not take a lock — and it is
applied by multiplying the samples in that callback rather than through
`kHALOutputParam_Volume`, which on a default-output unit reaches toward the
device instead of staying inside our own stream. `AudioOutput` is rebuilt per
game while the setting outlives every disc, so `play()` re-applies the gain to
each new one. In the HUD the slider **replaces** the transport controls instead
of being appended to them (the bar is already as wide as a 4:3 window
comfortably holds), and `VolumeControlState` holds the two-stage click rule —
first click opens, every click after it mutes — so it is testable without a
window, the same reason the OSD's show/hide policy lives on the model.

**This was a Command Line Tools-only machine until 2026-08-22, and that shaped
the whole macOS build. Xcode 26.6 is installed now and most of those
workarounds are GONE** — if you find a note anywhere claiming Xcode is
unavailable, `@State` is unusable, or the shader compiles at runtime, it
predates that and is wrong. `xcode-select` points at `/Applications/Xcode.app`,
so `swift`/`swiftc` on `PATH` resolve to Xcode's toolchain, not CLT's.

What survives from that era, and why each still looks odd:

- **The shaders are compiled OFFLINE and it is the one part that needs full
  Xcode.** `ps1-macos/Shaders/DisplayShader.metal` and `ps1-macos/Shaders/Rasterizer.metal`
  are both sources of record. `build.zig` drives `xcrun -sdk macosx metal` over
  each of them, then `metallib` to merge the two `.ir` files into one library, as
  real build-graph steps; `@embedFile`s the result through
  `ps1-macos/Shaders/embed.zig`, and repacks that object into
  **`libps1shaders.a`** (`zig build metallib`). Swift gets the bytes back over
  two C functions (`ps1_metallib_ptr/len`, declared in
  `Sources/CPs1/include/metallib.h`) and builds the library with
  `makeLibrary(data:)`. This is
  [how Ghostty does it](https://github.com/ghostty-org/ghostty/blob/main/src/build/MetallibStep.zig) —
  including the embed, which is what avoids bundle resources entirely: no
  `.metallib` in `PS1.app`, no copy-resources build phase, no `Bundle.main`
  lookup that can miss at runtime, and the test suite loads the exact same bytes
  the app does.
  **It is a separate library from `libps1core.a` on purpose**: `metal`/`metallib`
  ship with Xcode, not Command Line Tools, and on Xcode 16.3+ they are a further
  separate download (`xcodebuild -downloadComponent MetalToolchain`) — the
  portable emulator ABI must not inherit that requirement, so `zig build
  capi-lib` still works on a CLT-only machine. `build.zig` probes for the
  compiler at configure time (~50 ms) and swaps in an `addFail` naming both
  install steps, because xcrun's own message ("unable to find utility metal")
  says nothing about the component download.
  This replaced a runtime `makeLibrary(source:)` over a Swift string on
  2026-08-22 — **do not reintroduce it.** A shader error belongs at build time,
  not at the first frame of the first game opened.
- **`libps1core.a` is emitted as one object and repacked with `xcrun libtool`**,
  not produced by `b.addStaticLibrary`. Apple's `ld` rejects Zig's own archive
  members outright (`64-bit mach-o not 8-byte aligned`), so `-lps1core` against
  a Zig-produced `.a` does not link at all.
- **There is no `Package.swift` any more.** `ps1-macos/PS1.xcodeproj` is
  committed and hand-maintained, `objectVersion = 70`, following Ghostty (which
  also commits its project rather than generating it with XcodeGen or Tuist).
  `swift build` and `swift test` no longer work in this directory at all;
  `xcodebuild` is the only build system. Two targets: **`PS1`** (the app) and
  **`PS1Tests`** (a unit-test bundle hosted by it).
  `Sources/` and `Tests/` are **`PBXFileSystemSynchronizedRootGroup`s**, which
  is why the project file is ~340 lines and why **adding a `.swift` file needs
  no project edit** — the folder is the target's membership. Do not "fix" this
  by adding `PBXFileReference`/`PBXBuildFile` entries per file.
- **`SWIFT_INCLUDE_PATHS` is set at PROJECT level, not on the app target**, and
  that placement is load-bearing. It points at `Sources/CPs1/include` so the
  hand-written `module.modulemap` resolves `import CPs1`. The test target needs
  it too: `@testable import PS1` loads PS1's swiftmodule, which re-resolves its
  own `import CPs1`, and with the setting only on the app target the build fails
  with `unable to resolve module dependency: 'CPs1'`. `LIBRARY_SEARCH_PATHS` and
  `OTHER_LDFLAGS` stay on the *app* target, because the test bundle resolves
  those symbols through its `BUNDLE_LOADER` host instead of linking them twice.
- **The Zig archives are linked by `$(SRCROOT)`-relative build setting**
  (`LIBRARY_SEARCH_PATHS = $(SRCROOT)/../zig-out/lib`, `OTHER_LDFLAGS =
  -lps1core -lps1shaders`). The old absolute path in `build.sh` existed because a
  relative path in `Package.swift`'s `unsafeFlags` resolves against the linker's
  working directory; a build setting has no such problem.
- **`ONLY_ACTIVE_ARCH = YES` in Release too, which is not the Xcode default.**
  The Zig archives are built for the host architecture only, so a stock
  `ARCHS_STANDARD` release build would try x86_64 and fail to link. A universal
  app needs two `zig build` runs plus a lipo step; that is deliberately not done.
- **`test.sh` passes no `-quiet`, `build.sh` does.** xcodebuild's quiet mode
  suppresses the per-test result lines along with the build noise, so the suite
  would pass in silence and report a failure only through its exit status.

Gone as of 2026-08-22/23, recorded so nobody reinstates them: the two `-rpath`
flags for `Testing.framework`/`lib_TestingInterop.dylib`, the `-plugin-path` for
`libTestingMacros.dylib`, and the ban on `@State`. All three were CLT artifacts.
The Xcode test runner supplies swift-testing itself, `XCTest.framework` is
present should anything ever want it, and **`@State` compiles** (verified by
typecheck on 2026-08-23 — `libSwiftUIMacros.dylib` ships in Xcode's
`MacOSX.platform`). View state living on the `@Observable` model is now a design
choice, not a constraint; there is no reason to "restore" `@State` anywhere.

A few more things worth knowing before changing this code:

- **The letterbox is applied to UV, not to vertex position.** `display_vertex`
  keeps the oversized triangle at full viewport size and divides the UV by
  `scale_x/scale_y`; `display_fragment` returns black for any UV outside
  `[0,1)`. Scaling the *position* instead — which is what it did until
  2026-08-20 — shrinks the triangle around the origin, so the left and top bars
  fall outside it and get the black clear colour while the right and bottom
  bars stay inside it, land past the picture, and get painted by the
  `px >= p.width` clamp with a stretched copy of the last texel column. The
  give-away is the asymmetry: black bar on the left, smeared one on the right.
  Pinned by offscreen render tests in `DisplayRenderTests.swift`, which read the
  corner pixels back — the bug survived every compile-and-pipeline test because
  only the pixels were ever wrong.
- **The window is locked to 4:3** (`WindowConfigurator` sets
  `NSWindow.contentAspectRatio`), so in practice the picture fills it exactly
  and no bar is drawn at all; the letterbox path only runs in fullscreen on a
  non-4:3 display. `letterboxScale` therefore *snaps* to `(1, 1)` when the
  drawable is within half a pixel of 4:3 — the locked ratio lands a hair off,
  and an unsnapped 0.99999 blacks out the outermost pixel column.
  `WindowConfigurator` is also how the traffic lights fade with `GameHUD`:
  SwiftUI exposes neither the aspect ratio nor the standard window buttons, so a
  zero-sized `NSViewRepresentable` that walks up to `view.window` is the whole
  mechanism.
- **The aspect lock must come OFF for fullscreen, and `willEnterFullScreen` is
  the only hook that works.** AppKit honours `contentAspectRatio` in fullscreen
  by *centring* a 4:3 window on a black desktop instead of filling the screen —
  the picture is correct and the whole window is letterboxed, rounded corners
  and all. `updateNSView` does not fire on a fullscreen transition, and by
  `didEnterFullScreen` AppKit has already sized the window against the ratio, so
  clearing it then resizes nothing back. Snapping the window to 4:3 when the
  lock is first applied also has to pick a size that fits the *screen*: deriving
  height from width alone lets AppKit clamp the height and keep the width,
  leaving the window further from 4:3 than it started.
- **The OSD, the traffic lights and the CURSOR hide together, and "a mouse
  move" is defined as a change of POSITION.** A click on the picture calls
  `hideHUDNow()`, which takes all three down at once instead of waiting out the
  2.5 s idle timer; `WindowConfigurator.applyChrome` hides the pointer with
  `NSCursor.setHiddenUntilMouseMoves(true)` and has no matching unhide, because
  the system brings it back on the first movement. The subtle half is on the
  other side: `onContinuousHover` reports the pointer for a *click* as well as
  for a move, so re-showing on every callback undoes the hiding click in the
  same runloop turn and the OSD never goes down at all. `hoverMoved(to:)`
  therefore compares the point against the last one and re-shows only when it
  actually differs — which is the same rule the hidden cursor returns under, so
  the two stay in step without either driving the other. Pinned by four tests in
  `HudVisibilityTests.swift`.
- **The FPS readout counts EMULATED frames, not presented ones.**
  `EmulatorRunner` republishes `frameSeq` as the `framesProduced` atomic and the
  view model polls that total every `FpsCounter.window` (0.5 s) — a cumulative
  count rather than a rate, so the reader sets its own cadence and a missed poll
  costs accuracy rather than a frame. The number that matters is whether the
  core is keeping up with the ~59.94 a real NTSC machine runs at, which the
  display's own refresh rate cannot tell you; a paused emulator correctly reads
  0. `FpsCounter` is a value type for the same reason `InternalResolution` is
  one — the windowing rule is then reachable from a test with synthetic
  timestamps, including the case that matters: `eject()` installs a new runner
  whose count restarts at zero, and subtracting the old baseline would underflow
  `UInt64` rather than merely read wrong.
- **Keyboard input goes through an `NSEvent` monitor, not `onKeyPress`.**
  SwiftUI hands back a `KeyEquivalent` (a Character); `InputMap.button(forKey:)`
  is keyed on macOS **virtual key codes**, which are layout-independent, so the
  D-pad stays on the same physical keys on AZERTY or Dvorak.
- **`Disc` borrows its bytes.** `ps1_load_disc` does not copy the `.bin`; it
  holds a slice into the caller's buffer, so `Ps1Core` retains the `Data`
  alongside the handle. The cue is parsed immediately and is not retained.
  `ps1_load_disc` also decides `PS1_ERR_BAD_CUE`/`PS1_ERR_MULTI_FILE_CUE`
  *before* calling `initFromCue`, because `initFromCue` never fails — it falls
  back to a single data track on a cue it cannot parse.
- **`Sources/PS1` and `Sources/PS1App` are ONE module, `PS1`.** The `PS1`
  target's `fileSystemSynchronizedGroups` is the whole `Sources` root, with
  `PRODUCT_MODULE_NAME = PS1` — there is no per-subdirectory module boundary,
  `Sources/PS1App` is a directory convention, not a second target, and
  `import PS1` inside it is a self-import (a "file is part of module 'PS1';
  ignoring import" warning, not an error). `public` on the app-facing seams
  (`ContentView`, `EmulatorViewModel.isPaused`, `rescanLibrary()`,
  `internalScale`) is therefore a uniform convention across those seams, not a
  boundary requirement — nothing in `Sources/PS1App` needs `public` to reach
  them. Treating it as a real module boundary is what produced `menuRange`, a
  member invented to "cross" a boundary that does not exist; it was dead
  weight and was reverted in `4252a00`.
- **`Sources/CPs1` is a DIFFERENT thing: a headers-only Clang module, not part
  of `PS1`.** It holds no compiled sources, only
  `include/{ps1_shim.h, metallib.h, prim_instance_shim.h, module.modulemap}`,
  and that modulemap is what declares `module CPs1 { … }`. It is reached
  through `SWIFT_INCLUDE_PATHS = $(SRCROOT)/Sources/CPs1/include`
  (`PS1.xcodeproj/project.pbxproj:209,230`), and `import CPs1` is a real,
  load-bearing cross-module import used by 20 files across `Sources/` and
  `Tests/` — do not delete it as if it were the `PS1App` self-import above.
  The tell that separates the two: a genuine `import CPs1` emits no "ignoring
  import" warning, because there really is a module boundary there.

The button mask crossing the ABI is `sio.zig`'s own: **0 means pressed**, 1
released, `0xFFFF` idle. The ABI deliberately does not re-invent a button enum.

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

1. Run headless with `ps1-trace <bios.bin> <disc.bin> <max_instr> <snapdir> [autostart|walk|explore]`.
   `autostart` cycles Start/Cross/Circle with real button codes so intros, FMVs
   and title menus get walked past and a run reaches gameplay. `walk` adds a
   held Up for scenes gated on the player moving. **`explore` is the one that
   actually covers ground**: past 600M instructions it stops pressing Start
   (in-game that opens the inventory, and a run that pauses every few frames
   goes nowhere) and steers on a fixed LCG, mixing turns into the held Up so it
   does not simply walk into the first wall and stay there. It is deterministic,
   so a scene it reaches can be re-reached and A/B'd. It is still a blind
   walker: it reached Silent Hill's opening street and the Cheryl cutscene but
   never the alley beyond it.
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
  Sidecars are loaded from `<disc>.sbi` by `ps1-trace` and `ps1-golden`, and in
  the browser by `allocSbiBuffer` from the uploaded folder; `ps1-debug` does not
  load them (it takes a raw `.bin` and caps at 700 MB, so it cannot open these
  discs anyway).
- **The subchannel Q and the sector header must describe the same sector.**
  `readNextSector` used to refresh both *before* advancing `current_pos`, so
  GetlocP reported the sector before the one just handed over. Nothing noticed
  for months, because only software that correlates the two can see it —
  LibCrypt does exactly that, and with the Q one sector late every protected
  address reads back clean. Fixed 2026-08-19, pinned by a test in
  `cdrom_test.zig`. It moved the `cdrom` state hash of every disc workload and
  nothing else, which is what the accompanying golden recapture records.

Known remaining gaps (fix opportunistically, none currently blocking):
- **No disc swap.** `setDisc` replaces the slice and nothing else: there is no
  shell-open/close state (stat bit 4, the door-open INT5, the TOC re-read a game
  polls for), so a multi-disc title cannot be continued past its first disc —
  the swap is invisible to the game and it keeps its cached file table. The
  relaunch workaround fails too, because the 128 KB memory card image is
  in-memory only (`memcard_dirty` is set and never consumed), so disc 2 boots to
  no save data.
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

**GPU** (`gpu/`) — ABGR1555. **The triangle path is an integer edge-function
rasterizer with a top-left fill rule and exact integer interpolation of every
per-pixel attribute (Gouraud colour, texcoord, texture modulation) — no `f32`
anywhere in the inner loop.** The formulas are shared with the Phase B Metal
backend by design (Metal Renderer Design, Phase 0): don't "optimise" them back
into float, or into incremental/stepped fixed-point, even though either would
be a cheaper CPU implementation on its own. **`drawShadedLine`'s gradient is
the same deal**: `c0 + floor((c1-c0)*k / steps)`, evaluated from the step
index `k` rather than accumulated — also not to be turned back into float or a
DDA. **Dither offsets, wherever added (Gouraud, texture modulation, the
shaded-line gradient), are 8-bit channel units**, added to the channel at
8-bit scale and clamped to `[0, 255]` *before* the `>> 3` down to 5 bits —
misreading them as 5-bit units is the bug `900daa0` fixed. `900daa0` also
moved `drawTexturedRectangle`'s output: it calls `modulate` with dithering
too. **No texture/CLUT
cache** (re-reads VRAM per texel). GP0 goes through a real 16-word FIFO with a
`cycle_debt` budget; cycle "cost" is hand-tuned heuristics, not real clocks.
Quads decompose into 2 triangles (possible diagonal seam); the textured-rectangle
path avoids decomposition on purpose. **A primitive whose vertices span >=1024
horizontally or >=512 vertically is dropped, not clipped** — the check sits in
`rasterizeTriangle` (per triangle, so each half of a quad is judged separately),
in both line paths, and in both rectangle paths — the GP0 rectangle size field
is 16 bits, so nothing else bounds it. Matches Avocado's
`render_triangle.cpp:214` / `render_line.cpp:24` / `render_rectangle.cpp:17`. This is load-bearing, not a micro-optimisation: geometry
crossing the near plane projects to screen coordinates that saturate at the
GTE's +-1024 SXY clamp, and hardware refusing to draw the result is the only
thing keeping it off screen. Games do not clip it themselves. Without the rule
Silent Hill's roadside foliage sweeps across the camera in the opening street —
about 110 triangles per 4 frames there are oversized, and every one of them was
being painted. Pinned by four tests in `gpu_test.zig`. Scanout uses the **programmed display area**
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

**`gp0.zig` cannot reach the renderer.** Every VRAM-visible effect goes through
`gpu/sink.zig`, which builds a fixed-stride `command.Command` and hands it to
`command.execute` — the one function that turns a record into an effect, used by
the live path and by replay alike. The seam exists so the Metal backend can
consume an ordered stream, and the structural guarantee is the missing import: a
primitive that does not appear in the sink does not draw. **The stream must carry
the implicit texpage latch, not just E1-E6** — `e1_texpage_mask` covers bits 5-6,
the semi-transparency mode, so a textured polygon's blend mode comes from its own
tpage word; rectangles do not latch. Which core module records is a comptime
build option (`gpu_sink`), `.software` everywhere except `ps1-golden`, the two
ROM suites, and — since Phase D1 — `ps1-capi`, so the macOS app and `capi_test`
build `.dual` too; `Recorder.enabled` is a further runtime flag, so
`capture`/`verify` stay at today's speed. The recorder's capacities (`max_records`,
`max_payload_words`) are sized off the peaks `stream-verify` prints — it prints
them on success too, for exactly that reason.

**The fixture bridge is how Metal gets tested at all.** Metal runs only under
`ps1-macos/test.sh`; the ROM suites run only in Zig. `zig build fixtures`
writes `.p1fx` files — a header, a frame table, 72-byte records and a payload
blob — that Swift reads through `FixtureFile`. **The record type is declared
in `ps1-capi/include/ps1.h`, not mirrored in Swift**, because Swift does not
guarantee C-compatible struct layout; the header's `record_stride` and
`kind_count` are checked on load so a field or a `Kind` added on the Zig side
fails loudly instead of shearing every record. The hash is **FNV-1a 64, not
the trace harness's Wyhash** — Wyhash is a std-library implementation that can
change across Zig releases, and a file format pinned to it would break on a
toolchain upgrade while presenting as "Swift disagrees with Zig". Payload
offsets are **frame-relative**: a `vram_write_data` record's `.x` indexes its
own frame's run, exactly as `command.replay` reads it. Only the committed
synthetic fixture has its VRAM hashes verified — `ShadowVram` models the
memory movers, never the rasterizer — so the PL and Croc fixtures are
structurally checked and otherwise banked for Phase B. **Sixteen of each
PeterLemon fixture's seventeen frames are empty and repeat frame 0's hash** —
those ROMs draw once and then idle, so "17 frames verified" is not 17 frames
of coverage; only frame 0 is doing anything.

**The Metal backend renders at an internal resolution of 1-8x, and since Phase
D2 that scale is a player-chosen setting that reaches the screen.**
`MetalRasterizer` (with `MetalVram`, `PrimBuilder`, `PrimEncoders`,
`HazardTracker`) consumes both `.p1fx` fixtures and, since Phase D1, the live
command stream: `ps1-capi` builds `gpu_sink = .dual`, `ps1_take_frame_stream`
drains one frame per `ps1_run_frame`, `EmulatorRunner` copies it into a 4-slot
ring, and `LiveRenderer` drains that ring from the `MTKView` draw callback.
`Video ▸ 1x…8x` writes `InternalResolution` to `UserDefaults`. The menu attaches
⌘1…⌘8 via `.keyboardShortcut` on each `Picker` option's `Text` in
`VideoCommands.swift` — not a documented SwiftUI contract, only a type-check —
so treat the accelerators as unverified until someone confirms them by eye; a
plain `Button` per scale is the fallback shape if they don't show up in the menu.
`ContentView` keys `.id()` on the runner's identity AND the scale, so a change
rebuilds the coordinator, its pipelines, its `LiveRenderer` and its `MetalVram`
through exactly the path a disc change already uses.
Fixture playback still produces VRAM byte-identical to the software
rasterizer, checked per frame by `MetalRasterizerTests`. Four things about it
are load-bearing and easy to
"fix" wrongly: **coverage is decided in the FRAGMENT shader**, never by Metal's
rasterizer, whose fill rule and sample positions are not the PS1's; **blending
is integer arithmetic on 5-bit channels**, never fixed-function blending, which
normalizes to float and rounds differently; **every primitive is one instance
of a bounding-box quad** with all its state resolved on the CPU into a
`Ps1PrimInstance`, which is what leaves no pipeline state differing between
primitives and therefore nothing to break a batch on; and **a draw that samples
what the current render pass has already written must end that pass first**
(`HazardTracker`) — on a tile-based GPU such a read returns pre-pass contents,
so without the split it is silently stale. `synthetic-primitives.p1fx` is the
per-feature gate ladder, committed, one feature group per frame in a fixed
order that the Swift tests index by number; append to it, never reorder it.
**The texel HOLE is decided on the RAW texel, before modulation, and the
sampled colour must not travel back through the same value.** `renderer.zig:439`
returns `.draw = false` only for a raw texel of 0; a non-zero texel that
modulation maps onto 0x0000 is drawn BLACK (`renderer.zig:441-446`). Until
2026-08-30 `ps1_sample` returned the modulated colour and reused 0 as the hole
sentinel, so every such pixel was discarded and whatever was already in VRAM
showed through — a green speckle over the dark parts of Croc's rock, door and
crate. It now returns a bool with the colour in a `thread ushort&` out-param,
the shape `ps1_triangle_coverage` already used. Two things about it are worth
remembering. **Dithering makes one bug look like two**: its offset is in 8-bit
channel units and is applied at 1x only, so a marginal channel is pushed under
8 (and `>> 3` to 0) in a speckled pattern at 1x and left alone above it — the
crate's speckles vanish at 8x while the door's, whose un-dithered value is
already 0, do not. **The whole fixture corpus agreed on every hash throughout**,
because nothing in it modulates a texel to zero; a hand-built test
(`aTexelThatModulatesToBlackIsDrawnRatherThanDiscarded`) is what pins it, not
the gate ladder.
**A primitive that samples its OWN destination is the one shape no GPU
backend can reproduce, in any phase.** The software rasterizer scans row by
row, so a triangle whose texture read lands on pixels it has already drawn
sees the new values deterministically — and that determinism is baked into
every hash it produced. Nothing orders fragments *within* one primitive on a
GPU, so `HazardTracker` (which orders one draw against the next) does not
help and never will: it is a divergence class, not a bug to chase. Frames 2
and 4 of `synthetic-primitives.p1fx` contained it by accident and were
relocated below every read address they can generate (`142feb0`, `99bb56e`);
frames 0-5 now hold that invariant by construction, and frame 6's
*inter*-primitive feedback is the deliberate case `HazardTracker` exists for.
Expect this to resurface in Phase D as a real game diverging on a handful of
pixels with no explanation in the encoder.

Five things about the live path are load-bearing. **`ps1_take_frame_stream` is a
DRAIN, not a peek** — it resets the recorder, so it must be called exactly once
per `ps1_run_frame`, and a frame left untaken stacks onto the next until the
capacity overruns. **`complete == 0` means the records are a PREFIX**, so the
stream is discarded and the renderer resyncs from the shadow rather than
replaying it. **VRAM is published before the stream, under the same seq**, so a
shadow sampled at seq `S` accounts for every frame up to and including `S` and
for none above it — which is why a resync discards **only the slots at or below
`S`** (`StreamQueue.discardThrough`) and executes the rest. Discarding the whole
backlog instead loses the mutations of any stream published after the sample,
and replaying a slot at or below `S` applies its mutations twice, which
VRAM->VRAM copies, semi-transparent blends and mask-bit draws do not survive.
The flag is **cleared before the shadow is sampled**, because `clearResync` is a
store rather than a compare-and-clear and would otherwise swallow a request
raised in between; and it is **left raised when the queue does not resume at
`S+1`**, since a hole means the survivors have no matching base. Until
2026-08-30 this was "discard the backlog and adopt the newest shadow", sampled
after the queue snapshot, and it was racy in both directions. **Execution never skips a frame, only
presentation does** — a command stream is a set of incremental mutations, unlike
the idempotent VRAM snapshot the shadow path publishes. And **24bpp scans out of
the 1x shadow permanently**, because it byte-packs across adjacent 16-bit words
and that arithmetic cannot survive N x N replication; Croc and Silent Hill both
depend on it.

Two environment switches, both debug-only and both read by the APP rather than
the test host (the marker-file scheme exists because the hosted test process sees
no environment; the app launched from a shell has an ordinary one):
`PS1_LIVE_DIFF=1` reads the render texture back each frame and logs the first
divergence against the shadow, and `PS1_SOFTWARE_DISPLAY=1` routes 15bpp back to
the shadow so a suspect frame can be A/B'd without a rebuild. Neither is a mode
and neither is a user-facing setting.
**A silent `PS1_LIVE_DIFF` run is not by itself evidence** — the oracle compares
only when the newest published frame is the one the texture holds, and it runs
after a `drain` that blocks on the GPU, so every frame the emulator publishes in
that window is skipped rather than compared. It therefore prints a running
`checked N frames, skipped M` tally every 300 decisions and once more on eject;
read that ratio before reading anything into the absence of divergence lines.

Four things about the SCALED display path are load-bearing. **The scanout wrap
is NATIVE, then scaled** — `((vram_x + nx) & 1023) * s + sub_x`, never
`& (1024*s - 1)`: a bitwise mask is a modulo only at power-of-two `s`, so at
`s = 3` a display window crossing the VRAM edge samples the wrong column. The
parent Metal spec specifies the mask form in two places; **it is wrong and must
not be implemented as written.** **Scaling the wraps alone is a no-op** — `px`
is derived from `p.width * p.scale`, and without that multiplication every
sample lands on its block's top-left subtexel, which by Phase C's exactness
property is byte-identical to the 1x picture: the player selects 8x, pays 67 MB
and sees nothing. **24bpp and the `PS1_SOFTWARE_DISPLAY` seam read the 1024x512
shadow at `nx`/`ny`, discarding `sub_x`/`sub_y`** — feeding them `px` breaks
every FMV in Croc and Silent Hill above 1x and nowhere else. And
**`MetalDisplayView.Coordinator.init` calls `requestResync()` unconditionally**,
because a rebuilt `MetalVram` is a BLANK texture while a command stream is a set
of incremental mutations; `StreamQueue`'s `resync` flag defaults true, but that
covers a FRESH queue, and a scale change keeps the runner and therefore keeps
its queue.

**The default is 1x, and that is a testability decision.** 1x is the only scale
with a per-frame byte-exact oracle on arbitrary content — the software shadow is
a reference for whatever is actually being played — and above it the check
weakens to downsample-invariance. Selecting 4x opts out of the stronger check
knowingly; the shipped configuration must not opt out for the player.
`InternalResolution`'s initializer CLAMPS into 1...8 rather than trusting the
stored value, and `set` clamps again on the way in, because `MetalVram.init`
traps out of range and a `UserDefaults` integer is data, not a literal.

**The 4:3 aspect lock does not interact with internal resolution.** The parent
spec lists that interaction as Phase D work; there is none, and this note exists
so nobody concludes it was forgotten. `letterboxScale` reads the drawable's
dimensions, `WindowConfigurator` reads a constant `NSSize(4, 3)`, and
`display_vertex` applies the letterbox to uv while leaving the triangle at full
viewport size — none of the three reads the renderer, the display area or the
scale. Internal resolution changes how finely the render texture is sampled, not
the dimensions of the picture or of the window.

**`PS1_LIVE_DIFF` works above 1x for free, and it is the only coverage there
outside the fixture corpus — but expect it to be loud.** `LiveRenderer.diff`
reads `vram.readbackNative()`, which is already the top-left-subtexel view at
any scale, so at N the oracle becomes a live downsample-invariance check on
real games. It shares that role with a second, expected divergence class:
`Rasterizer.metal`'s fragment shader gates dithering on `s == 1`
(`bool dither = (p.flags & PS1_PRIM_DITHER) && s == 1 && uni.dither_off == 0u`,
`Rasterizer.metal:182`), so above 1x every dithered primitive draws without it
while `LiveRenderer.diff`'s software shadow always dithers. A real game at
2x/3x/4x will therefore print a divergence line on essentially every dithered
3D frame the oracle checks — that is by design, not a scale bug. The signal
worth reading a run for is a divergence that is *not* a ±1 single-channel
difference spread over a gradient; that shape is the dithering class, already
accounted for. Its `checked/skipped` tally still has to be read before an
absence of output means anything.

**Internal resolution is a runtime uniform, and every RECORD stays native.**
`Ps1PrimInstance` is in 1024x512 units at every scale — the vertex shader
sizes the quad to `box * s` and each fragment shader recovers
`nx = px / s`, `sub_x = px % s` and multiplies by `s` at the point of use.
That is a testability decision: the 1x gate compares literally the same
instance bytes Phase B pinned, and the oversized-primitive refusal and the
hazard rectangles never need a second coordinate space. Three rules are
load-bearing and each has a test aimed at it alone: **the drawing-area clip
is inclusive**, so it scales to `[x0*s, (x1+1)*s - 1]` and the plausible
wrong form (`x1*s`) is invisible to both the 1x gate and the
downsample-invariance gate, because they agree at every top-left subtexel;
**`ps1_vram_read` linearizes `y*1024+x` in NATIVE space and scales only the
resulting address**, since that row-crossing reproduces `Vram.index` and
linearizing at scale would invent a different wrap; and **`ps1_copy_fragment`
is the one read that is not reduced to native** — it carries `sub_x`/`sub_y`
so a VRAM->VRAM blit preserves scaled detail, and those terms are zero at a
top-left subtexel, so dropping them would pass every hash. Texture data is
never upscaled: a texel at `(u, v)` reads its block's top-left subtexel at
all three depths. **Dithering is on at 1x and off above it**, decided in the
shader (`scale == 1`) and never by clearing the flag in `PrimBuilder`, which
would make the record differ between scales — the visible consequence is
that a scaled frame loses the dither cross-hatch and shows 5-bit banding on
Gouraud gradients instead, which is correct and is Phase D's to revisit. The
gate is **downsample-invariance**: taking each block's top-left subtexel
reproduces the 1x image byte-for-byte over the whole 1024x512, on every
frame of all eleven fixtures, at N in {2,3,4,8} — **3 is in that list on
purpose**, since `/ s` and `% s` are shifts and masks at every power of two
and a `>> log2(s)` bug is invisible at 2, 4 and 8. Measured, the scale-8
pass over both 100-frame geometry fixtures costs 2.9 s, so nothing narrows.
Nothing display-side scales yet (the scanout wrap, 24bpp, the scale picker);
that is Phase D2.

**`HazardTracker`'s rule is symmetric, and the second half arrived late.** A
read during a render pass resolves against device memory; a write during that
same pass reaches device memory only when its tile is stored. So a draw that
WRITES what an earlier draw in this pass SAMPLED is exactly as unordered as
the reverse, and until 2026-08-30 only the reverse was tracked. It presents
as a RACE, not as a stable wrong pixel — frame 6 of `synthetic-primitives`
hashed three different ways across three runs of one binary once a Phase C
shader edit perturbed scheduling, and correctly and stably before it. Read
rects are kept as a LIST where written rects are unioned, and that is worth
50x: a sampled rect is a whole 256-row texture page, so unioning two distant
pages covers most of VRAM and nearly every later write then intersects it —
over `silent-hill-usa`, 244 passes before, 266 with the list, 13,767 with a
union.

**The two opt-in Metal gates are switched by a FILE, not an environment
variable.** `zig-out/fixtures/PS1_DUMP_SCALED` (holding N) writes the
comparison PNGs and `zig-out/fixtures/PS1_SCALE_TIMING` prints the per-scale
replay cost. That is forced, not chosen: the shared scheme's TestAction
carries `shouldUseLaunchSchemeArgsEnv`, and the hosted test process sees
neither an exported variable nor one passed with xcodebuild's `TEST_RUNNER_`
prefix — verified with a probe that printed an empty environment for both.
`zig-out/` is gitignored, so a marker cannot be committed by accident. Run
them with `-parallel-testing-enabled NO`: swift-testing otherwise runs them
beside the scale-8 comparisons, and the GPU contention both skews the timing
and intermittently fails the run.

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
no transfer at all (Avocado dispatches only modes 0/1/2).
**A linked-list chain that closes into a ring is a real thing real games build,
and it is guarded, not fixed** (`ll_node_limit`, 65,536 nodes — above the 512K
distinct nodes 2 MB of RAM could hold in principle and 4x the largest ordering
table any game allocates). Tekken 3 emits one fighter twice on the frame its
round-phase machine leaves state 4, which links a chain's tail to its own head;
**Avocado builds the identical ring on the identical store** and survives only
because `dma_channel.cpp` carries the same guard ("GPU DMA transfer loop
detected, breaking"). Hardware survives it differently and this is the one place
our CPU-stall model is knowingly unfaithful: **hardware does not halt the CPU
during DMA**, it steals bus cycles, so the next frame's `DrawOTag` restarts the
channel on a fresh list and the ring costs a dropped frame instead of the
machine. Real CPU/DMA interleaving would be the faithful fix; it would move
interleaving in every game and needs a rate nobody has measured, so it has not
been attempted. Do not "improve" the guard into a behaviour change without that
measurement, and do not read the guard as a claim about hardware. Channel priority is
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
- **The page fetches `/zig-out/bin/emulator.wasm`, so a core fix does not reach
  the browser until `zig build` runs — a hard reload alone re-fetches the *old*
  binary.** This is not hypothetical: the Tekken 3 "freezes on the STAGE 1
  XIAOYU VS JIN portraits screen" report was chased for a whole session against
  a tree where the fix (`60c136f`) was already committed, because the served
  wasm predated it. Before treating a browser-only symptom as a live bug,
  rebuild and check the `.wasm` mtime against the commit you expect. A browser
  symptom that no headless run reproduces is a stale-binary suspect first.
- **The browser build can be driven headlessly** — instantiate
  `emulator.wasm` under node, feed `getBiosPtr`/`allocCdBuffer`/
  `allocCueBuffer`/`loadCdFromBuffer` exactly as `index.html` does, then call
  `setControllerButtons` + `stepFrame` in a loop and fingerprint VRAM per
  window. That reproduces browser behaviour at ~80 fps without a browser run,
  and it is how the stale-binary case above was finally settled (the pre-fix
  wasm froze on the VS screen with `pos=` pinned, HEAD passed it on the
  byte-identical input schedule).
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
