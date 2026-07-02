# Blocker #3 root cause via avocado execution diff: vblank fires ~3.35× too fast

Date: 2026-06-22
Status: **root cause LOCALIZED** (first divergent value found). Fix not yet applied.

This is the "reference execution diff" prescribed at the end of
`2026-06-21-real-game-boot-vsync-and-iec-deadlock-findings.md` §"Where it stands".
It built/ran `avocado_ref` headless on the **same US BIOS + Silent Hill disc** and
diffed the execution against our Zig core. It found the first divergent value and
**overturns the prior hypothesis** that the trigger sits at the ~85–91M intro→post-
intro transition: the real divergence is a **continuous vblank-timing error present
every intro frame**, and the deadlock is its downstream consequence.

## TL;DR

- The Zig core and avocado execute **identically for the first 1117 BIOS syscalls**
  (A/B/C-function calls, exact arg match), then Zig deadlocks where avocado boots on.
- The divergence is the BIOS **intro VSync-wait loop at `0x80059dc8`**, which polls the
  vblank frame-counter `MEM[0x80079d9c]` (bumped by the vblank IRQ handler) and spins
  until it reaches a target. It runs **19,436 iters/frame in Zig vs 24,415 in avocado**.
- Root cause: **the vblank counter `0x80079d9c` increments ~3.35× too fast in Zig**
  — every **~88,960 instructions** vs avocado's **298,100**. Since the counter is
  bumped by *identical BIOS handler code* in both, the only explanation is the
  **vblank interrupt firing ~3.35× too frequently** relative to CPU execution.
- This timing skew accumulates and eventually derails Zig into the deadlock region
  (`0x80050268`, `0x80050f20`, `0x800513e0..f0`) that avocado **never executes**,
  ending in the unbalanced `ReturnFromException` (the `jr $ra=0` → trampoline chain
  from session 2) at instruction ~89.23M.

## The tooling (reusable; built this session)

**Zig side — `ps1-trace`** (`ps1-trace/src/main.zig`, wired in `build.zig`):
- Loads BIOS + disc **at runtime** (no recompile to switch BIOS), boots from CD.
- Logs every A0/B0/C0 BIOS syscall in a fixed text format
  (`@<instr> X:<fn> a0=.. a1=.. a2=.. a3=.. ra=.. sr=..`), TTY to stderr.
- Optional windowed per-instruction PC trace (args `[4]=start [5]=end [6]=outfile`).
- Build: `zig build -Doptimize=ReleaseFast`. Run:
  `./zig-out/bin/ps1-trace SCPH-1001_BIOS_1995_US.bin "<SH>.bin" <max_instr> <out.txt> [pcstart pcend pcout]`

**Reference side — avocado headless tracer** (in gitignored `avocado_ref/`):
- `avocado_ref/src/platform/headless/main.cpp` — minimal harness: `System` + runtime
  BIOS + `disc::load` + `cdrom->disc` + `emulateFrame()` loop. **Sets
  `config.debug.log.system = false`** so the retail BIOS runs UNPATCHED (avocado
  otherwise patches it to force `ttyflag=1`, which itself diverges — see gotcha).
- Trace instrumentation lives in `avocado_ref/src/cpu/cpu.cpp::executeInstructions`,
  env-gated: `AVOCADO_SYSCALL_TRACE=<file>`, `AVOCADO_PC_TRACE=<file>` +
  `AVOCADO_PC_START`/`AVOCADO_PC_END`, `AVOCADO_VBL_WATCH=1`.
- Built WITHOUT SDL/GL/CHD: excludes `src/{imgui,renderer,platform}` (keeps
  `platform/null/{file,sound}` + the headless main), stubs out the CHD loader
  (`load.cpp` chd branch → nullptr; `chd_format.cpp` excluded), links fmt + miniz.
- Build scripts: `avocado_ref/obj_build.sh` (incremental .o build, **use this** —
  1-file edits relink in seconds) and `avocado_ref/build_headless.sh` (one-shot).
  Needs submodules `fmt cereal magic_enum json EventBus filesystem` (header-only +
  fmt); fetched via `git submodule update --init --depth 1 externals/<name>`.
