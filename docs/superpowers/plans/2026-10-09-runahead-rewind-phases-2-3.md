# Runahead + Rewind, Phases 2 and 3: Rewind, PGXP Across a Mark, Runahead in the App: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship rewind (core ring + C ABI + a Hold to Rewind binding in the app) and runahead (PGXP surviving a return, the runner's speculative loop, and Metal speculation with a deferred restore), with both settings in Settings ▸ General.

**Architecture:** Rewind is a ring of reverse deltas over `saveTrusted` bytes, owned by the C ABI handle and captured inside `ps1_run_frame` every 2 frames. Runahead marks after the real frame, runs N speculative frames, and returns; the PGXP shadows ride in the `Mark` so a return leaves them as the real timeline had them. The app publishes speculative streams as a tagged group; `LiveRenderer` saves the region the group will touch, replays it for display, and restores that region at the start of the next drain, so between frames the texture is only ever the real timeline.

**Tech Stack:** Zig 0.17.0 (`ps1-core`, `ps1-capi`, `ps1-golden`, `ps1-bench`, `ps1-wasm`), TypeScript (`ps1-web` codes), Swift + Metal (`ps1-macos`).

**Spec:** `docs/superpowers/specs/2026-10-09-runahead-rewind-design.md` (Phases 2 and 3, Settings, Testing). Phase 1 is `docs/superpowers/plans/2026-10-09-runahead-rewind-phase1-snapshot.md`, landed.

**Decisions made here that the spec left open:**

1. **PGXP: CARRY, not invalidate.** The spec's success criterion 5 ("the `pgxp` sweep in snapshot mode shows no drop in its ratcheted counters") cannot hold if a return leaves the speculative frames' shadows behind, and invalidating them is the drop itself. So `Mark` also copies every PGXP shadow that is not in a state, but only while PGXP is on (with it off the shadows are never read and nothing is copied). The 83 MB vertex cache is the one exception: it is a lookup keyed and validated by the word, ships off, and copying it twice a frame would cost more than the rest of runahead. Rewind does NOT carry shadows: an entry would grow by 10.5 MB, and PGXP refills within a frame or two of the player letting go.
2. **The VRAM depth plane and `depth.State` ride in the PGXP part of the mark** while the depth buffer is on. Neither is in a state, and without them the software shadow (which a resync adopts) would depth-test the real frame against the speculative frames' depths.
3. **Speculative frames never capture rewind history.** `ps1_snapshot_mark` sets `Handle.speculating`, `ps1_snapshot_return` clears it, and `ps1_run_frame` skips the capture while it is set. No new ABI.
4. **A speculative group publishes its own `Ps1Display`.** A double-buffered game flips its display start every frame, so the speculative picture must be shown at the speculative display start. 24bpp (FMV) and the software display path keep the real frame's shadow: speculative frames publish no shadow.
5. **The rewind pad binding is a choice of None (default), L3 or R3.** The PS1 pad has no free button; while one is chosen it stops reaching the game.

## Global Constraints

- `zig version` is 0.17.0. `zig fmt` every touched `.zig` file before committing.
- Commit directly on `master`, one commit per task. Commit messages are a SINGLE title line: no body, no trailer, no Co-Authored-By. Never `git push`.
- Never name DuckStation (or any reference emulator) in code comments or commit messages.
- Match the surrounding style: inline field defaults, hand-written savestate sections, comments that state the rule and its reason, no thinking-out-loud.
- No savestate FORMAT change and no golden recapture.
- `trace-golden` and `ps1-bench` run `-Doptimize=ReleaseFast`.
- New C ABI codes take the next free value (`PS1_ERR_NO_HISTORY` = -17) and are mirrored in `ps1-wasm/src/codes.zig` and `ps1-web/src/errors.ts`.
- Both features ship OFF. Runahead values Off/1/2/3; Rewind On/Off; Rewind memory 128/256/512 MB (default 256); Hold to Rewind default Backspace (`kVK_Delete`, 51).
- Swift: `pkill -x Substation` before `ps1-macos/test.sh`; it needs `zig build capi-lib metallib` first.

## Review Focus

