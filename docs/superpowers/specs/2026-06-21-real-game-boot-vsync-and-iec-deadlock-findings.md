# Real-game boot: VSync fix + the layered blockers (findings)

Date: 2026-06-21
Status: blocker #1 FIXED; #2/#3 diagnosed, NOT fixed (next session)

This documents a debugging session on "why don't real games / the BIOS boot past
KERNEL SETUP". It started from the `VSync: timeout` hang (see
`memory/project-real-game-boot-blocker.md`) and peeled back **three layered
blockers**. Blocker #1 is fixed and in the tree; #2 and #3 are diagnosed here for a
follow-up session.

---

## TL;DR

1. **[FIXED]** The `VSync: timeout` boot hang was the **GPU clock never being scaled
   from the CPU clock**. The PS1 video clock is `CPU x 11/7` (53.2224 MHz vs
   33.8688 MHz); `gpu.step()` was fed raw CPU cycles 1:1 against video-clock scanline
   lengths, so vblank fired ~1.57x too slow and the BIOS VSync wait timed out. Fixed
   in `cpu.zig` `tickPeripherals` (scale CPU->video cycles with a carry field).
2. **[diagnosed]** With the **EU BIOS + no disc**, boot now reaches the CD-boot intro
   and then panics: the kernel jumps to uninitialized RAM at `0x80069210`
   (`0xccccc222` = `LWC3`) -> `CoprocessorUnusable` -> `SystemErrorUnresolvedException`
   loop. Region/no-disc specific.
3. **[diagnosed, CURRENT TARGET]** With the **US BIOS + a real US disc (Silent Hill)**,
   the panic disappears and boot advances much further, then **silently deadlocks**
   spinning in a kernel loop with **IEC (interrupt-enable) stuck at 0** and a pending
   vblank never serviced.

The build (incl. wasm) and `zig build test` are green with only the #1 fix applied.

---

## The fix (#1) — already in the tree

`ps1-core/src/cpu.zig`, `tickPeripherals`:

```zig
// Convert CPU cycles to video-clock cycles (11/7) for the GPU. Without this the
// vblank period is ~1.57x too long relative to the CPU-cycle root counters, so the
// BIOS VSync wait times out during KERNEL SETUP and the boot hangs.
const gpu_scaled = delta_cycles * 11 + self.gpu_clock_frac;
const gpu_cycles = gpu_scaled / 7;
self.gpu_clock_frac = gpu_scaled % 7;
const gpu_result = self.bus.gpu.step(gpu_cycles);
```

`gpu_clock_frac: u32` is a new field on `Cpu` (the conversion carry). Scaling lives at
the call site, not inside `gpu.step()`, so `gpu.step()` stays a pure video-cycle
stepper and the `gpu_test` CRT/dotclock tests (which feed video cycles) stay valid.

How it was found: cycle-timestamped tracing of vblank fire/ack showed every vblank was
serviced once enabled, yet VSync still timed out. The period was the tell — vblank
fired every ~1,069,477 CPU cycles = exactly PAL (`3406 x 314`), where the embedded
BIOS is the **EU/PAL** "Version 4.1 12/16/97 E"; the ratio to real PAL 50 Hz
(~677k cycles) is 1.579 ~= 11/7.

---

## BIOS region + test assets (important context)

- The native `ps1-debug` harness embeds `ps1-debug/src/BIOS.BIN` at **compile time**
  (`@embedFile`, must be exactly 512 KB, gitignored). Currently the **EU/PAL** BIOS.
- The **wasm** build does NOT embed a BIOS — `ps1-wasm` exposes `getBiosPtr()` /
  `setBiosLoaded()` and JS copies a user-selected BIOS into wasm memory at runtime
  (`ps1-wasm/www/index.html` `#bios-upload`). `rom_test.zig` also loads BIOS at
  runtime from the repo root.
- Repo root has both **US** BIOSes: `SCPH-1001_BIOS_1995_US.bin` (ROM 2.2 A) and
  `SCPH-101_BIOS_2000_US.bin`, plus JP ones. **US games need a US BIOS** (PS1 is
  region-locked). To test US games on native: copy a US BIOS over
  `ps1-debug/src/BIOS.BIN` and rebuild.
- User-provided NTSC-U discs:
  - `~/Downloads/Silent Hill (USA)/Silent Hill (USA)/Silent Hill (USA).bin` —
    single-track MODE2/2352, load with `Disc.init(bytes)` (the harness already does
    this when given a disc-path arg).
  - `~/Downloads/Castlevania - Symphony of the Night/` — multi-track `.cue`
    (data Track 1 + audio Track 2), needs `Disc.initFromCue`.