- Run: `./avocado_ref/build_headless/avocado_headless <bios> <disc.bin> <max_frames>`.
  ~600 frames reaches/loads `cdrom:\SLUS_007.07;1` (well past our deadlock).

## How the diff was driven (method that worked)

1. **Syscall stream first** (cheap, timing-robust): both emulators log A/B/C calls.
   Diffing on real args (`func,a0,a1,a2`, dropping `a3/ra/sr` register noise) showed
   **byte-identical for syscalls 1..1117**, then Zig stops (deadlock) while avocado
   continues to `A:33 malloc` / `B:08 OpenEvent` / `B:0c EnableEvent`.
2. **Instruction-count deltas between consecutive syscalls** exposed that both run the
   same periodic 3-vblank-per-frame intro loop, but at **different instr/frame**
   (avocado ~298,100 vs Zig ~241,468) — i.e. a per-frame timing difference, not a
   control-flow one (yet).
3. **Per-PC execution-count diff of one intro frame** (windowed PC traces, compared by
   PC-execution histogram, not line alignment — robust to differing iteration counts)
   pinpointed the loop `0x80059dc8..0x80059e10`: Zig 19,436 vs avocado 24,415, plus
   Zig-only PCs `0x80050268/0x80050f20/0x800513xx` (the deadlock region).
4. **RAM-dump + disassemble** `0x80059da4..0x80059e20` → it's a VSync wait on
   `MEM[0x80079d9c]` with a `0x8000` timeout guard.
5. **Watch `0x80079d9c` increments** in both → 88,960 (Zig) vs 298,100 (avocado) instr
   per increment = the 3.35× vblank-rate error.

## The divergent code (disasm of the intro VSync wait, RAM @ `0x80059da4`)

```
80059da8 ori   $t6,$zero,0x8000     ; timeout = 0x8000
80059dac sw    $t6,0x1c($sp)
80059db4 lw    $t7,MEM[0x80079d9c]   ; vblank counter
80059dbc slt   $at,$t7,$a1          ; while (counter < target $a1)
80059dc0 beq   $at,$zero,end
; body 0x80059dc8..0x80059e10:
80059dd4 addiu $t9,$t8,-1           ; timeout--
80059dd8 bne   counter!=0 -> 0x80059dfc
80059dec jal   0x8005a910           ; (timeout path; not taken — neither emu times out)
80059e00 lw    $t0,MEM[0x80079d9c]   ; reload counter
80059e08 slt   $at,$t0,$a1
80059e0c bne   ($t0<$a1) -> 0x80059dc8
```

## Open question for the fix (next session)

