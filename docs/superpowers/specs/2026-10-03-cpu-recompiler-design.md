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
  `irq_timer -= 1` per call). The pad's 500 and the card's 150 are instruction
  counts. A block engine must tick SIO by the number of instructions it ran,
  or the card's 150 ceiling breaks and every game reports the card
  unformatted (the 2026-08-31 FF7 symptom).
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
  (768-cycle sample accumulator), SIO and the DMA block-gap counters do not.

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
  cycle_accumulator`, SIO's `irq_timer` (in instructions) and the DMA
  block-gap counters.
- `tickPeripherals` gains a fast path: while `delta < downcount`, add `delta`
  to a single `pending` total (and the instruction count to a `pending_instrs`)
  and return.
- `sync()` hands `pending` to every device **in today's order** (SPU → GPU →
  SIO → Timer0/1/2 → CD-ROM → DMA window), then recomputes `downcount`. It
  runs when a deadline is reached and before any MMIO access, at the existing
  `catchUp` sites in `memory.zig`, `timer.zig` and `cdrom.zig`.
- A device whose result depends on per-instruction calls rather than cycles
  (SIO) takes the instruction count explicitly.
- **For the interpreter this must be exact.** Every device's own deferral is
  already exact; the scheduler only stops calling devices that have nothing
  due. This is also the "one global next-event countdown" the 2026-10-01
  profile named as the next win (~15% of the emulator thread is per-instruction
  guard and glue).

## Block engines: timing

- **Cycles stay honest.** Each instruction is charged what the interpreter
  charges, 1 plus load/store wait states, with the instruction fetch replaced
  by the block's static fetch cost: the cached-hit cost for RAM code run
  through KUSEG/KSEG0, the uncached per-word cost for KSEG1 and the BIOS. I-cache
  miss bursts are not modelled. The `icache` array stays in savestates; the
  block engines leave it invalidated.
- **A block starts only when `downcount > 0`**, and may overrun the deadline
  by at most its own length.
- **Interrupts are checked between blocks only**, with the interpreter's
  rules. "Never in a delay slot" holds by construction (blocks end after the
  delay slot). "Never on a GTE command" holds because a block never ends just
  before one.
- **DMA:** if `isCpuStalled` when a block would start, the dispatcher runs DMA
  words until the stall clears, as `step()` does. A store that starts a DMA
  ends the block after the store.
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
- a 4 KB page edge (a block never spans two pages);
- an instruction that changes interrupt or memory state: `mtc0` (any COP0
  register), `rfe`, `syscall`, `break`;
- after a store whose address is not RAM or scratchpad (an MMIO store may
  raise an interrupt, start a DMA or touch I_STAT/I_MASK). This is decided at
  run time: `Bus` sets a `block_exit` flag on such a store, and on a store
  that invalidates the running block, and both block engines stop after the
  instruction that set it.

### Where blocks live

- **RAM** (2 MB; the four mirrors fold onto one) and **the BIOS** (512 KB,
  read-only, never invalidated).
- Any other PC (scratchpad, I/O, expansion) runs one `Cpu.step()`. The
  interpreter already raises the correct instruction-fetch bus error there.
- The putchar TTY hook fires on PC 0xA0/0xB0, which is only reached by a jump
  and so is always a block start: the dispatcher runs the hook before the
  block.

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
  with summed cycles and the instruction count).

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
  slow paths do not observe `Cpu` and force no write-back.

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

A block compiled with PGXP CPU mode on calls the same `pgxp` hooks at every
site `exec.zig` calls them. Every guest register the JIT writes inline also
has its `gpr_shadow` cleared, because inline code bypasses `writeReg`, which
is the rule that keeps the propagation set small. With PGXP off, no shadow
code is emitted.

### Linking and timing

- Every block entry is `subs x21, x21, #static_cost` / `b.le
  exit_to_dispatcher`. Dynamic wait states are subtracted from `x21` as they
  occur.
- A direct branch to an already compiled block is patched to jump to its
  entry. Indirect jumps (`jr`, `jalr`) go through a lookup stub.
- Invalidating a block repoints its entry at the exit-to-dispatcher stub, so
  stale links fall out without tracking incoming patch sites.
- Skipping the dispatcher on a linked jump is unobservable: the interrupt
  state can only change at a sync (which needs `downcount <= 0`) or at an MMIO
  store, `mtc0` or `rfe`, all of which return to the dispatcher.
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

- A state is only taken between frames, always a `run()` boundary.
- Saving first calls `sync()`, so `pending` is 0 and each device holds its
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
| `ps1-core/tests/recompiler_test.zig` | termination rules; invalidation by CPU store, by DMA and by mid-block self-modification; IsC fallback; the TTY hook; segment-mismatch recompile |
| `trace-golden -- lockstep --engine=X` (`-Dlockstep`) | each block run by the engine, then re-run from a snapshot as per-instruction `exec` calls with devices frozen; registers, COP0, GTE and journaled RAM stores compared. Blocks touching MMIO are skipped (FIFO pops cannot replay). Localises a bug to one block. |
| Game smoke test under `.cached`, before the `trace-block/` capture | Croc, Crash, Spyro, Silent Hill, Tekken 3 boot and play; **an FF7 memory-card save and reload** (the SIO instruction-count rule) |
| `trace-golden verify --engine=cached` vs `trace-block/` | captured once, as its own commit |
| `trace-golden verify --engine=jit` vs the same `trace-block/` | the JIT equals the cached interpreter, game by game |
| `emit.zig` tests | the encoder matches `llvm-mc` |
| Differential fuzzer, `.jit` vs `.cached` | random short MIPS sequences with random registers: overflow, alignment faults, load-delay cancel, branch in delay slot |
| `pgxp` sweep under `.jit` | counters equal to `.cached`'s |
| ROM suites with `-Dengine=cached` | functional edge cases; timing-sensitive differences are expected and recorded |
| `ps1-bench --engine` interleaved A/B | each stage's speed-up, reported as measured |
| `zig build test`, `test-roms-ja` (12/17), the Swift suite | unchanged |

## Plans

Each plan ships something green.

1. **Scheduler.** `downcount`, `pending`, `sync()`, SIO instruction counts,
   sync-before-save. Interpreter only; zero golden movement; xctrace share of
   the interpreter; bench A/B.
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
6. **PGXP under the JIT.** Hook calls, shadow clearing, flush on toggle,
   `pgxp` sweep parity.
7. **The app.** `ps1_set_cpu_engine`, the Settings picker, the default flip,
   the wider `SpeedSetting` range, the battery measurement.

Follow-ups, out of scope: fastmem, global register allocation, constant
propagation, inlined MULT/DIV/GTE, a wasm JIT.
