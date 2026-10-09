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

### 0. GP0 FIFO deadline: DONE

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
- `trace-block/` recaptured by owner ruling, as its own commit; the diff
  is explained in `ps1-test-harnesses`.

### 1. JIT entry with a load in flight: DONE

`jit.execute` sent a whole block to `cached.execute` when `load_r != 0` at
entry, which a load in a branch delay slot (`jr $ra; lw …`) produces
constantly, and `exitsLink` refused to link such an exit.

- **As built: no second entry.** The entry's load was already op -1 in
  `model.zig`, a load to $zero with its value in x28; only its target was
  compile-time. Now op 0 retires it from `load_r` at run time
  (`Model.retireEntry`: `ldrb`, the cancel against op 0's `writeReg`
  target as a `csel`, `strb delay_r`, an indexed store, the shadow under
  PGXP). Memory is exact at entry, so a call or a slow path at op 0 needed
  nothing. One code path serves `load_r == 0` too, at about five words per
  block, so there was nothing to compile lazily and nothing to choose at
  link time: every exit with a load in its delay slot now links, direct or
  through the inline lookup.
- Crash Warped 772.6 → 811.0 fps (+5.0%), Silent Hill 628.0 → 641.5
  (+2.1%), Spyro with PGXP 416.1 → 422.8 (+1.6%): `--engine=jit
  threaded`, best of three interleaved, the new build ahead in every pair.
- `lockstep`, `verify`, `savestate`, `snapshot` and `verify
  --threaded=deferred`, all `--engine=jit`: OK, `trace-block/` unchanged.
  `zig build test` OK, with new `jit_test` cases for op 0 reading,
  cancelling, branching, storing, loading, an LWL call, an ADD slow path, a
  one-op block (`delay_r` as op 0 left it), PGXP in both tiers, and a
  return that links with a load landing in the caller. Removing the
  run-time cancel fails both fuzzers as well.

### 2. DMA-stalled steps in batches: DONE

While DMA owns the bus each word is one `Cpu.step`, even under the JIT
(`run.zig`'s `isCpuStalled` path), and a stalled step always took
`tickSlow`: a full `advance`, `deadline`, and the seven-channel
`cpuWindowDeadline` loop.

- **Counted first, and the count changed the approach.** A word that
  touches a device port syncs the scheduler from inside `Bus.read`/`write`,
  so deferring the stalled step alone reaches only RAM-only words. Over
  3000 frames (`--engine=jit threaded`), stalled words by channel, and how
  many synced:

  | | Silent Hill | Croc | Crash Warped |
  |---|---|---|---|
  | MDECin (0) | 2.2M, all | 2.1M, all | - |
  | MDECout (1) | 14.6M, all | 10.0M, all | - |
  | GPU (2) | 15.5M, 14.8M | 12.6M, 12.0M | 6.7M, 3.8M |
  | CDROM (3) | 1.8M, all | 2.4M, all | 0.7M, all |
  | SPU (4) | 0.1M, all | 0.03M, all | 0.2M, all |
  | OTC (6) | 1.9M, none | 0.6M, none | 0.3M, none |

  The GPU's unsynced words are linked-list headers.
- **As built, two exact pieces.** (a) The MDEC's ports skip `sync`
  (`Bus.needsSync`): it holds no countdown, reads no other device and
  raises no interrupt. (b) `dma.step` returns `Word{ cycles, runs_on }`,
  and a stalled step defers (`scheduler.Step.dma`) while its channel runs
  on. A word that ends the transfer, arms a block gap, starts a chop CPU
  turn or drains channel 3's FIFO takes the slow path (`.dma_last`), as
  does any word whose device access synced. A stall's backlog is never
  mixed with the CPU's, and `pending_stalled` keeps it from draining the
  DMA CPU window. That makes ~54% of Silent Hill's stalled steps
  deferrable.
- GP0 data words (Silent Hill 14.8M) and the CD data port keep their
  sync: both `catchUp` and re-arm their own countdown. Handing the GPU
  its share of the backlog early would be exact inside a window (it
  produces no dotclock or hblank tick there), but needs per-device
  pending; not attempted.
- Silent Hill 660.8 → 694.9 fps (+5.2%), Croc 712.1 → 738.8 (+3.8%,
  noisier: one pair inverted), Crash Warped 825.5 → 825.5: `--engine=jit
  threaded`, best of three interleaved. Interpreter: Silent Hill 260.1 →
  262.7, Croc 245.5 → 249.2, within drift.
- `verify` on all three engines, `verify --threaded=deferred` (interpreter
  and JIT), `savestate` and `snapshot` (interpreter and JIT), `lockstep`
  on both block engines, JA 12/17 (the same five), PL at floors, `zig
  build test`: OK. `trace/` and `trace-block/` unchanged. New
  `scheduler_test` cases: an OTC beside the paced SPU transfer, a chopped
  OTC against a per-step machine, and an MDEC access that leaves the
  deadline standing. Letting stalled cycles drain the window fails the
  first; letting every word defer fails the second.

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

`trace-golden -- pgxp --engine=jit` fails (12 workloads diverged; the
perspective, color, depth and depth_clears totals below floor) with output
byte-identical before and after item 1. The floors were set on the
interpreter, and a block engine reaches other scenes by its sample
points. Gate PGXP work on the interpreter's `pgxp` until the block engine
has floors of its own.
