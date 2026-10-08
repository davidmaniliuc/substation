# ps1-web: the browser emulator as an npm package

Status: design approved 2026-10-08, not implemented

## Goal

A web application imports the emulator as a package and gets a playable PS1
in a `<canvas>` with a few lines of TypeScript. The first consumer is the
Angular frontend of the PS1 community platform
(`AngularM1_Miage_2026_2027_TP123/frontend-starter`, Bun as package manager),
which needs to play a small set of verified titles in the browser, persist
memory cards per user, and identify uploaded discs for its catalogue.

Success is:

1. `bun add` (or `bun link` during development) of `ps1-web/` into an Angular
   app, then `Ps1Player.create({ canvas })`, `loadBios`, `loadDisc`, `start`
   boots a disc to gameplay with picture, sound, keyboard and gamepad. The
   only build configuration is one `assets` entry in `angular.json` for
   `ps1.wasm`, and no COOP/COEP headers are needed.
2. Emulation runs in a Web Worker: a slow frame never blocks Angular's UI.
3. Memory cards, savestates, disc identification, CHD discs and fast boot
   work in the browser.
4. Every wasm failure reaches TypeScript as a typed `Ps1Error`, never a trap
   and never a silent no-op.
5. `ps1-wasm/www/index.html` is a demo built ON the package, not a second
   copy of its glue.

Non-goals: publishing to npm (a separate step after this lands), cheats,
patch application, PGXP and the other renderer settings, analog sticks,
disc swap, the JIT (arm64 host code; wasm keeps the interpreter and the
cached engine), sector streaming from a `Blob` (the disc is
copied into wasm memory; see Limits), and any change to `ps1-capi` or
`ps1-core`.

## Decision: ps1-wasm stays its own frontend

Compiling `ps1-capi` to wasm was considered and rejected by the author:
`ps1-wasm` keeps its own export set, polished in place, and `ps1-capi` is
untouched. The cost is that the four features below are written a second
time against the core; `ps1-capi/src/root.zig` is the model to follow for
each, especially its all-or-nothing state load and its card drain.

It also stays ONE machine per wasm instance (module globals, no handle).
Each `Ps1Core` instantiates its own module, so two players on a page are two
instances.

## The wasm export set (`ps1-wasm/src/`)

`main.zig` (424 lines today) splits by job so no file passes ~600 lines:

| File         | Exports                                                                                                                                     |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `main.zig`   | `init`, `reset`, `runFrame`, `setButtons(mask)`, `setCpuEngine(e) → i32`, `setFastBoot(on)`, the `panic`/`log` overrides                     |
| `media.zig`  | `alloc(len) → ptr`, `free(ptr, len)`, `loadBios(ptr, len) → i32`, `loadDisc(bin, bin_len, cue, cue_len, sbi, sbi_len) → i32`, `identifyDisc(ptr, len, out) → i32` |
| `saves.zig`  | `loadMemcard(slot, ptr, len) → i32`, `takeMemcard(slot, dst) → i32`, `saveStateSize() → usize`, `saveState(dst, cap) → i32`, `loadState(ptr, len) → i32` |
| `video.zig`  | `renderFrame() → ptr`, `frameWidth()`, `frameHeight()`, `isPal()`                                                                             |
| `audio.zig`  | `readAudio(dst, max_floats) → usize`                                                                                                          |

Rules carried over from `ps1-capi`, each for the reason given there:

- **Error codes are negative `i32`s**, one value per failure, the same
  meanings as `ps1.h`'s `PS1_ERR_*` where one exists (bad BIOS size, bad cue,
  multi-file cue, OOM, bad sbi, bad memcard size, bad slot, the six state
  errors, engine unavailable, bad CHD). `0` is success.
- **`loadBios` copies and identifies.** It keeps the 512 KB image (a reset
  rebuilds `Bus`, which clears `bus.bios`), installs it through
  `ps1.bios.install` with the fast-boot patch only when fast boot is on AND a
  PlayStation disc is in, and writes the `ps1.bios.identify` result (known,
  region, version) into an out struct.
- **`loadDisc` detects CHD by content** (`ps1.chd.isChd`) and rejects a cue
  beside one; validates the `.sbi` magic; accepts a multi-FILE cue only when
  its images arrive concatenated with `REM FILESIZE` seams (the package's
  `discFromFiles` does that, as the old page did); and
  leaves the previous disc installed on every failure. The `.bin` bytes stay
  in a wasm buffer the module owns for as long as that disc is in.
