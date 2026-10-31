# CPU overclock (clock speed control): design

Date: 2026-10-31. Status: proposed.

## Intent

DuckStation parity: its "Clock Speed Control" lets the player run the
emulated CPU at a percentage of the real clock while everything the player
sees and hears keeps real-time pacing. A game that drops frames because its
CPU cannot keep up (the common PS1 slowdown) runs smoother; a game that ran
fine is unchanged. It ships OFF, and at 100% the machine is the machine it
is today, bit for bit.

## Goals

- A percentage, 10% to 1000% in steps of 10 (DuckStation's range and step),
  held as a reduced fraction `N/D` (`percent / gcd(percent, 100)` over
  `100 / gcd`), exactly as DuckStation stores it.
- DuckStation's split of the machine into two clocks:
  - **Real time** (does not move with the setting): the GPU's video timing
    (scanlines, hblank, vblank, dotclock, so the frame rate and Timer 0/1 on
    their external clocks), the CD drive (every CDROM timing: acks, seeks,
    sector periods, so XA and CD-DA play at pitch), and the SPU (sample
    clock, so audio output is unchanged).
  - **CPU time** (scales with the setting): the root counters on the system
    clock (Timer 2 always, Timers 0/1 when not on an external clock), DMA
    and its CPU window, MDEC, the SIO /ACK, and the GPU's DRAWING time
    (`cycle_debt` and the FIFO stall). DuckStation scales only the CRTC
    (`gpu.cpp:1225`) and charges command ticks in system ticks
    (`gpu.cpp:1748`), so drawing speeds up with the CPU there; it does here.
- A per-game override from the upstream game database's
  `cpuOverclockPercent`, folded in by the session the way the PGXP presets
  are (my call: included for parity).
- Exact scheduling: the scheduler's "nothing is ever due inside a deferred
  window" property holds at every percentage.

## Non-goals

- No change to how fast the host runs the emulator: a higher percentage
  costs proportionally more host CPU per frame. The JIT is what makes 200%+
  affordable; measure it, don't promise it.
- No GTE timing model (the core has none), no per-instruction cost change.
- No DuckStation-style "state was saved at a different clock" warning in the
  app (see Savestates).
- No browser (`ps1-wasm`) export in this work. It can follow later via its
  own export, per the separate-frontends rule.

## Anti-goals (a failure even if it works)

- **Any golden moving at 100%.** `trace-golden -- verify`, `savestate`,
  `snapshot`, `stream-verify`, `pgxp`, `gpu-verify`, every `--engine`, and
  `test-roms-pl`/`-ja` must pass UNCHANGED. A recapture here is a bug.
- A measurable slowdown at 100%. The conversion runs only at a hand-over
  (deferred to a deadline, not per step); at 100% it must cost nothing a
  `ps1-bench-dual` best-of-five can see (gate it on the ratio being 1/1 if it
  does).
- Audio pitch, frame rate or CD timing moving with the setting.
- Breaking a CLAUDE.md rule: the 11/7 GPU conversion stays exactly as it is
  (it is verified against the BIOS); the overclock conversion sits IN FRONT
  of it, it does not replace it. `ack_delay`, the ReadN 1,000,000-cycle seek
  and the first-sector period keep their values: they are real-clock
  constants and stay so because the CD is on the real clock.

## Design

### The real clock in the scheduler (`cpu/scheduler.zig`)

The machine has one clock today: CPU cycles, which `advance` fans out to
every device (the GPU through `stepGpu`'s 11/7). Add a second conversion,
CPU cycles to REAL cycles: `real = floor((cycles * D + real_clock_frac) / N)`,
with the remainder carried in `bus.sched.real_clock_frac` (range `[0, N)`),
the same shape as `gpu_clock_frac`.

- `advance` converts the hand-over's `cycles` once and gives the REAL count
  to `spu.step`, `cdrom.step` and (before its 11/7) `stepGpu`. Timers, SIO,
  and `tickCpuWindow` keep the CPU count. The fan-out ORDER does not change.
- `syncGpu` / `gpu_ahead` hand the GPU part of a backlog early; the GPU's
  share must convert consistently with the rest. The builder decides how
  (one shared real-clock carry consumed in order, or a GPU-side carry of its
  own), with the requirement that the GPU sees exactly the real cycles a
  single full hand-over would have given it. A second carry is a second
  savestate field.
- `due` converts the three real-clock deadlines back to CPU cycles with the
  ceiling inverse: a device needing `r` real cycles is due after
  `ceil((r * N - real_clock_frac) / D)` CPU cycles. The GPU term nests it
  inside its existing 11/7 ceiling. Both are exact for the same reason the
  existing 11/7 term is (floors are monotone). `assertInWindow` (Debug)
  already polices this and must stay on.
- At `N == D == 1` every conversion is the identity and `real_clock_frac`
  stays 0, which is how 100% stays bit-identical.

### GPU drawing time (`gpu/gpu.zig`)

`cycle_debt` drains in REAL video cycles (it is consumed by `gpu.step`). For
drawing to take the same number of CPU cycles at any percentage, the debt a
command adds is charged `* D / N` (round up: a draw never costs zero), and
`writeGp0`'s full-FIFO stall, which converts debt to CPU cycles with `* 7 /
11`, also takes `* N / D`. At 1/1 both are identities. The GPU needs the
ratio, so `Bus` mirrors it into `Gpu` when it changes (as `setPgxp` mirrors
into `gp0`).

### The setting (`memory.zig`)

`Bus.cpu_overclock: struct { num: u32 = 1, den: u32 = 1 }` and
`Bus.setCpuOverclock(percent)`. It is default 1/1 and that default is NOT
zero, so per the `Bus.init` `@memset` rule it must also be assigned in
`Bus.init`. The setter:

- clamps to 10..1000 and reduces the fraction;
- does nothing if the fraction is unchanged (the session re-applies every
  setting every frame);
- otherwise hands the backlog over at the OLD ratio first (`scheduler.sync`
  and the slow path, so `downcount` is recomputed under the new ratio),
  resets `real_clock_frac` to 0 (it may be `>= N` under the new
  denominator), and mirrors the ratio into the GPU.

No block-cache flush: nothing compiled bakes the clock in. The setter is
called between frames, never inside a block.

### Savestates

- `real_clock_frac` (and a GPU carry if the builder adds one) is machine
  state: it goes in the `CPU ` section beside `gpu_clock_frac`, and that
  section's version goes 1 -> 2. Teach `loadCpu` version 1 with the carry's
  power-on value (0), so existing saves keep loading (they were all saved at
  100%, where 0 is exact).
- The PERCENTAGE is host configuration, like `bios_patch`: never in a state.
  A state resumes at the clock the player has set now. DuckStation also
  resumes at the current setting (it only warns); we don't warn.
- Runahead and rewind are trusted snapshots of the same sections, so the
  carry travels with them and an overclocked replay is exact.

### Per-game database table

`gen_cpu_overclock.py` beside `gen_pgxp_presets.py`, reading the same
`gamedb.yaml` at the SAME commit (it imports `entries`/`keys` from
`gen_pgxp_presets`, as `gen_vram_readbacks.py` does), writes
`cpu_overclock.zon`: serial -> percent. Generated, never hand-edited.
`ps1_lookup_cpu_overclock(serial, *percent)` only reads it.

Folded by the session (`ps1-session/src/settings.zig`), never by the core,
exactly as the PGXP preset is: at creation and when a swap is answered. The
rule is DuckStation's (`game_database.cpp:559`): the table's value applies
when the player has NOT turned Clock Speed Control on; the player's own
setting wins when it is on. With the table applied, the effective percent
is what reaches `Bus`. If the table turns out to be empty or tiny at the
pinned commit, keep the plumbing anyway (it is cheap) and say so in the
commit.

### C ABI and session

- `ps1.h`: `void ps1_set_cpu_overclock(Ps1*, uint32_t percent)` (100 = off)
  and `ps1_lookup_cpu_overclock`. A bare handle's host folds the table
  itself.
- `ps1_session.h`: `Ps1SessionSettings` gains `int32_t cpu_overclock;`
  (percent; 0 or 100 means the player has it off). Append it at the end so
  `size` still versions the struct. The session applies it per frame
  through the setter (idempotent).

### Harnesses

- `ps1-golden`: every mode takes `--overclock=<percent>`. There is no golden
  for an overclocked run and never will be; what it gates:
  - `verify` and friends at the default (100) are the anti-goal above.
  - A new self-comparing check at a non-trivial ratio (e.g. 150 and 250,
    both reduce to non-unit denominators): boot each workload overclocked
    and require `savestate` (save at the midpoint, finish on a restored
    `Bus`) and `snapshot` (mark/run ahead/return) to produce the SAME final
    hashes as the plain overclocked run, under each `--engine`. That is the
    gate that the carry is complete and the deadlines exact.
- `ps1-trace` and `ps1-bench-dual`: `overclock=<percent>` to reproduce and to
  measure the host cost (report 100/200/400 on one game, best of five).
- Unit tests (`scheduler_test.zig` or a new `overclock_test.zig`): the
  conversion and its ceiling inverse agree for random `(cycles, frac, N, D)`
  (the device fires on exactly the cycle the deadline names); a setter
  change mid-backlog leaves nothing due inside the window; at 1/1 the carry
  never leaves 0; a vblank period measured in CPU cycles is `571,212 * N / D`
  (within the carry) while a Timer 2 period in CPU cycles is unchanged.

### App

Settings gains a "Clock Speed Control" toggle and a percentage control
(10-1000, step 10), stored in `UserDefaults`, sent in `Ps1SessionSettings`.
Placement and control shape follow the HIG (load
`apple-design-guidelines` first); the in-game HUD's badge row can show the
percent while it is not 100, as it already shows resolution and PGXP.

## Left to the builder

- How the GPU's early hand-over (`syncGpu`) shares the real-clock carry.
- Whether the 1/1 fast path needs an explicit branch (only if the bench
  says so).
- Exact Settings placement and copy.
- Whether `ps1-golden`'s self-comparing check is a new mode or a flag on
  `savestate`/`snapshot`.

## Calls made in this document (not asked)

- Per-game database overrides are included, with DuckStation's rule that
  the player's own enabled setting wins.
- The percentage stays out of savestates; a state resumes at the current
  setting, with no warning.
- The GPU's drawing time scales with the CPU (DuckStation's split), not
  with the video clock.
- No wasm export in this work.
