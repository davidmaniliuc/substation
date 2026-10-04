# CPU recompiler — design

## Goal

Add block-based execution engines beside the interpreter: a portable **cached
interpreter** and an **arm64 recompiler (JIT)** for the macOS app. The
interpreter stays as it is and stays the reference.

What the speed buys (all three are goals, none ranked above the others):

- **Fast-forward and headroom.** `SpeedSetting` caps base and turbo at 4x
  today; a faster engine lets that cap rise, and leaves room for features that
  re-execute frames (rewind, run-ahead).
- **Battery and heat.** The app's runner already sleeps between frames, so the
  same speed at less CPU idles the fanless M1 Air.
- **Headroom for expensive modes**: high internal resolution with every PGXP
  sub-setting on, on the slowest supported Mac.

A JIT speeds up instruction execution only. The software rasterizer (~15% of
the emulator thread under `.dual`), the SPU, the CD-ROM and GPU stepping do not
change. Stage 1 measures the interpreter's share with xctrace before any
speed-up is promised; no target number is set in this document.

## Decisions

| Question | Decision |
| --- | --- |
| Targets | arm64 macOS only. No x86 backend, no wasm JIT. |
| Web | Interpreter and cached interpreter only; cached is the web default. |
| Timing | **Block-granular**: interrupts and device events are seen between blocks. The interpreter stays per-instruction and bit-exact. |
| PGXP | The JIT emits calls to the same PGXP hooks the interpreter uses. |
| Approach | Staged: scheduler → block infrastructure + cached interpreter → arm64 JIT → optimisation only if a profile asks. |
| I-cache | Modelled by the interpreter only. Block engines charge a static fetch cost. |

## Non-goals

- Bit-exactness of the block engines against the interpreter. They have their
  own goldens (`goldens/trace-block/`).
- fastmem (a 4 GB reservation plus a SIGBUS handler), global register
  allocation, constant propagation, inlined MULT/DIV/GTE. Stage 4 candidates,
  each only on a profile's evidence.
- A wasm code generator.
- Any change to `ps1-trace`/`ps1-debug`: debugging tools, interpreter only.

## Findings that shape the design

- **SIO's /ACK timer counts `Cpu.step()` calls, not cycles** (`sio.zig`,
  `irq_timer -= 1` per call). The pad's 500 and the card's 150 are step
  counts, and a step is not always an instruction: a DMA-stalled step (one DMA
  word) and a step that takes an interrupt both tick SIO too. A block engine
  must tick SIO by the number of steps the interpreter would have made
  (instructions, plus DMA words, plus interrupt entries), or the card's 150
  ceiling breaks and every game reports the card unformatted (the 2026-08-31
  FF7 symptom).
- **A DMA-stalled step does not tick the DMA CPU window.** `step()` returns
  after `tickPeripherals(dma_cycles)` without calling `dma.tickCpuWindow`, so
  the block-gap and chop counters drain only on cycles the CPU spent running.
- **The interpreter never takes an interrupt on a branch target.** The check
  in `step()` runs before the pipeline rotates, so `is_delay_slot` still
  describes the instruction that just ran; when that was a delay slot, the
  instruction about to run is a branch target and the interrupt is refused.
  Most blocks start on a branch target, so a block engine cannot reuse that
  rule unchanged (see Block engines: timing).
- **PGXP load/store propagation does not depend on CPU mode.** `exec.zig`'s
  loads, stores, `lwc2`/`swc2` and `mtc2` call `shadowLoad`/`shadowStore`
  unconditionally; the bus gates them on the master `pgxp_enabled` alone.
  CPU mode gates only the ALU/shift/mult/move hooks.
- **Every DMA write to RAM goes through `bus.write32`** (`dma.zig`). Code
  invalidation therefore hooks one RAM-write path in `Bus.write`. The only
  writes that bypass it are `Cpu.loadExe`'s `@memcpy` and savestate load; both
  flush the whole block cache.
- **The macOS app builds with `ENABLE_HARDENED_RUNTIME = NO`**, so `MAP_JIT`
  and `pthread_jit_write_protect_np` work without an entitlement. Turning the
  hardened runtime on later (for notarization) requires
  `com.apple.security.cs.allow-jit`.
- GPU, timers and CD-ROM already defer their work behind an
  `event_countdown` and catch up exactly on MMIO access (`catchUp`). The SPU
  (768-cycle sample accumulator), SIO and the DMA block-gap and chop counters
  do not, and have no `catchUp` site: they are ticked every step today.
- `cpu.cycles` and `bus.sys_clock` are part of `ps1-golden`'s state hash
  (`state_hash.zig`) and of the `CPU `/`BUS ` savestate sections.

## Architecture

### Three engines, one machine

`Cpu` gets an `engine` field: `.interpreter`, `.cached`, `.jit`. All three
drive the same `Bus` and the same `Cpu` state (registers, COP0, GTE, pipeline,
load delay), so switching engines and saving state need no translation.

- `.interpreter` is today's `Cpu.step()`. `trace-golden`, the ROM suites,
  `ps1-trace` and `ps1-debug` default to it, and its goldens never move
  because of this project.
- `.cached` and `.jit` are **block engines**. They share discovery, the cache,
  invalidation, timing and the lockstep checker; they differ only in how a
  block executes.
- `.jit` exists only when the target is `aarch64-macos`: a `comptime` check in
  the core plus a `build.zig` option. Other targets, wasm included, never
  compile the arm64 code.

### Code layout

Each file stays under ~600 lines.

```
ps1-core/src/recompiler/
  block.zig        decode a run of guest instructions into a Block; owns the termination rules
  cache.zig        physical-PC -> Block lookup, per-4KB "has code" page bitmap, invalidate/flush
  run.zig          the dispatcher: lookup/compile, run, charge cycles, service events
  cached.zig       backend 1: pre-decoded handler array
  lockstep.zig     functional checker (block engine vs per-instruction exec from the same state)
  arm64/
    emit.zig       arm64 instruction encoder (pure, unit-tested)
    translate.zig  per-MIPS-op lowering
    memory.zig     MAP_JIT code buffer, W^X toggling, host icache invalidation
```

The scheduler (Stage 1) lives with the CPU in `cpu/`, because the interpreter
uses it too.

### Frontend contract

Frame loops (`ps1_run_frame`, wasm `stepFrame`, `ps1-bench`, `ps1-golden`)
call `cpu.run()` where they call `cpu.step()` today. Under the interpreter,
`run()` executes one instruction; under a block engine, one block. The loops'
`is_vblank` checks keep working because the vblank deadline ends a block.

## Stage 1: the scheduler

One countdown for the whole machine, used by all three engines.

- `Cpu.downcount`: CPU cycles until the earliest deadline among the GPU's
  `event_countdown` (converted back through 11/7, rounded up), each timer's
  `event_countdown`, CD-ROM's `event_countdown`, the SPU's `768 -
  cycle_accumulator`, SIO's `irq_timer`, and each DMA channel's
  `block_gap_counter` and (while it is the CPU's turn) `chop_counter`.
  A timer on the hblank clock needs no term of its own: the GPU's deadline
  already stops at every scanline.
- **SIO's term is a step count used as a cycle count.** That is a
  conservative bound, not a conversion: a step costs at least one cycle, so
  `irq_timer` steps never arrive before `irq_timer` cycles. A sync that comes
  early finds SIO not yet due and re-arms. Do not "convert" it.
- `tickPeripherals` gains a fast path: while `delta < downcount`, add `delta`
  to `pending`, add one to `pending_steps` and return. `cpu.cycles` and
  `bus.sys_clock` still advance on the fast path, so the state hash and a
  savestate see them current without a sync.
- **CPU-window cycles are kept apart.** A non-stalled step also adds its
  `delta` to `pending_cpu_window`; a DMA-stalled step does not, matching
  `step()`'s early return. `sync()` hands `pending_cpu_window`, not
  `pending`, to `dma.tickCpuWindow`.
- `sync()` hands `pending` to every device **in today's order** (SPU → GPU →
  SIO → Timer0/1/2 → CD-ROM → DMA window), then recomputes `downcount`. SIO
  takes `pending_steps` rather than cycles.