- **`identifyDisc` needs no BIOS and touches no machine state**: region,
  serial, volume id, plus `game_titles` / `discdb` lookups for the title and
  disc number. A CHD opens its own reader and closes it before returning.
- **`takeMemcard` is a DRAIN**: returns 1 having copied 128 KB and cleared
  dirty, or 0 having touched nothing. A reset carries the live cards and
  their dirty flags across.
- **`loadState` is all-or-nothing**: decode into a fresh `Bus` carrying the
  BIOS, disc and cards, swap it in only on success. A refused state leaves
  the running machine exactly as it was.
- **`renderFrame` converts the display area to RGBA inside wasm** (15-bit
  and 24-bit modes) into a module-owned buffer sized for the largest mode.
  JavaScript never reads VRAM.
- **`readAudio` drains the SPU ring**: the ring's indices stay inside wasm,
  odd `max_floats` truncates to a whole stereo pair.

Deleted: the TEMPORARY Jungle Rollers probe (the bug is closed; it scanned
64 KB of RAM every frame), the `.exe` sideload path (`allocExeBuffer`,
`stageExeForSideload`, `loadExeAndRun`, `checkPendingExe`; it serves the ROM
test `.exe`s, which have their own harness), and the raw audio-index and
`getVramPtr` exports.

The wasm build stays `ReleaseFast` whatever `-Doptimize` says, and stays on
the `.software` GPU sink.

## The package (`ps1-web/`)

```
ps1-web/
  package.json         exports "." → dist/index.js + dist/index.d.ts; files: ["dist"]
  tsconfig.json
  src/index.ts         re-exports
  src/core.ts          Ps1Core
  src/errors.ts        Ps1Error, the code table
  src/player.ts        Ps1Player (main thread)
  src/worker.ts        the emulation worker
  src/protocol.ts      the typed main ↔ worker messages
  src/audio-worklet.ts
  src/input.ts         default keyboard map, Gamepad API → button mask
  test/*.test.ts
```

### `Ps1Core`: no DOM

A thin synchronous class over one wasm instance. It owns the instance and
its memory, copies inputs in through `alloc`/`free`, and turns every
negative code into a `Ps1Error` (`code` a string union such as
`"BAD_BIOS_SIZE"`, `"STATE_DISC"`). It runs in a worker and under
`bun test`.

```ts
const core = await Ps1Core.create(wasmSource?);        // default: new URL('./ps1.wasm', import.meta.url)
core.loadBios(bytes): BiosInfo                         // { known, region, version }
core.loadDisc({ bin, cue?, sbi? }): void
core.runFrame(): void
core.frame(): { rgba: Uint8ClampedArray, width, height }  // a view; valid until the next runFrame
core.readAudio(max): Float32Array
core.setButtons(mask), core.reset(), core.setFastBoot(on), core.setCpuEngine(e)
core.loadMemcard(slot, bytes), core.takeMemcard(slot): Uint8Array | null
core.saveState(): Uint8Array, core.loadState(bytes)
Ps1Core.identifyDisc(bytes): DiscInfo                  // { serial, region, volumeId, title, discNumber }
```

### `Ps1Player`: the browser

```ts
const player = await Ps1Player.create({ canvas, wasmUrl?, keymap? });
await player.loadBios(file);          // Blob | ArrayBuffer | Uint8Array → BiosInfo
await player.loadDisc({ bin, cue?, sbi? });
await player.loadMemcard(slot, bytes);
player.on('memcard', (slot, bytes) => …);   // fired when the worker drains a dirty card
player.on('error', (e: Ps1Error) => …);
player.start(); player.pause(); player.reset();
player.volume = 0.8;
await player.saveState(); await player.loadState(bytes);
player.destroy();
```

- **Video**: `canvas.transferControlToOffscreen()` goes to the worker, which
  `putImageData`s the frame after each `runFrame`. Frames never cross to the
  main thread. The canvas keeps 4:3 by CSS; the player sets its pixel size to
  the frame's.
- **Pacing**: the worker runs frames against `performance.now()` at 59.94 Hz,
  or 50 Hz when `isPal()`, catching up at most a few frames after a stall
  rather than fast-forwarding.
- **Audio**: an `AudioWorklet` at 44100 Hz fed through a `MessagePort` from
  the worker (transferred `Float32Array` chunks), with a small jitter buffer.
  No `SharedArrayBuffer`, so no COOP/COEP headers. The `AudioContext` is
  resumed on the first `start()`, which a user gesture must call.
