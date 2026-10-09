# Core performance roadmap

Date: 2026-10-09. Status: roadmap; each item gets its own spec or plan
before work starts.

## Goal

Cut the emulator thread's cost in the configuration the macOS app ships
(`.jit`, `gpu_sink = .dual`, raster worker attached), and the browser's
(interpreter or `.cached`, single thread). At 1x the core is already a small
slice of a frame, so the payoff is in what multiplies it: runahead (N+1
frames of core per displayed frame), fast-forward, PGXP, battery, and the
browser build, which has no JIT.

Every item keeps the **interpreter byte-exact**: `trace-golden -- verify`
passes against `trace/` unchanged. Block-engine goldens (`trace-block/`) may
move only where an item says so, and then by owner ruling, as their own
commit (see `ps1-test-harnesses`).

## Where the time goes (measured 2026-10-09)

M1 Air, `ps1-bench-dual … 3000 --engine=jit threaded`, ReleaseFast,
xctrace Time Profiler, self time on the emulator thread. Measured AFTER
item 0 below landed in the tree.

| Cost | Silent Hill | Crash Warped | Spyro (PGXP on) |
|---|---|---|---|
| JIT code | 18.5% | 24.2% | 32.9% |
| Scheduler (`deadline`, `advance`, `charge`, `flush`, `serviceDue`, `tickSlow`) | ~17% | ~9% | ~5% |
| DMA (`cpuWindowDeadline`, `channelIsRunnable`, `step`, `doBlockCopyWord`, `isCpuStalled`) | ~9.5% | ~1.5% | ~1% |
| `cached.runOp` + `beginInstruction` (JIT fallback) | ~1% | ~5% | ~4% |
| SPU (`generateSample`, `adsr.step`, `decodeBlock`) | ~3.5% | ~13.6% | ~2% |
| JIT compile churn (`sys_icache_invalidate`, `Emitter.put`, install copies) | <1% | ~4% | <1% |
| PGXP shims (`loadShim`, `pgxp.ops.*`, `Hooked` shims) | - | - | ~17% |
| MDEC `idct` | 3.1% | - | - |