---

## Blocker #2 — EU BIOS + no disc: garbage jump -> SystemError

Repro: build native (EU BIOS), run `./zig-out/bin/ps1-debug` with **no** disc arg.
Add a `tty_write_fn` to see the kernel banner.

Symptom chain:
- Boot reaches `ResetCallback: _96_remove ..` and `System Controller ROM Version
  02/94/09 19`, then loops forever calling **A0:0x40 = `SystemErrorUnresolvedException`**
  (~4M A0/B0 syscalls; `a0=0xf0000010 a1=0x1000 ra=0x1b10`).
- Traced the trigger to **`EXC code=0x0B` (CoprocessorUnusable)** at `epc=0x80069210`,
  faulting instruction `0xccccc222` (opcode `0x33` = `LWC3`, cop3).
- RAM is `@memset(0)` (`memory.zig:49`), so `0xccccc222` is not our fill — the kernel
  **jumped into uninitialized/garbage memory** as code. The CopUnusable is just the
  symptom; root cause is a bad jump (corrupt handler pointer / wrong control flow).
- Lead-up: event system (`b0:08` OpenEvent, `b0:0c` EnableEvent, `b0:0b` TestEvent,
  `b0:07` DeliverEvent, `b0:17` ReturnFromException) + CDROM `Test(0x19)`/`Getstat(0x01)`.

This is EU + no-disc specific (does not occur with US BIOS + disc), so it is likely
lower priority than #3. If pursued: disassemble the kernel exception dispatch near
`ra=0x1b10` / `0x80068584` and find how a handler pointer became garbage.

---

## Blocker #3 — US BIOS + Silent Hill disc: IEC-stuck-at-0 deadlock (CURRENT TARGET)

Repro:
1. `cp SCPH-1001_BIOS_1995_US.bin ps1-debug/src/BIOS.BIN` (back up the EU one first).
2. `zig build`
3. `./zig-out/bin/ps1-debug "~/Downloads/Silent Hill (USA)/Silent Hill (USA)/Silent Hill (USA).bin"`
   (the harness loads it via `Disc.init` and sets `cdrom.debug_enable = true`).
4. Add a `tty_write_fn` printing to stderr to see the banner.

Observed:
- Boot completes KERNEL SETUP, prints `System ROM Version 2.2 12/04/95 A`,
  `ResetCallback: _96_remove ..`, then **goes silent (no error TTY) and deadlocks.**
- The deadlock is a kernel spin loop, body `[0x80050e68..0x800513c8]`, frequently
  sampled at the function epilogue `0x800513bc` (`lw $ra,0x1c($sp); jr $ra`). The loop
  repeatedly calls `jal 0x8005a910` (a0 = a struct ptr 0x800892c8) and
  `jal 0x80050f8c` (a0=1).
- **Key signature:** at the loop, `SR = 0x00000400` -> **IEC (SR bit0) = 0,
  interrupts disabled**, while a **vblank is pending and enabled** (`I_STAT=0x1`,
  `I_MASK=0x9`) and is **never serviced**. The loop makes **no syscalls** and issues
  **no CDROM commands** in the stuck window.
- RFE/MTC0 trace into the deadlock: the IRQ handler normally restores IEC=1 on each
  return (`MTC0 SR ...->0x404` at `pc=0xf80`, then `RFE 0x404->0x401` at `pc=0x1014`,
  IEC 0->1). Then **one transition flips `0x401 -> 0x400` (IEC 1->0) and it stays
  there** — the kernel deliberately enters an interrupts-off spin.

Interpretation: the kernel is waiting (interrupts off) for something that, in this
state, cannot change. On real US hardware Silent Hill boots, so this is a real bug —
NOT yet root-caused.

### Next steps for the follow-up session (do this)
1. **Trace what the loop polls.** Log load/store addresses inside the loop
   (`0x80050e68..0x800513c8`). Decide: is it polling a **RAM variable** that the vblank
   handler should update (=> IEC must be 1; emulator interrupt/COP0 bug), or an
   **MMIO/CD/DMA register** that is stuck (=> a device-side bug)? `I_MASK=0x9` enables
   bit3 = **DMA IRQ**, so a CD-read-via-DMA wait that never completes is a prime
   suspect.
2. **Find the transition that drops IEC for good.** Capture SR + PC + what exception/
   syscall preceded the `0x401->0x400` RFE, and what the kernel was doing just before
   (the loop changes from `0x80059xxx` around 60-80M instr to `0x800513bc` by ~100M).