- **Sync before an MMIO access, and force one after it.** Before: `Bus`'s I/O
  dispatch calls `sync()` for every MMIO read and write, not only at the
  existing GPU/timer/CD-ROM `catchUp` sites, because SPU, SIO, DMA and
  I_STAT/I_MASK have no `catchUp` and today rely on being ticked every step.
  After: the access sets `downcount = 0`, so the step that made it ends in a
  `sync()`. An MMIO write can arm or move a deadline (a JOY_TX write arms
  `irq_timer`, a CD command changes what `updateInterrupts` raises, an SPU
  write can set `irq_flag`, a timer write re-arms the timer), and today's
  per-step `tickPeripherals` acts on that within the same step.
- **For the interpreter this must be exact.** Every device's own deferral is
  already exact; the scheduler only stops calling devices that have nothing
  due. This is also the "one global next-event countdown" the 2026-10-01
  profile named as the next win (~15% of the emulator thread is per-instruction
  guard and glue).
- Known limit: while timer 0 counts the dotclock the GPU is `eager`, its
  deadline is 1, and the fast path never fires. Stage 1 gains nothing for
  that game, and is still exact.

### As built (Plan 1, 2026-10-03)

The design above stands; these are the names and the differences Plans 2-7
must use.

- The state is `bus.sched` (`Scheduler`: `downcount`, `pending`,
  `pending_steps`, `gpu_clock_frac`), not a field of `Cpu`. MMIO dispatch has
  to call `sync` and `Bus` holds no `Cpu` pointer. The JIT addresses
  `&bus.sched.downcount`.
- There is no `pending_cpu_window`. A DMA-stalled step always takes the slow
  path, so every cycle in `pending` was spent by the CPU and `pending` is the
  CPU-window count.
- `sync` hands `pending` over and sets `downcount = 0`; it does not recompute
  it. The step in progress recomputes the downcount on its slow path, after
  the access has moved the deadlines. Read "recomputes" above in that sense.
- What Plan 2 must design for:
  - `tick(bus, delta, cpu_window)` counts exactly one step, so a block engine
    needs a `steps` argument for SIO.
  - A block that overruns its deadline hands the devices more than one
    deadline's worth in a single call. `timer.stepRaw` detects one target
    crossing and one overflow per call, and the CD-ROM's batch safety assumes
    nothing lands past a deadline.
  - Adding mid-block elapsed cycles to `pending` before an MMIO access would
    trip `flush`'s `pending < deadline` debug assert after an overrun.

### As built (Plan 2, 2026-10-03)

The block engine core is in `ps1-core/src/recompiler/` (`block.zig`,
`cache.zig`, `cached.zig`, `run.zig`). No frontend calls it yet; every one
still calls `cpu.step()` and the interpreter gates did not move.

- Names. `recompiler.Engine` (`interpreter`, `cached`, `jit`);
  `recompiler.setEngine(cpu, allocator, engine)` and `engineOf(bus)`;
  `recompiler.run(cpu, cache)` is the dispatcher and `Cpu.run()` is the frame
  loop's entry (a block under a block engine, one `step()` otherwise).
  `Bus.blocks` (`?*BlockCache`) and `Bus.block_exit` (set by a store that
  invalidates a block or touches a device, read by the executing block).
  `scheduler.charge(bus, cycles, steps)` defers a block's cycles and
  `scheduler.serviceDue(bus)` hands an overrun over at the block boundary;
  `Cpu.chargeCycles` is the CPU-side wrapper. `exec.handlerFor` is the one
  handler table behind `execute` and the blocks. `.jit` returns
  `error.EngineUnavailable` until Plan 4.
- Departures from the design above, each deliberate:
  1. The engine is the presence of `bus.blocks`, not a `Cpu` field: `Bus.write`
     must reach the cache to invalidate it and `Bus` holds no `Cpu`, and a
     fresh `Bus` (load state, reset) must not inherit a cache for RAM it
     replaced. Same pattern as `pgxp_vertex_cache`.
  2. A `Block` records no segment. The fetch cost is read at every block start
     from the actual PC, which also lets a BIOS wait-state write apply from the
     next block. Plan 4 adds `Block.segment` and the segment-mismatch
     recompile once the JIT embeds the cost.
  3. No PGXP mode in `Block` and no flush on a PGXP toggle: `.cached` calls the
     handlers, which read the flags at run time. Plan 6 adds both for the JIT.
  4. `.cached` commits elapsed cycles before every load and store, not only
     before a slow-path call. The difference is only when RAM and scratchpad
     accesses commit, and those never sync, so device timing at every sync
     point is identical.
  5. The accessing instruction's own step is committed after its access, as
     the interpreter ticks SIO for step k after step k's store. A JOY_TX store
     must arm /ACK before its own step counts against it (pad floor 500).
  6. An interrupt taken at a block start clears `is_delay_slot` first. A block
     that ended on a delay slot leaves it set, and `exception()` would put
     EPC on the branch with Cause.BD.
  7. The dispatcher keeps the I-cache invalidated with a dirty flag: any
     interpreter fallback step fills lines the blocks never snoop, so the
     dispatcher flushes once before the next block. `setEngine` and
     `savestate.load` do the same, so a state never captures or restores stale
     lines.
  8. The overrun handover lives in the scheduler (`flushOverrun`), reached only
     when `downcount <= 0`, which only a block engine produces. `flush` keeps
     the interpreter's single handover (and its `pending < deadline` assert)
     when `downcount > 0`, and `tickSlow` keeps its assert: every `run()`
     ends in `serviceDue`, which flushes whenever a block reached or passed
     the deadline or an MMIO sync zeroed it. Steps go with the earliest
     cycles, so SIO's /ACK can fire up to one block's steps early in cycle
     time, never late and never skipped.
- Changes from the plan made during the build:
  - `setEngine` returns early when the engine is unchanged. Frontends
    re-apply settings every frame, and an unconditional I-cache flush would
    move interpreter timing.
  - The dispatcher's DMA-stall branch does not sync. Nothing can be pending
    there: the MMIO store that started the DMA synced, which zeroed
    `downcount`, so the closing `serviceDue` of that `run()` could not return
    early and flushed;
    `Cpu.step()`'s own `pending == 0` assert is the check.
  - `savestate.load` flushes the block cache and marks the I-cache dirty.
  - The BIOS putchar hook runs just before the block executes, so it fires
    once per entry: not on an out-of-memory fallback to `step()` (which runs
    it itself), and not on an interrupt taken at the vector (the return
    fires it). A block that falls through into 0xA0/0xB0 misses it, which
    the kernel's layout makes unreachable.
  - A refused interrupt runs one `Cpu.step()`, not the block, so it is taken
    one instruction later; a loop whose head is a GTE command never took it.
- Plan 3 must switch the frame loops to `cpu.run()`. `ps1-golden` counts
  instructions in its sample schedule, so its loop needs a block-aware
  counter. It must carry the engine through `ps1-capi`'s `HostSettings` once
  Plan 7 exposes it: a fresh `Bus` comes up on the interpreter.
- Plan 4 must add `Block.segment` and the segment-mismatch recompile when the
  JIT embeds a fetch cost.
- Interpreter bench against the pre-plan commit (`ps1-bench-dual`, Croc, 3000
  frames, interleaved, best of five): plain 10.820 s before, 11.064 s after
  (2.3% slower, over the 2% line and left unfixed for the owner to rule on;
  the `exec.handlerFor` table alone measured +1.2% in Task 1); `pgxp` 12.987 s
  before, 12.638 s after (2.7% faster).

### As built (Plan 3, 2026-10-04)

Every frontend except `ps1-trace` and `ps1-debug` now runs on `Cpu.run()`, the
ROM suites and `ps1-golden` can select a block engine, and the cached
interpreter has a golden set, a per-block checker and a browser default. No
interpreter golden moved and nothing was recaptured on the interpreter side.

- Names:
  - `Cpu.run() u32` returns the number of `step()` calls it stood for: 1 under
    the interpreter and for every one-step dispatcher path (interrupt entry,
    DMA word, delay-slot or IsC fallback, a refused interrupt), and only the
    instructions that ran for a block that an MMIO store ended early.
    `recompiler.run` and `cached.execute` return the same count.
  - `ps1-golden/src/ticker.zig`: `Ticker.due` returns the sample boundary a
    count has passed, so one crossing mid-block is one sample labelled with
    the boundary. `script.Pad` replaces `maskAt`: a press fires once at the
    first count at or past its instruction, and its release at press plus
    hold, so an event inside a block neither skips nor repeats.
  - `--engine=` on every `ps1-golden` mode and on `ps1-bench`; `-Dengine` on
    `test-roms-pl` and `test-roms-ja` (`RomEngine`, `rom_test_helpers.engine()`).
    `--engine=jit` and `-Dengine=jit` are accepted by the parser and fail per
    workload with `EngineUnavailable` until Plan 4.
  - `setCpuEngine` in `ps1-wasm`; `index.html` calls it after `init()`, and the
    browser page defaults to `.cached`. `ps1-capi` has no engine setting.
  - `recompiler.lockstep`: `Checker` (`checked`, `skipped_io`, `mismatch`, the
    test seam `fault`, `execute`), `Arch` (`capture`/`restore`), `Journal`
    (RAM-store undo log) and `compareArch`. `BlockCache.lockstep` switches it
    on at run time and `BlockCache.journal` is the log. `Bus.io_accessed` is
    set on an MMIO access so a block that touched a device is counted as
    skipped, not compared. `trace-golden -- lockstep --engine=cached` drives it.
  - `ps1-core/tests/goldens/trace-block/`: nine goldens captured under
    `.cached`, the set `verify --engine=jit` will reuse unchanged.
