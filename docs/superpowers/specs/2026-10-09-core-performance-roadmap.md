# Core performance roadmap

Date: 2026-10-09, updated 2026-10-15. Status: roadmap; each item gets its
own spec or plan before work starts.

**State on 2026-10-15:** items 0, 1, 2 and 7 are DONE; 3 is half done
(MMIO settling; `trace-block/` recapture pending a ruling); 8 is partly
done (SIMD in the rasterizer and the wasm build). Open, in the order
below: 3's DMA-stall half, 4 (the cheap check only), 5, 6, 8's
interpreter half, and 9. The app-side
list gained the FF8 pass count and lost the fast-forward cap.

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
- **Interleaved A/B, best of three or more**, two binaries copied aside.
  Build the old one in a `git worktree` in the scratchpad, never by
  stashing the working tree; copy `ps1-debug/src/BIOS.BIN` into it (it is
  gitignored and `zig build` embeds it). Never compare against a remembered
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

### 3. Scheduler residue: MMIO HALF DONE

- **Counted first, and the count moved the target.** Slow paths by cause
  over 3000 frames (`--engine=jit threaded`; the interpreter within 3%):

  | | Silent Hill | Crash Warped | Croc |
  |---|---|---|---|
  | Slow paths per frame | 9,270 | 3,769 | 7,255 |
  | GP0 write (almost all DMA-stalled) | 53.4% | 34.3% | ~55% |
  | GPUSTAT read | 20.4% | 13.5% | 8.0% |
  | CD-ROM read (mostly the data port) | 6.7% | 6.5% | 6.1% |
  | SPU sample deadline | 7.3% | 18.7% | 9.4% |
  | Timer read | 4.1% | 10.2% | 1.8% |
  | I_STAT, I_MASK, DMA, SPU reads | 2.9% | 4.6% | 3.0% |
  | GPU deadline | 2.6% | 6.6% | 3.3% |
  | DMA CPU window, last DMA word | 0.2% | 0.2% | 10.6% |

  The reads this item named were 3-15%. GP0 writes and GPUSTAT reads were
  most of it.
- **As built (2026-10-15): `scheduler.settle`.** An access that can move
  no countdown but its own device's, which that device re-arms, derives
  the deadline right after the access instead of zeroing `downcount`, so
  the step defers. That covers GP0 writes (`Gpu.rearm` at the end of
  `writeGp0`; a changed interrupt flag stays due at once, because
  `stepEvents` raises the edge), GPUSTAT reads, timer reads (`Timer.read`
  re-arms) and SPU reads other than the transfer FIFO, whose pop can raise
  the IRQ. Reads of I_STAT, I_MASK and the DMA registers now skip the sync
  entirely, like the MDEC's: nothing deferred changes what they answer.
  GP1, the CD-ROM, SIO and every other write keep the zero.
- **A trap the gates caught: `settle` refuses after an overrun.** Under a
  block engine an access's sync can hand over a backlog that had already
  reached the deadline, which fires device events (an IRQ, a DMA request)
  that only the dispatcher acts on. Settling there let a linked JIT chain
  run on past them: `.jit` stopped matching `.cached`, and `snapshot
  --engine=jit` diverged at 30M on Crash 1. `Scheduler.overran` keeps the
  zero for that sync. The interpreter never overruns.
- Silent Hill 655.0 -> 737.6 fps (+12.6%), Crash Warped 783.1 -> 808.3
  (+3.2%), Croc 703.1 -> 749.2 (+6.6%): `--engine=jit threaded`, best of
  three interleaved, the new build ahead in all nine pairs (a WebKit
  process held ~90% of a core throughout). Interpreter: Silent Hill 221.0
  -> 220.6, Crash Warped 213.6 -> 210.8, within drift.