1. **A rewind step with an empty history** must leave the machine bit-identical and return `PS1_ERR_NO_HISTORY`. Pinned in Task 3.
2. **Rewind across a disc swap, a state load or a reset** must not cross it: the history is cleared by each. Pinned in Task 3.
3. **Runahead with rewind on**: the speculative frames must not capture history, or rewinding walks through futures that never happened. Pinned in Task 3.
4. **A resync arriving while a speculative restore is pending** must drop the restore, not apply stale pixels over the freshly adopted shadow. Pinned in Task 6.
5. **Speculative audio** must never reach the ring, and the pad status shown must be the real frame's. Pinned in Task 7.

---

### Task 1: PGXP shadows ride in the mark

**Files:**
- Create: `ps1-core/src/savestate/pgxp_mark.zig`
- Modify: `ps1-core/src/savestate/mark.zig`
- Test: `ps1-core/tests/savestate_test.zig` (append)

**Interfaces:**
- Produces: `pub const PgxpShadows = struct { pub fn init(std.mem.Allocator) PgxpShadows; deinit; take(*PgxpShadows, *const Cpu) !void; restore(*const PgxpShadows, *Cpu) void; }`. `take` copies only while `bus.pgxp_enabled`; otherwise it records that it holds nothing. `restore` writes back only what it holds and only while PGXP is still on.
- Copied: `bus.ram_shadow`, `bus.scratch_shadow`, `bus.pgxp_pending`, `cpu.gpr_shadow`, `load_shadow`, `delay_shadow`, `hi_shadow`, `lo_shadow`, `cop0_shadow`, `cpu.cop2.precise`, `bus.gpu.fifo_pgxp`, `bus.gpu.gp0.cmd_buffer_pgxp`, `bus.gpu.gp0.weld`, the block cache's `pins.load_shadows`; and, while `bus.pgxpDepthBuffer()`, `bus.gpu.gp0.depth_state` and `bus.gpu.vram.depth`.
- `Mark.take` calls `shadows.take` after `saveTrusted` (which already drained the worker); `Mark.restore` calls `loadTrusted` and then `shadows.restore` after a `syncRaster`.

- [ ] Step 1: failing test `"a return keeps the PGXP shadows the mark was taken with"`: machine with PGXP on, write a known `Value` into `ram_shadow[100]`, `gpr_shadow[5]`, `cop2.precise[12]`; take a mark; overwrite all three; restore; expect the originals. Plus `"a mark taken with PGXP off copies no shadow"`: PGXP off, take, turn PGXP on, write a shadow, restore, the written shadow survives.
- [ ] Step 2: run `zig build test -Dtest-filter="PGXP shadows"`, expect FAIL.
- [ ] Step 3: implement `pgxp_mark.zig` and wire it into `Mark`.
- [ ] Step 4: tests pass.
- [ ] Step 5: `zig build -Doptimize=ReleaseFast trace-golden -- pgxp --snapshot`: every pass at or above its floor (it was 14 of 18 below). Then `trace-golden -- snapshot` stays 9/9.
- [ ] Step 6: commit `feat(savestate): the runahead mark carries the PGXP shadows`.

### Task 2: The rewind ring (core)

**Files:**
- Create: `ps1-core/src/savestate/rewind.zig`
- Modify: `ps1-core/src/savestate/savestate.zig` (`pub const Rewind = @import("rewind.zig").Rewind;`)
- Create: `ps1-core/tests/rewind_test.zig`; add it to `unit_test_files` in `build.zig`.

**Interfaces:**
- Produces:
  - `pub const word = 8;` and `pub fn encode(newer: []const u8, older: []const u8, out: *std.ArrayList(u8), a) !void` / `pub fn apply(delta: []const u8, buf: []u8) void` over equal-length, 8-aligned buffers; a delta is runs of `(offset u32, count u32, count*8 older bytes)`.
  - `pub const Rewind = struct { pub fn init(a) Rewind; deinit; configure(*Rewind, budget: usize) !void (0 = off, frees all); clear(*Rewind) void; enabled(*const Rewind) bool; frameDone(*Rewind, *const Cpu) !void (counts frames, captures every `capture_interval` = 2); step(*Rewind, *Cpu) Error!void (error.NoHistory when empty); info(*const Rewind) Info }` with `Info = struct { entries: u32, frames_covered: u32, bytes_used: usize }`.
  - Budget = sum of entry bytes + the two buffers' capacities; over budget the OLDEST entry is freed.