- The five departures from the plan's header, as built:
  1. No `-Dlockstep` build option. The journal hangs off `BlockCache` and the
     checker is a run-time switch, so nothing compiles in or out and the
     lockstep tests run inside `zig build test`. The interpreter's only new
     cost is the `io_accessed` byte store on an MMIO path (it already syncs
     the scheduler); its RAM write path still takes the one `if (self.blocks)`
     branch it took before.
  2. Lockstep snapshots the 1 KB scratchpad rather than journalling it.
  3. The reference runs exactly as many instructions as the engine did, so it
     checks what each instruction computes, not where the block ends.
  4. A trace-block sample is labelled with its boundary (2,500,000) while the
     hashes are taken where the run actually is (say 2,500,031).
  5. The FF7 memory-card READ and SAVE checks both move to Plan 7: the read
     half was inconclusive too, so Plan 7 must not assume it was proven. No
     frontend that can write a card runs a block engine before then.
- Restore order. A savestate restored under a block engine must select the
  engine BEFORE `savestate.load`. Load restores the I-cache lines and marks
  them dirty as the saving machine holds them; the other order flushes them on
  one machine only. `saveAndRestore` does this and a core test pins it. Plan
  7's `ps1-capi` must keep the order when it carries the engine through
  `HostSettings`.
- Changes from the plan made during the build:
  - The lockstep journal records the store's aligned word, not the u32 at the
    store's own offset (a sub-word store at an odd offset recorded the wrong
    old value, and 0x1FFFFF read past the end of RAM).
  - Review found no test failed with the journal undo removed. A
    read-modify-write block test now pins it (it fails with the undo
    removed), and the self-rewrite test's comment was corrected: it proves the
    checker survives its running block being rewritten, not that the word is
    restored before a fetch.
  - `memory.zig` is 987 lines, up from 947. It was over the ~600 line limit
    already.
- Measurements (Croc, 3000 frames, `ps1-bench-dual`, ReleaseFast, interleaved,
  best of five; the baseline is `d63f998`, the HEAD before this plan, whose
  tree is docs-only different from `a1ae280`):
  - Interpreter against the pre-plan binary, as first measured: 11.090 s
    before, 12.992 s after (+17.1%); the first set read 11.203 s against
    13.396 s (+19.6%). The pgxp pair read 12.758 s before, 14.403 s after (+12.9%,
    one run each). A bisect (best of five, Croc 3000 frames: `d63f998` 11.075,
    `248ff50` 12.621, `39266f5` 12.781, `84fe405` 13.099, `380875d` 13.142 s)
    put the jump (+14.0%) on `248ff50`, the commit that made the frame loops
    call `Cpu.run()` instead of `Cpu.step()`. Mechanism, from the disassembly:
    `recompiler.run` was inlined into `Cpu.run`, so `Cpu.run` built a 0x1b0
    byte frame and saved six register pairs before it tested `bus.blocks`; the
    interpreter path restored them all and tail-called `step`. A branch hint
    did not help; a bench loop calling `step` directly was back at baseline.
    The fix, `d2931f2`, calls the dispatcher with `@call(.never_inline, ...)`,
    so `Cpu.run` is a small trampoline that inlines into the frame loops
    (they `bl Cpu.step` directly again; `recompiler.run` is out of line).
    After the fix, interleaved best of five: 11.040 s at `d63f998`, 12.390 s
    at the fix (+12.2%, from +18.7% at HEAD). The fix recovered about a third
    of the loss and did NOT bring the interpreter within 3%, so the rest is
    unexplained and was not chased: the owner rules on it. The `84fe405`
    share (+2.6%, borderline, the lockstep RAM-write branch) was not
    re-measured separately.
  - `.cached` against the interpreter at HEAD, same interleaved set: 8.707 s
    against 13.396 s best of five (1.54x faster, 5.75x against 3.74x
    realtime). With `pgxp` one run each: 10.953 s against 15.211 s (1.39x).
    These are the first measured speeds of the cached interpreter. Against
    the pre-plan interpreter (11.090 s) `.cached` is 1.27x, not 1.5x.
    After `d2931f2`, `.cached` reads 8.629 s best of three (5.80x realtime).
- Gates, all `-Doptimize=ReleaseFast`: `zig build test` 47/47 steps; `verify`,
  `savestate`, `stream-verify` and `pgxp` on the interpreter green with no
  recapture; `capi-lib` and `metallib` build; the Swift suite passes with 530
  tests in 5 suites (CLAUDE.md said 484; no Plan 3 task touched Swift, so the
  documented count was stale). `verify --engine=cached` and `savestate
  --engine=cached` were last run in Task 6 straight after the capture (OK on
  all nine workloads); nothing in core or the harnesses changed afterwards
  (Task 6 added goldens and a doc), so those results were reused.
  `stream-verify --engine=cached` is OK on all nine.
- `lockstep --engine=cached`: 0 mismatches on all nine workloads. Blocks
  checked 81.7M (crash-europe) to 109.7M (croc), skipped for MMIO 2.1M (tr1)
  to 4.9M (crash-europe); about 11 minutes in all.
- ROM suites under `.cached`: JA 12/17 with the same five failing as on the
  interpreter (Getloc, Timing, MDEC 4bit, MDEC 8bit, MDEC Step By Step Log),
  PL passing with all six exactly at their floors. No test differs, so there
  is no timing or functional difference to classify. The results are
  byte-identical to the interpreter's, which is plausible but was not
  independently shown to exercise the block engine beyond `setEngine`
  returning without error.
- Per-game smoke. Owner browser play-test under `.cached`: Croc, Crash,
  Spyro, Silent Hill and Tekken 3 all played fine. Headless, all five draw on
  both engines (Crash Europe's zero-draw last 100 frames is a phase
  artifact: a 900M-instruction rerun draws like the interpreter).