- Interpreter `verify`, `verify --threaded=deferred`, `savestate` and
  `snapshot`: OK, `trace/` unchanged. `lockstep` on both block engines:
  OK. JA 12/17 (the same five), PL at floors, `zig build test`: OK, with
  new `scheduler_test` cases: settled and unsynced accesses against a
  per-step machine whose devices are left zeroed as the old rule left
  them (dropping `Gpu.rearm`'s interrupt clause fails it), and a settle
  after an overrun (dropping the refusal fails it).
- **`trace-block/` moves on 8 of 9 workloads** (not `bios-only`), the same
  at every block-engine gate: `cdrom` alone at the first failing sample on
  Crash 1, Resident Evil, Croc and TR1 (157.5M-195M), the whole machine
  within the interval on the rest. It is item 0's mechanism: a block's
  backlog now reaches the devices in different chunks, and
  `CdRom.stepEvents` takes a chunk as one step's delta. Recapture awaits
  an owner ruling, as its own commit.
- **Still open:** GP0 words still pay a full `sync` (a hand-over to every
  device) each; per-device pending is what would remove that. Per stalled
  word, `isCpuStalled` and `dma.step` each walk `channelIsRunnable` (6.2%
  of Silent Hill's thread on 2026-10-15) and `cpuWindowDeadline` 3.7%:
  cache the window minimum when a channel's gap/chop state changes.
  `getDotclockDivider` on GP1(08h) is 0.5%, not worth it alone.

### 4. SPU voice mixing: SIMD RULED OUT, the cheap check still open

~14% of Crash Warped's thread in the table above. Each output sample walks
24 voices in scalar code: 4-tap Gaussian, ADSR, volume, per-voice bit tests
on NON/VON/PMON.

- **SIMD is ruled out (2026-10-14 SIMD pass).** That pass profiled the
  mixing at ~4% of Crash and branch-bound, and the reverb send saturates in
  voice order, so lanes cannot reproduce it exactly. Its ~4% and this
  table's ~14% were not taken with the same attribution. Re-profile before
  sizing this item.
- **Still open, the cheap check:** count voices that are `is_on` with a
  zero envelope and nothing to fetch. If they are common, skipping them is
  the whole win.
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

### 7. MDEC IDCT: DONE

`5eee91f`: a row of eight outputs per `@Vector` op, 5.3x per block (304 →
58 ns). Silent Hill +4.1%, Croc +1.3% (`--engine=jit threaded`). Bit-exact:
`verify`, MDEC unit tests.

### 8. Browser path: interpreter and software rasterizer: PARTLY DONE

- **Done (2026-10-14):** the triangle walk tests coverage eight pixels per
  vector compare and shades only the covered ones, scalar and in pixel
  order (`4743307`: Crash Warped +6.4% threaded, +5.7% inline; Silent Hill
  neutral). The integer formulas are unchanged, so Metal parity holds; this
  supersedes "SIMD spans are out of scope". The wasm build targets
  `simd128` (`88c7e96`: Crash Warped in Bun 4.09x → 4.36x).
- **Decide first** whether the browser runs the interpreter at all: the
  demo page already defaults to `.cached`. If it does not, what is left
  shrinks to the rasterizer.
- **Interpreter (open):** pre-decode handlers (what `.cached` does), check
  `isInstructionBusErrorAddress` only when the PC changes region, fold
  `isCpuStalled` into the slow path.
- **Rasterizer (open):** hoist the clip test and mask flags out of
  `putPixel` to span bounds; the per-pixel arithmetic is untouched.
- **Gates:** `verify` on all engines, `stream-verify`, PL floors, the
  Swift fixture gates (`ps1-macos/test.sh`) for anything in `gpu/`.

### 9. The per-frame raster sync (new, 2026-10-14)

The app's `publishShadow` calls `ps1_copy_vram` every frame, which waits
for the raster worker (`syncRaster`) and copies 1 MB, although the shadow is
read only by a resync, a 24-bit display, `PS1_SOFTWARE_DISPLAY` and
`PS1_LIVE_DIFF`.

- **Measured with a bench probe** (`--engine=jit threaded nocopy`, the
  per-frame `syncRaster` skipped; best of five, interleaved): Crash Warped
  864 → 1057 fps (+22%), Silent Hill 668 → 725 (+8.5%). **Total CPU time
  (user + sys) does not fall**: it is the same work, overlapped. This buys
  fast-forward and runahead headroom, NOT power. The copy alone is ~1%.
- **Shape:** publish a shadow only when the frame needs one (24-bit
  display, a debug switch) or the renderer has asked for one (a resync, the
  repair debt). It must keep the rule that VRAM is published before the
  stream, under the same seq: a resync adopts a shadow at `S` and discards
  only the slots at or below `S`.
- **Gates:** the Swift suite (`StreamQueue`, resync and repair tests),
  `PS1_LIVE_DIFF` at 1x, and FMVs in Croc and Silent Hill (24-bit).

## App-side, not core

Open:

- **FF8's field scenes run 240-540 Metal passes a frame with no uploads at
  all**, while the replayed `HazardTracker` gave ~10 breaks a frame on one
  field scene, so that scene is not the one and the cause is open. Likely
  the largest known GPU waste. Start from a `.p1fx` capture of a field
  scene (`ps1-gpu-metal`).
- Cold `MetalRasterizer.init` builds 28 pipelines on the main thread: ~1.15
  s after an install or OS update. Build async or pre-warm off-main.
- **The live app uses 35-60% of a core at 1x and has never been profiled
  per thread** with the JIT on. The bench puts the emulator thread at ~12%
  at 60 fps, and item 9 shows the per-frame sync is not the power cost. Do
  this before attributing any app CPU use to the core.

Done:

- Fast-forward cap at 1x: `StreamQueue` 3 → 5 slots (`10f8f6a`), Spyro
  180 → ~240 fps. Draining on frame arrival rather than once per draw
  callback was not done.
- The raster worker runs at utility QoS (`1e43e92`), so macOS can place it
  on an efficiency core.
- Metal's per-fragment 64-bit divide → corrected float estimate
  (`19738f8`): -30 to -45% GPU.

## Already measured as noise (do not re-propose)

From 2026-10-01 (`project-emulator-cpu-profile`): a RAM-first fast path in
`Bus.read`, branchless `readReg`, `@call(.always_inline)` of `Cpu.step`,
skipping the colour divides on flat textured pixels. Each within drift; all
four together ≤2%. A register cache in the JIT was measured at <1%.

From 2026-10-14:

- **The software rasterizer's per-pixel 64-bit divide in `interp`.** A
  per-triangle reciprocal (u128 high multiply, one remainder correction)
  is exact and fuzz-tested, and gained nothing: Crash Warped inline 562 →
  542 fps, Silent Hill 474 → 492, i.e. noise. The M1's 64-bit `sdiv` is
  cheap; it was the GPU that had none.
- **The raster worker's wakes.** One wake syscall per sleep (`d52a0b5`,
  kept) is neutral on fps, CPU time and context switches. Spinning again
  after every futex wake halves involuntary context switches but raises
  user CPU, so it was dropped.
- **SIMD on the SPU and the GTE** (the GTE is under 2%); see item 4.
- **Metal:** a triangle hull instead of the bounding box (Silent Hill 2-6%
  slower) and a bilinear filter that skips fetches (no gain); both in
  `ps1-gpu-metal`.

## Known nuisance

`test-roms-pl -Dengine=jit` fails intermittently under machine load, on the
baseline as well as with item 0; a rerun passes. Not a gate for this work
until it is understood. On 2026-10-14 the interpreter run failed once the
same way, inside a chain of gates, and the same binary then passed twice.

`zig build test -Doptimize=ReleaseFast` crashes (SEGV) in `pgxp_test`'s
"the cache is not allocated while the setting is off", at HEAD as well.
Run the unit tests in Debug, as `zig build test` does by default.

`trace-golden -- pgxp --engine=jit` fails (12 workloads diverged; the
perspective, color, depth and depth_clears totals below floor) with output
byte-identical before and after item 1. The floors were set on the
interpreter, and a block engine reaches other scenes by its sample
points. Gate PGXP work on the interpreter's `pgxp` until the block engine
has floors of its own.
