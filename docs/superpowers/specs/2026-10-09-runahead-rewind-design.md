# Runahead and rewind

Status: Phase 1 implemented 2026-10-09; Phases 2 and 3 not started

## Goal

Two features built on one fast, in-place snapshot path:

- **Runahead** removes the game's own input lag in the macOS app: each
  displayed frame is N frames (1 to 3) in the future of the real timeline, so
  a press shows up N frames sooner. Upscaling, true colour, PGXP and the JIT
  all keep working.
- **Rewind**: holding a key plays the game backwards smoothly over as much
  recent history as a memory budget holds. The history lives in the core, so
  every frontend can use it.

Success is:

1. `trace-golden -- snapshot` (new) matches the existing goldens bit for bit
   under all three engines: a mark/return round trip changes nothing.
2. Runahead at N=2 holds full speed on the M1 for Crash Warped, Spyro and
   Silent Hill at the scales the app ships, measured through `ps1-bench`.
3. The Metal speculation gate: a fixture replayed with a speculative group
   injected after every frame leaves the real-timeline texture hashing
   identically to a plain replay.
4. Rewind at the default 256 MB budget covers at least 20 s of Crash Warped
   gameplay, captured every 2 frames.
5. The `pgxp` sweep in snapshot mode shows no drop in its ratcheted counters:
   PGXP survives in-place loads.

Both features ship **off**.

Non-goals: runahead in `ps1-web` (the core pieces are there, the loop is not
written in TypeScript), reversed audio while rewinding (it is silent),
per-game settings, a second-instance runahead mode, netplay.

## What exists today, measured

Measured 2026-10-09 on the M1, ReleaseFast, `ps1-bench-dual --engine=jit`,
games at frame 2400, using a throwaway probe:

| | Crash Warped | Spyro | Silent Hill |
| --- | --- | --- | --- |
| Frame | 2.1-2.3 ms | 3.1-3.3 ms | 2.1 ms |
| `savestate.save` | 1.2 ms | 1.2 ms | 1.3 ms |
| `savestate.load` in place | 1.5 ms | 1.5 ms | 1.9 ms |
| `ps1_load_state`-style load (fresh `Bus` + engine) | 5.3-5.8 ms | 7.6 ms | 6.6 ms |
| Runahead=1 through today's path | 1.66x realtime | 1.40x | 2.15x |

These follow `37b0064` (the state CRC on arm64 `crc32x`); before it, save and
load were 18 ms each, 97% of it `std.hash.Crc32`. What remains:

- The state is 6.9 MB: `BUS ` 4.2 MB (RAM plus the 2 MB `expansion_3`), `GPU `
  1 MB, `SPU ` 789 KB, `MDEC` 788 KB. All ten sections serialize in ~190 us.
- `identityOf` hashes the BIOS with SHA-256 on every save: ~250 us.
- `savestate.load` calls `BlockCache.flush()`. The same replayed frame costs
  1015 us after a flush against 649 us with the cache kept: ~370 us per load.
- `ps1_load_state` decodes into a scratch `Bus` and swaps it in, so the JIT
  cache, the raster worker and every PGXP shadow are rebuilt from nothing.
  That is right for a slot file and wrong 60 times a second.

How much a state changes between snapshots (60 samples each, compared as
8-byte words):

| Gap | Crash Warped | Spyro | Silent Hill |
| --- | --- | --- | --- |
| 1 frame | 91 KB | 141 KB | 136 KB |
| 2 frames | 238 KB | 235 KB | 274 KB |
| 8 frames | 231 KB | 170 KB | 1000 KB |

About half of every state is zero words; comparing two states takes ~0.7 ms
with a naive scan.

The app (`EmulatorRunner.runLoop`) is paced by the audio ring and, second, by
the stream queue. A slot load already goes through `requestResync()`: the
Metal texture adopts the core's native VRAM shadow and then draws on at
scale.

## Architecture

Three phases, each shippable on its own.

### Phase 1: the trusted snapshot (core + C ABI)

**`savestate.saveTrusted` / `savestate.loadTrusted`** use the existing
section layout, so there is one serializer:

- `saveTrusted` writes the CRC and both identity fields as zero: `loadTrusted`
  checks neither, so there is nothing to cache or invalidate. `save` keeps
  computing both.