- Open items for the owner to rule on. None was fixed, and no floor was
  lowered:
  1. `pgxp --engine=cached` misses the floors on 8 of 9 workloads (47
     floor/ceiling lines; only bios-only passes). Most are absolute volumes
     (perspective, colour, depth, `depth_clears` below floor; `clamped` over
     ceiling on crash-europe and croc). Every rate matches the interpreter to
     within about 0.5 point, except that tr1's shadow-resolved rate is 0.03
     point under its 99.0% floor (98.97% against the interpreter's 99.03%).
     The interpreter passes all of them in the same tree. The likely reading
     is that the block engine reaches different scenes in the same
     instruction budget (Silent Hill draws 742k GP0 vertices against 970k),
     but that is an inference, not a measurement. Per-engine or rate-based
     floors are the owner's ruling.
  2. The FF7 card check was inconclusive on both engines. Neither reaches
     field frames with the recipe and both end on the same 265-record
     screen, so there is no engine difference but no proof that a save
     loaded.
  3. Tekken 3 ran on its data track only, because `ps1-golden --cue` cannot
     load a multi-FILE cue.
  4. The interpreter bench regression above: bisected to `248ff50` and
     partly fixed by `d2931f2` (+18.7% down to +12.2%); the remainder is open
     and the owner's call.
- What Plan 4 inherits: `Checker.execute` calls `cached.execute` directly, so
  Plan 4 dispatches on the engine there. Under a JIT the reference can stray
  (`fetchWord` unwraps `regionOf(phys).?`, and a diverged reference could
  perform an MMIO access the engine never made before the mismatch is
  reported), so revisit both. `Journal.record` now panics past its capacity
  (`max_len + 1` entries); a JIT whose blocks can store more often must size it
  rather than rely on that guard. `verify --engine=jit` compares against
  `trace-block/` unchanged. The FF7 read and save checks move to Plan 7, which also
  carries the engine through `HostSettings`.

### As built (Plan 4, 2026-10-04)

`.jit` is a third CPU engine on `aarch64-macos`. Its emitted code is a
straight-line sequence of calls into `cached.runOp`, one per op, so every
instruction still reaches its `exec.zig` handler and nothing is lowered yet.
`.jit` equals `.cached` on every gate. No interpreter golden moved, no
`trace-block/` golden was recaptured, and no savestate section changed.

- Names:
  - `jit.available`: a comptime check on the target (`aarch64` and `macos`).
    Everything that maps or calls emitted code sits behind
    `if (comptime jit.available)`, so wasm never analyses it and `.jit` there
    is `EngineUnavailable`.
  - `jit.CodeBuffer` (`init`, `install`, `reset`): the MAP_JIT region, with a
    per-thread write window that opens and closes inside `install`, which
    refuses before opening it, so no path leaves it open. `install` returns
    `CodeBufferFull` and earlier code keeps running.
  - `jit.translate.compile`: a block's ops to host code. `jit.execute` runs it.
  - `block.JitEntry`, `Block.code` and `BlockCache.code`: the entry point of a
    block's host code, the field that holds it, and the cache's buffer. A full
    buffer flushes the cache and compilation continues.
  - `run.executeBlock`: the dispatcher's per-engine call, shared by `.cached`
    and `.jit`.
  - `cached.begin`/`commit`/`runOp`: the three inline pieces `cached.execute`'s
    loop body was split into. The JIT shares them, so the two engines cannot
    drift apart.
  - `ps1-core/tests/jit_test.zig` (encoder words, code buffer, engine switching,
    the self-modifying scenario) and `recompiler_helpers.zig`; the differential
    fuzzer runs `.jit` against `.cached`.
- The six deliberate departures from the plan's header, as built:
  1. No `Block.segment` and no segment-mismatch recompile. The dispatcher
     passes the fetch cost to the emitted function as its second argument, as
     it passes it to `cached.execute`, so the same block entered through KSEG0
     and KSEG1 is charged correctly and a BIOS wait-state write applies from
     the next block.
  2. No `-Djit` build option. `jit.available` is the only switch, and
     `setEngine` already leaves the choice to the frontend.
  3. The encoder is pinned against `clang -c` + `objdump -d`, not `llvm-mc`
     (Xcode ships none). Every expected word in `jit_test.zig` carries the
     assembly line that produced it.
  4. The code-buffer file is `arm64/code_buffer.zig`, not `arm64/memory.zig`,
     which would collide with the core's `memory.zig` (the `Bus`).
  5. The pinned registers are not x20-x22 yet. The skeleton uses x19 (`*Cpu`)
     and x23-x26 for its own accounting.
  6. `PS1_JIT_DUMP` and the per-op lower/call mask did not arrive: with every
     op a call there is nothing to bisect.
- Changes from the plan made during the build: nothing in the design. Review
  added a fix round to the fuzzer: it now also asserts that the JIT really
  emitted code, and its five coverage flags are separate expects rather than
  one. The generator's instruction mix was left alone (frequent SYSCALL/BREAK
  and unaligned faults end programs early), which is an item for Plan 5.
- Measurements (Croc, 3000 frames, `ps1-bench-dual`, ReleaseFast, interleaved,
  best of five):
  - `.cached` before and after the `begin`/`commit`/`runOp` split: 8.502 s
    (352.9 fps) at `ecf29e0`, 8.390 s (357.6 fps) after, 1.3% faster. No
    inlining fix was needed.
  - `.jit` against `.cached`, same set: `.cached` 8.416 s (356.5 fps, 5.95x
    realtime), `.jit` 9.375 s (320.0 fps, 5.34x), so the skeleton is 11.4%
    slower than the cached interpreter. All ten runs: `.cached` 8.478, 8.421,
    8.417, 8.423, 8.416 s; `.jit` 9.425, 9.405, 9.375, 9.433, 9.786 s. This is
    the cost of two indirect calls per op against a handler-array loop;
    nothing is inlined yet, and that is Plan 5's work.
- Gates, all `-Doptimize=ReleaseFast`: `zig build test` 49/49 steps, `zig
  build` (wasm included) and `capi-lib` build. On the interpreter `verify`,
  `savestate`, `stream-verify` and `pgxp` are green with no recapture.
  Under `.jit`, `verify` and `savestate` are OK on all nine workloads against
  `trace-block/`, and `stream-verify` is OK on all nine.
- `lockstep --engine=jit`: 0 mismatches on all nine workloads. Blocks checked
  81.7M (crash-europe, 81,654,585) to 109.7M (croc, 109,651,987), skipped for
  MMIO 2.1M (tr1, 2,145,192) to 4.9M (crash-europe, 4,893,933). That is the
  same range Plan 3 recorded for `.cached`, as expected from two engines that
  compile the same blocks.
- `pgxp --engine=jit` against `--engine=cached`: the two outputs differ in one
  line, the `failed command:` line that names the engine. Both miss the same 46
  floor/ceiling lines by the same amounts, so Plan 3's open item stands and
  was not ruled on here. No floor was lowered.
- ROM suites under `.jit`: JA 12/17 with the same five failing as under
  `.cached` (Getloc, Timing, MDEC 4bit, MDEC 8bit, MDEC Step By Step Log), PL
  passing with all six exactly at their floors.
- The fuzzer ran 1000 programs per run, the count the plan set; Task 5 did not
  lower it. It takes about 6 s in Debug, and a sabotage (per-instruction cost
  +2) failed it at seed 0, run 0 on a cycles mismatch.
- What Plan 5 inherits:
  - `Block.segment` arrives with the first code that bakes the fetch cost in
    as an immediate, the block-entry `subs x21, x21, #static_cost`.
  - Lockstep must run with linking off, and must revisit the reference
    straying into MMIO once inline code can diverge. The journal's `max_len + 1`
    capacity holds only while a block stores at most once per instruction.
  - The x20-x22 pinning (RAM base, downcount, page bitmap) starts there, and
    x23-x26 are free to be reassigned.
  - `PS1_JIT_DUMP` and the lower/call mask arrive with the first lowering.
  - The fuzzer is the per-family gate. Its generator should be retuned for
    depth per op family, since frequent SYSCALL/BREAK and unaligned faults end
    programs early.

### As built (Plan 5, 2026-10-04)

`.jit` now emits arm64 for ALU and shift ops, branches and jumps, and loads
and stores to the first 2 MB of RAM and the scratchpad. It links blocks
through direct branches and looks up the target of a jump through a register
inline. Every other op is still a call to its `exec.zig` handler, and every
inline op leaves through that handler on its slow path. On Croc `.jit` runs
1.94x as fast as `.cached` (4.598 s against 8.925 s for 3000 frames) and
equals it on every gate. No interpreter golden moved, no `trace-block/`
golden was recaptured, and no savestate section changed.

