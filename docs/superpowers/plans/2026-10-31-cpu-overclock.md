# CPU Overclock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the emulated CPU at a whole percentage of its real clock (10..1000) while video timing, the CD drive and the SPU stay on real time, bit-identical at 100%.

**Architecture:** A reduced ratio `num/den` (`percent/g` over `100/g`) lives on `Bus` as host configuration. The scheduler converts each hand-over's CPU cycles to REAL cycles (`floor((c*den + frac)/num)`) for the SPU, the CD-ROM and (in front of the untouched 11/7) the GPU, and converts their deadlines back with the ceiling inverse. The GPU's drawing debt is charged in CPU time. Carries are machine state (the `CPU ` section), the ratio is not; the session folds the per-game table and sends the effective percent through `ps1_set_cpu_overclock`.

**Tech Stack:** Zig 0.17.0 (core, C ABI, session, harnesses), Python 3 (table generator), Swift/SwiftUI (app).

**Spec:** `docs/superpowers/specs/2026-10-31-cpu-overclock-design.md`

## Global Constraints

- Range 10..1000 percent; the core takes ANY whole percent in that range (the app's control steps by 10). Out-of-range input is clamped, never refused.
- `num = percent / gcd(percent, 100)`, `den = 100 / gcd(percent, 100)`. `num <= 1000`, `den <= 100`: every conversion is done in `u64`/`i64`.
- At 100% (`num == den == 1`) every conversion is the identity and every carry stays 0. No golden may move: a recapture in this work is a bug.
- The 11/7 GPU conversion, `ack_delay`, the ReadN 1,000,000-cycle seek and the first-sector period are UNCHANGED. The overclock sits in front of 11/7.
- Real clock: GPU video timing, CD-ROM, SPU. CPU clock: timers on the system clock, SIO, DMA and its CPU window, MDEC, GPU drawing time (`cycle_debt`, FIFO stall).
- The percentage is host configuration: never in a savestate. The carries are machine state.
- `Bus.init`'s `@memset` leaves the ratio 0/0: it MUST be assigned in `Bus.init`.
- Commit messages are a title line only; commit on master, one commit per task. Never push.
- Run every `trace-golden` mode and `ps1-bench-dual` with `-Doptimize=ReleaseFast`.
- Invoke the area skill before each task: `ps1-core-subsystems` (Tasks 1-4), `ps1-gpu-metal` (Task 3), `ps1-test-harnesses` (Task 7), `ps1-macos-app` + `apple-design-guidelines` (Task 8).

## Review Focus

1. **A ratio change with a backlog pending** (the session applies the setting at the top of a frame, but a test or a bare-handle host may call it anywhere): expected exact hand-over at the old ratio, then nothing due inside the next window. Test: Task 2 `"a ratio change mid-backlog stays exact"`.
2. **A state saved at one percentage loaded at another** (the player changes the setting between sessions): expected the state loads and runs; a carry `>= num` under the new ratio is dropped to 0, never kept. Test: Task 4 `"a carry outside the current ratio loads as zero"`.
3. **A conversion that yields 0 real cycles** (above 100% a one-cycle step can convert to nothing): expected no device is stepped by 0 (a zeroed countdown would fire its event body with delta 0). Test: Task 2 equivalence at 250% under `armDotclock` (GPU eager, every step slow).
4. **A state load or reset on the C handle** rebuilds `Bus` from `Bus.init`: expected the handle keeps the player's percentage and the loaded carry survives. Test: Task 5 `"a state load keeps the overclock and its carry"`.
5. **The settings struct grows** (`size` versions it by exact equality): expected an old-size struct is refused as today and the new field's 0 means off. Test: Task 6 abi test.

---

### Task 1: The ratio and its conversions

**Files:**
- Create: `ps1-core/src/cpu/overclock.zig`
- Modify: `ps1-core/src/root.zig` (re-export as `overclock`)
- Create: `ps1-core/tests/overclock_test.zig`
- Modify: `build.zig` (`unit_test_files` gains `ps1-core/tests/overclock_test.zig`; CLAUDE.md's "29 unit_test_files / 37 test binaries" counts move by one)

**Interfaces:**
- Produces, in `overclock.zig`:
  - `pub const Ratio = struct { num: u32 = 1, den: u32 = 1, ... }`
  - `pub const min_percent: u32 = 10`, `pub const max_percent: u32 = 1000`
  - `pub fn fromPercent(percent: u32) Ratio`: clamps, reduces by gcd.
  - `pub fn percent(self: Ratio) u32`: `num * 100 / den` (exact for a reduced fraction of p/100).
  - `pub fn isUnit(self: Ratio) bool`: `num == den`.
  - `pub fn toReal(self: Ratio, cycles: u32, frac: *u32) u32`: `floor((cycles*den + frac) / num)`, new frac is the remainder, in `[0, num)`. `isUnit` returns `cycles` without touching `frac` (no u64 divide at 100%).
  - `pub fn cpuCyclesFor(self: Ratio, real: i64, frac: u32) i64`: CPU cycles until `real` real cycles are handed over: `ceil((real*num - frac) / den)` via `@divFloor(x + den - 1, den)`; `isUnit` returns `real`. Correct for `real <= 0` (returns `<= 0`).
  - `pub fn drawCost(self: Ratio, video: u32) u32`: `ceil(video*den / num)`, 0 stays 0.
  - `pub fn stallCycles(self: Ratio, debt: i32) u32`: `debt*7*num / (11*den)` truncated; at unit exactly today's `@divTrunc(debt * 7, 11)`.

- [ ] **Step 1: Write the failing tests** in `overclock_test.zig`:
  - `"fromPercent reduces and clamps"`: `fromPercent(100) == {1,1}`, `150 -> {3,2}`, `250 -> {5,2}`, `95 -> {19,20}`, `99 -> {99,100}`, `999 -> {999,100}`, `5 -> {1,10}` (clamped to 10), `5000 -> {10,1}`, `0 -> {1,10}`; `percent()` round-trips every value in 10..1000.
  - `"the unit ratio is the identity and never moves the carry"`: for 10,000 random `cycles`, `toReal == cycles` with `frac` staying 0, `cpuCyclesFor(r, 0) == r` for `r` in -5..1_000_000, `drawCost(v) == v`, `stallCycles(d) == @divTrunc(d*7, 11)`.
  - `"toReal over chunks equals toReal over the sum"`: random ratios from `fromPercent(10..1000)`, random chunk sequences: summed outputs and final frac equal one call over the total.
  - `"cpuCyclesFor names exactly the cycle the device fires on"`: random `(ratio, frac < num, real in 1..2_000_000)`: `c = cpuCyclesFor(real, frac)`; a copy of `frac` handed `c` cycles yields `>= real`, handed `c - 1` yields `< real` (when `c >= 1`).
  - `"drawCost never charges zero for a non-zero draw"`: `drawCost(1) >= 1` at 1000%.

- [ ] **Step 2: Run** `zig build test 2>&1 | grep -A3 overclock` — Expected: FAIL (`overclock` not found).

- [ ] **Step 3: Implement `overclock.zig`** with the signatures above; module comment states the two clocks (one paragraph, the spec's split).

- [ ] **Step 4: Run** `zig build test` — Expected: PASS, 38 binaries on macOS.

- [ ] **Step 5: Commit** `feat(core): CPU overclock ratio and its conversions`

---

### Task 2: The real clock in the scheduler, and the setter

**Files:**
- Modify: `ps1-core/src/cpu/scheduler.zig` (`Scheduler`, `stepGpu`, `advance`, `due`)
- Modify: `ps1-core/src/memory.zig` (`Bus.cpu_overclock`, `Bus.init`, `Bus.setCpuOverclock`)
- Modify: `ps1-core/tests/scheduler_test.zig`
- Modify: `CLAUDE.md` (one rule under "Core subsystems") and `.claude/skills/ps1-core-subsystems/` (the reasoning)

**Interfaces:**
- Consumes: `overclock.Ratio` (Task 1).
- Produces:
  - `Scheduler.real_clock_frac: u32 = 0` (SPU + CD carry) and `Scheduler.gpu_real_frac: u32 = 0` (the GPU's own carry, because `syncGpu` hands it its share early). Equal after any full flush.
  - `Bus.cpu_overclock: overclock.Ratio = .{}` — ON `Bus`, not in `Scheduler`: `loadCpu` replaces the whole `Scheduler`.
  - `pub fn setCpuOverclock(self: *Bus, percent: u32) void`.

- [ ] **Step 1: Write the failing tests** in `scheduler_test.zig`. Give `expectEquivalent` a `percent: u32` parameter applied to both machines (via `setCpuOverclock`) before arming; existing tests pass 100.
  - `"an overclocked machine defers exactly"`: `expectEquivalent(armSystemClock, p)` and `expectEquivalent(armDotclock, p)` for `p` in `{ 50, 95, 150, 250, 1000 }`. (Debug build: `assertInWindow` also polices every window.)
  - `"a ratio change mid-backlog stays exact"`: both machines at 100; after 50,000 steps (the deferring one holding a backlog: assert `sched.pending > 0` first) both call `setCpuOverclock(250)`; run 150,000 more steps comparing as `expectEquivalent` does, final `expectSameState`.
  - `"at 100% neither carry ever leaves zero"`: `armDotclock`, 200,000 steps, assert `real_clock_frac == 0 and gpu_real_frac == 0` after every step.
  - `"the frame period scales with the ratio and timer 2 does not"`: a helper measures CPU cycles between two vblank I_STAT edges (acking bit 0 by writing I_STAT) and between two timer-2 target IRQs (`armSystemClock`'s timer 2). At 200% the vblank period is within 2 cycles of twice the 100% one, at 50% within 2 cycles of half; the timer-2 period is equal at all three.
  - `"an unchanged percentage does nothing"`: with a backlog pending, `setCpuOverclock(100)` on a 100% machine leaves `sched.pending` and `downcount` as they were.

- [ ] **Step 2: Run** `zig build test` — Expected: FAIL to compile (`setCpuOverclock` missing).

- [ ] **Step 3: Implement the scheduler.**
  - `stepGpu`: `real = ratio.toReal(cycles, &gpu_real_frac)`; return `.{}` if `real == 0`, otherwise the existing 11/7 on `real` (comment unchanged).
  - `advance`: `real = ratio.toReal(cycles, &real_clock_frac)`; `spu.step(real)` and `cdrom.step(real, &bus.spu)` only when `real > 0` (a zero step would fire a zeroed countdown's body; at 100% `real == cycles >= 1`, so nothing changes there). `cdrom.updateInterrupts`, the IRQ edges, SIO, timers and order stay exactly as they are; timers keep `cycles`.
  - `due`: GPU term becomes `ratio.cpuCyclesFor(<today's 11/7 ceiling, i.e. real cycles needed>, gpu_real_frac) - gpu_cycles`. SPU and CD-ROM terms are real: `ratio.cpuCyclesFor(@min(spu_remaining, cdrom.event_countdown), real_clock_frac)`, then `@min` with the timer terms, then `- cycles`. SIO and DMA terms unchanged. Update the module comment's rule list with one bullet: three devices count real cycles, converted at the hand-over, and their deadlines by the ceiling inverse.

- [ ] **Step 4: Implement `Bus`.** `bus.cpu_overclock = .{}` in `Bus.init` beside the default-on PGXP flags (with the memset reason). `setCpuOverclock(percent)`: `r = overclock.fromPercent(percent)`; return if equal to the current one; else `scheduler.sync(self)` (hands the backlog over at the OLD ratio and zeroes `downcount`), store `r`, zero both carries, mirror into the GPU (Task 3 adds the mirror line; leave a single call site for it). No block-cache flush.

- [ ] **Step 5: Run** `zig build test` (Debug: `assertInWindow` on) — Expected: PASS.

- [ ] **Step 6: Add the CLAUDE.md rule** under "Core subsystems": **The overclock converts in FRONT of 11/7, and only SPU, CD-ROM and GPU video timing take real cycles.** Timers on the system clock, SIO, DMA, MDEC and GPU drawing stay in CPU cycles; at 100% every conversion is the identity. Put the why (DuckStation's split, the two carries, the zero-real-cycle skip) in the `ps1-core-subsystems` skill.

- [ ] **Step 7: Commit** `feat(core): real clock for SPU, CD and video under a CPU overclock`

---

### Task 3: GPU drawing time in CPU cycles

**Files:**
- Modify: `ps1-core/src/gpu/gpu.zig` (`Gpu.clock`, `processFifoWord`, `writeGp0`)
- Modify: `ps1-core/src/memory.zig` (`setCpuOverclock` mirrors)
- Test: `ps1-core/tests/gpu_test.zig`

**Interfaces:**
- Consumes: `Ratio.drawCost`, `Ratio.stallCycles` (Task 1); `Bus.setCpuOverclock` (Task 2).
- Produces: `Gpu.clock: overclock.Ratio = .{}` — host configuration, NOT in the `GPU ` section (`loadGpu` is field-by-field and must stay so).

- [ ] **Step 1: Write the failing tests** in `gpu_test.zig`:
  - `"a draw costs the same CPU cycles at any overclock"`: a bare `Gpu` at `fromPercent(100)` and one at `fromPercent(200)`: write the same large fill (`GP0(02h)`, 1024x512) then 16 more words; the stall `writeGp0` returns at 200% is within 1 of the 100% stall (debt halves, `stallCycles` doubles back).
  - `"a draw at 200% drains in half the video cycles"`: after the fill, `cycle_debt` at 200% == `drawCost` of the 100% debt == ceil(debt/2).
  - `"Bus mirrors the ratio into the GPU"`: `bus.setCpuOverclock(150)` → `bus.gpu.clock == fromPercent(150)`.

- [ ] **Step 2: Run** `zig build test` — Expected: FAIL.

- [ ] **Step 3: Implement.** `processFifoWord`: `self.cycle_debt += @intCast(self.clock.drawCost(debt))`. `writeGp0`'s full-FIFO stall: `stall_cycles = self.clock.stallCycles(self.cycle_debt)` (comment: debt is real video cycles, the caller bills CPU cycles). `Bus.setCpuOverclock` sets `self.gpu.clock = r`.

- [ ] **Step 4: Run** `zig build test` — Expected: PASS.

- [ ] **Step 5: Commit** `feat(gpu): drawing time follows the CPU clock`

---

### Task 4: The carry in savestates

**Files:**
- Modify: `ps1-core/src/savestate/savestate.zig` (`Section.oldest`, the version check, `CPU ` -> 2)
- Modify: `ps1-core/src/savestate/cpu_state.zig`
- Test: `ps1-core/tests/savestate_test.zig`

**Interfaces:**
- Consumes: `Scheduler.real_clock_frac`, `Scheduler.gpu_real_frac`, `Bus.cpu_overclock` (Task 2).
- Produces: `Section.oldest: ?u32 = null` (null: only `version` loads); `CPU ` is `.version = 2, .oldest = 1`.

- [ ] **Step 1: Write the failing tests:**
  - `"an overclocked state round-trips its carry"`: machine at 150%, run until `real_clock_frac != 0` (sync first), save, load into a fresh `Bus` set to 150% BEFORE the load: both carries equal the saved value; save again: byte-identical.
  - `"a carry outside the current ratio loads as zero"`: save at 250% with carry 3 or 4, load into a fresh `Bus` at 150% (`num == 3`): both carries 0 if the saved carry `>= 3`.
  - `"a version-1 CPU section still loads"`: build a v1 state by writing today's layout (a test-local writer that omits the carry, or a committed v1 blob if `savestate_test.zig` already keeps one) and require `load` to succeed with both carries 0.
  - `"a version-3 CPU section is refused"`: `error.StateVersion`.

- [ ] **Step 2: Run** `zig build test` — Expected: FAIL.

- [ ] **Step 3: Implement.** `saveCpu` writes `real_clock_frac` right after `gpu_clock_frac`, with `std.debug.assert(real_clock_frac == gpu_real_frac)` (every save goes through `write`, which syncs). `loadCpu`: version 2 reads it, version 1 takes 0; a value `>= cpu.bus.cpu_overclock.num` becomes 0; `cpu.bus.sched = .{ .gpu_clock_frac = g, .real_clock_frac = r, .gpu_real_frac = r }`. Version check: refuse `version > s.version or version < (s.oldest orelse s.version)`. Update the `savestate.zig` module comment's sentence about bumps to name `oldest`.

- [ ] **Step 4: Run** `zig build test` — Expected: PASS.

- [ ] **Step 5: The 100% gate.** Run, all ReleaseFast, every one UNCHANGED (no capture):
  `zig build trace-golden -Doptimize=ReleaseFast -- verify` (also `--engine=cached`, `--engine=jit`, `--threaded=deferred`), `-- savestate`, `-- snapshot --engine=jit`, `-- stream-verify`, `-- pgxp`, `zig build trace-golden-metal -Doptimize=ReleaseFast -- gpu-verify`, `zig build test-roms-pl`, `zig build test-roms-ja -Doptimize=ReleaseFast` (12/17). Expected: every workload matches, floors hold. Any divergence stops the plan: it is a bug at 100%, not a recapture.

- [ ] **Step 6: Commit** `feat(savestate): CPU section carries the overclock carry`

---

### Task 5: C ABI handle and the per-game table

**Files:**
- Create: `ps1-core/src/resources/gen_cpu_overclock.py`, `ps1-core/src/resources/cpu_overclock.zon`, `ps1-core/src/resources/cpu_overclock.zig`
- Modify: `ps1-core/src/root.zig` (`pub const cpu_overclock = @import("resources/cpu_overclock.zig");`)
- Modify: `ps1-capi/include/ps1.h`, `ps1-capi/src/root.zig` (`HostSettings`, `ps1_load_state`, two exports)
- Test: `ps1-capi/src/capi_test.zig`, `ps1-core/tests/discid_test.zig` (beside the other table lookups)

**Interfaces:**
- Consumes: `Bus.setCpuOverclock`, `Ratio.percent` (Tasks 1-2).
- Produces:
  - `cpu_overclock.zig`: `pub const Row = struct { serial: []const u8, percent: u32 }`, `pub const entries: []const Row = @import("cpu_overclock.zon")`, `pub fn lookup(serial: []const u8) ?u32` (case-insensitive, as `vram_readbacks.needsDual`).
  - `ps1.h`: `void ps1_set_cpu_overclock(Ps1*, uint32_t percent);` (100 = off; clamped to 10..1000) and `uint8_t ps1_lookup_cpu_overclock(const char* serial, uint32_t* percent);` (1 and writes `percent` when listed, else 0 and leaves it).

- [ ] **Step 1: Write the generator** mirroring `gen_vram_readbacks.py` (same docstring shape, `python3 -I`, imports `entries, keys` from `gen_pgxp_presets`): keep every entry whose settings carry `cpuOverclockPercent`, one row per `keys(serial, codes)`, sorted, `.{ .serial = "...", .percent = N }`. Header lines as the readbacks table's.

- [ ] **Step 2: Generate** at the pinned commit:
  `curl -sSfLO https://raw.githubusercontent.com/stenzek/duckstation/4122fed9ad3e6e5c2ecf1516cd51675a5931623e/data/resources/gamedb.yaml` into the scratchpad, then `python3 -I ps1-core/src/resources/gen_cpu_overclock.py <scratch>/gamedb.yaml 4122fed9ad3e6e5c2ecf1516cd51675a5931623e > ps1-core/src/resources/cpu_overclock.zon`. Expected: rows for SLPS-02459 and SLES-00275 at 95 (plus any extra keys their `codes` lists name). Do not commit `gamedb.yaml`.

- [ ] **Step 3: Write the failing tests:**
  - core: `"the overclock table lists the two 95% underclocks"`: `lookup("SLES-00275") == 95`, `lookup("sles-00275") == 95`, `lookup("SLUS-00000") == null`, `lookup("") == null`.
  - capi: `"ps1_set_cpu_overclock clamps and reduces"`: 150 → `bus.cpu_overclock == {3,2}`; 0 → `{1,10}`; 100 → `{1,1}`.
  - capi: `"a state load keeps the overclock and its carry"`: handle at 150%, run frames until the carry is non-zero, save, `ps1_load_state`: the handle is still at 150% and both carries equal the saved one (fails today: `Bus.init` resets the ratio, and setting it after the load would zero the carry).
  - capi: `"a reset keeps the overclock"`: `ps1_reset` → still 150%.
  - capi: `"ps1_lookup_cpu_overclock reads the table"`.

- [ ] **Step 4: Run** `zig build test` — Expected: FAIL.

- [ ] **Step 5: Implement.** `HostSettings` gains `cpu_overclock: u32` (captured with `.percent()`, applied with `setCpuOverclock`). `ps1_load_state` sets the live percent on `fresh` BEFORE `savestate.load` (beside the engine, same reason: the load must land in a machine already at the handle's ratio, so `loadCpu` keeps the carry). The two exports; `ps1.h` comments in the file's style (the lookup's says a session folds the table itself, a bare handle's host folds it).

- [ ] **Step 6: Run** `zig build test` and `zig build capi-lib` — Expected: PASS; the `nm` check still passes.

- [ ] **Step 7: Commit** `feat(capi): ps1_set_cpu_overclock and the per-game overclock table`

---

### Task 6: The session

**Files:**
- Modify: `ps1-session/src/settings.zig`, `ps1-session/src/abi.zig`, `ps1-capi/include/ps1_session.h`, `ps1-session/src/controls.zig`, `ps1-session/src/session.zig` (`refold`), `ps1-session/src/frame_path.zig`, `ps1-session/src/machine.zig` (`HandleMachine` + `contract`), `ps1-session/tests/fake_machine.zig`
- Test: `ps1-session/tests/settings_test.zig`, `ps1-session/tests/abi_test.zig`

**Interfaces:**
- Consumes: `ps1_set_cpu_overclock`, `ps1_core.cpu_overclock.lookup` (Task 5).
- Produces:
  - `Settings.cpu_overclock: u32 = 100` (the player's percent; 100 is off).
  - `Folded.cpu_overclock: u32`; `fold` gains a `table: ?u32` parameter; `forSerial` passes `ps1_core.cpu_overclock.lookup(serial)` (null for an empty serial).
  - `Ps1SessionSettings.cpu_overclock: i32` appended LAST.
  - `Controls.cpu_overclock: Atomic(u32) = .init(100)`.
  - `HandleMachine.setCpuOverclock(self, percent: u32) void`; `"setCpuOverclock"` in `contract`; `FakeMachine.setCpuOverclock` logs it.

- [ ] **Step 1: Write the failing tests:**
  - settings: `"the overclock table applies only while the player's is off"`: player 100 + table 95 → 95; player 150 + table 95 → 150; player 100 + no row → 100. Independent of `use_presets` (the spec's rule is DuckStation's, which does not gate it).
  - abi: `"settingsOf maps the overclock"`: `cpu_overclock = 0` → 100, `95` → 95, `5000` → 1000, `-3` → 100.

- [ ] **Step 2: Run** `zig build test` — Expected: FAIL.

- [ ] **Step 3: Implement.** `settingsOf`: `<= 0` → 100, else `clamp(10, 1000)`. `refold`: `storeChanged(u32, &c.cpu_overclock, f.cpu_overclock)`. `frame_path`: `self.m.setCpuOverclock(c.cpu_overclock.load(.acquire))` beside `applyPgxp`, every frame (the core's setter is idempotent). `ps1_session.h`: the field with a comment (percent; 0 or 100 is off; the session folds the per-game table under it).

- [ ] **Step 4: Run** `zig build test` — Expected: PASS (38 binaries).

- [ ] **Step 5: Commit** `feat(session): CPU overclock setting and its per-game fold`

---

### Task 7: Harnesses and measurement

**Files:**
- Modify: `ps1-golden/src/main.zig` (option, mode, `runWorkload`, `saveAndRestore`, usage text)
- Modify: `ps1-trace/src/main.zig`, `ps1-bench/main.zig`
- Modify: `CLAUDE.md` (quick commands), `.claude/skills/ps1-test-harnesses/`

**Interfaces:**
- Consumes: `Bus.setCpuOverclock` (Task 2).
- Produces: `Options.overclock: u32 = 100`, `--overclock=<percent>`; `Mode.overclock_verify` (`overclock-verify`).

- [ ] **Step 1: Add `--overclock=`.** `runWorkload` calls `bus.setCpuOverclock(opts.overclock)` right after `boot.loadMachine`; `saveAndRestore` sets it on `fresh` BEFORE `savestate.load`. `capture`, `verify`, `savestate`, `snapshot` and `pgxp` refuse a value other than 100 with `error.BadArguments` (they compare against goldens or floors that exist only at 100); `lockstep` and `stream-verify` accept it.

- [ ] **Step 2: Add `overclock-verify`.** Per workload and per percent (`--overclock=` if given, else 150 and 250): run `runWorkload` three times with `mode` overridden to `.verify`, `.savestate`, `.snapshot`, and require every sample's hashes and `static_after` to match the plain run's, sample for sample; report the first diverging sample and hash name as `verify` does. Exit non-zero on any divergence. Takes `--engine`, `--threaded`, `--filter`.

- [ ] **Step 3: Run the gate.**
  `zig build trace-golden -Doptimize=ReleaseFast -- overclock-verify` and the same with `--engine=cached` and `--engine=jit`; `-- lockstep --engine=jit --overclock=250`; `-- stream-verify --overclock=250`. Expected: all pass. A divergence means a carry or deadline is wrong: fix it in Tasks 2-4's code, not here.

- [ ] **Step 4: `ps1-trace` and the bench.** Both take `overclock=<percent>` (positional-keyword style each already uses: see `fastboot` / `nocopy`), applied after boot.

- [ ] **Step 5: Measure.** Settle the machine first (not straight after `trace-golden`). `zig build -Doptimize=ReleaseFast`, then best of five of `zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin games/<g>/<g>.cue 3000 --engine=jit` on this commit and on `92b4f58` (a worktree): the 100% numbers must agree within noise. If 100% is measurably slower, the `isUnit` branches in `Ratio` are already there; look for a conversion outside them. Then report 100/200/400 on the same game. Put the numbers in the commit's spec "As built" note (append a short section to the spec) and the memory file.

- [ ] **Step 6: Docs.** CLAUDE.md: one line in the `trace-golden` rows for `--overclock=` and `overclock-verify`; skill: what `overclock-verify` proves and does not (no golden for an overclocked run, ever).

- [ ] **Step 7: Commit** `feat(harness): --overclock and the overclock-verify self-comparison`

---

### Task 8: The app

**Files:**
- Create: `ps1-macos/Sources/PS1/CpuOverclockSetting.swift`
- Modify: `ps1-macos/Sources/PS1/GameSession.swift` (`SessionSettings.cpuOverclock`, `.c`), `Settings/GeneralSettingsPane.swift` ("Processor" section), `Settings/SettingsCopy.swift`, the view model that builds `SessionSettings`, `BadgeStack.swift` / `GameHUD.swift`
- Test: `ps1-macos/Tests/PS1Tests/CpuOverclockSettingTests.swift`

**Interfaces:**
- Consumes: `Ps1SessionSettings.cpu_overclock` (Task 6).
- Produces: `struct CpuOverclockSetting { enabled: Bool; percent: Int; var effective: Int }` stored under `cpuOverclockEnabled` / `cpuOverclockPercent`, shaped like `RunaheadSetting` (injected `UserDefaults`, a stored value outside `choices` reads as the default); `choices = Array(stride(from: 10, through: 1000, by: 10))`, default off at 100. `effective` is 100 while disabled; `SessionSettings.c` sends it as `cpu_overclock`.

- [ ] **Step 1: Load `ps1-macos-app` and `apple-design-guidelines`.**

- [ ] **Step 2: Write the failing tests:** `CpuOverclockSetting` defaults (disabled, 100, effective 100); stored 155 or 2000 reads 100; enabled at 200 → effective 200; disabled at 200 → effective 100; `SessionSettings.c.cpu_overclock` carries `effective`; `size` equals `MemoryLayout<Ps1SessionSettings>.size`. Use per-test `UserDefaults(suiteName:)`, never `.standard` (hosted tests share the app's defaults).

- [ ] **Step 3: Run** `zig build capi-lib metallib && pkill -x Substation; ps1-macos/test.sh` — Expected: FAIL to compile.

- [ ] **Step 4: Implement.** Settings → General → "Processor": a "Clock Speed Control" toggle and, enabled only while it is on, a percentage control over `choices` (shape per the HIG skill; not a 100-row menu). `SettingsCopy` gets the copy and a `SettingInfo` line saying it runs the console's processor faster or slower while video and sound keep real time, and that higher values cost more Mac CPU. The HUD's badge row shows the effective percent (e.g. "CPU 200%") while it is not 100, beside the resolution/PGXP badges. The running session picks it up through the existing `setSettings` path.

- [ ] **Step 5: Run** `ps1-macos/test.sh` — Expected: PASS (699 + new). Then `zig build macos` builds.

- [ ] **Step 6: Commit** `feat(macos): Clock Speed Control setting and HUD badge`

---

## Done when

- Every gate in Task 4 Step 5 passes unchanged at 100%; Task 7 Step 3 passes at 150/250 under all three engines.
- Bench at 100% indistinguishable from `92b4f58`; 100/200/400 measured and written down.
- `zig build test`, `ps1-macos/test.sh`, `zig build macos` green.
- Memory `project-cpu-overclock.md` updated (done, hand check pending: an in-app run of a slowdown-prone game at 200%).