3. **Check the CD path.** The kernel reaches CD-boot but the deadlock issues no CDROM
   commands in-window — confirm whether an earlier CD read (license / SYSTEM.CNF /
   boot exe) was issued and is being awaited. Inspect `cdrom.zig` + `dma.zig` CD DMA
   delivery against `avocado_ref`.
4. Candidate root causes to keep in mind: a COP0/critical-section (EnterCriticalSection
   via syscall) edge case; the `safe_to_interrupt = !is_delay_slot and
   !next_is_delay_slot` over-conservatism (blocks interrupts on the instruction
   *before* a delay slot too — stricter than hardware); or a CD/DMA completion that
   never fires.

---

## Blocker #3 — DEEP DIVE UPDATE (2026-06-21, session 2): mechanism fully root-caused, exact trigger still open

Re-ran the repro (US SCPH-1001 BIOS + Silent Hill .bin) with heavy capped
instrumentation (all via `std.log.warn`, which — unlike `std.debug.print` — is
safe in core and does **not** break the wasm build; cdrom.zig already uses it).
The deadlock reproduces deterministically: by ~90M instructions PC settles at
`0x800513bc` with `SR=0x400` (IEc=0), `I_STAT=0x1`/`I_MASK=0x9` (vblank pending,
never serviced).

### The complete failure chain (all evidence-backed)
1. **Final spin** at `0x800513bc` waits on RAM counters (`0x80079d9c`,
   `0x800dea5c`) a vblank handler would advance.
2. They never advance because **IEc is stuck at 0** → the pending+enabled vblank
   IRQ is never taken.
3. IEc dropped via **one unbalanced RFE** (counted **78 exceptions vs 79 RFEs** in
   the window; the 79th has no matching exception). The bad RFE goes
   `0x401 -> 0x400` (IEc 1→0) in *normal* context and sticks.
4. The extra RFE is a **`ReturnFromException` (B0:17)** call (caller `ra=0x8005a314`,
   `a0=0x1f801074`=I_MASK) reached **not** from the exception vector but from the
   kernel doing **`jr $ra` with `$ra = 0`** at `0x80040868`. Address `0x00000000`
   holds a real trampoline `lui $k0; addiu $k0,$k0,0x0c80; jr $k0` → the BIOS
   general-exception handler at `0xc80`. So the handler + ReturnFromException run
   **with no real exception behind them**.
5. Confirmed this is illegitimate (not a kernel idiom): the handler restores SR
   from the saved TCB via `mtc0 $v0,$12` at `0x0f80`. A *real* exception saves SR
   with IEp=1 (hardware pushed it); the *software* `jr 0` entry saves the live
   normal SR (`0x401`, IEp=0), so the terminating RFE pops IEc←IEp=0. On real HW
   this same path would also deadlock → real HW does **not** take it.
6. **`$ra` is never freshly computed to 0** anywhere in the whole boot (only 3
   restores of an already-0 value from stack/TCB slots). So the null is a return
   address that propagates from the **top of a deep BIOS call chain** down through
   tail-calls to the `jr $ra` at `0x80040868`.

### What was RULED OUT (don't re-chase these)
- **Not a CD/disc problem.** With debug_enable on, **zero CDROM commands** are
  issued during the entire boot — the deadlock is in the **BIOS intro/setup phase,
  before any disc access**. (The earlier "DMA/CD-read wait" suspicion from session 1
  is wrong.)
- **Not GPUSTAT bit 19.** The intro polls `GPUSTAT` (`0x1f801814`) bit 19 every
  frame at `0x80059d00`; bit 19 = vertical-resolution (vres), correctly 0 in 240p
  mode (GPUSTAT≈`0x1c06060a`, interlace bit22=0). bit19=0 matches real HW. Dead end.
- **Not a runaway/early-exit loop.** The big wait at `0x80059dc8` (ran ~35M→85M
  instr) is a **fixed busy-delay** (`[sp+0x1c]` counts down from `0x8000`), called
  ~per-frame by an intro animation (`while $s0 < $v0/2`, `$v0`=240 NTSC / 200 PAL,
  selected by flag `[0x80079de0]`). It completes normally — not the bug.
- **Not the interrupt/load-delay model.** Compared against `avocado_ref`
  (`cpu.cpp` `executeInstructions`/`checkForInterrupts`, `instructions.cpp`
  `exception()`): our load-delay commit timing across an interrupt matches avocado;
  our EPC handling matches. Avocado has two quirks we lack — (a) delay the interrupt
  if the faulting op is a GTE/COP2 command (avoids EPC double-executing it), and
  (b) it *allows* interrupts in branch-delay slots and fixes EPC in `exception()`,
  whereas we block them via `safe_to_interrupt = !is_delay_slot and
  !next_is_delay_slot`. Neither produces `$ra=0`: our discard-and-re-execute model
  already avoids the GTE double-exec the hack guards against, and the delay-slot
  block only postpones an IRQ by ≤2 instrs. (Still, (a) and (b) are real fidelity
  gaps worth closing eventually.)