Interpreter only (Croc, the browser's path): `Cpu.step` 16.7%,
`exec.handlerFor` 7.3%, `Bus.read` 6.8%, `beginInstruction` 5.5%,
`isInstructionBusErrorAddress` 3.9%, `scheduler.tick` 3.6%,
`isCpuStalled` 2.9%.

The raster worker runs `putPixel` at ~42% of its own thread but is busy
only ~20-40% of the time. It is off the app's critical path; it is ON the
browser's.

Probe counts over 3000 frames (temporary instrumentation, reverted):

| | Crash Warped | Spyro | Croc | Silent Hill |
|---|---|---|---|---|
| Blocks run on `.cached` because a load was pending at entry | 5.1M (43M instr) | 5.9M (49M instr) | 2.0M (21M instr) | 1.5M (18M instr) |
| JIT code-page invalidations | 37,113 (one hot page) | 705 | 2,023 | - |

## Measurement protocol

- `zig build -Doptimize=ReleaseFast`, then `ps1-bench-dual` with
  `--engine=jit threaded` (the app) and with no engine flag (the browser's
  interpreter). Note zsh does not word-split `$var`: pass flags literally.
- **Interleaved A/B, best of three or more**, two binaries copied aside
  (`git stash` to build the old one). Never compare against a remembered
  number: the fanless Air drifts ±15%, and a run straight after
  `trace-golden` reads slow. Check `uptime` load first.
- Attribute with xctrace (`project-emulator-cpu-profile` memory has the
  export recipe); `sample` cannot split inlined code.
- Count events with a temporary probe (global counters printed by the
  bench), then revert it. Every item below started from a count, not a
  guess.

## Items, in order

### 0. GP0 FIFO deadline: DONE in the tree, uncommitted

`Gpu.nextDeadline` returned 1 while the FIFO held words, though a queued word
waits only on `cycle_debt`. Under a block engine `flushOverrun` then handed
overruns over one cycle per full device fan-out: 140M one-cycle chunks on
Silent Hill. Now `min(scanline, cycle_debt)`.

- Silent Hill 350 → 508 fps (+45%); others within noise.
- Interpreter `verify`, `--threaded=deferred`, `lockstep --engine=jit`, JA
  12/17, PL, unit tests: OK.
- **`verify --engine=jit/cached`, `savestate`, `snapshot` diverge** on
  silent-hill (cdrom first, 217.5M) and spyro (302.5M):
  `CdRom.stepEvents(cycles)` takes a whole hand-over chunk as "this step's
  delta", so the chunk size is visible to block engines.
- **Blocked on owner ruling:** recapture `trace-block/` as its own commit,
  explained in `ps1-test-harnesses`.

### 1. JIT entry with a load in flight

`jit.execute` (`recompiler/jit.zig:128`) sends a whole block to
`cached.execute` when `load_delay.load_r != 0` at entry, which a load in a
branch delay slot (`jr $ra; lw …`) produces constantly. Such a block also
returns to the dispatcher rather than linking.

- **Approach:** a second, lazily compiled entry per block that executes
  op 0 inline, then retires the pending load at run time (`load_r`/value read
  from `Cpu.load_delay`; skipped if op 0 wrote `load_r`, per the
  cancel rule), then continues in the normal model. Start with op 0 not a
  load, branch or COP op; measure what share that covers before
  generalising.
- **Link exits** whose target is entered with a load pending need the same
  entry, or they keep falling back.
- **Gates:** `lockstep --engine=jit` (per block; this item changes nothing a
  block computes), `verify --engine=jit` against `trace-block/`
  unchanged (block boundaries and interrupt points do not move), the jit
  fuzzers. A goldens move here is a bug.
- **Expected:** ~5% on Crash/Spyro from the fallback alone, plus whatever
  the restored linking is worth.

### 2. DMA-stalled steps in batches

While DMA owns the bus each word is one `Cpu.step`, even under the JIT
(`run.zig`'s `isCpuStalled` path), and a stalled step always takes
`tickSlow`: a full `advance`, `deadline`, and the seven-channel
`cpuWindowDeadline` loop. ~9.5% of Silent Hill's thread.

- **Approach:** let a stalled step defer when its word changed nothing that
  `deadline` reads (no block gap armed, no chop turn started, transfer not
  ended). The DMA reports that. Stalled cycles need their own pending count:
  today `pending` doubles as the DMA CPU-window count, and stalled cycles
  must not tick the window.
- **Exactness:** interpreter-exact, like the CDROM and GPU deferrals: nothing
  is due inside a deferred window. `trace/` must verify unchanged.
- **Gates:** `verify` on all engines, `savestate`, `snapshot`,
  `--threaded=deferred`, JA 12/17 (the DMA tests are in it).

### 3. Scheduler residue

- **MMIO reads that cannot move a deadline.** Every IO access `sync`s and
  zeroes `downcount`, so the next step takes the full slow path. A read of
  the SPU, timers, I_STAT/I_MASK or DMA registers moves no countdown; after
  such a read `downcount = deadline(bus)` is exact. Writes, and every read of
  a device whose `catchUp` zeroes its own countdown (GPU, CDROM), keep the
  current rule.
- **`cpuWindowDeadline`:** cache the minimum when a channel's gap/chop state
  changes, not per call.
- **`getDotclockDivider`:** cache on GP1(08h).
- **Gate:** `verify` unchanged on every engine; first count slow paths by
  cause with a probe, as for item 0.

### 4. SPU voice mixing

~14% of Crash Warped's thread. Each output sample walks 24 voices in scalar
code: 4-tap Gaussian, ADSR, volume, per-voice bit tests on NON/VON/PMON.

- **First, the cheap check:** count voices that are `is_on` with a zero
  envelope and nothing to fetch. If they are common, skipping them is the
  win and SIMD is secondary.
- **Then SIMD:** `@Vector` lanes over voices for the Gaussian and the volume
  stage (integer, so exact). PMON chains voice n on voice n-1's raw sample,
  so it stays scalar where set. NEON inline asm only if `@Vector` codegen is
  measured to fall short.
- **Gates:** `verify` (the `spu` region moves every sample, so it is a tight
  net), the reverb goldens in `spu_test`.

### 5. JIT code-page invalidation granularity

Crash Warped invalidates one hot 4 KB page ~12 times a frame (data beside
code) and recompiles every block on it.

- **Approach:** compare the written offset against each block's byte range
  on hot pages only, or drop `page_shift` to 10 if a measurement says the
  bitmap cost is fine. `invalidations[]` already counts per page.
- **Gates:** `lockstep`, `verify --engine=jit`, `snapshot --engine=jit`
  (stale-block bugs show there).

### 6. PGXP in emitted code

With PGXP on (Spyro), the shims (`loadShim`, `pgxp.ops.source/addi/add`,
`Hooked` shims, `storeShim`) are ~17% on top of 33% JIT code. Inline the
hottest pairs (`addi`/`addiu`, `lw`/`sw` shadow moves) in arm64.

- **Gates:** `trace-golden -- pgxp` floors, `pgxp --snapshot`, the PGXP
  fuzzers. The CLAUDE.md JIT/PGXP rules (tier flush, `shadow.hooked`,
  never rotating `load_shadow` in emitted code) all apply.

### 7. MDEC IDCT

3.1% of Silent Hill; FMV-heavy games only. 8x8 integer matrix multiply:
`@Vector(8, i32)` rows. Gate: `verify` (mdec moves only in croc,
silent-hill, tr1) plus the MDEC unit tests.

### 8. Browser path: interpreter and software rasterizer

- **Decide first** whether the browser runs the interpreter at all: the
  demo page already defaults to `.cached`. If it does not, this item shrinks
  to the rasterizer.
- **Interpreter:** pre-decode handlers (what `.cached` does), check
  `isInstructionBusErrorAddress` only when the PC changes region, fold
  `isCpuStalled` into the slow path.
- **Rasterizer:** hoist the clip test and mask flags out of `putPixel` to
  span bounds; the per-pixel arithmetic is untouched, so Metal parity holds.
  SIMD spans are out of scope: the integer formulas are shared with Metal.
- **Gates:** `verify` on all engines, `stream-verify`, PL floors, the
  Swift fixture gates (`ps1-macos/test.sh`) for anything in `gpu/`.

## App-side, not core (already known, still open)

- Cold `MetalRasterizer.init` builds 28 pipelines on the main thread: ~1.15
  s after an install or OS update. Build async or pre-warm off-main.
- Fast-forward at 1x is capped at 3.6x for PAL games by the 3-frame
  `StreamQueue` drained once per 60 Hz draw callback. Drain on frame
  arrival.
- The live app has never been profiled per thread with the JIT on. Do that
  before attributing any app slowness to the core.

## Already measured as noise (do not re-propose)

From 2026-10-01 (`project-emulator-cpu-profile`): a RAM-first fast path in
`Bus.read`, branchless `readReg`, `@call(.always_inline)` of `Cpu.step`,
skipping the colour divides on flat textured pixels. Each within drift; all
four together ≤2%. A register cache in the JIT was measured at <1%.

## Known nuisance

`test-roms-pl -Dengine=jit` fails intermittently under machine load, on the
baseline as well as with item 0; a rerun passes. Not a gate for this work
until it is understood.
