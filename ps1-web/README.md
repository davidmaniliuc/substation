# Substation for the browser

A PlayStation emulator compiled to WebAssembly, with a typed TypeScript
wrapper. `Ps1Core` is one emulated machine: synchronous and DOM-free, so it
runs on the main thread, in a Web Worker, or under `bun test`. Driving it
(the frame loop, the canvas, audio output, input) is the application's job.

## Use

```ts
import { Ps1Core, discFromFiles, toBytes } from '@davidmaniliuc/substation';

const core = await Ps1Core.create('/ps1/ps1.wasm'); // default: ./ps1.wasm beside index.js
core.setCpuEngine('cached');
core.loadBios(await toBytes(biosFile));             // the user's own 512 KB BIOS
const disc = await discFromFiles(pickedFiles);      // .chd, .cue + .bin(s), or .bin
core.loadDisc({ bin: await toBytes(disc.bin), cue: disc.cue, sbi: disc.sbi && (await toBytes(disc.sbi)), ppf: disc.ppf && (await toBytes(disc.ppf)) });

function frame() {
  core.runFrame();                                  // one video frame: 1/60 s NTSC, 1/50 s PAL (core.isPal)
  const { rgba, width, height } = core.frame();     // a view into wasm memory: draw it before the next runFrame
  ctx.putImageData(new ImageData(rgba.slice(), width, height), 0, 0);
  queueAudio(core.readAudio());                     // interleaved stereo float32 at AUDIO_SAMPLE_RATE (44100)
  requestAnimationFrame(frame);
}
```

| Method                                   | What it does                                                                 |
| ---------------------------------------- | ---------------------------------------------------------------------------- |
| `loadBios(bytes)`                        | Installs a BIOS and returns `{ known, region, version, description }`        |
| `loadDisc({ bin, cue?, sbi? })`          | Inserts a disc; a CHD is recognised by content and takes no cue              |
| `identifyDisc(bin)`                      | Region, serial, volume id and catalogued title, with no BIOS                 |
| `runFrame()` / `frame()`                 | Runs to the next vblank / the displayed picture as RGBA                      |
| `readAudio(max?)`                        | Drains the sound output (a copy, transferable)                               |
| `setButtons(mask)`                       | Pad 1. A 0 bit is PRESSED; `0xFFFF` is idle                                   |
| `loadMemcard(slot, bytes)`               | Installs a 128 KB card image in slot 0 or 1                                  |
| `takeMemcard(slot)`                      | The card's image if the game wrote it since the last call, else `null`       |
| `saveState()` / `loadState(bytes)`       | The whole machine; a refused state leaves the running machine untouched      |
| `reset()`, `setFastBoot(on)`, `setCpuEngine('interpreter' \| 'cached')` |                                                      |

Pad bits, low to high: Select, -, -, Start, Up, Right, Down, Left, L2, R2,
L1, R1, Triangle, Circle, Cross, Square.

`identifyDisc(file, { wasmUrl })`, exported beside the class, identifies a
disc in a short-lived instance of its own, for an upload form.

## Serving the wasm

`ps1.wasm` (~7 MB) is the package's one asset. Bundlers that understand
`new URL('./ps1.wasm', import.meta.url)` resolve the default. Others (the
Angular application builder, for one) do not rewrite it inside a
dependency: copy `node_modules/@davidmaniliuc/substation/dist/ps1.wasm` into your
public assets and pass its URL to `Ps1Core.create`. No COOP/COEP headers
are needed.

## Errors

Every refusal is a `Ps1Error` with a `code` (`BAD_BIOS_SIZE`, `BAD_CUE`,
`MULTI_FILE_CUE`, `BAD_CHD`, `STATE_DISC`, ...). A core panic reaches
JavaScript as a `WebAssembly.RuntimeError`; the machine is unusable after it.

## Limits

The disc is copied into wasm memory, so a 700 MB `.bin` needs 700 MB there;
a `.chd` of the same disc is a third to a half of that. The browser runs the
cached interpreter at best: full speed depends on the game and the machine.
One disc per core; no disc swap.

## Build

From the repository root: `zig build web` (needs Zig 0.17 and Bun) writes
`dist/`. Tests: `cd ps1-web && bun test` after `zig build`; the BIOS-dependent
ones skip without `SCPH-1001_BIOS_1995_US.bin` in the repository root.