- [ ] Step 1: tests in `rewind_test.zig`: encode/apply round trip on synthetic buffers (equal; all different; first word only; last word only; alternating words); eviction (budget for K entries keeps the newest K and `bytes_used <= budget`); `step` on empty is `error.NoHistory` and leaves the machine's `saveTrusted` bytes identical; capture/step on a real machine (BIOS-less `Machine` test helper, run steps between) returns to the earlier snapshot exactly (compare `saveTrusted` bytes); `clear` empties the history.
- [ ] Step 2: run, expect FAIL (no file).
- [ ] Step 3: implement.
- [ ] Step 4: pass.
- [ ] Step 5: commit `feat(savestate): a rewind ring of reverse deltas over trusted snapshots`.

### Task 3: Rewind in the C ABI, wasm codes, bench

**Files:**
- Modify: `ps1-capi/src/root.zig`, `ps1-capi/include/ps1.h`, `ps1-capi/src/capi_test.zig`
- Modify: `ps1-wasm/src/codes.zig`, `ps1-web/src/errors.ts`
- Modify: `ps1-bench/main.zig` (`--rewind[=MB]`)

**Interfaces:**
- Produces (C): `PS1_ERR_NO_HISTORY (-17)`; `int32_t ps1_rewind_configure(Ps1*, size_t budget_bytes)`; `int32_t ps1_rewind_step(Ps1*)`; `typedef struct { uint32_t entries; uint32_t frames_covered; size_t bytes_used; } Ps1RewindInfo;` `void ps1_rewind_info(Ps1*, Ps1RewindInfo*)`.
- `Handle` gains `rewind: ps1.savestate.Rewind` and `speculating: bool`. `ps1_run_frame` = internal `runFrame(h)` + `if (!h.speculating) h.rewind.frameDone(&h.cpu)`. `ps1_rewind_step`: `step`, forget the mark, run one frame without capture, discard its audio (`spu.read_idx = spu.write_idx`). `ps1_reset`, `ps1_load_state`, `ps1_load_disc`, `ps1_swap_disc`, `ps1_load_bios` call `h.rewind.clear()`. `ps1_snapshot_mark` sets `speculating`, `ps1_snapshot_return` clears it.
- [ ] Step 1: capi tests: configure+run 10 frames gives entries 5 and frames_covered 10; step on empty returns NO_HISTORY and the save-state bytes are unchanged; step rewinds (save state after step equals a state captured earlier... compare `ps1_save_state` taken at frame 4 against the machine after stepping back to it and NOT running? Since the step runs one frame, compare to the state saved at frame 5 instead); reset/load_state/swap clear the history; frames run between mark and return capture nothing.
- [ ] Step 2: FAIL. Step 3: implement. Step 4: pass (`zig build test -Dtest-filter=rewind`).
- [ ] Step 5: `ps1-bench --rewind` measures capture cost and the 256 MB coverage on Crash Warped (criterion 4: at least 20 s).
- [ ] Step 6: commit `feat(capi): rewind configure, step and info`.

### Task 4: Rewind in the app

**Files:**
- Modify: `ps1-macos/Sources/PS1/Ps1Core.swift` (rewind wrappers), `EmulatorRunner.swift` (`setRewindBudget`, `setRewinding`, the loop branch, `rewindSeconds`), `EmulatorViewModel.swift` (settings, hold handling, HUD value), `InputMap.swift` (`PadControl.rewind`), `KeyBindings.swift` (default Backspace, stored as `"rewind"`), `Settings/ControlsSettingsPane.swift`, `Settings/GeneralSettingsPane.swift`, `Settings/SettingsCopy.swift`, `GameHUD.swift` (seconds left while rewinding)
- Create: `ps1-macos/Sources/PS1/RewindSetting.swift` (`RewindSetting`: enabled, memory MB, pad button; `object(forKey:)` probes)
- Test: `ps1-macos/Tests/PS1Tests/RewindSettingTests.swift`, `KeyBindingsTests.swift` (rewind default + move rule)

**Interfaces:**
- Runner: `func setRewindBudget(_ bytes: Int)` (applied on change in `runLoop`), `func setRewinding(_ held: Bool)`, `var rewindInfo: RewindInfo` (atomic, published per loop). While held: `core.rewindStep()` instead of `runFrame`, no audio written, VRAM + stream published as usual, `requestResync()` after each step, and pacing by a 1/30 s wait instead of the audio ring (the ring is not being refilled).
- [ ] Step 1: tests for `RewindSetting` defaults (off, 256, none), persistence, and `KeyBindings` default `.rewind` = 51 and that assigning Backspace to a button unbinds rewind.
- [ ] Step 2: FAIL. Step 3: implement. Step 4: `ps1-macos/test.sh` passes.
- [ ] Step 5: commit `feat(macos): hold to rewind`.

