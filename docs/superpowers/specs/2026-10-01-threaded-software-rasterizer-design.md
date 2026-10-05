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
  `ps1_save_state_size` syncs too: the size cannot change, but its counting
  pass still reads the transfer fields the worker writes.
- `ps1_load_state`, which replaces `Bus` (section 4).
- Detaching the worker: `ps1_destroy`, and around `ps1_reset`'s rebuild,
  which frees `Bus` and allocates a fresh one.
- ps1-golden, before every hash and fixture write in threaded mode, and
  before `savestate`'s midpoint save.

A `.deferred` worker mode runs no thread at all: records queue until a sync
or a full ring drains them on the caller's thread. A missing sync point then
reads stale VRAM on every run, so `verify --threaded=deferred` and the unit
tests can fail deterministically rather than by luck of timing.

Nothing else reads `vram.data`, `vram.depth` or the `Vram` transfer fields on
the emulator thread once section 1 lands; the plan's first task re-checks that
list with grep before anything is threaded.

### 4. Lifecycle and opt-in

`Gpu.attachRasterWorker(allocator, io)` / `detachRasterWorker()`. The ring
is heap-allocated on attach, so a `Bus` that never attaches does not grow.
`ps1-capi` attaches in `buildMachine` (so a reset re-attaches after the
rebuild). `Bus.deinit` detaches, so every path that frees a `Bus`
(`ps1_destroy`, the rebuild, a replaced machine, the harness, the tests)
drains and stops the worker without having to remember to.

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

## As built (2026-10-05)

Commits: `174e041` (the transfer mirror), `8283c9a` (`RasterWorker`),
`ac37d1b` (`ps1-golden`'s `--threaded`), `146a720` (the worker on the C ABI
handle).

- **The two additions the plan made.** A `.deferred` worker mode, which
  queues every record until a sync, so a reader that forgot to sync reads a
  stale VRAM on every run instead of on a lucky one: it is what makes
  `verify --threaded=deferred` a gate. And `Bus.deinit` detaching the worker,
  so no thread outlives the memory it rasterizes into.
- **`ps1_save_state_size` syncs too.** Its counting pass reads the transfer
  fields, which is a race without the sync even though the size cannot change.
- **Ring sizes.** The record ring is the file-scope `record_slots = 16_384`
  in `gpu/worker.zig` (`RasterWorker.ring_records` aliases it), the payload
  ring is `ring_payload = 262_144` words (one whole-VRAM upload), and a
  consumer run is at most `max_run = 4096` upload words (one published run). They come from the
  `stream-verify` peaks measured 2026-10-05, records / payload words:
  bios-only 236 / 8,528; crash-europe 3,711 / 21,696; crash-warped
  3,289 / 16,384; crash2 2,914 / 16,384; resident-evil 288 / 57,600;
  croc 2,085 / 38,400; silent-hill 2,647 / 49,920; tr1 1,345 / 106,496;
  spyro 2,208 / 131,072. The record peak (3,711) is far under the ring, so no
  resize was needed.
- **Gates.** `verify` and `savestate`, each with `--threaded` and
  `--threaded=deferred`, pass on all nine workloads against untouched goldens.
  Deleting the hash sync, or the `applyEnv` line, makes
  `verify --threaded=deferred --filter=croc` diverge. `zig build test` passes
  and so does the Swift suite (552 tests).
- **The bench.** Apple M1, 2026-10-05, `ps1-bench-dual ... 3000 --engine=jit`,
  `-Doptimize=ReleaseFast`, five interleaved pairs after the machine settled,
  best of five per side, the per-frame `syncRaster` included on both:

  | Game  | inline fps | threaded fps | change |
  | ----- | ---------- | ------------ | ------ |
  | Croc  | 641.0      | 698.1        | +8.9%  |
  | Spyro | 480.7      | 572.7        | +19.1% |

  The gain is real but below the raster share of a frame, and the threaded
  side degrades across a session on Spyro (572.7 down to 458.7 by the fifth
  pair), while the inline side fell only about 3% in the same pair. The cause
  is unverified: thermal drift on a fanless machine, or the per-record futex
  wakeups (`space.notify` after every record in `executeNext`, `work.notify`
  in `publish`, with `spins` never reset after a wake). An A/B once the notify
  follow-up is done will settle it. While the producer sleeps in `sync`, a
  drain can cost a futex wake per record, which makes the notify follow-up
  the first candidate if the threaded number needs to rise further.