- Names:
  - `emitter.Emitter`: a block's code while it is built, in two sections:
    hot (the straight path) and cold (slow paths and the stop tail). A branch
    names a label or an absolute address and is encoded once both sizes are
    known. `layout`: the `Cpu` and `Pins` byte offsets emitted code
    addresses, with comptime checks that each fits its unsigned-offset form.
  - `model.Model`: the pipeline and the load delay at compile time. An inline
    op moves the model on and `sync` writes `Cpu.pipeline` and
    `Cpu.load_delay` only before something can read them (a call, a slow
    path, the block's end). A load's value waits in x27 or x28 by the parity
    of the op that issued it.
  - `lower_alu`, `lower_branch`, `lower_memory`: one file per family. `link`:
    the exits, the relink stub, `link_entry` and the inline `lookup` for
    JR/JALR.
  - `jit.Jit` (code buffer, emitter, return and relink stubs, `links`);
    `jit.Lowering`, the per-family mask (`alu`, `branch`, `load`, `store`,
    `link`), with `parse` taking `all`, `none` or a list; `jit.Hook`, called
    with each installed block for a dump.
  - `cache.Pins`: what emitted code reads through x22: the page bitmap
    (first, so a store indexes it from x22 itself), the RAM and scratchpad
    bases, the running block, `downcount`'s address, the RAM table, the
    pending link site and pc, and the call's `budget`.
  - `BlockCache.discard` drops one block as invalidation would, for a block
    entered through another segment than it was compiled for;
    `BlockCache.segment_recompiles` counts those.
  - `Block.code_words` (the code's length, for a dump) and
    `Block.link_entry` (where a linked exit jumps in; dropping the block
    rewrites its first word to send that jump back to the dispatcher).
  - `run.compileBlock` (lowers nothing under PGXP, stores as calls under
    lockstep), `run.setLowering` and `run.setJitDump` (harness seams, both
    no-ops off `.jit`).
  - `Cpu.runFor(budget)`: `run()` is `runFor(1)`. Under `.jit` it chains
    linked blocks and stops at the first block end at or past `budget` steps,
    or when a device is due.
  - `Bus.ram_access_wait`: the 4 wait states the first 2 MB of RAM costs, now
    one constant that `Bus.waitCycles` and the inline path both bill.
  - `lockstep`'s `"io"` mismatch (the reference touched a device the engine
    did not) and its `stray` test seam, which sends the reference elsewhere
    to prove that report.
  - `script.Pad.next`: the first count at which the pad script can act, so
    `ps1-golden`'s `runWorkload` passes it to `runFor` as a budget.
- The ten deliberate departures from the plan's header, as built:
  1. Guest registers stay in `Cpu.regs`: every inline op loads its sources
     and stores its result there. No register cache.
  2. x21 is the scratchpad base. `downcount` stays in `Bus.sched`, read
     through `Pins.downcount` only at a linked block's entry.
  3. A linked block starts when `downcount > 0` and fewer steps than the
     budget have run: the dispatcher's own check, not a static-cost
     subtraction.
  4. No `Block.segment`. The fetch cost stays a runtime argument (w23). A
     block found under another `start_pc` than the one it was entered
     through is dropped and compiled again (`run.blockAt`).
  5. `--jit-lower=` and `--jit-dump=` are harness flags on `ps1-golden` (and
     `--jit-lower=` on `ps1-bench`), per family, not environment variables
     or a per-opcode mask.
  6. The JR/JALR lookup is inline at each exit, not a shared stub.
  7. `Cpu.runFor(budget)` is new, and `ps1-golden` passes its next sample or
     pad event as the budget.
  8. `Bus.setPgxp` flushes the block cache on every toggle, from this plan
     on.
  9. Stay calls: LWL, LWR, SWL, SWR, LWC2, SWC2, MULT/DIV, HI/LO moves, every
     COP0 and COP2 op, SYSCALL, BREAK, reserved opcodes, and a branch in
     another branch's delay slot.
  10. RAM mirrors (2-8 MB) take the slow path, which bills their own wait
      states.
- Changes from the plan made during the build:
  - Task 3: on the PGXP off-to-on edge the dispatcher clears `gpr_shadow`,
    `load_shadow` and `delay_shadow` before the next block, under both block
    engines (`BlockCache.pgxp_seen`). Inline ALU code bypasses `writeReg`, so
    shadows from an earlier PGXP period otherwise survived an off period
    under `.jit` only. The interpreter is untouched.
  - Task 6: a slow path in a delay slot advanced the pipeline twice (`verify`
    failed on croc and tr1). The fix copies `pc` back into `next_pc` after
    the call.
  - Task 7: the fuzzer now also addresses a RAM mirror ($k0) and the
    scratchpad ($k1), so slow paths that return are fuzzed.
  - Task 8: `link.entry`'s conditional exits go through a local `b` to the
    return stub, because a conditional branch reaches only 1 MB of the
    32 MB buffer. A block whose last op is a branch never links out, since
    linking would skip the dispatcher's delay-slot step. Any block holding a
    COP0 op never links out, which keeps Task 7's IsC safety for inline
    stores.
  - Task 9: `lookup`'s conditional refusals go through the same kind of
    local label. Its refusal test's target returns with `jalr t3, ra`, so a
    lookup that skipped the `start_pc` compare would be caught.
- Measurements (Croc, 3000 frames, `ps1-bench-dual`, ReleaseFast, best of
  five):
  - Each task's pair, `.cached` then `.jit`: Task 2 (the new frame, nothing
    lowered) 8.419 / 9.363 s; Task 3 (ALU) 8.478 / 7.559 s; Task 5
    (branches) 8.514 / 7.066 s; Task 6 (loads) 8.620 / 5.706 s; Task 7
    (stores) 8.615 / 5.487 s; Task 8 (linking) 9.154 / 4.761 s; Task 9
    (inline lookup) 9.029 / 4.647 s, linking off 5.563 s. Tasks 1 and 4
    were not benched.
  - Task 10, five rounds interleaved:

    | Engine                      | Best (s) | fps   | Realtime |
    | --------------------------- | -------- | ----- | -------- |
    | interpreter                 | 12.393   | 242.1 | 4.04x    |
    | `.cached`                   | 8.925    | 336.1 | 5.61x    |
    | `.jit`                      | 4.598    | 652.5 | 10.89x   |
    | `.jit --jit-lower=none`     | 9.447    | 317.6 | 5.30x    |
    | `.jit` with PGXP on         | 11.347   | 264.4 | 4.41x    |

    `.jit` is 1.94x `.cached` and 2.70x the interpreter. With nothing lowered
    it is 5.8% slower than `.cached`, against 11.4% for Plan 4's skeleton.
    With PGXP on it lowers nothing and pays the PGXP hooks too. On Croc,
    `segment_recompiles` is 0 and `links` is 62,494.
  - `.cached` slowed by 4.0% in Task 8. Five interleaved rounds: ced52ea
    (Task 7) best 8.573 s, 557512e (Task 8) 8.918 s, HEAD 8.924 s. The spread
    within each build is under 0.3%. Task 8 changed `.cached`'s path only by
    a `relink` check per block and a `budget` store, so the cost is probably
    code layout or inlining rather than the work itself. That was not
    looked into further.
  - Profile (xctrace Time Profiler, attached to the bench, leaf frames;
    each bucket is the share of all samples, summed from raw counts: 6,891
    samples under `.cached`, 2,498 under `.jit`). Every sample lands in one
    row, so each column sums to 100% within rounding:

    | Bucket                                        | `.cached` | `.jit` |
    | --------------------------------------------- | --------- | ------ |
    | emitted code (no symbol, no binary)           | 0.0%      | 17.5%  |
    | `recompiler.*` (dispatcher, shims)            | 27.2%     | 9.7%   |
    | `cpu.exec.*` handlers                         | 11.0%     | 0.7%   |
    | `cpu.cpu.*` (step, pipeline, regs)            | 13.7%     | 2.0%   |
    | `memory.Bus.*`                                | 14.0%     | 9.8%   |
    | `cop0.*`, `cop2.*`, `alu.*`                   | 0.9%      | 0.5%   |
    | JIT compiling (`sys_icache_invalidate`, W^X)  | 0.0%      | 0.6%   |
    | **CPU side**                                  | **66.9%** | **40.8%** |
    | `scheduler.*`                                 | 8.4%      | 8.7%   |
    | `gpu.*`                                       | 11.7%     | 28.6%  |
    | `dma.*`                                       | 5.4%      | 7.9%   |
    | `mdec.*`                                      | 2.7%      | 3.7%   |
    | `cdrom.*`                                     | 1.7%      | 3.7%   |
    | `spu.*`                                       | 0.6%      | 1.4%   |
    | `timer.*`, `sio.*`                            | 0.4%      | 0.5%   |
    | **Devices**                                   | **30.9%** | **54.6%** |
    | `_platform_memmove`                           | 1.0%      | 1.9%   |
    | unattributed (`math`/`bits`/`mem` helpers, `main`, allocator, no backtrace) | 1.2% | 2.7% |
    | **Neither**                                   | **2.2%**  | **4.6%** |

    The CPU side is 66.9% of `.cached`'s time and 40.8% of `.jit`'s. The
    40.8% is the ceiling any further JIT work can win. The 54.6% that is
    devices, the GPU above all, it cannot win, and the 4.6% that is neither
    is unattributed: `memmove` serves both the bench's per-frame VRAM copy
    and the devices, and the small helpers are inlined from either side.
    Under `.jit` the top three CPU-side leaves are `memory.Bus.read`
    (4.4%), `translate.commitShim` (3.5%) and `memory.Bus.write` (3.2%),
    ahead of `run.run` (2.5%). Emitted code is 17.5% in all, the largest
    CPU-side bucket, but it is spread over 285 addresses and none is above
    0.3%. An earlier draft of this table read emitted code from per-leaf
    lines printed to 0.1%, where each single-sample address rounds to 0.0%,
    and so put it at 10.4%.
