# Threaded software rasterizer — design

## Goal

Take the software rasterizer off the emulator thread in the macOS app, so the
time it costs (~15% of the emulator thread, measured 2026-10-01 with xctrace on
Croc and Spyro) overlaps with emulation on a second core instead of adding to
it. The app's speed-up ceiling on an M1 MacBook Air is the motivation.

The software VRAM is not optional under `gpu_sink = .dual`: the resync, the
24bpp scanout, `PS1_LIVE_DIFF` and the game's own VRAM->CPU reads all read it.
So the rasterizer moves, it does not go away, and **its output must stay
bit-exact** with today's.

## Success criteria

1. `zig build trace-golden -- verify` passes on every workload, goldens
   untouched, with the worker OFF (the shipped default for every frontend but
   `ps1-capi`).
2. A new `verify --threaded` passes on every workload against the SAME committed
   goldens with the worker ON. That is the gate for the feature: threaded
   output equals unthreaded output, hash for hash.
3. An interleaved A/B with `ps1-bench-dual ... threaded` shows a gain. The size
   is reported as measured; there is no target number.
4. `zig build test`, `test-roms-ja` (12/17) and the Swift suite unchanged.

## Non-goals

- No change to the Metal path, the recorder, the stream ABI or anything in
  `ps1-macos` beyond what `ps1-capi` does on its own.
- No frame pipelining (worker a frame behind). The worker is drained at every
  frame boundary.
- Not available in the wasm build (`builtin.single_threaded`), and not turned
  on by `ps1-debug`, `ps1-trace`, the ROM suites or plain `ps1-golden`.

## What the emulator thread shares with the rasterizer today

`command.execute` is the one function that turns a record into an effect, and
it does three different kinds of thing:

| Effect | Read by the emulator thread? |
|---|---|
| Pixels: `vram.data`, `vram.depth` (draws, fill, copy, upload words, `clear_depth`) | Rarely: GPUREAD, the per-frame `ps1_copy_vram`/`ps1_copy_depth`, ps1-golden's hashes and fixture capture |
| `DrawingEnv` (`set_draw_env`, `latch_texpage`, `set_texture_disable_allowed`, `reset_draw_env`) | Constantly: GPUSTAT bits 0-12/15, GP1(10h) info reads, and `gp0`'s own decode |
| The transfer state machines in `Vram` (`write_active`, `read_active` and their counters) | Every GP0 word: `gp0.write` tests `vram.write_active`, `Gpu.processFifoWord` tests `vram.read_active`; GPUSTAT bit 27 tests `read_active` |

Drawing never writes `DrawingEnv` — only the four env kinds above do (checked:
every renderer entry point takes `*const DrawingEnv`).

## Design

### 1. A transfer mirror the emulator thread owns — in BOTH modes

New `gpu/transfer.zig`: a small struct with the two counters the control
decisions need, updated by `Sink` at exactly the points the records are made:

- `vramWriteSetup(w, h)`: `write_words = (W*H + 1) / 2` with `W`/`H` taken
  through the same zero-means-whole-axis rule `Vram.axisExtent` applies.
- `vramWriteData`: decrement while non-zero.
- `vramWriteAbort`: zero.
- `vramReadSetup(w, h)`: `read_words = (W*H + 1) / 2`.
- a GPUREAD word: decrement while non-zero.

`writeActive()` is `write_words > 0`, `readActive()` is `read_words > 0`.

`gp0.write`, `Gpu.processFifoWord` and `Gpu.vramReadPending` read the mirror
instead of `vram.write_active` / `vram.read_active`, **with the worker off as
well as on**. One source of truth for control decisions in both modes is what
makes criterion 1 meaningful: the existing goldens then verify the mirror
itself, not a code path the shipped app does not run. `Vram` keeps its own
fields — `command.execute` and replay still need them to place pixels, and
`state_hash.zig` hashes them — and in safety builds the mirror is asserted
equal to them wherever the two are both settled.

The mirror is not a new savestate field. Its counters are in the same unit as
`Vram.write_remaining` / `read_remaining` (words), so `loadGpu` sets them from
the restored fields; the GPU section's format and version do not change. Left
at zero instead, a state saved mid-upload would resume with `gp0` decoding the
remaining payload as commands.

### 2. `RasterWorker` — `gpu/worker.zig`

A single-producer/single-consumer ring of `command.Command` (120 bytes,
`@sizeOf` pinned) plus a `u32` payload ring for upload words, and one thread.

- **Producer (emulator thread).** `Sink.submit` and `Sink.vramWriteData`, when
  a worker is attached, enqueue instead of executing. Consecutive upload words
  are coalesced into one `vram_write_data` entry over a payload range, the way
  the recorder already coalesces them; the run is closed by any other command
  or a sync. The env kinds are ALSO executed immediately against
  `Gpu.draw_env`, so everything the emulator thread reads stays current. The
  recorder push is unchanged and still happens first.
- **Consumer (worker thread).** Pops entries in order and runs the existing
  `command.execute(cmd, payload, &gpu.vram, &worker_env)`. `worker_env` is the
  worker's own `DrawingEnv`, copied from `Gpu.draw_env` when the worker is
  attached; applying the same env records in the same order keeps it equal to
  what `Gpu.draw_env` was at every record. No new rendering code exists.
- **Full ring.** The producer waits for space. Capacity is sized off
  `stream-verify`'s printed per-frame peaks so a normal frame never waits.