### Task 5: Speculative groups in the stream queue

**Files:**
- Modify: `ps1-macos/Sources/PS1/StreamQueue.swift`
- Test: `ps1-macos/Tests/PS1Tests/StreamQueueTests.swift`

**Interfaces:**
- `StreamSlot` gains `speculative: Bool`, `group: UInt64`, `display: Ps1Display`.
- `StreamQueue.capacity = 3 * (1 + RunaheadSetting.maxFrames)` = 12. `publish(..., speculative: Bool = false, group: UInt64 = 0, display: Ps1Display = Ps1Display())`.
- `isFull` stays measured in REAL frames: the backpressure counts `realPendingCount >= 3`.
- `drainGroups(real: (StreamSlot) -> Void, speculative: ([StreamSlot]) -> Void)`: real slots in order; each speculative group followed by a real slot in the same drain is skipped; the last group, if it is the tail, is handed over whole.
- `discardThrough(seq:)` also drops speculative slots it passes.
- [ ] Step 1: tests: a group followed by a real frame is skipped; a trailing group is handed over in order; capacity 12; backpressure counts only real slots.
- [ ] Step 2-4: FAIL, implement, pass.
- [ ] Step 5: commit `feat(macos): the stream queue carries speculative groups`.

### Task 6: Metal speculation with a deferred restore

**Files:**
- Modify: `ps1-macos/Sources/PS1/LiveRenderer.swift`, `MetalVram.swift` (save/restore a native rect of colour, sidecar and, when persistent, depth), `MetalRasterizer.swift` (snapshot/restore of `env` + `transfer`)
- Create: `ps1-macos/Sources/PS1/SpeculativeRegion.swift` (union of the rects a group writes: primitives clip to the drawing area tracked through the group's own `set_draw_env` records, fill/upload/copy use their explicit rect)
- Test: `ps1-macos/Tests/PS1Tests/SpeculationTests.swift` (the Metal speculation gate: replay a `.p1fx` with the next frames injected as a speculative group after every frame; the real-timeline texture must hash identically to a plain replay), `SpeculativeRegionTests.swift`

**Interfaces:**
- `LiveRenderer.drain` starts by applying a pending restore (unless a resync is due: then the restore is dropped), executes real slots, then for the trailing group: computes the region, saves it, snapshots rasterizer CPU state, executes the group, restores the CPU state immediately and marks the GPU restore pending. `presentDisplay: Ps1Display?` is the trailing group's display, read by `MetalDisplayView` instead of the shadow's display when set.
- [ ] Step 1: region unit tests; the fixture speculation gate.
- [ ] Step 2-4: FAIL, implement, pass.
- [ ] Step 5: commit `feat(macos): replay speculative frames over a region restored next drain`.

### Task 7: Runahead in the runner, the setting, the docs

**Files:**
- Modify: `ps1-macos/Sources/PS1/EmulatorRunner.swift`, `Ps1Core.swift` (`snapshotMark`, `snapshotReturn`), `EmulatorViewModel.swift`, `Settings/GeneralSettingsPane.swift`, `Settings/SettingsCopy.swift`, `MetalDisplayView.swift`
- Create: `ps1-macos/Sources/PS1/RunaheadSetting.swift`
- Test: `ps1-macos/Tests/PS1Tests/RunaheadSettingTests.swift`; a runner test that `runSpeculation` writes no audio to the ring and publishes the real pad status (driven through an `internal` seam with a fake core closure).
- Docs: `CLAUDE.md` (two rules), `.claude/skills/ps1-core-subsystems/SKILL.md`, `ps1-gpu-metal/SKILL.md`, `ps1-macos-app/SKILL.md`, the spec's status line.

**Interfaces:**
- Runner: `setRunahead(_ n: Int)`. Loop after the real frame, when `n > 0 && speed == 1 && !rewinding`: drain audio already done; `core.snapshotMark()`; N × (`runFrame`, read-and-discard audio, publish stream as speculative group `g` with `core.display()`); `core.snapshotReturn()`; `g += 1`.
- [ ] Step 1: setting tests. Step 2-4: FAIL, implement, pass.
- [ ] Step 5: `ps1-bench` best-of-5 at N=2 (criterion 2) with PGXP off and on, recorded in the skill.
- [ ] Step 6: commit `feat(macos): runahead`, then `docs: runahead and rewind` .