- Gates, all `-Doptimize=ReleaseFast`: `zig build` (wasm included),
  `zig build test` (49/49 steps) and `capi-lib` build. On the interpreter,
  `verify`, `savestate`, `stream-verify` and `pgxp` are green with no
  recapture, and `verify --engine=cached` is OK on all nine. Under `.jit`,
  with every family lowered and linking on, `verify`, `savestate` and
  `stream-verify` are OK on all nine workloads against `trace-block/`.
  - `lockstep --engine=jit`: 0 mismatches on all nine. Blocks checked:
    81.7M (crash-europe, 81,654,585) to 109.7M (croc, 109,651,987).
    Skipped for MMIO: 2.1M (tr1, 2,145,192) to 4.9M (crash-europe,
    4,893,933). Identical to Plan 4's counts. **Lockstep runs every block at
    budget 1 and compiles stores as calls**, so it never exercises linking,
    the inline JR/JALR lookup or an inline store. Those are gated by
    `verify`, `savestate`, the directed tests in `jit_test.zig` and the two
    fuzzers only.
  - `pgxp --engine=jit` and `--engine=cached`: byte-identical outputs when
    `ps1-golden` is run directly. Both exit 1 with the same 42 `BELOW FLOOR`
    lines, so Plan 3's open item stands and no floor was lowered. Plan 4
    recorded 46 lines; this count was taken with `grep -c 'BELOW FLOOR'`,
    and the two were not reconciled.
  - ROM suites under `.jit`: JA 12/17, the same five failing as under
    `.cached` (Getloc, Timing, MDEC 4bit, MDEC 8bit, MDEC Step By Step Log).
    PL passes, with all six exactly at their floors.
  - The fuzzers: "fuzz: .jit equals .cached on random programs" and "fuzz:
    linked .jit equals .cached, each program run twice", 1000 programs each
    (48 words, 24 runs per program; the linked one runs each program in two
    passes). The generator retuned in Task 2 reached a mean depth of 35
    words of 48 (the bar is 24), and the test asserts `mean >= len/2`.
    Neither fuzzer generates JR/JALR, so the inline lookup is covered by the
    two directed tests only.
- What Plan 6 inherits:
  - Inline loads and stores must call `shadowLoad`/`shadowStore` (and the
    half-word and byte variants) where the handlers do. Every register an op
    writes inline must have its `gpr_shadow` cleared.
  - CPU mode needs its hooks at every ALU, shift and move.
  - Until both arrive, `run.compileBlock` lowers nothing under PGXP. Plan 6
    relaxes that, and the PGXP-on bench row above is the number it starts
    from.
  - The register cache (departure 1) is not the obvious next step, and
    nothing here proves it is worth building. All emitted code together is
    17.5% of `.jit`'s time, the largest CPU-side bucket. A register cache
    would remove only part of that: the `cpu.regs` loads and stores around
    each op, and how large that part is has not been measured. A
    `--jit-dump` of the hot blocks would show it. Other CPU-side targets
    are cheaper and cost about as much time: the commit at each block end
    (`commitShim` at 3.5%, with the scheduler work under it) and the
    `Bus.read`/`Bus.write` slow paths (7.6%). The GPU (28.6%) is now the
    largest single cost, and no JIT work reaches it.

## Block engines: timing

- **Cycles stay honest.** Each instruction is charged what the interpreter
  charges, 1 plus load/store wait states, with the instruction fetch replaced
  by the block's static fetch cost: the cached-hit cost for RAM code run
  through KUSEG/KSEG0, the uncached per-word cost for KSEG1 and the BIOS. I-cache
  miss bursts are not modelled. The `icache` array stays in savestates; the
  block engines leave it invalidated.
- **A block starts only when `downcount > 0`**, and may overrun the deadline
  by at most its own length.
- **Interrupts are checked between blocks only, under the block engines' own
  rule**, which deliberately differs from the interpreter's. The interpreter
  refuses an interrupt on a branch target (see Findings); applied at block
  starts, which are mostly branch targets, that rule would refuse almost
  every interrupt, and a one-block VSync wait loop would never take its
  interrupt. At a block start the dispatcher takes a pending, enabled
  interrupt unless:
  - **the next instruction is a delay slot** (`next_is_delay_slot`).
    Termination never ends a block between a branch and its delay slot, but
    the machine can still arrive there from outside a block: a savestate
    taken under the interpreter (`trace-golden -- savestate` saves at an
    arbitrary instruction), an engine switch, or a single `Cpu.step()` from
    the IsC or non-RAM fallback. The dispatcher then runs one `Cpu.step()`
    for the delay slot instead of a block, because the instruction after it
    is `next_pc`, not the next word;
  - **the next instruction is a GTE command.** The dispatcher reads the block's
    first word and applies `(w >> 24) & 0xFE == 0x4A`. A block CAN start on
    one: a branch target, the length cap, a page edge or a store exit can all
    land just before a `cop2` command. Taking the interrupt there makes the
    BIOS handler skip the command (the Silent Hill green-surfaces bug).

  The "previous instruction was a delay slot" clause is dropped. Taking the
  interrupt sets `current_pc` to the block's start PC before
  `exception(.Interrupt)`, as `step()` does.
- **A refused interrupt is taken one instruction later.** When an interrupt
  is pending and enabled but refused at a block start (the GTE command), the
  dispatcher runs that one instruction with `Cpu.step()`, not the block, so
  the next block start, one instruction later, takes it. Running the whole
  block would never take it in a loop whose head is a GTE command: every
  start would refuse it again. The dispatcher also sets `downcount = 0`, so
  `.jit`'s block linking cannot defer the interrupt until the next
  deadline.
- **SIO is ticked by steps, not instructions:** instructions run, plus DMA
  words, plus interrupt entries, matching the step count the interpreter
  would have made.
- **DMA:** if `isCpuStalled` when a block would start, the dispatcher runs DMA
  words until the stall clears, as `step()` does: each word is one step for
  SIO and adds nothing to `pending_cpu_window`. A store that starts a DMA ends
  the block after the store.