### Boot structure mapped
- Boot dispatcher **`F0` at `0x80030040`** is a sequence of `jal` stages
  (`0x800403f0, 0x8004ef90, 0x8003fdb0, 0x8003fe88, 0x8003f910, 0x80040490,
  0x80030788, 0x80059c80, 0x8004ed1c, 0x80035bf4`). It was entered with `$ra=0`
  (boot main, not meant to return). The BIOS boot uses **setjmp/longjmp** (a
  jmp_buf-looking pair `{0x801ffe98,0x801ffe48}` sits at `0x801ffe30`).
- The `$ra=0` `jr` happens while a stage's subtree unwinds. On real HW one stage
  must **not return here** (it longjmps / context-switches / jumps to the next
  phase) — our emulator makes it return into the `jr $ra=0`.

### Where it stands / next step
Mechanism = **certain**. The remaining unknown is the single upstream value/branch
that makes the BIOS boot reach `jr $ra=0` (a return address that should be non-zero,
or a stage that should not return). Forward tracing can't isolate it further without
a **reference execution diff**: build/run `avocado_ref` on the *same* US BIOS + SH
disc and diff the instruction/register stream around the divergence (the transition
out of the `0x80059dc8` intro delay into the post-intro stage, ~85–91M instr) to
find the first register/memory value that differs. That is the recommended next move.

### Spec-conformance audit + fixes (2026-06-21 session 3) — did NOT fix the deadlock
A static code-vs-PSX-SPX/R3000A audit of the CPU core found it **spec-correct**
(COP0 SR push/RFE, exception EPC/BD, J/JAL/branch target math, JR/JALR link,
load-delay-across-interrupt timing vs avocado, I-cache tag/index, CDROM status
register = 0x18 idle). Real spec violations found and **fixed** this session
(`zig build test` green, boot re-run unchanged):
- **`timer.zig` mode read now clears bits 11/12** (reached-target / reached-0xFFFF)
  per PSX-SPX (were stuck-set). Still TODO: bit 10 IRQ-request, bit 6 once/repeat.
- **`memory.zig` RAM now mirrors 4× across `0x00000000–0x007FFFFF`** (was only
  `0–0x1FFFFF`, returning 0 above).
Remaining known divergences left as-is (riskier / intentional hacks): interrupt
condition ignores software IP0/IP1; SIO `0xC0C00000` and Timer1 `0x3C045678` magic
spoofs. **Result: Silent Hill still deadlocks at the same `0x800513c0`** — so these
were genuine fidelity fixes but NOT blocker #3's cause. Confirms the trigger is a
BIOS-internal control-flow branch off a device value, not a core-spec bug; needs the
runtime↔branch correlation (or avocado exec diff) to localize.

### Method note (instrumentation)
All diagnosis used temporary `std.debug.print` instrumentation in `cpu.zig`,
`interrupt.zig`, and `ps1-debug/src/main.zig`, gated by capped budgets and reverted
after. NOTE: `std.debug.print` in **core** files (`cpu.zig`, `interrupt.zig`, `gpu/`)
breaks the `wasm32-freestanding` build (pulls in `std.Io`); native still builds, so
you can iterate natively but must revert before trusting `zig build`. The most useful
hooks were: count/timestamp vblank fire vs ack; per-step IEC/IM2/safe + pending IRQ;
capped A0/B0 syscall tracer (reads `$t1` at PC `0xA0`/`0xB0`); capped MTC0-to-SR and
RFE tracer (old/new SR + PC); one-shot RAM dumps via `cpu.bus.read32`.

**Session-2 method correction:** use **`std.log.warn`** (not `std.debug.print`) for
core-file tracing — it is wasm-safe (cdrom.zig already uses it and the wasm build
stays green), so you can keep tracing core code without a separate revert just to
build. The highest-leverage hooks in session 2 were: a PC-history ring buffer dumped
on the "bad RFE" (`sr_before&1==1 && sr_after&1==0`), collapsed to control-flow
jumps only; a `writeReg`-side catcher for `$ra → 0` transitions (only 3 in the whole
boot — instantly proves the null is propagated, not computed); a targeted load probe
keyed on `current_pc`; and a full active-stack walk flagging return-address-looking
words. All reverted; only the VSync 11/7 fix remains in `cpu.zig`.