Is the 3.35× because (a) the **GPU vblank PERIOD is too short** (GPU stepped with too
many cycles, or NTSC scanline count/`cycles_per_scanline` wrong for the US BIOS — the
session-1 11/7 fix may be incomplete or PAL-tuned), or (b) the **vblank IRQ is
delivered multiple times per real frame** (spurious/level-retrigger or multi-source
handler entry — session-1 explicitly flagged "vblanks acked via multi-source handler
entries", and `I_MASK=0x9` enables vblank+DMA)? Disambiguate by counting raw GPU
vblank events vs `0x80079d9c` increments per frame:
- 1:1 → GPU period bug (fix in `cpu.zig tickPeripherals` / `gpu.step` scanline timing).
- N:1 → duplicate-IRQ bug (fix in vblank IRQ assert/ack in `gpu`/`interrupt.zig`).
The 11/7 ratio (1.571) does NOT explain 3.35 alone, so this is a *different/additional*
timing error than the one session-1 fixed (which only got the EU/PAL VSync to pass).

## DISAMBIGUATOR RESULT (2026-06-22, later same day) — the "vblank too fast" hypothesis is WRONG

Ran the prescribed disambiguator (raw GPU vblank events vs `MEM[0x80079d9c]`
increments) by instrumenting `ps1-trace` against US BIOS + SH disc. **The result
overturns this doc's root-cause claim. The vblank timing is physically correct; do
NOT apply a GPU-period or duplicate-IRQ fix — it would break the now-exact timing.**

Measured (steady-state intro phase, deltas between 20M and 40M instr):
- **vblank events : counter increments = 77 : 77 = exactly 1:1.** No duplicate IRQ.
  (The naive global ratio looks like ~3.17 only because of the early-boot phase where
  vblanks fire before the BIOS handler is live, so the counter is frozen — skew, not a bug.)
- **vblank period = 11,424,240 CPU cycles / 20 frames = 571,212.0 cyc/frame**, matching
  the NTSC ideal `263 lines × 3413 dots × 7/11 = 571,212.09` **to the cycle**. The GPU
  period is exact, not "too short".
- GPU emits exactly ONE vblank event per frame (one-shot `v_count == vblankStartLine()`
  `==` pulse in `gpu.step`) — structurally cannot duplicate.

Why the earlier "3.35× too fast" was a measurement artifact:
- The "3.35×" compared **instructions per counter increment** (Zig ~88,960 vs avocado
  ~298,100). But avocado's clock is **non-physical**: `cpu.cpp:154` does `sys->cycles++`
  **once per instruction**, ignoring ALL memory waitstates; the GPU then gets a flat
  3 dots/instruction (`system.cpp:373-406`: `executeInstructions(300/3)=100` instr ⟷
  `emulateGpuCycles(300)`). So avocado runs *more instructions per frame* simply because
  it pretends every instruction is 1 cycle.
- Zig instead advances the GPU by `delta_cycles × 11/7` where `delta_cycles = 1 +
  wait_cycles` — i.e. it models the real CPU clock continuing to tick during memory
  stalls. **This is the physically correct model:** the PSX GPU (53.69 MHz) and CPU
  (33.8688 MHz) are independent crystals at a fixed 11/7 ratio, so the vblank period in
  CPU cycles is fixed at 571,212 **regardless of waitstates**. Measured intro region ran
  ~6.4 cyc/instr in Zig vs avocado's definitional 1.0 → the same ~897,619 GPU dots per
  counter increment in **both** emulators (Zig 571,212 cyc × 11/7 = 897,619 dots).
- Net: Zig and avocado increment the counter at the **same wall-clock/GPU-dot rate**.
  They only differ in instruction count per frame, which is avocado being waitstate-blind.

Consequence for the avocado-diff method: because the two emulators use **incompatible
clocks** (avocado 1 cyc/instr, Zig real cycle accounting), their instruction streams
*must* diverge as soon as any interrupt-timing-dependent code runs — which is exactly
the intro VSync code. The "1117 identical syscalls then divergence" is therefore an
EXPECTED artifact of the clock mismatch, **not** evidence of a Zig timing bug. The
instruction-diff cannot localize the deadlock.

### Corrected next step
The deadlock is real (SH boots on hardware) but is **not** a vblank-rate bug. Chase the
concrete, avocado-independent symptom from session 2 directly in Zig: the **single
unbalanced ReturnFromException** — the `jr $ra` with `$ra=0` at `0x80040868` that
trampolines through address 0 into the BIOS exception handler and drops IEc for good.
Find the upstream branch/value that makes the boot *return* from a stage that should
longjmp/jump away. Open secondary question: whether Zig's waitstate *magnitude* (~6.4
cyc/instr in cached-RAM intro code) is higher than real hardware (~2-3), which would
make instructions-per-frame lower than real HW — plausible contributor, but it does not
by itself produce a deadlock (vblanks still arrive on the correct cycle).

## Gotchas discovered
- Avocado **patches the retail BIOS** when `config.debug.log.system != 0` (default 1):
  `patch(0x6F0C,0x24010001)`=`li $at,1`, forcing `InstallDevices(ttyflag=1)` →
  `AddDuartTtyDevice` instead of `AddDummyTtyDevice`. This is a real execution
  divergence (it was the *first* false hit in the diff). MUST set it false for a
  faithful retail boot. Our Zig core correctly runs `ttyflag=0` and only shows TTY via
  its own putchar-vector intercept hack.
- macOS `/bin/bash` is 3.2 (no `mapfile`); avocado's premake `system:macosx` filter is
  unconditional (pulls SDL/GL even with `--headless`) — hence the hand-rolled clang
  glob build instead of premake/cmake.