- **MMIO inside a block sees the block's elapsed cycles.** Before a slow-path
  bus call, the block adds the cycles it has spent so far (fetch cost plus
  wait states, up to and including the accessing instruction's fetch) to
  `pending`, and the block-end charge subtracts them, so a device read
  mid-block is not behind by up to 64 instructions. `.cached` and `.jit`
  compute this identically, because `trace-block/` is shared between them.
- **Exceptions inside a block** (address error, overflow, bus error, syscall,
  break) write the exact `current_pc`, EPC and delay-slot bit, charge the
  cycles spent so far and leave the block. Exceptions stay precise even though
  interrupts are approximate. `enterException` sets a new transient
  `Cpu.exception_taken` flag that the block engines read.
- **The load delay crosses blocks** in the existing `cpu.load_delay` fields.

## Blocks, the cache and invalidation

### Termination: one rule set, shared

`block.zig` alone decides where a block ends. Both block engines execute the
same boundaries, which is what makes `.jit` bit-exact against `.cached`. A block
ends at:

- a branch or jump plus its delay slot;
- the length cap (64 instructions);
- a 4 KB page edge;
- an instruction that changes interrupt or memory state: `mtc0` (any COP0
  register), `rfe`, `syscall`, `break`;
- after a store whose address is not RAM or scratchpad (an MMIO store may
  raise an interrupt, start a DMA or touch I_STAT/I_MASK). This is decided at
  run time: `Bus` sets a `block_exit` flag on such a store, and on a store
  that invalidates the running block, and both block engines stop after the
  instruction that set it.

**A branch is never separated from its delay slot** by the length cap or a
page edge: the cap stretches by one instruction to take the delay slot. A
branch in the last word of a page takes its delay slot from the next page, and
that block is registered in both pages' block lists, so a write to either
invalidates it. A store exit that lands on a branch's delay slot is the
block's natural end anyway.

### Where blocks live

- **RAM** (2 MB; the four mirrors fold onto one) and **the BIOS** (512 KB,
  read-only, never invalidated).
- Any other PC (scratchpad, I/O, expansion) runs one `Cpu.step()`. The
  interpreter already raises the correct instruction-fetch bus error there.
- The putchar TTY hook fires on PC 0xA0/0xB0, which is only reached by a jump
  and so is always a block start: the dispatcher runs the hook before the
  block. Because the hook lives in the dispatcher, **a block at physical
  0xA0 or 0xB0 is never a link target**: `.jit` always reaches it through
  the dispatcher.

### Lookup

One flat table per region, indexed by word: 512K entries for RAM, 128K for the
BIOS, each `?*Block` (4 MB native, 2 MB on wasm32). A `Block` records its
segment (cached KUSEG/KSEG0 or uncached KSEG1); a lookup whose segment
disagrees recompiles. This is rare and keeps one table per region.

A `Block` holds: start PC, segment, instruction words, static cycle cost,
flags (has load/store/GTE/`mtc0`), the PGXP mode it was compiled under, and
the backend entry (handler array or code pointer).

### Invalidation

- One "has code" bit per 4 KB RAM page (512 bits) plus each page's block list.
- `Bus.write`'s RAM case checks the bit. On a hit the page's blocks are
  dropped and the bit cleared. That covers CPU stores and all DMA.
- **A store that invalidates the running block ends it after the store**, so
  the next instruction is decoded from the new bytes.
- **A dropped block is freed by the dispatcher, never by the store.** The
  running `.cached` block is still iterating its handler array when its own
  store invalidates it, so invalidation unlinks the block and queues it, and
  the dispatcher frees the queue between blocks. (The JIT's code buffer is
  never freed piecemeal; see Full flushes.)
- A per-page invalidation counter, so a game that keeps hot data beside its
  code shows up in a measurement. Smaller pages only if that measurement asks.

### Cache isolation

While SR.IsC is set, stores go to the I-cache and not to RAM (the BIOS's cache
flush). The block engines **hand control to the interpreter while IsC is set**
and resume when it clears; the `mtc0` that sets it already ends the block.

### Full flushes

On `loadExe`, savestate load, reset, engine switch, and any change to PGXP or
its CPU mode (a compiled block embeds whether it calls the PGXP hooks). The
JIT's 32 MB code buffer is flushed whole when it fills; no eviction policy.

## The cached interpreter (`.cached`)

**No instruction semantics of its own.** A new `exec.handlerFor(instr)`
returns the function pointer `execute`'s switch dispatches to, and `execute`
becomes `handlerFor(instr)(cpu, instr)`. Every handler is an existing
`exec.zig` `opXxx`, so a fix to one instruction fixes it in both engines.

- Compile: the block's backend data is an array of `{ handler, instr }`.
- Run, per instruction: advance the PC pipeline, rotate the load delay, call
  the handler, retire the load, force `regs[0] = 0`, stop if
  `exception_taken`.
- Gone per instruction: the DMA-stall check, the bus-error PC check, the
  I-cache lookup, the Cause IP2 update and `tickPeripherals` (once per block,
  with summed cycles and the step count).

It is the web demo's engine and the JIT's fallback for blocks entered with a
pending load.

## The arm64 JIT (`.jit`)

### Registers

- Pinned (callee-saved): `x19` = `*Cpu`, `x20` = RAM base, `x21` =
  `downcount`, `x22` = page bitmap.
- Guest registers are cached **per block**: each one the block touches gets a
  host register from `x23`–`x28` and the caller-saved temporaries, loaded on
  first use, written back to `cpu.regs` at block exit and before any call into
  Zig that can observe `Cpu` (exec handlers, PGXP hooks, exception entry). Bus
  slow paths do not observe guest registers and force no write-back of them.
- **`x21` is written back before, and reloaded after, every call into Zig.**
  A Bus slow path can `sync()`, which recomputes `cpu.downcount` (and an MMIO
  access sets it to 0); a stale `x21` would run past that deadline.

### Lowering

- ALU, shifts, logic, LUI, SLT: inline.
- ADD/ADDI/SUB: `adds`/`subs` + `b.vs` to an overflow exit stub.
- MULT/DIV: calls into `alu.zig`, so the divide-by-zero and INT_MIN/−1 quirks
  keep one implementation.
- Loads/stores: alignment check to an address-error exit stub; inline fast
  paths for RAM (mask to 2 MB, `ldr`/`str` off `x20`, add the RAM wait-state
  constant, which must equal what `addWaitCycles` charges) and scratchpad;
  stores test the page bit and call the invalidate path when set; everything
  else calls `Bus.read`/`writeCpuStore` through a shim, so MMIO, wait states
  and `catchUp` behave exactly as in the interpreter.
- COP0, GTE (`cop2`, `mfc2`/`mtc2`/`lwc2`/`swc2`), `syscall`/`break`, HI/LO
  moves: write back, then call the `exec.zig` handler.
- **Any op not lowered is emitted as a call to its `exec.zig` handler inside
  the same block.** It never splits a block. A per-op "lower / call" mask (env
  var and test parameter) bisects a JIT bug to one opcode.
- **The load delay is resolved at compile time.** A load writes a temp,
  committed after the next instruction unless that instruction writes the same
  register (cancel, matching `writeReg`). A load pending at block end is stored
  into `cpu.load_delay`. A block entered with a pending load runs in full
  through `.cached`.

### PGXP

Two switches, two tiers of emitted code, matching what `exec.zig` gates:

- **PGXP on (master), whatever the CPU mode:** the inline RAM/scratchpad load
  and store fast paths call `shadowLoad`/`shadowStore` (and the half-word
  variants) exactly where `exec.zig`'s handlers do, and every guest register
  the JIT writes inline has its `gpr_shadow` cleared, because inline code
  bypasses `writeReg`, which is the rule that keeps the propagation set small.
  Without this, a vertex read with `mfc2` and stored with `sw` loses its
  provenance on the way to the GPU even with CPU mode off.
- **CPU mode on, in addition:** the ALU, shift, mult/div and HI/LO/COP0 move
  hooks, at every site `exec.zig` calls them.
- **PGXP off:** no shadow code is emitted.

### Plan 6: the PGXP tiers (design, 2026-10-04)

Plan 5 left `run.compileBlock` lowering nothing while PGXP is on, so `.jit`
with PGXP on (11.347 s on Croc) is barely ahead of the interpreter
(12.393 s). Plan 6 lowers what it can under each tier and emits the shadow
bookkeeping those ops skip. It adds no new machinery.

- **The tier is a compile-time fact.** `translate.Options.pgxp` is `off`,
  `base` (master on, CPU mode off) or `cpu` (both on), read from `Bus` by
  `run.compileBlock`. It replaces the blanket `.lower = .none`.
- **A CPU-mode change flushes.** A new `Bus.setPgxpCpu` flushes the block
  cache when the value changes, as `setPgxp` does. `ps1_set_pgxp_cpu` and
  `ps1-capi`'s settings restore go through it; both write `bus.pgxp_cpu`
  directly today, which would leave compiled blocks on the wrong tier.
  `.cached` needs no flush: its handlers read `cpuMode` at run time.
- **Branches, linking and the JR/JALR lookup** lower in both tiers. JAL and
  JALR clear `gpr_shadow[rd]`, as `writeReg` does in their handlers.
- **ALU and shifts:**
  - `base`: inline, and every register an inline op writes has its
    `gpr_shadow` cleared (a `Value` is 20 zero bytes). The
    `or`/`addu rd, rs, $zero` move idiom stays a call: it is the one ALU op
    that propagates in this tier.
  - `cpu`: calls. Inlining the op with a hook call after it is deferred
    until a bench shows those calls are what is left. Guest registers live
    in `Cpu.regs`, so such a call would need no write-back.
- **Loads.** The PGXP half of `opLoad` (the `load_shadow` switch) moves to
  a `pub` function in `exec.zig` that the handler and a JIT shim share. The
  inline fast path loads the integer as before, then calls the shim, which
  writes `cpu.load_shadow`. The integer keeps waiting in x27 or x28; the
  shadow takes the interpreter's own path through memory:
  - `model.advance` copies `load_shadow` to `delay_shadow` when a load is
    in flight (known at compile time), as `beginInstruction` does.
  - `model.retire` copies `delay_shadow` to `gpr_shadow[rt]` unless the
    load was cancelled, as `retireLoad` does.
  - `sync` leaves both fields exactly as `runOp` would.
- **Stores.** The PGXP half of `opStore` (`shadowStore` and `pgxp_pending`,
  or the half-word and byte forms) moves to a shared function the shim
  calls. The shim runs before `endInline`, so it reads the old shadow, as
  the store reads the old value.
- **Still calls under PGXP:** LWL, LWR, SWL, SWR, COP0, COP2, MULT/DIV and
  the HI/LO moves.
- **Gates:**
  - The fuzzer gains a PGXP-on variant per tier. It seeds `gpr_shadow` with
    valid `Value`s (`word` equal to the register) and compares
    `gpr_shadow`, `load_shadow`, `delay_shadow` and the shadow memory of
    every address it touched, `.jit` against `.cached`.
  - `stream-capture --pgxp-on` on tr1: the GP0 stream, which carries every
    precise vertex, is byte-identical under `--engine=jit` and
    `--engine=cached`.
  - `pgxp --engine=jit` output is byte-identical to `.cached`'s, and again
    with a new `--pgxp-cpu=off` flag on `ps1-golden` (the `base` tier).
  - `verify`, `savestate`, `stream-verify` and lockstep under `.jit` stay
    green with PGXP off. Lockstep keeps PGXP off.
- **Tasks:** (1) the tier plumbing, `setPgxpCpu` and its ABI callers,
  `--pgxp-cpu=off` and the PGXP fuzzers, lowering nothing new; (2) branches
  and linking under PGXP; (3) ALU in the `base` tier; (4) loads and stores;
  (5) gates, the bench against the 11.347 s row, as-built notes and the
  CLAUDE.md JIT rule rewritten for the tiers.

### Linking and timing

- Every block entry is `subs x21, x21, #static_cost` / `b.le
  exit_to_dispatcher`. The exit path adds `static_cost` back, because the
  block it refused did not run. Dynamic wait states are subtracted from `x21`
  as they occur.
- A direct branch to an already compiled block is patched to jump to its
  entry. Indirect jumps (`jr`, `jalr`) go through a lookup stub.
- Invalidating a block repoints its entry at the exit-to-dispatcher stub, so
  stale links fall out without tracking incoming patch sites.
- Skipping the dispatcher on a linked jump is unobservable, because each of
  the dispatcher's jobs either cannot be needed or forces an exit first:
  - **interrupt state** changes only at a sync (which needs `downcount <= 0`)
    or at an MMIO access, `mtc0` or `rfe`, all of which return to the
    dispatcher;
  - **a refused interrupt** runs one `Cpu.step()` and sets `downcount = 0`
    (see Block engines: timing);
  - **the TTY hook** blocks are never link targets;
  - **a DMA stall** begins only at an MMIO store or a deadline;
  - **IsC** is set only by `mtc0`.
- Wait states are summed as they occur in `.jit` and at block end in
  `.cached`; both are read only at the next block-start check.

### Machinery

- One 32 MB `MAP_JIT` region; `pthread_jit_write_protect_np(0/1)` around
  emission; `sys_icache_invalidate` over each emitted range.
- `emit.zig` is a pure encoder, tested against encodings pinned from
  `llvm-mc`.
- `PS1_JIT_DUMP=path` writes guest-PC → host-range records plus raw code for
  `llvm-objdump`.

## Frontends, savestates and the app

### Savestates: no format change

- A state is only taken at a `run()` boundary: between frames in the app,
  at an arbitrary one in `trace-golden -- savestate`.
- Saving first calls `sync()`, so `pending`, `pending_steps` and
  `pending_cpu_window` are 0 and each device holds its
  own exact deferral, which is already saved. `downcount` is recomputed from
  the devices on load. No section version bump.
- `exception_taken` and the block cache are not saved; a load flushes the
  cache. A state saved under one engine loads under any other.
- Gate: `trace-golden -- savestate`. If sync-before-save is not invisible
  there, the fallback is saving `pending` with a `CPU ` section bump.

### C ABI and wasm

- `ps1_set_cpu_engine(h, int)` / `ps1_get_cpu_engine(h)`; asking for the JIT
  on a build without it returns an error. The engine is a host setting like
  `pgxp_*` and is not part of a savestate.
- wasm: a new `setCpuEngine(u32)` export (additive; the `index.html` contract
  is unchanged). The page selects `.cached` at start-up.

### Harnesses

- `ps1-golden` takes `--engine=cached|jit` for `verify`, `stream-verify`,
  `pgxp` and `savestate`. Block engines compare against
  `ps1-core/tests/goldens/trace-block/`, captured from `.cached` and reused
  unchanged by `.jit`.
- `ps1-golden` gains a `lockstep` mode (below).
- `ps1-bench` takes `--engine`, so each A/B is one binary with a flag.
- The ROM suites take `-Dengine=cached`.

### macOS app

- Settings → General: **CPU engine: Recompiler / Cached interpreter /
  Interpreter**, in `UserDefaults`, applied at boot and on change.
- The default stays Interpreter until Stage 3's gates are green, then becomes
  Recompiler.
- `SpeedSetting.choices` widens (e.g. 1…8 plus "Max", meaning no frame
  pacing) only after a measured `ps1-bench` run shows the headroom.
- Battery: no code. A `powermetrics` measurement before and after.

## Testing and gates

| Gate | Proves |
| --- | --- |
| `trace-golden verify`, `savestate`, `stream-verify`, `pgxp` on the interpreter, **no recapture** | Stage 1 changed nothing |
| `ps1-core/tests/recompiler_test.zig` | termination rules, including a branch in a page's last word and a branch at the length cap; invalidation by CPU store, by DMA, by mid-block self-modification (the running block freed only by the dispatcher) and by a write to either page of a page-crossing block; IsC fallback; the TTY hook, including a linked jump to 0xB0; segment-mismatch recompile; a block engine resumed on a delay slot (from an interpreter savestate); the interrupt rule: taken at a branch target, refused before a GTE command at a block start and taken one instruction later, including in a loop whose head is a GTE command; SIO step counts across DMA-stalled steps |
| `trace-golden -- lockstep --engine=X` (`-Dlockstep`) | each block run by the engine, then re-run from a snapshot as per-instruction `exec` calls with devices frozen; registers, COP0, GTE and journaled RAM stores compared. Blocks touching MMIO are skipped (FIFO pops cannot replay). Localises a bug to one block. |
| Game smoke test under `.cached`, before the `trace-block/` capture | Croc, Crash, Spyro, Silent Hill, Tekken 3 boot and play; **an FF7 memory-card save and reload** (the SIO step-count rule) |
| `trace-golden verify --engine=cached` vs `trace-block/` | captured once, as its own commit |
| `trace-golden verify --engine=jit` vs the same `trace-block/` | the JIT equals the cached interpreter, game by game |
| `emit.zig` tests | the encoder matches `llvm-mc` |
| Differential fuzzer, `.jit` vs `.cached` | random short MIPS sequences with random registers: overflow, alignment faults, load-delay cancel, branch in delay slot |
| `pgxp` sweep under `.jit` | counters equal to `.cached`'s; plus one run with CPU mode forced off, the tier where loads and stores still propagate shadows |
| ROM suites with `-Dengine=cached` | functional edge cases; timing-sensitive differences are expected and recorded |
| `ps1-bench --engine` interleaved A/B | each stage's speed-up, reported as measured |
| `zig build test`, `test-roms-ja` (12/17), the Swift suite | unchanged |

## Plans

Each plan ships something green.

1. **Scheduler.** `downcount`, `pending`, `pending_steps`,
   `pending_cpu_window`, `sync()`, sync before and forced after every MMIO
   access, SIO step counts, sync-before-save. Interpreter only; zero golden
   movement; xctrace share of the interpreter; bench A/B.
2. **Block engine core.** `block.zig`, `cache.zig`, invalidation, `run.zig`,
   `exec.handlerFor`, `.cached`, the `engine` field, `recompiler_test.zig`.
3. **Block engine gates.** `--engine` in `ps1-golden`/`ps1-bench`, lockstep
   mode, the game smoke test, the `trace-block/` capture, ROM suites under
   `.cached`, wasm `setCpuEngine` with `.cached` as the web default.
4. **JIT skeleton.** `MAP_JIT` buffer, `emit.zig`, prologue/epilogue,
   dispatcher hookup, **every op emitted as a handler call**, the fuzzer. Gate:
   `verify --engine=jit` green.
5. **JIT lowering**, one family per task: ALU/shifts → branches and the load
   delay → loads/stores with the fast paths and the invalidation check → block
   linking. Each gated by the fuzzer and `verify --engine=jit`, with a bench
   number per step.
6. **PGXP under the JIT.** Load/store shadow propagation and shadow clearing
   (master on), CPU-mode hook calls, flush on toggle, `pgxp` sweep parity
   with CPU mode on and off.
7. **The app.** `ps1_set_cpu_engine`, the Settings picker, the default flip,
   the wider `SpeedSetting` range, the battery measurement.

Follow-ups, out of scope: fastmem, global register allocation, constant
propagation, inlined MULT/DIV/GTE, a wasm JIT.