- `loadTrusted` skips the CRC and the identity comparison and keeps every
  per-section range check. It writes into the running `Bus`: no scratch
  `Bus`, so the JIT cache, the raster worker (synced first), the memory cards
  and the PGXP shadow tables all survive. A PGXP shadow left over from the
  future is judged by the word it was recorded against, as every shadow is.
- **Incremental JIT invalidation.** Neither load path calls
  `BlockCache.flush()` any more. The `BUS ` loader compares the incoming RAM
  with the current RAM page by page (`block.page_shift`) and calls the
  existing `invalidatePage` for each page that differs and holds code
  (`hasBit`). BIOS blocks are untouched: the BIOS never changes. The I-cache
  lines are restored and `icache_dirty` set exactly as today. For `load`
  (scratch `Bus`, fresh cache) the comparison finds no code and costs only
  the compare.
- The trusted path is for bytes this process produced moments ago. It is
  never exposed for bytes from a file.

**The mark slot.** `Handle` owns one preallocated buffer for runahead:

```c
int32_t ps1_snapshot_mark(Ps1*);    /* saveTrusted + both cards + dirty flags */
int32_t ps1_snapshot_return(Ps1*);  /* loadTrusted + cards + dirty flags back */
```

`ps1_snapshot_return` without a mark returns `PS1_ERR_NO_SNAPSHOT`. The cards
ride in the mark slot, not in the state (they stay out of every state): a
save made during a speculative frame must not reach the card a frame early,
or be flushed to disk. Settings that live on `Bus` but outside a state (PGXP
switches, engine, dither) are untouched, because the load is in place.

`PS1_ERR_NO_SNAPSHOT` and `PS1_ERR_NO_HISTORY` (Phase 2) are new codes in
`ps1.h`; `ps1-wasm`'s `codes.zig` and `ps1-web/src/errors.ts` take the same
values, as every code does.

**Harness.** `ps1-golden` gains `snapshot`: like `savestate`, but at every
frame boundary it marks, runs one frame, returns and runs the same frame
again, then carries on. The final machine must match the golden. It takes
`--engine` and runs `-Doptimize=ReleaseFast`. The `pgxp` sweep takes
`--snapshot` to do the same with PGXP on.

### Phase 2: rewind (core + C ABI + app)

**`ps1-core/src/savestate/rewind.zig`.** A ring of reverse deltas:

- `head`: the newest trusted snapshot, in full.
- `entries`: newest first. Entry *k* turns snapshot *k* back into snapshot
  *k+1* (the older one). It is a list of runs of changed 8-byte words, each
  run `(word offset u32, word count u32, older words)`. Encoding is one pass
  over two buffers.
- Capture: `saveTrusted` into a scratch buffer, encode the delta from the new
  state back to `head`, push it, swap the buffers. Two 6.9 MB buffers stay
  allocated while rewind is on.
- Budget: the sum of the entries' sizes plus the two buffers. Over budget,
  the OLDEST entry is freed; nothing depends on it, so there are no
  keyframes.
- The deltas are not compressed further. The measured runs are mostly real
  changes, not zeros, and the budget already bounds memory.

**Capture runs inside `ps1_run_frame`** every 2 frames while rewind is on,
so no frontend has to call anything.

```c
int32_t ps1_rewind_configure(Ps1*, size_t budget_bytes);  /* 0 = off, frees everything */
int32_t ps1_rewind_step(Ps1*);
typedef struct { uint32_t entries; uint32_t frames_covered; size_t bytes_used; } Ps1RewindInfo;
void    ps1_rewind_info(Ps1*, Ps1RewindInfo*);
```

`ps1_rewind_step` pops the newest entry, rebuilds the older snapshot into
`head`, `loadTrusted`s it in place, then runs ONE frame with its audio
discarded and capture suppressed. That frame's GP0 stream is recorded as
usual, so the frontend's `ps1_take_frame_stream` after the step is the
picture to show. With history empty it returns `PS1_ERR_NO_HISTORY` and the
machine is unchanged. Rewinding therefore plays back at one shown frame per
two frames of history: about 30 fps of game time, backwards.

A disc swap, `ps1_load_state` or `ps1_reset` clears the history: none of
them is a point the player can rewind across.