- **Input**: keyboard events and `navigator.getGamepads()` polling on the main
  thread fold into one 16-bit mask (`sio.zig`'s 0 = pressed convention),
  posted to the worker when it changes. `keymap` overrides the default.
- **Memory cards**: the worker calls `takeMemcard` for both slots once per
  second while running and on `pause`/`destroy`, and posts each non-null
  image as a `memcard` event. Persisting it is the application's job.
- **Errors**: a refused call rejects its promise with the `Ps1Error`; a
  wasm trap in the worker (a core panic) stops the loop and fires `error`.
  The wasm `panic` logs and then `@trap()`s: today it spins forever, which
  would hang the worker with nothing to report.

### Loading the wasm, the worker and the worklet

The wasm (6.8 MB) is the package's ONE asset. Angular's application builder
does not rewrite `new URL('./x.wasm', import.meta.url)` inside a
dependency, so a consumer declares it once in `angular.json`:

```json
{ "glob": "ps1.wasm", "input": "node_modules/<package>/dist", "output": "ps1" }
```

and passes `wasmUrl: '/ps1/ps1.wasm'`. Without `wasmUrl` the default is
`new URL('./ps1.wasm', import.meta.url)`, which plain bundlers and the demo
page resolve. The main thread compiles the module once
(`WebAssembly.compileStreaming`) and posts the `WebAssembly.Module` to the
worker.

The worker and the AudioWorklet are NOT assets: the build bundles each to a
string and the player starts them from `Blob` URLs, so no bundler has to
understand `new Worker(new URL(...))` inside `node_modules`.

### `discFromFiles`

A helper that turns what an `<input type=file multiple>` or a folder picker
returns into a `DiscInput`, carrying the old page's rules: a `.chd` wins; else
the alphabetically first `.cue` (a multi-disc folder holds several), its
FILEs found by name and concatenated in cue order as a lazy `Blob` with a
`REM FILESIZE` line before each; else the largest `.bin`; and the `.sbi`
whose stem matches the disc's, or the only one present.

## Build

`zig build web`:

1. builds the wasm (`ReleaseFast`, as `zig build` already does);
2. runs `ps1-web/build.ts` under Bun, which bundles `worker.ts` and
   `audio-worklet.ts` to strings, writes them into the gitignored
   `src/inline.gen.ts`, bundles `index.ts` to `dist/index.js` (ESM, browser
   target), copies the wasm to `dist/ps1.wasm`, and runs
   `tsc --emitDeclarationOnly` for the `.d.ts` files.

The step fails with a clear message when `bun` is not on PATH, the way
`zig build macos` does without Xcode. `ps1-web/dist/`, `ps1-web/node_modules/` and `src/inline.gen.ts` are gitignored.

## Demo page

`ps1-wasm/www/index.html` is rewritten as a ~50-line page that imports
`ps1-web/dist/index.js`: BIOS and disc pickers, a canvas, start/pause/reset,
save/load state, memory card download. Its current 444 lines of glue go.

## Testing

- `bun test` in `ps1-web/` against `Ps1Core`, no BIOS needed:
  every loader refuses bad input with the right `Ps1Error.code`;
  `identifyDisc` reads serial and region from a synthetic ISO;
  a clean card drains `null`; a refused `loadState` leaves the machine
  running (a following `runFrame` and `saveState` still work).
- BIOS-gated, self-skipping without `SCPH-1001_BIOS_1995_US.bin` in the repo
  root: boot 300 frames, the last frame is not all one colour, audio
  produced samples, save → load → save gives identical bytes, and a
  `.chd` from `games/` (if present) boots like its `.cue`.
- `Ps1Player` is verified by hand through the demo page in Chrome and
  Safari: picture, sound, keyboard, gamepad, a memory card survives a
  reload, a savestate round-trips.
- `zig build test` is unaffected; `ps1-wasm` has no Zig unit tests and
  gains none (its logic is reached through `bun test`).

## Limits

- **The disc is copied into wasm memory.** A 700 MB `.bin` needs ~700 MB of
  wasm32 memory on top of the JavaScript copy; a CHD of the same disc is
  typically a third to a half of that. Streaming sectors from a `Blob` through
  `FileReaderSync` would remove the copy but needs a host-callback disc
  source in the core: deferred.
- **Speed**: the browser runs the cached interpreter at best. Whether a given
  title holds full speed is per game and per machine; the platform's
  "verified titles" list is where that is recorded, not this package.
- **One disc per player**; no disc swap, so multi-disc games stop at the end
  of disc 1.