- **Blocking.** Spin briefly, then `Io.futexWaitUncancelable` on the published
  index; the other side `futexWake`s only when the waiter has said it is
  sleeping. The `Io` comes from the frontend, as Zig 0.17 expects of library
  code (`std.Io.futexWaitUncancelable` / `std.Io.futexWake`); the thread is a
  plain `std.Thread.spawn`. `ps1-capi` has no `main` and so no `init.io`: it
  owns a `std.Io.Threaded` on its `Handle` and passes `.io()`. `ps1-golden`
  and `ps1-bench` pass their `init.io`. An idle worker sleeps; it never spins
  at 100% between frames.

### 3. Sync points — `Gpu.syncRaster()`

Blocks until the worker has executed everything queued. Called, and only
called, where the emulator side touches what the worker owns:

- `Gpu.readData` while a VRAM read is pending (GPUREAD, CPU or DMA).
- `ps1_copy_vram`, `ps1_copy_depth` (the per-frame copy `EmulatorRunner`
  makes).
- `ps1_save_state`, before `savestate.save`: the GPU section writes
  `vram.data` and every `Vram` transfer field, and a state taken with draws
  still queued would hold a half-drawn frame and the wrong transfer cursors.
  `ps1_save_state_size` needs no sync; the size does not depend on what the
  pixels are.
- `ps1_load_state`, which replaces `Bus` (section 4).
- Detaching the worker: `ps1_destroy`, and around `ps1_reset`'s rebuild,
  which frees `Bus` and allocates a fresh one.
- ps1-golden, before every hash and fixture write in threaded mode, and
  before `savestate`'s midpoint save.

Nothing else reads `vram.data`, `vram.depth` or the `Vram` transfer fields on
the emulator thread once section 1 lands; the plan's first task re-checks that
list with grep before anything is threaded.

### 4. Lifecycle and opt-in

`Gpu.attachRasterWorker(allocator, io)` / `detachRasterWorker()`. The ring
is heap-allocated on attach, so a `Bus` that never attaches does not grow.
`ps1-capi` attaches in `buildMachine` (so a reset re-attaches after the
rebuild) and detaches before the rebuild and in `ps1_destroy`.

`ps1_load_state` decodes into a scratch `Bus` and swaps it in only on
success, so the worker follows the swap rather than the decode: nothing is
attached to the scratch `Bus` while it loads, a refused state leaves the
running machine's worker exactly as it was, and on success the worker is
detached from the old `Bus` (draining it) before `h.bus.deinit` and attached
to the new one after the swap. Attaching after the load is what makes
`worker_env` a copy of the RESTORED `draw_env`. Everything is compiled out
under `builtin.single_threaded`.

## Testing

- **Unit (`gpu_test.zig`):** the mirror agrees with `Vram`'s own fields over
  upload, abort and GPUREAD sequences, including the zero-means-whole-axis
  case; a threaded `Gpu` and an unthreaded one fed the same GP0 words end with
  identical VRAM, depth and env; GPUREAD on a threaded `Gpu` returns the pixels
  of draws still queued ahead of it.
- **Unit (`capi_test.zig`):** a state saved from a threaded handle with draws
  still queued is byte-identical to one saved unthreaded at the same point;
  loading a state into a threaded handle and running a frame matches the
  unthreaded run, including a state saved mid-upload (the mirror rebuild).
- **Golden:** `verify` (criterion 1), the new `verify --threaded`
  (criterion 2), and `savestate --threaded`.
- **Proof the gate can fail:** with the sync in `readData` removed,
  `verify --threaded` or the GPUREAD unit test must go red; with the env kinds
  not applied on the emulator side, the GPUSTAT-dependent workloads must
  diverge.
- **Bench:** `ps1-bench-dual ... threaded`, interleaved against unthreaded.

## Risks

- **A missed emulator-side reader is a data race, not a wrong pixel.** It may
  pass every gate by luck of timing. Mitigation: section 1 removes the two
  per-word readers in both modes, and the plan greps every remaining
  `gpu.vram` access before threading is switched on.
- **Thermals on a fanless machine.** A second busy core can lower the clock
  of the first; the bench measures the net, and the gain may be smaller than
  the 15% the profile attributes to rasterizing.
- **`Gpu` lives inside `Bus`, which `ps1_reset` frees and `ps1_load_state`
  replaces.** The worker holds a pointer into it, so it must be detached
  before either frees the old `Bus`: the lifecycle above.

## Prior art: DuckStation

DuckStation's video thread has the same shape (checked against
`duckstation_ref/src/core/`, `gpu_use_thread` on by default): the CPU thread
turns GP0 words into command records and queues them, and the renderer,
including the software one, runs on the video thread. It waits for that
thread only where something reads VRAM: a game's VRAM->CPU transfer, a
savestate (`GPU::DoState`), and VRAM and GPU dumps. Those are this spec's sync
points.

Where this spec differs:

- **Two renderers, not one.** The worker carries only the software copy.
  Metal already runs off the emulator thread.
- **Its wait spins, ours sleeps.** It spins until the video thread catches up.
  We spin briefly and then sleep on a futex, which matters more on a fanless
  machine.
- **Neither saves CPU.** The work moves to another core. Frame time and
  fast-forward headroom improve; the total CPU in Activity Monitor does not.