**App.** A "Hold to Rewind" binding in `KeyBindings` (default Backspace,
optional pad button). While held, the runner calls `ps1_rewind_step` once
per loop instead of `ps1_run_frame`, writes no audio, publishes the VRAM
shadow and the stream as for a normal frame, and requests a resync after
each step. Every 3D game redraws its display every frame, so the picture
stays at scale; render-to-texture effects show 1x for a frame. Releasing
the binding just resumes: the history newer than that point was popped.
The HUD shows the seconds left, from `ps1_rewind_info`.

### Phase 3: runahead (app)

**The loop.** With runahead N > 0, speed 1x and no rewind held, one turn of
`runLoop` is:

1. Service requests and apply input and settings, as today.
2. `runFrame` the REAL frame. Its audio goes to the ring, its pad status and
   rumble are published, and its VRAM shadow and stream are published as
   today.
3. `ps1_snapshot_mark`.
4. N times: `runFrame` with the same input; read and discard its audio;
   publish its stream as SPECULATIVE in group `g`.
5. `ps1_snapshot_return`.

Disc swaps, state loads, resets and engine changes are serviced only in step
1, never between mark and return. Runahead is suspended above 1x and while
rewinding.

Cost per displayed frame is (1+N) frames plus one mark and one return, about
7 ms on Crash Warped at N=2.

**Metal speculation** (`StreamQueue`, `LiveRenderer`):

- `StreamSlot` gains `speculative: Bool` and `group: UInt64`.
  `StreamQueue.capacity` becomes `3 * (1 + maxRunahead)`, 12 slots at N=3.
- `drain` skips any speculative group followed by a real slot in the same
  drain: it is already stale.
- For the last group: compute the union of the VRAM rectangles its records
  write (drawing-area clip for primitives; the explicit rect for fill,
  upload and copy). Blit that region of the VRAM texture, the sidecar and
  the depth plane into scratch textures sized for it, replay the group, and
  present.
- The restore is DEFERRED to the start of the next drain, before any real
  slot, because the display pass must sample the speculative picture first.
  Between frames the texture holds only the real timeline, so the resync and
  dropped-frame rules apply unchanged. A resync discards a pending restore:
  adopting the shadow replaces the texture anyway.

**The VRAM shadow** a resync adopts is the real frame's, published in step 2.
A speculative frame publishes no shadow.

## Settings

| Setting | Values | Default |
| --- | --- | --- |
| Runahead | Off, 1, 2, 3 frames | Off |
| Rewind | On / Off | Off |
| Rewind memory | 128, 256, 512 MB | 256 MB |
| Hold to Rewind | key + optional pad button | Backspace |

Global, in the same settings pane as the CPU engine.

## Testing

**Core** (`savestate_test.zig`, new `rewind_test.zig` in `unit_test_files`):

- Reverse-delta encode/decode round trip on synthetic states: equal, fully
  different, changes at the first and last word, and odd lengths.
- Eviction: a budget that holds K entries keeps exactly the newest K; the
  bytes used never exceed the budget.
- `ps1_rewind_step` on an empty history leaves the machine unchanged.
- `loadTrusted` invalidation: a block on a page whose bytes change is
  dropped; a block on an unchanged page survives; BIOS blocks survive.

**Harnesses:** `trace-golden -- snapshot` under `.interpreter`, `.cached`
and `.jit`; the `pgxp` sweep with `--snapshot`. `ps1-bench` gains
`--runahead=N` and `--rewind` so their costs are timed through the frame
loop the app uses.

**C ABI** (`capi_test`): mark/return round trip; a memory-card write made
between mark and return is rolled back, dirty flag included;
`ps1_snapshot_return` without a mark; rewind configure, step and info; the
history is cleared by a swap, a load and a reset.

**Metal:** a fixture gate that replays a `.p1fx` with a speculative group
injected after every frame (the next frames of the same fixture) must leave
the real-timeline texture hashing identically to a plain replay. A Swift
test for the runner checks that speculative audio never reaches the ring
and that the pad status is the real frame's.

## Documentation

- `CLAUDE.md`: the new `trace-golden -- snapshot` row, and two rules:
  "a trusted load is only for bytes this process produced", and "the GPU
  texture holds only the real timeline between frames; a speculative
  group's restore is deferred to the next drain".
- `ps1-core-subsystems`: the trusted path, incremental invalidation, the
  mark slot and the rewind ring.
- `ps1-gpu-metal`: speculative groups and the deferred restore.
- `ps1-macos-app`: the runahead loop and the rewind binding.
